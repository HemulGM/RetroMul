unit DC.PVR.TA;

// Tile accelerator input: parses the 32-byte parameter stream (global
// polygon/sprite/modifier-volume parameters and vertices of every type) into
// backend-independent display lists. A context belongs to the TA_ISP_BASE
// active at list initialization; STARTRENDER selects the context whose base
// matches PARAM_BASE. Lists hold resolved colors, so a renderer (software
// tiles now, a GPU later) never sees the input encoding.
// References: Marcus Comstedt's PowerVR pages, KallistiOS pvr.h.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$TYPEDADDRESS ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, DC.Types,
  DC.Memory, DC.Interrupts, DC.PVR;

const
  TAListOpaque = 0;
  TAListOpaqueMod = 1;
  TAListTranslucent = 2;
  TAListTranslucentMod = 3;
  TAListPunchThrough = 4;

  // TPVRPoly.Kind
  PolyStrip = 0;     // triangle strip of Count vertices
  PolySprite = 1;    // quad: four vertices A, B, C, D
  PolyModifier = 2;  // modifier triangle (three vertices)

type
  TPVRVertex = record
    X, Y, Z: Single;
    U, V: Single;
    Base, Offset: Cardinal;   // ARGB8888
    U1, V1: Single;           // second volume
    Base1, Offset1: Cardinal;
  end;

  PPVRVertex = ^TPVRVertex;

  TPVRPoly = record
    Kind, List: Byte;
    // TA pass (list continuation) the polygon belongs to.
    Pass: Byte;
    TwoVolume: Boolean;
    ISP, TSP, TCW: Cardinal;
    TSP1, TCW1: Cardinal;
    PCW: Cardinal;
    First, Count: Integer;
    // Modifier volumes: instruction of the volume this triangle closes (0 none).
    VolumeEnd: Byte;
    // User tile clip (tiles) when PCW user clip mode is inside/outside.
    ClipMode: Byte;
    ClipX0, ClipY0, ClipX1, ClipY1: Word;
  end;

  PPVRPoly = ^TPVRPoly;

  TPVRContext = class
  public
    Base: Cardinal;
    Polys: TArray<TPVRPoly>;
    Vertices: TArray<TPVRVertex>;
    PolyCount, VertexCount: Integer;
    // Polygon index ranges per list in submission order.
    ListOrder: TArray<Integer>;
    Used: Int64;
    // TA_OL_BASE..TA_OL_LIMIT at list init (not saved): where the region
    // array of a render with another parameter base points.
    OLBase, OLLimit: Cardinal;
    procedure Clear;
    function AddVertex: PPVRVertex; inline;
    function AddPoly: PPVRPoly; inline;
  end;

  TDCTA = class(TDCTAInput)
  private
    FMemory: TDCMemory;
    FInterrupts: TDCInterrupts;
    FPVR: TDCPVR;
    FContexts: array[0..7] of TPVRContext;
    FCurrent: TPVRContext;
    FClock: Int64;
    // Parser state.
    FList: Integer;          // -1: no list open
    FListsDone: Cardinal;    // lists ended since list init (bit per list)
    FPCW, FISP, FTSP, FTCW, FTSP1, FTCW1: Cardinal;
    FVertexType: Integer;    // -1 none
    FPending: array[0..15] of Cardinal; // first half of a 64-byte parameter
    FPendingKind: Integer;   // 0 none, 1 global, 2 vertex
    FFaceColor, FFaceOffset, FFaceColor1, FFaceOffset1: array[0..3] of Single;
    FSpriteBase, FSpriteOffset: Cardinal;
    FStripOpen: Boolean;
    FStripPoly: Integer;
    FModVolumeStart: Integer;
    FPass: Integer;
    FClipMode: Byte;
    FClip: array[0..3] of Word;
    // YUV converter.
    FYUVBuffer: array[0..95] of Cardinal;
    FYUVCount: Integer;
    FYUVBlock: Integer;
    function ContextFor(Base: Cardinal): TPVRContext;
    procedure GlobalParameter(P: PCardinal);
    procedure VertexParameter(P: PCardinal);
    function GlobalSize(PCW: Cardinal): Integer;
    function VertexSize: Integer;
    procedure EndList;
    procedure NewPoly(Kind: Byte);
    procedure YUVMacroblock;
    procedure WaitIdle(Context: TPVRContext); inline;
  public
    // The context the last render read. A list started for its parameter
    // base builds another context, so the render may still read this one;
    // OnBusy (while that render runs) waits for it before the accelerator
    // appends to it.
    Rendering: TPVRContext;
    OnBusy: TDCVRAMBarrier;
    constructor Create(Memory: TDCMemory; Interrupts: TDCInterrupts; PVR: TDCPVR);
    destructor Destroy; override;
    procedure Reset; override;
    procedure SoftReset; override;
    procedure ListInit; override;
    procedure ListContinue; override;
    procedure Write32Bytes(Data: PCardinal); override;
    procedure WriteYUV(Data: PCardinal; Count: Integer); override;
    procedure SerializeState(Archive: TStateArchive); override;
    // The context last built for a parameter base, or nil.
    function Find(Base: Cardinal): TPVRContext;
    // The context last built with its object lists around Address, or nil
    // (renders whose PARAM_BASE differs from TA_ISP_BASE, as Windows CE's).
    function FindByObjectList(Address: Cardinal): TPVRContext;
  end;

function FloatColor(A, R, G, B: Single): Cardinal;

implementation

function Clamp255(V: Single): Cardinal; inline;
begin
  if not (V > 0) then
    Result := 0
  else if V >= 1 then
    Result := 255
  else
    Result := Cardinal(Trunc(V * 255 + 0.5));
end;

function FloatColor(A, R, G, B: Single): Cardinal;
begin
  Result := (Clamp255(A) shl 24) or (Clamp255(R) shl 16) or (Clamp255(G) shl 8) or Clamp255(B);
end;

function AsSingle(V: Cardinal): Single; inline;
begin
  Result := PSingle(@V)^;
end;

function UV16(V: Cardinal; High: Boolean): Single; inline;
begin
  // 16-bit texture coordinates are the upper halves of IEEE singles.
  if High then
    V := V and $FFFF0000
  else
    V := V shl 16;
  Result := PSingle(@V)^;
end;

{ TPVRContext }

procedure TPVRContext.Clear;
begin
  PolyCount := 0;
  VertexCount := 0;
  ListOrder := nil;
end;

function TPVRContext.AddVertex: PPVRVertex;
begin
  if VertexCount >= Length(Vertices) then
    SetLength(Vertices, Max(4096, Length(Vertices) * 2));
  Result := @Vertices[VertexCount];
  Inc(VertexCount);
end;

function TPVRContext.AddPoly: PPVRPoly;
begin
  if PolyCount >= Length(Polys) then
    SetLength(Polys, Max(1024, Length(Polys) * 2));
  Result := @Polys[PolyCount];
  Result^ := Default(TPVRPoly);
  Inc(PolyCount);
end;

{ TDCTA }

constructor TDCTA.Create(Memory: TDCMemory; Interrupts: TDCInterrupts; PVR: TDCPVR);
begin
  inherited Create;
  FMemory := Memory;
  FInterrupts := Interrupts;
  FPVR := PVR;
  for var I := 0 to High(FContexts) do
    FContexts[I] := TPVRContext.Create;
  Reset;
end;

destructor TDCTA.Destroy;
begin
  for var I := 0 to High(FContexts) do
    FContexts[I].Free;
  inherited;
end;

procedure TDCTA.Reset;
begin
  for var C in FContexts do
  begin
    C.Clear;
    C.Base := $FFFFFFFF;
    C.Used := 0;
  end;
  SoftReset;
end;

procedure TDCTA.SoftReset;
begin
  // Decoded contexts mirror parameter memory, which a reset does not erase:
  // programs reset the accelerator between building a list and rendering it.
  FCurrent := nil;
  FList := -1;
  FListsDone := 0;
  FVertexType := -1;
  FPendingKind := 0;
  FStripOpen := False;
  FYUVCount := 0;
  FYUVBlock := 0;
end;

function TDCTA.ContextFor(Base: Cardinal): TPVRContext;
begin
  Inc(FClock);
  Result := nil;
  for var C in FContexts do
    if C.Base = Base then
      Result := C;
  // The rendered context keeps its contents; the base moves to another.
  if (Result <> nil) and (Result = Rendering) then
  begin
    Result.Base := $FFFFFFFF;
    Result := nil;
  end;
  if Result = nil then
  begin
    for var C in FContexts do
      if (C <> Rendering) and ((Result = nil) or (C.Used < Result.Used)) then
        Result := C;
    Result.Base := Base;
  end;
  Result.Used := FClock;
end;

function TDCTA.Find(Base: Cardinal): TPVRContext;
begin
  Result := nil;
  for var C in FContexts do
    if (C.Base = Base) and (C.Used > 0) then
      Exit(C);
end;

function TDCTA.FindByObjectList(Address: Cardinal): TPVRContext;
begin
  Result := nil;
  for var C in FContexts do
    if (C.Used > 0) and (Address >= C.OLBase) and (Address < C.OLLimit) and
      ((Result = nil) or (C.Used > Result.Used)) then
      Result := C;
end;

procedure TDCTA.WaitIdle(Context: TPVRContext);
begin
  if (Context <> nil) and (Context = Rendering) and Assigned(OnBusy) then
    OnBusy;
end;

procedure TDCTA.ListInit;
begin
  FCurrent := ContextFor(FPVR.R[PVRTAISPBase shr 2] and $7FFFFF);
  WaitIdle(FCurrent);
  FCurrent.Clear;
  FCurrent.OLBase := FPVR.R[PVRTAOLBase shr 2] and $7FFFFF;
  FCurrent.OLLimit := FPVR.R[PVRTAOLLimit shr 2] and $7FFFFF;
  FList := -1;
  FListsDone := 0;
  FVertexType := -1;
  FPendingKind := 0;
  FStripOpen := False;
  FClipMode := 0;
  FPass := 0;
end;

procedure TDCTA.ListContinue;
begin
  // Multipass: further lists append to the current context.
  WaitIdle(FCurrent);
  Inc(FPass);
  FList := -1;
  FListsDone := 0;
  FVertexType := -1;
  FPendingKind := 0;
  FStripOpen := False;
end;

function TDCTA.GlobalSize(PCW: Cardinal): Integer;
begin
  Result := 32;
  if (PCW shr 29) <> 4 then
    Exit;
  if (FList = TAListOpaqueMod) or (FList = TAListTranslucentMod) then
    Exit;
  // Intensity mode 1 with offset, or two-volume intensity: 64 bytes.
  if ((PCW shr 4) and 3) = 2 then
    if ((PCW and $40) <> 0) or (((PCW and 8) <> 0) and ((PCW and 4) <> 0)) then
      Result := 64;
end;

function TDCTA.VertexSize: Integer;
begin
  case FVertexType of
    5, 6, 11, 12, 13, 14, 15, 16, 17:
      Result := 64;
  else
    Result := 32;
  end;
end;

procedure TDCTA.EndList;
begin
  if FList >= 0 then
  begin
    case FList of
      TAListOpaque:
        FInterrupts.RaiseNormal(HollyOpaqueDone);
      TAListOpaqueMod:
        FInterrupts.RaiseNormal(HollyOpaqueModDone);
      TAListTranslucent:
        FInterrupts.RaiseNormal(HollyTransDone);
      TAListTranslucentMod:
        FInterrupts.RaiseNormal(HollyTransModDone);
      TAListPunchThrough:
        FInterrupts.RaiseNormal(HollyPunchThroughDone);
    end;
    FListsDone := FListsDone or (Cardinal(1) shl FList);
    if FCurrent <> nil then
    begin
      var N := Length(FCurrent.ListOrder);
      SetLength(FCurrent.ListOrder, N + 1);
      FCurrent.ListOrder[N] := FList;
    end;
  end;
  FList := -1;
  FVertexType := -1;
  FStripOpen := False;
end;

procedure TDCTA.NewPoly(Kind: Byte);
begin
  var P := FCurrent.AddPoly;
  P.Kind := Kind;
  P.List := FList;
  P.Pass := Byte(FPass);
  P.PCW := FPCW;
  P.ISP := FISP;
  P.TSP := FTSP;
  P.TCW := FTCW;
  P.TSP1 := FTSP1;
  P.TCW1 := FTCW1;
  P.TwoVolume := (FPCW and $40) <> 0;
  P.First := FCurrent.VertexCount;
  P.ClipMode := FClipMode;
  P.ClipX0 := FClip[0];
  P.ClipY0 := FClip[1];
  P.ClipX1 := FClip[2];
  P.ClipY1 := FClip[3];
  FStripPoly := FCurrent.PolyCount - 1;
end;

procedure TDCTA.GlobalParameter(P: PCardinal);
begin
  var PCW := P[0];
  if FList < 0 then
  begin
    FList := (PCW shr 24) and 7;
    if FList > 4 then
      FList := TAListOpaque;
  end;
  FPCW := PCW;
  // The TA takes the texture/offset/Gouraud/16-bit UV flags from the PCW.
  FISP := (P[1] and not Cardinal($03C00000)) or ((PCW and 15) shl 22);
  FTSP := P[2];
  FTCW := P[3];
  FStripOpen := False;
  // User clip mode applies to the following objects.
  FClipMode := (PCW shr 16) and 3;
  var Mod_ := (FList = TAListOpaqueMod) or (FList = TAListTranslucentMod);
  if (PCW shr 29) = 4 then
  begin
    if Mod_ then
    begin
      FVertexType := 17;
      if FModVolumeStart < 0 then
        FModVolumeStart := FCurrent.PolyCount;
      Exit;
    end;
    var Textured := (PCW and 8) <> 0;
    var ColType := (PCW shr 4) and 3;
    var Volume := (PCW and $40) <> 0;
    var UV16Bit := (PCW and 1) <> 0;
    if Volume then
    begin
      FTSP1 := P[4];
      FTCW1 := P[5];
      if not Textured then
      begin
        if ColType = 0 then
          FVertexType := 9
        else
          FVertexType := 10;
      end
      else if ColType = 0 then
      begin
        if UV16Bit then
          FVertexType := 12
        else
          FVertexType := 11;
      end
      else if UV16Bit then
        FVertexType := 14
      else
        FVertexType := 13;
      if ColType = 2 then
      begin
        for var I := 0 to 3 do
        begin
          FFaceColor[I] := AsSingle(P[8 + I]);
          FFaceColor1[I] := AsSingle(P[12 + I]);
        end;
        FillChar(FFaceOffset, SizeOf(FFaceOffset), 0);
        FillChar(FFaceOffset1, SizeOf(FFaceOffset1), 0);
      end;
    end
    else
    begin
      FTSP1 := 0;
      FTCW1 := 0;
      if not Textured then
        case ColType of
          0:
            FVertexType := 0;
          1:
            FVertexType := 1;
        else
          FVertexType := 2;
        end
      else
        case ColType of
          0:
            if UV16Bit then
              FVertexType := 4
            else
              FVertexType := 3;
          1:
            if UV16Bit then
              FVertexType := 6
            else
              FVertexType := 5;
        else
          if UV16Bit then
            FVertexType := 8
          else
            FVertexType := 7;
        end;
      // Intensity mode 1 loads face colors; mode 2 keeps the previous ones.
      if ColType = 2 then
      begin
        if Textured and ((PCW and 4) <> 0) then
          for var I := 0 to 3 do
          begin
            FFaceColor[I] := AsSingle(P[8 + I]);
            FFaceOffset[I] := AsSingle(P[12 + I]);
          end
        else
        begin
          for var I := 0 to 3 do
            FFaceColor[I] := AsSingle(P[4 + I]);
          FillChar(FFaceOffset, SizeOf(FFaceOffset), 0);
        end;
      end;
    end;
  end
  else
  begin
    // Sprite.
    FTSP1 := 0;
    FTCW1 := 0;
    FSpriteBase := P[4];
    FSpriteOffset := P[5];
    if Mod_ then
      FVertexType := 17
    else if (PCW and 8) <> 0 then
      FVertexType := 16
    else
      FVertexType := 15;
  end;
end;

function Intensity(const Face: array of Single; I: Single): Cardinal;
begin
  Result := FloatColor(Face[0], Face[1] * I, Face[2] * I, Face[3] * I);
end;

procedure TDCTA.VertexParameter(P: PCardinal);
begin
  if (FCurrent = nil) or (FVertexType < 0) then
    Exit;
  var PCW := P[0];
  case FVertexType of
    15, 16:
      begin
        NewPoly(PolySprite);
        var Poly: PPVRPoly := @FCurrent.Polys[FStripPoly];
        for var K := 0 to 3 do
        begin
          var V := FCurrent.AddVertex;
          V^ := Default(TPVRVertex);
          if K < 3 then
          begin
            V.X := AsSingle(P[1 + K * 3]);
            V.Y := AsSingle(P[2 + K * 3]);
            V.Z := AsSingle(P[3 + K * 3]);
          end
          else
          begin
            V.X := AsSingle(P[10]);
            V.Y := AsSingle(P[11]);
          end;
          V.Base := FSpriteBase;
          V.Offset := FSpriteOffset;
          if FVertexType = 16 then
            case K of
              0:
                begin
                  V.U := UV16(P[13], True);
                  V.V := UV16(P[13], False);
                end;
              1:
                begin
                  V.U := UV16(P[14], True);
                  V.V := UV16(P[14], False);
                end;
              2:
                begin
                  V.U := UV16(P[15], True);
                  V.V := UV16(P[15], False);
                end;
            end;
        end;
        // D lies on the plane of A, B, C: Z and UV follow D = A + C - B.
        var VA: PPVRVertex := @FCurrent.Vertices[Poly.First];
        var VB: PPVRVertex := @FCurrent.Vertices[Poly.First + 1];
        var VC: PPVRVertex := @FCurrent.Vertices[Poly.First + 2];
        var VD: PPVRVertex := @FCurrent.Vertices[Poly.First + 3];
        VD.Z := VA.Z + VC.Z - VB.Z;
        VD.U := VA.U + VC.U - VB.U;
        VD.V := VA.V + VC.V - VB.V;
        Poly.Count := 4;
        FStripOpen := False;
      end;
    17:
      begin
        NewPoly(PolyModifier);
        var Poly: PPVRPoly := @FCurrent.Polys[FStripPoly];
        for var K := 0 to 2 do
        begin
          var V := FCurrent.AddVertex;
          V^ := Default(TPVRVertex);
          V.X := AsSingle(P[1 + K * 3]);
          V.Y := AsSingle(P[2 + K * 3]);
          V.Z := AsSingle(P[3 + K * 3]);
        end;
        Poly.Count := 3;
        // The global parameter's volume instruction closes a volume.
        var Instruction := (FISP shr 29) and 3;
        if Instruction <> 0 then
          Poly.VolumeEnd := Instruction;
      end;
  else
    begin
      if not FStripOpen then
      begin
        NewPoly(PolyStrip);
        FStripOpen := True;
      end;
      var V := FCurrent.AddVertex;
      V^ := Default(TPVRVertex);
      V.X := AsSingle(P[1]);
      V.Y := AsSingle(P[2]);
      V.Z := AsSingle(P[3]);
      case FVertexType of
        0:
          V.Base := P[6];
        1:
          V.Base := FloatColor(AsSingle(P[4]), AsSingle(P[5]), AsSingle(P[6]), AsSingle(P[7]));
        2:
          V.Base := Intensity(FFaceColor, AsSingle(P[6]));
        3:
          begin
            V.U := AsSingle(P[4]);
            V.V := AsSingle(P[5]);
            V.Base := P[6];
            V.Offset := P[7];
          end;
        4:
          begin
            V.U := UV16(P[4], True);
            V.V := UV16(P[4], False);
            V.Base := P[6];
            V.Offset := P[7];
          end;
        5, 6:
          begin
            if FVertexType = 5 then
            begin
              V.U := AsSingle(P[4]);
              V.V := AsSingle(P[5]);
            end
            else
            begin
              V.U := UV16(P[4], True);
              V.V := UV16(P[4], False);
            end;
            V.Base := FloatColor(AsSingle(P[8]), AsSingle(P[9]), AsSingle(P[10]), AsSingle(P[11]));
            V.Offset := FloatColor(AsSingle(P[12]), AsSingle(P[13]), AsSingle(P[14]), AsSingle(P[15]));
          end;
        7, 8:
          begin
            if FVertexType = 7 then
            begin
              V.U := AsSingle(P[4]);
              V.V := AsSingle(P[5]);
            end
            else
            begin
              V.U := UV16(P[4], True);
              V.V := UV16(P[4], False);
            end;
            V.Base := Intensity(FFaceColor, AsSingle(P[6]));
            V.Offset := Intensity(FFaceOffset, AsSingle(P[7]));
          end;
        9:
          begin
            V.Base := P[4];
            V.Base1 := P[5];
          end;
        10:
          begin
            V.Base := Intensity(FFaceColor, AsSingle(P[4]));
            V.Base1 := Intensity(FFaceColor1, AsSingle(P[5]));
          end;
        11, 12:
          begin
            if FVertexType = 11 then
            begin
              V.U := AsSingle(P[4]);
              V.V := AsSingle(P[5]);
              V.U1 := AsSingle(P[8]);
              V.V1 := AsSingle(P[9]);
            end
            else
            begin
              V.U := UV16(P[4], True);
              V.V := UV16(P[4], False);
              V.U1 := UV16(P[8], True);
              V.V1 := UV16(P[8], False);
            end;
            V.Base := P[6];
            V.Offset := P[7];
            V.Base1 := P[10];
            V.Offset1 := P[11];
          end;
        13, 14:
          begin
            if FVertexType = 13 then
            begin
              V.U := AsSingle(P[4]);
              V.V := AsSingle(P[5]);
              V.U1 := AsSingle(P[8]);
              V.V1 := AsSingle(P[9]);
            end
            else
            begin
              V.U := UV16(P[4], True);
              V.V := UV16(P[4], False);
              V.U1 := UV16(P[8], True);
              V.V1 := UV16(P[8], False);
            end;
            V.Base := Intensity(FFaceColor, AsSingle(P[6]));
            V.Offset := Intensity(FFaceOffset, AsSingle(P[7]));
            V.Base1 := Intensity(FFaceColor1, AsSingle(P[10]));
            V.Offset1 := Intensity(FFaceOffset1, AsSingle(P[11]));
          end;
      end;
      Inc(FCurrent.Polys[FStripPoly].Count);
      if (PCW and $10000000) <> 0 then
        FStripOpen := False;
    end;
  end;
end;

procedure TDCTA.Write32Bytes(Data: PCardinal);
begin
  if FCurrent = nil then
    ListInit;
  WaitIdle(FCurrent);
  if FPendingKind <> 0 then
  begin
    Move(Data^, FPending[8], 32);
    var Kind := FPendingKind;
    FPendingKind := 0;
    if Kind = 1 then
      GlobalParameter(@FPending[0])
    else
      VertexParameter(@FPending[0]);
    Exit;
  end;
  var PCW := Data[0];
  case PCW shr 29 of
    0:
      EndList;
    1:
      begin
        // User tile clip: tile coordinates in words 4..7.
        FClip[0] := Data[4] and $3F;
        FClip[1] := Data[5] and $F;
        FClip[2] := Data[6] and $3F;
        FClip[3] := Data[7] and $F;
      end;
    2:
      ; // Object list set: direct object pointers are not used by the decoded lists.
      4, 5:
      begin
        if FList < 0 then
        begin
          FList := (PCW shr 24) and 7;
          if FList > 4 then
            FList := TAListOpaque;
          FModVolumeStart := -1;
        end;
        if GlobalSize(PCW) = 64 then
        begin
          Move(Data^, FPending[0], 32);
          FPendingKind := 1;
        end
        else
          GlobalParameter(Data);
      end;
    7:
      if VertexSize = 64 then
      begin
        Move(Data^, FPending[0], 32);
        FPendingKind := 2;
      end
      else
        VertexParameter(Data);
  end;
end;

procedure TDCTA.WriteYUV(Data: PCardinal; Count: Integer);
begin
  var Ctrl := FPVR.R[PVRTAYUVTexCtrl shr 2];
  // YUV420 macroblocks are 384 bytes; YUV422 input blocks are 512 bytes.
  var BlockWords := 96;
  if (Ctrl and $1000000) <> 0 then
    BlockWords := 128;
  while Count > 0 do
  begin
    if BlockWords = 96 then
    begin
      FYUVBuffer[FYUVCount] := Data^;
      Inc(FYUVCount);
      if FYUVCount = 96 then
      begin
        FYUVCount := 0;
        YUVMacroblock;
      end;
    end
    else
    begin
      // YUV422 input passes through into the texture, 16x16 blocks.
      var Width := Integer((Ctrl and $3F) + 1) * 16;
      var Pixel := FYUVBlock * 2;
      var X := Pixel mod Width;
      var Y := Pixel div Width;
      var Base := FPVR.R[PVRTAYUVTexBase shr 2] and $7FFFF8;
      FMemory.VRAMWrite64Path(Base + Cardinal(Y * Width + X) * 2, Data^, 4);
      Inc(FYUVBlock);
      var Heights := Integer(((Ctrl shr 8) and $3F) + 1) * 16;
      if FYUVBlock * 2 >= Width * Heights then
      begin
        FYUVBlock := 0;
        FInterrupts.RaiseNormal(HollyYUVDone);
      end;
    end;
    Inc(Data);
    Dec(Count);
  end;
end;

procedure TDCTA.YUVMacroblock;
begin
  // Input: U 8x8, V 8x8, then four 8x8 Y blocks (TL, TR, BL, BR).
  var Ctrl := FPVR.R[PVRTAYUVTexCtrl shr 2];
  var BlocksX := Integer(Ctrl and $3F) + 1;
  var BlocksY := Integer((Ctrl shr 8) and $3F) + 1;
  var Width := BlocksX * 16;
  var Base := FPVR.R[PVRTAYUVTexBase shr 2] and $7FFFF8;
  var BX := FYUVBlock mod BlocksX;
  var BY := FYUVBlock div BlocksX;
  var Bytes := PByte(@FYUVBuffer[0]);
  for var Y := 0 to 15 do
    for var X := 0 to 7 do
    begin
      var CU := Bytes[(Y shr 1) * 8 + X];
      var CV := Bytes[64 + (Y shr 1) * 8 + X];
      var YBlock := ((Y shr 3) * 2) * 64 + 128;
      var X0 := X * 2;
      var Y0 := Bytes[YBlock + (X0 shr 3) * 64 + (Y and 7) * 8 + (X0 and 7)];
      var Y1 := Bytes[YBlock + ((X0 + 1) shr 3) * 64 + (Y and 7) * 8 + ((X0 + 1) and 7)];
      var Word_ := Cardinal(CU) or (Cardinal(Y0) shl 8) or (Cardinal(CV) shl 16) or (Cardinal(Y1) shl 24);
      var PX := BX * 16 + X0;
      var PY := BY * 16 + Y;
      FMemory.VRAMWrite64Path(Base + Cardinal(PY * Width + PX) * 2, Word_, 4);
    end;
  Inc(FYUVBlock);
  if FYUVBlock >= BlocksX * BlocksY then
  begin
    FYUVBlock := 0;
    FInterrupts.RaiseNormal(HollyYUVDone);
  end;
end;

procedure TDCTA.SerializeState(Archive: TStateArchive);
begin
  // Decoded contexts are part of the machine: a render may follow a load.
  for var C in FContexts do
  begin
    Archive.Field(C.Base, SizeOf(C.Base));
    Archive.Field(C.Used, SizeOf(C.Used));
    Archive.Field(C.PolyCount, SizeOf(C.PolyCount));
    Archive.Field(C.VertexCount, SizeOf(C.VertexCount));
    var Lists := Length(C.ListOrder);
    Archive.Field(Lists, SizeOf(Lists));
    if Archive.Loading then
    begin
      if (C.PolyCount < 0) or (C.PolyCount > 4000000) or (C.VertexCount < 0) or (C.VertexCount > 16000000) or
        (Lists < 0) or (Lists > 1000000) then
        raise EReadError.Create('Dreamcast snapshot TA context');
      SetLength(C.Polys, Max(C.PolyCount, 16));
      SetLength(C.Vertices, Max(C.VertexCount, 16));
      SetLength(C.ListOrder, Lists);
    end;
    if C.PolyCount > 0 then
      Archive.Field(C.Polys[0], C.PolyCount * SizeOf(TPVRPoly));
    if C.VertexCount > 0 then
      Archive.Field(C.Vertices[0], C.VertexCount * SizeOf(TPVRVertex));
    if Lists > 0 then
      Archive.Field(C.ListOrder[0], Lists * SizeOf(Integer));
    if Archive.Loading then
      for var I := 0 to C.PolyCount - 1 do
        if (C.Polys[I].First < 0) or (C.Polys[I].Count < 0) or
          (Int64(C.Polys[I].First) + C.Polys[I].Count > C.VertexCount) then
          raise EReadError.Create('Dreamcast snapshot TA polygon');
  end;
  var Current := -1;
  for var I := 0 to High(FContexts) do
    if FContexts[I] = FCurrent then
      Current := I;
  Archive.Field(Current, SizeOf(Current));
  var RenderingIndex := -1;
  for var I := 0 to High(FContexts) do
    if FContexts[I] = Rendering then
      RenderingIndex := I;
  Archive.Field(RenderingIndex, SizeOf(RenderingIndex));
  Archive.Field(FClock, SizeOf(FClock));
  Archive.Field(FStripOpen, SizeOf(FStripOpen));
  Archive.Field(FStripPoly, SizeOf(FStripPoly));
  Archive.Field(FModVolumeStart, SizeOf(FModVolumeStart));
  Archive.Field(FPass, SizeOf(FPass));
  Archive.Field(FList, SizeOf(FList));
  Archive.Field(FListsDone, SizeOf(FListsDone));
  Archive.Field(FPCW, SizeOf(FPCW));
  Archive.Field(FISP, SizeOf(FISP));
  Archive.Field(FTSP, SizeOf(FTSP));
  Archive.Field(FTCW, SizeOf(FTCW));
  Archive.Field(FTSP1, SizeOf(FTSP1));
  Archive.Field(FTCW1, SizeOf(FTCW1));
  Archive.Field(FVertexType, SizeOf(FVertexType));
  Archive.Field(FPending, SizeOf(FPending));
  Archive.Field(FPendingKind, SizeOf(FPendingKind));
  Archive.Field(FFaceColor, SizeOf(FFaceColor));
  Archive.Field(FFaceOffset, SizeOf(FFaceOffset));
  Archive.Field(FFaceColor1, SizeOf(FFaceColor1));
  Archive.Field(FFaceOffset1, SizeOf(FFaceOffset1));
  Archive.Field(FSpriteBase, SizeOf(FSpriteBase));
  Archive.Field(FSpriteOffset, SizeOf(FSpriteOffset));
  Archive.Field(FClipMode, SizeOf(FClipMode));
  Archive.Field(FClip, SizeOf(FClip));
  Archive.Field(FYUVBuffer, SizeOf(FYUVBuffer));
  Archive.Field(FYUVCount, SizeOf(FYUVCount));
  Archive.Field(FYUVBlock, SizeOf(FYUVBlock));
  if Archive.Loading then
  begin
    if (FList < -1) or (FList > 4) or (FVertexType < -1) or (FVertexType > 17) or
      (FPendingKind < 0) or (FPendingKind > 2) or (FYUVCount < 0) or (FYUVCount > 95) or (FYUVBlock < 0) then
      raise EReadError.Create('Dreamcast snapshot TA state');
    if (Current < -1) or (Current > High(FContexts)) then
      raise EReadError.Create('Dreamcast snapshot TA context');
    if (RenderingIndex < -1) or (RenderingIndex > High(FContexts)) then
      raise EReadError.Create('Dreamcast snapshot TA context');
    FCurrent := nil;
    if Current >= 0 then
      FCurrent := FContexts[Current];
    Rendering := nil;
    if RenderingIndex >= 0 then
      Rendering := FContexts[RenderingIndex];
    if FStripOpen and ((FCurrent = nil) or (FStripPoly < 0) or (FStripPoly >= FCurrent.PolyCount)) then
      raise EReadError.Create('Dreamcast snapshot TA strip');
  end;
end;

end.

