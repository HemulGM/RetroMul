unit AVM1.Runtime;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, SWF.Reader,
  Media.Image.PixelBuffer;

type
  TAVMObject = class;

  IAVMColorData = interface
    ['{D8F18B6B-18D4-4C47-8819-D8EDB1C62C1D}']
    function GetValue(Index: Integer): Double;
    procedure SetValue(Index: Integer; Value: Double);
    property Values[Index: Integer]: Double read GetValue write SetValue; default;
  end;

  TAVMColorData = class(TInterfacedObject, IAVMColorData)
  private
    FValues: array[0..7] of Double;
  public
    function GetValue(Index: Integer): Double;
    procedure SetValue(Index: Integer; Value: Double);
  end;

  TAVMKind = (avUndefined, avNull, avNumber, avBoolean, avString, avObject);

  TAVMValue = record
    Kind: TAVMKind;
    Number: Double;
    Text: string;
    Obj: TAVMObject;
    class function Num(N: Double): TAVMValue; static;
    class function Bool(B: Boolean): TAVMValue; static;
    class function Str(const S: string): TAVMValue; static;
    class function Ref(O: TAVMObject): TAVMValue; static;
    function AsNumber(SWFVersion: Byte = 7): Double;
    function AsBoolean(SWFVersion: Byte = 7): Boolean;
    function AsString(SWFVersion: Byte = 7): string;
  end;

  TAVMParam = record
    Name: string;
    RegisterIndex: Byte;
  end;

  TAVMTextFormatData = class
  public
    Values: array[0..18] of TAVMValue;
    TabStops: TArray<Double>;
    constructor Create;
    function Clone: TAVMTextFormatData;
    function Matches(Other: TAVMTextFormatData): Boolean;
  end;

  EAVMValueException = class(Exception)
  public
    Value: TAVMValue;
    constructor CreateValue(const AValue: TAVMValue; const MessageText: string);
  end;

  EAVMThrown = class(EAVMValueException);

  TAVMAccessor = record
    Getter, Setter: TAVMObject;
  end;

  TAVMWatcher = record
    Callback: TAVMObject;
    UserData: TAVMValue;
  end;

  TAVMPropertyCall = record
    Owner: TAVMObject;
    PropertyID: Integer;
  end;

  TAVMEventMember = (emOther, emButton, emMouseMove, emEnterFrame, emResolve);

  TAVMEventMembers = set of emButton..emResolve;

  TAVMObject = class
  private
    FNextPropertyID: Integer;
    FEventMemberCount: array[emButton..emResolve] of Integer;
    FPrototype: TAVMObject;
    procedure UpdateEventMember(const FoldedName: string; Delta: Integer);
    procedure SetPrototype(Value: TAVMObject);
  public
    Members: TDictionary<string, TAVMValue>;
    Interfaces: TArray<TAVMObject>;
    InterfacesDeclared: Boolean;
    MemberOrder: TList<string>;
    Attributes: TDictionary<string, Word>;
    CaseNames: TDictionary<string, string>;
    Accessors: TDictionary<string, TAVMAccessor>;
    PropertyIDs: TDictionary<string, Integer>;
    Watchers: TDictionary<string, TAVMWatcher>;
    WatchOrder: TList<string>;
    WatchCaseNames: TDictionary<string, string>;
    Scope, Target, WithObject, MovieRoot: TAVMObject;
    MovieVersion: Byte;
    MovieContext: TObject;
    SuperThis: TAVMObject;
    SuperDepth: Integer;
    ClassName, Native: string;
    Code: TBytes;
    Pool: TArray<string>;
    Params: TArray<TAVMParam>;
    Flags, RegisterCount: Integer;
    IsFunction: Boolean;
    IsBoxed: Boolean;
    IsDate: Boolean;
    DateValue: Double;
    ColorData: IAVMColorData;
    BitmapData: IImagePixelBuffer;
    TextFormatData: TAVMTextFormatData;
    IsTransform: Boolean;
    TransformTarget: TAVMObject;
    TransformPath: string;
    PrimitiveValue: TAVMValue;
    Marked: Boolean;
    HostData: TObject;
    OwnedNativeData: TObject;
    constructor Create;
    destructor Destroy; override;
    procedure StoreData(const Name: string; const Value: TAVMValue);
    procedure RemoveData(const Name: string);
    procedure ClearMembers;
    property Prototype: TAVMObject read FPrototype write SetPrototype;
  end;

  TAVMBitmapBlend = (bbNormal, bbLayer, bbMultiply, bbScreen, bbLighten,
    bbDarken, bbDifference, bbAdd, bbSubtract, bbInvert, bbAlpha, bbErase,
    bbOverlay, bbHardLight);

  TAVMBitmapDrawOptions = record
    Matrix: TSWFMatrix;
    ColorTransform: TSWFColorTransform;
    ClipRect: TSWFRect;
    Blend: TAVMBitmapBlend;
    HasClip, Smooth: Boolean;
  end;

  TAVMHost = class
  public
    function GetMember(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean; virtual;
    function GetStoredMember(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean; virtual;
    function SetMember(O: TAVMObject; const Name: string; const Value: TAVMValue): Boolean; virtual;
    function CallNative(const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue; virtual;
    function StringValue(O: TAVMObject; out Text: string): Boolean; virtual;
    function ObjectType(O: TAVMObject): string; virtual;
    function LevelObject(Index: Integer): TAVMObject; virtual;
    function UtcNowMilliseconds: Double; virtual;
    function DateTimezoneOffset(Time: Double; IsUTC: Boolean): Integer; virtual;
    function ColorTarget(const Value: TAVMValue): TAVMObject; virtual;
    procedure MarkColorTarget(O: TAVMObject); virtual;
    function ReadColorTransform(O: TAVMObject; out Value: TSWFColorTransform): Boolean; virtual;
    procedure WriteColorTransform(O: TAVMObject; const Value: TSWFColorTransform); virtual;
    function BindTransformReference(O: TAVMObject; out Path: string): TAVMObject; virtual;
    function ResolveTransformReference(var O: TAVMObject; const Path: string): TAVMObject; virtual;
    function DisplayParent(O: TAVMObject): TAVMObject; virtual;
    function ReadDisplayMatrix(O: TAVMObject; out Value: TSWFMatrix): Boolean; virtual;
    procedure WriteDisplayMatrix(O: TAVMObject; const Value: TSWFMatrix); virtual;
    function DisplayBounds(O: TAVMObject; out Bounds: TSWFRect): Boolean; virtual;
    function ReadLibraryBitmap(const Name: string): IImagePixelBuffer; virtual;
    function DrawBitmapData(const Target: IImagePixelBuffer; const Source: TAVMValue; const Options: TAVMBitmapDrawOptions): Integer; virtual;
    procedure ApplyBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter); virtual;
    function BitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect; virtual;
    function ActionGetProperty(Start: TAVMObject; const Path, Index: TAVMValue; out Value: TAVMValue): Boolean; virtual;
    function ActionSetProperty(Start: TAVMObject; const Path, Index, Value: TAVMValue): Boolean; virtual;
    function ResolveDragTarget(Start: TAVMObject; const Value: TAVMValue): TAVMObject; virtual;
    procedure StartDrag(Target: TAVMObject; LockCenter: Boolean; const Bounds: TArray<Double>); virtual;
    procedure StopDrag; virtual;
    procedure StopSounds; virtual;
    procedure ToggleQuality; virtual;
    function ResolveTimelineTarget(Start: TAVMObject; const Path: string): TAVMObject; virtual;
    procedure Timeline(Target: TAVMObject; const Command: string; const Value: TAVMValue); virtual;
    procedure CallFrame(Target: TAVMObject; const Value: TAVMValue; Stack: TList<TAVMValue>; const Pool: TArray<string>); virtual;
    procedure VisitRoots(const Visit: TProc<TAVMObject>); virtual;
    procedure VisitObjectReferences(O: TAVMObject; const Visit: TProc<TAVMObject>); virtual;
    procedure SweepUnreachable; virtual;
  end;

  TAVMPendingCall = record
    Target: TAVMObject;
    MethodName: string;
    Args: TArray<TAVMValue>;
    IsCurrent: TFunc<Boolean>;
  end;

  TAVMTimer = record
    Callback: TAVMValue;
    ThisObj: TAVMObject;
    Args: TArray<TAVMValue>;
    Deadline, Interval: Double;
  end;

  TAVM1 = class
  private
    FObjects: TObjectList<TAVMObject>;
    FPropertyCalls: TList<TAVMPropertyCall>;
    FHost: TAVMHost;
    FDepth, FBlockDepth, FBudget: Integer;
    FTraceLimit: Integer;
    FRNG: Cardinal;
    FSWFVersion: Byte;
    FRegisteredClasses: array[0..1] of TAVMObject;
    FObjectPrototype, FDatePrototype, FColorPrototype: TAVMObject;
    FGeometryPrototypes: TArray<TAVMObject>;
    FTransformPrototype: TAVMObject;
    FTextFormatPrototype: TAVMObject;
    FBitmapDataPrototype: TAVMObject;
    FPixelPool: IImagePixelPool;
    FFunctionPrototype, FArrayPrototype: TAVMObject;
    FStringPrototype, FNumberPrototype, FBooleanPrototype, FMovieClipPrototype, FButtonPrototype: TAVMObject;
    FTimers: TDictionary<Integer, TAVMTimer>;
    FNextTimer: Integer;
    FCallee: TAVMObject;
    FPending: TList<TAVMPendingCall>;
    FShared: TDictionary<string, TAVMObject>;
    procedure SetTraceLimit(Value: Integer);
    function CreateArguments(const Fn: TAVMValue; const Args: TArray<TAVMValue>): TAVMObject;
    function CallNativeFunction(F, ThisObj: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;
    function PropertyCallCount(O: TAVMObject; const Name: string): Integer;
    function CallProperty(O: TAVMObject; const Name: string; Callback, Receiver: TAVMObject; const Args: TArray<TAVMValue>; out Value: TAVMValue): Boolean;
    function FindWatcherKey(O: TAVMObject; const Name: string; out Key: string): Boolean;
    function Watch(O: TAVMObject; const Name: string; Callback: TAVMObject; const UserData: TAVMValue): Boolean;
    function Unwatch(O: TAVMObject; const Name: string): Boolean;
    function GetStored(O: TAVMObject; const Name: string): TAVMValue;
    procedure ApplyWatcher(O: TAVMObject; const Name: string; var Value: TAVMValue);
    procedure PutValue(O: TAVMObject; const Name: string; const Value: TAVMValue);
    procedure TrimArray(O: TAVMObject; NewLength: Integer);
    procedure ExecuteStartDrag(Stack: TList<TAVMValue>; Target: TAVMObject);
    function Execute(const Code: TBytes; Target, ThisObj, Scope: TAVMObject; const Pool: TArray<string>; var Registers: TArray<TAVMValue>; SharedStack: TList<TAVMValue> = nil): TAVMValue;
    function FindVariable(const Name: string; Scope, Target: TAVMObject): TAVMValue;
    function DeleteVariable(const Name: string; Scope, Target: TAVMObject): Boolean;
    procedure SetVariable(const Name: string; Scope, Target: TAVMObject; const Value: TAVMValue);
  public
    Global, Root, Level0, CurrentTarget: TAVMObject;
    MovieContext: TObject;
    Trace: TStringList;
    Milliseconds: Int64;
    constructor Create(Host: TAVMHost);
    destructor Destroy; override;
    function NewObject(const ClassName: string = 'Object'): TAVMObject;
    function NativeFunction(const Name: string): TAVMValue;
    function Get(O: TAVMObject; const Name: string): TAVMValue;
    function GetBoundVariable(Target: TAVMObject; const Name: string): TAVMValue;
    function TryGet(O: TAVMObject; const Name: string; out Value: TAVMValue; Resolve: Boolean = True): Boolean;
    function GetSpecial(O: TAVMObject; const Name: string): TAVMValue;
    function MayHaveEventMember(O: TAVMObject; Events: TAVMEventMembers): Boolean;
    function GetData(O: TAVMObject; const Name: string): TAVMValue;
    function GetOwnStored(O: TAVMObject; const Name: string): TAVMValue;
    function TryGetOwnStored(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean;
    procedure PutData(O: TAVMObject; const Name: string; const Value: TAVMValue);
    procedure SetArrayLength(O: TAVMObject; NewLength: Integer);
    function CreateArray(const Values: TArray<TAVMValue>): TAVMObject;
    function CreatePixelBuffer(Width, Height: Integer; Transparent: Boolean; Color: Cardinal): IImagePixelBuffer;
    function ReadLibraryBitmap(const Name: string): IImagePixelBuffer;
    function DrawBitmapData(const Target: IImagePixelBuffer; const Source: TAVMValue; const Options: TAVMBitmapDrawOptions): Integer;
    procedure ApplyBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter);
    function BitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect;
    procedure ChargeWork(Count: Integer);
    function FindOwnKey(O: TAVMObject; const Name: string; out Key: string; IgnoreCase: Boolean = False): Boolean;
    function HasProperty(O: TAVMObject; const Name: string): Boolean;
    function HasOwnProperty(O: TAVMObject; const Name: string): Boolean;
    function AddProperty(O: TAVMObject; const Name: string; Getter, Setter: TAVMObject): Boolean;
    procedure Put(O: TAVMObject; const Name: string; const Value: TAVMValue);
    function Call(const Fn: TAVMValue; ThisObj: TAVMObject; const Args: TArray<TAVMValue>; PrototypeDepth: Integer = 1; ConstructorCall: Boolean = False): TAVMValue;
    function SuperBase(O: TAVMObject): TAVMObject;
    function MethodDepth(O: TAVMObject; const Name: string): Integer;
    procedure InitializePrimitive(O: TAVMObject; const Name: string; const Args: TArray<TAVMValue>);
    procedure Run(const Code: TBytes; Target: TAVMObject; Stack: TList<TAVMValue> = nil; const Pool: TArray<string> = nil);
    procedure BeginTick;
    function UtcNowMilliseconds: Double;
    function DateTimezoneOffset(Time: Double; IsUTC: Boolean): Integer;
    function ColorTarget(const Value: TAVMValue): TAVMObject;
    procedure MarkColorTarget(O: TAVMObject);
    function ReadColorTransform(O: TAVMObject; out Value: TSWFColorTransform): Boolean;
    procedure WriteColorTransform(O: TAVMObject; const Value: TSWFColorTransform);
    function BindTransformReference(O: TAVMObject; out Path: string): TAVMObject;
    function ResolveTransformReference(var O: TAVMObject; const Path: string): TAVMObject;
    function DisplayParent(O: TAVMObject): TAVMObject;
    function ReadDisplayMatrix(O: TAVMObject; out Value: TSWFMatrix): Boolean;
    procedure WriteDisplayMatrix(O: TAVMObject; const Value: TSWFMatrix);
    function DisplayBounds(O: TAVMObject; out Bounds: TSWFRect): Boolean;
    procedure RunTimers;
    procedure QueueEvent(Target: TAVMObject; const MethodName: string; const Args: TArray<TAVMValue>; const IsCurrent: TFunc<Boolean> = nil);
    function Box(const Value: TAVMValue): TAVMObject;
    function Construct(const Fn: TAVMValue; const Args: TArray<TAVMValue>): TAVMValue;
    procedure ConstructOnExisting(const Fn: TAVMValue; O: TAVMObject; const Args: TArray<TAVMValue>);
    procedure RegisterClass(const Name: string; ConstructorObject: TAVMObject);
    function RegisteredClass(const Name: string): TAVMObject;
    function InstanceOf(const Value, ConstructorValue: TAVMValue): Boolean;
    procedure Collect;
    function RandomNumber: Double;
    function CoerceNumber(const Value: TAVMValue): Double;
    function CoerceString(const Value: TAVMValue): string;
    function ToPrimitiveNumber(const Value: TAVMValue): TAVMValue;
    function EqualValues(const Left, Right: TAVMValue; strict: Boolean): Boolean;
    function LessThan(const Left, Right: TAVMValue): TAVMValue;
    function AddValues(const Left, Right: TAVMValue): TAVMValue;
    function Enumerate(O: TAVMObject): TArray<string>;
    function DeleteMember(O: TAVMObject; const Name: string): Boolean;
    property SWFVersion: Byte read FSWFVersion write FSWFVersion;
    property TraceLimit: Integer read FTraceLimit write SetTraceLimit;
  end;

function AVMBlendName(Mode: TAVMBitmapBlend): string;

function TryAVMBlendCode(Code: Integer; out Mode: TAVMBitmapBlend): Boolean;

function TryAVMBlend(const Value: TAVMValue; out Mode: TAVMBitmapBlend): Boolean;

implementation

uses
  System.Math, System.StrUtils, AVM1.Coercion, AVM1.Numeric, AVM1.Names,
  AVM1.Arrays, AVM1.Strings, AVM1.Dates, AVM1.Colors, AVM1.Geometry,
  AVM1.Transforms, AVM1.Broadcaster, AVM1.TextFormat, AVM1.BitmapData,
  AVM1.Filters, System.DateUtils, System.TimeSpan;

type
  EAVMReturn = class(EAVMValueException);

constructor EAVMValueException.CreateValue(const AValue: TAVMValue; const MessageText: string);
begin
  inherited Create(MessageText);
  Value := AValue;
end;

const
  AVMBlendNames: array[TAVMBitmapBlend] of string = ('normal', 'layer', 'multiply',
    'screen', 'lighten', 'darken', 'difference', 'add', 'subtract', 'invert', 'alpha',
    'erase', 'overlay', 'hardlight');

function AVMBlendName(Mode: TAVMBitmapBlend): string;
begin
  Result := AVMBlendNames[Mode];
end;

function TryAVMBlendCode(Code: Integer; out Mode: TAVMBitmapBlend): Boolean;
begin
  Mode := bbNormal;
  Result := (Code >= 0) and (Code <= Ord(High(TAVMBitmapBlend)) + 1);
  if Result and (Code >= 2) then
    Mode := TAVMBitmapBlend(Code - 1);
end;

function TryAVMBlend(const Value: TAVMValue; out Mode: TAVMBitmapBlend): Boolean;
var
  Match: TAVMBitmapBlend;
begin
  Mode := bbNormal;
  case Value.Kind of
    avUndefined, avNull:
      Exit(True);
    avNumber:
      Exit(TryAVMBlendCode(AVMToInt32(Value.Number) and $FF, Mode));
    avString:
      for Match := Low(TAVMBitmapBlend) to High(TAVMBitmapBlend) do
        if Value.Text = AVMBlendNames[Match] then
        begin
          Mode := Match;
          Exit(True);
        end;
  end;
  Result := False;
end;

function TAVMColorData.GetValue(Index: Integer): Double;
begin
  Result := FValues[Index];
end;

procedure TAVMColorData.SetValue(Index: Integer; Value: Double);
begin
  FValues[Index] := Value;
end;

class function TAVMValue.Num(N: Double): TAVMValue;
begin
  Result := Default(TAVMValue);
  Result.Kind := avNumber;
  Result.Number := N;
end;

class function TAVMValue.Bool(B: Boolean): TAVMValue;
begin
  Result := Num(Ord(B));
  Result.Kind := avBoolean;
end;

class function TAVMValue.Str(const S: string): TAVMValue;
begin
  Result := Default(TAVMValue);
  Result.Kind := avString;
  Result.Text := S;
end;

class function TAVMValue.Ref(O: TAVMObject): TAVMValue;
begin
  Result := Default(TAVMValue);
  Result.Kind := avObject;
  Result.Obj := O;
  if O = nil then
    Result.Kind := avNull;
end;

function TAVMValue.AsNumber(SWFVersion: Byte): Double;
begin
  case Kind of
    avNumber, avBoolean:
      Result := Number;
    avString:
      Result := AVMStringToNumber(Text, SWFVersion);
    avUndefined, avNull:
      if SWFVersion < 7 then
        Result := 0
      else
        Result := NaN;
    avObject:
      if SWFVersion < 5 then
        Result := 0
      else
        Result := NaN;
  else
    Result := NaN;
  end;
end;

function TAVMValue.AsBoolean(SWFVersion: Byte): Boolean;
var
  NumericValue: Double;
begin
  case Kind of
    avNumber, avBoolean:
      Result := (Number <> 0) and not IsNan(Number);
    avString:
      if SWFVersion >= 7 then
        Result := Text <> ''
      else
      begin
        NumericValue := AVMStringToNumber(Text, SWFVersion);
        Result := not IsNan(NumericValue) and (NumericValue <> 0);
      end;
    avObject:
      Result := Obj <> nil;
  else
    Result := False;
  end;
end;

function TAVMValue.AsString(SWFVersion: Byte): string;
begin
  case Kind of
    avUndefined:
      if SWFVersion < 7 then
        Result := ''
      else
        Result := 'undefined';
    avNull:
      Result := 'null';
    avBoolean:
      if SWFVersion < 5 then
        Result := IntToStr(Ord(Number <> 0))
      else if Number <> 0 then
        Result := 'true'
      else
        Result := 'false';
    avNumber:
      Result := AVMNumberToString(Number);
    avString:
      Result := Text;
    avObject:
      if (Obj <> nil) and Obj.IsFunction then
        Result := '[type Function]'
      else
        Result := '[object Object]';
  end;
end;

function TAVM1.CoerceNumber(const Value: TAVMValue): Double;
var
  Primitive: TAVMValue;
begin
  Primitive := ToPrimitiveNumber(Value);
  Result := Primitive.AsNumber(FSWFVersion);
end;

function TAVM1.ToPrimitiveNumber(const Value: TAVMValue): TAVMValue;
var
  Method: TAVMValue;
begin
  Result := Value;
  if (Value.Kind = avObject) and (Value.Obj <> nil) then
  begin
    Method := GetSpecial(Value.Obj, 'valueOf');
    Result := Call(Method, Value.Obj, nil);
  end;
end;

function TAVM1.EqualValues(const Left, Right: TAVMValue; strict: Boolean): Boolean;
var
  A, B, Primitive: TAVMValue;
begin
  A := Left;
  B := Right;
  if strict then
  begin
    if A.Kind <> B.Kind then
      Exit(False);
    case A.Kind of
      avUndefined, avNull:
        Exit(True);
      avBoolean:
        Exit(A.Number = B.Number);
      avNumber:
        Exit((A.Number = B.Number) or (IsNan(A.Number) and IsNan(B.Number)));
      avString:
        Exit(A.Text = B.Text);
      avObject:
        Exit(A.Obj = B.Obj);
    end;
  end;
  { SWF5 evaluates valueOf on the right operand before the left operand,
    including comparisons of two objects. }
  if FSWFVersion <= 5 then
  begin
    B := ToPrimitiveNumber(B);
    A := ToPrimitiveNumber(A);
  end;
  if (A.Kind in [avNull, avUndefined]) and (B.Kind in [avNull, avUndefined]) then
    Exit(True);
  if A.Kind = B.Kind then
    case A.Kind of
      avBoolean:
        Exit(A.Number = B.Number);
      avNumber:
        Exit((A.Number = B.Number) or (IsNan(A.Number) and IsNan(B.Number)));
      avString:
        Exit(A.Text = B.Text);
      avObject:
        Exit(A.Obj = B.Obj);
    end;
  if A.Kind = avBoolean then
    Exit(EqualValues(TAVMValue.Num(A.Number), B, False));
  if B.Kind = avBoolean then
    Exit(EqualValues(A, TAVMValue.Num(B.Number), False));
  if (A.Kind = avNumber) and (B.Kind = avString) then
    Exit(A.Number = B.AsNumber(FSWFVersion));
  if (B.Kind = avNumber) and (A.Kind = avString) then
    Exit(B.Number = A.AsNumber(FSWFVersion));
  if A.Kind = avObject then
  begin
    Primitive := ToPrimitiveNumber(A);
    Exit((Primitive.Kind <> avObject) and EqualValues(Primitive, B, False));
  end;
  if B.Kind = avObject then
  begin
    Primitive := ToPrimitiveNumber(B);
    Exit((Primitive.Kind <> avObject) and EqualValues(A, Primitive, False));
  end;
  Result := False;
end;

function TAVM1.CoerceString(const Value: TAVMValue): string;
var
  Method, Primitive: TAVMValue;
begin
  if (Value.Kind = avObject) and (Value.Obj <> nil) then
  begin
    if Value.Obj.IsBoxed and (Value.Obj.PrimitiveValue.Kind = avString) then
      Exit(Value.Obj.PrimitiveValue.Text);
    if FHost.StringValue(Value.Obj, Result) then
      Exit;
    Method := GetSpecial(Value.Obj, 'toString');
    Primitive := Call(Method, Value.Obj, nil);
    if Primitive.Kind = avString then
      Exit(Primitive.Text);
    if Value.Obj.IsFunction then
      Exit('[type Function]');
    Exit('[type Object]');
  end;
  Result := Value.AsString(FSWFVersion);
end;

function TAVM1.AddValues(const Left, Right: TAVMValue): TAVMValue;
var
  A, B: TAVMValue;
  X, Y: Double;
  LeftText, RightText: string;

  function Primitive(const Value: TAVMValue): TAVMValue;
  begin
    if (FSWFVersion > 5) and (Value.Obj <> nil) and Value.Obj.IsDate then
      Result := Call(GetSpecial(Value.Obj, 'toString'), Value.Obj, [])
    else
      Result := ToPrimitiveNumber(Value);
    if Result.Kind = avObject then
      Result := Value;
  end;

begin
  B := Primitive(Right);
  if B.Kind = avObject then
    B := Right;
  A := Primitive(Left);
  if A.Kind = avObject then
    A := Left;
  if (A.Kind = avString) or (B.Kind = avString) then
  begin
    LeftText := CoerceString(A);
    RightText := CoerceString(B);
    Result := TAVMValue.Str(LeftText + RightText);
  end
  else
  begin
    X := CoerceNumber(A);
    Y := CoerceNumber(B);
    Result := TAVMValue.Num(AVMBinaryNumber($0A, X, Y));
  end;
end;

function TAVM1.LessThan(const Left, Right: TAVMValue): TAVMValue;
var
  A, B: TAVMValue;
  X, Y: Double;
begin
  A := ToPrimitiveNumber(Left);
  if A.Kind = avObject then
    Exit(TAVMValue.Bool(False));
  B := ToPrimitiveNumber(Right);
  if B.Kind = avObject then
    Exit(TAVMValue.Bool(False));
  if (A.Kind = avString) and (B.Kind = avString) then
    Exit(TAVMValue.Bool(A.Text < B.Text));
  X := A.AsNumber(FSWFVersion);
  Y := B.AsNumber(FSWFVersion);
  if IsNan(X) or IsNan(Y) then
    Exit(Default(TAVMValue));
  Result := TAVMValue.Bool(X < Y);
end;

constructor TAVMTextFormatData.Create;
var
  I: Integer;
begin
  inherited Create;
  for I := 0 to High(Values) do
    Values[I] := TAVMValue.Ref(nil);
  Values[16] := TAVMValue.Str('block');
end;

function TAVMTextFormatData.Clone: TAVMTextFormatData;
var
  I: Integer;
begin
  Result := TAVMTextFormatData.Create;
  for I := 0 to High(Values) do
    Result.Values[I] := Values[I];
  Result.TabStops := Copy(TabStops);
end;

function TAVMTextFormatData.Matches(Other: TAVMTextFormatData): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Other = nil then
    Exit;
  for I := 0 to High(Values) do
  begin
    if Values[I].Kind <> Other.Values[I].Kind then
      Exit;
    case Values[I].Kind of
      avNumber, avBoolean:
        if Values[I].Number <> Other.Values[I].Number then
          Exit;
      avString:
        if Values[I].Text <> Other.Values[I].Text then
          Exit;
    end;
  end;
  if Length(TabStops) <> Length(Other.TabStops) then
    Exit;
  for I := 0 to High(TabStops) do
    if TabStops[I] <> Other.TabStops[I] then
      Exit;
  Result := True;
end;

constructor TAVMObject.Create;
begin
  inherited;
  Members := TDictionary<string, TAVMValue>.Create;
  MemberOrder := TList<string>.Create;
  Attributes := TDictionary<string, Word>.Create;
  CaseNames := TDictionary<string, string>.Create;
  PropertyIDs := TDictionary<string, Integer>.Create;
end;

destructor TAVMObject.Destroy;
begin
  OwnedNativeData.Free;
  TextFormatData.Free;
  WatchCaseNames.Free;
  WatchOrder.Free;
  Watchers.Free;
  PropertyIDs.Free;
  Accessors.Free;
  CaseNames.Free;
  Attributes.Free;
  MemberOrder.Free;
  Members.Free;
  inherited;
end;

function EventMemberKind(const FoldedName: string): TAVMEventMember;
begin
  if FoldedName = '__resolve' then
    Exit(emResolve);
  if not FoldedName.StartsWith('on') then
    Exit(emOther);
  if FoldedName = 'onmousemove' then
    Exit(emMouseMove);
  if FoldedName = 'onenterframe' then
    Exit(emEnterFrame);
  if (FoldedName = 'onpress') or (FoldedName = 'onrelease') or (FoldedName = 'onreleaseoutside') or
    (FoldedName = 'onrollover') or (FoldedName = 'onrollout') or (FoldedName = 'ondragover') or (FoldedName = 'ondragout') then
    Exit(emButton);
  Result := emOther;
end;

procedure TAVMObject.UpdateEventMember(const FoldedName: string; Delta: Integer);
var
  Event: TAVMEventMember;
begin
  Event := EventMemberKind(FoldedName);
  if Event <> emOther then
    Inc(FEventMemberCount[Event], Delta);
end;

procedure TAVMObject.StoreData(const Name: string; const Value: TAVMValue);
var
  Folded: string;
begin
  Folded := AVMLowerName(Name);
  if not Members.ContainsKey(Name) then
  begin
    UpdateEventMember(Folded, 1);
    MemberOrder.Add(Name);
    Inc(FNextPropertyID);
    PropertyIDs.AddOrSetValue(Name, FNextPropertyID);
  end;
  Members.AddOrSetValue(Name, Value);
  if not CaseNames.ContainsKey(Folded) then
    CaseNames.Add(Folded, Name);
end;

procedure TAVMObject.RemoveData(const Name: string);
var
  Folded, Key: string;
begin
  Folded := AVMLowerName(Name);
  if Members.ContainsKey(Name) then
    UpdateEventMember(Folded, -1);
  Members.Remove(Name);
  MemberOrder.Remove(Name);
  Attributes.Remove(Name);
  PropertyIDs.Remove(Name);
  if Accessors <> nil then
    Accessors.Remove(Name);
  CaseNames.Remove(Folded);
  for Key in MemberOrder do
    if Members.ContainsKey(Key) and (AVMLowerName(Key) = Folded) then
    begin
      CaseNames.Add(Folded, Key);
      Break;
    end;
  if Name = '__proto__' then
    FPrototype := nil;
end;

procedure TAVMObject.ClearMembers;
begin
  Members.Clear;
  MemberOrder.Clear;
  Attributes.Clear;
  CaseNames.Clear;
  if Accessors <> nil then
    Accessors.Clear;
  PropertyIDs.Clear;
  FillChar(FEventMemberCount, SizeOf(FEventMemberCount), 0);
end;

procedure TAVMObject.SetPrototype(Value: TAVMObject);
begin
  FPrototype := Value;
  if (Value <> nil) or Members.ContainsKey('__proto__') then
  begin
    StoreData('__proto__', TAVMValue.Ref(Value));
    if not Attributes.ContainsKey('__proto__') then
      Attributes.Add('__proto__', 3);
  end;
end;

function TAVMHost.GetMember(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean;
begin
  Value := Default(TAVMValue);
  Result := False;
end;

function TAVMHost.GetStoredMember(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean;
begin
  Result := GetMember(O, Name, Value);
end;

function TAVMHost.SetMember(O: TAVMObject; const Name: string; const Value: TAVMValue): Boolean;
begin
  Result := False;
end;

function TAVMHost.LevelObject(Index: Integer): TAVMObject;
begin
  Result := nil;
end;

function TAVMHost.ObjectType(O: TAVMObject): string;
begin
  Result := 'object';
end;

function TAVMHost.CallNative(const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
begin
  raise ESWFError.Create('Unsupported AVM1 native: ' + Name);
end;

function TAVMHost.StringValue(O: TAVMObject; out Text: string): Boolean;
begin
  Text := '';
  Result := False;
end;

function TAVMHost.UtcNowMilliseconds: Double;
var
  Time: TDateTime;
begin
  Time := TDateTime.NowUTC;
  Result := DateTimeToUnix(Time, True) * 1000.0 + MilliSecondOfTheSecond(Time);
end;

function TAVMHost.DateTimezoneOffset(Time: Double; IsUTC: Boolean): Integer;
var
  DateValue: TDateTime;
  Days, Part: Double;

  function OffsetAtUTC(const UTCValue: TDateTime): Integer;
  var
    LocalValue: TDateTime;
    UTCStamp, LocalStamp: TTimeStamp;
  begin
    LocalValue := TTimeZone.local.ToLocalTime(UTCValue);
    { Preserve the UTC instant through repeated local hours, and handle
      Delphi's separate negative-date/fraction representation correctly. }
    UTCStamp := DateTimeToTimeStamp(UTCValue);
    LocalStamp := DateTimeToTimeStamp(LocalValue);
    Result := (Int64(LocalStamp.Date) - UTCStamp.Date) * 86400000 + LocalStamp.Time - UTCStamp.Time;
  end;

begin
  { The calendar supports years outside the RTL range. Unknown historic/gap
    rules fall back to the current offset, matching the pinned fixed model. }
  if IsNan(Time) or IsInfinite(Time) or (Time < -62135596800000.0) or (Time > 253402300799999.0) then
    Exit(OffsetAtUTC(TDateTime.NowUTC));
  try
    Days := Floor(Time / 86400000.0);
    Part := (Time - Days * 86400000.0) / 86400000.0;
    DateValue := Days + UnixDateDelta;
    if DateValue < 0 then
      DateValue := DateValue - Part
    else
      DateValue := DateValue + Part;
    if IsUTC then
      Result := OffsetAtUTC(DateValue)
    else
      Result := Round(TTimeZone.local.GetUtcOffset(DateValue).TotalMilliseconds);
  except
    on E: Exception do
      Result := OffsetAtUTC(TDateTime.NowUTC);
  end;
end;

procedure TAVMHost.Timeline(Target: TAVMObject; const Command: string; const Value: TAVMValue);
begin
end;

function TAVMHost.ResolveTimelineTarget(Start: TAVMObject; const Path: string): TAVMObject;
begin
  if Path = '' then
    Result := Start
  else
    Result := nil;
end;

procedure TAVMHost.CallFrame(Target: TAVMObject; const Value: TAVMValue; Stack: TList<TAVMValue>; const Pool: TArray<string>);
begin
end;

function TAVMHost.ColorTarget(const Value: TAVMValue): TAVMObject;
begin
  Result := nil;
end;

procedure TAVMHost.MarkColorTarget(O: TAVMObject);
begin
end;

function TAVMHost.ReadColorTransform(O: TAVMObject; out Value: TSWFColorTransform): Boolean;
begin
  Value := TSWFColorTransform.Identity;
  Result := False;
end;

procedure TAVMHost.WriteColorTransform(O: TAVMObject; const Value: TSWFColorTransform);
begin
end;

function TAVMHost.BindTransformReference(O: TAVMObject; out Path: string): TAVMObject;
begin
  Path := '';
  Result := nil;
end;

function TAVMHost.ResolveTransformReference(var O: TAVMObject; const Path: string): TAVMObject;
begin
  Result := nil;
end;

function TAVMHost.DisplayParent(O: TAVMObject): TAVMObject;
begin
  Result := nil;
end;

function TAVMHost.ReadDisplayMatrix(O: TAVMObject; out Value: TSWFMatrix): Boolean;
begin
  Value := TSWFMatrix.Identity;
  Result := False;
end;

procedure TAVMHost.WriteDisplayMatrix(O: TAVMObject; const Value: TSWFMatrix);
begin
end;

function TAVMHost.DisplayBounds(O: TAVMObject; out Bounds: TSWFRect): Boolean;
begin
  Bounds := Default(TSWFRect);
  Result := False;
end;

function TAVMHost.ReadLibraryBitmap(const Name: string): IImagePixelBuffer;
begin
  Result := nil;
end;

function TAVMHost.DrawBitmapData(const Target: IImagePixelBuffer; const Source: TAVMValue; const Options: TAVMBitmapDrawOptions): Integer;
begin
  Result := -2;
end;

procedure TAVMHost.ApplyBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter);
begin
end;

function TAVMHost.BitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect;
begin
  Result := Rect;
end;

function TAVMHost.ActionGetProperty(Start: TAVMObject; const Path, Index: TAVMValue; out Value: TAVMValue): Boolean;
begin
  Value := Default(TAVMValue);
  Result := False;
end;

function TAVMHost.ActionSetProperty(Start: TAVMObject; const Path, Index, Value: TAVMValue): Boolean;
begin
  Result := False;
end;

function TAVMHost.ResolveDragTarget(Start: TAVMObject; const Value: TAVMValue): TAVMObject;
begin
  Result := nil;
end;

procedure TAVMHost.StartDrag(Target: TAVMObject; LockCenter: Boolean; const Bounds: TArray<Double>);
begin
end;

procedure TAVMHost.StopDrag;
begin
end;

procedure TAVMHost.StopSounds;
begin
end;

procedure TAVMHost.ToggleQuality;
begin
end;

procedure TAVMHost.VisitRoots(const Visit: TProc<TAVMObject>);
begin
end;

procedure TAVMHost.VisitObjectReferences(O: TAVMObject; const Visit: TProc<TAVMObject>);
begin
end;

procedure TAVMHost.SweepUnreachable;
begin
end;

constructor TAVM1.Create(Host: TAVMHost);
var
  S, Name, ClassName: string;
  I: Integer;
  M, Stage, K, O: TAVMObject;
  StringCtor, ObjectCtor: TAVMValue;
begin
  inherited Create;
  FSWFVersion := 7;
  FTraceLimit := 4096;
  FHost := Host;
  FObjects := TObjectList<TAVMObject>.Create;
  FPropertyCalls := TList<TAVMPropertyCall>.Create;
  FPending := TList<TAVMPendingCall>.Create;
  FShared := TDictionary<string, TAVMObject>.Create;
  FTimers := TDictionary<Integer, TAVMTimer>.Create;
  Trace := TStringList.Create;
  FRNG := $12345678;
  Global := NewObject;
  Root := NewObject('MovieClip');
  Level0 := Root;
  Put(Global, '_global', TAVMValue.Ref(Global));
  Put(Global, '_root', TAVMValue.Ref(Root));
  Put(Global, 'NaN', TAVMValue.Num(NaN));
  Put(Global, 'Infinity', TAVMValue.Num(Infinity));
  for S in ['Object', 'Array', 'Number', 'String', 'Boolean', 'Date', 'MovieClip', 'Button', 'TextFormat', 'setInterval', 'clearInterval', 'updateAfterEvent', 'parseInt', 'parseFloat', 'LoadVars', 'isNaN', 'isFinite', 'getTimer', 'random', 'int', 'trace', 'ASSetPropFlags', 'ASnative'] do
    Put(Global, S, NativeFunction(S));
  FObjectPrototype := NewObject;
  ObjectCtor := Get(Global, 'Object');
  Put(ObjectCtor.Obj, 'prototype', TAVMValue.Ref(FObjectPrototype));
  Put(ObjectCtor.Obj, 'registerClass', NativeFunction('Object.registerClass'));
  ObjectCtor.Obj.Attributes.AddOrSetValue('registerClass', 7);
  Put(FObjectPrototype, 'toString', NativeFunction('Object.toString'));
  Put(FObjectPrototype, 'valueOf', NativeFunction('Object.valueOf'));
  Put(FObjectPrototype, 'hasOwnProperty', NativeFunction('Object.hasOwnProperty'));
  Put(FObjectPrototype, 'addProperty', NativeFunction('Object.addProperty'));
  Put(FObjectPrototype, 'watch', NativeFunction('Object.watch'));
  Put(FObjectPrototype, 'unwatch', NativeFunction('Object.unwatch'));
  Put(FObjectPrototype, 'isPropertyEnumerable', NativeFunction('Object.isPropertyEnumerable'));
  Put(FObjectPrototype, 'isPrototypeOf', NativeFunction('Object.isPrototypeOf'));
  Put(FObjectPrototype, 'toLocaleString', NativeFunction('Object.toLocaleString'));
  FObjectPrototype.Attributes.AddOrSetValue('toString', 3);
  FObjectPrototype.Attributes.AddOrSetValue('valueOf', 3);
  FObjectPrototype.Attributes.AddOrSetValue('toLocaleString', 3);
  for Name in ['hasOwnProperty', 'addProperty', 'watch', 'unwatch', 'isPropertyEnumerable', 'isPrototypeOf'] do
    FObjectPrototype.Attributes.AddOrSetValue(Name, $83);
  FFunctionPrototype := NewObject;
  Put(FFunctionPrototype, 'toString', NativeFunction('Function.toString'));
  Put(FFunctionPrototype, 'call', NativeFunction('Function.call'));
  Put(FFunctionPrototype, 'apply', NativeFunction('Function.apply'));
  FFunctionPrototype.Attributes.AddOrSetValue('toString', 1);
  FFunctionPrototype.Attributes.AddOrSetValue('call', 3);
  FFunctionPrototype.Attributes.AddOrSetValue('apply', 3);
  FArrayPrototype := NewObject;
  for Name in ['push', 'pop', 'concat', 'shift', 'unshift', 'slice', 'join', 'splice', 'toString', 'sort', 'reverse', 'sortOn'] do
  begin
    Put(FArrayPrototype, Name, NativeFunction('Array.' + Name));
    FArrayPrototype.Attributes.AddOrSetValue(Name, 3);
  end;
  ObjectCtor := Get(Global, 'Array');
  Put(ObjectCtor.Obj, 'prototype', TAVMValue.Ref(FArrayPrototype));
  Put(FArrayPrototype, 'constructor', ObjectCtor);
  FArrayPrototype.Attributes.AddOrSetValue('constructor', 3);
  I := 0;
  for Name in ['CASEINSENSITIVE', 'DESCENDING', 'UNIQUESORT', 'RETURNINDEXEDARRAY', 'NUMERIC'] do
  begin
    Put(ObjectCtor.Obj, Name, TAVMValue.Num(1 shl I));
    ObjectCtor.Obj.Attributes.AddOrSetValue(Name, 7);
    Inc(I);
  end;
  for O in FObjects do
    if O.IsFunction then
      O.Prototype := FFunctionPrototype
    else if (O <> FObjectPrototype) and (O <> Global) and (O.Prototype = nil) then
      O.Prototype := FObjectPrototype;
  M := NewObject('Math');
  Put(Global, 'Math', TAVMValue.Ref(M));
  for S in ['random', 'floor', 'ceil', 'round', 'abs', 'sin', 'cos', 'tan', 'sqrt', 'pow', 'min', 'max', 'atan2', 'atan', 'asin', 'acos', 'log', 'exp'] do
  begin
    Put(M, S, NativeFunction('Math.' + S));
    M.Attributes.AddOrSetValue(S, 7);
  end;
  Put(M, 'PI', TAVMValue.Num(Pi));
  Put(M, 'SQRT2', TAVMValue.Num(Sqrt(2)));
  Put(M, 'SQRT1_2', TAVMValue.Num(Sqrt(0.5)));
  Put(M, 'LN2', TAVMValue.Num(Ln(2)));
  Put(M, 'LN10', TAVMValue.Num(Ln(10)));
  Put(M, 'LOG2E', TAVMValue.Num(1 / Ln(2)));
  Put(M, 'LOG10E', TAVMValue.Num(1 / Ln(10)));
  Put(M, 'E', TAVMValue.Num(Exp(1)));
  for S in ['PI', 'SQRT2', 'SQRT1_2', 'LN2', 'LN10', 'LOG2E', 'LOG10E', 'E'] do
    M.Attributes.AddOrSetValue(S, 7);
  Stage := NewObject('Stage');
  Put(Global, 'Stage', TAVMValue.Ref(Stage));
  FStringPrototype := NewObject;
  StringCtor := Get(Global, 'String');
  Put(StringCtor.Obj, 'prototype', TAVMValue.Ref(FStringPrototype));
  Put(StringCtor.Obj, 'fromCharCode', NativeFunction('String.fromCharCode'));
  StringCtor.Obj.Attributes.AddOrSetValue('fromCharCode', 3);
  for Name in ['charAt', 'charCodeAt', 'concat', 'indexOf', 'lastIndexOf', 'slice', 'substring', 'substr', 'split', 'toString', 'valueOf', 'toLowerCase', 'toUpperCase'] do
  begin
    Put(FStringPrototype, Name, NativeFunction('String.' + Name));
    FStringPrototype.Attributes.AddOrSetValue(Name, 3);
  end;
  FNumberPrototype := NewObject;
  FBooleanPrototype := NewObject;
  for Name in ['toString', 'valueOf'] do
  begin
    Put(FNumberPrototype, Name, NativeFunction('Number.' + Name));
    FNumberPrototype.Attributes.AddOrSetValue(Name, 3);
    Put(FBooleanPrototype, Name, NativeFunction('Boolean.' + Name));
    FBooleanPrototype.Attributes.AddOrSetValue(Name, 3);
  end;
  ObjectCtor := Get(Global, 'Number');
  Put(ObjectCtor.Obj, 'prototype', TAVMValue.Ref(FNumberPrototype));
  Put(ObjectCtor.Obj, 'MAX_VALUE', TAVMValue.Num(1.7976931348623157e308));
  Put(ObjectCtor.Obj, 'MIN_VALUE', TAVMValue.Num(4.9406564584124654e-324));
  Put(ObjectCtor.Obj, 'NaN', TAVMValue.Num(NaN));
  Put(ObjectCtor.Obj, 'POSITIVE_INFINITY', TAVMValue.Num(Infinity));
  Put(ObjectCtor.Obj, 'NEGATIVE_INFINITY', TAVMValue.Num(NegInfinity));
  for Name in ['MAX_VALUE', 'MIN_VALUE', 'NaN', 'POSITIVE_INFINITY', 'NEGATIVE_INFINITY'] do
    ObjectCtor.Obj.Attributes.AddOrSetValue(Name, 7);
  ObjectCtor := Get(Global, 'Boolean');
  Put(ObjectCtor.Obj, 'prototype', TAVMValue.Ref(FBooleanPrototype));
  for ClassName in ['String', 'Number', 'Boolean'] do
  begin
    ObjectCtor := Get(Global, ClassName);
    O := Get(ObjectCtor.Obj, 'prototype').Obj;
    Put(O, 'constructor', ObjectCtor);
    O.Attributes.AddOrSetValue('constructor', 1);
  end;
  RegisterAVMDate(Self, FDatePrototype);
  RegisterAVMColor(Self, FColorPrototype);
  RegisterAVMGeometry(Self, FGeometryPrototypes);
  RegisterAVMTransform(Self, FTransformPrototype);
  RegisterAVMTextFormat(Self, FTextFormatPrototype);
  RegisterAVMBitmapData(Self, FBitmapDataPrototype);
  RegisterAVMFilters(Self);
  FMovieClipPrototype := NewObject;
  ObjectCtor := Get(Global, 'MovieClip');
  Put(ObjectCtor.Obj, 'prototype', TAVMValue.Ref(FMovieClipPrototype));
  Put(FMovieClipPrototype, 'constructor', ObjectCtor);
  FMovieClipPrototype.Attributes.AddOrSetValue('constructor', 1);
  Root.Prototype := FMovieClipPrototype;
  FButtonPrototype := NewObject;
  ObjectCtor := Get(Global, 'Button');
  Put(ObjectCtor.Obj, 'prototype', TAVMValue.Ref(FButtonPrototype));
  Put(FButtonPrototype, 'constructor', ObjectCtor);
  FButtonPrototype.Attributes.AddOrSetValue('constructor', 1);
  for ClassName in ['Selection', 'SharedObject'] do
  begin
    O := NewObject(ClassName);
    Put(Global, ClassName, TAVMValue.Ref(O));
    if ClassName = 'Selection' then
    begin
      Put(O, 'setFocus', NativeFunction('Selection.setFocus'));
      Put(O, 'setSelection', NativeFunction('Selection.setSelection'));
    end
    else
      Put(O, 'getLocal', NativeFunction('SharedObject.getLocal'));
  end;
  K := NewObject('Key');
  Put(Global, 'Key', TAVMValue.Ref(K));
  Put(K, 'isDown', NativeFunction('Key.isDown'));
  Put(K, 'getCode', NativeFunction('Key.getCode'));
  RegisterAVMBroadcaster(Self);
  AVMInitializeBroadcaster(Self, K);
  AVMInitializeBroadcaster(Self, Stage);
  O := Get(Global, 'Selection').Obj;
  AVMInitializeBroadcaster(Self, O);
  O := NewObject('Mouse');
  Put(Global, 'Mouse', TAVMValue.Ref(O));
  AVMInitializeBroadcaster(Self, O);
  BeginTick;
end;

destructor TAVM1.Destroy;
begin
  FPropertyCalls.Free;
  FShared.Free;
  FPending.Free;
  FTimers.Free;
  Trace.Free;
  FObjects.Free;
  inherited;
end;

function TAVM1.NewObject(const ClassName: string): TAVMObject;
begin
  if FObjects.Count >= 100000 then
    raise ESWFError.Create('AVM1 session object limit (100000)');
  Result := TAVMObject.Create;
  Result.ClassName := ClassName;
  Result.Prototype := FObjectPrototype;
  if ClassName = 'Function' then
    Result.Prototype := FFunctionPrototype;
  if ClassName = 'Array' then
    Result.Prototype := FArrayPrototype;
  if ClassName = 'Date' then
    Result.Prototype := FDatePrototype;
  if ClassName = 'Color' then
    Result.Prototype := FColorPrototype;
  if ClassName = 'Number' then
    Result.Prototype := FNumberPrototype;
  if ClassName = 'Boolean' then
    Result.Prototype := FBooleanPrototype;
  if ClassName = 'String' then
    Result.Prototype := FStringPrototype;
  if ClassName = 'MovieClip' then
    Result.Prototype := FMovieClipPrototype;
  if ClassName = 'Button' then
    Result.Prototype := FButtonPrototype;
  if ClassName = 'TextFormat' then
    Result.Prototype := FTextFormatPrototype;
  if ClassName = 'BitmapData' then
    Result.Prototype := FBitmapDataPrototype;
  FObjects.Add(Result);
end;

function TAVM1.NativeFunction(const Name: string): TAVMValue;
var
  O: TAVMObject;
begin
  O := NewObject('Function');
  O.IsFunction := True;
  O.Native := Name;
  Result := TAVMValue.Ref(O);
end;

procedure TAVM1.BeginTick;
const
  // Keep a shared cap for bytecode and native work while allowing long frame scripts.
  WorkPerTick = 4000000;
begin
  FBudget := WorkPerTick;
end;

procedure TAVM1.SetTraceLimit(Value: Integer);
begin
  if (Value < 0) or (Value > 65536) then
    raise ESWFError.Create('AVM1 trace limit range');
  FTraceLimit := Value;
end;

function TAVM1.UtcNowMilliseconds: Double;
begin
  Result := FHost.UtcNowMilliseconds;
end;

function TAVM1.DateTimezoneOffset(Time: Double; IsUTC: Boolean): Integer;
begin
  Result := FHost.DateTimezoneOffset(Time, IsUTC);
end;

function TAVM1.ColorTarget(const Value: TAVMValue): TAVMObject;
begin
  Result := FHost.ColorTarget(Value);
end;

procedure TAVM1.MarkColorTarget(O: TAVMObject);
begin
  FHost.MarkColorTarget(O);
end;

function TAVM1.ReadColorTransform(O: TAVMObject; out Value: TSWFColorTransform): Boolean;
begin
  Result := FHost.ReadColorTransform(O, Value);
end;

procedure TAVM1.WriteColorTransform(O: TAVMObject; const Value: TSWFColorTransform);
begin
  FHost.WriteColorTransform(O, Value);
end;

function TAVM1.BindTransformReference(O: TAVMObject; out Path: string): TAVMObject;
begin
  Result := FHost.BindTransformReference(O, Path);
end;

function TAVM1.ResolveTransformReference(var O: TAVMObject; const Path: string): TAVMObject;
begin
  Result := FHost.ResolveTransformReference(O, Path);
end;

function TAVM1.DisplayParent(O: TAVMObject): TAVMObject;
begin
  Result := FHost.DisplayParent(O);
end;

function TAVM1.ReadDisplayMatrix(O: TAVMObject; out Value: TSWFMatrix): Boolean;
begin
  Result := FHost.ReadDisplayMatrix(O, Value);
end;

procedure TAVM1.WriteDisplayMatrix(O: TAVMObject; const Value: TSWFMatrix);
begin
  FHost.WriteDisplayMatrix(O, Value);
end;

function TAVM1.DisplayBounds(O: TAVMObject; out Bounds: TSWFRect): Boolean;
begin
  Result := FHost.DisplayBounds(O, Bounds);
end;

procedure TAVM1.Collect;
var
  Pending: TList<TAVMObject>;
  Mark: TProc<TAVMObject>;
  O: TAVMObject;
  V: TAVMValue;
  PendingCall: TAVMPendingCall;
  Timer: TAVMTimer;
  I: Integer;
  Accessor: TAVMAccessor;
  Watcher: TAVMWatcher;
begin
  if FDepth <> 0 then
    raise ESWFError.Create('AVM1 collection during a call');
  Pending := TList<TAVMObject>.Create;
  Mark :=
    procedure(O: TAVMObject)
    begin
      if (O <> nil) and not O.Marked then
      begin
        O.Marked := True;
        Pending.Add(O);
      end;
    end;
  try
    for O in FObjects do
      O.Marked := False;
    Mark(Global);
    Mark(Root);
    Mark(Level0);
    Mark(FRegisteredClasses[0]);
    Mark(FRegisteredClasses[1]);
    { Built-in native classes also remain live when guest code replaces a
      global constructor or its prototype property. }
    Mark(FObjectPrototype);
    Mark(FDatePrototype);
    Mark(FColorPrototype);
    Mark(FFunctionPrototype);
    Mark(FArrayPrototype);
    for O in FGeometryPrototypes do
      Mark(O);
    Mark(FTransformPrototype);
    Mark(FTextFormatPrototype);
    Mark(FBitmapDataPrototype);
    Mark(FStringPrototype);
    Mark(FNumberPrototype);
    Mark(FBooleanPrototype);
    Mark(FMovieClipPrototype);
    Mark(FButtonPrototype);
    FHost.VisitRoots(Mark);
    for O in FShared.Values do
      Mark(O);
    for PendingCall in FPending do
    begin
      Mark(PendingCall.Target);
      for V in PendingCall.Args do
        Mark(V.Obj);
    end;
    for Timer in FTimers.Values do
    begin
      Mark(Timer.Callback.Obj);
      Mark(Timer.ThisObj);
      for V in Timer.Args do
        Mark(V.Obj);
    end;
    I := 0;
    while I < Pending.Count do
    begin
      O := Pending[I];
      Inc(I);
      Mark(O.Prototype);
      Mark(O.Scope);
      Mark(O.Target);
      Mark(O.WithObject);
      Mark(O.MovieRoot);
      Mark(O.SuperThis);
      FHost.VisitObjectReferences(O, Mark);
      for var Intf in O.Interfaces do
        Mark(Intf);
      if O.IsBoxed then
        Mark(O.PrimitiveValue.Obj);
      if O.Accessors <> nil then
        for Accessor in O.Accessors.Values do
        begin
          Mark(Accessor.Getter);
          Mark(Accessor.Setter);
        end;
      if O.Watchers <> nil then
        for Watcher in O.Watchers.Values do
        begin
          Mark(Watcher.Callback);
          Mark(Watcher.UserData.Obj);
        end;
      for V in O.Members.Values do
        if V.Kind = avObject then
          Mark(V.Obj);
    end;
    { Transform caches are weak: clear them before sweeping unreachable stages. }
    for O in FObjects do
      if O.IsTransform and (O.TransformTarget <> nil) and not O.TransformTarget.Marked then
        O.TransformTarget := nil;
    FHost.SweepUnreachable;
    for I := FObjects.Count - 1 downto 0 do
      if not FObjects[I].Marked then
        FObjects.Delete(I);
  finally
    Pending.Free;
  end;
end;

function TAVM1.Box(const Value: TAVMValue): TAVMObject;
var
  ConstructorValue, BoxedValue: TAVMValue;
  Name: string;
begin
  if Value.Kind = avObject then
    Exit(Value.Obj);
  if Value.Kind in [avUndefined, avNull] then
    Exit(nil);
  case Value.Kind of
    avNumber:
      Name := 'Number';
    avBoolean:
      Name := 'Boolean';
  else
    Name := 'String';
  end;
  ConstructorValue := GetSpecial(Global, Name);
  BoxedValue := Construct(ConstructorValue, [Value]);
  Result := BoxedValue.Obj;
end;

function PropertyVisible(O: TAVMObject; const Key: string; Version: Byte): Boolean; forward;

procedure TAVM1.InitializePrimitive(O: TAVMObject; const Name: string; const Args: TArray<TAVMValue>);
var
  Value: TAVMValue;
begin
  Value := Default(TAVMValue);
  if Length(Args) > 0 then
    Value := Args[0];
  if Name = 'Number' then
  begin
    if Length(Args) = 0 then
      Value := TAVMValue.Num(0)
    else
      Value := TAVMValue.Num(CoerceNumber(Value));
  end
  else if Name = 'String' then
  begin
    if Length(Args) = 0 then
      Value := TAVMValue.Str('')
    else
      Value := TAVMValue.Str(CoerceString(Value));
  end
  else
    Value := TAVMValue.Bool((Length(Args) > 0) and Value.AsBoolean(FSWFVersion));
  O.IsBoxed := True;
  O.PrimitiveValue := Value;
  O.ColorData := nil;
  O.IsDate := False;
  O.IsTransform := False;
  O.TransformTarget := nil;
  O.TransformPath := '';
  if Name = 'String' then
  begin
    O.StoreData('length', TAVMValue.Num(Length(Value.Text)));
    O.Attributes.AddOrSetValue('length', 3);
  end;
end;

function TAVM1.Construct(const Fn: TAVMValue; const Args: TArray<TAVMValue>): TAVMValue;
var
  O: TAVMObject;
  PrototypeValue: TAVMValue;
  Name: string;
begin
  Result := Default(TAVMValue);
  if (Fn.Obj = nil) or not Fn.Obj.IsFunction or (Fn.Obj.SuperThis <> nil) then
    Exit;
  Name := Fn.Obj.Native;
  if (Name = 'Geom.Transform') and ((Length(Args) <> 1) or (Args[0].Kind <> avObject)) then
    Exit;
  if (Name <> '') and not Name.StartsWith('Geom.') and not Name.StartsWith('Filter.') and
    not MatchStr(Name, ['Number', 'String', 'Boolean', 'Array', 'Date', 'Color', 'MovieClipLoader', 'MovieClip', 'Button', 'AsBroadcaster', 'TextFormat', 'TextField', 'BitmapData', 'Sound',
        'NetConnection', 'NetStream', 'Video']) then
    Exit(Call(Fn, Root, Args));
  if Name = '' then
    O := NewObject
  else
    O := NewObject(Name);
  PrototypeValue := GetData(Fn.Obj, 'prototype');
  PutData(O, '__proto__', PrototypeValue);
  if Name = 'BitmapData' then
    Exit(Call(Fn, O, Args, 1, True));
  ConstructOnExisting(Fn, O, Args);
  { Script constructor return values do not replace the new instance. }
  Result := TAVMValue.Ref(O);
end;

procedure TAVM1.ConstructOnExisting(const Fn: TAVMValue; O: TAVMObject; const Args: TArray<TAVMValue>);
begin
  if (O = nil) or (Fn.Obj = nil) or not Fn.Obj.IsFunction then
    Exit;
  O.StoreData('__constructor__', Fn);
  O.Attributes.AddOrSetValue('__constructor__', 1);
  if FSWFVersion < 7 then
  begin
    O.StoreData('constructor', Fn);
    O.Attributes.AddOrSetValue('constructor', 1);
  end;
  Call(Fn, O, Args, 1, True);
end;

procedure TAVM1.RegisterClass(const Name: string; ConstructorObject: TAVMObject);
var
  Registry: TAVMObject;
  Index: Integer;
  Key: string;
begin
  Index := Ord(FSWFVersion >= 7);
  Registry := FRegisteredClasses[Index];
  if Registry = nil then
  begin
    Registry := NewObject;
    Registry.Prototype := nil;
    Registry.RemoveData('__proto__');
    FRegisteredClasses[Index] := Registry;
  end;
  { SWF5/6 and SWF7+ have separate registries. Replace the spelling as well
    as the value in the case-insensitive registry, matching Flash. }
  if FindOwnKey(Registry, Name, Key) then
    Registry.RemoveData(Key);
  if ConstructorObject <> nil then
    Registry.StoreData(Name, TAVMValue.Ref(ConstructorObject));
end;

function TAVM1.RegisteredClass(const Name: string): TAVMObject;
var
  Registry: TAVMObject;
  Key: string;
  Value: TAVMValue;
begin
  Result := nil;
  Registry := FRegisteredClasses[Ord(FSWFVersion >= 7)];
  if (Registry <> nil) and FindOwnKey(Registry, Name, Key) and
    Registry.Members.TryGetValue(Key, Value) then
    Result := Value.Obj;
end;

function TAVM1.SuperBase(O: TAVMObject): TAVMObject;
var
  I: Integer;
begin
  Result := nil;
  if (O = nil) or (O.SuperThis = nil) then
    Exit;
  Result := O.SuperThis;
  for I := 1 to O.SuperDepth do
  begin
    if Result = nil then
      Exit;
    Result := Result.Prototype;
  end;
end;

function TAVM1.MethodDepth(O: TAVMObject; const Name: string): Integer;
var
  Current: TAVMObject;
  Key: string;
  Value: TAVMValue;
  Offset: Integer;
begin
  Result := 1;
  if O = nil then
    Exit;
  Offset := 0;
  Current := O;
  if O.SuperThis <> nil then
  begin
    Current := SuperBase(O);
    if Current <> nil then
      Current := Current.Prototype;
    Offset := O.SuperDepth + 1;
  end;
  while Current <> nil do
  begin
    if (FindOwnKey(Current, Name, Key) and PropertyVisible(Current, Key, FSWFVersion)) or
      FHost.GetMember(Current, Name, Value) then
      Exit(Max(1, Offset));
    Current := Current.Prototype;
    Inc(Offset);
    if Offset > 128 then
      raise ESWFError.Create('AVM1 prototype cycle');
  end;
end;

function TAVM1.InstanceOf(const Value, ConstructorValue: TAVMValue): Boolean;
var
  ConstructorObject, PrototypeObject, Current: TAVMObject;
  Depth: Integer;
  Visited: TDictionary<TAVMObject, Boolean>;

  function implements(InterfaceObject: TAVMObject; Level: Integer): Boolean;
  var
    Intf: TAVMObject;
  begin
    if InterfaceObject = PrototypeObject then
      Exit(True);
    if Visited.ContainsKey(InterfaceObject) then
      Exit(False);
    if Level > 128 then
      raise ESWFError.Create('AVM1 interface hierarchy limit');
    ChargeWork(1);
    Visited.Add(InterfaceObject, True);
    for Intf in InterfaceObject.Interfaces do
      if implements(Intf, Level + 1) then
        Exit(True);
    Result := False;
  end;

begin
  Result := False;
  if Value.Kind <> avObject then
    Exit;
  ConstructorObject := Box(ConstructorValue);
  PrototypeObject := Box(GetData(ConstructorObject, 'prototype'));
  if (Value.Obj = nil) or (PrototypeObject = nil) then
    Exit;
  Current := Value.Obj.Prototype;
  Depth := 0;
  Visited := nil;
  try
    while Current <> nil do
    begin
      if Current = PrototypeObject then
        Exit(True);
      if Length(Current.Interfaces) > 0 then
      begin
        if Visited = nil then
          Visited := TDictionary<TAVMObject, Boolean>.Create;
        if implements(Current, 0) then
          Exit(True);
      end;
      Inc(Depth);
      if Depth > 128 then
        raise ESWFError.Create('AVM1 prototype cycle');
      Current := Current.Prototype;
    end;
  finally
    Visited.Free;
  end;
end;

procedure TAVM1.QueueEvent(Target: TAVMObject; const MethodName: string; const Args: TArray<TAVMValue>; const IsCurrent: TFunc<Boolean>);
var
  EventValue: TAVMPendingCall;
begin
  if FPending.Count >= 4096 then
    raise ESWFError.Create('AVM1 pending event limit');
  EventValue.Target := Target;
  EventValue.MethodName := MethodName;
  EventValue.Args := Args;
  EventValue.IsCurrent := IsCurrent;
  FPending.Add(EventValue);
end;

procedure TAVM1.RunTimers;
var
  Timer: TAVMTimer;
  Fired, Id: Integer;
  PendingCalls: TArray<TAVMPendingCall>;
  PendingCall: TAVMPendingCall;
begin
  Fired := 0;
  PendingCalls := FPending.ToArray;
  FPending.Clear;
  for PendingCall in PendingCalls do
    if not Assigned(PendingCall.IsCurrent) or PendingCall.IsCurrent() then
      Call(Get(PendingCall.Target, PendingCall.MethodName), PendingCall.Target, PendingCall.Args);
  for Id in FTimers.Keys.ToArray do
  begin
    while FTimers.TryGetValue(Id, Timer) and (Timer.Deadline <= Milliseconds) do
    begin
      Inc(Fired);
      if Fired > 1000 then
        raise ESWFError.Create('AVM1 timer callback limit');
      Timer.Deadline := Timer.Deadline + Timer.Interval;
      FTimers[Id] := Timer;
      Call(Timer.Callback, Timer.ThisObj, Timer.Args);
    end;
  end;
end;

function TAVM1.RandomNumber: Double;
begin
  FRNG := FRNG xor (FRNG shl 13);
  FRNG := FRNG xor (FRNG shr 17);
  FRNG := FRNG xor (FRNG shl 5);
  Result := FRNG / 4294967296.0;
end;

function TAVM1.FindOwnKey(O: TAVMObject; const Name: string; out Key: string; IgnoreCase: Boolean): Boolean;
begin
  Key := Name;
  if O = nil then
    Exit(False);
  if (FSWFVersion >= 7) and not IgnoreCase then
    Exit(O.Members.ContainsKey(Name));
  // StoreData and RemoveData maintain the first spelling for every folded key.
  Result := O.CaseNames.TryGetValue(AVMLowerName(Name), Key);
  if not Result then
    Key := Name;
end;

function PropertyVisible(O: TAVMObject; const Key: string; Version: Byte): Boolean;
const
  Masks: array[0..9] of Word = ($7FF8, $7FF8, $7FF8, $7FF8, $7FF8, $7480, $7500, $7000, $6000, $4000);
var
  Flags: Word;
begin
  Flags := 0;
  O.Attributes.TryGetValue(Key, Flags);
  Result := (Version > High(Masks)) or ((Flags and Masks[Version]) = 0);
end;

function AttributeBits(Value: Double): Integer;
begin
  if IsNan(Value) or (Value <= 0) then
    Exit(0);
  if Value >= 65535 then
    Exit(65535);
  Result := Trunc(Value);
end;

function TAVM1.TryGet(O: TAVMObject; const Name: string; out Value: TAVMValue; Resolve: Boolean): Boolean;
var
  Current, Receiver: TAVMObject;
  Depth: Integer;
  Key: string;
  Accessor: TAVMAccessor;
  Resolver: TAVMValue;
begin
  Value := Default(TAVMValue);
  if O = nil then
    Exit(False);
  Current := O;
  Receiver := O;
  Depth := 0;
  if O.SuperThis <> nil then
  begin
    Receiver := O.SuperThis;
    Current := SuperBase(O);
    if Current <> nil then
      Current := Current.Prototype;
  end;
  while Current <> nil do
  begin
    if FindOwnKey(Current, Name, Key) and PropertyVisible(Current, Key, FSWFVersion) then
    begin
      if (Current.Accessors <> nil) and Current.Accessors.TryGetValue(Key, Accessor) and
        (Accessor.Getter <> nil) and Accessor.Getter.IsFunction then
      begin
        if not CallProperty(Current, Key, Accessor.Getter, Receiver, nil, Value) then
          Current.Members.TryGetValue(Key, Value);
      end
      else
        Current.Members.TryGetValue(Key, Value);
      Exit(True);
    end;
    if FHost.GetMember(Current, Name, Value) then
      Exit(True);
    Current := Current.Prototype;
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('AVM1 prototype cycle');
  end;
  if Resolve then
  begin
    Current := O;
    Depth := 0;
    if O.SuperThis <> nil then
    begin
      Current := SuperBase(O);
      if Current <> nil then
        Current := Current.Prototype;
    end;
    while Current <> nil do
    begin
      if FindOwnKey(Current, '__resolve', Key) and PropertyVisible(Current, Key, FSWFVersion) then
      begin
        Current.Members.TryGetValue(Key, Resolver);
        { MovieClip references are primitive AVM1 values for this lookup. }
        if (Resolver.Kind = avObject) and (Resolver.Obj <> nil) and
          (Resolver.Obj.ClassName <> 'MovieClip') then
        begin
          Value := Call(Resolver, Receiver, [TAVMValue.Str(Name)]);
          Exit(True);
        end;
      end;
      Current := Current.Prototype;
      Inc(Depth);
      if Depth > 128 then
        raise ESWFError.Create('AVM1 prototype cycle');
    end;
  end;
  Result := False;
end;

function TAVM1.Get(O: TAVMObject; const Name: string): TAVMValue;
begin
  TryGet(O, Name, Result);
end;

function TAVM1.GetSpecial(O: TAVMObject; const Name: string): TAVMValue;
begin
  TryGet(O, Name, Result, False);
end;

function TAVM1.MayHaveEventMember(O: TAVMObject; Events: TAVMEventMembers): Boolean;
begin
  // A folded spelling may be hidden by case or version. The caller still
  // performs the normal lookup when a candidate exists.
  for var Depth := 0 to 128 do
  begin
    if O = nil then
      Exit(False);
    if O.SuperThis <> nil then
      Exit(True);
    for var Event in Events do
      if O.FEventMemberCount[Event] <> 0 then
        Exit(True);
    O := O.Prototype;
  end;
  Result := True;
end;

function TAVM1.GetData(O: TAVMObject; const Name: string): TAVMValue;
var
  Key: string;
begin
  Result := Default(TAVMValue);
  if FindOwnKey(O, Name, Key) then
    O.Members.TryGetValue(Key, Result);
end;

function TAVM1.GetOwnStored(O: TAVMObject; const Name: string): TAVMValue;
begin
  TryGetOwnStored(O, Name, Result);
end;

function TAVM1.TryGetOwnStored(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean;
var
  Key: string;
begin
  Value := Default(TAVMValue);
  if (O = nil) or (O.SuperThis <> nil) then
    Exit(False);
  if FindOwnKey(O, Name, Key) and PropertyVisible(O, Key, FSWFVersion) then
    Result := O.Members.TryGetValue(Key, Value)
  else
    Result := FHost.GetStoredMember(O, Name, Value);
end;

procedure TAVM1.PutData(O: TAVMObject; const Name: string; const Value: TAVMValue);
var
  Key: string;
  Flags: Word;
begin
  if (O = nil) or (Name = '') then
    Exit;
  if not FindOwnKey(O, Name, Key) then
    Key := Name;
  Flags := 0;
  O.Attributes.TryGetValue(Key, Flags);
  if (Flags and 4) <> 0 then
    Exit;
  if not O.Members.ContainsKey(Key) and (O.Members.Count >= 65536) then
    raise ESWFError.Create('AVM1 property limit');
  O.StoreData(Key, Value);
  O.Attributes.AddOrSetValue(Key, Flags and 7);
  if Key = '__proto__' then
    O.FPrototype := Value.Obj;
end;

procedure TAVM1.TrimArray(O: TAVMObject; NewLength: Integer);
var
  OldValue: TAVMValue;
  Key: string;
  Keys: TArray<string>;
  OldLength, Index: Integer;
begin
  if O = nil then
    Exit;
  OldValue := GetData(O, 'length');
  if (O.ClassName = 'Array') and (OldValue.Kind = avNumber) then
  begin
    OldLength := AVMToInt32(OldValue.Number);
    if Max(0, NewLength) < OldLength then
    begin
      Keys := O.MemberOrder.ToArray;
      for Key in Keys do
        if TryStrToInt(Key, Index) and (Key = IntToStr(Index)) and
          (Index >= Max(0, NewLength)) and (Index < OldLength) then
          DeleteMember(O, Key);
    end;
  end;
end;

procedure TAVM1.SetArrayLength(O: TAVMObject; NewLength: Integer);
begin
  if (O = nil) or (O.SuperThis <> nil) then
    Exit;
  TrimArray(O, NewLength);
  PutData(O, 'length', TAVMValue.Num(NewLength));
end;

function TAVM1.CreateArray(const Values: TArray<TAVMValue>): TAVMObject;
begin
  Result := AVMNewArray(Self, Values);
end;

function TAVM1.CreatePixelBuffer(Width, Height: Integer; Transparent: Boolean; Color: Cardinal): IImagePixelBuffer;
begin
  if FPixelPool = nil then
    FPixelPool := CreateImagePixelPool(32 * 1024 * 1024);
  Result := FPixelPool.Allocate(Width, Height, Transparent, Color);
end;

function TAVM1.ReadLibraryBitmap(const Name: string): IImagePixelBuffer;
begin
  Result := FHost.ReadLibraryBitmap(Name);
end;

function TAVM1.DrawBitmapData(const Target: IImagePixelBuffer; const Source: TAVMValue; const Options: TAVMBitmapDrawOptions): Integer;
begin
  Result := FHost.DrawBitmapData(Target, Source, Options);
end;

procedure TAVM1.ApplyBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter);
begin
  FHost.ApplyBitmapFilter(Dest, Source, Rect, X, Y, Filter);
end;

function TAVM1.BitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect;
begin
  Result := FHost.BitmapFilterRect(Rect, Filter);
end;

procedure TAVM1.ChargeWork(Count: Integer);
begin
  if (Count < 0) or (Count > FBudget) then
    raise ESWFError.Create('AVM1 instruction budget exceeded');
  Dec(FBudget, Count);
end;

function TAVM1.HasOwnProperty(O: TAVMObject; const Name: string): Boolean;
var
  Key: string;
begin
  if (O <> nil) and (O.SuperThis <> nil) then
    O := O.SuperThis;
  Result := FindOwnKey(O, Name, Key);
end;

function TAVM1.HasProperty(O: TAVMObject; const Name: string): Boolean;
var
  Current: TAVMObject;
  Depth: Integer;
  Key: string;
  Value: TAVMValue;
begin
  if (O <> nil) and (O.SuperThis <> nil) then
    O := O.SuperThis;
  Current := O;
  Depth := 0;
  while Current <> nil do
  begin
    if FindOwnKey(Current, Name, Key) then
      Exit(True);
    if FHost.GetMember(Current, Name, Value) then
      Exit(True);
    Current := Current.Prototype;
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('AVM1 prototype cycle');
  end;
  Result := False;
end;

function TAVM1.AddProperty(O: TAVMObject; const Name: string; Getter, Setter: TAVMObject): Boolean;
var
  Key: string;
  Flags: Word;
  Accessor: TAVMAccessor;
  InitialValue: TAVMValue;
begin
  Result := False;
  if (O = nil) or (Name = '') or (Getter = nil) then
    Exit;
  if O.SuperThis <> nil then
    Exit(True);
  if Length(Name) > 65536 then
    raise ESWFError.Create('AVM1 property name limit');
  if not FindOwnKey(O, Name, Key) then
  begin
    Key := Name;
    if O.Members.Count >= 65536 then
      raise ESWFError.Create('AVM1 property limit');
    { Initialize the own slot, without invoking an inherited setter. An
      existing watcher still sees undefined and supplies the stored data. }
    InitialValue := Default(TAVMValue);
    ApplyWatcher(O, Name, InitialValue);
    O.StoreData(Key, InitialValue);
    Flags := 0;
    if Setter = nil then
      Flags := 4;
    O.Attributes.AddOrSetValue(Key, Flags);
  end;
  if O.Accessors = nil then
    O.Accessors := TDictionary<string, TAVMAccessor>.Create;
  Accessor.Getter := Getter;
  Accessor.Setter := Setter;
  O.Accessors.AddOrSetValue(Key, Accessor);
  Result := True;
end;

function TAVM1.PropertyCallCount(O: TAVMObject; const Name: string): Integer;
var
  Frame: TAVMPropertyCall;
  Key: string;
  ID: Integer;
begin
  ID := 0;
  if FindOwnKey(O, Name, Key) then
    O.PropertyIDs.TryGetValue(Key, ID);
  Result := 0;
  for Frame in FPropertyCalls do
    if (Frame.PropertyID = ID) and ((ID = 0) or (Frame.Owner = O)) then
      Inc(Result);
end;

function TAVM1.CallProperty(O: TAVMObject; const Name: string; Callback, Receiver: TAVMObject; const Args: TArray<TAVMValue>; out Value: TAVMValue): Boolean;
var
  Frame: TAVMPropertyCall;
  Key: string;
  Limit: Integer;
begin
  Value := Default(TAVMValue);
  Limit := 65;
  if FSWFVersion < 7 then
    Limit := 1;
  Result := PropertyCallCount(O, Name) < Limit;
  if not Result then
    Exit;
  Frame.Owner := O;
  Frame.PropertyID := 0;
  if FindOwnKey(O, Name, Key) then
    O.PropertyIDs.TryGetValue(Key, Frame.PropertyID);
  FPropertyCalls.Add(Frame);
  try
    Value := Call(TAVMValue.Ref(Callback), Receiver, Args);
  finally
    FPropertyCalls.Delete(FPropertyCalls.Count - 1);
  end;
end;

function TAVM1.FindWatcherKey(O: TAVMObject; const Name: string; out Key: string): Boolean;
begin
  Key := Name;
  Result := False;
  if (O = nil) or (O.Watchers = nil) then
    Exit;
  if FSWFVersion >= 7 then
    Exit(O.Watchers.ContainsKey(Name));
  Result := O.WatchCaseNames.TryGetValue(AVMLowerName(Name), Key);
end;

function TAVM1.Watch(O: TAVMObject; const Name: string; Callback: TAVMObject; const UserData: TAVMValue): Boolean;
var
  Key, Folded: string;
  Watcher: TAVMWatcher;
begin
  Result := False;
  if (O = nil) or (Callback = nil) or not Callback.IsFunction then
    Exit;
  Result := True;
  if O.SuperThis <> nil then
    Exit;
  if Length(Name) > 65536 then
    raise ESWFError.Create('AVM1 property name limit');
  if O.Watchers = nil then
  begin
    O.Watchers := TDictionary<string, TAVMWatcher>.Create;
    O.WatchOrder := TList<string>.Create;
    O.WatchCaseNames := TDictionary<string, string>.Create;
  end;
  if not FindWatcherKey(O, Name, Key) then
  begin
    Key := Name;
    if O.Watchers.Count >= 65536 then
      raise ESWFError.Create('AVM1 watcher limit');
    O.WatchOrder.Add(Key);
    Folded := AVMLowerName(Key);
    if not O.WatchCaseNames.ContainsKey(Folded) then
      O.WatchCaseNames.Add(Folded, Key);
  end;
  Watcher.Callback := Callback;
  Watcher.UserData := UserData;
  O.Watchers.AddOrSetValue(Key, Watcher);
end;

function TAVM1.Unwatch(O: TAVMObject; const Name: string): Boolean;
var
  Key, Folded, Candidate: string;
begin
  Result := False;
  if (O = nil) or (O.SuperThis <> nil) then
    Exit;
  if not FindWatcherKey(O, Name, Key) then
    Exit;
  { Flash cannot remove the watcher of an own virtual property this way. }
  if FindOwnKey(O, Name, Candidate) and (O.Accessors <> nil) and
    O.Accessors.ContainsKey(Candidate) then
    Exit;
  O.Watchers.Remove(Key);
  O.WatchOrder.Remove(Key);
  Folded := AVMLowerName(Key);
  O.WatchCaseNames.Remove(Folded);
  for Candidate in O.WatchOrder do
    if AVMLowerName(Candidate) = Folded then
    begin
      O.WatchCaseNames.Add(Folded, Candidate);
      Break;
    end;
  Result := True;
end;

function TAVM1.GetStored(O: TAVMObject; const Name: string): TAVMValue;
var
  Key: string;
  Depth: Integer;
begin
  Result := Default(TAVMValue);
  Depth := 0;
  while O <> nil do
  begin
    if FindOwnKey(O, Name, Key) and PropertyVisible(O, Key, FSWFVersion) then
    begin
      O.Members.TryGetValue(Key, Result);
      Exit;
    end;
    if FHost.GetStoredMember(O, Name, Result) then
      Exit;
    O := O.Prototype;
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('AVM1 prototype cycle');
  end;
end;

procedure TAVM1.ApplyWatcher(O: TAVMObject; const Name: string; var Value: TAVMValue);
var
  Key: string;
  Watcher: TAVMWatcher;
  OldValue, NewValue: TAVMValue;
begin
  if O.SuperThis <> nil then
    O := O.SuperThis;
  if not FindWatcherKey(O, Name, Key) then
    Exit;
  { Snapshot before guest code can unwatch or replace the callback. The old
    value is stored data, including inherited data, never a getter result. }
  O.Watchers.TryGetValue(Key, Watcher);
  OldValue := GetStored(O, Name);
  if CallProperty(O, Name, Watcher.Callback, O,
    [TAVMValue.Str(Name), OldValue, Value, Watcher.UserData], NewValue) then
    Value := NewValue;
end;

procedure TAVM1.Put(O: TAVMObject; const Name: string; const Value: TAVMValue);
var
  NewValue: TAVMValue;
begin
  if (O = nil) or (Name = '') then
    Exit;
  if Length(Name) > 65536 then
    raise ESWFError.Create('AVM1 property name limit');
  NewValue := Value;
  try
    ApplyWatcher(O, Name, NewValue);
  except
    on E: EAVMThrown do
    begin
      { A thrown guest value still writes undefined, then propagates. }
      try
        PutValue(O, Name, Default(TAVMValue));
      except
      end;
      raise;
    end;
    else
      begin
        try
          PutValue(O, Name, NewValue);
        except
        end;
        raise;
      end;
  end;
  PutValue(O, Name, NewValue);
end;

procedure TAVM1.PutValue(O: TAVMObject; const Name: string; const Value: TAVMValue);
var
  Index, Len, Depth: Integer;
  Flags: Word;
  Key, InheritedKey: string;
  Current, Receiver: TAVMObject;
  Accessor: TAVMAccessor;
  Exists: Boolean;
  Ignored: TAVMValue;
begin
  if (O = nil) or (Name = '') then
    Exit;
  if Length(Name) > 65536 then
    raise ESWFError.Create('AVM1 property name limit');
  if O.SuperThis <> nil then
  begin
    Receiver := O.SuperThis;
    if HasOwnProperty(Receiver, Name) then
      Exit;
    Current := SuperBase(O);
    if Current <> nil then
      Current := Current.Prototype;
    Depth := 0;
    while Current <> nil do
    begin
      if FindOwnKey(Current, Name, InheritedKey) and PropertyVisible(Current, InheritedKey, FSWFVersion) and
        (Current.Accessors <> nil) and Current.Accessors.TryGetValue(InheritedKey, Accessor) then
      begin
        if (Accessor.Setter <> nil) and Accessor.Setter.IsFunction then
          CallProperty(Current, InheritedKey, Accessor.Setter, Receiver, [Value], Ignored);
        Exit;
      end;
      Current := Current.Prototype;
      Inc(Depth);
      if Depth > 128 then
        raise ESWFError.Create('AVM1 prototype cycle');
    end;
    Exit;
  end;
  if O.ClassName = 'Array' then
  begin
    if Name = 'length' then
      TrimArray(O, AVMToInt32(CoerceNumber(Value)))
    else if AVMArrayIndex(Name, Index) then
    begin
      Len := AVMToInt32(CoerceNumber(GetData(O, 'length')));
      if Index >= Len then
        SetArrayLength(O, AVMToInt32(Index + 1.0));
    end;
  end;
  Exists := FindOwnKey(O, Name, Key);
  if not Exists then
  begin
    Current := O.Prototype;
    Depth := 0;
    while Current <> nil do
    begin
      if FindOwnKey(Current, Name, InheritedKey) and PropertyVisible(Current, InheritedKey, FSWFVersion) and
        (Current.Accessors <> nil) and Current.Accessors.TryGetValue(InheritedKey, Accessor) then
      begin
        if (Accessor.Setter <> nil) and Accessor.Setter.IsFunction then
          CallProperty(Current, InheritedKey, Accessor.Setter, O, [Value], Ignored);
        Exit;
      end;
      Current := Current.Prototype;
      Inc(Depth);
      if Depth > 128 then
        raise ESWFError.Create('AVM1 prototype cycle');
    end;
    if FHost.SetMember(O, Name, Value) then
      Exit;
    Key := Name;
  end
  else if (O.Accessors <> nil) and O.Accessors.TryGetValue(Key, Accessor) and
    (Accessor.Setter <> nil) and Accessor.Setter.IsFunction then
    CallProperty(O, Key, Accessor.Setter, O, [Value], Ignored);
  { A setter may delete or redefine its own property. Re-read its flags. }
  Flags := 0;
  O.Attributes.TryGetValue(Key, Flags);
  if (Flags and 4) <> 0 then
    Exit;
  if not O.Members.ContainsKey(Key) and (O.Members.Count >= 65536) then
    raise ESWFError.Create('AVM1 property limit');
  O.StoreData(Key, Value);
  O.Attributes.AddOrSetValue(Key, Flags and 7);
  if Key = '__proto__' then
    O.FPrototype := Value.Obj;
  if (O.ClassName = 'Array') and (Key = 'length') and not Exists then
    O.Attributes.AddOrSetValue(Key, 3);
end;

function TAVM1.DeleteMember(O: TAVMObject; const Name: string): Boolean;
var
  Flags: Word;
  Key: string;
begin
  Result := False;
  if (O <> nil) and (O.SuperThis <> nil) then
    Exit;
  if not FindOwnKey(O, Name, Key) then
    Exit;
  Flags := 0;
  O.Attributes.TryGetValue(Key, Flags);
  if (Flags and 2) <> 0 then
    Exit;
  O.RemoveData(Key);
  Result := True;
end;

function TAVM1.Enumerate(O: TAVMObject): TArray<string>;
var
  Names: TList<string>;

  procedure Visit(Current: TAVMObject; Depth: Integer);
  var
    I: Integer;
    Name: string;
    Flags: Word;
  begin
    if Current = nil then
      Exit;
    if Depth > 128 then
      raise ESWFError.Create('AVM1 prototype cycle');
    Visit(Current.Prototype, Depth + 1);
    { Prototype keys come first, except where any own property shadows them. }
    for I := Names.Count - 1 downto 0 do
      if HasOwnProperty(Current, Names[I]) then
        Names.Delete(I);
    for I := Current.MemberOrder.Count - 1 downto 0 do
    begin
      Name := Current.MemberOrder[I];
      if not Current.Members.ContainsKey(Name) then
        Continue;
      Flags := 0;
      Current.Attributes.TryGetValue(Name, Flags);
      if (Flags and 1) = 0 then
      begin
        if Names.Count >= 65536 then
          raise ESWFError.Create('AVM1 enumeration key limit');
        Names.Add(Name);
      end;
    end;
  end;

begin
  if (O <> nil) and (O.SuperThis <> nil) then
    Exit(nil);
  Names := TList<string>.Create;
  try
    Visit(O, 0);
    Result := Names.ToArray;
  finally
    Names.Free;
  end;
end;

function TAVM1.FindVariable(const Name: string; Scope, Target: TAVMObject): TAVMValue;
var
  P, I: Integer;
  S, Key: string;
  O: TAVMObject;
  V: TAVMValue;
begin
  if Name = '' then
    Exit(Default(TAVMValue));
  if Target = nil then
    Target := Root;
  if FSWFVersion <= 4 then
  begin
    P := LastDelimiter(':', Name);
    if P > 0 then
    begin
      O := FHost.ResolveTimelineTarget(Target, Copy(Name, 1, P - 1));
      Exit(Get(O, Copy(Name, P + 1, MaxInt)));
    end;
  end;
  S := StringReplace(Name, ':', '.', [rfReplaceAll]);
  S := StringReplace(S, '/', '.', [rfReplaceAll]);
  if S.StartsWith('.') then
    S := '_root' + S;
  P := Pos('.', S);
  if P > 0 then
  begin
    V := FindVariable(Copy(S, 1, P - 1), Scope, Target);
    O := V.Obj;
    S := Copy(S, P + 1, MaxInt);
    while Pos('.', S) > 0 do
    begin
      P := Pos('.', S);
      V := Get(O, Copy(S, 1, P - 1));
      O := V.Obj;
      Delete(S, 1, P);
    end;
    Exit(Get(O, S));
  end;
  O := Scope;
  for I := 0 to 128 do
  begin
    if O = nil then
      Break;
    if (O.WithObject <> nil) and HasProperty(O.WithObject, Name) then
      Exit(Get(O.WithObject, Name));
    if FindOwnKey(O, Name, Key) then
      Exit(Get(O, Name));
    O := O.Scope;
  end;
  if Name = '_root' then
    Exit(TAVMValue.Ref(Root));
  if Name = '_global' then
    Exit(TAVMValue.Ref(Global));
  if HasProperty(Target, Name) then
    Exit(Get(Target, Name));
  if HasProperty(Global, Name) then
    Exit(Get(Global, Name));
  S := Name;
  if FSWFVersion < 7 then
    S := AVMLowerName(S);
  if AVMParseLevelName(Name, FSWFVersion, I) then
  begin
    if I = 0 then
      O := Level0
    else
      O := FHost.LevelObject(I);
    if O <> nil then
      Exit(TAVMValue.Ref(O));
  end;
  Result := Default(TAVMValue);
end;

function TAVM1.GetBoundVariable(Target: TAVMObject; const Name: string): TAVMValue;
var
  Separator: Integer;
  Path: string;
begin
  Separator := LastDelimiter(':.', Name);
  if Separator > 1 then
  begin
    Path := Copy(Name, 1, Separator - 1);
    if (Pos('/', Path) <> 0) or (Path = '..') then
      Target := FHost.ResolveTimelineTarget(Target, Path)
    else if Path <> 'this' then
    begin
      if Path.StartsWith('this.') then
        Delete(Path, 1, 5);
      Target := FindVariable(Path, nil, Target).Obj;
    end;
  end;
  Result := Get(Target, Copy(Name, Separator + 1, MaxInt));
end;

function TAVM1.DeleteVariable(const Name: string; Scope, Target: TAVMObject): Boolean;
var
  P, Depth: Integer;
  O: TAVMObject;
  Value: TAVMValue;
begin
  Result := False;
  P := LastDelimiter(':.', Name);
  if P > 0 then
  begin
    Value := FindVariable(Copy(Name, 1, P - 1), Scope, Target);
    if Value.Obj <> nil then
      Exit(DeleteMember(Value.Obj, Copy(Name, P + 1, MaxInt)));
    if not (Value.Kind in [avUndefined, avNull]) and (Trace.Count < 4096) then
      if Trace.Count < FTraceLimit then
        Trace.Add('Parameters of primitive types are no longer coerced into the required type - Object.');
    Exit;
  end;
  O := Scope;
  Depth := 0;
  while O <> nil do
  begin
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('AVM1 scope cycle');
    if (O.WithObject <> nil) and HasProperty(O.WithObject, Name) then
      Exit(DeleteMember(O.WithObject, Name));
    if HasProperty(O, Name) then
      Exit(DeleteMember(O, Name));
    O := O.Scope;
  end;
  if HasProperty(Target, Name) then
    Exit(DeleteMember(Target, Name));
  if HasProperty(Global, Name) then
    Exit(DeleteMember(Global, Name));
end;

procedure TAVM1.SetVariable(const Name: string; Scope, Target: TAVMObject; const Value: TAVMValue);
var
  P, I: Integer;
  S: string;
  O: TAVMObject;
  V: TAVMValue;
begin
  if Target = nil then
    Target := Root;
  if FSWFVersion <= 4 then
  begin
    P := LastDelimiter(':', Name);
    if P > 0 then
    begin
      O := FHost.ResolveTimelineTarget(Target, Copy(Name, 1, P - 1));
      Put(O, Copy(Name, P + 1, MaxInt), Value);
      Exit;
    end;
  end;
  S := StringReplace(Name, ':', '.', [rfReplaceAll]);
  P := LastDelimiter('.', S);
  if P > 0 then
  begin
    V := FindVariable(Copy(S, 1, P - 1), Scope, Target);
    Put(V.Obj, Copy(S, P + 1, MaxInt), Value);
    Exit;
  end;
  O := Scope;
  for I := 0 to 128 do
  begin
    if O = nil then
      Break;
    if (O.WithObject <> nil) and HasProperty(O.WithObject, Name) then
    begin
      Put(O.WithObject, Name, Value);
      Exit;
    end;
    if HasOwnProperty(O, Name) then
    begin
      Put(O, Name, Value);
      Exit;
    end;
    O := O.Scope;
  end;
  Put(Target, Name, Value);
end;

{ Keep native dispatch temporaries off the stack of ordinary script calls.
  In particular, two watched properties may each recurse 65 times. }
function TAVM1.CallNativeFunction(F, ThisObj: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;
var
  local, Receiver: TAVMObject;
  N, Offset, I, ClearFlags, SetFlags: Integer;
  S, Name, Text, PropertyKey: string;
  X, Y: Double;
  Timer: TAVMTimer;
  Flags: Word;
  Value, V: TAVMValue;
  Names: TArray<string>;
  CallArgs: TArray<TAVMValue>;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

begin
  Result := Default(TAVMValue);
  S := F.Native;
  if (S = 'Sound') and not ConstructorCall then
    Exit;
  if (S = 'BitmapData') or S.StartsWith('BitmapData.') then
    Exit(AVMBitmapDataCall(Self, S, ThisObj, Args, ConstructorCall));
  if S.StartsWith('Filter.') then
    Exit(AVMFilterCall(Self, S, ThisObj, Args));
  if (S = 'TextFormat') or S.StartsWith('TextFormat.') then
    Exit(AVMTextFormatCall(Self, S, ThisObj, Args, ConstructorCall));
  if (S = 'AsBroadcaster') or S.StartsWith('AsBroadcaster.') then
    Exit(AVMBroadcasterCall(Self, S, ThisObj, Args));
  if ConstructorCall and MatchStr(S, ['Number', 'Boolean', 'String']) then
  begin
    if ThisObj = nil then
      Exit;
    InitializePrimitive(ThisObj, S, Args);
    Exit(TAVMValue.Ref(ThisObj));
  end;
  if ConstructorCall and MatchStr(S, ['Object', 'MovieClip', 'Button']) then
    Exit(TAVMValue.Ref(ThisObj));
  if S = 'ASnative' then
  begin
    if Length(Args) <> 2 then
      Exit;
    N := AVMToInt32(CoerceNumber(Arg(0)));
    I := AVMToInt32(CoerceNumber(Arg(1)));
    if (N = 101) and (I = 12) then
      Exit(NativeFunction('AsBroadcaster.broadcastMessage'));
    if N = 103 then
    begin
      if (I < 0) or (I > 65535) then
        I := 65535;
      Exit(NativeFunction('Date.' + IntToStr(I)));
    end;
    if N = 1106 then
    begin
      if (I < 0) or (I > 65535) then
        I := 65535;
      Exit(NativeFunction('Transform.' + IntToStr(I)));
    end;
    if N = 252 then
    begin
      Names := ['Array', 'push', 'pop', 'concat', 'shift', 'unshift', 'slice', 'join', 'splice', 'toString', 'sort', 'reverse', 'sortOn'];
      if I = 0 then
        Exit(NativeFunction('Array'));
      if (I > 0) and (I < Length(Names)) then
        Name := Names[I]
      else
        Name := 'unknown';
      Exit(NativeFunction('Array.' + Name));
    end;
    if N <> 200 then
      Exit;
    Names := ['abs', 'min', 'max', 'sin', 'cos', 'atan2', 'tan', 'exp', 'log', 'sqrt', 'round', 'random', 'floor', 'ceil', 'atan', 'asin', 'acos', 'pow'];
    if (I >= 0) and (I < Length(Names)) then
      Name := Names[I]
    else
      Name := 'unknown';
    Exit(NativeFunction('Math.' + Name));
  end;
  if (S = 'Function.call') or (S = 'Function.apply') then
  begin
    Receiver := Box(Arg(0));
    if Receiver = nil then
      Receiver := Global;
    if S = 'Function.call' then
      CallArgs := Copy(Args, 1, MaxInt)
    else
    begin
      local := Arg(1).Obj;
      N := 0;
      if local <> nil then
        N := AVMToInt32(CoerceNumber(Get(local, 'length')));
      if (N < 0) or (N > 65536) then
        raise ESWFError.Create('AVM1 apply argument limit');
      SetLength(CallArgs, N);
      for I := 0 to N - 1 do
        CallArgs[I] := Get(local, IntToStr(I));
    end;
    Exit(Call(TAVMValue.Ref(ThisObj), Receiver, CallArgs));
  end;
  if S.StartsWith('Number.') then
  begin
    if (ThisObj = nil) or not ThisObj.IsBoxed or (ThisObj.PrimitiveValue.Kind <> avNumber) then
      Exit;
    if S = 'Number.valueOf' then
      Exit(ThisObj.PrimitiveValue);
    N := 10;
    if Length(Args) > 0 then
    begin
      X := CoerceNumber(Arg(0));
      if not IsNan(X) and not IsInfinite(X) and (X >= 2) and (X < 37) then
        N := Trunc(X);
    end;
    Exit(TAVMValue.Str(AVMNumberInRadix(ThisObj.PrimitiveValue.Number, N)));
  end;
  if S.StartsWith('Boolean.') then
  begin
    if (ThisObj = nil) or not ThisObj.IsBoxed or (ThisObj.PrimitiveValue.Kind <> avBoolean) then
      Exit;
    if S = 'Boolean.valueOf' then
      Exit(ThisObj.PrimitiveValue);
    if ThisObj.PrimitiveValue.Number <> 0 then
      Exit(TAVMValue.Str('true'));
    Exit(TAVMValue.Str('false'));
  end;
  if S = 'Object.registerClass' then
  begin
    if Length(Args) < 2 then
      Exit(TAVMValue.Bool(False));
    V := Arg(1);
    if not (V.Kind in [avNull, avUndefined]) and
      ((V.Obj = nil) or not V.Obj.IsFunction) then
      Exit(TAVMValue.Bool(False));
    { Constructor validity is tested before coercing the symbol name. }
    RegisterClass(CoerceString(Arg(0)), V.Obj);
    Exit(TAVMValue.Bool(True));
  end;
  if S = 'Object.toString' then
  begin
    if (ThisObj <> nil) and ThisObj.IsFunction then
      Exit(TAVMValue.Str('[type Function]'));
    Exit(TAVMValue.Str('[object Object]'));
  end;
  if S = 'Object.valueOf' then
    Exit(TAVMValue.Ref(ThisObj));
  if S = 'Object.toLocaleString' then
    Exit(TAVMValue.Str(CoerceString(TAVMValue.Ref(ThisObj))));
  if S = 'Object.hasOwnProperty' then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Bool(False));
    Exit(TAVMValue.Bool(HasOwnProperty(ThisObj, CoerceString(Arg(0)))));
  end;
  if (S = 'Object.watch') or (S = 'Object.unwatch') then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Bool(False));
    Name := CoerceString(Arg(0));
    if S = 'Object.unwatch' then
      Exit(TAVMValue.Bool(Unwatch(ThisObj, Name)));
    Exit(TAVMValue.Bool(Watch(ThisObj, Name, Arg(1).Obj, Arg(2))));
  end;
  if S = 'Object.addProperty' then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Bool(False));
    Name := CoerceString(Arg(0));
    Value := Arg(1);
    V := Arg(2);
    if (Value.Kind <> avObject) or (Value.Obj = nil) or (Value.Obj.ClassName = 'MovieClip') or
      not (V.Kind in [avNull, avObject]) or ((V.Obj <> nil) and (V.Obj.ClassName = 'MovieClip')) then
      Exit(TAVMValue.Bool(False));
    Exit(TAVMValue.Bool(AddProperty(ThisObj, Name, Value.Obj, V.Obj)));
  end;
  if S = 'Object.isPropertyEnumerable' then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Bool(False));
    if not FindOwnKey(ThisObj, CoerceString(Arg(0)), PropertyKey) then
      Exit(TAVMValue.Bool(False));
    Flags := 0;
    ThisObj.Attributes.TryGetValue(PropertyKey, Flags);
    Exit(TAVMValue.Bool((Flags and 1) = 0));
  end;
  if S = 'Object.isPrototypeOf' then
  begin
    local := Box(Arg(0));
    N := 0;
    if local <> nil then
      local := local.Prototype;
    while local <> nil do
    begin
      if local = ThisObj then
        Exit(TAVMValue.Bool(True));
      Inc(N);
      if N > 128 then
        raise ESWFError.Create('AVM1 prototype cycle');
      local := local.Prototype;
    end;
    Exit(TAVMValue.Bool(False));
  end;
  if S = 'Function.toString' then
    Exit(TAVMValue.Str('[type Function]'));
  if S = 'SharedObject.getLocal' then
  begin
    Name := CoerceString(Arg(0));
    if not FShared.TryGetValue(Name, local) then
    begin
      local := NewObject('SharedObject');
      Put(local, 'data', TAVMValue.Ref(NewObject));
      FShared.Add(Name, local);
    end;
    FHost.CallNative('memorySharedObject', ThisObj, nil);
    Exit(TAVMValue.Ref(local));
  end;
  if S = 'LoadVars' then
  begin
    local := NewObject('LoadVars');
    Put(local, 'sendAndLoad', NativeFunction('LoadVars.sendAndLoad'));
    Exit(TAVMValue.Ref(local));
  end;
  if S = 'LoadVars.sendAndLoad' then
  begin
    Receiver := Arg(1).Obj;
    if Receiver = nil then
      Receiver := ThisObj;
    QueueEvent(Receiver, 'onLoad', [TAVMValue.Bool(False)]);
    FHost.CallNative('offlineRequest', ThisObj, nil);
    Exit(TAVMValue.Bool(False));
  end;
  if S = 'setInterval' then
  begin
    Timer := Default(TAVMTimer);
    Offset := 2;
    Timer.Callback := Arg(0);
    Timer.ThisObj := Root;
    Timer.Interval := Arg(1).AsNumber(FSWFVersion);
    if (Arg(0).Obj <> nil) and not Arg(0).Obj.IsFunction then
    begin
      Timer.ThisObj := Arg(0).Obj;
      Timer.Callback := Get(Timer.ThisObj, Arg(1).AsString(FSWFVersion));
      Timer.Interval := Arg(2).AsNumber(FSWFVersion);
      Offset := 3;
    end;
    if (Timer.Callback.Obj = nil) or not Timer.Callback.Obj.IsFunction then
      Exit;
    if IsNan(Timer.Interval) or IsInfinite(Timer.Interval) then
      Exit;
    Timer.Interval := Max(10.0, Timer.Interval);
    Timer.Deadline := Milliseconds + Timer.Interval;
    Timer.Args := Copy(Args, Offset, MaxInt);
    Inc(FNextTimer);
    FTimers.Add(FNextTimer, Timer);
    Exit(TAVMValue.Num(FNextTimer));
  end;
  if S = 'clearInterval' then
  begin
    FTimers.Remove(AVMToInt32(CoerceNumber(Arg(0))));
    Exit;
  end;
  if S = 'updateAfterEvent' then
    Exit;
  if S = 'parseInt' then
  begin
    if Length(Args) = 0 then
      Exit;
    N := 0;
    if Length(Args) > 1 then
      N := AVMToInt32(CoerceNumber(Arg(1)));
    if (Length(Args) > 1) and ((N < 2) or (N > 36)) then
      Exit(TAVMValue.Num(NaN));
    Exit(TAVMValue.Num(AVMParseInteger(CoerceString(Arg(0)), Length(Args) > 1, N)));
  end;
  if S = 'parseFloat' then
  begin
    if Length(Args) = 0 then
      Exit;
    Exit(TAVMValue.Num(AVMParseFloat(CoerceString(Arg(0)), False)));
  end;
  if S.StartsWith('Math.') then
  begin
    Name := Copy(S, 6, MaxInt);
    { Every Math method converts its first two arguments in order,
      including random and functions that only use one argument. }
    X := CoerceNumber(Arg(0));
    Y := CoerceNumber(Arg(1));
    if Name = 'random' then
      Exit(TAVMValue.Num(RandomNumber));
    if ((Name = 'min') or (Name = 'max')) and (Length(Args) = 0) then
    begin
      if Name = 'min' then
        Exit(TAVMValue.Num(Infinity));
      Exit(TAVMValue.Num(NegInfinity));
    end;
    if FSWFVersion <= 6 then
    begin
      if (Name = 'pow') and (Length(Args) = 1) and (X = 1) then
        Exit(TAVMValue.Num(1));
      if (Length(Args) = 0) or ((Length(Args) = 1) and MatchText(Name, ['min', 'max', 'pow', 'atan2'])) then
        Exit(TAVMValue.Num(NaN));
    end;
    Exit(TAVMValue.Num(AVMMathNumber(Name, X, Y)));
  end;
  if S = 'random' then
  begin
    N := AVMToInt32(CoerceNumber(Arg(0)));
    if N <= 0 then
      Exit(TAVMValue.Num(0));
    Exit(TAVMValue.Num(Trunc(RandomNumber * N)));
  end;
  if S = 'getTimer' then
    Exit(TAVMValue.Num(Milliseconds));
  if S = 'Number' then
  begin
    if Length(Args) = 0 then
      X := 0
    else
      X := CoerceNumber(Arg(0));
    Exit(TAVMValue.Num(X));
  end;
  if S = 'int' then
    Exit(TAVMValue.Num(AVMToInt32(CoerceNumber(Arg(0)))));
  if S = 'String' then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Str(''));
    Exit(TAVMValue.Str(CoerceString(Arg(0))));
  end;
  if S = 'Boolean' then
  begin
    if Length(Args) = 0 then
      Exit;
    Exit(TAVMValue.Bool(Arg(0).AsBoolean(FSWFVersion)));
  end;
  if S = 'isNaN' then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Bool(True));
    Exit(TAVMValue.Bool(IsNan(CoerceNumber(Arg(0)))));
  end;
  if S = 'isFinite' then
  begin
    if Length(Args) = 0 then
      Exit(TAVMValue.Bool(False));
    X := CoerceNumber(Arg(0));
    Exit(TAVMValue.Bool(not IsNan(X) and not IsInfinite(X)));
  end;
  if S = 'trace' then
  begin
    Text := CoerceString(Arg(0));
    if Trace.Count < FTraceLimit then
      Trace.Add(AVMStringForTrace(Text));
    Exit;
  end;
  if S = 'ASSetPropFlags' then
  begin
    Receiver := Arg(0).Obj;
    if (Receiver = nil) or (Length(Args) < 2) then
      Exit;
    SetFlags := AttributeBits(CoerceNumber(Arg(2)));
    ClearFlags := AttributeBits(CoerceNumber(Arg(3)));
    if Arg(1).Kind = avNull then
      Names := Receiver.Members.Keys.ToArray
    else
      Names := CoerceString(Arg(1)).Split([',']);
    for Name in Names do
      if FindOwnKey(Receiver, Name, PropertyKey, True) then
      begin
        Flags := 0;
        Receiver.Attributes.TryGetValue(PropertyKey, Flags);
        Flags := Word((Flags and not ClearFlags) or SetFlags);
        Receiver.Attributes.AddOrSetValue(PropertyKey, Flags);
      end;
    Exit;
  end;
  if S = 'Object' then
  begin
    if (Length(Args) > 0) and not (Arg(0).Kind in [avNull, avUndefined]) then
      Exit(TAVMValue.Ref(Box(Arg(0))));
    Exit(TAVMValue.Ref(NewObject));
  end;
  if S = 'MovieClip' then
    Exit(TAVMValue.Ref(NewObject(S)));
  if (S = 'Button') or (S = 'TextField') then
    Exit;
  Exit(FHost.CallNative(S, ThisObj, Args));
end;

function TAVM1.CreateArguments(const Fn: TAVMValue; const Args: TArray<TAVMValue>): TAVMObject;
begin
  Result := CreateArray(Args);
  PutData(Result, 'callee', Fn);
  PutData(Result, 'caller', TAVMValue.Ref(FCallee));
  Result.Attributes.AddOrSetValue('callee', 1);
  Result.Attributes.AddOrSetValue('caller', 1);
end;

function TAVM1.Call(const Fn: TAVMValue; ThisObj: TAVMObject; const Args: TArray<TAVMValue>; PrototypeDepth: Integer; ConstructorCall: Boolean): TAVMValue;
var
  F, local, Arguments, SuperObject: TAVMObject;
  Registers: TArray<TAVMValue>;
  N: Integer;
  I: Integer;
  Value, SuperValue: TAVMValue;
  PreviousRoot, PreviousCallee: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  procedure Preload(Flag: Integer; const V: TAVMValue);
  begin
    if (F.Flags and Flag) <> 0 then
    begin
      if N >= Length(Registers) then
        raise ESWFError.Create('AVM1 preload register limit');
      Registers[N] := V;
      Inc(N);
    end;
  end;

begin
  Result := Default(TAVMValue);
  F := Fn.Obj;
  if F = nil then
    Exit;
  if F.SuperThis <> nil then
  begin
    if F.SuperDepth >= 128 then
      raise ESWFError.Create('AVM1 super depth limit');
    local := SuperBase(F);
    if local = nil then
      Exit;
    Value := GetSpecial(local, '__constructor__');
    Exit(Call(Value, F.SuperThis, Args, F.SuperDepth + 1, True));
  end;
  if not F.IsFunction then
    Exit;
  PreviousRoot := Root;
  PreviousVersion := FSWFVersion;
  PreviousContext := MovieContext;
  if (F.Native = '') and (F.MovieVersion <> 0) then
  begin
    Root := F.MovieRoot;
    FSWFVersion := F.MovieVersion;
    MovieContext := F.MovieContext;
  end;
  PreviousCallee := FCallee;
  Inc(FDepth);
  try
    { Property calls have their own per-slot limit. Preserve the ordinary
      call bound while allowing the tested pair of 65-deep property chains. }
    if (FDepth > 144) or (FDepth - FPropertyCalls.Count > 128) then
      raise ESWFError.Create('AVM1 call depth limit');
    if (F.Native = 'Array') or F.Native.StartsWith('Array.') then
      Exit(AVMArrayCall(Self, F.Native, ThisObj, Args, ConstructorCall));
    if F.Native.StartsWith('String.') then
      Exit(AVMStringCall(Self, F.Native, ThisObj, Args));
    if F.Native = 'Date' then
    begin
      if ConstructorCall then
        Exit(AVMDateCall(Self, ThisObj, Args, 256));
      Exit(AVMDateFunction(Self));
    end;
    if F.Native.StartsWith('Date.') then
      Exit(AVMDateCall(Self, ThisObj, Args, StrToInt(Copy(F.Native, 6, MaxInt))));
    if (F.Native = 'Color') or F.Native.StartsWith('Color.') then
      Exit(AVMColorCall(Self, F.Native, ThisObj, Args));
    if F.Native = 'Geom.Transform' then
      Exit(AVMTransformCall(Self, ThisObj, Args, 0));
    if F.Native.StartsWith('Transform.') then
      Exit(AVMTransformCall(Self, ThisObj, Args, StrToInt(Copy(F.Native, 11, MaxInt))));
    if F.Native.StartsWith('Geom.') then
      Exit(AVMGeometryCall(Self, F.Native, ThisObj, Args));
    if F.Native <> '' then
      Exit(CallNativeFunction(F, ThisObj, Args, ConstructorCall));
    local := NewObject('Activation');
    local.Scope := F.Scope;
    if ThisObj = nil then
      ThisObj := Root;
    Put(local, 'this', TAVMValue.Ref(ThisObj));
    Arguments := CreateArguments(Fn, Args);
    FCallee := F;
    Put(local, 'arguments', TAVMValue.Ref(Arguments));
    SuperValue := Default(TAVMValue);
    if (F.Flags and 32) = 0 then
    begin
      SuperObject := NewObject('Super');
      SuperObject.RemoveData('__proto__');
      SuperObject.SuperThis := ThisObj;
      SuperObject.SuperDepth := PrototypeDepth;
      SuperValue := TAVMValue.Ref(SuperObject);
      if (F.Flags and 16) = 0 then
        Put(local, 'super', SuperValue);
    end;
    SetLength(Registers, 256);
    for I := 0 to High(F.Params) do
    begin
      if F.Params[I].RegisterIndex = 0 then
        Put(local, F.Params[I].Name, Arg(I))
      else
        Registers[F.Params[I].RegisterIndex] := Arg(I);
    end;
    N := 1;
    Preload(1, TAVMValue.Ref(ThisObj));
    Preload(4, TAVMValue.Ref(Arguments));
    Preload(16, SuperValue);
    Preload(64, TAVMValue.Ref(Root));
    if (F.Flags and 128) <> 0 then
      Preload(128, GetSpecial(ThisObj, '_parent'));
    Preload(256, TAVMValue.Ref(Global));
    try
      Result := Execute(F.Code, F.Target, ThisObj, local, F.Pool, Registers);
    except
      on E: EAVMReturn do
        Result := E.Value;
    end;
  finally
    FCallee := PreviousCallee;
    Dec(FDepth);
    Root := PreviousRoot;
    FSWFVersion := PreviousVersion;
    MovieContext := PreviousContext;
  end;
end;

procedure TAVM1.Run(const Code: TBytes; Target: TAVMObject; Stack: TList<TAVMValue>; const Pool: TArray<string>);
var
  Registers: TArray<TAVMValue>;
begin
  SetLength(Registers, 256);
  try
    Execute(Code, Target, Target, nil, Pool, Registers, Stack);
  except
    on E: EAVMReturn do
      ;
  end;
end;

procedure TAVM1.ExecuteStartDrag(Stack: TList<TAVMValue>; Target: TAVMObject);
var
  DragTarget: TAVMObject;
  Locked, Constrained: Boolean;
  Bounds: TArray<Double>;
  Value: TAVMValue;

  function Pop: TAVMValue;
  begin
    if Stack.Count = 0 then
      Exit(Default(TAVMValue));
    Result := Stack.Last;
    Stack.Delete(Stack.Count - 1);
  end;

begin
  Value := Pop;
  DragTarget := FHost.ResolveDragTarget(Target, Value);
  Locked := AVMToInt32(CoerceNumber(Pop)) = 1;
  Constrained := AVMToInt32(CoerceNumber(Pop)) = 1;
  if Constrained then
  begin
    SetLength(Bounds, 4);
    Bounds[3] := CoerceNumber(Pop);
    Bounds[2] := CoerceNumber(Pop);
    Bounds[1] := CoerceNumber(Pop);
    Bounds[0] := CoerceNumber(Pop);
  end;
  if DragTarget <> nil then
    FHost.StartDrag(DragTarget, Locked, Bounds);
end;

function TAVM1.Execute(const Code: TBytes; Target, ThisObj, Scope: TAVMObject; const Pool: TArray<string>; var Registers: TArray<TAVMValue>; SharedStack: TList<TAVMValue>): TAVMValue;
var
  PC, Op, Size, Finish, EndIndex, N, Index, Offset, I, CallDepth: Integer;
  Stack: TList<TAVMValue>;
  R: TSWFReader;
  A, B, V, Fn: TAVMValue;
  O, F, PreviousTarget, BaseTarget: TAVMObject;
  Constants: TArray<string>;
  Args: TArray<TAVMValue>;
  S, StringOperand: string;
  X, Y: Double;
  Names: TArray<string>;
  Implemented: TArray<TAVMObject>;
  Body, Raw, Swapped: TBytes;
  SingleValue: Single;
  RawInteger: Cardinal;
  TryBody, CatchBody, FinallyBody: TBytes;
  TryFlags, TryLength, CatchLength, FinallyLength, CatchRegister, OriginalStackCount: Integer;
  CatchName: string;
  OwnStack: Boolean;

  procedure Push(const Value: TAVMValue);
  begin
    if Stack.Count >= 65536 then
      raise ESWFError.Create('AVM1 stack limit');
    Stack.Add(Value);
  end;

  function Pop: TAVMValue;
  begin
    if Stack.Count = 0 then
      Exit(Default(TAVMValue));
    Result := Stack.Last;
    Stack.Delete(Stack.Count - 1);
  end;

  function Count: Integer;
  var
    Value: Double;
  begin
    Value := Pop.AsNumber(FSWFVersion);
    if IsNan(Value) or IsInfinite(Value) or (Value < 0) or (Value > 65536) then
      raise ESWFError.Create('Invalid AVM1 argument count');
    Result := Trunc(Value);
    if Result > Stack.Count then
      raise ESWFError.Create('Truncated AVM1 argument list');
  end;

  procedure ReadArgs;
  var
    ArgumentIndex: Integer;
  begin
    N := Count;
    SetLength(Args, N);
    for ArgumentIndex := 0 to N - 1 do
      Args[ArgumentIndex] := Pop;
  end;

  function Int32(const Value: TAVMValue): Integer;
  begin
    Result := AVMToInt32(CoerceNumber(Value));
  end;

  function Equal(const L, R: TAVMValue; strict: Boolean): Boolean;
  begin
    Result := EqualValues(L, R, strict);
  end;

begin
  Result := Default(TAVMValue);
  Constants := Pool;
  PC := 0;
  if (FBlockDepth >= 144) or (FBlockDepth - FPropertyCalls.Count >= 128) then
    raise ESWFError.Create('AVM1 action block depth limit');
  Inc(FBlockDepth);
  OwnStack := SharedStack = nil;
  PreviousTarget := CurrentTarget;
  BaseTarget := Target;
  Stack := SharedStack;
  if OwnStack then
    Stack := TList<TAVMValue>.Create;
  try
    while PC < Length(Code) do
    begin
      CurrentTarget := Target;
      Dec(FBudget);
      if FBudget < 0 then
        raise ESWFError.Create('AVM1 instruction budget exceeded');
      Op := Code[PC];
      Inc(PC);
      if Op = 0 then
        Exit;
      Size := 0;
      if Op >= 128 then
      begin
        if PC > Length(Code) - 2 then
          raise ESWFError.Create('Truncated AVM1 action header');
        Size := Code[PC] or (Integer(Code[PC + 1]) shl 8);
        Inc(PC, 2);
      end;
      Finish := PC + Size;
      if Finish > Length(Code) then
        raise ESWFError.Create('Truncated AVM1 action');
      R := TSWFReader.Create(Copy(Code, PC, Size), FSWFVersion);
      try
        case Op of
          $04:
            FHost.Timeline(Target, 'nextFrame', Default(TAVMValue));
          $05:
            FHost.Timeline(Target, 'prevFrame', Default(TAVMValue));
          $06:
            FHost.Timeline(Target, 'play', Default(TAVMValue));
          $07:
            FHost.Timeline(Target, 'stop', Default(TAVMValue));
          $08:
            FHost.ToggleQuality;
          $09:
            FHost.StopSounds;
          $0A, $0B, $0C, $0D, $0E, $0F, $10, $11, $13, $21, $29, $3F, $47, $48, $49, $60..$68:
            begin
              B := Pop;
              A := Pop;
              X := 0;
              Y := 0;
              if Op in [$0A..$0F, $3F] then
              begin
                if Op in [$0B, $0D, $0E, $3F] then
                begin
                  Y := CoerceNumber(B);
                  X := CoerceNumber(A);
                end
                else
                begin
                  X := CoerceNumber(A);
                  Y := CoerceNumber(B);
                end;
              end;
              case Op of
                $0A, $0B, $0C, $3F:
                  Push(TAVMValue.Num(AVMBinaryNumber(Op, X, Y)));
                $0D:
                  begin
                    if (Y = 0) and (FSWFVersion < 5) then
                      Push(TAVMValue.Str('#ERROR#'))
                    else
                      Push(TAVMValue.Num(AVMBinaryNumber(Op, X, Y)));
                  end;
                $0E:
                  Push(TAVMValue.Bool(X = Y));
                $0F:
                  Push(TAVMValue.Bool(X < Y));
                $10:
                  Push(TAVMValue.Bool(A.AsBoolean(FSWFVersion) and B.AsBoolean(FSWFVersion)));
                $11:
                  Push(TAVMValue.Bool(A.AsBoolean(FSWFVersion) or B.AsBoolean(FSWFVersion)));
                $13:
                  begin
                    S := CoerceString(B);
                    StringOperand := CoerceString(A);
                    Push(TAVMValue.Bool(StringOperand = S));
                  end;
                $21:
                  begin
                    S := CoerceString(B);
                    StringOperand := CoerceString(A);
                    Push(TAVMValue.Str(StringOperand + S));
                  end;
                $29:
                  begin
                    S := CoerceString(B);
                    StringOperand := CoerceString(A);
                    Push(TAVMValue.Bool(StringOperand < S));
                  end;
                $47:
                  Push(AddValues(A, B));
                $48:
                  Push(LessThan(A, B));
                $49:
                  Push(TAVMValue.Bool(Equal(A, B, False)));
                $60:
                  Push(TAVMValue.Num(Int32(A) and Int32(B)));
                $61:
                  Push(TAVMValue.Num(Int32(A) or Int32(B)));
                $62:
                  Push(TAVMValue.Num(Int32(A) xor Int32(B)));
                $63:
                  Push(TAVMValue.Num(Int32(A) shl (Int32(B) and 31)));
                $64:
                  begin
                    Index := Int32(A);
                    N := Int32(B) and 31;
                    if Index < 0 then
                      Index := not ((not Index) shr N)
                    else
                      Index := Index shr N;
                    Push(TAVMValue.Num(Index));
                  end;
                $65:
                  Push(TAVMValue.Num(Cardinal(Int32(A)) shr (Int32(B) and 31)));
                $66:
                  Push(TAVMValue.Bool(Equal(A, B, True)));
                $67:
                  Push(LessThan(B, A));
                $68:
                  begin
                    StringOperand := CoerceString(A);
                    S := CoerceString(B);
                    Push(TAVMValue.Bool(StringOperand > S));
                  end;
              end;
            end;
          $12:
            Push(TAVMValue.Bool(not Pop.AsBoolean(FSWFVersion)));
          $14, $31:
            Push(TAVMValue.Num(Length(CoerceString(Pop))));
          $15, $35:
            begin
              N := Int32(Pop);
              Index := Int32(Pop);
              S := CoerceString(Pop);
              if Index >= 1 then
                Dec(Index)
              else
                Index := 0;
              if (N < 0) or (Int64(Index) + N > Length(S)) then
                EndIndex := Length(S)
              else
                EndIndex := Index + N;
              Index := Min(Index, EndIndex);
              Push(TAVMValue.Str(Copy(S, Index + 1, EndIndex - Index)));
            end;
          $32, $36:
            begin
              S := CoerceString(Pop);
              Index := 0;
              if S <> '' then
                Index := Ord(S[1]);
              if (Op = $36) and (FSWFVersion < 6) then
                Index := Index and $FF
              else if (Index >= $D800) and (Index <= $DFFF) then
                Index := $FFFD;
              Push(TAVMValue.Num(Index));
            end;
          $33, $37:
            begin
              Index := Int32(Pop) and $FFFF;
              if (Index >= $D800) and (Index <= $DFFF) and ((Op = $37) or (FSWFVersion >= 6)) then
                Index := $FFFD;
              if Index = 0 then
                S := ''
              else
                S := Char(Index);
              Push(TAVMValue.Str(S));
            end;
          $17:
            Pop;
          $18:
            Push(TAVMValue.Num(Int32(Pop)));
          $1C:
            begin
              S := Pop.AsString(FSWFVersion);
              if (S = 'this') or ((FSWFVersion < 7) and AVMNamesEqual(S, 'this')) then
                Push(TAVMValue.Ref(ThisObj))
              else
                Push(FindVariable(S, Scope, Target));
            end;
          $1D:
            begin
              V := Pop;
              S := Pop.AsString(FSWFVersion);
              SetVariable(S, Scope, Target, V);
            end;
          $20:
            begin
              V := Pop;
              if V.Kind = avUndefined then
              begin
                if FSWFVersion <= 6 then
                  Target := BaseTarget
                else
                  Target := nil;
              end
              else
                Target := FHost.ResolveTimelineTarget(BaseTarget, CoerceString(V));
            end;
          $22:
            begin
              B := Pop;
              A := Pop;
              if FHost.ActionGetProperty(Target, A, B, V) then
              begin
                Push(V);
                Continue;
              end;
              Index := Int32(B);
              V := FindVariable(A.AsString(FSWFVersion), Scope, Target);
              if A.AsString(FSWFVersion) = '' then
                V := TAVMValue.Ref(Target);
              Names := ['_x', '_y', '_xscale', '_yscale', '_currentframe', '_totalframes', '_alpha', '_visible', '_width', '_height', '_rotation', '_target', '_framesloaded', '_name', '_droptarget', '_url', '_highquality', '_focusrect', '_soundbuftime', '_quality', '_xmouse', '_ymouse'];
              if (Index < 0) or (Index >= Length(Names)) then
                Push(Default(TAVMValue))
              else
                Push(Get(V.Obj, Names[Index]));
            end;
          $23:
            begin
              V := Pop;
              B := Pop;
              A := Pop;
              if FHost.ActionSetProperty(Target, A, B, V) then
                Continue;
              Index := Int32(B);
              B := FindVariable(A.AsString(FSWFVersion), Scope, Target);
              if A.AsString(FSWFVersion) = '' then
                B := TAVMValue.Ref(Target);
              Names := ['_x', '_y', '_xscale', '_yscale', '_currentframe', '_totalframes', '_alpha', '_visible', '_width', '_height', '_rotation'];
              if (Index >= 0) and (Index < Length(Names)) then
                Put(B.Obj, Names[Index], V);
            end;
          $24:
            begin
              V := Pop;
              B := Pop;
              A := Pop;
              FHost.CallNative('duplicateMovieClip', Target, [A, B, V]);
            end;
          $25:
            begin
              A := Pop;
              FHost.CallNative('removeMovieClip', Target, [A]);
            end;
          $27:
            ExecuteStartDrag(Stack, Target);
          $28:
            FHost.StopDrag;
          $26:
            begin
              V := Pop;
              try
                if V.Kind = avUndefined then
                  S := 'undefined'
                else
                  S := CoerceString(V);
              except
                if Trace.Count < FTraceLimit then
                  Trace.Add('[type Object]');
                raise;
              end;
              if Trace.Count < FTraceLimit then
                Trace.Add(AVMStringForTrace(S));
            end;
          $2A:
            raise EAVMThrown.CreateValue(Pop, 'Uncaught AVM1 thrown value');
          $2B:
            begin
              A := Pop;
              B := Pop;
              if A.Kind <> avObject then
                Box(A);
              if InstanceOf(A, B) then
                Push(A)
              else
                Push(TAVMValue.Ref(nil));
            end;
          $2C:
            begin
              A := Pop;
              B := Pop;
              N := 0;
              if B.Kind <> avObject then
                N := AVMToInt32(CoerceNumber(B));
              if N < 0 then
                N := Stack.Count
              else
                N := Min(N, Stack.Count);
              if N > 0 then
              begin
                SetLength(Implemented, N);
                Index := 0;
                for I := 1 to N do
                begin
                  V := Pop;
                  V := GetData(V.Obj, 'prototype');
                  if (V.Obj = nil) or (V.Obj.ClassName = 'MovieClip') then
                    Continue;
                  Implemented[Index] := V.Obj;
                  Inc(Index);
                end;
                if FSWFVersion >= 7 then
                begin
                  B := GetData(A.Obj, 'prototype');
                  if (B.Obj <> nil) and (B.Obj.SuperThis = nil) and not B.Obj.InterfacesDeclared then
                  begin
                    SetLength(Implemented, Index);
                    B.Obj.Interfaces := Implemented;
                    B.Obj.InterfacesDeclared := True;
                  end;
                end;
              end;
            end;
          $30:
            begin
              X := Pop.AsNumber(FSWFVersion);
              if X <= 0 then
                X := 0
              else
                X := Trunc(RandomNumber * X);
              Push(TAVMValue.Num(X));
            end;
          $34:
            Push(TAVMValue.Num(Milliseconds));
          $3A:
            begin
              S := CoerceString(Pop);
              A := Pop;
              Push(TAVMValue.Bool(DeleteMember(A.Obj, S)));
            end;
          $3B:
            begin
              S := CoerceString(Pop);
              Push(TAVMValue.Bool(DeleteVariable(S, Scope, Target)));
            end;
          $3C:
            begin
              V := Pop;
              S := Pop.AsString(FSWFVersion);
              if Scope = nil then
                Put(Target, S, V)
              else
                Put(Scope, S, V);
            end;
          $3D, $40:
            begin
              S := Pop.AsString(FSWFVersion);
              ReadArgs;
              Fn := FindVariable(S, Scope, Target);
              if Op = $40 then
                V := Construct(Fn, Args)
              else
                V := Call(Fn, Target, Args);
              Push(V);
            end;
          $3E:
            raise EAVMReturn.CreateValue(Pop, 'AVM1 function return');
          $41:
            begin
              S := Pop.AsString(FSWFVersion);
              if Scope = nil then
                Put(Target, S, Default(TAVMValue))
              else
                Put(Scope, S, Default(TAVMValue));
            end;
          $42:
            begin
              ReadArgs;
              O := CreateArray(Args);
              Push(TAVMValue.Ref(O));
            end;
          $43:
            begin
              X := CoerceNumber(Pop);
              if (X < 0) or (X > MaxInt) then
                Push(Default(TAVMValue))
              else
              begin
                N := 0;
                if not IsNan(X) then
                  N := Trunc(X);
                if N > 65536 then
                  raise ESWFError.Create('AVM1 object initializer limit');
                O := NewObject;
                Fn := GetSpecial(Global, 'Object');
                PutData(O, '__proto__', GetData(Fn.Obj, 'prototype'));
                for I := 1 to N do
                begin
                  Dec(FBudget);
                  if FBudget < 0 then
                    raise ESWFError.Create('AVM1 instruction limit');
                  V := Pop;
                  S := CoerceString(Pop);
                  Put(O, S, V);
                end;
                Push(TAVMValue.Ref(O));
              end;
            end;
          $44:
            begin
              V := Pop;
              case V.Kind of
                avUndefined:
                  S := 'undefined';
                avNull:
                  S := 'null';
                avNumber:
                  S := 'number';
                avBoolean:
                  S := 'boolean';
                avString:
                  S := 'string';
                avObject:
                  if (V.Obj <> nil) and V.Obj.IsFunction then
                    S := 'function'
                  else
                    S := FHost.ObjectType(V.Obj);
              end;
              Push(TAVMValue.Str(S));
            end;
          $46, $55:
            begin
              A := Pop;
              if Op = $46 then
                A := FindVariable(CoerceString(A), Scope, Target);
              Push(Default(TAVMValue));
              Names := Enumerate(A.Obj);
              for I := High(Names) downto 0 do
                Push(TAVMValue.Str(Names[I]));
            end;
          $4A:
            Push(TAVMValue.Num(CoerceNumber(Pop)));
          $4B:
            Push(TAVMValue.Str(CoerceString(Pop)));
          $4C:
            begin
              V := Pop;
              Push(V);
              Push(V);
            end;
          $4D:
            begin
              A := Pop;
              B := Pop;
              Push(A);
              Push(B);
            end;
          $4E:
            begin
              S := CoerceString(Pop);
              A := Pop;
              Push(Get(Box(A), S));
            end;
          $4F:
            begin
              V := Pop;
              S := CoerceString(Pop);
              A := Pop;
              Put(A.Obj, S, V);
            end;
          $50:
            Push(TAVMValue.Num(AVMBinaryNumber($0A, CoerceNumber(Pop), 1)));
          $51:
            Push(TAVMValue.Num(AVMBinaryNumber($0B, CoerceNumber(Pop), 1)));
          $52, $53:
            begin
              V := Pop;
              A := Pop;
              ReadArgs;
              O := Box(A);
              if V.Kind = avUndefined then
                S := ''
              else
                S := CoerceString(V);
              CallDepth := MethodDepth(O, S);
              if (V.Kind = avUndefined) or (S = '') then
                Fn := A
              else
                Fn := Get(O, S);
              if Op = $53 then
                V := Construct(Fn, Args)
              else
              begin
                if (O <> nil) and (O.SuperThis <> nil) then
                  O := O.SuperThis;
                V := Call(Fn, O, Args, CallDepth);
              end;
              Push(V);
            end;
          $54:
            begin
              B := Pop;
              A := Pop;
              Push(TAVMValue.Bool(InstanceOf(A, B)));
            end;
          $69:
            begin
              B := Pop;
              A := Pop;
              F := Box(B);
              O := Box(A);
              V := Get(F, 'prototype');
              F := NewObject;
              PutData(F, '__proto__', V);
              Put(F, 'constructor', B);
              F.Attributes.AddOrSetValue('constructor', 1);
              Put(F, '__constructor__', B);
              F.Attributes.AddOrSetValue('__constructor__', 1);
              Put(O, 'prototype', TAVMValue.Ref(F));
            end;
          $81:
            FHost.Timeline(Target, 'gotoAndStop', TAVMValue.Num(R.U16 + 1));
          $83:
            FHost.CallNative('getURL', Target, [TAVMValue.Str(R.Str), TAVMValue.Str(R.Str)]);
          $87:
            begin
              Index := R.U8;
              V := Pop;
              Registers[Index] := V;
              Push(V);
            end;
          $8A:
            begin
              R.U16;
              R.U8;
            end; // The local movie is fully loaded before execution.
            $8D:
            begin
              Pop;
              R.U8;
            end;
          $88:
            begin
              N := R.U16;
              SetLength(Constants, N);
              for I := 0 to N - 1 do
                Constants[I] := R.Str;
            end;
          $8B:
            Target := FHost.ResolveTimelineTarget(BaseTarget, R.Str);
          $8C:
            FHost.Timeline(Target, 'gotoAndStop', TAVMValue.Str(R.Str));
          $8E, $9B:
            begin
              S := R.Str;
              N := R.U16;
              F := NewObject('Function');
              F.IsFunction := True;
              F.Scope := Scope;
              F.Target := Target;
              F.Pool := Constants;
              F.MovieRoot := Root;
              F.MovieVersion := FSWFVersion;
              F.MovieContext := MovieContext;
              O := NewObject;
              Put(O, 'constructor', TAVMValue.Ref(F));
              O.Attributes.AddOrSetValue('constructor', 1);
              Put(F, 'prototype', TAVMValue.Ref(O));
              F.Attributes.AddOrSetValue('prototype', 1);
              if Op = $8E then
              begin
                F.RegisterCount := R.U8;
                F.Flags := R.U16;
              end;
              SetLength(F.Params, N);
              for I := 0 to N - 1 do
              begin
                if Op = $8E then
                  F.Params[I].RegisterIndex := R.U8;
                F.Params[I].Name := R.Str;
              end;
              N := R.U16;
              if R.Remaining >= N then
                F.Code := R.Bytes(N)
              else
              begin
                if N > Length(Code) - Finish then
                  raise ESWFError.Create('Truncated AVM1 function');
                F.Code := Copy(Code, Finish, N);
                Inc(Finish, N);
              end;
              if S = '' then
                Push(TAVMValue.Ref(F))
              else
              begin
                if Scope = nil then
                  Put(Target, S, TAVMValue.Ref(F))
                else
                  Put(Scope, S, TAVMValue.Ref(F));
              end;
            end;
          $8F:
            begin
              TryFlags := R.U8;
              TryLength := R.U16;
              CatchLength := R.U16;
              FinallyLength := R.U16;
              CatchRegister := 0;
              CatchName := '';
              if (TryFlags and 4) <> 0 then
                CatchRegister := R.U8
              else
                CatchName := R.Str;
              N := TryLength + CatchLength + FinallyLength;
              if R.Remaining >= N then
                Body := R.Bytes(N)
              else
              begin
                if N > Length(Code) - Finish then
                  raise ESWFError.Create('Truncated AVM1 try action');
                Body := Copy(Code, Finish, N);
                Inc(Finish, N);
              end;
              TryBody := Copy(Body, 0, TryLength);
              CatchBody := Copy(Body, TryLength, CatchLength);
              FinallyBody := Copy(Body, TryLength + CatchLength, FinallyLength);
              OriginalStackCount := Stack.Count;
              try
                try
                  Execute(TryBody, Target, ThisObj, Scope, Constants, Registers, Stack);
                except
                  on E: EAVMThrown do
                  begin
                    if (TryFlags and 1) = 0 then
                      raise;
                    while Stack.Count > OriginalStackCount do
                      Stack.Delete(Stack.Count - 1);
                    if (TryFlags and 4) <> 0 then
                      Registers[CatchRegister] := E.Value
                    else
                      SetVariable(CatchName, Scope, Target, E.Value);
                    Execute(CatchBody, Target, ThisObj, Scope, Constants, Registers, Stack);
                  end;
                end;
              finally
                if (TryFlags and 2) <> 0 then
                  Execute(FinallyBody, Target, ThisObj, Scope, Constants, Registers, Stack);
              end;
            end;
          $94:
            begin
              N := R.U16;
              V := Pop;
              O := NewObject('With');
              O.Scope := Scope;
              O.WithObject := V.Obj;

              if R.Remaining >= N then
                Body := R.Bytes(N)
              else
              begin
                if N > Length(Code) - Finish then
                  raise ESWFError.Create('Truncated with action');
                Body := Copy(Code, Finish, N);
                Inc(Finish, N);
              end;
              Execute(Body, Target, ThisObj, O, Constants, Registers, Stack);
            end;
          $96:
            while R.Remaining > 0 do
            begin
              Index := R.U8;
              case Index of
                0:
                  Push(TAVMValue.Str(R.Str));
                1:
                  begin
                    Raw := R.Bytes(4);
                    Move(Raw[0], SingleValue, 4);
                    Push(TAVMValue.Num(SingleValue));
                  end;
                2:
                  Push(TAVMValue.Ref(nil));
                3:
                  Push(Default(TAVMValue));
                4:
                  Push(Registers[R.U8]);
                5:
                  Push(TAVMValue.Bool(R.U8 <> 0));
                6:
                  begin
                    Raw := R.Bytes(8);
                    Swapped := Copy(Raw);
                    Move(Raw[4], Swapped[0], 4);
                    Move(Raw[0], Swapped[4], 4);
                    Move(Swapped[0], X, 8);
                    Push(TAVMValue.Num(X));
                  end;
                7:
                  begin
                    RawInteger := R.U32;
                    Move(RawInteger, Index, 4);
                    Push(TAVMValue.Num(Index));
                  end;
                8, 9:
                  begin
                    if Index = 8 then
                      N := R.U8
                    else
                      N := R.U16;
                    if N >= Length(Constants) then
                      raise ESWFError.Create('Invalid AVM1 constant index');
                    Push(TAVMValue.Str(Constants[N]));
                  end;
              else
                raise ESWFError.Create('Unknown AVM1 push type');
              end;
            end;
          $99, $9D:
            begin
              Offset := R.S16;
              if (Op = $99) or Pop.AsBoolean(FSWFVersion) then
              begin
                Inc(Finish, Offset);
                if Finish < 0 then
                  raise ESWFError.Create('AVM1 branch before action data');
              { Forward branches past this block's end are implicit returns.
                Compilers use them to skip a catch body. }
              end;
            end;
          $9A:
            begin
              Index := R.U8;
              B := Pop;
              A := Pop;
              FHost.CallNative('getURL', Target, [TAVMValue.Str(CoerceString(A)), TAVMValue.Str(CoerceString(B)), TAVMValue.Num(Index)]);
            end;
          $9E:
            FHost.CallFrame(Target, Pop, Stack, Constants);
          $9F:
            begin
              Index := R.U8;
              V := Pop;
              if (Index and 2) <> 0 then
                V := TAVMValue.Num(V.AsNumber(FSWFVersion) + R.U16);
              if (Index and 1) <> 0 then
                S := 'gotoAndPlay'
              else
                S := 'gotoAndStop';
              FHost.Timeline(Target, S, V);
            end;
        else
          raise ESWFError.CreateFmt('AVM1 opcode %.2x is not implemented (offset %d)', [Op, PC]);
        end;
      finally
        R.Free;
      end;
      PC := Finish;
    end;
  finally
    CurrentTarget := PreviousTarget;
    if OwnStack then
      Stack.Free;
    Dec(FBlockDepth);
  end;
end;

end.

