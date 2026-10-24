unit PS2.GS.Raster;

// GS drawing: the general registers, vertex queue and primitive assembly
// (points, lines, strips, triangles, fans, sprites), the pixel pipeline
// (texture with CLUT and filtering, fog, alpha/destination-alpha/depth tests,
// blending, FBA, masks, colour clamp) and host/local transfers.
// Triangles use edge functions over the scissored bounding box with plane
// equations for the attributes; sprites step their UV linearly.
// References: GS User's Manual (PS2 Linux Kit), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.GS.Memory;

const
  GSRegPRIM = $00;
  GSRegRGBAQ = $01;
  GSRegST = $02;
  GSRegUV = $03;
  GSRegXYZF2 = $04;
  GSRegXYZ2 = $05;
  GSRegTEX0_1 = $06;
  GSRegTEX0_2 = $07;
  GSRegCLAMP_1 = $08;
  GSRegCLAMP_2 = $09;
  GSRegFOG = $0A;
  GSRegXYZF3 = $0C;
  GSRegXYZ3 = $0D;
  GSRegTEX1_1 = $14;
  GSRegTEX1_2 = $15;
  GSRegTEX2_1 = $16;
  GSRegTEX2_2 = $17;
  GSRegXYOFFSET_1 = $18;
  GSRegXYOFFSET_2 = $19;
  GSRegPRMODECONT = $1A;
  GSRegPRMODE = $1B;
  GSRegTEXCLUT = $1C;
  GSRegSCANMSK = $22;
  GSRegTEXA = $3B;
  GSRegFOGCOL = $3D;
  GSRegTEXFLUSH = $3F;
  GSRegSCISSOR_1 = $40;
  GSRegSCISSOR_2 = $41;
  GSRegALPHA_1 = $42;
  GSRegALPHA_2 = $43;
  GSRegDIMX = $44;
  GSRegDTHE = $45;
  GSRegCOLCLAMP = $46;
  GSRegTEST_1 = $47;
  GSRegTEST_2 = $48;
  GSRegPABE = $49;
  GSRegFBA_1 = $4A;
  GSRegFBA_2 = $4B;
  GSRegFRAME_1 = $4C;
  GSRegFRAME_2 = $4D;
  GSRegZBUF_1 = $4E;
  GSRegZBUF_2 = $4F;
  GSRegBITBLTBUF = $50;
  GSRegTRXPOS = $51;
  GSRegTRXREG = $52;
  GSRegTRXDIR = $53;
  GSRegHWREG = $54;
  GSRegSIGNAL = $60;
  GSRegFINISH = $61;
  GSRegLABEL = $62;

type
  TPS2GSVertex = record
    X, Y: Integer;       // 12.4 fixed, offset applied
    Z: Cardinal;
    F: Integer;
    R, G, B, A: Integer;
    S, T, Q: Single;
    U, V: Integer;       // 10.4 fixed
  end;

  // Everything one primitive needs, resolved from the registers.
  TPS2GSDraw = record
    Ctx: Integer;
    IIP, TME, FGE, ABE, FST: Boolean;
    FBP, FBW, FPSM: Cardinal;
    FBMSK: Cardinal;
    ZBP, ZPSM: Cardinal;
    ZMSK: Boolean;
    SX0, SX1, SY0, SY1: Integer;
    ATE: Boolean;
    ATST, AREF, AFAIL: Integer;
    DATE, DATM: Boolean;
    ZTE: Boolean;
    ZTST: Integer;
    BlendA, BlendB, BlendC, BlendD, BlendFix: Integer;
    PABE, FBA, ColClamp: Boolean;
    TBP, TBW, TPSM, TW, TH: Cardinal;
    TCC: Boolean;
    TFX: Integer;
    WMS, WMT: Integer;
    MINU, MAXU, MINV, MAXV: Integer;
    Linear: Boolean;
    TA0, TA1: Integer;
    AEM: Boolean;
    FogR, FogG, FogB: Integer;
  end;

  TPS2GSRaster = class
  private
    FMemory: TPS2GSMemory;
    FOnSignal: TProc;
    FSignal, FFinish: Boolean;
    FQueue: array[0..2] of TPS2GSVertex;
    FQueueCount: Integer;
    FStripIndex: Integer;
    FCurrent: TPS2GSVertex;
    FQ: Single;
    FClut: array[0..511] of Word;
    FCBP0, FCBP1: Cardinal;
    FD: TPS2GSDraw;
    // Host-to-local transfer.
    FXferActive: Boolean;
    FXferX, FXferY: Integer;
    FXferBits: UInt64;
    FXferBitCount: Integer;
    FReadBuffer: TArray<Cardinal>;
    FReadPos: Integer;
    FPrimitives, FPixels, FXferPixels: Int64;
    procedure Kick(DrawingKick: Boolean);
    procedure SetupDraw;
    procedure DrawPoint(const V: TPS2GSVertex);
    procedure DrawLine(const V0, V1: TPS2GSVertex);
    procedure DrawTriangle(const V0, V1, V2: TPS2GSVertex);
    procedure DrawSprite(const V0, V1: TPS2GSVertex);
    procedure Pixel(X, Y: Integer; Z: Cardinal; R, G, B, A, F: Integer; U, V: Integer);
    function Texel(U, V: Integer): Cardinal;
    function TexelAt(TU, TV: Integer): Cardinal;
    function ClampCoord(C, Size, Mode, MinC, MaxC: Integer): Integer; inline;
    procedure LoadClut(Tex0: UInt64);
    procedure StartTransfer;
    procedure FeedWord(W: Cardinal);
    procedure TransferPixel(Value: Cardinal);
    procedure LocalToLocal;
    procedure LocalToHost;
  public
    Regs: array[0..$7F] of UInt64;
    SigLblId: UInt64;
    // Diagnostics: transfers started (BITBLTBUF, TRXPOS, TRXREG, TRXDIR) when assigned.
    TransferLog: TStrings;
    PrimLog: TStrings;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure WriteRegister(Index: Integer; Value: UInt64);
    procedure WriteImage(const Data: TPS2Reg128);
    function ReadImage(out Data: TPS2Reg128): Boolean;
    procedure ClearSignal;
    procedure ClearFinish;
    procedure SerializeState(State: TStateArchive);
    property Memory: TPS2GSMemory read FMemory;
    property SignalPending: Boolean read FSignal;
    property FinishPending: Boolean read FFinish;
    property OnSignal: TProc read FOnSignal write FOnSignal;
    property Primitives: Int64 read FPrimitives;
    property PixelsDrawn: Int64 read FPixels;
    property PixelsTransferred: Int64 read FXferPixels;
  end;

implementation

// A texel coordinate in 1/16 texels, clamped (degenerate S/T/Q give huge or NaN values).
function TexCoord(D: Double): Integer;
begin
  if not (D > -$1000000) then
    Exit(-$1000000);
  if D > $1000000 then
    Exit($1000000);
  Result := Trunc(D);
end;

constructor TPS2GSRaster.Create;
begin
  inherited Create;
  FMemory := TPS2GSMemory.Create;
  Reset;
end;

destructor TPS2GSRaster.Destroy;
begin
  FMemory.Free;
  inherited;
end;

procedure TPS2GSRaster.Reset;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  FSignal := False;
  FFinish := False;
  SigLblId := 0;
  FQueueCount := 0;
  FStripIndex := 0;
  FCurrent := Default(TPS2GSVertex);
  FQ := 1;
  FillChar(FClut, SizeOf(FClut), 0);
  FCBP0 := 0;
  FCBP1 := 0;
  FXferActive := False;
  FXferBits := 0;
  FXferBitCount := 0;
  FReadBuffer := nil;
  FReadPos := 0;
  Regs[GSRegPRMODECONT] := 1;
  FMemory.Clear;
end;

procedure TPS2GSRaster.ClearSignal;
begin
  FSignal := False;
end;

procedure TPS2GSRaster.ClearFinish;
begin
  FFinish := False;
end;

function SingleOf(V: Cardinal): Single; inline;
begin
  Result := PSingle(@V)^;
end;

procedure TPS2GSRaster.WriteRegister(Index: Integer; Value: UInt64);
begin
  Index := Index and $7F;
  if (PrimLog <> nil) and (PrimLog.Count < 200000) and (Index in [6, 7, $14, $15, $16, $17, $3B, $4C, $4D]) then
    PrimLog.Add(Format('reg %.2x = %.16x', [Index, Value]));
  Regs[Index] := Value;
  case Index of
    GSRegPRIM:
      begin
        FQueueCount := 0;
        FStripIndex := 0;
      end;
    GSRegRGBAQ:
      begin
        FCurrent.R := Integer(Value and $FF);
        FCurrent.G := Integer((Value shr 8) and $FF);
        FCurrent.B := Integer((Value shr 16) and $FF);
        FCurrent.A := Integer((Value shr 24) and $FF);
        FCurrent.Q := SingleOf(Cardinal(Value shr 32));
      end;
    GSRegST:
      begin
        FCurrent.S := SingleOf(Cardinal(Value));
        FCurrent.T := SingleOf(Cardinal(Value shr 32));
      end;
    GSRegUV:
      begin
        FCurrent.U := Integer(Value and $3FFF);
        FCurrent.V := Integer((Value shr 16) and $3FFF);
      end;
    GSRegFOG:
      FCurrent.F := Integer((Value shr 56) and $FF);
    GSRegXYZF2, GSRegXYZF3:
      begin
        FCurrent.X := Integer(Value and $FFFF);
        FCurrent.Y := Integer((Value shr 16) and $FFFF);
        FCurrent.Z := Cardinal((Value shr 32) and $FFFFFF);
        FCurrent.F := Integer((Value shr 56) and $FF);
        Kick(Index = GSRegXYZF2);
      end;
    GSRegXYZ2, GSRegXYZ3:
      begin
        FCurrent.X := Integer(Value and $FFFF);
        FCurrent.Y := Integer((Value shr 16) and $FFFF);
        FCurrent.Z := Cardinal(Value shr 32);
        Kick(Index = GSRegXYZ2);
      end;
    GSRegTEX0_1, GSRegTEX0_2:
      LoadClut(Value);
    GSRegTEX2_1, GSRegTEX2_2:
      begin
        // TEX2 replaces the CLUT/format fields of TEX0.
        var T := GSRegTEX0_1 + (Index - GSRegTEX2_1);
        var Mask: UInt64 := (UInt64($3F) shl 20) or (UInt64($FFFFFFF) shl 37);
        Regs[T] := (Regs[T] and not Mask) or (Value and Mask);
        LoadClut(Regs[T]);
      end;
    GSRegTRXDIR:
      StartTransfer;
    GSRegHWREG:
      begin
        FeedWord(Cardinal(Value));
        FeedWord(Cardinal(Value shr 32));
      end;
    GSRegSIGNAL:
      begin
        var Mask := Value shr 32;
        SigLblId := (SigLblId and not Mask) or (Value and Mask and $FFFFFFFF);
        FSignal := True;
        if Assigned(FOnSignal) then
          FOnSignal();
      end;
    GSRegFINISH:
      begin
        FFinish := True;
        if Assigned(FOnSignal) then
          FOnSignal();
      end;
    GSRegLABEL:
      begin
        var Mask := (Value shr 32) shl 32;
        SigLblId := (SigLblId and not Mask) or ((Value shl 32) and Mask);
      end;
  end;
end;

{ Primitives }

procedure TPS2GSRaster.SetupDraw;
begin
  var Attr := Regs[GSRegPRIM];
  if (Regs[GSRegPRMODECONT] and 1) = 0 then
    Attr := (Attr and 7) or (Regs[GSRegPRMODE] and not UInt64(7));
  var D := Default(TPS2GSDraw);
  D.IIP := (Attr and $8) <> 0;
  D.TME := (Attr and $10) <> 0;
  D.FGE := (Attr and $20) <> 0;
  D.ABE := (Attr and $40) <> 0;
  D.FST := (Attr and $100) <> 0;
  D.Ctx := Integer((Attr shr 9) and 1);
  var C := D.Ctx;
  var Frame := Regs[GSRegFRAME_1 + C];
  D.FBP := Cardinal(Frame and $1FF) * 32;
  D.FBW := Cardinal((Frame shr 16) and $3F);
  D.FPSM := Cardinal((Frame shr 24) and $3F);
  D.FBMSK := Cardinal(Frame shr 32);
  var ZBuf := Regs[GSRegZBUF_1 + C];
  D.ZBP := Cardinal(ZBuf and $1FF) * 32;
  D.ZPSM := Cardinal((ZBuf shr 24) and $F) or $30;
  D.ZMSK := (ZBuf and (UInt64(1) shl 32)) <> 0;
  var Sc := Regs[GSRegSCISSOR_1 + C];
  D.SX0 := Integer(Sc and $7FF);
  D.SX1 := Integer((Sc shr 16) and $7FF);
  D.SY0 := Integer((Sc shr 32) and $7FF);
  D.SY1 := Integer((Sc shr 48) and $7FF);
  var Test := Regs[GSRegTEST_1 + C];
  D.ATE := (Test and 1) <> 0;
  D.ATST := Integer((Test shr 1) and 7);
  D.AREF := Integer((Test shr 4) and $FF);
  D.AFAIL := Integer((Test shr 12) and 3);
  D.DATE := (Test and $4000) <> 0;
  D.DATM := (Test and $8000) <> 0;
  D.ZTE := (Test and $10000) <> 0;
  D.ZTST := Integer((Test shr 17) and 3);
  if not D.ZTE then
    D.ZTST := 1;
  var Alpha := Regs[GSRegALPHA_1 + C];
  D.BlendA := Integer(Alpha and 3);
  D.BlendB := Integer((Alpha shr 2) and 3);
  D.BlendC := Integer((Alpha shr 4) and 3);
  D.BlendD := Integer((Alpha shr 6) and 3);
  D.BlendFix := Integer((Alpha shr 32) and $FF);
  D.PABE := (Regs[GSRegPABE] and 1) <> 0;
  D.FBA := (Regs[GSRegFBA_1 + C] and 1) <> 0;
  D.ColClamp := (Regs[GSRegCOLCLAMP] and 1) <> 0;
  var Tex0 := Regs[GSRegTEX0_1 + C];
  D.TBP := Cardinal(Tex0 and $3FFF);
  D.TBW := Cardinal((Tex0 shr 14) and $3F);
  D.TPSM := Cardinal((Tex0 shr 20) and $3F);
  D.TW := Cardinal((Tex0 shr 26) and $F);
  D.TH := Cardinal((Tex0 shr 30) and $F);
  if D.TW > 10 then
    D.TW := 10;
  if D.TH > 10 then
    D.TH := 10;
  D.TCC := (Tex0 and (UInt64(1) shl 34)) <> 0;
  D.TFX := Integer((Tex0 shr 35) and 3);
  var Clamp := Regs[GSRegCLAMP_1 + C];
  D.WMS := Integer(Clamp and 3);
  D.WMT := Integer((Clamp shr 2) and 3);
  D.MINU := Integer((Clamp shr 4) and $3FF);
  D.MAXU := Integer((Clamp shr 14) and $3FF);
  D.MINV := Integer((Clamp shr 24) and $3FF);
  D.MAXV := Integer((Clamp shr 34) and $3FF);
  var Tex1 := Regs[GSRegTEX1_1 + C];
  D.Linear := (Tex1 and $20) <> 0;
  var TexA := Regs[GSRegTEXA];
  D.TA0 := Integer(TexA and $FF);
  D.AEM := (TexA and $8000) <> 0;
  D.TA1 := Integer((TexA shr 32) and $FF);
  var FogCol := Regs[GSRegFOGCOL];
  D.FogR := Integer(FogCol and $FF);
  D.FogG := Integer((FogCol shr 8) and $FF);
  D.FogB := Integer((FogCol shr 16) and $FF);
  FD := D;
end;

procedure TPS2GSRaster.Kick(DrawingKick: Boolean);
begin
  var Attr := Regs[GSRegPRIM];
  if (Regs[GSRegPRMODECONT] and 1) = 0 then
    Attr := (Attr and 7) or (Regs[GSRegPRMODE] and not UInt64(7));
  var C := Integer((Attr shr 9) and 1);
  var Off := Regs[GSRegXYOFFSET_1 + C];
  var V := FCurrent;
  V.X := FCurrent.X - Integer(Off and $FFFF);
  V.Y := FCurrent.Y - Integer((Off shr 32) and $FFFF);
  var Prim := Integer(Regs[GSRegPRIM] and 7);
  case Prim of
    0:
      begin
        if DrawingKick then
        begin
          SetupDraw;
          DrawPoint(V);
        end;
      end;
    1, 6:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 2 then
        begin
          FQueueCount := 0;
          if DrawingKick then
          begin
            SetupDraw;
            if Prim = 1 then
              DrawLine(FQueue[0], FQueue[1])
            else
              DrawSprite(FQueue[0], FQueue[1]);
          end;
        end;
      end;
    2:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 2 then
        begin
          if DrawingKick then
          begin
            SetupDraw;
            DrawLine(FQueue[0], FQueue[1]);
          end;
          FQueue[0] := FQueue[1];
          FQueueCount := 1;
        end;
      end;
    3:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 3 then
        begin
          FQueueCount := 0;
          if DrawingKick then
          begin
            SetupDraw;
            DrawTriangle(FQueue[0], FQueue[1], FQueue[2]);
          end;
        end;
      end;
    4:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 3 then
        begin
          if DrawingKick then
          begin
            SetupDraw;
            DrawTriangle(FQueue[0], FQueue[1], FQueue[2]);
          end;
          FQueue[0] := FQueue[1];
          FQueue[1] := FQueue[2];
          FQueueCount := 2;
        end;
      end;
    5:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 3 then
        begin
          if DrawingKick then
          begin
            SetupDraw;
            DrawTriangle(FQueue[0], FQueue[1], FQueue[2]);
          end;
          FQueue[1] := FQueue[2];
          FQueueCount := 2;
        end;
      end;
  end;
end;

function TPS2GSRaster.ClampCoord(C, Size, Mode, MinC, MaxC: Integer): Integer;
begin
  case Mode of
    0: Result := C and (Size - 1);
    1:
      if C < 0 then
        Result := 0
      else if C >= Size then
        Result := Size - 1
      else
        Result := C;
    2:
      if C < MinC then
        Result := MinC
      else if C > MaxC then
        Result := MaxC
      else
        Result := C;
  else
    Result := (C and MinC) or MaxC;
  end;
end;

function ExpandTexA(V: Cardinal; TA0, TA1: Integer; AEM: Boolean): Cardinal; inline;
begin
  // 16-bit RGBA5551 to 32-bit with TEXA alpha.
  Result := ((V and $1F) shl 3) or (((V shr 5) and $1F) shl 11) or (((V shr 10) and $1F) shl 19);
  var A: Integer;
  if (V and $8000) <> 0 then
    A := TA1
  else if AEM and ((V and $7FFF) = 0) then
    A := 0
  else
    A := TA0;
  Result := Result or (Cardinal(A) shl 24);
end;

function TPS2GSRaster.TexelAt(TU, TV: Integer): Cardinal;
begin
  var Raw := FMemory.ReadRaw(Integer(FD.TPSM), FD.TBP, FD.TBW, Cardinal(TU), Cardinal(TV));
  case FD.TPSM of
    PSMCT32, PSMZ32:
      Result := Raw;
    PSMCT24, PSMZ24:
      begin
        var A := FD.TA0;
        if FD.AEM and ((Raw and $FFFFFF) = 0) then
          A := 0;
        Result := (Raw and $FFFFFF) or (Cardinal(A) shl 24);
      end;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      Result := ExpandTexA(Raw, FD.TA0, FD.TA1, FD.AEM);
  else
    begin
      // Palettized: CLUT entry.
      var Tex0 := Regs[GSRegTEX0_1 + FD.Ctx];
      var CPSM := Integer((Tex0 shr 51) and $F);
      var CSA := Integer((Tex0 shr 56) and $1F);
      var Index := Integer(Raw);
      if (FD.TPSM = PSMT4) or (FD.TPSM = PSMT4HL) or (FD.TPSM = PSMT4HH) then
        Index := Index + CSA * 16;
      if CPSM = PSMCT32 then
      begin
        Index := Index and 255;
        Result := Cardinal(FClut[Index]) or (Cardinal(FClut[Index + 256]) shl 16);
      end
      else
        Result := ExpandTexA(FClut[Index and 511], FD.TA0, FD.TA1, FD.AEM);
    end;
  end;
end;

function TPS2GSRaster.Texel(U, V: Integer): Cardinal;
begin
  var W := 1 shl FD.TW;
  var H := 1 shl FD.TH;
  if not FD.Linear then
  begin
    var TU := ClampCoord(U shr 4, W, FD.WMS, FD.MINU, FD.MAXU);
    var TV := ClampCoord(V shr 4, H, FD.WMT, FD.MINV, FD.MAXV);
    Exit(TexelAt(TU, TV));
  end;
  var U0 := (U - 8) shr 4;
  var V0 := (V - 8) shr 4;
  var FU := (U - 8) and 15;
  var FV := (V - 8) and 15;
  var A := TexelAt(ClampCoord(U0, W, FD.WMS, FD.MINU, FD.MAXU), ClampCoord(V0, H, FD.WMT, FD.MINV, FD.MAXV));
  var B := TexelAt(ClampCoord(U0 + 1, W, FD.WMS, FD.MINU, FD.MAXU), ClampCoord(V0, H, FD.WMT, FD.MINV, FD.MAXV));
  var C := TexelAt(ClampCoord(U0, W, FD.WMS, FD.MINU, FD.MAXU), ClampCoord(V0 + 1, H, FD.WMT, FD.MINV, FD.MAXV));
  var D := TexelAt(ClampCoord(U0 + 1, W, FD.WMS, FD.MINU, FD.MAXU), ClampCoord(V0 + 1, H, FD.WMT, FD.MINV, FD.MAXV));
  Result := 0;
  for var Shift := 0 to 3 do
  begin
    var S := Shift * 8;
    var Top := Integer((A shr S) and $FF) * (16 - FU) + Integer((B shr S) and $FF) * FU;
    var Bottom := Integer((C shr S) and $FF) * (16 - FU) + Integer((D shr S) and $FF) * FU;
    var Value := (Top * (16 - FV) + Bottom * FV) shr 8;
    Result := Result or (Cardinal(Value and $FF) shl S);
  end;
end;

procedure TPS2GSRaster.Pixel(X, Y: Integer; Z: Cardinal; R, G, B, A, F: Integer; U, V: Integer);
var
  Mask: Cardinal;
begin
  if (X < FD.SX0) or (X > FD.SX1) or (Y < FD.SY0) or (Y > FD.SY1) then
    Exit;
  Inc(FPixels);
  if FD.TME then
  begin
    var T := Texel(U, V);
    var TR := Integer(T and $FF);
    var TG := Integer((T shr 8) and $FF);
    var TB := Integer((T shr 16) and $FF);
    var TA := Integer(T shr 24);
    case FD.TFX of
      0:
        begin
          R := (R * TR) shr 7;
          G := (G * TG) shr 7;
          B := (B * TB) shr 7;
          if FD.TCC then
            A := (A * TA) shr 7;
        end;
      1:
        begin
          R := TR;
          G := TG;
          B := TB;
          if FD.TCC then
            A := TA;
        end;
      2, 3:
        begin
          R := ((R * TR) shr 7) + A;
          G := ((G * TG) shr 7) + A;
          B := ((B * TB) shr 7) + A;
          if FD.TCC then
          begin
            if FD.TFX = 2 then
              A := TA + A
            else
              A := TA;
          end;
        end;
    end;
    if R > 255 then R := 255;
    if G > 255 then G := 255;
    if B > 255 then B := 255;
    if A > 255 then A := 255;
  end;
  if FD.FGE then
  begin
    R := (F * R + (255 - F) * FD.FogR) shr 8;
    G := (F * G + (255 - F) * FD.FogG) shr 8;
    B := (F * B + (255 - F) * FD.FogB) shr 8;
  end;
  var WriteFB := True;
  var WriteZ := not FD.ZMSK;
  var WriteAlpha := True;
  if FD.ATE then
  begin
    var Pass: Boolean;
    case FD.ATST of
      0: Pass := False;
      1: Pass := True;
      2: Pass := A < FD.AREF;
      3: Pass := A <= FD.AREF;
      4: Pass := A = FD.AREF;
      5: Pass := A >= FD.AREF;
      6: Pass := A > FD.AREF;
    else
      Pass := A <> FD.AREF;
    end;
    if not Pass then
      case FD.AFAIL of
        0: Exit;
        1: WriteZ := False;
        2: WriteFB := False;
      else
        begin
          WriteZ := False;
          WriteAlpha := False;
        end;
      end;
  end;
  // Depth.
  var ZMax: Cardinal := $FFFFFFFF;
  case FD.ZPSM of
    PSMZ24: ZMax := $FFFFFF;
    PSMZ16, PSMZ16S: ZMax := $FFFF;
  end;
  if Z > ZMax then
    Z := ZMax;
  if FD.ZTST <> 1 then
  begin
    if FD.ZTST = 0 then
      Exit;
    var Old := FMemory.ReadRaw(Integer(FD.ZPSM), FD.ZBP, FD.FBW, Cardinal(X), Cardinal(Y));
    if (FD.ZTST = 2) and (Z < Old) then
      Exit;
    if (FD.ZTST = 3) and (Z <= Old) then
      Exit;
  end;
  // Destination colour.
  var Dst: Cardinal := 0;
  var Is16 := (FD.FPSM = PSMCT16) or (FD.FPSM = PSMCT16S) or (FD.FPSM = PSMZ16) or (FD.FPSM = PSMZ16S);
  var NeedDst := FD.DATE or (FD.ABE and ((FD.BlendA = 1) or (FD.BlendB = 1) or (FD.BlendC = 1) or (FD.BlendD = 1))) or
    (FD.FBMSK <> 0) or not WriteAlpha;
  if NeedDst then
  begin
    var Raw := FMemory.ReadRaw(Integer(FD.FPSM), FD.FBP, FD.FBW, Cardinal(X), Cardinal(Y));
    if Is16 then
      Dst := ((Raw and $1F) shl 3) or (((Raw shr 5) and $1F) shl 11) or (((Raw shr 10) and $1F) shl 19) or
        (((Raw shr 15) and 1) shl 31)
    else if (FD.FPSM = PSMCT24) or (FD.FPSM = PSMZ24) then
      Dst := (Raw and $FFFFFF) or $80000000
    else
      Dst := Raw;
  end;
  if FD.DATE then
  begin
    var Bit := (Dst shr 31) <> 0;
    if Bit <> FD.DATM then
      Exit;
  end;
  if FD.ABE and (not FD.PABE or (A >= 128)) then
  begin
    var DR := Integer(Dst and $FF);
    var DG := Integer((Dst shr 8) and $FF);
    var DB := Integer((Dst shr 16) and $FF);
    var DA := Integer(Dst shr 24);
    var CA, CB, CD: array[0..2] of Integer;
    case FD.BlendA of
      0: begin CA[0] := R; CA[1] := G; CA[2] := B; end;
      1: begin CA[0] := DR; CA[1] := DG; CA[2] := DB; end;
    else
      begin CA[0] := 0; CA[1] := 0; CA[2] := 0; end;
    end;
    case FD.BlendB of
      0: begin CB[0] := R; CB[1] := G; CB[2] := B; end;
      1: begin CB[0] := DR; CB[1] := DG; CB[2] := DB; end;
    else
      begin CB[0] := 0; CB[1] := 0; CB[2] := 0; end;
    end;
    case FD.BlendD of
      0: begin CD[0] := R; CD[1] := G; CD[2] := B; end;
      1: begin CD[0] := DR; CD[1] := DG; CD[2] := DB; end;
    else
      begin CD[0] := 0; CD[1] := 0; CD[2] := 0; end;
    end;
    var CC: Integer;
    case FD.BlendC of
      0: CC := A;
      1: CC := DA;
    else
      CC := FD.BlendFix;
    end;
    R := (((CA[0] - CB[0]) * CC) shr 7) + CD[0];
    G := (((CA[1] - CB[1]) * CC) shr 7) + CD[1];
    B := (((CA[2] - CB[2]) * CC) shr 7) + CD[2];
  end;
  if FD.ColClamp then
  begin
    R := EnsureRange(R, 0, 255);
    G := EnsureRange(G, 0, 255);
    B := EnsureRange(B, 0, 255);
  end
  else
  begin
    R := R and $FF;
    G := G and $FF;
    B := B and $FF;
  end;
  if FD.FBA then
    A := A or $80;
  if WriteFB then
  begin
    var Color := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16) or (Cardinal(A and $FF) shl 24);
    Mask := FD.FBMSK;
    if not WriteAlpha then
      Mask := Mask or $FF000000;
    if Mask <> 0 then
      Color := (Color and not Mask) or (Dst and Mask);
    if Is16 then
      FMemory.WriteRaw(Integer(FD.FPSM), FD.FBP, FD.FBW, Cardinal(X), Cardinal(Y), Color32To16(Color))
    else
      FMemory.WriteRaw(Integer(FD.FPSM), FD.FBP, FD.FBW, Cardinal(X), Cardinal(Y), Color);
  end;
  if WriteZ and WriteFB or (WriteZ and (FD.AFAIL = 2)) then
    FMemory.WriteRaw(Integer(FD.ZPSM), FD.ZBP, FD.FBW, Cardinal(X), Cardinal(Y), Z);
end;

procedure TPS2GSRaster.DrawPoint(const V: TPS2GSVertex);
begin
  Inc(FPrimitives);
  var U := V.U;
  var TV := V.V;
  if FD.TME and not FD.FST then
  begin
    var Q := V.Q;
    if Q = 0 then
      Q := 1;
    U := TexCoord(V.S / Q * (1 shl FD.TW) * 16);
    TV := TexCoord(V.T / Q * (1 shl FD.TH) * 16);
  end;
  Pixel((V.X + 8) shr 4, (V.Y + 8) shr 4, V.Z, V.R, V.G, V.B, V.A, V.F, U, TV);
end;

procedure TPS2GSRaster.DrawLine(const V0, V1: TPS2GSVertex);
begin
  Inc(FPrimitives);
  var DX := V1.X - V0.X;
  var DY := V1.Y - V0.Y;
  var Steps := Max(Abs(DX), Abs(DY)) shr 4;
  // Lines longer than the 2048x2048 drawing space come from garbage vertices.
  if Steps > 4096 then
    Exit;
  if Steps = 0 then
    Steps := 1;
  for var K := 0 to Steps do
  begin
    var T := K / Steps;
    var X := Integer(EnsureRange((Int64(V0.X) + Round(DX * T) + 8) div 16, -1, 4096));
    var Y := Integer(EnsureRange((Int64(V0.Y) + Round(DY * T) + 8) div 16, -1, 4096));
    var R := V1.R;
    var G := V1.G;
    var B := V1.B;
    var A := V1.A;
    if FD.IIP then
    begin
      R := V0.R + Round((V1.R - V0.R) * T);
      G := V0.G + Round((V1.G - V0.G) * T);
      B := V0.B + Round((V1.B - V0.B) * T);
      A := V0.A + Round((V1.A - V0.A) * T);
    end;
    var Z := Cardinal(EnsureRange(Round(V0.Z + (Double(V1.Z) - V0.Z) * T), 0, Int64($FFFFFFFF)));
    var F := V0.F + Round((V1.F - V0.F) * T);
    var U := V0.U + Round((V1.U - V0.U) * T);
    var TV := V0.V + Round((V1.V - V0.V) * T);
    if FD.TME and not FD.FST then
    begin
      var S := V0.S + (V1.S - V0.S) * T;
      var TT := V0.T + (V1.T - V0.T) * T;
      var Q := V0.Q + (V1.Q - V0.Q) * T;
      if Q = 0 then
        Q := 1;
      U := TexCoord(S / Q * (1 shl FD.TW) * 16);
      TV := TexCoord(TT / Q * (1 shl FD.TH) * 16);
    end;
    Pixel(X, Y, Z, EnsureRange(R, 0, 255), EnsureRange(G, 0, 255), EnsureRange(B, 0, 255), EnsureRange(A, 0, 255),
      EnsureRange(F, 0, 255), U, TV);
  end;
end;

procedure TPS2GSRaster.DrawSprite(const V0, V1: TPS2GSVertex);
begin
  Inc(FPrimitives);
  if (PrimLog <> nil) and (PrimLog.Count < 200000) then
    PrimLog.Add(Format('sprite %d,%d-%d,%d uv=%d,%d-%d,%d st=%g,%g q=%g rgba=%d,%d,%d,%d tme=%s fst=%s abe=%s fbp=%x fbw=%d fpsm=%x msk=%x tbp=%x tbw=%d tpsm=%x tw=%d th=%d tcc=%s tfx=%d ate=%s atst=%d aref=%d afail=%d zte=%s ztst=%d blend=%d%d%d%d fix=%d',
      [V0.X div 16, V0.Y div 16, V1.X div 16, V1.Y div 16, V0.U div 16, V0.V div 16, V1.U div 16, V1.V div 16, V0.S, V0.T, V0.Q,
      V1.R, V1.G, V1.B, V1.A, BoolToStr(FD.TME, True), BoolToStr(FD.FST, True), BoolToStr(FD.ABE, True), FD.FBP, FD.FBW, FD.FPSM,
      FD.FBMSK, FD.TBP, FD.TBW, FD.TPSM, FD.TW, FD.TH, BoolToStr(FD.TCC, True), FD.TFX, BoolToStr(FD.ATE, True), FD.ATST, FD.AREF,
      FD.AFAIL, BoolToStr(FD.ZTE, True), FD.ZTST, FD.BlendA, FD.BlendB, FD.BlendC, FD.BlendD, FD.BlendFix]));
  var X0 := V0.X;
  var X1 := V1.X;
  var Y0 := V0.Y;
  var Y1 := V1.Y;
  var PX0 := (Min(X0, X1) + 15) shr 4;
  var PX1 := (Max(X0, X1) + 15) shr 4;
  var PY0 := (Min(Y0, Y1) + 15) shr 4;
  var PY1 := (Max(Y0, Y1) + 15) shr 4;
  if PX0 < FD.SX0 then PX0 := FD.SX0;
  if PY0 < FD.SY0 then PY0 := FD.SY0;
  if PX1 > FD.SX1 + 1 then PX1 := FD.SX1 + 1;
  if PY1 > FD.SY1 + 1 then PY1 := FD.SY1 + 1;
  if (PX0 >= PX1) or (PY0 >= PY1) then
    Exit;
  // Texture coordinates along the edges (in 1/16 texels).
  var U0, U1, TV0, TV1: Double;
  if FD.FST then
  begin
    U0 := V0.U;
    U1 := V1.U;
    TV0 := V0.V;
    TV1 := V1.V;
  end
  else
  begin
    var Q0 := V0.Q;
    var Q1 := V1.Q;
    if Q0 = 0 then Q0 := 1;
    if Q1 = 0 then Q1 := 1;
    U0 := V0.S / Q0 * (1 shl FD.TW) * 16;
    U1 := V1.S / Q1 * (1 shl FD.TW) * 16;
    TV0 := V0.T / Q0 * (1 shl FD.TH) * 16;
    TV1 := V1.T / Q1 * (1 shl FD.TH) * 16;
  end;
  var DUDX := 0.0;
  if X1 <> X0 then
    DUDX := (U1 - U0) / (X1 - X0) * 16;
  var DVDY := 0.0;
  if Y1 <> Y0 then
    DVDY := (TV1 - TV0) / (Y1 - Y0) * 16;
  for var Y := PY0 to PY1 - 1 do
  begin
    var VV := TexCoord(TV0 + (Y * 16 - Y0) * DVDY / 16);
    var UStart := U0 + (PX0 * 16 - X0) * DUDX / 16;
    for var X := PX0 to PX1 - 1 do
    begin
      var UU := TexCoord(UStart + (X - PX0) * DUDX);
      Pixel(X, Y, V1.Z, V1.R, V1.G, V1.B, V1.A, V1.F, UU, VV);
    end;
  end;
end;

procedure TPS2GSRaster.DrawTriangle(const V0, V1, V2: TPS2GSVertex);
begin
  Inc(FPrimitives);
  if (PrimLog <> nil) and (PrimLog.Count < 200000) and FD.TME then
    PrimLog.Add(Format('tri %d,%d %d,%d %d,%d uv=%d,%d %d,%d st=%g,%g,%g q=%g rgba=%d,%d,%d,%d fst=%s abe=%s fbp=%x fbw=%d fpsm=%x tbp=%x tbw=%d tpsm=%x tw=%d th=%d tcc=%s tfx=%d ate=%s atst=%d aref=%d zte=%s ztst=%d blend=%d%d%d%d fix=%d iip=%s',
      [V0.X div 16, V0.Y div 16, V1.X div 16, V1.Y div 16, V2.X div 16, V2.Y div 16, V0.U div 16, V0.V div 16, V2.U div 16, V2.V div 16,
      V0.S, V0.T, V2.S, V0.Q, V0.R, V0.G, V0.B, V0.A, BoolToStr(FD.FST, True), BoolToStr(FD.ABE, True), FD.FBP, FD.FBW, FD.FPSM,
      FD.TBP, FD.TBW, FD.TPSM, FD.TW, FD.TH, BoolToStr(FD.TCC, True), FD.TFX, BoolToStr(FD.ATE, True), FD.ATST, FD.AREF,
      BoolToStr(FD.ZTE, True), FD.ZTST, FD.BlendA, FD.BlendB, FD.BlendC, FD.BlendD, FD.BlendFix, BoolToStr(FD.IIP, True)]));
  var X0 := Int64(V0.X);
  var Y0 := Int64(V0.Y);
  var X1 := Int64(V1.X);
  var Y1 := Int64(V1.Y);
  var X2 := Int64(V2.X);
  var Y2 := Int64(V2.Y);
  var Area := (X1 - X0) * (Y2 - Y0) - (X2 - X0) * (Y1 - Y0);
  if Area = 0 then
    Exit;
  // Bounding box in pixels (sample points at integer pixel coordinates).
  var MinX := (Min(X0, Min(X1, X2)) + 15) shr 4;
  var MaxX := Max(X0, Max(X1, X2)) shr 4;
  var MinY := (Min(Y0, Min(Y1, Y2)) + 15) shr 4;
  var MaxY := Max(Y0, Max(Y1, Y2)) shr 4;
  if MinX < FD.SX0 then MinX := FD.SX0;
  if MinY < FD.SY0 then MinY := FD.SY0;
  if MaxX > FD.SX1 then MaxX := FD.SX1;
  if MaxY > FD.SY1 then MaxY := FD.SY1;
  if (MinX > MaxX) or (MinY > MaxY) then
    Exit;
  var Sign: Int64 := 1;
  if Area < 0 then
    Sign := -1;
  var InvArea := 1.0 / Area;
  // Edge functions E_i (opposite vertex i), positive inside (times Sign).
  // Top-left rule: an edge that is not top or left needs E > 0.
  var A0 := (Y1 - Y2) * Sign;
  var B0 := (X2 - X1) * Sign;
  var A1 := (Y2 - Y0) * Sign;
  var B1 := (X0 - X2) * Sign;
  var A2 := (Y0 - Y1) * Sign;
  var B2 := (X1 - X0) * Sign;
  var Bias0: Int64 := 0;
  var Bias1: Int64 := 0;
  var Bias2: Int64 := 0;
  if not ((A0 > 0) or ((A0 = 0) and (B0 > 0))) then Bias0 := -1;
  if not ((A1 > 0) or ((A1 = 0) and (B1 > 0))) then Bias1 := -1;
  if not ((A2 > 0) or ((A2 = 0) and (B2 > 0))) then Bias2 := -1;
  // Attribute values per vertex.
  var R0 := V0.R; var G0 := V0.G; var BB0 := V0.B; var AA0 := V0.A;
  var R1 := V1.R; var G1 := V1.G; var BB1 := V1.B; var AA1 := V1.A;
  var R2 := V2.R; var G2 := V2.G; var BB2 := V2.B; var AA2 := V2.A;
  if not FD.IIP then
  begin
    R0 := V2.R; R1 := V2.R;
    G0 := V2.G; G1 := V2.G;
    BB0 := V2.B; BB1 := V2.B;
    AA0 := V2.A; AA1 := V2.A;
  end;
  var SW := Double(1 shl FD.TW) * 16;
  var TH := Double(1 shl FD.TH) * 16;
  for var Y := MinY to MaxY do
  begin
    var PY := Int64(Y) * 16;
    var PX := Int64(MinX) * 16;
    var E0 := A0 * (PX - X1) + B0 * (PY - Y1);
    var E1 := A1 * (PX - X2) + B1 * (PY - Y2);
    var E2 := A2 * (PX - X0) + B2 * (PY - Y0);
    var Started := False;
    for var X := MinX to MaxX do
    begin
      if (E0 + Bias0 >= 0) and (E1 + Bias1 >= 0) and (E2 + Bias2 >= 0) then
      begin
        Started := True;
        var W0 := E0 * Sign * InvArea;
        var W1 := E1 * Sign * InvArea;
        var W2 := 1.0 - W0 - W1;
        var R := Round(W0 * R0 + W1 * R1 + W2 * R2);
        var G := Round(W0 * G0 + W1 * G1 + W2 * G2);
        var B := Round(W0 * BB0 + W1 * BB1 + W2 * BB2);
        var A := Round(W0 * AA0 + W1 * AA1 + W2 * AA2);
        var ZD := W0 * V0.Z + W1 * V1.Z + W2 * V2.Z;
        if ZD < 0 then
          ZD := 0;
        if ZD > 4294967295.0 then
          ZD := 4294967295.0;
        var F := Round(W0 * V0.F + W1 * V1.F + W2 * V2.F);
        var U, TV: Integer;
        if FD.TME then
        begin
          if FD.FST then
          begin
            U := TexCoord(W0 * V0.U + W1 * V1.U + W2 * V2.U);
            TV := TexCoord(W0 * V0.V + W1 * V1.V + W2 * V2.V);
          end
          else
          begin
            var Q := W0 * V0.Q + W1 * V1.Q + W2 * V2.Q;
            if Q = 0 then
              Q := 1;
            U := TexCoord((W0 * V0.S + W1 * V1.S + W2 * V2.S) / Q * SW);
            TV := TexCoord((W0 * V0.T + W1 * V1.T + W2 * V2.T) / Q * TH);
          end;
        end
        else
        begin
          U := 0;
          TV := 0;
        end;
        Pixel(X, Y, Cardinal(Trunc(ZD)), EnsureRange(R, 0, 255), EnsureRange(G, 0, 255), EnsureRange(B, 0, 255),
          EnsureRange(A, 0, 255), EnsureRange(F, 0, 255), U, TV);
      end
      else if Started then
        Break;
      Inc(E0, A0 * 16);
      Inc(E1, A1 * 16);
      Inc(E2, A2 * 16);
    end;
  end;
end;

{ CLUT }

procedure TPS2GSRaster.LoadClut(Tex0: UInt64);
begin
  var CLD := Integer((Tex0 shr 61) and 7);
  var CBP := Cardinal((Tex0 shr 37) and $3FFF);
  case CLD of
    0: Exit;
    1: ;
    2: FCBP0 := CBP;
    3: FCBP1 := CBP;
    4:
      begin
        if CBP = FCBP0 then
          Exit;
        FCBP0 := CBP;
      end;
    5:
      begin
        if CBP = FCBP1 then
          Exit;
        FCBP1 := CBP;
      end;
  else
    Exit;
  end;
  var PSM := Integer((Tex0 shr 20) and $3F);
  var CPSM := Integer((Tex0 shr 51) and $F);
  var CSM := Integer((Tex0 shr 55) and 1);
  var CSA := Integer((Tex0 shr 56) and $1F);
  var Count := 16;
  if (PSM = PSMT8) or (PSM = PSMT8H) then
    Count := 256
  else if not ((PSM = PSMT4) or (PSM = PSMT4HL) or (PSM = PSMT4HH)) then
    Exit;
  var Is32 := CPSM = PSMCT32;
  var Base := 0;
  if Count = 16 then
    Base := CSA * 16;
  for var I := 0 to Count - 1 do
  begin
    var X, Y: Integer;
    if CSM = 0 then
    begin
      if Count = 256 then
      begin
        var J := (I and $E7) or ((I and 8) shl 1) or ((I and $10) shr 1);
        X := J and 15;
        Y := J shr 4;
      end
      else
      begin
        X := I and 7;
        Y := I shr 3;
      end;
    end
    else
    begin
      var TexClut := Regs[GSRegTEXCLUT];
      X := Integer((TexClut shr 6) and $3F) * 16 + I;
      Y := Integer((TexClut shr 12) and $3FF);
    end;
    var BW: Cardinal := 1;
    if CSM <> 0 then
      BW := Cardinal(Regs[GSRegTEXCLUT] and $3F);
    if Is32 then
    begin
      var V := FMemory.ReadRaw(PSMCT32, CBP, BW, Cardinal(X), Cardinal(Y));
      var Slot := (Base + I) and 255;
      FClut[Slot] := Word(V);
      FClut[Slot + 256] := Word(V shr 16);
    end
    else
    begin
      var V := FMemory.ReadRaw(CPSM, CBP, BW, Cardinal(X), Cardinal(Y));
      FClut[(Base + I) and 511] := Word(V);
    end;
  end;
end;

{ Transfers }

function TransferBits(PSM: Cardinal): Integer;
begin
  case PSM of
    PSMCT32, PSMZ32: Result := 32;
    PSMCT24, PSMZ24: Result := 24;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: Result := 16;
    PSMT8, PSMT8H: Result := 8;
    PSMT4, PSMT4HL, PSMT4HH: Result := 4;
  else
    Result := 32;
  end;
end;

procedure TPS2GSRaster.StartTransfer;
begin
  var Dir := Integer(Regs[GSRegTRXDIR] and 3);
  if (TransferLog <> nil) and (TransferLog.Count < 100000) then
    TransferLog.Add(Format('buf=%.16x pos=%.16x reg=%.16x dir=%d', [Regs[GSRegBITBLTBUF], Regs[GSRegTRXPOS],
      Regs[GSRegTRXREG], Dir]));
  FXferActive := False;
  FXferX := 0;
  FXferY := 0;
  FXferBits := 0;
  FXferBitCount := 0;
  case Dir of
    0: FXferActive := True;
    1: LocalToHost;
    2: LocalToLocal;
  end;
end;

procedure TPS2GSRaster.TransferPixel(Value: Cardinal);
begin
  var Buf := Regs[GSRegBITBLTBUF];
  var Pos := Regs[GSRegTRXPOS];
  var Reg := Regs[GSRegTRXREG];
  var DBP := Cardinal((Buf shr 32) and $3FFF);
  var DBW := Cardinal((Buf shr 48) and $3F);
  var DPSM := Integer((Buf shr 56) and $3F);
  var DSAX := Integer((Pos shr 32) and $7FF);
  var DSAY := Integer((Pos shr 48) and $7FF);
  var RRW := Integer(Reg and $FFF);
  var RRH := Integer((Reg shr 32) and $FFF);
  if (RRW = 0) or (RRH = 0) then
  begin
    FXferActive := False;
    Exit;
  end;
  FMemory.WriteRaw(DPSM, DBP, DBW, Cardinal((DSAX + FXferX) and $7FF), Cardinal((DSAY + FXferY) and $7FF), Value);
  Inc(FXferPixels);
  Inc(FXferX);
  if FXferX >= RRW then
  begin
    FXferX := 0;
    Inc(FXferY);
    if FXferY >= RRH then
      FXferActive := False;
  end;
end;

procedure TPS2GSRaster.FeedWord(W: Cardinal);
begin
  if not FXferActive then
    Exit;
  var Bits := TransferBits(Cardinal((Regs[GSRegBITBLTBUF] shr 56) and $3F));
  FXferBits := FXferBits or (UInt64(W) shl FXferBitCount);
  Inc(FXferBitCount, 32);
  var Mask := (UInt64(1) shl Bits) - 1;
  while (FXferBitCount >= Bits) and FXferActive do
  begin
    TransferPixel(Cardinal(FXferBits and Mask));
    FXferBits := FXferBits shr Bits;
    Dec(FXferBitCount, Bits);
  end;
end;

procedure TPS2GSRaster.WriteImage(const Data: TPS2Reg128);
begin
  for var K := 0 to 3 do
    FeedWord(Data.UW[K]);
end;

procedure TPS2GSRaster.LocalToLocal;
begin
  var Buf := Regs[GSRegBITBLTBUF];
  var Pos := Regs[GSRegTRXPOS];
  var Reg := Regs[GSRegTRXREG];
  var SBP := Cardinal(Buf and $3FFF);
  var SBW := Cardinal((Buf shr 16) and $3F);
  var SPSM := Integer((Buf shr 24) and $3F);
  var DBP := Cardinal((Buf shr 32) and $3FFF);
  var DBW := Cardinal((Buf shr 48) and $3F);
  var DPSM := Integer((Buf shr 56) and $3F);
  var SSAX := Integer(Pos and $7FF);
  var SSAY := Integer((Pos shr 16) and $7FF);
  var DSAX := Integer((Pos shr 32) and $7FF);
  var DSAY := Integer((Pos shr 48) and $7FF);
  var RRW := Integer(Reg and $FFF);
  var RRH := Integer((Reg shr 32) and $FFF);
  for var Y := 0 to RRH - 1 do
    for var X := 0 to RRW - 1 do
    begin
      var V := FMemory.ReadRaw(SPSM, SBP, SBW, Cardinal((SSAX + X) and $7FF), Cardinal((SSAY + Y) and $7FF));
      FMemory.WriteRaw(DPSM, DBP, DBW, Cardinal((DSAX + X) and $7FF), Cardinal((DSAY + Y) and $7FF), V);
    end;
end;

procedure TPS2GSRaster.LocalToHost;
begin
  var Buf := Regs[GSRegBITBLTBUF];
  var Pos := Regs[GSRegTRXPOS];
  var Reg := Regs[GSRegTRXREG];
  var SBP := Cardinal(Buf and $3FFF);
  var SBW := Cardinal((Buf shr 16) and $3F);
  var SPSM := Integer((Buf shr 24) and $3F);
  var SSAX := Integer(Pos and $7FF);
  var SSAY := Integer((Pos shr 16) and $7FF);
  var RRW := Integer(Reg and $FFF);
  var RRH := Integer((Reg shr 32) and $FFF);
  var Bits := TransferBits(Cardinal(SPSM));
  var Acc: UInt64 := 0;
  var Count := 0;
  FReadBuffer := nil;
  SetLength(FReadBuffer, (RRW * RRH * Bits + 31) div 32 + 4);
  var N := 0;
  for var Y := 0 to RRH - 1 do
    for var X := 0 to RRW - 1 do
    begin
      var V := FMemory.ReadRaw(SPSM, SBP, SBW, Cardinal((SSAX + X) and $7FF), Cardinal((SSAY + Y) and $7FF));
      Acc := Acc or (UInt64(V and ((UInt64(1) shl Bits) - 1)) shl Count);
      Inc(Count, Bits);
      while Count >= 32 do
      begin
        FReadBuffer[N] := Cardinal(Acc);
        Inc(N);
        Acc := Acc shr 32;
        Dec(Count, 32);
      end;
    end;
  if Count > 0 then
  begin
    FReadBuffer[N] := Cardinal(Acc);
    Inc(N);
  end;
  SetLength(FReadBuffer, (N + 3) and not 3);
  FReadPos := 0;
end;

function TPS2GSRaster.ReadImage(out Data: TPS2Reg128): Boolean;
begin
  Data := Default(TPS2Reg128);
  if FReadPos + 4 > Length(FReadBuffer) then
    Exit(False);
  for var K := 0 to 3 do
    Data.UW[K] := FReadBuffer[FReadPos + K];
  Inc(FReadPos, 4);
  Result := True;
end;

procedure TPS2GSRaster.SerializeState(State: TStateArchive);
begin
  State.Field(Regs, SizeOf(Regs));
  State.Field(SigLblId, SizeOf(SigLblId));
  State.Field(FSignal, SizeOf(FSignal));
  State.Field(FFinish, SizeOf(FFinish));
  State.Field(FQueue, SizeOf(FQueue));
  State.Field(FQueueCount, SizeOf(FQueueCount));
  State.Field(FStripIndex, SizeOf(FStripIndex));
  State.Field(FCurrent, SizeOf(FCurrent));
  State.Field(FQ, SizeOf(FQ));
  State.Field(FClut, SizeOf(FClut));
  State.Field(FCBP0, SizeOf(FCBP0));
  State.Field(FCBP1, SizeOf(FCBP1));
  State.Field(FXferActive, SizeOf(FXferActive));
  State.Field(FXferX, SizeOf(FXferX));
  State.Field(FXferY, SizeOf(FXferY));
  State.Field(FXferBits, SizeOf(FXferBits));
  State.Field(FXferBitCount, SizeOf(FXferBitCount));
  var N := Length(FReadBuffer);
  State.Field(N, SizeOf(N));
  if State.Loading then
    SetLength(FReadBuffer, N);
  if N > 0 then
    State.Field(FReadBuffer[0], N * 4);
  State.Field(FReadPos, SizeOf(FReadPos));
  State.Field(FMemory.Data^, PS2GSMemorySize);
end;

end.
