unit AVM2.Runtime;

{$IF Defined(MSWINDOWS) and Defined(CPUX64)}
  {$DEFINE AVM2_WIN64_JIT}
{$IFEND}

interface

uses
  System.SysUtils, System.Generics.Collections, Xml.XMLIntf,
  Media.Image.PixelBuffer, SWF.Reader, AVM2.ABC
  {$IFDEF AVM2_WIN64_JIT}, HW.JIT{$ENDIF};

type
  TAVM2Object = class;

  TAVM2Module = class;

  TAVM2ValueKind = (a2Undefined, a2Null, a2Boolean, a2Int, a2UInt, a2Number, a2String, a2Object);

  TAVM2TypeKind = (atAny, atObject, atString, atBoolean, atNumber, atInt, atUInt, atFunction, atVoid, atClass);

  TAVM2PrimitiveMethod = (pmNone, pmCharAt, pmCharCodeAt, pmConcat, pmIndexOf,
    pmLastIndexOf, pmSlice, pmSubstr, pmSubstring, pmSplit, pmMatch, pmSearch, pmReplace, pmLowerCase, pmUpperCase,
    pmStringText, pmStringValue, pmBooleanText, pmBooleanValue, pmNumberText,
    pmNumberValue, pmNumberFixed, pmNumberExponential, pmNumberPrecision, pmFromCharCode);

  TAVM2RegExpMethod = (reExec, reTest, reText);

  TAVM2RegExpFlags = set of  (rfGlobal, rfIgnoreCase, rfMultiline, rfDotAll, rfExtended);

  TAVM2RegExp = class
    Source: string;
    Flags: TAVM2RegExpFlags;
    LastIndex: Integer;
    Compiled: Pointer;
    CompileTried: Boolean;
    LibraryLoaded: Boolean;
    CaptureCount: Integer;
    destructor Destroy; override;
  end;

  TAVM2RegExpInput = record
    Text: string;
    {$IFNDEF MSWINDOWS}
    Encoded: UTF8String;
    ByteOffsets: TArray<Integer>;
    {$ENDIF}
  end;

  TAVM2RegExpMatch = record
    Offsets: TArray<Integer>;
  end;

  TAVM2ObjectKind = (a2PlainObject, a2Script, a2Class, a2Function);

  TAVM2EventKind = (aeNone, aeEvent, aeKeyboard, aeMouse, aeTimer, aeProgress, aeText, aeError, aeStatus, aeFocus);

  TAVM2FrameEvent = (afEnter, afConstructed, afExit);

  TAVM2EventMethod = (aeAddListener, aeRemoveListener, aeHasListener, aeWillTrigger,
    aeDispatch, aeStop, aeStopImmediate, aePreventDefault, aeIsDefaultPrevented, aeToString);

  TAVM2TimerMethod = (tmStart, tmStop, tmReset, tmGetTimer, tmSetInterval, tmSetTimeout,
    tmClearInterval, tmClearTimeout, tmCloneEvent, tmEventText, tmUpdateAfterEvent);

  TAVM2SharedReader = reference to function(const Origin, Key: string; out Data: TBytes): Boolean;

  TAVM2SharedWriter = reference to function(const Origin, Key: string; const Data: TBytes): Boolean;

  TAVM2ResourceReader = reference to function(const BaseURI, URL: string; out Data: TBytes; out ResolvedURI: string): Boolean;

  TAVM2BitmapMethod = (abDraw, abCopyPixels, abFillRect, abGetPixel, abGetPixel32, abSetPixel,
    abSetPixel32, abClone, abDispose, abLock, abUnlock, abColorBounds);

  TAVM2MathMethod = (amAbs, amAcos, amAsin, amAtan, amAtan2, amCeil, amCos, amExp, amFloor,
    amLog, amMax, amMin, amPow, amRandom, amRound, amSin, amSqrt, amTan);

  TAVM2DateMethod = (admGetTime, admSetTime, admToString, admValueOf);

  TAVM2TextMethod = (atfSetFormat, atfAppendText, atfSetSelection);

  TAVM2StyleMethod = (atsClear, atsSetStyle, atsGetStyle);

  TAVM2SoundMethod = (asPlay, asStop);

  TAVM2XMLMethod = (axLength, axChild, axChildren, axElements, axAttribute, axAttributes,
    axDescendants, axText, axString, axXMLString, axName);

  TAVM2SharedMethod = (asGetLocal, asFlush, asClear, asSetProperty, asSetDirty);

  TAVM2URLMethod = (auLoad, auClose, auDecode, auEncode, auLoadBytes, auUnload, auUnloadAndStop);

  TAVM2ConnectionMethod = (acConnect, acClose, acSend, acAllowDomain, acAllowInsecureDomain);

  TAVM2Listener = record
    Name: string;
    Callback: TAVM2Object;
    Capture: Boolean;
    Priority: Integer;
  end;

  TAVM2DisplayKind = (adNone, adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton, adGraphics);

  TAVM2DisplayMethod = (adAddChild, adAddChildAt, adRemoveChild, adRemoveChildAt,
    adGetChildAt, adGetChildIndex, adSetChildIndex, adContains,
    adClear, adBeginFill, adEndFill, adMoveTo, adLineTo, adCurveTo, adDrawRect,
    adDrawCircle, adDrawEllipse, adDrawRoundRect, adBeginBitmapFill, adLineStyle, adLocalToGlobal, adGlobalToLocal,
    adHitTestPoint, adHitTestObject, adGetBounds, adGetRect, adGetChildByName);

  TAVM2FrameLabel = record
    Name: string;
    Frame: Integer;
  end;

  TAVM2TimelineChild = record
    Handle: TObject;
    Name, ClassName, SymbolClass: string;
    X, Y, ScaleX, ScaleY, Rotation, Alpha: Double;
    Visible: Boolean;
  end;

  TAVM2PointMethod = (apAdd, apSubtract, apClone, apCopyFrom, apEquals, apNormalize,
    apOffset, apSetTo, apText, apDistance, apInterpolate, apPolar);

  TAVM2RectangleMethod = (arClone, arIsEmpty, arSetEmpty, arInflate, arInflatePoint,
    arOffset, arOffsetPoint, arContains, arContainsPoint, arContainsRect, arIntersection,
    arIntersects, arUnion, arEquals, arText, arCopyFrom, arSetTo);

  TAVM2Rectangle = record
    X, Y, Width, Height: Double;
    function Right: Double;
    function Bottom: Double;
    function IsEmpty: Boolean;
  end;

  TAVM2MatrixMethod = (amClone, amConcat, amIdentity, amInvert, amRotate, amScale,
    amTranslate, amTransformPoint, amDeltaTransformPoint, amCreateBox, amCreateGradientBox,
    amCopyFrom, amSetTo, amCopyRowFrom, amCopyRowTo, amCopyColumnFrom, amCopyColumnTo, amText);

  TAVM2Matrix = record
    case Integer of
      0:
        (A, B, C, D, TX, TY: Double);
      1:
        (Values: array[0..5] of Double);
  end;

  TAVM2BitmapDraw = record
    Matrix: TAVM2Matrix;
    Clip: TAVM2Rectangle;
    Color: array[0..7] of Double;
    Blend: string;
    HasClip, Smooth: Boolean;
  end;

  TAVM2ByteArray = class
    Buffer: TBytes;
    Size: Integer;
    Position: Cardinal;
    LittleEndian: Boolean;
  end;

  TAVM2ByteMethod = (abClear, abReadByte, abReadUnsignedByte, abReadBoolean,
    abReadShort, abReadUnsignedShort, abReadInt, abReadUnsignedInt,
    abReadFloat, abReadDouble, abReadUTF, abReadUTFBytes, abWriteByte,
    abWriteBoolean, abWriteShort, abWriteInt, abWriteUnsignedInt,
    abWriteFloat, abWriteDouble, abWriteUTF, abWriteUTFBytes, abToString, abReadBytes, abWriteBytes,
    abCompress, abUncompress, abDeflate, abInflate);

  TAVM2Value = record
    Kind: TAVM2ValueKind;
    Number: Double;
    Text: string;
    Obj: TAVM2Object;
    class function Num(AValue: Double; AKind: TAVM2ValueKind = a2Number): TAVM2Value; static;
    class function Str(const AValue: string): TAVM2Value; static;
    class function Ref(AValue: TAVM2Object): TAVM2Value; static;
  end;

  TAVM2Array = class
    Elements: TDictionary<Cardinal, TAVM2Value>;
    OrderedKeys: TArray<Cardinal>;
    ArrayLength: Cardinal;
    Prototype: TAVM2Array;
    Joining: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TAVM2ArrayMethod = (aaPush, aaPop, aaJoin, aaToString, aaShift, aaUnshift,
    aaReverse, aaSlice, aaSplice, aaIndexOf, aaLastIndexOf, aaForEach, aaMap, aaFilter, aaEvery, aaSome,
    aaSort, aaSortOn, aaConcat);

  TAVM2ObjectMethod = (omPropertyIsEnumerable, omSetPropertyIsEnumerable, omHasOwnProperty, omToString, omValueOf);

  TAVM2VectorMethod = (vePush, vePop, veShift, veUnshift, veJoin, veToString,
    veReverse, veIndexOf, veLastIndexOf, veSlice, veConcat, veSplice,
    veEvery, veSome, veForEach, veMap, veFilter, veInsertAt, veRemoveAt, veSort, veToLocaleString);

  TAVM2DynamicProperty = record
    Key: string;
    Enumerable: Boolean;
    ObjectKey: TAVM2Object;
  end;

  TAVM2DictionaryEntry = record
    Slot: Integer;
    Value: TAVM2Value;
  end;

  TAVM2TimedCall = record
    Id, Interval: Integer;
    Due: Int64;
    Owner, Callback: TAVM2Object;
    Args: TArray<TAVM2Value>;
    Once: Boolean;
  end;

  TAVM2LoadedMovie = record
    Width, Height, Version: Integer;
    FrameRate: Double;
  end;

  TAVM2DisplayHost = class abstract
    function CreateStage: TObject; virtual; abstract;
    function EmbeddedBytes(const ClassName: string; out Data: TBytes): Boolean; virtual;
    function MovieBytes: TBytes; virtual;
    function LoadTimeline(const Data: TBytes; out Info: TAVM2LoadedMovie): TObject; virtual;
    procedure StopTimeline(Display: TObject); virtual;
    function SoundLength(const ClassName: string): Double; virtual;
    function StartSound(const ClassName: string; Channel: TAVM2Object; Start: Double; Loops: Integer): Boolean; virtual;
    procedure StopSound(Channel: TAVM2Object); virtual;
    function EmbeddedBitmap(const ClassName: string): IImagePixelBuffer; virtual;
    procedure AttachBitmap(Display: TObject; const Buffer: IImagePixelBuffer; Smooth: Boolean); virtual;
    procedure BeginBitmapFill(Display: TObject; const Buffer: IImagePixelBuffer; const Matrix: TAVM2Matrix; RepeatFill, Smoothing: Boolean); virtual;
    procedure DrawBitmap(const Target: IImagePixelBuffer; Source: TAVM2Object; const Options: TAVM2BitmapDraw); virtual;
    function GetColorTransform(Display: TObject): TSWFColorTransform; virtual;
    procedure SetColorTransform(Display: TObject; const Value: TSWFColorTransform); virtual;
    function GetFilters(Display: TObject): TSWFFilters; virtual;
    procedure SetFilters(Display: TObject; const Filters: TSWFFilters); virtual;
    procedure SetMask(Display, Mask: TObject); virtual;
    procedure InitializeText(Display: TObject); virtual;
    function GetTextProperty(Display: TObject; const Name: string; out Value: TAVM2Value): Boolean; virtual;
    function SetTextProperty(Display: TObject; const Name: string; const Value: TAVM2Value): Boolean; virtual;
    procedure SetTextFormat(Display: TObject; Format: TAVM2Object; First, Last: Integer); virtual;
    function CreateDisplay(Document: Boolean; const Classes: TArray<string>; out Name: string): TObject; virtual; abstract;
    procedure Place(Child, Parent: TObject; Position: Integer); virtual; abstract;
    procedure RequestFrameScript(Display: TObject; Frame: Integer); virtual; abstract;
    procedure SetPlaying(Display: TObject; Playing: Boolean); virtual; abstract;
    function GotoFrame(Display: TObject; const Target, Scene: string; HasScene, Playing: Boolean): Boolean; virtual; abstract;
    function TimelineFrame(Display: TObject; Total: Boolean): Integer; virtual; abstract;
    function TimelineLabels(Display: TObject): TArray<TAVM2FrameLabel>; virtual;
    procedure SetProperty(Display: TObject; const Name: string; Value: Double); virtual; abstract;
    procedure Draw(Display: TObject; Command: TAVM2DisplayMethod; const Args: TArray<Double>); virtual; abstract;
    procedure TransformPoint(Display: TObject; ToGlobal: Boolean; var X, Y: Double); virtual; abstract;
    function GetScrollRect(Display: TObject; out Rect: TAVM2Rectangle): Boolean; virtual; abstract;
    procedure SetScrollRect(Display: TObject; Enabled: Boolean; const Rect: TAVM2Rectangle); virtual; abstract;
    function GetMatrix(Display: TObject; Concatenated, OnStage: Boolean): TAVM2Matrix; virtual; abstract;
    procedure SetMatrix(Display: TObject; const Matrix: TAVM2Matrix; out X, Y, ScaleX, ScaleY, Rotation: Double); virtual; abstract;
    function HitTestPoint(Display: TObject; X, Y: Double; Shape, OnStage: Boolean): Boolean; virtual; abstract;
    function HitTestObject(Display, Other: TObject): Boolean; virtual; abstract;
    function GetBounds(Display, Target: TObject; IgnoreStrokes, PixelBounds: Boolean): TAVM2Rectangle; virtual; abstract;
    function DisplayChildren(Display: TObject): TArray<TAVM2TimelineChild>; virtual; abstract;
  end;

  TAVM2ConnectionMessage = record
    Sender: TAVM2Object;
    Channel, Method: string;
    Arguments: TArray<TAVM2Value>;
  end;

  TAVM2URLLoad = record
    Loader: TAVM2Object;
    URL, Method: string;
    Ticket: UInt64;
    FromBytes: Boolean;
    Bytes: TBytes;
  end;

  TAVM2Accessor = record
    Getter, Setter: TAVM2Object;
  end;

  PAVM2Value = ^TAVM2Value;

  TAVM2Properties = class
  private
    FIndices: TDictionary<string, Integer>;
    FDeclaredIndices: TDictionary<string, Integer>; // Borrowed from the class layout.
    FEntries: TArray<TPair<string, TAVM2Value>>;
    FCount, FDeclaredCount: Integer;
    FMayHaveNumericNames: Boolean; // Includes every property key ending in a decimal digit.
    // Number of property cells pointing to objects managed by the collector.
    FHostReferences: Integer;
    FHostReferenceSlots: NativeUInt;
    procedure NoteReferenceChange(var Slot: TAVM2Value; Current: TAVM2Object); inline;
    procedure StoreValue(var Slot: TAVM2Value; const Value: TAVM2Value); inline;
    // Valid until the next structural change to this table.
    function FindHinted(const Key: string; var Hint: Integer): PAVM2Value;
    function FindIndex(const Key: string; out Index: Integer): Boolean; inline;
    function RequireIndex(const Key: string): Integer;
    function GetItem(const Key: string): TAVM2Value;
    procedure SetItem(const Key: string; const Value: TAVM2Value);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Key: string; const Value: TAVM2Value);
    procedure AddOrSetValue(const Key: string; const Value: TAVM2Value);
    procedure Remove(const Key: string);
    procedure Clear;
    function ContainsKey(const Key: string): Boolean; inline;
    function TryGetValue(const Key: string; var Value: TAVM2Value): Boolean;
    function TrySetHinted(const Key: string; var Hint: Integer; const Value: TAVM2Value): Boolean;
    property Items[const Key: string]: TAVM2Value read GetItem write SetItem; default;
  end;

  TAVM2SlotLayout = class
    Names: TDictionary<Integer, string>;
    Types: TDictionary<string, TPair<TAVM2Module, Integer>>;
    // Offset plus one. Zero denotes a slot which requires name resolution.
    Offsets: TArray<Integer>;
    Flags: TBytes;
    PropertyIndices: TDictionary<string, Integer>;
    Defaults: TArray<TPair<string, TAVM2Value>>;
    destructor Destroy; override;
  end;

  TAVM2FieldBinding = record
    Layout: TAVM2SlotLayout;
    NameIndex, Offset: Integer;
  end;

  TAVM2Object = class
    Kind: TAVM2ObjectKind;
    Props: TAVM2Properties;
    HasPlainInstances: Boolean; // Script class whose ancestors have no native instance properties.
    Accessors: TDictionary<string, TAVM2Accessor>;
    DynamicProperties: TList<TAVM2DynamicProperty>;
    DynamicIndices: TDictionary<string, Integer>;
    DictionaryKeys: TDictionary<TAVM2Object, TAVM2DictionaryEntry>;
    BoundNativeMethods: TDictionary<TAVM2Object, TAVM2Object>;
    TraitMethods: TDictionary<Integer, TAVM2Object>;
    NeedsMethodReceiver: Boolean;
    Slots: TDictionary<Integer, string>;
    InstanceSlots: TAVM2SlotLayout; // Owned by the class.
    DeclaredSlots: TAVM2SlotLayout; // Borrowed by the instance.
    SlotTypes: TDictionary<string, TPair<TAVM2Module, Integer>>;
    ByteArrayData: TAVM2ByteArray;
    ArrayData: TAVM2Array;
    XMLDocument: IXMLDocument;
    XMLNodes: TArray<IXMLNode>;
    SoundFinished: Boolean;
    BitmapData: IImagePixelBuffer;
    FilterData: ^TSWFFilter;
    VectorData: TList<TAVM2Value>;
    VectorFixed, VectorJoining: Boolean;
    HasNamespaceURI: Boolean;
    NamespaceURI: string;
    IsVectorType: Boolean;
    VectorElementType, VectorSpecialization: TAVM2Object;
    Module: TAVM2Module;
    Parent, ClassObject, Script: TAVM2Object;
    Scope: TArray<TAVM2Value>;
    InstanceScope: TArray<TAVM2Value>;
    Index, State: Integer;
    DisplayName: string;
    DisplayKind: TAVM2DisplayKind;
    DisplayData: TObject;
    DisplayParent: TAVM2Object;
    DisplayChildren: TList<TAVM2Object>;
    TimelineBindings: TDictionary<string, TAVM2Object>;
    FrameScripts: TDictionary<Integer, TAVM2Object>;
    TimelinePlaced, TimelineConstructorPending, DisplayRemoving: Boolean;
    BoundReceiver: TAVM2Value;
    FunctionPrototype: TAVM2Object;
    InstancePrototype: TAVM2Object;
    PrimitiveKind: TAVM2TypeKind;
    RegExp: TAVM2RegExp;
    CanDispatch, NativeError: Boolean;
    Listeners: TList<TAVM2Listener>;
    EventKind: TAVM2EventKind;
    IsTimer, IsLocalConnection: Boolean;
    ConnectionName, SharedKey: string;
    URLTicket: UInt64;
    IsPoint, IsRectangle: Boolean;
    IsMatrix, IsVector3D, Matrix3DActive: Boolean;
    TransformOwner: TAVM2Object;
    TimerID: Integer;
    EventStop: Integer;
    EventCancelled, EventDispatching, HostManaged, HostMarked: Boolean;
    constructor Create(AKind: TAVM2ObjectKind);
    destructor Destroy; override;
  end;

  TAVM2ResolvedType = record
    Generation: UInt64;
    Kind: TAVM2TypeKind;
    ClassObject: TAVM2Object;
    QualifiedName: string;
  end;

  TAVM2NumericOp = (anLoadLocal, anLoadField, anInt, anUInt, anNumber, anBoolean,
    anConvert, anNegate, anAdd, anSubtract, anMultiply, anDivide);

  TAVM2NumericInstruction = record
    Kind: TAVM2NumericOp;
    Target, Source: Byte;
    Operand: Integer;
    case Boolean of
      False:
        (Number: Double);
      True:
        (FieldLayout: TAVM2SlotLayout;
        FieldSlot: Integer);
  end;

  {$IFDEF AVM2_WIN64_JIT}
  TAVM2NumericSample = record
    Kind: TAVM2ValueKind;
    Layout: TAVM2SlotLayout;
    SlotIndex: Integer;
  end;
  {$ENDIF}

  TAVM2NumericRegion = record
    First, Limit, Next, Peak, OutputCount: Integer;
    StoreLocal, StoreField, StoreRegister, Work: Integer;
    {$IFDEF AVM2_WIN64_JIT}
    NativeCode: TJitAsm;
    NativeEntry: Pointer;
    Warmups: Byte;
    {$ENDIF}
  end;

  TAVM2NumericMethod = record
    Calls: Integer;
    EncodedCode: TBytes;
    Offsets: TArray<Word>;
    Regions: TArray<TAVM2NumericRegion>;
    Code: TArray<TAVM2NumericInstruction>;
  end;

  TAVM2CapturedBinding = record
    Layout: TAVM2SlotLayout;
    Owner: TAVM2Object;
    NameIndex, Offset: Integer;
  end;

  TAVM2Module = class
    ABC: TABCFile;
    Id: Integer;
    Scripts, Classes, NamespaceObjects: TArray<TAVM2Object>;
    Boundaries: TArray<TBytes>;
    NumericMethods: TArray<TAVM2NumericMethod>;
    StaticNames: TArray<TArray<string>>;
    PublicIndexSets: TBytes; // Lazily records which sets contain the public namespace.
    ResolvedTypes: TArray<TAVM2ResolvedType>;
    FieldBindings: TArray<TAVM2FieldBinding>;
    CapturedBindings: TArray<TAVM2CapturedBinding>;
    PropertyHints: TArray<Integer>; // Validated against the property key after any layout change.
    constructor Create(const Data: TBytes; AId: Integer);
    destructor Destroy; override;
  end;

  TAVM2IndexedNames = record
    Module: TAVM2Module;
    NamespaceSet, Index: Integer;
    Name: string;
    Keys: TArray<string>;
  end;

  TAVM2CollectionStats = record
    // ObjectBytes counts the tracked object bodies, excluding their owned buffers.
    MovieTimeMS: Int64;
    NewObjects, RootObjects, DirectlyReachable, LiveObjects, TrackedObjects, FreedObjects: Integer;
    ObjectBytes, ObjectBytesAfter: Int64;
    ByteArrayCapacity, ByteArrayCapacityAfter: Integer;
    ArrayElements, ArrayElementsAfter: Integer;
    ClockFrequency, RootTicks, MarkTicks, SweepTicks: Int64;
    // Logically retired objects awaiting physical reclamation.
    PendingObjects: Integer;
  end;

  TAVM2CollectionObserver = reference to procedure(const Stats: TAVM2CollectionStats);

  TAVM2ReclaimObserver = reference to procedure(SweepTicks: Int64; PendingObjects: Integer);

  TAVM2Runtime = class
  private
    type
      TNumericRegister = record
        Kind: TAVM2ValueKind;
        Number: Double;
        Obj: TAVM2Object;
      end;

      TExecutionScratch = record
        Stack, Locals, Scopes: TArray<TAVM2Value>;
        Numeric: array[0..31] of TNumericRegister;
      end;

      TAVM2Relation = (arUnordered, arLess, arEqual, arGreater);
  private
    FObjects: TObjectList<TAVM2Object>;
    FModules: TObjectList<TAVM2Module>;
    FDefinitions: TDictionary<string, TAVM2Object>;
    FDefinitionGeneration: UInt64;
    FExecutionScratch: array[0..127] of TExecutionScratch;
    FNumericIRBudget: Integer;
    {$IFDEF AVM2_WIN64_JIT}
    FNumericJitBudget, FNumericCompiles: Integer;
    FNumericJitEnabled: Boolean;
    {$ENDIF}
    FLoadedTags: TDictionary<Integer, Boolean>;
    FNative, FDocument, FAddFrameScript, FPlayMovieClip, FStopMovieClip, FErrorToString: TAVM2Object;
    FGotoAndPlay, FGotoAndStop: TAVM2Object;
    FByteArrayClass, FDictionaryClass, FNamespaceClass: TAVM2Object;
    FByteArrayMethods: array[TAVM2ByteMethod] of TAVM2Object;
    FByteArrayCapacity: Integer;
    FArrayClass, FArrayPrototype: TAVM2Object;
    FFunctionClass, FFunctionPrototype: TAVM2Object;
    FObjectClass, FObjectPrototype: TAVM2Object;
    FClassClass, FClassPrototype: TAVM2Object;
    FPrimitiveClasses: array[atString..atUInt] of TAVM2Object;
    FPrimitiveMethods: array[TAVM2PrimitiveMethod] of TAVM2Object;
    FRegExpClass: TAVM2Object;
    FForwardDepth: Integer;
    FArrayMethods: array[TAVM2ArrayMethod] of TAVM2Object;
    FArrayElements: Integer;
    FVectorClass, FVectorWildcard: TAVM2Object;
    FVectorMethods: array[TAVM2VectorMethod] of TAVM2Object;
    FSWFVersion: Integer;
    FRandomState: Cardinal;
    FTrace: TProc<string>;
    FDisplay: TAVM2DisplayHost;
    FDisplayFunctions: array[TAVM2DisplayMethod] of TAVM2Object;
    FStage, FEnterFrameClass, FKeyboardClass, FMouseClass, FFocusClass, FFocus: TAVM2Object;
    FMouseVisible: Boolean;
    FLoaderInfo, FFrameLabelClass: TAVM2Object;
    FLocalConnectionClass, FStatusEventClass: TAVM2Object;
    FLoaderClass, FLoaderContextClass: TAVM2Object;
    FURLRequestClass, FURLVariablesClass, FURLLoaderClass, FIOErrorEventClass: TAVM2Object;
    FURLLoads: TList<TAVM2URLLoad>;
    FURLSerial: UInt64;
    FEventDispatcherInterface: TAVM2Object;
    FBitmapPool: IImagePixelPool;
    FBitmapClass, FBitmapDataClass, FColorTransformClass: TAVM2Object;
    FBitmapFilterClass, FGlowFilterClass: TAVM2Object;
    FProxyClass, FDateClass, FQNameClass: TAVM2Object;
    FStyleSheetClass, FTextFieldClass, FTextFormatClass: TAVM2Object;
    FSoundClass, FSoundChannelClass, FSoundTransformClass: TAVM2Object;
    FSoundChannels: TList<TAVM2Object>;
    FXMLClass, FXMLListClass: TAVM2Object;
    FXMLMethods: array[TAVM2XMLMethod] of TAVM2Object;
    FSharedObjectClass: TAVM2Object;
    FSharedObjects: TDictionary<string, TAVM2Object>;
    FReadSharedObject: TAVM2SharedReader;
    FWriteSharedObject: TAVM2SharedWriter;
    FReadResource: TAVM2ResourceReader;
    FMovieURL: string;
    FLocalConnections: TDictionary<string, TAVM2Object>;
    FConnectionMessages: TList<TAVM2ConnectionMessage>;
    FEventFunctions: array[TAVM2EventMethod] of TAVM2Object;
    FHostObjects: TObjectList<TAVM2Object>;
    FTimerClass, FTimerEventClass, FPointClass, FRectangleClass: TAVM2Object;
    FMatrixClass, FTransformClass, FVector3DClass: TAVM2Object;
    FTimers: TList<TAVM2TimedCall>;
    FTimerSerial: Integer;
    FMilliseconds: Int64;
    FNewHostObjects: Integer;
    FCollectionWork, FDeadHostObjects: TArray<TAVM2Object>;
    FDeadHostCount: Integer;
    FOnCollection: TAVM2CollectionObserver;
    FOnReclaim: TAVM2ReclaimObserver;
    FFrameEventTargets: array[TAVM2FrameEvent] of TList<TAVM2Object>;
    FDisplayObjects: TDictionary<TObject, TAVM2Object>;
    FWork, FDepth: Integer;
    FIndexedNames: array[0..511] of TAVM2IndexedNames;
    function FrameLabelProperty(Display: TObject; const Name: string): TAVM2Value;
    procedure InstallBitmapClasses;
    function NewFilter(const Data: TSWFFilter): TAVM2Object;
    function ReadFilter(Obj: TAVM2Object): TSWFFilter;
    function DisplayFilters(Obj: TAVM2Object): TAVM2Value;
    procedure WriteDisplayFilters(Obj: TAVM2Object; const Value: TAVM2Value);
    procedure InitBitmapData(Obj: TAVM2Object; const Args: TArray<TAVM2Value>);
    function BitmapCall(Method: TAVM2BitmapMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure UpdateBitmapDisplay(Receiver: TAVM2Object);
    procedure InstallMathClass;
    function MathCall(Method: TAVM2MathMethod; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallSystemClasses;
    function TransformURI(const Input: string; Decode, Component: Boolean): string;
    function LoaderBytes: TAVM2Value;
    function DateCall(Method: TAVM2DateMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallTextClasses(InteractiveObject: TAVM2Object);
    function TextCall(Method: TAVM2TextMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallStyleSheet(EventDispatcher: TAVM2Object);
    function StyleCall(Method: TAVM2StyleMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallSound(EventDispatcher: TAVM2Object);
    function SoundCall(Method: TAVM2SoundMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure DeliverSoundComplete;
    function ProxyMethod(Receiver: TAVM2Object; const Name: string): TAVM2Object;
    procedure InstallXMLClasses;
    function IsXML(Obj: TAVM2Object): Boolean; inline;
    procedure ParseXML(Obj: TAVM2Object; const Args: TArray<TAVM2Value>);
    function XMLValue(const Document: IXMLDocument; const Nodes: TArray<IXMLNode>; IsList: Boolean): TAVM2Value;
    function XMLProperty(Obj: TAVM2Object; const Key: string): TAVM2Value;
    function XMLCall(Method: TAVM2XMLMethod; Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallSharedObject(EventDispatcher: TAVM2Object);
    function EncodeSharedObject(Data: TAVM2Object): TBytes;
    function DecodeSharedObject(const Data: TBytes): TAVM2Object;
    function SharedObjectCall(Method: TAVM2SharedMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallLocalConnection(EventDispatcher: TAVM2Object);
    function ConnectionCall(Method: TAVM2ConnectionMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure DeliverConnectionMessages;
    procedure InstallURLClasses(EventDispatcher: TAVM2Object);
    function URLCall(Method: TAVM2URLMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure DecodeVariables(Receiver: TAVM2Object; const Text: string);
    procedure DeliverURLLoads;
    procedure UnloadContent(Loader, Info: TAVM2Object; Stop: Boolean);
    procedure DeliverTimelineLoad(const Load: TAVM2URLLoad; Info: TAVM2Object);
    procedure DispatchStreamError(Info: TAVM2Object);
    procedure InstallTimers(EventDispatcher, EventClass: TAVM2Object);
    procedure InstallPointClass;
    function PointCall(Method: TAVM2PointMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function PointArgument(const Value: TAVM2Value): TAVM2Object;
    function NewPoint(X, Y: Double): TAVM2Value;
    procedure InstallRectangleClass;
    function RectangleCall(Method: TAVM2RectangleMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function NewRectangle(const Rect: TAVM2Rectangle): TAVM2Value;
    function RectangleArgument(const Value: TAVM2Value; AllowNull: Boolean = False): TAVM2Object;
    function RectangleProperty(Obj: TAVM2Object; const Key: string; out Value: TAVM2Value): Boolean;
    function SetRectangleProperty(Obj: TAVM2Object; const Key: string; const Value: TAVM2Value): Boolean;
    procedure InstallMatrixClasses;
    function MatrixCall(Method: TAVM2MatrixMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function NewMatrix(const Matrix: TAVM2Matrix): TAVM2Value;
    procedure ApplyDisplayMatrix(Obj: TAVM2Object; const Matrix: TAVM2Matrix);
    function AddTimer(Owner, Callback: TAVM2Object; Delay: Double; Once: Boolean; const Args: TArray<TAVM2Value>): Integer;
    function FindTimer(Id: Integer): Integer;
    procedure RemoveTimer(Id: Integer);
    function TimerCall(Method: TAVM2TimerMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure SetTimerDelay(Receiver: TAVM2Object; Delay: Double);
    procedure InstallFunctionClass(ObjectClass: TAVM2Object);
    function ForwardFunction(Func: TAVM2Object; const Args: TArray<TAVM2Value>; UseArray: Boolean): TAVM2Value;
    procedure InstallArrayClass(ObjectClass: TAVM2Object);
    function ArrayLengthValue(const Value: TAVM2Value): Cardinal;
    procedure SetArrayLength(Data: TAVM2Array; LengthValue: Cardinal);
    procedure SetArrayElement(Data: TAVM2Array; Index: Cardinal; const Value: TAVM2Value);
    procedure RemoveArrayElement(Data: TAVM2Array; Index: Cardinal);
    procedure AppendArray(Data: TAVM2Array; const Args: array of TAVM2Value; First: Integer = 0);
    function ConcatArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure ShiftArrayKeys(Data: TAVM2Array; Delta: Int64);
    procedure ReverseArray(Data: TAVM2Array);
    function SliceArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SpliceArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SearchArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>; Backwards: Boolean): Integer;
    function ArrayCallback(Command: TAVM2ArrayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function ArrayCall(Command: TAVM2ArrayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SortCollection(Receiver: TAVM2Object; const Args: TArray<TAVM2Value>; ByFields: Boolean): TAVM2Value;
    procedure InstallByteArrayClasses(ObjectClass, ErrorClass: TAVM2Object);
    function GetByteArrayProperty(Data: TAVM2ByteArray; const Name: string; out Value: TAVM2Value): Boolean;
    function SetByteArrayProperty(Data: TAVM2ByteArray; const Name: string; const Value: TAVM2Value): Boolean;
    procedure ResizeByteArray(Data: TAVM2ByteArray; Size: Cardinal);
    procedure TransformByteArray(Data: TAVM2ByteArray; Command: TAVM2ByteMethod; const Args: TArray<TAVM2Value>);
    function ByteArrayCall(Command: TAVM2ByteMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallEventConstants;
    procedure RaiseScriptError(const ClassName: string; Code: Integer; const Detail: string);
    function ResolveType(Module: TAVM2Module; Index: Integer; out ClassObject: TAVM2Object; out QualifiedName: string; Depth: Integer = 0): TAVM2TypeKind;
    function ResolveTypeClass(Module: TAVM2Module; Index, Depth: Integer): TAVM2Object;
    procedure InstallVectorClass;
    procedure CheckTypeApplication(Base: TAVM2Object; Count: Integer);
    function ApplyType(Base: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Object;
    function VectorType(ElementType: TAVM2Object): TAVM2Object;
    procedure ResizeVector(Obj: TAVM2Object; NewLength: Cardinal);
    function VectorElement(Obj: TAVM2Object; const Value: TAVM2Value): TAVM2Value;
    procedure VectorRangeError(Obj: TAVM2Object; Index: Double);
    function VectorProperty(Obj: TAVM2Object; const Key: string; out Value: TAVM2Value): Boolean;
    procedure SetVectorIndex(Obj: TAVM2Object; Index: Cardinal; const Value: TAVM2Value);
    procedure SetVectorProperty(Obj: TAVM2Object; const Keys: TArray<string>; const Value: TAVM2Value);
    function InvokeVector(Method: TAVM2VectorMethod; Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function ConcatVector(Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SpliceVector(Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function VectorCallback(Method: TAVM2VectorMethod; Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function ConvertVector(AClass: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function ValueHasType(const Value: TAVM2Value; Kind: TAVM2TypeKind; ClassObject: TAVM2Object): Boolean;
    function ClassHasType(ValueClass, TargetClass: TAVM2Object; Depth: Integer = 0): Boolean;
    function CoerceValue(const Value: TAVM2Value; Kind: TAVM2TypeKind; ClassObject: TAVM2Object; const QualifiedName: string): TAVM2Value;
    function MatchesExceptionType(Module: TAVM2Module; Index: Integer; const Value: TAVM2Value): Boolean;
    procedure BindDispatcher(Instance: TAVM2Object);
    procedure CollectHostObjects;
    procedure ReclaimHostObjects(Count: Integer);
    procedure ReclaimHostSlice;
    function StageOf(Display: TAVM2Object): TAVM2Object;
    procedure InitEvent(Event: TAVM2Object; Kind: TAVM2EventKind; const Name: string; Bubbles, Cancelable: Boolean);
    function HostEventObject(EventClass: TAVM2Object; const Name: string; Bubbles, Cancelable: Boolean): TAVM2Object;
    function HasListener(Receiver: TAVM2Object; const Name: string; IncludeAncestors: Boolean): Boolean;
    function EventCall(Command: TAVM2EventMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function DispatchEventTo(Target, Event: TAVM2Object; BroadcastOnly: Boolean): Boolean;
    procedure DispatchAddedToStage(Instance: TAVM2Object; Depth: Integer = 0);
    procedure DispatchRemovedFromStage(Instance: TAVM2Object; Depth: Integer = 0);
    procedure DispatchRemoval(Instance: TAVM2Object; LeavingStage: Boolean);
    procedure BindDisplay(Instance: TAVM2Object; Kind: TAVM2DisplayKind; Document: Boolean; Existing: TObject = nil);
    procedure SyncDisplayChildren(Parent: TAVM2Object; Depth: Integer);
    procedure ConstructTimelineChildren(Parent: TAVM2Object);
    function LinkedClass(const Name: string): TAVM2Object;
    procedure RebuildTimelineBindings(Parent: TAVM2Object; ClearRemovedSlots: Boolean = True);
    function DisplayCall(Command: TAVM2DisplayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure SetProperty(Receiver: TAVM2Object; const Keys: TArray<string>; const Value: TAVM2Value; UseAccessor: Boolean = True);
    function SuperMember(Base, Receiver: TAVM2Object; const Names: TArray<string>; Kind: Integer): TAVM2Value;
    function QualifiedClassName(Obj: TAVM2Object): string;
    function NewObject(Kind: TAVM2ObjectKind; HostManaged: Boolean = False): TAVM2Object;
    function BindNativeMethod(Receiver, Method: TAVM2Object): TAVM2Value;
    function Key(Module: TAVM2Module; NamespaceIndex: Integer; const Name: string): string;
    function NamespaceSetKeys(Module: TAVM2Module; SetIndex: Integer; const Name: string): TArray<string>;
    function ProtectedMemberName(Receiver: TAVM2Object; const Name: string): string;
    function InterfacePublicName(Receiver: TAVM2Object; const Key: string): string;
    function HasProperty(Receiver: TAVM2Object; const Name: string): Boolean;
    function Names(Module: TAVM2Module; Index: Integer): TArray<string>;
    function TraitKey(Module: TAVM2Module; Index: Integer): string;
    function ConstantValue(Module: TAVM2Module; Index: Integer; Kind: Byte): TAVM2Value;
    procedure StoreSlot(Target: TAVM2Object; const Name: string; const Value: TAVM2Value);
    procedure StoreDynamicProperty(Obj: TAVM2Object; const Key: string; const Value: TAVM2Value; Enumerable: Boolean = True);
    procedure StoreDictionaryKey(Obj, Key: TAVM2Object; const Value: TAVM2Value);
    function DictionaryValue(Obj, Key: TAVM2Object): TAVM2Value;
    procedure InstallObjectMethods;
    function InvokeObjectMethod(Method: TAVM2ObjectMethod; const Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
    function DeleteProperty(Obj: TAVM2Object; const Names: TArray<string>): Boolean;
    function NextEnumerant(Obj: TAVM2Object; Previous: Cardinal): Cardinal;
    function EnumerantName(Obj: TAVM2Object; Index: Cardinal): TAVM2Value;
    function InitialSlotValue(Module: TAVM2Module; const Trait: TABCTrait): TAVM2Value;
    procedure ShareInstanceSlots(ClassObject, Instance: TAVM2Object);
    procedure AddTraits(Target: TAVM2Object; Module: TAVM2Module; const Traits: TArray<TABCTrait>; Activation: Boolean = False);
    procedure Initialize(Script: TAVM2Object);
    function Find(Module: TAVM2Module; Index: Integer; Script: TAVM2Object; const Scope, Outer: TArray<TAVM2Value>; ScopeCount: Integer; Op: Byte; out FoundValue: PAVM2Value): TAVM2Object;
    function PropertyValue(Receiver: TAVM2Object; const Names: TArray<string>): TAVM2Value;
    function NewClass(Module: TAVM2Module; Index: Integer; Base, Script: TAVM2Object; const Outer: TArray<TAVM2Value>): TAVM2Object;
    procedure ConstructInto(ClassObject, Instance: TAVM2Object; const Args: TArray<TAVM2Value>);
    procedure InitializeFunctionPrototype(Func: TAVM2Object);
    function ClassPrototype(AClass: TAVM2Object; Depth: Integer = 0): TAVM2Object;
    function ObjectPrototype(Obj: TAVM2Object): TAVM2Object; inline;
    function ValuePrototype(const Value: TAVM2Value): TAVM2Object;
    function IsInstanceOf(const Value: TAVM2Value; ConstructorObject: TAVM2Object): Boolean;
    function ConvertPrimitive(Kind: TAVM2TypeKind; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallPrimitiveMethods;
    function PrimitiveClass(const Value: TAVM2Value): TAVM2Object;
    function PrimitiveTrait(AClass: TAVM2Object; const Key: string): TAVM2PrimitiveMethod;
    function ReadProperty(const Receiver: TAVM2Value; const Names: TArray<string>; ForCall: Boolean): TAVM2Value;
    procedure RejectPrimitiveWrite(const Receiver: TAVM2Value; const Names: TArray<string>; Deleting: Boolean);
    function InvokePrimitive(Method: TAVM2PrimitiveMethod; Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallRegExpClass;
    procedure InitRegExp(Data: TAVM2RegExp; const Args: TArray<TAVM2Value>);
    function InvokeRegExp(Method: TAVM2RegExpMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function FindRegExp(Data: TAVM2RegExp; const Input: TAVM2RegExpInput; Start: Integer; out Match: TAVM2RegExpMatch): Boolean;
    function RegExpResult(Data: TAVM2RegExp; const Text: string; const Match: TAVM2RegExpMatch; IncludeNames: Boolean): TAVM2Object;
    function CoerceText(const Value: TAVM2Value): string;
    function CoerceNumber(const Value: TAVM2Value): Double;
    function CompareValues(const Left, Right: TAVM2Value): TAVM2Relation;
    function CoercePrimitive(const Value: TAVM2Value; PreferText: Boolean): TAVM2Value;
    function StringRegExp(Method: TAVM2PrimitiveMethod; const Text: string; const Args: TArray<TAVM2Value>): TAVM2Value;
    function Instantiate(AClass: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function Construct(ClassObject: TAVM2Object; const Args: TArray<TAVM2Value>; Existing: TObject = nil): TAVM2Object;
    procedure InstallInstanceTraits(ClassObject, Instance: TAVM2Object; Depth: Integer = 0);
    function Invoke(FunctionObject, Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value; overload;
    function Invoke(FunctionObject: TAVM2Object; Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value; overload;
    function InvokeClass(ClassObject: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function InvokeNative(FunctionObject: TAVM2Object; const Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
    function InvokeScript(FunctionObject: TAVM2Object; Receiver: TAVM2Value; const Args: array of TAVM2Value): TAVM2Value;
    function Execute(Module: TAVM2Module; MethodIndex: Integer; const Receiver: TAVM2Value; Script, OwnerClass: TAVM2Object; const Outer: TArray<TAVM2Value>; const Args: array of TAVM2Value; CurrentFunction: TAVM2Object = nil): TAVM2Value;
  public
    constructor Create(const Trace: TProc<string>; Display: TAVM2DisplayHost = nil; SWFVersion: Integer = 13);
    destructor Destroy; override;
    procedure BeginFrame(Milliseconds: Int64 = -1);
    procedure RunTimers(Milliseconds: Int64);
    procedure LoadABC(TagId: Integer; const Data: TBytes; Lazy: Boolean);
    procedure CreateDocument(const Name: string);
    procedure RunFrameScript(Handle: TObject; Frame: Integer);
    procedure SyncTimelineDisplay(Handle: TObject);
    procedure SetStageSize(Width, Height: Integer);
    property ReadResource: TAVM2ResourceReader read FReadResource write FReadResource;
    property ReadSharedObject: TAVM2SharedReader read FReadSharedObject write FReadSharedObject;
    property WriteSharedObject: TAVM2SharedWriter read FWriteSharedObject write FWriteSharedObject;
    procedure SetMovieInfo(const URL: string; SourceBytes, Width, Height: Integer; FrameRate: Double);
    procedure BroadcastFrameEvent(Phase: TAVM2FrameEvent);
    property MouseVisible: Boolean read FMouseVisible;
    // Observers run at the end of a collection on the VM's owning thread.
    property OnCollection: TAVM2CollectionObserver read FOnCollection write FOnCollection;
    property OnReclaim: TAVM2ReclaimObserver read FOnReclaim write FOnReclaim;
    procedure Keyboard(Code, CharCode: Integer; Pressed, Ctrl, Alt, Shift: Boolean);
    function DisplayObjectAt(Handle: TObject): TAVM2Object;
    procedure Mouse(Target: TAVM2Object; const Name: string; StageX, StageY, LocalX, LocalY: Double; ButtonDown, Ctrl, Alt, Shift: Boolean);
  end;

implementation

uses
  System.RTLConsts, System.Diagnostics, System.Classes, System.Character,
  System.Math, System.RegularExpressionsAPI, System.StrUtils, System.ZLib,
  System.NetEncoding, System.Variants, System.DateUtils, Xml.XMLDoc, Xml.xmldom,
  Xml.OmniXMLDom, AVM1.TextFormat, AVM1.Coercion, AVM1.Strings,
  AVM1.Trigonometry, Z7.Archive.Lzma;

type
  TByteCodecResult = (bcOK, bcInvalid, bcLimit);

  EAVM2Thrown = class(EAVM2Error)
  public
    Value: TAVM2Value;
    constructor Create(const AValue: TAVM2Value);
  end;

const
  WorkLimit = 40000000;
  DirectSlotLimit = 4096;
  FieldBindingCacheSize = 2048;
  SlotReadable = 1;
  SlotWritable = 2;
  SlotMethod = 4;
  NumericRegionOpcode = $FF; // Internal only. The ABC verifier rejects it.
  {$IFDEF AVM2_WIN64_JIT}
  NumericJitWarmups = 32;
  NumericJitBufferBytes = 4096;
  NumericJitCompilesPerFrame = 4;
  {$ENDIF}
  InstructionStart = 1;
  BranchDestination = 2;
  NeedsArguments = $01;
  NeedsActivation = $02;
  NeedsRest = $04;
  BuiltinTypeNames: array[atObject..atVoid] of string =
    ('Object', 'String', 'Boolean', 'Number', 'int', 'uint', 'Function', 'void');
  TextLimit = 1024 * 1024;
  ErrorTextDepthLimit = 8;
  FrameEventNames: array[TAVM2FrameEvent] of string = ('enterFrame', 'frameConstructed', 'exitFrame');
  ObjectLimit = 65536;
  TemporaryObjectLimit = 524288;
  HostReclaimQueueLimit = 16384;
  HostReclaimSliceSize = 2048;
  TraceMethod = -2;
  AddFrameScriptMethod = -3;
  ErrorToStringMethod = -4;
  FunctionCallMethod = -5;
  FunctionApplyMethod = -6;
  EmptyFunctionMethod = -7;
  IsNaNMethod = -8;
  DictionaryToJSONMethod = -9;
  Vector3DTextMethod = -11;
  MovieClipPlayMethod = -12;
  MovieClipStopMethod = -13;
  MovieClipGotoAndPlayMethod = -14;
  MovieClipGotoAndStopMethod = -15;
  TimerMethodBase = -416;
  PointMethodBase = -448;
  RectangleMethodBase = -480;
  MatrixMethodBase = -512;
  MouseShowMethod = -750;
  MouseHideMethod = -751;
  BitmapMethodBase = -736;
  MathMethodBase = -704;
  GlowFilterFields: array[0..7] of string = ('color', 'alpha', 'blurX', 'blurY', 'strength', 'quality', 'inner', 'knockout');
  ColorTransformFields: array[0..7] of string = ('redMultiplier', 'greenMultiplier', 'blueMultiplier',
    'alphaMultiplier', 'redOffset', 'greenOffset', 'blueOffset', 'alphaOffset');
  QualifiedNameMethodBase = -688;
  QualifiedClassNameMethod = -689;
  QualifiedSuperclassNameMethod = -690;
  ExternalCallMethod = -691;
  ParseIntMethod = -692;
  ParseFloatMethod = -693;
  IsFiniteMethod = -694;
  EncodeURIMethod = -695;
  EncodeURIComponentMethod = -696;
  DecodeURIMethod = -697;
  DecodeURIComponentMethod = -698;
  EscapeMethod = -699;
  UnescapeMethod = -700;
  DateMethodBase = -672;
  TextMethodBase = -656;
  StyleMethodBase = -640;
  SoundMethodBase = -624;
  XMLMethodBase = -608;
  SharedMethodBase = -592;
  SharedDataSignature = $314F5352; // RSO1
  SharedDataLimit = 1024 * 1024;
  SharedGraphLimit = 4096;
  SharedItemLimit = 32768;
  URLMethodBase = -576;
  URLMethods: array[TAVM2URLMethod] of string = ('load', 'close', 'decode', 'toString',
    'loadBytes', 'unload', 'unloadAndStop');
  ConnectionMethodBase = -560;
  ConnectionMethods: array[TAVM2ConnectionMethod] of string =
    ('connect', 'close', 'send', 'allowDomain', 'allowInsecureDomain');
  MatrixFields: array[0..5] of string = (#0 + 'a', #0 + 'b', #0 + 'c', #0 + 'd', #0 + 'tx', #0 + 'ty');
  Vector3DFields: array[0..3] of string = (#0 + 'x', #0 + 'y', #0 + 'z', #0 + 'w');
  MatrixNames: array[TAVM2MatrixMethod] of string = ('clone', 'concat', 'identity', 'invert',
    'rotate', 'scale', 'translate', 'transformPoint', 'deltaTransformPoint', 'createBox',
    'createGradientBox', 'copyFrom', 'setTo', 'copyRowFrom', 'copyRowTo', 'copyColumnFrom',
    'copyColumnTo', 'toString');
  RectangleFields: array[0..3] of string = (#0 + 'x', #0 + 'y', #0 + 'width', #0 + 'height');
  RectangleAccessors: array[0..6] of string = (#0 + 'left', #0 + 'top', #0 + 'right',
    #0 + 'bottom', #0 + 'topLeft', #0 + 'bottomRight', #0 + 'size');
  RectangleNames: array[TAVM2RectangleMethod] of string = ('clone', 'isEmpty', 'setEmpty',
    'inflate', 'inflatePoint', 'offset', 'offsetPoint', 'contains', 'containsPoint', 'containsRect',
    'intersection', 'intersects', 'union', 'equals', 'toString', 'copyFrom', 'setTo');
  PointNames: array[TAVM2PointMethod] of string = ('add', 'subtract', 'clone', 'copyFrom',
    'equals', 'normalize', 'offset', 'setTo', 'toString', 'distance', 'interpolate', 'polar');
  TimerNames: array[TAVM2TimerMethod] of string = ('start', 'stop', 'reset', 'getTimer',
    'setInterval', 'setTimeout', 'clearInterval', 'clearTimeout', 'clone', 'toString', 'updateAfterEvent');
  DefinitionByNameMethod = -237;
  SecurityLoadPolicyFileMethod = -240;
  PrimitiveMethodBase = -256;
  RegExpMethodBase = -320;
  ObjectMethodBase = -336;
  VectorMethodBase = -384;
  VectorNamespace = '__AS3__.vec' + #0;
  VectorMethodNames: array[TAVM2VectorMethod] of string = ('push', 'pop', 'shift',
    'unshift', 'join', 'toString', 'reverse', 'indexOf', 'lastIndexOf', 'slice', 'concat', 'splice',
    'every', 'some', 'forEach', 'map', 'filter', 'insertAt', 'removeAt', 'sort', 'toLocaleString');
  RegExpCaptureLimit = 512;
  RegExpPatternLimit = 16384;
  BuiltinNamespace = 'http://adobe.com/AS3/2006/builtin' + #0;
  PrimitiveMethodNames: array[pmCharAt..pmFromCharCode] of string =
    ('charAt', 'charCodeAt', 'concat', 'indexOf', 'lastIndexOf', 'slice', 'substr',
    'substring', 'split', 'match', 'search', 'replace', 'toLowerCase', 'toUpperCase', 'toString', 'valueOf',
    'toString', 'valueOf', 'toString', 'valueOf', 'toFixed', 'toExponential', 'toPrecision', 'fromCharCode');
  FunctionArgumentLimit = 4096;
  DisplayMethodBase = -16;
  EventMethodBase = -64;
  ByteArrayMethodBase = -96;
  ArrayMethodBase = -128;
  ArrayElementLimit = 262144;
  ArrayJoinLimit = 65536;
  ArrayTextDepthLimit = 32;
  SortCaseInsensitive = 1;
  SortDescending = 2;
  SortUnique = 4;
  SortReturnIndices = 8;
  SortNumeric = 16;
  ArrayMethods: array[TAVM2ArrayMethod] of string =
    ('push', 'pop', 'join', 'toString', 'shift', 'unshift', 'reverse', 'slice', 'splice', 'indexOf', 'lastIndexOf',
    'forEach', 'map', 'filter', 'every', 'some', 'sort', 'sortOn', 'concat');
  ByteArraySizeLimit = 16 * 1024 * 1024;
  ByteArrayTotalLimit = 64 * 1024 * 1024;
  ByteArrayMethods: array[TAVM2ByteMethod] of string =
    ('clear', 'readByte', 'readUnsignedByte', 'readBoolean', 'readShort',
    'readUnsignedShort', 'readInt', 'readUnsignedInt', 'readFloat', 'readDouble',
    'readUTF', 'readUTFBytes', 'writeByte', 'writeBoolean', 'writeShort', 'writeInt',
    'writeUnsignedInt', 'writeFloat', 'writeDouble', 'writeUTF', 'writeUTFBytes', 'toString', 'readBytes', 'writeBytes',
    'compress', 'uncompress', 'deflate', 'inflate');
  EventMethods: array[TAVM2EventMethod] of string =
    ('addEventListener', 'removeEventListener', 'hasEventListener', 'willTrigger', 'dispatchEvent',
    'stopPropagation', 'stopImmediatePropagation', 'preventDefault', 'isDefaultPrevented', 'toString');
  DisplayProperties: array[0..7] of string =
    ('x', 'y', 'scaleX', 'scaleY', 'rotation', 'alpha', 'visible', 'name');
  DisplayMethods: array[TAVM2DisplayMethod] of string =
    ('addChild', 'addChildAt', 'removeChild', 'removeChildAt', 'getChildAt', 'getChildIndex',
    'setChildIndex', 'contains', 'clear', 'beginFill', 'endFill', 'moveTo', 'lineTo',
    'curveTo', 'drawRect', 'drawCircle', 'drawEllipse', 'drawRoundRect', 'beginBitmapFill', 'lineStyle', 'localToGlobal', 'globalToLocal',
    'hitTestPoint', 'hitTestObject', 'getBounds', 'getRect', 'getChildByName');

class function TAVM2Value.Num(AValue: Double; AKind: TAVM2ValueKind): TAVM2Value;
begin
  Result := Default(TAVM2Value);
  Result.Kind := AKind;
  Result.Number := AValue;
end;

class function TAVM2Value.Str(const AValue: string): TAVM2Value;
begin
  Result := Default(TAVM2Value);
  Result.Kind := a2String;
  Result.Text := AValue;
end;

class function TAVM2Value.Ref(AValue: TAVM2Object): TAVM2Value;
begin
  Result := Default(TAVM2Value);
  if AValue = nil then
    Result.Kind := a2Null
  else
    Result.Kind := a2Object;
  Result.Obj := AValue;
end;

procedure CopyValue(const Source: TAVM2Value; var Dest: TAVM2Value); inline;
begin
  Dest.Kind := Source.Kind;
  Dest.Number := Source.Number;
  Dest.Obj := Source.Obj;
  if Pointer(Dest.Text) <> Pointer(Source.Text) then
    Dest.Text := Source.Text;
end;

constructor TAVM2Properties.Create;
begin
  inherited Create;
  FIndices := TDictionary<string, Integer>.Create;
end;

destructor TAVM2Properties.Destroy;
begin
  FIndices.Free;
  inherited;
end;

function TAVM2Properties.FindIndex(const Key: string; out Index: Integer): Boolean;
begin
  Result := ((FDeclaredIndices <> nil) and FDeclaredIndices.TryGetValue(Key, Index)) or
    FIndices.TryGetValue(Key, Index);
end;

function TAVM2Properties.RequireIndex(const Key: string): Integer;
begin
  if not FindIndex(Key, Result) then
    raise EListError.CreateRes(@SGenericItemNotFound);
end;

procedure TAVM2Properties.NoteReferenceChange(var Slot: TAVM2Value; Current: TAVM2Object);
var
  Previous: TAVM2Object;
  WasTracked, IsTracked: Boolean;
  Index: NativeUInt;
begin
  Previous := Slot.Obj;
  if Previous = Current then
    Exit;
  WasTracked := (Previous <> nil) and Previous.HostManaged;
  IsTracked := (Current <> nil) and Current.HostManaged;
  if WasTracked = IsTracked then
    Exit;
  Inc(FHostReferences, Ord(IsTracked) - Ord(WasTracked));
  Index := (NativeUInt(@Slot) - NativeUInt(@FEntries[0].Value)) div SizeOf(FEntries[0]);
  if Index < SizeOf(NativeUInt) * 8 then
    FHostReferenceSlots := FHostReferenceSlots xor (NativeUInt(1) shl Index);
end;

procedure TAVM2Properties.StoreValue(var Slot: TAVM2Value; const Value: TAVM2Value);
begin
  NoteReferenceChange(Slot, Value.Obj);
  CopyValue(Value, Slot);
end;

procedure TAVM2Properties.Add(const Key: string; const Value: TAVM2Value);
begin
  if (FDeclaredIndices <> nil) and FDeclaredIndices.ContainsKey(Key) then
    raise EListError.CreateRes(@SGenericDuplicateItem);
  if FCount = Length(FEntries) then
    SetLength(FEntries, Max(4, FCount * 2));
  FIndices.Add(Key, FCount);
  FEntries[FCount].Key := Key;
  if (Key <> '') and CharInSet(Key[Length(Key)], ['0'..'9']) then
    FMayHaveNumericNames := True;
  StoreValue(FEntries[FCount].Value, Value);
  Inc(FCount);
end;

procedure TAVM2Properties.AddOrSetValue(const Key: string; const Value: TAVM2Value);
var
  Index: Integer;
begin
  if FindIndex(Key, Index) then
    StoreValue(FEntries[Index].Value, Value)
  else
    Add(Key, Value);
end;

function TAVM2Properties.GetItem(const Key: string): TAVM2Value;
begin
  Result := FEntries[RequireIndex(Key)].Value;
end;

procedure TAVM2Properties.SetItem(const Key: string; const Value: TAVM2Value);
begin
  StoreValue(FEntries[RequireIndex(Key)].Value, Value);
end;

function TAVM2Properties.ContainsKey(const Key: string): Boolean;
var
  Index: Integer;
begin
  Result := FindIndex(Key, Index);
end;

function TAVM2Properties.TryGetValue(const Key: string; var Value: TAVM2Value): Boolean;
var
  Index: Integer;
begin
  Result := FindIndex(Key, Index);
  if Result then
    Value := FEntries[Index].Value
  else
    Value := Default(TAVM2Value);
end;

function TAVM2Properties.FindHinted(const Key: string; var Hint: Integer): PAVM2Value;
var
  Index: Integer;
begin
  Index := Hint;
  if (Index < FCount) and (FEntries[Index].Key = Key) then
    Exit(@FEntries[Index].Value);
  if not FindIndex(Key, Index) then
    Exit(nil);
  Hint := Index;
  Result := @FEntries[Index].Value;
end;

function TAVM2Properties.TrySetHinted(const Key: string; var Hint: Integer; const Value: TAVM2Value): Boolean;
var
  Slot: PAVM2Value;
begin
  Slot := FindHinted(Key, Hint);
  Result := Slot <> nil;
  if Result then
    StoreValue(Slot^, Value);
end;

procedure TAVM2Properties.Remove(const Key: string);
var
  Index: Integer;
begin
  if not FindIndex(Key, Index) then
    Exit;
  if Index < FDeclaredCount then
  begin
    // Only the generic property table can remove a declared cell.
    // Materialize its index before rearranging the entries.
    if FDeclaredIndices <> nil then
    begin
      for var Declared in FDeclaredIndices do
        FIndices.Add(Declared.Key, Declared.Value);
      FDeclaredIndices := nil;
    end;
    FDeclaredCount := 0;
  end;
  FIndices.Remove(Key);
  Dec(FCount);
  if Index <> FCount then
  begin
    NoteReferenceChange(FEntries[Index].Value, FEntries[FCount].Value.Obj);
    FEntries[Index] := FEntries[FCount];
    FIndices[FEntries[Index].Key] := Index;
  end;
  NoteReferenceChange(FEntries[FCount].Value, nil);
  FEntries[FCount] := Default(TPair<string, TAVM2Value>);
end;

procedure TAVM2Properties.Clear;
begin
  FIndices.Clear;
  FDeclaredIndices := nil;
  FEntries := nil;
  FCount := 0;
  FDeclaredCount := 0;
  FHostReferences := 0;
  FHostReferenceSlots := 0;
end;

destructor TAVM2SlotLayout.Destroy;
begin
  PropertyIndices.Free;
  Types.Free;
  Names.Free;
  inherited;
end;

constructor TAVM2Object.Create(AKind: TAVM2ObjectKind);
begin
  inherited Create;
  Kind := AKind;
  Index := -1;
  Props := TAVM2Properties.Create;
end;

destructor TAVM2Object.Destroy;
begin
  BoundNativeMethods.Free;
  TraitMethods.Free;
  if FilterData <> nil then
    Dispose(FilterData);
  VectorData.Free;
  DictionaryKeys.Free;
  DynamicIndices.Free;
  DynamicProperties.Free;
  RegExp.Free;
  DisplayChildren.Free;
  TimelineBindings.Free;
  FrameScripts.Free;
  Listeners.Free;
  ArrayData.Free;
  ByteArrayData.Free;
  Accessors.Free;
  InstanceSlots.Free;
  SlotTypes.Free;
  Slots.Free;
  Props.Free;
  inherited;
end;

destructor TAVM2RegExp.Destroy;
begin
  if Compiled <> nil then
    pcre_dispose(Compiled, nil, nil);
  {$IF Declared(UnloadPCRELib)}
  if LibraryLoaded then
    UnloadPCRELib;
  {$ENDIF}
  inherited;
end;

constructor TAVM2Module.Create(const Data: TBytes; AId: Integer);
begin
  inherited Create;
  Id := AId;
  ABC := TABCFile.Create(Data);
  SetLength(Scripts, Length(ABC.Scripts));
  SetLength(Classes, Length(ABC.Classes));
  SetLength(NamespaceObjects, Length(ABC.Namespaces));
  SetLength(Boundaries, Length(ABC.Bodies));
  {$IFNDEF AVM2_NO_NUMERIC_IR}
  SetLength(NumericMethods, Length(ABC.Bodies));
  {$ENDIF}
  SetLength(PropertyHints, Length(ABC.Multinames));
  SetLength(FieldBindings, Min(Length(ABC.Multinames), FieldBindingCacheSize));
  SetLength(StaticNames, Length(ABC.Multinames));
  SetLength(PublicIndexSets, Length(ABC.NamespaceSets));
end;

destructor TAVM2Module.Destroy;
begin
  {$IFDEF AVM2_WIN64_JIT}
  for var Method in NumericMethods do
    for var Region in Method.Regions do
      Region.NativeCode.Free;
  {$ENDIF}
  ABC.Free;
  inherited;
end;

function ByteArrayText(Data: TAVM2ByteArray): string;
var
  Start, Size: Integer;
  Encoding: TEncoding;
begin
  if Data.Size = 0 then
    Exit('');
  Start := 0;
  Size := Data.Size;
  Encoding := TEncoding.UTF8;
  if (Size >= 3) and (Data.Buffer[0] = $EF) and (Data.Buffer[1] = $BB) and (Data.Buffer[2] = $BF) then
    Start := 3
  else if Size >= 2 then
  begin
    if (Data.Buffer[0] = $FF) and (Data.Buffer[1] = $FE) then
      Encoding := TEncoding.Unicode
    else if (Data.Buffer[0] = $FE) and (Data.Buffer[1] = $FF) then
      Encoding := TEncoding.BigEndianUnicode;
    if Encoding <> TEncoding.UTF8 then
    begin
      Start := 2;
      Size := Size and not 1;
    end;
  end;
  if Size - Start > 4 * TextLimit then
    raise EAVM2Error.Create('AVM2 string size limit');
  Result := Encoding.GetString(Data.Buffer, Start, Size - Start);
  if Length(Result) > TextLimit then
    raise EAVM2Error.Create('AVM2 string size limit');
end;

constructor TAVM2Array.Create;
begin
  inherited Create;
  Elements := TDictionary<Cardinal, TAVM2Value>.Create;
end;

destructor TAVM2Array.Destroy;
begin
  Elements.Free;
  inherited;
end;

function AsText(const Value: TAVM2Value; Depth: Integer = 0): string; forward;

function TryArrayElement(Data: TAVM2Array; Index: Cardinal; out Value: TAVM2Value): Boolean;
begin
  while Data <> nil do
  begin
    if Data.Elements.TryGetValue(Index, Value) then
      Exit(True);
    Data := Data.Prototype;
  end;
  Value := Default(TAVM2Value);
  Result := False;
end;

function ArrayText(Data: TAVM2Array; const Separator: string; Depth: Integer; Runtime: TAVM2Runtime = nil): string;
var
  Builder: TStringBuilder;
  I: Integer;
  Element: TAVM2Value;
  Part: string;
begin
  if (Data.ArrayLength = 0) or Data.Joining then
    Exit('');
  if (Depth >= ArrayTextDepthLimit) or (Data.ArrayLength > ArrayJoinLimit) or
    (UInt64(Data.ArrayLength - 1) * UInt64(Length(Separator)) > TextLimit) then
    raise EAVM2Error.Create('AVM2 Array join limit');
  Builder := TStringBuilder.Create;
  Data.Joining := True;
  try
    for I := 0 to Integer(Data.ArrayLength) - 1 do
    begin
      if I > 0 then
      begin
        if Length(Separator) > TextLimit - Builder.Length then
          raise EAVM2Error.Create('AVM2 string size limit');
        Builder.Append(Separator);
      end;
      if TryArrayElement(Data, Cardinal(I), Element) and not (Element.Kind in [a2Null, a2Undefined]) then
      begin
        if Runtime <> nil then
          Part := Runtime.CoerceText(Element)
        else
          Part := AsText(Element, Depth + 1);
        if Length(Part) > TextLimit - Builder.Length then
          raise EAVM2Error.Create('AVM2 string size limit');
        Builder.Append(Part);
      end;
    end;
    Result := Builder.ToString;
  finally
    Data.Joining := False;
    Builder.Free;
  end;
end;

function VectorText(Obj: TAVM2Object; const Separator: string; Depth: Integer; Runtime: TAVM2Runtime; Localized: Boolean = False): string;
const
  LocaleMethod = #0 + 'toLocaleString';
var
  Builder: TStringBuilder;
  I, Count: Integer;
  Element, Method: TAVM2Value;
  Holder: TAVM2Object;
  Part: string;
begin
  Count := Obj.VectorData.Count;
  if (Count = 0) or Obj.VectorJoining then
    Exit('');
  if (Depth >= ArrayTextDepthLimit) or (Count > ArrayJoinLimit) or
    (UInt64(Count - 1) * UInt64(Length(Separator)) > TextLimit) then
    raise EAVM2Error.Create('AVM2 Vector join limit');
  Builder := TStringBuilder.Create;
  Obj.VectorJoining := True;
  try
    for I := 0 to Count - 1 do
    begin
      if I > 0 then
      begin
        if Length(Separator) > TextLimit - Builder.Length then
          raise EAVM2Error.Create('AVM2 string size limit');
        Builder.Append(Separator);
      end;
      if (Runtime <> nil) and (I >= Obj.VectorData.Count) then
        Runtime.VectorRangeError(Obj, I);
      Element := Obj.VectorData[I];
      if Localized and not (Element.Kind in [a2Null, a2Undefined]) then
      begin
        Holder := Element.Obj;
        if Holder = nil then
          Holder := Runtime.ValuePrototype(Element);
        if Runtime.HasProperty(Holder, LocaleMethod) then
        begin
          Method := Runtime.ReadProperty(Element, [LocaleMethod], True);
          Part := Runtime.CoerceText(Runtime.Invoke(Method.Obj, Element, nil));
        end
        else if Element.Kind = a2Boolean then
          Part := '[object Boolean]'
        else if Element.Kind = a2String then
          Part := '[object String]'
        else
          Part := AsText(Element, Depth + 1);
      end
      else if Localized then
        Part := AsText(Element)
      else if Element.Kind in [a2Null, a2Undefined] then
        Part := 'null'
      else if Runtime <> nil then
        Part := Runtime.CoerceText(Element)
      else
        Part := AsText(Element, Depth + 1);
      if Length(Part) > TextLimit - Builder.Length then
        raise EAVM2Error.Create('AVM2 string size limit');
      Builder.Append(Part);
    end;
    Result := Builder.ToString;
  finally
    Obj.VectorJoining := False;
    Builder.Free;
  end;
end;

function RegExpLiteral(Data: TAVM2RegExp): string;
begin
  Result := '/' + Data.Source + '/';
  if rfGlobal in Data.Flags then
    Result := Result + 'g';
  if rfIgnoreCase in Data.Flags then
    Result := Result + 'i';
  if rfMultiline in Data.Flags then
    Result := Result + 'm';
  if rfDotAll in Data.Flags then
    Result := Result + 's';
  if rfExtended in Data.Flags then
    Result := Result + 'x';
end;

function AsText(const Value: TAVM2Value; Depth: Integer): string;
var
  Field: TAVM2Value;
  MessageText: string;
  Separator: Integer;
begin
  case Value.Kind of
    a2Undefined:
      Result := 'undefined';
    a2Null:
      Result := 'null';
    a2Boolean:
      if Value.Number = 0 then
        Result := 'false'
      else
        Result := 'true';
    a2Int, a2UInt, a2Number:
      if IsNan(Value.Number) then
        Result := 'NaN'
      else if IsInfinite(Value.Number) then
      begin
        if Value.Number < 0 then
          Result := '-Infinity'
        else
          Result := 'Infinity';
      end
      else if Value.Number = 0 then
        Result := '0'
      else
        Result := AVMNumberToString(Value.Number);
    a2String:
      Result := Value.Text;
  else
    if Value.Obj.HasNamespaceURI then
      Result := Value.Obj.NamespaceURI
    else if Value.Obj.Kind = a2Function then
      Result := 'function Function() {}'
    else if Value.Obj.RegExp <> nil then
      Result := RegExpLiteral(Value.Obj.RegExp)
    else if Value.Obj.ArrayData <> nil then
      Result := ArrayText(Value.Obj.ArrayData, ',', Depth)
    else if Value.Obj.VectorData <> nil then
      Result := VectorText(Value.Obj, ',', Depth, nil)
    else if Value.Obj.Kind = a2Class then
    begin
      Separator := 0;
      if not Value.Obj.IsVectorType then
        Separator := LastDelimiter('.', Value.Obj.DisplayName);
      Result := '[class ' + Copy(Value.Obj.DisplayName, Separator + 1, MaxInt) + ']';
    end
    else if Value.Obj.ByteArrayData <> nil then
      Result := ByteArrayText(Value.Obj.ByteArrayData)
    else if (Value.Obj.Kind = a2PlainObject) and Value.Obj.NativeError and (Depth < ErrorTextDepthLimit) then
    begin
      Value.Obj.Props.TryGetValue(#0 + 'name', Field);
      Result := AsText(Field, Depth + 1);
      Value.Obj.Props.TryGetValue(#0 + 'message', Field);
      MessageText := AsText(Field, Depth + 1);
      if MessageText <> '' then
      begin
        if Length(MessageText) > TextLimit - Length(Result) - 2 then
          raise EAVM2Error.Create('AVM2 error string size limit');
        Result := Result + ': ' + MessageText;
      end;
    end
    else if Value.Obj.DisplayName <> '' then
      Result := '[object ' + Value.Obj.DisplayName + ']'
    else
      Result := '[object Object]';
  end;
end;

constructor EAVM2Thrown.Create(const AValue: TAVM2Value);
var
  Detail, ErrorMessage: string;
  Field: TAVM2Value;
begin
  Value := AValue;
  if (AValue.Kind = a2Object) and ((AValue.Obj.ArrayData <> nil) or (AValue.Obj.ByteArrayData <> nil)) then
    Detail := '[object ' + AValue.Obj.DisplayName + ']'
  else
    Detail := AsText(AValue, ErrorTextDepthLimit);
  if (AValue.Kind = a2Object) and (AValue.Obj.Kind = a2PlainObject) and AValue.Obj.NativeError then
  begin
    Detail := AValue.Obj.DisplayName;
    if AValue.Obj.Props.TryGetValue(#0 + 'name', Field) and (Field.Kind = a2String) then
      Detail := Field.Text;
    if AValue.Obj.Props.TryGetValue(#0 + 'message', Field) and (Field.Kind = a2String) and
      (Field.Text <> '') then
      ErrorMessage := ': ' + Copy(Field.Text, 1, 240);
  end;
  inherited Create('Uncaught AVM2 exception: ' + Copy(Detail, 1, 240) + ErrorMessage);
end;

function AsNumber(const Value: TAVM2Value): Double;
begin
  case Value.Kind of
    a2Null:
      Result := 0;
    a2Boolean, a2Int, a2UInt, a2Number:
      Result := Value.Number;
    a2String:
      if Trim(Value.Text) = '' then
        Result := 0
      else if not TryStrToFloat(Value.Text, Result, TFormatSettings.Invariant) then
        Result := NaN;
  else
    Result := NaN;
  end;
end;

function TAVM2Runtime.CompareValues(const Left, Right: TAVM2Value): TAVM2Relation;
var
  A, B: TAVM2Value;
  Order: Integer;
  L, R: Double;
begin
  A := Left;
  B := Right;
  if A.Kind = a2Object then
    A := CoercePrimitive(A, False);
  if B.Kind = a2Object then
    B := CoercePrimitive(B, False);
  if (A.Kind = a2String) and (B.Kind = a2String) then
  begin
    Order := CompareStr(A.Text, B.Text);
    if Order < 0 then
      Exit(arLess);
    if Order > 0 then
      Exit(arGreater);
    Exit(arEqual);
  end;
  L := AsNumber(A);
  R := AsNumber(B);
  if IsNan(L) or IsNan(R) then
    Exit(arUnordered);
  if L < R then
    Exit(arLess);
  if L > R then
    Exit(arGreater);
  Result := arEqual;
end;

function IntBits(Value: Double): Cardinal;
var
  Reduced: Double;
begin
  if IsNan(Value) or IsInfinite(Value) then
    Exit(0);
  if (Value >= Low(Integer)) and (Value <= High(Cardinal)) then
    Exit(Cardinal(Trunc(Value)));
  if Abs(Value) >= 1.0E30 then
    Exit(0);
  Reduced := FMod(Int(Value), 4294967296.0);
  if Reduced < 0 then
    Reduced := Reduced + 4294967296.0;
  Result := Cardinal(Trunc(Reduced));
end;

function Truth(const Value: TAVM2Value): Boolean;
begin
  case Value.Kind of
    a2Undefined, a2Null:
      Result := False;
    a2String:
      Result := Value.Text <> '';
    a2Object:
      Result := True;
  else
    Result := not IsNan(Value.Number) and (Value.Number <> 0);
  end;
end;

function Equal(const A, B: TAVM2Value; strict: Boolean): Boolean;
begin
  if A.Kind = B.Kind then
  begin
    case A.Kind of
      a2Undefined, a2Null:
        Exit(True);
      a2String:
        Exit(A.Text = B.Text);
      a2Object:
        Exit(A.Obj = B.Obj);
    end;
    Exit(not IsNan(A.Number) and not IsNan(B.Number) and (A.Number = B.Number));
  end;
  if (A.Kind in [a2Int, a2UInt, a2Number]) and (B.Kind in [a2Int, a2UInt, a2Number]) then
    Exit(not IsNan(A.Number) and not IsNan(B.Number) and (A.Number = B.Number));
  if strict then
    Exit(False);
  if (A.Kind in [a2Undefined, a2Null]) or (B.Kind in [a2Undefined, a2Null]) then
    Exit((A.Kind in [a2Undefined, a2Null]) and (B.Kind in [a2Undefined, a2Null]));
  if (A.Kind = a2Object) or (B.Kind = a2Object) then
    Exit(False);
  Result := AsNumber(A) = AsNumber(B);
end;

function TAVM2DisplayHost.TimelineLabels(Display: TObject): TArray<TAVM2FrameLabel>;
begin
  Result := nil;
end;

function TAVM2DisplayHost.EmbeddedBytes(const ClassName: string; out Data: TBytes): Boolean;
begin
  Data := nil;
  Result := False;
end;

function TAVM2DisplayHost.MovieBytes: TBytes;
begin
  Result := nil;
end;

function TAVM2DisplayHost.LoadTimeline(const Data: TBytes; out Info: TAVM2LoadedMovie): TObject;
begin
  Info := Default(TAVM2LoadedMovie);
  Result := nil;
end;

procedure TAVM2DisplayHost.StopTimeline(Display: TObject);
begin
end;

function TAVM2DisplayHost.SoundLength(const ClassName: string): Double;
begin
  Result := 0;
end;

function TAVM2DisplayHost.StartSound(const ClassName: string; Channel: TAVM2Object; Start: Double; Loops: Integer): Boolean;
begin
  Result := False;
end;

procedure TAVM2DisplayHost.StopSound(Channel: TAVM2Object);
begin
end;

function TAVM2DisplayHost.EmbeddedBitmap(const ClassName: string): IImagePixelBuffer;
begin
  Result := nil;
end;

procedure TAVM2DisplayHost.AttachBitmap(Display: TObject; const Buffer: IImagePixelBuffer; Smooth: Boolean);
begin
end;

procedure TAVM2DisplayHost.BeginBitmapFill(Display: TObject; const Buffer: IImagePixelBuffer; const Matrix: TAVM2Matrix; RepeatFill, Smoothing: Boolean);
begin
end;

procedure TAVM2DisplayHost.DrawBitmap(const Target: IImagePixelBuffer; Source: TAVM2Object; const Options: TAVM2BitmapDraw);
begin
end;

function TAVM2DisplayHost.GetColorTransform(Display: TObject): TSWFColorTransform;
begin
  Result := TSWFColorTransform.Identity;
end;

procedure TAVM2DisplayHost.SetColorTransform(Display: TObject; const Value: TSWFColorTransform);
begin
end;

function TAVM2DisplayHost.GetFilters(Display: TObject): TSWFFilters;
begin
  Result := nil;
end;

procedure TAVM2DisplayHost.SetFilters(Display: TObject; const Filters: TSWFFilters);
begin
end;

procedure TAVM2DisplayHost.SetMask(Display, Mask: TObject);
begin
end;

procedure TAVM2DisplayHost.InitializeText(Display: TObject);
begin
end;

function TAVM2DisplayHost.GetTextProperty(Display: TObject; const Name: string; out Value: TAVM2Value): Boolean;
begin
  Result := False;
end;

function TAVM2DisplayHost.SetTextProperty(Display: TObject; const Name: string; const Value: TAVM2Value): Boolean;
begin
  Result := False;
end;

procedure TAVM2DisplayHost.SetTextFormat(Display: TObject; Format: TAVM2Object; First, Last: Integer);
begin
end;

constructor TAVM2Runtime.Create(const Trace: TProc<string>; Display: TAVM2DisplayHost; SWFVersion: Integer);
var
  Base, Native, DisplayObject, ObjectClass, ErrorClass, TextEventClass: TAVM2Object;
  Name, QualifiedName: string;
  Separator: Integer;
  Command: TAVM2DisplayMethod;
  EventCommand: TAVM2EventMethod;
  Phase: TAVM2FrameEvent;
  PrimitiveKind: TAVM2TypeKind;

  function EventClass(const Name: string; Base: TAVM2Object; Kind: TAVM2EventKind): TAVM2Object;
  begin
    Result := NewObject(a2Class);
    Result.Parent := Base;
    Result.EventKind := Kind;
    Result.DisplayName := Name;
    FNative.Props.Add('flash.events' + #0 + Name, TAVM2Value.Ref(Result));
  end;

  procedure ConstantString(AClass: TAVM2Object; const Name, Value: string);
  begin
    AClass.Props.Add(#0 + Name, TAVM2Value.Str(Value));
  end;

begin
  inherited Create;
  FSWFVersion := SWFVersion;
  FRandomState := $12345678;
  FDisplay := Display;
  FTrace := Trace;
  FNumericIRBudget := 16 * 1024 * 1024;
  {$IFDEF AVM2_WIN64_JIT}
  FNumericJitEnabled := GetEnvironmentVariable('RETROMUL_AVM2_JIT') = '1';
  FNumericJitBudget := 8 * 1024 * 1024;
  {$ENDIF}
  FObjects := TObjectList<TAVM2Object>.Create;
  FModules := TObjectList<TAVM2Module>.Create;
  FDefinitions := TDictionary<string, TAVM2Object>.Create;
  FLoadedTags := TDictionary<Integer, Boolean>.Create;
  FHostObjects := TObjectList<TAVM2Object>.Create;
  FTimers := TList<TAVM2TimedCall>.Create;
  for Phase := Low(TAVM2FrameEvent) to High(TAVM2FrameEvent) do
    FFrameEventTargets[Phase] := TList<TAVM2Object>.Create;
  FDisplayObjects := TDictionary<TObject, TAVM2Object>.Create;
  FFunctionPrototype := NewObject(a2Function);
  FFunctionPrototype.Index := EmptyFunctionMethod;
  FAddFrameScript := NewObject(a2Function);
  FAddFrameScript.Index := AddFrameScriptMethod;
  FPlayMovieClip := NewObject(a2Function);
  FPlayMovieClip.Index := MovieClipPlayMethod;
  FStopMovieClip := NewObject(a2Function);
  FStopMovieClip.Index := MovieClipStopMethod;
  FGotoAndPlay := NewObject(a2Function);
  FGotoAndPlay.Index := MovieClipGotoAndPlayMethod;
  FGotoAndStop := NewObject(a2Function);
  FGotoAndStop.Index := MovieClipGotoAndStopMethod;
  FErrorToString := NewObject(a2Function);
  FErrorToString.Index := ErrorToStringMethod;
  FNative := NewObject(a2Script);
  Native := NewObject(a2Function);
  Native.Index := TraceMethod;
  FNative.Props.Add(#0 + 'trace', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := DefinitionByNameMethod;
  FNative.Props.Add('flash.utils' + #0 + 'getDefinitionByName', TAVM2Value.Ref(Native));
  FNative.Props.Add(#0 + 'undefined', Default(TAVM2Value));
  FNative.Props.Add(#0 + 'NaN', TAVM2Value.Num(NaN));
  FNative.Props.Add(#0 + 'Infinity', TAVM2Value.Num(Infinity));
  Base := nil;
  DisplayObject := nil;
  ObjectClass := nil;
  for Name in ['Object', 'flash.events.EventDispatcher', 'flash.display.DisplayObject', 'flash.display.InteractiveObject', 'flash.display.DisplayObjectContainer', 'flash.display.Sprite', 'flash.display.MovieClip', 'flash.display.Shape', 'flash.display.MorphShape'] do
  begin
    Native := NewObject(a2Class);
    Native.DisplayName := Name;
    Native.Parent := Base;
    Native.CanDispatch := (Name = 'flash.events.EventDispatcher') or
      ((Base <> nil) and Base.CanDispatch);
    if Name = 'Object' then
      ObjectClass := Native
    else if Name = 'flash.display.DisplayObject' then
      DisplayObject := Native
    else if Name = 'flash.display.DisplayObjectContainer' then
      Native.DisplayKind := adContainer
    else if Name = 'flash.display.Sprite' then
      Native.DisplayKind := adSprite
    else if Name = 'flash.display.MovieClip' then
      Native.DisplayKind := adMovieClip
    else if (Name = 'flash.display.Shape') or (Name = 'flash.display.MorphShape') then
    begin
      Native.DisplayKind := adShape;
      Native.Parent := DisplayObject;
    end;
    Base := Native;
    Separator := LastDelimiter('.', Name);
    if Separator = 0 then
      QualifiedName := #0 + Name
    else
      QualifiedName := Copy(Name, 1, Separator - 1) + #0 + Copy(Name, Separator + 1, MaxInt);
    FNative.Props.Add(QualifiedName, TAVM2Value.Ref(Native));
  end;
  Native := NewObject(a2Class);
  Native.DisplayName := 'flash.display.SimpleButton';
  Native.Parent := FNative.Props['flash.display' + #0 + 'InteractiveObject'].Obj;
  Native.CanDispatch := True;
  Native.DisplayKind := adButton;
  FNative.Props.Add('flash.display' + #0 + 'SimpleButton', TAVM2Value.Ref(Native));
  FFrameLabelClass := NewObject(a2Class);
  FFrameLabelClass.DisplayName := 'flash.display.FrameLabel';
  FFrameLabelClass.Parent := ObjectClass;
  FNative.Props.Add('flash.display' + #0 + 'FrameLabel', TAVM2Value.Ref(FFrameLabelClass));
  FEventDispatcherInterface := NewObject(a2Class);
  FEventDispatcherInterface.DisplayName := 'flash.events.IEventDispatcher';
  FNative.Props.Add('flash.events' + #0 + 'IEventDispatcher', TAVM2Value.Ref(FEventDispatcherInterface));
  ErrorClass := ObjectClass;
  FObjectClass := ObjectClass;
  FObjectPrototype := NewObject(a2PlainObject);
  FObjectPrototype.ClassObject := ObjectClass;
  FObjectPrototype.Props.Add(#0 + 'constructor', TAVM2Value.Ref(ObjectClass));
  ObjectClass.InstancePrototype := FObjectPrototype;
  FClassClass := NewObject(a2Class);
  FClassClass.Parent := ObjectClass;
  FClassClass.DisplayName := 'Class';
  FClassPrototype := ClassPrototype(FClassClass);
  FNative.Props.Add(#0 + 'Class', TAVM2Value.Ref(FClassClass));
  for PrimitiveKind := Low(FPrimitiveClasses) to High(FPrimitiveClasses) do
  begin
    Native := NewObject(a2Class);
    Native.Parent := ObjectClass;
    Native.PrimitiveKind := PrimitiveKind;
    Native.DisplayName := BuiltinTypeNames[PrimitiveKind];
    FPrimitiveClasses[PrimitiveKind] := Native;
    FNative.Props.Add(#0 + Native.DisplayName, TAVM2Value.Ref(Native));
  end;
  FFunctionPrototype.Parent := FObjectPrototype;
  for Name in ['Error', 'ArgumentError', 'EvalError', 'RangeError', 'ReferenceError', 'SecurityError', 'SyntaxError', 'TypeError', 'URIError', 'VerifyError'] do
  begin
    Native := NewObject(a2Class);
    Native.DisplayName := Name;
    Native.NativeError := True;
    Native.Parent := ErrorClass;
    if Name = 'Error' then
      ErrorClass := Native;
    FNative.Props.Add(#0 + Name, TAVM2Value.Ref(Native));
  end;
  InstallFunctionClass(ObjectClass);
  Native := NewObject(a2Function);
  Native.Index := IsNaNMethod;
  FNative.Props.Add(#0 + 'isNaN', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := IsFiniteMethod;
  FNative.Props.Add(#0 + 'isFinite', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := ParseIntMethod;
  FNative.Props.Add(#0 + 'parseInt', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := ParseFloatMethod;
  FNative.Props.Add(#0 + 'parseFloat', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := EncodeURIMethod;
  FNative.Props.Add(#0 + 'encodeURI', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := EncodeURIComponentMethod;
  FNative.Props.Add(#0 + 'encodeURIComponent', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := DecodeURIMethod;
  FNative.Props.Add(#0 + 'decodeURI', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := DecodeURIComponentMethod;
  FNative.Props.Add(#0 + 'decodeURIComponent', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := EscapeMethod;
  FNative.Props.Add(#0 + 'escape', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := UnescapeMethod;
  FNative.Props.Add(#0 + 'unescape', TAVM2Value.Ref(Native));
  InstallObjectMethods;
  InstallPrimitiveMethods;
  InstallRegExpClass;
  FProxyClass := NewObject(a2Class);
  FProxyClass.Parent := ObjectClass;
  FProxyClass.DisplayName := 'flash.utils.Proxy';
  FNative.Props.Add('flash.utils' + #0 + 'Proxy', TAVM2Value.Ref(FProxyClass));
  InstallXMLClasses;
  FQNameClass := NewObject(a2Class);
  FQNameClass.Parent := ObjectClass;
  FQNameClass.DisplayName := 'QName';
  FNative.Props.Add(#0 + 'QName', TAVM2Value.Ref(FQNameClass));
  Native := NewObject(a2Function);
  Native.Index := QualifiedNameMethodBase;
  ClassPrototype(FQNameClass).Props.Add(#0 + 'toString', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := QualifiedClassNameMethod;
  FNative.Props.Add('flash.utils' + #0 + 'getQualifiedClassName', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := QualifiedSuperclassNameMethod;
  FNative.Props.Add('flash.utils' + #0 + 'getQualifiedSuperclassName', TAVM2Value.Ref(Native));
  InstallArrayClass(ObjectClass);
  InstallVectorClass;
  InstallByteArrayClasses(ObjectClass, ErrorClass);
  FDictionaryClass := NewObject(a2Class);
  FDictionaryClass.Parent := ObjectClass;
  FDictionaryClass.DisplayName := 'Dictionary';
  FNative.Props.Add('flash.utils' + #0 + 'Dictionary', TAVM2Value.Ref(FDictionaryClass));
  Native := NewObject(a2Function);
  Native.Index := DictionaryToJSONMethod;
  StoreDynamicProperty(ClassPrototype(FDictionaryClass), #0 + 'toJSON', TAVM2Value.Ref(Native), False);
  FNamespaceClass := NewObject(a2Class);
  FNamespaceClass.Parent := ObjectClass;
  FNamespaceClass.DisplayName := 'Namespace';
  FNative.Props.Add(#0 + 'Namespace', TAVM2Value.Ref(FNamespaceClass));
  for Command := Low(TAVM2DisplayMethod) to High(TAVM2DisplayMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := DisplayMethodBase - Ord(Command);
    FDisplayFunctions[Command] := Native;
  end;
  for EventCommand := Low(TAVM2EventMethod) to High(TAVM2EventMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := EventMethodBase - Ord(EventCommand);
    FEventFunctions[EventCommand] := Native;
  end;
  FEnterFrameClass := EventClass('Event', ObjectClass, aeEvent);
  ConstantString(FEnterFrameClass, 'ENTER_FRAME', 'enterFrame');
  ConstantString(FEnterFrameClass, 'FRAME_CONSTRUCTED', 'frameConstructed');
  ConstantString(FEnterFrameClass, 'EXIT_FRAME', 'exitFrame');
  ConstantString(FEnterFrameClass, 'ADDED_TO_STAGE', 'addedToStage');
  ConstantString(FEnterFrameClass, 'ADDED', 'added');
  ConstantString(FEnterFrameClass, 'COMPLETE', 'complete');
  ConstantString(FEnterFrameClass, 'INIT', 'init');
  ConstantString(FEnterFrameClass, 'UNLOAD', 'unload');
  ConstantString(FEnterFrameClass, 'CHANGE', 'change');
  ConstantString(FEnterFrameClass, 'RESIZE', 'resize');
  ConstantString(FEnterFrameClass, 'MOUSE_LEAVE', 'mouseLeave');
  ConstantString(FEnterFrameClass, 'REMOVED_FROM_STAGE', 'removedFromStage');
  ConstantString(FEnterFrameClass, 'REMOVED', 'removed');
  FFocusClass := EventClass('FocusEvent', FEnterFrameClass, aeFocus);
  ConstantString(FFocusClass, 'FOCUS_IN', 'focusIn');
  ConstantString(FFocusClass, 'FOCUS_OUT', 'focusOut');
  ConstantString(FFocusClass, 'KEY_FOCUS_CHANGE', 'keyFocusChange');
  ConstantString(FFocusClass, 'MOUSE_FOCUS_CHANGE', 'mouseFocusChange');
  FKeyboardClass := EventClass('KeyboardEvent', FEnterFrameClass, aeKeyboard);
  ConstantString(FKeyboardClass, 'KEY_DOWN', 'keyDown');
  ConstantString(FKeyboardClass, 'KEY_UP', 'keyUp');
  FMouseClass := EventClass('MouseEvent', FEnterFrameClass, aeMouse);
  ConstantString(FMouseClass, 'MOUSE_MOVE', 'mouseMove');
  ConstantString(FMouseClass, 'MOUSE_DOWN', 'mouseDown');
  ConstantString(FMouseClass, 'MOUSE_UP', 'mouseUp');
  ConstantString(FMouseClass, 'CLICK', 'click');
  ConstantString(FMouseClass, 'DOUBLE_CLICK', 'doubleClick');
  ConstantString(FMouseClass, 'MOUSE_OVER', 'mouseOver');
  ConstantString(FMouseClass, 'MOUSE_OUT', 'mouseOut');
  ConstantString(FMouseClass, 'ROLL_OVER', 'rollOver');
  ConstantString(FMouseClass, 'ROLL_OUT', 'rollOut');
  ConstantString(FMouseClass, 'MOUSE_WHEEL', 'mouseWheel');
  Native := EventClass('ProgressEvent', FEnterFrameClass, aeProgress);
  ConstantString(Native, 'PROGRESS', 'progress');
  TextEventClass := EventClass('TextEvent', FEnterFrameClass, aeText);
  ConstantString(TextEventClass, 'LINK', 'link');
  ConstantString(TextEventClass, 'TEXT_INPUT', 'textInput');
  Native := EventClass('ErrorEvent', TextEventClass, aeError);
  ConstantString(Native, 'ERROR', 'error');
  FIOErrorEventClass := EventClass('IOErrorEvent', Native, aeError);
  ConstantString(FIOErrorEventClass, 'IO_ERROR', 'ioError');
  Native := EventClass('SecurityErrorEvent', Native, aeError);
  ConstantString(Native, 'SECURITY_ERROR', 'securityError');
  ConstantString(FEnterFrameClass, 'OPEN', 'open');
  FStatusEventClass := EventClass('StatusEvent', FEnterFrameClass, aeStatus);
  ConstantString(FStatusEventClass, 'STATUS', 'status');
  ConstantString(FEnterFrameClass, 'SOUND_COMPLETE', 'soundComplete');
  InstallSystemClasses;
  InstallBitmapClasses;
  InstallTextClasses(FNative.Props['flash.display' + #0 + 'InteractiveObject'].Obj);
  InstallStyleSheet(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  InstallSound(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  InstallLocalConnection(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  InstallURLClasses(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  InstallSharedObject(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  InstallEventConstants;
  FStage := NewObject(a2PlainObject);
  FStage.Parent := ClassPrototype(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  InstallTimers(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj, FEnterFrameClass);
  InstallPointClass;
  InstallMathClass;
  InstallRectangleClass;
  InstallMatrixClasses;
  FStage.Props.Add(#0 + 'transform', Default(TAVM2Value));
  FStage.Props.Add(#0 + 'localToGlobal', TAVM2Value.Ref(FDisplayFunctions[adLocalToGlobal]));
  FStage.Props.Add(#0 + 'globalToLocal', TAVM2Value.Ref(FDisplayFunctions[adGlobalToLocal]));
  FStage.DisplayName := 'Stage';
  FStage.DisplayKind := adContainer;
  Native := NewObject(a2Class);
  Native.DisplayName := 'flash.display.Stage';
  Native.Parent := FNative.Props['flash.display' + #0 + 'DisplayObjectContainer'].Obj;
  Native.DisplayKind := adContainer;
  Native.CanDispatch := True;
  FNative.Props.Add('flash.display' + #0 + 'Stage', TAVM2Value.Ref(Native));
  FStage.ClassObject := Native;
  FStage.Parent := ClassPrototype(Native);
  FStage.DisplayChildren := TList<TAVM2Object>.Create;
  FStage.Props.Add(#0 + 'numChildren', TAVM2Value.Num(0, a2Int));
  FStage.Props.Add(#0 + 'root', TAVM2Value.Ref(FStage));
  FStage.Props.Add(#0 + 'quality', TAVM2Value.Str('HIGH'));
  Native := NewObject(a2Class);
  Native.DisplayName := 'flash.display.StageQuality';
  Native.Parent := ObjectClass;
  for Name in ['LOW', 'MEDIUM', 'HIGH', 'BEST', '8X8', '8X8_LINEAR', '16X16', '16X16_LINEAR'] do
    Native.Props.Add(#0 + Name, TAVM2Value.Str(Name));
  FNative.Props.Add('flash.display' + #0 + 'StageQuality', TAVM2Value.Ref(Native));
  for Command := adAddChild to adContains do
    FStage.Props.Add(#0 + DisplayMethods[Command], TAVM2Value.Ref(FDisplayFunctions[Command]));
  FStage.Props.Add(#0 + 'getChildByName', TAVM2Value.Ref(FDisplayFunctions[adGetChildByName]));
  BindDispatcher(FStage);
  FStage.Props.Add(#0 + 'stage', TAVM2Value.Ref(FStage));
  Native := NewObject(a2Class);
  Native.DisplayName := 'flash.display.LoaderInfo';
  Native.Parent := FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj;
  Native.CanDispatch := True;
  FNative.Props.Add('flash.display' + #0 + 'LoaderInfo', TAVM2Value.Ref(Native));
  FLoaderClass := NewObject(a2Class);
  FLoaderClass.DisplayName := 'flash.display.Loader';
  FLoaderClass.Parent := FNative.Props['flash.display' + #0 + 'DisplayObjectContainer'].Obj;
  FLoaderClass.CanDispatch := True;
  FLoaderClass.DisplayKind := adContainer;
  FNative.Props.Add('flash.display' + #0 + 'Loader', TAVM2Value.Ref(FLoaderClass));
  ClassPrototype(FLoaderClass).Props.Add(#0 + 'load', ClassPrototype(FURLLoaderClass).Props[#0 + 'load']);
  ClassPrototype(FLoaderClass).Props.Add(#0 + 'close', ClassPrototype(FURLLoaderClass).Props[#0 + 'close']);
  for var LoaderMethod := auLoadBytes to auUnloadAndStop do
  begin
    var LoaderFunction := NewObject(a2Function);
    LoaderFunction.Index := URLMethodBase - Ord(LoaderMethod);
    ClassPrototype(FLoaderClass).Props.Add(#0 + URLMethods[LoaderMethod], TAVM2Value.Ref(LoaderFunction));
  end;
  FLoaderContextClass := NewObject(a2Class);
  FLoaderContextClass.DisplayName := 'flash.system.LoaderContext';
  FLoaderContextClass.Parent := FObjectClass;
  FNative.Props.Add('flash.system' + #0 + 'LoaderContext', TAVM2Value.Ref(FLoaderContextClass));

  FLoaderInfo := NewObject(a2PlainObject);
  FLoaderInfo.ClassObject := Native;
  FLoaderInfo.Parent := ClassPrototype(Native);
  FLoaderInfo.DisplayName := Native.DisplayName;
  BindDispatcher(FLoaderInfo);
  FStage.Props.Add(#0 + 'loaderInfo', TAVM2Value.Ref(FLoaderInfo));
  FLoaderInfo.Props.Add(#0 + 'loader', TAVM2Value.Ref(nil));
  FLoaderInfo.Props.Add(#0 + 'content', TAVM2Value.Ref(nil));
  FLoaderInfo.Props.Add(#0 + 'contentType', TAVM2Value.Str('application/x-shockwave-flash'));
  FLoaderInfo.Props.Add(#0 + 'actionScriptVersion', TAVM2Value.Num(3, a2UInt));
  FLoaderInfo.Props.Add(#0 + 'swfVersion', TAVM2Value.Num(FSWFVersion, a2UInt));
  SetMovieInfo('', 0, 0, 0, 0);
  Native := NewObject(a2Class);
  Native.DisplayName := 'flash.system.Security';
  Native.Parent := ObjectClass;
  FNative.Props.Add('flash.system' + #0 + 'Security', TAVM2Value.Ref(Native));
  Base := NewObject(a2Function);
  Base.Index := SecurityLoadPolicyFileMethod;
  Native.Props.Add(#0 + 'loadPolicyFile', TAVM2Value.Ref(Base));
end;

destructor TAVM2Runtime.Destroy;
var
  Phase: TAVM2FrameEvent;
begin
  if (FSoundChannels <> nil) and (FDisplay <> nil) then
    for var Channel in FSoundChannels do
      FDisplay.StopSound(Channel);
  FSoundChannels.Free;
  FSharedObjects.Free;
  FURLLoads.Free;
  FConnectionMessages.Free;
  FLocalConnections.Free;
  FTimers.Free;
  FDisplayObjects.Free;
  for Phase := Low(TAVM2FrameEvent) to High(TAVM2FrameEvent) do
    FFrameEventTargets[Phase].Free;
  ReclaimHostObjects(FDeadHostCount);
  FHostObjects.Free;
  FLoadedTags.Free;
  FDefinitions.Free;
  FObjects.Free;
  FModules.Free;
  FDisplay.Free;
  inherited;
end;

procedure TAVM2Runtime.BeginFrame(Milliseconds: Int64);
begin
  {$IFDEF AVM2_WIN64_JIT}
  FNumericCompiles := 0;
  {$ENDIF}
  FWork := WorkLimit;
  if Milliseconds >= 0 then
    FMilliseconds := Milliseconds;
  if FDepth = 0 then
  begin
    if FNewHostObjects >= Max(128, FHostObjects.Count div 4) then
      CollectHostObjects
    else if FDeadHostCount <> 0 then
      ReclaimHostSlice;
  end;
end;

procedure TAVM2Runtime.InstallPointClass;
var
  Method: TAVM2PointMethod;
  Native, Prototype: TAVM2Object;
begin
  FPointClass := NewObject(a2Class);
  FPointClass.Parent := FObjectClass;
  FPointClass.DisplayName := 'Point';
  FNative.Props.Add('flash.geom' + #0 + 'Point', TAVM2Value.Ref(FPointClass));
  Prototype := ClassPrototype(FPointClass);
  for Method := Low(TAVM2PointMethod) to High(TAVM2PointMethod) do
  begin
    if (FSWFVersion < 13) and (Method in [apCopyFrom, apSetTo]) then
      Continue;
    Native := NewObject(a2Function);
    Native.Index := PointMethodBase - Ord(Method);
    if Method >= apDistance then
      FPointClass.Props.Add(#0 + PointNames[Method], TAVM2Value.Ref(Native))
    else
      Prototype.Props.Add(#0 + PointNames[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.NewPoint(X, Y: Double): TAVM2Value;
begin
  Result := TAVM2Value.Ref(Construct(FPointClass, [TAVM2Value.Num(X), TAVM2Value.Num(Y)]));
end;

function TAVM2Runtime.PointArgument(const Value: TAVM2Value): TAVM2Object;
begin
  Result := CoerceValue(Value, atClass, FPointClass, 'flash.geom.Point').Obj;
  if Result = nil then
    RaiseScriptError('TypeError', 1009, 'Cannot access a property or method of a null object reference.');
end;

function TAVM2Runtime.PointCall(Method: TAVM2PointMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
const
  MinimumArgs: array[TAVM2PointMethod] of Integer = (1, 1, 0, 1, 1, 1, 2, 2, 0, 2, 3, 2);
var
  X, Y, OtherX, OtherY, Factor: Double;
  Other: TAVM2Object;
begin
  Result := Default(TAVM2Value);
  if Length(Args) < MinimumArgs[Method] then
    RaiseScriptError('ArgumentError', 1063, 'Missing argument for Point.' + PointNames[Method] + '.');
  if Method = apPolar then
  begin
    Factor := CoerceNumber(Args[0]);
    X := CoerceNumber(Args[1]);
    Exit(NewPoint(Factor * Cos(X), Factor * Sin(X)));
  end;
  OtherX := 0;
  OtherY := 0;
  if Method in [apDistance, apInterpolate] then
  begin
    Receiver := PointArgument(Args[0]);
    Other := PointArgument(Args[1]);
    OtherX := Other.Props[#0 + 'x'].Number;
    OtherY := Other.Props[#0 + 'y'].Number;
  end
  else if (Receiver = nil) or not Receiver.IsPoint then
    RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
  X := Receiver.Props[#0 + 'x'].Number;
  Y := Receiver.Props[#0 + 'y'].Number;
  if Method in [apAdd, apSubtract, apCopyFrom, apEquals] then
  begin
    Other := PointArgument(Args[0]);
    OtherX := Other.Props[#0 + 'x'].Number;
    OtherY := Other.Props[#0 + 'y'].Number;
  end;
  case Method of
    apAdd:
      Exit(NewPoint(X + OtherX, Y + OtherY));
    apSubtract:
      Exit(NewPoint(X - OtherX, Y - OtherY));
    apClone:
      Exit(NewPoint(X, Y));
    apEquals:
      Exit(TAVM2Value.Num(Ord((X = OtherX) and (Y = OtherY)), a2Boolean));
    apText:
      Exit(TAVM2Value.Str('(x=' + AsText(TAVM2Value.Num(X)) + ', y=' + AsText(TAVM2Value.Num(Y)) + ')'));
    apDistance:
      Exit(TAVM2Value.Num(Sqrt(Sqr(OtherX - X) + Sqr(OtherY - Y))));
    apInterpolate:
      begin
        Factor := CoerceNumber(Args[2]);
        Exit(NewPoint(OtherX - (OtherX - X) * Factor, OtherY - (OtherY - Y) * Factor));
      end;
    apCopyFrom:
      begin
        X := OtherX;
        Y := OtherY;
      end;
    apNormalize:
      begin
        Factor := CoerceNumber(Args[0]);
        X := Receiver.Props[#0 + 'x'].Number;
        Y := Receiver.Props[#0 + 'y'].Number;
        OtherX := Sqrt(Sqr(X) + Sqr(Y));
        if not (OtherX > 0) then
          Exit;
        Factor := Factor / OtherX;
        X := X * Factor;
        Y := Y * Factor;
      end;
    apOffset, apSetTo:
      begin
        OtherX := CoerceNumber(Args[0]);
        OtherY := CoerceNumber(Args[1]);
        X := OtherX;
        Y := OtherY;
        if Method = apOffset then
        begin
          X := X + Receiver.Props[#0 + 'x'].Number;
          Y := Y + Receiver.Props[#0 + 'y'].Number;
        end;
      end;
  end;
  Receiver.Props[#0 + 'x'] := TAVM2Value.Num(X);
  Receiver.Props[#0 + 'y'] := TAVM2Value.Num(Y);
end;

function TAVM2Rectangle.Right: Double;
begin
  Result := X + Width;
end;

function TAVM2Rectangle.Bottom: Double;
begin
  Result := Y + Height;
end;

function TAVM2Rectangle.IsEmpty: Boolean;
begin
  Result := (Width <= 0) or (Height <= 0);
end;

function ReadNativeRectangle(Obj: TAVM2Object): TAVM2Rectangle;
begin
  Result.X := Obj.Props[RectangleFields[0]].Number;
  Result.Y := Obj.Props[RectangleFields[1]].Number;
  Result.Width := Obj.Props[RectangleFields[2]].Number;
  Result.Height := Obj.Props[RectangleFields[3]].Number;
end;

procedure WriteNativeRectangle(Obj: TAVM2Object; const Rect: TAVM2Rectangle);
begin
  Obj.Props[RectangleFields[0]] := TAVM2Value.Num(Rect.X);
  Obj.Props[RectangleFields[1]] := TAVM2Value.Num(Rect.Y);
  Obj.Props[RectangleFields[2]] := TAVM2Value.Num(Rect.Width);
  Obj.Props[RectangleFields[3]] := TAVM2Value.Num(Rect.Height);
end;

procedure TAVM2Runtime.InstallRectangleClass;
var
  Prototype, Native: TAVM2Object;
  Method: TAVM2RectangleMethod;
begin
  FRectangleClass := NewObject(a2Class);
  FRectangleClass.Parent := FObjectClass;
  FRectangleClass.DisplayName := 'Rectangle';
  FNative.Props.Add('flash.geom' + #0 + 'Rectangle', TAVM2Value.Ref(FRectangleClass));
  Prototype := ClassPrototype(FRectangleClass);
  for Method := Low(TAVM2RectangleMethod) to High(TAVM2RectangleMethod) do
  begin
    if (FSWFVersion < 13) and (Method in [arCopyFrom, arSetTo]) then
      Continue;
    Native := NewObject(a2Function);
    Native.Index := RectangleMethodBase - Ord(Method);
    Prototype.Props.Add(#0 + RectangleNames[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.NewRectangle(const Rect: TAVM2Rectangle): TAVM2Value;
var
  Obj: TAVM2Object;
begin
  Obj := Construct(FRectangleClass, nil);
  WriteNativeRectangle(Obj, Rect);
  Result := TAVM2Value.Ref(Obj);
end;

function TAVM2Runtime.RectangleArgument(const Value: TAVM2Value; AllowNull: Boolean): TAVM2Object;
begin
  Result := CoerceValue(Value, atClass, FRectangleClass, 'flash.geom.Rectangle').Obj;
  if (Result = nil) and not AllowNull then
    RaiseScriptError('TypeError', 1009, 'Cannot access a property or method of a null object reference.');
end;

function TAVM2Runtime.RectangleProperty(Obj: TAVM2Object; const Key: string; out Value: TAVM2Value): Boolean;
var
  Which: Integer;
  Rect: TAVM2Rectangle;
begin
  Which := IndexStr(Key, RectangleAccessors);
  if Which < 0 then
    Exit(False);
  Rect := ReadNativeRectangle(Obj);
  case Which of
    0:
      Value := TAVM2Value.Num(Rect.X);
    1:
      Value := TAVM2Value.Num(Rect.Y);
    2:
      Value := TAVM2Value.Num(Rect.Right);
    3:
      Value := TAVM2Value.Num(Rect.Bottom);
    4:
      Value := NewPoint(Rect.X, Rect.Y);
    5:
      Value := NewPoint(Rect.Right, Rect.Bottom);
    6:
      Value := NewPoint(Rect.Width, Rect.Height);
  end;
  Result := True;
end;

function TAVM2Runtime.SetRectangleProperty(Obj: TAVM2Object; const Key: string; const Value: TAVM2Value): Boolean;
var
  Which: Integer;
  Rect: TAVM2Rectangle;
  Point: TAVM2Object;
  X, Y: Double;
begin
  Which := IndexStr(Key, RectangleAccessors);
  if Which < 0 then
  begin
    Result := IndexStr(Key, RectangleFields) >= 0;
    if Result then
      Obj.Props[Key] := TAVM2Value.Num(CoerceNumber(Value));
    Exit;
  end;
  if Which >= 4 then
  begin
    Point := PointArgument(Value);
    X := Point.Props[#0 + 'x'].Number;
    Y := Point.Props[#0 + 'y'].Number;
  end
  else
  begin
    X := CoerceNumber(Value);
    Y := X;
  end;
  Rect := ReadNativeRectangle(Obj);
  case Which of
    0, 1, 4:
      begin
        if Which in [0, 4] then
        begin
          Rect.Width := Rect.Width + (Rect.X - X);
          Rect.X := X;
        end;
        if Which in [1, 4] then
        begin
          Rect.Height := Rect.Height + (Rect.Y - Y);
          Rect.Y := Y;
        end;
      end;
    2:
      Rect.Width := X - Rect.X;
    3:
      Rect.Height := Y - Rect.Y;
    5:
      begin
        Rect.Width := X - Rect.X;
        Rect.Height := Y - Rect.Y;
      end;
    6:
      begin
        Rect.Width := X;
        Rect.Height := Y;
      end;
  end;
  WriteNativeRectangle(Obj, Rect);
  Result := True;
end;

function TAVM2Runtime.RectangleCall(Method: TAVM2RectangleMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
const
  Required: array[TAVM2RectangleMethod] of Integer = (0, 0, 0, 2, 1, 2, 1, 2, 1, 1, 1, 1, 1, 1, 0, 1, 4);
var
  Rect, Other, Combined: TAVM2Rectangle;
  Point: TAVM2Object;
  X, Y: Double;
  Empty: Boolean;

  function Extremum(A, B: Double; TakeMaximum: Boolean): Double;
  begin
    if IsNan(A) or IsNan(B) then
      Exit(NaN);
    if TakeMaximum then
      Result := Max(A, B)
    else
      Result := Min(A, B);
  end;

  function Text(Value: Double): string;
  begin
    Result := AsText(TAVM2Value.Num(Value));
  end;

begin
  Result := Default(TAVM2Value);
  if (Receiver = nil) or not Receiver.IsRectangle then
    RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
  if Length(Args) < Required[Method] then
    RaiseScriptError('ArgumentError', 1063, 'Missing argument for Rectangle.' + RectangleNames[Method] + '.');
  X := 0;
  Y := 0;
  Other := Default(TAVM2Rectangle);
  case Method of
    arInflate, arOffset, arContains, arSetTo:
      begin
        X := CoerceNumber(Args[0]);
        Y := CoerceNumber(Args[1]);
      end;
    arInflatePoint, arOffsetPoint, arContainsPoint:
      begin
        Point := PointArgument(Args[0]);
        X := Point.Props[#0 + 'x'].Number;
        Y := Point.Props[#0 + 'y'].Number;
      end;
    arContainsRect..arEquals, arCopyFrom:
      Other := ReadNativeRectangle(RectangleArgument(Args[0]));
  end;
  Rect := ReadNativeRectangle(Receiver);
  case Method of
    arClone:
      Exit(NewRectangle(Rect));
    arIsEmpty:
      Exit(TAVM2Value.Num(Ord(Rect.IsEmpty), a2Boolean));
    arSetEmpty:
      Rect := Default(TAVM2Rectangle);
    arInflate, arInflatePoint:
      begin
        Rect.X := Rect.X - X;
        Rect.Y := Rect.Y - Y;
        Rect.Width := Rect.Width + 2 * X;
        Rect.Height := Rect.Height + 2 * Y;
      end;
    arOffset, arOffsetPoint:
      begin
        Rect.X := Rect.X + X;
        Rect.Y := Rect.Y + Y;
      end;
    arContains, arContainsPoint:
      Exit(TAVM2Value.Num(Ord((X >= Rect.X) and (X < Rect.Right) and
            (Y >= Rect.Y) and (Y < Rect.Bottom)), a2Boolean));
    arContainsRect:
      Exit(TAVM2Value.Num(Ord((Other.X >= Rect.X) and (Other.X < Rect.Right) and
            (Other.Y >= Rect.Y) and (Other.Y < Rect.Bottom) and (Other.Right > Rect.X) and
            (Other.Right <= Rect.Right) and (Other.Bottom > Rect.Y) and (Other.Bottom <= Rect.Bottom)), a2Boolean));
    arIntersection, arIntersects:
      begin
        Empty := Rect.IsEmpty or Other.IsEmpty;
        Combined := Default(TAVM2Rectangle);
        if not Empty then
        begin
          Combined.X := Extremum(Rect.X, Other.X, True);
          Combined.Y := Extremum(Rect.Y, Other.Y, True);
          Combined.Width := Extremum(Rect.Right, Other.Right, False) - Combined.X;
          Combined.Height := Extremum(Rect.Bottom, Other.Bottom, False) - Combined.Y;
          Empty := Combined.IsEmpty;
        end;
        if Method = arIntersects then
          Exit(TAVM2Value.Num(Ord(not Empty), a2Boolean));
        if Empty then
          Combined := Default(TAVM2Rectangle);
        Exit(NewRectangle(Combined));
      end;
    arUnion:
      begin
        if Rect.IsEmpty then
          Exit(NewRectangle(Other));
        if Other.IsEmpty then
          Exit(NewRectangle(Rect));
        Combined.X := Extremum(Rect.X, Other.X, False);
        Combined.Y := Extremum(Rect.Y, Other.Y, False);
        Combined.Width := Extremum(Rect.Right, Other.Right, True) - Combined.X;
        Combined.Height := Extremum(Rect.Bottom, Other.Bottom, True) - Combined.Y;
        Exit(NewRectangle(Combined));
      end;
    arEquals:
      Exit(TAVM2Value.Num(Ord((Rect.X = Other.X) and (Rect.Y = Other.Y) and
            (Rect.Width = Other.Width) and (Rect.Height = Other.Height)), a2Boolean));
    arText:
      Exit(TAVM2Value.Str('(x=' + Text(Rect.X) + ', y=' + Text(Rect.Y) + ', w=' +
          Text(Rect.Width) + ', h=' + Text(Rect.Height) + ')'));
    arCopyFrom:
      Rect := Other;
    arSetTo:
      begin
        Rect.X := X;
        Rect.Y := Y;
        Rect.Width := CoerceNumber(Args[2]);
        Rect.Height := CoerceNumber(Args[3]);
      end;
  end;
  WriteNativeRectangle(Receiver, Rect);
end;

function IdentityMatrix: TAVM2Matrix;
begin
  Result := Default(TAVM2Matrix);
  Result.A := 1;
  Result.D := 1;
end;

function ReadNativeMatrix(Obj: TAVM2Object): TAVM2Matrix;
var
  I: Integer;
begin
  for I := Low(MatrixFields) to High(MatrixFields) do
    Result.Values[I] := Obj.Props[MatrixFields[I]].Number;
end;

procedure WriteNativeMatrix(Obj: TAVM2Object; const Matrix: TAVM2Matrix);
var
  I: Integer;
begin
  for I := Low(MatrixFields) to High(MatrixFields) do
    Obj.Props.AddOrSetValue(MatrixFields[I], TAVM2Value.Num(Matrix.Values[I]));
end;

procedure TAVM2Runtime.InstallMatrixClasses;
var
  Prototype, Native: TAVM2Object;
  Method: TAVM2MatrixMethod;

  function GeometryClass(const Name: string): TAVM2Object;
  begin
    Result := NewObject(a2Class);
    Result.Parent := FObjectClass;
    Result.DisplayName := Name;
    FNative.Props.Add('flash.geom' + #0 + Name, TAVM2Value.Ref(Result));
  end;

begin
  FMatrixClass := GeometryClass('Matrix');
  FTransformClass := GeometryClass('Transform');
  FVector3DClass := GeometryClass('Vector3D');
  Native := NewObject(a2Function);
  Native.Index := Vector3DTextMethod;
  ClassPrototype(FVector3DClass).Props.Add(#0 + 'toString', TAVM2Value.Ref(Native));
  Prototype := ClassPrototype(FMatrixClass);
  for Method := Low(TAVM2MatrixMethod) to High(TAVM2MatrixMethod) do
  begin
    if (FSWFVersion < 13) and (Method in [amCopyFrom..amCopyColumnTo]) then
      Continue;
    Native := NewObject(a2Function);
    Native.Index := MatrixMethodBase - Ord(Method);
    Prototype.Props.Add(#0 + MatrixNames[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.NewMatrix(const Matrix: TAVM2Matrix): TAVM2Value;
var
  Obj: TAVM2Object;
begin
  Obj := Construct(FMatrixClass, nil);
  WriteNativeMatrix(Obj, Matrix);
  Result := TAVM2Value.Ref(Obj);
end;

procedure TAVM2Runtime.ApplyDisplayMatrix(Obj: TAVM2Object; const Matrix: TAVM2Matrix);
var
  X, Y, ScaleX, ScaleY, Rotation: Double;
begin
  if (FDisplay = nil) or (Obj.DisplayData = nil) then
    Exit;
  FDisplay.SetMatrix(Obj.DisplayData, Matrix, X, Y, ScaleX, ScaleY, Rotation);
  Obj.Props[#0 + 'x'] := TAVM2Value.Num(X);
  Obj.Props[#0 + 'y'] := TAVM2Value.Num(Y);
  Obj.Props[#0 + 'scaleX'] := TAVM2Value.Num(ScaleX);
  Obj.Props[#0 + 'scaleY'] := TAVM2Value.Num(ScaleY);
  Obj.Props[#0 + 'rotation'] := TAVM2Value.Num(Rotation);
end;

function TAVM2Runtime.MatrixCall(Method: TAVM2MatrixMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
const
  Required: array[TAVM2MatrixMethod] of Integer = (0, 1, 0, 0, 1, 2, 2, 1, 1, 2, 2, 1, 6, 2, 2, 2, 2, 0);
var
  Current, Other, Output: TAVM2Matrix;
  Vector: TAVM2Object;
  X, Y, Z, Det, Angle, SinAngle, CosAngle: Double;
  I: Integer;
  Index: Cardinal;

  function NumberArgument(Argument: Integer; DefaultValue: Double = 0): Double;
  begin
    Result := DefaultValue;
    if Argument < Length(Args) then
      Result := CoerceNumber(Args[Argument]);
  end;

  function ObjectArgument(Argument: Integer; ValueClass: TAVM2Object): TAVM2Object;
  begin
    Result := CoerceValue(Args[Argument], atClass, ValueClass, 'flash.geom.' + ValueClass.DisplayName).Obj;
    if Result = nil then
      RaiseScriptError('TypeError', 1009, 'Cannot access a property or method of a null object reference.');
  end;

  function Product(const First, ThenBy: TAVM2Matrix): TAVM2Matrix;
  begin
    Result.A := ThenBy.A * First.A + ThenBy.C * First.B;
    Result.B := ThenBy.B * First.A + ThenBy.D * First.B;
    Result.C := ThenBy.A * First.C + ThenBy.C * First.D;
    Result.D := ThenBy.B * First.C + ThenBy.D * First.D;
    Result.TX := ThenBy.A * First.TX + ThenBy.C * First.TY + ThenBy.TX;
    Result.TY := ThenBy.B * First.TX + ThenBy.D * First.TY + ThenBy.TY;
  end;

  procedure StoreVector(AX, AY, AZ: Double);
  begin
    Vector.Props[Vector3DFields[0]] := TAVM2Value.Num(AX);
    Vector.Props[Vector3DFields[1]] := TAVM2Value.Num(AY);
    Vector.Props[Vector3DFields[2]] := TAVM2Value.Num(AZ);
  end;

begin
  Result := Default(TAVM2Value);
  if (Receiver = nil) or not Receiver.IsMatrix then
    RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
  if Length(Args) < Required[Method] then
    RaiseScriptError('ArgumentError', 1063, 'Missing argument for Matrix.' + MatrixNames[Method] + '.');
  Current := ReadNativeMatrix(Receiver);
  Output := Current;
  case Method of
    amClone:
      Exit(NewMatrix(Current));
    amIdentity:
      Output := IdentityMatrix;
    amConcat:
      Output := Product(Current, ReadNativeMatrix(ObjectArgument(0, FMatrixClass)));
    amCopyFrom:
      Output := ReadNativeMatrix(ObjectArgument(0, FMatrixClass));
    amInvert:
      begin
        Det := Current.A * Current.D - Current.C * Current.B;
        Output.A := Current.D / Det;
        Output.B := Current.B /  - Det;
        Output.C := Current.C /  - Det;
        Output.D := Current.A / Det;
        Output.TX := (Current.D * Current.TX - Current.C * Current.TY) /  - Det;
        Output.TY := (Current.B * Current.TX - Current.A * Current.TY) / Det;
      end;
    amRotate:
      begin
        Angle := NumberArgument(0);
        Other := Default(TAVM2Matrix);
        Other.A := AVMTrig(1, Angle);
        Other.B := AVMTrig(0, Angle);
        Other.C := -Other.B;
        Other.D := Other.A;
        Output := Product(ReadNativeMatrix(Receiver), Other);
      end;
    amScale, amTranslate:
      begin
        X := NumberArgument(0);
        Y := NumberArgument(1);
        Output := ReadNativeMatrix(Receiver);
        if Method = amScale then
        begin
          Output.A := Output.A * X;
          Output.B := Output.B * Y;
          Output.C := Output.C * X;
          Output.D := Output.D * Y;
          Output.TX := Output.TX * X;
          Output.TY := Output.TY * Y;
        end
        else
        begin
          Output.TX := Output.TX + X;
          Output.TY := Output.TY + Y;
        end;
      end;
    amTransformPoint, amDeltaTransformPoint:
      begin
        Vector := PointArgument(Args[0]);
        X := Vector.Props[#0 + 'x'].Number;
        Y := Vector.Props[#0 + 'y'].Number;
        if Method = amDeltaTransformPoint then
          Exit(NewPoint(Current.A * X + Current.C * Y, Current.B * X + Current.D * Y));
        Exit(NewPoint(Current.A * X + Current.C * Y + Current.TX,
            Current.B * X + Current.D * Y + Current.TY));
      end;
    amCreateBox, amCreateGradientBox:
      begin
        X := NumberArgument(0);
        Y := NumberArgument(1);
        Angle := NumberArgument(2);
        Output.TX := NumberArgument(3);
        Output.TY := NumberArgument(4);
        if Method = amCreateGradientBox then
        begin
          Output.TX := Output.TX + X / 2;
          Output.TY := Output.TY + Y / 2;
          X := X / 1638.4;
          Y := Y / 1638.4;
        end;
        SinAngle := AVMTrig(0, Angle);
        CosAngle := AVMTrig(1, Angle);
        Output.A := CosAngle * X;
        Output.B := SinAngle * Y;
        Output.C := -SinAngle * X;
        Output.D := CosAngle * Y;
      end;
    amSetTo:
      for I := Low(MatrixFields) to High(MatrixFields) do
        Output.Values[I] := NumberArgument(I);
    amCopyRowFrom..amCopyColumnTo:
      begin
        Index := IntBits(NumberArgument(0));
        Vector := ObjectArgument(1, FVector3DClass);
        case Method of
          amCopyRowFrom, amCopyColumnFrom:
            begin
              if Index > 1 then
                Exit;
              Output := ReadNativeMatrix(Receiver);
              X := Vector.Props[Vector3DFields[0]].Number;
              Y := Vector.Props[Vector3DFields[1]].Number;
              Z := Vector.Props[Vector3DFields[2]].Number;
              Output.Values[Index] := X;
              Output.Values[Index + 2] := Y;
              Output.Values[Index + 4] := Z;
            end;
          amCopyRowTo:
            begin
              if Index = 2 then
                StoreVector(0, 0, 1)
              else if Index < 2 then
                StoreVector(Current.Values[Index], Current.Values[Index + 2], Current.Values[Index + 4]);
              Exit;
            end;
          amCopyColumnTo:
            begin
              if Index < 3 then
                StoreVector(Current.Values[2 * Index], Current.Values[2 * Index + 1], Ord(Index = 2));
              Exit;
            end;
        end;
      end;
    amText:
      Exit(TAVM2Value.Str('(a=' + AsText(TAVM2Value.Num(Current.A)) +
          ', b=' + AsText(TAVM2Value.Num(Current.B)) + ', c=' + AsText(TAVM2Value.Num(Current.C)) +
          ', d=' + AsText(TAVM2Value.Num(Current.D)) + ', tx=' + AsText(TAVM2Value.Num(Current.TX)) +
          ', ty=' + AsText(TAVM2Value.Num(Current.TY)) + ')'));
  end;
  WriteNativeMatrix(Receiver, Output);
end;

procedure TAVM2Runtime.InstallLocalConnection(EventDispatcher: TAVM2Object);
var
  Method: TAVM2ConnectionMethod;
  Native, Prototype: TAVM2Object;
begin
  FLocalConnections := TDictionary<string, TAVM2Object>.Create;
  FConnectionMessages := TList<TAVM2ConnectionMessage>.Create;
  FLocalConnectionClass := NewObject(a2Class);
  FLocalConnectionClass.Parent := EventDispatcher;
  FLocalConnectionClass.CanDispatch := True;
  FLocalConnectionClass.DisplayName := 'flash.net.LocalConnection';
  FLocalConnectionClass.Props.Add(#0 + 'isSupported', TAVM2Value.Num(1, a2Boolean));
  FNative.Props.Add('flash.net' + #0 + 'LocalConnection', TAVM2Value.Ref(FLocalConnectionClass));
  Prototype := ClassPrototype(FLocalConnectionClass);
  for Method := Low(TAVM2ConnectionMethod) to High(TAVM2ConnectionMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := ConnectionMethodBase - Ord(Method);
    Prototype.Props.Add(#0 + ConnectionMethods[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.ProxyMethod(Receiver: TAVM2Object; const Name: string): TAVM2Object;
begin
  Result := nil;
  if (Receiver <> nil) and ClassHasType(Receiver.ClassObject, FProxyClass) then
    Result := PropertyValue(Receiver, ['http://www.adobe.com/2006/actionscript/flash/proxy' + #0 + Name]).Obj;
end;

function TAVM2Runtime.FrameLabelProperty(Display: TObject; const Name: string): TAVM2Value;
var
  Labels: TArray<TAVM2FrameLabel>;
  Item: TAVM2FrameLabel;
  Values: TArray<TAVM2Value>;
  I, Frame, LastLabel: Integer;
begin
  Labels := FDisplay.TimelineLabels(Display);
  if Name = #0 + 'currentLabels' then
  begin
    SetLength(Values, Length(Labels));
    for I := 0 to High(Labels) do
      Values[I] := TAVM2Value.Ref(Construct(FFrameLabelClass,
            [TAVM2Value.Str(Labels[I].Name), TAVM2Value.Num(Labels[I].Frame, a2Int)]));
    Exit(TAVM2Value.Ref(Construct(FArrayClass, Values)));
  end;
  Result := TAVM2Value.Ref(nil);
  Frame := FDisplay.TimelineFrame(Display, False);
  LastLabel := 0;
  for Item in Labels do
    if (Item.Frame <= Frame) and (Item.Frame >= LastLabel) then
    begin
      if (Name = #0 + 'currentFrameLabel') and (Frame <> Item.Frame) then
        Continue;
      LastLabel := Item.Frame;
      Result := TAVM2Value.Str(Item.Name);
    end;
end;

procedure TAVM2Runtime.InstallBitmapClasses;
const
  Names: array[TAVM2BitmapMethod] of string = ('draw', 'copyPixels', 'fillRect', 'getPixel', 'getPixel32',
    'setPixel', 'setPixel32', 'clone', 'dispose', 'lock', 'unlock', 'getColorBoundsRect');
var
  Method: TAVM2BitmapMethod;
  Native: TAVM2Object;
begin
  FBitmapPool := CreateImagePixelPool(128 * 1024 * 1024);
  FBitmapClass := NewObject(a2Class);
  FBitmapClass.DisplayName := 'flash.display.Bitmap';
  FBitmapClass.Parent := FNative.Props['flash.display' + #0 + 'DisplayObject'].Obj;
  FBitmapClass.CanDispatch := True;
  FBitmapClass.DisplayKind := adBitmap;
  FNative.Props.Add('flash.display' + #0 + 'Bitmap', TAVM2Value.Ref(FBitmapClass));

  FBitmapDataClass := NewObject(a2Class);
  FBitmapDataClass.DisplayName := 'flash.display.BitmapData';
  FBitmapDataClass.Parent := FObjectClass;
  FNative.Props.Add('flash.display' + #0 + 'BitmapData', TAVM2Value.Ref(FBitmapDataClass));
  for Method := Low(TAVM2BitmapMethod) to High(TAVM2BitmapMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := BitmapMethodBase - Ord(Method);
    ClassPrototype(FBitmapDataClass).Props.Add(#0 + Names[Method], TAVM2Value.Ref(Native));
  end;

  FColorTransformClass := NewObject(a2Class);
  FColorTransformClass.DisplayName := 'flash.geom.ColorTransform';
  FColorTransformClass.Parent := FObjectClass;
  FNative.Props.Add('flash.geom' + #0 + 'ColorTransform', TAVM2Value.Ref(FColorTransformClass));
  FBitmapFilterClass := NewObject(a2Class);
  FBitmapFilterClass.DisplayName := 'flash.filters.BitmapFilter';
  FBitmapFilterClass.Parent := FObjectClass;
  FNative.Props.Add('flash.filters' + #0 + 'BitmapFilter', TAVM2Value.Ref(FBitmapFilterClass));
  FGlowFilterClass := NewObject(a2Class);
  FGlowFilterClass.DisplayName := 'flash.filters.GlowFilter';
  FGlowFilterClass.Parent := FBitmapFilterClass;
  FNative.Props.Add('flash.filters' + #0 + 'GlowFilter', TAVM2Value.Ref(FGlowFilterClass));
end;

function TAVM2Runtime.NewFilter(const Data: TSWFFilter): TAVM2Object;
begin
  Result := NewObject(a2PlainObject, True);
  Result.ClassObject := FBitmapFilterClass;
  if Data.Kind = sfGlow then
    Result.ClassObject := FGlowFilterClass;
  Result.Parent := ClassPrototype(Result.ClassObject);
  Result.DisplayName := Result.ClassObject.DisplayName;
  New(Result.FilterData);
  Result.FilterData^ := Data;
  if Data.Kind = sfGlow then
  begin
    Result.Props.Add(#0 + 'color', TAVM2Value.Num(Data.Color and $FFFFFF, a2UInt));
    Result.Props.Add(#0 + 'alpha', TAVM2Value.Num((Data.Color shr 24) / 255));
    Result.Props.Add(#0 + 'blurX', TAVM2Value.Num(Data.BlurX));
    Result.Props.Add(#0 + 'blurY', TAVM2Value.Num(Data.BlurY));
    Result.Props.Add(#0 + 'strength', TAVM2Value.Num(Data.Strength));
    Result.Props.Add(#0 + 'quality', TAVM2Value.Num(Data.Passes, a2Int));
    Result.Props.Add(#0 + 'inner', TAVM2Value.Num(Ord(Data.Inner), a2Boolean));
    Result.Props.Add(#0 + 'knockout', TAVM2Value.Num(Ord(Data.Knockout), a2Boolean));
  end;
end;

function TAVM2Runtime.ReadFilter(Obj: TAVM2Object): TSWFFilter;

  function Number(const Key: string; Default: Double): Double;
  var
    Value: TAVM2Value;
  begin
    Result := Default;
    if Obj.Props.TryGetValue(#0 + Key, Value) then
      Result := CoerceNumber(Value);
    if IsNan(Result) then
      Result := 0;
  end;

begin
  Result := Default(TSWFFilter);
  if Obj.FilterData <> nil then
    Result := Obj.FilterData^;
  if Obj.ClassObject <> FGlowFilterClass then
    Exit;
  Result.Kind := sfGlow;
  Result.Color := (IntBits(Number('color', $FF0000)) and $FFFFFF) or
    (Cardinal(Round(EnsureRange(Number('alpha', 1), 0.0, 1.0) * 255)) shl 24);
  Result.BlurX := EnsureRange(Number('blurX', 6), 0.0, 255.0);
  Result.BlurY := EnsureRange(Number('blurY', 6), 0.0, 255.0);
  Result.Strength := EnsureRange(Number('strength', 2), 0.0, 255.0);
  Result.Passes := Trunc(EnsureRange(Number('quality', 1), 0.0, 15.0));
  Result.Inner := Truth(Obj.Props[#0 + 'inner']);
  Result.Knockout := Truth(Obj.Props[#0 + 'knockout']);
  Result.CompositeSource := not Result.Knockout;
end;

function TAVM2Runtime.DisplayFilters(Obj: TAVM2Object): TAVM2Value;
var
  Filters: TSWFFilters;
  Values: TArray<TAVM2Value>;
  I: Integer;
begin
  if (FDisplay <> nil) and (Obj.DisplayData <> nil) then
    Filters := FDisplay.GetFilters(Obj.DisplayData);
  SetLength(Values, Length(Filters));
  for I := 0 to High(Filters) do
    Values[I] := TAVM2Value.Ref(NewFilter(Filters[I]));
  Result := TAVM2Value.Ref(Construct(FArrayClass, Values));
end;

procedure TAVM2Runtime.WriteDisplayFilters(Obj: TAVM2Object; const Value: TAVM2Value);
var
  ArrayObject: TAVM2Object;
  Data: TAVM2Value;
  Filters: TSWFFilters;
  I: Integer;
begin
  ArrayObject := CoerceValue(Value, atClass, FArrayClass, 'Array').Obj;
  if ArrayObject <> nil then
  begin
    if ArrayObject.ArrayData.ArrayLength > 32 then
      RaiseScriptError('RangeError', 2006, 'Display filter count limit.');
    SetLength(Filters, ArrayObject.ArrayData.ArrayLength);
    for I := 0 to High(Filters) do
    begin
      if not TryArrayElement(ArrayObject.ArrayData, I, Data) or (Data.Obj = nil) or
        not ClassHasType(Data.Obj.ClassObject, FBitmapFilterClass) then
        RaiseScriptError('ArgumentError', 2005, 'Invalid display filter.');
      Filters[I] := ReadFilter(Data.Obj);
    end;
  end;
  if (FDisplay <> nil) and (Obj.DisplayData <> nil) then
    FDisplay.SetFilters(Obj.DisplayData, Filters);
end;

procedure TAVM2Runtime.InitBitmapData(Obj: TAVM2Object; const Args: TArray<TAVM2Value>);
var
  W, H: Integer;
  Transparent: Boolean;
  Color: Cardinal;
begin
  if (FDisplay <> nil) and (Obj.ClassObject <> FBitmapDataClass) then
    Obj.BitmapData := FDisplay.EmbeddedBitmap(QualifiedClassName(Obj.ClassObject));
  if Obj.BitmapData <> nil then
    Exit;
  if Length(Args) < 2 then
    RaiseScriptError('ArgumentError', 1063, 'BitmapData requires width and height.');
  W := Integer(IntBits(CoerceNumber(Args[0])));
  H := Integer(IntBits(CoerceNumber(Args[1])));
  if (W <= 0) or (H <= 0) or ((FSWFVersion < 10) and ((W > 2880) or (H > 2880))) then
    RaiseScriptError('ArgumentError', 2015, 'Invalid BitmapData dimensions.');
  Transparent := (Length(Args) <= 2) or Truth(Args[2]);
  Color := $FFFFFFFF;
  if Length(Args) > 3 then
    Color := IntBits(CoerceNumber(Args[3]));
  Obj.BitmapData := FBitmapPool.Allocate(W, H, Transparent, Color);
  if Obj.BitmapData = nil then
    RaiseScriptError('ArgumentError', 2015, 'BitmapData pixel limit.');
end;

procedure TAVM2Runtime.UpdateBitmapDisplay(Receiver: TAVM2Object);
var
  Data: TAVM2Object;
  Buffer: IImagePixelBuffer;
begin
  if (FDisplay = nil) or (Receiver.DisplayData = nil) then
    Exit;
  Data := Receiver.Props[#0 + 'bitmapData'].Obj;
  if Data <> nil then
    Buffer := Data.BitmapData;
  FDisplay.AttachBitmap(Receiver.DisplayData, Buffer, Truth(Receiver.Props[#0 + 'smoothing']));
end;

function TAVM2Runtime.BitmapCall(Method: TAVM2BitmapMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
const
  Required: array[TAVM2BitmapMethod] of Integer = (1, 3, 2, 2, 2, 3, 3, 0, 0, 0, 0, 2);
var
  Target, Source, Mask: IImagePixelBuffer;
  SourceObject, Point, Transform, Clone: TAVM2Object;
  Rect: TAVM2Rectangle;
  Options: TAVM2BitmapDraw;
  X, Y, I, J, SX, SY, DX, DY, AX, AY, W, H: Integer;
  L, T, R, B: Int64;
  Color, Alpha, ColorMask, Expected: Cardinal;
  Merge, MatchColor: Boolean;
  Saved: TArray<Cardinal>;

  function IntArg(Arg: Integer): Integer;
  begin
    Result := Integer(IntBits(CoerceNumber(Args[Arg])));
  end;

  procedure Charge(Pixels: Int64);
  begin
    Dec(FWork, (Pixels + 31) div 32);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 BitmapData work limit');
  end;

  function RectArg(Arg: Integer): TAVM2Rectangle;
  begin
    Result := ReadNativeRectangle(RectangleArgument(Args[Arg], False));
  end;

  function PointCoord(const Name: string): Integer;
  begin
    Result := Integer(IntBits(Point.Props[#0 + Name].Number));
  end;

  function ColorMasked(const Value: Cardinal; AtX, AtY: Integer): Cardinal;
  begin
    Result := Value;
    if Mask = nil then
      Exit;
    Alpha := Mask.PixelPremultiplied(AtX, AtY) shr 24;
    Result := ((Value and $FF) * Alpha + 127) div 255;
    Result := Result or (((((Value shr 8) and $FF) * Alpha + 127) div 255) shl 8);
    Result := Result or (((((Value shr 16) and $FF) * Alpha + 127) div 255) shl 16);
    Result := Result or ((((Value shr 24) * Alpha + 127) div 255) shl 24);
  end;

begin
  Result := Default(TAVM2Value);
  if (Receiver = nil) or (Receiver.BitmapData = nil) then
    RaiseScriptError('TypeError', 1004, 'Incompatible BitmapData receiver.');
  Target := Receiver.BitmapData;
  if Method = abDispose then
  begin
    Target.Dispose;
    Exit;
  end;
  if Target.Disposed then
    RaiseScriptError('ArgumentError', 2015, 'BitmapData has been disposed.');
  if Length(Args) < Required[Method] then
    RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for BitmapData.');
  case Method of
    abGetPixel, abGetPixel32:
      begin
        Color := Target.Pixel(IntArg(0), IntArg(1));
        if Method = abGetPixel then
          Color := Color and $FFFFFF;
        Result := TAVM2Value.Num(Color, a2UInt);
      end;
    abSetPixel, abSetPixel32:
      begin
        X := IntArg(0);
        Y := IntArg(1);
        Color := IntBits(CoerceNumber(Args[2]));
        if Method = abSetPixel then
          Color := (Color and $FFFFFF) or (Target.Pixel(X, Y) and $FF000000);
        Target.SetPixel(X, Y, Color);
      end;
    abColorBounds:
      begin
        ColorMask := IntBits(CoerceNumber(Args[0]));
        Expected := IntBits(CoerceNumber(Args[1]));
        MatchColor := (Length(Args) < 3) or Truth(Args[2]);
        Charge(Int64(Target.Width) * Target.Height);
        L := Target.Width;
        T := Target.Height;
        R := -1;
        B := -1;
        for J := 0 to Target.Height - 1 do
          for I := 0 to Target.Width - 1 do
          begin
            if ColorMask and $FFFFFF = 0 then
              Color := Target.PixelPremultiplied(I, J)
            else
              Color := Target.Pixel(I, J);
            if ((Color and ColorMask) = Expected) = MatchColor then
            begin
              L := Min(L, I);
              T := Min(T, J);
              R := Max(R, I);
              B := Max(B, J);
            end;
          end;
        Rect := Default(TAVM2Rectangle);
        if R >= L then
        begin
          Rect.X := L;
          Rect.Y := T;
          Rect.Width := R - L + 1;
          Rect.Height := B - T + 1;
        end;
        Result := NewRectangle(Rect);
      end;
    abFillRect:
      begin
        Rect := RectArg(0);
        X := Integer(IntBits(Rect.X));
        Y := Integer(IntBits(Rect.Y));
        R := Min(Int64(Target.Width), Int64(X) + Integer(IntBits(Rect.Width)));
        B := Min(Int64(Target.Height), Int64(Y) + Integer(IntBits(Rect.Height)));
        X := Max(0, X);
        Y := Max(0, Y);
        if (X >= R) or (Y >= B) then
          Exit;
        Charge((R - X) * (B - Y));
        Color := PremultiplyBitmapColor(IntBits(CoerceNumber(Args[1])), Target.Transparent);
        for J := Y to Integer(B) - 1 do
          for I := X to Integer(R) - 1 do
            Target.SetPixelPremultiplied(I, J, Color);
      end;
    abClone:
      begin
        Charge(Int64(Target.Width) * Target.Height);
        Clone := Construct(FBitmapDataClass, [TAVM2Value.Num(Target.Width), TAVM2Value.Num(Target.Height),
            TAVM2Value.Num(Ord(Target.Transparent), a2Boolean), TAVM2Value.Num(0, a2UInt)]);
        for J := 0 to Target.Height - 1 do
          for I := 0 to Target.Width - 1 do
            Clone.BitmapData.SetPixelPremultiplied(I, J, Target.PixelPremultiplied(I, J));
        Result := TAVM2Value.Ref(Clone);
      end;
    abCopyPixels:
      begin
        SourceObject := Args[0].Obj;
        if (SourceObject = nil) or (SourceObject.BitmapData = nil) or SourceObject.BitmapData.Disposed then
          RaiseScriptError('ArgumentError', 2015, 'Invalid source BitmapData.');
        Source := SourceObject.BitmapData;
        Rect := RectArg(1);
        Point := PointArgument(Args[2]);
        SX := Integer(IntBits(Rect.X));
        SY := Integer(IntBits(Rect.Y));
        DX := PointCoord('x');
        DY := PointCoord('y');
        AX := 0;
        AY := 0;
        if (Length(Args) > 3) and (Args[3].Obj <> nil) then
        begin
          Mask := Args[3].Obj.BitmapData;
          if (Mask = nil) or Mask.Disposed then
            RaiseScriptError('ArgumentError', 2015, 'Invalid alpha BitmapData.');
          if (Length(Args) > 4) and (Args[4].Obj <> nil) then
          begin
            Point := PointArgument(Args[4]);
            AX := PointCoord('x');
            AY := PointCoord('y');
          end;
        end;
        Merge := (Length(Args) > 5) and Truth(Args[5]);
        L := Max(0, Max(-Int64(SX), -Int64(DX)));
        T := Max(0, Max(-Int64(SY), -Int64(DY)));
        R := Min(Integer(IntBits(Rect.Width)), Min(Int64(Source.Width) - SX, Int64(Target.Width) - DX));
        B := Min(Integer(IntBits(Rect.Height)), Min(Int64(Source.Height) - SY, Int64(Target.Height) - DY));
        if (L >= R) or (T >= B) then
          Exit;
        W := Integer(R - L);
        H := Integer(B - T);
        Inc(SX, Integer(L));
        Inc(SY, Integer(T));
        Inc(DX, Integer(L));
        Inc(DY, Integer(T));
        AX := Integer(EnsureRange(Int64(AX) + L, Low(Integer), High(Integer) - W));
        AY := Integer(EnsureRange(Int64(AY) + T, Low(Integer), High(Integer) - H));
        Charge(Int64(W) * H);
        if not Merge and (Mask = nil) and
          Target.TryCopyPremultiplied(Source, SX, SY, DX, DY, W, H) then
          Exit;
        if (Source = Target) or (Mask = Target) then
        begin
          SetLength(Saved, W * H);
          for J := 0 to H - 1 do
            for I := 0 to W - 1 do
              Saved[J * W + I] := ColorMasked(Source.PixelPremultiplied(SX + I, SY + J), AX + I, AY + J);
        end;
        for J := 0 to H - 1 do
          for I := 0 to W - 1 do
          begin
            if Saved <> nil then
              Color := Saved[J * W + I]
            else
              Color := ColorMasked(Source.PixelPremultiplied(SX + I, SY + J), AX + I, AY + J);
            if Merge then
              Color := BlendPremultiplied(Target.PixelPremultiplied(DX + I, DY + J), Color)
            else if not Target.Transparent then
              Color := UnpremultiplyBitmapColor(Color) or $FF000000;
            Target.SetPixelPremultiplied(DX + I, DY + J, Color);
          end;
      end;
    abDraw:
      begin
        SourceObject := Args[0].Obj;
        if (SourceObject = nil) or ((SourceObject.DisplayData = nil) and (SourceObject.BitmapData = nil)) then
          RaiseScriptError('ArgumentError', 2004, 'Invalid BitmapData.draw source.');
        Options := Default(TAVM2BitmapDraw);
        Options.Matrix := IdentityMatrix;
        if (Length(Args) > 1) and (Args[1].Obj <> nil) then
          Options.Matrix := ReadNativeMatrix(CoerceValue(Args[1], atClass, FMatrixClass, 'flash.geom.Matrix').Obj);
        for I := 0 to 3 do
          Options.Color[I] := 1;
        if (Length(Args) > 2) and (Args[2].Obj <> nil) then
        begin
          Transform := CoerceValue(Args[2], atClass, FColorTransformClass, 'flash.geom.ColorTransform').Obj;
          for I := 0 to High(ColorTransformFields) do
            Options.Color[I] := CoerceNumber(Transform.Props[#0 + ColorTransformFields[I]]);
        end;
        if (Length(Args) > 3) and (Args[3].Kind <> a2Null) then
          Options.Blend := CoerceText(Args[3]);
        Options.HasClip := (Length(Args) > 4) and (Args[4].Obj <> nil);
        if Options.HasClip then
          Options.Clip := RectArg(4);
        Options.Smooth := (Length(Args) > 5) and Truth(Args[5]);
        if FDisplay <> nil then
          FDisplay.DrawBitmap(Target, SourceObject, Options);
      end;
  end;
end;

procedure TAVM2Runtime.InstallMathClass;
const
  Names: array[TAVM2MathMethod] of string = ('abs', 'acos', 'asin', 'atan', 'atan2', 'ceil',
    'cos', 'exp', 'floor', 'log', 'max', 'min', 'pow', 'random', 'round', 'sin', 'sqrt', 'tan');
var
  MathClass, Native: TAVM2Object;
  Method: TAVM2MathMethod;
begin
  MathClass := NewObject(a2Class);
  MathClass.Parent := FObjectClass;
  MathClass.DisplayName := 'Math';
  FNative.Props.Add(#0 + 'Math', TAVM2Value.Ref(MathClass));
  MathClass.Props.Add(#0 + 'PI', TAVM2Value.Num(Pi));
  MathClass.Props.Add(#0 + 'E', TAVM2Value.Num(Exp(1)));
  MathClass.Props.Add(#0 + 'LN2', TAVM2Value.Num(Ln(2)));
  MathClass.Props.Add(#0 + 'LN10', TAVM2Value.Num(Ln(10)));
  MathClass.Props.Add(#0 + 'LOG2E', TAVM2Value.Num(1 / Ln(2)));
  MathClass.Props.Add(#0 + 'LOG10E', TAVM2Value.Num(1 / Ln(10)));
  MathClass.Props.Add(#0 + 'SQRT2', TAVM2Value.Num(Sqrt(2)));
  MathClass.Props.Add(#0 + 'SQRT1_2', TAVM2Value.Num(Sqrt(0.5)));
  for Method := Low(TAVM2MathMethod) to High(TAVM2MathMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := MathMethodBase - Ord(Method);
    MathClass.Props.Add(#0 + Names[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.MathCall(Method: TAVM2MathMethod; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  X, Y: Double;
  Value: TAVM2Value;
begin
  if Method = amRandom then
  begin
    if Length(Args) <> 0 then
      RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for Math.random.');
    FRandomState := FRandomState xor (FRandomState shl 13);
    FRandomState := FRandomState xor (FRandomState shr 17);
    FRandomState := FRandomState xor (FRandomState shl 5);
    Exit(TAVM2Value.Num(FRandomState / 4294967296.0));
  end;
  if Method in [amMin, amMax] then
  begin
    X := Infinity;
    if Method = amMax then
      X := NegInfinity;
    for Value in Args do
    begin
      Y := CoerceNumber(Value);
      if IsNan(Y) then
        Exit(TAVM2Value.Num(NaN));
      if Method = amMax then
        X := Max(X, Y)
      else
        X := Min(X, Y);
    end;
    Exit(TAVM2Value.Num(X));
  end;
  X := NaN;
  Y := NaN;
  if Length(Args) >= 1 then
    X := CoerceNumber(Args[0]);
  if (Length(Args) >= 2) and (Method in [amAtan2, amPow]) then
    Y := CoerceNumber(Args[1]);
  if (Method = amPow) and (Y = 0) then
    Exit(TAVM2Value.Num(1));
  if IsNan(X) or ((Method in [amAtan2, amPow]) and IsNan(Y)) then
    Exit(TAVM2Value.Num(NaN));
  case Method of
    amAbs:
      X := Abs(X);
    amAcos:
      if Abs(X) <= 1 then
        X := ArcCos(X)
      else
        X := NaN;
    amAsin:
      if Abs(X) <= 1 then
        X := ArcSin(X)
      else
        X := NaN;
    amAtan:
      X := ArcTan(X);
    amAtan2:
      X := ArcTan2(X, Y);
    amCeil:
      if not IsInfinite(X) then
        X := Int(X) + Ord(X > Int(X));
    amCos:
      if IsInfinite(X) then
        X := NaN
      else
        X := Cos(X);
    amExp:
      X := Exp(X);
    amFloor:
      if not IsInfinite(X) then
        X := Int(X) - Ord(X < Int(X));
    amLog:
      if X < 0 then
        X := NaN
      else if X = 0 then
        X := NegInfinity
      else
        X := Ln(X);
    amPow:
      if (X < 0) and not IsInfinite(Y) and (Y <> Int(Y)) then
        X := NaN
      else
        X := Power(X, Y);
    amRound:
      if not IsInfinite(X) and (Abs(X) < 4503599627370496.0) then
      begin
        if (X < 0) and (X >= -0.5) then
          X := -0.0
        else
        begin
          Y := Int(X) - Ord(X < Int(X));
          X := Y + Ord(X - Y >= 0.5);
        end;
      end;
    amSin:
      if IsInfinite(X) then
        X := NaN
      else
        X := Sin(X);
    amSqrt:
      if X < 0 then
        X := NaN
      else
        X := Sqrt(X);
    amTan:
      if IsInfinite(X) then
        X := NaN
      else
        X := Tan(X);
  end;
  Result := TAVM2Value.Num(X);
end;

procedure TAVM2Runtime.InstallSystemClasses;
const
  Names: array[TAVM2DateMethod] of string = ('getTime', 'setTime', 'toString', 'valueOf');
var
  Native, Capabilities, ExternalInterface, SystemClass: TAVM2Object;
  Method: TAVM2DateMethod;
begin
  Capabilities := NewObject(a2Class);
  Capabilities.DisplayName := 'flash.system.Capabilities';
  Capabilities.Parent := FObjectClass;
  Capabilities.Props.Add(#0 + 'manufacturer', TAVM2Value.Str('RetroMul ' + TOSVersion.Name));
  Capabilities.Props.Add(#0 + 'os', TAVM2Value.Str(TOSVersion.Name));
  Capabilities.Props.Add(#0 + 'language', TAVM2Value.Str('en'));
  Capabilities.Props.Add(#0 + 'screenColor', TAVM2Value.Str('color'));
  Capabilities.Props.Add(#0 + 'pixelAspectRatio', TAVM2Value.Num(1));
  Capabilities.Props.Add(#0 + 'playerType', TAVM2Value.Str('StandAlone'));
  Capabilities.Props.Add(#0 + 'version', TAVM2Value.Str('RETROMUL 0,0,0,0'));
  Capabilities.Props.Add(#0 + 'isDebugger', TAVM2Value.Num(0, a2Boolean));
  Capabilities.Props.Add(#0 + 'hasAudio', TAVM2Value.Num(1, a2Boolean));
  Capabilities.Props.Add(#0 + 'hasMP3', TAVM2Value.Num(1, a2Boolean));
  FNative.Props.Add('flash.system' + #0 + 'Capabilities', TAVM2Value.Ref(Capabilities));

  SystemClass := NewObject(a2Class);
  SystemClass.DisplayName := 'flash.system.System';
  SystemClass.Parent := FObjectClass;
  SystemClass.Props.Add(#0 + 'vmVersion', TAVM2Value.Str('2.0.0.0'));
  SystemClass.Props.Add(#0 + 'useCodePage', TAVM2Value.Num(0, a2Boolean));
  FNative.Props.Add('flash.system' + #0 + 'System', TAVM2Value.Ref(SystemClass));

  ExternalInterface := NewObject(a2Class);
  ExternalInterface.DisplayName := 'flash.external.ExternalInterface';
  ExternalInterface.Parent := FObjectClass;
  ExternalInterface.Props.Add(#0 + 'available', TAVM2Value.Num(0, a2Boolean));
  ExternalInterface.Props.Add(#0 + 'objectID', TAVM2Value.Ref(nil));
  ExternalInterface.Props.Add(#0 + 'marshallExceptions', TAVM2Value.Num(0, a2Boolean));
  Native := NewObject(a2Function);
  Native.Index := ExternalCallMethod;
  ExternalInterface.Props.Add(#0 + 'call', TAVM2Value.Ref(Native));
  FNative.Props.Add('flash.external' + #0 + 'ExternalInterface', TAVM2Value.Ref(ExternalInterface));

  FDateClass := NewObject(a2Class);
  FDateClass.DisplayName := 'Date';
  FDateClass.Parent := FObjectClass;
  FNative.Props.Add(#0 + 'Date', TAVM2Value.Ref(FDateClass));
  for Method := Low(TAVM2DateMethod) to High(TAVM2DateMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := DateMethodBase - Ord(Method);
    ClassPrototype(FDateClass).Props.Add(#0 + Names[Method], TAVM2Value.Ref(Native));
    ClassPrototype(FDateClass).Props.Add(BuiltinNamespace + Names[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.DateCall(Method: TAVM2DateMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Time: Double;
begin
  if (Receiver = nil) or (Receiver.ClassObject <> FDateClass) then
    RaiseScriptError('TypeError', 1004, 'Incompatible Date receiver.');
  Result := Receiver.Props[#0 + 'time'];
  if Method = admSetTime then
  begin
    Time := NaN;
    if Length(Args) > 0 then
      Time := CoerceNumber(Args[0]);
    if not IsNan(Time) and (Abs(Time) <= 8640000000000000.0) then
      Time := Int(Time)
    else
      Time := NaN;
    Result := TAVM2Value.Num(Time);
    Receiver.Props[#0 + 'time'] := Result;
  end
  else if Method = admToString then
  begin
    Time := Result.Number;
    if IsNan(Time) or (Time < -62135596800000.0) or (Time >= 253402300800000.0) then
      Exit(TAVM2Value.Str('Invalid Date'));
    Result := TAVM2Value.Str(FormatDateTime('ddd mmm d hh:nn:ss "GMT+0000" yyyy',
        IncMilliSecond(EncodeDate(1970, 1, 1), Trunc(Time)), TFormatSettings.Invariant));
  end;
end;

function TAVM2Runtime.LoaderBytes: TAVM2Value;
var
  Data: TBytes;
  Obj: TAVM2Object;
begin
  if FDisplay <> nil then
    Data := FDisplay.MovieBytes;
  if Length(Data) = 0 then
    Exit(TAVM2Value.Ref(nil));
  Obj := NewObject(a2PlainObject, True);
  Obj.ClassObject := FByteArrayClass;
  Obj.Parent := ClassPrototype(FByteArrayClass);
  Obj.DisplayName := FByteArrayClass.DisplayName;
  InstallInstanceTraits(FByteArrayClass, Obj);
  ResizeByteArray(Obj.ByteArrayData, Length(Data));
  Move(Data[0], Obj.ByteArrayData.Buffer[0], Length(Data));
  Result := TAVM2Value.Ref(Obj);
end;

procedure TAVM2Runtime.InstallTextClasses(InteractiveObject: TAVM2Object);
const
  Methods: array[TAVM2TextMethod] of string = ('setTextFormat', 'appendText', 'setSelection');
var
  Method: TAVM2TextMethod;
  Native: TAVM2Object;

  procedure Enum(const Name: string; const Values: array of string);
  var
    Item: string;
  begin
    Native := NewObject(a2Class);
    Native.Parent := FObjectClass;
    Native.DisplayName := 'flash.text.' + Name;
    FNative.Props.Add('flash.text' + #0 + Name, TAVM2Value.Ref(Native));
    for Item in Values do
      Native.Props.Add(#0 + UpperCase(Item), TAVM2Value.Str(Item));
  end;

begin
  FTextFieldClass := NewObject(a2Class);
  FTextFieldClass.DisplayName := 'flash.text.TextField';
  FTextFieldClass.Parent := InteractiveObject;
  FTextFieldClass.CanDispatch := True;
  FTextFieldClass.DisplayKind := adText;
  FNative.Props.Add('flash.text' + #0 + 'TextField', TAVM2Value.Ref(FTextFieldClass));
  for Method := Low(TAVM2TextMethod) to High(TAVM2TextMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := TextMethodBase - Ord(Method);
    ClassPrototype(FTextFieldClass).Props.Add(#0 + Methods[Method], TAVM2Value.Ref(Native));
  end;
  FTextFormatClass := NewObject(a2Class);
  FTextFormatClass.DisplayName := 'flash.text.TextFormat';
  FTextFormatClass.Parent := FObjectClass;
  FNative.Props.Add('flash.text' + #0 + 'TextFormat', TAVM2Value.Ref(FTextFormatClass));
  Enum('TextFieldType', ['input', 'dynamic']);
  Enum('TextFieldAutoSize', ['none', 'left', 'center', 'right']);
  Enum('TextFormatAlign', ['left', 'center', 'right', 'justify', 'start', 'end']);
  Enum('AntiAliasType', ['normal', 'advanced']);
  Enum('GridFitType', ['none', 'pixel', 'subpixel']);
end;

function TAVM2Runtime.TextCall(Method: TAVM2TextMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Value: TAVM2Value;
  Format: TAVM2Object;
  First, Last: Integer;
begin
  Result := Default(TAVM2Value);
  if (Receiver = nil) or (Receiver.DisplayKind <> adText) then
    RaiseScriptError('TypeError', 1004, 'Incompatible TextField receiver.');
  if FDisplay = nil then
    Exit;
  if (Length(Args) < 1) or ((Method = atfSetSelection) and (Length(Args) < 2)) then
    RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for TextField.');
  case Method of
    atfSetFormat:
      begin
        Format := CoerceValue(Args[0], atClass, FTextFormatClass, 'flash.text.TextFormat').Obj;
        if Format = nil then
          RaiseScriptError('TypeError', 2007, 'Text format must be non-null.');
        First := 0;
        Last := -1;
        if Length(Args) > 1 then
          First := Max(0, Integer(IntBits(CoerceNumber(Args[1]))));
        if Length(Args) > 2 then
          Last := Integer(IntBits(CoerceNumber(Args[2])));
        FDisplay.SetTextFormat(Receiver.DisplayData, Format, First, Last);
      end;
    atfAppendText:
      if FDisplay.GetTextProperty(Receiver.DisplayData, 'text', Value) then
        FDisplay.SetTextProperty(Receiver.DisplayData, 'text', TAVM2Value.Str(Value.Text + CoerceText(Args[0])));
    atfSetSelection:
      begin
        Receiver.Props.AddOrSetValue(#0 + 'selectionBeginIndex', TAVM2Value.Num(IntBits(CoerceNumber(Args[0])), a2Int));
        Receiver.Props.AddOrSetValue(#0 + 'selectionEndIndex', TAVM2Value.Num(IntBits(CoerceNumber(Args[1])), a2Int));
      end;
  end;
end;

procedure TAVM2Runtime.InstallStyleSheet(EventDispatcher: TAVM2Object);
const
  Methods: array[TAVM2StyleMethod] of string = ('clear', 'setStyle', 'getStyle');
var
  Method: TAVM2StyleMethod;
  Native: TAVM2Object;
begin
  FStyleSheetClass := NewObject(a2Class);
  FStyleSheetClass.DisplayName := 'flash.text.StyleSheet';
  FStyleSheetClass.Parent := EventDispatcher;
  FStyleSheetClass.CanDispatch := True;
  FNative.Props.Add('flash.text' + #0 + 'StyleSheet', TAVM2Value.Ref(FStyleSheetClass));
  for Method := Low(TAVM2StyleMethod) to High(TAVM2StyleMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := StyleMethodBase - Ord(Method);
    ClassPrototype(FStyleSheetClass).Props.Add(#0 + Methods[Method], TAVM2Value.Ref(Native));
  end;
end;

function TAVM2Runtime.StyleCall(Method: TAVM2StyleMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Key: string;
  Style, Rule: TAVM2Value;
  CopyOfStyle: TAVM2Object;
  Source: TAVM2Object;
begin
  Result := Default(TAVM2Value);
  if (Receiver = nil) or not ClassHasType(Receiver.ClassObject, FStyleSheetClass) then
    RaiseScriptError('TypeError', 1004, 'Incompatible StyleSheet receiver.');
  if Method = atsClear then
  begin
    for Key in Receiver.Props.FIndices.Keys.ToArray do
      if StartsStr('css' + #0, Key) then
        Receiver.Props.Remove(Key);
    Exit;
  end;
  if (Length(Args) < 1) or ((Method = atsSetStyle) and (Length(Args) < 2)) then
    RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for StyleSheet.');
  Key := 'css' + #0 + LowerCase(CoerceText(Args[0]));
  Source := nil;
  if Method = atsSetStyle then
    Source := Args[1].Obj
  else if Receiver.Props.TryGetValue(Key, Style) then
    Source := Style.Obj;
  if Source = nil then
  begin
    if Method = atsSetStyle then
      Receiver.Props.Remove(Key)
    else
      Result := TAVM2Value.Ref(nil);
    Exit;
  end;
  CopyOfStyle := NewObject(a2PlainObject, True);
  CopyOfStyle.Parent := FObjectPrototype;
  if Source.DynamicProperties <> nil then
    for var Entry in Source.DynamicProperties do
      if Entry.Enumerable and Source.Props.TryGetValue(Entry.Key, Rule) then
        StoreDynamicProperty(CopyOfStyle, Entry.Key, Rule);
  if Method = atsSetStyle then
    Receiver.Props.AddOrSetValue(Key, TAVM2Value.Ref(CopyOfStyle))
  else
    Result := TAVM2Value.Ref(CopyOfStyle);
end;

procedure TAVM2Runtime.InstallSound(EventDispatcher: TAVM2Object);
var
  Native: TAVM2Object;
begin
  FSoundChannels := TList<TAVM2Object>.Create;
  FSoundClass := NewObject(a2Class);
  FSoundClass.DisplayName := 'flash.media.Sound';
  FSoundClass.Parent := EventDispatcher;
  FSoundClass.CanDispatch := True;
  FNative.Props.Add('flash.media' + #0 + 'Sound', TAVM2Value.Ref(FSoundClass));
  Native := NewObject(a2Function);
  Native.Index := SoundMethodBase - Ord(asPlay);
  ClassPrototype(FSoundClass).Props.Add(#0 + 'play', TAVM2Value.Ref(Native));
  FSoundChannelClass := NewObject(a2Class);
  FSoundChannelClass.DisplayName := 'flash.media.SoundChannel';
  FSoundChannelClass.Parent := EventDispatcher;
  FSoundChannelClass.CanDispatch := True;
  FNative.Props.Add('flash.media' + #0 + 'SoundChannel', TAVM2Value.Ref(FSoundChannelClass));
  Native := NewObject(a2Function);
  Native.Index := SoundMethodBase - Ord(asStop);
  ClassPrototype(FSoundChannelClass).Props.Add(#0 + 'stop', TAVM2Value.Ref(Native));
  FSoundTransformClass := NewObject(a2Class);
  FSoundTransformClass.DisplayName := 'flash.media.SoundTransform';
  FSoundTransformClass.Parent := FObjectClass;
  FNative.Props.Add('flash.media' + #0 + 'SoundTransform', TAVM2Value.Ref(FSoundTransformClass));
end;

function TAVM2Runtime.SoundCall(Method: TAVM2SoundMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Channel, Transform: TAVM2Object;
  Start: Double;
  Loops: Integer;
begin
  Result := Default(TAVM2Value);
  if Method = asStop then
  begin
    if (Receiver = nil) or (Receiver.ClassObject <> FSoundChannelClass) then
      RaiseScriptError('TypeError', 1004, 'Incompatible SoundChannel receiver.');
    if (FSoundChannels.Remove(Receiver) >= 0) and (FDisplay <> nil) then
      FDisplay.StopSound(Receiver);
    Exit;
  end;
  if (Receiver = nil) or not ClassHasType(Receiver.ClassObject, FSoundClass) then
    RaiseScriptError('TypeError', 1004, 'Incompatible Sound receiver.');
  Result := TAVM2Value.Ref(nil);
  if (FDisplay = nil) or (FSoundChannels.Count >= 64) then
    Exit;
  Start := 0;
  Loops := 0;
  Transform := nil;
  if Length(Args) >= 1 then
    Start := CoerceNumber(Args[0]);
  if Length(Args) >= 2 then
    Loops := Integer(IntBits(CoerceNumber(Args[1])));
  if Length(Args) >= 3 then
    Transform := CoerceValue(Args[2], atClass, FSoundTransformClass, 'flash.media.SoundTransform').Obj;
  if Transform = nil then
    Transform := Construct(FSoundTransformClass, nil);
  if IsNan(Start) or (Start < 0) then
    Start := 0;
  Channel := NewObject(a2PlainObject, True);
  Channel.ClassObject := FSoundChannelClass;
  Channel.Parent := ClassPrototype(FSoundChannelClass);
  Channel.DisplayName := FSoundChannelClass.DisplayName;
  BindDispatcher(Channel);
  Channel.Props.Add(#0 + 'position', TAVM2Value.Num(Start));
  Channel.Props.Add(#0 + 'soundTransform', TAVM2Value.Ref(Transform));
  if FDisplay.StartSound(QualifiedClassName(Receiver.ClassObject), Channel, Start, Max(0, Loops)) then
  begin
    FSoundChannels.Add(Channel);
    Result := TAVM2Value.Ref(Channel);
  end;
end;

procedure TAVM2Runtime.DeliverSoundComplete;
var
  Channel: TAVM2Object;
begin
  for Channel in FSoundChannels.ToArray do
    if Channel.SoundFinished and (FSoundChannels.Remove(Channel) >= 0) and
      HasListener(Channel, 'soundComplete', False) then
      DispatchEventTo(Channel, HostEventObject(FEnterFrameClass, 'soundComplete', False, False), False);
end;

function TryPublicIndex(const Name: string; out Index: Cardinal): Boolean; forward;

procedure TAVM2Runtime.InstallXMLClasses;
const
  Names: array[TAVM2XMLMethod] of string = ('length', 'child', 'children', 'elements', 'attribute',
    'attributes', 'descendants', 'text', 'toString', 'toXMLString', 'name');
var
  Method: TAVM2XMLMethod;
begin
  FXMLClass := NewObject(a2Class);
  FXMLClass.Parent := FObjectClass;
  FXMLClass.DisplayName := 'XML';
  FNative.Props.Add(#0 + 'XML', TAVM2Value.Ref(FXMLClass));
  FXMLListClass := NewObject(a2Class);
  FXMLListClass.Parent := FObjectClass;
  FXMLListClass.DisplayName := 'XMLList';
  FNative.Props.Add(#0 + 'XMLList', TAVM2Value.Ref(FXMLListClass));
  for Method := Low(TAVM2XMLMethod) to High(TAVM2XMLMethod) do
  begin
    FXMLMethods[Method] := NewObject(a2Function);
    FXMLMethods[Method].Index := XMLMethodBase - Ord(Method);
    ClassPrototype(FXMLClass).Props.Add(#0 + Names[Method], TAVM2Value.Ref(FXMLMethods[Method]));
    ClassPrototype(FXMLClass).Props.Add(BuiltinNamespace + Names[Method], TAVM2Value.Ref(FXMLMethods[Method]));
    ClassPrototype(FXMLListClass).Props.Add(#0 + Names[Method], TAVM2Value.Ref(FXMLMethods[Method]));
    ClassPrototype(FXMLListClass).Props.Add(BuiltinNamespace + Names[Method], TAVM2Value.Ref(FXMLMethods[Method]));
  end;
end;

function TAVM2Runtime.IsXML(Obj: TAVM2Object): Boolean;
begin
  Result := (Obj <> nil) and ((Obj.ClassObject = FXMLClass) or (Obj.ClassObject = FXMLListClass));
end;

procedure TAVM2Runtime.ParseXML(Obj: TAVM2Object; const Args: TArray<TAVM2Value>);
var
  Text: string;
  Document: IXMLDocument;
  NativeDocument: TXMLDocument;
  Node: IXMLNode;
  Nodes: TList<IXMLNode>;
begin
  if (Length(Args) = 0) or (Args[0].Kind in [a2Undefined, a2Null]) then
    Text := ''
  else if IsXML(Args[0].Obj) then
    Text := XMLCall(axXMLString, Args[0].Obj, nil).Text
  else
    Text := CoerceText(Args[0]);
  if Length(Text) > TextLimit then
    raise EAVM2Error.Create('AVM2 XML size limit');
  if (Pos('<!DOCTYPE', Text) > 0) or (Pos('<!ENTITY', Text) > 0) then
    RaiseScriptError('TypeError', 1088, 'XML document type declarations are unsupported.');
  NativeDocument := TXMLDocument.Create(nil);
  Document := NativeDocument;
  NativeDocument.DOMVendor := GetDOMVendor(sOmniXmlVendor);
  Document.Options := [];
  try
    Text := Trim(Text);
    if Obj.ClassObject = FXMLListClass then
      Text := '<xml-list>' + Text + '</xml-list>'
    else if not StartsStr('<', Text) then
    begin
      Document.Active := True;
      Node := Document.CreateNode('', ntText);
      Node.Text := Text;
      Obj.XMLDocument := Document;
      Obj.XMLNodes := [Node];
      Exit;
    end;
    Document.LoadFromXML(Text);
    Obj.XMLDocument := Document;
    Node := Document.DocumentElement;
    if Obj.ClassObject = FXMLClass then
    begin
      if Node <> nil then
        Obj.XMLNodes := [Node];
      Exit;
    end;
    Nodes := TList<IXMLNode>.Create;
    try
      if Node <> nil then
        for var I := 0 to Node.ChildNodes.Count - 1 do
          if Node.ChildNodes[I].NodeType in [ntElement, ntText, ntCData] then
            Nodes.Add(Node.ChildNodes[I]);
      Obj.XMLNodes := Nodes.ToArray;
    finally
      Nodes.Free;
    end;
  except
    on E: EXMLDocError do
      RaiseScriptError('TypeError', 1088, 'The markup in the document is not well formed.');
    on E: EDOMParseError do
      RaiseScriptError('TypeError', 1088, 'The markup in the document is not well formed.');
  end;
end;

function TAVM2Runtime.XMLValue(const Document: IXMLDocument; const Nodes: TArray<IXMLNode>; IsList: Boolean): TAVM2Value;
var
  Obj: TAVM2Object;
begin
  Obj := NewObject(a2PlainObject, True);
  if IsList then
    Obj.ClassObject := FXMLListClass
  else
    Obj.ClassObject := FXMLClass;
  Obj.Parent := ClassPrototype(Obj.ClassObject);
  Obj.DisplayName := Obj.ClassObject.DisplayName;
  Obj.XMLDocument := Document;
  Obj.XMLNodes := Nodes;
  Result := TAVM2Value.Ref(Obj);
end;

function TAVM2Runtime.XMLProperty(Obj: TAVM2Object; const Key: string): TAVM2Value;
var
  Index: Cardinal;
  Name: string;
begin
  if TryPublicIndex(Key, Index) then
  begin
    if Index < Cardinal(Length(Obj.XMLNodes)) then
    begin
      if Obj.ClassObject = FXMLClass then
        Exit(TAVM2Value.Ref(Obj));
      Exit(XMLValue(Obj.XMLDocument, [Obj.XMLNodes[Index]], False));
    end;
    Exit(Default(TAVM2Value));
  end;
  Name := Copy(Key, 2, MaxInt);
  if StartsStr('@', Name) then
    Exit(XMLCall(axAttribute, Obj, [TAVM2Value.Str(Copy(Name, 2, MaxInt))]));
  Result := XMLCall(axChild, Obj, [TAVM2Value.Str(Name)]);
end;

function TAVM2Runtime.XMLCall(Method: TAVM2XMLMethod; Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Name: string;
  Nodes: TList<IXMLNode>;
  Builder: TStringBuilder;
  List: IXMLNodeList;
  Node: IXMLNode;
  Index: Cardinal;
  Simple: Boolean;

  procedure SelectChildren(const Parent: IXMLNode; Depth: Integer);
  var
    Children: IXMLNodeList;
    Child: IXMLNode;
    Matches: Boolean;
  begin
    if Depth >= 256 then
      raise EAVM2Error.Create('AVM2 XML depth limit');
    Children := Parent.ChildNodes;
    for var I := 0 to Children.Count - 1 do
    begin
      Dec(FWork);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      Child := Children[I];
      case Method of
        axText:
          Matches := Child.NodeType in [ntText, ntCData];
        axChildren:
          Matches := Child.NodeType in [ntElement, ntText, ntCData];
        axChild:
          if TryPublicIndex(#0 + Name, Index) then
            Matches := Cardinal(I) = Index
          else if Name = '*' then
            Matches := Child.NodeType in [ntElement, ntText, ntCData]
          else
            Matches := (Child.NodeType = ntElement) and (Child.LocalName = Name);
      else
        Matches := (Child.NodeType = ntElement) and ((Name = '*') or (Child.LocalName = Name));
      end;
      if Matches then
        Nodes.Add(Child);
      if (Method = axDescendants) and (Child.NodeType = ntElement) then
        SelectChildren(Child, Depth + 1);
    end;
  end;

begin
  if not IsXML(Obj) then
    RaiseScriptError('TypeError', 1004, 'Incompatible XML receiver.');
  Name := '*';
  if Length(Args) <> 0 then
    Name := CoerceText(Args[0]);
  case Method of
    axLength:
      Exit(TAVM2Value.Num(Length(Obj.XMLNodes), a2Int));
    axName:
      begin
        if (Length(Obj.XMLNodes) = 1) and (Obj.XMLNodes[0].NodeType in [ntElement, ntAttribute]) then
          Exit(TAVM2Value.Str(Obj.XMLNodes[0].LocalName));
        Exit(TAVM2Value.Ref(nil));
      end;
    axString, axXMLString:
      begin
        Builder := TStringBuilder.Create;
        try
          Simple := Method = axString;
          for Node in Obj.XMLNodes do
            if Node.NodeType = ntElement then
              for var I := 0 to Node.ChildNodes.Count - 1 do
                if Node.ChildNodes[I].NodeType = ntElement then
                  Simple := False;
          for Node in Obj.XMLNodes do
          begin
            if not Simple and (Builder.Length > 0) then
              Builder.Append(#10);
            if Node.NodeType in [ntAttribute, ntText, ntCData] then
              Builder.Append(VarToStr(Node.NodeValue))
            else if Simple then
            begin
              for var I := 0 to Node.ChildNodes.Count - 1 do
                if Node.ChildNodes[I].NodeType in [ntText, ntCData] then
                  Builder.Append(VarToStr(Node.ChildNodes[I].NodeValue));
            end
            else
              Builder.Append(Node.XML);
            if Builder.Length > TextLimit then
              raise EAVM2Error.Create('AVM2 XML size limit');
          end;
          Exit(TAVM2Value.Str(Builder.ToString));
        finally
          Builder.Free;
        end;
      end;
  end;
  Nodes := TList<IXMLNode>.Create;
  try
    for Node in Obj.XMLNodes do
      if Node.NodeType = ntElement then
        if Method in [axAttribute, axAttributes] then
        begin
          List := Node.AttributeNodes;
          for var I := 0 to List.Count - 1 do
            if (Method = axAttributes) or (Name = '*') or (List[I].LocalName = Name) then
              Nodes.Add(List[I]);
        end
        else
          SelectChildren(Node, 0);
    Result := XMLValue(Obj.XMLDocument, Nodes.ToArray, True);
  finally
    Nodes.Free;
  end;
end;

procedure TAVM2Runtime.InstallSharedObject(EventDispatcher: TAVM2Object);
const
  Methods: array[TAVM2SharedMethod] of string = ('getLocal', 'flush', 'clear', 'setProperty', 'setDirty');
var
  Method: TAVM2SharedMethod;
  Native, Owner: TAVM2Object;
begin
  FSharedObjects := TDictionary<string, TAVM2Object>.Create;
  FSharedObjectClass := NewObject(a2Class);
  FSharedObjectClass.Parent := EventDispatcher;
  FSharedObjectClass.CanDispatch := True;
  FSharedObjectClass.DisplayName := 'flash.net.SharedObject';
  FNative.Props.Add('flash.net' + #0 + 'SharedObject', TAVM2Value.Ref(FSharedObjectClass));
  for Method := Low(TAVM2SharedMethod) to High(TAVM2SharedMethod) do
  begin
    Owner := ClassPrototype(FSharedObjectClass);
    if Method = asGetLocal then
      Owner := FSharedObjectClass;
    Native := NewObject(a2Function);
    Native.Index := SharedMethodBase - Ord(Method);
    Owner.Props.Add(#0 + Methods[Method], TAVM2Value.Ref(Native));
  end;
  Native := NewObject(a2Class);
  Native.DisplayName := 'flash.net.SharedObjectFlushStatus';
  Native.Props.Add(#0 + 'FLUSHED', TAVM2Value.Str('flushed'));
  Native.Props.Add(#0 + 'PENDING', TAVM2Value.Str('pending'));
  FNative.Props.Add('flash.net' + #0 + 'SharedObjectFlushStatus', TAVM2Value.Ref(Native));
end;

function TAVM2Runtime.EncodeSharedObject(Data: TAVM2Object): TBytes;
var
  Stream: TMemoryStream;
  Seen: TDictionary<TAVM2Object, Cardinal>;

  procedure WriteByte(Value: Byte);
  begin
    Stream.WriteBuffer(Value, SizeOf(Value));
  end;

  procedure WriteUInt(Value: Cardinal);
  begin
    Stream.WriteBuffer(Value, SizeOf(Value));
  end;

  procedure WriteText(const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.UTF8.GetBytes(Text);
    if Length(Bytes) > SharedDataLimit - Stream.Size - SizeOf(Cardinal) then
      RaiseScriptError('Error', 0, 'SharedObject data exceeds the local storage limit.');
    WriteUInt(Length(Bytes));
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  end;

  procedure WriteValue(const Value: TAVM2Value; Depth: Integer);
  var
    Obj: TAVM2Object;
    ID, Count: Cardinal;
    Entry: TAVM2DynamicProperty;
    Element: TPair<Cardinal, TAVM2Value>;
    Member: TAVM2Value;
  begin
    if (Depth >= 64) or (Stream.Size > SharedDataLimit - 16) then
      RaiseScriptError('Error', 0, 'SharedObject data exceeds the local storage limit.');
    if (Value.Obj <> nil) and (Value.Obj.Kind <> a2PlainObject) then
    begin
      WriteByte(Ord(a2Undefined));
      Exit;
    end;
    WriteByte(Ord(Value.Kind));
    case Value.Kind of
      a2Boolean, a2Int, a2UInt, a2Number:
        Stream.WriteBuffer(Value.Number, SizeOf(Double));
      a2String:
        WriteText(Value.Text);
      a2Object:
        begin
          Obj := Value.Obj;
          if Seen.TryGetValue(Obj, ID) then
          begin
            WriteUInt(ID);
            Exit;
          end;
          if Seen.Count >= SharedGraphLimit then
            RaiseScriptError('Error', 0, 'SharedObject contains too many objects.');
          ID := Seen.Count;
          Seen.Add(Obj, ID);
          WriteUInt(ID);
          WriteByte(Ord(Obj.ArrayData <> nil));
          if Obj.ArrayData <> nil then
          begin
            if (Obj.ArrayData.ArrayLength > SharedItemLimit) or (Obj.ArrayData.Elements.Count > SharedItemLimit) then
              RaiseScriptError('Error', 0, 'SharedObject array size limit.');
            WriteUInt(Obj.ArrayData.ArrayLength);
            WriteUInt(Obj.ArrayData.Elements.Count);
            for Element in Obj.ArrayData.Elements do
            begin
              WriteUInt(Element.Key);
              WriteValue(Element.Value, Depth + 1);
            end;
          end;
          Count := 0;
          if Obj.DynamicProperties <> nil then
            for Entry in Obj.DynamicProperties do
              if Entry.Enumerable and StartsStr(#0, Entry.Key) and Obj.Props.ContainsKey(Entry.Key) then
                Inc(Count);
          if Count > SharedItemLimit then
            RaiseScriptError('Error', 0, 'SharedObject property count limit.');
          WriteUInt(Count);
          if Count > 0 then
            for Entry in Obj.DynamicProperties do
              if Entry.Enumerable and StartsStr(#0, Entry.Key) and Obj.Props.TryGetValue(Entry.Key, Member) then
              begin
                WriteText(Copy(Entry.Key, 2, MaxInt));
                WriteValue(Member, Depth + 1);
              end;
        end;
    end;
  end;

begin
  Stream := TMemoryStream.Create;
  Seen := TDictionary<TAVM2Object, Cardinal>.Create;
  try
    WriteUInt(SharedDataSignature);
    WriteValue(TAVM2Value.Ref(Data), 0);
    SetLength(Result, Stream.Size);
    Move(Stream.Memory^, Result[0], Length(Result));
  finally
    Seen.Free;
    Stream.Free;
  end;
end;

function TAVM2Runtime.DecodeSharedObject(const Data: TBytes): TAVM2Object;
var
  Stream: TBytesStream;
  Seen: TList<TAVM2Object>;
  Value: TAVM2Value;

  function ReadByte: Byte;
  begin
    Stream.ReadBuffer(Result, SizeOf(Result));
  end;

  function ReadUInt: Cardinal;
  begin
    Stream.ReadBuffer(Result, SizeOf(Result));
  end;

  function ReadText: string;
  var
    Size: Cardinal;
    Bytes: TBytes;
  begin
    Size := ReadUInt;
    if Size > Stream.Size - Stream.Position then
      raise EReadError.Create('Invalid SharedObject string.');
    SetLength(Bytes, Size);
    if Size > 0 then
      Stream.ReadBuffer(Bytes[0], Size);
    Result := TEncoding.UTF8.GetString(Bytes);
  end;

  function ReadValue(Depth: Integer): TAVM2Value;
  var
    Kind, Shape: Byte;
    Obj: TAVM2Object;
    ID, Count, Index, Extent: Cardinal;
    Key: string;
    Number: Double;
    Item: TAVM2Value;
  begin
    if Depth >= 64 then
      raise EReadError.Create('Invalid SharedObject nesting.');
    Kind := ReadByte;
    if Kind > Byte(Ord(High(TAVM2ValueKind))) then
      raise EReadError.Create('Invalid SharedObject type.');
    Result := Default(TAVM2Value);
    Result.Kind := TAVM2ValueKind(Kind);
    case Result.Kind of
      a2Boolean, a2Int, a2UInt, a2Number:
        begin
          Stream.ReadBuffer(Number, SizeOf(Number));
          Result.Number := Number;
        end;
      a2String:
        Result.Text := ReadText;
      a2Object:
        begin
          ID := ReadUInt;
          if ID < Cardinal(Seen.Count) then
            Exit(TAVM2Value.Ref(Seen[ID]));
          if (ID <> Cardinal(Seen.Count)) or (ID >= SharedGraphLimit) then
            raise EReadError.Create('Invalid SharedObject reference.');
          Shape := ReadByte;
          if Shape = 1 then
            Obj := Construct(FArrayClass, nil)
          else if Shape = 0 then
          begin
            Obj := NewObject(a2PlainObject, True);
            Obj.ClassObject := FObjectClass;
          end
          else
            raise EReadError.Create('Invalid SharedObject object shape.');
          Seen.Add(Obj);
          if Shape = 1 then
          begin
            Extent := ReadUInt;
            Count := ReadUInt;
            if (Extent > SharedItemLimit) or (Count > Extent) then
              raise EReadError.Create('Invalid SharedObject array.');
            SetArrayLength(Obj.ArrayData, Extent);
            while Count > 0 do
            begin
              Index := ReadUInt;
              if Index >= Extent then
                raise EReadError.Create('Invalid SharedObject array index.');
              Item := ReadValue(Depth + 1);
              SetArrayElement(Obj.ArrayData, Index, Item);
              Dec(Count);
            end;
          end;
          Count := ReadUInt;
          if Count > SharedItemLimit then
            raise EReadError.Create('Invalid SharedObject property count.');
          while Count > 0 do
          begin
            Key := #0 + ReadText;
            Item := ReadValue(Depth + 1);
            StoreDynamicProperty(Obj, Key, Item);
            Dec(Count);
          end;
          Result := TAVM2Value.Ref(Obj);
        end;
    end;
  end;

begin
  Result := nil;
  if (Length(Data) < 5) or (Length(Data) > SharedDataLimit) then
    Exit;
  Stream := TBytesStream.Create(Data);
  Seen := TList<TAVM2Object>.Create;
  try
    try
      if ReadUInt = SharedDataSignature then
      begin
        Value := ReadValue(0);
        if (Value.Obj <> nil) and (Value.Obj.ArrayData = nil) and (Stream.Position = Stream.Size) then
          Result := Value.Obj;
      end;
    except
      on E: EReadError do
        Result := nil;
    end;
  finally
    Seen.Free;
    Stream.Free;
  end;
end;

function TAVM2Runtime.SharedObjectCall(Method: TAVM2SharedMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Obj, Data: TAVM2Object;
  Name, LocalPath, Key: string;
  Value: TAVM2Value;
  Bytes: TBytes;
begin
  Result := Default(TAVM2Value);
  if Method = asGetLocal then
  begin
    if Length(Args) = 0 then
      RaiseScriptError('ArgumentError', 1063, 'SharedObject.getLocal requires a name.');
    Name := CoerceText(Args[0]);
    if (Name = '') or (Pos(#0, Name) > 0) then
      RaiseScriptError('ArgumentError', 2004, 'Invalid SharedObject name.');
    LocalPath := FMovieURL;
    if (Length(Args) > 1) and not (Args[1].Kind in [a2Null, a2Undefined]) then
      LocalPath := CoerceText(Args[1]);
    if (Length(Args) > 2) and Truth(Args[2]) and not StartsText('https://', FMovieURL) then
      RaiseScriptError('SecurityError', 0, 'A secure SharedObject requires an HTTPS origin.');
    Key := LocalPath + #0 + Name;
    if not FSharedObjects.TryGetValue(Key, Obj) then
    begin
      if FSharedObjects.Count >= 256 then
        raise EAVM2Error.Create('AVM2 SharedObject count limit');
      Obj := NewObject(a2PlainObject);
      Obj.ClassObject := FSharedObjectClass;
      Obj.Parent := ClassPrototype(FSharedObjectClass);
      Obj.DisplayName := FSharedObjectClass.DisplayName;
      BindDispatcher(Obj);
      Obj.SharedKey := Key;
      Data := nil;
      if Assigned(FReadSharedObject) and FReadSharedObject(FMovieURL, Key, Bytes) then
        Data := DecodeSharedObject(Bytes);
      if Data = nil then
      begin
        Data := NewObject(a2PlainObject, True);
        Data.ClassObject := FObjectClass;
      end;
      Obj.Props.Add(#0 + 'data', TAVM2Value.Ref(Data));
      FSharedObjects.Add(Key, Obj);
    end;
    Exit(TAVM2Value.Ref(Obj));
  end;
  if (Receiver = nil) or not Receiver.Props.TryGetValue(#0 + 'data', Value) or
    not ClassHasType(Receiver.ClassObject, FSharedObjectClass) then
    RaiseScriptError('TypeError', 1004, 'Incompatible SharedObject receiver.');
  Data := Value.Obj;
  case Method of
    asFlush:
      begin
        if Assigned(FWriteSharedObject) and
          not FWriteSharedObject(FMovieURL, Receiver.SharedKey, EncodeSharedObject(Data)) then
          RaiseScriptError('Error', 0, 'SharedObject could not be written.');
        Result := TAVM2Value.Str('flushed');
      end;
    asClear:
      begin
        if Assigned(FWriteSharedObject) and not FWriteSharedObject(FMovieURL, Receiver.SharedKey, nil) then
          RaiseScriptError('Error', 0, 'SharedObject could not be cleared.');
        Data.Props.Clear;
        if Data.DynamicIndices <> nil then
          Data.DynamicIndices.Clear;
        if Data.DynamicProperties <> nil then
          Data.DynamicProperties.Clear;
      end;
    asSetProperty:
      begin
        if Length(Args) = 0 then
          RaiseScriptError('ArgumentError', 1063, 'SharedObject.setProperty requires a name.');
        Value := TAVM2Value.Ref(nil);
        if Length(Args) > 1 then
          Value := Args[1];
        StoreDynamicProperty(Data, #0 + CoerceText(Args[0]), Value);
      end;
  end;
end;

procedure TAVM2Runtime.InstallURLClasses(EventDispatcher: TAVM2Object);
var
  Value, Native, Prototype: TAVM2Object;
  Method: TAVM2URLMethod;

  function NetClass(const Name: string; Parent: TAVM2Object): TAVM2Object;
  begin
    Result := NewObject(a2Class);
    Result.Parent := Parent;
    Result.CanDispatch := Parent.CanDispatch;
    Result.DisplayName := 'flash.net.' + Name;
    FNative.Props.Add('flash.net' + #0 + Name, TAVM2Value.Ref(Result));
  end;

begin
  FURLLoads := TList<TAVM2URLLoad>.Create;
  FURLRequestClass := NetClass('URLRequest', FObjectClass);
  FURLVariablesClass := NetClass('URLVariables', FObjectClass);
  FURLLoaderClass := NetClass('URLLoader', EventDispatcher);
  Value := NetClass('URLRequestMethod', FObjectClass);
  Value.Props.Add(#0 + 'GET', TAVM2Value.Str('GET'));
  Value.Props.Add(#0 + 'POST', TAVM2Value.Str('POST'));
  Value := NetClass('URLLoaderDataFormat', FObjectClass);
  Value.Props.Add(#0 + 'TEXT', TAVM2Value.Str('text'));
  Value.Props.Add(#0 + 'BINARY', TAVM2Value.Str('binary'));
  Value.Props.Add(#0 + 'VARIABLES', TAVM2Value.Str('variables'));
  for Method := auLoad to auEncode do
  begin
    if Method in [auDecode, auEncode] then
      Prototype := ClassPrototype(FURLVariablesClass)
    else
      Prototype := ClassPrototype(FURLLoaderClass);
    Native := NewObject(a2Function);
    Native.Index := URLMethodBase - Ord(Method);
    Prototype.Props.Add(#0 + URLMethods[Method], TAVM2Value.Ref(Native));
  end;
end;

procedure TAVM2Runtime.DecodeVariables(Receiver: TAVM2Object; const Text: string);
var
  Separator: Integer;
begin
  for var Pair in Text.Split(['&']) do
  begin
    if Pair = '' then
      Continue;
    Separator := Pos('=', Pair);
    if Separator = 0 then
      RaiseScriptError('Error', 2101, 'Invalid URLVariables encoding.');
    StoreDynamicProperty(Receiver, #0 + TNetEncoding.URL.Decode(Copy(Pair, 1, Separator - 1)),
      TAVM2Value.Str(TNetEncoding.URL.Decode(Copy(Pair, Separator + 1, MaxInt))));
  end;
end;

function TAVM2Runtime.URLCall(Method: TAVM2URLMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Request, Info: TAVM2Object;
  Load: TAVM2URLLoad;
  Builder: TStringBuilder;
  PendingBytes: Int64;
  IsDisplayLoader: Boolean;
begin
  Result := Default(TAVM2Value);
  if Receiver = nil then
    RaiseScriptError('TypeError', 1004, 'Incompatible URL method receiver.');
  if Method in [auDecode, auEncode] then
  begin
    if not ClassHasType(Receiver.ClassObject, FURLVariablesClass) then
      RaiseScriptError('TypeError', 1004, 'Incompatible URLVariables receiver.');
    if Method = auDecode then
    begin
      if Length(Args) = 0 then
        RaiseScriptError('ArgumentError', 1063, 'URLVariables.decode requires a string.');
      DecodeVariables(Receiver, CoerceText(Args[0]));
    end
    else
    begin
      Builder := TStringBuilder.Create;
      try
        if Receiver.DynamicProperties <> nil then
          for var Entry in Receiver.DynamicProperties do
            if Entry.Enumerable and Receiver.Props.ContainsKey(Entry.Key) then
            begin
              if Builder.Length > 0 then
                Builder.Append('&');
              Builder.Append(TNetEncoding.URL.Encode(Copy(Entry.Key, 2, MaxInt)));
              Builder.Append('=');
              Builder.Append(TNetEncoding.URL.Encode(CoerceText(Receiver.Props[Entry.Key])));
              if Builder.Length > TextLimit then
                raise EAVM2Error.Create('AVM2 URLVariables text limit');
            end;
        Result := TAVM2Value.Str(Builder.ToString);
      finally
        Builder.Free;
      end;
    end;
    Exit;
  end;
  IsDisplayLoader := ClassHasType(Receiver.ClassObject, FLoaderClass);
  if not IsDisplayLoader and ((Method in [auLoadBytes..auUnloadAndStop]) or
    not ClassHasType(Receiver.ClassObject, FURLLoaderClass)) then
    RaiseScriptError('TypeError', 1004, 'Incompatible loader receiver.');
  if Method = auClose then
  begin
    Receiver.URLTicket := 0;
    Exit;
  end;
  Info := nil;
  if IsDisplayLoader then
    Info := Receiver.Props[#0 + 'contentLoaderInfo'].Obj;
  if Method in [auUnload, auUnloadAndStop] then
  begin
    Receiver.URLTicket := 0;
    UnloadContent(Receiver, Info, Method = auUnloadAndStop);
    Exit;
  end;
  if FURLLoads.Count >= 64 then
    raise EAVM2Error.Create('AVM2 URLLoader queue limit');
  Load := Default(TAVM2URLLoad);
  if Method = auLoadBytes then
  begin
    if Length(Args) = 0 then
      RaiseScriptError('ArgumentError', 1063, 'Loader.loadBytes requires a ByteArray.');
    Request := CoerceValue(Args[0], atClass, FByteArrayClass, 'flash.utils.ByteArray').Obj;
    if Request = nil then
      RaiseScriptError('TypeError', 2007, 'ByteArray must be non-null.');
    if Length(Args) > 1 then
      CoerceValue(Args[1], atClass, FLoaderContextClass, 'flash.system.LoaderContext');
    PendingBytes := Request.ByteArrayData.Size;
    for var Pending in FURLLoads do
      Inc(PendingBytes, Length(Pending.Bytes));
    if PendingBytes > ByteArrayTotalLimit then
      raise EAVM2Error.Create('AVM2 loader byte queue limit');
    Load.FromBytes := True;
    Load.Bytes := Copy(Request.ByteArrayData.Buffer, 0, Request.ByteArrayData.Size);
    Load.URL := FMovieURL;
  end
  else
  begin
    if Length(Args) = 0 then
      RaiseScriptError('ArgumentError', 1063, 'URLLoader.load requires a URLRequest.');
    Request := CoerceValue(Args[0], atClass, FURLRequestClass, 'flash.net.URLRequest').Obj;
    if Request = nil then
      RaiseScriptError('TypeError', 2007, 'URLRequest must be non-null.');
    Load.URL := CoerceText(Request.Props[#0 + 'url']);
    Load.Method := CoerceText(Request.Props[#0 + 'method']);
  end;
  Inc(FURLSerial);
  Load.Loader := Receiver;
  Load.Ticket := FURLSerial;
  Receiver.URLTicket := Load.Ticket;
  if Info = nil then
  begin
    Receiver.Props[#0 + 'data'] := Default(TAVM2Value);
    Receiver.Props[#0 + 'bytesLoaded'] := TAVM2Value.Num(0, a2UInt);
    Receiver.Props[#0 + 'bytesTotal'] := TAVM2Value.Num(0, a2UInt);
  end
  else
    Info.Props.AddOrSetValue(#0 + 'url', TAVM2Value.Str(Load.URL));
  FURLLoads.Add(Load);
end;

procedure TAVM2Runtime.DispatchStreamError(Info: TAVM2Object);
var
  Event: TAVM2Object;
begin
  Event := HostEventObject(FIOErrorEventClass, 'ioError', False, False);
  Event.Props.Add(#0 + 'text', TAVM2Value.Str('Error #2032: Stream Error.'));
  Event.Props.Add(#0 + 'errorID', TAVM2Value.Num(2032, a2Int));
  DispatchEventTo(Info, Event, False);
end;

procedure TAVM2Runtime.UnloadContent(Loader, Info: TAVM2Object; Stop: Boolean);
var
  Content: TAVM2Object;
begin
  Content := Loader.Props[#0 + 'content'].Obj;
  Loader.Props[#0 + 'content'] := TAVM2Value.Ref(nil);
  Info.Props[#0 + 'content'] := TAVM2Value.Ref(nil);
  Info.Props[#0 + 'bytesLoaded'] := TAVM2Value.Num(0, a2UInt);
  Info.Props[#0 + 'bytesTotal'] := TAVM2Value.Num(0, a2UInt);
  if Content = nil then
    Exit;
  if Stop and (FDisplay <> nil) then
    FDisplay.StopTimeline(Content.DisplayData);
  if Content.DisplayParent = Loader then
    DisplayCall(adRemoveChild, Loader, [TAVM2Value.Ref(Content)]);
  DispatchEventTo(Info, HostEventObject(FEnterFrameClass, 'unload', False, False), False);
end;

procedure TAVM2Runtime.DeliverTimelineLoad(const Load: TAVM2URLLoad; Info: TAVM2Object);
var
  MovieInfo: TAVM2LoadedMovie;
  Display: TObject;
  Content, Event, Loader: TAVM2Object;
  ByteCount: TAVM2Value;
begin
  Loader := Load.Loader;
  DispatchEventTo(Info, HostEventObject(FEnterFrameClass, 'open', False, False), False);
  if Loader.URLTicket <> Load.Ticket then
    Exit;
  Display := nil;
  if FDisplay <> nil then
    Display := FDisplay.LoadTimeline(Load.Bytes, MovieInfo);
  if Display = nil then
  begin
    Loader.URLTicket := 0;
    DispatchStreamError(Info);
    Exit;
  end;
  Content := Construct(FNative.Props['flash.display' + #0 + 'MovieClip'].Obj, nil, Display);
  ByteCount := TAVM2Value.Num(Length(Load.Bytes), a2UInt);
  Info.Props[#0 + 'bytesLoaded'] := ByteCount;
  Info.Props[#0 + 'bytesTotal'] := ByteCount;
  Info.Props.AddOrSetValue(#0 + 'width', TAVM2Value.Num(MovieInfo.Width, a2Int));
  Info.Props.AddOrSetValue(#0 + 'height', TAVM2Value.Num(MovieInfo.Height, a2Int));
  Info.Props.AddOrSetValue(#0 + 'swfVersion', TAVM2Value.Num(MovieInfo.Version, a2UInt));
  Info.Props.AddOrSetValue(#0 + 'frameRate', TAVM2Value.Num(MovieInfo.FrameRate));
  Info.Props.AddOrSetValue(#0 + 'actionScriptVersion', TAVM2Value.Num(3, a2UInt));
  Info.Props.AddOrSetValue(#0 + 'contentType', TAVM2Value.Str('application/x-shockwave-flash'));
  Content.Props[#0 + 'loaderInfo'] := TAVM2Value.Ref(Info);
  Loader.Props[#0 + 'content'] := TAVM2Value.Ref(Content);
  Info.Props[#0 + 'content'] := TAVM2Value.Ref(Content);
  DisplayCall(adAddChild, Loader, [TAVM2Value.Ref(Content)]);
  if Loader.URLTicket <> Load.Ticket then
    Exit;
  Event := HostEventObject(FNative.Props['flash.events' + #0 + 'ProgressEvent'].Obj, 'progress', False, False);
  Event.Props.Add(#0 + 'bytesLoaded', ByteCount);
  Event.Props.Add(#0 + 'bytesTotal', ByteCount);
  DispatchEventTo(Info, Event, False);
  if Loader.URLTicket <> Load.Ticket then
    Exit;
  DispatchEventTo(Info, HostEventObject(FEnterFrameClass, 'init', False, False), False);
  if Loader.URLTicket <> Load.Ticket then
    Exit;
  Loader.URLTicket := 0;
  DispatchEventTo(Info, HostEventObject(FEnterFrameClass, 'complete', False, False), False);
end;

procedure TAVM2Runtime.DeliverURLLoads;
var
  Loads: TArray<TAVM2URLLoad>;
  Loader, Content, Info: TAVM2Object;
  Data: TBytes;
  Resolved, FormatName: string;
  Loaded: Boolean;
begin
  if FURLLoads.Count = 0 then
    Exit;
  Loads := FURLLoads.ToArray;
  FURLLoads.Clear;
  for var Load in Loads do
  begin
    Loader := Load.Loader;
    if Loader.URLTicket <> Load.Ticket then
      Continue;
    Data := nil;
    Loaded := False;
    Info := Loader;
    if ClassHasType(Loader.ClassObject, FLoaderClass) then
    begin
      Info := Loader.Props[#0 + 'contentLoaderInfo'].Obj;
      UnloadContent(Loader, Info, True);
      if Loader.URLTicket <> Load.Ticket then
        Continue;
    end;
    if Load.FromBytes then
    begin
      DeliverTimelineLoad(Load, Info);
      Continue;
    end;
    if (Info = Loader) and Assigned(FReadResource) and SameText(Load.Method, 'GET') and
      (Pos(':', Load.URL) = 0) and (Load.URL <> '') then
    try
      Loaded := FReadResource(FMovieURL, Load.URL, Data, Resolved) and (Length(Data) <= ByteArraySizeLimit);
    except
      on E: EInOutError do
        Loaded := False;
    end;
    if not Loaded then
    begin
      Loader.URLTicket := 0;
      DispatchStreamError(Info);
      Continue;
    end;
    DispatchEventTo(Loader, HostEventObject(FEnterFrameClass, 'open', False, False), False);
    if Loader.URLTicket <> Load.Ticket then
      Continue;
    Loader.Props[#0 + 'bytesLoaded'] := TAVM2Value.Num(Length(Data), a2UInt);
    Loader.Props[#0 + 'bytesTotal'] := TAVM2Value.Num(Length(Data), a2UInt);
    FormatName := CoerceText(Loader.Props[#0 + 'dataFormat']);
    if FormatName = 'binary' then
    begin
      Content := Construct(FByteArrayClass, nil);
      ResizeByteArray(Content.ByteArrayData, Length(Data));
      if Length(Data) > 0 then
        Move(Data[0], Content.ByteArrayData.Buffer[0], Length(Data));
      Loader.Props[#0 + 'data'] := TAVM2Value.Ref(Content);
    end
    else if FormatName = 'variables' then
      Loader.Props[#0 + 'data'] := TAVM2Value.Ref(Construct(FURLVariablesClass,
            [TAVM2Value.Str(TEncoding.UTF8.GetString(Data))]))
    else
      Loader.Props[#0 + 'data'] := TAVM2Value.Str(TEncoding.UTF8.GetString(Data));
    Loader.URLTicket := 0;
    DispatchEventTo(Loader, HostEventObject(FEnterFrameClass, 'complete', False, False), False);
  end;
end;

function TAVM2Runtime.ConnectionCall(Method: TAVM2ConnectionMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Name: string;
  Message: TAVM2ConnectionMessage;
begin
  Result := Default(TAVM2Value);
  if (Receiver = nil) or not Receiver.IsLocalConnection then
    RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
  if Method in [acAllowDomain, acAllowInsecureDomain] then
    Exit; // The registry is confined to this movie's runtime.
  if Method = acClose then
  begin
    if Receiver.ConnectionName = '' then
      RaiseScriptError('ArgumentError', 2083, 'LocalConnection is not connected.');
    FLocalConnections.Remove(Receiver.ConnectionName);
    Receiver.ConnectionName := '';
    Exit;
  end;
  if Length(Args) < (1 + Ord(Method = acSend)) then
    RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for LocalConnection.');
  if Args[0].Kind in [a2Undefined, a2Null] then
    RaiseScriptError('TypeError', 2007, 'Connection name must be non-null.');
  Name := CoerceText(Args[0]);
  if (Name = '') or (Length(Name) > 1024) then
    RaiseScriptError('ArgumentError', 2082, 'Invalid LocalConnection name.');
  if Method = acConnect then
  begin
    if (Receiver.ConnectionName <> '') or FLocalConnections.ContainsKey(Name) then
      RaiseScriptError('ArgumentError', 2082, 'LocalConnection name is already in use.');
    FLocalConnections.Add(Name, Receiver);
    Receiver.ConnectionName := Name;
    Exit;
  end;
  if Args[1].Kind in [a2Undefined, a2Null] then
    RaiseScriptError('TypeError', 2007, 'Method name must be non-null.');
  Message.Method := CoerceText(Args[1]);
  if (Message.Method = '') or MatchStr(Message.Method,
    ['connect', 'close', 'send', 'allowDomain', 'allowInsecureDomain', 'client', 'domain']) then
    RaiseScriptError('ArgumentError', 2004, 'Invalid LocalConnection method.');
  if FConnectionMessages.Count >= 256 then
    raise EAVM2Error.Create('AVM2 LocalConnection queue limit');
  Message.Sender := Receiver;
  Message.Channel := Name;
  Message.Arguments := Copy(Args, 2, Length(Args) - 2);
  FConnectionMessages.Add(Message);
end;

procedure TAVM2Runtime.DeliverConnectionMessages;
var
  Messages: TArray<TAVM2ConnectionMessage>;
  Message: TAVM2ConnectionMessage;
  Target, Event: TAVM2Object;
  Client, Callback: TAVM2Value;
  Level: string;
begin
  if FConnectionMessages.Count = 0 then
    Exit;
  Messages := FConnectionMessages.ToArray;
  FConnectionMessages.Clear;
  for Message in Messages do
  begin
    Level := 'error';
    if FLocalConnections.TryGetValue(Message.Channel, Target) then
    begin
      Client := Target.Props[#0 + 'client'];
      Callback := Default(TAVM2Value);
      if Client.Obj <> nil then
        Callback := ReadProperty(Client, [#0 + Message.Method], True);
      if (Callback.Obj <> nil) and (Callback.Obj.Kind = a2Function) then
      begin
        Invoke(Callback.Obj, Client, Message.Arguments);
        Level := 'status';
      end;
    end;
    if HasListener(Message.Sender, 'status', False) then
    begin
      Event := HostEventObject(FStatusEventClass, 'status', False, False);
      Event.Props.Add(#0 + 'code', TAVM2Value.Str(''));
      Event.Props.Add(#0 + 'level', TAVM2Value.Str(Level));
      DispatchEventTo(Message.Sender, Event, False);
    end;
  end;
end;

procedure TAVM2Runtime.InstallTimers(EventDispatcher, EventClass: TAVM2Object);
var
  Method: TAVM2TimerMethod;
  Native, TimerPrototype, EventPrototype: TAVM2Object;
begin
  FTimerClass := NewObject(a2Class);
  FTimerClass.Parent := EventDispatcher;
  FTimerClass.CanDispatch := True;
  FTimerClass.DisplayName := 'Timer';
  FNative.Props.Add('flash.utils' + #0 + 'Timer', TAVM2Value.Ref(FTimerClass));
  TimerPrototype := ClassPrototype(FTimerClass);
  FTimerEventClass := NewObject(a2Class);
  FTimerEventClass.Parent := EventClass;
  FTimerEventClass.DisplayName := 'TimerEvent';
  FTimerEventClass.EventKind := aeTimer;
  FNative.Props.Add('flash.events' + #0 + 'TimerEvent', TAVM2Value.Ref(FTimerEventClass));
  FTimerEventClass.Props.Add(#0 + 'TIMER', TAVM2Value.Str('timer'));
  FTimerEventClass.Props.Add(#0 + 'TIMER_COMPLETE', TAVM2Value.Str('timerComplete'));
  EventPrototype := ClassPrototype(FTimerEventClass);
  for Method := Low(TAVM2TimerMethod) to High(TAVM2TimerMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := TimerMethodBase - Ord(Method);
    case Method of
      tmStart..tmReset:
        TimerPrototype.Props.Add(#0 + TimerNames[Method], TAVM2Value.Ref(Native));
      tmGetTimer..tmClearTimeout:
        FNative.Props.Add('flash.utils' + #0 + TimerNames[Method], TAVM2Value.Ref(Native));
      tmCloneEvent..tmUpdateAfterEvent:
        EventPrototype.Props.Add(#0 + TimerNames[Method], TAVM2Value.Ref(Native));
    end;
  end;
end;

function TimerInterval(Delay: Double): Integer;
begin
  if IsNan(Delay) or (Delay < 10) then
    Exit(10);
  if Delay >= MaxInt then
    Exit(MaxInt);
  Result := Trunc(Delay);
end;

function TAVM2Runtime.AddTimer(Owner, Callback: TAVM2Object; Delay: Double; Once: Boolean; const Args: TArray<TAVM2Value>): Integer;
var
  Call: TAVM2TimedCall;
begin
  if (FTimers.Count >= FunctionArgumentLimit) or (FTimerSerial = MaxInt) then
    raise EAVM2Error.Create('AVM2 timer limit');
  Inc(FTimerSerial);
  Call.Id := FTimerSerial;
  Call.Interval := TimerInterval(Delay);
  Call.Due := FMilliseconds + Call.Interval;
  Call.Owner := Owner;
  Call.Callback := Callback;
  Call.Args := Args;
  Call.Once := Once;
  FTimers.Add(Call);
  Result := Call.Id;
end;

function TAVM2Runtime.FindTimer(Id: Integer): Integer;
var
  I: Integer;
begin
  if Id <= 0 then
    Exit(-1);
  for I := 0 to FTimers.Count - 1 do
  begin
    Dec(FWork);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    if FTimers[I].Id = Id then
      Exit(I);
  end;
  Result := -1;
end;

procedure TAVM2Runtime.RemoveTimer(Id: Integer);
var
  Index: Integer;
  Owner: TAVM2Object;
begin
  Index := FindTimer(Id);
  if Index < 0 then
    Exit;
  Owner := FTimers[Index].Owner;
  if (Owner <> nil) and (Owner.TimerID = Id) then
  begin
    Owner.TimerID := 0;
    Owner.Props[#0 + 'running'] := TAVM2Value.Num(0, a2Boolean);
  end;
  FTimers.Delete(Index);
end;

procedure TAVM2Runtime.SetTimerDelay(Receiver: TAVM2Object; Delay: Double);
var
  Index: Integer;
  Call: TAVM2TimedCall;
begin
  if IsNan(Delay) or IsInfinite(Delay) or (Delay < 0) then
    RaiseScriptError('RangeError', 2066, 'The Timer delay specified is out of range.');
  Index := FindTimer(Receiver.TimerID);
  Receiver.Props.AddOrSetValue(#0 + 'delay', TAVM2Value.Num(Delay));
  if Index >= 0 then
  begin
    Call := FTimers[Index];
    Call.Interval := TimerInterval(Delay);
    Call.Due := FMilliseconds + Call.Interval;
    FTimers[Index] := Call;
  end;
end;

function TAVM2Runtime.TimerCall(Method: TAVM2TimerMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Callback: TAVM2Object;
  Delay: Double;
  EventType, Bubbles, Cancelable: TAVM2Value;
begin
  Result := Default(TAVM2Value);
  case Method of
    tmStart..tmReset:
      begin
        if (Receiver = nil) or not Receiver.IsTimer then
          RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
        case Method of
          tmStart:
            if Receiver.TimerID = 0 then
            begin
              Receiver.TimerID := AddTimer(Receiver, nil, Receiver.Props[#0 + 'delay'].Number, False, nil);
              Receiver.Props[#0 + 'running'] := TAVM2Value.Num(1, a2Boolean);
            end;
          tmStop, tmReset:
            begin
              RemoveTimer(Receiver.TimerID);
              if Method = tmReset then
                Receiver.Props[#0 + 'currentCount'] := TAVM2Value.Num(0, a2Int);
            end;
        end;
      end;
    tmGetTimer:
      Result := TAVM2Value.Num(Integer(IntBits(FMilliseconds)), a2Int);
    tmSetInterval, tmSetTimeout:
      begin
        if Length(Args) < 2 then
          RaiseScriptError('ArgumentError', 1063, TimerNames[Method] + ' requires a function and a delay.');
        Callback := CoerceValue(Args[0], atFunction, nil, 'Function').Obj;
        Delay := CoerceNumber(Args[1]);
        Result := TAVM2Value.Num(AddTimer(nil, Callback, Delay, Method = tmSetTimeout,
            Copy(Args, 2, MaxInt)), a2Int);
      end;
    tmClearInterval, tmClearTimeout:
      if Length(Args) > 0 then
        RemoveTimer(Integer(IntBits(CoerceNumber(Args[0]))));
    tmCloneEvent, tmEventText, tmUpdateAfterEvent:
      begin
        if (Receiver = nil) or (Receiver.EventKind <> aeTimer) then
          RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
        EventType := Receiver.Props[#0 + 'type'];
        Bubbles := Receiver.Props[#0 + 'bubbles'];
        Cancelable := Receiver.Props[#0 + 'cancelable'];
        case Method of
          tmCloneEvent:
            Result := TAVM2Value.Ref(Construct(FTimerEventClass, [EventType, Bubbles, Cancelable]));
          tmEventText:
            Result := TAVM2Value.Str('[TimerEvent type="' + EventType.Text +
              '" bubbles=' + AsText(Bubbles) + ' cancelable=' + AsText(Cancelable) +
              ' eventPhase=' + AsText(Receiver.Props[#0 + 'eventPhase']) + ']');
        end;
      end;
  end;
end;

procedure TAVM2Runtime.RunTimers(Milliseconds: Int64);
var
  I, Next, Fired, Count, RepeatCount: Integer;
  Call: TAVM2TimedCall;
  Owner: TAVM2Object;
begin
  DeliverSoundComplete;
  DeliverConnectionMessages;
  DeliverURLLoads;
  FMilliseconds := Milliseconds;
  for Fired := 1 to 10 do
  begin
    Next := -1;
    Dec(FWork, FTimers.Count);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    for I := 0 to FTimers.Count - 1 do
      if (FTimers[I].Due <= FMilliseconds) and ((Next < 0) or (FTimers[I].Due < FTimers[Next].Due)) then
        Next := I;
    if Next < 0 then
      Exit;
    Call := FTimers[Next];
    if Call.Once then
      FTimers.Delete(Next)
    else
    begin
      // A callback may remove the timer or set a different deadline.
      Inc(Call.Due, Call.Interval);
      FTimers[Next] := Call;
    end;
    Owner := Call.Owner;
    if Owner <> nil then
    begin
      Count := Integer(IntBits(Owner.Props[#0 + 'currentCount'].Number + 1));
      Owner.Props[#0 + 'currentCount'] := TAVM2Value.Num(Count, a2Int);
      DispatchEventTo(Owner, HostEventObject(FTimerEventClass, 'timer', False, False), False);
      Count := Trunc(Owner.Props[#0 + 'currentCount'].Number);
      RepeatCount := Trunc(Owner.Props[#0 + 'repeatCount'].Number);
      if (RepeatCount <> 0) and (Count >= RepeatCount) then
      begin
        RemoveTimer(Owner.TimerID);
        DispatchEventTo(Owner, HostEventObject(FTimerEventClass, 'timerComplete', False, False), False);
      end;
    end
    else
    begin
      if Call.Callback = nil then
        RaiseScriptError('TypeError', 1009, 'Cannot access a property or method of a null object reference.');
      if Truth(Invoke(Call.Callback, TAVM2Value.Ref(nil), Call.Args)) then
        RemoveTimer(Call.Id);
    end;
  end;
end;

function TAVM2Runtime.NewObject(Kind: TAVM2ObjectKind; HostManaged: Boolean): TAVM2Object;
var
  Owner: TObjectList<TAVM2Object>;
  Limit: Integer;
begin
  if HostManaged then
  begin
    Owner := FHostObjects;
    Limit := TemporaryObjectLimit;
  end
  else
  begin
    Owner := FObjects;
    Limit := ObjectLimit;
  end;
  if Owner.Count >= Limit then
    raise EAVM2Error.Create('AVM2 object limit');
  if HostManaged and (FDeadHostCount <> 0) and (Owner.Count >= Limit - FDeadHostCount) then
    ReclaimHostObjects(FDeadHostCount);
  Result := TAVM2Object.Create(Kind);
  Owner.Add(Result);
  Result.HostManaged := HostManaged;
  if HostManaged then
    Inc(FNewHostObjects);
  if Kind = a2Function then
  begin
    Result.ClassObject := FFunctionClass;
    Result.Parent := FFunctionPrototype;
  end
  else if Kind in [a2PlainObject, a2Script] then
    Result.Parent := FObjectPrototype;
end;

function TAVM2Runtime.Key(Module: TAVM2Module; NamespaceIndex: Integer; const Name: string): string;
var
  Namespace: TABCNamespace;
begin
  Namespace := Module.ABC.Namespaces[NamespaceIndex];
  case Namespace.Kind of
    0, 8, $16:
      Result := Module.ABC.Strings[Namespace.Name];
    5:
      Result := '#private:' + IntToStr(Module.Id) + ':' + IntToStr(NamespaceIndex);
  else
    Result := '#' + IntToStr(Namespace.Kind) + ':' + Module.ABC.Strings[Namespace.Name];
  end;
  Result := Result + #0 + Name;
end;

function TAVM2Runtime.NamespaceSetKeys(Module: TAVM2Module; SetIndex: Integer; const Name: string): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(Module.ABC.NamespaceSets[SetIndex]));
  for I := 0 to High(Result) do
    Result[I] := Key(Module, Module.ABC.NamespaceSets[SetIndex][I], Name);
end;

function TAVM2Runtime.Names(Module: TAVM2Module; Index: Integer): TArray<string>;
var
  Name: TABCMultiname;
  LocalName: string;
begin
  if (Index <= 0) or (Index >= Length(Module.ABC.Multinames)) then
    raise EAVM2Error.Create('AVM2 multiname index outside pool');
  Result := Module.StaticNames[Index];
  if Length(Result) <> 0 then
    Exit;
  Name := Module.ABC.Multinames[Index];
  LocalName := Module.ABC.Strings[Name.Name];
  if Name.Name = 0 then
    LocalName := '*';
  if Name.Kind in [$0D, $0E] then
    LocalName := '@' + LocalName;
  case Name.Kind of
    7, $0D:
      Result := [Key(Module, Name.NamespaceIndex, LocalName)];
    9, $0E:
      Result := NamespaceSetKeys(Module, Name.NamespaceSet, LocalName);
  else
    raise EAVM2Error.CreateFmt('AVM2 multiname kind $%.2x is not executable yet', [Name.Kind]);
  end;
  Module.StaticNames[Index] := Result;
end;

function TAVM2Runtime.TraitKey(Module: TAVM2Module; Index: Integer): string;
begin
  if Module.ABC.Multinames[Index].Kind <> 7 then
    raise EAVM2Error.Create('AVM2 trait requires a QName');
  if Module.ABC.Multinames[Index].Name = 0 then
    Result := Key(Module, Module.ABC.Multinames[Index].NamespaceIndex, '')
  else
    Result := Names(Module, Index)[0];
end;

function TAVM2Runtime.ConstantValue(Module: TAVM2Module; Index: Integer; Kind: Byte): TAVM2Value;
var
  Obj: TAVM2Object;
begin
  Result := Default(TAVM2Value);
  case Kind of
    0:
      ;
    1:
      Result := TAVM2Value.Str(Module.ABC.Strings[Index]);
    3:
      Result := TAVM2Value.Num(Module.ABC.Ints[Index], a2Int);
    4:
      Result := TAVM2Value.Num(Module.ABC.UInts[Index], a2UInt);
    6:
      Result := TAVM2Value.Num(Module.ABC.Doubles[Index]);
    $0A, $0B:
      Result := TAVM2Value.Num(Ord(Kind = $0B), a2Boolean);
    $0C:
      Result.Kind := a2Null;
    5, 8, $16..$1A:
      begin
        Obj := Module.NamespaceObjects[Index];
        if Obj = nil then
        begin
          Obj := NewObject(a2PlainObject);
          Obj.ClassObject := FNamespaceClass;
          Obj.DisplayName := FNamespaceClass.DisplayName;
          Obj.Parent := ClassPrototype(FNamespaceClass);
          Obj.HasNamespaceURI := True;
          Obj.NamespaceURI := Module.ABC.Strings[Module.ABC.Namespaces[Index].Name];
          Obj.Props.Add(#0 + 'uri', TAVM2Value.Str(Obj.NamespaceURI));
          if Obj.NamespaceURI = '' then
            Obj.Props.Add(#0 + 'prefix', TAVM2Value.Str(''))
          else
            Obj.Props.Add(#0 + 'prefix', Default(TAVM2Value));
          Module.NamespaceObjects[Index] := Obj;
        end;
        Result := TAVM2Value.Ref(Obj);
      end;
  else
    raise EAVM2Error.Create('Unsupported AVM2 constant kind');
  end;
end;

procedure TAVM2Runtime.StoreSlot(Target: TAVM2Object; const Name: string; const Value: TAVM2Value);
var
  SlotType: TPair<TAVM2Module, Integer>;
  Types: TDictionary<string, TPair<TAVM2Module, Integer>>;
  ClassObject: TAVM2Object;
  Kind: TAVM2TypeKind;
  TypeName: string;
begin
  Types := Target.SlotTypes;
  if Target.DeclaredSlots <> nil then
    Types := Target.DeclaredSlots.Types;
  if (Types <> nil) and Types.TryGetValue(Name, SlotType) then
  begin
    Kind := ResolveType(SlotType.Key, SlotType.Value, ClassObject, TypeName);
    Target.Props.AddOrSetValue(Name, CoerceValue(Value, Kind, ClassObject, TypeName));
  end
  else
    Target.Props.AddOrSetValue(Name, Value);
  if Target.Kind = a2Script then
    Inc(FDefinitionGeneration);
end;

function TAVM2Runtime.InitialSlotValue(Module: TAVM2Module; const Trait: TABCTrait): TAVM2Value;
var
  NamesToTry: TArray<string>;
  Name: string;
begin
  if (Trait.Value <> 0) or (Trait.Target = 0) then
    Exit(ConstantValue(Module, Trait.Value, Trait.ValueKind));

  if Module.ABC.Multinames[Trait.Target].Kind = $1D then
    Exit(TAVM2Value.Ref(nil));
  NamesToTry := Names(Module, Trait.Target);
  for Name in NamesToTry do
  begin
    if Name = #0 + 'int' then
      Exit(TAVM2Value.Num(0, a2Int));
    if Name = #0 + 'uint' then
      Exit(TAVM2Value.Num(0, a2UInt));
    if Name = #0 + 'Boolean' then
      Exit(TAVM2Value.Num(0, a2Boolean));
    if Name = #0 + 'Number' then
      Exit(TAVM2Value.Num(NaN));
  end;
  Result := TAVM2Value.Ref(nil);
end;

procedure TAVM2Runtime.AddTraits(Target: TAVM2Object; Module: TAVM2Module; const Traits: TArray<TABCTrait>; Activation: Boolean);
var
  Trait: TABCTrait;
  Name: string;
  Slot: Integer;
  Method, DeclaringClass: TAVM2Object;
  Value: TAVM2Value;
  Accessor: TAVM2Accessor;
  Shared: Boolean;
begin
  for Trait in Traits do
  begin
    Name := TraitKey(Module, Trait.Name);
    Value := Default(TAVM2Value);
    case Trait.Kind of
      0, 6:
        Value := InitialSlotValue(Module, Trait);
      1..3, 5:
        begin
          DeclaringClass := Target.ClassObject;
          if Target.Kind = a2Class then
            DeclaringClass := Target;
          Shared := (Trait.Kind in [1..3]) and (Target.Kind = a2PlainObject) and
            not Activation and (DeclaringClass <> nil) and (DeclaringClass.Module = Module);
          Method := nil;
          if Shared then
          begin
            if DeclaringClass.TraitMethods = nil then
              DeclaringClass.TraitMethods := TDictionary<Integer, TAVM2Object>.Create;
            DeclaringClass.TraitMethods.TryGetValue(Trait.Target, Method);
          end;
          if Method = nil then
          begin
            Method := NewObject(a2Function, Target.HostManaged and not Shared);
            Method.Module := Module;
            Method.Index := Trait.Target;
            Method.NeedsMethodReceiver := Shared;
            if Shared then
              DeclaringClass.TraitMethods.Add(Trait.Target, Method)
            else if Trait.Kind <> 5 then
              Method.BoundReceiver := TAVM2Value.Ref(Target);
            if Trait.Kind = 5 then
              InitializeFunctionPrototype(Method);
            Method.Script := Target.Script;
            Method.Scope := Target.Scope;
            Method.ClassObject := DeclaringClass;
          end;
          if Trait.Kind in [2, 3] then
          begin
            Target.Props.TryGetValue(Name, Value);
            if Target.Accessors = nil then
              Target.Accessors := TDictionary<string, TAVM2Accessor>.Create;
            if not Target.Accessors.TryGetValue(Name, Accessor) then
              Accessor := Default(TAVM2Accessor);
            if Trait.Kind = 2 then
              Accessor.Getter := Method
            else
              Accessor.Setter := Method;
            Target.Accessors.AddOrSetValue(Name, Accessor);
          end
          else
            Value := TAVM2Value.Ref(Method);
        end;
    end;
    Target.Props.AddOrSetValue(Name, Value);
    if (Target.DeclaredSlots = nil) and (Trait.Kind in [0, 4, 5, 6]) then
    begin
      if Target.Slots = nil then
        Target.Slots := TDictionary<Integer, string>.Create;
      Slot := Trait.Slot;
      if Slot = 0 then
      begin
        Slot := 1;
        while Target.Slots.ContainsKey(Slot) do
          Inc(Slot);
      end;
      Target.Slots.AddOrSetValue(Slot, Name);
      if (Trait.Kind in [0, 6]) and (Trait.Target <> 0) and
        (Activation or (Module.ABC.Multinames[Trait.Target].Kind = $1D)) then
      begin
        if Target.SlotTypes = nil then
          Target.SlotTypes := TDictionary<string, TPair<TAVM2Module, Integer>>.Create;
        Target.SlotTypes.AddOrSetValue(Name, TPair<TAVM2Module, Integer>.Create(Module, Trait.Target));
      end;
    end;
  end;
end;

procedure TAVM2Runtime.LoadABC(TagId: Integer; const Data: TBytes; Lazy: Boolean);
var
  Module: TAVM2Module;
  Script: TAVM2Object;
  Trait: TABCTrait;
  I: Integer;
  Name: string;
begin
  if FLoadedTags.ContainsKey(TagId) then
    Exit;
  if FModules.Count >= 1024 then
    raise EAVM2Error.Create('AVM2 module limit');
  Module := TAVM2Module.Create(Data, FModules.Count);
  FModules.Add(Module);
  Inc(FDefinitionGeneration);
  if Length(Module.Scripts) = 0 then
    raise EAVM2Error.Create('ABC has no script entry point');
  for I := 0 to High(Module.Scripts) do
  begin
    Script := NewObject(a2Script);
    Script.Module := Module;
    Script.Index := I;
    Script.Script := Script;
    Script.Scope := [TAVM2Value.Ref(Script)];
    Module.Scripts[I] := Script;
    for Trait in Module.ABC.Scripts[I].Traits do
    begin
      Name := TraitKey(Module, Trait.Name);
      if not FDefinitions.ContainsKey(Name) then
        FDefinitions.Add(Name, Script);
    end;
  end;
  FLoadedTags.Add(TagId, True);
  if not Lazy then
    Initialize(Module.Scripts[High(Module.Scripts)]);
end;

procedure TAVM2Runtime.Initialize(Script: TAVM2Object);
begin
  if Script.State <> 0 then
    Exit;
  Script.State := 1;
  AddTraits(Script, Script.Module, Script.Module.ABC.Scripts[Script.Index].Traits);
  Execute(Script.Module, Script.Module.ABC.Scripts[Script.Index].Init, TAVM2Value.Ref(Script), Script, nil, nil, []);
  Script.State := 2;
end;

procedure TAVM2Runtime.RaiseScriptError(const ClassName: string; Code: Integer; const Detail: string);
var
  ErrorClass: TAVM2Object;
begin
  if Pos(#0, ClassName) > 0 then
    ErrorClass := FNative.Props[ClassName].Obj
  else
    ErrorClass := FNative.Props[#0 + ClassName].Obj;
  raise EAVM2Thrown.Create(TAVM2Value.Ref(Construct(ErrorClass, [TAVM2Value.Str(Format('Error #%d: %s', [Code, Detail])), TAVM2Value.Num(Code, a2Int)])));
end;

function TAVM2Runtime.Find(Module: TAVM2Module; Index: Integer; Script: TAVM2Object; const Scope, Outer: TArray<TAVM2Value>; ScopeCount: Integer; Op: Byte; out FoundValue: PAVM2Value): TAVM2Object;
var
  Candidates: TArray<string>;
  Name: string;
  I: Integer;
begin
  FoundValue := nil;
  Candidates := Names(Module, Index);
  if Length(Candidates) = 1 then
  begin
    Name := Candidates[0];
    for I := ScopeCount - 1 downto 0 do
      if Scope[I].Obj <> nil then
      begin
        FoundValue := Scope[I].Obj.Props.FindHinted(Name, Module.PropertyHints[Index]);
        if FoundValue <> nil then
          Exit(Scope[I].Obj);
      end;
    for I := High(Outer) downto 0 do
      if Outer[I].Obj <> nil then
      begin
        FoundValue := Outer[I].Obj.Props.FindHinted(Name, Module.PropertyHints[Index]);
        if FoundValue <> nil then
          Exit(Outer[I].Obj);
      end;
  end
  else
  begin
    for I := ScopeCount - 1 downto 0 do
      if Scope[I].Obj <> nil then
        for Name in Candidates do
          if Scope[I].Obj.Props.ContainsKey(Name) then
            Exit(Scope[I].Obj);
    for I := High(Outer) downto 0 do
      if Outer[I].Obj <> nil then
        for Name in Candidates do
          if Outer[I].Obj.Props.ContainsKey(Name) then
            Exit(Outer[I].Obj);
  end;
  for Name in Candidates do
  begin
    if FDefinitions.TryGetValue(Name, Result) then
    begin
      Initialize(Result);
      Exit;
    end;
    if FNative.Props.ContainsKey(Name) then
      Exit(FNative);
  end;
  if Op <> $5F then
  begin
    for I := ScopeCount - 1 downto 0 do
      if Scope[I].Obj <> nil then
        for Name in Candidates do
          if HasProperty(Scope[I].Obj, Name) then
            Exit(Scope[I].Obj);
    for I := High(Outer) downto 0 do
      if Outer[I].Obj <> nil then
        for Name in Candidates do
          if HasProperty(Outer[I].Obj, Name) then
            Exit(Outer[I].Obj);
  end;
  Name := Module.ABC.Strings[Module.ABC.Multinames[Index].Name];
  if Op in [$5D, $60] then
    RaiseScriptError('ReferenceError', 1065, 'Variable ' + Name + ' is not defined.')
  else if Op = $5F then
    raise EAVM2Error.Create('Unresolved AVM2 definition ' + Name);
  Result := Script;
end;

procedure TAVM2Runtime.InstallFunctionClass(ObjectClass: TAVM2Object);
var
  Native: TAVM2Object;
begin
  FFunctionClass := NewObject(a2Class);
  FFunctionClass.Parent := ObjectClass;
  FFunctionClass.DisplayName := 'Function';
  FFunctionPrototype.ClassObject := FFunctionClass;
  FFunctionPrototype.DisplayName := 'Function';
  InitializeFunctionPrototype(FFunctionPrototype);
  FFunctionClass.InstancePrototype := FFunctionPrototype;
  FFunctionPrototype.Props.Add(#0 + 'constructor', TAVM2Value.Ref(FFunctionClass));
  FNative.Props.Add(#0 + 'Function', TAVM2Value.Ref(FFunctionClass));
  Native := NewObject(a2Function);
  Native.Index := FunctionCallMethod;
  FFunctionPrototype.Props.Add(#0 + 'call', TAVM2Value.Ref(Native));
  FFunctionPrototype.Props.Add(BuiltinNamespace + 'call', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := FunctionApplyMethod;
  FFunctionPrototype.Props.Add(#0 + 'apply', TAVM2Value.Ref(Native));
  FFunctionPrototype.Props.Add(BuiltinNamespace + 'apply', TAVM2Value.Ref(Native));
end;

function TAVM2Runtime.ForwardFunction(Func: TAVM2Object; const Args: TArray<TAVM2Value>; UseArray: Boolean): TAVM2Value;
var
  ThisValue: TAVM2Value;
  Passed: TArray<TAVM2Value>;
  Data: TAVM2Array;
  I: Integer;
begin
  if (Func = nil) or (Func.Kind <> a2Function) then
    RaiseScriptError('TypeError', 1006, 'value is not a function.');
  if FForwardDepth >= 128 then
    raise EAVM2Error.Create('AVM2 function forwarding depth limit');
  ThisValue := Default(TAVM2Value);
  if Length(Args) > 0 then
    ThisValue := Args[0];
  if not UseArray then
    Passed := Copy(Args, 1, MaxInt)
  else if (Length(Args) > 1) and not (Args[1].Kind in [a2Null, a2Undefined]) then
  begin
    if (Args[1].Kind <> a2Object) or (Args[1].Obj.ArrayData = nil) then
      RaiseScriptError('TypeError', 1116, 'second argument to Function.prototype.apply must be an array.');
    Data := Args[1].Obj.ArrayData;
    if Data.ArrayLength > FunctionArgumentLimit then
      raise EAVM2Error.Create('AVM2 function argument limit');
    SetLength(Passed, Integer(Data.ArrayLength));
    for I := 0 to High(Passed) do
      TryArrayElement(Data, Cardinal(I), Passed[I]);
  end;
  Dec(FWork, Length(Passed) + 1);
  if FWork < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');
  Inc(FForwardDepth);
  try
    Result := Invoke(Func, ThisValue, Passed);
  finally
    Dec(FForwardDepth);
  end;
end;

procedure TAVM2Runtime.InstallArrayClass(ObjectClass: TAVM2Object);
var
  Method: TAVM2ArrayMethod;
begin
  FArrayClass := NewObject(a2Class);
  FArrayClass.Parent := ObjectClass;
  FArrayClass.DisplayName := 'Array';
  FNative.Props.Add(#0 + 'Array', TAVM2Value.Ref(FArrayClass));
  FArrayClass.Props.Add(#0 + 'CASEINSENSITIVE', TAVM2Value.Num(SortCaseInsensitive, a2UInt));
  FArrayClass.Props.Add(#0 + 'DESCENDING', TAVM2Value.Num(SortDescending, a2UInt));
  FArrayClass.Props.Add(#0 + 'UNIQUESORT', TAVM2Value.Num(SortUnique, a2UInt));
  FArrayClass.Props.Add(#0 + 'RETURNINDEXEDARRAY', TAVM2Value.Num(SortReturnIndices, a2UInt));
  FArrayClass.Props.Add(#0 + 'NUMERIC', TAVM2Value.Num(SortNumeric, a2UInt));
  FArrayPrototype := NewObject(a2PlainObject);
  FArrayPrototype.ClassObject := FArrayClass;
  FArrayPrototype.DisplayName := 'Array';
  FArrayPrototype.ArrayData := TAVM2Array.Create;
  FArrayClass.InstancePrototype := FArrayPrototype;
  FArrayPrototype.Props.Add(#0 + 'constructor', TAVM2Value.Ref(FArrayClass));
  for Method := Low(TAVM2ArrayMethod) to High(TAVM2ArrayMethod) do
  begin
    FArrayMethods[Method] := NewObject(a2Function);
    FArrayMethods[Method].Index := ArrayMethodBase - Ord(Method);
    FArrayPrototype.Props.Add(#0 + ArrayMethods[Method], TAVM2Value.Ref(FArrayMethods[Method]));
    FArrayPrototype.Props.Add(BuiltinNamespace + ArrayMethods[Method], TAVM2Value.Ref(FArrayMethods[Method]));
  end;
end;

function TAVM2Runtime.ArrayLengthValue(const Value: TAVM2Value): Cardinal;
var
  Number: Double;
begin
  Number := AsNumber(Value);
  if IsNan(Number) or (Number < 0) or (Number > High(Cardinal)) or (Frac(Number) <> 0) then
    RaiseScriptError('RangeError', 1005, 'Array index is not a positive integer.');
  Result := Cardinal(Trunc(Number));
end;

procedure TAVM2Runtime.SetArrayLength(Data: TAVM2Array; LengthValue: Cardinal);
var
  Index: Cardinal;
  Keys: TArray<Cardinal>;
begin
  if LengthValue < Data.ArrayLength then
  begin
    Keys := Data.Elements.Keys.ToArray;
    for Index in Keys do
      if Index >= LengthValue then
        RemoveArrayElement(Data, Index);
  end;
  Data.ArrayLength := LengthValue;
end;

procedure TAVM2Runtime.SetArrayElement(Data: TAVM2Array; Index: Cardinal; const Value: TAVM2Value);
var
  IsNew: Boolean;
begin
  IsNew := not Data.Elements.ContainsKey(Index);
  if IsNew and (FArrayElements >= ArrayElementLimit) then
    raise EAVM2Error.Create('AVM2 Array storage limit');
  Data.Elements.AddOrSetValue(Index, Value);
  if IsNew then
  begin
    Inc(FArrayElements);
    Data.OrderedKeys := nil;
  end;
  if Index >= Data.ArrayLength then
    Data.ArrayLength := Index + 1;
end;

procedure TAVM2Runtime.RemoveArrayElement(Data: TAVM2Array; Index: Cardinal);
begin
  if not Data.Elements.ContainsKey(Index) then
    Exit;
  Data.Elements.Remove(Index);
  Data.OrderedKeys := nil;
  Dec(FArrayElements);
end;

procedure TAVM2Runtime.AppendArray(Data: TAVM2Array; const Args: array of TAVM2Value; First: Integer);
var
  Count: Integer;
begin
  Count := Max(0, Length(Args) - First);
  if UInt64(Data.ArrayLength) + UInt64(Count) > High(Cardinal) then
    RaiseScriptError('RangeError', 1005, 'Array index is not a positive integer.');
  if Count > ArrayElementLimit - FArrayElements then
    raise EAVM2Error.Create('AVM2 Array storage limit');
  for var Index := First to High(Args) do
    SetArrayElement(Data, Data.ArrayLength, Args[Index]);
end;

function ClampArrayIndex(Number: Double; LengthValue: Cardinal): Cardinal;
begin
  if IsNan(Number) then
    Exit(0);
  if Number >= LengthValue then
    Exit(LengthValue);
  if Number <= -Double(LengthValue) then
    Exit(0);
  if Number < 0 then
    Exit(Cardinal(Int64(LengthValue) + Trunc(Number)));
  Result := Cardinal(Trunc(Number));
end;

procedure TAVM2Runtime.ShiftArrayKeys(Data: TAVM2Array; Delta: Int64);
var
  Updated: TDictionary<Cardinal, TAVM2Value>;
  Entry: TPair<Cardinal, TAVM2Value>;
  Shifted: Int64;
begin
  Updated := TDictionary<Cardinal, TAVM2Value>.Create;
  try
    for Entry in Data.Elements do
    begin
      Shifted := Int64(Entry.Key) + Delta;
      if Shifted >= 0 then
        Updated.Add(Cardinal(Shifted), Entry.Value);
    end;
    Dec(FArrayElements, Data.Elements.Count - Updated.Count);
    Data.Elements.Free;
    Data.Elements := Updated;
    Data.OrderedKeys := nil;
    Updated := nil;
  finally
    Updated.Free;
  end;
end;

procedure TAVM2Runtime.ReverseArray(Data: TAVM2Array);
var
  Updated: TDictionary<Cardinal, TAVM2Value>;
  Entry: TPair<Cardinal, TAVM2Value>;
  LastIndex: Cardinal;
begin
  if Data.Elements.Count = 0 then
    Exit;
  LastIndex := 0;
  for Entry in Data.Elements do
    if Entry.Key > LastIndex then
      LastIndex := Entry.Key;
  Updated := TDictionary<Cardinal, TAVM2Value>.Create;
  try
    for Entry in Data.Elements do
      Updated.Add(LastIndex - Entry.Key, Entry.Value);
    Data.Elements.Free;
    Data.Elements := Updated;
    Data.OrderedKeys := nil;
    Updated := nil;
  finally
    Updated.Free;
  end;
end;

function TAVM2Runtime.SliceArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  First, Last, Index: Cardinal;
  Target: TAVM2Object;
  Value: TAVM2Value;
begin
  First := 0;
  Last := Data.ArrayLength;
  if Length(Args) > 0 then
    First := ClampArrayIndex(AsNumber(Args[0]), Data.ArrayLength);
  if Length(Args) > 1 then
    Last := ClampArrayIndex(AsNumber(Args[1]), Data.ArrayLength);
  if Last < First then
    Last := First;
  if Last - First > Cardinal(ArrayElementLimit - FArrayElements) then
    raise EAVM2Error.Create('AVM2 Array storage limit');

  Target := Construct(FArrayClass, nil);
  Index := First;
  while Index < Last do
  begin
    TryArrayElement(Data, Index, Value);
    SetArrayElement(Target.ArrayData, Index - First, Value);
    Inc(Index);
  end;
  Result := TAVM2Value.Ref(Target);
end;

function TAVM2Runtime.SpliceArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  First, Last, RemoveCount, InsertCount, Index, LengthValue: Cardinal;
  DeleteArgument: Integer;
  NewLength: UInt64;
  Entry: TPair<Cardinal, TAVM2Value>;
  Kept: TDictionary<Cardinal, TAVM2Value>;
  Removed: TAVM2Object;
  Value: TAVM2Value;
  I, PrefixCount: Integer;
begin
  if Length(Args) = 0 then
    Exit(Default(TAVM2Value));
  First := ClampArrayIndex(AsNumber(Args[0]), Data.ArrayLength);
  RemoveCount := Data.ArrayLength - First;
  if Length(Args) > 1 then
  begin
    DeleteArgument := Integer(IntBits(AsNumber(Args[1])));
    if DeleteArgument < 0 then
      RemoveCount := 0
    else if Cardinal(DeleteArgument) < RemoveCount then
      RemoveCount := Cardinal(DeleteArgument);
  end;
  InsertCount := Cardinal(Max(0, Length(Args) - 2));
  Last := First + RemoveCount;
  NewLength := UInt64(Data.ArrayLength) - RemoveCount + InsertCount;
  if NewLength > High(Cardinal) then
    RaiseScriptError('RangeError', 1005, 'Array index is not a positive integer.');
  LengthValue := Cardinal(NewLength);

  PrefixCount := 0;
  for Entry in Data.Elements do
    if Entry.Key < First then
      Inc(PrefixCount);
  if UInt64(Data.ArrayLength - First) + InsertCount + UInt64(PrefixCount) >
    UInt64(ArrayElementLimit - FArrayElements + Data.Elements.Count) then
    raise EAVM2Error.Create('AVM2 Array storage limit');

  Removed := Construct(FArrayClass, nil);
  Kept := TDictionary<Cardinal, TAVM2Value>.Create;
  try
    for Entry in Data.Elements do
      if Entry.Key < First then
        Kept.Add(Entry.Key, Entry.Value);
    Index := First;
    while Index < Last do
    begin
      TryArrayElement(Data, Index, Value);
      Removed.ArrayData.Elements.Add(Index - First, Value);
      Inc(Index);
    end;
    for I := 2 to High(Args) do
      Kept.Add(First + Cardinal(I - 2), Args[I]);
    Index := Last;
    while Index < Data.ArrayLength do
    begin
      TryArrayElement(Data, Index, Value);
      Kept.Add(First + InsertCount + (Index - Last), Value);
      Inc(Index);
    end;
    Inc(FArrayElements, Kept.Count + Removed.ArrayData.Elements.Count - Data.Elements.Count);
    Data.Elements.Free;
    Data.Elements := Kept;
    Data.OrderedKeys := nil;
    Kept := nil;
    Data.ArrayLength := LengthValue;
    Removed.ArrayData.ArrayLength := RemoveCount;
  finally
    Kept.Free;
  end;
  Result := TAVM2Value.Ref(Removed);
end;

function TAVM2Runtime.SearchArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>; Backwards: Boolean): Integer;
var
  Wanted: TAVM2Value;
  Start, Match: Int64;
  Entry: TPair<Cardinal, TAVM2Value>;
  Level: TAVM2Array;

  procedure Consider(Index: Cardinal; const Value: TAVM2Value);
  begin
    if Index >= Data.ArrayLength then
      Exit;
    if Backwards then
    begin
      if (Index > Start) or (Index <= Match) then
        Exit;
    end
    else if (Index < Start) or ((Match >= 0) and (Index >= Match)) then
      Exit;
    if Equal(Wanted, Value, True) then
      Match := Index;
  end;

begin
  Wanted := Default(TAVM2Value);
  if Length(Args) > 0 then
    Wanted := Args[0];
  if Backwards then
    Start := High(Integer)
  else
    Start := 0;
  if Length(Args) > 1 then
    Start := Integer(IntBits(AsNumber(Args[1])));
  if Start < 0 then
  begin
    Inc(Start, Data.ArrayLength);
    if Start < 0 then
      Start := 0;
  end;
  Match := -1;
  for Entry in Data.Elements do
    Consider(Entry.Key, Entry.Value);
  Level := Data.Prototype;
  if Level <> nil then
    for Entry in Level.Elements do
      if not Data.Elements.ContainsKey(Entry.Key) then
        Consider(Entry.Key, Entry.Value);
  Result := Integer(Match);
end;

function TAVM2Runtime.ArrayCallback(Command: TAVM2ArrayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Callback, Output: TAVM2Object;
  ThisValue: TAVM2Value;
  Index, LengthAtStart: Cardinal;
  CallbackArgs: TArray<TAVM2Value>;
  Element, Returned: TAVM2Value;
begin
  if Length(Args) = 0 then
    RaiseScriptError('ArgumentError', 1063, 'Array callback method requires a function argument.');
  Callback := CoerceValue(Args[0], atFunction, nil, 'Function').Obj;
  Result := Default(TAVM2Value);
  Output := nil;
  case Command of
    aaMap, aaFilter:
      begin
        Output := Construct(FArrayClass, nil);
        Result := TAVM2Value.Ref(Output);
      end;
    aaEvery, aaSome:
      Result := TAVM2Value.Num(Ord(Command = aaEvery), a2Boolean);
  end;
  if Callback = nil then
    Exit;

  ThisValue := Default(TAVM2Value);
  if Length(Args) > 1 then
    ThisValue := Args[1];

  Index := 0;
  LengthAtStart := Receiver.ArrayData.ArrayLength;
  SetLength(CallbackArgs, 3);
  CallbackArgs[2] := TAVM2Value.Ref(Receiver);
  while Index < LengthAtStart do
  begin
    Dec(FWork);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    // A callback can change future elements, including inherited properties.
    TryArrayElement(Receiver.ArrayData, Index, Element);
    CallbackArgs[0] := Element;
    CallbackArgs[1] := TAVM2Value.Num(Index, a2UInt);
    Returned := Invoke(Callback, ThisValue, CallbackArgs);
    case Command of
      aaMap:
        SetArrayElement(Output.ArrayData, Index, Returned);
      aaFilter:
        if Truth(Returned) then
          SetArrayElement(Output.ArrayData, Output.ArrayData.ArrayLength, Element);
      aaEvery:
        if not Truth(Returned) then
          Exit(TAVM2Value.Num(0, a2Boolean));
      aaSome:
        if Truth(Returned) then
          Exit(TAVM2Value.Num(1, a2Boolean));
    end;
    Inc(Index);
  end;
end;

type
  TAVM2SortValue = record
    Index: Cardinal;
    Value: TAVM2Value;
  end;

function TAVM2Runtime.SortCollection(Receiver: TAVM2Object; const Args: TArray<TAVM2Value>; ByFields: Boolean): TAVM2Value;
var
  Data, ParameterArray: TAVM2Array;
  Callback, IndexArray: TAVM2Object;
  Values: TArray<TAVM2SortValue>;
  FieldNames: TArray<TArray<string>>;
  FieldOptions: TArray<Cardinal>;
  Updated: TDictionary<Cardinal, TAVM2Value>;
  Value: TAVM2Value;
  Options: Cardinal;
  I, Count: Integer;
  Unique, IsVector: Boolean;

  function ReadArrayValue(Obj: TAVM2Object; Index: Integer): TAVM2Value;
  begin
    Result := PropertyValue(Obj, [#0 + IntToStr(Index)]);
  end;

  function ArrayParameterCount(A: TAVM2Array): Integer;
  begin
    if A.ArrayLength > ArrayElementLimit then
      raise EAVM2Error.Create('AVM2 Array sort size limit');
    Result := Integer(A.ArrayLength);
    Dec(FWork, Result);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
  end;

  function OldInteger(const Item: TAVM2Value): Boolean;
  begin
    Result := (Item.Kind in [a2Int, a2UInt, a2Number]) and
      (Item.Number >= -268435456.0) and (Item.Number < 268435456.0) and
      (Frac(Item.Number) = 0);
  end;

  function CompareValuesForSort(const A, B: TAVM2Value; Flags: Cardinal): Integer;
  var
    L, R: Double;
    LText, RText: string;
    K: Integer;
  begin
    if Flags and SortNumeric <> 0 then
    begin
      if (FSWFVersion < 11) and OldInteger(A) and OldInteger(B) then
      begin
        Result := Integer(Cardinal((UInt64(IntBits(A.Number) shl 3) + UInt64($100000000) -
            UInt64(IntBits(B.Number) shl 3)) and UInt64($FFFFFFFF)));
      end
      else
      begin
        L := CoerceNumber(A);
        R := CoerceNumber(B);
        if IsNan(L) or IsNan(R) then
          Result := Ord(IsNan(L)) - Ord(IsNan(R))
        else
          Result := Ord(L > R) - Ord(L < R);
      end;
    end
    else
    begin
      LText := CoerceText(A);
      RText := CoerceText(B);
      Dec(FWork, 1 + (Length(LText) + Length(RText)) div 8);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      if Flags and SortCaseInsensitive <> 0 then
      begin
        UniqueString(LText);
        UniqueString(RText);
        for K := 1 to Length(LText) do
          LText[K] := LText[K].ToLower;
        for K := 1 to Length(RText) do
          RText[K] := RText[K].ToLower;
      end;
      Result := CompareStr(LText, RText);
    end;
    Result := Ord(Result > 0) - Ord(Result < 0);
    if Flags and SortDescending <> 0 then
      Result := -Result;
  end;

  function Compare(const A, B: TAVM2Value): Integer;
  var
    K: Integer;
    P, Q: TAVM2Value;
    Order: Double;
  begin
    Dec(FWork);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    if not IsVector and ((A.Kind = a2Undefined) or (B.Kind = a2Undefined)) then
      Result := Ord(A.Kind = a2Undefined) - Ord(B.Kind = a2Undefined)
    else if ByFields then
    begin
      Result := 0;
      for K := 0 to High(FieldNames) do
      begin
        Dec(FWork);
        if FWork < 0 then
          raise EAVM2Error.Create('AVM2 instruction limit');
        if (A.Kind = a2Null) or (B.Kind = a2Null) then
          RaiseScriptError('TypeError', 1009, 'Cannot access a property or method of a null object reference.');
        P := ReadProperty(A, FieldNames[K], False);
        Q := ReadProperty(B, FieldNames[K], False);
        Result := CompareValuesForSort(P, Q, FieldOptions[K]);
        if Result <> 0 then
          Break;
      end;
    end
    else if Callback <> nil then
    begin
      Order := CoerceNumber(Invoke(Callback, Receiver, [A, B]));
      if not IsVector and (FSWFVersion < 13) then
        Order := Integer(IntBits(Order));
      if IsNan(Order) then
        Result := 0
      else
        Result := Ord(Order > 0) - Ord(Order < 0);
      if Options and SortDescending <> 0 then
        Result := -Result;
    end
    else
      Result := CompareValuesForSort(A, B, Options);
    if Result = 0 then
      Unique := False;
  end;

  procedure Swap(Left, Right: Integer);
  var
    Saved: TAVM2SortValue;
  begin
    Saved := Values[Left];
    Values[Left] := Values[Right];
    Values[Right] := Saved;
  end;

  procedure SortRange(First, After: Integer);
  var
    Left, Right: Integer;
  begin
    // Keep Flash's partition and comparison order, including equal elements.
    // Recurse only into the smaller partition to bound the stack depth.
    while After - First > 3 do
    begin
      Swap(First, First + (After - First) div 2);
      Left := First;
      Right := After;
      repeat
        repeat
          Inc(Left)
        until (Left = After) or (Compare(Values[Left].Value, Values[First].Value) > 0);
        repeat
          Dec(Right)
        until (Right = First) or (Compare(Values[Right].Value, Values[First].Value) < 0);
        if Right < Left then
          Break;
        Swap(Left, Right);
      until False;
      Swap(First, Right);
      if Right - First < After - Left then
      begin
        SortRange(First, Right);
        First := Left;
      end
      else
      begin
        SortRange(Left, After);
        After := Right;
      end;
    end;
    if After - First < 2 then
      Exit;
    if Compare(Values[First].Value, Values[First + 1].Value) > 0 then
      Swap(First, First + 1);
    if (After - First = 3) and (Compare(Values[First + 1].Value, Values[First + 2].Value) > 0) then
    begin
      Swap(First + 1, First + 2);
      if Compare(Values[First].Value, Values[First + 1].Value) > 0 then
        Swap(First, First + 1);
    end;
  end;

begin
  Data := Receiver.ArrayData;
  IsVector := Receiver.VectorData <> nil;
  Callback := nil;
  Options := 0;
  if ByFields then
  begin
    if Length(Args) = 0 then
      RaiseScriptError('ArgumentError', 1063, 'Array.sortOn requires a field name.');
    if (Args[0].Obj <> nil) and (Args[0].Obj.ArrayData <> nil) then
    begin
      SetLength(FieldNames, ArrayParameterCount(Args[0].Obj.ArrayData));
      for I := 0 to High(FieldNames) do
        FieldNames[I] := [#0 + CoerceText(ReadArrayValue(Args[0].Obj, I))];
    end
    else if Args[0].Kind = a2String then
      FieldNames := [[#0 + Args[0].Text]];
    if Length(Args) > 1 then
    begin
      if (Args[1].Obj <> nil) and (Args[1].Obj.ArrayData <> nil) then
      begin
        ParameterArray := Args[1].Obj.ArrayData;
        SetLength(FieldOptions, ArrayParameterCount(ParameterArray));
        for I := 0 to High(FieldOptions) do
          FieldOptions[I] := IntBits(CoerceNumber(ReadArrayValue(Args[1].Obj, I)));
      end
      else
        FieldOptions := [IntBits(CoerceNumber(Args[1]))];
    end;
    if Length(FieldOptions) > 0 then
      Options := FieldOptions[0] and (SortUnique or SortReturnIndices);
    if Length(FieldOptions) < Length(FieldNames) then
    begin
      Count := Length(FieldOptions);
      SetLength(FieldOptions, Length(FieldNames));
      if Count > 0 then
        for I := Count to High(FieldOptions) do
          FieldOptions[I] := FieldOptions[Count - 1];
    end;
  end
  else if Length(Args) > 0 then
  begin
    if Args[0].Kind in [a2Int, a2UInt, a2Number] then
      Options := IntBits(Args[0].Number)
    else
    begin
      Callback := Args[0].Obj;
      if (Callback = nil) or (Callback.Kind <> a2Function) then
        RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert ' + AsText(Args[0]) + ' to Function.');
      if Length(Args) > 1 then
      begin
        if not (Args[1].Kind in [a2Int, a2UInt, a2Number]) then
          RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert ' + AsText(Args[1]) + ' to Number.');
        Options := IntBits(Args[1].Number);
      end;
    end;
  end;

  if IsVector then
  begin
    Count := Receiver.VectorData.Count;
    Dec(FWork, Count);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
  end
  else
    Count := ArrayParameterCount(Data);
  SetLength(Values, Count);
  for I := 0 to Count - 1 do
  begin
    Values[I].Index := Cardinal(I);
    if IsVector then
      Values[I].Value := Receiver.VectorData[I]
    else
      Values[I].Value := ReadArrayValue(Receiver, I);
  end;
  Unique := True;
  SortRange(0, Count);
  if IsVector then
  begin
    // Vector sorts a snapshot. These flags can suppress writing it back.
    if (Options and SortReturnIndices = 0) and ((Options and SortUnique = 0) or Unique) then
    begin
      ResizeVector(Receiver, Cardinal(Count));
      for I := 0 to Count - 1 do
        Receiver.VectorData[I] := Values[I].Value;
    end;
    Exit(TAVM2Value.Ref(Receiver));
  end;
  if (Options and SortUnique <> 0) and not Unique then
    Exit(TAVM2Value.Num(0, a2Int));
  if Options and SortReturnIndices <> 0 then
  begin
    if Count > ArrayElementLimit - FArrayElements then
      raise EAVM2Error.Create('AVM2 Array storage limit');
    IndexArray := Construct(FArrayClass, nil);
    for I := 0 to Count - 1 do
      SetArrayElement(IndexArray.ArrayData, Cardinal(I), TAVM2Value.Num(Values[I].Index, a2UInt));
    Exit(TAVM2Value.Ref(IndexArray));
  end;
  Updated := TDictionary<Cardinal, TAVM2Value>.Create;
  try
    for I := 0 to Count - 1 do
    begin
      if not Data.Elements.TryGetValue(Values[I].Index, Value) then
      begin
        Value := Values[I].Value;
        if Value.Kind = a2Undefined then
          Continue;
      end;
      Updated.Add(Cardinal(I), Value);
    end;
    if Updated.Count - Data.Elements.Count > ArrayElementLimit - FArrayElements then
      raise EAVM2Error.Create('AVM2 Array storage limit');
    Inc(FArrayElements, Updated.Count - Data.Elements.Count);
    Data.Elements.Free;
    Data.Elements := Updated;
    Updated := nil;
    Data.ArrayLength := Cardinal(Count);
    Data.OrderedKeys := nil;
  finally
    Updated.Free;
  end;
  Result := TAVM2Value.Ref(Receiver);
end;

function TAVM2Runtime.ConcatArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Target: TAVM2Object;
  Arg: TAVM2Value;

  procedure AddElements(Source: TAVM2Array);
  var
    Base, Index, Count: Cardinal;
    Item: TPair<Cardinal, TAVM2Value>;
  begin
    Base := Target.ArrayData.ArrayLength;
    Count := Source.ArrayLength;
    if Count > High(Cardinal) - Base then
      RaiseScriptError('RangeError', 1005, 'Array index is not a positive integer.');
    while Source <> nil do
    begin
      Dec(FWork, Source.Elements.Count);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      for Item in Source.Elements do
        if Item.Key < Count then
        begin
          Index := Base + Item.Key;
          if not Target.ArrayData.Elements.ContainsKey(Index) then
            SetArrayElement(Target.ArrayData, Index, Item.Value);
        end;
      Source := Source.Prototype;
    end;
    SetArrayLength(Target.ArrayData, Base + Count);
  end;

begin
  Target := Construct(FArrayClass, nil);
  AddElements(Data);
  for Arg in Args do
    if (Arg.Obj <> nil) and (Arg.Obj.ArrayData <> nil) then
      AddElements(Arg.Obj.ArrayData)
    else
      AppendArray(Target.ArrayData, [Arg]);
  Result := TAVM2Value.Ref(Target);
end;

function TAVM2Runtime.ArrayCall(Command: TAVM2ArrayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Data: TAVM2Array;
  Index: Cardinal;
  Separator: string;
  I: Integer;
begin
  if (Receiver = nil) or (Receiver.ArrayData = nil) then
  begin
    if Command in [aaSort, aaSortOn] then
      RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert receiver to Array.');
    raise EAVM2Error.Create('Invalid AVM2 Array receiver');
  end;
  Data := Receiver.ArrayData;
  Result := Default(TAVM2Value);
  case Command of
    aaConcat:
      Result := ConcatArray(Data, Args);
    aaSort, aaSortOn:
      Result := SortCollection(Receiver, Args, Command = aaSortOn);
    aaPush:
      begin
        AppendArray(Data, Args);
        Result := TAVM2Value.Num(Data.ArrayLength, a2UInt);
      end;
    aaPop:
      begin
        if Data.ArrayLength = 0 then
          Exit;
        Index := Data.ArrayLength - 1;
        if Data.Elements.TryGetValue(Index, Result) then
          RemoveArrayElement(Data, Index);
        Data.ArrayLength := Index;
      end;
    aaShift:
      begin
        if Data.ArrayLength = 0 then
          Exit;
        Data.Elements.TryGetValue(0, Result);
        ShiftArrayKeys(Data, -1);
        Dec(Data.ArrayLength);
      end;
    aaUnshift:
      begin
        if UInt64(Data.ArrayLength) + UInt64(Length(Args)) > High(Cardinal) then
          RaiseScriptError('RangeError', 1005, 'Array index is not a positive integer.');
        if Length(Args) > ArrayElementLimit - FArrayElements then
          raise EAVM2Error.Create('AVM2 Array storage limit');
        if Length(Args) > 0 then
        begin
          ShiftArrayKeys(Data, Length(Args));
          Inc(Data.ArrayLength, Length(Args));
          for I := 0 to High(Args) do
            SetArrayElement(Data, Cardinal(I), Args[I]);
        end;
        Result := TAVM2Value.Num(Data.ArrayLength, a2UInt);
      end;
    aaReverse:
      begin
        ReverseArray(Data);
        Result := TAVM2Value.Ref(Receiver);
      end;
    aaSlice:
      Result := SliceArray(Data, Args);
    aaSplice:
      Result := SpliceArray(Data, Args);
    aaIndexOf, aaLastIndexOf:
      Result := TAVM2Value.Num(SearchArray(Data, Args, Command = aaLastIndexOf), a2Int);
    aaForEach..aaSome:
      Result := ArrayCallback(Command, Receiver, Args);
    aaJoin, aaToString:
      begin
        Separator := ',';
        if (Command = aaJoin) and (Length(Args) > 0) and (Args[0].Kind <> a2Undefined) then
          Separator := AsText(Args[0]);
        Result := TAVM2Value.Str(ArrayText(Data, Separator, 0, Self));
      end;
  end;
end;

procedure TAVM2Runtime.InstallByteArrayClasses(ObjectClass, ErrorClass: TAVM2Object);
var
  Native, IOErrorClass, EOFErrorClass: TAVM2Object;
  Method: TAVM2ByteMethod;
begin
  FByteArrayClass := NewObject(a2Class);
  FByteArrayClass.Parent := ObjectClass;
  FByteArrayClass.DisplayName := 'flash.utils.ByteArray';
  FNative.Props.Add('flash.utils' + #0 + 'ByteArray', TAVM2Value.Ref(FByteArrayClass));
  for Method := Low(TAVM2ByteMethod) to High(TAVM2ByteMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := ByteArrayMethodBase - Ord(Method);
    FByteArrayMethods[Method] := Native;
  end;
  Native := NewObject(a2Class);
  Native.Parent := ObjectClass;
  Native.DisplayName := 'flash.utils.Endian';
  Native.Props.Add(#0 + 'BIG_ENDIAN', TAVM2Value.Str('bigEndian'));
  Native.Props.Add(#0 + 'LITTLE_ENDIAN', TAVM2Value.Str('littleEndian'));
  FNative.Props.Add('flash.utils' + #0 + 'Endian', TAVM2Value.Ref(Native));
  Native := NewObject(a2Class);
  Native.Parent := ObjectClass;
  Native.DisplayName := 'flash.utils.CompressionAlgorithm';
  Native.Props.Add(#0 + 'ZLIB', TAVM2Value.Str('zlib'));
  Native.Props.Add(#0 + 'DEFLATE', TAVM2Value.Str('deflate'));
  Native.Props.Add(#0 + 'LZMA', TAVM2Value.Str('lzma'));
  FNative.Props.Add('flash.utils' + #0 + 'CompressionAlgorithm', TAVM2Value.Ref(Native));

  IOErrorClass := NewObject(a2Class);
  IOErrorClass.Parent := ErrorClass;
  IOErrorClass.NativeError := True;
  IOErrorClass.DisplayName := 'IOError';
  FNative.Props.Add('flash.errors' + #0 + 'IOError', TAVM2Value.Ref(IOErrorClass));
  EOFErrorClass := NewObject(a2Class);
  EOFErrorClass.Parent := IOErrorClass;
  EOFErrorClass.NativeError := True;
  EOFErrorClass.DisplayName := 'EOFError';
  FNative.Props.Add('flash.errors' + #0 + 'EOFError', TAVM2Value.Ref(EOFErrorClass));
end;

function TryPublicIndex(const Name: string; out Index: Cardinal): Boolean;
var
  I: Integer;
  Value: UInt64;
begin
  Result := False;
  Index := 0;
  if (Length(Name) < 2) or (Length(Name) > 11) or (Name[1] <> #0) then
    Exit;
  if (Length(Name) > 2) and (Name[2] = '0') then
    Exit;
  Value := 0;
  for I := 2 to Length(Name) do
  begin
    if not CharInSet(Name[I], ['0'..'9']) then
      Exit;
    Value := Value * 10 + UInt64(Ord(Name[I]) - Ord('0'));
  end;
  if Value >= High(Cardinal) then
    Exit;
  Index := Cardinal(Value);
  Result := True;
end;

function TAVM2Runtime.GetByteArrayProperty(Data: TAVM2ByteArray; const Name: string; out Value: TAVM2Value): Boolean;
var
  Available: Integer;
  Index: Cardinal;
begin
  Result := True;
  if TryPublicIndex(Name, Index) then
  begin
    Value := Default(TAVM2Value);
    if Index < Cardinal(Data.Size) then
      Value := TAVM2Value.Num(Data.Buffer[Index], a2Int);
  end
  else if Name = #0 + 'length' then
    Value := TAVM2Value.Num(Data.Size, a2UInt)
  else if Name = #0 + 'position' then
    Value := TAVM2Value.Num(Data.Position, a2UInt)
  else if Name = #0 + 'bytesAvailable' then
  begin
    Available := 0;
    if Data.Position < Cardinal(Data.Size) then
      Available := Data.Size - Integer(Data.Position);
    Value := TAVM2Value.Num(Available, a2UInt);
  end
  else if Name = #0 + 'endian' then
  begin
    if Data.LittleEndian then
      Value := TAVM2Value.Str('littleEndian')
    else
      Value := TAVM2Value.Str('bigEndian');
  end
  else
    Result := False;
end;

procedure TAVM2Runtime.ResizeByteArray(Data: TAVM2ByteArray; Size: Cardinal);
var
  PreviousCapacity, Capacity: Integer;
begin
  if Size > ByteArraySizeLimit then
    raise EAVM2Error.Create('AVM2 ByteArray size limit');
  if Size = 0 then
  begin
    Dec(FByteArrayCapacity, Length(Data.Buffer));
    Data.Buffer := nil;
  end
  else if Size > Cardinal(Length(Data.Buffer)) then
  begin
    PreviousCapacity := Length(Data.Buffer);
    Capacity := Max(64, PreviousCapacity);
    while Capacity < Integer(Size) do
      Capacity := Capacity * 2;
    if Capacity - PreviousCapacity > ByteArrayTotalLimit - FByteArrayCapacity then
      raise EAVM2Error.Create('AVM2 ByteArray memory limit');
    SetLength(Data.Buffer, Capacity);
    Inc(FByteArrayCapacity, Capacity - PreviousCapacity);
  end;
  if Size > Cardinal(Data.Size) then
    FillChar(Data.Buffer[Data.Size], Integer(Size) - Data.Size, 0);
  Data.Size := Integer(Size);
end;

function TAVM2Runtime.SetByteArrayProperty(Data: TAVM2ByteArray; const Name: string; const Value: TAVM2Value): Boolean;
var
  Text: string;
  Index: Cardinal;
begin
  Result := True;
  if TryPublicIndex(Name, Index) then
  begin
    if Index >= Cardinal(Data.Size) then
      ResizeByteArray(Data, Index + 1);
    Data.Buffer[Index] := Byte(IntBits(AsNumber(Value)) and $FF);
  end
  else if Name = #0 + 'length' then
  begin
    ResizeByteArray(Data, IntBits(AsNumber(Value)));
    if Data.Position > Cardinal(Data.Size) then
      Data.Position := Cardinal(Data.Size);
  end
  else if Name = #0 + 'position' then
    Data.Position := IntBits(AsNumber(Value))
  else if Name = #0 + 'bytesAvailable' then
    RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property bytesAvailable on flash.utils.ByteArray.')
  else if Name = #0 + 'endian' then
  begin
    if Value.Kind in [a2Null, a2Undefined] then
      RaiseScriptError('TypeError', 2007, 'Parameter endian must be non-null.');
    Text := AsText(Value);
    if (Text <> 'bigEndian') and (Text <> 'littleEndian') then
      RaiseScriptError('ArgumentError', 2008, 'Parameter endian must be one of the accepted values.');
    Data.LittleEndian := Text = 'littleEndian';
  end
  else
    Result := False;
end;

function TransformDeflate(const Input: TBytes; Size, Window, Limit: Integer; Compress: Boolean; out Output: TBytes): TByteCodecResult;
var
  Stream: z_stream;
  Block: array[0..16383] of Byte;
  Status, Produced, Written, Capacity: Integer;
begin
  FillChar(Stream, SizeOf(Stream), 0);
  if Compress then
    Status := deflateInit2(Stream, Z_BEST_COMPRESSION, Z_DEFLATED, Window, 8, Z_DEFAULT_STRATEGY)
  else
    Status := inflateInit2(Stream, Window);
  if Status <> Z_OK then
    Exit(bcInvalid);
  try
    if Size > 0 then
      Stream.next_in := @Input[0];
    Stream.avail_in := Size;
    Written := 0;
    repeat
      Stream.next_out := @Block[0];
      Stream.avail_out := SizeOf(Block);
      if Compress then
        Status := deflate(Stream, Z_FINISH)
      else
        Status := inflate(Stream, Z_NO_FLUSH);
      if not (Status in [Z_OK, Z_STREAM_END]) then
        Exit(bcInvalid);

      Produced := SizeOf(Block) - Integer(Stream.avail_out);
      if Produced > Limit - Written then
        Exit(bcLimit);
      if Produced > 0 then
      begin
        if Written + Produced > Length(Output) then
        begin
          Capacity := Min(Limit, Max(Written + Produced, Max(SizeOf(Block), Length(Output) * 2)));
          SetLength(Output, Capacity);
        end;
        Move(Block[0], Output[Written], Produced);
        Inc(Written, Produced);
      end;
    until Status = Z_STREAM_END;
    SetLength(Output, Written);
    Result := bcOK;
  finally
    if Compress then
      deflateEnd(Stream)
    else
      inflateEnd(Stream);
  end;
end;

function InflateLzmaAlone(const Input: TBytes; InputSize, Limit: Integer; out Output: TBytes): TByteCodecResult;
const
  PropertiesSize = 5;
  HeaderSize = 13;
var
  Size: UInt64;
  I: Integer;
  Source, Destination: TBytesStream;
begin
  if InputSize < HeaderSize + 5 then
    Exit(bcInvalid);
  Size := 0;
  for I := 0 to 7 do
    Size := Size or (UInt64(Input[PropertiesSize + I]) shl (I * 8));
  if Size = High(UInt64) then
    Exit(bcInvalid);
  if Size > UInt64(Limit) then
    Exit(bcLimit);
  SetLength(Output, Integer(Size));
  Source := TBytesStream.Create(Input);
  try
    Destination := TBytesStream.Create(Output);
    try
      Source.Position := HeaderSize;
      try
        DecodeLzma(Source, Destination, InputSize - HeaderSize, Int64(Size),
          Copy(Input, 0, PropertiesSize), False, nil);
      except
        on E: ESevenZip do
          Exit(bcInvalid);
      end;
    finally
      Destination.Free;
    end;
  finally
    Source.Free;
  end;
  Result := bcOK;
end;

procedure TAVM2Runtime.TransformByteArray(Data: TAVM2ByteArray; Command: TAVM2ByteMethod; const Args: TArray<TAVM2Value>);
var
  Algorithm: string;
  Compress: Boolean;
  Limit, Window: Integer;
  Output: TBytes;
  Status: TByteCodecResult;
begin
  Compress := Command in [abCompress, abDeflate];
  if Command in [abDeflate, abInflate] then
    Algorithm := 'deflate'
  else if Length(Args) = 0 then
    Algorithm := 'zlib'
  else
  begin
    if Args[0].Kind in [a2Null, a2Undefined] then
      RaiseScriptError('TypeError', 2007, 'Parameter algorithm must be non-null.');
    Algorithm := AsText(Args[0]);
  end;

  Limit := Min(ByteArraySizeLimit, ByteArrayTotalLimit - FByteArrayCapacity + Length(Data.Buffer));
  if (Algorithm = 'lzma') and not Compress then
    Status := InflateLzmaAlone(Data.Buffer, Data.Size, Limit, Output)
  else if (Algorithm = 'zlib') or (Algorithm = 'deflate') then
  begin
    Window := 15;
    if Algorithm = 'deflate' then
      Window := -Window;
    Status := TransformDeflate(Data.Buffer, Data.Size, Window, Limit, Compress, Output);
  end
  else
    Status := bcInvalid;

  if Status = bcLimit then
    raise EAVM2Error.Create('AVM2 ByteArray size limit');
  if Status <> bcOK then
    RaiseScriptError('flash.errors' + #0 + 'IOError', 2058, 'There was an error decompressing the data.');

  Inc(FByteArrayCapacity, Length(Output) - Length(Data.Buffer));
  Data.Buffer := Output;
  Data.Size := Length(Output);
  if Compress then
    Data.Position := Cardinal(Data.Size)
  else
    Data.Position := 0;
end;

function TAVM2Runtime.ByteArrayCall(Command: TAVM2ByteMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Data: TAVM2ByteArray;
  Bits: UInt64;
  FloatValue: Single;
  DoubleValue: Double;
  Encoded: TBytes;
  Count: Cardinal;

  procedure NeedReadAt(Source: TAVM2ByteArray; Offset, Bytes: Cardinal);
  begin
    if (Offset > Cardinal(Source.Size)) or (Bytes > Cardinal(Source.Size) - Offset) then
      RaiseScriptError('flash.errors' + #0 + 'EOFError', 2030, 'End of file was encountered.');
  end;

  procedure NeedWriteAt(Destination: TAVM2ByteArray; Offset, Bytes: Cardinal);
  var
    Finish: Cardinal;
  begin
    if (Offset > ByteArraySizeLimit) or (Bytes > ByteArraySizeLimit - Offset) then
      raise EAVM2Error.Create('AVM2 ByteArray size limit');
    Finish := Offset + Bytes;
    if Finish > Cardinal(Destination.Size) then
      ResizeByteArray(Destination, Finish);
  end;

  function ReadBits(Width: Integer): UInt64;
  var
    I, Shift: Integer;
  begin
    NeedReadAt(Data, Data.Position, Width);
    Result := 0;
    for I := 0 to Width - 1 do
    begin
      Shift := I;
      if not Data.LittleEndian then
        Shift := Width - I - 1;
      Result := Result or (UInt64(Data.Buffer[Data.Position]) shl (8 * Shift));
      Inc(Data.Position);
    end;
  end;

  procedure WriteBits(Value: UInt64; Width: Integer);
  var
    I, Shift: Integer;
  begin
    NeedWriteAt(Data, Data.Position, Width);
    for I := 0 to Width - 1 do
    begin
      Shift := I;
      if not Data.LittleEndian then
        Shift := Width - I - 1;
      Data.Buffer[Data.Position] := Byte((Value shr (8 * Shift)) and $FF);
      Inc(Data.Position);
    end;
  end;

  procedure CopyBytes;
  var
    Other, Source, Destination: TAVM2ByteArray;
    Offset, Bytes, SourceOffset, DestinationOffset: Cardinal;
  begin
    if Args[0].Kind in [a2Null, a2Undefined] then
      RaiseScriptError('TypeError', 2007, 'Parameter bytes must be non-null.');
    if (Args[0].Kind <> a2Object) or (Args[0].Obj.ByteArrayData = nil) then
      RaiseScriptError('TypeError', 1034, 'Type Coercion failed: expected flash.utils.ByteArray.');
    Other := Args[0].Obj.ByteArrayData;
    Offset := 0;
    Bytes := 0;
    if Length(Args) > 1 then
      Offset := IntBits(AsNumber(Args[1]));
    if Length(Args) > 2 then
      Bytes := IntBits(AsNumber(Args[2]));
    if Command = abReadBytes then
    begin
      Source := Data;
      Destination := Other;
      SourceOffset := Data.Position;
      DestinationOffset := Offset;
    end
    else
    begin
      Source := Other;
      Destination := Data;
      SourceOffset := Offset;
      DestinationOffset := Data.Position;
    end;
    if (Bytes = 0) and (SourceOffset < Cardinal(Source.Size)) then
      Bytes := Cardinal(Source.Size) - SourceOffset;
    NeedReadAt(Source, SourceOffset, Bytes);
    NeedWriteAt(Destination, DestinationOffset, Bytes);
    if Bytes > 0 then
      Move(Source.Buffer[SourceOffset], Destination.Buffer[DestinationOffset], Bytes);
    if (Command = abWriteBytes) or (Source <> Destination) then
      Inc(Data.Position, Bytes);
  end;

begin
  if (Receiver = nil) or (Receiver.ByteArrayData = nil) then
    raise EAVM2Error.Create('Invalid AVM2 ByteArray receiver');
  Data := Receiver.ByteArrayData;
  Result := Default(TAVM2Value);
  if (Command in [abReadUTFBytes, abWriteByte..abWriteUTFBytes, abReadBytes, abWriteBytes]) and (Length(Args) = 0) then
    RaiseScriptError('ArgumentError', 1063, 'ByteArray method requires an argument.');
  case Command of
    abClear:
      begin
        ResizeByteArray(Data, 0);
        Data.Position := 0;
      end;
    abReadBytes, abWriteBytes:
      CopyBytes;
    abCompress, abUncompress, abDeflate, abInflate:
      TransformByteArray(Data, Command, Args);
    abToString:
      Result := TAVM2Value.Str(ByteArrayText(Data));
    abReadByte:
      Result := TAVM2Value.Num(ShortInt(Byte(ReadBits(1))), a2Int);
    abReadUnsignedByte:
      Result := TAVM2Value.Num(ReadBits(1), a2UInt);
    abReadBoolean:
      Result := TAVM2Value.Num(Ord(ReadBits(1) <> 0), a2Boolean);
    abReadShort:
      Result := TAVM2Value.Num(SmallInt(Word(ReadBits(2))), a2Int);
    abReadUnsignedShort:
      Result := TAVM2Value.Num(ReadBits(2), a2UInt);
    abReadInt:
      Result := TAVM2Value.Num(Integer(Cardinal(ReadBits(4))), a2Int);
    abReadUnsignedInt:
      Result := TAVM2Value.Num(ReadBits(4), a2UInt);
    abReadFloat:
      begin
        Bits := ReadBits(4);
        Move(Bits, FloatValue, SizeOf(FloatValue));
        Result := TAVM2Value.Num(FloatValue);
      end;
    abReadDouble:
      begin
        Bits := ReadBits(8);
        Move(Bits, DoubleValue, SizeOf(DoubleValue));
        Result := TAVM2Value.Num(DoubleValue);
      end;
    abReadUTF, abReadUTFBytes:
      begin
        if Command = abReadUTF then
          Count := Cardinal(ReadBits(2))
        else
          Count := IntBits(AsNumber(Args[0]));
        NeedReadAt(Data, Data.Position, Count);
        if Count > 4 * TextLimit then
          raise EAVM2Error.Create('AVM2 string size limit');
        if Count = 0 then
          Exit(TAVM2Value.Str(''));
        Result := TAVM2Value.Str(TEncoding.UTF8.GetString(Data.Buffer, Integer(Data.Position), Integer(Count)));
        if Length(Result.Text) > TextLimit then
          raise EAVM2Error.Create('AVM2 string size limit');
        Inc(Data.Position, Count);
      end;
    abWriteByte:
      WriteBits(IntBits(AsNumber(Args[0])), 1);
    abWriteBoolean:
      WriteBits(Ord(Truth(Args[0])), 1);
    abWriteShort:
      WriteBits(IntBits(AsNumber(Args[0])), 2);
    abWriteInt, abWriteUnsignedInt:
      WriteBits(IntBits(AsNumber(Args[0])), 4);
    abWriteFloat:
      begin
        FloatValue := AsNumber(Args[0]);
        Bits := 0;
        Move(FloatValue, Bits, SizeOf(FloatValue));
        WriteBits(Bits, 4);
      end;
    abWriteDouble:
      begin
        DoubleValue := AsNumber(Args[0]);
        Move(DoubleValue, Bits, SizeOf(DoubleValue));
        WriteBits(Bits, 8);
      end;
    abWriteUTF, abWriteUTFBytes:
      begin
        if Args[0].Kind in [a2Null, a2Undefined] then
          RaiseScriptError('TypeError', 2007, 'Parameter value must be non-null.');
        Encoded := TEncoding.UTF8.GetBytes(AsText(Args[0]));
        Count := Length(Encoded);
        if (Command = abWriteUTF) and (Count > Cardinal(High(Word))) then
          RaiseScriptError('RangeError', 2006, 'The supplied UTF-8 text is too long.');
        NeedWriteAt(Data, Data.Position, Count + Cardinal(2 * Ord(Command = abWriteUTF)));
        if Command = abWriteUTF then
          WriteBits(Count, 2);
        if Count > 0 then
        begin
          Move(Encoded[0], Data.Buffer[Data.Position], Count);
          Inc(Data.Position, Count);
        end;
      end;
  end;
end;

function RegExpProperty(Data: TAVM2RegExp; const Name: string; out Value: TAVM2Value): Boolean;
begin
  if Name = #0 + 'source' then
    Value := TAVM2Value.Str(Data.Source)
  else if Name = #0 + 'lastIndex' then
    Value := TAVM2Value.Num(Data.LastIndex, a2Int)
  else if Name = #0 + 'global' then
    Value := TAVM2Value.Num(Ord(rfGlobal in Data.Flags), a2Boolean)
  else if Name = #0 + 'ignoreCase' then
    Value := TAVM2Value.Num(Ord(rfIgnoreCase in Data.Flags), a2Boolean)
  else if Name = #0 + 'multiline' then
    Value := TAVM2Value.Num(Ord(rfMultiline in Data.Flags), a2Boolean)
  else if Name = #0 + 'dotall' then
    Value := TAVM2Value.Num(Ord(rfDotAll in Data.Flags), a2Boolean)
  else if Name = #0 + 'extended' then
    Value := TAVM2Value.Num(Ord(rfExtended in Data.Flags), a2Boolean)
  else
    Exit(False);
  Result := True;
end;

procedure TAVM2Runtime.StoreDynamicProperty(Obj: TAVM2Object; const Key: string; const Value: TAVM2Value; Enumerable: Boolean);
var
  Entry: TAVM2DynamicProperty;
begin
  if Obj.Kind = a2Script then
    Inc(FDefinitionGeneration);
  if not Obj.Props.ContainsKey(Key) then
  begin
    if Obj.DynamicProperties = nil then
    begin
      Obj.DynamicProperties := TList<TAVM2DynamicProperty>.Create;
      Obj.DynamicIndices := TDictionary<string, Integer>.Create;
    end;
    if Obj.DynamicProperties.Count >= ArrayElementLimit then
      raise EAVM2Error.Create('AVM2 dynamic property limit');
    Entry := Default(TAVM2DynamicProperty);
    Entry.Key := Key;
    Entry.Enumerable := Enumerable;
    Obj.DynamicIndices.Add(Key, Obj.DynamicProperties.Count);
    Obj.DynamicProperties.Add(Entry);
  end;
  Obj.Props.AddOrSetValue(Key, Value);
end;

procedure TAVM2Runtime.StoreDictionaryKey(Obj, Key: TAVM2Object; const Value: TAVM2Value);
var
  DictionaryEntry: TAVM2DictionaryEntry;
  Entry: TAVM2DynamicProperty;
begin
  if not Obj.DictionaryKeys.TryGetValue(Key, DictionaryEntry) then
  begin
    if Obj.DynamicProperties = nil then
    begin
      Obj.DynamicProperties := TList<TAVM2DynamicProperty>.Create;
      Obj.DynamicIndices := TDictionary<string, Integer>.Create;
    end;
    if Obj.DynamicProperties.Count >= ArrayElementLimit then
      raise EAVM2Error.Create('AVM2 dynamic property limit');
    DictionaryEntry.Slot := Obj.DynamicProperties.Count;
    Entry := Default(TAVM2DynamicProperty);
    Entry.ObjectKey := Key;
    Entry.Enumerable := True;
    Obj.DynamicProperties.Add(Entry);
  end;
  DictionaryEntry.Value := Value;
  Obj.DictionaryKeys.AddOrSetValue(Key, DictionaryEntry);
end;

function TAVM2Runtime.DictionaryValue(Obj, Key: TAVM2Object): TAVM2Value;
var
  Entry: TAVM2DictionaryEntry;
begin
  if Obj.DictionaryKeys.TryGetValue(Key, Entry) then
    Exit(Entry.Value);
  Result := Default(TAVM2Value);
end;

procedure TAVM2Runtime.InstallObjectMethods;
const
  Names: array[TAVM2ObjectMethod] of string =
    ('propertyIsEnumerable', 'setPropertyIsEnumerable', 'hasOwnProperty', 'toString', 'valueOf');
var
  Method: TAVM2ObjectMethod;
  Native: TAVM2Object;
begin
  for Method := Low(TAVM2ObjectMethod) to High(TAVM2ObjectMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := ObjectMethodBase - Ord(Method);
    FObjectPrototype.Props.Add(BuiltinNamespace + Names[Method], TAVM2Value.Ref(Native));
    StoreDynamicProperty(FObjectPrototype, #0 + Names[Method], TAVM2Value.Ref(Native), False);
  end;
end;

function TryVectorIndex(const Key: string; out Number: Double): Boolean; forward;

function HasVectorProperty(Obj: TAVM2Object; const Key: string): Boolean;
var
  Number: Double;
begin
  Result := (Key = #0 + 'length') or (Key = #0 + 'fixed') or
    (TryVectorIndex(Key, Number) and (Number >= 0) and (Number < Obj.VectorData.Count) and (Frac(Number) = 0));
end;

function TAVM2Runtime.InvokeObjectMethod(Method: TAVM2ObjectMethod; const Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Obj: TAVM2Object;
  Key: string;
  Value: TAVM2Value;
  Entry: TAVM2DynamicProperty;
  Slot: Integer;
  Index: Cardinal;
  IsDynamic, HasProperty: Boolean;
begin
  if Method = omToString then
    Exit(TAVM2Value.Str(AsText(Receiver)));
  if Method = omValueOf then
    Exit(Receiver);
  Key := #0 + 'undefined';
  if Length(Args) > 0 then
    Key := #0 + CoerceText(Args[0]);
  Obj := Receiver.Obj;
  if Obj = nil then
  begin
    if Method = omSetPropertyIsEnumerable then
      Exit(Default(TAVM2Value));
    Exit(TAVM2Value.Num(Ord((Method = omHasOwnProperty) and (Receiver.Kind = a2String) and
          (Key = #0 + 'length')), a2Boolean));
  end;
  IsDynamic := (Obj.DynamicIndices <> nil) and Obj.DynamicIndices.TryGetValue(Key, Slot);
  case Method of
    omSetPropertyIsEnumerable:
      begin
        if IsDynamic and (Obj.DictionaryKeys = nil) then
        begin
          Entry := Obj.DynamicProperties[Slot];
          Entry.Enumerable := (Length(Args) < 2) or Truth(Args[1]);
          Obj.DynamicProperties[Slot] := Entry;
        end;
        Exit(Default(TAVM2Value));
      end;
    omPropertyIsEnumerable:
      HasProperty := (IsDynamic and Obj.DynamicProperties[Slot].Enumerable) or
        ((Obj.ArrayData <> nil) and TryPublicIndex(Key, Index) and (Index < Obj.ArrayData.ArrayLength));
  else
    HasProperty := Obj.Props.ContainsKey(Key) or
      ((Obj.VectorData <> nil) and HasVectorProperty(Obj, Key)) or
      ((Obj.Kind in [a2Function, a2Class]) and (Key = #0 + 'prototype')) or
      ((Obj.RegExp <> nil) and RegExpProperty(Obj.RegExp, Key, Value)) or
      ((Obj.ArrayData <> nil) and ((Key = #0 + 'length') or
      (TryPublicIndex(Key, Index) and Obj.ArrayData.Elements.ContainsKey(Index)))) or
      ((Obj.ByteArrayData <> nil) and (GetByteArrayProperty(Obj.ByteArrayData, Key, Value) or
      (TryPublicIndex(Key, Index) and (Index < Cardinal(Obj.ByteArrayData.Size)))));
  end;
  Result := TAVM2Value.Num(Ord(HasProperty), a2Boolean);
end;

function TAVM2Runtime.DeleteProperty(Obj: TAVM2Object; const Names: TArray<string>): Boolean;
var
  Key: string;
  Value: TAVM2Value;
  Slot: Integer;
  Index: Cardinal;
  HasPublicName: Boolean;
begin
  if Obj.Kind = a2Script then
    Inc(FDefinitionGeneration);
  HasPublicName := False;
  for Key in Names do
  begin
    HasPublicName := HasPublicName or (Key[1] = #0);
    if Obj.VectorData <> nil then
    begin
      if (Key = #0 + 'length') or (Key = #0 + 'fixed') then
        Exit(False);
      if Key[1] = #0 then
        Exit(True);
    end;
    if (Obj.ArrayData <> nil) and TryPublicIndex(Key, Index) then
    begin
      RemoveArrayElement(Obj.ArrayData, Index);
      Exit(True);
    end;
    if (Obj.DynamicIndices <> nil) and Obj.DynamicIndices.TryGetValue(Key, Slot) then
    begin
      Obj.DynamicIndices.Remove(Key);
      Obj.DynamicProperties[Slot] := Default(TAVM2DynamicProperty);
      Obj.Props.Remove(Key);
      Exit(True);
    end;
    if Obj.Props.ContainsKey(Key) or ((Obj.RegExp <> nil) and RegExpProperty(Obj.RegExp, Key, Value)) or
      ((Obj.Kind in [a2Function, a2Class]) and (Key = #0 + 'prototype')) or
      ((Obj.ArrayData <> nil) and (Key = #0 + 'length')) or
      ((Obj.ByteArrayData <> nil) and (GetByteArrayProperty(Obj.ByteArrayData, Key, Value) or
      TryPublicIndex(Key, Index))) then
      Exit(False);
  end;
  if (Obj.ClassObject <> nil) and (Obj.ClassObject.Kind = a2Class) and (Obj.ClassObject.Module <> nil) then
    if Obj.ClassObject.Module.ABC.Instances[Obj.ClassObject.Index].Flags and 1 <> 0 then
      Exit(False);
  Result := HasPublicName and (Obj.Kind <> a2Class);
end;

function TAVM2Runtime.NextEnumerant(Obj: TAVM2Object; Previous: Cardinal): Cardinal;
var
  Data: TAVM2Array;
  Start: Cardinal;
  First, Last, Middle: Integer;
begin
  if Obj = nil then
    Exit(0);
  if IsXML(Obj) then
  begin
    if Previous < Cardinal(Length(Obj.XMLNodes)) then
      Exit(Previous + 1);
    Exit(0);
  end;
  if Obj.VectorData <> nil then
  begin
    if Previous < Cardinal(Obj.VectorData.Count) then
      Exit(Previous + 1);
    Exit(0);
  end;
  Data := Obj.ArrayData;
  Start := 0;
  if Data <> nil then
  begin
    if (Previous < Data.ArrayLength) and (Data.Elements.Count > 0) then
    begin
      if Data.OrderedKeys = nil then
      begin
        Dec(FWork, Data.Elements.Count);
        if FWork < 0 then
          raise EAVM2Error.Create('AVM2 instruction limit');
        Data.OrderedKeys := Data.Elements.Keys.ToArray;
        TArray.Sort<Cardinal>(Data.OrderedKeys);
      end;
      First := 0;
      Last := Length(Data.OrderedKeys);
      while First < Last do
      begin
        Middle := (First + Last) div 2;
        if Data.OrderedKeys[Middle] < Previous then
          First := Middle + 1
        else
          Last := Middle;
      end;
      if First < Length(Data.OrderedKeys) then
        Exit(Data.OrderedKeys[First] + 1);
    end;
    Start := Data.ArrayLength;
  end;
  Result := 0;
  if Obj.DynamicProperties = nil then
    Exit;
  Previous := Max(Previous, Start) - Start;
  if Previous >= Cardinal(Obj.DynamicProperties.Count) then
    Exit;
  for First := Integer(Previous) to Obj.DynamicProperties.Count - 1 do
  begin
    Dec(FWork);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    if Obj.DynamicProperties[First].Enumerable then
      Exit(Cardinal((UInt64(Start) + UInt64(First) + 1) and $FFFFFFFF));
  end;
end;

function TAVM2Runtime.EnumerantName(Obj: TAVM2Object; Index: Cardinal): TAVM2Value;
var
  Key: string;
  Numeric: Cardinal;
begin
  Result := TAVM2Value.Ref(nil);
  if (Obj = nil) or (Index = 0) then
    Exit;
  if IsXML(Obj) then
  begin
    if Index <= Cardinal(Length(Obj.XMLNodes)) then
      Result := TAVM2Value.Num(Index - 1, a2UInt);
    Exit;
  end;
  if Obj.VectorData <> nil then
  begin
    if Index <= Cardinal(Obj.VectorData.Count) then
      Result := TAVM2Value.Num(Index - 1, a2UInt);
    Exit;
  end;
  if Obj.ArrayData <> nil then
  begin
    if Index <= Obj.ArrayData.ArrayLength then
      Exit(TAVM2Value.Num(Index - 1, a2UInt));
    Dec(Index, Obj.ArrayData.ArrayLength);
  end;
  if (Obj.DynamicProperties = nil) or (Index > Cardinal(Obj.DynamicProperties.Count)) then
    Exit;
  if Obj.DynamicProperties[Integer(Index) - 1].ObjectKey <> nil then
    Exit(TAVM2Value.Ref(Obj.DynamicProperties[Integer(Index) - 1].ObjectKey));
  Key := Obj.DynamicProperties[Integer(Index) - 1].Key;
  if Key = '' then
    Exit;
  if TryPublicIndex(Key, Numeric) then
    Exit(TAVM2Value.Num(Numeric, a2UInt));
  Result := TAVM2Value.Str(Copy(Key, 2, MaxInt));
end;

function TAVM2Runtime.ProtectedMemberName(Receiver: TAVM2Object; const Name: string): string;
var
  Base: TAVM2Object;
  Member, NamespaceIndex: Integer;
  LocalName, Candidate, FirstMember: string;
  Related: Boolean;
begin
  Result := Name;
  if (Receiver = nil) or not StartsStr('#24:', Name) then
    Exit;
  Member := Pos(#0, Name);
  if Member = 0 then
    Exit;
  LocalName := Copy(Name, Member + 1, MaxInt);
  FirstMember := '';
  Related := False;
  Base := Receiver.ClassObject;
  while (Base <> nil) and (Base.Module <> nil) and (Base.Index >= 0) do
  begin
    NamespaceIndex := Base.Module.ABC.Instances[Base.Index].ProtectedNamespace;
    if NamespaceIndex > 0 then
    begin
      Candidate := Key(Base.Module, NamespaceIndex, LocalName);
      if Candidate = Name then
        Related := True;
      if (FirstMember = '') and Receiver.Props.ContainsKey(Candidate) then
        FirstMember := Candidate;
    end;
    Base := Base.Parent;
  end;
  if Related and (FirstMember <> '') then
    Result := FirstMember;
end;

function TAVM2Runtime.InterfacePublicName(Receiver: TAVM2Object; const Key: string): string;
var
  Separator, Member: Integer;
  InterfaceClass: TAVM2Object;
  ClassName: string;
begin
  Result := Key;
  if (Receiver = nil) or (Receiver.ClassObject = nil) or (Key = '') or CharInSet(Key[1], [#0, '#']) then
    Exit;
  Member := Pos(#0, Key);
  Separator := Pos(':', Key);
  if (Separator < 1) or (Separator >= Member - 1) or (Pos('/', Key) > 0) then
    Exit;
  ClassName := Copy(Key, 1, Separator - 1) + '.' + Copy(Key, Separator + 1, Member - Separator - 1);
  if ClassName = 'flash.events.IEventDispatcher' then
    InterfaceClass := FEventDispatcherInterface
  else
    InterfaceClass := LinkedClass(ClassName);
  if (InterfaceClass <> nil) and
    ((InterfaceClass = FEventDispatcherInterface) or ((InterfaceClass.Module <> nil) and
    (InterfaceClass.Module.ABC.Instances[InterfaceClass.Index].Flags and 4 <> 0))) and
    ClassHasType(Receiver.ClassObject, InterfaceClass) then
    Result := Copy(Key, Member, MaxInt);
end;

function TAVM2Runtime.HasProperty(Receiver: TAVM2Object; const Name: string): Boolean;
var
  Index: Cardinal;
  Value: TAVM2Value;
begin
  while Receiver <> nil do
  begin
    if (Receiver.VectorData <> nil) and HasVectorProperty(Receiver, Name) then
      Exit(True);
    if (Receiver.RegExp <> nil) and RegExpProperty(Receiver.RegExp, Name, Value) then
      Exit(True);
    if (Receiver.Kind in [a2Class, a2Function]) and (Name = #0 + 'prototype') then
      Exit(True);
    if Receiver.ArrayData <> nil then
    begin
      if Name = #0 + 'length' then
        Exit(True);
      if TryPublicIndex(Name, Index) and TryArrayElement(Receiver.ArrayData, Index, Value) then
        Exit(True);
    end;
    if Receiver.ByteArrayData <> nil then
    begin
      if TryPublicIndex(Name, Index) then
        Exit(Index < Cardinal(Receiver.ByteArrayData.Size));
      if GetByteArrayProperty(Receiver.ByteArrayData, Name, Value) then
        Exit(True);
    end;
    if Receiver.Props.ContainsKey(Name) then
      Exit(True);
    if (Receiver.TimelineBindings <> nil) and Receiver.TimelineBindings.ContainsKey(Name) then
      Exit(True);
    Receiver := ObjectPrototype(Receiver);
  end;
  Result := False;
end;

function TAVM2Runtime.PropertyValue(Receiver: TAVM2Object; const Names: TArray<string>): TAVM2Value;
var
  Name, Candidate: string;
  Index: Cardinal;
  Rect: TAVM2Rectangle;
  Matrix: TAVM2Matrix;
  Owner: TAVM2Object;
  Accessor: TAVM2Accessor;
  Color: TSWFColorTransform;
  ColorArgs: TArray<TAVM2Value>;
  HasNativeProperties: Boolean;
begin
  while Receiver <> nil do
  begin
    HasNativeProperties := (Receiver.Kind in [a2Class, a2Function]) or
      (Receiver.DisplayKind <> adNone) or (Receiver.DisplayData <> nil) or (Receiver = FLoaderInfo) or
      (Receiver.TransformOwner <> nil) or Receiver.IsRectangle or Receiver.IsPoint or
      (Receiver.BitmapData <> nil) or (Receiver.VectorData <> nil) or (Receiver.RegExp <> nil) or
      (Receiver.ArrayData <> nil) or (Receiver.ByteArrayData <> nil);
    for Candidate in Names do
    begin
      Name := Candidate;
      if (Length(Name) >= 4) and (Name[1] = '#') and (Name[2] = '2') and (Name[3] = '4') and (Name[4] = ':') then
        Name := ProtectedMemberName(Receiver, Name);
      if (Name <> '') and not CharInSet(Name[1], [#0, '#']) and
        (Pos(':', Name) > 0) and not Receiver.Props.ContainsKey(Name) then
        Name := InterfacePublicName(Receiver, Name);
      if HasNativeProperties then
      begin
        if (Receiver.BitmapData <> nil) and ((Name = #0 + 'width') or (Name = #0 + 'height') or
          (Name = #0 + 'transparent') or (Name = #0 + 'rect')) then
        begin
          if Receiver.BitmapData.Disposed then
            RaiseScriptError('ArgumentError', 2015, 'BitmapData has been disposed.');
          if Name = #0 + 'width' then
            Exit(TAVM2Value.Num(Receiver.BitmapData.Width, a2Int));
          if Name = #0 + 'height' then
            Exit(TAVM2Value.Num(Receiver.BitmapData.Height, a2Int));
          if Name = #0 + 'transparent' then
            Exit(TAVM2Value.Num(Ord(Receiver.BitmapData.Transparent), a2Boolean));
          Rect := Default(TAVM2Rectangle);
          Rect.Width := Receiver.BitmapData.Width;
          Rect.Height := Receiver.BitmapData.Height;
          Exit(NewRectangle(Rect));
        end;
        if (Receiver.DisplayKind = adMovieClip) and (Receiver.DisplayData <> nil) and
          ((Name = #0 + 'currentLabels') or (Name = #0 + 'currentLabel') or (Name = #0 + 'currentFrameLabel')) then
          Exit(FrameLabelProperty(Receiver.DisplayData, Name));
        if (Receiver = FLoaderInfo) and (Name = #0 + 'bytes') then
          Exit(LoaderBytes);
        if (Receiver.DisplayKind = adText) and (Receiver.DisplayData <> nil) and
          StartsStr(#0, Name) and FDisplay.GetTextProperty(Receiver.DisplayData, Copy(Name, 2, MaxInt), Result) then
          Exit;
        if (Receiver.DisplayData <> nil) and ((Name = #0 + 'width') or (Name = #0 + 'height')) then
        begin
          Owner := Receiver.DisplayParent;
          if Owner <> nil then
            Rect := FDisplay.GetBounds(Receiver.DisplayData, Owner.DisplayData, False, False)
          else
            Rect := FDisplay.GetBounds(Receiver.DisplayData, Receiver.DisplayData, False, False);
          if Name = #0 + 'width' then
            Exit(TAVM2Value.Num(Rect.Width));
          Exit(TAVM2Value.Num(Rect.Height));
        end;
        if (Name = #0 + 'transform') and ((Receiver = FStage) or
          (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton])) then
          Exit(TAVM2Value.Ref(Construct(FTransformClass, [TAVM2Value.Ref(Receiver)])));
        if (Name = #0 + 'filters') and (Receiver.DisplayKind in
          [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
          Exit(DisplayFilters(Receiver));
        Owner := Receiver.TransformOwner;
        if (Owner <> nil) and (Name = #0 + 'colorTransform') then
        begin
          Color := TSWFColorTransform.Identity;
          if FDisplay <> nil then
            Color := FDisplay.GetColorTransform(Owner.DisplayData);
          SetLength(ColorArgs, 8);
          for var I := 0 to 3 do
          begin
            ColorArgs[I] := TAVM2Value.Num(Color.Mult[I]);
            ColorArgs[I + 4] := TAVM2Value.Num(Color.Add[I]);
          end;
          Exit(TAVM2Value.Ref(Construct(FColorTransformClass, ColorArgs)));
        end;
        if (Owner <> nil) and (Name = #0 + 'pixelBounds') then
        begin
          Rect := Default(TAVM2Rectangle);
          if FDisplay <> nil then
            Rect := FDisplay.GetBounds(Owner.DisplayData, nil, False, True);
          Exit(NewRectangle(Rect));
        end;
        if (Owner <> nil) and ((Name = #0 + 'matrix') or (Name = #0 + 'concatenatedMatrix')) then
        begin
          if (Name = #0 + 'matrix') and Owner.Matrix3DActive then
            Exit(TAVM2Value.Ref(nil));
          Matrix := IdentityMatrix;
          if FDisplay <> nil then
            Matrix := FDisplay.GetMatrix(Owner.DisplayData, Name = #0 + 'concatenatedMatrix',
              (Owner <> FStage) and (StageOf(Owner) = FStage));
          Exit(NewMatrix(Matrix));
        end;
        if Receiver.IsRectangle and RectangleProperty(Receiver, Name, Result) then
          Exit;
        if (Name = #0 + 'scrollRect') and (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
        begin
          if (FDisplay <> nil) and FDisplay.GetScrollRect(Receiver.DisplayData, Rect) then
            Exit(NewRectangle(Rect));
          Exit(TAVM2Value.Ref(nil));
        end;
        if Receiver.IsPoint and (Name = #0 + 'length') then
          Exit(TAVM2Value.Num(Sqrt(Sqr(Receiver.Props[#0 + 'x'].Number) +
                Sqr(Receiver.Props[#0 + 'y'].Number))));
        if (Receiver.VectorData <> nil) and VectorProperty(Receiver, Name, Result) then
          Exit;
        if (Receiver.RegExp <> nil) and RegExpProperty(Receiver.RegExp, Name, Result) then
          Exit;
        if (Receiver.Kind = a2Class) and (Name = #0 + 'prototype') then
          Exit(TAVM2Value.Ref(ClassPrototype(Receiver)));
        if (Receiver.Kind = a2Function) and (Name = #0 + 'prototype') then
        begin
          if Receiver.BoundReceiver.Kind <> a2Undefined then
            Exit(TAVM2Value.Ref(nil));
          if Receiver.FunctionPrototype = nil then
            Exit(Default(TAVM2Value));
          Exit(TAVM2Value.Ref(Receiver.FunctionPrototype));
        end;
        if Receiver.ArrayData <> nil then
        begin
          if Name = #0 + 'length' then
            Exit(TAVM2Value.Num(Receiver.ArrayData.ArrayLength, a2UInt));
          if TryPublicIndex(Name, Index) and TryArrayElement(Receiver.ArrayData, Index, Result) then
            Exit;
        end;
        if (Receiver.ByteArrayData <> nil) and GetByteArrayProperty(Receiver.ByteArrayData, Name, Result) then
          Exit;
      end;
      if Receiver.Props.TryGetValue(Name, Result) then
      begin
        if (Receiver.Accessors <> nil) and Receiver.Accessors.TryGetValue(Name, Accessor) then
        begin
          if Accessor.Getter <> nil then
            Exit(Invoke(Accessor.Getter, Receiver, nil));
          if (Receiver.DisplayKind = adNone) or not StartsStr(#0, Name) or
            (IndexStr(Copy(Name, 2, MaxInt), DisplayProperties) < 0) then
            RaiseScriptError('ReferenceError', 1077, 'Illegal read of write-only property ' +
              Copy(Name, LastDelimiter(#0, Name) + 1, MaxInt) + ' on ' + Receiver.DisplayName + '.');
        end;
        if (Name = #0 + 'length') and ClassHasType(Receiver.ClassObject, FSoundClass) and (FDisplay <> nil) then
          Exit(TAVM2Value.Num(FDisplay.SoundLength(QualifiedClassName(Receiver.ClassObject))));
        if (Receiver.DisplayKind = adMovieClip) and (FDisplay <> nil) and
          ((Name = #0 + 'currentFrame') or (Name = #0 + 'totalFrames')) then
          Exit(TAVM2Value.Num(FDisplay.TimelineFrame(Receiver.DisplayData, Name = #0 + 'totalFrames'), a2Int));
        if (Name = #0 + 'stage') and (Receiver.DisplayKind <> adNone) then
          Result := TAVM2Value.Ref(StageOf(Receiver))
        else if (Name = #0 + 'loaderInfo') and (Result.Obj = nil) and
          ((Receiver = FDocument) or (StageOf(Receiver) = FStage)) then
          Result := TAVM2Value.Ref(FLoaderInfo)
        else if (Name = #0 + 'root') and (Receiver <> FStage) and (Receiver.DisplayKind <> adNone) then
        begin
          Owner := Receiver;
          while (Owner.DisplayParent <> nil) and (Owner.DisplayParent <> FStage) do
            Owner := Owner.DisplayParent;
          if (Owner.DisplayParent = FStage) or (Owner = FDocument) then
            Result := TAVM2Value.Ref(Owner);
        end
        else if (Name = #0 + 'focus') and (Receiver = FStage) and (StageOf(FFocus) <> FStage) then
          Result := TAVM2Value.Ref(nil);
        Exit;
      end;
      if (Receiver.TimelineBindings <> nil) and Receiver.TimelineBindings.TryGetValue(Name, Owner) then
        Exit(TAVM2Value.Ref(Owner));
    end;
    Receiver := ObjectPrototype(Receiver);
  end;
  Result := Default(TAVM2Value);
end;

function TAVM2Runtime.ResolveType(Module: TAVM2Module; Index: Integer; out ClassObject: TAVM2Object; out QualifiedName: string; Depth: Integer): TAVM2TypeKind;
var
  Name: string;
  Kind: TAVM2TypeKind;
  Scope, Base: TAVM2Object;
  TypeValue: TAVM2Value;
  Generic: TABCMultiname;
  Cached: ^TAVM2ResolvedType;

  function Remember(AKind: TAVM2TypeKind): TAVM2TypeKind;
  begin
    Cached.Generation := FDefinitionGeneration;
    Cached.Kind := AKind;
    Cached.ClassObject := ClassObject;
    Cached.QualifiedName := QualifiedName;
    Result := AKind;
  end;

begin
  ClassObject := nil;
  QualifiedName := '';
  if Index = 0 then
    Exit(atAny);
  if (Index < 0) or (Index >= Length(Module.ABC.Multinames)) then
    raise EAVM2Error.Create('Invalid AVM2 type multiname');
  if Depth >= 32 then
    raise EAVM2Error.Create('AVM2 parameterized type depth limit');
  if Module.ResolvedTypes = nil then
    SetLength(Module.ResolvedTypes, Length(Module.ABC.Multinames));
  Cached := @Module.ResolvedTypes[Index];
  if Cached.Generation = FDefinitionGeneration then
  begin
    ClassObject := Cached.ClassObject;
    QualifiedName := Cached.QualifiedName;
    Exit(Cached.Kind);
  end;
  Generic := Module.ABC.Multinames[Index];
  if Generic.Kind = $1D then
  begin
    Base := ResolveTypeClass(Module, Generic.BaseType, Depth + 1);
    CheckTypeApplication(Base, Length(Generic.Parameters));
    ClassObject := VectorType(ResolveTypeClass(Module, Generic.Parameters[0], Depth + 1));
    QualifiedName := ClassObject.DisplayName;
    Exit(Remember(atClass));
  end;
  for Name in Names(Module, Index) do
  begin
    for Kind := Low(BuiltinTypeNames) to High(BuiltinTypeNames) do
      if Name = #0 + BuiltinTypeNames[Kind] then
      begin
        QualifiedName := BuiltinTypeNames[Kind];
        Exit(Remember(Kind));
      end;
    if FDefinitions.TryGetValue(Name, Scope) then
    begin
      Initialize(Scope);
      TypeValue := PropertyValue(Scope, [Name]);
    end
    else if not FNative.Props.TryGetValue(Name, TypeValue) then
      Continue;
    if (TypeValue.Kind <> a2Object) or (TypeValue.Obj.Kind <> a2Class) then
      raise EAVM2Error.Create('AVM2 type is not a class');
    ClassObject := TypeValue.Obj;
    if Name[1] = #0 then
      QualifiedName := Copy(Name, 2, MaxInt)
    else
      QualifiedName := StringReplace(Name, #0, '::', []);
    Exit(Remember(atClass));
  end;
  raise EAVM2Error.Create('Unresolved AVM2 type ' + Module.ABC.Strings[Module.ABC.Multinames[Index].Name]);
end;

function TAVM2Runtime.ResolveTypeClass(Module: TAVM2Module; Index, Depth: Integer): TAVM2Object;
var
  Kind: TAVM2TypeKind;
  Name: string;
begin
  Kind := ResolveType(Module, Index, Result, Name, Depth);
  case Kind of
    atObject:
      Result := FObjectClass;
    atFunction:
      Result := FFunctionClass;
    atString..atUInt:
      Result := FPrimitiveClasses[Kind];
    atVoid:
      RaiseScriptError('VerifyError', 1107, 'The ABC data is corrupt, attempt to read out of bounds.');
  end;
end;

procedure TAVM2Runtime.InstallVectorClass;
var
  Method: TAVM2VectorMethod;
begin
  FVectorClass := NewObject(a2Class);
  FVectorClass.Parent := FObjectClass;
  FVectorClass.DisplayName := 'Vector';
  FNative.Props.Add(VectorNamespace + 'Vector', TAVM2Value.Ref(FVectorClass));
  for Method := Low(TAVM2VectorMethod) to High(TAVM2VectorMethod) do
  begin
    FVectorMethods[Method] := NewObject(a2Function);
    FVectorMethods[Method].Index := VectorMethodBase - Ord(Method);
  end;
  FNative.Props.Add(VectorNamespace + 'Vector$int', TAVM2Value.Ref(VectorType(FPrimitiveClasses[atInt])));
  FNative.Props.Add(VectorNamespace + 'Vector$uint', TAVM2Value.Ref(VectorType(FPrimitiveClasses[atUInt])));
  FNative.Props.Add(VectorNamespace + 'Vector$double', TAVM2Value.Ref(VectorType(FPrimitiveClasses[atNumber])));
  FNative.Props.Add(VectorNamespace + 'Vector$object', TAVM2Value.Ref(VectorType(nil)));
end;

procedure TAVM2Runtime.CheckTypeApplication(Base: TAVM2Object; Count: Integer);
begin
  if Base <> FVectorClass then
    RaiseScriptError('TypeError', 1127, 'Type application attempted on a non-parameterized type.');
  if Count <> 1 then
    RaiseScriptError('TypeError', 1128, Format('Incorrect number of type parameters for Vector. Expected 1, got %d.',
        [Count]));
end;

function TAVM2Runtime.ApplyType(Base: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Object;
begin
  CheckTypeApplication(Base, Length(Args));
  if Args[0].Kind = a2Null then
    Exit(VectorType(nil));
  if (Args[0].Obj = nil) or (Args[0].Obj.Kind <> a2Class) then
    RaiseScriptError('VerifyError', 1107, 'The ABC data is corrupt, attempt to read out of bounds.');
  Result := VectorType(Args[0].Obj);
end;

function TAVM2Runtime.VectorType(ElementType: TAVM2Object): TAVM2Object;
var
  Name: string;
  Prototype: TAVM2Object;
  Method: TAVM2VectorMethod;
begin
  if ElementType = nil then
  begin
    if FVectorWildcard <> nil then
      Exit(FVectorWildcard);
    Name := '*';
  end
  else
  begin
    if ElementType.VectorSpecialization <> nil then
      Exit(ElementType.VectorSpecialization);
    Name := ElementType.DisplayName;
  end;
  if Length(Name) > TextLimit - 10 then
    raise EAVM2Error.Create('AVM2 type name length limit');
  Result := NewObject(a2Class);
  Result.Parent := FObjectClass;
  Result.DisplayName := 'Vector.<' + Name + '>';
  Result.IsVectorType := True;
  Result.VectorElementType := ElementType;
  Prototype := ClassPrototype(Result);
  for Method := Low(TAVM2VectorMethod) to High(TAVM2VectorMethod) do
  begin
    if Method in [veInsertAt, veRemoveAt] then
    begin
      if FSWFVersion < 30 then
        Continue;
    end
    else
      Prototype.Props.Add(#0 + VectorMethodNames[Method], TAVM2Value.Ref(FVectorMethods[Method]));
    Prototype.Props.Add(BuiltinNamespace + VectorMethodNames[Method], TAVM2Value.Ref(FVectorMethods[Method]));
  end;
  if ElementType = nil then
    FVectorWildcard := Result
  else
    ElementType.VectorSpecialization := Result;
end;

procedure TAVM2Runtime.ResizeVector(Obj: TAVM2Object; NewLength: Cardinal);
var
  OldLength, I: Integer;
  Initial: TAVM2Value;
  Element: TAVM2Object;
begin
  OldLength := Obj.VectorData.Count;
  if NewLength > Cardinal(ArrayElementLimit - FArrayElements + OldLength) then
    raise EAVM2Error.Create('AVM2 Vector storage limit');
  Dec(FWork, Abs(OldLength - Integer(NewLength)));
  if FWork < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');
  Obj.VectorData.Count := Integer(NewLength);
  Inc(FArrayElements, Integer(NewLength) - OldLength);
  if Integer(NewLength) <= OldLength then
    Exit;
  Initial := TAVM2Value.Ref(nil);
  Element := Obj.ClassObject.VectorElementType;
  if (Element <> nil) and (Element.PrimitiveKind in [atNumber..atUInt]) then
    Initial := TAVM2Value.Num(0, a2Int);
  for I := OldLength to Integer(NewLength) - 1 do
    Obj.VectorData[I] := Initial;
end;

function TAVM2Runtime.VectorElement(Obj: TAVM2Object; const Value: TAVM2Value): TAVM2Value;
var
  Element: TAVM2Object;
begin
  Element := Obj.ClassObject.VectorElementType;
  if (Element = nil) or (Element = FObjectClass) then
    Exit(CoerceValue(Value, atObject, nil, 'Object'));
  if Element = FFunctionClass then
    Exit(CoerceValue(Value, atFunction, nil, 'Function'));
  case Element.PrimitiveKind of
    atNumber:
      Exit(TAVM2Value.Num(CoerceNumber(Value)));
    atInt:
      Exit(TAVM2Value.Num(Integer(IntBits(CoerceNumber(Value))), a2Int));
    atUInt:
      Exit(TAVM2Value.Num(IntBits(CoerceNumber(Value)), a2UInt));
    atBoolean:
      Exit(TAVM2Value.Num(Ord(Truth(Value)), a2Boolean));
    atString:
      if Value.Kind in [a2Null, a2Undefined] then
        Exit(TAVM2Value.Ref(nil))
      else
        Exit(TAVM2Value.Str(CoerceText(Value)));
  end;
  Result := CoerceValue(Value, atClass, Element, Element.DisplayName);
end;

procedure TAVM2Runtime.VectorRangeError(Obj: TAVM2Object; Index: Double);
begin
  RaiseScriptError('RangeError', 1125, Format('The index %s is out of range %d.',
      [AsText(TAVM2Value.Num(Index)), Obj.VectorData.Count]));
end;

function TryVectorIndex(const Key: string; out Number: Double): Boolean;
var
  Index: Cardinal;
  Text: string;
begin
  if TryPublicIndex(Key, Index) then
  begin
    Number := Index;
    Exit(True);
  end;
  if (Length(Key) < 2) or (Key[1] <> #0) then
    Exit(False);
  Text := Copy(Key, 2, MaxInt);
  Result := (Trim(Text) = Text) and TryStrToFloat(Text, Number, TFormatSettings.Invariant);
end;

function TAVM2Runtime.VectorProperty(Obj: TAVM2Object; const Key: string; out Value: TAVM2Value): Boolean;
var
  Number: Double;
begin
  if Key = #0 + 'length' then
    Value := TAVM2Value.Num(Obj.VectorData.Count, a2UInt)
  else if Key = #0 + 'fixed' then
    Value := TAVM2Value.Num(Ord(Obj.VectorFixed), a2Boolean)
  else if TryVectorIndex(Key, Number) then
  begin
    if (Number >= 0) and (Number < Obj.VectorData.Count) and (Frac(Number) = 0) then
      Value := Obj.VectorData[Trunc(Number)]
    else
    begin
      if FSWFVersion >= 11 then
        VectorRangeError(Obj, Number);
      if (Number >= 0) and (Number <= High(Cardinal)) and (Frac(Number) = 0) then
        VectorRangeError(Obj, Number);
      Exit(False);
    end;
  end
  else
    Exit(False);
  Result := True;
end;

procedure TAVM2Runtime.SetVectorIndex(Obj: TAVM2Object; Index: Cardinal; const Value: TAVM2Value);
var
  Normalized: TAVM2Value;
  Count: Cardinal;
begin
  Normalized := VectorElement(Obj, Value);
  Count := Cardinal(Obj.VectorData.Count);
  if (Index > Count) or ((Index = Count) and Obj.VectorFixed) then
    VectorRangeError(Obj, Index);
  if Index = Count then
    ResizeVector(Obj, Index + 1);
  Obj.VectorData[Integer(Index)] := Normalized;
end;

procedure TAVM2Runtime.SetVectorProperty(Obj: TAVM2Object; const Keys: TArray<string>; const Value: TAVM2Value);
var
  Key: string;
  Number: Double;
begin
  for Key in Keys do
  begin
    if Key = #0 + 'fixed' then
    begin
      Obj.VectorFixed := Truth(Value);
      Exit;
    end;
    if Key = #0 + 'length' then
    begin
      Number := CoerceNumber(Value);
      if Obj.VectorFixed then
        RaiseScriptError('RangeError', 1126, 'Cannot change the length of a fixed Vector.');
      ResizeVector(Obj, IntBits(Number));
      Exit;
    end;
    if not TryVectorIndex(Key, Number) then
      Continue;
    if (Number >= 0) and (Number <= High(Cardinal)) and (Frac(Number) = 0) then
    begin
      SetVectorIndex(Obj, Cardinal(Trunc(Number)), Value);
      Exit;
    end;
    if FSWFVersion >= 11 then
      VectorRangeError(Obj, Number);
  end;
  RaiseScriptError('ReferenceError', 1056, 'Cannot create property ' +
    Copy(Keys[0], Pos(#0, Keys[0]) + 1, MaxInt) + ' on ' + Obj.DisplayName + '.');
end;

function TAVM2Runtime.ConvertVector(AClass: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Source, Target: TAVM2Object;
  I: Integer;
  Count: Cardinal;
begin
  if Length(Args) <> 1 then
    RaiseScriptError('ArgumentError', 1112, 'Argument count mismatch on class coercion. Expected 1, got ' +
      IntToStr(Length(Args)) + '.');
  Source := Args[0].Obj;
  if Source = nil then
    RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert ' + AsText(Args[0]) +
      ' to ' + AClass.DisplayName + '.');
  if Source.ClassObject = AClass then
    Exit(Args[0]);
  Count := IntBits(CoerceNumber(ReadProperty(Args[0], [#0 + 'length'], False)));
  Target := Construct(AClass, nil);
  ResizeVector(Target, Count);
  for I := 0 to Integer(Count) - 1 do
    Target.VectorData[I] := VectorElement(Target, ReadProperty(Args[0], [#0 + IntToStr(I)], False));
  Result := TAVM2Value.Ref(Target);
end;

function TAVM2Runtime.ConcatVector(Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Target, Source, Element, SourceElement: TAVM2Object;
  Data: TList<TAVM2Value>;
  Arg: TAVM2Value;
  Items: TArray<TAVM2Value>;
  I, Count, Added, StartIndex, OriginalLength: Integer;
  Numeric, Fixed: Boolean;
begin
  OriginalLength := Obj.VectorData.Count;
  Fixed := Obj.VectorFixed;
  Element := Obj.ClassObject.VectorElementType;
  Numeric := (Element <> nil) and (Element.PrimitiveKind in [atNumber..atUInt]);
  if OriginalLength > ArrayElementLimit - FArrayElements then
    raise EAVM2Error.Create('AVM2 Vector storage limit');
  Data := TList<TAVM2Value>.Create;
  try
    Data.Count := OriginalLength;
    for I := 0 to OriginalLength - 1 do
      Data[I] := Obj.VectorData[I];
    for Arg in Args do
    begin
      if Arg.Kind = a2Null then
        RaiseScriptError('TypeError', 1009, 'Cannot access a property or method of a null object reference.');
      if Arg.Kind = a2Undefined then
        RaiseScriptError('TypeError', 1010, 'A term is undefined and has no properties.');
      Source := Arg.Obj;
      if (Source = nil) or (Source.VectorData = nil) then
        RaiseScriptError('TypeError', 1034, 'Type Coercion failed: expected a Vector.');
      SourceElement := Source.ClassObject.VectorElementType;
      if (Numeric and (SourceElement <> Element)) or
        (not Numeric and (SourceElement <> nil) and (SourceElement.PrimitiveKind in [atNumber..atUInt])) then
        RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert ' + Source.DisplayName +
          ' to ' + Obj.DisplayName + '.');
      Added := Source.VectorData.Count;
      if Added = 0 then
        Continue;
      Count := Data.Count;
      if Count + Added > ArrayElementLimit - FArrayElements then
        raise EAVM2Error.Create('AVM2 Vector storage limit');
      StartIndex := Count;
      // SWF 10 inserts every argument immediately after the original vector.
      if FSWFVersion < 11 then
        StartIndex := OriginalLength;
      Dec(FWork, Added + Count - StartIndex);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      Items := Source.VectorData.ToArray;
      if Fixed then
      begin
        VectorElement(Obj, Items[0]);
        RaiseScriptError('RangeError', 1126, 'Cannot change the length of a fixed Vector.');
      end;
      Data.Count := Count + Added;
      for I := Count - 1 downto StartIndex do
        Data[I + Added] := Data[I];
      for I := 0 to Added - 1 do
        Data[StartIndex + I] := VectorElement(Obj, Items[I]);
    end;
    Target := Construct(Obj.ClassObject, nil);
    ResizeVector(Target, Cardinal(Data.Count));
    for I := 0 to Data.Count - 1 do
      Target.VectorData[I] := Data[I];
    Target.VectorFixed := Fixed;
    Result := TAVM2Value.Ref(Target);
  finally
    Data.Free;
  end;
end;

function TAVM2Runtime.SpliceVector(Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Data: TList<TAVM2Value>;
  Target: TAVM2Object;
  Items: TArray<TAVM2Value>;
  Count, StartIndex, EndIndex, DeleteCount, Removed, Delta, ShiftCost, I: Integer;
begin
  Data := Obj.VectorData;
  StartIndex := 0;
  DeleteCount := 0;
  if Length(Args) > 0 then
    StartIndex := Integer(IntBits(CoerceNumber(Args[0])));
  if Length(Args) > 1 then
    DeleteCount := Integer(IntBits(CoerceNumber(Args[1])));
  Count := Data.Count;
  StartIndex := Integer(ClampArrayIndex(StartIndex, Cardinal(Count)));
  if DeleteCount < 0 then
    EndIndex := Max(StartIndex, Integer(ClampArrayIndex(DeleteCount, Cardinal(Count))))
  else
    EndIndex := StartIndex + Min(DeleteCount, Count - StartIndex);
  if Length(Args) > 2 then
  begin
    SetLength(Items, Length(Args) - 2);
    for I := 0 to High(Items) do
      Items[I] := VectorElement(Obj, Args[I + 2]);
  end;
  // Element coercion can call script and resize the receiver.
  Count := Data.Count;
  StartIndex := Min(StartIndex, Count);
  EndIndex := Min(EndIndex, Count);
  Removed := EndIndex - StartIndex;
  Delta := Length(Items) - Removed;
  if Removed + Max(0, Delta) > ArrayElementLimit - FArrayElements then
    raise EAVM2Error.Create('AVM2 Vector storage limit');
  ShiftCost := 0;
  if Delta <> 0 then
    ShiftCost := Count - EndIndex;
  if FWork < ShiftCost + Removed + Abs(Delta) then
    raise EAVM2Error.Create('AVM2 instruction limit');
  Dec(FWork, ShiftCost);
  Target := Construct(Obj.ClassObject, nil);
  ResizeVector(Target, Cardinal(Removed));
  for I := 0 to Removed - 1 do
    Target.VectorData[I] := Data[StartIndex + I];
  if Delta <> 0 then
  begin
    // Flash permits splice to resize a fixed Vector.
    if Delta > 0 then
    begin
      ResizeVector(Obj, Cardinal(Count + Delta));
      for I := Count - 1 downto EndIndex do
        Data[I + Delta] := Data[I];
    end
    else
    begin
      for I := EndIndex to Count - 1 do
        Data[I + Delta] := Data[I];
      ResizeVector(Obj, Cardinal(Count + Delta));
    end;
  end;
  for I := 0 to High(Items) do
    Data[StartIndex + I] := Items[I];
  Result := TAVM2Value.Ref(Target);
end;

function TAVM2Runtime.VectorCallback(Method: TAVM2VectorMethod; Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Callback, Target: TAVM2Object;
  ThisValue, Item, Returned: TAVM2Value;
  CallbackArgs: TArray<TAVM2Value>;
  Items: TList<TAVM2Value>;
  I, Count: Integer;
begin
  Callback := nil;
  if Length(Args) > 0 then
    Callback := CoerceValue(Args[0], atFunction, nil, 'Function').Obj;
  ThisValue := TAVM2Value.Ref(nil);
  if Length(Args) > 1 then
    ThisValue := CoerceValue(Args[1], atObject, nil, 'Object');
  Count := Obj.VectorData.Count;
  Result := Default(TAVM2Value);
  case Method of
    veEvery, veSome:
      Result := TAVM2Value.Num(Ord(Method = veEvery), a2Boolean);
    veMap, veFilter:
      if Callback = nil then
      begin
        Target := Construct(Obj.ClassObject, nil);
        if Method = veMap then
          ResizeVector(Target, Cardinal(Count));
        Exit(TAVM2Value.Ref(Target));
      end;
  end;
  if Callback = nil then
    Exit;
  Items := nil;
  if Method in [veMap, veFilter] then
    Items := TList<TAVM2Value>.Create;
  try
    SetLength(CallbackArgs, 3);
    CallbackArgs[2] := TAVM2Value.Ref(Obj);
    for I := 0 to Count - 1 do
    begin
      Dec(FWork);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      if I >= Obj.VectorData.Count then
        VectorRangeError(Obj, I);
      Item := Obj.VectorData[I];
      CallbackArgs[0] := Item;
      CallbackArgs[1] := TAVM2Value.Num(I, a2UInt);
      Returned := Invoke(Callback, ThisValue, CallbackArgs);
      case Method of
        veEvery:
          if not Truth(Returned) then
            Exit(TAVM2Value.Num(0, a2Boolean));
        veSome:
          if Truth(Returned) then
            Exit(TAVM2Value.Num(1, a2Boolean));
        veMap, veFilter:
          begin
            if Method = veMap then
              Item := VectorElement(Obj, Returned)
            else if not Truth(Returned) then
              Continue;
            if Items.Count >= ArrayElementLimit - FArrayElements then
              raise EAVM2Error.Create('AVM2 Vector storage limit');
            Items.Add(Item);
          end;
      end;
    end;
    if Items <> nil then
    begin
      Target := Construct(Obj.ClassObject, nil);
      ResizeVector(Target, Cardinal(Items.Count));
      for I := 0 to Items.Count - 1 do
        Target.VectorData[I] := Items[I];
      Result := TAVM2Value.Ref(Target);
    end;
  finally
    Items.Free;
  end;
end;

function TAVM2Runtime.InvokeVector(Method: TAVM2VectorMethod; Obj: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  I, J, Count, StartIndex, EndIndex, Added, Step: Integer;
  Data: TList<TAVM2Value>;
  Item, Search: TAVM2Value;
  Items: TArray<TAVM2Value>;
  Target, Element: TAVM2Object;
  Separator: string;

  procedure CheckMutable;
  begin
    if Obj.VectorFixed then
      RaiseScriptError('RangeError', 1126, 'Cannot change the length of a fixed Vector.');
  end;

  function IndexArgument(Argument, DefaultIndex: Integer): Integer;
  begin
    Result := DefaultIndex;
    if Argument < Length(Args) then
      Result := Integer(IntBits(CoerceNumber(Args[Argument])));
  end;

begin
  Result := Default(TAVM2Value);
  if (Obj = nil) or (Obj.VectorData = nil) then
    RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
  Data := Obj.VectorData;
  Count := Data.Count;
  case Method of
    vePush, veUnshift:
      begin
        Added := Length(Args);
        if (Method = vePush) or (Added <> 0) then
          CheckMutable;
        if Added = 0 then
          Exit(TAVM2Value.Num(Count, a2UInt));
        SetLength(Items, Added);
        for I := 0 to High(Items) do
          Items[I] := VectorElement(Obj, Args[I]);
        CheckMutable;
        Count := Data.Count;
        if Method = veUnshift then
        begin
          Dec(FWork, Count);
          if FWork < 0 then
            raise EAVM2Error.Create('AVM2 instruction limit');
        end;
        ResizeVector(Obj, Cardinal(Count + Added));
        StartIndex := Count;
        if Method = veUnshift then
        begin
          for I := Count - 1 downto 0 do
            Data[I + Added] := Data[I];
          StartIndex := 0;
        end;
        for I := 0 to High(Items) do
          Data[StartIndex + I] := Items[I];
        Exit(TAVM2Value.Num(Data.Count, a2UInt));
      end;
    vePop, veShift:
      begin
        CheckMutable;
        if Count = 0 then
        begin
          Element := Obj.ClassObject.VectorElementType;
          if (Element <> nil) and (Element.PrimitiveKind in [atNumber..atUInt]) then
            Result := TAVM2Value.Num(0, a2Int);
          Exit;
        end;
        if Method = vePop then
          Result := Data[Count - 1]
        else
        begin
          Dec(FWork, Count);
          if FWork <= 0 then
            raise EAVM2Error.Create('AVM2 instruction limit');
          Result := Data[0];
          for I := 1 to Count - 1 do
            Data[I - 1] := Data[I];
        end;
        ResizeVector(Obj, Cardinal(Count - 1));
      end;
    veJoin, veToString:
      begin
        Separator := ',';
        if (Method = veJoin) and (Length(Args) > 0) and (Args[0].Kind <> a2Undefined) then
          Separator := CoerceText(Args[0]);
        Exit(TAVM2Value.Str(VectorText(Obj, Separator, 0, Self)));
      end;
    veToLocaleString:
      begin
        Element := Obj.ClassObject.VectorElementType;
        Exit(TAVM2Value.Str(VectorText(Obj, ',', 0, Self,
              (Element = nil) or not (Element.PrimitiveKind in [atNumber..atUInt]))));
      end;
    veSort:
      Exit(SortCollection(Obj, Args, False));
    veReverse:
      begin
        Dec(FWork, Count);
        if FWork < 0 then
          raise EAVM2Error.Create('AVM2 instruction limit');
        for I := 0 to Count div 2 - 1 do
        begin
          J := Count - I - 1;
          Item := Data[I];
          Data[I] := Data[J];
          Data[J] := Item;
        end;
        Exit(TAVM2Value.Ref(Obj));
      end;
    veIndexOf, veLastIndexOf:
      begin
        Search := Default(TAVM2Value);
        if Length(Args) > 0 then
          Search := Args[0];
        if Method = veIndexOf then
        begin
          StartIndex := IndexArgument(1, 0);
          Step := 1;
        end
        else
        begin
          StartIndex := IndexArgument(1, MaxInt);
          Step := -1;
        end;
        Count := Data.Count;
        if StartIndex < 0 then
          Inc(StartIndex, Count);
        if Method = veIndexOf then
          StartIndex := Max(0, StartIndex)
        else
          StartIndex := Min(Count - 1, StartIndex);
        I := StartIndex;
        while (I >= 0) and (I < Count) do
        begin
          Dec(FWork);
          if FWork < 0 then
            raise EAVM2Error.Create('AVM2 instruction limit');
          if Equal(Data[I], Search, True) then
            Exit(TAVM2Value.Num(I, a2Int));
          Inc(I, Step);
        end;
        Exit(TAVM2Value.Num(-1, a2Int));
      end;
    veSlice:
      begin
        StartIndex := IndexArgument(0, 0);
        EndIndex := IndexArgument(1, MaxInt);
        Count := Data.Count;
        StartIndex := Integer(ClampArrayIndex(StartIndex, Cardinal(Count)));
        EndIndex := Integer(ClampArrayIndex(EndIndex, Cardinal(Count)));
        Count := Max(0, EndIndex - StartIndex);
        Target := Construct(Obj.ClassObject, nil);
        ResizeVector(Target, Cardinal(Count));
        for I := 0 to Count - 1 do
          Target.VectorData[I] := Data[StartIndex + I];
        Exit(TAVM2Value.Ref(Target));
      end;
    veConcat:
      Exit(ConcatVector(Obj, Args));
    veSplice:
      Exit(SpliceVector(Obj, Args));
    veEvery..veFilter:
      Exit(VectorCallback(Method, Obj, Args));
    veInsertAt, veRemoveAt:
      begin
        if Length(Args) < 1 + Ord(Method = veInsertAt) then
          RaiseScriptError('ArgumentError', 1063, 'Missing argument for Vector.' + VectorMethodNames[Method] + '.');
        StartIndex := IndexArgument(0, 0);
        if Method = veInsertAt then
          Item := VectorElement(Obj, Args[1]);
        CheckMutable;
        Count := Data.Count;
        if StartIndex < 0 then
          StartIndex := Max(0, StartIndex + Count);
        if Method = veInsertAt then
        begin
          StartIndex := Min(StartIndex, Count);
          Dec(FWork, Count - StartIndex);
          ResizeVector(Obj, Cardinal(Count + 1));
          for I := Count - 1 downto StartIndex do
            Data[I + 1] := Data[I];
          Data[StartIndex] := Item;
        end
        else
        begin
          if StartIndex >= Count then
            VectorRangeError(Obj, StartIndex);
          Dec(FWork, Count - StartIndex);
          if FWork < 0 then
            raise EAVM2Error.Create('AVM2 instruction limit');
          Result := Data[StartIndex];
          Data.Delete(StartIndex);
          Dec(FArrayElements);
        end;
      end;
  end;
end;

function TAVM2Runtime.ValueHasType(const Value: TAVM2Value; Kind: TAVM2TypeKind; ClassObject: TAVM2Object): Boolean;
var
  ValueClass: TAVM2Object;
begin
  case Kind of
    atAny:
      Exit(True);
    atObject:
      Exit(not (Value.Kind in [a2Null, a2Undefined]));
    atString:
      Exit(Value.Kind = a2String);
    atBoolean:
      Exit(Value.Kind = a2Boolean);
    atNumber:
      Exit(Value.Kind in [a2Int, a2UInt, a2Number]);
    atInt:
      Exit((Value.Kind in [a2Int, a2UInt, a2Number]) and
        (Value.Number >= Low(Integer)) and (Value.Number <= High(Integer)) and (Frac(Value.Number) = 0));
    atUInt:
      Exit((Value.Kind in [a2Int, a2UInt, a2Number]) and
        (Value.Number >= 0) and (Value.Number <= High(Cardinal)) and (Frac(Value.Number) = 0));
    atFunction:
      Exit((Value.Kind = a2Object) and (Value.Obj.Kind = a2Function));
    atVoid:
      Exit(Value.Kind = a2Undefined);
  end;
  if Value.Kind = a2Object then
  begin
    if Value.Obj.Kind = a2Class then
      ValueClass := FClassClass
    else
      ValueClass := Value.Obj.ClassObject;
    Exit(ClassHasType(ValueClass, ClassObject));
  end;
  Result := False;
end;

function TAVM2Runtime.ClassHasType(ValueClass, TargetClass: TAVM2Object; Depth: Integer): Boolean;
var
  CheckInterfaces: Boolean;
  InterfaceIndex: Integer;
begin
  if TargetClass = nil then
    Exit(False);
  CheckInterfaces := (TargetClass = FEventDispatcherInterface) or
    ((TargetClass.Module <> nil) and (TargetClass.Index >= 0) and
    (TargetClass.Module.ABC.Instances[TargetClass.Index].Flags and 4 <> 0));
  while ValueClass <> nil do
  begin
    if (ValueClass = TargetClass) or ((TargetClass = FEventDispatcherInterface) and ValueClass.CanDispatch) then
      Exit(True);
    Inc(Depth);
    if Depth >= 128 then
      raise EAVM2Error.Create('AVM2 inheritance depth limit');
    if CheckInterfaces and (ValueClass.Module <> nil) and (ValueClass.Index >= 0) then
      for InterfaceIndex in ValueClass.Module.ABC.Instances[ValueClass.Index].Interfaces do
      begin
        Dec(FWork);
        if FWork < 0 then
          raise EAVM2Error.Create('AVM2 instruction limit');
        if ClassHasType(ResolveTypeClass(ValueClass.Module, InterfaceIndex, 0), TargetClass, Depth) then
          Exit(True);
      end;
    ValueClass := ValueClass.Parent;
  end;
  Result := False;
end;

function TAVM2Runtime.CoerceValue(const Value: TAVM2Value; Kind: TAVM2TypeKind; ClassObject: TAVM2Object; const QualifiedName: string): TAVM2Value;
var
  SourceName: string;
begin
  case Kind of
    atAny:
      Exit(Value);
    atInt:
      Exit(TAVM2Value.Num(Integer(IntBits(CoerceNumber(Value))), a2Int));
    atUInt:
      Exit(TAVM2Value.Num(IntBits(CoerceNumber(Value)), a2UInt));
    atNumber:
      Exit(TAVM2Value.Num(CoerceNumber(Value)));
    atBoolean:
      Exit(TAVM2Value.Num(Ord(Truth(Value)), a2Boolean));
  end;
  if Value.Kind in [a2Null, a2Undefined] then
  begin
    if Kind = atVoid then
      Exit(Default(TAVM2Value));
    Exit(TAVM2Value.Ref(nil));
  end;
  if Kind = atString then
    Exit(TAVM2Value.Str(CoerceText(Value)));
  if ValueHasType(Value, Kind, ClassObject) then
    Exit(Value);
  case Value.Kind of
    a2String:
      SourceName := '"' + Copy(Value.Text, 1, 240) + '"';
    a2Object:
      begin
        SourceName := Value.Obj.DisplayName;
        if SourceName = '' then
          SourceName := 'Object';
      end;
  else
    SourceName := AsText(Value);
  end;
  RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert ' + SourceName + ' to ' + QualifiedName + '.');
  Result := Default(TAVM2Value);
end;

function TAVM2Runtime.MatchesExceptionType(Module: TAVM2Module; Index: Integer; const Value: TAVM2Value): Boolean;
var
  Kind: TAVM2TypeKind;
  ClassObject: TAVM2Object;
  Name: string;
begin
  if Index = 0 then
    Exit(True);
  if Value.Kind in [a2Null, a2Undefined] then
    Exit(False);
  Kind := ResolveType(Module, Index, ClassObject, Name);
  Result := ValueHasType(Value, Kind, ClassObject);
end;

procedure TAVM2Runtime.InstallEventConstants;
const
  Names: array[0..34] of string = ('BACKSPACE', 'TAB', 'ENTER', 'COMMAND', 'SHIFT',
    'CONTROL', 'ALTERNATE', 'CAPS_LOCK', 'NUMPAD', 'ESCAPE', 'SPACE', 'PAGE_UP', 'PAGE_DOWN',
    'END', 'HOME', 'LEFT', 'UP', 'RIGHT', 'DOWN', 'INSERT', 'DELETE', 'NUMPAD_MULTIPLY',
    'NUMPAD_ADD', 'NUMPAD_ENTER', 'NUMPAD_SUBTRACT', 'NUMPAD_DECIMAL', 'NUMPAD_DIVIDE',
    'SEMICOLON', 'EQUAL', 'COMMA', 'MINUS', 'PERIOD', 'SLASH', 'BACKQUOTE', 'LEFTBRACKET');
  Codes: array[0..34] of Word = (8, 9, 13, 15, 16, 17, 18, 20, 21, 27, 32, 33, 34, 35, 36, 37,
    38, 39, 40, 45, 46, 106, 107, 108, 109, 110, 111, 186, 187, 188, 189, 190, 191, 192, 219);
var
  Table, Native: TAVM2Object;
  I: Integer;

  procedure Put(const Name: string; Code: Cardinal);
  begin
    Table.Props.Add(#0 + Name, TAVM2Value.Num(Code, a2UInt));
  end;

begin
  FMouseVisible := True;
  Table := NewObject(a2Class);
  Table.DisplayName := 'flash.ui.Mouse';
  Table.Parent := FObjectClass;
  Table.Props.Add(#0 + 'cursor', TAVM2Value.Str('auto'));
  Table.Props.Add(#0 + 'supportsCursor', TAVM2Value.Num(0, a2Boolean));
  Table.Props.Add(#0 + 'supportsNativeCursor', TAVM2Value.Num(0, a2Boolean));
  Native := NewObject(a2Function);
  Native.Index := MouseShowMethod;
  Table.Props.Add(#0 + 'show', TAVM2Value.Ref(Native));
  Native := NewObject(a2Function);
  Native.Index := MouseHideMethod;
  Table.Props.Add(#0 + 'hide', TAVM2Value.Ref(Native));
  FNative.Props.Add('flash.ui' + #0 + 'Mouse', TAVM2Value.Ref(Table));
  Table := NewObject(a2Class);
  Table.DisplayName := 'flash.ui.MouseCursor';
  Table.Parent := FObjectClass;
  for var CursorName in ['auto', 'arrow', 'button', 'hand', 'ibeam'] do
    Table.Props.Add(#0 + UpperCase(CursorName), TAVM2Value.Str(CursorName));
  FNative.Props.Add('flash.ui' + #0 + 'MouseCursor', TAVM2Value.Ref(Table));
  Table := NewObject(a2Class);
  Table.DisplayName := 'Keyboard';
  FNative.Props.Add('flash.ui' + #0 + 'Keyboard', TAVM2Value.Ref(Table));
  for I := Low(Names) to High(Names) do
    Put(Names[I], Codes[I]);
  Put('BACKSLASH', 220);
  Put('RIGHTBRACKET', 221);
  Put('QUOTE', 222);
  for I := 0 to 9 do
  begin
    Put('NUMBER_' + IntToStr(I), 48 + I);
    Put('NUMPAD_' + IntToStr(I), 96 + I);
  end;
  for I := Ord('A') to Ord('Z') do
    Put(Char(I), I);
  for I := 1 to 15 do
    Put('F' + IntToStr(I), 111 + I);

  Table := NewObject(a2Class);
  Table.DisplayName := 'EventPhase';
  FNative.Props.Add('flash.events' + #0 + 'EventPhase', TAVM2Value.Ref(Table));
  Put('CAPTURING_PHASE', 1);
  Put('AT_TARGET', 2);
  Put('BUBBLING_PHASE', 3);
end;

procedure TAVM2Runtime.BindDispatcher(Instance: TAVM2Object);
var
  Command: TAVM2EventMethod;
begin
  Instance.CanDispatch := True;
  for Command := aeAddListener to aeDispatch do
    Instance.Props.Add(#0 + EventMethods[Command], TAVM2Value.Ref(FEventFunctions[Command]));
end;

function TAVM2Runtime.StageOf(Display: TAVM2Object): TAVM2Object;
begin
  while (Display <> nil) and (Display <> FStage) do
    Display := Display.DisplayParent;
  Result := Display;
end;

procedure TAVM2Runtime.SetStageSize(Width, Height: Integer);
var
  Capabilities: TAVM2Object;
begin
  Capabilities := FNative.Props['flash.system' + #0 + 'Capabilities'].Obj;
  Capabilities.Props.AddOrSetValue(#0 + 'screenResolutionX', TAVM2Value.Num(Width));
  Capabilities.Props.AddOrSetValue(#0 + 'screenResolutionY', TAVM2Value.Num(Height));
  FStage.Props.AddOrSetValue(#0 + 'stageWidth', TAVM2Value.Num(Width, a2Int));
  FStage.Props.AddOrSetValue(#0 + 'stageHeight', TAVM2Value.Num(Height, a2Int));
  FStage.Props.AddOrSetValue(#0 + 'focus', TAVM2Value.Ref(nil));
end;

procedure TAVM2Runtime.SetMovieInfo(const URL: string; SourceBytes, Width, Height: Integer; FrameRate: Double);
var
  Parameters: TAVM2Object;
  Query, Name: string;
  Start, Separator: Integer;
begin
  FMovieURL := URL;
  FLoaderInfo.Props.AddOrSetValue(#0 + 'url', TAVM2Value.Str(URL));
  FLoaderInfo.Props.AddOrSetValue(#0 + 'loaderURL', TAVM2Value.Str(URL));
  FLoaderInfo.Props.AddOrSetValue(#0 + 'bytesLoaded', TAVM2Value.Num(SourceBytes, a2UInt));
  FLoaderInfo.Props.AddOrSetValue(#0 + 'bytesTotal', TAVM2Value.Num(SourceBytes, a2UInt));
  FLoaderInfo.Props.AddOrSetValue(#0 + 'width', TAVM2Value.Num(Width, a2Int));
  FLoaderInfo.Props.AddOrSetValue(#0 + 'height', TAVM2Value.Num(Height, a2Int));
  FLoaderInfo.Props.AddOrSetValue(#0 + 'frameRate', TAVM2Value.Num(FrameRate));
  Parameters := Construct(FObjectClass, nil);
  FLoaderInfo.Props.AddOrSetValue(#0 + 'parameters', TAVM2Value.Ref(Parameters));
  Start := Pos('?', URL);
  if Start = 0 then
    Exit;
  Query := Copy(URL, Start + 1, MaxInt);
  Separator := Pos('#', Query);
  if Separator <> 0 then
    SetLength(Query, Separator - 1);
  for var Pair in Query.Split(['&']) do
  begin
    Separator := Pos('=', Pair);
    if Separator <= 1 then
      Continue;
    Name := TNetEncoding.URL.Decode(Copy(Pair, 1, Separator - 1));
    StoreDynamicProperty(Parameters, #0 + Name,
      TAVM2Value.Str(TNetEncoding.URL.Decode(Copy(Pair, Separator + 1, MaxInt))));
  end;
end;


{$IF Defined(MSWINDOWS) and Defined(CPUX64)}
function FirstAVM2ReferenceSlot(Slots: NativeUInt): Integer; assembler;
asm
        .       NOFRAME
        BSF     RAX, RCX
end;
{$ELSEIF Defined(MSWINDOWS) and Defined(CPUX86)}

function FirstAVM2ReferenceSlot(Slots: NativeUInt): Integer; assembler;
asm
        .       NOFRAME
        BSF     RAX, RCX
end;
{$ELSE}

function FirstAVM2ReferenceSlot(Slots: NativeUInt): Integer;
begin
  Result := 0;
  {$IFDEF CPU64BITS}
  if Slots and $FFFFFFFF = 0 then
  begin
    Inc(Result, 32);
    Slots := Slots shr 32;
  end;
  {$ENDIF}
  if Slots and $FFFF = 0 then
  begin
    Inc(Result, 16);
    Slots := Slots shr 16;
  end;
  if Slots and $FF = 0 then
  begin
    Inc(Result, 8);
    Slots := Slots shr 8;
  end;
  if Slots and $F = 0 then
  begin
    Inc(Result, 4);
    Slots := Slots shr 4;
  end;
  if Slots and 3 = 0 then
  begin
    Inc(Result, 2);
    Slots := Slots shr 2;
  end;
  if Slots and 1 = 0 then
    Inc(Result);
end;
{$ENDIF}

procedure TAVM2Runtime.ReclaimHostObjects(Count: Integer);
begin
  while Count > 0 do
  begin
    Dec(FDeadHostCount);
    FDeadHostObjects[FDeadHostCount].Free;
    FDeadHostObjects[FDeadHostCount] := nil;
    Dec(Count);
  end;
end;

procedure TAVM2Runtime.ReclaimHostSlice;
var
  Count: Integer;
  Started: Int64;
begin
  Count := Min(FDeadHostCount, HostReclaimSliceSize);
  if not Assigned(FOnReclaim) then
  begin
    ReclaimHostObjects(Count);
    Exit;
  end;
  Started := TStopwatch.GetTimeStamp;
  ReclaimHostObjects(Count);
  FOnReclaim(TStopwatch.GetTimeStamp - Started, FDeadHostCount);
end;

procedure TAVM2Runtime.CollectHostObjects;
const
  ScopeCacheMask = 1023;
var
  Objects: TArray<TAVM2Object>;
  Obj: TAVM2Object;
  Index, Alive, WorkCount: Integer;
  Call: TAVM2TimedCall;
  Argument: TAVM2Value;
  Observe: Boolean;
  Stats: TAVM2CollectionStats;
  Started, RootsFinished, MarkFinished, Finished: Int64;
  ScopesSeen: array[0..ScopeCacheMask] of Pointer;

  procedure Mark(Subject: TAVM2Object);
  begin
    if (Subject = nil) or not Subject.HostManaged or Subject.HostMarked then
      Exit;
    Subject.HostMarked := True;
    FCollectionWork[WorkCount] := Subject;
    Inc(WorkCount);
  end;

  procedure MarkScope(const Scope: TArray<TAVM2Value>);
  var
    Address: Pointer;
    Cell: NativeUInt;
  begin
    Address := Pointer(Scope);
    if Address = nil then
      Exit;
    Cell := ((NativeUInt(Address) shr 4) xor (NativeUInt(Address) shr 15)) and ScopeCacheMask;
    if ScopesSeen[Cell] = Address then
      Exit;
    // Closures share immutable captured arrays. The address stays live
    // throughout mark, so a repeated address represents the same edges.
    ScopesSeen[Cell] := Address;
    for var Index := 0 to High(Scope) do
      Mark(Scope[Index].Obj);
  end;

  procedure MarkContainers(Subject: TAVM2Object);
  var
    Value: TAVM2Value;
    Vector: TArray<TAVM2Value>;
    Entry: TPair<TAVM2Object, TAVM2DictionaryEntry>;
  begin
    if Subject.Accessors <> nil then
      for var Accessor in Subject.Accessors.Values do
      begin
        Mark(Accessor.Getter);
        Mark(Accessor.Setter);
      end;
    if Subject.ArrayData <> nil then
      for Value in Subject.ArrayData.Elements.Values do
        Mark(Value.Obj);
    if Subject.VectorData <> nil then
    begin
      Vector := Subject.VectorData.List;
      for var I := 0 to Subject.VectorData.Count - 1 do
        Mark(Vector[I].Obj);
    end;
    if Subject.DictionaryKeys <> nil then
      for Entry in Subject.DictionaryKeys do
      begin
        Mark(Entry.Key);
        Mark(Entry.Value.Value.Obj);
      end;
  end;

  procedure MarkCallbacks(Subject: TAVM2Object);
  var
    Routine: TAVM2Object;
    Listener: TAVM2Listener;
  begin
    if Subject.BoundNativeMethods <> nil then
      for Routine in Subject.BoundNativeMethods.Values do
        Mark(Routine);
    if Subject.Listeners <> nil then
      for Listener in Subject.Listeners do
        Mark(Listener.Callback);
    if Subject.FrameScripts <> nil then
      for Routine in Subject.FrameScripts.Values do
        Mark(Routine);
  end;

  procedure MarkFields(Subject: TAVM2Object);
  var
    Slots: NativeUInt;
    Remaining: Integer;
  begin
    {$IFDEF AVM2_CHECK_GC_REFS}
    var ActualReferences := 0;
    var ActualSlots: NativeUInt := 0;
    for var I := 0 to Subject.Props.FCount - 1 do
    begin
      var Ref := Subject.Props.FEntries[I].Value.Obj;
      if (Ref <> nil) and Ref.HostManaged then
      begin
        Inc(ActualReferences);
        if I < SizeOf(NativeUInt) * 8 then
          ActualSlots := ActualSlots or (NativeUInt(1) shl I);
      end;
    end;
    if (ActualReferences <> Subject.Props.FHostReferences) or (ActualSlots <> Subject.Props.FHostReferenceSlots) then
      raise EAVM2Error.Create('Inconsistent AVM2 property reference count');
    {$ENDIF}
    Slots := Subject.Props.FHostReferenceSlots;
    Remaining := Subject.Props.FHostReferences;
    while Slots <> 0 do
    begin
      Mark(Subject.Props.FEntries[FirstAVM2ReferenceSlot(Slots)].Value.Obj);
      Slots := Slots and (Slots - 1);
      Dec(Remaining);
    end;
    if Remaining > 0 then
      for var I := SizeOf(NativeUInt) * 8 to Subject.Props.FCount - 1 do
        Mark(Subject.Props.FEntries[I].Value.Obj);
    if (Subject.Accessors <> nil) or (Subject.ArrayData <> nil) or
      (Subject.VectorData <> nil) or (Subject.DictionaryKeys <> nil) then
      MarkContainers(Subject);
    MarkScope(Subject.Scope);
    MarkScope(Subject.InstanceScope);
    if (Subject.BoundNativeMethods <> nil) or (Subject.Listeners <> nil) or
      (Subject.FrameScripts <> nil) then
      MarkCallbacks(Subject);
    Mark(Subject.BoundReceiver.Obj);
    Mark(Subject.Parent);
    Mark(Subject.FunctionPrototype);
    Mark(Subject.TransformOwner);
  end;

begin
  // Collection runs between VM calls, when operand stacks are empty.
  Observe := Assigned(FOnCollection);
  if Observe then
  begin
    Stats := Default(TAVM2CollectionStats);
    Stats.MovieTimeMS := FMilliseconds;
    Stats.NewObjects := FNewHostObjects;
    Stats.TrackedObjects := FHostObjects.Count;
    Stats.RootObjects := FObjects.Count;
    Stats.ObjectBytes := Int64(Stats.TrackedObjects) * TAVM2Object.InstanceSize;
    Stats.ByteArrayCapacity := FByteArrayCapacity;
    Stats.ArrayElements := FArrayElements;
    Stats.ClockFrequency := TStopwatch.Frequency;
    Started := TStopwatch.GetTimeStamp;
  end;
  FNewHostObjects := 0;
  // Only host-managed objects enter the queue, each at most once.
  if Length(FCollectionWork) < FHostObjects.Count then
    SetLength(FCollectionWork, Max(FHostObjects.Count, Length(FCollectionWork) * 2));
  WorkCount := 0;
  FillChar(ScopesSeen, SizeOf(ScopesSeen), 0);
  Objects := FObjects.List;
  for Index := 0 to FObjects.Count - 1 do
    MarkFields(Objects[Index]);
  for var Connection in FLocalConnections.Values do
    Mark(Connection);
  for var Load in FURLLoads do
    Mark(Load.Loader);
  for var Phase := Low(TAVM2FrameEvent) to High(TAVM2FrameEvent) do
    for var Target in FFrameEventTargets[Phase] do
      Mark(Target);
  for var Channel in FSoundChannels do
    Mark(Channel);
  for var Message in FConnectionMessages do
  begin
    Mark(Message.Sender);
    for var MessageArgument in Message.Arguments do
      Mark(MessageArgument.Obj);
  end;
  for Call in FTimers do
  begin
    Mark(Call.Owner);
    Mark(Call.Callback);
    for Argument in Call.Args do
      Mark(Argument.Obj);
  end;
  if Observe then
  begin
    RootsFinished := TStopwatch.GetTimeStamp;
    Stats.DirectlyReachable := WorkCount;
  end;
  Index := 0;
  while Index < WorkCount do
  begin
    MarkFields(FCollectionWork[Index]);
    Inc(Index);
  end;
  if Observe then
    MarkFinished := TStopwatch.GetTimeStamp;
  Alive := 0;
  if FDeadHostObjects = nil then
    SetLength(FDeadHostObjects, HostReclaimQueueLimit);
  // Compact the private backing array before trimming its unused tail.
  Objects := FHostObjects.List;
  FHostObjects.OwnsObjects := False;
  try
    for Index := 0 to FHostObjects.Count - 1 do
    begin
      Obj := Objects[Index];
      if Obj.HostMarked then
      begin
        Obj.HostMarked := False;
        if Alive <> Index then
          Objects[Alive] := Obj;
        Inc(Alive);
      end
      else
      begin
        if Obj.ArrayData <> nil then
          Dec(FArrayElements, Obj.ArrayData.Elements.Count);
        if Obj.VectorData <> nil then
          Dec(FArrayElements, Obj.VectorData.Count);
        if Obj.ByteArrayData <> nil then
          Dec(FByteArrayCapacity, Length(Obj.ByteArrayData.Buffer));
        // Finish quota accounting now. Resources with their own pools or
        // potentially large buffers also release synchronously.
        if (FDeadHostCount < HostReclaimQueueLimit) and (Obj.BitmapData = nil) and
          (Obj.FilterData = nil) and (Obj.ByteArrayData = nil) and
          (Obj.ArrayData = nil) and (Obj.VectorData = nil) and (Obj.RegExp = nil) and
          (Obj.XMLDocument = nil) and (Obj.XMLNodes = nil) then
        begin
          FDeadHostObjects[FDeadHostCount] := Obj;
          Inc(FDeadHostCount);
        end
        else
          Obj.Free;
      end;
    end;
    FHostObjects.DeleteRange(Alive, FHostObjects.Count - Alive);
  finally
    FHostObjects.OwnsObjects := True;
  end;
  if Observe then
  begin
    Finished := TStopwatch.GetTimeStamp;
    Stats.RootTicks := RootsFinished - Started;
    Stats.MarkTicks := MarkFinished - RootsFinished;
    Stats.SweepTicks := Finished - MarkFinished;
    Stats.LiveObjects := Alive;
    Stats.FreedObjects := Stats.TrackedObjects - Alive;
    Stats.PendingObjects := FDeadHostCount;
    Stats.ObjectBytesAfter := Int64(Alive) * TAVM2Object.InstanceSize;
    Stats.ByteArrayCapacityAfter := FByteArrayCapacity;
    Stats.ArrayElementsAfter := FArrayElements;
    FOnCollection(Stats);
  end;
end;

procedure TAVM2Runtime.InitEvent(Event: TAVM2Object; Kind: TAVM2EventKind; const Name: string; Bubbles, Cancelable: Boolean);
var
  Command: TAVM2EventMethod;
begin
  Event.EventKind := Kind;
  Event.Props.AddOrSetValue(#0 + 'type', TAVM2Value.Str(Name));
  Event.Props.AddOrSetValue(#0 + 'bubbles', TAVM2Value.Num(Ord(Bubbles), a2Boolean));
  Event.Props.AddOrSetValue(#0 + 'cancelable', TAVM2Value.Num(Ord(Cancelable), a2Boolean));
  Event.Props.AddOrSetValue(#0 + 'target', TAVM2Value.Ref(nil));
  Event.Props.AddOrSetValue(#0 + 'currentTarget', TAVM2Value.Ref(nil));
  Event.Props.AddOrSetValue(#0 + 'eventPhase', TAVM2Value.Num(2, a2UInt));
  for Command := aeStop to aeToString do
    Event.Props.AddOrSetValue(#0 + EventMethods[Command], TAVM2Value.Ref(FEventFunctions[Command]));
end;

function TAVM2Runtime.HostEventObject(EventClass: TAVM2Object; const Name: string; Bubbles, Cancelable: Boolean): TAVM2Object;
begin
  Result := NewObject(a2PlainObject, True);
  Result.DisplayName := EventClass.DisplayName;
  Result.ClassObject := EventClass;
  Result.Parent := ClassPrototype(EventClass);
  InitEvent(Result, EventClass.EventKind, Name, Bubbles, Cancelable);
end;

function TAVM2Runtime.HasListener(Receiver: TAVM2Object; const Name: string; IncludeAncestors: Boolean): Boolean;
var
  Listener: TAVM2Listener;
begin
  while Receiver <> nil do
  begin
    if Receiver.Listeners <> nil then
      for Listener in Receiver.Listeners do
        if Listener.Name = Name then
          Exit(True);
    if not IncludeAncestors then
      Break;
    Receiver := Receiver.DisplayParent;
  end;
  Result := False;
end;

function TAVM2Runtime.EventCall(Command: TAVM2EventMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Listener, Existing: TAVM2Listener;
  Event: TAVM2Object;
  Position, I, BroadcastIndex: Integer;
begin
  Result := Default(TAVM2Value);
  if Receiver = nil then
    raise EAVM2Error.Create('Missing AVM2 event receiver');
  if Command >= aeStop then
  begin
    if Receiver.EventKind = aeNone then
      raise EAVM2Error.Create('AVM2 receiver is not an Event');
    case Command of
      aeStop:
        Receiver.EventStop := Max(Receiver.EventStop, 1);
      aeStopImmediate:
        Receiver.EventStop := 2;
      aePreventDefault:
        if Truth(Receiver.Props[#0 + 'cancelable']) then
          Receiver.EventCancelled := True;
      aeIsDefaultPrevented:
        Result := TAVM2Value.Num(Ord(Receiver.EventCancelled), a2Boolean);
      aeToString:
        Result := TAVM2Value.Str(Format('[%s type="%s" bubbles=%s cancelable=%s eventPhase=%s]',
            [Receiver.DisplayName, AsText(Receiver.Props[#0 + 'type']), AsText(Receiver.Props[#0 + 'bubbles']),
              AsText(Receiver.Props[#0 + 'cancelable']), AsText(Receiver.Props[#0 + 'eventPhase'])]));
    end;
    Exit;
  end;
  if not Receiver.CanDispatch then
    raise EAVM2Error.Create('AVM2 receiver is not an EventDispatcher');
  if Length(Args) = 0 then
    raise EAVM2Error.Create('Missing AVM2 event argument');
  if Command = aeDispatch then
  begin
    Event := Args[0].Obj;
    if (Event = nil) or (Event.EventKind = aeNone) then
      raise EAVM2Error.Create('Missing AVM2 Event object');
    Exit(TAVM2Value.Num(Ord(DispatchEventTo(Receiver, Event, False)), a2Boolean));
  end;
  Listener.Name := AsText(Args[0]);
  if Command in [aeHasListener, aeWillTrigger] then
    Exit(TAVM2Value.Num(Ord(HasListener(Receiver, Listener.Name, Command = aeWillTrigger)), a2Boolean));
  if (Length(Args) < 2) or (Args[1].Obj = nil) or (Args[1].Obj.Kind <> a2Function) then
    raise EAVM2Error.Create('AVM2 event listener must be a function');
  BroadcastIndex := -1;
  if (Receiver = FStage) or (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
    BroadcastIndex := IndexStr(Listener.Name, FrameEventNames);
  Listener.Callback := Args[1].Obj;
  Listener.Capture := (Length(Args) > 2) and Truth(Args[2]);
  Listener.Priority := 0;
  if Length(Args) > 3 then
    Listener.Priority := Integer(IntBits(AsNumber(Args[3])));
  if Receiver.Listeners = nil then
  begin
    if Command = aeRemoveListener then
      Exit;
    Receiver.Listeners := TList<TAVM2Listener>.Create;
  end;
  Position := Receiver.Listeners.Count;
  for I := 0 to Receiver.Listeners.Count - 1 do
  begin
    Existing := Receiver.Listeners[I];
    if (Existing.Name = Listener.Name) and (Existing.Callback = Listener.Callback) and
      (Existing.Capture = Listener.Capture) then
    begin
      if Command = aeRemoveListener then
      begin
        Receiver.Listeners.Delete(I);
        if (BroadcastIndex >= 0) and not HasListener(Receiver, Listener.Name, False) then
          FFrameEventTargets[TAVM2FrameEvent(BroadcastIndex)].Remove(Receiver);
      end;
      Exit;
    end;
    if (Existing.Priority < Listener.Priority) and (Position = Receiver.Listeners.Count) then
      Position := I;
  end;
  if Command = aeRemoveListener then
    Exit;
  if Receiver.Listeners.Count >= 4096 then
    raise EAVM2Error.Create('AVM2 listener limit');
  if (BroadcastIndex >= 0) and not HasListener(Receiver, Listener.Name, False) then
    FFrameEventTargets[TAVM2FrameEvent(BroadcastIndex)].Add(Receiver);
  Receiver.Listeners.Insert(Position, Listener);
end;

function TAVM2Runtime.DispatchEventTo(Target, Event: TAVM2Object; BroadcastOnly: Boolean): Boolean;
var
  Ancestors: array[0..255] of TAVM2Object;
  Parent, Original: TAVM2Object;
  Count, I: Integer;
  Name: string;
  Prop: TPair<string, TAVM2Value>;

  procedure DispatchPhase(Receiver: TAVM2Object; Phase: Integer);
  var
    List: TArray<TAVM2Listener>;
    Listener: TAVM2Listener;
    SetCurrent: Boolean;
  begin
    if Receiver.Listeners = nil then
      Exit;
    List := Receiver.Listeners.ToArray;
    SetCurrent := False;
    for Listener in List do
    begin
      if Event.EventStop = 2 then
        Break;
      if (Listener.Name <> Name) or (Listener.Capture <> (Phase = 1)) then
        Continue;
      if not SetCurrent then
      begin
        Event.Props.AddOrSetValue(#0 + 'currentTarget', TAVM2Value.Ref(Receiver));
        Event.Props.AddOrSetValue(#0 + 'eventPhase', TAVM2Value.Num(Phase, a2UInt));
        SetCurrent := True;
      end;
      Invoke(Listener.Callback, Listener.Callback.Script, [TAVM2Value.Ref(Event)]);
    end;
  end;

begin
  Name := Event.Props[#0 + 'type'].Text;
  if Event.EventDispatching or (Event.Props[#0 + 'target'].Obj <> nil) then
  begin
    Original := Event;
    Event := HostEventObject(Original.ClassObject, Name, Truth(Original.Props[#0 + 'bubbles']),
      Truth(Original.Props[#0 + 'cancelable']));
    for var EntryIndex := 0 to Original.Props.FCount - 1 do
    begin
      Prop := Original.Props.FEntries[EntryIndex];
      if (Prop.Key <> #0 + 'currentTarget') and (Prop.Key <> #0 + 'target') and
        (Prop.Key <> #0 + 'eventPhase') then
        Event.Props.AddOrSetValue(Prop.Key, Prop.Value);
    end;
  end;
  Event.EventDispatching := True;
  Event.Props.AddOrSetValue(#0 + 'target', TAVM2Value.Ref(Target));
  try
    Count := 0;
    if not BroadcastOnly then
    begin
      Parent := Target.DisplayParent;
      while Parent <> nil do
      begin
        if Count >= Length(Ancestors) then
          raise EAVM2Error.Create('AVM2 event ancestry limit');
        Ancestors[Count] := Parent;
        Inc(Count);
        Parent := Parent.DisplayParent;
      end;
      for I := Count - 1 downto 0 do
      begin
        if Event.EventStop <> 0 then
          Break;
        DispatchPhase(Ancestors[I], 1);
      end;
    end;
    if Event.EventStop = 0 then
      DispatchPhase(Target, 2);
    if not BroadcastOnly and Truth(Event.Props[#0 + 'bubbles']) then
      for I := 0 to Count - 1 do
      begin
        if Event.EventStop <> 0 then
          Break;
        DispatchPhase(Ancestors[I], 3);
      end;
    Result := not Event.EventCancelled;
  finally
    Event.EventDispatching := False;
  end;
end;

procedure TAVM2Runtime.BroadcastFrameEvent(Phase: TAVM2FrameEvent);
var
  Receiver: TAVM2Object;
  Name: string;
begin
  Name := FrameEventNames[Phase];
  for Receiver in FFrameEventTargets[Phase].ToArray do
    if HasListener(Receiver, Name, False) then
      DispatchEventTo(Receiver, HostEventObject(FEnterFrameClass, Name, False, False), True);
end;

procedure TAVM2Runtime.Keyboard(Code, CharCode: Integer; Pressed, Ctrl, Alt, Shift: Boolean);
var
  Target, Event: TAVM2Object;
  Name: string;
begin
  Target := FFocus;
  if StageOf(Target) <> FStage then
    Target := FStage;
  if Pressed then
    Name := 'keyDown'
  else
    Name := 'keyUp';
  if not HasListener(Target, Name, True) then
    Exit;
  Event := HostEventObject(FKeyboardClass, Name, True, False);
  Event.Props.Add(#0 + 'keyCode', TAVM2Value.Num(Code, a2UInt));
  Event.Props.Add(#0 + 'charCode', TAVM2Value.Num(CharCode, a2UInt));
  Event.Props.Add(#0 + 'keyLocation', TAVM2Value.Num(0, a2UInt));
  Event.Props.Add(#0 + 'ctrlKey', TAVM2Value.Num(Ord(Ctrl), a2Boolean));
  Event.Props.Add(#0 + 'altKey', TAVM2Value.Num(Ord(Alt), a2Boolean));
  Event.Props.Add(#0 + 'shiftKey', TAVM2Value.Num(Ord(Shift), a2Boolean));
  DispatchEventTo(Target, Event, False);
end;

function TAVM2Runtime.DisplayObjectAt(Handle: TObject): TAVM2Object;
begin
  if not FDisplayObjects.TryGetValue(Handle, Result) or
    not (Result.DisplayKind in [adContainer, adSprite, adMovieClip, adText, adButton]) then
    Result := nil;
end;

procedure TAVM2Runtime.Mouse(Target: TAVM2Object; const Name: string; StageX, StageY, LocalX, LocalY: Double; ButtonDown, Ctrl, Alt, Shift: Boolean);
var
  Event: TAVM2Object;
begin
  if StageOf(Target) <> FStage then
    Target := FStage;
  if not HasListener(Target, Name, True) then
    Exit;
  Event := HostEventObject(FMouseClass, Name, True, False);
  Event.Props.Add(#0 + 'stageX', TAVM2Value.Num(StageX));
  Event.Props.Add(#0 + 'stageY', TAVM2Value.Num(StageY));
  Event.Props.Add(#0 + 'localX', TAVM2Value.Num(LocalX));
  Event.Props.Add(#0 + 'localY', TAVM2Value.Num(LocalY));
  Event.Props.Add(#0 + 'buttonDown', TAVM2Value.Num(Ord(ButtonDown), a2Boolean));
  Event.Props.Add(#0 + 'ctrlKey', TAVM2Value.Num(Ord(Ctrl), a2Boolean));
  Event.Props.Add(#0 + 'altKey', TAVM2Value.Num(Ord(Alt), a2Boolean));
  Event.Props.Add(#0 + 'shiftKey', TAVM2Value.Num(Ord(Shift), a2Boolean));
  DispatchEventTo(Target, Event, False);
end;

procedure TAVM2Runtime.DispatchAddedToStage(Instance: TAVM2Object; Depth: Integer);
begin
  if (Depth >= 128) or (StageOf(Instance) <> FStage) then
    Exit;
  if HasListener(Instance, 'addedToStage', False) then
    DispatchEventTo(Instance, HostEventObject(FEnterFrameClass, 'addedToStage', False, False), False);
  if Instance.DisplayChildren <> nil then
    for var Child in Instance.DisplayChildren.ToArray do
      if Child.DisplayParent = Instance then
        DispatchAddedToStage(Child, Depth + 1);
end;

procedure TAVM2Runtime.DispatchRemovedFromStage(Instance: TAVM2Object; Depth: Integer);
begin
  if (Depth >= 128) or (StageOf(Instance) <> FStage) then
    Exit;
  if HasListener(Instance, 'removedFromStage', False) then
    DispatchEventTo(Instance, HostEventObject(FEnterFrameClass, 'removedFromStage', False, False), False);
  if Instance.DisplayChildren <> nil then
    for var Child in Instance.DisplayChildren.ToArray do
      if Child.DisplayParent = Instance then
        DispatchRemovedFromStage(Child, Depth + 1);
end;

procedure TAVM2Runtime.DispatchRemoval(Instance: TAVM2Object; LeavingStage: Boolean);
var
  PreviousParent: TAVM2Object;
begin
  if Instance.DisplayRemoving then
    Exit;
  Instance.DisplayRemoving := True;
  try
    PreviousParent := Instance.DisplayParent;
    if HasListener(Instance, 'removed', True) then
      DispatchEventTo(Instance, HostEventObject(FEnterFrameClass, 'removed', True, False), False);
    if LeavingStage and (Instance.DisplayParent = PreviousParent) then
      DispatchRemovedFromStage(Instance);
  finally
    Instance.DisplayRemoving := False;
  end;
end;

procedure TAVM2Runtime.BindDisplay(Instance: TAVM2Object; Kind: TAVM2DisplayKind; Document: Boolean; Existing: TObject);
var
  Graphics: TAVM2Object;
  AClass: TAVM2Object;
  Command: TAVM2DisplayMethod;
  Name, InstanceName, QualifiedName: string;
  Classes: TArray<string>;
  Empty: TAVM2Value;
begin
  if Kind = adNone then
    Exit;
  InstanceName := '';
  Instance.DisplayKind := Kind;
  if FDisplay <> nil then
  begin
    Instance.DisplayData := Existing;
    if Instance.DisplayData = nil then
    begin
      if not Document and (Kind in [adSprite, adMovieClip]) then
      begin
        AClass := Instance.ClassObject;
        while (AClass <> nil) and (AClass.Module <> nil) do
        begin
          for QualifiedName in Names(AClass.Module, AClass.Module.ABC.Instances[AClass.Index].Name) do
            if QualifiedName[1] = #0 then
              Classes := Classes + [Copy(QualifiedName, 2, MaxInt)]
            else
              Classes := Classes + [StringReplace(QualifiedName, #0, '.', [])];
          AClass := AClass.Parent;
        end;
      end;
      Instance.DisplayData := FDisplay.CreateDisplay(Document, Classes, InstanceName);
      if Kind = adText then
        FDisplay.InitializeText(Instance.DisplayData);
    end;
    FDisplayObjects.Add(Instance.DisplayData, Instance);
  end;
  Instance.Props.Add(#0 + 'stage', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'root', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'loaderInfo', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'x', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'y', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'width', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'height', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'filters', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'scaleX', TAVM2Value.Num(1));
  Instance.Props.Add(#0 + 'scaleY', TAVM2Value.Num(1));
  Instance.Props.Add(#0 + 'rotation', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'alpha', TAVM2Value.Num(1));
  Instance.Props.Add(#0 + 'visible', TAVM2Value.Num(1, a2Boolean));
  Instance.Props.Add(#0 + 'name', TAVM2Value.Str(InstanceName));
  for Command := adLocalToGlobal to adGetRect do
    Instance.Props.Add(#0 + DisplayMethods[Command], TAVM2Value.Ref(FDisplayFunctions[Command]));
  Instance.Props.Add(#0 + 'scrollRect', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'mask', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'transform', Default(TAVM2Value));
  Empty := Default(TAVM2Value);
  Empty.Kind := a2Null;
  Instance.Props.Add(#0 + 'parent', Empty);
  if Kind in [adContainer, adSprite, adMovieClip] then
  begin
    Instance.DisplayChildren := TList<TAVM2Object>.Create;
    Instance.Props.Add(#0 + 'numChildren', TAVM2Value.Num(0, a2Int));
    for Command := adAddChild to adContains do
      Instance.Props.Add(#0 + DisplayMethods[Command], TAVM2Value.Ref(FDisplayFunctions[Command]));
    Instance.Props.Add(#0 + 'getChildByName', TAVM2Value.Ref(FDisplayFunctions[adGetChildByName]));
  end;
  if Kind in [adShape, adSprite, adMovieClip] then
  begin
    Graphics := NewObject(a2PlainObject);
    Graphics.DisplayKind := adGraphics;
    Graphics.DisplayName := 'Graphics';
    Graphics.DisplayData := Instance.DisplayData;
    for Command := adClear to adLineStyle do
    begin
      Name := DisplayMethods[Command];
      Graphics.Props.Add(#0 + Name, TAVM2Value.Ref(FDisplayFunctions[Command]));
    end;
    Instance.Props.Add(#0 + 'graphics', TAVM2Value.Ref(Graphics));
  end;
end;

procedure TAVM2Runtime.RebuildTimelineBindings(Parent: TAVM2Object; ClearRemovedSlots: Boolean);
var
  Previous, Current: TDictionary<string, TAVM2Object>;
  Item: TPair<string, TAVM2Object>;
  Child, OldChild: TAVM2Object;
  Key: string;
  Stored: TAVM2Value;
begin
  if (Parent = nil) or (Parent.DisplayChildren = nil) then
    Exit;
  Previous := Parent.TimelineBindings;
  Current := nil;
  try
    for Child in Parent.DisplayChildren do
    begin
      if not Child.TimelinePlaced then
        Continue;
      Key := Child.Props[#0 + 'name'].Text;
      if Key = '' then
        Continue;
      Key := #0 + Key;
      if Current = nil then
        Current := TDictionary<string, TAVM2Object>.Create;
      if not Current.ContainsKey(Key) then
        Current.Add(Key, Child);
    end;
    if ClearRemovedSlots and (Previous <> nil) then
      for Item in Previous do
        if ((Current = nil) or not Current.TryGetValue(Item.Key, Child) or (Child <> Item.Value)) and
          Parent.Props.TryGetValue(Item.Key, Stored) and (Stored.Obj = Item.Value) then
          Parent.Props[Item.Key] := TAVM2Value.Ref(nil);
    if Current <> nil then
      for Item in Current do
        if ((Previous = nil) or not Previous.TryGetValue(Item.Key, OldChild) or (OldChild <> Item.Value)) and
          Parent.Props.TryGetValue(Item.Key, Stored) and (Stored.Kind in [a2Null, a2Undefined]) then
          Parent.Props[Item.Key] := TAVM2Value.Ref(Item.Value);
    Parent.TimelineBindings := Current;
    Current := nil;
    Previous.Free;
  finally
    Current.Free;
  end;
end;

procedure TAVM2Runtime.SyncDisplayChildren(Parent: TAVM2Object; Depth: Integer);
var
  Descriptions: TArray<TAVM2TimelineChild>;
  Description: TAVM2TimelineChild;
  Seen: TDictionary<TAVM2Object, Boolean>;
  Children: TArray<TAVM2Object>;
  Child, NativeClass, SymbolClass, Base: TAVM2Object;
  I: Integer;
begin
  if (FDisplay = nil) or (Parent = nil) or (Parent.DisplayData = nil) or (Parent.DisplayChildren = nil) then
    Exit;
  if Depth >= 128 then
    raise EAVM2Error.Create('AVM2 display nesting limit');
  Descriptions := FDisplay.DisplayChildren(Parent.DisplayData);
  if (Length(Descriptions) = 0) and (Parent.DisplayChildren.Count = 0) then
    Exit;
  Dec(FWork, Length(Descriptions) + Parent.DisplayChildren.Count);
  if FWork < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');
  SetLength(Children, Length(Descriptions));
  Seen := TDictionary<TAVM2Object, Boolean>.Create;
  try
    for I := 0 to High(Descriptions) do
    begin
      Description := Descriptions[I];
      if not FDisplayObjects.TryGetValue(Description.Handle, Child) then
      begin
        if Description.ClassName = 'TextField' then
          NativeClass := FTextFieldClass
        else
          NativeClass := FNative.Props['flash.display' + #0 + Description.ClassName].Obj;
        SymbolClass := LinkedClass(Description.SymbolClass);
        Base := SymbolClass;
        while (Base <> nil) and (Base <> NativeClass) do
          Base := Base.Parent;
        if (Base = nil) and ((SymbolClass = nil) or (Description.ClassName <> 'MovieClip') or
          not (SymbolClass.DisplayKind in [adContainer, adSprite])) then
          SymbolClass := NativeClass;
        Child := NewObject(a2PlainObject);
        Child.ClassObject := SymbolClass;
        Child.Parent := ClassPrototype(SymbolClass);
        Child.DisplayName := Description.ClassName;
        if SymbolClass <> NativeClass then
          Child.DisplayName := SymbolClass.DisplayName;
        Child.TimelinePlaced := True;
        Child.TimelineConstructorPending := True;
        if SymbolClass.CanDispatch then
          BindDispatcher(Child);
        BindDisplay(Child, SymbolClass.DisplayKind, False, Description.Handle);
        InstallInstanceTraits(SymbolClass, Child);
        SyncDisplayChildren(Child, Depth + 1);
      end;
      if Child.TimelinePlaced then
      begin
        Child.Props[#0 + 'name'] := TAVM2Value.Str(Description.Name);
        Child.Props[#0 + 'x'] := TAVM2Value.Num(Description.X);
        Child.Props[#0 + 'y'] := TAVM2Value.Num(Description.Y);
        Child.Props[#0 + 'scaleX'] := TAVM2Value.Num(Description.ScaleX);
        Child.Props[#0 + 'scaleY'] := TAVM2Value.Num(Description.ScaleY);
        Child.Props[#0 + 'rotation'] := TAVM2Value.Num(Description.Rotation);
        Child.Props[#0 + 'alpha'] := TAVM2Value.Num(Description.Alpha);
        Child.Props[#0 + 'visible'] := TAVM2Value.Num(Ord(Description.Visible), a2Boolean);
      end;
      Child.DisplayParent := Parent;
      Child.Props[#0 + 'parent'] := TAVM2Value.Ref(Parent);
      Children[I] := Child;
      Seen.Add(Child, True);
    end;
    for Child in Parent.DisplayChildren do
      if (Child.DisplayParent = Parent) and not Seen.ContainsKey(Child) then
      begin
        Child.DisplayParent := nil;
        Child.Props[#0 + 'parent'] := TAVM2Value.Ref(nil);
      end;
    Parent.DisplayChildren.Clear;
    Parent.DisplayChildren.AddRange(Children);
    Parent.Props[#0 + 'numChildren'] := TAVM2Value.Num(Length(Children), a2Int);
    RebuildTimelineBindings(Parent);
  finally
    Seen.Free;
  end;
end;

procedure TAVM2Runtime.ConstructTimelineChildren(Parent: TAVM2Object);
var
  Child: TAVM2Object;
begin
  if (Parent = nil) or (Parent.DisplayChildren = nil) then
    Exit;
  for Child in Parent.DisplayChildren.ToArray do
    if (Child.DisplayParent = Parent) and Child.TimelineConstructorPending then
    begin
      Child.TimelineConstructorPending := False;
      ConstructInto(Child.ClassObject, Child, nil);
    end;
end;

procedure TAVM2Runtime.SyncTimelineDisplay(Handle: TObject);
var
  Parent: TAVM2Object;
begin
  Parent := DisplayObjectAt(Handle);
  SyncDisplayChildren(Parent, 0);
  ConstructTimelineChildren(Parent);
end;

function TAVM2Runtime.QualifiedClassName(Obj: TAVM2Object): string;
begin
  Result := Obj.DisplayName;
  if (Obj.Module <> nil) and (Obj.Index >= 0) then
  begin
    Result := TraitKey(Obj.Module, Obj.Module.ABC.Instances[Obj.Index].Name);
    if StartsStr(#0, Result) then
      Delete(Result, 1, 1)
    else
      Result := StringReplace(Result, #0, '.', []);
  end;
end;

function TAVM2Runtime.SuperMember(Base, Receiver: TAVM2Object; const Names: TArray<string>; Kind: Integer): TAVM2Value;
var
  Trait: TABCTrait;
  Name, TraitName: string;
  Method: TAVM2Object;
  EventMethod: TAVM2EventMethod;
  DisplayMethod: TAVM2DisplayMethod;
begin
  while (Base <> nil) and (Base.Module <> nil) and (Base.Index >= 0) do
  begin
    for Trait in Base.Module.ABC.Instances[Base.Index].Definition.Traits do
      if (Trait.Kind = Kind) or ((Kind = 2) and (Trait.Kind = 1)) then
      begin
        TraitName := TraitKey(Base.Module, Trait.Name);
        for Name in Names do
          if (Name = TraitName) or (StartsStr('#24:', Name) and StartsStr('#24:', TraitName) and
            (Copy(Name, Pos(#0, Name), MaxInt) = Copy(TraitName, Pos(#0, TraitName), MaxInt))) then
          begin
            Method := NewObject(a2Function, True);
            Method.Module := Base.Module;
            Method.Index := Trait.Target;
            if Trait.Kind = 2 then
              Method.State := 1;
            Method.ClassObject := Base;
            Method.Script := Base.Script;
            Method.Scope := Base.InstanceScope;
            Method.BoundReceiver := TAVM2Value.Ref(Receiver);
            Exit(TAVM2Value.Ref(Method));
          end;
      end;
    Base := Base.Parent;
  end;
  Result := Default(TAVM2Value);
  if (Base = nil) or not (Kind in [1, 2]) then
    Exit;
  Result := PropertyValue(ClassPrototype(Base), Names);
  if Result.Kind <> a2Undefined then
    Exit;
  for Name in Names do
  begin
    if Base.CanDispatch then
      for EventMethod := aeAddListener to aeDispatch do
        if Name = #0 + EventMethods[EventMethod] then
          Exit(TAVM2Value.Ref(FEventFunctions[EventMethod]));
    if Base.DisplayKind <> adNone then
      for DisplayMethod := Low(TAVM2DisplayMethod) to High(TAVM2DisplayMethod) do
        if Name = #0 + DisplayMethods[DisplayMethod] then
          Exit(TAVM2Value.Ref(FDisplayFunctions[DisplayMethod]));
    if Base.DisplayKind = adMovieClip then
    begin
      if Name = #0 + 'play' then
        Exit(TAVM2Value.Ref(FPlayMovieClip));
      if Name = #0 + 'stop' then
        Exit(TAVM2Value.Ref(FStopMovieClip));
      if Name = #0 + 'gotoAndPlay' then
        Exit(TAVM2Value.Ref(FGotoAndPlay));
      if Name = #0 + 'gotoAndStop' then
        Exit(TAVM2Value.Ref(FGotoAndStop));
    end;
  end;
end;

procedure TAVM2Runtime.SetProperty(Receiver: TAVM2Object; const Keys: TArray<string>; const Value: TAVM2Value; UseAccessor: Boolean);
var
  Key, Candidate, Name: string;
  Normalized: TAVM2Value;
  Number: Double;
  Index: Cardinal;
  RepeatCount: Integer;
  Rect: TAVM2Rectangle;
  RectObject: TAVM2Object;
  SourceObject, Owner, PreviousFocus, FocusEvent: TAVM2Object;
  Accessor: TAVM2Accessor;
  Color: TSWFColorTransform;
begin
  if Receiver.VectorData <> nil then
  begin
    SetVectorProperty(Receiver, Keys, Value);
    Exit;
  end;
  Key := Keys[0];
  for Candidate in Keys do
  begin
    if ((Receiver.IsMatrix and (IndexStr(Candidate, MatrixFields) >= 0)) or
      (Receiver.IsVector3D and (IndexStr(Candidate, Vector3DFields) >= 0))) then
    begin
      Receiver.Props[Candidate] := TAVM2Value.Num(CoerceNumber(Value));
      Exit;
    end;
    Owner := Receiver.TransformOwner;
    if Owner <> nil then
    begin
      if Candidate = #0 + 'colorTransform' then
      begin
        SourceObject := CoerceValue(Value, atClass, FColorTransformClass, 'flash.geom.ColorTransform').Obj;
        if SourceObject = nil then
          RaiseScriptError('TypeError', 2007, 'Color transform must be non-null.');
        for var I := 0 to 3 do
        begin
          Color.Mult[I] := CoerceNumber(SourceObject.Props[#0 + ColorTransformFields[I]]);
          Number := CoerceNumber(SourceObject.Props[#0 + ColorTransformFields[I + 4]]);
          Color.Add[I] := Integer(IntBits(Number));
        end;
        if FDisplay <> nil then
          FDisplay.SetColorTransform(Owner.DisplayData, Color);
        Exit;
      end;
      if Candidate = #0 + 'matrix' then
      begin
        SourceObject := CoerceValue(Value, atClass, FMatrixClass, 'flash.geom.Matrix').Obj;
        if SourceObject <> nil then
          ApplyDisplayMatrix(Owner, ReadNativeMatrix(SourceObject));
        Owner.Matrix3DActive := SourceObject = nil;
        Exit;
      end;
      if (Candidate = #0 + 'concatenatedMatrix') or (Candidate = #0 + 'pixelBounds') then
        RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property ' +
          Copy(Candidate, 2, MaxInt) + ' on Transform.');
    end;
    if (Candidate = #0 + 'transform') and (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
    begin
      SourceObject := CoerceValue(Value, atClass, FTransformClass, 'flash.geom.Transform').Obj;
      if SourceObject = nil then
        RaiseScriptError('TypeError', 2007, 'Parameter transform must be non-null.');
      Owner := SourceObject.TransformOwner;
      if (Owner <> nil) and (FDisplay <> nil) then
      begin
        ApplyDisplayMatrix(Receiver, FDisplay.GetMatrix(Owner.DisplayData, False, False));
        Receiver.Matrix3DActive := Owner.Matrix3DActive;
      end;
      Exit;
    end;
    if Receiver.IsRectangle and SetRectangleProperty(Receiver, Candidate, Value) then
      Exit;
    if (Candidate = #0 + 'scrollRect') and (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
    begin
      RectObject := RectangleArgument(Value, True);
      if RectObject = nil then
        Rect := Default(TAVM2Rectangle)
      else
        Rect := ReadNativeRectangle(RectObject);
      if FDisplay <> nil then
        FDisplay.SetScrollRect(Receiver.DisplayData, RectObject <> nil, Rect);
      Exit;
    end;
    if Receiver.IsPoint then
    begin
      if (Candidate = #0 + 'x') or (Candidate = #0 + 'y') then
      begin
        Receiver.Props[Candidate] := TAVM2Value.Num(CoerceNumber(Value));
        Exit;
      end;
      if Candidate = #0 + 'length' then
        RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property length on Point.');
    end;
    if Receiver.IsTimer then
    begin
      if Candidate = #0 + 'delay' then
      begin
        SetTimerDelay(Receiver, CoerceNumber(Value));
        Exit;
      end;
      if Candidate = #0 + 'repeatCount' then
      begin
        RepeatCount := Integer(IntBits(CoerceNumber(Value)));
        Receiver.Props.AddOrSetValue(Candidate, TAVM2Value.Num(RepeatCount, a2Int));
        if (RepeatCount <> 0) and (RepeatCount <= Receiver.Props[#0 + 'currentCount'].Number) then
          RemoveTimer(Receiver.TimerID);
        Exit;
      end;
      if (Candidate = #0 + 'running') or (Candidate = #0 + 'currentCount') then
        RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property ' +
          Copy(Candidate, 2, MaxInt) + ' on Timer.');
    end;
    if (Receiver.RegExp <> nil) and RegExpProperty(Receiver.RegExp, Candidate, Normalized) then
    begin
      if Candidate = #0 + 'lastIndex' then
        Receiver.RegExp.LastIndex := Integer(IntBits(AsNumber(Value)))
      else
        RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property ' +
          Copy(Candidate, 2, MaxInt) + ' on RegExp.');
      Exit;
    end;
    if (Receiver.Kind = a2Function) and (Candidate = #0 + 'prototype') then
    begin
      if Receiver.BoundReceiver.Kind <> a2Undefined then
        RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property prototype on MethodClosure.');
      case Value.Kind of
        a2Object:
          Receiver.FunctionPrototype := Value.Obj;
        a2Undefined, a2Null:
          Receiver.FunctionPrototype := nil;
      else
        RaiseScriptError('TypeError', 1049, 'Prototype objects must be vanilla Objects.');
      end;
      Exit;
    end;
    if (Receiver = FLoaderInfo) and MatchStr(Candidate, [#0 + 'url', #0 + 'loaderURL',
        #0 + 'parameters', #0 + 'bytesLoaded', #0 + 'bytesTotal', #0 + 'width', #0 + 'height',
        #0 + 'frameRate', #0 + 'content', #0 + 'contentType', #0 + 'loader', #0 + 'swfVersion',
        #0 + 'actionScriptVersion']) then
      RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property ' +
        Copy(Candidate, 2, MaxInt) + ' on LoaderInfo.');
    if Receiver.Props.ContainsKey(Candidate) or ((Receiver.ByteArrayData <> nil) and
      GetByteArrayProperty(Receiver.ByteArrayData, Candidate, Normalized)) then
    begin
      Key := ProtectedMemberName(Receiver, Candidate);
      Break;
    end;
    if Candidate[1] = #0 then
      Key := Candidate;
  end;
  if UseAccessor and (Receiver.Accessors <> nil) and Receiver.Accessors.TryGetValue(Key, Accessor) then
  begin
    if Accessor.Setter = nil then
      RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property ' +
        Copy(Key, LastDelimiter(#0, Key) + 1, MaxInt) + ' on ' + Receiver.DisplayName + '.');
    Invoke(Accessor.Setter, Receiver, [Value]);
    Exit;
  end;
  if (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
  begin
    if Key = #0 + 'filters' then
    begin
      WriteDisplayFilters(Receiver, Value);
      Exit;
    end;
    if Key = #0 + 'mask' then
    begin
      SourceObject := Value.Obj;
      if (SourceObject <> nil) and ((SourceObject.DisplayKind in [adNone, adGraphics]) or
        (Receiver = SourceObject)) then
        RaiseScriptError('ArgumentError', 2004, 'Invalid display mask.');
      if FDisplay <> nil then
        if SourceObject = nil then
          FDisplay.SetMask(Receiver.DisplayData, nil)
        else
          FDisplay.SetMask(Receiver.DisplayData, SourceObject.DisplayData);
      Receiver.Props.AddOrSetValue(Key, TAVM2Value.Ref(SourceObject));
      Exit;
    end;
  end;
  if (Receiver.DisplayKind = adBitmap) and ((Key = #0 + 'bitmapData') or (Key = #0 + 'smoothing')) then
  begin
    if Key = #0 + 'bitmapData' then
      Normalized := CoerceValue(Value, atClass, FBitmapDataClass, 'flash.display.BitmapData')
    else
      Normalized := TAVM2Value.Num(Ord(Truth(Value)), a2Boolean);
    Receiver.Props.AddOrSetValue(Key, Normalized);
    UpdateBitmapDisplay(Receiver);
    Exit;
  end;
  if (Receiver.DisplayKind = adText) and (Receiver.DisplayData <> nil) and StartsStr(#0, Key) then
  begin
    Name := Copy(Key, 2, MaxInt);
    Normalized := Value;
    if (Name = 'text') or (Name = 'htmlText') or (Name = 'type') then
      Normalized := TAVM2Value.Str(CoerceText(Value))
    else if Name = 'textColor' then
      Normalized := TAVM2Value.Num(IntBits(CoerceNumber(Value)), a2UInt)
    else if (Name = 'multiline') or (Name = 'wordWrap') then
      Normalized := TAVM2Value.Num(Ord(Truth(Value)), a2Boolean)
    else if Name = 'defaultTextFormat' then
      Normalized := CoerceValue(Value, atClass, FTextFormatClass, 'flash.text.TextFormat');
    if FDisplay.SetTextProperty(Receiver.DisplayData, Name, Normalized) then
      Exit;
  end;
  if (Receiver.DisplayData <> nil) and ((Key = #0 + 'width') or (Key = #0 + 'height')) then
  begin
    FDisplay.SetProperty(Receiver.DisplayData, Copy(Key, 2, MaxInt), CoerceNumber(Value));
    Exit;
  end;
  if (Receiver.ClassObject = FDateClass) and (Key = #0 + 'time') then
  begin
    DateCall(admSetTime, Receiver, [Value]);
    Exit;
  end;
  if (Key = #0 + 'data') and ClassHasType(Receiver.ClassObject, FSharedObjectClass) then
    RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property data on SharedObject.');
  if (Receiver.Kind = a2Class) and (Key = #0 + 'prototype') then
    RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property prototype on ' + Receiver.DisplayName + '.');
  if (Receiver.EventKind <> aeNone) and
    ((Key = #0 + 'type') or (Key = #0 + 'target') or (Key = #0 + 'currentTarget') or
    (Key = #0 + 'eventPhase') or (Key = #0 + 'bubbles') or (Key = #0 + 'cancelable')) then
    raise EAVM2Error.Create('Read-only AVM2 event property ' + Copy(Key, 2, MaxInt));
  if (Receiver = FStage) and (Key = #0 + 'focus') then
  begin
    PreviousFocus := FFocus;
    if Value.Kind in [a2Null, a2Undefined] then
      FFocus := nil
    else
    begin
      if (Value.Obj = nil) or (StageOf(Value.Obj) <> FStage) or
        not (Value.Obj.DisplayKind in [adContainer, adSprite, adMovieClip, adText, adButton]) then
        raise EAVM2Error.Create('Invalid AVM2 Stage.focus');
      FFocus := Value.Obj;
    end;
    Receiver.Props.AddOrSetValue(Key, TAVM2Value.Ref(FFocus));
    if PreviousFocus <> FFocus then
    begin
      if (StageOf(PreviousFocus) = FStage) and HasListener(PreviousFocus, 'focusOut', True) then
      begin
        FocusEvent := HostEventObject(FFocusClass, 'focusOut', True, False);
        FocusEvent.Props.Add(#0 + 'relatedObject', TAVM2Value.Ref(FFocus));
        DispatchEventTo(PreviousFocus, FocusEvent, False);
      end;
      if (StageOf(FFocus) = FStage) and HasListener(FFocus, 'focusIn', True) then
      begin
        FocusEvent := HostEventObject(FFocusClass, 'focusIn', True, False);
        FocusEvent.Props.Add(#0 + 'relatedObject', TAVM2Value.Ref(PreviousFocus));
        DispatchEventTo(FFocus, FocusEvent, False);
      end;
    end;
    Exit;
  end;
  if (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) and
    (Length(Key) > 0) and (Key[1] = #0) then
  begin
    Name := Copy(Key, 2, MaxInt);
    if (Receiver.DisplayKind = adMovieClip) and ((Name = 'currentFrame') or (Name = 'totalFrames')) then
      RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property ' + Name + ' on MovieClip.');
    if Name = 'loaderInfo' then
      RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property loaderInfo on DisplayObject.');
    if (Name = 'parent') or (Name = 'graphics') or (Name = 'numChildren') or (Name = 'stage') or (Name = 'root') then
      raise EAVM2Error.Create('Read-only AVM2 display property ' + Name);
    if Name = 'name' then
    begin
      if Receiver.TimelinePlaced then
        RaiseScriptError('Error', 2078, 'The name property of a timeline-placed object cannot be modified.');
      Receiver.Props.AddOrSetValue(Key, TAVM2Value.Str(AsText(Value)));
      Exit;
    end;
    for Candidate in DisplayProperties do
      if Candidate = Name then
      begin
        if Name = 'visible' then
          Normalized := TAVM2Value.Num(Ord(Truth(Value)), a2Boolean)
        else
        begin
          Number := AsNumber(Value);
          if Name = 'alpha' then
          begin
            if IsNan(Number) then
              Number := 0;
            Number := EnsureRange(Number, 0.0, 1.0);
          end;
          Normalized := TAVM2Value.Num(Number);
        end;
        if FDisplay <> nil then
          FDisplay.SetProperty(Receiver.DisplayData, Name, Normalized.Number);
        Receiver.Props.AddOrSetValue(Key, Normalized);
        Exit;
      end;
  end;
  if Receiver.ArrayData <> nil then
  begin
    if Key = #0 + 'length' then
    begin
      SetArrayLength(Receiver.ArrayData, ArrayLengthValue(Value));
      Exit;
    end;
    if TryPublicIndex(Key, Index) then
    begin
      SetArrayElement(Receiver.ArrayData, Index, Value);
      Exit;
    end;
  end;
  if (Receiver.ByteArrayData <> nil) and SetByteArrayProperty(Receiver.ByteArrayData, Key, Value) then
    Exit;
  if (Key[1] = #0) and not Receiver.Props.ContainsKey(Key) then
  begin
    Owner := ProxyMethod(Receiver, 'setProperty');
    if Owner <> nil then
      Invoke(Owner, Receiver, [TAVM2Value.Str(Copy(Key, 2, MaxInt)), Value])
    else
      StoreDynamicProperty(Receiver, Key, Value);
  end
  else
    StoreSlot(Receiver, Key, Value);
end;

function TAVM2Runtime.DisplayCall(Command: TAVM2DisplayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Child, Ancestor, OldParent: TAVM2Object;
  Values: TArray<Double>;
  Position, I, Count, Depth: Integer;
  NullValue: TAVM2Value;
  Children: TList<TAVM2Object>;
  X, Y: Double;
  Rect: TAVM2Rectangle;
  Shape, WasOnStage: Boolean;
  Matrix: TAVM2Matrix;
  Name: string;

  procedure Require(Minimum: Integer);
  begin
    if Length(Args) < Minimum then
      raise EAVM2Error.Create('Missing AVM2 ' + DisplayMethods[Command] + ' argument');
  end;

  function ChildAt(Index: Integer): TAVM2Object;
  begin
    if (Index < 0) or (Index >= Children.Count) then
      RaiseScriptError('RangeError', 2006, 'The supplied index is out of bounds.');
    Result := Children[Index];
  end;

  function ChildArg: TAVM2Object;
  begin
    Require(1);
    if Args[0].Kind in [a2Null, a2Undefined] then
      RaiseScriptError('TypeError', 2007, 'Parameter child must be non-null.');
    Result := Args[0].Obj;
    if (Result = nil) or not (Result.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
      raise EAVM2Error.Create('AVM2 argument is not a DisplayObject');
  end;

  procedure SetChildCount(Parent: TAVM2Object);
  begin
    Parent.Props.AddOrSetValue(#0 + 'numChildren', TAVM2Value.Num(Parent.DisplayChildren.Count, a2Int));
  end;

begin
  Result := Default(TAVM2Value);
  if Receiver = nil then
    raise EAVM2Error.Create('Missing AVM2 native receiver');
  if Command in [adHitTestPoint..adGetRect] then
  begin
    if not (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
      RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
    if Length(Args) < 1 + Ord(Command = adHitTestPoint) then
      RaiseScriptError('ArgumentError', 1063, 'Missing argument for ' + DisplayMethods[Command] + '.');
    if Command = adHitTestPoint then
    begin
      X := CoerceNumber(Args[0]);
      Y := CoerceNumber(Args[1]);
      Shape := (Length(Args) > 2) and Truth(Args[2]);
      Exit(TAVM2Value.Num(Ord((FDisplay <> nil) and
            FDisplay.HitTestPoint(Receiver.DisplayData, X, Y, Shape, StageOf(Receiver) = FStage)), a2Boolean));
    end;
    Child := Args[0].Obj;
    if Args[0].Kind in [a2Null, a2Undefined] then
    begin
      if Command = adHitTestObject then
        RaiseScriptError('TypeError', 2007, 'Parameter obj must be non-null.');
      Child := Receiver;
    end;
    if (Child = nil) or ((Child <> FStage) and
      not (Child.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton])) then
      RaiseScriptError('TypeError', 1034, 'Type Coercion failed: expected a DisplayObject.');
    if Command = adHitTestObject then
      Exit(TAVM2Value.Num(Ord((FDisplay <> nil) and FDisplay.HitTestObject(Receiver.DisplayData,
              Child.DisplayData)), a2Boolean));
    Rect := Default(TAVM2Rectangle);
    if FDisplay <> nil then
      Rect := FDisplay.GetBounds(Receiver.DisplayData, Child.DisplayData, Command = adGetRect, False);
    Exit(NewRectangle(Rect));
  end;
  if Command in [adLocalToGlobal, adGlobalToLocal] then
  begin
    Require(1);
    if (Receiver <> FStage) and not (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton]) then
      RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
    if Args[0].Kind in [a2Null, a2Undefined] then
      RaiseScriptError('TypeError', 2007, 'Parameter point must be non-null.');
    Child := PointArgument(Args[0]);
    X := Child.Props[#0 + 'x'].Number;
    Y := Child.Props[#0 + 'y'].Number;
    if FDisplay <> nil then
      FDisplay.TransformPoint(Receiver.DisplayData, Command = adLocalToGlobal, X, Y);
    Exit(NewPoint(X, Y));
  end;
  if Command in [adClear..adLineStyle] then
  begin
    if Receiver.DisplayKind <> adGraphics then
      raise EAVM2Error.Create('Invalid AVM2 Graphics receiver');
    if Command = adBeginBitmapFill then
    begin
      Require(1);
      Child := CoerceValue(Args[0], atClass, FBitmapDataClass, 'flash.display.BitmapData').Obj;
      if (Child = nil) or (Child.BitmapData = nil) or Child.BitmapData.Disposed then
        RaiseScriptError('ArgumentError', 2015, 'Invalid fill BitmapData.');
      Matrix := IdentityMatrix;
      if (Length(Args) > 1) and (Args[1].Obj <> nil) then
        Matrix := ReadNativeMatrix(CoerceValue(Args[1], atClass, FMatrixClass, 'flash.geom.Matrix').Obj);
      if FDisplay <> nil then
        FDisplay.BeginBitmapFill(Receiver.DisplayData, Child.BitmapData, Matrix,
          (Length(Args) < 3) or Truth(Args[2]), (Length(Args) > 3) and Truth(Args[3]));
      Exit;
    end;
    case Command of
      adBeginFill:
        Require(1);
      adMoveTo, adLineTo:
        Require(2);
      adDrawCircle:
        Require(3);
      adCurveTo, adDrawRect, adDrawEllipse:
        Require(4);
      adDrawRoundRect:
        Require(5);
    end;
    // Coerce only the numeric arguments understood by the host.
    Count := Min(Length(Args), 4);
    if Command = adDrawRoundRect then
      Count := Min(Length(Args), 6)
    else if Command = adLineStyle then
      Count := Min(Count, 3);
    SetLength(Values, Count);
    for I := 0 to Count - 1 do
      Values[I] := AsNumber(Args[I]);
    if (Command = adBeginFill) or ((Command = adLineStyle) and (Count >= 2)) then
    begin
      I := Ord(Command = adLineStyle);
      Values[I] := IntBits(Values[I]);
    end;
    if FDisplay <> nil then
      FDisplay.Draw(Receiver.DisplayData, Command, Values);
    Exit;
  end;
  Children := Receiver.DisplayChildren;
  if Children = nil then
    raise EAVM2Error.Create('Invalid AVM2 DisplayObjectContainer receiver');
  case Command of
    adGetChildByName:
      begin
        Require(1);
        Name := CoerceText(Args[0]);
        for Child in Children do
          if Child.Props[#0 + 'name'].Text = Name then
            Exit(TAVM2Value.Ref(Child));
        Exit(TAVM2Value.Ref(nil));
      end;
    adGetChildAt:
      begin
        Require(1);
        Exit(TAVM2Value.Ref(ChildAt(Integer(IntBits(AsNumber(Args[0]))))));
      end;
    adGetChildIndex:
      begin
        Position := Children.IndexOf(ChildArg);
        if Position < 0 then
          RaiseScriptError('ArgumentError', 2025, 'The supplied DisplayObject must be a child of the caller.');
        Exit(TAVM2Value.Num(Position, a2Int));
      end;
    adContains:
      begin
        Ancestor := ChildArg;
        while (Ancestor <> nil) and (Ancestor <> Receiver) do
          Ancestor := Ancestor.DisplayParent;
        Exit(TAVM2Value.Num(Ord(Ancestor = Receiver), a2Boolean));
      end;
    adRemoveChild, adRemoveChildAt:
      begin
        if Command = adRemoveChildAt then
        begin
          Require(1);
          Child := ChildAt(Integer(IntBits(AsNumber(Args[0]))));
        end
        else
          Child := ChildArg;
        if Child.DisplayParent <> Receiver then
          RaiseScriptError('ArgumentError', 2025, 'The supplied DisplayObject must be a child of the caller.');
        DispatchRemoval(Child, StageOf(Child) = FStage);
        if Child.DisplayParent <> Receiver then
          Exit(TAVM2Value.Ref(Child));
        if FDisplay <> nil then
          FDisplay.Place(Child.DisplayData, nil, 0);
        Children.Remove(Child);
        Child.DisplayParent := nil;
        NullValue := Default(TAVM2Value);
        NullValue.Kind := a2Null;
        Child.Props.AddOrSetValue(#0 + 'parent', NullValue);
        SetChildCount(Receiver);
        if Child.TimelinePlaced then
          RebuildTimelineBindings(Receiver, False);
        Exit(TAVM2Value.Ref(Child));
      end;
  end;
  Child := ChildArg;
  Position := Children.Count;
  if Command in [adAddChildAt, adSetChildIndex] then
  begin
    Require(2);
    Position := Integer(IntBits(AsNumber(Args[1])));
  end;
  if (Command = adSetChildIndex) and (Child.DisplayParent <> Receiver) then
    RaiseScriptError('ArgumentError', 2025, 'The supplied DisplayObject must be a child of the caller.');
  if Receiver = Child then
    RaiseScriptError('ArgumentError', 2024, 'An object cannot be added as a child of itself.');
  Ancestor := Receiver.DisplayParent;
  Depth := 0;
  while Ancestor <> nil do
  begin
    if Ancestor = Child then
      RaiseScriptError('ArgumentError', 2150,
        'An object cannot be added as a child to one of it''s children (or children''s children, etc.).');
    Inc(Depth);
    if Depth > 128 then
      raise EAVM2Error.Create('AVM2 display nesting limit');
    Ancestor := Ancestor.DisplayParent;
  end;
  if (Position < 0) or (Position > Children.Count) then
    RaiseScriptError('RangeError', 2006, 'The supplied index is out of bounds.');
  if Child = FDocument then
    raise EAVM2Error.Create('Cannot reparent the AS3 document');
  OldParent := Child.DisplayParent;
  WasOnStage := StageOf(Child) = FStage;
  if (OldParent <> nil) and (OldParent <> Receiver) then
  begin
    DispatchRemoval(Child, WasOnStage and (StageOf(Receiver) <> FStage));
    if Child.DisplayParent <> OldParent then
      Exit(TAVM2Value.Ref(Child));
    Position := Min(Position, Children.Count);
  end;
  if (OldParent = Receiver) and (Position = Children.Count) then
    Dec(Position);
  if FDisplay <> nil then
  begin
    if (Receiver = FStage) and (FStage.DisplayData = nil) then
    begin
      FStage.DisplayData := FDisplay.CreateStage;
      if FStage.DisplayData = nil then
        raise EAVM2Error.Create('AVM2 host cannot attach a Stage child');
    end;
    FDisplay.Place(Child.DisplayData, Receiver.DisplayData, Position);
  end;
  if OldParent <> nil then
  begin
    OldParent.DisplayChildren.Remove(Child);
    SetChildCount(OldParent);
  end;
  Children.Insert(Position, Child);
  Child.DisplayParent := Receiver;
  Child.Props.AddOrSetValue(#0 + 'parent', TAVM2Value.Ref(Receiver));
  SetChildCount(Receiver);
  if Child.TimelinePlaced then
  begin
    RebuildTimelineBindings(Receiver, False);
    if OldParent <> Receiver then
      RebuildTimelineBindings(OldParent, False);
  end;
  if OldParent <> Receiver then
  begin
    if HasListener(Child, 'added', True) then
      DispatchEventTo(Child, HostEventObject(FEnterFrameClass, 'added', True, False), False);
    if not WasOnStage then
      DispatchAddedToStage(Child);
  end;
  if Command <> adSetChildIndex then
    Result := TAVM2Value.Ref(Child);
end;

function TAVM2Runtime.NewClass(Module: TAVM2Module; Index: Integer; Base, Script: TAVM2Object; const Outer: TArray<TAVM2Value>): TAVM2Object;
begin
  if Index >= Length(Module.Classes) then
    raise EAVM2Error.Create('AVM2 class index outside table');
  if (Base <> nil) and (Base.Kind <> a2Class) then
    raise EAVM2Error.Create('Invalid AVM2 superclass');
  Result := Module.Classes[Index];
  if Result <> nil then
    Exit;
  Result := NewObject(a2Class);
  Module.Classes[Index] := Result;
  Result.Index := Index;
  Result.Module := Module;
  Result.Parent := Base;
  Result.HasPlainInstances := (Base <> nil) and ((Base = FObjectClass) or Base.HasPlainInstances);
  if Base <> nil then
  begin
    Result.DisplayKind := Base.DisplayKind;
    Result.CanDispatch := Base.CanDispatch;
    Result.EventKind := Base.EventKind;
  end;
  Result.Script := Script;
  Result.Scope := Outer;
  Result.InstanceScope := Outer + [TAVM2Value.Ref(Result)];
  Result.DisplayName := Module.ABC.Strings[Module.ABC.Multinames[Module.ABC.Instances[Index].Name].Name];
  AddTraits(Result, Module, Module.ABC.Classes[Index].Traits);
  Execute(Module, Module.ABC.Classes[Index].Init, TAVM2Value.Ref(Result), Script, Result, Outer, []);
end;

procedure TAVM2Runtime.ShareInstanceSlots(ClassObject, Instance: TAVM2Object);
var
  Layout: TAVM2SlotLayout;
  Slot: TPair<Integer, string>;
  Offset, MaxSlot, Limit: Integer;
  DynamicIndices: TDictionary<string, Integer>;
  CanShareDefaults: Boolean;
begin
  Layout := Instance.DeclaredSlots;
  if Layout = nil then
  begin
    Layout := TAVM2SlotLayout.Create;
    ClassObject.InstanceSlots := Layout;
    Instance.DeclaredSlots := Layout;
    Layout.Names := Instance.Slots;
    Instance.Slots := nil;
    Layout.Types := Instance.SlotTypes;
    Instance.SlotTypes := nil;
    SetLength(Layout.Flags, Instance.Props.FCount);
    if (Layout.Names <> nil) and (Instance.Accessors = nil) then
    begin
      MaxSlot := 0;
      Limit := Min(DirectSlotLimit, 16 + Layout.Names.Count * 4);
      for Slot in Layout.Names do
        if Slot.Key <= Limit then
          MaxSlot := Max(MaxSlot, Slot.Key);
      SetLength(Layout.Offsets, MaxSlot + 1);
      for Slot in Layout.Names do
      begin
        if (Slot.Key <= 0) or (Slot.Key > MaxSlot) or
          (Slot.Value = #0 + 'loaderInfo') or StartsStr('#24:', Slot.Value) then
          Continue;
        Offset := Instance.Props.FIndices[Slot.Value];
        Layout.Offsets[Slot.Key] := Offset + 1;
        Layout.Flags[Offset] := SlotReadable;
        if (Layout.Types = nil) or not Layout.Types.ContainsKey(Slot.Value) then
          Layout.Flags[Offset] := SlotReadable or SlotWritable;
      end;
    end;

    if Instance.Accessors = nil then
      for Offset := 0 to Instance.Props.FCount - 1 do
        with Instance.Props.FEntries[Offset] do
          if (Value.Obj <> nil) and Value.Obj.NeedsMethodReceiver and not StartsStr('#24:', Key) and
            (Key <> #0 + 'loaderInfo') then
            Layout.Flags[Offset] := Layout.Flags[Offset] or SlotMethod;

    // Namespace defaults and shared trait methods can be reused. Function
    // traits create a fresh function and prototype for each instance.
    CanShareDefaults := (Instance.Accessors = nil) and (Instance.Props.FCount <> 0);
    if CanShareDefaults then
      for Offset := 0 to Instance.Props.FCount - 1 do
        with Instance.Props.FEntries[Offset].Value do
          if (Obj <> nil) and (Obj.HostManaged or ((Obj.Kind = a2Function) and not Obj.NeedsMethodReceiver)) then
          begin
            CanShareDefaults := False;
            Break;
          end;
    if CanShareDefaults then
    begin
      Layout.Defaults := Copy(Instance.Props.FEntries, 0, Instance.Props.FCount);
      DynamicIndices := TDictionary<string, Integer>.Create;
      Layout.PropertyIndices := Instance.Props.FIndices;
      Instance.Props.FIndices := DynamicIndices;
      Instance.Props.FDeclaredIndices := Layout.PropertyIndices;
    end;
  end;
  // Trait installation is base-first on an initially empty instance. Dynamic
  // entries can change afterwards without moving this prefix of property cells.
  if Instance.Props.FCount = Length(Layout.Flags) then
    Instance.Props.FDeclaredCount := Length(Layout.Flags);
end;

procedure TAVM2Runtime.InstallInstanceTraits(ClassObject, Instance: TAVM2Object; Depth: Integer);
var
  Method: TAVM2ByteMethod;
  ArrayMethod: TAVM2ArrayMethod;
  Name: string;
  ShareSlots: Boolean;
begin
  if Depth >= 128 then
    raise EAVM2Error.Create('AVM2 inheritance depth limit');
  if ClassObject = nil then
    Exit;
  if ClassObject.Index < 0 then
  begin
    if ClassObject = FRegExpClass then
      Instance.RegExp := TAVM2RegExp.Create;
    if ClassObject = FDictionaryClass then
      Instance.DictionaryKeys := TDictionary<TAVM2Object, TAVM2DictionaryEntry>.Create;
    if ClassObject = FSoundClass then
      Instance.Props.Add(#0 + 'length', TAVM2Value.Num(0));
    if ClassObject = FLocalConnectionClass then
    begin
      Instance.IsLocalConnection := True;
      Instance.Props.Add(#0 + 'client', TAVM2Value.Ref(Instance));
      Instance.Props.Add(#0 + 'domain', TAVM2Value.Str('localhost'));
    end;
    if ClassObject = FTimerClass then
      Instance.IsTimer := True;
    if ClassObject = FPointClass then
    begin
      Instance.IsPoint := True;
      Instance.Props.Add(#0 + 'x', TAVM2Value.Num(0));
      Instance.Props.Add(#0 + 'y', TAVM2Value.Num(0));
      Instance.Props.Add(#0 + 'length', TAVM2Value.Num(0));
    end;
    if ClassObject = FRectangleClass then
    begin
      Instance.IsRectangle := True;
      for Name in RectangleFields do
        Instance.Props.Add(Name, TAVM2Value.Num(0));
      for Name in RectangleAccessors do
        Instance.Props.Add(Name, Default(TAVM2Value));
    end;
    if ClassObject = FMatrixClass then
    begin
      Instance.IsMatrix := True;
      WriteNativeMatrix(Instance, IdentityMatrix);
    end;
    if ClassObject = FVector3DClass then
    begin
      Instance.IsVector3D := True;
      for Name in Vector3DFields do
        Instance.Props.Add(Name, TAVM2Value.Num(0));
    end;
    if ClassObject.DisplayName = 'flash.display.MovieClip' then
    begin
      Instance.Props.Add(#0 + 'addFrameScript', TAVM2Value.Ref(FAddFrameScript));
      Instance.Props.Add(#0 + 'play', TAVM2Value.Ref(FPlayMovieClip));
      Instance.Props.Add(#0 + 'stop', TAVM2Value.Ref(FStopMovieClip));
      Instance.Props.Add(#0 + 'gotoAndPlay', TAVM2Value.Ref(FGotoAndPlay));
      Instance.Props.Add(#0 + 'gotoAndStop', TAVM2Value.Ref(FGotoAndStop));
      Instance.Props.Add(#0 + 'currentFrame', TAVM2Value.Num(1, a2Int));
      Instance.Props.Add(#0 + 'totalFrames', TAVM2Value.Num(1, a2Int));
      Instance.Props.Add(#0 + 'currentLabel', TAVM2Value.Ref(nil));
      Instance.Props.Add(#0 + 'currentFrameLabel', TAVM2Value.Ref(nil));
      Instance.Props.Add(#0 + 'currentLabels', TAVM2Value.Ref(nil));
    end;
    if ClassObject = FArrayClass then
    begin
      Instance.ArrayData := TAVM2Array.Create;
      Instance.ArrayData.Prototype := FArrayPrototype.ArrayData;
      for ArrayMethod := Low(TAVM2ArrayMethod) to High(TAVM2ArrayMethod) do
        if not (ArrayMethod in [aaSort, aaSortOn]) then
          Instance.Props.Add(#0 + ArrayMethods[ArrayMethod], TAVM2Value.Ref(FArrayMethods[ArrayMethod]));
    end;
    if ClassObject = FByteArrayClass then
    begin
      Instance.ByteArrayData := TAVM2ByteArray.Create;
      for Method := Low(TAVM2ByteMethod) to High(TAVM2ByteMethod) do
        Instance.Props.Add(#0 + ByteArrayMethods[Method], TAVM2Value.Ref(FByteArrayMethods[Method]));
    end;
    Exit;
  end;
  ShareSlots := (Depth = 0) and ClassObject.HasPlainInstances and (Instance.Kind = a2PlainObject) and
    (Instance.DisplayKind = adNone) and (Instance.Props.FCount = 0) and (Instance.Slots = nil);
  if ShareSlots then
  begin
    Instance.DeclaredSlots := ClassObject.InstanceSlots;
    if (Instance.DeclaredSlots <> nil) and (Instance.DeclaredSlots.Defaults <> nil) then
    begin
      Instance.Scope := ClassObject.InstanceScope;
      Instance.Script := ClassObject.Script;
      Instance.ClassObject := ClassObject;
      Instance.Props.FEntries := Copy(Instance.DeclaredSlots.Defaults);
      Instance.Props.FCount := Length(Instance.Props.FEntries);
      Instance.Props.FDeclaredCount := Instance.Props.FCount;
      Instance.Props.FDeclaredIndices := Instance.DeclaredSlots.PropertyIndices;
      Exit;
    end;
  end;
  InstallInstanceTraits(ClassObject.Parent, Instance, Depth + 1);
  Instance.Scope := ClassObject.InstanceScope;
  Instance.Script := ClassObject.Script;
  Instance.ClassObject := ClassObject;
  AddTraits(Instance, ClassObject.Module, ClassObject.Module.ABC.Instances[ClassObject.Index].Definition.Traits);
  if ShareSlots then
    ShareInstanceSlots(ClassObject, Instance);
end;

procedure TAVM2Runtime.ConstructInto(ClassObject, Instance: TAVM2Object; const Args: TArray<TAVM2Value>);
var
  Bubbles, Cancelable: Boolean;
  MessageValue: TAVM2Value;
  ErrorID: Cardinal;
  RepeatCount, I: Integer;
  DisplayObject, LoaderInfo: TAVM2Object;
begin
  if (ClassObject = nil) or (ClassObject.Kind <> a2Class) then
    raise EAVM2Error.Create('AVM2 receiver is not a class');
  if ClassObject = FFrameLabelClass then
  begin
    if Length(Args) < 2 then
      RaiseScriptError('ArgumentError', 1063, 'FrameLabel requires a name and a frame.');
    Instance.Props.Add(#0 + 'name', TAVM2Value.Str(CoerceText(Args[0])));
    Instance.Props.Add(#0 + 'frame', TAVM2Value.Num(Integer(IntBits(CoerceNumber(Args[1]))), a2Int));
  end
  else if ClassObject = FBitmapDataClass then
    InitBitmapData(Instance, Args)
  else if ClassObject = FBitmapClass then
  begin
    Instance.Props.Add(#0 + 'bitmapData', TAVM2Value.Ref(nil));
    Instance.Props.Add(#0 + 'pixelSnapping', TAVM2Value.Str('auto'));
    Instance.Props.Add(#0 + 'smoothing', TAVM2Value.Num(0, a2Boolean));
    if Length(Args) > 1 then
      Instance.Props[#0 + 'pixelSnapping'] := TAVM2Value.Str(CoerceText(Args[1]));
    if Length(Args) > 2 then
      Instance.Props[#0 + 'smoothing'] := TAVM2Value.Num(Ord(Truth(Args[2])), a2Boolean);
    if Length(Args) > 0 then
      SetProperty(Instance, [#0 + 'bitmapData'], Args[0]);
  end
  else if ClassObject = FGlowFilterClass then
  begin
    Instance.Props.Add(#0 + 'color', TAVM2Value.Num($FF0000, a2UInt));
    Instance.Props.Add(#0 + 'alpha', TAVM2Value.Num(1));
    Instance.Props.Add(#0 + 'blurX', TAVM2Value.Num(6));
    Instance.Props.Add(#0 + 'blurY', TAVM2Value.Num(6));
    Instance.Props.Add(#0 + 'strength', TAVM2Value.Num(2));
    Instance.Props.Add(#0 + 'quality', TAVM2Value.Num(1, a2Int));
    Instance.Props.Add(#0 + 'inner', TAVM2Value.Num(0, a2Boolean));
    Instance.Props.Add(#0 + 'knockout', TAVM2Value.Num(0, a2Boolean));
    for I := 0 to Min(High(Args), 7) do
      Instance.Props[#0 + GlowFilterFields[I]] := Args[I];
  end
  else if ClassObject = FColorTransformClass then
  begin
    for I := 0 to High(ColorTransformFields) do
    begin
      MessageValue := TAVM2Value.Num(Ord(I < 4));
      if I < Length(Args) then
        MessageValue := TAVM2Value.Num(CoerceNumber(Args[I]));
      Instance.Props.Add(#0 + ColorTransformFields[I], MessageValue);
    end;
  end
  else if ClassObject = FQNameClass then
  begin
    MessageValue := TAVM2Value.Str('');
    if Length(Args) > 1 then
    begin
      MessageValue := Args[0];
      if MessageValue.Obj <> nil then
        if MessageValue.Obj.HasNamespaceURI then
          MessageValue := TAVM2Value.Str(MessageValue.Obj.NamespaceURI)
        else
          MessageValue := TAVM2Value.Str(CoerceText(MessageValue));
    end;
    Instance.Props.Add(#0 + 'uri', MessageValue);
    MessageValue := TAVM2Value.Str('');
    if Length(Args) > 0 then
      MessageValue := TAVM2Value.Str(CoerceText(Args[High(Args)]));
    Instance.Props.Add(#0 + 'localName', MessageValue);
  end
  else if ClassObject = FDateClass then
  begin
    Instance.Props.Add(#0 + 'time', TAVM2Value.Num(DateTimeToUnix(Now, False) * 1000.0 + MilliSecondOf(Now)));
    if Length(Args) > 0 then
      DateCall(admSetTime, Instance, Args);
  end
  else if ClassObject = FTextFormatClass then
  begin
    for I := Low(AVMFormatNames) to High(AVMFormatNames) do
    begin
      MessageValue := TAVM2Value.Ref(nil);
      if (I <= 12) and (I < Length(Args)) then
        MessageValue := Args[I];
      Instance.Props.Add(#0 + AVMFormatNames[I], MessageValue);
    end;
  end
  else if ClassObject = FSoundTransformClass then
  begin
    Bubbles := Length(Args) > 0;
    if Bubbles then
      MessageValue := TAVM2Value.Num(CoerceNumber(Args[0]))
    else
      MessageValue := TAVM2Value.Num(1);
    Instance.Props.Add(#0 + 'volume', MessageValue);
    if Length(Args) > 1 then
      MessageValue := TAVM2Value.Num(CoerceNumber(Args[1]))
    else
      MessageValue := TAVM2Value.Num(0);
    Instance.Props.Add(#0 + 'pan', MessageValue);
  end
  else if (ClassObject = FXMLClass) or (ClassObject = FXMLListClass) then
    ParseXML(Instance, Args)
  else if ClassObject.Index >= 0 then
    Execute(ClassObject.Module, ClassObject.Module.ABC.Instances[ClassObject.Index].Definition.Init,
      TAVM2Value.Ref(Instance), ClassObject.Script, ClassObject, ClassObject.InstanceScope, Args)
  else if ClassObject = FLoaderClass then
  begin
    LoaderInfo := NewObject(a2PlainObject, True);
    LoaderInfo.ClassObject := FLoaderInfo.ClassObject;
    LoaderInfo.Parent := ClassPrototype(LoaderInfo.ClassObject);
    LoaderInfo.DisplayName := FLoaderInfo.DisplayName;
    BindDispatcher(LoaderInfo);
    LoaderInfo.Props.Add(#0 + 'loader', TAVM2Value.Ref(Instance));
    LoaderInfo.Props.Add(#0 + 'content', TAVM2Value.Ref(nil));
    LoaderInfo.Props.Add(#0 + 'bytesLoaded', TAVM2Value.Num(0, a2UInt));
    LoaderInfo.Props.Add(#0 + 'bytesTotal', TAVM2Value.Num(0, a2UInt));
    Instance.Props.Add(#0 + 'content', TAVM2Value.Ref(nil));
    Instance.Props.Add(#0 + 'contentLoaderInfo', TAVM2Value.Ref(LoaderInfo));
  end
  else if ClassObject = FLoaderContextClass then
  begin
    Instance.Props.Add(#0 + 'checkPolicyFile', TAVM2Value.Num(Ord((Length(Args) > 0) and Truth(Args[0])), a2Boolean));
    Instance.Props.Add(#0 + 'applicationDomain', TAVM2Value.Ref(nil));
    Instance.Props.Add(#0 + 'securityDomain', TAVM2Value.Ref(nil));
    if Length(Args) > 1 then
      Instance.Props[#0 + 'applicationDomain'] := Args[1];
    if Length(Args) > 2 then
      Instance.Props[#0 + 'securityDomain'] := Args[2];
  end
  else if ClassObject.DisplayKind in [adContainer, adSprite, adMovieClip] then
    ConstructTimelineChildren(Instance)
  else if ClassObject.IsVectorType then
  begin
    if Length(Args) > 0 then
      ResizeVector(Instance, IntBits(CoerceNumber(Args[0])));
    if Length(Args) > 1 then
      Instance.VectorFixed := Truth(Args[1]);
  end
  else if ClassObject = FURLVariablesClass then
  begin
    if (Length(Args) > 0) and not (Args[0].Kind in [a2Null, a2Undefined]) then
      DecodeVariables(Instance, CoerceText(Args[0]));
  end
  else if ClassObject = FURLRequestClass then
  begin
    MessageValue := TAVM2Value.Ref(nil);
    if Length(Args) > 0 then
      MessageValue := TAVM2Value.Str(CoerceText(Args[0]));
    Instance.Props.Add(#0 + 'url', MessageValue);
    Instance.Props.Add(#0 + 'method', TAVM2Value.Str('GET'));
    Instance.Props.Add(#0 + 'data', Default(TAVM2Value));
    Instance.Props.Add(#0 + 'contentType', TAVM2Value.Str('application/x-www-form-urlencoded'));
  end
  else if ClassObject = FURLLoaderClass then
  begin
    Instance.Props.Add(#0 + 'data', Default(TAVM2Value));
    Instance.Props.Add(#0 + 'dataFormat', TAVM2Value.Str('text'));
    Instance.Props.Add(#0 + 'bytesLoaded', TAVM2Value.Num(0, a2UInt));
    Instance.Props.Add(#0 + 'bytesTotal', TAVM2Value.Num(0, a2UInt));
    if (Length(Args) > 0) and not (Args[0].Kind in [a2Null, a2Undefined]) then
      URLCall(auLoad, Instance, Args);
  end
  else if ClassObject = FTimerClass then
  begin
    if Length(Args) = 0 then
      RaiseScriptError('ArgumentError', 1063, 'Timer requires a delay.');
    SetTimerDelay(Instance, CoerceNumber(Args[0]));
    RepeatCount := 0;
    if Length(Args) > 1 then
      RepeatCount := Integer(IntBits(CoerceNumber(Args[1])));
    Instance.Props.AddOrSetValue(#0 + 'repeatCount', TAVM2Value.Num(RepeatCount, a2Int));
    Instance.Props.AddOrSetValue(#0 + 'currentCount', TAVM2Value.Num(0, a2Int));
    Instance.Props.AddOrSetValue(#0 + 'running', TAVM2Value.Num(0, a2Boolean));
  end
  else if ClassObject = FPointClass then
  begin
    if Length(Args) > 0 then
      Instance.Props[#0 + 'x'] := TAVM2Value.Num(CoerceNumber(Args[0]));
    if Length(Args) > 1 then
      Instance.Props[#0 + 'y'] := TAVM2Value.Num(CoerceNumber(Args[1]));
  end
  else if ClassObject = FRectangleClass then
  begin
    for I := 0 to Min(High(Args), High(RectangleFields)) do
      Instance.Props[RectangleFields[I]] := TAVM2Value.Num(CoerceNumber(Args[I]));
  end
  else if ClassObject = FMatrixClass then
  begin
    for I := 0 to Min(High(Args), High(MatrixFields)) do
      Instance.Props[MatrixFields[I]] := TAVM2Value.Num(CoerceNumber(Args[I]));
  end
  else if ClassObject = FVector3DClass then
  begin
    for I := 0 to Min(High(Args), High(Vector3DFields)) do
      Instance.Props[Vector3DFields[I]] := TAVM2Value.Num(CoerceNumber(Args[I]));
  end
  else if ClassObject = FTransformClass then
  begin
    if Length(Args) = 0 then
      RaiseScriptError('ArgumentError', 1063, 'Transform requires a DisplayObject.');
    DisplayObject := Args[0].Obj;
    if (DisplayObject = nil) or ((DisplayObject <> FStage) and
      not (DisplayObject.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton])) then
      RaiseScriptError('TypeError', 1034, 'Transform requires a DisplayObject.');
    Instance.TransformOwner := DisplayObject;
    Instance.Props.Add(#0 + 'matrix', Default(TAVM2Value));
    Instance.Props.Add(#0 + 'concatenatedMatrix', Default(TAVM2Value));
    Instance.Props.Add(#0 + 'pixelBounds', Default(TAVM2Value));
  end
  else if ClassObject = FRegExpClass then
    InitRegExp(Instance.RegExp, Args)
  else if ClassObject = FArrayClass then
  begin
    if (Length(Args) = 1) and (Args[0].Kind in [a2Int, a2UInt, a2Number]) then
      SetArrayLength(Instance.ArrayData, ArrayLengthValue(Args[0]))
    else
      AppendArray(Instance.ArrayData, Args);
  end
  else if ClassObject.NativeError then
  begin
    Instance.NativeError := True;
    MessageValue := TAVM2Value.Str('');
    ErrorID := 0;
    if Length(Args) > 0 then
      MessageValue := Args[0];
    if Length(Args) > 1 then
      ErrorID := IntBits(AsNumber(Args[1]));
    Instance.Props.AddOrSetValue(#0 + 'name', TAVM2Value.Str(ClassObject.DisplayName));
    Instance.Props.AddOrSetValue(#0 + 'message', MessageValue);
    Instance.Props.AddOrSetValue(#0 + 'errorID', TAVM2Value.Num(Integer(ErrorID), a2Int));
    if not Instance.Props.ContainsKey(#0 + 'toString') then
      Instance.Props.Add(#0 + 'toString', TAVM2Value.Ref(FErrorToString));
  end
  else if ClassObject.EventKind <> aeNone then
  begin
    if Length(Args) = 0 then
      raise EAVM2Error.Create('Missing AVM2 Event type');
    if Instance.ClassObject = nil then
      Instance.ClassObject := ClassObject;
    Bubbles := ClassObject.EventKind in [aeKeyboard, aeMouse, aeFocus];
    if Length(Args) > 1 then
      Bubbles := Truth(Args[1]);
    Cancelable := (Length(Args) > 2) and Truth(Args[2]);
    InitEvent(Instance, ClassObject.EventKind, AsText(Args[0]), Bubbles, Cancelable);
    case ClassObject.EventKind of
      aeStatus:
        begin
          Instance.Props.AddOrSetValue(#0 + 'code', TAVM2Value.Str(''));
          Instance.Props.AddOrSetValue(#0 + 'level', TAVM2Value.Str(''));
          if Length(Args) > 3 then
            Instance.Props[#0 + 'code'] := TAVM2Value.Str(CoerceText(Args[3]));
          if Length(Args) > 4 then
            Instance.Props[#0 + 'level'] := TAVM2Value.Str(CoerceText(Args[4]));
        end;
      aeProgress:
        begin
          Instance.Props.AddOrSetValue(#0 + 'bytesLoaded', TAVM2Value.Num(0));
          Instance.Props.AddOrSetValue(#0 + 'bytesTotal', TAVM2Value.Num(0));
          if Length(Args) > 3 then
            Instance.Props[#0 + 'bytesLoaded'] := TAVM2Value.Num(CoerceNumber(Args[3]));
          if Length(Args) > 4 then
            Instance.Props[#0 + 'bytesTotal'] := TAVM2Value.Num(CoerceNumber(Args[4]));
        end;
      aeText, aeError:
        begin
          Instance.Props.AddOrSetValue(#0 + 'text', TAVM2Value.Str(''));
          if Length(Args) > 3 then
            Instance.Props[#0 + 'text'] := TAVM2Value.Str(CoerceText(Args[3]));
          if ClassObject.EventKind = aeError then
          begin
            ErrorID := 0;
            if Length(Args) > 4 then
              ErrorID := IntBits(CoerceNumber(Args[4]));
            Instance.Props.AddOrSetValue(#0 + 'errorID', TAVM2Value.Num(Integer(ErrorID), a2Int));
          end;
        end;
    end;
  end;
end;

procedure TAVM2Runtime.InitializeFunctionPrototype(Func: TAVM2Object);
begin
  Func.FunctionPrototype := NewObject(a2PlainObject, Func.HostManaged);
  Func.FunctionPrototype.ClassObject := FObjectClass;
  Func.FunctionPrototype.Parent := FObjectPrototype;
  Func.FunctionPrototype.Props.Add(#0 + 'constructor', TAVM2Value.Ref(Func));
end;

function TAVM2Runtime.ClassPrototype(AClass: TAVM2Object; Depth: Integer): TAVM2Object;
var
  BasePrototype: TAVM2Object;
begin
  if AClass.InstancePrototype <> nil then
    Exit(AClass.InstancePrototype);
  if Depth >= 128 then
    raise EAVM2Error.Create('AVM2 inheritance depth limit');
  BasePrototype := FObjectPrototype;
  if AClass.Parent <> nil then
    BasePrototype := ClassPrototype(AClass.Parent, Depth + 1);
  Result := NewObject(a2PlainObject);
  Result.Parent := BasePrototype;
  Result.ClassObject := FObjectClass;
  Result.Props.Add(#0 + 'constructor', TAVM2Value.Ref(AClass));
  AClass.InstancePrototype := Result;
end;

function TAVM2Runtime.ValuePrototype(const Value: TAVM2Value): TAVM2Object;
begin
  case Value.Kind of
    a2String, a2Boolean, a2Int, a2UInt, a2Number:
      Result := ClassPrototype(PrimitiveClass(Value));
    a2Object:
      Result := ObjectPrototype(Value.Obj);
  else
    Result := nil;
  end;
end;

function TAVM2Runtime.ObjectPrototype(Obj: TAVM2Object): TAVM2Object;
begin
  if Obj.Kind = a2Class then
    Result := FClassPrototype
  else
    Result := Obj.Parent;
end;

function TAVM2Runtime.IsInstanceOf(const Value: TAVM2Value; ConstructorObject: TAVM2Object): Boolean;
var
  Current, Prototype: TAVM2Object;
begin
  if (ConstructorObject = nil) or not (ConstructorObject.Kind in [a2Class, a2Function]) then
    RaiseScriptError('TypeError', 1040, 'The right-hand side of instanceof must be a class or function.');
  if Value.Kind = a2Undefined then
    RaiseScriptError('TypeError', 1010, 'A term is undefined and has no properties.');
  if Value.Kind = a2Null then
    Exit(False);
  if ConstructorObject.Kind = a2Class then
    Prototype := ClassPrototype(ConstructorObject)
  else
    Prototype := ConstructorObject.FunctionPrototype;
  if Prototype = nil then
    Exit(False);
  Current := ValuePrototype(Value);
  while Current <> nil do
  begin
    Dec(FWork);
    if FWork < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    if Current = Prototype then
      Exit(True);
    Current := ObjectPrototype(Current);
  end;
  Result := False;
end;

function TAVM2Runtime.ConvertPrimitive(Kind: TAVM2TypeKind; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Value: TAVM2Value;
begin
  if Length(Args) > 0 then
    Value := Args[0]
  else if Kind = atString then
    Value := TAVM2Value.Str('')
  else
    Value := TAVM2Value.Num(0, a2Int);
  if Kind = atString then
    Exit(TAVM2Value.Str(CoerceText(Value)));
  Result := CoerceValue(Value, Kind, nil, BuiltinTypeNames[Kind]);
end;

procedure TAVM2Runtime.InstallPrimitiveMethods;
var
  Method: TAVM2PrimitiveMethod;
  Kind: TAVM2TypeKind;
  Native, Prototype: TAVM2Object;
  Smallest: Double;
  Bits: UInt64;
begin
  for Method := pmCharAt to pmFromCharCode do
  begin
    Native := NewObject(a2Function);
    Native.Index := PrimitiveMethodBase - Ord(Method);
    FPrimitiveMethods[Method] := Native;
    if Method = pmFromCharCode then
      Continue;
    case Method of
      pmBooleanText, pmBooleanValue:
        Kind := atBoolean;
      pmNumberText..pmNumberPrecision:
        Kind := atNumber;
    else
      Kind := atString;
    end;
    Prototype := ClassPrototype(FPrimitiveClasses[Kind]);
    Prototype.Props.Add(#0 + PrimitiveMethodNames[Method], TAVM2Value.Ref(Native));
  end;
  Native := FPrimitiveMethods[pmFromCharCode];
  FPrimitiveClasses[atString].Props.Add(#0 + 'fromCharCode', TAVM2Value.Ref(Native));
  FPrimitiveClasses[atString].Props.Add(BuiltinNamespace + 'fromCharCode', TAVM2Value.Ref(Native));
  ClassPrototype(FPrimitiveClasses[atNumber]).Props.Add(#0 + 'toLocaleString',
      TAVM2Value.Ref(FPrimitiveMethods[pmNumberText]));
  Prototype := ClassPrototype(FPrimitiveClasses[atString]);
  Prototype.Props.Add(#0 + 'toLocaleLowerCase', TAVM2Value.Ref(FPrimitiveMethods[pmLowerCase]));
  Prototype.Props.Add(#0 + 'toLocaleUpperCase', TAVM2Value.Ref(FPrimitiveMethods[pmUpperCase]));
  Native := FPrimitiveClasses[atNumber];
  Native.Props.Add(#0 + 'NaN', TAVM2Value.Num(NaN));
  Native.Props.Add(#0 + 'POSITIVE_INFINITY', TAVM2Value.Num(Infinity));
  Native.Props.Add(#0 + 'NEGATIVE_INFINITY', TAVM2Value.Num(-Infinity));
  Native.Props.Add(#0 + 'MAX_VALUE', TAVM2Value.Num(MaxDouble));
  Bits := 1;
  Move(Bits, Smallest, SizeOf(Smallest));
  Native.Props.Add(#0 + 'MIN_VALUE', TAVM2Value.Num(Smallest));
  Native := FPrimitiveClasses[atInt];
  Native.Props.Add(#0 + 'MIN_VALUE', TAVM2Value.Num(Low(Integer), a2Int));
  Native.Props.Add(#0 + 'MAX_VALUE', TAVM2Value.Num(High(Integer), a2Int));
  Native := FPrimitiveClasses[atUInt];
  Native.Props.Add(#0 + 'MIN_VALUE', TAVM2Value.Num(0, a2UInt));
  Native.Props.Add(#0 + 'MAX_VALUE', TAVM2Value.Num(High(Cardinal), a2UInt));
end;

function TAVM2Runtime.PrimitiveClass(const Value: TAVM2Value): TAVM2Object;
begin
  case Value.Kind of
    a2String:
      Result := FPrimitiveClasses[atString];
    a2Boolean:
      Result := FPrimitiveClasses[atBoolean];
  else
    Result := FPrimitiveClasses[atNumber];
  end;
end;

function TAVM2Runtime.PrimitiveTrait(AClass: TAVM2Object; const Key: string): TAVM2PrimitiveMethod;
var
  Method, FirstMethod, LastMethod: TAVM2PrimitiveMethod;
  Name: string;
begin
  Result := pmNone;
  if not Key.StartsWith(BuiltinNamespace) then
    Exit;
  case AClass.PrimitiveKind of
    atString:
      begin
        FirstMethod := pmCharAt;
        LastMethod := pmUpperCase;
      end;
    atBoolean:
      begin
        FirstMethod := pmBooleanText;
        LastMethod := pmBooleanValue;
      end;
  else
    FirstMethod := pmNumberText;
    LastMethod := pmNumberPrecision;
  end;
  Name := Copy(Key, Length(BuiltinNamespace) + 1, MaxInt);
  for Method := FirstMethod to LastMethod do
    if Name = PrimitiveMethodNames[Method] then
      Exit(Method);
end;

function TAVM2Runtime.BindNativeMethod(Receiver, Method: TAVM2Object): TAVM2Value;
var
  Closure: TAVM2Object;
begin
  if Receiver.BoundNativeMethods = nil then
    Receiver.BoundNativeMethods := TDictionary<TAVM2Object, TAVM2Object>.Create;
  if not Receiver.BoundNativeMethods.TryGetValue(Method, Closure) then
  begin
    Closure := NewObject(a2Function, Receiver.HostManaged);
    Closure.Index := Method.Index;
    if Method.Module <> nil then
    begin
      Closure.Module := Method.Module;
      Closure.Scope := Method.Scope;
      Closure.Script := Method.Script;
      Closure.ClassObject := Method.ClassObject;
    end;
    Closure.BoundReceiver := TAVM2Value.Ref(Receiver);
    Receiver.BoundNativeMethods.Add(Method, Closure);
  end;
  Result := TAVM2Value.Ref(Closure);
end;

function TAVM2Runtime.ReadProperty(const Receiver: TAVM2Value; const Names: TArray<string>; ForCall: Boolean): TAVM2Value;
var
  AClass, Func, Prototype, Obj: TAVM2Object;
  Key: string;
  Method: TAVM2PrimitiveMethod;
  MethodIndex: Integer;
begin
  if Receiver.Kind = a2Object then
  begin
    Obj := Receiver.Obj;
    if IsXML(Obj) and not ForCall then
      for Key in Names do
        if StartsStr(#0, Key) then
          Exit(XMLProperty(Obj, Key));
    Result := PropertyValue(Obj, Names);
    if (not ForCall) and (Result.Kind = a2Undefined) then
    begin
      Func := ProxyMethod(Obj, 'getProperty');
      if Func <> nil then
        for Key in Names do
          if StartsStr(#0, Key) then
            Exit(Invoke(Func, Receiver, [TAVM2Value.Str(Copy(Key, 2, MaxInt))]));
    end;
    if (not ForCall) and (Result.Obj <> nil) and (Result.Obj.Kind = a2Function) and
      (Result.Obj.BoundReceiver.Kind = a2Undefined) then
    begin
      MethodIndex := Result.Obj.Index;
      if Result.Obj.NeedsMethodReceiver or (Obj.IsMatrix and (MethodIndex <= MatrixMethodBase) and
        (MethodIndex >= MatrixMethodBase - Ord(High(TAVM2MatrixMethod)))) or
        (Obj.IsVector3D and (MethodIndex = Vector3DTextMethod)) or
        (Obj.IsRectangle and (MethodIndex <= RectangleMethodBase) and
        (MethodIndex >= RectangleMethodBase - Ord(High(TAVM2RectangleMethod)))) or
        (Obj.IsPoint and (MethodIndex <= PointMethodBase) and (MethodIndex >= PointMethodBase - Ord(apText))) or
        ((Obj.DisplayKind = adMovieClip) and ((MethodIndex = AddFrameScriptMethod) or
        ((MethodIndex <= MovieClipPlayMethod) and (MethodIndex >= MovieClipGotoAndStopMethod)))) or
        (((Obj = FStage) or (Obj.DisplayKind in [adContainer, adSprite, adMovieClip, adShape, adText, adBitmap, adButton])) and
        (MethodIndex <= DisplayMethodBase - Ord(adLocalToGlobal)) and
        (MethodIndex >= DisplayMethodBase - Ord(adGetRect))) or
        (Obj.IsTimer and (MethodIndex <= TimerMethodBase) and
        (MethodIndex >= TimerMethodBase - Ord(tmReset))) or
        ((Obj.EventKind = aeTimer) and (MethodIndex <= TimerMethodBase - Ord(tmCloneEvent)) and
        (MethodIndex >= TimerMethodBase - Ord(tmUpdateAfterEvent))) or
        (Obj.CanDispatch and (MethodIndex <= EventMethodBase) and
        (MethodIndex >= EventMethodBase - Ord(aeDispatch))) or
        ((Obj.EventKind <> aeNone) and (MethodIndex <= EventMethodBase - Ord(aeStop)) and
        (MethodIndex >= EventMethodBase - Ord(aeToString))) then
        Exit(BindNativeMethod(Obj, Result.Obj));
      for Key in Names do
        if ((Obj.RegExp <> nil) and
          ((Key = BuiltinNamespace + 'exec') or (Key = BuiltinNamespace + 'test')) and
          ((MethodIndex = RegExpMethodBase) or (MethodIndex = RegExpMethodBase - 1))) or
          ((Obj.ArrayData <> nil) and Key.StartsWith(BuiltinNamespace) and
          (MethodIndex <= ArrayMethodBase) and (MethodIndex >= ArrayMethodBase - Ord(High(TAVM2ArrayMethod)))) or
          ((Obj.VectorData <> nil) and Key.StartsWith(BuiltinNamespace) and
          (MethodIndex <= VectorMethodBase) and (MethodIndex >= VectorMethodBase - Ord(High(TAVM2VectorMethod)))) then
          Exit(BindNativeMethod(Obj, Result.Obj));
    end;
    Exit;
  end;
  if Length(Names) = 0 then
    raise EAVM2Error.Create('AVM2 property has no namespace');
  AClass := PrimitiveClass(Receiver);
  for Key in Names do
  begin
    if (Receiver.Kind = a2String) and (Key = #0 + 'length') then
      Exit(TAVM2Value.Num(Length(Receiver.Text), a2Int));
    Method := PrimitiveTrait(AClass, Key);
    if Method = pmNone then
      Continue;
    if ForCall then
      Exit(TAVM2Value.Ref(FPrimitiveMethods[Method]));
    Func := NewObject(a2Function);
    Func.Index := FPrimitiveMethods[Method].Index;
    Func.BoundReceiver := Receiver;
    Exit(TAVM2Value.Ref(Func));
  end;
  Prototype := ClassPrototype(AClass);
  for Key in Names do
    if HasProperty(Prototype, Key) then
      Exit(PropertyValue(Prototype, [Key]));
  if not ForCall then
    RaiseScriptError('ReferenceError', 1069, 'Property ' + Copy(Names[0], Pos(#0, Names[0]) + 1, MaxInt) +
      ' not found on ' + AClass.DisplayName + ' and there is no default value.');
  Result := Default(TAVM2Value);
end;

procedure TAVM2Runtime.RejectPrimitiveWrite(const Receiver: TAVM2Value; const Names: TArray<string>; Deleting: Boolean);
var
  AClass: TAVM2Object;
  Key, Name: string;
begin
  if Length(Names) = 0 then
    raise EAVM2Error.Create('AVM2 property has no namespace');
  AClass := PrimitiveClass(Receiver);
  Name := Copy(Names[0], Pos(#0, Names[0]) + 1, MaxInt);
  if Deleting then
    RaiseScriptError('ReferenceError', 1120,
      'Cannot delete property ' + Name + ' on ' + AClass.DisplayName + '.');
  for Key in Names do
  begin
    if (Receiver.Kind = a2String) and (Key = #0 + 'length') then
      RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property length on String.');
    if PrimitiveTrait(AClass, Key) <> pmNone then
      RaiseScriptError('ReferenceError', 1037, 'Cannot assign to a method ' +
        Copy(Key, Pos(#0, Key) + 1, MaxInt) + ' on ' + AClass.DisplayName + '.');
  end;
  RaiseScriptError('ReferenceError', 1056, 'Cannot create property ' + Name + ' on ' + AClass.DisplayName + '.');
end;

procedure TAVM2Runtime.InstallRegExpClass;
const
  Names: array[TAVM2RegExpMethod] of string = ('exec', 'test', 'toString');
var
  Prototype, Native: TAVM2Object;
  Method: TAVM2RegExpMethod;
begin
  FRegExpClass := NewObject(a2Class);
  FRegExpClass.DisplayName := 'RegExp';
  FRegExpClass.Parent := FObjectClass;
  FRegExpClass.Props.Add(#0 + 'length', TAVM2Value.Num(1, a2Int));
  FNative.Props.Add(#0 + 'RegExp', TAVM2Value.Ref(FRegExpClass));
  Prototype := ClassPrototype(FRegExpClass);
  for Method := Low(TAVM2RegExpMethod) to High(TAVM2RegExpMethod) do
  begin
    Native := NewObject(a2Function);
    Native.Index := RegExpMethodBase - Ord(Method);
    Prototype.Props.Add(#0 + Names[Method], TAVM2Value.Ref(Native));
    if Method <> reText then
      Prototype.Props.Add(BuiltinNamespace + Names[Method], TAVM2Value.Ref(Native));
  end;
end;

procedure TAVM2Runtime.InitRegExp(Data: TAVM2RegExp; const Args: TArray<TAVM2Value>);
var
  SourceArg, FlagsArg: TAVM2Value;
  Source: string;
  Flags: TAVM2RegExpFlags;
  Flag: Char;
begin
  SourceArg := Default(TAVM2Value);
  FlagsArg := Default(TAVM2Value);
  if Length(Args) > 0 then
    SourceArg := Args[0];
  if Length(Args) > 1 then
    FlagsArg := Args[1];
  Source := '';
  Flags := [];
  if (SourceArg.Obj <> nil) and (SourceArg.Obj.RegExp <> nil) then
  begin
    if FlagsArg.Kind <> a2Undefined then
      RaiseScriptError('TypeError', 1100, 'Cannot supply flags when constructing one RegExp from another.');
    Source := SourceArg.Obj.RegExp.Source;
    Flags := SourceArg.Obj.RegExp.Flags;
  end
  else
  begin
    if SourceArg.Kind <> a2Undefined then
      Source := CoerceText(SourceArg);
    if FlagsArg.Kind <> a2Undefined then
      for Flag in CoerceText(FlagsArg) do
        case Flag of
          'g':
            Include(Flags, rfGlobal);
          'i':
            Include(Flags, rfIgnoreCase);
          'm':
            Include(Flags, rfMultiline);
          's':
            Include(Flags, rfDotAll);
          'x':
            Include(Flags, rfExtended);
        end;
  end;
  if Data.Compiled <> nil then
    pcre_dispose(Data.Compiled, nil, nil);
  Data.Compiled := nil;
  Data.CompileTried := False;
  Data.LastIndex := 0;
  Data.Source := Source;
  Data.Flags := Flags;
end;

function NewRegExpInput(const Text: string): TAVM2RegExpInput;
{$IFNDEF MSWINDOWS}
var
  Index, Offset: Integer;
  UnitValue: Char;
{$ENDIF}
begin
  Result.Text := AVMStringForTrace(Text) + #0;
  {$IFNDEF MSWINDOWS}
  Result.Encoded := UTF8Encode(Result.Text);
  SetLength(Result.ByteOffsets, Length(Result.Text));
  Offset := 0;
  Index := 0;
  while Index < Length(Text) do
  begin
    UnitValue := Result.Text[Index + 1];
    Result.ByteOffsets[Index] := Offset;
    Inc(Index);
    if UnitValue <= #$7F then
      Inc(Offset)
    else if UnitValue <= #$7FF then
      Inc(Offset, 2)
    else if UnitValue.IsHighSurrogate then
    begin
      Result.ByteOffsets[Index] := Offset;
      Inc(Index);
      Inc(Offset, 4);
    end
    else
      Inc(Offset, 3);
  end;
  Result.ByteOffsets[Index] := Offset;
  {$ENDIF}
end;

{$IFNDEF MSWINDOWS}
function ByteOffsetToUTF16(const Input: TAVM2RegExpInput; Offset: Integer): Integer;
var
  First, Last, Middle: Integer;
begin
  First := 0;
  Last := High(Input.ByteOffsets);
  while First < Last do
  begin
    Middle := (First + Last) div 2;
    if Input.ByteOffsets[Middle] < Offset then
      First := Middle + 1
    else
      Last := Middle;
  end;
  Result := First;
end;
{$ENDIF}

function TAVM2Runtime.FindRegExp(Data: TAVM2RegExp; const Input: TAVM2RegExpInput; Start: Integer; out Match: TAVM2RegExpMatch): Boolean;
var
  Options, ErrorOffset, Count, I, Status, InputStart, InputLength: Integer;
  ErrorText: MarshaledAString;
  Pattern: string;
  Offsets: TArray<Integer>;
  Limits: TPCREExtra;
  Subject: PCRE_STR;
  {$IFNDEF MSWINDOWS}
  EncodedPattern: UTF8String;
  {$ENDIF}
begin
  Result := False;
  if (Start < 0) or (Start >= Length(Input.Text)) then
    Exit;
  if (Start > 0) and Input.Text[Start + 1].IsLowSurrogate and Input.Text[Start].IsHighSurrogate then
    Exit;
  if not Data.CompileTried then
  begin
    Data.CompileTried := True;
    if Length(Data.Source) > RegExpPatternLimit then
      raise EAVM2Error.Create('AVM2 regular expression pattern limit');
    {$IF Declared(LoadPCRELib)}
    if not Data.LibraryLoaded then
    begin
      Data.LibraryLoaded := LoadPCRELib;
      if not Data.LibraryLoaded then
        raise EAVM2Error.Create('Delphi RTL regular expression engine unavailable');
    end;
    {$ENDIF}
    Options := PCRE_JAVASCRIPT_COMPAT or PCRE_NEWLINE_ANY or PCRE_DOLLAR_ENDONLY or PCRE_UTF16;
    if rfIgnoreCase in Data.Flags then
      Options := Options or PCRE_CASELESS;
    if rfMultiline in Data.Flags then
      Options := Options or PCRE_MULTILINE;
    if rfDotAll in Data.Flags then
      Options := Options or PCRE_DOTALL;
    if rfExtended in Data.Flags then
      Options := Options or PCRE_EXTENDED;
    Pattern := StringReplace(AVMStringForTrace(Data.Source), #0, '\x00', [rfReplaceAll]) + #0;
    {$IFDEF MSWINDOWS}
    Data.Compiled := pcre_compile(PChar(Pattern), Options, @ErrorText, @ErrorOffset, nil);
    {$ELSE}
    EncodedPattern := UTF8Encode(Pattern);
    Data.Compiled := pcre_compile(PAnsiChar(EncodedPattern), Options, @ErrorText, @ErrorOffset, nil);
    {$ENDIF}
    if Data.Compiled <> nil then
    begin
      pcre_fullinfo(PPCRE(Data.Compiled), nil, PCRE_INFO_CAPTURECOUNT, @Data.CaptureCount);
      if Data.CaptureCount > RegExpCaptureLimit then
      begin
        pcre_dispose(Data.Compiled, nil, nil);
        Data.Compiled := nil;
        raise EAVM2Error.Create('AVM2 regular expression capture limit');
      end;
    end;
  end;
  if Data.Compiled = nil then
    Exit;
  Dec(FWork, 32 + Data.CaptureCount);
  if FWork < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');
  Count := Data.CaptureCount + 1;
  SetLength(Offsets, 3 * Count);
  Limits := Default(TPCREExtra);
  Limits.flags := PCRE_EXTRA_MATCH_LIMIT or PCRE_EXTRA_MATCH_LIMIT_RECURSION;
  Limits.match_limit := 50000;
  Limits.match_limit_recursion := 512;
  {$IFDEF MSWINDOWS}
  Subject := PChar(Input.Text);
  InputStart := Start;
  InputLength := Length(Input.Text) - 1;
  {$ELSE}
  Subject := PAnsiChar(Input.Encoded);
  InputStart := Input.ByteOffsets[Start];
  InputLength := Length(Input.Encoded) - 1;
  {$ENDIF}
  Status := pcre_exec(PPCRE(Data.Compiled), @Limits, Subject, InputLength, InputStart,
    PCRE_NO_UTF8_CHECK, @Offsets[0], Length(Offsets));
  if Status = PCRE_ERROR_NOMATCH then
    Exit;
  if (Status = PCRE_ERROR_MATCHLIMIT) or (Status = PCRE_ERROR_RECURSIONLIMIT) then
    raise EAVM2Error.Create('AVM2 regular expression execution limit');
  if Status <= 0 then
    raise EAVM2Error.Create('AVM2 regular expression execution failed');
  if (Offsets[0] < InputStart) or (Offsets[1] < Offsets[0]) or (Offsets[1] > InputLength) then
    Exit;
  SetLength(Match.Offsets, 2 * Count);
  for I := 0 to High(Match.Offsets) do
    if (I < 2 * Status) and (Offsets[I] >= 0) then
    begin
      {$IFDEF MSWINDOWS}
      Match.Offsets[I] := Offsets[I];
      {$ELSE}
      Match.Offsets[I] := ByteOffsetToUTF16(Input, Offsets[I]);
      {$ENDIF}
    end
    else
      Match.Offsets[I] := -1;
  Result := True;
end;

function RegExpGroup(const Text: string; const Match: TAVM2RegExpMatch; Group: Integer): string;
var
  First: Integer;
begin
  First := Match.Offsets[2 * Group];
  if First < 0 then
    Exit('');
  Result := Copy(Text, First + 1, Match.Offsets[2 * Group + 1] - First);
end;

function TAVM2Runtime.RegExpResult(Data: TAVM2RegExp; const Text: string; const Match: TAVM2RegExpMatch; IncludeNames: Boolean): TAVM2Object;
var
  Group, I, NameCount, EntrySize: Integer;
  Entry: PCRE_STR;
  Key: string;
  Value: TAVM2Value;
begin
  Result := Construct(FArrayClass, nil);
  for Group := 0 to Data.CaptureCount do
  begin
    Value := Default(TAVM2Value);
    if Match.Offsets[2 * Group] >= 0 then
      Value := TAVM2Value.Str(RegExpGroup(Text, Match, Group));
    SetArrayElement(Result.ArrayData, Group, Value);
  end;
  NameCount := 0;
  if IncludeNames then
    pcre_fullinfo(PPCRE(Data.Compiled), nil, PCRE_INFO_NAMECOUNT, @NameCount);
  if NameCount > 0 then
  begin
    pcre_fullinfo(PPCRE(Data.Compiled), nil, PCRE_INFO_NAMEENTRYSIZE, @EntrySize);
    pcre_fullinfo(PPCRE(Data.Compiled), nil, PCRE_INFO_NAMETABLE, @Entry);
    for I := 1 to NameCount do
    begin
      {$IFDEF MSWINDOWS}
      Group := Ord(Entry[0]);
      Key := string(Entry + 1);
      {$ELSE}
      Group := 256 * Ord(Entry[0]) + Ord(Entry[1]);
      Key := UTF8ToString(Entry + 2);
      {$ENDIF}
      StoreDynamicProperty(Result, #0 + Key, TAVM2Value.Str(RegExpGroup(Text, Match, Group)));
      Inc(Entry, EntrySize);
    end;
  end;
  StoreDynamicProperty(Result, #0 + 'index', TAVM2Value.Num(Match.Offsets[0], a2Int));
  StoreDynamicProperty(Result, #0 + 'input', TAVM2Value.Str(Text));
end;

function TAVM2Runtime.InvokeRegExp(Method: TAVM2RegExpMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  Data: TAVM2RegExp;
  Text: string;
  Start: Integer;
  Input: TAVM2RegExpInput;
  Match: TAVM2RegExpMatch;
  Found: Boolean;
begin
  if (Receiver = nil) or (Receiver.RegExp = nil) then
    RaiseScriptError('TypeError', 1034, 'Type Coercion failed: cannot convert receiver to RegExp.');
  Data := Receiver.RegExp;
  if Method = reText then
    Exit(TAVM2Value.Str(RegExpLiteral(Data)));
  Text := '';
  if Length(Args) > 0 then
    Text := CoerceText(Args[0]);
  Dec(FWork, Length(Text) div 8);
  if FWork < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');
  Input := NewRegExpInput(Text);
  Start := 0;
  if rfGlobal in Data.Flags then
    Start := Data.LastIndex;
  Found := FindRegExp(Data, Input, Start, Match);
  if Found and (rfGlobal in Data.Flags) then
    Data.LastIndex := Match.Offsets[1];
  if Method = reTest then
    Exit(TAVM2Value.Num(Ord(Found), a2Boolean));
  if Found then
    Exit(TAVM2Value.Ref(RegExpResult(Data, Text, Match, True)));
  Result := TAVM2Value.Ref(nil);
end;

function StringPosition(Number: Double; Count: Integer; Wrap: Boolean): Integer;
begin
  if IsNan(Number) then
    Exit(0);
  if Number >= Count then
    Exit(Count);
  if Number < 0 then
  begin
    if not Wrap or (Number <= -Count) then
      Exit(0);
    if Number <= -1 then
      Exit(Count + Trunc(Number));
    Exit(0);
  end;
  Result := Trunc(Number);
end;

function FindStringUnits(const Text, Pattern: string; Start, Limit: Integer; Last: Boolean; var Work: Integer): Integer;
var
  Prefix: TArray<Integer>;
  I, J, Count: Integer;
begin
  Result := -1;
  Count := Length(Pattern);
  if Count > Limit - Start then
    Exit;
  if Count = 0 then
  begin
    if Last then
      Exit(Limit);
    Exit(Start);
  end;
  Dec(Work, 2 * Count);
  if Work < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');
  SetLength(Prefix, Count);
  J := 0;
  for I := 1 to Count - 1 do
  begin
    while (J > 0) and (Pattern[I + 1] <> Pattern[J + 1]) do
      J := Prefix[J - 1];
    if Pattern[I + 1] = Pattern[J + 1] then
      Inc(J);
    Prefix[I] := J;
  end;
  J := 0;
  for I := Start + 1 to Limit do
  begin
    Dec(Work, 2);
    if Work < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    while (J > 0) and (Text[I] <> Pattern[J + 1]) do
      J := Prefix[J - 1];
    if Text[I] = Pattern[J + 1] then
      Inc(J);
    if J = Count then
    begin
      Result := I - Count;
      if not Last then
        Exit;
      J := Prefix[J - 1];
    end;
  end;
end;

function TAVM2Runtime.CoercePrimitive(const Value: TAVM2Value; PreferText: Boolean): TAVM2Value;
const
  Methods: array[0..1] of string = (#0 + 'valueOf', #0 + 'toString');
var
  I: Integer;
  Method, Converted: TAVM2Value;
begin
  if Value.Obj <> nil then
    for I := 0 to High(Methods) do
    begin
      Method := PropertyValue(Value.Obj, [Methods[I xor Ord(PreferText)]]);
      if (Method.Obj = nil) or (Method.Obj.Kind <> a2Function) then
        Continue;
      Converted := Invoke(Method.Obj, Value, nil);
      if Converted.Kind <> a2Object then
        Exit(Converted);
    end;
  Result := Value;
end;

function TAVM2Runtime.CoerceText(const Value: TAVM2Value): string;
begin
  Result := AsText(CoercePrimitive(Value, True));
end;

function TAVM2Runtime.CoerceNumber(const Value: TAVM2Value): Double;
begin
  Result := AsNumber(CoercePrimitive(Value, False));
end;

procedure AppendRegExpText(Builder: TStringBuilder; const Text: string);
begin
  if Length(Text) > TextLimit - Builder.Length then
    raise EAVM2Error.Create('AVM2 string size limit');
  Builder.Append(Text);
end;

procedure ExpandRegExpReplacement(Builder: TStringBuilder; const Text, Replacement: string; const Match: TAVM2RegExpMatch);
var
  I, Run, Group, TwoDigits, Count: Integer;
  Code: Char;
  LeadingZero: Boolean;
begin
  Count := Length(Match.Offsets) div 2;
  Run := 1;
  I := 1;
  while I < Length(Replacement) do
  begin
    if Replacement[I] <> '$' then
    begin
      Inc(I);
      Continue;
    end;
    AppendRegExpText(Builder, Copy(Replacement, Run, I - Run));
    Code := Replacement[I + 1];
    Inc(I, 2);
    case Code of
      '$':
        AppendRegExpText(Builder, '$');
      '&':
        AppendRegExpText(Builder, RegExpGroup(Text, Match, 0));
      #96:
        AppendRegExpText(Builder, Copy(Text, 1, Match.Offsets[0]));
      '''':
        AppendRegExpText(Builder, Copy(Text, Match.Offsets[1] + 1, MaxInt));
      '0'..'9':
        begin
          Group := Ord(Code) - Ord('0');
          LeadingZero := False;
          if (Group < Count) and (I <= Length(Replacement)) and
            CharInSet(Replacement[I], ['0'..'9']) then
          begin
            TwoDigits := Group * 10 + Ord(Replacement[I]) - Ord('0');
            if (TwoDigits > 0) and (TwoDigits < Count) then
            begin
              LeadingZero := Group = 0;
              Group := TwoDigits;
              Inc(I);
            end;
          end;
          if (Group > 0) and (Group < Count) then
          begin
            AppendRegExpText(Builder, RegExpGroup(Text, Match, Group));
            if LeadingZero then
              AppendRegExpText(Builder, Replacement[I - 1]);
          end
          else
            AppendRegExpText(Builder, '$' + Code);
        end;
    else
      AppendRegExpText(Builder, '$' + Code);
    end;
    Run := I;
  end;
  AppendRegExpText(Builder, Copy(Replacement, Run, MaxInt));
end;

function TAVM2Runtime.StringRegExp(Method: TAVM2PrimitiveMethod; const Text: string; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  PatternArg, ReplacementArg: TAVM2Value;
  Owned, Data: TAVM2RegExp;
  Input: TAVM2RegExpInput;
  Match: TAVM2RegExpMatch;
  ArrayObject, Callback: TAVM2Object;
  Builder: TStringBuilder;
  Params: TArray<TAVM2Value>;
  Pattern, Replacement: string;
  Position, First, After, Group, Count, Width: Integer;
  MaxItems: Cardinal;
  Found, GlobalMatch: Boolean;

  procedure AddPart(const Part: string);
  begin
    SetArrayElement(ArrayObject.ArrayData, ArrayObject.ArrayData.ArrayLength, TAVM2Value.Str(Part));
  end;

begin
  PatternArg := Default(TAVM2Value);
  ReplacementArg := Default(TAVM2Value);
  if Length(Args) > 0 then
    PatternArg := Args[0];
  if Length(Args) > 1 then
    ReplacementArg := Args[1];
  Data := nil;
  if PatternArg.Obj <> nil then
    Data := PatternArg.Obj.RegExp;
  Owned := nil;
  if (Data = nil) and (Method in [pmMatch, pmSearch]) then
  begin
    Owned := TAVM2RegExp.Create;
    Data := Owned;
  end;
  try
    if Owned <> nil then
      Owned.Source := CoerceText(PatternArg);
    if Data <> nil then
    begin
      Dec(FWork, Length(Text) div 8);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      Input := NewRegExpInput(Text);
    end;
    case Method of
      pmSearch:
        begin
          if FindRegExp(Data, Input, 0, Match) then
            Exit(TAVM2Value.Num(Match.Offsets[0], a2Int));
          Exit(TAVM2Value.Num(-1, a2Int));
        end;
      pmMatch:
        begin
          if not (rfGlobal in Data.Flags) then
          begin
            if FindRegExp(Data, Input, 0, Match) then
              Exit(TAVM2Value.Ref(RegExpResult(Data, Text, Match, False)));
            Exit(TAVM2Value.Ref(nil));
          end;
          ArrayObject := Construct(FArrayClass, nil);
          Position := 0;
          while FindRegExp(Data, Input, Position, Match) and (Match.Offsets[1] <> Position) do
          begin
            AddPart(RegExpGroup(Text, Match, 0));
            Position := Match.Offsets[1];
          end;
          Data.LastIndex := Ord(Data.LastIndex = 0);
          Exit(TAVM2Value.Ref(ArrayObject));
        end;
      pmSplit:
        begin
          ArrayObject := Construct(FArrayClass, nil);
          MaxItems := High(Cardinal);
          if ReplacementArg.Kind <> a2Undefined then
            MaxItems := IntBits(AsNumber(ReplacementArg));
          Position := 0;
          if Data.Source = '' then
          begin
            while (Position < Length(Text)) and (ArrayObject.ArrayData.ArrayLength < MaxItems) do
            begin
              Width := 1;
              if Text[Position + 1].IsHighSurrogate and (Position + 1 < Length(Text)) and
                Text[Position + 2].IsLowSurrogate then
                Width := 2
              else if Text[Position + 1].IsSurrogate then
                Break;
              AddPart(Copy(Text, Position + 1, Width));
              Inc(Position, Width);
            end;
          end
          else if MaxItems > 0 then
          begin
            while FindRegExp(Data, Input, Position, Match) do
            begin
              if Match.Offsets[1] = Position then
                Break;
              AddPart(Copy(Text, Position + 1, Match.Offsets[0] - Position));
              if ArrayObject.ArrayData.ArrayLength >= MaxItems then
                Break;
              for Group := 1 to Data.CaptureCount do
                if Match.Offsets[2 * Group] >= 0 then
                begin
                  AddPart(RegExpGroup(Text, Match, Group));
                // Flash can append another field after the captures reach the limit.
                  if ArrayObject.ArrayData.ArrayLength >= MaxItems then
                    Break;
                end;
              Position := Match.Offsets[1];
            end;
            if ArrayObject.ArrayData.ArrayLength < MaxItems then
              AddPart(Copy(Text, Position + 1, MaxInt));
          end;
          Exit(TAVM2Value.Ref(ArrayObject));
        end;
    end;

    if Data <> nil then
    begin
      Found := FindRegExp(Data, Input, 0, Match);
      GlobalMatch := rfGlobal in Data.Flags;
    end
    else
    begin
      Pattern := CoerceText(PatternArg);
      First := FindStringUnits(Text, Pattern, 0, Length(Text), False, FWork);
      Found := First >= 0;
      if Found then
        Match.Offsets := [First, First + Length(Pattern)];
      GlobalMatch := False;
    end;
    if not Found then
      Exit(TAVM2Value.Str(Text));
    Callback := ReplacementArg.Obj;
    if (Callback <> nil) and (Callback.Kind <> a2Function) then
      Callback := nil;
    if Callback = nil then
      Replacement := CoerceText(ReplacementArg);
    Position := 0;
    Builder := TStringBuilder.Create;
    try
      repeat
        First := Match.Offsets[0];
        After := Match.Offsets[1];
        AppendRegExpText(Builder, Copy(Text, Position + 1, First - Position));
        if Callback <> nil then
        begin
          Count := Length(Match.Offsets) div 2;
          SetLength(Params, Count + 2);
          for Group := 0 to Count - 1 do
            Params[Group] := TAVM2Value.Str(RegExpGroup(Text, Match, Group));
          Params[Count] := TAVM2Value.Num(First, a2Int);
          Params[Count + 1] := TAVM2Value.Str(Text);
          AppendRegExpText(Builder, CoerceText(Invoke(Callback, TAVM2Value.Ref(nil), Params)));
        end
        else if Data <> nil then
          ExpandRegExpReplacement(Builder, Text, Replacement, Match)
        else
          AppendRegExpText(Builder, Replacement);
        Position := After;
        if (First = After) and (Data <> nil) and (Position < Length(Text)) then
        begin
          AppendRegExpText(Builder, Text[Position + 1]);
          Inc(Position);
        end
        else if First = After then
          Break;
      until not GlobalMatch or not FindRegExp(Data, Input, Position, Match);
      AppendRegExpText(Builder, Copy(Text, Position + 1, MaxInt));
      Result := TAVM2Value.Str(Builder.ToString);
    finally
      Builder.Free;
    end;
  finally
    Owned.Free;
  end;
end;

function PrimitiveNumberText(Number: Double; Radix: Integer): string;
const
  Digits = '0123456789abcdefghijklmnopqrstuvwxyz';
var
  Bits: UInt64;
  Magnitude: Cardinal;
  First: Integer;
  Buffer: array[0..32] of Char;
  Negative: Boolean;
begin
  if (Radix = 10) or IsNan(Number) or IsInfinite(Number) then
    Exit(AsText(TAVM2Value.Num(Number)));
  Move(Number, Bits, SizeOf(Bits));
  Negative := Bits shr 63 <> 0;
  Number := Abs(Number);
  if (Number <= High(Cardinal)) and (Frac(Number) = 0) then
  begin
    Magnitude := Cardinal(Trunc(Number));
    First := Length(Buffer);
    repeat
      Dec(First);
      Buffer[First] := Digits[Magnitude mod Cardinal(Radix) + 1];
      Magnitude := Magnitude div Cardinal(Radix);
    until Magnitude = 0;
    if Negative and (Number <> 0) then
    begin
      Dec(First);
      Buffer[First] := '-';
    end;
    SetString(Result, PChar(@Buffer[First]), Length(Buffer) - First);
    Exit;
  end;
  Result := '';
  repeat
    Result := Digits[Trunc(FMod(Number, Radix)) + 1] + Result;
    Number := Number / Radix;
  until Number < 1;
  if Negative then
    Result := '-' + Result;
end;

type
  TDecimalMagnitude = record
    Size: Integer;
    // 432 decimal digits cover binary64 scaling, including 21-digit precision.
    Words: array[0..47] of Cardinal;
  end;

const
  DecimalWordBase = 1000000000;
  DecimalPowers: array[0..9] of Cardinal = (1, 10, 100, 1000, 10000, 100000, 1000000,
    10000000, 100000000, DecimalWordBase);

function DecimalMagnitude(Value: UInt64): TDecimalMagnitude;
begin
  Result := Default(TDecimalMagnitude);
  while Value <> 0 do
  begin
    Result.Words[Result.Size] := Value mod DecimalWordBase;
    Value := Value div DecimalWordBase;
    Inc(Result.Size);
  end;
end;

procedure MultiplyMagnitude(var Value: TDecimalMagnitude; Factor: Cardinal);
var
  I: Integer;
  Carry: UInt64;
begin
  Carry := 0;
  for I := 0 to Value.Size - 1 do
  begin
    Carry := UInt64(Value.Words[I]) * Factor + Carry;
    Value.Words[I] := Carry mod DecimalWordBase;
    Carry := Carry div DecimalWordBase;
  end;
  if Carry <> 0 then
  begin
    Value.Words[Value.Size] := Carry;
    Inc(Value.Size);
  end;
end;

procedure ScaleMagnitude(var Value: TDecimalMagnitude; Base, Exponent: Integer);
begin
  if Base = 2 then
  begin
    while Exponent >= 29 do
    begin
      MultiplyMagnitude(Value, Cardinal(1) shl 29);
      Dec(Exponent, 29);
    end;
    if Exponent > 0 then
      MultiplyMagnitude(Value, Cardinal(1) shl Exponent);
  end
  else
  begin
    while Exponent >= 9 do
    begin
      MultiplyMagnitude(Value, DecimalWordBase);
      Dec(Exponent, 9);
    end;
    if Exponent > 0 then
      MultiplyMagnitude(Value, DecimalPowers[Exponent]);
  end;
end;

function CompareMagnitude(const A, B: TDecimalMagnitude): Integer;
var
  I: Integer;
begin
  Result := A.Size - B.Size;
  if Result <> 0 then
    Exit;
  for I := A.Size - 1 downto 0 do
    if A.Words[I] <> B.Words[I] then
      Exit(Integer(A.Words[I]) - Integer(B.Words[I]));
end;

procedure SubtractMagnitude(var A: TDecimalMagnitude; const B: TDecimalMagnitude);
var
  I, Difference, Borrow: Integer;
begin
  Borrow := 0;
  for I := 0 to A.Size - 1 do
  begin
    Difference := Integer(A.Words[I]) - Borrow;
    if I < B.Size then
      Dec(Difference, Integer(B.Words[I]));
    Borrow := Ord(Difference < 0);
    A.Words[I] := Difference + Borrow * DecimalWordBase;
  end;
  while (A.Size > 0) and (A.Words[A.Size - 1] = 0) do
    Dec(A.Size);
end;

function InsideUpperMargin(const Remainder, Denominator, HighMargin: TDecimalMagnitude): Boolean;
var
  Minimum: TDecimalMagnitude;
begin
  if CompareMagnitude(HighMargin, Denominator) >= 0 then
    Exit(True);
  Minimum := Denominator;
  SubtractMagnitude(Minimum, HighMargin);
  Result := CompareMagnitude(Remainder, Minimum) >= 0;
end;

function FormatFlashNumber(Number: Double; Method: TAVM2PrimitiveMethod; Digits: Integer; var Work: Integer): string;
var
  Bits, Mantissa, Top: UInt64;
  Remainder, Denominator, LowMargin, HighMargin: TDecimalMagnitude;
  BinaryExponent, BinaryOrder, Guard, Point, Retain, I, Digit, Exponent: Integer;
  Significand: string;
  Finished, Scientific: Boolean;

  function NextDigit: Integer;
  var
    Twice: TDecimalMagnitude;
    Low, High: Boolean;
  begin
    Result := 0;
    if Finished then
      Exit;
    Dec(Work, 1 + Denominator.Size div 4);
    if Work < 0 then
      raise EAVM2Error.Create('AVM2 instruction limit');
    while CompareMagnitude(Remainder, Denominator) >= 0 do
    begin
      SubtractMagnitude(Remainder, Denominator);
      Inc(Result);
    end;
    Low := CompareMagnitude(Remainder, LowMargin) <= 0;
    High := InsideUpperMargin(Remainder, Denominator, HighMargin);
    Finished := Low or High;
    if not Finished then
    begin
      MultiplyMagnitude(Remainder, 10);
      MultiplyMagnitude(LowMargin, 10);
      MultiplyMagnitude(HighMargin, 10);
    end
    else if High then
    begin
      Twice := Remainder;
      MultiplyMagnitude(Twice, 2);
      if not Low or (CompareMagnitude(Twice, Denominator) >= 0) then
        Inc(Result);
    end;
  end;

  procedure RoundLast;
  var
    Position: Integer;
  begin
    Position := Length(Significand);
    while (Position > 0) and (Significand[Position] = '9') do
    begin
      Significand[Position] := '0';
      Dec(Position);
    end;
    if Position > 0 then
      Significand[Position] := Succ(Significand[Position])
    else
      Significand := '1' + Significand;
  end;

begin
  if IsNan(Number) or IsInfinite(Number) then
    Exit(AsText(TAVM2Value.Num(Number)));
  if Number = 0 then
  begin
    if Method = pmNumberExponential then
    begin
      if Digits = 0 then
        Exit('1e-15');
      Exit('0.' + StringOfChar('0', Digits) + 'e-16');
    end;
    if Digits = 0 then
      Exit('0');
    Exit('0.' + StringOfChar('0', Digits));
  end;

  Move(Number, Bits, SizeOf(Bits));
  Mantissa := Bits and $000FFFFFFFFFFFFF;
  BinaryExponent := Integer((Bits shr 52) and $7FF);
  if BinaryExponent = 0 then
    BinaryExponent := -1074
  else
  begin
    Mantissa := Mantissa or $0010000000000000;
    Dec(BinaryExponent, 1075);
  end;
  Dec(Work, 8 + Abs(BinaryExponent) div 8);
  if Work < 0 then
    raise EAVM2Error.Create('AVM2 instruction limit');

  // Half-ULP bounds narrow by the requested precision. They can terminate
  // the digit stream before the output is padded to its requested width.
  Guard := 2;
  if Mantissa = $0010000000000000 then
    Guard := 4;
  Remainder := DecimalMagnitude(Mantissa * UInt64(Guard));
  Denominator := DecimalMagnitude(Guard);
  LowMargin := DecimalMagnitude(1);
  HighMargin := DecimalMagnitude(Guard div 2);
  if BinaryExponent >= 0 then
  begin
    ScaleMagnitude(Remainder, 2, BinaryExponent);
    ScaleMagnitude(LowMargin, 2, BinaryExponent);
    ScaleMagnitude(HighMargin, 2, BinaryExponent);
  end
  else
    ScaleMagnitude(Denominator, 2, -BinaryExponent);
  ScaleMagnitude(Remainder, 10, Digits);
  ScaleMagnitude(Denominator, 10, Digits);

  BinaryOrder := BinaryExponent;
  Top := Mantissa;
  while Top > 1 do
  begin
    Top := Top shr 1;
    Inc(BinaryOrder);
  end;
  Point := Ceil(BinaryOrder * 0.301029995663981195 - 1.0e-10);
  if Point >= 0 then
    ScaleMagnitude(Denominator, 10, Point)
  else
  begin
    ScaleMagnitude(Remainder, 10, -Point);
    ScaleMagnitude(LowMargin, 10, -Point);
    ScaleMagnitude(HighMargin, 10, -Point);
  end;
  if InsideUpperMargin(Remainder, Denominator, HighMargin) then
    Inc(Point)
  else
  begin
    MultiplyMagnitude(Remainder, 10);
    MultiplyMagnitude(LowMargin, 10);
    MultiplyMagnitude(HighMargin, 10);
  end;

  Scientific := (Method = pmNumberExponential) or ((Method = pmNumberPrecision) and (Point > Digits));
  case Method of
    pmNumberFixed:
      Retain := Point + Digits;
    pmNumberExponential:
      Retain := Digits + 1;
  else
    Retain := Digits;
  end;
  Finished := False;
  SetLength(Significand, Max(Retain, 0));
  for I := 1 to Retain do
  begin
    Digit := NextDigit;
    if Digit = 10 then
    begin
      SetLength(Significand, I - 1);
      RoundLast;
      if Length(Significand) = I then
      begin
        Inc(Point);
        Significand := Significand + StringOfChar('0', Retain - I + Ord(Method = pmNumberFixed));
      end
      else
        Significand := Significand + StringOfChar('0', Retain - I + 1);
      Break;
    end;
    Significand[I] := Char(Ord('0') + Digit);
  end;
  if (Method <> pmNumberExponential) and (Retain >= 0) and (NextDigit >= 5) then
  begin
    RoundLast;
    if Length(Significand) > Retain then
    begin
      Inc(Point);
      if Method = pmNumberPrecision then
        SetLength(Significand, Retain);
    end;
  end;

  if Scientific then
  begin
    Result := Significand;
    if Length(Result) > 1 then
      Insert('.', Result, 2);
    Exponent := Point - 1;
    if Exponent > 0 then
      Result := Result + 'e+' + IntToStr(Exponent)
    else if Exponent < 0 then
      Result := Result + 'e' + IntToStr(Exponent);
  end
  else if Significand = '' then
  begin
    Result := '0';
    if Digits > 0 then
      Result := Result + '.' + StringOfChar('0', Digits);
  end
  else if Point <= 0 then
    Result := '0.' + StringOfChar('0', -Point) + Significand
  else if Point < Length(Significand) then
  begin
    Result := Significand;
    Insert('.', Result, Point + 1);
  end
  else
    Result := Significand + StringOfChar('0', Point - Length(Significand));
  if Number < 0 then
    Result := '-' + Result;
end;

function TAVM2Runtime.InvokePrimitive(Method: TAVM2PrimitiveMethod; Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  AClass, Arr: TAVM2Object;
  Kind: TAVM2TypeKind;
  Text, Needle, Part: string;
  Position, Stop, Count, Found, I, Radix: Integer;
  Index, Limit: Double;
  MaxItems: Cardinal;
  Builder: TStringBuilder;
  Arg: TAVM2Value;

  function NumberArg(ArgIndex: Integer; DefaultNumber: Double): Double;
  begin
    if ArgIndex < Length(Args) then
      Result := AsNumber(Args[ArgIndex])
    else
      Result := DefaultNumber;
  end;

begin
  if Method = pmFromCharCode then
  begin
    SetLength(Text, Length(Args));
    for I := 0 to High(Args) do
      Text[I + 1] := Char(IntBits(AsNumber(Args[I])) and $FFFF);
    Exit(TAVM2Value.Str(Text));
  end;
  case Method of
    pmNumberText..pmNumberPrecision:
      Kind := atNumber;
    pmBooleanText, pmBooleanValue:
      Kind := atBoolean;
  else
    Kind := atString;
  end;
  AClass := FPrimitiveClasses[Kind];
  if Receiver.Obj = AClass.InstancePrototype then
  begin
    if Method = pmNumberText then
      Exit(TAVM2Value.Str('0'));
    Receiver := ConvertPrimitive(Kind, nil);
  end;
  if Method in [pmNumberFixed..pmNumberPrecision] then
  begin
    if (Method = pmNumberPrecision) and ((Length(Args) = 0) or
      (Args[0].Kind in [a2Null, a2Undefined])) then
      Exit(TAVM2Value.Str(AsText(Receiver)));
    Radix := Integer(IntBits(NumberArg(0, 0)));
    I := Ord(Method = pmNumberPrecision);
    if (Radix < I) or (Radix > 20 + I) then
      RaiseScriptError('RangeError', 1002,
        'Number.toPrecision has a range of 1 to 21. Number.toFixed and Number.toExponential have a range of 0 to 20. ' +
        'Specified value is not within expected range.');
    Exit(TAVM2Value.Str(FormatFlashNumber(AsNumber(Receiver), Method, Radix, FWork)));
  end;
  if Method in [pmStringText..pmNumberValue] then
  begin
    if not ValueHasType(Receiver, Kind, nil) then
      RaiseScriptError('TypeError', 1004,
        'Method ' + AClass.DisplayName + '.prototype.' + PrimitiveMethodNames[Method] + ' was invoked on an incompatible object.');
    case Method of
      pmStringValue, pmBooleanValue, pmNumberValue:
        Exit(Receiver);
      pmNumberText:
        begin
          Radix := Integer(IntBits(NumberArg(0, 10)));
          if (Radix < 2) or (Radix > 36) then
            RaiseScriptError('RangeError', 1003,
              'The radix argument must be between 2 and 36; got ' + IntToStr(Radix) + '.');
          Exit(TAVM2Value.Str(PrimitiveNumberText(Receiver.Number, Radix)));
        end;
    end;
    Exit(TAVM2Value.Str(AsText(Receiver)));
  end;

  Text := AsText(Receiver);
  if Method in [pmMatch, pmSearch, pmReplace] then
    Exit(StringRegExp(Method, Text, Args));
  if (Method = pmSplit) and (Length(Args) > 0) and (Args[0].Obj <> nil) and
    (Args[0].Obj.RegExp <> nil) then
    Exit(StringRegExp(Method, Text, Args));
  Count := Length(Text);
  case Method of
    pmCharAt, pmCharCodeAt:
      begin
        Index := NumberArg(0, 0);
        if IsNan(Index) then
          Index := 0;
        if (Index >= 0) and (Index < Count) then
        begin
          Position := Trunc(Index) + 1;
          if Method = pmCharAt then
            Exit(TAVM2Value.Str(Text[Position]));
          Exit(TAVM2Value.Num(Ord(Text[Position])));
        end;
        if Method = pmCharAt then
          Exit(TAVM2Value.Str(''));
        Exit(TAVM2Value.Num(NaN));
      end;
    pmConcat:
      begin
        Builder := TStringBuilder.Create(Text);
        try
          for Arg in Args do
          begin
            Part := AsText(Arg);
            if Length(Part) > TextLimit - Builder.Length then
              raise EAVM2Error.Create('AVM2 string size limit');
            Builder.Append(Part);
          end;
          Text := Builder.ToString;
        finally
          Builder.Free;
        end;
      end;
    pmIndexOf, pmLastIndexOf:
      begin
        Needle := 'undefined';
        if Length(Args) > 0 then
        begin
          if Args[0].Kind in [a2Null, a2Undefined] then
            Exit(TAVM2Value.Num(-1, a2Int));
          Needle := AsText(Args[0]);
        end;
        if Method = pmIndexOf then
        begin
          Position := StringPosition(NumberArg(1, 0), Count, False);
          Found := FindStringUnits(Text, Needle, Position, Count, False, FWork);
        end
        else
        begin
          Index := NumberArg(1, High(Integer));
          if Index <= -1 then
            Exit(TAVM2Value.Num(-1, a2Int));
          if IsNan(Index) then
            Stop := Count
          else
            Stop := Min(Count, StringPosition(Index, Count, False) + Length(Needle));
          Found := FindStringUnits(Text, Needle, 0, Stop, True, FWork);
        end;
        Exit(TAVM2Value.Num(Found, a2Int));
      end;
    pmSlice, pmSubstring, pmSubstr:
      begin
        Index := NumberArg(0, 0);
        Limit := NumberArg(1, High(Integer));
        Position := StringPosition(Index, Count, Method <> pmSubstring);
        if Method = pmSubstr then
        begin
          if (Limit <= -1) and not IsInfinite(Limit) then
          begin
            Limit := Count + Limit;
            if StringPosition(Limit, Count, False) + Position >= Count then
              Limit := 0;
          end;
          Stop := Position + StringPosition(Limit, Count - Position, False);
        end
        else
        begin
          Stop := StringPosition(Limit, Count, Method = pmSlice);
          if (Method = pmSubstring) and (Stop < Position) then
          begin
            I := Position;
            Position := Stop;
            Stop := I;
          end;
        end;
        Text := Copy(Text, Position + 1, Max(0, Stop - Position));
      end;
    pmSplit:
      begin
        MaxItems := High(Cardinal);
        if (Length(Args) > 1) and (Args[1].Kind <> a2Undefined) then
          MaxItems := IntBits(AsNumber(Args[1]));
        Arr := Construct(FArrayClass, nil);
        if MaxItems = 0 then
          Exit(TAVM2Value.Ref(Arr));
        Needle := 'undefined';
        if Length(Args) > 0 then
          Needle := AsText(Args[0]);
        if (Needle = '') and (Count > 0) then
        begin
          for I := 1 to Integer(Min(Cardinal(Count), MaxItems)) do
            SetArrayElement(Arr.ArrayData, Arr.ArrayData.ArrayLength, TAVM2Value.Str(Text[I]));
        end
        else
        begin
          Position := 0;
          while Arr.ArrayData.ArrayLength < MaxItems do
          begin
            if Needle = '' then
              Found := -1
            else
              Found := FindStringUnits(Text, Needle, Position, Count, False, FWork);
            if Found < 0 then
              Stop := Count
            else
              Stop := Found;
            SetArrayElement(Arr.ArrayData, Arr.ArrayData.ArrayLength, TAVM2Value.Str(Copy(Text, Position + 1, Stop - Position)));
            if Found < 0 then
              Break;
            Position := Found + Length(Needle);
          end;
        end;
        Exit(TAVM2Value.Ref(Arr));
      end;
    pmLowerCase, pmUpperCase:
      begin
        Dec(FWork, Count);
        if FWork < 0 then
          raise EAVM2Error.Create('AVM2 instruction limit');
        UniqueString(Text);
        if Method = pmLowerCase then
          for I := 1 to Count do
            Text[I] := Text[I].ToLower
        else
          for I := 1 to Count do
            Text[I] := Text[I].ToUpper;
      end;
  end;
  Result := TAVM2Value.Str(Text);
end;

function TAVM2Runtime.Instantiate(AClass: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
begin
  if AClass = FObjectClass then
  begin
    if (Length(Args) > 0) and not (Args[0].Kind in [a2Undefined, a2Null]) then
      Exit(Args[0]);
    Exit(TAVM2Value.Ref(Construct(AClass, nil)));
  end;
  if (AClass <> nil) and (AClass.PrimitiveKind in [atString..atUInt]) then
    Exit(ConvertPrimitive(AClass.PrimitiveKind, Args));
  Result := TAVM2Value.Ref(Construct(AClass, Args));
end;

function TAVM2Runtime.Construct(ClassObject: TAVM2Object; const Args: TArray<TAVM2Value>; Existing: TObject): TAVM2Object;
var
  Value: TAVM2Value;
  Bytes: TBytes;
begin
  if (ClassObject = nil) or not (ClassObject.Kind in [a2Class, a2Function]) then
    RaiseScriptError('TypeError', 1007, 'Instantiation attempted on a non-constructor.');
  if ClassObject = FClassClass then
    RaiseScriptError('TypeError', 1115, 'Class$ is not a constructor.');
  if ClassObject = FVectorClass then
    RaiseScriptError('TypeError', 1115, 'Vector$ is not a constructor.');
  if ClassObject.Kind = a2Function then
  begin
    if (ClassObject.BoundReceiver.Kind <> a2Undefined) or ((ClassObject.Module = nil) and
      (ClassObject.Index <> EmptyFunctionMethod)) then
      RaiseScriptError('TypeError', 1064, 'Cannot call a method as a constructor.');
    if ClassObject.FunctionPrototype = nil then
      ClassObject.FunctionPrototype := FObjectPrototype;
    Result := NewObject(a2PlainObject, True);
    Result.ClassObject := FObjectClass;
    Result.Parent := ClassObject.FunctionPrototype;
    Value := Invoke(ClassObject, Result, Args);
    if Value.Kind in [a2Object, a2Null] then
      Result := Value.Obj;
    Exit;
  end;
  if ClassObject = FFunctionClass then
  begin
    if Length(Args) > 0 then
      RaiseScriptError('EvalError', 1066, 'The form function(''function body'') is not supported.');
    Result := NewObject(a2Function, True);
    Result.Index := EmptyFunctionMethod;
    Result.DisplayName := 'Function';
    InitializeFunctionPrototype(Result);
    Exit;
  end;
  if (ClassObject.Index < 0) and (ClassObject.DisplayName = 'Object') and
    (Length(Args) > 0) and (Args[0].Kind = a2Object) then
    Exit(Args[0].Obj);
  Result := NewObject(a2PlainObject, ClassObject.DisplayKind = adNone);
  Result.DisplayName := ClassObject.DisplayName;
  Result.ClassObject := ClassObject;
  if ClassObject.IsVectorType then
    Result.VectorData := TList<TAVM2Value>.Create;
  Result.Parent := ClassPrototype(ClassObject);
  if ClassObject.CanDispatch then
    BindDispatcher(Result);
  BindDisplay(Result, ClassObject.DisplayKind, False, Existing);
  InstallInstanceTraits(ClassObject, Result);
  if (Result.ByteArrayData <> nil) and (FDisplay <> nil) and
    FDisplay.EmbeddedBytes(QualifiedClassName(ClassObject), Bytes) then
  begin
    ResizeByteArray(Result.ByteArrayData, Length(Bytes));
    if Length(Bytes) > 0 then
      Move(Bytes[0], Result.ByteArrayData.Buffer[0], Length(Bytes));
  end;
  if (ClassObject.Module <> nil) or (Existing <> nil) then
    SyncDisplayChildren(Result, 0);
  ConstructInto(ClassObject, Result, Args);
end;

function TAVM2Runtime.LinkedClass(const Name: string): TAVM2Object;
var
  KeyName: string;
  I: Integer;
  Script: TAVM2Object;
  Value: TAVM2Value;
begin
  if Name = '' then
    Exit(nil);
  I := LastDelimiter('.', Name);
  if I = 0 then
    KeyName := #0 + Name
  else
    KeyName := Copy(Name, 1, I - 1) + #0 + Copy(Name, I + 1, MaxInt);
  if not FDefinitions.TryGetValue(KeyName, Script) then
    Exit(nil);
  Initialize(Script);
  Value := PropertyValue(Script, [KeyName]);
  if (Value.Obj = nil) or (Value.Obj.Kind <> a2Class) then
    raise EAVM2Error.CreateFmt('Invalid AVM2 symbol class %s', [Name]);
  Result := Value.Obj;
end;

procedure TAVM2Runtime.CreateDocument(const Name: string);
var
  DocumentClass, Instance: TAVM2Object;
begin
  if FDocument <> nil then
    Exit;
  if Name = '' then
    DocumentClass := FNative.Props['flash.display' + #0 + 'MovieClip'].Obj
  else
    DocumentClass := LinkedClass(Name);
  if DocumentClass = nil then
    Exit;
  Instance := NewObject(a2PlainObject);
  Instance.ClassObject := DocumentClass;
  Instance.Parent := ClassPrototype(DocumentClass);
  Instance.DisplayName := DocumentClass.DisplayName;
  if DocumentClass.CanDispatch then
    BindDispatcher(Instance);
  BindDisplay(Instance, DocumentClass.DisplayKind, True);
  if Instance.DisplayKind <> adNone then
  begin
    Instance.DisplayParent := FStage;
    FStage.DisplayChildren.Add(Instance);
    FStage.Props[#0 + 'numChildren'] := TAVM2Value.Num(FStage.DisplayChildren.Count, a2Int);
    Instance.Props.AddOrSetValue(#0 + 'parent', TAVM2Value.Ref(FStage));
  end;
  InstallInstanceTraits(DocumentClass, Instance);
  FDocument := Instance;
  FLoaderInfo.Props[#0 + 'content'] := TAVM2Value.Ref(Instance);
  SyncDisplayChildren(Instance, 0);
  ConstructInto(DocumentClass, Instance, nil);
end;

procedure TAVM2Runtime.RunFrameScript(Handle: TObject; Frame: Integer);
var
  Clip, Routine: TAVM2Object;
begin
  Clip := DisplayObjectAt(Handle);
  if (Clip <> nil) and (Clip.FrameScripts <> nil) and Clip.FrameScripts.TryGetValue(Frame, Routine) then
    Invoke(Routine, Clip, nil);
end;

function LegacyEscape(const Text: string; Decode: Boolean): string;
var
  Builder: TStringBuilder;
  I, First, Digits, EndPos, Value: Integer;
  Ch: Char;
begin
  Builder := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(Text) do
    begin
      Ch := Text[I];
      Inc(I);
      if Decode and (Ch = '%') then
      begin
        First := I;
        Digits := 2;
        if (I <= Length(Text)) and (Text[I] = 'u') then
        begin
          Inc(First);
          Digits := 4;
        end;
        EndPos := First;
        while (EndPos < First + Digits) and (EndPos <= Length(Text)) and
          CharInSet(Text[EndPos], ['0'..'9', 'A'..'F', 'a'..'f']) do
          Inc(EndPos);
        if (EndPos = First + Digits) and TryStrToInt('$' + Copy(Text, First, Digits), Value) then
        begin
          Ch := Char(Value);
          I := EndPos;
        end;
        Builder.Append(Ch);
      end
      else if Decode or CharInSet(Ch, ['A'..'Z', 'a'..'z', '0'..'9', '@', '*', '_', '+', '-', '.', '/']) then
        Builder.Append(Ch)
      else if Ord(Ch) <= $FF then
        Builder.Append('%').Append(IntToHex(Ord(Ch), 2))
      else
        Builder.Append('%u').Append(IntToHex(Ord(Ch), 4));
      if Builder.Length > TextLimit then
        raise EAVM2Error.Create('AVM2 string size limit');
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function TAVM2Runtime.TransformURI(const Input: string; Decode, Component: Boolean): string;
const
  Unescaped: TSysCharSet = ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '!', '~', '*', '''', '(', ')'];
  Reserved: TSysCharSet = [';', ',', '/', '?', ':', '@', '&', '=', '+', '$', '#'];
var
  Encoding: TEncoding;
  Builder: TStringBuilder;
  Data: TBytes;
  I, Count, Size, Value: Integer;
  B: Byte;

  function ReadEscape: Byte;
  begin
    if (I + 2 > Length(Input)) or (Input[I] <> '%') or
      not CharInSet(Input[I + 1], ['0'..'9', 'A'..'F', 'a'..'f']) or
      not CharInSet(Input[I + 2], ['0'..'9', 'A'..'F', 'a'..'f']) or
      not TryStrToInt('$' + Copy(Input, I + 1, 2), Value) then
      RaiseScriptError('URIError', 1052, 'Invalid URI escape sequence.');
    Result := Byte(Value);
    Inc(I, 3);
  end;

begin
  Encoding := TEncoding.UTF8;
  Builder := TStringBuilder.Create;
  try
    try
      if not Decode then
      begin
        Data := Encoding.GetBytes(Input);
        for B in Data do
        begin
          if (AnsiChar(B) in Unescaped) or (not Component and (AnsiChar(B) in Reserved)) then
            Builder.Append(Char(B))
          else
            Builder.Append('%').Append(IntToHex(B, 2));
          if Builder.Length > TextLimit then
            raise EAVM2Error.Create('AVM2 string size limit');
        end;
      end
      else
      begin
        SetLength(Data, 4);
        I := 1;
        while I <= Length(Input) do
          if Input[I] <> '%' then
          begin
            Builder.Append(Input[I]);
            Inc(I);
          end
          else
          begin
            B := ReadEscape;
            if B < $80 then
            begin
              if not Component and (AnsiChar(B) in Reserved) then
                Builder.Append(Copy(Input, I - 3, 3))
              else
                Builder.Append(Char(B));
            end
            else
            begin
              Size := 0;
              if B and $E0 = $C0 then
                Size := 2
              else if B and $F0 = $E0 then
                Size := 3
              else if B and $F8 = $F0 then
                Size := 4
              else
                RaiseScriptError('URIError', 1052, 'Invalid UTF-8 URI escape sequence.');
              Data[0] := B;
              for Count := 1 to Size - 1 do
                Data[Count] := ReadEscape;
              if not Encoding.IsBufferValid(@Data[0], Size) then
                RaiseScriptError('URIError', 1052, 'Invalid UTF-8 URI escape sequence.');
              Builder.Append(Encoding.GetString(Data, 0, Size));
            end;
          end;
      end;
    except
      on E: EEncodingError do
        RaiseScriptError('URIError', 1052, 'Invalid Unicode in URI.');
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function ParseAVM2Integer(const Text: string; Radix: Integer): Double;
var
  I, First, Digit: Integer;
  Negative: Boolean;
  Ch: Char;
begin
  if (Radix <> 0) and ((Radix < 2) or (Radix > 36)) then
    Exit(NaN);
  I := 1;
  while (I <= Length(Text)) and (Text[I].IsWhiteSpace or (Text[I] = #$FEFF)) do
    Inc(I);
  Negative := (I <= Length(Text)) and (Text[I] = '-');
  if (I <= Length(Text)) and CharInSet(Text[I], ['+', '-']) then
    Inc(I);
  if ((Radix = 0) or (Radix = 16)) and (I < Length(Text)) and
    (Text[I] = '0') and CharInSet(Text[I + 1], ['X', 'x']) then
  begin
    Radix := 16;
    Inc(I, 2);
  end;
  if Radix = 0 then
    Radix := 10;
  First := I;
  Result := 0;
  while I <= Length(Text) do
  begin
    Ch := Text[I];
    case Ch of
      '0'..'9':
        Digit := Ord(Ch) - Ord('0');
      'a'..'z':
        Digit := Ord(Ch) - Ord('a') + 10;
      'A'..'Z':
        Digit := Ord(Ch) - Ord('A') + 10;
    else
      Break;
    end;
    if Digit >= Radix then
      Break;
    Result := Result * Radix + Digit;
    Inc(I);
  end;
  if I = First then
    Result := NaN
  else if Negative then
    Result := -Result;
end;

function TAVM2Runtime.Invoke(FunctionObject, Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
begin
  Result := Invoke(FunctionObject, TAVM2Value.Ref(Receiver), Args);
end;

function TAVM2Runtime.Invoke(FunctionObject: TAVM2Object; Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
begin
  if (FunctionObject = nil) or not (FunctionObject.Kind in [a2Function, a2Class]) then
    RaiseScriptError('TypeError', 1006, 'value is not a function.');
  if FunctionObject.Kind = a2Class then
    Exit(InvokeClass(FunctionObject, Args));
  if FunctionObject.Module <> nil then
    Exit(InvokeScript(FunctionObject, Receiver, Args));
  if FunctionObject.BoundReceiver.Kind <> a2Undefined then
    Receiver := FunctionObject.BoundReceiver;
  Result := InvokeNative(FunctionObject, Receiver, Args);
end;

function TAVM2Runtime.InvokeScript(FunctionObject: TAVM2Object; Receiver: TAVM2Value; const Args: array of TAVM2Value): TAVM2Value;
begin
  if FunctionObject.BoundReceiver.Kind <> a2Undefined then
    Receiver := FunctionObject.BoundReceiver;
  if Receiver.Kind in [a2Null, a2Undefined] then
  begin
    if Length(FunctionObject.Scope) > 0 then
      Receiver := FunctionObject.Scope[0]
    else
      Receiver := TAVM2Value.Ref(FunctionObject.Script);
  end;
  Result := Execute(FunctionObject.Module, FunctionObject.Index, Receiver, FunctionObject.Script,
    FunctionObject.ClassObject, FunctionObject.Scope, Args, FunctionObject);
end;

function TAVM2Runtime.InvokeClass(ClassObject: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
begin
  if ClassObject = FObjectClass then
    Exit(Instantiate(ClassObject, Args));
  if (ClassObject = FMatrixClass) or (ClassObject = FTransformClass) or (ClassObject = FVector3DClass) then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1112, 'Incorrect number of arguments for class coercion.');
    Exit(CoerceValue(Args[0], atClass, ClassObject, 'flash.geom.' + ClassObject.DisplayName));
  end;
  if ClassObject = FRectangleClass then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1112, 'Incorrect number of arguments for Rectangle coercion.');
    Exit(CoerceValue(Args[0], atClass, FRectangleClass, 'flash.geom.Rectangle'));
  end;
  if ClassObject = FPointClass then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1112, 'Incorrect number of arguments for Point coercion.');
    Exit(CoerceValue(Args[0], atClass, FPointClass, 'flash.geom.Point'));
  end;
  if ClassObject = FDictionaryClass then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1112, 'Incorrect number of arguments for Dictionary coercion.');
    Exit(CoerceValue(Args[0], atClass, FDictionaryClass, 'flash.utils.Dictionary'));
  end;
  if ClassObject.IsVectorType then
    Exit(ConvertVector(ClassObject, Args));
  if ClassObject.PrimitiveKind in [atString..atUInt] then
    Exit(ConvertPrimitive(ClassObject.PrimitiveKind, Args));
  if (ClassObject = FRegExpClass) and (Length(Args) = 1) and (Args[0].Obj <> nil) and
    (Args[0].Obj.RegExp <> nil) then
    Exit(Args[0]);
  if (ClassObject = FXMLClass) or (ClassObject = FXMLListClass) then
  begin
    if (Length(Args) = 1) and IsXML(Args[0].Obj) then
    begin
      if Args[0].Obj.ClassObject = ClassObject then
        Exit(Args[0]);
      if (ClassObject = FXMLClass) and (Length(Args[0].Obj.XMLNodes) <> 1) then
        RaiseScriptError('TypeError', 1088, 'Cannot convert this XMLList to XML.');
      Exit(XMLValue(Args[0].Obj.XMLDocument, Args[0].Obj.XMLNodes, ClassObject = FXMLListClass));
    end;
    Exit(TAVM2Value.Ref(Construct(ClassObject, Args)));
  end;
  if ClassObject.NativeError or (ClassObject = FArrayClass) or (ClassObject = FFunctionClass) or
    (ClassObject = FRegExpClass) then
    Exit(TAVM2Value.Ref(Construct(ClassObject, Args)));
  if Length(Args) <> 1 then
    RaiseScriptError('ArgumentError', 1112, 'Incorrect number of arguments for class coercion.');
  Exit(CoerceValue(Args[0], atClass, ClassObject, QualifiedClassName(ClassObject)));
end;

function TAVM2Runtime.InvokeNative(FunctionObject: TAVM2Object; const Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  I, Frame: Integer;
  DefinitionName: string;
  DefinitionScript: TAVM2Object;
  FrameValue: Double;
  Routine, ThisObject: TAVM2Object;
  Line, Part: string;
  HasScene: Boolean;
begin
  Result := Default(TAVM2Value);
  ThisObject := Receiver.Obj;
  if (FunctionObject.Index = MouseShowMethod) or (FunctionObject.Index = MouseHideMethod) then
  begin
    FMouseVisible := FunctionObject.Index = MouseShowMethod;
    Exit;
  end;
  if FunctionObject.Index <= BitmapMethodBase then
    Exit(BitmapCall(TAVM2BitmapMethod(BitmapMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= MathMethodBase then
    Exit(MathCall(TAVM2MathMethod(MathMethodBase - FunctionObject.Index), Args));
  if (FunctionObject.Index = ParseIntMethod) or (FunctionObject.Index = ParseFloatMethod) then
  begin
    if Length(Args) = 0 then
      Exit(TAVM2Value.Num(NaN));
    Line := CoerceText(Args[0]);
    if FunctionObject.Index = ParseFloatMethod then
    begin
      Line := TrimLeft(Line);
      if StartsStr('-Infinity', Line) then
        Exit(TAVM2Value.Num(NegInfinity));
      if StartsStr('Infinity', Line) or StartsStr('+Infinity', Line) then
        Exit(TAVM2Value.Num(Infinity));
      Exit(TAVM2Value.Num(AVMParseFloat(Line, False)));
    end;
    I := 0;
    if Length(Args) > 1 then
      I := Integer(IntBits(CoerceNumber(Args[1])));
    Exit(TAVM2Value.Num(ParseAVM2Integer(Line, I)));
  end;
  if FunctionObject.Index = IsFiniteMethod then
  begin
    FrameValue := NaN;
    if Length(Args) > 0 then
      FrameValue := CoerceNumber(Args[0]);
    Exit(TAVM2Value.Num(Ord(not IsNan(FrameValue) and not IsInfinite(FrameValue)), a2Boolean));
  end;
  if (FunctionObject.Index <= EncodeURIMethod) and (FunctionObject.Index >= DecodeURIComponentMethod) then
  begin
    Line := 'undefined';
    if Length(Args) > 0 then
      Line := CoerceText(Args[0]);
    Exit(TAVM2Value.Str(TransformURI(Line, FunctionObject.Index <= DecodeURIMethod,
          (FunctionObject.Index = EncodeURIComponentMethod) or (FunctionObject.Index = DecodeURIComponentMethod))));
  end;
  if (FunctionObject.Index = EscapeMethod) or (FunctionObject.Index = UnescapeMethod) then
  begin
    Line := 'undefined';
    if Length(Args) > 0 then
      Line := CoerceText(Args[0]);
    Exit(TAVM2Value.Str(LegacyEscape(Line, FunctionObject.Index = UnescapeMethod)));
  end;
  if FunctionObject.Index = ExternalCallMethod then
    Exit(TAVM2Value.Ref(nil));
  if FunctionObject.Index = QualifiedNameMethodBase then
  begin
    if (ThisObject = nil) or (ThisObject.ClassObject <> FQNameClass) then
      RaiseScriptError('TypeError', 1004, 'Incompatible QName receiver.');
    DefinitionName := CoerceText(ThisObject.Props[#0 + 'uri']);
    if DefinitionName <> '' then
      DefinitionName := DefinitionName + '::';
    Exit(TAVM2Value.Str(DefinitionName + ThisObject.Props[#0 + 'localName'].Text));
  end;
  if (FunctionObject.Index = QualifiedClassNameMethod) or (FunctionObject.Index = QualifiedSuperclassNameMethod) then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for class reflection.');
    Routine := Args[0].Obj;
    if (Routine <> nil) and (Routine.Kind <> a2Class) then
      Routine := Routine.ClassObject;
    if (Routine = nil) and (Args[0].Kind in [a2Boolean, a2Int, a2UInt, a2Number, a2String]) then
    begin
      case Args[0].Kind of
        a2Boolean:
          Routine := FPrimitiveClasses[atBoolean];
        a2Int:
          Routine := FPrimitiveClasses[atInt];
        a2UInt:
          Routine := FPrimitiveClasses[atUInt];
        a2Number:
          Routine := FPrimitiveClasses[atNumber];
        a2String:
          Routine := FPrimitiveClasses[atString];
      end;
    end;
    if FunctionObject.Index = QualifiedSuperclassNameMethod then
    begin
      if Routine <> nil then
        Routine := Routine.Parent;
      if Routine = nil then
        Exit(TAVM2Value.Ref(nil));
    end;
    if Routine = nil then
    begin
      if Args[0].Kind = a2Undefined then
        Exit(TAVM2Value.Str('void'));
      if Args[0].Kind = a2Null then
        Exit(TAVM2Value.Str('null'));
      if (Args[0].Obj <> nil) and (Args[0].Obj.Kind = a2Function) then
        Exit(TAVM2Value.Str('Function'));
      Exit(TAVM2Value.Str('Object'));
    end;
    DefinitionName := QualifiedClassName(Routine);
    I := LastDelimiter('.', DefinitionName);
    if I > 0 then
      DefinitionName := Copy(DefinitionName, 1, I - 1) + '::' + Copy(DefinitionName, I + 1, MaxInt);
    Exit(TAVM2Value.Str(DefinitionName));
  end;
  if FunctionObject.Index <= DateMethodBase then
    Exit(DateCall(TAVM2DateMethod(DateMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= TextMethodBase then
    Exit(TextCall(TAVM2TextMethod(TextMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= StyleMethodBase then
    Exit(StyleCall(TAVM2StyleMethod(StyleMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= SoundMethodBase then
    Exit(SoundCall(TAVM2SoundMethod(SoundMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= XMLMethodBase then
    Exit(XMLCall(TAVM2XMLMethod(XMLMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= SharedMethodBase then
    Exit(SharedObjectCall(TAVM2SharedMethod(SharedMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= URLMethodBase then
    Exit(URLCall(TAVM2URLMethod(URLMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= ConnectionMethodBase then
    Exit(ConnectionCall(TAVM2ConnectionMethod(ConnectionMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= MatrixMethodBase then
    Exit(MatrixCall(TAVM2MatrixMethod(MatrixMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index = Vector3DTextMethod then
  begin
    if (ThisObject = nil) or not ThisObject.IsVector3D then
      RaiseScriptError('TypeError', 1004, 'Method was invoked on an incompatible object.');
    Exit(TAVM2Value.Str('Vector3D(' + AsText(ThisObject.Props[Vector3DFields[0]]) + ', ' +
        AsText(ThisObject.Props[Vector3DFields[1]]) + ', ' + AsText(ThisObject.Props[Vector3DFields[2]]) + ')'));
  end;
  if FunctionObject.Index <= RectangleMethodBase then
    Exit(RectangleCall(TAVM2RectangleMethod(RectangleMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= PointMethodBase then
    Exit(PointCall(TAVM2PointMethod(PointMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index = DefinitionByNameMethod then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for getDefinitionByName.');
    DefinitionName := StringReplace(CoerceText(Args[0]), '::', '.', []);
    I := LastDelimiter('.', DefinitionName);
    if I = 0 then
      DefinitionName := #0 + DefinitionName
    else
      DefinitionName[I] := #0;
    if FDefinitions.TryGetValue(DefinitionName, DefinitionScript) then
    begin
      Initialize(DefinitionScript);
      Exit(PropertyValue(DefinitionScript, [DefinitionName]));
    end;
    if FNative.Props.TryGetValue(DefinitionName, Result) then
      Exit;
    RaiseScriptError('ReferenceError', 1065, 'Definition ' + CoerceText(Args[0]) + ' is not defined.');
  end;
  if FunctionObject.Index = SecurityLoadPolicyFileMethod then
  begin
    if Length(Args) <> 1 then
      RaiseScriptError('ArgumentError', 1063, 'Wrong argument count for Security.loadPolicyFile.');
    CoerceText(Args[0]);
    // Network access is disabled, so there is no network policy to load.
    Exit;
  end;
  if FunctionObject.Index <= TimerMethodBase then
    Exit(TimerCall(TAVM2TimerMethod(TimerMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index = DictionaryToJSONMethod then
    Exit(TAVM2Value.Str('Dictionary'));
  if FunctionObject.Index <= VectorMethodBase then
    Exit(InvokeVector(TAVM2VectorMethod(VectorMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index <= ObjectMethodBase then
    Exit(InvokeObjectMethod(TAVM2ObjectMethod(ObjectMethodBase - FunctionObject.Index), Receiver, Args));
  if FunctionObject.Index <= RegExpMethodBase then
    Exit(InvokeRegExp(TAVM2RegExpMethod(RegExpMethodBase - FunctionObject.Index), ThisObject, Args));
  if FunctionObject.Index < PrimitiveMethodBase then
    Exit(InvokePrimitive(TAVM2PrimitiveMethod(PrimitiveMethodBase - FunctionObject.Index), Receiver, Args));
  if FunctionObject.Index = EmptyFunctionMethod then
    Exit;
  if (FunctionObject.Index = FunctionCallMethod) or (FunctionObject.Index = FunctionApplyMethod) then
    Exit(ForwardFunction(ThisObject, Args, FunctionObject.Index = FunctionApplyMethod));
  if FunctionObject.Index = IsNaNMethod then
  begin
    FrameValue := NaN;
    if Length(Args) > 0 then
      FrameValue := CoerceNumber(Args[0]);
    Exit(TAVM2Value.Num(Ord(IsNan(FrameValue)), a2Boolean));
  end;
  if FunctionObject.Index = TraceMethod then
  begin
    Line := '';
    for I := 0 to High(Args) do
    begin
      Part := CoerceText(Args[I]);
      if Length(Part) > TextLimit - Length(Line) - Ord(I > 0) then
        raise EAVM2Error.Create('AVM2 trace size limit');
      if I > 0 then
        Line := Line + ' ';
      Line := Line + Part;
    end;
    if Assigned(FTrace) then
      FTrace(AVMStringForTrace(Line));
  end
  else if FunctionObject.Index = ErrorToStringMethod then
  begin
    if ThisObject = nil then
      raise EAVM2Error.Create('AVM2 Error.toString requires a receiver');
    Result := TAVM2Value.Str(AsText(Receiver));
  end
  else if FunctionObject.Index = AddFrameScriptMethod then
  begin
    if (Length(Args) = 0) or Odd(Length(Args)) then
      RaiseScriptError('ArgumentError', 2001, 'Invalid number of arguments for addFrameScript.');
    if (ThisObject = nil) or (ThisObject.DisplayKind <> adMovieClip) then
      Exit;
    I := 0;
    while I < Length(Args) do
    begin
      Frame := Integer(IntBits(CoerceNumber(Args[I])) and $FFFF);
      Routine := Args[I + 1].Obj;
      if Routine = nil then
      begin
        if ThisObject.FrameScripts <> nil then
          ThisObject.FrameScripts.Remove(Frame);
      end
      else
      begin
        if ThisObject.FrameScripts = nil then
          ThisObject.FrameScripts := TDictionary<Integer, TAVM2Object>.Create;
        ThisObject.FrameScripts.AddOrSetValue(Frame, Routine);
        if FDisplay <> nil then
          FDisplay.RequestFrameScript(ThisObject.DisplayData, Frame);
      end;
      Inc(I, 2);
    end;
  end
  else if (FunctionObject.Index = MovieClipPlayMethod) or (FunctionObject.Index = MovieClipStopMethod) then
  begin
    if (FDisplay <> nil) and (ThisObject <> nil) and (ThisObject.DisplayKind = adMovieClip) then
      FDisplay.SetPlaying(ThisObject.DisplayData, FunctionObject.Index = MovieClipPlayMethod);
  end
  else if (FunctionObject.Index = MovieClipGotoAndPlayMethod) or (FunctionObject.Index = MovieClipGotoAndStopMethod) then
  begin
    if (Length(Args) < 1) or (Length(Args) > 2) then
      RaiseScriptError('ArgumentError', 1063, 'MovieClip goto expects one or two arguments.');
    if (FDisplay = nil) or (ThisObject = nil) or (ThisObject.DisplayKind <> adMovieClip) then
      Exit;
    HasScene := (Length(Args) = 2) and not (Args[1].Kind in [a2Undefined, a2Null]);
    Part := '';
    if HasScene then
      Part := CoerceText(Args[1]);
    Line := CoerceText(Args[0]);
    if not FDisplay.GotoFrame(ThisObject.DisplayData, Line, Part, HasScene,
      FunctionObject.Index = MovieClipGotoAndPlayMethod) then
    begin
      if not HasScene then
        Part := Line;
      RaiseScriptError('ArgumentError', 2109, Format('Frame label %s not found in scene %s.', [Line, Part]));
    end;
  end
  else if FunctionObject.Index <= ArrayMethodBase then
    Result := ArrayCall(TAVM2ArrayMethod(ArrayMethodBase - FunctionObject.Index), ThisObject, Args)
  else if FunctionObject.Index <= ByteArrayMethodBase then
    Result := ByteArrayCall(TAVM2ByteMethod(ByteArrayMethodBase - FunctionObject.Index), ThisObject, Args)
  else if FunctionObject.Index <= EventMethodBase then
    Result := EventCall(TAVM2EventMethod(EventMethodBase - FunctionObject.Index), ThisObject, Args)
  else if FunctionObject.Index <= DisplayMethodBase then
    Result := DisplayCall(TAVM2DisplayMethod(DisplayMethodBase - FunctionObject.Index), ThisObject, Args);
end;

// Mark instruction starts before executing any method in this subset. This
// checks bytecode framing and branch destinations. Stack and scope counts are
// still checked at execution time.
function ReadSwitchCaseCount(var Code: TABCReader): Integer;
begin
  Result := Code.U30 + 1;
  if Result > Code.Remaining div 3 then
    raise EAVM2Error.Create('Truncated AVM2 lookupswitch table');
end;

function ReadBoundaries(const Body: TABCBody; HasActivation: Boolean): TBytes;
var
  Code: TABCReader;
  Offset, Op, Operand, Count, I: Integer;
  Handler: TABCException;
  Trait: TABCTrait;
  RequiresReachabilityCheck: Boolean;

  procedure MarkDestination(Target: Integer);
  begin
    if (Target < 0) or (Target >= Length(Result)) then
      RequiresReachabilityCheck := True
    else
      Result[Target] := Result[Target] or BranchDestination;
  end;

  procedure CheckReachableTargets;
  const
    Reachable = 4;
  var
    Pending: TList<Integer>;
    Current, Cursor, Next, Cases, CaseIndex: Integer;
    Opcode: Byte;

    procedure Visit(Target: Integer);
    begin
      if (Target < 0) or (Target >= Length(Result)) then
        raise EAVM2Error.Create('AVM2 branch target is outside the method');
      if Result[Target] and InstructionStart = 0 then
        raise EAVM2Error.Create('AVM2 branch target is not an instruction boundary');
      if Result[Target] and Reachable = 0 then
      begin
        Result[Target] := Result[Target] or Reachable;
        Pending.Add(Target);
      end;
    end;

  begin
    // A compiler can leave branches in unreachable code. Validate every
    // destination of a reachable branch, including unselected switch cases.
    Pending := TList<Integer>.Create;
    try
      Visit(0);
      for var Entry in Body.Exceptions do
        Visit(Entry.Target);
      Cursor := 0;
      while Cursor < Pending.Count do
      begin
        Current := Pending[Cursor];
        Inc(Cursor);
        Opcode := Body.Code[Current];
        if (Opcode >= $0C) and (Opcode <= $1A) then
        begin
          Code.Position := Current + 1;
          var Delta := Code.S24;
          Visit(Code.Position + Delta);
        end
        else if Opcode = $1B then
        begin
          Code.Position := Current + 1;
          Visit(Current + Code.S24);
          Cases := ReadSwitchCaseCount(Code);
          for CaseIndex := 1 to Cases do
            Visit(Current + Code.S24);
        end;
        if Opcode in [$03, $10, $1B, $47, $48] then
          Continue;
        Next := Current + 1;
        while (Next < Length(Result)) and (Result[Next] and InstructionStart = 0) do
          Inc(Next);
        if Next < Length(Result) then
          Visit(Next);
      end;
    finally
      Pending.Free;
    end;
  end;

begin
  Code := Default(TABCReader);
  Code.Data := Body.Code;
  RequiresReachabilityCheck := False;
  SetLength(Result, Length(Body.Code));
  if HasActivation then
    for Trait in Body.Traits do
      if not (Trait.Kind in [0, 6]) then
        raise EAVM2Error.Create('Invalid AVM2 activation trait');
  while Code.Remaining > 0 do
  begin
    Offset := Code.Position;
    Result[Offset] := Result[Offset] or InstructionStart;
    Op := Code.U8;
    case Op of
      $02, $03, $09, $1C..$21, $23, $26..$2B, $30, $47, $48, $64, $70, $73..$76, $77, $81..$85, $87..$89, $90, $91, $93, $95, $96, $97, $A0..$B1, $B3, $B4, $C0, $C1, $C5..$C7, $D0..$D7:
        ;
      $04, $05, $08, $2C..$2F, $31, $40..$42, $49, $53, $55, $56, $58, $5D..$63, $66, $67, $68, $6A, $6C..$6F, $80, $86, $92, $94, $B2, $C2, $C3, $F0, $F1:
        Code.U30;
      $25:
        Code.U32; // Some compilers sign-extend negative short immediates.
        $24, $65:
        Code.U8;
      $57:
        if not HasActivation then
          raise EAVM2Error.Create('AVM2 newactivation requires NEED_ACTIVATION');
      $5A:
        if Code.U30 >= Length(Body.Exceptions) then
          raise EAVM2Error.Create('AVM2 newcatch index outside exception table');
      $32, $45, $46, $4A, $4C, $4E, $4F:
        begin
          Code.U30;
          Code.U30;
        end;
      $0C..$1A:
        begin
          Operand := Code.S24;
          MarkDestination(Code.Position + Operand);
        end;
      $1B:
        begin
          MarkDestination(Offset + Code.S24);
          Count := ReadSwitchCaseCount(Code);
          for I := 1 to Count do
            MarkDestination(Offset + Code.S24);
        end;
      $EF:
        begin
          Code.U8;
          Code.U30;
          Code.U8;
          Code.U30;
        end;
    else
      raise EAVM2Error.CreateFmt('AVM2 opcode $%.2x at byte %d is not implemented', [Op, Offset]);
    end;
  end;
  for Handler in Body.Exceptions do
    if (Body.StackLimit = 0) or (Handler.First >= Length(Result)) or
      (Result[Handler.First] and InstructionStart = 0) or
      ((Handler.Last < Length(Result)) and (Result[Handler.Last] and InstructionStart = 0)) or
      (Result[Handler.Target] and InstructionStart = 0) then
      raise EAVM2Error.Create('AVM2 exception range or target is invalid');
  if not RequiresReachabilityCheck then
    for I := 0 to High(Result) do
      if Result[I] = BranchDestination then
      begin
        RequiresReachabilityCheck := True;
        Break;
      end;
  if RequiresReachabilityCheck then
    CheckReachableTargets;
end;

procedure DecodeNumericMethod(Module: TAVM2Module; BodyIndex: Integer; var Budget: Integer);
const
  MaxMethodBytes = 8192;
  MaxInstructions = 48;
  MaxRegisters = 32;
var
  Body: ^TABCBody;
  ProgramCode: ^TAVM2NumericMethod;
  Boundaries: TBytes;
  Reader: TABCReader;
  Instructions: TList<TAVM2NumericInstruction>;
  Regions: TList<TAVM2NumericRegion>;
  Region: TAVM2NumericRegion;
  Instruction, Previous: TAVM2NumericInstruction;
  Offset, Next, Count, Depth, Operand, Op, Peak, Bytes: Integer;
  Arithmetic: Boolean;

  function ReadInstruction: Boolean;
  begin
    Result := False;
    Instruction := Default(TAVM2NumericInstruction);
    Op := Reader.U8;
    case Op of
      $62, $D0..$D3:
        begin
          if Op = $62 then
            Operand := Reader.U30
          else
            Operand := Op and 3;
          if Operand >= Body.LocalCount then
            Exit;
          Instruction.Kind := anLoadLocal;
          Instruction.Operand := Operand;
        end;
      $66:
        begin
          Operand := Reader.U30;
          if (Depth = 0) or (Operand = 0) or (Operand >= Length(Module.ABC.Multinames)) or
            not (Module.ABC.Multinames[Operand].Kind in [$07, $09, $0D, $0E]) then
            Exit;
          Instruction.Kind := anLoadField;
          Instruction.Target := Depth - 1;
          Instruction.Operand := Operand;
          Exit(True);
        end;
      $24, $25, $2D:
        begin
          Instruction.Kind := anInt;
          case Op of
            $24:
              Instruction.Number := ShortInt(Reader.U8);
            $25:
              Instruction.Number := SmallInt(Reader.U32 and $FFFF);
            $2D:
              begin
                Operand := Reader.U30;
                if Operand >= Length(Module.ABC.Ints) then
                  Exit;
                Instruction.Number := Module.ABC.Ints[Operand];
              end;
          end;
        end;
      $2E:
        begin
          Operand := Reader.U30;
          if Operand >= Length(Module.ABC.UInts) then
            Exit;
          Instruction.Kind := anUInt;
          Instruction.Number := Module.ABC.UInts[Operand];
        end;
      $28, $2F:
        begin
          Instruction.Kind := anNumber;
          Instruction.Number := NaN;
          if Op = $2F then
          begin
            Operand := Reader.U30;
            if Operand >= Length(Module.ABC.Doubles) then
              Exit;
            if Operand <> 0 then
              Instruction.Number := Module.ABC.Doubles[Operand];
          end;
        end;
      $26, $27:
        begin
          Instruction.Kind := anBoolean;
          Instruction.Number := Ord(Op = $26);
        end;
      $75, $84, $90:
        begin
          if Depth = 0 then
            Exit;
          if Op = $90 then
          begin
            Instruction.Kind := anNegate;
            Arithmetic := True;
          end
          else
            Instruction.Kind := anConvert;
          Instruction.Target := Depth - 1;
          Exit(True);
        end;
      $A0..$A3:
        begin
          if Depth < 2 then
            Exit;
          Dec(Depth);
          Instruction.Kind := TAVM2NumericOp(Ord(anAdd) + Op - $A0);
          Instruction.Target := Depth - 1;
          Instruction.Source := Depth;
          Arithmetic := True;
          Exit(True);
        end;
    else
      Exit;
    end;
    if Depth >= MaxRegisters then
      Exit;
    Instruction.Target := Depth;
    Inc(Depth);
    if Depth > Peak then
      Peak := Depth;
    Result := True;
  end;

begin
  Body := @Module.ABC.Bodies[BodyIndex];
  if (Length(Body.Code) > MaxMethodBytes) or (Budget <= 0) then
    Exit;
  ProgramCode := @Module.NumericMethods[BodyIndex];
  Boundaries := Module.Boundaries[BodyIndex];
  Reader := Default(TABCReader);
  Reader.Data := Body.Code;
  Instructions := TList<TAVM2NumericInstruction>.Create;
  Regions := TList<TAVM2NumericRegion>.Create;
  try
    Offset := 0;
    while Offset < Length(Body.Code) do
    begin
      Count := 0;
      Depth := 0;
      Peak := 0;
      Arithmetic := False;
      Reader.Position := Offset;
      Region := Default(TAVM2NumericRegion);
      Region.First := Instructions.Count;
      Region.StoreLocal := -1;
      Region.StoreField := 0;
      Region.StoreRegister := 0;
      Next := Offset;
      while (Reader.Position < Length(Body.Code)) and (Count < MaxInstructions) do
      begin
        if (Count > 0) and (Boundaries[Reader.Position] and BranchDestination <> 0) then
          Break;
        if not ReadInstruction then
          Break;
        // Numeric operations and double constants already leave a Number.
        // Keep charging the original conversion, including when it is coalesced.
        if (Instruction.Kind <> anConvert) or (Count = 0) or (Previous.Target <> Instruction.Target) or
          not (Previous.Kind in [anNumber, anConvert, anNegate, anAdd, anSubtract, anMultiply, anDivide]) then
          Instructions.Add(Instruction);
        Previous := Instruction;
        Next := Reader.Position;
        Inc(Count);
      end;
      if (Count >= 4) and Arithmetic then
      begin
        // Only the final store can mutate VM state. Until then, falling back
        // leaves the bytecode cursor, operand stack, locals and budget intact.
        if (Depth > 0) and (Next < Length(Body.Code)) and
          (Boundaries[Next] and BranchDestination = 0) then
        begin
          Reader.Position := Next;
          Op := Reader.U8;
          Operand := -1;
          if Op = $63 then
            Operand := Reader.U30
          else if Op in [$D4..$D7] then
            Operand := Op and 3;
          if (Operand >= 0) and (Operand < Body.LocalCount) then
          begin
            Dec(Depth);
            Region.StoreLocal := Operand;
            Region.StoreRegister := Depth;
            Next := Reader.Position;
          end
          else if (Depth >= 2) and (Op in [$61, $68]) then
          begin
            Operand := Reader.U30;
            if (Operand > 0) and (Operand < Length(Module.ABC.Multinames)) and
              (Module.ABC.Multinames[Operand].Kind in [$07, $09, $0D, $0E]) then
            begin
              Region.StoreRegister := Depth - 1;
              Region.StoreField := Operand;
              Dec(Depth, 2);
              Next := Reader.Position;
            end;
          end;
        end;
        if ProgramCode.Offsets = nil then
          SetLength(ProgramCode.Offsets, Length(Body.Code));
        Region.Limit := Instructions.Count;
        Region.Next := Next;
        Region.Peak := Peak;
        Region.OutputCount := Depth;
        Region.Work := Count + Ord((Region.StoreLocal >= 0) or (Region.StoreField <> 0));
        ProgramCode.Offsets[Offset] := Regions.Count + 1;
        Regions.Add(Region);
        Offset := Next;
      end
      else
      begin
        Instructions.Count := Region.First;
        repeat
          Inc(Offset);
        until (Offset >= Length(Boundaries)) or (Boundaries[Offset] and InstructionStart <> 0);
      end;
    end;
    if Regions.Count <> 0 then
    begin
      Bytes := Length(Body.Code) + Length(ProgramCode.Offsets) * SizeOf(Word) +
        Regions.Count * SizeOf(TAVM2NumericRegion) + Instructions.Count * SizeOf(TAVM2NumericInstruction);
      if Bytes <= Budget then
      begin
        Dec(Budget, Bytes);
        ProgramCode.Regions := Regions.ToArray;
        ProgramCode.Code := Instructions.ToArray;
        // Keep all instruction offsets and branch operands identical to ABC.
        // Only entries of compiled regions change in this private stream.
        ProgramCode.EncodedCode := Copy(Body.Code);
        for Offset := 0 to High(ProgramCode.Offsets) do
          if ProgramCode.Offsets[Offset] <> 0 then
            ProgramCode.EncodedCode[Offset] := NumericRegionOpcode;
      end
      else
        ProgramCode.Offsets := nil;
    end;
  finally
    Regions.Free;
    Instructions.Free;
  end;
end;

{$IFDEF AVM2_WIN64_JIT}
procedure CompileNumericRegion(var Region: TAVM2NumericRegion; const Code: TArray<TAVM2NumericInstruction>; const Samples: TArray<TAVM2NumericSample>);
var
  J: TJitAsm;
  Entry: Pointer;
  Bail: TJitLabel;
  Kinds: array[0..31] of TAVM2ValueKind;
  Value: TAVM2Value;
  RegisterValue: TAVM2Runtime.TNumericRegister;
  Pair: TPair<string, TAVM2Value>;
  ValueKindOffset, ValueNumberOffset, ValueObjectOffset, PairValueOffset: Integer;
  RegisterKindOffset, RegisterNumberOffset, RegisterObjectOffset: Integer;
  ObjectKindWidth, ValueKindWidth: TJitWidth;
  Index, RegisterIndex: Integer;
  Instr: ^TAVM2NumericInstruction;
  Sample: ^TAVM2NumericSample;

  function Cell(RegisterIndex, Field: Integer): TJitOp;
  begin
    Result := JMem(jrCtx, RegisterIndex * SizeOf(RegisterValue) + Field);
  end;

  procedure LoadValue(Base: TJitReg; Offset: Integer; CheckMethod: Boolean);
  begin
    J.Branch(jcNe, ValueKindWidth, JMem(Base, Offset + ValueKindOffset), JImm(Ord(Sample.Kind)), Bail);
    if Sample.Kind = a2Object then
    begin
      J.Move(jw64, JT0, JMem(Base, Offset + ValueObjectOffset));
      if CheckMethod then
      begin
        J.Branch(jcEq, jw64, JT0, JImm(0), Bail);
        J.Branch(jcEq, ObjectKindWidth, JMem(jrT0, NativeInt(@TAVM2Object(nil).Kind)),
          JImm(Ord(a2Function)), Bail);
      end;
      J.Move(jw64, Cell(Instr.Target, RegisterObjectOffset), JT0);
    end;
    J.Move(jw64, JT0, JMem(Base, Offset + ValueNumberOffset));
    J.Move(jw64, Cell(Instr.Target, RegisterNumberOffset), JT0);
    Kinds[Instr.Target] := Sample.Kind;
  end;

  procedure FinishRegister(RegisterIndex: Integer);
  begin
    J.Move(ValueKindWidth, Cell(RegisterIndex, RegisterKindOffset), JImm(Ord(Kinds[RegisterIndex])));
    if Kinds[RegisterIndex] <> a2Object then
      J.Move(jw64, Cell(RegisterIndex, RegisterObjectOffset), JImm(0));
  end;

begin
  // All writes in generated code target scratch cells. The interpreter
  // commits the final VM stores only after these guards have succeeded.
  ValueKindOffset := NativeInt(@Value.Kind) - NativeInt(@Value);
  ValueNumberOffset := NativeInt(@Value.Number) - NativeInt(@Value);
  ValueObjectOffset := NativeInt(@Value.Obj) - NativeInt(@Value);
  PairValueOffset := NativeInt(@Pair.Value) - NativeInt(@Pair);
  RegisterKindOffset := NativeInt(@RegisterValue.Kind) - NativeInt(@RegisterValue);
  RegisterNumberOffset := NativeInt(@RegisterValue.Number) - NativeInt(@RegisterValue);
  RegisterObjectOffset := NativeInt(@RegisterValue.Obj) - NativeInt(@RegisterValue);
  ValueKindWidth := jw8;
  if SizeOf(TAVM2ValueKind) <> 1 then
    ValueKindWidth := jw32;
  ObjectKindWidth := jw8;
  if SizeOf(TAVM2ObjectKind) <> 1 then
    ObjectKindWidth := jw32;

  J := CreateJitSealableAsm(NumericJitBufferBytes);
  if J = nil then
    Exit;
  try
    Entry := J.Here;
    J.Enter;
    Bail := J.NewLabel;
    for Index := 0 to High(Samples) do
    begin
      Instr := @Code[Region.First + Index];
      Sample := @Samples[Index];
      case Instr.Kind of
        anLoadLocal:
          LoadValue(jrSelf, Instr.Operand * SizeOf(TAVM2Value), False);
        anLoadField:
          begin
            // The declared prefix may be invalidated by removal. Resolve the
            // current storage only after checking its layout and bounds.
            J.Move(jw64, JT1, Cell(Instr.Target, RegisterObjectOffset));
            J.Branch(jcEq, jw64, JT1, JImm(0), Bail);
            J.Move(jw64, JT0, JImm(NativeInt(Sample.Layout)));
            J.Branch(jcNe, jw64, JMem(jrT1, NativeInt(@TAVM2Object(nil).DeclaredSlots)), JT0, Bail);
            J.Move(jw64, JT1, JMem(jrT1, NativeInt(@TAVM2Object(nil).Props)));
            J.Branch(jcLe, jw32, JMem(jrT1, NativeInt(@TAVM2Properties(nil).FDeclaredCount)),
              JImm(Sample.SlotIndex), Bail);
            J.Move(jw64, JT1, JMem(jrT1, NativeInt(@TAVM2Properties(nil).FEntries)));
            LoadValue(jrT1, Sample.SlotIndex * SizeOf(Pair) + PairValueOffset, True);
          end;
        anInt, anUInt, anNumber, anBoolean:
          begin
            case Instr.Kind of
              anInt:
                Kinds[Instr.Target] := a2Int;
              anUInt:
                Kinds[Instr.Target] := a2UInt;
              anNumber:
                Kinds[Instr.Target] := a2Number;
              anBoolean:
                Kinds[Instr.Target] := a2Boolean;
            end;
            J.Move(jw64, JT0, JImm(PInt64(@Instr.Number)^));
            J.Move(jw64, Cell(Instr.Target, RegisterNumberOffset), JT0);
          end;
        anConvert:
          Kinds[Instr.Target] := a2Number;
        anNegate:
          begin
            J.Move(jw64, JT0, JImm(Low(Int64)));
            J.Alu(jaXor, jw64, Cell(Instr.Target, RegisterNumberOffset), JT0);
            Kinds[Instr.Target] := a2Number;
          end;
        anAdd, anSubtract, anMultiply, anDivide:
          begin
            J.AluDouble(TJitDoubleAlu(Ord(Instr.Kind) - Ord(anAdd)),
              Cell(Instr.Target, RegisterNumberOffset), Cell(Instr.Source, RegisterNumberOffset));
            Kinds[Instr.Target] := a2Number;
          end;
      end;
    end;
    for RegisterIndex := 0 to Region.OutputCount - 1 do
      FinishRegister(RegisterIndex);
    if (Region.StoreLocal >= 0) or (Region.StoreField <> 0) then
      FinishRegister(Region.StoreRegister);
    J.Leave(JImm(1));
    J.Bind(Bail);
    J.Leave(JImm(0));
    J.Publish;
    Region.NativeEntry := Entry;
    Region.NativeCode := J;
    J := nil;
  finally
    J.Free;
  end;
end;
{$ENDIF}

function TAVM2Runtime.Execute(Module: TAVM2Module; MethodIndex: Integer; const Receiver: TAVM2Value; Script, OwnerClass: TAVM2Object; const Outer: TArray<TAVM2Value>; const Args: array of TAVM2Value; CurrentFunction: TAVM2Object): TAVM2Value;
type
  TFrameCells = array[0..4095] of TAVM2Value;

  PFrameCells = ^TFrameCells;
var
  Body: ^TABCBody;
  Method: ^TABCMethod;
  Code: TABCReader;
  Stack, Locals, Scopes: PFrameCells;
  Parameters, Captured: TArray<TAVM2Value>;
  NamesToTry: TArray<string>;
  StackTop, ScopeTop, Op, Offset, N, I, Target: Integer;
  EnumIndex, ElementIndex, LeftBits, RightBits: Cardinal;
  A, B: TAVM2Value;
  Obj, Callable, DictionaryKey: TAVM2Object;
  DictionaryEntry: TAVM2DictionaryEntry;
  L, R: Double;
  Name: string;
  Branch: Boolean;
  Relation: TAVM2Relation;
  TypeKind: TAVM2TypeKind;
  TargetClass: TAVM2Object;
  TypeName: string;
  PreviousMask: TArithmeticExceptionMask;
  Handler: TABCException;
  Scratch: ^TExecutionScratch;
  NumericMethod: ^TAVM2NumericMethod;
  OwnField, FoundLexical: PAVM2Value;
  SlotLayout: TAVM2SlotLayout;
  SlotNames: TDictionary<Integer, string>;
  StackLimit, LocalLimit, ScopeLimit, CodeLength: Integer;

  procedure Push(const Value: TAVM2Value);
  begin
    if StackTop >= StackLimit then
      raise EAVM2Error.Create('AVM2 operand stack overflow');
    CopyValue(Value, Stack[StackTop]);
    Inc(StackTop);
  end;

  procedure PushNumber(Value: Double; Kind: TAVM2ValueKind = a2Number);
  begin
    if StackTop >= StackLimit then
      raise EAVM2Error.Create('AVM2 operand stack overflow');
    // A popped slot releases its managed value before it can be reused.
    Stack[StackTop].Kind := Kind;
    Stack[StackTop].Number := Value;
    Stack[StackTop].Obj := nil;
    Inc(StackTop);
  end;

  function Pop: TAVM2Value;
  begin
    if StackTop = 0 then
      raise EAVM2Error.Create('AVM2 operand stack underflow');
    Dec(StackTop);
    CopyValue(Stack[StackTop], Result);
    if Stack[StackTop].Text <> '' then
      Stack[StackTop].Text := '';
  end;

  function AsObject(const Value: TAVM2Value): TAVM2Object;
  begin
    if (Value.Kind <> a2Object) or (Value.Obj = nil) then
      raise EAVM2Error.Create('AVM2 receiver is not an object');
    Result := Value.Obj;
  end;

  procedure CheckNullReceiver(const Value: TAVM2Value; FieldIndex: Integer = 0; const RuntimeName: string = '');
  var
    ErrorCode: Integer;
    Field: TABCMultiname;
    Detail, FieldName, PackageName: string;
  begin
    if Value.Kind in [a2Null, a2Undefined] then
    begin
      if Value.Kind = a2Null then
      begin
        ErrorCode := 1009;
        Detail := 'Cannot access a property or method of a null object reference.';
      end
      else
      begin
        ErrorCode := 1010;
        Detail := 'A term is undefined and has no properties.';
      end;
      if FieldIndex <> 0 then
      begin
        Field := Module.ABC.Multinames[FieldIndex];
        if Field.Kind = $1B then
          FieldName := RuntimeName
        else
          FieldName := Module.ABC.Strings[Field.Name];
        if (Field.Kind = 7) and (Field.NamespaceIndex <> 0) then
        begin
          PackageName := Module.ABC.Strings[Module.ABC.Namespaces[Field.NamespaceIndex].Name];
          if PackageName <> '' then
            FieldName := PackageName + '::' + FieldName;
        end;
        Detail := Detail + ' (accessing field: ' + FieldName + ')';
      end;
      RaiseScriptError('TypeError', ErrorCode, Detail);
    end;
  end;

  function ObjectReceiver(const Value: TAVM2Value; FieldIndex: Integer = 0; const RuntimeName: string = ''): TAVM2Object;
  begin
    CheckNullReceiver(Value, FieldIndex, RuntimeName);
    Result := AsObject(Value);
  end;

  function EnumerationObject(const Value: TAVM2Value): TAVM2Object;
  begin
    if Value.Kind = a2Object then
      Result := Value.Obj
    else
      Result := ValuePrototype(Value);
  end;

  function IndexedNames(NamespaceSet, Index: Integer; out RuntimeName: string): TArray<string>;
  var
    Entry: ^TAVM2IndexedNames;
    TextLength: Integer;
  begin
    Entry := @FIndexedNames[((NamespaceSet * 33) xor Index xor
      (Module.Id and High(FIndexedNames))) and High(FIndexedNames)];
    if (Entry.Module = Module) and (Entry.NamespaceSet = NamespaceSet) and (Entry.Index = Index) then
    begin
      RuntimeName := Entry.Name;
      Exit(Entry.Keys);
    end;
    RuntimeName := IntToStr(Index);
    // Preserve every candidate and its position in the original namespace set.
    Result := NamespaceSetKeys(Module, NamespaceSet, RuntimeName);
    if Length(Result) > 32 then
      Exit;
    TextLength := 0;
    for var Key in Result do
    begin
      Inc(TextLength, Length(Key));
      if TextLength > 1024 then
        Exit;
    end;
    Entry.Module := Module;
    Entry.NamespaceSet := NamespaceSet;
    Entry.Index := Index;
    Entry.Name := RuntimeName;
    Entry.Keys := Result;
  end;

  function NativeIndexedReceiver(NameIndex, ReceiverSlot: Integer; out Element: Cardinal): TAVM2Object;
  var
    Receiver: TAVM2Object;
    KeyValue: PAVM2Value;
    SetIndex: Integer;
    State: PByte;
    Namespace: TABCNamespace;
  begin
    Result := nil;
    if ReceiverSlot < 0 then
      Exit;
    Receiver := Stack[ReceiverSlot].Obj;
    // An own numeric name in an earlier namespace can override the index.
    // Shared trait layouts and other special receivers use normal resolution.
    if (Receiver = nil) or (Receiver.ClassObject = nil) or
      ((Receiver.ClassObject <> FArrayClass) and not Receiver.ClassObject.IsVectorType) or
      ((Receiver.ArrayData = nil) and (Receiver.VectorData = nil)) or
      (Receiver.DisplayKind <> adNone) or (Receiver.DisplayData <> nil) or
      (Receiver.Accessors <> nil) or (Receiver.TimelineBindings <> nil) or
      (Receiver.DeclaredSlots <> nil) or Receiver.Props.FMayHaveNumericNames then
      Exit;
    KeyValue := @Stack[ReceiverSlot + 1];
    if not (KeyValue.Kind in [a2Int, a2UInt, a2Number]) or
      not ((KeyValue.Number >= 0) and (KeyValue.Number <= High(Integer))) then
      Exit;
    Element := Cardinal(Trunc(KeyValue.Number));
    if KeyValue.Number <> Element then
      Exit;
    SetIndex := Module.ABC.Multinames[NameIndex].NamespaceSet;
    State := @Module.PublicIndexSets[SetIndex];
    if State^ = 0 then
    begin
      State^ := 1;
      for var NamespaceIndex in Module.ABC.NamespaceSets[SetIndex] do
      begin
        Namespace := Module.ABC.Namespaces[NamespaceIndex];
        if (Namespace.Kind in [0, 8, $16]) and (Module.ABC.Strings[Namespace.Name] = '') then
        begin
          State^ := 2;
          Break;
        end;
      end;
    end;
    if State^ = 2 then
      Result := Receiver;
  end;

  function TryReadNativeIndex(Receiver: TAVM2Object; Index: Cardinal; out Value: TAVM2Value): Boolean;
  begin
    if Receiver.VectorData <> nil then
    begin
      if Index >= Cardinal(Receiver.VectorData.Count) then
        Exit(False);
      Value := Receiver.VectorData[Integer(Index)];
    end
    else if not TryArrayElement(Receiver.ArrayData, Index, Value) then
      Exit(False);
    Result := (Value.Kind <> a2Undefined) and ((Value.Obj = nil) or (Value.Obj.Kind <> a2Function));
  end;

  function PropertyNames(Index: Integer; out RuntimeName: string; IdentityNames: Boolean = False): TArray<string>;
  var
    Field: TABCMultiname;
    KeyValue: TAVM2Value;
    TargetObject: TAVM2Object;
    NumericIndex: Integer;
  begin
    if (Index <= 0) or (Index >= Length(Module.ABC.Multinames)) then
      raise EAVM2Error.Create('AVM2 multiname index outside pool');
    RuntimeName := '';
    DictionaryKey := nil;
    Result := Module.StaticNames[Index];
    if Result <> nil then
      Exit;
    Field := Module.ABC.Multinames[Index];
    if not (Field.Kind in [$1B, $1C]) then
      Exit(Names(Module, Index));
    KeyValue := Pop;
    if IdentityNames and (KeyValue.Obj <> nil) and (StackTop > 0) then
    begin
      TargetObject := Stack[StackTop - 1].Obj;
      if (TargetObject <> nil) and (TargetObject.DictionaryKeys <> nil) then
      begin
        DictionaryKey := KeyValue.Obj;
        Exit(nil);
      end;
    end;
    if (Field.Kind = $1B) and (KeyValue.Kind in [a2Int, a2UInt, a2Number]) and
      (KeyValue.Number >= 0) and (KeyValue.Number < 512) then
    begin
      NumericIndex := Trunc(KeyValue.Number);
      if KeyValue.Number = NumericIndex then
        Exit(IndexedNames(Field.NamespaceSet, NumericIndex, RuntimeName));
    end;
    RuntimeName := CoerceText(KeyValue);
    if Field.Kind = $1C then
      RuntimeName := '@' + RuntimeName;
    Result := NamespaceSetKeys(Module, Field.NamespaceSet, RuntimeName);
  end;

  function CanAccessOwn(Obj: TAVM2Object; const Keys: TArray<string>): Boolean;
  begin
    Result := (Obj <> nil) and (Obj.Kind = a2PlainObject) and (Obj.ClassObject <> nil) and
      Obj.ClassObject.HasPlainInstances and (Obj.DisplayKind = adNone) and
      (Obj.Accessors = nil) and (Length(Keys) = 1) and
      ((Keys[0][1] <> '#') or not StartsStr('#24:', Keys[0]));
  end;

  function FindDeclaredField(Obj: TAVM2Object; NameIndex: Integer; RequiredFlag: Byte): PAVM2Value;
  var
    Keys: ^TArray<string>;
    Layout: TAVM2SlotLayout;
    Binding: ^TAVM2FieldBinding;
    Index: Integer;
  begin
    Result := nil;
    if (Obj = nil) or (Obj.DeclaredSlots = nil) or (Obj.Props.FDeclaredCount = 0) then
      Exit;
    Layout := Obj.DeclaredSlots;
    Binding := @Module.FieldBindings[NameIndex and (FieldBindingCacheSize - 1)];
    if (Binding.Layout = Layout) and (Binding.NameIndex = NameIndex) then
      Index := Binding.Offset
    else
    begin
      Keys := @Module.StaticNames[NameIndex];
      if Keys^ = nil then
        Exit;
      // A declared field matching the first name wins over later namespaces.
      Index := -1;
      if not Obj.Props.FindIndex(Keys^[0], Index) or (Index >= Obj.Props.FDeclaredCount) or
        (Layout.Flags[Index] = 0) then
        Index := -1;
      Binding.Layout := Layout;
      Binding.NameIndex := NameIndex;
      Binding.Offset := Index;
    end;
    if (Index >= 0) and (Layout.Flags[Index] and RequiredFlag <> 0) then
      Result := @Obj.Props.FEntries[Index].Value;
  end;

  function DeclaredScopeLayout(Obj: TAVM2Object): TAVM2SlotLayout;
  begin
    Result := nil;
    if (Obj <> nil) and (Obj.Kind = a2PlainObject) and (Obj.DeclaredSlots <> nil) and
      (Obj.Props.FDeclaredIndices <> nil) and (Obj.Props.FCount = Obj.Props.FDeclaredCount) and
      (Obj.Props.FDeclaredIndices = Obj.DeclaredSlots.PropertyIndices) then
      Result := Obj.DeclaredSlots;
  end;

  function ReadCapturedField(NameIndex: Integer): PAVM2Value;
  var
    Binding: ^TAVM2CapturedBinding;
    Owner: TAVM2Object;
  begin
    Result := nil;
    if (Module.CapturedBindings = nil) or (ScopeTop <> 1) or (Outer = nil) then
      Exit;
    // A shared declared prefix proves that the active scope has no new shadowing field.
    Binding := @Module.CapturedBindings[NameIndex and (FieldBindingCacheSize - 1)];
    if (Binding.NameIndex <> NameIndex) or (Binding.Layout = nil) or
      (DeclaredScopeLayout(Scopes[0].Obj) <> Binding.Layout) then
      Exit;
    Owner := Outer[High(Outer)].Obj;
    if (Owner <> Binding.Owner) or (Owner.Accessors <> nil) or
      (Binding.Offset >= Owner.Props.FCount) or
      (Owner.Props.FEntries[Binding.Offset].Key <> Module.StaticNames[NameIndex][0]) then
      Exit;
    Result := @Owner.Props.FEntries[Binding.Offset].Value;
    if (Result.Kind = a2Undefined) or ((Result.Obj <> nil) and (Result.Obj.Kind = a2Function)) then
      Result := nil;
  end;

  procedure RememberCapturedField(NameIndex: Integer; Owner: TAVM2Object; Value: PAVM2Value);
  var
    Binding: ^TAVM2CapturedBinding;
    Layout: TAVM2SlotLayout;
  begin
    if (ScopeTop <> 1) or (Outer = nil) or (Outer[High(Outer)].Obj <> Owner) or
      (Scopes[0].Obj = Owner) then
      Exit;
    Layout := DeclaredScopeLayout(Scopes[0].Obj);
    if Layout = nil then
      Exit;
    if Module.CapturedBindings = nil then
      SetLength(Module.CapturedBindings, Length(Module.FieldBindings));
    Binding := @Module.CapturedBindings[NameIndex and (FieldBindingCacheSize - 1)];
    Binding.Layout := Layout;
    Binding.Owner := Owner;
    Binding.NameIndex := NameIndex;
    Binding.Offset := (NativeInt(Value) - NativeInt(@Owner.Props.FEntries[0].Value)) div
      SizeOf(Owner.Props.FEntries[0]);
  end;

  function FindStaticOwnField(Obj: TAVM2Object; NameIndex: Integer; const Keys: TArray<string>; FoundValue: PAVM2Value = nil): PAVM2Value;
  var
    Key: string;
  begin
    Result := nil;
    if (Obj = nil) or not (Obj.Kind in [a2Script, a2Class]) or (Obj.Accessors <> nil) or (Keys = nil) then
      Exit;
    Key := Keys[0];
    // Protected names can be rebound to the declaring class. Public
    // synthetic properties also need the full resolver.
    if (Key = '') or ((Key[1] = '#') and StartsStr('#24:', Key)) or
      ((Key[1] = #0) and ((Key = #0 + 'prototype') or (Key = #0 + 'loaderInfo') or (Key = #0 + 'length'))) then
      Exit;
    Result := FoundValue;
    if Result = nil then
      Result := Obj.Props.FindHinted(Key, Module.PropertyHints[NameIndex]);
    if (Result <> nil) and (Result.Kind = a2Undefined) then
      Result := nil;
  end;

  function FindOwnField(Obj: TAVM2Object; NameIndex: Integer; const Keys: TArray<string>): PAVM2Value;
  begin
    Result := FindDeclaredField(Obj, NameIndex, SlotReadable);
    if Result = nil then
      Result := FindStaticOwnField(Obj, NameIndex, Keys);
    if (Result = nil) and CanAccessOwn(Obj, Keys) then
      Result := Obj.Props.FindHinted(Keys[0], Module.PropertyHints[NameIndex]);
    if (Result <> nil) and (Result.Obj <> nil) and (Result.Obj.Kind = a2Function) then
      Result := nil;
  end;

  procedure LoadLocal(Index: Integer);
  var
    Operand, Position: Integer;
    Value, Field: PAVM2Value;
  begin
    Value := @Locals[Index];
    // Only existing fields with static names can be read here. If a field
    // requires a getter, a proxy or a lexical lookup, the interpreter handles it.
    while (Value.Obj <> nil) and (StackTop < StackLimit) and (FWork > 0) and
      (Code.Position < CodeLength) and (Code.Data[Code.Position] = $66) do
    begin
      Position := Code.Position;
      Inc(Code.Position);
      Operand := Code.U30;
      if (Operand > 0) and (Operand < Length(Module.StaticNames)) then
        Field := FindOwnField(Value.Obj, Operand, Module.StaticNames[Operand])
      else
        Field := nil;
      if Field = nil then
      begin
        Code.Position := Position;
        Break;
      end;
      Dec(FWork);
      Value := Field;
    end;
    Push(Value^);
  end;

  procedure StoreLocal(Index: Integer);
  begin
    if StackTop = 0 then
      raise EAVM2Error.Create('AVM2 operand stack underflow');
    Dec(StackTop);
    CopyValue(Stack[StackTop], Locals[Index]);
    if Stack[StackTop].Text <> '' then
      Stack[StackTop].Text := '';
  end;

  function CoerceResolvedClass(TypeIndex: Integer): Boolean;
  var
    Cached: ^TAVM2ResolvedType;
    Value: PAVM2Value;
    ValueClass: TAVM2Object;
  begin
    Result := False;
    if (StackTop = 0) or (TypeIndex >= Length(Module.ResolvedTypes)) then
      Exit;
    Cached := @Module.ResolvedTypes[TypeIndex];
    if (Cached.Generation <> FDefinitionGeneration) or (Cached.Kind <> atClass) or (Cached.ClassObject = nil) then
      Exit;
    Value := @Stack[StackTop - 1];
    if Value.Kind in [a2Null, a2Undefined] then
    begin
      Value^ := TAVM2Value.Ref(nil);
      Exit(True);
    end;
    if (Value.Kind <> a2Object) or (Value.Obj = nil) then
      Exit;
    if Value.Obj.Kind = a2Class then
      ValueClass := FClassClass
    else
      ValueClass := Value.Obj.ClassObject;
    Result := ValueClass = Cached.ClassObject;
  end;

  function TakeParams(Count: Integer): TArray<TAVM2Value>;
  var
    J: Integer;
  begin
    if Count > StackTop then
      raise EAVM2Error.Create('AVM2 invalid argument count');
    SetLength(Result, Count);
    Dec(StackTop, Count);
    for J := 0 to Count - 1 do
    begin
      CopyValue(Stack[StackTop + J], Result[J]);
      if Stack[StackTop + J].Text <> '' then
        Stack[StackTop + J].Text := '';
    end;
  end;

  function CallPropertyOnStack(NameIndex, ArgumentCount: Integer; Lexical: Boolean): TAVM2Value;
  var
    FirstArgument, J: Integer;
    Receiver, MethodValue: TAVM2Value;
    Keys: TArray<string>;
    Key: string;
    FieldValue: PAVM2Value;
    FunctionObject, Proxy: TAVM2Object;
    Args: TArray<TAVM2Value>;
  begin
    if ArgumentCount > StackTop then
      raise EAVM2Error.Create('AVM2 invalid argument count');
    Dec(StackTop, ArgumentCount);
    FirstArgument := StackTop;
    // Name lookup sees the original stack layout after consuming the arguments.
    // Script calls copy arguments into their own locals before executing guest code.
    try
      Keys := PropertyNames(NameIndex, Key);
      Receiver := Pop;
      CheckNullReceiver(Receiver, NameIndex, Key);
      FieldValue := nil;
      if not Lexical then
      begin
        if Pointer(Keys) = Pointer(Module.StaticNames[NameIndex]) then
        begin
          FieldValue := FindDeclaredField(Receiver.Obj, NameIndex, SlotMethod);
          if FieldValue = nil then
            FieldValue := FindStaticOwnField(Receiver.Obj, NameIndex, Keys);
        end;
        if (FieldValue = nil) and CanAccessOwn(Receiver.Obj, Keys) then
          FieldValue := Receiver.Obj.Props.FindHinted(Keys[0], Module.PropertyHints[NameIndex]);
      end;
      if FieldValue <> nil then
        CopyValue(FieldValue^, MethodValue)
      else
        MethodValue := ReadProperty(Receiver, Keys, not Lexical);
      Proxy := nil;
      if not Lexical and (MethodValue.Kind = a2Undefined) then
        Proxy := ProxyMethod(Receiver.Obj, 'callProperty');
      if Lexical then
        Receiver := TAVM2Value.Ref(nil);
      FunctionObject := MethodValue.Obj;
      if (Proxy = nil) and (FunctionObject <> nil) and (FunctionObject.Kind = a2Function) and
        (FunctionObject.Module <> nil) then
      begin
        if ArgumentCount = 0 then
          Exit(InvokeScript(FunctionObject, Receiver, []));
        Exit(InvokeScript(FunctionObject, Receiver, Slice(PFrameCells(@Stack[FirstArgument])^, ArgumentCount)));
      end;
      SetLength(Args, ArgumentCount);
      for J := 0 to ArgumentCount - 1 do
        CopyValue(Stack[FirstArgument + J], Args[J]);
      if Proxy <> nil then
        for Key in Keys do
          if StartsStr(#0, Key) then
          begin
            FunctionObject := Proxy;
            Args := [TAVM2Value.Str(Copy(Key, 2, MaxInt))] + Args;
            Break;
          end;
      Result := Invoke(FunctionObject, Receiver, Args);
    finally
      for J := FirstArgument to FirstArgument + ArgumentCount - 1 do
        if Stack[J].Text <> '' then
          Stack[J].Text := '';
    end;
  end;

  function CheckedIndex(Count: Integer): Integer;
  begin
    Result := Code.U30;
    if Result >= Count then
      raise EAVM2Error.Create('AVM2 operand index out of bounds');
  end;

  function Capture: TArray<TAVM2Value>;
  begin
    Result := Outer + Copy(Scratch.Scopes, 0, ScopeTop);
  end;

  procedure JumpTo(Destination: Integer);
  begin
    if (Destination < 0) or (Destination >= Length(Code.Data)) then
      raise EAVM2Error.Create('AVM2 branch target out of bounds');
    if Module.Boundaries[Method.Body][Destination] and InstructionStart = 0 then
      raise EAVM2Error.Create('AVM2 branch target is not an instruction boundary');
    Code.Position := Destination;
  end;

  function RunNumericRegion(RegionIndex: Integer): Boolean;
  var
    Region: ^TAVM2NumericRegion;
    Instr: ^TAVM2NumericInstruction;
    Reg: ^TNumericRegister;
    Value: PAVM2Value;
    FieldOwner: TAVM2Object;
    Index: Integer;
    Right: Double;
    {$IFDEF AVM2_WIN64_JIT}
    Samples: TArray<TAVM2NumericSample>;
    Capture: Boolean;
    {$ENDIF}

    function Load(const Source: TAVM2Value): Boolean;
    begin
      Result := Source.Kind in [a2Boolean, a2Int, a2UInt, a2Number, a2Object];
      if Result then
      begin
        Reg.Kind := Source.Kind;
        Reg.Number := Source.Number;
        Reg.Obj := Source.Obj;
      end;
    end;

    procedure Write(const Source: TNumericRegister; var Dest: TAVM2Value);
    begin
      if Dest.Text <> '' then
        Dest.Text := '';
      Dest.Kind := Source.Kind;
      Dest.Number := Source.Number;
      Dest.Obj := Source.Obj;
    end;

  begin
    Result := False;
    Region := @NumericMethod.Regions[RegionIndex];
    if (FWork < Region.Work - 1) or (Region.Peak > StackLimit - StackTop) then
      Exit;
    {$IFDEF AVM2_WIN64_JIT}
    if (Region.NativeCode = nil) and FNumericJitEnabled and
      (Region.Warmups < NumericJitWarmups) then
    begin
      Capture := (Region.Warmups = NumericJitWarmups - 1) and
        (FNumericCompiles < NumericJitCompilesPerFrame) and (FNumericJitBudget >= NumericJitBufferBytes);
      if Capture then
        SetLength(Samples, Region.Limit - Region.First)
      else if Region.Warmups < NumericJitWarmups - 1 then
        Inc(Region.Warmups);
    end
    else
      Capture := False;
    if (Region.NativeCode = nil) or
      (Region.NativeCode.Invoke(Region.NativeEntry, NativeUInt(@Locals[0]), NativeUInt(@Scratch.Numeric[0]), 0, 0) = 0) then
    {$ENDIF}
      for Index := Region.First to Region.Limit - 1 do
      begin
        Instr := @NumericMethod.Code[Index];
        Reg := @Scratch.Numeric[Instr.Target];
        case Instr.Kind of
          anLoadLocal:
            if not Load(Locals[Instr.Operand]) then
              Exit;
          anLoadField:
            begin
              FieldOwner := Reg.Obj;
              if (FieldOwner <> nil) and (Instr.FieldLayout <> nil) and
                (FieldOwner.DeclaredSlots = Instr.FieldLayout) and (Instr.FieldSlot < FieldOwner.Props.FDeclaredCount) then
                Value := @FieldOwner.Props.FEntries[Instr.FieldSlot].Value
              else
              begin
                Value := FindDeclaredField(FieldOwner, Instr.Operand, SlotReadable);
                if Value <> nil then
                begin
                  Instr.FieldLayout := FieldOwner.DeclaredSlots;
                  Instr.FieldSlot := (NativeInt(Value) - NativeInt(@FieldOwner.Props.FEntries[0].Value)) div
                    SizeOf(FieldOwner.Props.FEntries[0]);
                end;
              end;
            {$IFDEF AVM2_WIN64_JIT}
              if Capture and (Value <> nil) then
              begin
                Samples[Index - Region.First].Layout := Instr.FieldLayout;
                Samples[Index - Region.First].SlotIndex := Instr.FieldSlot;
              end;
            {$ENDIF}
              if (Value = nil) or ((Value.Obj <> nil) and (Value.Obj.Kind = a2Function)) or
                not Load(Value^) then
                Exit;
            end;
          anInt, anUInt, anNumber, anBoolean:
            begin
              case Instr.Kind of
                anInt:
                  Reg.Kind := a2Int;
                anUInt:
                  Reg.Kind := a2UInt;
                anNumber:
                  Reg.Kind := a2Number;
                anBoolean:
                  Reg.Kind := a2Boolean;
              end;
              Reg.Number := Instr.Number;
              Reg.Obj := nil;
            end;
          anConvert, anNegate, anAdd, anSubtract, anMultiply, anDivide:
            begin
              if not (Reg.Kind in [a2Boolean, a2Int, a2UInt, a2Number]) then
                Exit;
              if Instr.Kind >= anAdd then
              begin
                if not (Scratch.Numeric[Instr.Source].Kind in [a2Boolean, a2Int, a2UInt, a2Number]) then
                  Exit;
                Right := Scratch.Numeric[Instr.Source].Number;
              end
              else
                Right := 0;
              case Instr.Kind of
                anNegate:
                  Reg.Number := -Reg.Number;
                anAdd:
                  Reg.Number := Reg.Number + Right;
                anSubtract:
                  Reg.Number := Reg.Number - Right;
                anMultiply:
                  Reg.Number := Reg.Number * Right;
                anDivide:
                  Reg.Number := Reg.Number / Right;
              end;
              Reg.Kind := a2Number;
            end;
        end;
      {$IFDEF AVM2_WIN64_JIT}
        if Capture then
          Samples[Index - Region.First].Kind := Reg.Kind;
      {$ENDIF}
      end;
    if Region.StoreField <> 0 then
    begin
      var Target := Scratch.Numeric[Region.StoreRegister - 1].Obj;
      Value := FindDeclaredField(Target, Region.StoreField, SlotWritable);
      if Value = nil then
        Exit;
      Target.Props.NoteReferenceChange(Value^, Scratch.Numeric[Region.StoreRegister].Obj);
      Write(Scratch.Numeric[Region.StoreRegister], Value^);
    end
    else if Region.StoreLocal >= 0 then
      Write(Scratch.Numeric[Region.StoreRegister], Locals[Region.StoreLocal]);
    for Index := 0 to Region.OutputCount - 1 do
      Write(Scratch.Numeric[Index], Stack[StackTop + Index]);
    Inc(StackTop, Region.OutputCount);
    Dec(FWork, Region.Work - 1); // The dispatcher has charged the first instruction.
    Code.Position := Region.Next;
    Result := True;
    {$IFDEF AVM2_WIN64_JIT}
    if Capture then
    begin
      Inc(Region.Warmups);
      Inc(FNumericCompiles);
      try
        CompileNumericRegion(Region^, NumericMethod.Code, Samples);
        if Region.NativeCode <> nil then
          Dec(FNumericJitBudget, NumericJitBufferBytes);
      except
        // A page policy or unsupported emission leaves this region interpreted.
        on E: EOSError do
          ;
        on E: EInvalidOpException do
          ;
      end;
    end;
    {$ENDIF}
  end;

  function ResumeAfterThrow(const Value: TAVM2Value): Boolean;
  var
    Entry: TABCException;
  begin
    for Entry in Body.Exceptions do
    begin
      Dec(FWork);
      if FWork < 0 then
        raise EAVM2Error.Create('AVM2 instruction limit');
      if (Offset >= Entry.First) and (Offset < Entry.Last) and
        MatchesExceptionType(Module, Entry.TypeName, Value) then
      begin
        while StackTop > 0 do
          Pop;
        while ScopeTop > 0 do
        begin
          Dec(ScopeTop);
          Scopes[ScopeTop] := Default(TAVM2Value);
        end;
        Push(Value);
        JumpTo(Entry.Target);
        Exit(True);
      end;
    end;
    Result := False;
  end;

begin
  if FDepth >= 128 then
    raise EAVM2Error.Create('AVM2 call depth limit');
  if (MethodIndex < 0) or (MethodIndex >= Length(Module.ABC.Methods)) then
    raise EAVM2Error.Create('AVM2 method index outside table');
  Method := @Module.ABC.Methods[MethodIndex];
  if Method.Body < 0 then
    raise EAVM2Error.Create('AVM2 method has no executable body');
  Body := @Module.ABC.Bodies[Method.Body];
  if Method.Flags and (NeedsArguments or NeedsRest) = (NeedsArguments or NeedsRest) then
    raise EAVM2Error.Create('Conflicting AVM2 variadic method flags');
  if (Body.LocalCount <= Length(Method.ParameterTypes) + Ord(Method.Flags and (NeedsArguments or NeedsRest) <> 0)) or
    (Body.StackLimit > 4096) or
    (Body.LocalCount > 4096) or (Body.ScopeLimit - Body.InitialScope > 1024) then
    raise EAVM2Error.Create('Invalid or excessive AVM2 method frame');
  if Module.Boundaries[Method.Body] = nil then
    Module.Boundaries[Method.Body] := ReadBoundaries(Body^, Method.Flags and NeedsActivation <> 0);
  NumericMethod := nil;
  {$IFNDEF AVM2_NO_NUMERIC_IR}
  NumericMethod := @Module.NumericMethods[Method.Body];
  if NumericMethod.Calls < 16 then
  begin
    Inc(NumericMethod.Calls);
    if NumericMethod.Calls = 16 then
      DecodeNumericMethod(Module, Method.Body, FNumericIRBudget);
  end;
  if NumericMethod.Offsets = nil then
    NumericMethod := nil;
  {$ENDIF}
  if NumericMethod <> nil then
    Code.Data := NumericMethod.EncodedCode
  else
    Code.Data := Body.Code;
  Code.Position := 0;
  CodeLength := Length(Code.Data);
  StackLimit := Body.StackLimit;
  LocalLimit := Body.LocalCount;
  ScopeLimit := Body.ScopeLimit - Body.InitialScope;
  Scratch := @FExecutionScratch[FDepth];
  if Length(Scratch.Stack) < StackLimit then
    SetLength(Scratch.Stack, StackLimit);
  if Length(Scratch.Locals) < LocalLimit then
    SetLength(Scratch.Locals, LocalLimit);
  if Length(Scratch.Scopes) < ScopeLimit then
    SetLength(Scratch.Scopes, ScopeLimit);
  // Each active VM depth owns its buffers until this invocation returns.
  Stack := Pointer(Scratch.Stack);
  Locals := Pointer(Scratch.Locals);
  Scopes := Pointer(Scratch.Scopes);
  StackTop := 0;
  ScopeTop := 0;
  Inc(FDepth);
  if FDepth = 1 then
  begin
    PreviousMask := GetExceptionMask;
    SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  end;
  try
    Locals[0] := Receiver;
    for I := 0 to High(Method.ParameterTypes) do
    begin
      if I < Length(Args) then
        Locals[I + 1] := Args[I]
      else
      begin
        N := I - Length(Method.ParameterTypes) + Length(Method.DefaultValues);
        if N < 0 then
          raise EAVM2Error.Create('Missing required AVM2 argument');
        Locals[I + 1] := ConstantValue(Module, Method.DefaultValues[N], Method.DefaultKinds[N]);
      end;
    end;
    if Method.Flags and (NeedsArguments or NeedsRest) <> 0 then
    begin
      Obj := Construct(FArrayClass, nil);
      if Method.Flags and NeedsRest <> 0 then
        AppendArray(Obj.ArrayData, Args, Length(Method.ParameterTypes))
      else
      begin
        AppendArray(Obj.ArrayData, Args);
        if CurrentFunction <> nil then
          StoreDynamicProperty(Obj, #0 + 'callee', TAVM2Value.Ref(CurrentFunction), False);
      end;
      Locals[Length(Method.ParameterTypes) + 1] := TAVM2Value.Ref(Obj);
    end;
    repeat
      try
        while Code.Position < CodeLength do
        begin
          Dec(FWork);
          if FWork < 0 then
            raise EAVM2Error.Create('AVM2 instruction limit');
          Offset := Code.Position;
          Op := Code.Data[Offset];
          Inc(Code.Position);
          if Op = NumericRegionOpcode then
          begin
            if RunNumericRegion(NumericMethod.Offsets[Offset] - 1) then
              Continue;
            Op := Body.Code[Offset];
          end;
          case Op of
            $02, $09:
              ;
            $03:
              raise EAVM2Thrown.Create(Pop);
            $04, $05:
              begin
                N := Code.U30;
                if Op = $05 then
                  A := Pop;
                NamesToTry := PropertyNames(N, Name);
                B := Pop;
                CheckNullReceiver(B, N, Name);
                if OwnerClass = nil then
                  raise EAVM2Error.Create('AVM2 super property outside a class');
                if Op = $04 then
                begin
                  A := SuperMember(OwnerClass.Parent, B.Obj, NamesToTry, 2);
                  if (A.Obj <> nil) and (A.Obj.Module <> nil) and (A.Obj.State = 1) then
                    A := Invoke(A.Obj, B, nil)
                  else if A.Kind = a2Undefined then
                    A := ReadProperty(B, NamesToTry, False);
                  Push(A);
                end
                else
                begin
                  Callable := SuperMember(OwnerClass.Parent, B.Obj, NamesToTry, 3).Obj;
                  if Callable <> nil then
                    Invoke(Callable, B, [A])
                  else
                    SetProperty(B.Obj, NamesToTry, A, False);
                end;
              end;
            $08:
              Locals[CheckedIndex(LocalLimit)] := Default(TAVM2Value);
            $0C..$1A:
              begin
                N := Code.S24;
                Target := Code.Position + N;
                Branch := True;
                if Op = $11 then
                  Branch := Truth(Pop)
                else if Op = $12 then
                  Branch := not Truth(Pop)
                else if Op <> $10 then
                begin
                  B := Pop;
                  A := Pop;
                  case Op of
                    $13, $14, $19, $1A:
                      begin
                        Branch := Equal(A, B, Op in [$19, $1A]);
                        if Op in [$14, $1A] then
                          Branch := not Branch;
                      end;
                  else
                    Relation := CompareValues(A, B);
                    case Op of
                      $0C, $15:
                        Branch := Relation = arLess;
                      $0D, $16:
                        Branch := Relation in [arLess, arEqual];
                      $0E, $17:
                        Branch := Relation = arGreater;
                      $0F, $18:
                        Branch := Relation in [arGreater, arEqual];
                    end;
                    if Op < $10 then
                      Branch := not Branch;
                  end;
                end;
                if Branch then
                  JumpTo(Target);
              end;
            $1B:
              begin
                A := Pop;
                if not (A.Kind in [a2Int, a2UInt, a2Number]) then
                  raise EAVM2Error.Create('AVM2 lookupswitch requires a numeric index');
                Target := Code.S24;
                N := ReadSwitchCaseCount(Code);
                I := Integer(IntBits(A.Number));
                if (I >= 0) and (I < N) then
                begin
                  Inc(Code.Position, I * 3);
                  Target := Code.S24;
                end;
                JumpTo(Offset + Target);
              end;
            $1D:
              begin
                if ScopeTop = 0 then
                  raise EAVM2Error.Create('AVM2 scope stack underflow');
                Dec(ScopeTop);
                Scopes[ScopeTop] := Default(TAVM2Value);
              end;
            $1E, $1F, $23:
              begin
                A := Pop;
                Target := Integer(IntBits(CoerceNumber(A)));
                B := Pop;
                if Op = $1F then
                begin
                  EnumIndex := 0;
                  if Target >= 0 then
                    EnumIndex := NextEnumerant(EnumerationObject(B), Cardinal(Target));
                  PushNumber(EnumIndex, a2UInt);
                end
                else if Target <= 0 then
                begin
                  if Op = $1E then
                    Push(TAVM2Value.Ref(nil))
                  else
                    Push(Default(TAVM2Value));
                end
                else
                begin
                  CheckNullReceiver(B);
                  Obj := EnumerationObject(B);
                  if (Op = $23) and (Obj <> nil) and (Obj.VectorData <> nil) and
                    (Target <= Obj.VectorData.Count) then
                  begin
                    Push(Obj.VectorData[Target - 1]);
                    Continue;
                  end;
                  A := EnumerantName(Obj, Cardinal(Target));
                  if Op = $1E then
                    Push(A)
                  else if (Obj <> nil) and (Obj.DictionaryKeys <> nil) and (A.Obj <> nil) then
                    Push(DictionaryValue(Obj, A.Obj))
                  else
                  begin
                    Name := #0 + AsText(A);
                    if (Obj <> nil) and (Obj.VectorData <> nil) and (A.Kind = a2Null) and not HasProperty(Obj, Name) then
                      RaiseScriptError('ReferenceError', 1069, 'Property null not found on ' +
                        Obj.DisplayName + ' and there is no default value.');
                    if IsXML(Obj) then
                      Push(XMLProperty(Obj, Name))
                    else
                      Push(PropertyValue(Obj, [Name]));
                  end;
                end;
              end;
            $20:
              begin
                A := Default(TAVM2Value);
                A.Kind := a2Null;
                Push(A);
              end;
            $21:
              Push(Default(TAVM2Value));
            $24:
              begin
                N := Code.U8;
                if N >= 128 then
                  Dec(N, 256);
                PushNumber(N, a2Int);
              end;
            $25:
              begin
                N := Integer(Code.U32 and $FFFF);
                if N >= 32768 then
                  Dec(N, 65536);
                PushNumber(N, a2Int);
              end;
            $26, $27:
              PushNumber(Ord(Op = $26), a2Boolean);
            $28:
              PushNumber(NaN);
            $29:
              Pop;
            $2A:
              begin
                A := Pop;
                Push(A);
                Push(A);
              end;
            $2B:
              begin
                B := Pop;
                A := Pop;
                Push(B);
                Push(A);
              end;
            $2C:
              Push(TAVM2Value.Str(Module.ABC.Strings[CheckedIndex(Length(Module.ABC.Strings))]));
            $2D:
              PushNumber(Module.ABC.Ints[CheckedIndex(Length(Module.ABC.Ints))], a2Int);
            $2E:
              PushNumber(Module.ABC.UInts[CheckedIndex(Length(Module.ABC.UInts))], a2UInt);
            $2F:
              begin
                N := CheckedIndex(Length(Module.ABC.Doubles));
                if N = 0 then
                  PushNumber(NaN)
                else
                  PushNumber(Module.ABC.Doubles[N]);
              end;
            $1C, $30:
              begin
                if ScopeTop >= ScopeLimit then
                  raise EAVM2Error.Create('AVM2 scope stack overflow');
                A := Pop;
                CheckNullReceiver(A);
                Scopes[ScopeTop] := A;
                Inc(ScopeTop);
              end;
            $32:
              begin
                N := CheckedIndex(LocalLimit);
                I := CheckedIndex(LocalLimit);
                Target := Integer(IntBits(AsNumber(Locals[I])));
                if Target < 0 then
                  PushNumber(0, a2Boolean)
                else
                begin
                  A := Locals[N];
                  Obj := EnumerationObject(A);
                  EnumIndex := NextEnumerant(Obj, Cardinal(Target));
                  while (EnumIndex = 0) and (Obj <> nil) do
                  begin
                    Dec(FWork);
                    if FWork < 0 then
                      raise EAVM2Error.Create('AVM2 instruction limit');
                    Obj := ObjectPrototype(Obj);
                    A := TAVM2Value.Ref(Obj);
                    EnumIndex := NextEnumerant(Obj, 0);
                  end;
                  if EnumIndex = 0 then
                    A := TAVM2Value.Ref(nil);
                  Locals[N] := A;
                  Locals[I] := TAVM2Value.Num(EnumIndex, a2UInt);
                  PushNumber(Ord(EnumIndex <> 0), a2Boolean);
                end;
              end;
            $31:
              begin
                N := CheckedIndex(Length(Module.ABC.Namespaces));
                if N = 0 then
                  raise EAVM2Error.Create('Invalid AVM2 pushnamespace operand');
                Push(ConstantValue(Module, N, Module.ABC.Namespaces[N].Kind));
              end;
            $40:
              begin
                N := CheckedIndex(Length(Module.ABC.Methods));
                Callable := NewObject(a2Function, True);
                Callable.Module := Module;
                Callable.Index := N;
                Callable.Scope := Capture;
                Callable.Script := Script;
                InitializeFunctionPrototype(Callable);
                Push(TAVM2Value.Ref(Callable));
              end;
            $41:
              begin
                Parameters := TakeParams(Code.U30);
                A := Pop;
                B := Pop;
                Push(Invoke(B.Obj, A, Parameters));
              end;
            $42:
              begin
                Parameters := TakeParams(Code.U30);
                A := Pop;
                Push(Instantiate(A.Obj, Parameters));
              end;
            $45, $4E:
              begin
                N := Code.U30;
                Parameters := TakeParams(Code.U30);
                NamesToTry := PropertyNames(N, Name);
                B := Pop;
                CheckNullReceiver(B, N, Name);
                if OwnerClass = nil then
                  raise EAVM2Error.Create('AVM2 callsuper outside a class');
                A := SuperMember(OwnerClass.Parent, B.Obj, NamesToTry, 1);
                B := Invoke(A.Obj, B, Parameters);
                if Op = $45 then
                  Push(B);
              end;
            $46, $4C, $4F:
              begin
                N := Code.U30;
                B := CallPropertyOnStack(N, Code.U30, Op = $4C);
                if Op <> $4F then
                  Push(B);
              end;
            $47:
              Exit(Default(TAVM2Value));
            $48:
              Exit(Pop);
            $49:
              begin
                Parameters := TakeParams(Code.U30);
                Obj := AsObject(Pop);
                if OwnerClass = nil then
                  raise EAVM2Error.Create('AVM2 constructsuper outside a class');
                ConstructInto(OwnerClass.Parent, Obj, Parameters);
              end;
            $4A:
              begin
                N := Code.U30;
                Parameters := TakeParams(Code.U30);
                NamesToTry := PropertyNames(N, Name);
                B := Pop;
                CheckNullReceiver(B, N, Name);
                A := ReadProperty(B, NamesToTry, True);
                Push(Instantiate(A.Obj, Parameters));
              end;
            $53:
              begin
                Parameters := TakeParams(Code.U30);
                A := Pop;
                Push(TAVM2Value.Ref(ApplyType(A.Obj, Parameters)));
              end;
            $55:
              begin
                N := Code.U30;
                if N > StackTop div 2 then
                  raise EAVM2Error.Create('AVM2 object literal stack underflow');
                Obj := NewObject(a2PlainObject, True);
                Obj.ClassObject := FObjectClass;
                Obj.Parent := FObjectPrototype;
                Parameters := TakeParams(N * 2);
                for I := 0 to N - 1 do
                  StoreDynamicProperty(Obj, #0 + AsText(Parameters[I * 2]), Parameters[I * 2 + 1]);
                Push(TAVM2Value.Ref(Obj));
              end;
            $56:
              begin
                Parameters := TakeParams(Code.U30);
                Obj := Construct(FArrayClass, nil);
                AppendArray(Obj.ArrayData, Parameters);
                Push(TAVM2Value.Ref(Obj));
              end;
            $57:
              begin
                Dec(FWork, Length(Body.Traits));
                if FWork < 0 then
                  raise EAVM2Error.Create('AVM2 instruction limit');
                Obj := NewObject(a2PlainObject, True);
                Obj.Module := Module;
                AddTraits(Obj, Module, Body.Traits, True);
                Push(TAVM2Value.Ref(Obj));
              end;
            $58:
              begin
                N := Code.U30;
                A := Pop;
                if A.Kind <> a2Null then
                  AsObject(A);
                Captured := Capture;
                Obj := NewClass(Module, N, A.Obj, Script, Captured);
                Push(TAVM2Value.Ref(Obj));
              end;
            $5A:
              begin
                Handler := Body.Exceptions[Code.U30];
                Obj := NewObject(a2PlainObject, True);
                if Handler.VariableName <> 0 then
                begin
                  Name := TraitKey(Module, Handler.VariableName);
                  Obj.Props.Add(Name, Default(TAVM2Value));
                  Obj.Slots := TDictionary<Integer, string>.Create;
                  Obj.Slots.Add(1, Name);
                end;
                Push(TAVM2Value.Ref(Obj));
              end;
            $5D, $5E, $5F, $60:
              begin
                N := Code.U30;
                if (N > 0) and (N < Length(Module.ABC.Multinames)) and
                  (Op = $60) and (Module.ABC.Multinames[N].Kind = $1D) then
                  Push(TAVM2Value.Ref(ResolveTypeClass(Module, N, 0)))
                else
                begin
                  if (Op = $60) and (ScopeTop > 0) and (N > 0) and (N < Length(Module.StaticNames)) then
                  begin
                    OwnField := ReadCapturedField(N);
                    if OwnField = nil then
                      OwnField := FindOwnField(Scopes[ScopeTop - 1].Obj, N, Module.StaticNames[N]);
                    if OwnField <> nil then
                    begin
                      Push(OwnField^);
                      Continue;
                    end;
                  end;
                  Obj := Find(Module, N, Script, Scratch.Scopes, Outer, ScopeTop, Op, FoundLexical);
                  if Op = $60 then
                  begin
                    NamesToTry := Names(Module, N);
                    OwnField := FindStaticOwnField(Obj, N, NamesToTry, FoundLexical);
                    if (OwnField <> nil) and ((OwnField.Obj = nil) or (OwnField.Obj.Kind <> a2Function)) then
                    begin
                      Push(OwnField^);
                      if OwnField = FoundLexical then
                        RememberCapturedField(N, Obj, OwnField);
                    end
                    else
                      Push(ReadProperty(TAVM2Value.Ref(Obj), NamesToTry, False));
                  end
                  else
                    Push(TAVM2Value.Ref(Obj));
                end;
              end;
            $61, $68:
              begin
                N := Code.U30;
                if (StackTop >= 2) and (N > 0) and (N < Length(Module.StaticNames)) then
                begin
                  if Module.StaticNames[N] <> nil then
                  begin
                    OwnField := FindDeclaredField(Stack[StackTop - 2].Obj, N, SlotWritable);
                    if OwnField <> nil then
                    begin
                      Dec(StackTop, 2);
                      Stack[StackTop].Obj.Props.StoreValue(OwnField^, Stack[StackTop + 1]);
                      if Stack[StackTop + 1].Text <> '' then
                        Stack[StackTop + 1].Text := '';
                      // The receiver is a plain object and holds no managed text.
                      Continue;
                    end;
                  end
                  else if Module.ABC.Multinames[N].Kind = $1B then
                  begin
                    Obj := NativeIndexedReceiver(N, StackTop - 3, ElementIndex);
                    if Obj <> nil then
                    begin
                      A := Pop;
                      Dec(StackTop, 2);
                      if Obj.VectorData <> nil then
                        SetVectorIndex(Obj, ElementIndex, A)
                      else
                        SetArrayElement(Obj.ArrayData, ElementIndex, A);
                      Continue;
                    end;
                  end;
                end;
                A := Pop;
                NamesToTry := PropertyNames(N, Name, Op = $61);
                if (Length(NamesToTry) = 0) and (DictionaryKey = nil) then
                  raise EAVM2Error.Create('Empty AVM2 property namespace set');
                B := Pop;
                CheckNullReceiver(B, N, Name);
                if B.Kind <> a2Object then
                  RejectPrimitiveWrite(B, NamesToTry, False)
                else if DictionaryKey <> nil then
                  StoreDictionaryKey(B.Obj, DictionaryKey, A)
                else if not CanAccessOwn(B.Obj, NamesToTry) or (B.Obj.SlotTypes <> nil) or
                  ((B.Obj.DeclaredSlots <> nil) and (B.Obj.DeclaredSlots.Types <> nil)) or
                  not B.Obj.Props.TrySetHinted(NamesToTry[0], Module.PropertyHints[N], A) then
                  SetProperty(B.Obj, NamesToTry, A);
              end;
            $62:
              LoadLocal(CheckedIndex(LocalLimit));
            $63:
              begin
                N := CheckedIndex(LocalLimit);
                StoreLocal(N);
              end;
            $64:
              Push(TAVM2Value.Ref(Script));
            $65:
              begin
                N := Code.U8;
                if N >= ScopeTop then
                  raise EAVM2Error.Create('Invalid AVM2 scope index');
                Push(Scopes[N]);
              end;
            $66:
              begin
                N := Code.U30;
                if (StackTop > 0) and (N > 0) and (N < Length(Module.StaticNames)) then
                begin
                  if Module.StaticNames[N] <> nil then
                  begin
                    Obj := Stack[StackTop - 1].Obj;
                    OwnField := FindDeclaredField(Obj, N, SlotReadable);
                    if OwnField = nil then
                      OwnField := FindStaticOwnField(Obj, N, Module.StaticNames[N]);
                    if (OwnField <> nil) and ((OwnField.Obj = nil) or (OwnField.Obj.Kind <> a2Function)) then
                    begin
                      CopyValue(OwnField^, Stack[StackTop - 1]);
                      Continue;
                    end;
                  end
                  else if Module.ABC.Multinames[N].Kind = $1B then
                  begin
                    Obj := NativeIndexedReceiver(N, StackTop - 2, ElementIndex);
                    if (Obj <> nil) and TryReadNativeIndex(Obj, ElementIndex, A) then
                    begin
                      Dec(StackTop);
                      CopyValue(A, Stack[StackTop - 1]);
                      Continue;
                    end;
                  end;
                end;
                NamesToTry := PropertyNames(N, Name, True);
                if StackTop = 0 then
                  raise EAVM2Error.Create('AVM2 operand stack underflow');
                I := StackTop - 1;
                CheckNullReceiver(Stack[I], N, Name);
                Obj := Stack[I].Obj;
                if DictionaryKey <> nil then
                  Stack[I] := DictionaryValue(Obj, DictionaryKey)
                else
                begin
                  OwnField := nil;
                  if CanAccessOwn(Obj, NamesToTry) then
                    OwnField := Obj.Props.FindHinted(NamesToTry[0], Module.PropertyHints[N]);
                  if (OwnField <> nil) and ((OwnField.Obj = nil) or (OwnField.Obj.Kind <> a2Function)) then
                    CopyValue(OwnField^, Stack[I])
                  else
                  begin
                    A := Stack[I];
                    Stack[I] := ReadProperty(A, NamesToTry, False);
                  end;
                end;
              end;
            $67:
              Push(Outer[CheckedIndex(Length(Outer))]);
            $6A:
              begin
                N := Code.U30;
                NamesToTry := PropertyNames(N, Name, True);
                A := Pop;
                CheckNullReceiver(A, N, Name);
                if A.Kind <> a2Object then
                  RejectPrimitiveWrite(A, NamesToTry, True);
                if DictionaryKey <> nil then
                begin
                  if A.Obj.DictionaryKeys.TryGetValue(DictionaryKey, DictionaryEntry) then
                  begin
                    A.Obj.DictionaryKeys.Remove(DictionaryKey);
                    A.Obj.DynamicProperties[DictionaryEntry.Slot] := Default(TAVM2DynamicProperty);
                  end;
                  Branch := True;
                end
                else
                  Branch := DeleteProperty(A.Obj, NamesToTry);
                PushNumber(Ord(Branch), a2Boolean);
              end;
            $6C..$6F:
              begin
                N := Code.U30;
                if Op in [$6D, $6F] then
                  A := Pop;
                if Op in [$6E, $6F] then
                  Obj := Script
                else
                  Obj := ObjectReceiver(Pop);
                SlotLayout := Obj.DeclaredSlots;
                SlotNames := Obj.Slots;
                if SlotLayout <> nil then
                begin
                  SlotNames := SlotLayout.Names;
                  if (Obj.Props.FDeclaredCount <> 0) and (N < Length(SlotLayout.Offsets)) then
                  begin
                    I := SlotLayout.Offsets[N] - 1;
                    if I >= 0 then
                    begin
                      if Op in [$6C, $6E] then
                      begin
                        Push(Obj.Props.FEntries[I].Value);
                        Continue;
                      end;
                      if SlotLayout.Flags[I] and SlotWritable <> 0 then
                      begin
                        Obj.Props.StoreValue(Obj.Props.FEntries[I].Value, A);
                        Continue;
                      end;
                    end;
                  end;
                end;
                if (SlotNames = nil) or not SlotNames.TryGetValue(N, Name) then
                  raise EAVM2Error.Create('Invalid AVM2 slot');
                if Op in [$6D, $6F] then
                  StoreSlot(Obj, Name, A)
                else
                  Push(PropertyValue(Obj, [Name]));
              end;
            $70:
              Push(TAVM2Value.Str(CoerceText(Pop)));
            $73, $83:
              PushNumber(Integer(IntBits(CoerceNumber(Pop))), a2Int);
            $74, $88:
              PushNumber(IntBits(CoerceNumber(Pop)), a2UInt);
            $75, $84:
              if (StackTop > 0) and (Stack[StackTop - 1].Kind in [a2Boolean, a2Int, a2UInt, a2Number]) then
                Stack[StackTop - 1].Kind := a2Number
              else
                PushNumber(CoerceNumber(Pop));
            $76, $81:
              PushNumber(Ord(Truth(Pop)), a2Boolean);
            $77:
              begin
                A := Pop;
                CheckNullReceiver(A);
                Push(A);
              end;
            $80, $86, $B2:
              begin
                N := Code.U30;
                if (Op = $80) and CoerceResolvedClass(N) then
                  Continue;
                A := Pop;
                TypeKind := ResolveType(Module, N, TargetClass, TypeName);
                if Op = $80 then
                  Push(CoerceValue(A, TypeKind, TargetClass, TypeName))
                else if Op = $B2 then
                  PushNumber(Ord(ValueHasType(A, TypeKind, TargetClass)), a2Boolean)
                else if ValueHasType(A, TypeKind, TargetClass) then
                  Push(A)
                else
                  Push(TAVM2Value.Ref(nil));
              end;
            $82:
              ; // coerce_a
              $85:
              begin
                A := Pop;
                if A.Kind in [a2Null, a2Undefined] then
                begin
                  A.Kind := a2Null;
                  Push(A);
                end
                else
                  Push(TAVM2Value.Str(CoerceText(A)));
              end;
            $89:
              begin
                A := Pop;
                if A.Kind in [a2Null, a2Undefined] then
                  Push(TAVM2Value.Ref(nil))
                else
                  Push(A);
              end;
            $90:
              PushNumber(-AsNumber(Pop));
            $91:
              PushNumber(AsNumber(Pop) + 1);
            $93:
              PushNumber(AsNumber(Pop) - 1);
            $92, $94, $C2, $C3:
              begin
                N := CheckedIndex(LocalLimit);
                L := CoerceNumber(Locals[N]);
                if Op in [$C2, $C3] then
                begin
                  L := Integer(IntBits(L));
                  Locals[N] := TAVM2Value.Num(Integer(IntBits(L + 1 - 2 * Ord(Op = $C3))), a2Int);
                end
                else
                  Locals[N] := TAVM2Value.Num(L + 1 - 2 * Ord(Op = $94));
              end;
            $C0, $C1:
              begin
                L := Integer(IntBits(CoerceNumber(Pop)));
                PushNumber(Integer(IntBits(L + 1 - 2 * Ord(Op = $C1))), a2Int);
              end;
            $95:
              begin
                A := Pop;
                case A.Kind of
                  a2Undefined:
                    Name := 'undefined';
                  a2Boolean:
                    Name := 'boolean';
                  a2Int, a2UInt, a2Number:
                    Name := 'number';
                  a2String:
                    Name := 'string';
                else
                  if (A.Obj <> nil) and (A.Obj.Kind = a2Function) then
                    Name := 'function'
                  else
                    Name := 'object';
                end;
                Push(TAVM2Value.Str(Name));
              end;
            $96:
              PushNumber(Ord(not Truth(Pop)), a2Boolean);
            $97:
              PushNumber(Integer(not IntBits(CoerceNumber(Pop))), a2Int);
            $A5..$AA:
              begin
                B := Pop;
                A := Pop;
                LeftBits := IntBits(CoerceNumber(A));
                RightBits := IntBits(CoerceNumber(B));
                case Op of
                  $A5:
                    LeftBits := LeftBits shl (RightBits and 31);
                  $A6:
                    begin
                      N := Integer(RightBits and 31);
                      Branch := LeftBits and $80000000 <> 0;
                      LeftBits := LeftBits shr N;
                      if Branch and (N <> 0) then
                        LeftBits := LeftBits or (High(Cardinal) shl (32 - N));
                    end;
                  $A7:
                    LeftBits := LeftBits shr (RightBits and 31);
                  $A8:
                    LeftBits := LeftBits and RightBits;
                  $A9:
                    LeftBits := LeftBits or RightBits;
                  $AA:
                    LeftBits := LeftBits xor RightBits;
                end;
                if Op = $A7 then
                  PushNumber(LeftBits, a2UInt)
                else
                  PushNumber(Integer(LeftBits), a2Int);
              end;
            $A0..$A4, $AB, $AC, $C5..$C7:
              begin
                if (Op <= $A4) and (StackTop >= 2) and
                  (Stack[StackTop - 2].Kind in [a2Boolean, a2Int, a2UInt, a2Number]) and
                  (Stack[StackTop - 1].Kind in [a2Boolean, a2Int, a2UInt, a2Number]) then
                begin
                  Dec(StackTop);
                  L := Stack[StackTop - 1].Number;
                  R := Stack[StackTop].Number;
                  case Op of
                    $A0:
                      L := L + R;
                    $A1:
                      L := L - R;
                    $A2:
                      L := L * R;
                    $A3:
                      L := L / R;
                    $A4:
                      L := FMod(L, R);
                  end;
                  Stack[StackTop - 1].Kind := a2Number;
                  Stack[StackTop - 1].Number := L;
                  Continue;
                end;
                B := Pop;
                A := Pop;
                if Op = $A0 then
                begin
                  A := CoercePrimitive(A, False);
                  B := CoercePrimitive(B, False);
                end;
                if (Op = $A0) and ((A.Kind = a2String) or (B.Kind = a2String)) then
                begin
                  Name := AsText(A);
                  B.Text := AsText(B);
                  if Length(Name) > TextLimit - Length(B.Text) then
                    raise EAVM2Error.Create('AVM2 string size limit');
                  Push(TAVM2Value.Str(Name + B.Text));
                end
                else if Op in [$AB, $AC] then
                  PushNumber(Ord(Equal(A, B, Op = $AC)), a2Boolean)
                else
                begin
                  L := AsNumber(A);
                  R := AsNumber(B);
                  case Op of
                    $A0:
                      PushNumber(L + R);
                    $A1:
                      PushNumber(L - R);
                    $A2:
                      PushNumber(L * R);
                    $A3:
                      PushNumber(L / R);
                    $A4:
                      PushNumber(FMod(L, R));
                    $C5:
                      PushNumber(Integer(Cardinal(UInt64(IntBits(L)) + IntBits(R))), a2Int);
                    $C6:
                      PushNumber(Integer(Cardinal(UInt64(IntBits(L)) + UInt64($100000000) - IntBits(R))), a2Int);
                    $C7:
                      PushNumber(Integer(Cardinal(UInt64(IntBits(L)) * IntBits(R))), a2Int);
                  end;
                end;
              end;
            $AD..$B0:
              begin
                B := Pop;
                A := Pop;
                Relation := CompareValues(A, B);
                case Op of
                  $AD:
                    Branch := Relation = arLess;
                  $AE:
                    Branch := Relation in [arLess, arEqual];
                  $AF:
                    Branch := Relation = arGreater;
                else // greater-or-equal ($B0)
                  Branch := Relation in [arGreater, arEqual];
                end;
                PushNumber(Ord(Branch), a2Boolean);
              end;
            $B1:
              begin
                B := Pop;
                A := Pop;
                PushNumber(Ord(IsInstanceOf(A, B.Obj)), a2Boolean);
              end;
            $87, $B3:
              begin
                B := Pop;
                A := Pop;
                TargetClass := B.Obj;
                if (TargetClass = nil) or (TargetClass.Kind <> a2Class) then
                  RaiseScriptError('TypeError', 1041, 'The right-hand side of operator must be a class.');
                TypeKind := TargetClass.PrimitiveKind;
                if TargetClass = FObjectClass then
                  TypeKind := atObject
                else if TargetClass = FFunctionClass then
                  TypeKind := atFunction
                else if TypeKind = atAny then
                  TypeKind := atClass;
                Branch := ValueHasType(A, TypeKind, TargetClass);
                if Op = $B3 then
                  PushNumber(Ord(Branch), a2Boolean)
                else if Branch then
                  Push(A)
                else
                  Push(TAVM2Value.Ref(nil));
              end;
            $B4:
              begin
                A := Pop;
                CheckNullReceiver(A);
                B := Pop;
                if (B.Obj <> nil) and (A.Obj <> nil) and (A.Obj.DictionaryKeys <> nil) then
                  Branch := A.Obj.DictionaryKeys.ContainsKey(B.Obj)
                else
                begin
                  Name := #0 + AsText(B);
                  if A.Kind = a2Object then
                    Branch := HasProperty(A.Obj, Name)
                  else
                    Branch := ((A.Kind = a2String) and (Name = #0 + 'length')) or
                      HasProperty(ValuePrototype(A), Name);
                end;
                PushNumber(Ord(Branch), a2Boolean);
              end;
            $D0..$D7:
              begin
                N := Op and 3;
                if N >= LocalLimit then
                  raise EAVM2Error.Create('Invalid AVM2 local register');
                if Op < $D4 then
                  LoadLocal(N)
                else
                  StoreLocal(N);
              end;
            $EF:
              begin
                Code.U8;
                Code.U30;
                Code.U8;
                Code.U30;
              end;
            $F0, $F1:
              Code.U30;
          else
            raise EAVM2Error.CreateFmt('AVM2 opcode $%.2x at byte %d is not implemented', [Op, Offset]);
          end;
        end;
        raise EAVM2Error.Create('AVM2 method ended without return');
      except
        on E: EAVM2Thrown do
          if not ResumeAfterThrow(E.Value) then
            raise;
      end;
    until False;
  finally
    // There is no live VM frame at this depth after this call returns.
    for I := 0 to StackTop - 1 do
      Stack[I].Text := '';
    for I := 0 to ScopeTop - 1 do
      Scopes[I].Text := '';
    for I := 0 to LocalLimit - 1 do
    begin
      Locals[I].Kind := a2Undefined;
      Locals[I].Obj := nil;
      Locals[I].Number := 0;
      if Locals[I].Text <> '' then
        Locals[I].Text := '';
    end;
    if FDepth = 1 then
    begin
      ClearExceptions;
      SetExceptionMask(PreviousMask);
    end;
    Dec(FDepth);
  end;
end;

end.

