unit AVM2.Runtime;

interface

uses
  System.SysUtils, System.Generics.Collections, AVM2.ABC;

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

  TAVM2EventKind = (aeNone, aeEvent, aeKeyboard, aeMouse);

  TAVM2EventMethod = (aeAddListener, aeRemoveListener, aeHasListener, aeWillTrigger,
    aeDispatch, aeStop, aeStopImmediate, aePreventDefault, aeIsDefaultPrevented);

  TAVM2Listener = record
    Name: string;
    Callback: TAVM2Object;
    Capture: Boolean;
    Priority: Integer;
  end;

  TAVM2DisplayKind = (adNone, adContainer, adSprite, adMovieClip, adShape, adGraphics);

  TAVM2DisplayMethod = (adAddChild, adAddChildAt, adRemoveChild, adRemoveChildAt,
    adGetChildAt, adGetChildIndex, adSetChildIndex, adContains,
    adClear, adBeginFill, adEndFill, adMoveTo, adLineTo, adCurveTo, adDrawRect,
    adDrawCircle, adDrawEllipse, adLineStyle);

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
    aaSort, aaSortOn);

  TAVM2ObjectMethod = (omPropertyIsEnumerable, omSetPropertyIsEnumerable, omHasOwnProperty);

  TAVM2DynamicProperty = record
    Key: string;
    Enumerable: Boolean;
  end;

  TAVM2DisplayHost = class abstract
    function CreateDisplay(Document: Boolean): TObject; virtual; abstract;
    procedure Place(Child, Parent: TObject; Position: Integer); virtual; abstract;
    procedure SetProperty(Display: TObject; const Name: string; Value: Double); virtual; abstract;
    procedure Draw(Display: TObject; Command: TAVM2DisplayMethod; const Args: TArray<Double>); virtual; abstract;
  end;

  TAVM2Object = class
    Kind: TAVM2ObjectKind;
    Props: TDictionary<string, TAVM2Value>;
    DynamicProperties: TList<TAVM2DynamicProperty>;
    DynamicIndices: TDictionary<string, Integer>;
    Slots: TDictionary<Integer, string>;
    ActivationSlotTypes: TDictionary<string, Integer>;
    ByteArrayData: TAVM2ByteArray;
    ArrayData: TAVM2Array;
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
    BoundReceiver: TAVM2Value;
    FunctionPrototype: TAVM2Object;
    InstancePrototype: TAVM2Object;
    PrimitiveKind: TAVM2TypeKind;
    RegExp: TAVM2RegExp;
    CanDispatch, NativeError: Boolean;
    Listeners: TList<TAVM2Listener>;
    EventKind: TAVM2EventKind;
    EventStop: Integer;
    EventCancelled, EventDispatching, HostEvent, EventMarked: Boolean;
    constructor Create(AKind: TAVM2ObjectKind);
    destructor Destroy; override;
  end;

  TAVM2Module = class
    ABC: TABCFile;
    Id: Integer;
    Scripts, Classes: TArray<TAVM2Object>;
    Boundaries: TArray<TBytes>;
    constructor Create(const Data: TBytes; AId: Integer);
    destructor Destroy; override;
  end;

  TAVM2Runtime = class
  private
    FObjects: TObjectList<TAVM2Object>;
    FModules: TObjectList<TAVM2Module>;
    FDefinitions: TDictionary<string, TAVM2Object>;
    FLoadedTags: TDictionary<Integer, Boolean>;
    FNative, FDocument, FAddFrameScript, FErrorToString: TAVM2Object;
    FByteArrayClass: TAVM2Object;
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
    FSWFVersion: Integer;
    FFrameScripts: TDictionary<Integer, TAVM2Object>;
    FTrace: TProc<string>;
    FDisplay: TAVM2DisplayHost;
    FDisplayFunctions: array[TAVM2DisplayMethod] of TAVM2Object;
    FStage, FEnterFrameClass, FKeyboardClass, FMouseClass, FFocus: TAVM2Object;
    FEventFunctions: array[TAVM2EventMethod] of TAVM2Object;
    FHostEvents: TObjectList<TAVM2Object>;
    FNewHostEvents: Integer;
    FEnterFrameTargets: TList<TAVM2Object>;
    FDisplayObjects: TDictionary<TObject, TAVM2Object>;
    FWork, FDepth: Integer;
    procedure InstallFunctionClass(ObjectClass: TAVM2Object);
    function ForwardFunction(Func: TAVM2Object; const Args: TArray<TAVM2Value>; UseArray: Boolean): TAVM2Value;
    procedure InstallArrayClass(ObjectClass: TAVM2Object);
    function ArrayLengthValue(const Value: TAVM2Value): Cardinal;
    procedure SetArrayLength(Data: TAVM2Array; LengthValue: Cardinal);
    procedure SetArrayElement(Data: TAVM2Array; Index: Cardinal; const Value: TAVM2Value);
    procedure RemoveArrayElement(Data: TAVM2Array; Index: Cardinal);
    procedure AppendArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>);
    procedure ShiftArrayKeys(Data: TAVM2Array; Delta: Int64);
    procedure ReverseArray(Data: TAVM2Array);
    function SliceArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SpliceArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SearchArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>; Backwards: Boolean): Integer;
    function ArrayCallback(Command: TAVM2ArrayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function ArrayCall(Command: TAVM2ArrayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function SortArray(Receiver: TAVM2Object; const Args: TArray<TAVM2Value>; ByFields: Boolean): TAVM2Value;
    procedure InstallByteArrayClasses(ObjectClass, ErrorClass: TAVM2Object);
    function GetByteArrayProperty(Data: TAVM2ByteArray; const Name: string; out Value: TAVM2Value): Boolean;
    function SetByteArrayProperty(Data: TAVM2ByteArray; const Name: string; const Value: TAVM2Value): Boolean;
    procedure ResizeByteArray(Data: TAVM2ByteArray; Size: Cardinal);
    procedure TransformByteArray(Data: TAVM2ByteArray; Command: TAVM2ByteMethod; const Args: TArray<TAVM2Value>);
    function ByteArrayCall(Command: TAVM2ByteMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure InstallEventConstants;
    procedure RaiseScriptError(const ClassName: string; Code: Integer; const Detail: string);
    function ResolveType(Module: TAVM2Module; Index: Integer; out ClassObject: TAVM2Object; out QualifiedName: string): TAVM2TypeKind;
    function ValueHasType(const Value: TAVM2Value; Kind: TAVM2TypeKind; ClassObject: TAVM2Object): Boolean;
    function CoerceValue(const Value: TAVM2Value; Kind: TAVM2TypeKind; ClassObject: TAVM2Object; const QualifiedName: string): TAVM2Value;
    function MatchesExceptionType(Module: TAVM2Module; Index: Integer; const Value: TAVM2Value): Boolean;
    procedure BindDispatcher(Instance: TAVM2Object);
    procedure CollectHostEvents;
    function StageOf(Display: TAVM2Object): TAVM2Object;
    procedure InitEvent(Event: TAVM2Object; Kind: TAVM2EventKind; const Name: string; Bubbles, Cancelable: Boolean);
    function HostEventObject(EventClass: TAVM2Object; const Name: string; Bubbles, Cancelable: Boolean): TAVM2Object;
    function HasListener(Receiver: TAVM2Object; const Name: string; IncludeAncestors: Boolean): Boolean;
    function EventCall(Command: TAVM2EventMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function DispatchEventTo(Target, Event: TAVM2Object; BroadcastOnly: Boolean): Boolean;
    procedure BindDisplay(Instance: TAVM2Object; Kind: TAVM2DisplayKind; Document: Boolean);
    function DisplayCall(Command: TAVM2DisplayMethod; Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    procedure SetProperty(Receiver: TAVM2Object; const Keys: TArray<string>; const Value: TAVM2Value);
    function NewObject(Kind: TAVM2ObjectKind): TAVM2Object;
    function Key(Module: TAVM2Module; NamespaceIndex: Integer; const Name: string): string;
    function NamespaceSetKeys(Module: TAVM2Module; SetIndex: Integer; const Name: string): TArray<string>;
    function HasProperty(Receiver: TAVM2Object; const Name: string): Boolean;
    function Names(Module: TAVM2Module; Index: Integer): TArray<string>;
    function TraitKey(Module: TAVM2Module; Index: Integer): string;
    function ConstantValue(Module: TAVM2Module; Index: Integer; Kind: Byte): TAVM2Value;
    procedure StoreSlot(Target: TAVM2Object; const Name: string; const Value: TAVM2Value);
    procedure StoreDynamicProperty(Obj: TAVM2Object; const Key: string; const Value: TAVM2Value; Enumerable: Boolean = True);
    procedure InstallObjectMethods;
    function InvokeObjectMethod(Method: TAVM2ObjectMethod; const Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
    function DeleteProperty(Obj: TAVM2Object; const Names: TArray<string>): Boolean;
    function NextEnumerant(Obj: TAVM2Object; Previous: Cardinal): Cardinal;
    function EnumerantName(Obj: TAVM2Object; Index: Cardinal): TAVM2Value;
    function ActivationSlotValue(Module: TAVM2Module; const Trait: TABCTrait): TAVM2Value;
    procedure AddTraits(Target: TAVM2Object; Module: TAVM2Module; const Traits: TArray<TABCTrait>; Activation: Boolean = False);
    procedure Initialize(Script: TAVM2Object);
    function Find(Module: TAVM2Module; Index: Integer; Script: TAVM2Object; const Scope, Outer: TArray<TAVM2Value>; ScopeCount: Integer; Op: Byte): TAVM2Object;
    function PropertyValue(Receiver: TAVM2Object; const Names: TArray<string>): TAVM2Value;
    function NewClass(Module: TAVM2Module; Index: Integer; Base, Script: TAVM2Object; const Outer: TArray<TAVM2Value>): TAVM2Object;
    procedure ConstructInto(ClassObject, Instance: TAVM2Object; const Args: TArray<TAVM2Value>);
    procedure InitializeFunctionPrototype(Func: TAVM2Object);
    function ClassPrototype(AClass: TAVM2Object; Depth: Integer = 0): TAVM2Object;
    function ObjectPrototype(Obj: TAVM2Object): TAVM2Object;
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
    function StringRegExp(Method: TAVM2PrimitiveMethod; const Text: string; const Args: TArray<TAVM2Value>): TAVM2Value;
    function Instantiate(AClass: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
    function Construct(ClassObject: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Object;
    procedure InstallInstanceTraits(ClassObject, Instance: TAVM2Object; Depth: Integer = 0);
    function Invoke(FunctionObject, Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value; overload;
    function Invoke(FunctionObject: TAVM2Object; Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value; overload;
    function Execute(Module: TAVM2Module; MethodIndex: Integer; const Receiver: TAVM2Value; Script, OwnerClass: TAVM2Object; const Outer, Args: TArray<TAVM2Value>; CurrentFunction: TAVM2Object = nil): TAVM2Value;
  public
    constructor Create(const Trace: TProc<string>; Display: TAVM2DisplayHost = nil; SWFVersion: Integer = 13);
    destructor Destroy; override;
    procedure BeginFrame;
    procedure LoadABC(TagId: Integer; const Data: TBytes; Lazy: Boolean);
    procedure CreateDocument(const Name: string);
    procedure RunFrameScript(Frame: Integer);
    procedure SetStageSize(Width, Height: Integer);
    procedure EnterFrame;
    procedure Keyboard(Code, CharCode: Integer; Pressed, Ctrl, Alt, Shift: Boolean);
    function DisplayObjectAt(Handle: TObject): TAVM2Object;
    procedure Mouse(Target: TAVM2Object; const Name: string; StageX, StageY, LocalX, LocalY: Double; ButtonDown, Ctrl, Alt, Shift: Boolean);
  end;

implementation

uses
  System.Classes, System.Character, System.Math, System.RegularExpressionsAPI,
  System.ZLib, AVM1.Coercion, AVM1.Strings, Z7.Archive.Lzma;

type
  TAVM2Relation = (arUnordered, arLess, arEqual, arGreater);

  TByteCodecResult = (bcOK, bcInvalid, bcLimit);

  EAVM2Thrown = class(EAVM2Error)
  public
    Value: TAVM2Value;
    constructor Create(const AValue: TAVM2Value);
  end;

const
  WorkLimit = 1000000;
  InstructionStart = 1;
  BranchDestination = 2;
  NeedsArguments = $01;
  NeedsActivation = $02;
  NeedsRest = $04;
  BuiltinTypeNames: array[atObject..atVoid] of string =
    ('Object', 'String', 'Boolean', 'Number', 'int', 'uint', 'Function', 'void');
  TextLimit = 1024 * 1024;
  ErrorTextDepthLimit = 8;
  ObjectLimit = 65536;
  TraceMethod = -2;
  AddFrameScriptMethod = -3;
  ErrorToStringMethod = -4;
  FunctionCallMethod = -5;
  FunctionApplyMethod = -6;
  EmptyFunctionMethod = -7;
  PrimitiveMethodBase = -256;
  RegExpMethodBase = -320;
  ObjectMethodBase = -336;
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
    'forEach', 'map', 'filter', 'every', 'some', 'sort', 'sortOn');
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
    'stopPropagation', 'stopImmediatePropagation', 'preventDefault', 'isDefaultPrevented');
  DisplayProperties: array[0..7] of string =
    ('x', 'y', 'scaleX', 'scaleY', 'rotation', 'alpha', 'visible', 'name');
  DisplayMethods: array[TAVM2DisplayMethod] of string =
    ('addChild', 'addChildAt', 'removeChild', 'removeChildAt', 'getChildAt', 'getChildIndex',
    'setChildIndex', 'contains', 'clear', 'beginFill', 'endFill', 'moveTo', 'lineTo',
    'curveTo', 'drawRect', 'drawCircle', 'drawEllipse', 'lineStyle');

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

constructor TAVM2Object.Create(AKind: TAVM2ObjectKind);
begin
  inherited Create;
  Kind := AKind;
  Index := -1;
  Props := TDictionary<string, TAVM2Value>.Create;
  Slots := TDictionary<Integer, string>.Create;
end;

destructor TAVM2Object.Destroy;
begin
  DynamicIndices.Free;
  DynamicProperties.Free;
  RegExp.Free;
  DisplayChildren.Free;
  Listeners.Free;
  ArrayData.Free;
  ByteArrayData.Free;
  ActivationSlotTypes.Free;
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
  SetLength(Boundaries, Length(ABC.Bodies));
end;

destructor TAVM2Module.Destroy;
begin
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

function ArrayText(Data: TAVM2Array; const Separator: string; Depth: Integer): string;
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
    if Value.Obj.Kind = a2Function then
      Result := 'function Function() {}'
    else if Value.Obj.RegExp <> nil then
      Result := RegExpLiteral(Value.Obj.RegExp)
    else if Value.Obj.ArrayData <> nil then
      Result := ArrayText(Value.Obj.ArrayData, ',', Depth)
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

function CompareValues(const Left, Right: TAVM2Value): TAVM2Relation;
var
  Order: Integer;
  L, R: Double;
begin
  if (Left.Kind = a2String) and (Right.Kind = a2String) then
  begin
    Order := CompareStr(Left.Text, Right.Text);
    if Order < 0 then
      Exit(arLess);
    if Order > 0 then
      Exit(arGreater);
    Exit(arEqual);
  end;
  L := AsNumber(Left);
  R := AsNumber(Right);
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
  if IsNan(Value) or IsInfinite(Value) or (Abs(Value) >= 1.0E30) then
    Exit(0);
  if Abs(Value) < 1.0 then
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

constructor TAVM2Runtime.Create(const Trace: TProc<string>; Display: TAVM2DisplayHost; SWFVersion: Integer);
var
  Base, Native, DisplayObject, ObjectClass, ErrorClass: TAVM2Object;
  Name, QualifiedName: string;
  Separator: Integer;
  Command: TAVM2DisplayMethod;
  EventCommand: TAVM2EventMethod;
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
  FDisplay := Display;
  FTrace := Trace;
  FObjects := TObjectList<TAVM2Object>.Create;
  FModules := TObjectList<TAVM2Module>.Create;
  FDefinitions := TDictionary<string, TAVM2Object>.Create;
  FLoadedTags := TDictionary<Integer, Boolean>.Create;
  FFrameScripts := TDictionary<Integer, TAVM2Object>.Create;
  FHostEvents := TObjectList<TAVM2Object>.Create;
  FEnterFrameTargets := TList<TAVM2Object>.Create;
  FDisplayObjects := TDictionary<TObject, TAVM2Object>.Create;
  FFunctionPrototype := NewObject(a2Function);
  FFunctionPrototype.Index := EmptyFunctionMethod;
  FAddFrameScript := NewObject(a2Function);
  FAddFrameScript.Index := AddFrameScriptMethod;
  FErrorToString := NewObject(a2Function);
  FErrorToString.Index := ErrorToStringMethod;
  FNative := NewObject(a2Script);
  Native := NewObject(a2Function);
  Native.Index := TraceMethod;
  FNative.Props.Add(#0 + 'trace', TAVM2Value.Ref(Native));
  FNative.Props.Add(#0 + 'undefined', Default(TAVM2Value));
  FNative.Props.Add(#0 + 'NaN', TAVM2Value.Num(NaN));
  FNative.Props.Add(#0 + 'Infinity', TAVM2Value.Num(Infinity));
  Base := nil;
  DisplayObject := nil;
  ObjectClass := nil;
  for Name in ['Object', 'flash.events.EventDispatcher', 'flash.display.DisplayObject', 'flash.display.InteractiveObject', 'flash.display.DisplayObjectContainer', 'flash.display.Sprite', 'flash.display.MovieClip', 'flash.display.Shape'] do
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
    else if Name = 'flash.display.Shape' then
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
  InstallObjectMethods;
  InstallPrimitiveMethods;
  InstallRegExpClass;
  InstallArrayClass(ObjectClass);
  InstallByteArrayClasses(ObjectClass, ErrorClass);
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
  FKeyboardClass := EventClass('KeyboardEvent', FEnterFrameClass, aeKeyboard);
  ConstantString(FKeyboardClass, 'KEY_DOWN', 'keyDown');
  ConstantString(FKeyboardClass, 'KEY_UP', 'keyUp');
  FMouseClass := EventClass('MouseEvent', FEnterFrameClass, aeMouse);
  ConstantString(FMouseClass, 'MOUSE_MOVE', 'mouseMove');
  ConstantString(FMouseClass, 'MOUSE_DOWN', 'mouseDown');
  ConstantString(FMouseClass, 'MOUSE_UP', 'mouseUp');
  ConstantString(FMouseClass, 'CLICK', 'click');
  InstallEventConstants;
  FStage := NewObject(a2PlainObject);
  FStage.Parent := ClassPrototype(FNative.Props['flash.events' + #0 + 'EventDispatcher'].Obj);
  FStage.DisplayName := 'Stage';
  BindDispatcher(FStage);
  FStage.Props.Add(#0 + 'stage', TAVM2Value.Ref(FStage));
end;

destructor TAVM2Runtime.Destroy;
begin
  FDisplayObjects.Free;
  FEnterFrameTargets.Free;
  FHostEvents.Free;
  FFrameScripts.Free;
  FLoadedTags.Free;
  FDefinitions.Free;
  FObjects.Free;
  FModules.Free;
  FDisplay.Free;
  inherited;
end;

procedure TAVM2Runtime.BeginFrame;
begin
  FWork := WorkLimit;
  if (FDepth = 0) and (FNewHostEvents >= 64) then
    CollectHostEvents;
end;

function TAVM2Runtime.NewObject(Kind: TAVM2ObjectKind): TAVM2Object;
begin
  if FObjects.Count >= ObjectLimit then
    raise EAVM2Error.Create('AVM2 object limit');
  Result := TAVM2Object.Create(Kind);
  if Kind = a2Function then
  begin
    Result.ClassObject := FFunctionClass;
    Result.Parent := FFunctionPrototype;
  end
  else if Kind in [a2PlainObject, a2Script] then
    Result.Parent := FObjectPrototype;
  FObjects.Add(Result);
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
begin
  if (Index <= 0) or (Index >= Length(Module.ABC.Multinames)) then
    raise EAVM2Error.Create('AVM2 multiname index outside pool');
  Name := Module.ABC.Multinames[Index];
  case Name.Kind of
    7:
      Result := [Key(Module, Name.NamespaceIndex, Module.ABC.Strings[Name.Name])];
    9:
      Result := NamespaceSetKeys(Module, Name.NamespaceSet, Module.ABC.Strings[Name.Name]);
  else
    raise EAVM2Error.CreateFmt('AVM2 multiname kind $%.2x is not executable yet', [Name.Kind]);
  end;
end;

function TAVM2Runtime.TraitKey(Module: TAVM2Module; Index: Integer): string;
begin
  if Module.ABC.Multinames[Index].Kind <> 7 then
    raise EAVM2Error.Create('AVM2 trait requires a QName');
  Result := Key(Module, Module.ABC.Multinames[Index].NamespaceIndex,
    Module.ABC.Strings[Module.ABC.Multinames[Index].Name]);
end;

function TAVM2Runtime.ConstantValue(Module: TAVM2Module; Index: Integer; Kind: Byte): TAVM2Value;
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
  else
    raise EAVM2Error.Create('AVM2 namespace constant is not executable yet');
  end;
end;

procedure TAVM2Runtime.StoreSlot(Target: TAVM2Object; const Name: string; const Value: TAVM2Value);
var
  TypeIndex: Integer;
  ClassObject: TAVM2Object;
  Kind: TAVM2TypeKind;
  TypeName: string;
begin
  if (Target.ActivationSlotTypes <> nil) and Target.ActivationSlotTypes.TryGetValue(Name, TypeIndex) then
  begin
    Kind := ResolveType(Target.Module, TypeIndex, ClassObject, TypeName);
    Target.Props.AddOrSetValue(Name, CoerceValue(Value, Kind, ClassObject, TypeName));
  end
  else
    Target.Props.AddOrSetValue(Name, Value);
end;

function TAVM2Runtime.ActivationSlotValue(Module: TAVM2Module; const Trait: TABCTrait): TAVM2Value;
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
  Method: TAVM2Object;
  Value: TAVM2Value;
begin
  for Trait in Traits do
  begin
    Name := TraitKey(Module, Trait.Name);
    Value := Default(TAVM2Value);
    case Trait.Kind of
      0, 6:
        if Activation then
          Value := ActivationSlotValue(Module, Trait)
        else
          Value := ConstantValue(Module, Trait.Value, Trait.ValueKind);
      1, 5:
        begin
          Method := NewObject(a2Function);
          Method.Module := Module;
          Method.Index := Trait.Target;
          if Trait.Kind = 1 then
            Method.BoundReceiver := TAVM2Value.Ref(Target);
          if Trait.Kind = 5 then
            InitializeFunctionPrototype(Method);
          Method.Script := Target.Script;
          Method.Scope := Target.Scope;
          if Target.Kind = a2Class then
            Method.ClassObject := Target
          else
            Method.ClassObject := Target.ClassObject;
          Value := TAVM2Value.Ref(Method);
        end;
      2, 3:
        Continue; // Accessor metadata is retained in the ABC.
    end;
    Target.Props.AddOrSetValue(Name, Value);
    if Trait.Kind in [0, 4, 5, 6] then
    begin
      Slot := Trait.Slot;
      if Slot = 0 then
      begin
        Slot := 1;
        while Target.Slots.ContainsKey(Slot) do
          Inc(Slot);
      end;
      Target.Slots.AddOrSetValue(Slot, Name);
      if Activation and (Trait.Target <> 0) then
      begin
        if Target.ActivationSlotTypes = nil then
          Target.ActivationSlotTypes := TDictionary<string, Integer>.Create;
        Target.ActivationSlotTypes.AddOrSetValue(Name, Trait.Target);
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
  Execute(Script.Module, Script.Module.ABC.Scripts[Script.Index].Init, TAVM2Value.Ref(Script), Script, nil, nil, nil);
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

function TAVM2Runtime.Find(Module: TAVM2Module; Index: Integer; Script: TAVM2Object; const Scope, Outer: TArray<TAVM2Value>; ScopeCount: Integer; Op: Byte): TAVM2Object;
var
  Candidates: TArray<string>;
  Name: string;
  I: Integer;
begin
  Candidates := Names(Module, Index);
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
  Native := NewObject(a2Function);
  Native.Index := FunctionApplyMethod;
  FFunctionPrototype.Props.Add(#0 + 'apply', TAVM2Value.Ref(Native));
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
    if Method in [aaSort, aaSortOn] then
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

procedure TAVM2Runtime.AppendArray(Data: TAVM2Array; const Args: TArray<TAVM2Value>);
var
  Value: TAVM2Value;
begin
  if UInt64(Data.ArrayLength) + UInt64(Length(Args)) > High(Cardinal) then
    RaiseScriptError('RangeError', 1005, 'Array index is not a positive integer.');
  if Length(Args) > ArrayElementLimit - FArrayElements then
    raise EAVM2Error.Create('AVM2 Array storage limit');
  for Value in Args do
    SetArrayElement(Data, Data.ArrayLength, Value);
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

function TAVM2Runtime.SortArray(Receiver: TAVM2Object; const Args: TArray<TAVM2Value>; ByFields: Boolean): TAVM2Value;
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
  Unique: Boolean;

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
    if (A.Kind = a2Undefined) or (B.Kind = a2Undefined) then
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
      if FSWFVersion < 13 then
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

  Count := ArrayParameterCount(Data);
  SetLength(Values, Count);
  for I := 0 to Count - 1 do
  begin
    Values[I].Index := Cardinal(I);
    Values[I].Value := ReadArrayValue(Receiver, I);
  end;
  Unique := True;
  SortRange(0, Count);
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
    aaSort, aaSortOn:
      Result := SortArray(Receiver, Args, Command = aaSortOn);
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
        Result := TAVM2Value.Str(ArrayText(Data, Separator, 0));
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
  if not Obj.Props.ContainsKey(Key) then
  begin
    if Obj.DynamicProperties = nil then
    begin
      Obj.DynamicProperties := TList<TAVM2DynamicProperty>.Create;
      Obj.DynamicIndices := TDictionary<string, Integer>.Create;
    end;
    if Obj.DynamicProperties.Count >= ArrayElementLimit then
      raise EAVM2Error.Create('AVM2 dynamic property limit');
    Entry.Key := Key;
    Entry.Enumerable := Enumerable;
    Obj.DynamicIndices.Add(Key, Obj.DynamicProperties.Count);
    Obj.DynamicProperties.Add(Entry);
  end;
  Obj.Props.AddOrSetValue(Key, Value);
end;

procedure TAVM2Runtime.InstallObjectMethods;
const
  Names: array[TAVM2ObjectMethod] of string =
    ('propertyIsEnumerable', 'setPropertyIsEnumerable', 'hasOwnProperty');
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
  Key := #0 + 'undefined';
  if Length(Args) > 0 then
    Key := #0 + AsText(Args[0]);
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
        if IsDynamic then
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
  HasPublicName := False;
  for Key in Names do
  begin
    HasPublicName := HasPublicName or (Key[1] = #0);
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
  if Obj.ArrayData <> nil then
  begin
    if Index <= Obj.ArrayData.ArrayLength then
      Exit(TAVM2Value.Num(Index - 1, a2UInt));
    Dec(Index, Obj.ArrayData.ArrayLength);
  end;
  if (Obj.DynamicProperties = nil) or (Index > Cardinal(Obj.DynamicProperties.Count)) then
    Exit;
  Key := Obj.DynamicProperties[Integer(Index) - 1].Key;
  if Key = '' then
    Exit;
  if TryPublicIndex(Key, Numeric) then
    Exit(TAVM2Value.Num(Numeric, a2UInt));
  Result := TAVM2Value.Str(Copy(Key, 2, MaxInt));
end;

function TAVM2Runtime.HasProperty(Receiver: TAVM2Object; const Name: string): Boolean;
var
  Index: Cardinal;
  Value: TAVM2Value;
begin
  while Receiver <> nil do
  begin
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
    Receiver := ObjectPrototype(Receiver);
  end;
  Result := False;
end;

function TAVM2Runtime.PropertyValue(Receiver: TAVM2Object; const Names: TArray<string>): TAVM2Value;
var
  Name: string;
  Index: Cardinal;
begin
  while Receiver <> nil do
  begin
    for Name in Names do
    begin
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
      if Receiver.Props.TryGetValue(Name, Result) then
      begin
        if (Name = #0 + 'stage') and (Receiver.DisplayKind <> adNone) then
          Result := TAVM2Value.Ref(StageOf(Receiver))
        else if (Name = #0 + 'focus') and (Receiver = FStage) and (StageOf(FFocus) <> FStage) then
          Result := TAVM2Value.Ref(nil);
        Exit;
      end;
    end;
    Receiver := ObjectPrototype(Receiver);
  end;
  Result := Default(TAVM2Value);
end;

function TAVM2Runtime.ResolveType(Module: TAVM2Module; Index: Integer; out ClassObject: TAVM2Object; out QualifiedName: string): TAVM2TypeKind;
var
  Name: string;
  Kind: TAVM2TypeKind;
  Scope: TAVM2Object;
  TypeValue: TAVM2Value;
begin
  ClassObject := nil;
  QualifiedName := '';
  if Index = 0 then
    Exit(atAny);
  for Name in Names(Module, Index) do
  begin
    for Kind := Low(BuiltinTypeNames) to High(BuiltinTypeNames) do
      if Name = #0 + BuiltinTypeNames[Kind] then
      begin
        QualifiedName := BuiltinTypeNames[Kind];
        Exit(Kind);
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
    Exit(atClass);
  end;
  raise EAVM2Error.Create('Unresolved AVM2 type ' + Module.ABC.Strings[Module.ABC.Multinames[Index].Name]);
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
    while ValueClass <> nil do
    begin
      if ValueClass = ClassObject then
        Exit(True);
      ValueClass := ValueClass.Parent;
    end;
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
      Exit(TAVM2Value.Num(Integer(IntBits(AsNumber(Value))), a2Int));
    atUInt:
      Exit(TAVM2Value.Num(IntBits(AsNumber(Value)), a2UInt));
    atNumber:
      Exit(TAVM2Value.Num(AsNumber(Value)));
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
    Exit(TAVM2Value.Str(AsText(Value)));
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
  Table: TAVM2Object;
  I: Integer;

  procedure Put(const Name: string; Code: Cardinal);
  begin
    Table.Props.Add(#0 + Name, TAVM2Value.Num(Code, a2UInt));
  end;

begin
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
begin
  FStage.Props.AddOrSetValue(#0 + 'stageWidth', TAVM2Value.Num(Width, a2Int));
  FStage.Props.AddOrSetValue(#0 + 'stageHeight', TAVM2Value.Num(Height, a2Int));
  FStage.Props.AddOrSetValue(#0 + 'focus', TAVM2Value.Ref(nil));
end;

procedure TAVM2Runtime.CollectHostEvents;
var
  Work: TList<TAVM2Object>;
  Obj: TAVM2Object;
  Index: Integer;

  procedure Mark(Subject: TAVM2Object);
  begin
    if (Subject = nil) or not Subject.HostEvent or Subject.EventMarked then
      Exit;
    Subject.EventMarked := True;
    Work.Add(Subject);
  end;

  procedure MarkFields(Subject: TAVM2Object);
  var
    Value: TAVM2Value;
    ScopeValue: TAVM2Value;
  begin
    for Value in Subject.Props.Values do
      Mark(Value.Obj);
    if Subject.ArrayData <> nil then
      for Value in Subject.ArrayData.Elements.Values do
        Mark(Value.Obj);
    for ScopeValue in Subject.Scope do
      Mark(ScopeValue.Obj);
    Mark(Subject.BoundReceiver.Obj);
    Mark(Subject.Parent);
    Mark(Subject.FunctionPrototype);
  end;

begin
  // Host-generated events can outlive dispatch if bytecode stores them.
  // Collection runs only between VM calls, when operand stacks are empty.
  FNewHostEvents := 0;
  Work := TList<TAVM2Object>.Create;
  try
    for Obj in FObjects do
      MarkFields(Obj);
    Index := 0;
    while Index < Work.Count do
    begin
      MarkFields(Work[Index]);
      Inc(Index);
    end;
    for Index := FHostEvents.Count - 1 downto 0 do
      if FHostEvents[Index].EventMarked then
        FHostEvents[Index].EventMarked := False
      else
        FHostEvents.Delete(Index);
  finally
    Work.Free;
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
  for Command := aeStop to aeIsDefaultPrevented do
    Event.Props.AddOrSetValue(#0 + EventMethods[Command], TAVM2Value.Ref(FEventFunctions[Command]));
end;

function TAVM2Runtime.HostEventObject(EventClass: TAVM2Object; const Name: string; Bubbles, Cancelable: Boolean): TAVM2Object;
begin
  if FHostEvents.Count >= ObjectLimit then
    raise EAVM2Error.Create('AVM2 retained event limit');
  Result := TAVM2Object.Create(a2PlainObject);
  FHostEvents.Add(Result);
  Inc(FNewHostEvents);
  Result.HostEvent := True;
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
  Position, I: Integer;
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
        if (Listener.Name = 'enterFrame') and not HasListener(Receiver, 'enterFrame', False) then
          FEnterFrameTargets.Remove(Receiver);
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
  if (Listener.Name = 'enterFrame') and not HasListener(Receiver, 'enterFrame', False) then
    FEnterFrameTargets.Add(Receiver);
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
    for Prop in Original.Props do
      if (Prop.Key <> #0 + 'currentTarget') and (Prop.Key <> #0 + 'target') and
        (Prop.Key <> #0 + 'eventPhase') then
        Event.Props.AddOrSetValue(Prop.Key, Prop.Value);
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

procedure TAVM2Runtime.EnterFrame;
var
  Receiver: TAVM2Object;
begin
  for Receiver in FEnterFrameTargets.ToArray do
    if HasListener(Receiver, 'enterFrame', False) then
      DispatchEventTo(Receiver, HostEventObject(FEnterFrameClass, 'enterFrame', False, False), True);
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
    not (Result.DisplayKind in [adContainer, adSprite, adMovieClip]) then
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

procedure TAVM2Runtime.BindDisplay(Instance: TAVM2Object; Kind: TAVM2DisplayKind; Document: Boolean);
var
  Graphics: TAVM2Object;
  Command: TAVM2DisplayMethod;
  Name: string;
  Empty: TAVM2Value;
begin
  if Kind = adNone then
    Exit;
  Instance.DisplayKind := Kind;
  if FDisplay <> nil then
  begin
    Instance.DisplayData := FDisplay.CreateDisplay(Document);
    FDisplayObjects.Add(Instance.DisplayData, Instance);
  end;
  Instance.Props.Add(#0 + 'stage', TAVM2Value.Ref(nil));
  Instance.Props.Add(#0 + 'x', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'y', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'scaleX', TAVM2Value.Num(1));
  Instance.Props.Add(#0 + 'scaleY', TAVM2Value.Num(1));
  Instance.Props.Add(#0 + 'rotation', TAVM2Value.Num(0));
  Instance.Props.Add(#0 + 'alpha', TAVM2Value.Num(1));
  Instance.Props.Add(#0 + 'visible', TAVM2Value.Num(1, a2Boolean));
  Instance.Props.Add(#0 + 'name', TAVM2Value.Str(''));
  Empty := Default(TAVM2Value);
  Empty.Kind := a2Null;
  Instance.Props.Add(#0 + 'parent', Empty);
  if Kind in [adContainer, adSprite, adMovieClip] then
  begin
    Instance.DisplayChildren := TList<TAVM2Object>.Create;
    Instance.Props.Add(#0 + 'numChildren', TAVM2Value.Num(0, a2Int));
    for Command := adAddChild to adContains do
      Instance.Props.Add(#0 + DisplayMethods[Command], TAVM2Value.Ref(FDisplayFunctions[Command]));
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

procedure TAVM2Runtime.SetProperty(Receiver: TAVM2Object; const Keys: TArray<string>; const Value: TAVM2Value);
var
  Key, Candidate, Name: string;
  Normalized: TAVM2Value;
  Number: Double;
  Index: Cardinal;
begin
  Key := Keys[0];
  for Candidate in Keys do
  begin
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
    if Receiver.Props.ContainsKey(Candidate) or ((Receiver.ByteArrayData <> nil) and
      GetByteArrayProperty(Receiver.ByteArrayData, Candidate, Normalized)) then
    begin
      Key := Candidate;
      Break;
    end;
    if Candidate[1] = #0 then
      Key := Candidate;
  end;
  if (Receiver.Kind = a2Class) and (Key = #0 + 'prototype') then
    RaiseScriptError('ReferenceError', 1074, 'Illegal write to read-only property prototype on ' + Receiver.DisplayName + '.');
  if (Receiver.EventKind <> aeNone) and
    ((Key = #0 + 'type') or (Key = #0 + 'target') or (Key = #0 + 'currentTarget') or
    (Key = #0 + 'eventPhase') or (Key = #0 + 'bubbles') or (Key = #0 + 'cancelable')) then
    raise EAVM2Error.Create('Read-only AVM2 event property ' + Copy(Key, 2, MaxInt));
  if (Receiver = FStage) and (Key = #0 + 'focus') then
  begin
    if Value.Kind in [a2Null, a2Undefined] then
      FFocus := nil
    else
    begin
      if (Value.Obj = nil) or (StageOf(Value.Obj) <> FStage) or
        not (Value.Obj.DisplayKind in [adContainer, adSprite, adMovieClip]) then
        raise EAVM2Error.Create('Invalid AVM2 Stage.focus');
      FFocus := Value.Obj;
    end;
    Receiver.Props.AddOrSetValue(Key, TAVM2Value.Ref(FFocus));
    Exit;
  end;
  if (Receiver.DisplayKind in [adContainer, adSprite, adMovieClip, adShape]) and
    (Length(Key) > 0) and (Key[1] = #0) then
  begin
    Name := Copy(Key, 2, MaxInt);
    if (Name = 'parent') or (Name = 'graphics') or (Name = 'numChildren') or (Name = 'stage') then
      raise EAVM2Error.Create('Read-only AVM2 display property ' + Name);
    if Name = 'name' then
    begin
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
    StoreDynamicProperty(Receiver, Key, Value)
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
    if (Result = nil) or not (Result.DisplayKind in [adContainer, adSprite, adMovieClip, adShape]) then
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
  if Command >= adClear then
  begin
    if Receiver.DisplayKind <> adGraphics then
      raise EAVM2Error.Create('Invalid AVM2 Graphics receiver');
    case Command of
      adBeginFill:
        Require(1);
      adMoveTo, adLineTo:
        Require(2);
      adDrawCircle:
        Require(3);
      adCurveTo, adDrawRect, adDrawEllipse:
        Require(4);
    end;
    // Coerce only the numeric arguments understood by the host.
    Count := Min(Length(Args), 4);
    if Command = adLineStyle then
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
        if FDisplay <> nil then
          FDisplay.Place(Child.DisplayData, nil, 0);
        Children.Remove(Child);
        Child.DisplayParent := nil;
        NullValue := Default(TAVM2Value);
        NullValue.Kind := a2Null;
        Child.Props.AddOrSetValue(#0 + 'parent', NullValue);
        SetChildCount(Receiver);
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
  if (OldParent = Receiver) and (Position = Children.Count) then
    Dec(Position);
  if FDisplay <> nil then
    FDisplay.Place(Child.DisplayData, Receiver.DisplayData, Position);
  if OldParent <> nil then
  begin
    OldParent.DisplayChildren.Remove(Child);
    SetChildCount(OldParent);
  end;
  Children.Insert(Position, Child);
  Child.DisplayParent := Receiver;
  Child.Props.AddOrSetValue(#0 + 'parent', TAVM2Value.Ref(Receiver));
  SetChildCount(Receiver);
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
  Execute(Module, Module.ABC.Classes[Index].Init, TAVM2Value.Ref(Result), Script, Result, Outer, nil);
end;

procedure TAVM2Runtime.InstallInstanceTraits(ClassObject, Instance: TAVM2Object; Depth: Integer);
var
  Method: TAVM2ByteMethod;
  ArrayMethod: TAVM2ArrayMethod;
begin
  if Depth >= 128 then
    raise EAVM2Error.Create('AVM2 inheritance depth limit');
  if ClassObject = nil then
    Exit;
  if ClassObject.Index < 0 then
  begin
    if ClassObject = FRegExpClass then
      Instance.RegExp := TAVM2RegExp.Create;
    if ClassObject.DisplayName = 'flash.display.MovieClip' then
      Instance.Props.Add(#0 + 'addFrameScript', TAVM2Value.Ref(FAddFrameScript));
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
  InstallInstanceTraits(ClassObject.Parent, Instance, Depth + 1);
  Instance.Scope := ClassObject.InstanceScope;
  Instance.Script := ClassObject.Script;
  Instance.ClassObject := ClassObject;
  AddTraits(Instance, ClassObject.Module, ClassObject.Module.ABC.Instances[ClassObject.Index].Definition.Traits);
end;

procedure TAVM2Runtime.ConstructInto(ClassObject, Instance: TAVM2Object; const Args: TArray<TAVM2Value>);
var
  Bubbles, Cancelable: Boolean;
  MessageValue: TAVM2Value;
  ErrorID: Cardinal;
begin
  if (ClassObject = nil) or (ClassObject.Kind <> a2Class) then
    raise EAVM2Error.Create('AVM2 receiver is not a class');
  if ClassObject.Index >= 0 then
    Execute(ClassObject.Module, ClassObject.Module.ABC.Instances[ClassObject.Index].Definition.Init,
      TAVM2Value.Ref(Instance), ClassObject.Script, ClassObject, ClassObject.InstanceScope, Args)
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
    Bubbles := ClassObject.EventKind in [aeKeyboard, aeMouse];
    if Length(Args) > 1 then
      Bubbles := Truth(Args[1]);
    Cancelable := (Length(Args) > 2) and Truth(Args[2]);
    InitEvent(Instance, ClassObject.EventKind, AsText(Args[0]), Bubbles, Cancelable);
  end;
end;

procedure TAVM2Runtime.InitializeFunctionPrototype(Func: TAVM2Object);
begin
  Func.FunctionPrototype := NewObject(a2PlainObject);
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
    Exit(TAVM2Value.Str(AsText(Value)));
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

function TAVM2Runtime.ReadProperty(const Receiver: TAVM2Value; const Names: TArray<string>; ForCall: Boolean): TAVM2Value;
var
  AClass, Func, Prototype: TAVM2Object;
  Key: string;
  Method: TAVM2PrimitiveMethod;
begin
  if Receiver.Kind = a2Object then
  begin
    Result := PropertyValue(Receiver.Obj, Names);
    if (not ForCall) and (Result.Obj <> nil) and (Result.Obj.Kind = a2Function) then
      for Key in Names do
        if ((Receiver.Obj.RegExp <> nil) and
          ((Key = BuiltinNamespace + 'exec') or (Key = BuiltinNamespace + 'test')) and
          ((Result.Obj.Index = RegExpMethodBase) or (Result.Obj.Index = RegExpMethodBase - 1))) or
          ((Receiver.Obj.ArrayData <> nil) and
          (((Key = BuiltinNamespace + 'sort') and (Result.Obj = FArrayMethods[aaSort])) or
          ((Key = BuiltinNamespace + 'sortOn') and (Result.Obj = FArrayMethods[aaSortOn])))) then
        begin
          Func := NewObject(a2Function);
          Func.Index := Result.Obj.Index;
          Func.BoundReceiver := Receiver;
          Exit(TAVM2Value.Ref(Func));
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
      Match.Offsets[I] := {$IFDEF MSWINDOWS}Offsets[I]
      {$ELSE}
      Match.Offsets[I] := ByteOffsetToUTF16(Input,Offsets[I])
      {$ENDIF}
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

function TAVM2Runtime.CoerceText(const Value: TAVM2Value): string;
const
  Methods: array[0..1] of string = (#0 + 'toString', #0 + 'valueOf');
var
  Name: string;
  Method, Converted: TAVM2Value;
begin
  if Value.Obj <> nil then
    for Name in Methods do
    begin
      Method := PropertyValue(Value.Obj, [Name]);
      if (Method.Obj = nil) or (Method.Obj.Kind <> a2Function) then
        Continue;
      Converted := Invoke(Method.Obj, Value, nil);
      if Converted.Kind <> a2Object then
        Exit(AsText(Converted));
    end;
  Result := AsText(Value);
end;

function TAVM2Runtime.CoerceNumber(const Value: TAVM2Value): Double;
const
  ConversionNames: array[0..1] of string = (#0 + 'valueOf', #0 + 'toString');
var
  Key: string;
  Method, Converted: TAVM2Value;
begin
  if Value.Obj <> nil then
    for Key in ConversionNames do
    begin
      Method := PropertyValue(Value.Obj, [Key]);
      if (Method.Obj = nil) or (Method.Obj.Kind <> a2Function) then
        Continue;
      Converted := Invoke(Method.Obj, Value, nil);
      if Converted.Kind <> a2Object then
        Exit(AsNumber(Converted));
    end;
  Result := AsNumber(Value);
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
  Negative: Boolean;
begin
  if (Radix = 10) or IsNan(Number) or IsInfinite(Number) then
    Exit(AsText(TAVM2Value.Num(Number)));
  Move(Number, Bits, SizeOf(Bits));
  Negative := Bits shr 63 <> 0;
  Number := Abs(Number);
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
  if (AClass <> nil) and (AClass.PrimitiveKind in [atString..atUInt]) then
    Exit(ConvertPrimitive(AClass.PrimitiveKind, Args));
  Result := TAVM2Value.Ref(Construct(AClass, Args));
end;

function TAVM2Runtime.Construct(ClassObject: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Object;
var
  Value: TAVM2Value;
begin
  if (ClassObject = nil) or not (ClassObject.Kind in [a2Class, a2Function]) then
    RaiseScriptError('TypeError', 1007, 'Instantiation attempted on a non-constructor.');
  if ClassObject = FClassClass then
    RaiseScriptError('TypeError', 1115, 'Class$ is not a constructor.');
  if ClassObject.Kind = a2Function then
  begin
    if (ClassObject.BoundReceiver.Kind <> a2Undefined) or ((ClassObject.Module = nil) and
      (ClassObject.Index <> EmptyFunctionMethod)) then
      RaiseScriptError('TypeError', 1064, 'Cannot call a method as a constructor.');
    if ClassObject.FunctionPrototype = nil then
      ClassObject.FunctionPrototype := FObjectPrototype;
    Result := NewObject(a2PlainObject);
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
    Result := NewObject(a2Function);
    Result.Index := EmptyFunctionMethod;
    Result.DisplayName := 'Function';
    InitializeFunctionPrototype(Result);
    Exit;
  end;
  if (ClassObject.Index < 0) and (ClassObject.DisplayName = 'Object') and
    (Length(Args) > 0) and (Args[0].Kind = a2Object) then
    Exit(Args[0].Obj);
  Result := NewObject(a2PlainObject);
  Result.DisplayName := ClassObject.DisplayName;
  Result.ClassObject := ClassObject;
  Result.Parent := ClassPrototype(ClassObject);
  if ClassObject.CanDispatch then
    BindDispatcher(Result);
  BindDisplay(Result, ClassObject.DisplayKind, False);
  InstallInstanceTraits(ClassObject, Result);
  ConstructInto(ClassObject, Result, Args);
end;

procedure TAVM2Runtime.CreateDocument(const Name: string);
var
  KeyName: string;
  I: Integer;
  Script, Instance: TAVM2Object;
  Value: TAVM2Value;
begin
  if (Name = '') or (FDocument <> nil) then
    Exit;
  I := LastDelimiter('.', Name);
  if I = 0 then
    KeyName := #0 + Name
  else
    KeyName := Copy(Name, 1, I - 1) + #0 + Copy(Name, I + 1, MaxInt);
  if not FDefinitions.TryGetValue(KeyName, Script) then
    Exit;
  Initialize(Script);
  Value := PropertyValue(Script, [KeyName]);
  if (Value.Obj = nil) or (Value.Obj.Kind <> a2Class) then
    raise EAVM2Error.CreateFmt('Invalid AVM2 document class %s', [Name]);
  Instance := NewObject(a2PlainObject);
  Instance.Parent := ClassPrototype(Value.Obj);
  Instance.DisplayName := Value.Obj.DisplayName;
  if Value.Obj.CanDispatch then
    BindDispatcher(Instance);
  BindDisplay(Instance, Value.Obj.DisplayKind, True);
  if Instance.DisplayKind <> adNone then
  begin
    Instance.DisplayParent := FStage;
    Instance.Props.AddOrSetValue(#0 + 'parent', TAVM2Value.Ref(FStage));
  end;
  InstallInstanceTraits(Value.Obj, Instance);
  FDocument := Instance;
  ConstructInto(Value.Obj, Instance, nil);
end;

procedure TAVM2Runtime.RunFrameScript(Frame: Integer);
var
  Routine: TAVM2Object;
begin
  if (FDocument <> nil) and FFrameScripts.TryGetValue(Frame, Routine) then
    Invoke(Routine, FDocument, nil);
end;

function TAVM2Runtime.Invoke(FunctionObject, Receiver: TAVM2Object; const Args: TArray<TAVM2Value>): TAVM2Value;
begin
  Result := Invoke(FunctionObject, TAVM2Value.Ref(Receiver), Args);
end;

function TAVM2Runtime.Invoke(FunctionObject: TAVM2Object; Receiver: TAVM2Value; const Args: TArray<TAVM2Value>): TAVM2Value;
var
  I, Frame: Integer;
  FrameValue: Double;
  Routine, ThisObject: TAVM2Object;
  Line, Part: string;
begin
  Result := Default(TAVM2Value);
  if (FunctionObject = nil) or not (FunctionObject.Kind in [a2Function, a2Class]) then
    RaiseScriptError('TypeError', 1006, 'value is not a function.');
  if FunctionObject.Kind = a2Class then
  begin
    if FunctionObject.PrimitiveKind in [atString..atUInt] then
      Exit(ConvertPrimitive(FunctionObject.PrimitiveKind, Args));
    if (FunctionObject = FRegExpClass) and (Length(Args) = 1) and (Args[0].Obj <> nil) and
      (Args[0].Obj.RegExp <> nil) then
      Exit(Args[0]);
    if FunctionObject.NativeError or (FunctionObject = FArrayClass) or (FunctionObject = FFunctionClass) or
      (FunctionObject = FRegExpClass) then
      Exit(TAVM2Value.Ref(Construct(FunctionObject, Args)));
    raise EAVM2Error.Create('AVM2 class coercion is not implemented');
  end;
  if FunctionObject.BoundReceiver.Kind <> a2Undefined then
    Receiver := FunctionObject.BoundReceiver;
  ThisObject := Receiver.Obj;
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
  if FunctionObject.Index = TraceMethod then
  begin
    Line := '';
    for I := 0 to High(Args) do
    begin
      Part := AsText(Args[I]);
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
    if (ThisObject <> FDocument) or (ThisObject = nil) or Odd(Length(Args)) then
      raise EAVM2Error.Create('Invalid AVM2 addFrameScript arguments');
    I := 0;
    while I < Length(Args) do
    begin
      FrameValue := AsNumber(Args[I]);
      if IsNan(FrameValue) or (FrameValue < 0) or (FrameValue > 65534) then
        raise EAVM2Error.Create('Invalid AVM2 frame script index');
      Frame := Trunc(FrameValue);
      Routine := Args[I + 1].Obj;
      if Args[I + 1].Kind = a2Null then
        FFrameScripts.Remove(Frame)
      else
      begin
        if (Routine = nil) or (Routine.Kind <> a2Function) then
          raise EAVM2Error.Create('AVM2 frame script must be a function');
        FFrameScripts.AddOrSetValue(Frame, Routine);
      end;
      Inc(I, 2);
    end;
  end
  else if FunctionObject.Index <= ArrayMethodBase then
    Result := ArrayCall(TAVM2ArrayMethod(ArrayMethodBase - FunctionObject.Index), ThisObject, Args)
  else if FunctionObject.Index <= ByteArrayMethodBase then
    Result := ByteArrayCall(TAVM2ByteMethod(ByteArrayMethodBase - FunctionObject.Index), ThisObject, Args)
  else if FunctionObject.Index <= EventMethodBase then
    Result := EventCall(TAVM2EventMethod(EventMethodBase - FunctionObject.Index), ThisObject, Args)
  else if FunctionObject.Index <= DisplayMethodBase then
    Result := DisplayCall(TAVM2DisplayMethod(DisplayMethodBase - FunctionObject.Index), ThisObject, Args)
  else
  begin
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

  procedure MarkDestination(Target: Integer);
  begin
    if (Target < 0) or (Target >= Length(Result)) then
      raise EAVM2Error.Create('AVM2 branch target is outside the method');
    Result[Target] := Result[Target] or BranchDestination;
  end;

begin
  Code := Default(TABCReader);
  Code.Data := Body.Code;
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
      $02, $03, $09, $1C..$21, $23, $26..$2B, $30, $47, $48, $64, $70, $73..$76, $77, $81..$85, $88, $89, $90, $91, $93, $96, $97, $A0..$B1, $B4, $C5..$C7, $D0..$D7:
        ;
      $08, $25, $2C..$2F, $40..$42, $49, $55, $56, $58, $5D..$63, $66, $67, $68, $6A, $6C..$6F, $80, $86, $B2, $F0, $F1:
        Code.U30;
      $24, $65:
        Code.U8;
      $57:
        if not HasActivation then
          raise EAVM2Error.Create('AVM2 newactivation requires NEED_ACTIVATION');
      $5A:
        if Code.U30 >= Length(Body.Exceptions) then
          raise EAVM2Error.Create('AVM2 newcatch index outside exception table');
      $32, $46, $4A, $4C, $4F:
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
  for I := 0 to High(Result) do
    if Result[I] = BranchDestination then
      raise EAVM2Error.Create('AVM2 branch target is not an instruction boundary');
  for Handler in Body.Exceptions do
    if (Body.StackLimit = 0) or (Handler.First >= Length(Result)) or
      (Result[Handler.First] and InstructionStart = 0) or
      ((Handler.Last < Length(Result)) and (Result[Handler.Last] and InstructionStart = 0)) or
      (Result[Handler.Target] and InstructionStart = 0) then
      raise EAVM2Error.Create('AVM2 exception range or target is invalid');
end;

function TAVM2Runtime.Execute(Module: TAVM2Module; MethodIndex: Integer; const Receiver: TAVM2Value; Script, OwnerClass: TAVM2Object; const Outer, Args: TArray<TAVM2Value>; CurrentFunction: TAVM2Object): TAVM2Value;
var
  Body: TABCBody;
  Method: TABCMethod;
  Code: TABCReader;
  Stack, Locals, Parameters: TArray<TAVM2Value>;
  Scopes, Captured: TArray<TAVM2Value>;
  NamesToTry: TArray<string>;
  StackTop, ScopeTop, Op, Offset, N, I, Target: Integer;
  EnumIndex, LeftBits, RightBits: Cardinal;
  A, B: TAVM2Value;
  Obj, Callable: TAVM2Object;
  L, R: Double;
  Name: string;
  Branch: Boolean;
  Relation: TAVM2Relation;
  TypeKind: TAVM2TypeKind;
  TargetClass: TAVM2Object;
  TypeName: string;
  PreviousMask: TArithmeticExceptionMask;
  Handler: TABCException;

  procedure Push(const Value: TAVM2Value);
  begin
    if StackTop >= Length(Stack) then
      raise EAVM2Error.Create('AVM2 operand stack overflow');
    Stack[StackTop] := Value;
    Inc(StackTop);
  end;

  function Pop: TAVM2Value;
  begin
    if StackTop = 0 then
      raise EAVM2Error.Create('AVM2 operand stack underflow');
    Dec(StackTop);
    Result := Stack[StackTop];
    Stack[StackTop] := Default(TAVM2Value);
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

  function PropertyNames(Index: Integer; out RuntimeName: string): TArray<string>;
  var
    Field: TABCMultiname;
  begin
    if (Index <= 0) or (Index >= Length(Module.ABC.Multinames)) then
      raise EAVM2Error.Create('AVM2 multiname index outside pool');
    Field := Module.ABC.Multinames[Index];
    RuntimeName := '';
    if Field.Kind <> $1B then
      Exit(Names(Module, Index));
    RuntimeName := AsText(Pop);
    Result := NamespaceSetKeys(Module, Field.NamespaceSet, RuntimeName);
  end;

  function TakeParams(Count: Integer): TArray<TAVM2Value>;
  var
    J: Integer;
  begin
    if Count > StackTop then
      raise EAVM2Error.Create('AVM2 invalid argument count');
    SetLength(Result, Count);
    for J := Count - 1 downto 0 do
      Result[J] := Pop;
  end;

  function CheckedIndex(Count: Integer): Integer;
  begin
    Result := Code.U30;
    if Result >= Count then
      raise EAVM2Error.Create('AVM2 operand index out of bounds');
  end;

  function Capture: TArray<TAVM2Value>;
  begin
    Result := Outer + Copy(Scopes, 0, ScopeTop);
  end;

  procedure JumpTo(Destination: Integer);
  begin
    if (Destination < 0) or (Destination >= Length(Code.Data)) then
      raise EAVM2Error.Create('AVM2 branch target out of bounds');
    Code.Position := Destination;
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
  Method := Module.ABC.Methods[MethodIndex];
  if Method.Body < 0 then
    raise EAVM2Error.Create('AVM2 method has no executable body');
  Body := Module.ABC.Bodies[Method.Body];
  if Method.Flags and (NeedsArguments or NeedsRest) = (NeedsArguments or NeedsRest) then
    raise EAVM2Error.Create('Conflicting AVM2 variadic method flags');
  if (Body.LocalCount <= Length(Method.ParameterTypes) + Ord(Method.Flags and (NeedsArguments or NeedsRest) <> 0)) or
    (Body.StackLimit > 4096) or
    (Body.LocalCount > 4096) or (Body.ScopeLimit - Body.InitialScope > 1024) then
    raise EAVM2Error.Create('Invalid or excessive AVM2 method frame');
  if Module.Boundaries[Method.Body] = nil then
    Module.Boundaries[Method.Body] := ReadBoundaries(Body, Method.Flags and NeedsActivation <> 0);
  Code.Data := Body.Code;
  Code.Position := 0;
  SetLength(Stack, Body.StackLimit);
  SetLength(Locals, Body.LocalCount);
  SetLength(Scopes, Body.ScopeLimit - Body.InitialScope);
  StackTop := 0;
  ScopeTop := 0;
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
      AppendArray(Obj.ArrayData, Copy(Args, Length(Method.ParameterTypes), MaxInt))
    else
    begin
      AppendArray(Obj.ArrayData, Args);
      if CurrentFunction <> nil then
        StoreDynamicProperty(Obj, #0 + 'callee', TAVM2Value.Ref(CurrentFunction), False);
    end;
    Locals[Length(Method.ParameterTypes) + 1] := TAVM2Value.Ref(Obj);
  end;
  Inc(FDepth);
  PreviousMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    repeat
      try
        while Code.Remaining > 0 do
        begin
          Dec(FWork);
          if FWork < 0 then
            raise EAVM2Error.Create('AVM2 instruction limit');
          Offset := Code.Position;
          Op := Code.U8;
          case Op of
            $02, $09:
              ;
            $03:
              raise EAVM2Thrown.Create(Pop);
            $08:
              Locals[CheckedIndex(Length(Locals))] := Default(TAVM2Value);
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
                Target := Integer(IntBits(AsNumber(A)));
                B := Pop;
                if Op = $1F then
                begin
                  EnumIndex := 0;
                  if Target >= 0 then
                    EnumIndex := NextEnumerant(EnumerationObject(B), Cardinal(Target));
                  Push(TAVM2Value.Num(EnumIndex, a2UInt));
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
                  A := EnumerantName(Obj, Cardinal(Target));
                  if Op = $1E then
                    Push(A)
                  else
                    Push(PropertyValue(Obj, [#0 + AsText(A)]));
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
                Push(TAVM2Value.Num(N, a2Int));
              end;
            $25:
              begin
                N := Code.U30 and $FFFF;
                if N >= 32768 then
                  Dec(N, 65536);
                Push(TAVM2Value.Num(N, a2Int));
              end;
            $26, $27:
              Push(TAVM2Value.Num(Ord(Op = $26), a2Boolean));
            $28:
              Push(TAVM2Value.Num(NaN));
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
              Push(TAVM2Value.Num(Module.ABC.Ints[CheckedIndex(Length(Module.ABC.Ints))], a2Int));
            $2E:
              Push(TAVM2Value.Num(Module.ABC.UInts[CheckedIndex(Length(Module.ABC.UInts))], a2UInt));
            $2F:
              begin
                N := CheckedIndex(Length(Module.ABC.Doubles));
                if N = 0 then
                  Push(TAVM2Value.Num(NaN))
                else
                  Push(TAVM2Value.Num(Module.ABC.Doubles[N]));
              end;
            $1C, $30:
              begin
                if ScopeTop >= Length(Scopes) then
                  raise EAVM2Error.Create('AVM2 scope stack overflow');
                A := Pop;
                CheckNullReceiver(A);
                Scopes[ScopeTop] := A;
                Inc(ScopeTop);
              end;
            $32:
              begin
                N := CheckedIndex(Length(Locals));
                I := CheckedIndex(Length(Locals));
                Target := Integer(IntBits(AsNumber(Locals[I])));
                if Target < 0 then
                  Push(TAVM2Value.Num(0, a2Boolean))
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
                  Push(TAVM2Value.Num(Ord(EnumIndex <> 0), a2Boolean));
                end;
              end;
            $40:
              begin
                N := CheckedIndex(Length(Module.ABC.Methods));
                Callable := NewObject(a2Function);
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
            $46, $4C, $4F:
              begin
                N := Code.U30;
                Parameters := TakeParams(Code.U30);
                NamesToTry := PropertyNames(N, Name);
                B := Pop;
                CheckNullReceiver(B, N, Name);
                A := ReadProperty(B, NamesToTry, Op <> $4C);
                if Op = $4C then
                  B := TAVM2Value.Ref(nil);
                B := Invoke(A.Obj, B, Parameters);
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
            $55:
              begin
                N := Code.U30;
                if N > StackTop div 2 then
                  raise EAVM2Error.Create('AVM2 object literal stack underflow');
                Obj := NewObject(a2PlainObject);
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
                Obj := NewObject(a2PlainObject);
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
                Obj := NewObject(a2PlainObject);
                if Handler.VariableName <> 0 then
                begin
                  Name := TraitKey(Module, Handler.VariableName);
                  Obj.Props.Add(Name, Default(TAVM2Value));
                  Obj.Slots.Add(1, Name);
                end;
                Push(TAVM2Value.Ref(Obj));
              end;
            $5D, $5E, $5F, $60:
              begin
                N := Code.U30;
                Obj := Find(Module, N, Script, Scopes, Outer, ScopeTop, Op);
                if Op = $60 then
                  Push(PropertyValue(Obj, Names(Module, N)))
                else
                  Push(TAVM2Value.Ref(Obj));
              end;
            $61, $68:
              begin
                N := Code.U30;
                A := Pop;
                NamesToTry := PropertyNames(N, Name);
                if Length(NamesToTry) = 0 then
                  raise EAVM2Error.Create('Empty AVM2 property namespace set');
                B := Pop;
                CheckNullReceiver(B, N, Name);
                if B.Kind <> a2Object then
                  RejectPrimitiveWrite(B, NamesToTry, False)
                else
                  SetProperty(B.Obj, NamesToTry, A);
              end;
            $62:
              Push(Locals[CheckedIndex(Length(Locals))]);
            $63:
              begin
                N := CheckedIndex(Length(Locals));
                Locals[N] := Pop;
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
                NamesToTry := PropertyNames(N, Name);
                A := Pop;
                CheckNullReceiver(A, N, Name);
                Push(ReadProperty(A, NamesToTry, False));
              end;
            $67:
              Push(Outer[CheckedIndex(Length(Outer))]);
            $6A:
              begin
                N := Code.U30;
                NamesToTry := PropertyNames(N, Name);
                A := Pop;
                CheckNullReceiver(A, N, Name);
                if A.Kind <> a2Object then
                  RejectPrimitiveWrite(A, NamesToTry, True);
                Push(TAVM2Value.Num(Ord(DeleteProperty(A.Obj, NamesToTry)), a2Boolean));
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
                if not Obj.Slots.TryGetValue(N, Name) then
                  raise EAVM2Error.Create('Invalid AVM2 slot');
                if Op in [$6D, $6F] then
                  StoreSlot(Obj, Name, A)
                else
                  Push(PropertyValue(Obj, [Name]));
              end;
            $70:
              Push(TAVM2Value.Str(AsText(Pop)));
            $73, $83:
              Push(TAVM2Value.Num(Integer(IntBits(AsNumber(Pop))), a2Int));
            $74, $88:
              Push(TAVM2Value.Num(IntBits(AsNumber(Pop)), a2UInt));
            $75, $84:
              Push(TAVM2Value.Num(AsNumber(Pop)));
            $76, $81:
              Push(TAVM2Value.Num(Ord(Truth(Pop)), a2Boolean));
            $77:
              begin
                A := Pop;
                CheckNullReceiver(A);
                Push(A);
              end;
            $80, $86, $B2:
              begin
                N := Code.U30;
                A := Pop;
                TypeKind := ResolveType(Module, N, TargetClass, TypeName);
                if Op = $80 then
                  Push(CoerceValue(A, TypeKind, TargetClass, TypeName))
                else if Op = $B2 then
                  Push(TAVM2Value.Num(Ord(ValueHasType(A, TypeKind, TargetClass)), a2Boolean))
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
                  Push(TAVM2Value.Str(AsText(A)));
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
              Push(TAVM2Value.Num(-AsNumber(Pop)));
            $91:
              Push(TAVM2Value.Num(AsNumber(Pop) + 1));
            $93:
              Push(TAVM2Value.Num(AsNumber(Pop) - 1));
            $96:
              Push(TAVM2Value.Num(Ord(not Truth(Pop)), a2Boolean));
            $97:
              Push(TAVM2Value.Num(Integer(not IntBits(CoerceNumber(Pop))), a2Int));
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
                  Push(TAVM2Value.Num(LeftBits, a2UInt))
                else
                  Push(TAVM2Value.Num(Integer(LeftBits), a2Int));
              end;
            $A0..$A4, $AB, $AC, $C5..$C7:
              begin
                B := Pop;
                A := Pop;
                if (Op = $A0) and ((A.Kind = a2String) or (B.Kind = a2String)) then
                begin
                  Name := AsText(A);
                  B.Text := AsText(B);
                  if Length(Name) > TextLimit - Length(B.Text) then
                    raise EAVM2Error.Create('AVM2 string size limit');
                  Push(TAVM2Value.Str(Name + B.Text));
                end
                else if Op in [$AB, $AC] then
                  Push(TAVM2Value.Num(Ord(Equal(A, B, Op = $AC)), a2Boolean))
                else
                begin
                  L := AsNumber(A);
                  R := AsNumber(B);
                  case Op of
                    $A0:
                      Push(TAVM2Value.Num(L + R));
                    $A1:
                      Push(TAVM2Value.Num(L - R));
                    $A2:
                      Push(TAVM2Value.Num(L * R));
                    $A3:
                      Push(TAVM2Value.Num(L / R));
                    $A4:
                      Push(TAVM2Value.Num(FMod(L, R)));
                    $C5:
                      Push(TAVM2Value.Num(Integer(Cardinal(UInt64(IntBits(L)) + IntBits(R))), a2Int));
                    $C6:
                      Push(TAVM2Value.Num(Integer(Cardinal(UInt64(IntBits(L)) + UInt64($100000000) - IntBits(R))), a2Int));
                    $C7:
                      Push(TAVM2Value.Num(Integer(Cardinal(UInt64(IntBits(L)) * IntBits(R))), a2Int));
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
                Push(TAVM2Value.Num(Ord(Branch), a2Boolean));
              end;
            $B1:
              begin
                B := Pop;
                A := Pop;
                Push(TAVM2Value.Num(Ord(IsInstanceOf(A, B.Obj)), a2Boolean));
              end;
            $B4:
              begin
                A := Pop;
                CheckNullReceiver(A);
                Name := #0 + AsText(Pop);
                if A.Kind = a2Object then
                  Branch := HasProperty(A.Obj, Name)
                else
                  Branch := ((A.Kind = a2String) and (Name = #0 + 'length')) or
                    HasProperty(ValuePrototype(A), Name);
                Push(TAVM2Value.Num(Ord(Branch), a2Boolean));
              end;
            $D0..$D7:
              begin
                N := Op and 3;
                if N >= Length(Locals) then
                  raise EAVM2Error.Create('Invalid AVM2 local register');
                if Op < $D4 then
                  Push(Locals[N])
                else
                  Locals[N] := Pop;
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
    ClearExceptions;
    SetExceptionMask(PreviousMask);
    Dec(FDepth);
  end;
end;

end.

