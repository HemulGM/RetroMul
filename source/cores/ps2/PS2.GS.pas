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
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, Core.Snapshots, PS2.Types, PS2.EE.Bus, PS2.GS.Memory, PS2.GS.Raster;

type
  TPS2GSInterrupt = procedure of object;
  TPS2GSAccess = procedure of object;
  TPS2GSRaised = function: Boolean of object;

  // The display registers a picture is built from (at a VBlank).
  TPS2GSDisplay = record
    PMODE, SMODE2, DISPFB1, DISPLAY1, DISPFB2, DISPLAY2, BGCOLOR: UInt64;
    Interlaced: Boolean;
  end;

  // A picture built: Width x Height pixels (ARGB), the frame Number it is.
  TPS2GSFrameEvent = reference to procedure(const Pixels: TArray<Cardinal>; Width, Height: Integer; Number: Int64);

  TPS2GS = class;

  // Builds pictures from copies of the display's pages (TPS2GS.BuildFrame
  // with the raster Async): the GS worker copies the pages into a free
  // snapshot and hands it over, so it goes on drawing at once.
  TPS2GSComposer = class(TThread)
  private type
    TJob = record
      Display: TPS2GSDisplay;
      Number: Int64;
    end;
  private
    FGS: TPS2GS;
    FSnapshots: array[0..1] of TPS2GSMemory;
    FJobs: array[0..1] of TJob;
    // Jobs handed over and done (snapshot K: job K mod 2).
    FPosted, FDone: Int64;
    FWork, FFinished: TEvent;
    // A picture failed (1; 2 while the message is being set): raised by
    // Post and Finish.
    FFailed: Integer;
    FFailure: string;
    procedure CheckFailure;
  protected
    procedure Execute; override;
  public
    constructor Create(GS: TPS2GS);
    destructor Destroy; override;
    // Copies Pages of Memory into the next snapshot (once it is free) and
    // hands it over (one thread at a time: the GS worker's or, with no copy
    // of it outstanding, the emulation thread).
    procedure Post(const Display: TPS2GSDisplay; const Pages: TPS2GSPages; Memory: TPS2GSMemory; Number: Int64);
    // Waits until the jobs handed over are done.
    procedure Finish;
  end;

  TPS2GS = class(TPS2Device)
  private
    FRaster: TPS2GSRaster;
    FOnInterrupt: TPS2GSInterrupt;
    FBeforeAccess: TPS2GSAccess;
    FInterruptRaised: TPS2GSRaised;
    FInterruptsQuiet: Boolean;
    FFrame: TArray<Cardinal>;
    FFrameWidth, FFrameHeight: Integer;
    // Pictures asked for (BuildFrame) and built (Compose: on the GS worker's
    // thread with the raster Async, in order with the drawing).
    FFramesQueued, FFramesBuilt: Int64;
    FOnFrame: TPS2GSFrameEvent;
    FComposer: TPS2GSComposer;
    // Pictures whose pages the GS worker copies for the composer: queued and
    // copied (the emulation thread copies them itself only when none is
    // outstanding, so that they stay in order).
    FWorkerFrames, FWorkerCopied: Int64;
    procedure CheckInterrupt;
    class procedure CircuitSize(const D: TPS2GSDisplay; N: Integer; out W, H, DX, DY, MagH: Integer); static;
    class procedure ReadCircuit(const D: TPS2GSDisplay; Memory: TPS2GSMemory; N, W, H: Integer;
      out Pixels: TArray<Cardinal>); static;
    class procedure CircuitPages(const D: TPS2GSDisplay; N: Integer; var Pages: TPS2GSPages); static;
    class procedure CircuitsRead(const D: TPS2GSDisplay; out Read1, Read2: Boolean); static;
    procedure Compose(const D: TPS2GSDisplay; Memory: TPS2GSMemory; Number: Int64);
    procedure SyncFrame;
    function GetFrame: TArray<Cardinal>;
    function GetFrameWidth: Integer;
    function GetFrameHeight: Integer;
  public
    // Privileged registers (index by (address shr 4) and $FF for 1200_0000h,
    // CSR etc. at 1200_1000h).
    PMODE, SMODE1, SMODE2, SRFSH, SYNCH1, SYNCH2, SYNCV, DISPFB1, DISPLAY1, DISPFB2, DISPLAY2, EXTBUF, EXTDATA,
      EXTWRITE, BGCOLOR, CSR, IMR, BUSDIR, SIGLBLID: UInt64;
    PAL, Interlaced: Boolean;
    OddField: Boolean;
    // SMODE2.INT sets Interlaced (BIOS boot; the high-level kernel keeps it
    // on).
    InterlaceFromSMODE2: Boolean;
    // BIOS boot as well: SMODE1 selects NTSC or PAL field timing.
    OnVideoMode: TProc<Boolean>;
    // The frame number the next VBlank's picture is (the console's).
    FrameNumber: Int64;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    // A general register write from the GIF (A+D or packed/reglist).
    procedure WriteRegister(Index: Integer; Value: UInt64);
    // Whether WriteRegister raises the interrupt now, whatever it writes (a
    // SIGNAL or FINISH event is pending and an unmasked event is in CSR), to
    // any effect (it is not raised already, InterruptRaised).
    function WriteInterrupts: Boolean;
    // Host-to-local transfer data (IMAGE mode), 128 bits at a time.
    procedure WriteImage(const Data: TPS2Reg128);
    // Local-to-host transfer (BUSDIR=1): next 128 bits.
    function ReadImage(out Data: TPS2Reg128): Boolean;
    // VBlank start: CSR.VSINT and the interrupt; builds the output picture.
    procedure VBlank;
    procedure HBlank;
    // Asks for the output picture of the display registers as they are now,
    // built from GS memory as everything queued so far draws it (with the
    // raster Async, later on the GS worker's thread: OnFrame tells).
    procedure BuildFrame;
    procedure SerializeState(State: TStateArchive);
    property Raster: TPS2GSRaster read FRaster;
    // The last picture asked for (they wait until it is built: emulation
    // thread).
    property Frame: TArray<Cardinal> read GetFrame;
    property FrameWidth: Integer read GetFrameWidth;
    property FrameHeight: Integer read GetFrameHeight;
    // Each picture once built, on the thread that built it (the GS worker's
    // with the raster Async, else the emulation thread). Pixels are not to be
    // changed.
    property OnFrame: TPS2GSFrameEvent read FOnFrame write FOnFrame;
    property OnInterrupt: TPS2GSInterrupt read FOnInterrupt write FOnInterrupt;
    // Whether OnInterrupt would change nothing now (the interrupt is pending).
    property InterruptRaised: TPS2GSRaised read FInterruptRaised write FInterruptRaised;
    // OnInterrupt is not called (the GIF's kick thread: given only what would
    // raise nothing new, WriteInterrupts).
    property InterruptsQuiet: Boolean read FInterruptsQuiet write FInterruptsQuiet;
    // Called before the methods above other than WriteRegister, WriteImage and
    // WriteInterrupts (the GIF's: it may be giving the GS packets on a thread
    // of its own).
    property BeforeAccess: TPS2GSAccess read FBeforeAccess write FBeforeAccess;
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
  FComposer.Free;
  inherited;
end;

procedure TPS2GS.Reset;
begin
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
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
  if FComposer <> nil then
    FComposer.Finish;
  FFrameWidth := 640;
  FFrameHeight := 448;
  SetLength(FFrame, FFrameWidth * FFrameHeight);
  FillChar(FFrame[0], Length(FFrame) * 4, 0);
end;

procedure TPS2GS.CheckInterrupt;
begin
  // CSR bits 0..4 (SIGNAL, FINISH, HSINT, VSINT, EDWINT) against IMR bits 8..12.
  if FRaster.SignalPending then
    CSR := CSR or 1;
  if FRaster.FinishPending then
    CSR := CSR or 2;
  var Pending := (CSR and $1F) and not ((IMR shr 8) and $1F);
  if (Pending <> 0) and Assigned(FOnInterrupt) and not FInterruptsQuiet then
    FOnInterrupt;
end;

function TPS2GS.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
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
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
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
    $0010:
      begin
        SMODE1 := Value;
        // CMOD (bits 13-14): 2 NTSC, 3 PAL; other values (VESA, HDTV) leave
        // the field timing.
        if InterlaceFromSMODE2 and Assigned(OnVideoMode) and (((Value shr 13) and 3) >= 2) then
          OnVideoMode(((Value shr 13) and 3) = 3);
      end;
    $0020:
      begin
        SMODE2 := Value;
        if InterlaceFromSMODE2 then
          Interlaced := (Value and 1) <> 0;
      end;
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
        CSR := CSR and not (Value and $1F);
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

function TPS2GS.WriteInterrupts: Boolean;
begin
  if not (FRaster.SignalPending or FRaster.FinishPending) or not Assigned(FOnInterrupt) then
    Exit(False);
  var C := CSR;
  if FRaster.SignalPending then
    C := C or 1;
  if FRaster.FinishPending then
    C := C or 2;
  Result := (((C and $1F) and not ((IMR shr 8) and $1F)) <> 0) and
    not (Assigned(FInterruptRaised) and FInterruptRaised());
end;

procedure TPS2GS.WriteImage(const Data: TPS2Reg128);
begin
  FRaster.WriteImage(Data);
end;

function TPS2GS.ReadImage(out Data: TPS2Reg128): Boolean;
begin
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
  Result := FRaster.ReadImage(Data);
end;

procedure TPS2GS.VBlank;
begin
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
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
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
  CSR := CSR or 4;
  CheckInterrupt;
end;

class procedure TPS2GS.CircuitSize(const D: TPS2GSDisplay; N: Integer; out W, H, DX, DY, MagH: Integer);
begin
  var R := D.DISPLAY1;
  if N = 2 then R := D.DISPLAY2;
  DX := Integer(R and $FFF);
  DY := Integer((R shr 12) and $7FF);
  MagH := Integer((R shr 23) and $F) + 1;
  var MagV := Integer((R shr 27) and 3) + 1;
  W := (Integer((R shr 32) and $FFF) + 1) div MagH;
  H := (Integer((R shr 44) and $7FF) + 1) div MagV;
  if W <= 0 then
    W := 1;
  if H <= 0 then
    H := 1;
  if W > 1024 then
    W := 1024;
  if H > 1024 then
    H := 1024;
  // Interlaced frame mode (SMODE2 INT and FFMD) reads every line of a buffer
  // holding one field: half the lines DISPLAY counts. Field mode reads every
  // other line of a full frame per field; both fields together are the
  // frame as it is in memory, which is what is shown.
  if D.Interlaced and ((D.SMODE2 and 3) = 3) then
    H := H div 2;
end;

// The pages circuit N reads.
class procedure TPS2GS.CircuitPages(const D: TPS2GSDisplay; N: Integer; var Pages: TPS2GSPages);
begin
  var W, H, X, Y, M: Integer;
  CircuitSize(D, N, W, H, X, Y, M);
  var FB := D.DISPFB1;
  if N = 2 then FB := D.DISPFB2;
  var DBX := Integer((FB shr 32) and $7FF);
  var DBY := Integer((FB shr 43) and $7FF);
  AddRectPages(Pages, Cardinal(FB and $1FF) * 32, Cardinal((FB shr 9) and $3F), Cardinal((FB shr 15) and $1F), DBX, DBY,
    DBX + W - 1, DBY + H - 1);
end;

class procedure TPS2GS.ReadCircuit(const D: TPS2GSDisplay; Memory: TPS2GSMemory; N, W, H: Integer;
  out Pixels: TArray<Cardinal>);
begin
  SetLength(Pixels, W * H);
  if H = 0 then Exit;
  var FB := D.DISPFB1;
  if N = 2 then FB := D.DISPFB2;
  var FBP := Cardinal(FB and $1FF) * 2048;
  var FBW := Cardinal((FB shr 9) and $3F) * 64;
  var PSM := Integer((FB shr 15) and $1F);
  var DBX := Integer((FB shr 32) and $7FF);
  var DBY := Integer((FB shr 43) and $7FF);
  for var Y := 0 to H - 1 do
    Memory.ReadDisplayRow(PSM, FBP, FBW, DBX, DBY + Y, @Pixels[Y * W], W);
end;

// The circuits Compose reads: circuit 2 not under an opaque circuit 1
// covering the picture, nor where it shows circuit 1's very rectangle.
class procedure TPS2GS.CircuitsRead(const D: TPS2GSDisplay; out Read1, Read2: Boolean);
begin
  var En1 := (D.PMODE and 1) <> 0;
  var En2 := (D.PMODE and 2) <> 0;
  Read1 := En1;
  Read2 := False;
  if not En2 then
    Exit;
  var W1, H1, X1, Y1, M1, W2, H2, X2, Y2, M2: Integer;
  W1 := 0;
  H1 := 0;
  X1 := 0;
  Y1 := 0;
  M1 := 1;
  if En1 then
    CircuitSize(D, 1, W1, H1, X1, Y1, M1);
  CircuitSize(D, 2, W2, H2, X2, Y2, M2);
  var W := Max(W1, W2);
  var H := Max(H1, H2);
  var OX1 := 0;
  var OY1 := 0;
  if En1 then
  begin
    var MinX := Min(X1 div M1, X2 div M2);
    var MinY := Min(Y1, Y2);
    OX1 := X1 div M1 - MinX;
    OY1 := Y1 - MinY;
  end;
  var AlphaFixed := (D.PMODE and $20) <> 0;
  var ALP := Integer((D.PMODE shr 8) and $FF);
  var FrontPSM := Integer((D.DISPFB1 shr 15) and $1F);
  var OpaqueFront := En1 and (OX1 = 0) and (OY1 = 0) and (W1 = W) and (H1 = H) and
    ((AlphaFixed and (ALP >= 128)) or (not AlphaFixed and (FrontPSM in [PSMCT32, PSMCT24])));
  Read2 := not OpaqueFront and not (En1 and (D.DISPFB1 = D.DISPFB2) and (W1 = W2) and (H1 = H2));
end;

procedure TPS2GS.BuildFrame;
begin
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
  var D: TPS2GSDisplay;
  D.PMODE := PMODE;
  D.SMODE2 := SMODE2;
  D.DISPFB1 := DISPFB1;
  D.DISPLAY1 := DISPLAY1;
  D.DISPFB2 := DISPFB2;
  D.DISPLAY2 := DISPLAY2;
  D.BGCOLOR := BGCOLOR;
  D.Interlaced := Interlaced;
  // The pages of the circuits read.
  var Pages: TPS2GSPages;
  FillChar(Pages, SizeOf(Pages), 0);
  var Read1, Read2: Boolean;
  CircuitsRead(D, Read1, Read2);
  if Read1 then
    CircuitPages(D, 1, Pages);
  if Read2 then
    CircuitPages(D, 2, Pages);
  Inc(FFramesQueued);
  var Number := FrameNumber;
  // No GS worker: the picture now, here. (After pictures still being built
  // from snapshots.)
  if not FRaster.Async then
  begin
    if FComposer <> nil then
      FComposer.Finish;
    Compose(D, FRaster.MemoryFor(Pages), Number);
    Exit;
  end;
  if FComposer = nil then
    FComposer := TPS2GSComposer.Create(Self);
  var Composer := FComposer;
  // The pages drawn already: copied here (the worker, often the busier,
  // goes on); else by the worker once it has drawn them.
  if (TInterlocked.Read(FWorkerCopied) = FWorkerFrames) and FRaster.PagesDrawn(Pages) then
  begin
    Composer.Post(D, Pages, FRaster.MemoryFor(Pages), Number);
    Exit;
  end;
  Inc(FWorkerFrames);
  FRaster.QueueRead(Pages,
    procedure(Memory: TPS2GSMemory)
    begin
      Composer.Post(D, Pages, Memory, Number);
      TInterlocked.Increment(FWorkerCopied);
    end);
end;

procedure TPS2GS.Compose(const D: TPS2GSDisplay; Memory: TPS2GSMemory; Number: Int64);
var
  Pixels: TArray<Cardinal>;
begin
  // Circuit 2 (background) then circuit 1, blended per PMODE.
  var PMODE := D.PMODE;
  var En1 := (PMODE and 1) <> 0;
  var En2 := (PMODE and 2) <> 0;
  var W := FFrameWidth;
  var H := FFrameHeight;
  if not En1 and not En2 then
    // (Black, the size as it was.)
    SetLength(Pixels, W * H)
  else
  begin
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
      CircuitSize(D, 1, W1, H1, X1, Y1, M1);
    if En2 then
      CircuitSize(D, 2, W2, H2, X2, Y2, M2);
    W := Max(W1, W2);
    H := Max(H1, H2);
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
    // An opaque foreground covering the entire output cannot expose circuit
    // 2 or the background. 32/24-bit ReadPixel always returns opaque alpha;
    // 16-bit and unknown formats still require the fixed-alpha proof.
    var FrontPSM := Integer((D.DISPFB1 shr 15) and $1F);
    var OpaqueFront := En1 and (OX1 = 0) and (OY1 = 0) and (W1 = W) and (H1 = H) and
      ((AlphaFixed and (ALP >= 128)) or (not AlphaFixed and (FrontPSM in [PSMCT32, PSMCT24])));
    if En1 then ReadCircuit(D, Memory, 1, W1, H1, P1);
    if En2 and not OpaqueFront then
      // Identical source rectangles remain identical even when the circuits
      // have different output offsets or magnification.
      if En1 and (D.DISPFB1 = D.DISPFB2) and (W1 = W2) and (H1 = H2) then
        P2 := P1
      else
        ReadCircuit(D, Memory, 2, W2, H2, P2);
    SetLength(Pixels, W * H);
    if OpaqueFront then
      for var I := 0 to Length(Pixels) - 1 do
      begin
        var Color := P1[I];
        Pixels[I] := $FF000000 or ((Color and $FF) shl 16) or (Color and $FF00) or ((Color shr 16) and $FF);
      end
    else
    begin
      var BG := Cardinal(D.BGCOLOR and $FFFFFF);
      var BGPixel := $FF000000 or ((BG and $FF) shl 16) or (BG and $FF00) or ((BG shr 16) and $FF);
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
          Pixels[Y * W + X] := $FF000000 or ((Out and $FF) shl 16) or (Out and $FF00) or ((Out shr 16) and $FF);
        end;
    end;
  end;
  FFrame := Pixels;
  FFrameWidth := W;
  FFrameHeight := H;
  // (After the picture: the emulation thread reads it once it sees this.)
  TInterlocked.Exchange(FFramesBuilt, FFramesBuilt + 1);
  if Assigned(FOnFrame) then
    FOnFrame(Pixels, W, H, Number);
end;

procedure TPS2GS.SyncFrame;
begin
  if TInterlocked.Read(FFramesBuilt) = FFramesQueued then
    Exit;
  if TInterlocked.Read(FWorkerCopied) <> FWorkerFrames then
    FRaster.FinishReads;
  if FComposer <> nil then
    FComposer.Finish;
end;

{ TPS2GSComposer }

constructor TPS2GSComposer.Create(GS: TPS2GS);
begin
  FGS := GS;
  FSnapshots[0] := TPS2GSMemory.Create;
  FSnapshots[1] := TPS2GSMemory.Create;
  FWork := TEvent.Create(nil, False, False, '');
  FFinished := TEvent.Create(nil, False, False, '');
  inherited Create(False);
  {$IFDEF MSWINDOWS}
  // (The emulation threads first: a picture may be shown a little later.)
  Priority := tpLower;
  {$ENDIF}
end;

destructor TPS2GSComposer.Destroy;
begin
  Terminate;
  FWork.SetEvent;
  inherited;
  FWork.Free;
  FFinished.Free;
  FSnapshots[0].Free;
  FSnapshots[1].Free;
end;

procedure TPS2GSComposer.Post(const Display: TPS2GSDisplay; const Pages: TPS2GSPages; Memory: TPS2GSMemory;
  Number: Int64);
begin
  // (The snapshot this one takes was the one before last's: done by now,
  // nearly always.)
  while FPosted - TInterlocked.Read(FDone) >= 2 do
    FFinished.WaitFor(1);
  CheckFailure;
  var K := Integer(FPosted and 1);
  var Source := Memory.Data;
  var Target := FSnapshots[K].Data;
  for var P := 0 to 511 do
    if (Pages[P shr 5] and (Cardinal(1) shl (P and 31))) <> 0 then
      Move(Source[P * 8192], Target[P * 8192], 8192);
  FJobs[K].Display := Display;
  FJobs[K].Number := Number;
  TInterlocked.Increment(FPosted);
  FWork.SetEvent;
end;

procedure TPS2GSComposer.Finish;
begin
  while TInterlocked.Read(FDone) < TInterlocked.Read(FPosted) do
    FFinished.WaitFor(1);
  CheckFailure;
end;

procedure TPS2GSComposer.CheckFailure;
begin
  if TInterlocked.CompareExchange(FFailed, 0, 0) = 1 then
    raise Exception.Create('GS composer thread: ' + FFailure);
end;

procedure TPS2GSComposer.Execute;
begin
  while True do
  begin
    while not Terminated and (TInterlocked.Read(FDone) >= TInterlocked.Read(FPosted)) do
      FWork.WaitFor(INFINITE);
    if Terminated then
      Break;
    var K := Integer(FDone and 1);
    try
      FGS.Compose(FJobs[K].Display, FSnapshots[K], FJobs[K].Number);
    except
      on E: Exception do
        if TInterlocked.CompareExchange(FFailed, 2, 0) = 0 then
        begin
          FFailure := E.Message;
          TInterlocked.Exchange(FFailed, 1);
        end;
    end;
    TInterlocked.Increment(FDone);
    FFinished.SetEvent;
  end;
end;

function TPS2GS.GetFrame: TArray<Cardinal>;
begin
  SyncFrame;
  Result := FFrame;
end;

function TPS2GS.GetFrameWidth: Integer;
begin
  SyncFrame;
  Result := FFrameWidth;
end;

function TPS2GS.GetFrameHeight: Integer;
begin
  SyncFrame;
  Result := FFrameHeight;
end;

procedure TPS2GS.SerializeState(State: TStateArchive);
begin
  if Assigned(FBeforeAccess) then
    FBeforeAccess;
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
