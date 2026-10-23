unit PS2.GS;

// Graphics Synthesizer: privileged registers (PMODE..SIGLBLID, CSR/IMR),
// the general registers written through the GIF, 4 MiB of local memory in
// its swizzled page layout, the drawing environment and the display (CRTC):
// one or two read circuits merged into the output picture. Drawing itself is
// done by PS2.GS.Raster.
// References: GS User's Manual (PS2 Linux Kit), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types, PS2.EE.Bus, PS2.GS.Memory, PS2.GS.Raster;

type
  TPS2GSInterrupt = procedure of object;

  TPS2GS = class(TPS2Device)
  private
    FRaster: TPS2GSRaster;
    FOnInterrupt: TPS2GSInterrupt;
    FFrame: TArray<Cardinal>;
    FFrameWidth, FFrameHeight: Integer;
    procedure CheckInterrupt;
    procedure ReadCircuit(N: Integer; out Pixels: TArray<Cardinal>; out W, H, DX, DY, MagH: Integer);
  public
    // Privileged registers (index by (address shr 4) and $FF for 1200_0000h,
    // CSR etc. at 1200_1000h).
    PMODE, SMODE1, SMODE2, SRFSH, SYNCH1, SYNCH2, SYNCV, DISPFB1, DISPLAY1, DISPFB2, DISPLAY2, EXTBUF, EXTDATA,
      EXTWRITE, BGCOLOR, CSR, IMR, BUSDIR, SIGLBLID: UInt64;
    PAL, Interlaced: Boolean;
    OddField: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    // A general register write from the GIF (A+D or packed/reglist).
    procedure WriteRegister(Index: Integer; Value: UInt64);
    // Host-to-local transfer data (IMAGE mode), 128 bits at a time.
    procedure WriteImage(const Data: TPS2Reg128);
    // Local-to-host transfer (BUSDIR=1): next 128 bits.
    function ReadImage(out Data: TPS2Reg128): Boolean;
    // VBlank start: CSR.VSINT and the interrupt; builds the output picture.
    procedure VBlank;
    procedure HBlank;
    procedure BuildFrame;
    procedure SerializeState(State: TStateArchive);
    property Raster: TPS2GSRaster read FRaster;
    property Frame: TArray<Cardinal> read FFrame;
    property FrameWidth: Integer read FFrameWidth;
    property FrameHeight: Integer read FFrameHeight;
    property OnInterrupt: TPS2GSInterrupt read FOnInterrupt write FOnInterrupt;
  end;

implementation

constructor TPS2GS.Create;
begin
  inherited Create;
  FRaster := TPS2GSRaster.Create;
  FRaster.OnSignal := CheckInterrupt;
  Reset;
end;

destructor TPS2GS.Destroy;
begin
  FRaster.Free;
  inherited;
end;

procedure TPS2GS.Reset;
begin
  PMODE := 0;
  SMODE1 := 0;
  SMODE2 := 0;
  SRFSH := 0;
  SYNCH1 := 0;
  SYNCH2 := 0;
  SYNCV := 0;
  DISPFB1 := 0;
  DISPLAY1 := 0;
  DISPFB2 := 0;
  DISPLAY2 := 0;
  EXTBUF := 0;
  EXTDATA := 0;
  EXTWRITE := 0;
  BGCOLOR := 0;
  CSR := $551B0000 or 8;
  IMR := $FF00;
  BUSDIR := 0;
  SIGLBLID := 0;
  OddField := False;
  FRaster.Reset;
  FFrameWidth := 640;
  FFrameHeight := 448;
  SetLength(FFrame, FFrameWidth * FFrameHeight);
  FillChar(FFrame[0], Length(FFrame) * 4, 0);
end;

procedure TPS2GS.CheckInterrupt;
begin
  // CSR bits 0..4 (SIGNAL, FINISH, HSINT, VSINT, EDWINT) against IMR bits 8..12.
  var Pending := (CSR and $1F) and not ((IMR shr 8) and $1F);
  if FRaster.SignalPending then
    CSR := CSR or 1;
  if FRaster.FinishPending then
    CSR := CSR or 2;
  Pending := (CSR and $1F) and not ((IMR shr 8) and $1F);
  if (Pending <> 0) and Assigned(FOnInterrupt) then
    FOnInterrupt;
end;

function TPS2GS.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  var Shift := (Address and 7) * 8;
  var V: UInt64;
  case Address and $FFF8 of
    $1000:
      begin
        V := CSR and not UInt64($2000);
        if OddField then
          V := V or $2000;
        if FRaster.SignalPending then
          V := V or 1;
        if FRaster.FinishPending then
          V := V or 2;
      end;
    $1010: V := IMR;
    $1040: V := BUSDIR;
    $1080: V := FRaster.SigLblId;
  else
    V := 0;
  end;
  Result := V shr Shift;
end;

procedure TPS2GS.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  if Size = 4 then
  begin
    // 32-bit halves of the 64-bit registers.
    var Old := Read(Address and not 7, 8);
    if (Address and 4) <> 0 then
      Value := (Old and $FFFFFFFF) or (Value shl 32)
    else
      Value := (Old and $FFFFFFFF00000000) or (Value and $FFFFFFFF);
    if (Address and $FFF8) = $1000 then
    begin
      // CSR: only the low half acts; FIELD etc. read-only.
      if (Address and 4) <> 0 then
        Exit;
    end;
  end;
  case Address and $FFF8 of
    $0000: PMODE := Value;
    $0010: SMODE1 := Value;
    $0020: SMODE2 := Value;
    $0030: SRFSH := Value;
    $0040: SYNCH1 := Value;
    $0050: SYNCH2 := Value;
    $0060: SYNCV := Value;
    $0070: DISPFB1 := Value;
    $0080: DISPLAY1 := Value;
    $0090: DISPFB2 := Value;
    $00A0: DISPLAY2 := Value;
    $00B0: EXTBUF := Value;
    $00C0: EXTDATA := Value;
    $00D0: EXTWRITE := Value;
    $00E0: BGCOLOR := Value;
    $1000:
      begin
        // Writing 1 clears the event bits; RESET (bit 9) resets the GS.
        if (Value and 1) <> 0 then
          FRaster.ClearSignal;
        if (Value and 2) <> 0 then
          FRaster.ClearFinish;
        CSR := CSR and not (Value and $1C);
        if (Value and $200) <> 0 then
        begin
          FRaster.ClearSignal;
          FRaster.ClearFinish;
          CSR := CSR and not UInt64($1F);
        end;
        CheckInterrupt;
      end;
    $1010:
      begin
        IMR := Value and $7F00;
        CheckInterrupt;
      end;
    $1040: BUSDIR := Value and 1;
    $1080: FRaster.SigLblId := Value;
  end;
end;

procedure TPS2GS.WriteRegister(Index: Integer; Value: UInt64);
begin
  FRaster.WriteRegister(Index, Value);
  if FRaster.SignalPending or FRaster.FinishPending then
    CheckInterrupt;
end;

procedure TPS2GS.WriteImage(const Data: TPS2Reg128);
begin
  FRaster.WriteImage(Data);
end;

function TPS2GS.ReadImage(out Data: TPS2Reg128): Boolean;
begin
  Result := FRaster.ReadImage(Data);
end;

procedure TPS2GS.VBlank;
begin
  if Interlaced then
    OddField := not OddField
  else
    OddField := False;
  CSR := CSR or 8;
  BuildFrame;
  CheckInterrupt;
end;

procedure TPS2GS.HBlank;
begin
  CSR := CSR or 4;
  CheckInterrupt;
end;

procedure TPS2GS.ReadCircuit(N: Integer; out Pixels: TArray<Cardinal>; out W, H, DX, DY, MagH: Integer);
begin
  var FB := DISPFB1;
  var D := DISPLAY1;
  if N = 2 then
  begin
    FB := DISPFB2;
    D := DISPLAY2;
  end;
  var FBP := Cardinal(FB and $1FF) * 2048;
  var FBW := Cardinal((FB shr 9) and $3F) * 64;
  var PSM := Integer((FB shr 15) and $1F);
  var DBX := Integer((FB shr 32) and $7FF);
  var DBY := Integer((FB shr 43) and $7FF);
  DX := Integer(D and $FFF);
  DY := Integer((D shr 12) and $7FF);
  MagH := Integer((D shr 23) and $F) + 1;
  var MagV := Integer((D shr 27) and 3) + 1;
  W := (Integer((D shr 32) and $FFF) + 1) div MagH;
  H := (Integer((D shr 44) and $7FF) + 1) div MagV;
  if W <= 0 then
    W := 1;
  if H <= 0 then
    H := 1;
  if W > 1024 then
    W := 1024;
  if H > 1024 then
    H := 1024;
  // Frame mode in interlace reads every other line of a full frame.
  var FrameMode := Interlaced and ((SMODE2 and 2) <> 0);
  if FrameMode then
    H := H div 2;
  SetLength(Pixels, W * H);
  for var Y := 0 to H - 1 do
  begin
    var SY := DBY + Y;
    if FrameMode then
      SY := DBY + Y * 2 + Ord(OddField);
    for var X := 0 to W - 1 do
      Pixels[Y * W + X] := FRaster.Memory.ReadPixel(PSM, FBP, FBW, DBX + X, SY);
  end;
end;

procedure TPS2GS.BuildFrame;
begin
  // Circuit 2 (background) then circuit 1, blended per PMODE.
  var En1 := (PMODE and 1) <> 0;
  var En2 := (PMODE and 2) <> 0;
  if not En1 and not En2 then
  begin
    if Length(FFrame) = 0 then
      SetLength(FFrame, FFrameWidth * FFrameHeight);
    FillChar(FFrame[0], Length(FFrame) * 4, 0);
    Exit;
  end;
  var P1, P2: TArray<Cardinal>;
  var W1, H1, X1, Y1, M1, W2, H2, X2, Y2, M2: Integer;
  W1 := 0;
  H1 := 0;
  W2 := 0;
  H2 := 0;
  X1 := 0;
  Y1 := 0;
  X2 := 0;
  Y2 := 0;
  M1 := 1;
  M2 := 1;
  if En1 then
    ReadCircuit(1, P1, W1, H1, X1, Y1, M1);
  if En2 then
    ReadCircuit(2, P2, W2, H2, X2, Y2, M2);
  var W := Max(W1, W2);
  var H := Max(H1, H2);
  if (W <> FFrameWidth) or (H <> FFrameHeight) then
  begin
    FFrameWidth := W;
    FFrameHeight := H;
  end;
  SetLength(FFrame, W * H);
  var BG := Cardinal(BGCOLOR and $FFFFFF);
  var BGPixel := $FF000000 or ((BG and $FF) shl 16) or (BG and $FF00) or ((BG shr 16) and $FF);
  // Offsets between the circuits (in output pixels).
  var OX1 := 0;
  var OY1 := 0;
  var OX2 := 0;
  var OY2 := 0;
  if En1 and En2 then
  begin
    var MinX := Min(X1 div M1, X2 div M2);
    var MinY := Min(Y1, Y2);
    OX1 := X1 div M1 - MinX;
    OX2 := X2 div M2 - MinX;
    OY1 := Y1 - MinY;
    OY2 := Y2 - MinY;
  end;
  var AlphaFixed := (PMODE and $20) <> 0;
  var ALP := Integer((PMODE shr 8) and $FF);
  var Slbg := (PMODE and $80) <> 0;
  for var Y := 0 to H - 1 do
    for var X := 0 to W - 1 do
    begin
      var Back := BGPixel;
      if En2 and not Slbg then
      begin
        var SX := X - OX2;
        var SY := Y - OY2;
        if (SX >= 0) and (SY >= 0) and (SX < W2) and (SY < H2) then
          Back := P2[SY * W2 + SX];
      end;
      var Out := Back;
      if En1 then
      begin
        var SX := X - OX1;
        var SY := Y - OY1;
        if (SX >= 0) and (SY >= 0) and (SX < W1) and (SY < H1) then
        begin
          var F := P1[SY * W1 + SX];
          var A := ALP;
          if not AlphaFixed then
            A := Integer(F shr 24);
          if A >= 128 then
            Out := F
          else
          begin
            var R := ((Integer(F and $FF) * A) + Integer(Back and $FF) * (128 - A)) shr 7;
            var G := ((Integer((F shr 8) and $FF) * A) + Integer((Back shr 8) and $FF) * (128 - A)) shr 7;
            var B := ((Integer((F shr 16) and $FF) * A) + Integer((Back shr 16) and $FF) * (128 - A)) shr 7;
            Out := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
          end;
        end;
      end;
      // GS pixels are R in bits 0..7; output ARGB.
      FFrame[Y * W + X] := $FF000000 or ((Out and $FF) shl 16) or (Out and $FF00) or ((Out shr 16) and $FF);
    end;
end;

procedure TPS2GS.SerializeState(State: TStateArchive);
begin
  State.Field(PMODE, SizeOf(PMODE));
  State.Field(SMODE1, SizeOf(SMODE1));
  State.Field(SMODE2, SizeOf(SMODE2));
  State.Field(SRFSH, SizeOf(SRFSH));
  State.Field(SYNCH1, SizeOf(SYNCH1));
  State.Field(SYNCH2, SizeOf(SYNCH2));
  State.Field(SYNCV, SizeOf(SYNCV));
  State.Field(DISPFB1, SizeOf(DISPFB1));
  State.Field(DISPLAY1, SizeOf(DISPLAY1));
  State.Field(DISPFB2, SizeOf(DISPFB2));
  State.Field(DISPLAY2, SizeOf(DISPLAY2));
  State.Field(EXTBUF, SizeOf(EXTBUF));
  State.Field(EXTDATA, SizeOf(EXTDATA));
  State.Field(EXTWRITE, SizeOf(EXTWRITE));
  State.Field(BGCOLOR, SizeOf(BGCOLOR));
  State.Field(CSR, SizeOf(CSR));
  State.Field(IMR, SizeOf(IMR));
  State.Field(BUSDIR, SizeOf(BUSDIR));
  State.Field(PAL, SizeOf(PAL));
  State.Field(Interlaced, SizeOf(Interlaced));
  State.Field(OddField, SizeOf(OddField));
  FRaster.SerializeState(State);
end;

end.
