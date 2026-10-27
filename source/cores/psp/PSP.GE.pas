unit PSP.GE;

{$Q-}{$R-}{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Generics.Collections, System.Threading, PSP.Memory, PSP.CPU, PSP.Kernel, PSP.GEMath;

type
  TPSPGEVertexLayout = record
    Key, Stride, OneSize: Cardinal;
    TextureOffset, ColorOffset, NormalOffset, PositionOffset: Integer;
    TexType, ColorType, NormalType, PositionType, WeightType, WeightCount, MorphCount: Cardinal;
  end;

  TPSPGETextureState = record
    Width, Height, Format, BitsPerPixel, Stride, RowBytes, Address: Cardinal;
    ClampU, ClampV, Swizzled: Boolean;
    CLUTShift, CLUTMask, CLUTStart, CLUTIndexMask: Cardinal;
  end;

  TPSPGEVertex = record
    X, Y, Z, U, V, ReciprocalW: Double;
    Clip: TPSPGEClip;
    Color: Cardinal;
    ClipMask: Byte;
    Outside, Near: Boolean;
  end;

  TPSPGEUV = record
    Q,S,T:array[0..2] of Double;
    CachedQ:Single;
    CachedReciprocal:Double;
    FlatQ:Boolean;
  end;

  TPSPGEList = class
    Id, PC, Stall, CallbackId, Status, Offset, FinishToken, SignalMode, SignalToken, PreviousCommand: Cardinal;
    Stack: TArray<Cardinal>;
    Finish, Waiting, Paused: Boolean;
  end;

  TPSPGECallback = record
    Signal, SignalArg, Finish, FinishArg: Cardinal;
  end;

  TPSPGE = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FRegisters: array[0..255] of Cardinal;
    FWorld, FView: array[0..11] of Single;
    FBones: array[0..95] of Single;
    FBoneIndex: Integer;
    FLayout: TPSPGEVertexLayout;
    FLayoutValid: Boolean;
    FProjection, FCombinedTransform: TPSPGEMatrix;
    FTransformDirty: Boolean;
    FWorldIndex, FViewIndex, FProjectionIndex: Integer;
    FVertexAddress, FIndexAddress: Cardinal;
    FLists: TObjectList<TPSPGEList>;
    FQueue: TList<TPSPGEList>;
    FCallbacks: TDictionary<Cardinal, TPSPGECallback>;
    FNextList, FNextCallback: Cardinal;
    FCLUT: TBytes;
    FTexture: TPSPGETextureState;
    FCLUTColors: array[0..1023] of Cardinal;
    FCLUTDirty: Boolean;
    FCLUTFormat: Cardinal;
    FOptimizedRasterization: Boolean;
    FSpanColors: array[0..1023] of Cardinal;
    FSpanDepth: array[0..1023] of Double;
    FColorRow, FDepthRow, FTextureRow: TBytes;
    FParallelRendering, FIsRenderWorker: Boolean;
    FRenderPool: TThreadPool;
    FRenderers: array[0..3] of TPSPGE;
    FRenderMemories: array[0..3] of TPSPMemory;
    FMaxRenderWorkers, FObservedRenderThreads: Integer;
    FParallelDrawCount, FParallelFallbackCount: UInt64;
    procedure ConfigureTexture;
    procedure UpdateTransform;
    procedure ProjectVertex(var V: TPSPGEVertex);
    function NearVertex(const Inside, Outside: TPSPGEVertex): TPSPGEVertex;
    procedure SubmitPoint(const V: TPSPGEVertex);
    procedure SubmitLine(A,B: TPSPGEVertex);
    procedure SubmitTriangle(const A,B,C: TPSPGEVertex; Reversed: Boolean = False);
    procedure SubmitSprite(const A,B: TPSPGEVertex);
    function Light(X, Y, Z, NX, NY, NZ: Double; Color: Cardinal; HasColor: Boolean): Cardinal;
    function FloatAt(Address: Cardinal): Single; inline;
    procedure ConfigureVertexLayout(VType: Cardinal);
    function Relative(Data, Offset: Cardinal): Cardinal;
    function Vertex(Index, VType: Cardinal; out Stride: Cardinal): TPSPGEVertex;
    function Texture(U, V: Double): Cardinal;
    function TextureReadRange(out Address, Size: Cardinal): Boolean;
    procedure Pixel(X, Y: Integer; Z: Double; Color: Cardinal);
    function Shade(Color: Cardinal; U, V: Double): Cardinal;
    function PerspectiveState(const A,B,C:TPSPGEVertex):TPSPGEUV;
    function ShadePerspective(Color:Cardinal; WA,WB,WC:Double; var UV:TPSPGEUV):Cardinal;
    procedure Line(A, B: TPSPGEVertex);
    procedure Triangle(A, B, C: TPSPGEVertex);
    procedure Sprite(const A, C: TPSPGEVertex);
    function Rectangle(const A, B, C, D: TPSPGEVertex): Boolean;
    function BlitSprite(const A, C: TPSPGEVertex; MinX, MinY, MaxX, MaxY: Integer): Boolean;
    function SolidSpan(Left, Right, Y: Integer; Z: Double; Color: Cardinal;
      Colors: PCardinal = nil; DepthValues: PDouble = nil): Boolean;
    procedure Draw(Primitive, Count: Cardinal);
    procedure RenderPrimitives(Primitive: Cardinal; const Vertices: TArray<TPSPGEVertex>);
    function TryParallelDraw(Primitive: Cardinal; const Vertices: TArray<TPSPGEVertex>): Boolean;
    procedure SetMaxRenderWorkers(Value: Integer);
    procedure RunList(List: TPSPGEList);
    procedure Transfer;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    procedure Update;
    // Allows differential validation against the original pixel pipeline.
    property OptimizedRasterization: Boolean read FOptimizedRasterization write FOptimizedRasterization;
    property ParallelRendering: Boolean read FParallelRendering write FParallelRendering;
    property MaxRenderWorkers: Integer read FMaxRenderWorkers write SetMaxRenderWorkers;
    property ParallelDrawCount: UInt64 read FParallelDrawCount;
    property ParallelFallbackCount: UInt64 read FParallelFallbackCount;
    property ObservedRenderThreads: Integer read FObservedRenderThreads;
  end;

implementation

uses
  System.Math, System.Classes, System.SyncObjs{$IFDEF PSP_PROFILE},PSP.Profile{$ENDIF};

function Float24(Value: Cardinal): Single;
begin
  Value := Value shl 8;
  Move(Value, Result, 4);
end;

function Expand5(Value: Cardinal): Cardinal;
begin
  Result := (Value shl 3) or (Value shr 2);
end;

function DecodeColor(Value, Format: Cardinal): Cardinal;
begin
  case Format of
    0:
      begin
        var G := (Value shr 5) and 63;
        Result := $FF000000 or Expand5(Value and 31) or (((G shl 2) or (G shr 4)) shl 8) or
          (Expand5((Value shr 11) and 31) shl 16);
      end;
    1:
      Result := Expand5(Value and 31) or (Expand5((Value shr 5) and 31) shl 8) or
        (Expand5((Value shr 10) and 31) shl 16) or (Cardinal(Ord(Value and $8000 <> 0)) * $FF000000);
    2:
      Result := (Value and 15) * 17 or (((Value shr 4) and 15) * 17 shl 8) or
        (((Value shr 8) and 15) * 17 shl 16) or (((Value shr 12) and 15) * 17 shl 24);
  else
    Result := Value;
  end;
end;

function EncodeColor(Value, Format: Cardinal): Cardinal;
begin
  case Format of
    0:
      Result := ((Value shr 3) and 31) or (((Value shr 10) and 63) shl 5) or (((Value shr 19) and 31) shl 11);
    1:
      Result := ((Value shr 3) and 31) or (((Value shr 11) and 31) shl 5) or
        (((Value shr 19) and 31) shl 10) or ((Value shr 16) and $8000);
    2:
      Result := ((Value shr 4) and 15) or (((Value shr 12) and 15) shl 4) or
        (((Value shr 20) and 15) shl 8) or ((Value shr 16) and $F000);
  else
    Result := Value;
  end;
end;

constructor TPSPGE.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FTransformDirty := True;
  FCPU := CPU;
  FKernel := Kernel;
  FLists := TObjectList<TPSPGEList>.Create(True);
  FQueue := TList<TPSPGEList>.Create;
  FCallbacks := TDictionary<Cardinal, TPSPGECallback>.Create;
  FNextList := 1;
  SetLength(FCLUT, 2048);
  FCLUTDirty := True;
  FCLUTFormat := $FFFFFFFF;
  FOptimizedRasterization := True;
  SetLength(FColorRow,1024*4);
  SetLength(FDepthRow,1024*2);
  SetLength(FTextureRow,512*4);
  FMaxRenderWorkers := Min(4, TThread.ProcessorCount);
  {$IF defined(MSWINDOWS) and (defined(CPUX86) or defined(CPUX64))}
  FParallelRendering := FMaxRenderWorkers > 1;
  {$ENDIF}
end;

destructor TPSPGE.Destroy;
begin
  FRenderPool.Free;
  for var I := 0 to High(FRenderers) do
  begin FRenderers[I].Free; FRenderMemories[I].Free end;
  FCallbacks.Free;
  FQueue.Free;
  FLists.Free;
  inherited;
end;

procedure TPSPGE.SetMaxRenderWorkers(Value: Integer);
begin
  if (Value < 1) or (Value > Length(FRenderers)) then
    raise EArgumentOutOfRangeException.Create('PSP: render worker count');
  FMaxRenderWorkers := Value;
end;

function TPSPGE.Relative(Data, Offset: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(Offset) + ((FRegisters[$10] and $F0000) shl 8) + (Data and $FFFFFF)) and $0FFFFFFF);
end;

function TPSPGE.Light(X, Y, Z, NX, NY, NZ: Double; Color: Cardinal; HasColor: Boolean): Cardinal;

  procedure Normalize(var X, Y, Z: Double);
  begin
    var Size := Sqrt(X * X + Y * Y + Z * Z);
    if Size > 0 then
    begin
      X := X / Size;
      Y := Y / Size;
      Z := Z / Size
    end;
  end;

  function Component(Color: Cardinal; Index: Integer): Double; inline;
  begin
    Result := (Color shr (Index * 8)) and 255
  end;

begin
  if FRegisters[$51] and 1 <> 0 then
  begin
    NX := -NX;
    NY := -NY;
    NZ := -NZ
  end;
  Normalize(NX, NY, NZ);
  var Material: array[0..2] of Cardinal;
  Material[0] := (FRegisters[$55] and $FFFFFF) or ((FRegisters[$58] and 255) shl 24);
  Material[1] := FRegisters[$56];
  Material[2] := FRegisters[$57];
  if HasColor then
    for var I := 0 to 2 do
      if FRegisters[$53] and (1 shl I) <> 0 then
        Material[I] := Color;
  var Sum: array[0..2] of Double;
  for var I := 0 to 2 do
    Sum[I] := Component(FRegisters[$54], I) + Component(FRegisters[$5C], I) * Component(Material[0], I) / 255;
  var Exponent := Max(0.0, Double(Float24(FRegisters[$5B])));
  for var Light := 0 to 3 do
  begin
    if FRegisters[$18 + Light] and 1 = 0 then
      Continue;
    var LX: Double := Float24(FRegisters[$63 + Light * 3]);
    var LY: Double := Float24(FRegisters[$64 + Light * 3]);
    var LZ: Double := Float24(FRegisters[$65 + Light * 3]);
    var Kind := (FRegisters[$5F + Light] shr 8) and 3;
    var Attenuation: Double := 1;
    if Kind <> 0 then
    begin
      LX := LX - X;
      LY := LY - Y;
      LZ := LZ - Z;
      var Distance := Sqrt(LX * LX + LY * LY + LZ * LZ);
      var Denominator := Float24(FRegisters[$7B + Light * 3]) + Distance * Float24(FRegisters[$7C + Light * 3]) + Distance * Distance * Float24(FRegisters[$7D + Light * 3]);
      if Denominator > 0 then
        Attenuation := Min(1.0, 1 / Denominator);
    end;
    Normalize(LX, LY, LZ);
    if Kind >= 2 then
    begin
      var DX: Double := Float24(FRegisters[$6F + Light * 3]);
      var DY: Double := Float24(FRegisters[$70 + Light * 3]);
      var DZ: Double := Float24(FRegisters[$71 + Light * 3]);
      Normalize(DX, DY, DZ);
      var Dot := -(LX * DX + LY * DY + LZ * DZ);
      if Dot < Double(Float24(FRegisters[$8B + Light])) then
        Attenuation := 0
      else
        Attenuation := Attenuation * Power(Max(0.0, Dot), Max(0.0, Double(Float24(FRegisters[$87 + Light]))));
    end;
    var Dot := NX * LX + NY * LY + NZ * LZ;
    var Diffuse := Max(0.0, Dot);
    var Computation := FRegisters[$5F + Light] and 3;
    if Computation = 2 then
      Diffuse := Power(Diffuse, Exponent);
    var Specular: Double := 0;
    if (Computation = 1) and (Dot >= 0) then
    begin
      LZ := LZ + 1;
      Normalize(LX, LY, LZ);
      Specular := Power(Max(0.0, NX * LX + NY * LY + NZ * LZ), Exponent);
    end;
    for var I := 0 to 2 do
      Sum[I] := Sum[I] + Attenuation * (
        Component(FRegisters[$8F + Light * 3], I) * Component(Material[0], I) +
        Diffuse * Component(FRegisters[$90 + Light * 3], I) * Component(Material[1], I) +
        Specular * Component(FRegisters[$91 + Light * 3], I) * Component(Material[2], I)) / 255;
  end;
  Result := Cardinal(EnsureRange(Round(Component(Material[0], 3) * (FRegisters[$5D] and 255) / 255), Int64(0), Int64(255))) shl 24;
  for var I := 0 to 2 do
    Result := Result or (Cardinal(EnsureRange(Round(Sum[I]), Int64(0), Int64(255))) shl (I * 8));
end;

function TPSPGE.FloatAt(Address: Cardinal): Single;
begin
  var Bits := FMemory.ReadGE32(Address);
  Move(Bits, Result, 4)
end;

procedure TPSPGE.ConfigureVertexLayout(VType: Cardinal);
begin
  FLayout := Default(TPSPGEVertexLayout);
  FLayout.Key := VType;
  FLayout.TexType := VType and 3;
  FLayout.ColorType := (VType shr 2) and 7;
  FLayout.NormalType := (VType shr 5) and 3;
  FLayout.PositionType := (VType shr 7) and 3;
  FLayout.WeightType := (VType shr 9) and 3;
  FLayout.WeightCount := ((VType shr 14) and 7) + 1;
  FLayout.MorphCount := ((VType shr 18) and 7) + 1;
  var Offset: Cardinal := 0;
  var Alignment: Cardinal := 1;
  FLayout.TextureOffset := -1;
  FLayout.ColorOffset := -1;
  FLayout.NormalOffset := -1;
  if FLayout.WeightType <> 0 then
  begin
    Alignment := 1 shl (FLayout.WeightType - 1);
    Offset := Alignment * FLayout.WeightCount;
  end;
  if FLayout.TexType <> 0 then
  begin
    var Size := Cardinal(1 shl (FLayout.TexType - 1));
    Offset := (Offset + Size - 1) and not (Size - 1);
    FLayout.TextureOffset := Offset;
    Inc(Offset, Size * 2);
    Alignment := Max(Alignment, Size);
  end;
  if FLayout.ColorType <> 0 then
  begin
    if FLayout.ColorType < 4 then
      raise EPSPInstruction.Create('PSP: invalid GE vertex color format');
    var Size: Cardinal := 2;
    if FLayout.ColorType = 7 then
      Size := 4;
    Offset := (Offset + Size - 1) and not (Size - 1);
    FLayout.ColorOffset := Offset;
    Inc(Offset, Size);
    Alignment := Max(Alignment, Size);
  end;
  if FLayout.NormalType <> 0 then
  begin
    var Size := Cardinal(1 shl (FLayout.NormalType - 1));
    Offset := (Offset + Size - 1) and not (Size - 1);
    FLayout.NormalOffset := Offset;
    Inc(Offset, Size * 3);
    Alignment := Max(Alignment, Size);
  end;
  if FLayout.PositionType = 0 then
    raise EPSPInstruction.Create('PSP: GE vertex has no position');
  var Size := Cardinal(1 shl (FLayout.PositionType - 1));
  Offset := (Offset + Size - 1) and not (Size - 1);
  FLayout.PositionOffset := Offset;
  Inc(Offset, Size * 3);
  Alignment := Max(Alignment, Size);
  FLayout.OneSize := (Offset + Alignment - 1) and not (Alignment - 1);
  FLayout.Stride := FLayout.OneSize * FLayout.MorphCount;
  FLayoutValid := True;
end;

function TPSPGE.Vertex(Index, VType: Cardinal; out Stride: Cardinal): TPSPGEVertex;

  function SignedValue(Address, Kind: Cardinal): Double;
  begin
    case Kind of
      1:
        Result := ShortInt(FMemory.ReadGE8(Address)) / 128;
      2:
        Result := SmallInt(FMemory.ReadGE16(Address)) / 32768;
    else
      Result := FloatAt(Address);
    end;
  end;

begin
  if not FLayoutValid or (FLayout.Key <> VType) then
    ConfigureVertexLayout(VType);
  Stride := FLayout.Stride;
  var Address := UInt64(FVertexAddress) + UInt64(Index) * Stride;
  if Address + Stride > High(Cardinal) then
    raise EPSPMemory.Create('PSP: GE vertex address overflow');
  var P := Cardinal(Address);
  if not FMemory.IsValid(P, Stride) then
    raise EPSPMemory.Create('PSP: GE vertex outside memory');
  var Through := VType and $800000 <> 0;
  Result := Default(TPSPGEVertex);
  Result.ReciprocalW := 1;
  var Normal: array[0..2] of Double;
  Normal[0] := 0;
  Normal[1] := 0;
  Normal[2] := 0;
  var Colors: array[0..3] of Double;
  FillChar(Colors, SizeOf(Colors), 0);
  for var Morph := 0 to Integer(FLayout.MorphCount) - 1 do
  begin
    var Q := P + Cardinal(Morph) * FLayout.OneSize;
    var Weight: Double := 1;
    if FLayout.MorphCount > 1 then
      Weight := Float24(FRegisters[$2C + Morph]);
    if FLayout.TextureOffset >= 0 then
      for var Component := 0 to 1 do
      begin
        var At := Q + Cardinal(FLayout.TextureOffset) + Cardinal(Component) * (1 shl (FLayout.TexType - 1));
        var Value: Double;
        case FLayout.TexType of
          1:
            begin
              Value := FMemory.ReadGE8(At);
              if not Through then
                Value := Value / 128
            end;
          2:
            begin
              Value := FMemory.ReadGE16(At);
              if not Through then
                Value := Value / 32768
            end;
        else
          Value := FloatAt(At);
        end;
        if Component = 0 then
          Result.U := Result.U + Value * Weight
        else
          Result.V := Result.V + Value * Weight;
      end;
    if FLayout.ColorOffset >= 0 then
    begin
      var Color: Cardinal;
      if FLayout.ColorType = 7 then
        Color := FMemory.ReadGE32(Q + Cardinal(FLayout.ColorOffset))
      else
        Color := DecodeColor(FMemory.ReadGE16(Q + Cardinal(FLayout.ColorOffset)), FLayout.ColorType - 4);
      if FLayout.MorphCount = 1 then Result.Color := Color
      else
        for var Component := 0 to 3 do
          Colors[Component] := Colors[Component] + ((Color shr (Component * 8)) and 255) * Weight;
    end;
    for var Component := 0 to 2 do
    begin
      var At := Q + Cardinal(FLayout.PositionOffset) + Cardinal(Component) * (1 shl (FLayout.PositionType - 1));
      var Value: Double;
      if Through then
        case FLayout.PositionType of
          1:
            Value := ShortInt(FMemory.ReadGE8(At));
          2:
            Value := SmallInt(FMemory.ReadGE16(At));
        else
          Value := FloatAt(At);
        end
      else
        Value := SignedValue(At, FLayout.PositionType);
      if Through and (Component = 2) and (FLayout.PositionType = 2) then
        Value := FMemory.ReadGE16(At);
      case Component of
        0:
          Result.X := Result.X + Value * Weight;
        1:
          Result.Y := Result.Y + Value * Weight;
        2:
          Result.Z := Result.Z + Value * Weight;
      end;
      if FLayout.NormalOffset >= 0 then
      begin
        At := Q + Cardinal(FLayout.NormalOffset) + Cardinal(Component) * (1 shl (FLayout.NormalType - 1));
        Normal[Component] := Normal[Component] + SignedValue(At, FLayout.NormalType) * Weight;
      end;
    end;
  end;
  if (FLayout.ColorOffset >= 0) and (FLayout.MorphCount > 1) then
  begin
    for var Component := 0 to 3 do
      Result.Color := Result.Color or
        (Cardinal(EnsureRange(Round(Colors[Component]), Int64(0), Int64(255))) shl (Component * 8));
  end
  else if FLayout.ColorOffset < 0 then
    Result.Color := (FRegisters[$55] and $FFFFFF) or ((FRegisters[$58] and $FF) shl 24);
  if (FLayout.WeightType <> 0) and not Through then
  begin
    var Matrix: array[0..11] of Double;
    FillChar(Matrix, SizeOf(Matrix), 0);
    for var Bone := 0 to Integer(FLayout.WeightCount) - 1 do
    begin
      var At := P + Cardinal(Bone) * (1 shl (FLayout.WeightType - 1));
      var Weight: Double;
      case FLayout.WeightType of
        1:
          Weight := FMemory.ReadGE8(At) / 128;
        2:
          Weight := FMemory.ReadGE16(At) / 32768;
      else
        Weight := FloatAt(At);
      end;
      if Weight <> 0 then
        for var I := 0 to 11 do
          Matrix[I] := Matrix[I] + FBones[Bone * 12 + I] * Weight;
    end;
    var X := Result.X * Matrix[0] + Result.Y * Matrix[3] + Result.Z * Matrix[6] + Matrix[9];
    var Y := Result.X * Matrix[1] + Result.Y * Matrix[4] + Result.Z * Matrix[7] + Matrix[10];
    var Z := Result.X * Matrix[2] + Result.Y * Matrix[5] + Result.Z * Matrix[8] + Matrix[11];
    Result.X := X;
    Result.Y := Y;
    Result.Z := Z;
    X := Normal[0] * Matrix[0] + Normal[1] * Matrix[3] + Normal[2] * Matrix[6];
    Y := Normal[0] * Matrix[1] + Normal[1] * Matrix[4] + Normal[2] * Matrix[7];
    Z := Normal[0] * Matrix[2] + Normal[1] * Matrix[5] + Normal[2] * Matrix[8];
    Normal[0] := X;
    Normal[1] := Y;
    Normal[2] := Z;
  end;
  if not Through then
  begin
    if FTransformDirty then UpdateTransform;
    var Position:TPSPGEClip;
    Position[0]:=Single(Result.X);Position[1]:=Single(Result.Y);Position[2]:=Single(Result.Z);Position[3]:=1;
    var X := Result.X * FWorld[0] + Result.Y * FWorld[3] + Result.Z * FWorld[6] + FWorld[9];
    var Y := Result.X * FWorld[1] + Result.Y * FWorld[4] + Result.Z * FWorld[7] + FWorld[10];
    var Z := Result.X * FWorld[2] + Result.Y * FWorld[5] + Result.Z * FWorld[8] + FWorld[11];
    if FRegisters[$17] and 1 <> 0 then
    begin
      var NX := Normal[0] * FWorld[0] + Normal[1] * FWorld[3] + Normal[2] * FWorld[6];
      var NY := Normal[0] * FWorld[1] + Normal[1] * FWorld[4] + Normal[2] * FWorld[7];
      var NZ := Normal[0] * FWorld[2] + Normal[1] * FWorld[5] + Normal[2] * FWorld[8];
      Result.Color := Light(X, Y, Z, NX, NY, NZ, Result.Color, FLayout.ColorOffset >= 0);
    end;
    Result.Clip:=GETransform(Position,FCombinedTransform);
    ProjectVertex(Result);
    Result.U:=GETruncate(GEAdd(GEProduct(Double(GETruncate(Single(Result.U)))*Float24(FRegisters[$48])),Float24(FRegisters[$4A]))) *
      (1 shl (FRegisters[$B8] and 15));
    Result.V:=GETruncate(GEAdd(GEProduct(Double(GETruncate(Single(Result.V)))*Float24(FRegisters[$49])),Float24(FRegisters[$4B]))) *
      (1 shl ((FRegisters[$B8] shr 8) and 15));
  end;
end;

procedure TPSPGE.UpdateTransform;
begin
  var World, View, WorldView:TPSPGEMatrix;
  FillChar(World,SizeOf(World),0);FillChar(View,SizeOf(View),0);
  for var R:=0 to 3 do for var C:=0 to 2 do
  begin World[R*4+C]:=FWorld[R*3+C];View[R*4+C]:=FView[R*3+C] end;
  World[15]:=1;View[15]:=1;
  GECombine(WorldView,World,View);
  GECombine(FCombinedTransform,WorldView,FProjection);
  FTransformDirty:=False;
end;

function GEFinite(Value:Single):Boolean; inline;
begin
  var Bits:Cardinal;Move(Value,Bits,4);Result:=Bits and $7F800000<>$7F800000;
end;

procedure TPSPGE.ProjectVertex(var V: TPSPGEVertex);
const ScreenBound:Single=4095+15.5/16;
begin
  V.Outside:=False;V.Near:=False;V.ClipMask:=0;V.ReciprocalW:=0;V.X:=0;V.Y:=0;V.Z:=0;
  for var C:=0 to 3 do if not GEFinite(V.Clip[C]) then begin V.Outside:=True;Exit end;
  var W:Single:=V.Clip[3];
  V.Near:=V.Clip[2]<-W;
  if V.Clip[0]>W then V.ClipMask:=V.ClipMask or 1;
  if -V.Clip[0]>W then V.ClipMask:=V.ClipMask or 2;
  if V.Clip[1]>W then V.ClipMask:=V.ClipMask or 4;
  if -V.Clip[1]>W then V.ClipMask:=V.ClipMask or 8;
  if V.Clip[2]>W then V.ClipMask:=V.ClipMask or 16;
  if V.Near then V.ClipMask:=V.ClipMask or 32;
  var WBits:Cardinal;Move(W,WBits,4);
  if WBits and $7F800000=0 then begin V.Outside:=True;Exit end;
  V.ReciprocalW:=GEReciprocal(W);
  var SX:Single:=GEViewport(V.Clip[0],W,Float24(FRegisters[$42]),Float24(FRegisters[$45]));
  var SY:Single:=GEViewport(V.Clip[1],W,Float24(FRegisters[$43]),Float24(FRegisters[$46]));
  var SZ:Single:=GEViewport(V.Clip[2],W,Float24(FRegisters[$44]),Float24(FRegisters[$47]));
  if not GEFinite(SX) or not GEFinite(SY) or not GEFinite(SZ) then begin V.Outside:=True;Exit end;
  var DepthClip:=FRegisters[$1C] and 1<>0;
  if DepthClip then V.Outside:=(SX<0) or (SX>=ScreenBound) or (SY<0) or (SY>=ScreenBound)
  else V.Outside:=(SX<0) or (SX>ScreenBound) or (SY<0) or (SY>=ScreenBound) or (SZ<0) or (SZ>=65536);
  if V.Outside then Exit;
  V.X:=Floor(SX*16)/16-(FRegisters[$4C] and $FFFF)/16;
  V.Y:=Floor(SY*16)/16-(FRegisters[$4D] and $FFFF)/16;
  if DepthClip then SZ:=EnsureRange(SZ,Single(0),Single(65535));
  V.Z:=Floor(SZ);
end;

function TPSPGE.NearVertex(const Inside, Outside: TPSPGEVertex): TPSPGEVertex;
begin
  Result:=Inside;
  var DIn:Single:=GEAdd(Inside.Clip[2],Inside.Clip[3]);
  var DOut:Single:=GEAdd(Outside.Clip[2],Outside.Clip[3]);
  var Den:Single:=GETruncate(GEAdd(DIn,-DOut));
  var T:Single:=0;
  if Den<>0 then T:=GEProduct(Double(GETruncate(DIn))*GEReciprocal(Den));
  for var C:=0 to 3 do
  begin
    var Delta:Single:=GETruncate(GEAdd(Outside.Clip[C],-Inside.Clip[C]));
    Result.Clip[C]:=GETruncate(GEAdd(GEProduct(Double(T)*Delta),Inside.Clip[C]));
  end;
  var Delta:Single:=GETruncate(GEAdd(Single(Outside.U),-Single(Inside.U)));
  Result.U:=GETruncate(GEAdd(GEProduct(Double(T)*Delta),Single(Inside.U)));
  Delta:=GETruncate(GEAdd(Single(Outside.V),-Single(Inside.V)));
  Result.V:=GETruncate(GEAdd(GEProduct(Double(T)*Delta),Single(Inside.V)));
  var Weight:=EnsureRange(Integer(Trunc(T*256+0.5)),0,256);
  Result.Color:=0;
  for var Lane:=0 to 3 do
  begin
    var A:=Integer((Inside.Color shr (Lane*8)) and 255);var B:=Integer((Outside.Color shr (Lane*8)) and 255);
    Result.Color:=Result.Color or (Cardinal((A*(256-Weight)+B*Weight) shr 8) shl (Lane*8));
  end;
  ProjectVertex(Result);
end;

procedure TPSPGE.SubmitPoint(const V: TPSPGEVertex);
begin
  if (FRegisters[$12] and $800000=0) and (V.Outside or (V.ClipMask<>0)) then Exit;
  Pixel(Floor(V.X),Floor(V.Y),V.Z,Shade(V.Color,V.U,V.V));
end;

procedure TPSPGE.SubmitLine(A,B: TPSPGEVertex);
begin
  if FRegisters[$12] and $800000=0 then
  begin
    var DepthClip:=FRegisters[$1C] and 1<>0;
    if (A.Outside and not (DepthClip and A.Near)) or (B.Outside and not (DepthClip and B.Near)) or
      (A.ClipMask and B.ClipMask<>0) then Exit;
    if not DepthClip then
    begin if (A.Clip[3]<=0) or (B.Clip[3]<=0) then Exit end
    else
    begin
      var Color:=B.Color;
      if A.Near then A:=NearVertex(B,A) else if B.Near then B:=NearVertex(A,B);
      if A.Outside or B.Outside then Exit;
      if FRegisters[$50] and 1=0 then B.Color:=Color;
    end;
  end;
  Line(A,B);
end;

procedure TPSPGE.SubmitTriangle(const A,B,C: TPSPGEVertex; Reversed: Boolean);
var Vertices:array[0..2] of TPSPGEVertex;
  procedure DrawSub(V0,V1,V2:TPSPGEVertex);
  begin
    if V0.Outside or V1.Outside or V2.Outside then Exit;
    if FRegisters[$50] and 1=0 then V2.Color:=C.Color;
    Triangle(V0,V1,V2);
  end;
begin
  if FRegisters[$12] and $800000<>0 then begin Triangle(A,B,C);Exit end;
  var DepthClip:=FRegisters[$1C] and 1<>0;
  if (A.Outside and not (DepthClip and A.Near)) or (B.Outside and not (DepthClip and B.Near)) or
    (C.Outside and not (DepthClip and C.Near)) or (A.ClipMask and B.ClipMask and C.ClipMask<>0) then Exit;
  if not DepthClip then
  begin
    if (A.Clip[3]<=0) or (B.Clip[3]<=0) or (C.Clip[3]<=0) then Exit;
    Triangle(A,B,C);Exit;
  end;
  var Count:=Ord(A.Near)+Ord(B.Near)+Ord(C.Near);
  if Count=0 then begin Triangle(A,B,C);Exit end;
  if Count=3 then Exit;
  Vertices[0]:=A;Vertices[1]:=B;Vertices[2]:=C;
  var Index:=0;
  if Count=1 then
  begin
    while not Vertices[Index].Near do Inc(Index);
    var Previous:=(Index+2) mod 3;var Next:=(Index+1) mod 3;
    if Reversed then begin var Swap:=Previous;Previous:=Next;Next:=Swap end;
    var MadeA:=NearVertex(Vertices[Previous],Vertices[Index]);
    var MadeB:=NearVertex(Vertices[Next],Vertices[Index]);
    if not Reversed then
    begin DrawSub(Vertices[Previous],MadeA,MadeB);DrawSub(Vertices[Previous],MadeB,Vertices[Next]) end
    else
    begin DrawSub(Vertices[Previous],MadeB,MadeA);DrawSub(Vertices[Previous],Vertices[Next],MadeB) end;
  end
  else
  begin
    while Vertices[Index].Near do Inc(Index);
    DrawSub(Vertices[Index],NearVertex(Vertices[Index],Vertices[(Index+1) mod 3]),NearVertex(Vertices[Index],Vertices[(Index+2) mod 3]));
  end;
end;

procedure TPSPGE.SubmitSprite(const A,B: TPSPGEVertex);
begin
  if (FRegisters[$12] and $800000=0) and (A.Outside or B.Outside or
    (A.ClipMask and B.ClipMask<>0) or (A.Clip[3]<=0) or (B.Clip[3]<=0)) then Exit;
  Sprite(A,B);
end;

procedure TPSPGE.ConfigureTexture;
begin
  FTexture.Width := 1 shl (FRegisters[$B8] and 15);
  FTexture.Height := 1 shl ((FRegisters[$B8] shr 8) and 15);
  FTexture.Format := FRegisters[$C3] and 15;
  FTexture.ClampU := FRegisters[$C7] and 1 <> 0;
  FTexture.ClampV := FRegisters[$C7] and $100 <> 0;
  FTexture.Stride := FRegisters[$A8] and $7FF;
  FTexture.Address := (FRegisters[$A0] and $FFFFF0) or ((FRegisters[$A8] shl 8) and $0F000000);
  FTexture.BitsPerPixel := 16;
  case FTexture.Format of
    3, 7:
      FTexture.BitsPerPixel := 32;
    4:
      FTexture.BitsPerPixel := 4;
    5:
      FTexture.BitsPerPixel := 8
  end;
  FTexture.RowBytes := FTexture.Stride * FTexture.BitsPerPixel div 8;
  FTexture.Swizzled := FRegisters[$C2] and 1 <> 0;
  FTexture.CLUTShift := (FRegisters[$C5] shr 2) and 31;
  FTexture.CLUTMask := (FRegisters[$C5] shr 8) and $FF;
  FTexture.CLUTStart := ((FRegisters[$C5] shr 16) and 31) shl 4;
  var Format := FRegisters[$C5] and 3;
  FTexture.CLUTIndexMask := 1023;
  if Format = 3 then
    FTexture.CLUTIndexMask := 511;
  if (FTexture.Format in [4..7]) and (FCLUTDirty or (FCLUTFormat <> Format)) then
  begin
    var Size: Cardinal := 2;
    if Format = 3 then
      Size := 4;
    for var I: Cardinal := 0 to FTexture.CLUTIndexMask do
    begin
      var P := I * Size;
      var Value := Cardinal(FCLUT[P]) or (Cardinal(FCLUT[P + 1]) shl 8);
      if Size = 4 then
        Value := Value or (Cardinal(FCLUT[P + 2]) shl 16) or (Cardinal(FCLUT[P + 3]) shl 24);
      FCLUTColors[I] := DecodeColor(Value, Format);
    end;
    FCLUTFormat := Format;
    FCLUTDirty := False;
  end;
end;

function TPSPGE.Texture(U, V: Double): Cardinal;
begin
  var Width := Integer(FTexture.Width);
  var Height := Integer(FTexture.Height);
  if (Width > 512) or (Height > 512) then
    raise EPSPInstruction.Create('PSP: invalid GE texture size');
  var X := Integer(Floor(U));
  var Y := Integer(Floor(V));
  if FTexture.ClampU then
    X := EnsureRange(X, 0, Width - 1)
  else
    X := X and (Width - 1);
  if FTexture.ClampV then
    Y := EnsureRange(Y, 0, Height - 1)
  else
    Y := Y and (Height - 1);
  var Format := FTexture.Format;
  if Format > 10 then
    raise EPSPInstruction.CreateFmt('PSP: invalid GE texture format %d', [Format]);
  if Format >= 8 then
  begin
    var BlockSize: Cardinal := 8;
    if Format <> 8 then
      BlockSize := 16;
    var Stride := FTexture.Stride;
    var Address := FTexture.Address;
    Inc(Address, (Cardinal(Y div 4) * Max(Cardinal(1), Stride div 4) + Cardinal(X div 4)) * BlockSize);
    var First := FMemory.ReadGE16(Address + 4);
    var Second := FMemory.ReadGE16(Address + 6);
    var Index := (FMemory.ReadGE8(Address + Cardinal(Y and 3)) shr ((X and 3) * 2)) and 3;
    var Colors: array[0..1, 0..2] of Cardinal;
    Colors[0, 0] := Expand5(First shr 11);
    Colors[1, 0] := Expand5(Second shr 11);
    Colors[0, 1] := ((First shr 5) and 63) * 255 div 63;
    Colors[1, 1] := ((Second shr 5) and 63) * 255 div 63;
    Colors[0, 2] := Expand5(First and 31);
    Colors[1, 2] := Expand5(Second and 31);
    Result := $FF000000;
    for var Component := 0 to 2 do
    begin
      var Value: Cardinal := 0;
      case Index of
        0, 1:
          Value := Colors[Index, Component];
        2:
          if (First > Second) or (Format <> 8) then
            Value := (Colors[0, Component] * 2 + Colors[1, Component]) div 3
          else
            Value := (Colors[0, Component] + Colors[1, Component]) div 2;
        3:
          if (First > Second) or (Format <> 8) then
            Value := (Colors[0, Component] + Colors[1, Component] * 2) div 3
          else
            Result := 0;
      end;
      Result := Result or (Value shl (Component * 8));
    end;
    if Format = 9 then
    begin
      var Alpha := (FMemory.ReadGE16(Address + 8 + Cardinal(Y and 3) * 2) shr ((X and 3) * 4)) and 15;
      Result := (Result and $FFFFFF) or (Alpha * 17 shl 24);
    end
    else if Format = 10 then
    begin
      var FirstAlpha := Cardinal(FMemory.ReadGE8(Address + 14));
      var SecondAlpha := Cardinal(FMemory.ReadGE8(Address + 15));
      var Bits := UInt64(FMemory.ReadGE32(Address + 8)) or (UInt64(FMemory.ReadGE16(Address + 12)) shl 32);
      var AlphaIndex := (Bits shr (((Y and 3) * 4 + (X and 3)) * 3)) and 7;
      var Alpha: Cardinal;
      if AlphaIndex = 0 then
        Alpha := FirstAlpha
      else if AlphaIndex = 1 then
        Alpha := SecondAlpha
      else if FirstAlpha > SecondAlpha then
        Alpha := ((8 - AlphaIndex) * FirstAlpha + (AlphaIndex - 1) * SecondAlpha) div 7
      else if AlphaIndex = 6 then
        Alpha := 0
      else if AlphaIndex = 7 then
        Alpha := 255
      else
        Alpha := ((6 - AlphaIndex) * FirstAlpha + (AlphaIndex - 1) * SecondAlpha) div 5;
      Result := (Result and $FFFFFF) or (Alpha shl 24);
    end;
    Exit;
  end;
  var BitsPerPixel := Integer(FTexture.BitsPerPixel);
  var RowBytes := FTexture.RowBytes;
  var ByteX := Cardinal(X * BitsPerPixel div 8);
  var Offset := Cardinal(Y) * RowBytes + ByteX;
  if FTexture.Swizzled then
    Offset := (Cardinal(Y) div 8) * RowBytes * 8 + (ByteX div 16) * 128 + (Cardinal(Y) mod 8) * 16 + ByteX mod 16;
  var Address := FTexture.Address;
  Inc(Address, Offset);
  var Value: Cardinal;
  case BitsPerPixel of
    4:
      Value := (FMemory.ReadGE8(Address) shr ((X and 1) * 4)) and 15;
    8:
      Value := FMemory.ReadGE8(Address);
    16:
      Value := FMemory.ReadGE16(Address);
  else
    Value := FMemory.ReadGE32(Address);
  end;
  if Format < 4 then
    Exit(DecodeColor(Value, Format));
  var Index := ((Value shr FTexture.CLUTShift) and FTexture.CLUTMask) or FTexture.CLUTStart;
  Result := FCLUTColors[Index and FTexture.CLUTIndexMask];
end;

function Compare(A, B: Cardinal; Kind: Cardinal): Boolean;
begin
  case Kind of
    0:
      Result := False;
    1:
      Result := True;
    2:
      Result := A = B;
    3:
      Result := A <> B;
    4:
      Result := A < B;
    5:
      Result := A <= B;
    6:
      Result := A > B;
  else
    Result := A >= B;
  end;
end;

function GEStorageAddress(Address: Cardinal): Cardinal;
begin
  Result := Address and $3FFFFFFF;
  if (Result >= PSPVRAMBase) and (Result < PSPVRAMBase + $1000000) then
    Result := PSPVRAMBase or (Result and $1FFFFF);
end;

function TPSPGE.TextureReadRange(out Address, Size: Cardinal): Boolean;
begin
  Result:=False;Address:=0;Size:=0;
  var Source:=TPSPMemory.GEAddress(FTexture.Address);
  if (FTexture.Stride<FTexture.Width) or TPSPMemory.IsDepthMirror(Source) then Exit;
  var RowBytes:UInt64:=(UInt64(FTexture.Width)*FTexture.BitsPerPixel+7) div 8;
  var Span:=UInt64(FTexture.Height-1)*FTexture.RowBytes+RowBytes;
  if FTexture.Swizzled then
    Span:=UInt64((FTexture.Height-1) div 8)*FTexture.RowBytes*8+
      ((RowBytes-1) div 16)*128+UInt64((FTexture.Height-1) and 7)*16+((RowBytes-1) and 15)+1;
  if FTexture.Format in [8..10] then
  begin
    var BlockBytes:Cardinal:=16;if FTexture.Format=8 then BlockBytes:=8;
    Span:=(UInt64((FTexture.Height+3) div 4)-1)*((FTexture.Stride+3) div 4)*BlockBytes+
      UInt64((FTexture.Width+3) div 4)*BlockBytes;
  end;
  if (Span=0) or (Span>High(Cardinal)) or not FMemory.IsValid(Source,Cardinal(Span)) then Exit;
  Address:=GEStorageAddress(Source);Size:=Cardinal(Span);Result:=True;
end;

procedure TPSPGE.Pixel(X, Y: Integer; Z: Double; Color: Cardinal);
begin
  if (X < 0) or (Y < 0) or (X > 1023) or (Y > 1023) then
    Exit;
  if (X < Integer(FRegisters[$D4] and $3FF)) or (Y < Integer((FRegisters[$D4] shr 10) and $3FF)) or
    (X > Integer(FRegisters[$D5] and $3FF)) or (Y > Integer((FRegisters[$D5] shr 10) and $3FF)) then
    Exit;
  var Clear := FRegisters[$D3] and 1 <> 0;
  var Format := FRegisters[$D2] and 3;
  var Bytes: Cardinal := 2;
  if Format = 3 then
    Bytes := 4;
  var Stride := FRegisters[$9D] and $7FC;
  if (Stride = 0) or (Cardinal(X) >= Stride) then
    Exit;
  var Address := GEStorageAddress(PSPVRAMBase + (FRegisters[$9C] and $1FFFF0) + (Cardinal(Y) * Stride + Cardinal(X)) * Bytes);
  if not FMemory.IsValid(Address, Bytes) then
    Exit;
  var WriteMask := (FRegisters[$E8] and $FFFFFF) or ((FRegisters[$E9] and $FF) shl 24);
  if Clear then
  begin
    WriteMask := $FFFFFFFF;
    if FRegisters[$D3] and $100 <> 0 then
      WriteMask := WriteMask and $FF000000;
    if FRegisters[$D3] and $200 <> 0 then
      WriteMask := WriteMask and $00FFFFFF;
  end;
  var Blending := not Clear and (FRegisters[$21] and 1 <> 0);
  var StandardAlpha := FRegisters[$DF] and $7FF = $32;
  var IdentityBlend := Blending and StandardAlpha and (Color shr 24 = 255);
  var Old: Cardinal := 0;
  if (WriteMask <> 0) or (Blending and not IdentityBlend) then
    if Bytes = 4 then
      Old := FMemory.Read32(Address)
    else
      Old := DecodeColor(FMemory.Read16(Address), Format);
  if not Clear and (FRegisters[$22] and 1 <> 0) then
  begin
    var Test := FRegisters[$DB];
    var Mask := (Test shr 16) and $FF;
    if not Compare((Color shr 24) and Mask, (Test shr 8) and Mask, Test and 7) then
      Exit;
  end;
  var DepthTest := not Clear and (FRegisters[$23] and 1 <> 0);
  var DepthWrite := (not Clear and (FRegisters[$E7] and 1 = 0)) or (Clear and (FRegisters[$D3] and $400 <> 0));
  var Depth: Cardinal := 0;
  var DepthAddress: Cardinal := 0;
  if DepthTest or DepthWrite then
  begin
    Depth := Cardinal(EnsureRange(Round(Z), Int64(0), Int64(65535)));
    DepthAddress := FMemory.DepthAddress(PSPVRAMBase + (FRegisters[$9E] and $1FFFF0) +
      (Cardinal(Y) * (FRegisters[$9F] and $7FC) + Cardinal(X)) * 2, Format=3);
    if DepthTest and not Compare(Depth, FMemory.Read16(DepthAddress), FRegisters[$DE] and 7) then
      Exit;
  end;
  if Blending and StandardAlpha and (Color shr 24 = 0) then
    Color := Old and $FFFFFF
  else if Blending and not IdentityBlend then
  begin
    var Blended: Cardinal := 0;
    var SourceAlpha := Integer(Color shr 24);
    var DestAlpha := Integer(Old shr 24);
    var SrcKind := FRegisters[$DF] and 15;
    var DstKind := (FRegisters[$DF] shr 4) and 15;
    var Equation := (FRegisters[$DF] shr 8) and 7;
    for var Component := 0 to 2 do
    begin
      var Src := Integer((Color shr (Component * 8)) and $FF);
      var Dst := Integer((Old shr (Component * 8)) and $FF);
      var SF, DF: Integer;
      case SrcKind of
        0:
          SF := Dst;
        1:
          SF := 255 - Dst;
        2:
          SF := SourceAlpha;
        3:
          SF := 255 - SourceAlpha;
        4:
          SF := DestAlpha;
        5:
          SF := 255 - DestAlpha;
        6:
          SF := SourceAlpha * 2;
        7:
          SF := 255 - SourceAlpha * 2;
        8:
          SF := DestAlpha * 2;
        9:
          SF := 255 - DestAlpha * 2;
        10:
          SF := (FRegisters[$E0] shr (Component * 8)) and $FF;
      else
        raise EPSPInstruction.CreateFmt('PSP: GE blend factor %d is not implemented', [SrcKind]);
      end;
      case DstKind of
        0:
          DF := Src;
        1:
          DF := 255 - Src;
        2:
          DF := SourceAlpha;
        3:
          DF := 255 - SourceAlpha;
        4:
          DF := DestAlpha;
        5:
          DF := 255 - DestAlpha;
        6:
          DF := SourceAlpha * 2;
        7:
          DF := 255 - SourceAlpha * 2;
        8:
          DF := DestAlpha * 2;
        9:
          DF := 255 - DestAlpha * 2;
        10:
          DF := (FRegisters[$E1] shr (Component * 8)) and $FF;
      else
        raise EPSPInstruction.CreateFmt('PSP: GE blend factor %d is not implemented', [DstKind]);
      end;
      var SourceTerm := ((Src * 2 + 1) * (Abs(SF) * 2 + 1)) shr 10;
      var DestTerm := ((Dst * 2 + 1) * (Abs(DF) * 2 + 1)) shr 10;
      if SF < 0 then
        SourceTerm := -SourceTerm;
      if DF < 0 then
        DestTerm := -DestTerm;
      var OutValue: Integer;
      case Equation of
        0:
          OutValue := SourceTerm + DestTerm;
        1:
          OutValue := SourceTerm - DestTerm;
        2:
          OutValue := DestTerm - SourceTerm;
        3:
          OutValue := Min(Src, Dst);
        4:
          OutValue := Max(Src, Dst);
        5:
          OutValue := Abs(Src - Dst);
      else
        raise EPSPInstruction.Create('PSP: invalid GE blend equation');
      end;
      Blended := Blended or (Cardinal(EnsureRange(OutValue, 0, 255)) shl (Component * 8));
    end;
    Color := Blended or (Color and $FF000000);
  end;
  if WriteMask <> 0 then
    Color := (Color and not WriteMask) or (Old and WriteMask);
  if Bytes = 4 then
    FMemory.Write32(Address, Color)
  else
    FMemory.Write16(Address, EncodeColor(Color, Format));
  if DepthWrite and FMemory.IsValid(DepthAddress, 2) then
    FMemory.Write16(DepthAddress, Depth);
end;

function TPSPGE.SolidSpan(Left, Right, Y: Integer; Z: Double; Color: Cardinal;
  Colors: PCardinal; DepthValues: PDouble): Boolean;
begin
  Result := False;
  if not FOptimizedRasterization then Exit;
  Result := True;
  if (Y < 0) or (Y > 1023) or
    (Y < Integer((FRegisters[$D4] shr 10) and $3FF)) or
    (Y > Integer((FRegisters[$D5] shr 10) and $3FF)) then Exit;
  var Stride := FRegisters[$9D] and $7FC;
  var OriginalLeft := Left;
  Left := Max(Left, Integer(FRegisters[$D4] and $3FF));
  Right := Min(Right, Min(Integer(FRegisters[$D5] and $3FF), Integer(Stride) - 1));
  if Left > Right then Exit;
  if Colors <> nil then Inc(Colors, Left - OriginalLeft);
  if DepthValues <> nil then Inc(DepthValues, Left - OriginalLeft);
  var Clear := FRegisters[$D3] and 1 <> 0;
  var AlphaTest := not Clear and (FRegisters[$22] and 1 <> 0);
  var AlphaState := FRegisters[$DB];
  var AlphaMask := (AlphaState shr 16) and $FF;
  if AlphaTest and (Colors = nil) then
  begin
    var Test := FRegisters[$DB];
    var Mask := (Test shr 16) and $FF;
    if not Compare((Color shr 24) and Mask, (Test shr 8) and Mask, Test and 7) then Exit;
  end;
  Result := False;
  var Blending := not Clear and (FRegisters[$21] and 1 <> 0);
  if Blending and (FRegisters[$DF] and $7FF <> $32) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileSolidRejects[2]);{$ENDIF}
    Exit;
  end;
  Blending := Blending and ((Colors <> nil) or (Color shr 24 <> 255));
  var WriteMask := (FRegisters[$E8] and $FFFFFF) or ((FRegisters[$E9] and $FF) shl 24);
  if Clear then
  begin
    WriteMask := $FFFFFFFF;
    if FRegisters[$D3] and $100 <> 0 then WriteMask := WriteMask and $FF000000;
    if FRegisters[$D3] and $200 <> 0 then WriteMask := WriteMask and $00FFFFFF;
  end;
  var Format := FRegisters[$D2] and 3;
  var Bytes: Cardinal := 2;
  if Format = 3 then Bytes := 4;
  var Width := Right - Left + 1;
  var Address := GEStorageAddress(PSPVRAMBase + (FRegisters[$9C] and $1FFFF0) + (Cardinal(Y) * Stride + Cardinal(Left)) * Bytes);
  if not FMemory.IsValid(Address, Cardinal(Width) * Bytes) then Exit;
  var DepthTest := not Clear and (FRegisters[$23] and 1 <> 0);
  var DepthWrite := (not Clear and (FRegisters[$E7] and 1 = 0)) or (Clear and (FRegisters[$D3] and $400 <> 0));
  var DepthAddress := PSPVRAMBase + (FRegisters[$9E] and $1FFFF0) +
    (Cardinal(Y) * (FRegisters[$9F] and $7FC) + Cardinal(Left)) * 2;
  if DepthTest or DepthWrite then
  begin
    var StoredFirst, StoredSize: Cardinal;
    if not FMemory.DepthStorageBounds(DepthAddress,Cardinal(Width)*2,StoredFirst,StoredSize) then Exit;
    // Use the physical permutation envelope when rejecting feedback.
    if (UInt64(Address) < UInt64(StoredFirst) + StoredSize) and
      (UInt64(StoredFirst) < UInt64(Address) + Cardinal(Width) * Bytes) then
    begin
      {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileSolidRejects[5]);{$ENDIF}
      Exit;
    end;
  end;
  var Depth: Word := 0;
  var DepthReady := not ((Colors <> nil) and AlphaTest);
  if (DepthTest or DepthWrite) and (DepthValues = nil) and DepthReady then
    Depth := Word(EnsureRange(Round(Z), Int64(0), Int64(65535)));
  var DepthData := FDepthRow;
  var BufferedDepth := DepthTest or (DepthWrite and ((DepthValues <> nil) or ((Colors <> nil) and AlphaTest)));
  if BufferedDepth then FMemory.ReadDepthInto(DepthAddress,Width*2,Format=3,DepthData);
  var DepthFunction := FRegisters[$DE] and 7;
  if (WriteMask = 0) and not Blending and (Colors = nil) and (DepthValues = nil) then
  begin
    var PackedColor := Color;
    if Format <> 3 then PackedColor := EncodeColor(Color, Format);
    var X := 0;
    while X < Width do
    begin
      if DepthTest and not Compare(Depth, PWord(@DepthData[0])[X], DepthFunction) then
      begin
        Inc(X);
        Continue;
      end;
      var First := X;
      Inc(X);
      while X < Width do
      begin
        if DepthTest and not Compare(Depth, PWord(@DepthData[0])[X], DepthFunction) then Break;
        Inc(X);
      end;
      if Format = 3 then FMemory.Fill32(Address + Cardinal(First) * Bytes, X - First, PackedColor)
      else FMemory.Fill16(Address + Cardinal(First) * Bytes, X - First, Word(PackedColor));
      if DepthWrite then FMemory.FillDepth16(DepthAddress + Cardinal(First) * 2, X - First, Depth,Format=3);
    end;
    Exit(True);
  end;
  var DestData := FColorRow;
  FMemory.ReadInto(Address,Cardinal(Width)*Bytes,DestData);
  var Dirty := False;
  for var X := 0 to Width - 1 do
  begin
    var Source := Color;
    if Colors <> nil then Source := Colors[X];
    if AlphaTest and (Colors <> nil) and
      not Compare((Source shr 24) and AlphaMask, (AlphaState shr 8) and AlphaMask, AlphaState and 7) then Continue;
    if (DepthTest or DepthWrite) and (DepthValues = nil) and not DepthReady then
    begin
      Depth := Word(EnsureRange(Round(Z), Int64(0), Int64(65535)));
      DepthReady := True;
    end;
    if (DepthTest or DepthWrite) and (DepthValues <> nil) then
      Depth := Word(EnsureRange(Round(DepthValues[X]), Int64(0), Int64(65535)));
    if DepthTest and not Compare(Depth, PWord(@DepthData[0])[X], DepthFunction) then Continue;
    var Old: Cardinal;
    if Format = 3 then Old := PCardinal(@DestData[0])[X]
    else Old := DecodeColor(PWord(@DestData[0])[X], Format);
    var Output := Source;
    if Blending and (Source shr 24 <> 255) then
    begin
      var Alpha := Source shr 24;
      if Alpha = 0 then Output := Old and $FFFFFF
      else
      begin
        Output := Source and $FF000000;
        for var Lane := 0 to 2 do
        begin
          var Src := (Source shr (Lane * 8)) and $FF;
          var Dst := (Old shr (Lane * 8)) and $FF;
          var Value := (((Src * 2 + 1) * (Alpha * 2 + 1)) shr 10) +
            (((Dst * 2 + 1) * ((255 - Alpha) * 2 + 1)) shr 10);
          Output := Output or (Min(Cardinal(255), Value) shl (Lane * 8));
        end;
      end;
    end;
    Output := (Output and not WriteMask) or (Old and WriteMask);
    if Format = 3 then PCardinal(@DestData[0])[X] := Output
    else PWord(@DestData[0])[X] := EncodeColor(Output, Format);
    if DepthWrite and BufferedDepth then PWord(@DepthData[0])[X] := Depth;
    Dirty := True;
  end;
  if Dirty then
  begin
    FMemory.WriteFrom(Address,Cardinal(Width)*Bytes,DestData);
    if DepthWrite then
      if BufferedDepth then FMemory.WriteDepthFrom(DepthAddress,Width*2,Format=3,DepthData)
      else FMemory.FillDepth16(DepthAddress, Width, Depth,Format=3);
  end;
  Result := True;
end;

function TPSPGE.Shade(Color: Cardinal; U, V: Double): Cardinal;
begin
  if (FRegisters[$1E] and 1 <> 0) and (FRegisters[$D3] and 1 = 0) then
  begin
    var Texel := Texture(U, V);
    var FunctionCode := FRegisters[$C9] and 7;
    if FunctionCode = 3 then
    begin
      if FRegisters[$C9] and $100 <> 0 then
        Exit(Texel);
      Exit((Texel and $FFFFFF) or (Color and $FF000000));
    end;
    if (FunctionCode = 0) and (Color and $FFFFFF = $FFFFFF) then
    begin
      if FRegisters[$C9] and $100 = 0 then
        Exit((Texel and $FFFFFF) or (Color and $FF000000));
      var Alpha := ((Texel shr 24) * (Color shr 24)) div 255;
      Exit((Texel and $FFFFFF) or (Alpha shl 24));
    end;
    var Textured: Cardinal := 0;
    for var I := 0 to 3 do
    begin
      var ComponentValue := Integer((Texel shr (I * 8)) and $FF);
      var Original := Integer((Color shr (I * 8)) and $FF);
      if (I = 3) and (FRegisters[$C9] and $100 = 0) then
        ComponentValue := Original
      else
        case FunctionCode of
          0:
            ComponentValue := (ComponentValue * Original) div 255;
          3:
            ;
          4:
            ComponentValue := Min(255, ComponentValue + Original);
        else
          raise EPSPInstruction.CreateFmt('PSP: GE texture function %d is not implemented', [FunctionCode]);
        end;
      Textured := Textured or (Cardinal(ComponentValue) shl (I * 8));
    end;
    Color := Textured;
  end;
  Result := Color;
end;

function TPSPGE.PerspectiveState(const A,B,C:TPSPGEVertex):TPSPGEUV;
begin
  Result.Q[0]:=A.ReciprocalW;Result.Q[1]:=B.ReciprocalW;Result.Q[2]:=C.ReciprocalW;
  Result.S[0]:=GEProduct(Double(GETruncate(Single(A.U)))*Result.Q[0]);
  Result.S[1]:=GEProduct(Double(GETruncate(Single(B.U)))*Result.Q[1]);
  Result.S[2]:=GEProduct(Double(GETruncate(Single(C.U)))*Result.Q[2]);
  Result.T[0]:=GEProduct(Double(GETruncate(Single(A.V)))*Result.Q[0]);
  Result.T[1]:=GEProduct(Double(GETruncate(Single(B.V)))*Result.Q[1]);
  Result.T[2]:=GEProduct(Double(GETruncate(Single(C.V)))*Result.Q[2]);
  Result.FlatQ:=(Result.Q[0]=Result.Q[1]) and (Result.Q[0]=Result.Q[2]);
  Result.CachedQ:=0;Result.CachedReciprocal:=0;
  if Result.FlatQ then
  begin
    Result.CachedQ:=GETruncate(Single(Result.Q[0]));
    if Result.CachedQ>0 then Result.CachedReciprocal:=GEReciprocal(Result.CachedQ);
  end;
end;

function TPSPGE.ShadePerspective(Color:Cardinal; WA,WB,WC:Double; var UV:TPSPGEUV):Cardinal;
begin
  var Q:Single;
  if UV.FlatQ then Q:=UV.CachedQ
  else Q:=GETruncate(Single(UV.Q[0]*WA+UV.Q[1]*WB+UV.Q[2]*WC));
  var U,V:Single;
  if Q>0 then
  begin
    if Q<>UV.CachedQ then
    begin UV.CachedQ:=Q;UV.CachedReciprocal:=GEReciprocal(Q) end;
    var Reciprocal:Double:=UV.CachedReciprocal;
    U:=GEUVProduct(Double(GETruncate(Single(UV.S[0]*WA+UV.S[1]*WB+UV.S[2]*WC)))*Reciprocal);
    V:=GEUVProduct(Double(GETruncate(Single(UV.T[0]*WA+UV.T[1]*WB+UV.T[2]*WC)))*Reciprocal);
  end
  else
  begin
    // A nonpositive projected Q saturates to the final texel on a PSP,
    // including in wrap mode (pspautotests gpu/texmtx/negq).
    U:=(1-1/65536)*FTexture.Width;V:=(1-1/65536)*FTexture.Height;
  end;
  Result:=Shade(Color,U,V);
end;

procedure TPSPGE.Line(A, B: TPSPGEVertex);
var
  Start, Finish: Double;

  function Clip(P, Q: Double): Boolean;
  begin
    if P = 0 then
      Exit(Q >= 0);
    var R := Q / P;
    if P < 0 then
    begin
      if R > Finish then
        Exit(False);
      Start := Max(Start, R);
    end
    else
    begin
      if R < Start then
        Exit(False);
      Finish := Min(Finish, R);
    end;
    Result := True;
  end;

begin
  var DX := B.X - A.X;
  var DY := B.Y - A.Y;
  Start := 0;
  Finish := 1;
  if not Clip(-DX, A.X) or not Clip(DX, 1024 - A.X) or
    not Clip(-DY, A.Y) or not Clip(DY, 1024 - A.Y) then
    Exit;
  var Steps := Integer(Ceil(Max(Abs(DX), Abs(DY)) * (Finish - Start)));
  if Steps = 0 then
    Steps := 1;
  var Perspective:=(FRegisters[$12] and $800000=0) and (FRegisters[$1E] and 1<>0) and (FRegisters[$D3] and 1=0);
  var UV:TPSPGEUV;
  if Perspective then UV:=PerspectiveState(A,B,B);
  for var I := 0 to Steps - 1 do
  begin
    var T := Start + (Finish - Start) * I / Steps;
    var Color := B.Color;
    if FRegisters[$50] and 1 <> 0 then
    begin
      Color := 0;
      for var Lane := 0 to 3 do
      begin
        var Component := Round(((A.Color shr (Lane * 8)) and $FF) * (1 - T) + ((B.Color shr (Lane * 8)) and $FF) * T);
        Color := Color or (Cardinal(EnsureRange(Component, Int64(0), Int64(255))) shl (Lane * 8));
      end;
    end;
    if Perspective then Color:=ShadePerspective(Color,1-T,T,0,UV)
    else Color:=Shade(Color,A.U*(1-T)+B.U*T,A.V*(1-T)+B.V*T);
    Pixel(Floor(A.X + DX * T), Floor(A.Y + DY * T), A.Z * (1 - T) + B.Z * T,Color);
  end;
end;

// Clip a scanline using the same double-precision edge expression and top-left
// rule as the general rasterizer. Binary search avoids rounding new endpoints.
procedure ClipTriangleEdge(const P, Q: TPSPGEVertex; Y: Integer; var Left, Right: Integer);
  function Inside(X: Integer): Boolean;
  var E: Double;
  begin
    E := (Q.X - P.X) * (Y + 0.5 - P.Y) - (Q.Y - P.Y) * (X + 0.5 - P.X);
    Result := (E > 0) or ((E = 0) and ((Q.Y < P.Y) or ((Q.Y = P.Y) and (Q.X > P.X))));
  end;
begin
  if Left > Right then Exit;
  if Q.Y = P.Y then
  begin
    if not Inside(Left) then Right := Left - 1;
    Exit;
  end;
  var Low := Left;
  var High := Right + 1;
  while Low < High do
  begin
    var Middle := Low + (High - Low) div 2;
    var Accepted := Inside(Middle);
    if Accepted = (Q.Y < P.Y) then High := Middle
    else Low := Middle + 1;
  end;
  if Q.Y < P.Y then Left := Low else Right := Low - 1;
end;

procedure TPSPGE.Triangle(A, B, C: TPSPGEVertex);
begin
  // Preserve the provoking vertex before normalizing triangle winding.
  var ProvokingColor := C.Color;
  var FlatColor := (FRegisters[$50] and 1 = 0) or ((A.Color = B.Color) and (A.Color = C.Color));
  var FlatDepth := (A.Z = B.Z) and (A.Z = C.Z);
  var Textured := (FRegisters[$1E] and 1 <> 0) and (FRegisters[$D3] and 1 = 0);
  var Interpolate := not FlatColor or not FlatDepth or Textured;
  {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then
    Inc(PSPProfileTriangleTypes[Ord(FlatColor) or (Ord(FlatDepth) shl 1) or (Ord(Textured) shl 2)]);{$ENDIF}
  var Area := (B.X - A.X) * (C.Y - A.Y) - (B.Y - A.Y) * (C.X - A.X);
  if Abs(Area) < 1E-8 then Exit;
  if (FRegisters[$1D] and 1<>0) and (FRegisters[$D3] and 1=0) then
    if ((FRegisters[$9B] and 1=0) and (Area>0)) or
      ((FRegisters[$9B] and 1<>0) and (Area<0)) then Exit;
  if Area < 0 then
  begin
    var Temp := B;
    B := C;
    C := Temp;
    Area := -Area;
  end;
  var MinX := Max(Integer(FRegisters[$D4] and $3FF), Integer(Floor(Min(A.X, Min(B.X, C.X)))));
  var MinY := Max(Integer((FRegisters[$D4] shr 10) and $3FF), Integer(Floor(Min(A.Y, Min(B.Y, C.Y)))));
  var MaxX := Min(Integer(FRegisters[$D5] and $3FF), Integer(Ceil(Max(A.X, Max(B.X, C.X)))) - 1);
  var MaxY := Min(Integer((FRegisters[$D5] shr 10) and $3FF), Integer(Ceil(Max(A.Y, Max(B.Y, C.Y)))) - 1);
  if (MinX > MaxX) or (MinY > MaxY) then Exit;
  var InverseArea := 1.0 / Area;
  var Perspective:=Textured and (FRegisters[$12] and $800000=0);
  var UV:TPSPGEUV;
  if Perspective then UV:=PerspectiveState(A,B,C);
  var BufferedTexture:=False;
  if FOptimizedRasterization and Textured then
  begin
    var SourceBase, SourceSize:Cardinal;
    var Bytes:Cardinal:=2;if FRegisters[$D2] and 3=3 then Bytes:=4;
    var Stride:=FRegisters[$9D] and $7FC;
    var ColorAddress:=GEStorageAddress(PSPVRAMBase+(FRegisters[$9C] and $1FFFF0)+
      (Cardinal(MinY)*Stride+Cardinal(MinX))*Bytes);
    var ColorSize:Cardinal:=(Cardinal(MaxY-MinY)*Stride+Cardinal(MaxX-MinX+1))*Bytes;
    if TextureReadRange(SourceBase,SourceSize) and FMemory.IsValid(ColorAddress,ColorSize) then
    begin
      BufferedTexture:=not ((UInt64(SourceBase)<UInt64(ColorAddress)+ColorSize) and
        (UInt64(ColorAddress)<UInt64(SourceBase)+SourceSize));
      if BufferedTexture and (FRegisters[$E7] and 1=0) then
      begin
        var DepthStride:=FRegisters[$9F] and $7FC;
        var DepthAddress:=PSPVRAMBase+(FRegisters[$9E] and $1FFFF0)+
          (Cardinal(MinY)*DepthStride+Cardinal(MinX))*2;
        var DepthSize:Cardinal:=(Cardinal(MaxY-MinY)*DepthStride+Cardinal(MaxX-MinX+1))*2;
        var StoredFirst, StoredSize:Cardinal;
        BufferedTexture:=FMemory.DepthStorageBounds(DepthAddress,DepthSize,StoredFirst,StoredSize);
        if BufferedTexture then BufferedTexture:=not ((UInt64(SourceBase)<UInt64(StoredFirst)+StoredSize) and
          (UInt64(StoredFirst)<UInt64(SourceBase)+SourceSize));
      end;
    end;
  end;
  if FOptimizedRasterization and (not Textured or BufferedTexture) then
  begin
    for var Y := MinY to MaxY do
    begin
      var Left := MinX;
      var Right := MaxX;
      ClipTriangleEdge(B, C, Y, Left, Right);
      ClipTriangleEdge(C, A, Y, Left, Right);
      ClipTriangleEdge(A, B, Y, Left, Right);
      if Left > Right then Continue;
      var Colors: PCardinal := nil;
      var Depths: PDouble := nil;
      if not FlatColor or Textured then Colors := @FSpanColors[0];
      if not FlatDepth then Depths := @FSpanDepth[0];
      if Interpolate then
        for var X := Left to Right do
        begin
          var PX := X + 0.5;
          var PY := Y + 0.5;
          var EA := (C.X - B.X) * (PY - B.Y) - (C.Y - B.Y) * (PX - B.X);
          var EB := (A.X - C.X) * (PY - C.Y) - (A.Y - C.Y) * (PX - C.X);
          var EC := (B.X - A.X) * (PY - A.Y) - (B.Y - A.Y) * (PX - A.X);
          // Match the general path's explicit Double stores on x87 as well.
          var WA: Double := EA * InverseArea;
          var WB: Double := EB * InverseArea;
          var WC: Double := EC * InverseArea;
          var Color:=ProvokingColor;
          if not FlatColor then
          begin
            Color := 0;
            for var Lane := 0 to 3 do
            begin
              var Value := Round(((A.Color shr (Lane * 8)) and $FF) * WA +
                ((B.Color shr (Lane * 8)) and $FF) * WB + ((C.Color shr (Lane * 8)) and $FF) * WC);
              Color := Color or (Cardinal(EnsureRange(Value, Int64(0), Int64(255))) shl (Lane * 8));
            end;
          end;
          if Perspective then Color:=ShadePerspective(Color,WA,WB,WC,UV)
          else if Textured then Color:=Shade(Color,A.U*WA+B.U*WB+C.U*WC,A.V*WA+B.V*WB+C.V*WC);
          if Colors<>nil then FSpanColors[X-Left]:=Color;
          if not FlatDepth then FSpanDepth[X - Left] := A.Z * WA + B.Z * WB + C.Z * WC;
        end;
      if not SolidSpan(Left, Right, Y, A.Z, ProvokingColor, Colors, Depths) then
        for var X := Left to Right do
        begin
          var Color := ProvokingColor;
          var Depth := A.Z;
          if Colors<>nil then Color := FSpanColors[X - Left];
          if not FlatDepth then Depth := FSpanDepth[X - Left];
          Pixel(X, Y, Depth, Color);
        end;
    end;
    Exit;
  end;
  for var Y := MinY to MaxY do
    for var X := MinX to MaxX do
    begin
      var PX := X + 0.5;
      var PY := Y + 0.5;
      var EA := (C.X - B.X) * (PY - B.Y) - (C.Y - B.Y) * (PX - B.X);
      var EB := (A.X - C.X) * (PY - C.Y) - (A.Y - C.Y) * (PX - C.X);
      var EC := (B.X - A.X) * (PY - A.Y) - (B.Y - A.Y) * (PX - A.X);
      if (EA < 0) or (EB < 0) or (EC < 0) then
        Continue;
      if (EA = 0) and not ((C.Y < B.Y) or ((C.Y = B.Y) and (C.X > B.X))) then
        Continue;
      if (EB = 0) and not ((A.Y < C.Y) or ((A.Y = C.Y) and (A.X > C.X))) then
        Continue;
      if (EC = 0) and not ((B.Y < A.Y) or ((B.Y = A.Y) and (B.X > A.X))) then
        Continue;
      var WA: Double := 0;
      var WB: Double := 0;
      var WC: Double := 0;
      if Interpolate then
      begin
        WA := EA * InverseArea;
        WB := EB * InverseArea;
        WC := EC * InverseArea
      end;
      var Color := ProvokingColor;
      if not FlatColor then
      begin
        Color := 0;
        for var I := 0 to 3 do
        begin
          var Value := Round(((A.Color shr (I * 8)) and $FF) * WA + ((B.Color shr (I * 8)) and $FF) * WB + ((C.Color shr (I * 8)) and $FF) * WC);
          Color := Color or (Cardinal(EnsureRange(Value, Int64(0), Int64(255))) shl (I * 8));
        end;
      end;
      if Perspective then Color:=ShadePerspective(Color,WA,WB,WC,UV)
      else if Textured then
        Color := Shade(Color, A.U * WA + B.U * WB + C.U * WC, A.V * WA + B.V * WB + C.V * WC);
      var Depth := A.Z;
      if not FlatDepth then
        Depth := A.Z * WA + B.Z * WB + C.Z * WC;
      Pixel(X, Y, Depth, Color);
    end;
end;

function TPSPGE.BlitSprite(const A, C: TPSPGEVertex; MinX, MinY, MaxX, MaxY: Integer): Boolean;
var
  SourceX: array[0..1023] of Cardinal;
  Texels: array[0..511] of Cardinal;
  UsedX: array[0..511] of Cardinal;
  SeenX: array[0..511] of Boolean;
begin
  Result := False;
  if not FOptimizedRasterization or TPSPMemory.IsDepthMirror(TPSPMemory.GEAddress(FTexture.Address)) or not (FTexture.Format in [0..7]) or
    (FRegisters[$E8] and $FFFFFF <> 0) or (FRegisters[$E9] and $FF <> 0) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[1]);{$ENDIF}
    Exit;
  end;
  var FunctionCode := FRegisters[$C9] and 7;
  if not (FunctionCode in [0,3]) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[2]);{$ENDIF}
    Exit;
  end;
  var Blending := FRegisters[$21] and 1 <> 0;
  if Blending and (FRegisters[$DF] and $7FF <> $32) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[3]);{$ENDIF}
    Exit;
  end;
  if (FTexture.Width > 512) or (FTexture.Height > 512) or (FTexture.Stride < FTexture.Width) then
    Exit;
  var Stride := FRegisters[$9D] and $7FC;
  MaxX := Min(MaxX, Integer(Stride) - 1);
  if MaxX < MinX then
    Exit(True);
  var Width := MaxX - MinX + 1;
  var PixelFormat:=FRegisters[$D2] and 3;
  var PixelBytes:Cardinal:=2;if PixelFormat=3 then PixelBytes:=4;
  var Address := GEStorageAddress(PSPVRAMBase + (FRegisters[$9C] and $1FFFF0) + (Cardinal(MinY) * Stride + Cardinal(MinX)) * PixelBytes);
  var Span := (Cardinal(MaxY - MinY) * Stride + Cardinal(Width)) * PixelBytes;
  var RowSize := (FTexture.Width * FTexture.BitsPerPixel + 7) div 8;
  var SourceSpan := (FTexture.Height - 1) * FTexture.RowBytes + RowSize;
  if FTexture.Swizzled then
    SourceSpan := ((FTexture.Height - 1) div 8) * FTexture.RowBytes * 8 +
      ((RowSize - 1) div 16) * 128 + ((FTexture.Height - 1) and 7) * 16 + ((RowSize - 1) and 15) + 1;
  if not FMemory.IsValid(Address, Span) or not FMemory.IsValid(FTexture.Address, SourceSpan) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[4]);{$ENDIF}
    Exit;
  end;
  var DepthWrite := FRegisters[$E7] and 1 = 0;
  var DepthTest := FRegisters[$23] and 1 <> 0;
  var DepthFunction := FRegisters[$DE] and 7;
  var DepthStride := FRegisters[$9F] and $7FC;
  var DepthAddress := PSPVRAMBase + (FRegisters[$9E] and $1FFFF0) + (Cardinal(MinY) * DepthStride + Cardinal(MinX)) * 2;
  var DepthSpan := (Cardinal(MaxY - MinY) * DepthStride + Cardinal(Width)) * 2;
  var StoredFirst, StoredSize: Cardinal;
  if (DepthWrite or DepthTest) and not FMemory.DepthStorageBounds(DepthAddress,DepthSpan,StoredFirst,StoredSize) then Exit;
  var SourceBase := GEStorageAddress(FTexture.Address);
  var DestBase := Address and $1FFFFFFF;
  if (DepthWrite or DepthTest) and
    (UInt64(DestBase) < UInt64(StoredFirst) + StoredSize) and (UInt64(StoredFirst) < UInt64(DestBase) + Span) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[5]);{$ENDIF}
    Exit;
  end;
  if DepthWrite and (UInt64(SourceBase) < UInt64(StoredFirst) + StoredSize) and
    (UInt64(StoredFirst) < UInt64(SourceBase) + SourceSpan) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[6]);{$ENDIF}
    Exit;
  end;
  // Rendering into the sampled texture needs the general pixel ordering.
  if (UInt64(SourceBase) < UInt64(DestBase) + Span) and (UInt64(DestBase) < UInt64(SourceBase) + SourceSpan) then
  begin
    {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[7]);{$ENDIF}
    Exit;
  end;
  var DU := (C.U - A.U) / (C.X - A.X);
  var DV := (C.V - A.V) / (C.Y - A.Y);
  var FirstU := A.U + (MinX + 0.5 - A.X) * DU;
  FillChar(SeenX,SizeOf(SeenX),0);
  var UsedCount:=0;var FirstSample:=Cardinal(511);var LastSample:=Cardinal(0);
  for var X := 0 to Width - 1 do
  begin
    var Sample := Integer(Floor(FirstU + X * DU));
    if FTexture.ClampU then
      Sample := EnsureRange(Sample, 0, Integer(FTexture.Width) - 1)
    else
      Sample := Sample and (Integer(FTexture.Width) - 1);
    SourceX[X] := Sample;
    if not SeenX[Sample] then
    begin
      SeenX[Sample]:=True;UsedX[UsedCount]:=Sample;Inc(UsedCount);
      FirstSample:=Min(FirstSample,Cardinal(Sample));LastSample:=Max(LastSample,Cardinal(Sample));
    end;
  end;
  var SourceData := FTextureRow;
  var DestData := FColorRow;
  var DepthData := FDepthRow;
  var AlphaTest := FRegisters[$22] and 1 <> 0;
  var AlphaFunction := FRegisters[$DB] and 7;
  var AlphaMask := (FRegisters[$DB] shr 16) and $FF;
  var AlphaReference := ((FRegisters[$DB] shr 8) and $FF) and AlphaMask;
  var BufferedDepth:=DepthTest or (DepthWrite and AlphaTest);
  var Depth: Word := 0;
  var DepthReady := False;
  var PreviousY: Integer := -1;
  var TextureAlpha := FRegisters[$C9] and $100 <> 0;
  var Tint:=(FunctionCode=0) and (C.Color and $FFFFFF<>$FFFFFF);
  var Transform:=Tint or not TextureAlpha or ((FunctionCode=0) and (C.Color shr 24<>255));
  var FirstByte:=FirstSample*FTexture.BitsPerPixel div 8;
  var EndByte:=((LastSample+1)*FTexture.BitsPerPixel+7) div 8;
  for var Y := MinY to MaxY do
  begin
    var SampleY := Integer(Floor(A.V + (Y + 0.5 - A.Y) * DV));
    if FTexture.ClampV then
      SampleY := EnsureRange(SampleY, 0, Integer(FTexture.Height) - 1)
    else
      SampleY := SampleY and (Integer(FTexture.Height) - 1);
    if SampleY <> PreviousY then
    begin
      if not FTexture.Swizzled then
        FMemory.ReadInto(FTexture.Address + Cardinal(SampleY) * FTexture.RowBytes+FirstByte, EndByte-FirstByte, SourceData, FirstByte)
      else
      begin
        // A swizzled tile is sixteen bytes by eight rows. Gather the visible
        // row in tile-sized pieces, keeping guest bounds checks in the bus.
        var Column: Cardinal := FirstByte;
        while Column < EndByte do
        begin
          var Count := Min(Cardinal(16)-(Column and 15), EndByte - Column);
          var Tile := (Cardinal(SampleY) div 8) * FTexture.RowBytes * 8 +
            (Column div 16) * 128 + (Cardinal(SampleY) and 7) * 16+(Column and 15);
          FMemory.ReadInto(FTexture.Address + Tile, Count, SourceData, Column);
          Inc(Column, Count);
        end;
      end;
      if (FTexture.Format = 3) and not Transform then
        Move(SourceData[FirstByte], Texels[FirstSample], EndByte-FirstByte)
      else
        for var Used:=0 to UsedCount-1 do
        begin
          var SampleX:=UsedX[Used];var Color:Cardinal;
          if FTexture.Format=3 then Color:=PCardinal(@SourceData[0])[SampleX]
          else if FTexture.Format<3 then Color:=DecodeColor(PWord(@SourceData[0])[SampleX],FTexture.Format)
          else
          begin
            var Index: Cardinal;
            case FTexture.BitsPerPixel of
              4: Index := (SourceData[SampleX shr 1] shr ((SampleX and 1) * 4)) and 15;
              8: Index := SourceData[SampleX];
              16: Index := PWord(@SourceData[0])[SampleX];
            else
              Index := PCardinal(@SourceData[0])[SampleX];
            end;
            Color:=FCLUTColors[(((Index shr FTexture.CLUTShift) and FTexture.CLUTMask) or FTexture.CLUTStart) and FTexture.CLUTIndexMask];
          end;
          if Tint then
            Color:=(Color and $FF000000) or (((Color and 255)*(C.Color and 255)) div 255) or
              (((((Color shr 8) and 255)*((C.Color shr 8) and 255)) div 255) shl 8) or
              (((((Color shr 16) and 255)*((C.Color shr 16) and 255)) div 255) shl 16);
          if not TextureAlpha then Color:=(Color and $FFFFFF) or (C.Color and $FF000000)
          else if FunctionCode=0 then Color:=(Color and $FFFFFF) or ((((Color shr 24)*(C.Color shr 24)) div 255) shl 24);
          Texels[SampleX]:=Color;
        end;
      PreviousY := SampleY;
    end;
    if Blending or AlphaTest or DepthTest then
      FMemory.ReadInto(Address, Width * PixelBytes, DestData);
    if BufferedDepth then
      FMemory.ReadDepthInto(DepthAddress, Width * 2, PixelFormat=3, DepthData);
    var RowDirty := False;
    var Destination := PCardinal(@DestData[0]);
    for var X := 0 to Width - 1 do
    begin
      var Color := Texels[SourceX[X]];
      var Alpha := Color shr 24;
      if AlphaTest and not Compare(Alpha and AlphaMask, AlphaReference, AlphaFunction) then
        Continue;
      if DepthWrite or DepthTest then
      begin
        if not DepthReady then
        begin
          Depth := Word(EnsureRange(Round(C.Z), Int64(0), Int64(65535)));
          DepthReady := True;
        end;
      end;
      if DepthTest and not Compare(Depth,PWord(@DepthData[0])[X],DepthFunction) then Continue;
      RowDirty := True;
      if DepthWrite and BufferedDepth then PWord(@DepthData[0])[X] := Depth;
      if Blending and (Alpha <> 255) then
      begin
        var Old:Cardinal;
        if PixelFormat=3 then Old:=Destination[X]
        else Old:=DecodeColor(PWord(@DestData[0])[X],PixelFormat);
        if Alpha = 0 then
          Color := Old and $FFFFFF
        else
        begin
          var Blended := Color and $FF000000;
          for var Component := 0 to 2 do
          begin
            var Src := (Color shr (Component * 8)) and $FF;
            var Dst := (Old shr (Component * 8)) and $FF;
            var Value := (((Src * 2 + 1) * (Alpha * 2 + 1)) shr 10) + (((Dst * 2 + 1) * ((255 - Alpha) * 2 + 1)) shr 10);
            Blended := Blended or (Min(Cardinal(255), Value) shl (Component * 8));
          end;
          Color := Blended;
        end;
      end;
      if PixelFormat=3 then Destination[X] := Color
      else PWord(@DestData[0])[X]:=EncodeColor(Color,PixelFormat);
    end;
    if RowDirty then
    begin
      FMemory.WriteFrom(Address,Width*PixelBytes,DestData);
      if DepthWrite then
        if BufferedDepth then FMemory.WriteDepthFrom(DepthAddress,Width*2,PixelFormat=3,DepthData)
        else FMemory.FillDepth16(DepthAddress, Width, Depth,PixelFormat=3);
    end;
    Inc(Address, Stride * PixelBytes);
    Inc(DepthAddress, DepthStride * 2);
  end;
  Result := True;
  {$IFDEF PSP_PROFILE}if PSPProfileCollecting and not FIsRenderWorker then Inc(PSPProfileBlitRejects[0]);{$ENDIF}
end;

procedure TPSPGE.Sprite(const A, C: TPSPGEVertex);
begin
  var DX := C.X - A.X;
  var DY := C.Y - A.Y;
  if (DX = 0) or (DY = 0) then
    Exit;
  var MinX := Max(Integer(FRegisters[$D4] and $3FF), Integer(Ceil(Min(A.X, C.X) - 0.5)));
  var MinY := Max(Integer((FRegisters[$D4] shr 10) and $3FF), Integer(Ceil(Min(A.Y, C.Y) - 0.5)));
  var MaxX := Min(Integer(FRegisters[$D5] and $3FF), Integer(Ceil(Max(A.X, C.X) - 0.5)) - 1);
  var MaxY := Min(Integer((FRegisters[$D5] shr 10) and $3FF), Integer(Ceil(Max(A.Y, C.Y) - 0.5)) - 1);
  if (MinX > MaxX) or (MinY > MaxY) then
    Exit;
  var Textured := (FRegisters[$1E] and 1 <> 0) and (FRegisters[$D3] and 1 = 0);
  if FOptimizedRasterization and not Textured and (FRegisters[$D3] and 1 = 0) and
    (FRegisters[$21] and 1 = 0) and (FRegisters[$22] and 1 = 0) and (FRegisters[$23] and 1 = 0) and
    (FRegisters[$E8] and $FFFFFF = 0) and (FRegisters[$E9] and $FF = 0) then
  begin
    var Stride := FRegisters[$9D] and $7FC;
    var Right := Min(MaxX, Integer(Stride) - 1);
    if Right < MinX then
      Exit;
    var Format := FRegisters[$D2] and 3;
    var Bytes: Cardinal := 2;
    if Format = 3 then
      Bytes := 4;
    var Address := GEStorageAddress(PSPVRAMBase + (FRegisters[$9C] and $1FFFF0) + (Cardinal(MinY) * Stride + Cardinal(MinX)) * Bytes);
    var Span := (Cardinal(MaxY - MinY) * Stride + Cardinal(Right - MinX + 1)) * Bytes;
    var DepthWrite := FRegisters[$E7] and 1 = 0;
    var DepthStride := FRegisters[$9F] and $7FC;
    var DepthAddress := PSPVRAMBase + (FRegisters[$9E] and $1FFFF0) + (Cardinal(MinY) * DepthStride + Cardinal(MinX)) * 2;
    var DepthSpan := (Cardinal(MaxY - MinY) * DepthStride + Cardinal(Right - MinX + 1)) * 2;
    var StoredFirst, StoredSize: Cardinal;
    var Mapped := not DepthWrite or FMemory.DepthStorageBounds(DepthAddress,DepthSpan,StoredFirst,StoredSize);
    var Overlap := DepthWrite and (UInt64(Address) < UInt64(StoredFirst) + StoredSize) and (UInt64(StoredFirst) < UInt64(Address) + Span);
    if Mapped and not Overlap and FMemory.IsValid(Address, Span) then
    begin
      var Color := C.Color;
      if Format <> 3 then
        Color := EncodeColor(Color, Format);
      var Depth: Word := 0;
      if DepthWrite then
        Depth := Word(EnsureRange(Round(C.Z), Int64(0), Int64(65535)));
      for var Y := MinY to MaxY do
      begin
        if Format = 3 then
          FMemory.Fill32(Address, Right - MinX + 1, Color)
        else
          FMemory.Fill16(Address, Right - MinX + 1, Word(Color));
        if DepthWrite then
          FMemory.FillDepth16(DepthAddress, Right - MinX + 1, Depth,Format=3);
        Inc(Address, Stride * Bytes);
        Inc(DepthAddress, DepthStride * 2);
      end;
      Exit;
    end;
  end;
  if not Textured then
  begin
    for var Y := MinY to MaxY do
      if not SolidSpan(MinX, MaxX, Y, C.Z, C.Color) then
        for var X := MinX to MaxX do Pixel(X, Y, C.Z, C.Color);
    Exit;
  end;
  if BlitSprite(A, C, MinX, MinY, MaxX, MaxY) then
    Exit;
  var DU := (C.U - A.U) / DX;
  var DV := (C.V - A.V) / DY;
  var FirstU := A.U + (MinX + 0.5 - A.X) * DU;
  for var Y := MinY to MaxY do
  begin
    var V := A.V + (Y + 0.5 - A.Y) * DV;
    for var X := MinX to MaxX do
      Pixel(X, Y, C.Z, Shade(C.Color, FirstU + (X - MinX) * DU, V));
  end;
end;

function TPSPGE.Rectangle(const A, B, C, D: TPSPGEVertex): Boolean;
begin
  Result := False;
  if not FOptimizedRasterization then Exit;
  if (FRegisters[$1D] and 1 <> 0) or (A.X = D.X) or (A.Y = D.Y) then Exit;
  if not (((B.X = A.X) and (B.Y = D.Y) and (C.X = D.X) and (C.Y = A.Y)) or
          ((B.X = D.X) and (B.Y = A.Y) and (C.X = A.X) and (C.Y = D.Y))) then Exit;
  if (A.Color <> B.Color) or (A.Color <> C.Color) or (A.Color <> D.Color) or
    (A.Z <> B.Z) or (A.Z <> C.Z) or (A.Z <> D.Z) then Exit;
  if (A.X < 0) or (A.X > 1024) or (D.X < 0) or (D.X > 1024) or
    (A.Y < 0) or (A.Y > 1024) or (D.Y < 0) or (D.Y > 1024) then Exit;
  if (Frac(A.X) <> 0) or (Frac(A.Y) <> 0) or (Frac(D.X) <> 0) or (Frac(D.Y) <> 0) then Exit;
  if (FRegisters[$1E] and 1 <> 0) and (FRegisters[$D3] and 1 = 0) then
  begin
    // Keep one texel per pixel: the half-texel samples are away from integer
    // sampler boundaries, so both triangle and sprite interpolation agree.
    if (Abs(D.U - A.U) <> Abs(D.X - A.X)) or (Abs(D.V - A.V) <> Abs(D.Y - A.Y)) then Exit;
    if (Frac(A.U) <> 0) or (Frac(A.V) <> 0) or (Frac(D.U) <> 0) or (Frac(D.V) <> 0) then Exit;
    if not (((B.X = A.X) and (B.U = A.U) and (B.V = D.V) and (C.U = D.U) and (C.V = A.V)) or
            ((B.X = D.X) and (B.U = D.U) and (B.V = A.V) and (C.U = A.U) and (C.V = D.V))) then Exit;
    var TextureAddress := GEStorageAddress(FTexture.Address);
    if (TextureAddress >= PSPVRAMBase) and (TextureAddress < PSPVRAMBase + PSPVRAMSize) then Exit;
  end;
  // Intersecting color/depth storage needs the two original triangle passes.
  if (FRegisters[$E7] and 1 = 0) or (FRegisters[$23] and 1 <> 0) or (FRegisters[$D3] and $400 <> 0) then
  begin
    var Left := Cardinal(Trunc(Min(A.X, D.X)));var Top := Cardinal(Trunc(Min(A.Y, D.Y)));
    var Width := Cardinal(Trunc(Abs(D.X - A.X)));var Height := Cardinal(Trunc(Abs(D.Y - A.Y)));
    var Bytes: Cardinal := 2;if FRegisters[$D2] and 3 = 3 then Bytes := 4;
    var Stride := FRegisters[$9D] and $7FC;var DepthStride := FRegisters[$9F] and $7FC;
    var ColorStart := GEStorageAddress(PSPVRAMBase + (FRegisters[$9C] and $1FFFF0) + (Top * Stride + Left) * Bytes);
    var DepthStart := PSPVRAMBase + (FRegisters[$9E] and $1FFFF0) + (Top * DepthStride + Left) * 2;
    var ColorSpan := ((Height - 1) * Stride + Width) * Bytes;
    var DepthSpan := ((Height - 1) * DepthStride + Width) * 2;
    var StoredFirst, StoredSize: Cardinal;
    if not FMemory.DepthStorageBounds(DepthStart,DepthSpan,StoredFirst,StoredSize) then Exit;
    if (UInt64(ColorStart) < UInt64(StoredFirst) + StoredSize) and (UInt64(StoredFirst) < UInt64(ColorStart) + ColorSpan) then Exit;
  end;
  Sprite(A, D);
  Result := True;
end;

function TPSPGE.TryParallelDraw(Primitive: Cardinal; const Vertices: TArray<TPSPGEVertex>): Boolean;
begin
  Result := False;
  if not FParallelRendering or not FOptimizedRasterization or FIsRenderWorker or
    (FMaxRenderWorkers < 2) or (TThread.ProcessorCount < 2) or not (Primitive in [3..6]) then Exit;
  {$IF defined(MSWINDOWS) and (defined(CPUX86) or defined(CPUX64))}
  var Count := Length(Vertices);
  if Count < 2 then Exit;
  var Stride := FRegisters[$9D] and $7FC;
  var Left := Integer(FRegisters[$D4] and $3FF);
  var Right := Min(Integer(FRegisters[$D5] and $3FF), Integer(Stride) - 1);
  var Top := Integer((FRegisters[$D4] shr 10) and $3FF);
  var Bottom := Integer((FRegisters[$D5] shr 10) and $3FF);
  // Small draws only benefit when their actual raster footprint is large.
  if Count < 1536 then
  begin
    var X0 := Vertices[0].X;var X1 := X0;
    var Y0 := Vertices[0].Y;var Y1 := Y0;
    var ClipSensitive:=False;
    for var V in Vertices do
    begin
      if IsNan(V.X) or IsInfinite(V.X) or IsNan(V.Y) or IsInfinite(V.Y) then Exit;
      X0 := Min(X0,V.X);X1 := Max(X1,V.X);Y0 := Min(Y0,V.Y);Y1 := Max(Y1,V.Y);
      if (FRegisters[$12] and $800000=0) and V.Near then ClipSensitive:=True;
    end;
    // Near-plane intersections with changing W can project beyond the
    // original screen bounds. In that case retain the complete scissor.
    if not ClipSensitive then
    begin
      Left := Max(Left, Integer(Floor(EnsureRange(X0-1,0.0,1023.0))));
      Right := Min(Right, Integer(Ceil(EnsureRange(X1+1,0.0,1023.0))));
      Top := Max(Top, Integer(Floor(EnsureRange(Y0-1,0.0,1023.0))));
      Bottom := Min(Bottom, Integer(Ceil(EnsureRange(Y1+1,0.0,1023.0))));
      if (Right-Left+1)*(Bottom-Top+1) < 32768 then Exit;
    end;
  end;
  if (Right < Left) or (Bottom-Top+1 < 64) then Exit;
  var Jobs := Min(FMaxRenderWorkers, Min(TThread.ProcessorCount, (Bottom-Top+1) div 32));
  if Jobs < 2 then Exit;
  var PixelBytes: Cardinal := 2;
  if FRegisters[$D2] and 3 = 3 then PixelBytes := 4;
  var ColorBase := PSPVRAMBase + (FRegisters[$9C] and $1FFFF0);
  var Clear := FRegisters[$D3] and 1 <> 0;
  var DepthUsed := (not Clear and ((FRegisters[$23] and 1 <> 0) or (FRegisters[$E7] and 1 = 0))) or
    (Clear and (FRegisters[$D3] and $400 <> 0));
  var DepthStride := FRegisters[$9F] and $7FC;
  var DepthBase := PSPVRAMBase + (FRegisters[$9E] and $1FFFF0);
  var RowAlignment := 1;
  if DepthUsed then
  begin
    var RowBytes := DepthStride*2;
    if (RowBytes=0) or (RowBytes and (RowBytes-1)<>0) or
      (DepthBase and (FMemory.DepthWindowSize-1)<>0) then Exit;
    RowAlignment := Max(1,Integer(FMemory.DepthWindowSize div RowBytes));
  end;
  var OwnedTop := Top div RowAlignment*RowAlignment;
  var OwnedBottom := ((Bottom+RowAlignment) div RowAlignment)*RowAlignment-1;
  var Groups := (OwnedBottom-OwnedTop+1) div RowAlignment;
  Jobs := Min(Jobs,Groups);
  if Jobs<2 then Exit;
  var ColorAddress := ColorBase + Cardinal(OwnedTop) * Stride * PixelBytes;
  var ColorSize := Cardinal(OwnedBottom-OwnedTop+1) * Stride * PixelBytes;
  if (UInt64(ColorAddress)+ColorSize>UInt64(PSPVRAMBase)+PSPVRAMSize) or not FMemory.IsValid(ColorAddress,ColorSize) then Exit;
  var DepthAddress := DepthBase + Cardinal(OwnedTop) * DepthStride * 2;
  var DepthSize: Cardinal := 0;
  if DepthUsed then
  begin
    if DepthStride <= Cardinal(Right) then Exit;
    DepthSize := Cardinal(OwnedBottom-OwnedTop+1) * DepthStride * 2;
    if (UInt64(DepthAddress)+DepthSize>UInt64(PSPVRAMBase)+PSPVRAMSize) or not FMemory.IsValid(DepthAddress,DepthSize) then Exit;
    if (UInt64(ColorAddress) < UInt64(DepthAddress)+DepthSize) and
      (UInt64(DepthAddress) < UInt64(ColorAddress)+ColorSize) then Exit;
  end;
  if not Clear and (FRegisters[$1E] and 1 <> 0) then
  begin
    var SourceBase, SourceSize:Cardinal;
    if not TextureReadRange(SourceBase,SourceSize) then Exit;
    // Texture feedback (including mirrors and padding) keeps its original
    // primitive/pixel order in the serial renderer.
    if (UInt64(SourceBase)<UInt64(ColorAddress)+ColorSize) and (UInt64(ColorAddress)<UInt64(SourceBase)+SourceSize) then Exit;
    if DepthUsed and (UInt64(SourceBase)<UInt64(DepthAddress)+DepthSize) and (UInt64(DepthAddress)<UInt64(SourceBase)+SourceSize) then Exit;
  end;
  {$IFDEF PSP_PROFILE}var PrepareStarted:=PSPProfileStart;{$ENDIF}
  if FRenderPool=nil then
  begin
    FRenderPool:=TThreadPool.Create;
    FRenderPool.SetMinWorkerThreads(0);
    FRenderPool.SetMaxWorkerThreads(4);
    FRenderPool.UnlimitedWorkerThreadsWhenBlocked:=False;
  end;
  for var I:=0 to Jobs-1 do
  begin
    if FRenderers[I]=nil then
    begin
      FRenderMemories[I]:=TPSPMemory.CreateRenderView(FMemory);
      FRenderers[I]:=TPSPGE.Create(FRenderMemories[I],nil,nil);
      FRenderers[I].FIsRenderWorker:=True;
      FRenderers[I].FParallelRendering:=False;
    end;
    var First:=OwnedTop+(Groups*I div Jobs)*RowAlignment;
    var Last:=OwnedTop+(Groups*(I+1) div Jobs)*RowAlignment-1;
    var LocalDepthSize:Cardinal:=0;
    if DepthUsed then LocalDepthSize:=Cardinal(Last-First+1)*DepthStride*2;
    FRenderMemories[I].PrepareRenderView(ColorBase+Cardinal(First)*Stride*PixelBytes,
      Cardinal(Last-First+1)*Stride*PixelBytes,DepthBase+Cardinal(First)*DepthStride*2,LocalDepthSize);
    Move(FRegisters,FRenderers[I].FRegisters,SizeOf(FRegisters));
    Move(FCLUTColors,FRenderers[I].FCLUTColors,SizeOf(FCLUTColors));
    FRenderers[I].FTexture:=FTexture;
    FRenderers[I].FRegisters[$D4]:=(FRegisters[$D4] and $3FF) or (Cardinal(Max(Top,First)) shl 10);
    FRenderers[I].FRegisters[$D5]:=(FRegisters[$D5] and $3FF) or (Cardinal(Min(Bottom,Last)) shl 10);
  end;
  var Failed:Integer:=0;
  {$IFDEF PSP_PROFILE}
  PSPProfileEnd(TPSPProfilePart.GEPrepare,PrepareStarted);
  var JobsStarted:=PSPProfileStart;
  var WorkerTicks:TArray<Int64>;SetLength(WorkerTicks,Jobs);
  {$ENDIF}
  var ThreadIds:TArray<Cardinal>;SetLength(ThreadIds,Jobs);
  var ParentCW:=Get8087CW;
  var ParentMXCSR:=GetMXCSR;
  TParallel.For(0,Jobs-1,procedure(Index:Integer)
    begin
      {$IFDEF PSP_PROFILE}var WorkerStarted:=PSPProfileStart;{$ENDIF}
      var SavedCW:=Get8087CW;var SavedMXCSR:=GetMXCSR;
      try
        Set8087CW(ParentCW);SetMXCSR(ParentMXCSR);
        ThreadIds[Index]:=TThread.CurrentThread.ThreadID;
        try FRenderers[Index].RenderPrimitives(Primitive,Vertices)
        except on Exception do TInterlocked.Exchange(Failed,1) end;
      finally
        Set8087CW(SavedCW);SetMXCSR(SavedMXCSR);
        {$IFDEF PSP_PROFILE}WorkerTicks[Index]:=PSPProfileStart-WorkerStarted;{$ENDIF}
      end;
    end,FRenderPool);
  {$IFDEF PSP_PROFILE}
  PSPProfileEnd(TPSPProfilePart.GEJobs,JobsStarted);
  if PSPProfileCollecting then
  begin
    var Critical:Int64:=0;for var Ticks in WorkerTicks do Critical:=Max(Critical,Ticks);
    Inc(PSPProfileTicks[TPSPProfilePart.GEWorkerCritical],Critical);
  end;
  var CommitStarted:=PSPProfileStart;
  {$ENDIF}
  // No parent bytes have changed on a failed job. Serial execution reproduces
  // the first guest fault and its partial writes, rather than an aggregate error.
  if Failed<>0 then
  begin Inc(FParallelFallbackCount);Exit end;
  for var I:=0 to Jobs-1 do FRenderMemories[I].CommitRenderView;
  {$IFDEF PSP_PROFILE}PSPProfileEnd(TPSPProfilePart.GECommit,CommitStarted);{$ENDIF}
  var Distinct:=0;
  for var I:=0 to Jobs-1 do
  begin
    var Seen:=False;
    for var J:=0 to I-1 do if ThreadIds[I]=ThreadIds[J] then Seen:=True;
    if not Seen then Inc(Distinct);
  end;
  FObservedRenderThreads:=Max(FObservedRenderThreads,Distinct);
  Inc(FParallelDrawCount);
  Result:=True;
  {$ENDIF}
end;

procedure TPSPGE.RenderPrimitives(Primitive: Cardinal; const Vertices: TArray<TPSPGEVertex>);
begin
  var Count := Cardinal(Length(Vertices));
  var VType := FRegisters[$12];
  var RectangleDrawn := False;
  if (Count = 4) and (VType and $800000 <> 0) then
    case Primitive of
      4: RectangleDrawn := Rectangle(Vertices[0], Vertices[1], Vertices[2], Vertices[3]);
      5: RectangleDrawn := Rectangle(Vertices[0], Vertices[1], Vertices[3], Vertices[2]);
    end;
  if not RectangleDrawn then
  case Primitive of
    0:
      for var Vertex in Vertices do
        SubmitPoint(Vertex);
    1:
      for var I := 0 to Integer(Count div 2) - 1 do
        SubmitLine(Vertices[I * 2], Vertices[I * 2 + 1]);
    2:
      for var I := 0 to Integer(Count) - 2 do
        SubmitLine(Vertices[I], Vertices[I + 1]);
    3:
      for var I := 0 to Integer(Count div 3) - 1 do
        SubmitTriangle(Vertices[I * 3], Vertices[I * 3 + 1], Vertices[I * 3 + 2]);
    4:
      for var I := 0 to Integer(Count) - 3 do
        if I and 1=0 then SubmitTriangle(Vertices[I], Vertices[I + 1], Vertices[I + 2])
        else SubmitTriangle(Vertices[I + 1], Vertices[I], Vertices[I + 2],True);
    5:
      for var I := 1 to Integer(Count) - 2 do
        SubmitTriangle(Vertices[0], Vertices[I], Vertices[I + 1]);
    6:
      for var I := 0 to Integer(Count div 2) - 1 do
        SubmitSprite(Vertices[I * 2], Vertices[I * 2 + 1]);
  else
    raise EPSPInstruction.CreateFmt('PSP: GE primitive %d is not implemented', [Primitive]);
  end;
end;

procedure TPSPGE.Draw(Primitive, Count: Cardinal);
var
  CachedIndices, CachedVertices: array[0..255] of Cardinal;
begin
  {$IFDEF PSP_PROFILE}var ProfileStarted:=PSPProfileStart;{$ENDIF}
  if (FRegisters[$1E] and 1 <> 0) and (FRegisters[$D3] and 1 = 0) then
    ConfigureTexture;
  var VType := FRegisters[$12];
  {$IFDEF PSP_PROFILE}var VertexStarted:=PSPProfileStart;{$ENDIF}
  var Vertices: TArray<TPSPGEVertex>;
  SetLength(Vertices, Count);
  var Stride: Cardinal := 0;
  var IndexType := (VType shr 11) and 3;
  if FOptimizedRasterization and (IndexType <> 0) then
    FillChar(CachedIndices, SizeOf(CachedIndices), $FF);
  for var I := 0 to Integer(Count) - 1 do
  begin
    var Index := Cardinal(I);
    case IndexType of
      0:
        ;
      1:
        Index := FMemory.ReadGE8(FIndexAddress + Cardinal(I));
      2:
        Index := FMemory.ReadGE16(FIndexAddress + Cardinal(I) * 2);
    else
      raise EPSPInstruction.Create('PSP: invalid GE index format');
    end;
    // All vertex fetches precede rasterization. Repeated indices within this
    // draw therefore share exactly the same input bytes and transform state.
    var Slot := Index and 255;
    if FOptimizedRasterization and (IndexType <> 0) and (CachedIndices[Slot] = Index) then
      Vertices[I] := Vertices[CachedVertices[Slot]]
    else
    begin
      Vertices[I] := Vertex(Index, VType, Stride);
      if FOptimizedRasterization and (IndexType <> 0) then
      begin CachedIndices[Slot] := Index; CachedVertices[Slot] := I end;
    end;
  end;
  {$IFDEF PSP_PROFILE}
  PSPProfileEnd(TPSPProfilePart.GEVertices,VertexStarted);
  if PSPProfileCollecting then
  begin
    var Bucket:=0;var BatchSize:=Count;
    while (BatchSize>=8) and (Bucket<7) do begin BatchSize:=BatchSize shr 2;Inc(Bucket) end;
    Inc(PSPProfileVertexBatches[Bucket]);Inc(PSPProfileVertexIndices[IndexType],Count);
  end;
  {$ENDIF}
  if not TryParallelDraw(Primitive, Vertices) then RenderPrimitives(Primitive, Vertices);
  if IndexType = 0 then
    Inc(FVertexAddress, Count * Stride)
  else
    Inc(FIndexAddress, Count * (1 shl (IndexType - 1)));
  {$IFDEF PSP_PROFILE}
  var ProfileTexture:Cardinal:=15;if FRegisters[$1E] and 1<>0 then ProfileTexture:=FTexture.Format and 15;
  var ProfileState:=ProfileTexture or ((FRegisters[$D2] and 3) shl 4) or ((FRegisters[$23] and 1) shl 6) or
    ((FRegisters[$C9] and 7) shl 7) or ((Primitive and 7) shl 10) or ((FRegisters[$DE] and 7) shl 13);
  PSPProfileDrawEnd(ProfileState,ProfileStarted);
  if PSPProfileCollecting and (PSPProfileDrawDetails[ProfileState]='') then
    PSPProfileDrawDetails[ProfileState]:=Format('blend=%x:%x masks=%x:%x clear=%x depth_write=%x count=%d shade=%x',
      [FRegisters[$21],FRegisters[$DF],FRegisters[$E8],FRegisters[$E9],FRegisters[$D3],FRegisters[$E7],Count,FRegisters[$50]]);
  {$ENDIF}
end;

procedure TPSPGE.Transfer;
begin
  var Source := (FRegisters[$B2] and $FFFFF0) or ((FRegisters[$B3] shl 8) and $0F000000);
  var Dest := (FRegisters[$B4] and $FFFFF0) or ((FRegisters[$B5] shl 8) and $0F000000);
  var Bytes: Cardinal := 2;
  if FRegisters[$EA] and 1 <> 0 then
    Bytes := 4;
  var Width := (FRegisters[$EE] and $3FF) + 1;
  var Height := ((FRegisters[$EE] shr 10) and $3FF) + 1;
  var SX := FRegisters[$EB] and $3FF;
  var SY := (FRegisters[$EB] shr 10) and $3FF;
  var DX := FRegisters[$EC] and $3FF;
  var DY := (FRegisters[$EC] shr 10) and $3FF;
  for var Y := 0 to Integer(Height) - 1 do
  begin
    FMemory.ReadGEInto(Source + ((SY + Cardinal(Y)) * (FRegisters[$B3] and $7F8) + SX) * Bytes,Width*Bytes,FColorRow);
    FMemory.WriteGEFrom(Dest + ((DY + Cardinal(Y)) * (FRegisters[$B5] and $7F8) + DX) * Bytes,Width*Bytes,FColorRow);
  end;
end;

procedure TPSPGE.RunList(List: TPSPGEList);
begin
  if (List.Status = 0) or List.Waiting then
    Exit;
  List.Status := 2;
  for var Budget := 1 to 100000 do
  begin
    if (List.Stall <> 0) and (List.PC = List.Stall) then
    begin
      List.Status := 3;
      Exit;
    end;
    var Command := FMemory.ReadGE32(List.PC);
    var Code := Command shr 24;
    var Data := Command and $FFFFFF;
    Inc(List.PC, 4);
    var Previous := List.PreviousCommand;
    List.PreviousCommand := Command;
    FRegisters[Code] := Data;
    case Code of
      $01:
        FVertexAddress := Relative(Data, List.Offset);
      $02:
        FIndexAddress := Relative(Data, List.Offset);
      $04:
        Draw((Data shr 16) and 7, Data and $FFFF);
      $05, $06:
        raise EPSPInstruction.Create('PSP: GE bezier/spline patches are not implemented');
      $08:
        List.PC := Relative(Data, List.Offset) and $FFFFFFFC;
      $0A:
        begin
          if Length(List.Stack) >= 96 then
            raise EPSPInstruction.Create('PSP: GE call stack overflow');
          List.Stack := List.Stack + [List.PC, List.Offset, Cardinal(0)];
          List.PC := Relative(Data, List.Offset) and $FFFFFFFC;
        end;
      $0B:
        begin
          var N := Length(List.Stack);
          if N < 3 then
            Continue; // Empty RET advances to the following command.
          List.PC := List.Stack[N - 3] and $0FFFFFFF;
          List.Offset := List.Stack[N - 2]; // Ordinary CALL/RET does not restore BASE.
          SetLength(List.Stack, N - 3);
        end;
      $0C:
        begin
          var Callback: TPSPGECallback;
          var HasCallback := FCallbacks.TryGetValue(List.CallbackId, Callback);
          var CallbackPC: Cardinal := 0;
          if FKernel.SDK > $02000010 then
            CallbackPC := List.PC;
          if Previous shr 24 = $0E then
          begin
            var Behavior := (Previous shr 16) and $FF;
            var Token := Previous and $FFFF;
            case Behavior of
              0:
                ;
              1, 2:
                if HasCallback and (Callback.Signal <> 0) then
                begin
                  if Behavior = 1 then
                  begin
                    List.Waiting := True;
                    List.Status := 4;
                    FKernel.QueueCall(Callback.Signal, Token, Callback.SignalArg, CallbackPC, True,
                      procedure
                      begin
                        List.Waiting := False;
                        List.Status := 1;
                        Update;
                      end);
                    Exit;
                  end
                  else
                    FKernel.QueueCall(Callback.Signal, Token, Callback.SignalArg, CallbackPC);
                end;
              3:
                begin
                  List.SignalMode := 3;
                  List.SignalToken := Token;
                end;
              8:
                List.SignalMode := 8;
              $10, $11, $13, $14, $15, $16:
                begin
                  var Target := (Token shl 16) or (Data and $FFFF);
                  if Behavior in [$13, $14] then
                    Target := Cardinal((UInt64(Target) + List.PC - 8) and $0FFFFFFF)
                  else if Behavior in [$15, $16] then
                    Target := Cardinal((UInt64(Target) + List.Offset + ((FRegisters[$10] and $F0000) shl 8)) and $0FFFFFFF);
                  Target := Target and $0FFFFFFC;
                  if not FMemory.IsValid(Target, 4) then
                    raise EPSPMemory.Create('PSP: invalid GE signal target');
                  if Behavior in [$11, $14, $16] then
                  begin
                    if Length(List.Stack) >= 96 then
                      raise EPSPInstruction.Create('PSP: GE signal stack overflow');
                    List.Stack := List.Stack + [List.PC, List.Offset, FRegisters[$10]];
                  end;
                  List.PC := Target;
                end;
              $12:
                begin
                  var N := Length(List.Stack);
                  if N < 3 then
                    raise EPSPInstruction.Create('PSP: GE signal return without call');
                  List.PC := List.Stack[N - 3];
                  List.Offset := List.Stack[N - 2];
                  FRegisters[$10] := List.Stack[N - 1];
                  SetLength(List.Stack, N - 3);
                end;
            else
              raise EPSPInstruction.CreateFmt('PSP: GE signal behavior %.2x is not implemented', [Behavior]);
            end;
            Continue;
          end;
          if (Previous shr 24 = $0F) and (List.SignalMode = 8) then
          begin
            List.SignalMode := 0;
            List.Finish := False;
            Continue;
          end;
          if (Previous shr 24 = $0F) and (List.SignalMode = 3) then
          begin
            List.Waiting := True;
            List.Paused := True;
            List.Status := 4;
            List.Finish := False;
            if HasCallback and (Callback.Signal <> 0) then
              FKernel.QueueCall(Callback.Signal, List.SignalToken, Callback.SignalArg, CallbackPC);
            List.SignalMode := 0;
            Exit;
          end;
          if List.Finish and HasCallback and (Callback.Finish <> 0) then
          begin
            List.Waiting := True;
            List.Status := 4;
            FKernel.QueueCall(Callback.Finish, List.FinishToken, Callback.FinishArg, CallbackPC, True,
              procedure
              begin
                List.Waiting := False;
                List.Status := 0;
                Update;
              end);
          end
          else
            List.Status := 0;
          Exit;
        end;
      $0E:
        ; // SIGNAL takes effect together with the following END.
        $0F:
        begin
          List.Finish := True;
          List.FinishToken := Data and $FFFF;
        end;
      $13:
        List.Offset := Data shl 8;
      $14:
        List.Offset := List.PC - 4;
      $2A:
        FBoneIndex := Data and $7F;
      $2B:
        begin
          if FBoneIndex < 96 then
            FBones[FBoneIndex] := Float24(Data);
          FBoneIndex := (FBoneIndex + 1) and $7F
        end;
      $3A:
        FWorldIndex := Data and 15;
      $3B:
        begin
          if FWorldIndex < 12 then
            FWorld[FWorldIndex] := Float24(Data);
          FTransformDirty := True;
          FWorldIndex := (FWorldIndex + 1) and 15;
        end;
      $3C:
        FViewIndex := Data and 15;
      $3D:
        begin
          if FViewIndex < 12 then
            FView[FViewIndex] := Float24(Data);
          FTransformDirty := True;
          FViewIndex := (FViewIndex + 1) and 15;
        end;
      $3E:
        FProjectionIndex := Data and 15;
      $3F:
        begin
          FProjection[FProjectionIndex] := Float24(Data);
          FTransformDirty := True;
          FProjectionIndex := (FProjectionIndex + 1) and 15;
        end;
      $C4:
        begin
          var Address := (FRegisters[$B0] and $FFFFF0) or ((FRegisters[$B1] shl 8) and $0F000000);
          var Count := Min(Cardinal(2048), (Data and $3F) * 32);
          FMemory.ReadGEInto(Address,Count,FCLUT);
          FCLUTDirty := True;
        end;
      $EA:
        Transfer;
    end;
  end;
  raise EPSPInstruction.Create('PSP: GE list exceeded command budget');
end;

procedure TPSPGE.Update;
begin
  while FQueue.Count > 0 do
  begin
    var List := FQueue[0];
    RunList(List);
    if List.Status <> 0 then
      Break;
    FKernel.CompleteDevice(1, List.Id, 0);
    FQueue.Delete(0);
  end;
  if FQueue.Count = 0 then
    FKernel.CompleteDevice(2, 0, 0);
end;

function TPSPGE.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  case NID of
    $E47E40E4:
      Value := PSPVRAMBase;
    $1F6752AD:
      Value := PSPVRAMSize;
    $B77905EA:
      begin
        case A of 0,$200,$400,$800,$1000:;
        else Value:=$800001FE;Exit end;
        Value := FMemory.DepthTranslation;
        FMemory.DepthTranslation := A;
      end;
    $A4FC06A4:
      begin
        var Callback: TPSPGECallback;
        Callback.Signal := FMemory.Read32(A);
        Callback.SignalArg := FMemory.Read32(A + 4);
        Callback.Finish := FMemory.Read32(A + 8);
        Callback.FinishArg := FMemory.Read32(A + 12);
        Value := FNextCallback;
        Inc(FNextCallback);
        FCallbacks.Add(Value, Callback);
      end;
    $05DB22CE:
      FCallbacks.Remove(A);
    $AB49E76A, $1C0D95A6:
      begin
        var List: TPSPGEList := nil;
        if FLists.Count < 64 then
        begin
          List := TPSPGEList.Create;
          List.Id := FNextList;
          Inc(FNextList);
          FLists.Add(List);
        end
        else
          for var Entry in FLists do
            if Entry.Status = 0 then
            begin
              List := Entry;
              Break;
            end;
        if List = nil then
        begin
          Value := $80000104;
          Exit;
        end;
        List.PC := A and $0FFFFFFF;
        List.Stall := B and $0FFFFFFF;
        List.CallbackId := C;
        List.Status := 1;
        List.Offset := 0;
        List.Stack := nil;
        List.Finish := False;
        List.FinishToken := 0;
        List.SignalMode := 0;
        List.SignalToken := 0;
        List.PreviousCommand := 0;
        List.Waiting := False;
        List.Paused := False;
        if NID = $1C0D95A6 then
          FQueue.Insert(0, List)
        else
          FQueue.Add(List);
        Value := List.Id;
        Update;
      end;
    $E0D68148:
      begin
        Value := $80000100;
        for var List in FLists do
          if List.Id = A then
          begin
            List.Stall := B and $0FFFFFFF;
            Update;
            Value := 0;
            Break;
          end;
      end;
    $03444EB4:
      begin
        Value := $80000100;
        for var List in FLists do
          if List.Id = A then
          begin
            if B = 1 then
              Value := List.Status
            else if List.Status = 0 then
              Value := 0
            else
              FKernel.WaitDevice(1, List.Id);
            Break;
          end;
      end;
    $B287BD61:
      begin
        Update;
        if FQueue.Count > 0 then
          if A = 1 then
            Value := FQueue[0].Status
          else
            FKernel.WaitDevice(2, 0);
      end;
    $4C06E472:
      begin
        Value := $80000020;
        if (FQueue.Count > 0) and FQueue[0].Paused then
        begin
          FQueue[0].Paused := False;
          FQueue[0].Waiting := False;
          FQueue[0].Status := 1;
          Value := 0;
          Update;
        end;
      end;
    $DC93CFEF:
      if A > 255 then
        Value := $80000102
      else
        Value := FRegisters[A] or (A shl 24);
  else
    Result := False;
  end;
end;

end.

