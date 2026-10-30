unit NDS.Geometry;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

type
  TNDSVRAMRead = function(Address: Cardinal): Byte of object;

  TNDSVRAMPage = function(Address: Cardinal): PByte of object;

  TNDSMatrix = array[0..15] of Double;

  TNDSVertex = record
    X, Y, Z, W, U, V, R, G, B: Double;
  end;

  TNDSPolygon = record
    V: array[0..2] of TNDSVertex;
    Attributes, Texture, Palette: Cardinal;
  end;

  PNDSPolygon = ^TNDSPolygon;

  TNDSCoverage = record
    Mask, BackgroundAlpha: Byte;
    // A full pixel retains its plane; edge sample depths are expanded lazily.
    // The pointer is borrowed from the immutable prepared list for one render.
    Source: PNDSPolygon;
    Colors: array[0..3] of Word;
    Depths: array[0..3] of Double;
  end;

  PNDSCoverage = ^TNDSCoverage;

  TNDSGeometry = class
  private
    FRead: TNDSVRAMRead;
    FGetPage: TNDSVRAMPage;
    FReadPage: PByte;
    FReadTag: Cardinal;
    FRasterWorkers: array[0..6] of TNDSGeometry;
    FRasterThreads: array[0..6] of TThread;
    FClipY0, FClipY1: Integer;
    FMatrices: array[0..3] of TNDSMatrix;
    FPositionStack, FVectorStack: array[0..31] of TNDSMatrix;
    FProjectionStack, FTextureStack: TNDSMatrix;
    FStack, FMode, FPrimitive: Integer;
    FParameters: array[0..31] of Cardinal;
    FCommand, FParameterCount, FExpected, FCommandsLeft: Integer;
    FPackedCommands: Cardinal;
    FColor: Word;
    FDiffuseAmbient, FSpecularEmission: Cardinal;
    FLightVectors: array[0..3, 0..2] of Double;
    FLightColors: array[0..3] of Word;
    FStripParity: Boolean;
    FControl: Word;
    FAlphaTest: Byte;
    FToon: array[0..31] of Word;
    FFogTable: array[0..31] of Byte;
    FFogColor: Cardinal;
    FFogOffset: Word;
    FRearOffset: Word;
    FEdgeColors: array[0..7] of Word;
    FPolygonID, FTranslucentID: array[0..256 * 192 - 1] of Byte;
    FFogFlags, FShadow: array[0..256 * 192 - 1] of Boolean;
    // Work buffer for one synchronous VBlank render, rebuilt before drawing.
    // It is not guest state and does not survive a render or need serialization.
    FCoverage: array[0..256 * 192 - 1] of TNDSCoverage;
    // Derived per-triangle cache. Texture VRAM is immutable during rasterization.
    FPaletteCache: array[0..255] of Word;
    FPaletteValid: array[0..255] of Boolean;
    FShininess: array[0..127] of Byte;
    FRawU, FRawV: Double;
    FSwapFlags, FPendingFlags: Cardinal;
    FBoxResult: Boolean;
    FVectorResult: array[0..2] of SmallInt;
    FAttributes, FTexture, FPalette, FViewport: Cardinal;
    FX, FY, FZ, FU, FV: Double;
    FVertices: array[0..3] of TNDSVertex;
    FVertexCount: Integer;
    FBuilding, FPending: TArray<TNDSPolygon>;
    FRendering: TArray<TNDSPolygon>;
    FPrepared: TArray<TNDSPolygon>;
    FPreparedCount: Integer;
    FRenderReady: Boolean;
    FRenderFlags, FRenderViewport: Cardinal;
    FBuildingCount: Integer;
    FSwapPending, FStackError: Boolean;
    FPositionResult: array[0..3] of Cardinal;
    procedure SelectCommand(Command: Integer);
    procedure ExecuteCommand;
    procedure Multiply(const M: TNDSMatrix);
    procedure AddVertex;
    procedure Light(Normal: Cardinal);
    procedure AddTriangle(const A, B, C: TNDSVertex);
    procedure PreparePolygon(const Polygon: TNDSPolygon);
    procedure PrepareTriangle(const Polygon: TNDSPolygon);
    procedure RasterizeTriangle(const Polygon: TNDSPolygon);
    procedure RasterizePrepared(const Polygons: TArray<TNDSPolygon>; Count: Integer);
    function Read16(Address: Cardinal): Word;
    function Read8(Address: Cardinal): Byte; inline;
    function Texel(Texture, Palette: Cardinal; U, V: Double; out Alpha: Integer): Integer;
    constructor CreateRasterWorker(Owner: TNDSGeometry);
  public
    Pixels: array[0..256 * 192 - 1] of Word;
    Alpha: array[0..256 * 192 - 1] of Byte;
    Depth: array[0..256 * 192 - 1] of Double;
    ClearColor: Cardinal;
    ClearDepth: Word;
    IRQMode: Byte;
    constructor Create(Read: TNDSVRAMRead; GetPage: TNDSVRAMPage = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure SerializeState(State: TStateArchive; Version: Cardinal = 2);
    procedure FIFO(Value: Cardinal);
    procedure Direct(Command: Integer; Value: Cardinal);
    procedure VBlank;
    procedure SwapBuffers;
    procedure Render;
    function ReadRegister(Offset: Integer): Cardinal;
    procedure WriteRegister(Offset: Integer; Value: Byte);
    procedure Effects;
  end;

implementation

uses
  System.SyncObjs, Core.PerformanceHints;

type
  TNDSRasterThread = class(TThread)
  private
    FTarget: TNDSGeometry;
    FReady, FDone: TEvent;
    FPolygons: TArray<TNDSPolygon>;
    FCount: Integer;
    FError: string;
    FSlot: Integer;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(Target: TNDSGeometry; Slot: Integer);
    destructor Destroy; override;
    procedure Submit(const Polygons: TArray<TNDSPolygon>; Count: Integer);
    procedure Finish;
    procedure CheckResult;
  end;

constructor TNDSRasterThread.Create(Target: TNDSGeometry; Slot: Integer);
begin
  inherited Create(False);
  FTarget := Target;
  FSlot := Slot;
  FReady := TEvent.Create(nil, False, False, '');
  FDone := TEvent.Create(nil, False, False, '');
end;

destructor TNDSRasterThread.Destroy;
begin
  Terminate;
  if FReady <> nil then
    FReady.SetEvent;
  WaitFor;
  FReady.Free;
  FDone.Free;
  inherited;
end;

procedure TNDSRasterThread.TerminatedSet;
begin
  inherited;
  if FReady <> nil then
    FReady.SetEvent;
end;

procedure TNDSRasterThread.Execute;
begin
  var Performance: TEmulationPerformanceHints := nil;
  try
    try
      Performance := TEmulationPerformanceHints.Create(16715100, 'NDS raster strip', True, FSlot);
      while not Terminated do
      begin
        if FReady.WaitFor(INFINITE) <> wrSignaled then
          raise EInvalidOperation.Create('NDS raster command wait failed');
        if Terminated then
          Break;
        try
          Performance.BeginWork;
          try
            FTarget.RasterizePrepared(FPolygons, FCount);
          finally
            Performance.EndWork;
          end;
        except
          on E: Exception do
            FError := E.ClassName + ': ' + E.Message;
        end;
        FPolygons := nil;
        FDone.SetEvent;
      end;
    except
      on E: Exception do
      begin
        FError := E.ClassName + ': ' + E.Message;
        FDone.SetEvent;
      end;
    end;
  finally
    Performance.Free;
  end;
end;

procedure TNDSRasterThread.Submit(const Polygons: TArray<TNDSPolygon>; Count: Integer);
begin
  if Finished then
    raise EInvalidOperation.Create('NDS raster worker has stopped');
  FPolygons := Polygons;
  FCount := Count;
  FReady.SetEvent;
end;

procedure TNDSRasterThread.Finish;
begin
  if FDone.WaitFor(INFINITE) <> wrSignaled then
    raise EInvalidOperation.Create('NDS raster wait failed');
end;

procedure TNDSRasterThread.CheckResult;
begin
  if FError <> '' then
    raise EInvalidOperation.Create('NDS raster: ' + FError);
end;

function PixelFloor(Value: Double): Integer; inline;
begin
  // Floor without the RTL Frac call; compare against the unwrapped Int64
  // so negative values and the existing Integer conversion stay identical.
  var Whole := Trunc(Value);
  Result := Integer(Whole);
  if Value < Whole then
    Dec(Result);
end;

const
  TextureBase = $12000000;
  PaletteBase = $13000000;

procedure Identity(out M: TNDSMatrix);
begin
  FillChar(M, SizeOf(M), 0);
  for var i := 0 to 3 do
    M[i * 5] := 1;
end;

function Product(const A, B: TNDSMatrix): TNDSMatrix;
begin
  for var C := 0 to 3 do
    for var R := 0 to 3 do
    begin
      Result[C * 4 + R] := 0;
      for var K := 0 to 3 do
        Result[C * 4 + R] := Result[C * 4 + R] + A[K * 4 + R] * B[C * 4 + K];
    end;
end;

function Transform(const V: TNDSVertex; const M: TNDSMatrix): TNDSVertex;
begin
  Result := V;
  Result.X := M[0] * V.X + M[4] * V.Y + M[8] * V.Z + M[12] * V.W;
  Result.Y := M[1] * V.X + M[5] * V.Y + M[9] * V.Z + M[13] * V.W;
  Result.Z := M[2] * V.X + M[6] * V.Y + M[10] * V.Z + M[14] * V.W;
  Result.W := M[3] * V.X + M[7] * V.Y + M[11] * V.Z + M[15] * V.W;
end;

function SignedBits(Value: Cardinal; Bits: Integer): Integer;
begin
  Result := Integer(Value and ((Cardinal(1) shl Bits) - 1));
  if Value and (Cardinal(1) shl (Bits - 1)) <> 0 then
    Dec(Result, 1 shl Bits);
end;

function CountParameters(Command: Integer): Integer;
begin
  Result := 1;
  case Command of
    0, $11, $15, $41:
      Result := 0;
    $16, $18:
      Result := 16;
    $17, $19:
      Result := 12;
    $1A:
      Result := 9;
    $1B, $1C, $70:
      Result := 3;
    $23, $71:
      Result := 2;
    $34:
      Result := 32;
  end;
end;

constructor TNDSGeometry.Create(Read: TNDSVRAMRead; GetPage: TNDSVRAMPage);
begin
  inherited Create;
  FRead := Read;
  FGetPage := GetPage;
  FClipY0 := 0;
  FClipY1 := 191;
  SetLength(FBuilding, 12288);
  Reset;
end;

destructor TNDSGeometry.Destroy;
begin
  // Raster jobs finish synchronously before Render returns.
  for var Worker in FRasterThreads do
    Worker.Free;
  for var Worker in FRasterWorkers do
    Worker.Free;
  inherited;
end;

constructor TNDSGeometry.CreateRasterWorker(Owner: TNDSGeometry);
begin
  inherited Create;
  FRead := Owner.FRead;
  FGetPage := Owner.FGetPage;
  // A strip worker needs only raster outputs and scratch, not a command
  // processor, matrix stacks or the allocated polygon-building list.
end;

procedure TNDSGeometry.Reset;
begin
  for var i := 0 to 3 do
    Identity(FMatrices[i]);
  for var i := 0 to 31 do
  begin
    Identity(FPositionStack[i]);
    Identity(FVectorStack[i]);
  end;
  Identity(FProjectionStack);
  Identity(FTextureStack);
  FStack := 0;
  FMode := 0;
  FPrimitive := 0;
  FCommand := 0;
  FParameterCount := 0;
  FExpected := 0;
  FCommandsLeft := 0;
  FPackedCommands := 0;
  FColor := $7FFF;
  FAttributes := $001F00C0;
  FTexture := 0;
  FPalette := 0;
  FViewport := $BFFF0000;
  FX := 0;
  FY := 0;
  FZ := 0;
  FU := 0;
  FV := 0;
  FVertexCount := 0;
  FBuildingCount := 0;
  FPending := nil;
  FSwapPending := False;
  FRendering := nil;
  FRenderReady := False;
  FRenderFlags := 0;
  FRenderViewport := FViewport;
  FStackError := False;
  FControl := 0;
  FAlphaTest := 0;
  FFogColor := 0;
  FFogOffset := 0;
  FRearOffset := 0;
  FRawU := 0;
  FRawV := 0;
  FSwapFlags := 0;
  FPendingFlags := 0;
  FBoxResult := True;
  FillChar(FToon, SizeOf(FToon), 0);
  FillChar(FFogTable, SizeOf(FFogTable), 0);
  FillChar(FEdgeColors, SizeOf(FEdgeColors), 0);
  FillChar(FShininess, SizeOf(FShininess), 0);
  FillChar(FPolygonID, SizeOf(FPolygonID), 0);
  FillChar(FTranslucentID, SizeOf(FTranslucentID), 255);
  FillChar(FFogFlags, SizeOf(FFogFlags), 0);
  FillChar(FShadow, SizeOf(FShadow), 0);
  FillChar(FCoverage, SizeOf(FCoverage), 0);
  FillChar(FVectorResult, SizeOf(FVectorResult), 0);
  FDiffuseAmbient := $7FFF;
  FSpecularEmission := 0;
  FStripParity := False;
  FillChar(FLightVectors, SizeOf(FLightVectors), 0);
  FillChar(FLightColors, SizeOf(FLightColors), 0);
  FillChar(Pixels, SizeOf(Pixels), 0);
  FillChar(Alpha, SizeOf(Alpha), 0);
  FillChar(FPositionResult, SizeOf(FPositionResult), 0);
  ClearColor := 0;
  ClearDepth := $7FFF;
  IRQMode := 0;
end;

procedure TNDSGeometry.SelectCommand(Command: Integer);
begin
  FCommand := Command;
  FParameterCount := 0;
  FExpected := CountParameters(Command);
  if FExpected = 0 then
    ExecuteCommand;
end;

procedure TNDSGeometry.FIFO(Value: Cardinal);
begin
  if FExpected > FParameterCount then
  begin
    FParameters[FParameterCount] := Value;
    Inc(FParameterCount);
    if FParameterCount < FExpected then
      Exit;
    ExecuteCommand;
  end
  else
  begin
    FPackedCommands := Value;
    FCommandsLeft := 4;
  end;
  while FCommandsLeft > 0 do
  begin
    var Command := FPackedCommands and $FF;
    FPackedCommands := FPackedCommands shr 8;
    Dec(FCommandsLeft);
    SelectCommand(Command);
    if FExpected <> 0 then
      Break;
  end;
end;

procedure TNDSGeometry.Direct(Command: Integer; Value: Cardinal);
begin
  if (FCommand <> Command) or (FParameterCount >= FExpected) then
    SelectCommand(Command);
  if FExpected = 0 then
    Exit;
  FParameters[FParameterCount] := Value;
  Inc(FParameterCount);
  if FParameterCount = FExpected then
    ExecuteCommand;
end;

procedure TNDSGeometry.Multiply(const M: TNDSMatrix);
begin
  FMatrices[FMode] := Product(FMatrices[FMode], M);
  if FMode = 2 then
    FMatrices[1] := Product(FMatrices[1], M);
end;

procedure TNDSGeometry.ExecuteCommand;
begin
  var P := FParameters[0];
  case FCommand of
    $10:
      FMode := P and 3;
    $11:
      case FMode of
        0:
          FProjectionStack := FMatrices[0];
        1, 2:
          begin
            FPositionStack[FStack and 31] := FMatrices[1];
            FVectorStack[FStack and 31] := FMatrices[2];
            if FStack = 31 then
              FStackError := True;
            FStack := (FStack + 1) and 31;
          end;
        3:
          FTextureStack := FMatrices[3];
      end;
    $12:
      case FMode of
        0:
          FMatrices[0] := FProjectionStack;
        1, 2:
          begin
            FStack := (FStack - SignedBits(P, 6)) and 31;
            FMatrices[1] := FPositionStack[FStack];
            FMatrices[2] := FVectorStack[FStack];
          end;
        3:
          FMatrices[3] := FTextureStack;
      end;
    $13:
      if FMode in [1, 2] then
      begin
        FPositionStack[P and 31] := FMatrices[1];
        FVectorStack[P and 31] := FMatrices[2];
      end;
    $14:
      if FMode in [1, 2] then
      begin
        FMatrices[1] := FPositionStack[P and 31];
        FMatrices[2] := FVectorStack[P and 31];
      end;
    $15:
      begin
        Identity(FMatrices[FMode]);
        if FMode = 2 then
          Identity(FMatrices[1]);
      end;
    $16..$1C:
      begin
        var M: TNDSMatrix;
        Identity(M);
        case FCommand of
          $16, $18:
            for var i := 0 to 15 do
              M[i] := Integer(FParameters[i]) / 4096;
          $17, $19:
            for var i := 0 to 11 do
              M[(i div 3) * 4 + (i mod 3)] := Integer(FParameters[i]) / 4096;
          $1A:
            for var i := 0 to 8 do
              M[(i div 3) * 4 + (i mod 3)] := Integer(FParameters[i]) / 4096;
          $1B:
            begin
              M[0] := Integer(P) / 4096;
              M[5] := Integer(FParameters[1]) / 4096;
              M[10] := Integer(FParameters[2]) / 4096;
            end;
          $1C:
            for var i := 0 to 2 do
              M[12 + i] := Integer(FParameters[i]) / 4096;
        end;
        if FCommand in [$16, $17] then
        begin
          FMatrices[FMode] := M;
          if FMode = 2 then
            FMatrices[1] := M;
        end
        else if (FCommand = $1B) and (FMode = 2) then
          FMatrices[1] := Product(FMatrices[1], M)
        else
          Multiply(M);
      end;
    $20:
      FColor := P and $7FFF;
    $21:
      Light(P);
    $22:
      begin
        FRawU := SignedBits(P, 16) / 16;
        FRawV := SignedBits(P shr 16, 16) / 16;
        FU := FRawU;
        FV := FRawV;
        if FTexture shr 30 = 1 then
        begin
          FU := FMatrices[3, 0] * FRawU + FMatrices[3, 4] * FRawV + (FMatrices[3, 8] + FMatrices[3, 12]) / 16;
          FV := FMatrices[3, 1] * FRawU + FMatrices[3, 5] * FRawV + (FMatrices[3, 9] + FMatrices[3, 13]) / 16;
        end;
      end;
    $23:
      begin
        FX := SignedBits(P, 16) / 4096;
        FY := SignedBits(P shr 16, 16) / 4096;
        FZ := SignedBits(FParameters[1], 16) / 4096;
        AddVertex;
      end;
    $24:
      begin
        FX := SignedBits(P, 10) / 64;
        FY := SignedBits(P shr 10, 10) / 64;
        FZ := SignedBits(P shr 20, 10) / 64;
        AddVertex;
      end;
    $25:
      begin
        FX := SignedBits(P, 16) / 4096;
        FY := SignedBits(P shr 16, 16) / 4096;
        AddVertex;
      end;
    $26:
      begin
        FX := SignedBits(P, 16) / 4096;
        FZ := SignedBits(P shr 16, 16) / 4096;
        AddVertex;
      end;
    $27:
      begin
        FY := SignedBits(P, 16) / 4096;
        FZ := SignedBits(P shr 16, 16) / 4096;
        AddVertex;
      end;
    $28:
      begin
        FX := FX + SignedBits(P, 10) / 4096;
        FY := FY + SignedBits(P shr 10, 10) / 4096;
        FZ := FZ + SignedBits(P shr 20, 10) / 4096;
        AddVertex;
      end;
    $29:
      FAttributes := P;
    $2A:
      FTexture := P;
    $2B:
      FPalette := P and $1FFF;
    $30:
      begin
        FDiffuseAmbient := P;
        if P and $8000 <> 0 then
          FColor := P and $7FFF;
      end;
    $31:
      FSpecularEmission := P;
    $32:
      begin
        var L := P shr 30;
        var V := Default(TNDSVertex);
        V.X := SignedBits(P, 10) / 512;
        V.Y := SignedBits(P shr 10, 10) / 512;
        V.Z := SignedBits(P shr 20, 10) / 512;
        V := Transform(V, FMatrices[2]);
        FLightVectors[L, 0] := V.X;
        FLightVectors[L, 1] := V.Y;
        FLightVectors[L, 2] := V.Z;
      end;
    $33:
      FLightColors[P shr 30] := P and $7FFF;
    $34:
      for var i := 0 to 127 do
        FShininess[i] := Byte(FParameters[i div 4] shr ((i and 3) * 8));
    $40:
      begin
        FPrimitive := P and 3;
        FVertexCount := 0;
        FStripParity := False;
      end;
    $41:
      FVertexCount := 0;
    $50:
      begin
        FPending := Copy(FBuilding, 0, FBuildingCount);
        FBuildingCount := 0;
        FPendingFlags := FSwapFlags;
        FSwapFlags := P and 3;
        FSwapPending := True;
      end;
    $60:
      FViewport := P;
    $70:
      begin
        var Outside: array[0..5] of Boolean;
        for var i := 0 to 5 do
          Outside[i] := True;
        for var Corner := 0 to 7 do
        begin
          var V := Default(TNDSVertex);
          V.X := SignedBits(P, 16) / 4096;
          V.Y := SignedBits(P shr 16, 16) / 4096;
          V.Z := SignedBits(FParameters[1], 16) / 4096;
          V.W := 1;
          if Corner and 1 <> 0 then
            V.X := V.X + SignedBits(FParameters[1] shr 16, 16) / 4096;
          if Corner and 2 <> 0 then
            V.Y := V.Y + SignedBits(FParameters[2], 16) / 4096;
          if Corner and 4 <> 0 then
            V.Z := V.Z + SignedBits(FParameters[2] shr 16, 16) / 4096;
          V := Transform(Transform(V, FMatrices[1]), FMatrices[0]);
          Outside[0] := Outside[0] and (V.X < -V.W);
          Outside[1] := Outside[1] and (V.X > V.W);
          Outside[2] := Outside[2] and (V.Y < -V.W);
          Outside[3] := Outside[3] and (V.Y > V.W);
          Outside[4] := Outside[4] and (V.Z < -V.W);
          Outside[5] := Outside[5] and (V.Z > V.W);
        end;
        FBoxResult := True;
        for var i := 0 to 5 do
          if Outside[i] then
            FBoxResult := False;
      end;
    $72:
      begin
        var V := Default(TNDSVertex);
        V.X := SignedBits(P, 10) / 512;
        V.Y := SignedBits(P shr 10, 10) / 512;
        V.Z := SignedBits(P shr 20, 10) / 512;
        V := Transform(V, FMatrices[2]);
        FVectorResult[0] := SmallInt(Round(V.X * 4096) and $FFFF);
        FVectorResult[1] := SmallInt(Round(V.Y * 4096) and $FFFF);
        FVectorResult[2] := SmallInt(Round(V.Z * 4096) and $FFFF);
      end;
    $71:
      begin
        var V := Default(TNDSVertex);
        V.X := SignedBits(P, 16) / 4096;
        V.Y := SignedBits(P shr 16, 16) / 4096;
        V.Z := SignedBits(FParameters[1], 16) / 4096;
        V.W := 1;
        V := Transform(Transform(V, FMatrices[1]), FMatrices[0]);
        FPositionResult[0] := Cardinal(Round(V.X * 4096) and $FFFFFFFF);
        FPositionResult[1] := Cardinal(Round(V.Y * 4096) and $FFFFFFFF);
        FPositionResult[2] := Cardinal(Round(V.Z * 4096) and $FFFFFFFF);
        FPositionResult[3] := Cardinal(Round(V.W * 4096) and $FFFFFFFF);
      end;
  end;
  FParameterCount := FExpected;
end;

procedure TNDSGeometry.Light(Normal: Cardinal);
begin
  var V := Default(TNDSVertex);
  V.X := SignedBits(Normal, 10) / 512;
  V.Y := SignedBits(Normal shr 10, 10) / 512;
  V.Z := SignedBits(Normal shr 20, 10) / 512;
  if FTexture shr 30 = 2 then
  begin
    FU := V.X * FMatrices[3, 0] + V.Y * FMatrices[3, 4] + V.Z * FMatrices[3, 8] + FRawU;
    FV := V.X * FMatrices[3, 1] + V.Y * FMatrices[3, 5] + V.Z * FMatrices[3, 9] + FRawV;
  end;
  V := Transform(V, FMatrices[2]);
  var RGB: array[0..2] of Integer;
  for var C := 0 to 2 do
  begin
    var Value := Double((FSpecularEmission shr (16 + C * 5)) and 31);
    for var L := 0 to 3 do
      if FAttributes and (1 shl L) <> 0 then
      begin
        var Diffuse := Max(0.0, -(V.X * FLightVectors[L, 0] + V.Y * FLightVectors[L, 1] + V.Z * FLightVectors[L, 2]));
        var Specular := Max(0.0, -(V.X * FLightVectors[L, 0] + V.Y * FLightVectors[L, 1] + V.Z * (FLightVectors[L, 2] - 1)) * 0.5);
        Specular := Specular * Specular;
        if FSpecularEmission and $8000 <> 0 then
          Specular := FShininess[EnsureRange(Trunc(Specular * 128), 0, 127)] / 256;
        var Material := ((FDiffuseAmbient shr (C * 5)) and 31) * Diffuse +
          ((FDiffuseAmbient shr (16 + C * 5)) and 31) + ((FSpecularEmission shr (C * 5)) and 31) * Specular;
        Value := Value + Material * ((FLightColors[L] shr (C * 5)) and 31) / 31;
      end;
    RGB[C] := EnsureRange(Round(Value), 0, 31);
  end;
  FColor := RGB[0] or (RGB[1] shl 5) or (RGB[2] shl 10);
end;

procedure TNDSGeometry.AddTriangle(const A, B, C: TNDSVertex);
begin
  if FBuildingCount >= Length(FBuilding) then
    Exit;
  var i := FBuildingCount;
  Inc(FBuildingCount);
  FBuilding[i].V[0] := A;
  FBuilding[i].V[1] := B;
  FBuilding[i].V[2] := C;
  FBuilding[i].Attributes := FAttributes;
  FBuilding[i].Texture := FTexture;
  FBuilding[i].Palette := FPalette;
end;

procedure TNDSGeometry.AddVertex;
begin
  var V := Default(TNDSVertex);
  V.X := FX;
  V.Y := FY;
  V.Z := FZ;
  V.W := 1;
  V.U := FU;
  V.V := FV;
  V.R := FColor and 31;
  V.G := (FColor shr 5) and 31;
  V.B := (FColor shr 10) and 31;
  if FTexture shr 30 = 3 then
  begin
    V.U := V.X * FMatrices[3, 0] + V.Y * FMatrices[3, 4] + V.Z * FMatrices[3, 8] + FRawU;
    V.V := V.X * FMatrices[3, 1] + V.Y * FMatrices[3, 5] + V.Z * FMatrices[3, 9] + FRawV;
  end;
  V.U := SignedBits(Cardinal(Trunc(V.U * 16) and $FFFF), 16) / 16;
  V.V := SignedBits(Cardinal(Trunc(V.V * 16) and $FFFF), 16) / 16;
  V := Transform(Transform(V, FMatrices[1]), FMatrices[0]);
  FVertices[FVertexCount] := V;
  Inc(FVertexCount);
  case FPrimitive of
    0:
      if FVertexCount = 3 then
      begin
        AddTriangle(FVertices[0], FVertices[1], FVertices[2]);
        FVertexCount := 0;
      end;
    1:
      if FVertexCount = 4 then
      begin
        AddTriangle(FVertices[0], FVertices[1], FVertices[2]);
        AddTriangle(FVertices[0], FVertices[2], FVertices[3]);
        FVertexCount := 0;
      end;
    2:
      if FVertexCount = 3 then
      begin
        if FStripParity then
          AddTriangle(FVertices[1], FVertices[0], FVertices[2])
        else
          AddTriangle(FVertices[0], FVertices[1], FVertices[2]);
        FStripParity := not FStripParity;
        FVertices[0] := FVertices[1];
        FVertices[1] := FVertices[2];
        FVertexCount := 2;
      end;
    3:
      if FVertexCount = 4 then
      begin
        AddTriangle(FVertices[0], FVertices[1], FVertices[2]);
        AddTriangle(FVertices[1], FVertices[3], FVertices[2]);
        FVertices[0] := FVertices[2];
        FVertices[1] := FVertices[3];
        FVertexCount := 2;
      end;
  end;
end;

function TNDSGeometry.Read16(Address: Cardinal): Word;
begin
  Result := Read8(Address) or (Word(Read8(Address + 1)) shl 8);
end;

function TNDSGeometry.Read8(Address: Cardinal): Byte;
begin
  if Assigned(FGetPage) then
  begin
    var Page := Address and $FFFFC000;
    if Page <> FReadTag then
    begin
      FReadPage := FGetPage(Page);
      FReadTag := Page;
    end;
    var Memory := FReadPage;
    if Memory <> nil then
    begin
      Inc(Memory, Address and $3FFF);
      Exit(Memory^);
    end;
  end;
  Result := FRead(Address);
end;

function TNDSGeometry.Texel(Texture, Palette: Cardinal; U, V: Double; out Alpha: Integer): Integer;
begin
  Result := $7FFF;
  Alpha := 31;
  var Format := (Texture shr 26) and 7;
  if Format = 0 then
    Exit;
  var W := 8 shl ((Texture shr 20) and 7);
  var H := 8 shl ((Texture shr 23) and 7);
  var X := PixelFloor(U);
  var Y := PixelFloor(V);
  if Texture and $10000 <> 0 then
  begin
    if (Texture and $40000 <> 0) and (X and W <> 0) then
      X := not X;
    X := X and (W - 1);
  end
  else
    X := EnsureRange(X, 0, W - 1);
  if Texture and $20000 <> 0 then
  begin
    if (Texture and $80000 <> 0) and (Y and H <> 0) then
      Y := not Y;
    Y := Y and (H - 1);
  end
  else
    Y := EnsureRange(Y, 0, H - 1);
  var Index := Y * W + X;
  var Address := TextureBase + (Texture and $FFFF) * 8;
  var Entry := 0;
  var PaletteAddress := PaletteBase + Palette * 16;
  case Format of
    1:
      begin
        Entry := Read8(Address + Cardinal(Index));
        Alpha := ((Entry shr 5) * 31) div 7;
        Entry := Entry and 31;
      end;
    2:
      begin
        Entry := (Read8(Address + Cardinal(Index div 4)) shr ((Index and 3) * 2)) and 3;
        PaletteAddress := PaletteBase + Palette * 8;
      end;
    3:
      Entry := (Read8(Address + Cardinal(Index div 2)) shr ((Index and 1) * 4)) and 15;
    4:
      Entry := Read8(Address + Cardinal(Index));
    5:
      begin
        var Block := (Y div 4) * (W div 4) + (X div 4);
        var Bit := ((Y and 3) * 4 + (X and 3)) * 2;
        var DataAddress := Address + Cardinal(Block) * 4 + Cardinal(Bit div 8);
        Entry := (Read8(DataAddress) shr (Bit and 7)) and 3;
        var Offset := (Texture and $FFFF) * 8;
        var Descriptor := Read16(TextureBase + $20000 + ((Offset and $1FFFF) shr 1) + ((Offset and $40000) shr 2) + Cardinal(Block) * 2);
        Inc(PaletteAddress, Cardinal(Descriptor and $3FFF) * 4);
        var Mode := Descriptor shr 14;
        if (Entry = 3) and (Mode < 2) then
        begin
          Alpha := 0;
          Exit(0);
        end;
        if ((Mode = 1) or (Mode = 3)) and (Entry >= 2) then
        begin
          var A := Read16(PaletteAddress);
          var B := Read16(PaletteAddress + 2);
          var FA := 1;
          var FB := 1;
          var Divisor := 2;
          if Mode = 3 then
          begin
            Divisor := 8;
            FA := 5;
            FB := 3;
            if Entry = 3 then
            begin
              FA := 3;
              FB := 5;
            end;
          end;
          Exit(((A and 31) * FA + (B and 31) * FB) div Divisor or
            (((((A shr 5) and 31) * FA + ((B shr 5) and 31) * FB) div Divisor) shl 5) or
            (((((A shr 10) and 31) * FA + ((B shr 10) and 31) * FB) div Divisor) shl 10));
        end;
      end;
    6:
      begin
        Entry := Read8(Address + Cardinal(Index));
        Alpha := Entry shr 3;
        Entry := Entry and 7;
      end;
    7:
      begin
        var Color := Read16(Address + Cardinal(Index) * 2);
        if Color and $8000 = 0 then
          Alpha := 0;
        Exit(Color and $7FFF);
      end;
  end;
  if (Entry = 0) and (Texture and $20000000 <> 0) and (Format in [2, 3, 4]) then
    Alpha := 0;
  if Format = 5 then
    Exit(Read16(PaletteAddress + Cardinal(Entry) * 2) and $7FFF);
  if not FPaletteValid[Entry] then
  begin
    FPaletteCache[Entry] := Read16(PaletteAddress + Cardinal(Entry) * 2) and $7FFF;
    FPaletteValid[Entry] := True;
  end;
  Result := FPaletteCache[Entry];
end;

procedure TNDSGeometry.PreparePolygon(const Polygon: TNDSPolygon);
var
  A, B: array[0..15] of TNDSVertex;

  function Distance(const V: TNDSVertex; Plane: Integer): Double;
  begin
    case Plane of
      0:
        Result := V.W + V.X;
      1:
        Result := V.W - V.X;
      2:
        Result := V.W + V.Y;
      3:
        Result := V.W - V.Y;
      4:
        Result := V.W + V.Z;
    else
      Result := V.W - V.Z;
    end;
  end;

  function Interpolate(const P, Q: TNDSVertex; T: Double): TNDSVertex;
  begin
    Result.X := P.X + (Q.X - P.X) * T;
    Result.Y := P.Y + (Q.Y - P.Y) * T;
    Result.Z := P.Z + (Q.Z - P.Z) * T;
    Result.W := P.W + (Q.W - P.W) * T;
    Result.U := P.U + (Q.U - P.U) * T;
    Result.V := P.V + (Q.V - P.V) * T;
    Result.R := P.R + (Q.R - P.R) * T;
    Result.G := P.G + (Q.G - P.G) * T;
    Result.B := P.B + (Q.B - P.B) * T;
  end;

begin
  var Count := 3;
  for var i := 0 to 2 do
    A[i] := Polygon.V[i];
  for var Plane := 0 to 5 do
  begin
    if Count < 3 then
      Exit;
    var OutCount := 0;
    var Previous := A[Count - 1];
    var PD := Distance(Previous, Plane);
    for var i := 0 to Count - 1 do
    begin
      var Current := A[i];
      var CD := Distance(Current, Plane);
      if (PD >= 0) <> (CD >= 0) then
      begin
        B[OutCount] := Interpolate(Previous, Current, PD / (PD - CD));
        Inc(OutCount);
      end;
      if CD >= 0 then
      begin
        B[OutCount] := Current;
        Inc(OutCount);
      end;
      Previous := Current;
      PD := CD;
    end;
    Count := OutCount;
    for var i := 0 to Count - 1 do
      A[i] := B[i];
  end;
  var Triangle := Polygon;
  for var i := 1 to Count - 2 do
  begin
    Triangle.V[0] := A[0];
    Triangle.V[1] := A[i];
    Triangle.V[2] := A[i + 1];
    PrepareTriangle(Triangle);
  end;
end;

procedure TNDSGeometry.PrepareTriangle(const Polygon: TNDSPolygon);
begin
  var V := Polygon.V;
  for var i := 0 to 2 do
  begin
    if V[i].W <= 0.00001 then
      Exit;
    var ViewW := Integer((FViewport shr 16) and 255) - Integer(FViewport and 255) + 1;
    var ViewH := Integer((FViewport shr 24) and 255) - Integer((FViewport shr 8) and 255) + 1;
    V[i].X := ((V[i].X / V[i].W + 1) * 0.5) * ViewW + (FViewport and 255);
    V[i].Y := 191 - (((V[i].Y / V[i].W + 1) * 0.5) * ViewH + ((FViewport shr 8) and 255));
    V[i].Z := V[i].Z / V[i].W;
  end;
  if FPreparedCount = Length(FPrepared) then
    SetLength(FPrepared, FPreparedCount + 256);
  FPrepared[FPreparedCount] := Polygon;
  FPrepared[FPreparedCount].V := V;
  Inc(FPreparedCount);
end;

procedure TNDSGeometry.RasterizeTriangle(const Polygon: TNDSPolygon);
const
  SampleCount: array[0..15] of Integer = (0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);

  function Edge(const A, B: TNDSVertex; X, Y: Double): Double; {$IFDEF CPUX64} inline;{$ENDIF}
  begin
    Result := (X - A.X) * (B.Y - A.Y) - (Y - A.Y) * (B.X - A.X);
  end;

  function SampleDepth(Source: PNDSPolygon; X, Y, BackgroundDepth: Double): Double;
  begin
    if Source = nil then
      Exit(BackgroundDepth);
    var P := Source^.V;
    var Area := Edge(P[0], P[1], P[2].X, P[2].Y);
    var A := Edge(P[1], P[2], X, Y) / Area;
    var B := Edge(P[2], P[0], X, Y) / Area;
    var C := 1 - A - B;
    if FPendingFlags and 2 <> 0 then
      Result := 2 / ((A / P[0].W + B / P[1].W + C / P[2].W) * 4095.875) - 1
    else
      Result := A * P[0].Z + B * P[1].Z + C * P[2].Z;
  end;

begin
  var V := Polygon.V;
  var Area := Edge(V[0], V[1], V[2].X, V[2].Y);
  if Abs(Area) < 0.00001 then
    Exit;
  if ((Area > 0) and (Polygon.Attributes and $80 = 0)) or ((Area < 0) and (Polygon.Attributes and $40 = 0)) then
    Exit;

  // A pixel's four AA samples are within 1/4 pixel of its center. Only the
  // edge band needs individual coverage tests; strictly interior pixels are
  // fully covered. Keep the original sample calculation on the boundary.
  var RadiusA := 0.25 * (Abs(V[2].Y - V[1].Y) + Abs(V[2].X - V[1].X)) / Abs(Area) + 1E-10;
  var RadiusB := 0.25 * (Abs(V[0].Y - V[2].Y) + Abs(V[0].X - V[2].X)) / Abs(Area) + 1E-10;
  var RadiusC := 0.25 * (Abs(V[1].Y - V[0].Y) + Abs(V[1].X - V[0].X)) / Abs(Area) + 1E-10;
  var UnitW := (V[0].W = 1) and (V[1].W = 1) and (V[2].W = 1);
  {$IFDEF CPUX64}
  var EdgeADY := V[2].Y - V[1].Y;
  var EdgeADX := V[2].X - V[1].X;
  var EdgeBDY := V[0].Y - V[2].Y;
  var EdgeBDX := V[0].X - V[2].X;
  {$ENDIF}
  var X0 := Max(0, Floor(Min(V[0].X, Min(V[1].X, V[2].X))));
  var X1 := Min(255, Ceil(Max(V[0].X, Max(V[1].X, V[2].X))));
  var BoundsY0 := Max(0, Floor(Min(V[0].Y, Min(V[1].Y, V[2].Y))));
  var BoundsY1 := Min(191, Ceil(Max(V[0].Y, Max(V[1].Y, V[2].Y))));
  var Y0 := Max(FClipY0, BoundsY0);
  var Y1 := Min(FClipY1, BoundsY1);
  if (X0 > X1) or (Y0 > Y1) then
    Exit;
  var PolygonAlpha := Integer((Polygon.Attributes shr 16) and 31);
  if PolygonAlpha = 0 then
    PolygonAlpha := 31;
  FillChar(FPaletteValid, SizeOf(FPaletteValid), 0);
  var FlatColor := (V[0].R = V[1].R) and (V[0].R = V[2].R) and
    (V[0].G = V[1].G) and (V[0].G = V[2].G) and
    (V[0].B = V[1].B) and (V[0].B = V[2].B);
  var ConstantColor: array[0..2] of Integer;
  ConstantColor[0] := EnsureRange(Round(V[0].R), 0, 31);
  ConstantColor[1] := EnsureRange(Round(V[0].G), 0, 31);
  ConstantColor[2] := EnsureRange(Round(V[0].B), 0, 31);
  for var Y := Y0 to Y1 do
  begin
    {$IFDEF CPUX64}
    var AY := Y + 0.5 - V[1].Y;
    var BY := Y + 0.5 - V[2].Y;
    {$ENDIF}
    for var X := X0 to X1 do
    begin
      {$IFDEF CPUX64}
      var PX := X + 0.5;
      var A := ((PX - V[1].X) * EdgeADY - AY * EdgeADX) / Area;
      var B := ((PX - V[2].X) * EdgeBDY - BY * EdgeBDX) / Area;
      {$ELSE}
      var A := Edge(V[1], V[2], X + 0.5, Y + 0.5) / Area;
      var B := Edge(V[2], V[0], X + 0.5, Y + 0.5) / Area;
      {$ENDIF}
      var C := 1 - A - B;
      var Coverage := 4;
      var SampleMask: Byte := 15;
      if (FControl and $10 <> 0) and ((A < -RadiusA) or (B < -RadiusB) or (C < -RadiusC)) then
        Continue;
      if (FControl and $10 <> 0) and not ((A > RadiusA) and (B > RadiusB) and (C > RadiusC)) then
      begin
        Coverage := 0;
        SampleMask := 0;
        for var SampleY := 0 to 1 do
          for var SampleX := 0 to 1 do
          begin
            var SX := X + 0.25 + SampleX * 0.5;
            var SY := Y + 0.25 + SampleY * 0.5;
            var SA := Edge(V[1], V[2], SX, SY) / Area;
            var SB := Edge(V[2], V[0], SX, SY) / Area;
            if (SA >= 0) and (SB >= 0) and (SA + SB <= 1) then
            begin
              Inc(Coverage);
              SampleMask := SampleMask or (1 shl (SampleY * 2 + SampleX));
            end;
          end;
        if Coverage = 0 then
          Continue;
      end
      else if (FControl and $10 = 0) and ((A < 0) or (B < 0) or (C < 0)) then
        Continue;
      var Z := A * V[0].Z + B * V[1].Z + C * V[2].Z;
      if (Z < -1) or (Z > 1) then
        Continue;
      var Offset := Y * 256 + X;
      var PolygonID: Byte := (Polygon.Attributes shr 24) and 63;
      var Mode: Integer := (Polygon.Attributes shr 4) and 3;
      if (Polygon.Attributes shr 16) and 31 = 0 then
      begin
        // Alpha zero selects a wireframe, retaining only the triangle border.
        var Thickness := Max(1.0 / (X1 - X0 + 1), 1.0 / (BoundsY1 - BoundsY0 + 1));
        if Min(A, Min(B, C)) > Thickness then
          Continue;
      end;
      var InvW: Double;
      if UnitW then
        InvW := A + B + C
      else
        InvW := A / V[0].W + B / V[1].W + C / V[2].W;
      if Abs(InvW) < 0.000001 then
        Continue;
      if FPendingFlags and 2 <> 0 then
        Z := 2 / (InvW * 4095.875) - 1;
      var Pass := Z < Depth[Offset];
      if Polygon.Attributes and $4000 <> 0 then
        Pass := Abs(Z - Depth[Offset]) <= 512.0 / 16777215.0;
      if Mode = 3 then
      begin
        if PolygonID = 0 then
        begin
          if not Pass then
            FShadow[Offset] := True;
          Continue;
        end;
        if not FShadow[Offset] or (FPolygonID[Offset] = PolygonID) then
          Continue;
      end;

      // Adjacent faces have different center depths even at a shared edge.
      // Resolve their covered samples rather than rejecting the farther center.
      var CoverageState: PNDSCoverage := @FCoverage[Offset];
      var CombineSamples := (Mode <> 3) and (FControl and $30 = $10) and
        ((CoverageState.Mask <> 0) or (Coverage < 4));
      if not Pass and not CombineSamples then
        Continue;

      var U, T: Double;
      if UnitW then
      begin
        U := (A * V[0].U + B * V[1].U + C * V[2].U) / InvW;
        T := (A * V[0].V + B * V[1].V + C * V[2].V) / InvW;
      end
      else
      begin
        U := (A * V[0].U / V[0].W + B * V[1].U / V[1].W + C * V[2].U / V[2].W) / InvW;
        T := (A * V[0].V / V[0].W + B * V[1].V / V[1].W + C * V[2].V / V[2].W) / InvW;
      end;
      var TextureAlpha: Integer := 31;
      var Color: Integer := $7FFF;
      if FControl and 1 <> 0 then
        Color := Texel(Polygon.Texture, Polygon.Palette, U, T, TextureAlpha);
      var Opacity := ((PolygonAlpha + 1) * (TextureAlpha + 1) - 1) shr 5;
      if Mode = 1 then
        Opacity := PolygonAlpha;
      if (Opacity = 0) or ((FControl and 4 <> 0) and (Opacity <= FAlphaTest)) then
        Continue;

      var Opaque := Opacity = 31;
      if not Opaque then
      begin
        CombineSamples := False;
        if not Pass then
          Continue;
      end;

      if Opaque and (Coverage < 4) and (FControl and $20 = 0) then
        Opacity := Max(1, Coverage * 8 - 1);
      if not Opaque and (FTranslucentID[Offset] = PolygonID) then
        Continue;

      var VertexColor: array[0..2] of Integer;
      if FlatColor then
      begin
        VertexColor[0] := ConstantColor[0];
        VertexColor[1] := ConstantColor[1];
        VertexColor[2] := ConstantColor[2];
      end
      else
      begin
        VertexColor[0] := EnsureRange(Round(A * V[0].R + B * V[1].R + C * V[2].R), 0, 31);
        VertexColor[1] := EnsureRange(Round(A * V[0].G + B * V[1].G + C * V[2].G), 0, 31);
        VertexColor[2] := EnsureRange(Round(A * V[0].B + B * V[1].B + C * V[2].B), 0, 31);
      end;
      var Toon := FToon[VertexColor[0]];
      var Output: Word := 0;
      var Blend := (Opacity < 31) and (FControl and 8 <> 0) and (Alpha[Offset] <> 0) and not CombineSamples;
      for var Channel := 0 to 2 do
      begin
        var VC := VertexColor[Channel];
        var TC := (Color shr (Channel * 5)) and 31;
        if Mode = 2 then
          VC := (Toon shr (Channel * 5)) and 31;
        var ResultColor := ((TC + 1) * (VC + 1) - 1) shr 5;
        if Mode = 1 then
        begin
          if (FControl and 1 = 0) or (Polygon.Texture and $1C000000 = 0) or (TextureAlpha = 0) then
            ResultColor := VC
          else if TextureAlpha = 31 then
            ResultColor := TC
          else
            ResultColor := (TC * (TextureAlpha + 1) + VC * (31 - TextureAlpha)) shr 5;
        end
        else if (Mode = 2) and (FControl and 2 <> 0) then
          ResultColor := Min(31, ResultColor + VC);
        if Blend then
          ResultColor := (ResultColor * (Opacity + 1) + ((Pixels[Offset] shr (Channel * 5)) and 31) * (31 - Opacity)) shr 5;
        Output := Output or (ResultColor shl (Channel * 5));
      end;
      if CombineSamples then
      begin
        if CoverageState.Mask = 0 then
        begin
          CoverageState.BackgroundAlpha := Alpha[Offset];
          for var Sample := 0 to 3 do
          begin
            CoverageState.Colors[Sample] := Pixels[Offset];
            CoverageState.Depths[Sample] := SampleDepth(CoverageState.Source,
                X + 0.25 + (Sample and 1) * 0.5, Y + 0.25 + (Sample shr 1) * 0.5, Depth[Offset]);
          end;
        end;
        var PassedMask: Byte := 0;
        for var Sample := 0 to 3 do
          if SampleMask and (1 shl Sample) <> 0 then
          begin
            var SampleZ := SampleDepth(@Polygon, X + 0.25 + (Sample and 1) * 0.5,
              Y + 0.25 + (Sample shr 1) * 0.5, Z);
            var SamplePass := SampleZ < CoverageState.Depths[Sample];
            if Polygon.Attributes and $4000 <> 0 then
              SamplePass := Abs(SampleZ - CoverageState.Depths[Sample]) <= 512.0 / 16777215.0;
            if SamplePass then
            begin
              CoverageState.Depths[Sample] := SampleZ;
              CoverageState.Colors[Sample] := Output;
              PassedMask := PassedMask or (1 shl Sample);
            end;
          end;
        if PassedMask = 0 then
          Continue;
        CoverageState.Mask := CoverageState.Mask or PassedMask;
        var Total := SampleCount[CoverageState.Mask];
        var Resolved: Word := 0;
        for var Channel := 0 to 2 do
        begin
          var Value := 0;
          for var Sample := 0 to 3 do
            if (CoverageState.BackgroundAlpha <> 0) or (CoverageState.Mask and (1 shl Sample) <> 0) then
              Inc(Value, (CoverageState.Colors[Sample] shr (Channel * 5)) and 31);
          if CoverageState.BackgroundAlpha <> 0 then
            Value := Value div 4
          else
            Value := Value div Total;
          Resolved := Resolved or (Value shl (Channel * 5));
        end;
        Pixels[Offset] := Resolved;
        Alpha[Offset] := Max(CoverageState.BackgroundAlpha, Total * 8 - 1);
        if PassedMask = 15 then
        begin
          CoverageState.Mask := 0;
          CoverageState.Source := @Polygon;
        end;
      end
      else
      begin
        CoverageState.Mask := 0;
        if Opaque then
          CoverageState.Source := @Polygon
        else
          CoverageState.Source := nil;
        Pixels[Offset] := Output;
        if Blend then
          Alpha[Offset] := Max(Opacity, Alpha[Offset])
        else
          Alpha[Offset] := Opacity;
      end;
      if Opaque then
      begin
        if Pass then
        begin
          FPolygonID[Offset] := PolygonID;
          FFogFlags[Offset] := Polygon.Attributes and $8000 <> 0;
        end;
      end
      else
      begin
        FTranslucentID[Offset] := PolygonID;
        FFogFlags[Offset] := FFogFlags[Offset] and (Polygon.Attributes and $8000 <> 0);
      end;
      if (Opaque and Pass) or (not Opaque and (Polygon.Attributes and $800 <> 0)) then
        Depth[Offset] := Z;
    end;
  end;
end;

procedure TNDSGeometry.VBlank;
begin
  SwapBuffers;
  Render;
end;

procedure TNDSGeometry.SwapBuffers;
begin
  if not FSwapPending then
    Exit;
  FSwapPending := False;
  FRendering := FPending;
  FPending := nil;
  FRenderFlags := FPendingFlags;
  FRenderViewport := FViewport;
  FRenderReady := True;
end;

procedure TNDSGeometry.RasterizePrepared(const Polygons: TArray<TNDSPolygon>; Count: Integer);
begin
  for var i := 0 to Count - 1 do
    RasterizeTriangle(Polygons[i]);
end;

procedure TNDSGeometry.Render;

  function Translucent(const P: TNDSPolygon): Boolean;
  begin
    var Mode: Integer := (P.Attributes shr 4) and 3;
    var A: Integer := (P.Attributes shr 16) and 31;
    var TextureAlpha := (FControl and 1 <> 0) and (((P.Texture shr 26) and 7) in [1, 6]) and (Mode <> 1);
    Result := ((A <> 0) and (A < 31)) or TextureAlpha or (Mode = 3);
  end;

  procedure CopyStrip(Source, Target: TNDSGeometry; First, Count: Integer);
  begin
    Move(Source.Pixels[First], Target.Pixels[First], Count * SizeOf(Word));
    Move(Source.Alpha[First], Target.Alpha[First], Count);
    Move(Source.Depth[First], Target.Depth[First], Count * SizeOf(Double));
    Move(Source.FPolygonID[First], Target.FPolygonID[First], Count);
    Move(Source.FTranslucentID[First], Target.FTranslucentID[First], Count);
    Move(Source.FFogFlags[First], Target.FFogFlags[First], Count);
    Move(Source.FShadow[First], Target.FShadow[First], Count);
    Move(Source.FCoverage[First], Target.FCoverage[First], Count * SizeOf(TNDSCoverage));
  end;

begin
  if not FRenderReady then
    Exit;

  FRenderReady := False;

  // Rendering is synchronous. Bank mapping and VRAM bytes stay fixed until
  // it completes; discard borrowed page mappings before every render.
  FReadTag := $FFFFFFFF;
  FReadPage := nil;

  // Geometry is latched at VBlank; rendering registers and texture VRAM are
  // sampled when the rendering engine starts, after the VBlank upload window.
  var PendingFlags := FPendingFlags;
  var Viewport := FViewport;
  FPendingFlags := FRenderFlags;
  FViewport := FRenderViewport;
  try
    // Clipping and projection are shared read-only inputs to every strip.
    FPreparedCount := 0;
    for var Polygon in FRendering do
      if not Translucent(Polygon) then
        PreparePolygon(Polygon);
    for var Polygon in FRendering do
      if Translucent(Polygon) then
        PreparePolygon(Polygon);
    var ClearZ := ClearDepth / 16383.5 - 1;
    for var i := 0 to High(Pixels) do
    begin
      Pixels[i] := ClearColor and $7FFF;
      Alpha[i] := (ClearColor shr 16) and 31;
      Depth[i] := ClearZ;
      FPolygonID[i] := (ClearColor shr 24) and 63;
      FTranslucentID[i] := 255;
      FCoverage[i].Mask := 0;
      FCoverage[i].Source := nil;
      FFogFlags[i] := ClearColor and $8000 <> 0;
      FShadow[i] := False;
      if FControl and $4000 <> 0 then
      begin
        var X := (i mod 256 + (FRearOffset and 255)) and 255;
        var Y := (i div 256 + (FRearOffset shr 8)) and 255;
        var Color := Read16(TextureBase + $40000 + Cardinal(Y * 256 + X) * 2);
        var Z := Read16(TextureBase + $60000 + Cardinal(Y * 256 + X) * 2);
        Pixels[i] := Color and $7FFF;
        Alpha[i] := Ord(Color and $8000 <> 0) * 31;
        Depth[i] := (Z and $7FFF) / 16383.5 - 1;
        FFogFlags[i] := Z and $8000 <> 0;
      end;
    end;
    if (Length(FRendering) >= 32) and (TThread.ProcessorCount >= 4) then
    begin
      var StripCount := 4;
      if TThread.ProcessorCount >= 8 then
        StripCount := 8;
      var StripHeight := 192 div StripCount;

      // Each strip owns its raster scratch and output; polygon order within
      // it is unchanged. VRAM and rendering registers are read-only here.
      for var i := 0 to StripCount - 2 do
      begin
        if FRasterWorkers[i] = nil then
          FRasterWorkers[i] := TNDSGeometry.CreateRasterWorker(Self);
        if FRasterThreads[i] = nil then
          FRasterThreads[i] := TNDSRasterThread.Create(FRasterWorkers[i], i + 1);
        var Worker := FRasterWorkers[i];
        Worker.FControl := FControl;
        Worker.FAlphaTest := FAlphaTest;
        Worker.FToon := FToon;
        Worker.FViewport := FViewport;
        Worker.FPendingFlags := FPendingFlags;
        Worker.FReadTag := $FFFFFFFF;
        Worker.FReadPage := nil;
        Worker.FClipY0 := (i + 1) * StripHeight;
        Worker.FClipY1 := Worker.FClipY0 + StripHeight - 1;
        CopyStrip(Self, Worker, Worker.FClipY0 * 256, StripHeight * 256);
      end;
      FClipY0 := 0;
      FClipY1 := StripHeight - 1;
      var Submitted := 0;
      try
        for var i := 0 to StripCount - 2 do
        begin
          TNDSRasterThread(FRasterThreads[i]).Submit(FPrepared, FPreparedCount);
          Inc(Submitted);
        end;
        RasterizePrepared(FPrepared, FPreparedCount);
      finally
        for var i := 0 to Submitted - 1 do
          TNDSRasterThread(FRasterThreads[i]).Finish;
      end;
      for var i := 0 to StripCount - 2 do
        TNDSRasterThread(FRasterThreads[i]).CheckResult;
      for var i := 0 to StripCount - 2 do
        CopyStrip(FRasterWorkers[i], Self, (i + 1) * StripHeight * 256, StripHeight * 256);
      FClipY1 := 191;
    end
    else
      RasterizePrepared(FPrepared, FPreparedCount);
    Effects;
  finally
    FClipY0 := 0;
    FClipY1 := 191;
    FRendering := nil;
    FPendingFlags := PendingFlags;
    FViewport := Viewport;
  end;
end;

function TNDSGeometry.ReadRegister(Offset: Integer): Cardinal;
begin
  Result := 0;
  case Offset of
    $600:
      begin
        Result := $06000000 or Cardinal(FStack shl 8);
        if FBoxResult then
          Result := Result or 2;
        if FStackError then
          Result := Result or $8000;
        Result := Result or (Cardinal(IRQMode) shl 30);
      end;
    $604:
      Result := FBuildingCount;
    $608:
      Result := FBuildingCount * 3;
    $630, $634, $638:
      Result := Cardinal(Integer(FVectorResult[(Offset - $630) div 4]) and $FFFF);
    $620..$62C:
      Result := FPositionResult[(Offset - $620) div 4];
    $640..$67C:
      begin
        var M := Product(FMatrices[0], FMatrices[1]);
        Result := Cardinal(Round(M[(Offset - $640) div 4] * 4096) and $FFFFFFFF);
      end;
    $680..$6A0:
      Result := Cardinal(Round(FMatrices[2][((Offset - $680) div 4 div 3) * 4 + ((Offset - $680) div 4 mod 3)] * 4096) and $FFFFFFFF);
  end;
end;

procedure TNDSGeometry.WriteRegister(Offset: Integer; Value: Byte);

  procedure PutWord(var Target: Word);
  begin
    var Shift := (Offset and 1) * 8;
    Target := (Target and not (Word($FF) shl Shift)) or (Word(Value) shl Shift);
  end;

begin
  case Offset of
    $60, $61:
      begin
        PutWord(FControl);
        FControl := FControl and $4FFF;
      end;
    $330..$33F:
      PutWord(FEdgeColors[(Offset - $330) div 2]);
    $340:
      FAlphaTest := Value and 31;
    $356, $357:
      PutWord(FRearOffset);
    $358..$35B:
      begin
        var Shift := (Offset and 3) * 8;
        FFogColor := (FFogColor and not (Cardinal($FF) shl Shift)) or (Cardinal(Value) shl Shift);
      end;
    $35C, $35D:
      begin
        PutWord(FFogOffset);
        FFogOffset := FFogOffset and $7FFF;
      end;
    $360..$37F:
      FFogTable[Offset - $360] := Value and 127;
    $380..$3BF:
      PutWord(FToon[(Offset - $380) div 2]);
    $601:
      if Value and $80 <> 0 then
        FStackError := False;
  end;
end;

procedure TNDSGeometry.Effects;
begin
  if FControl and $A0 = 0 then
    Exit;

  for var Y := 0 to 191 do
    for var X := 0 to 255 do
    begin
      var i := Y * 256 + X;
      if (FControl and $20 <> 0) and (Alpha[i] = 31) then
      begin
        var Edge := False;
        for var Direction := 0 to 3 do
        begin
          var NX: Integer := X;
          var NY: Integer := Y;
          case Direction of
            0:
              Dec(NX);
            1:
              Inc(NX);
            2:
              Dec(NY);
            3:
              Inc(NY);
          end;
          var ID: Byte := (ClearColor shr 24) and 63;
          var Z := ClearDepth / 16383.5 - 1;
          if (NX >= 0) and (NX < 256) and (NY >= 0) and (NY < 192) then
          begin
            ID := FPolygonID[NY * 256 + NX];
            Z := Depth[NY * 256 + NX];
          end;
          if (ID <> FPolygonID[i]) and (Depth[i] < Z) then
            Edge := True;
        end;
        if Edge then
          Pixels[i] := FEdgeColors[FPolygonID[i] shr 3] and $7FFF;
      end;
      if (FControl and $80 <> 0) and FFogFlags[i] then
      begin
        var Step := Integer($400 shr ((FControl shr 8) and 15));
        var D := ((Depth[i] + 1) * 16383.5 - FFogOffset);
        var Density: Integer;
        if Step = 0 then
          if D <= 0 then
            Density := FFogTable[0]
          else
            Density := FFogTable[31]
        else
        begin
          var Position := D / Step - 1;
          if Position <= 0 then
            Density := FFogTable[0]
          else if Position >= 31 then
            Density := FFogTable[31]
          else
          begin
            var Index := Floor(Position);
            var Fraction := Position - Index;
            Density := Trunc(FFogTable[Index] * (1 - Fraction) + FFogTable[Index + 1] * Fraction);
          end;
        end;
        if Density = 127 then
          Density := 128;
        var Color: Word := 0;
        if FControl and $40 = 0 then
        begin
          for var Channel := 0 to 2 do
            Color := Color or
              (((((Pixels[i] shr (Channel * 5)) and 31) * (128 - Density) + Integer((FFogColor shr (Channel * 5)) and 31) * Density) shr 7) shl (Channel * 5));
          Pixels[i] := Color;
        end;
        Alpha[i] := (Alpha[i] * (128 - Density) + Integer((FFogColor shr 16) and 31) * Density) shr 7;
      end;
    end;
end;

procedure TNDSGeometry.SerializeState(State: TStateArchive; Version: Cardinal);

  procedure Finite(const Value: Double);
  begin
    if IsNan(Value) or IsInfinite(Value) then
      raise EReadError.Create('Invalid NDS snapshot geometry number');
  end;

  procedure Matrix(const M: TNDSMatrix);
  begin
    for var V in M do
      Finite(V);
  end;

  procedure Vertex(const V: TNDSVertex);
  begin
    Finite(V.X);
    Finite(V.Y);
    Finite(V.Z);
    Finite(V.W);
    Finite(V.U);
    Finite(V.V);
    Finite(V.R);
    Finite(V.G);
    Finite(V.B);
  end;

  procedure Polygon(var P: TNDSPolygon);
  begin
    State.Field(P.V, SizeOf(P.V));
    State.Field(P.Attributes, SizeOf(P.Attributes));
    State.Field(P.Texture, SizeOf(P.Texture));
    State.Field(P.Palette, SizeOf(P.Palette));
    if State.Loading then
      for var V in P.V do
        Vertex(V);
  end;

begin
  State.Field(FControl, SizeOf(FControl));
  State.Field(FAlphaTest, SizeOf(FAlphaTest));
  State.Field(FToon, SizeOf(FToon));
  State.Field(FFogTable, SizeOf(FFogTable));
  State.Field(FFogColor, SizeOf(FFogColor));
  State.Field(FFogOffset, SizeOf(FFogOffset));
  State.Field(FRearOffset, SizeOf(FRearOffset));
  State.Field(FEdgeColors, SizeOf(FEdgeColors));
  State.Field(FPolygonID, SizeOf(FPolygonID));
  State.Field(FTranslucentID, SizeOf(FTranslucentID));
  State.Field(FFogFlags, SizeOf(FFogFlags));
  State.Field(FShadow, SizeOf(FShadow));
  State.Field(FShininess, SizeOf(FShininess));
  State.Field(FRawU, SizeOf(FRawU));
  State.Field(FRawV, SizeOf(FRawV));
  State.Field(FSwapFlags, SizeOf(FSwapFlags));
  State.Field(FPendingFlags, SizeOf(FPendingFlags));
  State.Field(FBoxResult, SizeOf(FBoxResult));
  State.Field(FVectorResult, SizeOf(FVectorResult));
  State.Field(FMatrices, SizeOf(FMatrices));
  State.Field(FPositionStack, SizeOf(FPositionStack));
  State.Field(FVectorStack, SizeOf(FVectorStack));
  State.Field(FProjectionStack, SizeOf(FProjectionStack));
  State.Field(FTextureStack, SizeOf(FTextureStack));
  State.Field(FStack, SizeOf(FStack));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FPrimitive, SizeOf(FPrimitive));
  State.Field(FParameters, SizeOf(FParameters));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FParameterCount, SizeOf(FParameterCount));
  State.Field(FExpected, SizeOf(FExpected));
  State.Field(FCommandsLeft, SizeOf(FCommandsLeft));
  State.Field(FPackedCommands, SizeOf(FPackedCommands));
  State.Field(FColor, SizeOf(FColor));
  State.Field(FDiffuseAmbient, SizeOf(FDiffuseAmbient));
  State.Field(FSpecularEmission, SizeOf(FSpecularEmission));
  State.Field(FLightVectors, SizeOf(FLightVectors));
  State.Field(FLightColors, SizeOf(FLightColors));
  State.Field(FStripParity, SizeOf(FStripParity));
  State.Field(FAttributes, SizeOf(FAttributes));
  State.Field(FTexture, SizeOf(FTexture));
  State.Field(FPalette, SizeOf(FPalette));
  State.Field(FViewport, SizeOf(FViewport));
  State.Field(FX, SizeOf(FX));
  State.Field(FY, SizeOf(FY));
  State.Field(FZ, SizeOf(FZ));
  State.Field(FU, SizeOf(FU));
  State.Field(FV, SizeOf(FV));
  State.Field(FVertices, SizeOf(FVertices));
  State.Field(FVertexCount, SizeOf(FVertexCount));
  State.Field(FBuildingCount, SizeOf(FBuildingCount));
  State.Field(FSwapPending, SizeOf(FSwapPending));
  State.Field(FStackError, SizeOf(FStackError));
  State.Field(FPositionResult, SizeOf(FPositionResult));
  State.Field(Pixels, SizeOf(Pixels));
  State.Field(Alpha, SizeOf(Alpha));
  State.Field(Depth, SizeOf(Depth));
  State.Field(ClearColor, SizeOf(ClearColor));
  State.Field(ClearDepth, SizeOf(ClearDepth));
  State.Field(IRQMode, SizeOf(IRQMode));
  if State.Loading and ((FStack < 0) or (FStack > 31) or (FMode < 0) or (FMode > 3) or
    (FPrimitive < 0) or (FPrimitive > 3) or (FVertexCount < 0) or (FVertexCount > 3) or
    (FCommand < 0) or (FCommand > 255) or (FExpected < 0) or (FExpected > 32) or
    (FParameterCount < 0) or (FParameterCount > FExpected) or (FCommandsLeft < 0) or (FCommandsLeft > 4) or
    (FBuildingCount < 0) or (FBuildingCount > 12288) or (IRQMode > 3)) then
    raise EReadError.Create('Invalid NDS snapshot geometry state');

  for var i := 0 to FBuildingCount - 1 do
    Polygon(FBuilding[i]);
  var Count: Integer := Length(FPending);
  State.Field(Count, SizeOf(Count));
  if (Count < 0) or (Count > 12288) then
    raise EReadError.Create('Invalid NDS snapshot polygon count');

  if State.Loading then
    SetLength(FPending, Count);
  for var i := 0 to Count - 1 do
    Polygon(FPending[i]);
  if Version >= 2 then
  begin
    State.Field(FRenderReady, SizeOf(FRenderReady));
    State.Field(FRenderFlags, SizeOf(FRenderFlags));
    State.Field(FRenderViewport, SizeOf(FRenderViewport));
    Count := Length(FRendering);
    State.Field(Count, SizeOf(Count));
    if (Count < 0) or (Count > 12288) or (FRenderFlags > 3) then
      raise EReadError.Create('Invalid NDS snapshot render list');

    if State.Loading then
      SetLength(FRendering, Count);
    for var i := 0 to Count - 1 do
      Polygon(FRendering[i]);
  end
  else if State.Loading then
  begin
    FRendering := nil;
    FRenderReady := False;
    FRenderFlags := 0;
    FRenderViewport := FViewport;
  end;
  if State.Loading then
  begin
    if (FAlphaTest > 31) or (FFogOffset > $7FFF) or (FSwapFlags > 3) or (FPendingFlags > 3) then
      raise EReadError.Create('Invalid NDS snapshot render controls');

    for var i := 0 to 3 do
      Matrix(FMatrices[i]);
    for var i := 0 to 31 do
    begin
      Matrix(FPositionStack[i]);
      Matrix(FVectorStack[i]);
    end;
    Matrix(FProjectionStack);
    Matrix(FTextureStack);
    for var V in FVertices do
      Vertex(V);
    Finite(FX);
    Finite(FY);
    Finite(FZ);
    Finite(FU);
    Finite(FV);
    Finite(FRawU);
    Finite(FRawV);
    for var i := 0 to 3 do
      for var J := 0 to 2 do
        Finite(FLightVectors[i, J]);

    for var i := 0 to High(Depth) do
    begin
      Finite(Depth[i]);
      if (Alpha[i] > 31) or (FPolygonID[i] > 63) or ((FTranslucentID[i] > 63) and (FTranslucentID[i] <> 255)) then
        raise EReadError.Create('Invalid NDS snapshot pixel attributes');
    end;

    for var Value in FFogTable do
      if Value > 127 then
        raise EReadError.Create('Invalid NDS snapshot fog density');
  end;
end;

end.

