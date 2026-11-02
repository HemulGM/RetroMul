unit PSP.Display;

// sceDisplay and sceCtrl. A field is 286 lines at 59.94 Hz. The vblank
// interrupt comes at the end of line 285: hcount wraps to 0, vcount steps and
// the vblank flag is on for the next ~818 us. The kernel's own interrupt code
// holds the CPU for ~60 us (handlers run ~29 us in); threads waiting for
// vblank get the CPU ~20 us after it lets go, one by one ~12 us
// apart. The controller is sampled just after vblank ends (or every sampling
// cycle when one is set).
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  System.SysUtils, System.Generics.Collections, System.UITypes,
  Core.Emulation.Types, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.State.Action;

const
  PSPLineNs = PSPFrameNs div PSPLinesPerFrame;
  PSPVBlankNs = 818000;
  PSPVSyncNs = 631500;
  PSPIntrHandlerNs = 29000;
  PSPIntrTailNs = 26000;
  PSPIntrHandlerExtraNs = 10000;
  PSPWakeLatencyNs = 20000;
  PSPWakeStepNs = 12000;
  PSPCtrlSampleNs = 830000;

type
  TPSPFrameBuffer = record
    Address, Width, Format: Cardinal;
  end;

  TPSPCtrlSample = record
    Time, Buttons: Cardinal;
    LX, LY: Byte;
  end;

  TPSPDisplayPhase = (dpInterrupt, dpHandlers, dpWake, dpSample, dpNextField);

  TPSPDisplay = class
  private
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FMemory: TPSPMemory;
    FScheduler: TPSPScheduler;
    FCurrentAddr, FLatchedAddr: Cardinal;
    FWidth, FFormat: Cardinal;
    FHasPending: Boolean;
    FFieldStart: Int64;
    FHcountOrigin: Int64;
    FHcountAdjust: Int64;
    FVCount: Cardinal;
    FPhase: TPSPDisplayPhase;
    FWaiters: TList<TPSPThread>;
    FReleaseQueue: TList<TPSPThread>;
    FMode, FModeWidth, FModeHeight: Cardinal;
    FFrameDone: Boolean;
    FHandlersRan: Boolean;
    FWakeAt, FSampleAt: Int64;
    // Controller
    FInput: Cardinal;
    FAnalogX, FAnalogY: Byte;
    FSamples: array[0..63] of TPSPCtrlSample;
    FSampleHead: Integer;
    FSampleIndex, FReadIndex: Int64;
    FSamplingMode, FSamplingCycle: Cardinal;
    FCycleTimer: Int64;
    FLatchMake, FLatchBreak, FLatchPress, FLatchRelease, FLastButtons: Cardinal;
    FLatchCount: Integer;
    FCtrlWaiters: TList<TPSPThread>;
    FIdleReset, FIdleBack: Integer;
    procedure SchedulePhase(Phase: TPSPDisplayPhase; At: Int64);
    procedure Interrupt;
    procedure InterruptDone;
    procedure ReleaseNext;
    function InVBlankNow: Boolean;
    function VBlankRetry(T: TPSPThread): Boolean;
    procedure VBlankAbort(T: TPSPThread);
    procedure WaitFields(Count: Integer; AllowCB: Boolean);
    procedure SampleController;
    procedure StartCycleTimer;
    procedure StateCycle(Action: TPSPStateAction; Value: Cardinal);
    procedure StateInterruptDone(Action: TPSPStateAction; Value: Cardinal);
    function CtrlRetry(T: TPSPThread): Boolean;
    procedure CtrlAbort(T: TPSPThread);
    procedure ReadSamples(Address: Cardinal; Count: Integer; Negative: Boolean; FromIndex: Int64);
    procedure ReadBufferCommon(Negative: Boolean);
    procedure PeekBufferCommon(Negative: Boolean);
    function ValidPointer(Address: Cardinal): Boolean;
    procedure hSetMode;
    procedure hGetMode;
    procedure hSetFrameBuf;
    procedure hGetFrameBuf;
    procedure hWaitVblankStart;
    procedure hWaitVblankStartCB;
    procedure hWaitVblank;
    procedure hWaitVblankCB;
    procedure hWaitVblankStartMulti;
    procedure hWaitVblankStartMultiCB;
    procedure hGetVcount;
    procedure hIsVblank;
    procedure hIsVsync;
    procedure hGetCurrentHcount;
    procedure hGetAccumulatedHcount;
    procedure hAdjustAccumulatedHcount;
    procedure hGetVblankRest;
    procedure hGetFramePerSec;
    procedure hIsForeground;
    procedure hSetHoldMode;
    procedure hSetResumeMode;
    procedure hGetResumeMode;
    procedure hGetBrightness;
    procedure hCtrlSetSamplingCycle;
    procedure hCtrlGetSamplingCycle;
    procedure hCtrlSetSamplingMode;
    procedure hCtrlGetSamplingMode;
    procedure hCtrlPeekBufferPositive;
    procedure hCtrlPeekBufferNegative;
    procedure hCtrlReadBufferPositive;
    procedure hCtrlReadBufferNegative;
    procedure hCtrlPeekLatch;
    procedure hCtrlReadLatch;
    procedure hCtrlSetIdleCancelThreshold;
    procedure hCtrlGetIdleCancelThreshold;
    procedure hCtrlZero;
  public
    constructor Create(Kernel: TPSPKernel);
    destructor Destroy; override;
    procedure Reset;
    procedure Register;
    procedure OnEvent;
    procedure SetInput(const Input: TEmulatorInput);
    // Converts the shown framebuffer to ARGB pixels.
    procedure Render(var Frame: TEmulatorFrame);
    // The 512x272 32-bit BMP the test programs write on hardware: every
    // framebuffer row of 512 pixels, bottom-up, alpha kept.
    function ScreenshotBMP: TBytes;
    function Hcount: Integer;
    property CurrentAddress: Cardinal read FCurrentAddr;
    property Width: Cardinal read FWidth;
    property Format: Cardinal read FFormat;
    property VCount: Cardinal read FVCount;
    // The buttons of the controller's latest sample (what a read returns now).
    property SampledButtons: Cardinal read FLastButtons;
    property FrameDone: Boolean read FFrameDone write FFrameDone;
    property InVBlank: Boolean read InVBlankNow;
  end;

implementation

uses
  System.Math;

const
  ButtonBits: array[TEmulatorButton] of Cardinal = ($10, $40, $80, $20, $4000, $2000, $1, $8, $100, $8000,
    $1000, $200, 0);

constructor TPSPDisplay.Create(Kernel: TPSPKernel);
begin
  inherited Create;
  FKernel := Kernel;
  FHLE := Kernel.HLE;
  FMemory := Kernel.Memory;
  FScheduler := Kernel.Scheduler;
  FWaiters := TList<TPSPThread>.Create;
  FReleaseQueue := TList<TPSPThread>.Create;
  FCtrlWaiters := TList<TPSPThread>.Create;
end;

destructor TPSPDisplay.Destroy;
begin
  FWaiters.Free;
  FReleaseQueue.Free;
  FCtrlWaiters.Free;
  inherited;
end;

procedure TPSPDisplay.Reset;
begin
  FCurrentAddr := 0;
  FLatchedAddr := 0;
  FWidth := 512;
  FFormat := 3;
  FHasPending := False;
  FVCount := 0;
  FWaiters.Clear;
  FReleaseQueue.Clear;
  FCtrlWaiters.Clear;
  FMode := 0;
  FModeWidth := 480;
  FModeHeight := 272;
  FFrameDone := False;
  // Power-on was long ago: the next field starts a little after boot.
  FFieldStart := FScheduler.Now + 4000000 - PSPFrameNs;
  FHcountOrigin := FFieldStart;
  FHcountAdjust := 0;
  // The driver has been sampling since power-on.
  FillChar(FSamples, SizeOf(FSamples), 0);
  for var I := 0 to High(FSamples) do
  begin
    var At := FFieldStart - Int64(High(FSamples) - I) * PSPFrameNs + PSPCtrlSampleNs;
    if At > 0 then
      FSamples[I].Time := Cardinal(At div 1000);
    FSamples[I].LX := 128;
    FSamples[I].LY := 128;
  end;
  FSampleHead := 0;
  FSampleIndex := Length(FSamples);
  FReadIndex := FSampleIndex - 1;
  FSamplingMode := 0;
  FSamplingCycle := 0;
  FCycleTimer := 0;
  FLatchMake := 0;
  FLatchBreak := 0;
  FLatchPress := 0;
  FLatchRelease := $FFFFFFFF;
  FLatchCount := 1;
  FLastButtons := 0;
  FInput := 0;
  FAnalogX := 128;
  FAnalogY := 128;
  FIdleReset := -1;
  FIdleBack := -1;
  SchedulePhase(dpInterrupt, FFieldStart + PSPFrameNs);
end;

procedure TPSPDisplay.SchedulePhase(Phase: TPSPDisplayPhase; At: Int64);
begin
  FPhase := Phase;
  FScheduler.Schedule(TPSPEvent.VBlank, At);
end;

function TPSPDisplay.InVBlankNow: Boolean;
begin
  Result := FScheduler.Now - FFieldStart < PSPVBlankNs;
end;

function TPSPDisplay.Hcount: Integer;
begin
  Result := Integer(((FScheduler.Now - FFieldStart) * PSPLinesPerFrame div PSPFrameNs) mod PSPLinesPerFrame);
end;

procedure TPSPDisplay.OnEvent;
begin
  case FPhase of
    dpInterrupt:
      Interrupt;
    dpHandlers:
      begin
        var N := FKernel.QueueSubInterrupts(PSPInterruptVBlank, 0, nil,
          TPSPStateAction.Create(StateInterruptDone, [], []));
        if N = 0 then
          InterruptDone;
      end;
    dpWake:
      ReleaseNext;
    dpSample:
      begin
        if FSamplingCycle = 0 then
          SampleController;
        SchedulePhase(dpInterrupt, FFieldStart + PSPFrameNs);
      end;
    dpNextField:
      SchedulePhase(dpInterrupt, FFieldStart + PSPFrameNs);
  end;
end;

procedure TPSPDisplay.Interrupt;
begin
  // The scan clock does not restart when the CPU notices the interrupt late.
  // Anchor the next field to the previous hardware edge, not syscall latency.
  Inc(FFieldStart, PSPFrameNs);
  Inc(FVCount);
  if FKernel.Trace then
    FHLE.Log('%d vblank interrupt %d', [FScheduler.Now div 1000, FVCount]);
  if FHasPending then
  begin
    FCurrentAddr := FLatchedAddr;
    FHasPending := False;
  end;
  FFrameDone := True;
  FHandlersRan := False;
  FKernel.BusyUntil := FScheduler.Now + PSPIntrHandlerNs;
  SchedulePhase(dpHandlers, FScheduler.Now + PSPIntrHandlerNs);
end;

procedure TPSPDisplay.InterruptDone;
begin
  var Tail: Int64 := PSPIntrTailNs;
  if FHandlersRan then
    Inc(Tail, PSPIntrHandlerExtraNs);
  FKernel.BusyUntil := FScheduler.Now + Tail;
  FReleaseQueue.Clear;
  // Better threads first, otherwise in the order they began to wait.
  for var T in FWaiters do
  begin
    var I := FReleaseQueue.Count;
    while (I > 0) and (FReleaseQueue[I - 1].Priority > T.Priority) do
      Dec(I);
    FReleaseQueue.Insert(I, T);
  end;
  FWakeAt := FKernel.BusyUntil + PSPWakeLatencyNs;
  SchedulePhase(dpWake, FWakeAt);
end;

procedure TPSPDisplay.StateInterruptDone(Action: TPSPStateAction; Value: Cardinal);
begin
  FHandlersRan := True;
  InterruptDone;
end;

procedure TPSPDisplay.ReleaseNext;
begin
  // Waiters that were counted at this vblank are released one at a time.
  while FReleaseQueue.Count > 0 do
  begin
    var T := FReleaseQueue[0];
    FReleaseQueue.Delete(0);
    if not FWaiters.Contains(T) then
      Continue;
    if not (T.IsWaiting and (T.Wait.HLETag = 'vblank')) then
    begin
      FWaiters.Remove(T);
      Continue;
    end;
    if T.Wait.Data[1] > 1 then
    begin
      // Still more fields to wait for.
      Dec(T.Wait.Data[1]);
      Continue;
    end;
    FWaiters.Remove(T);
    FKernel.EndWait(T, 0);
    if FReleaseQueue.Count > 0 then
    begin
      SchedulePhase(dpWake, FScheduler.Now + PSPWakeStepNs);
      Exit;
    end;
  end;
  FSampleAt := FFieldStart + PSPCtrlSampleNs;
  if FScheduler.Now < FSampleAt then
    SchedulePhase(dpSample, FSampleAt)
  else
  begin
    if FSamplingCycle = 0 then
      SampleController;
    SchedulePhase(dpInterrupt, FFieldStart + PSPFrameNs);
  end;
end;

function TPSPDisplay.VBlankRetry(T: TPSPThread): Boolean;
begin
  Result := False;
  if not FWaiters.Contains(T) then
    FWaiters.Add(T);
end;

procedure TPSPDisplay.VBlankAbort(T: TPSPThread);
begin
  FWaiters.Remove(T);
  FReleaseQueue.Remove(T);
end;

procedure TPSPDisplay.WaitFields(Count: Integer; AllowCB: Boolean);
begin
  FHLE.Result(0);
  if FKernel.RefuseWait then
    Exit;
  var T := FKernel.Current;
  FWaiters.Add(T);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, AllowCB, VBlankRetry, VBlankAbort, 'vblank');
  if T.Wait.HLETag = 'vblank' then
    T.Wait.Data[1] := Cardinal(Count)
  else if T.Frames.Count > 0 then
  begin
    var F := T.Frames.Last;
    F.SavedWait.Data[1] := Cardinal(Count);
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPDisplay.SetInput(const Input: TEmulatorInput);
begin
  var B: Cardinal := 0;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if Button in Input.Buttons then
      B := B or ButtonBits[Button];
  FInput := B;
  var X := 128;
  var Y := 128;
  if Input.Analog[0].Valid then
  begin
    X := EnsureRange((Integer(Input.Analog[0].X) + 32768) div 256, 0, 255);
    Y := EnsureRange((Integer(Input.Analog[0].Y) + 32768) div 256, 0, 255);
  end;
  FAnalogX := X;
  FAnalogY := Y;
end;

procedure TPSPDisplay.SampleController;
begin
  var S := Default(TPSPCtrlSample);
  S.Time := Cardinal(FScheduler.Now div 1000);
  S.Buttons := FInput;
  if FSamplingMode <> 0 then
  begin
    S.LX := FAnalogX;
    S.LY := FAnalogY;
  end
  else
  begin
    S.LX := 128;
    S.LY := 128;
  end;
  FLatchMake := FLatchMake or (FInput and not FLastButtons);
  FLatchBreak := FLatchBreak or (FLastButtons and not FInput);
  FLatchPress := FLatchPress or FInput;
  FLatchRelease := FLatchRelease or not FInput;
  Inc(FLatchCount);
  FLastButtons := FInput;
  FSamples[FSampleHead] := S;
  FSampleHead := (FSampleHead + 1) mod Length(FSamples);
  Inc(FSampleIndex);
  while FCtrlWaiters.Count > 0 do
  begin
    var T := FCtrlWaiters[0];
    FCtrlWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'ctrl') then
    begin
      var Count := Min(Integer(T.Wait.Data[1]), Integer(FSampleIndex - FReadIndex));
      ReadSamples(T.Wait.Data[0], Count, T.Wait.Data[3] <> 0, FSampleIndex - Count);
      FReadIndex := FSampleIndex;
      FKernel.EndWait(T, Cardinal(Count));
    end;
  end;
end;

procedure TPSPDisplay.StartCycleTimer;
begin
  if FCycleTimer <> 0 then
  begin
    FKernel.CancelTimer(FCycleTimer);
    FCycleTimer := 0;
  end;
  if FSamplingCycle = 0 then
    Exit;
  FCycleTimer := FKernel.AddStateTimer(FScheduler.Now + Int64(FSamplingCycle) * 1000, Self,
    TPSPStateAction.Create(StateCycle, [], []));
end;

procedure TPSPDisplay.StateCycle(Action: TPSPStateAction; Value: Cardinal);
begin
  FCycleTimer := 0;
  SampleController;
  StartCycleTimer;
end;

procedure TPSPDisplay.ReadSamples(Address: Cardinal; Count: Integer; Negative: Boolean; FromIndex: Int64);
begin
  for var I := 0 to Count - 1 do
  begin
    var Age := Integer(FSampleIndex - (FromIndex + I));
    var Slot := (FSampleHead - Age + Length(FSamples) * 2) mod Length(FSamples);
    var S := FSamples[Slot];
    var A := Address + Cardinal(I) * 16;
    FMemory.Write32(A, S.Time);
    if Negative then
      FMemory.Write32(A + 4, not S.Buttons)
    else
      FMemory.Write32(A + 4, S.Buttons);
    FMemory.Write8(A + 8, S.LX);
    FMemory.Write8(A + 9, S.LY);
    FMemory.Fill(A + 10, 0, 6);
  end;
end;

function TPSPDisplay.CtrlRetry(T: TPSPThread): Boolean;
begin
  Result := FSampleIndex > FReadIndex;
  if Result then
  begin
    var Count := Min(Integer(T.Wait.Data[1]), Integer(FSampleIndex - FReadIndex));
    ReadSamples(T.Wait.Data[0], Count, T.Wait.Data[3] <> 0, FSampleIndex - Count);
    FReadIndex := FSampleIndex;
    T.SetResult(Cardinal(Count));
  end
  else if not FCtrlWaiters.Contains(T) then
    FCtrlWaiters.Add(T);
end;

procedure TPSPDisplay.CtrlAbort(T: TPSPThread);
begin
  FCtrlWaiters.Remove(T);
end;

// A 16-bit pixel as shown (format 0: 565, 1: 5551, else 4444): each channel
// widened to 8 bits, R in bits 16..23, B in 0..7, alpha opaque.
function DisplayColour16(Format, C: Cardinal): Cardinal;
var
  R, G, B: Cardinal;
begin
  case Format of
    0:
      begin
        R := C and $1F;
        G := (C shr 5) and $3F;
        B := (C shr 11) and $1F;
        R := (R shl 3) or (R shr 2);
        G := (G shl 2) or (G shr 4);
        B := (B shl 3) or (B shr 2);
      end;
    1:
      begin
        R := C and $1F;
        G := (C shr 5) and $1F;
        B := (C shr 10) and $1F;
        R := (R shl 3) or (R shr 2);
        G := (G shl 3) or (G shr 2);
        B := (B shl 3) or (B shr 2);
      end;
  else
    R := (C and $F) * 17;
    G := ((C shr 4) and $F) * 17;
    B := ((C shr 8) and $F) * 17;
  end;
  Result := $FF000000 or (R shl 16) or (G shl 8) or B;
end;

type
  TDisplayHalf = array[0..255] of Cardinal;

  PDisplayHalf = ^TDisplayHalf;

var
  // DisplayColour16(F, C) = GDisplayLo[F, C and $FF] or GDisplayHi[F, C shr 8]:
  // in every format the bits of the colour from either byte are apart (green
  // widened, in 565 G = A + 8B: (A shl 2) or (B shl 5) or (B shr 1)).
  GDisplayLo, GDisplayHi: array[0..2] of TDisplayHalf;

procedure InitDisplayColours;
begin
  for var F := 0 to 2 do
    for var I := 0 to 255 do
    begin
      GDisplayLo[F, I] := DisplayColour16(F, I);
      GDisplayHi[F, I] := DisplayColour16(F, Cardinal(I) shl 8);
    end;
end;

procedure TPSPDisplay.Render(var Frame: TEmulatorFrame);
begin
  Frame.Width := PSPFrameWidth;
  Frame.Height := PSPFrameHeight;
  if Length(Frame.Pixels) <> PSPFrameWidth * PSPFrameHeight then
    SetLength(Frame.Pixels, PSPFrameWidth * PSPFrameHeight);
  var Bpp: Cardinal := 2;
  if FFormat = 3 then
    Bpp := 4;
  for var Y := 0 to PSPFrameHeight - 1 do
  begin
    var Row: PByte := nil;
    if FCurrentAddr <> 0 then
      // Read only: drawn pages are brought back, watched ones need not be.
      Row := FMemory.ReadPtr(FCurrentAddr + Cardinal(Y) * FWidth * Bpp, PSPFrameWidth * Bpp);
    var Dest := PCardinal(@Frame.Pixels[Y * PSPFrameWidth]);
    if Row = nil then
    begin
      for var X := 0 to PSPFrameWidth - 1 do
        PCardinal(PByte(Dest) + X * 4)^ := $FF000000;
      Continue;
    end;
    // One loop a format (the colours as before: R in bits 16..23, B in 0..7).
    case FFormat of
      3:
        // Two pixels at a time: R and B swapped, alpha opaque.
        for var X := 0 to PSPFrameWidth div 2 - 1 do
        begin
          var C := PUInt64(Row + X * 8)^;
          PUInt64(PByte(Dest) + X * 8)^ := UInt64($FF000000FF000000) or ((C and UInt64($000000FF000000FF)) shl 16) or
            (C and UInt64($0000FF000000FF00)) or ((C shr 16) and UInt64($000000FF000000FF));
        end;
    else
      begin
        // DisplayColour16 by the pixel's low and high byte.
        var T := Min(FFormat, 2);
        var Lo: PDisplayHalf := @GDisplayLo[T];
        var Hi: PDisplayHalf := @GDisplayHi[T];
        for var X := 0 to PSPFrameWidth - 1 do
        begin
          var C := Cardinal(PWord(Row + X * 2)^);
          PCardinal(PByte(Dest) + X * 4)^ := Lo[C and $FF] or Hi[C shr 8];
        end;
      end;
    end;
  end;
end;

function TPSPDisplay.ScreenshotBMP: TBytes;
const
  Header: array[0..53] of Byte = ($42, $4D, $38, $80, $08, $00, $00, $00, $00, $00, $36, $00, $00, $00, $28, $00, $00,
    $00, $00, $02, $00, $00, $10, $01, $00, $00, $01, $00, $20, $00, $00, $00, $00, $00, $02, $80, $08, $00, $12, $0B,
    $00, $00, $12, $0B, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00);

  function E4(V: Cardinal): Cardinal; inline;
  begin
    Result := (V shl 4) or V;
  end;

  function E5(V: Cardinal): Cardinal; inline;
  begin
    Result := (V shl 3) or (V shr 2);
  end;

  function E6(V: Cardinal): Cardinal; inline;
  begin
    Result := (V shl 2) or (V shr 4);
  end;

begin
  SetLength(Result, 54 + 512 * 272 * 4);
  Move(Header, Result[0], 54);
  if (FCurrentAddr = 0) or (FWidth = 0) then
    Exit;
  var Bpp: Cardinal := 2;
  if FFormat = 3 then
    Bpp := 4;
  for var Y := 0 to 271 do
  begin
    var Row := FCurrentAddr + Bpp * FWidth * Cardinal(271 - Y);
    var Dst := PByte(@Result[54 + Y * 512 * 4]);
    for var X := 0 to 511 do
    begin
      var R, G, B, A: Cardinal;
      if Bpp = 4 then
      begin
        var C := FMemory.Read32(Row + Cardinal(X) * 4);
        R := C and $FF;
        G := (C shr 8) and $FF;
        B := (C shr 16) and $FF;
        A := C shr 24;
      end
      else
      begin
        var C := FMemory.Read16(Row + Cardinal(X) * 2);
        case FFormat of
          0:
            begin
              R := E5(C and $1F);
              G := E6((C shr 5) and $3F);
              B := E5((C shr 11) and $1F);
              A := $FF;
            end;
          1:
            begin
              R := E5(C and $1F);
              G := E5((C shr 5) and $1F);
              B := E5((C shr 10) and $1F);
              if (C and $8000) <> 0 then
                A := $FF
              else
                A := 0;
            end;
        else
          R := E4(C and $F);
          G := E4((C shr 4) and $F);
          B := E4((C shr 8) and $F);
          A := E4((C shr 12) and $F);
        end;
      end;
      PCardinal(Dst + X * 4)^ := B or (G shl 8) or (R shl 16) or (A shl 24);
    end;
  end;
end;

function TPSPDisplay.ValidPointer(Address: Cardinal): Boolean;
begin
  Result := (Address <> 0) and FMemory.Valid(Address, 4) and (Address < $80000000);
end;

{ HLE: display }

procedure TPSPDisplay.hSetMode;
begin
  var Mode := FHLE.Arg(0);
  var W := FHLE.Arg(1);
  var H := FHLE.Arg(2);
  if Mode <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if (W <> 480) or (H <> 272) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  FMode := Mode;
  FModeWidth := W;
  FModeHeight := H;
  // Changing the mode waits for the next vblank.
  if FKernel.CanWait then
    WaitFields(1, False)
  else
    FHLE.Result(0);
end;

procedure TPSPDisplay.hGetMode;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), FMode);
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), FModeWidth);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), FModeHeight);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hSetFrameBuf;
begin
  var Address := FHLE.Arg(0);
  var W := FHLE.Arg(1);
  var Fmt := FHLE.Arg(2);
  var Sync := FHLE.Arg(3);
  if Sync > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if Fmt > 3 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_FORMAT);
    Exit;
  end;
  if Address <> 0 then
  begin
    if (W = 0) or ((W and 63) <> 0) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
      Exit;
    end;
    var Physical := Address and $1FFFFFFF;
    var InVRAM := (Physical >= PSPVRAMBase) and (Physical < PSPVRAMBase + 4 * PSPVRAMSize);
    var InRAM := (Physical >= PSPRAMBase) and (Physical < PSPRAMBase + PSPRAMSize);
    if ((Address and 15) <> 0) or not (InVRAM or InRAM) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER);
      Exit;
    end;
  end;
  if Sync = 0 then
  begin
    // An immediate change keeps the format and stride.
    if (Address <> 0) and ((W <> FWidth) or (Fmt <> FFormat)) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
      Exit;
    end;
    if (Address = 0) and (W <> 0) and ((W <> FWidth) or (Fmt <> FFormat)) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
      Exit;
    end;
    if (Address = 0) and (W = 0) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
      Exit;
    end;
    FCurrentAddr := Address;
    FLatchedAddr := Address;
    FHasPending := False;
  end
  else
  begin
    FLatchedAddr := Address;
    FHasPending := True;
    FWidth := W;
    FFormat := Fmt;
  end;
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetFrameBuf;
begin
  var A := FCurrentAddr;
  if (FHLE.Arg(3) = 1) and FHasPending then
    A := FLatchedAddr;
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), A);
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), FWidth);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), FFormat);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hWaitVblankStart;
begin
  WaitFields(1, False);
end;

procedure TPSPDisplay.hWaitVblankStartCB;
begin
  WaitFields(1, True);
end;

procedure TPSPDisplay.hWaitVblank;
begin
  FKernel.NowUs;
  if InVBlankNow then
  begin
    FHLE.Result(1);
    Exit;
  end;
  WaitFields(1, False);
end;

procedure TPSPDisplay.hWaitVblankCB;
begin
  FKernel.NowUs;
  if InVBlankNow then
  begin
    FHLE.Result(1);
    FKernel.CheckCallbacks;
    Exit;
  end;
  WaitFields(1, True);
end;

procedure TPSPDisplay.hWaitVblankStartMulti;
begin
  if FHLE.ArgInt(0) <= 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  WaitFields(FHLE.ArgInt(0), False);
end;

procedure TPSPDisplay.hWaitVblankStartMultiCB;
begin
  if FHLE.ArgInt(0) <= 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  WaitFields(FHLE.ArgInt(0), True);
end;

procedure TPSPDisplay.hGetVcount;
begin
  FHLE.Result(FVCount);
end;

procedure TPSPDisplay.hIsVblank;
begin
  FKernel.NowUs;
  FHLE.Result(Ord(InVBlankNow));
end;

procedure TPSPDisplay.hIsVsync;
begin
  FKernel.NowUs;
  var T := FScheduler.Now - FFieldStart;
  FHLE.Result(Ord((T >= PSPVSyncNs) and (T < PSPVBlankNs)));
end;

procedure TPSPDisplay.hGetCurrentHcount;
begin
  FKernel.NowUs;
  FHLE.Result(Cardinal(Hcount));
end;

procedure TPSPDisplay.hGetAccumulatedHcount;
begin
  FKernel.NowUs;
  var Lines := (FScheduler.Now - FHcountOrigin) * PSPLinesPerFrame div PSPFrameNs + FHcountAdjust;
  FHLE.Result(Cardinal(Lines and $7FFFFFFF));
end;

procedure TPSPDisplay.hAdjustAccumulatedHcount;
begin
  var V := FHLE.ArgInt(0);
  if V < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  FKernel.NowUs;
  FHcountAdjust := Int64(V) - (FScheduler.Now - FHcountOrigin) * PSPLinesPerFrame div PSPFrameNs;
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetVblankRest;
begin
  FKernel.NowUs;
  var T := FScheduler.Now - FFieldStart;
  if T < PSPVBlankNs then
    FHLE.Result(0)
  else
    FHLE.Result(Cardinal((PSPFrameNs - T) div 1000));
end;

procedure TPSPDisplay.hGetFramePerSec;
begin
  FHLE.ResultFloat(59.9400599);
  FHLE.Result(FHLE.CPU.Ctx.FPR[0]);
end;

procedure TPSPDisplay.hIsForeground;
begin
  FHLE.Result(Ord(FCurrentAddr <> 0));
end;

procedure TPSPDisplay.hSetHoldMode;
begin
  FHLE.Result(0);
end;

procedure TPSPDisplay.hSetResumeMode;
begin
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetResumeMode;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), 0);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetBrightness;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), 84);
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), 0);
  FHLE.Result(0);
end;

{ HLE: controller }

procedure TPSPDisplay.hCtrlSetSamplingCycle;
begin
  var C := FHLE.Arg(0);
  if (C <> 0) and ((C < 5555) or (C > 20000)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  FHLE.Result(FSamplingCycle);
  FSamplingCycle := C;
  StartCycleTimer;
end;

procedure TPSPDisplay.hCtrlGetSamplingCycle;
begin
  if not ValidPointer(FHLE.Arg(0)) then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(0), FSamplingCycle);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlSetSamplingMode;
begin
  var M := FHLE.Arg(0);
  if M > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  FHLE.Result(FSamplingMode);
  FSamplingMode := M;
end;

procedure TPSPDisplay.hCtrlGetSamplingMode;
begin
  if not ValidPointer(FHLE.Arg(0)) then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(0), FSamplingMode);
  FHLE.Result(0);
end;

procedure TPSPDisplay.PeekBufferCommon(Negative: Boolean);
begin
  var N := FHLE.ArgInt(1);
  if (N < 0) or (N > 64) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  ReadSamples(FHLE.Arg(0), N, Negative, FSampleIndex - N);
  // Copying costs about 0.2 us a sample.
  FHLE.CPU.AddCycles(N * Integer(FScheduler.MHz) div 5);
  FHLE.Result(Cardinal(N));
end;

procedure TPSPDisplay.hCtrlPeekBufferPositive;
begin
  PeekBufferCommon(False);
end;

procedure TPSPDisplay.hCtrlPeekBufferNegative;
begin
  PeekBufferCommon(True);
end;

procedure TPSPDisplay.ReadBufferCommon(Negative: Boolean);
begin
  var Address := FHLE.Arg(0);
  var N := FHLE.ArgInt(1);
  if (N < 0) or (N > 64) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  if FKernel.RefuseWait then
    Exit;
  var Unread := FSampleIndex - FReadIndex;
  if (Unread > 0) or not FKernel.CanWait then
  begin
    var Count := Min(Int64(N), Unread);
    ReadSamples(Address, Count, Negative, FSampleIndex - Count);
    FReadIndex := FSampleIndex;
    FHLE.Result(Cardinal(Count));
    Exit;
  end;
  FCtrlWaiters.Add(FKernel.Current);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, CtrlRetry, CtrlAbort, 'ctrl');
  var T := FKernel.Current;
  T.Wait.Data[0] := Address;
  T.Wait.Data[1] := Cardinal(N);
  T.Wait.Data[3] := Ord(Negative);
end;

procedure TPSPDisplay.hCtrlReadBufferPositive;
begin
  ReadBufferCommon(False);
end;

procedure TPSPDisplay.hCtrlReadBufferNegative;
begin
  ReadBufferCommon(True);
end;

procedure TPSPDisplay.hCtrlPeekLatch;
begin
  var P := FHLE.Arg(0);
  if not ValidPointer(P) then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  FMemory.Write32(P, FLatchMake);
  FMemory.Write32(P + 4, FLatchBreak);
  FMemory.Write32(P + 8, FLatchPress);
  FMemory.Write32(P + 12, FLatchRelease);
  FHLE.Result(Cardinal(FLatchCount));
end;

procedure TPSPDisplay.hCtrlReadLatch;
begin
  hCtrlPeekLatch;
  if FHLE.CPU.Ctx.GPR[2] = $80000023 then
    Exit;
  FLatchMake := 0;
  FLatchBreak := 0;
  FLatchPress := 0;
  FLatchRelease := 0;
  FLatchCount := 0;
end;

procedure TPSPDisplay.hCtrlSetIdleCancelThreshold;
begin
  var R := FHLE.ArgInt(0);
  var B := FHLE.ArgInt(1);
  if (R < -1) or (R > 128) or (B < -1) or (B > 128) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  FIdleReset := R;
  FIdleBack := B;
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlGetIdleCancelThreshold;
begin
  var A := FHLE.Arg(0);
  var B := FHLE.Arg(1);
  if ((A <> 0) and not ValidPointer(A)) or ((B <> 0) and not ValidPointer(B)) then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  if A <> 0 then
    FMemory.Write32(A, Cardinal(FIdleReset));
  if B <> 0 then
    FMemory.Write32(B, Cardinal(FIdleBack));
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlZero;
begin
  FHLE.Result(0);
end;

procedure TPSPDisplay.Register;
const
  D = 'sceDisplay';
  C = 'sceCtrl';
begin
  var H := FHLE;
  H.Register(D, $0E20F177, 'sceDisplaySetMode', hSetMode);
  H.Register(D, $DEA197D4, 'sceDisplayGetMode', hGetMode);
  H.Register(D, $289D82FE, 'sceDisplaySetFrameBuf', hSetFrameBuf);
  H.Register(D, $EEDA2E54, 'sceDisplayGetFrameBuf', hGetFrameBuf);
  H.Register(D, $984C27E7, 'sceDisplayWaitVblankStart', hWaitVblankStart);
  H.Register(D, $46F186C3, 'sceDisplayWaitVblankStartCB', hWaitVblankStartCB);
  H.Register(D, $36CDFADE, 'sceDisplayWaitVblank', hWaitVblank);
  H.Register(D, $8EB9EC49, 'sceDisplayWaitVblankCB', hWaitVblankCB);
  H.Register(D, $40F1469C, 'sceDisplayWaitVblankStartMulti', hWaitVblankStartMulti);
  H.Register(D, $77ED8B3A, 'sceDisplayWaitVblankStartMultiCB', hWaitVblankStartMultiCB);
  H.Register(D, $9C6EAAD7, 'sceDisplayGetVcount', hGetVcount);
  H.Register(D, $4D4E10EC, 'sceDisplayIsVblank', hIsVblank);
  H.Register(D, $21038913, 'sceDisplayIsVsync', hIsVsync);
  H.Register(D, $773DD3A3, 'sceDisplayGetCurrentHcount', hGetCurrentHcount);
  H.Register(D, $210EAB3A, 'sceDisplayGetAccumulatedHcount', hGetAccumulatedHcount);
  H.Register(D, $A83EF139, 'sceDisplayAdjustAccumulatedHcount', hAdjustAccumulatedHcount);
  H.Register(D, $69B53541, 'sceDisplayGetVblankRest', hGetVblankRest);
  H.Register(D, $DBA6C4C4, 'sceDisplayGetFramePerSec', hGetFramePerSec);
  H.Register(D, $B4F378FA, 'sceDisplayIsForeground', hIsForeground);
  H.Register(D, $7ED59BC4, 'sceDisplaySetHoldMode', hSetHoldMode);
  H.Register(D, $A544C486, 'sceDisplaySetResumeMode', hSetResumeMode);
  H.Register(D, $BF79F646, 'sceDisplayGetResumeMode', hGetResumeMode);
  H.Register(D, $31C4BAA8, 'sceDisplayGetBrightness', hGetBrightness);
  H.Register(C, $6A2774F3, 'sceCtrlSetSamplingCycle', hCtrlSetSamplingCycle);
  H.Register(C, $02BAAD91, 'sceCtrlGetSamplingCycle', hCtrlGetSamplingCycle);
  H.Register(C, $1F4011E6, 'sceCtrlSetSamplingMode', hCtrlSetSamplingMode);
  H.Register(C, $DA6B76A1, 'sceCtrlGetSamplingMode', hCtrlGetSamplingMode);
  H.Register(C, $3A622550, 'sceCtrlPeekBufferPositive', hCtrlPeekBufferPositive);
  H.Register(C, $C152080A, 'sceCtrlPeekBufferNegative', hCtrlPeekBufferNegative);
  H.Register(C, $1F803938, 'sceCtrlReadBufferPositive', hCtrlReadBufferPositive);
  H.Register(C, $60B81F86, 'sceCtrlReadBufferNegative', hCtrlReadBufferNegative);
  H.Register(C, $B1D0E5CD, 'sceCtrlPeekLatch', hCtrlPeekLatch);
  H.Register(C, $0B588501, 'sceCtrlReadLatch', hCtrlReadLatch);
  H.Register(C, $A7144800, 'sceCtrlSetIdleCancelThreshold', hCtrlSetIdleCancelThreshold);
  H.Register(C, $687660FA, 'sceCtrlGetIdleCancelThreshold', hCtrlGetIdleCancelThreshold);
  H.Register(C, $348D99D4, 'sceCtrlSetSuspendingExtraSamples', hCtrlZero);
  H.Register(C, $AF5960F3, 'sceCtrlGetSuspendingExtraSamples', hCtrlZero);
  H.Register(C, $A68FD260, 'sceCtrlClearRapidFire', hCtrlZero);
  H.Register(C, $6841BE1A, 'sceCtrlSetRapidFire', hCtrlZero);
end;

initialization
  InitDisplayColours;

end.

