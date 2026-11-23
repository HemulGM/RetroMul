unit GBA.NativeClock;

// Exact event-free clock updates for Android ARM64. All guards run before
// any state is written. Event boundaries and unsupported states return to
// TGBAConsole.Tick; devices retain their existing clock and sample timing.
interface

uses
  HW.JIT;

type
  TGBANativeQuietLayout = record
    QuietCycles, InDMA, CPUResuming, CPUYieldIdle, Halted: Integer;
    Cartridge, Hardware, IRQPending, TickRequired: Integer;
    Sound, SoundPending, SoundEvent: Integer;
    GamePakBusy, PrefetchValid, MasterClock: Integer;
    Video, WaitPort, WaitControl, WaitSequential: Integer;
    PrefetchNext, PrefetchPhase, PrefetchCount: Integer;
    TimerMask, TimerEvent, TimerPending, LineCycle, VideoPending: Integer;
  end;

  TGBANativeQuietFunction = function(Console: Pointer; Cycles, Aux1, Aux2: NativeUInt): NativeInt;

  TGBANativeQuiet = class
  private
    FJit: TJitAsm;
    FCode: Pointer;
    FLayout: TGBANativeQuietLayout;
  public
    constructor Create(const Layout: TGBANativeQuietLayout);
    destructor Destroy; override;
    {$IFDEF RETROMUL_GBA_NATIVE_QUIET_TEST}
    function SelfTest: string;
    {$ENDIF}
    function TryTick(Console: Pointer; Cycles: Integer): Boolean; inline;
  end;

var
  NativeQuietHits: UInt64;

function EmitNativeQuiet(J: TJitAsm; const L: TGBANativeQuietLayout): Pointer;

implementation

{$IFDEF RETROMUL_GBA_NATIVE_QUIET_TEST}

uses
  GBA.NativeQuietChecks;

function TGBANativeQuiet.SelfTest: string;
begin
  Result := CheckNativeQuiet(FLayout);
end;
{$ENDIF}

function EmitNativeQuiet(J: TJitAsm; const L: TGBANativeQuietLayout): Pointer;
{$IFDEF CPU64BITS}
const
  PointerWidth = jw64;
{$ELSE}
const
  PointerWidth = jw32;
{$ENDIF}
begin
  J.Reset;
  Result := J.Here;
  J.Enter;
  var Fail := J.NewLabel;
  var NoOverlap := J.NewLabel;
  var NoPrefetch := J.NewLabel;
  var NoTimer := J.NewLabel;
  var PrefetchLoop := J.NewLabel;
  var PrefetchDone := J.NewLabel;
  var PrefetchFull := J.NewLabel;
  var PrefetchCommitDone := J.NewLabel;
  J.Branch(jcLe, jw32, JCtx, JImm(0), Fail);
  J.Branch(jcGe, jw32, JCtx, JMem(jrSelf, L.QuietCycles), Fail);
  J.Move(PointerWidth, JT0, JMem(jrSelf, L.Cartridge));
  J.Branch(jcNe, jw8, JMem(jrT0, L.TickRequired), JImm(0), Fail);
  J.Move(PointerWidth, JT1, JMem(jrT0, L.Hardware));
  J.Branch(jcNe, jw8, JMem(jrT1, L.IRQPending), JImm(0), Fail);
  J.Branch(jcEq, jw8, JMem(jrSelf, L.InDMA), JImm(0), NoOverlap);
  J.Branch(jcEq, jw8, JMem(jrSelf, L.CPUResuming), JImm(0), NoOverlap);
  J.Branch(jcEq, jw8, JMem(jrSelf, L.CPUYieldIdle), JImm(0), NoOverlap);
  J.Branch(jcEq, jw8, JMem(jrSelf, L.Halted), JImm(0), Fail);
  J.Bind(NoOverlap);
  J.Move(PointerWidth, JT0, JMem(jrSelf, L.Sound));
  J.Branch(jcGe, jw32, JCtx, JMem(jrT0, L.SoundEvent), Fail);
  // Do not bypass checked overflow semantics for an artificial near-wrap clock.
  J.Move(jw64, JT2, JMem(jrSelf, L.MasterClock));
  J.Move(jw64, JT3, JT2);
  J.Alu(jaAdd, jw64, JT3, JCtx);
  J.Branch(jcBelow, jw64, JT3, JT2, Fail);
  // Reproduce PrefetchTick only when its cached WAITCNT decode is current.
  // Otherwise the normal code must perform DecodeWaitControl itself.
  J.Move(jw32, JS0, JImm(0));
  J.Branch(jcEq, jw8, JMem(jrSelf, L.PrefetchValid), JImm(0), NoPrefetch);
  J.Branch(jcNe, jw8, JMem(jrSelf, L.GamePakBusy), JImm(0), NoPrefetch);
  J.Move(PointerWidth, JT1, JMem(jrSelf, L.Video));
  J.Move(jw8, JT2, JMem(jrT1, L.WaitPort));
  J.Move(jw8, JT4, JMem(jrT1, L.WaitPort + 1));
  J.Shift(jsShl, jw32, jrT4, 8);
  J.Alu(jaOr, jw32, JT2, JT4);
  J.Branch(jcNe, jw32, JT2, JMem(jrSelf, L.WaitControl), Fail);
  J.BranchTest(jcEq, jw32, JT2, JImm($4000), NoPrefetch);
  J.Move(jw32, JS3, JMem(jrSelf, L.PrefetchNext));
  J.Move(jw32, JT2, JS3);
  J.Shift(jsShr, jw32, jrT2, 24);
  J.Alu(jaSub, jw32, JT2, JImm(8));
  J.Shift(jsShr, jw32, jrT2, 1);
  J.Branch(jcAbove, jw32, JT2, JImm(2), Fail);
  J.Shift(jsShl, jw32, jrT2, 2);
  J.Alu(jaAdd, PointerWidth, JT2, JSelf);
  J.Move(jw32, JT2, JMem(jrT2, L.WaitSequential));
  J.Move(jw32, JS1, JMem(jrSelf, L.PrefetchPhase));
  J.Alu(jaAdd, jw32, JS1, JCtx);
  J.Move(jw32, JS2, JMem(jrSelf, L.PrefetchCount));
  J.Bind(PrefetchLoop);
  J.Branch(jcGe, jw32, JS2, JImm(8), PrefetchDone);
  J.Branch(jcLt, jw32, JS1, JT2, PrefetchDone);
  J.Alu(jaSub, jw32, JS1, JT2);
  J.Alu(jaAdd, jw32, JS2, JImm(1));
  J.Alu(jaAdd, jw32, JS3, JImm(2));
  J.BranchTest(jcNe, jw32, JS3, JImm($1FFFF), PrefetchLoop);
  J.Move(jw32, JS1, JImm(0));
  J.Bind(PrefetchDone);
  J.Branch(jcNe, jw32, JS2, JImm(8), PrefetchFull);
  J.Move(jw32, JS1, JImm(0));
  J.Bind(PrefetchFull);
  J.Move(jw32, JS0, JImm(1));
  J.Bind(NoPrefetch);
  // No side effects precede the final guard. A rejected attempt is a no-op.
  J.Alu(jaSub, jw32, JMem(jrSelf, L.QuietCycles), JCtx);
  J.Alu(jaAdd, jw32, JMem(jrT0, L.SoundPending), JCtx);
  J.Alu(jaSub, jw32, JMem(jrT0, L.SoundEvent), JCtx);
  J.Move(jw64, JMem(jrSelf, L.MasterClock), JT3);
  J.Branch(jcEq, jw32, JS0, JImm(0), PrefetchCommitDone);
  J.Move(jw32, JMem(jrSelf, L.PrefetchPhase), JS1);
  J.Move(jw32, JMem(jrSelf, L.PrefetchCount), JS2);
  J.Move(jw32, JMem(jrSelf, L.PrefetchNext), JS3);
  J.Bind(PrefetchCommitDone);
  J.Branch(jcEq, jw8, JMem(jrSelf, L.TimerMask), JImm(0), NoTimer);
  J.Alu(jaSub, jw32, JMem(jrSelf, L.TimerEvent), JCtx);
  J.Alu(jaAdd, jw32, JMem(jrSelf, L.TimerPending), JCtx);
  J.Bind(NoTimer);
  J.Alu(jaAdd, jw32, JMem(jrSelf, L.LineCycle), JCtx);
  J.Alu(jaAdd, jw32, JMem(jrSelf, L.VideoPending), JCtx);
  J.Leave(JImm(1));
  J.Bind(Fail);
  J.Leave(JImm(0));
  J.Flush;
end;

constructor TGBANativeQuiet.Create(const Layout: TGBANativeQuietLayout);
begin
  inherited Create;
  FLayout := Layout;
  {$IF Defined(ANDROID) and Defined(RETROMUL_GBA_NATIVE_QUIET_TEST)}
  RequestedQuietTest(Layout);
  {$ENDIF}
  FJit := CreateJitLeafAsm(65536);
  if FJit <> nil then
    FCode := EmitNativeQuiet(FJit, Layout);
end;

destructor TGBANativeQuiet.Destroy;
begin
  FJit.Free;
  inherited;
end;

function TGBANativeQuiet.TryTick(Console: Pointer; Cycles: Integer): Boolean;
begin
  Result := (FCode <> nil) and
    (TGBANativeQuietFunction(FCode)(Console, NativeUInt(Cardinal(Cycles)), 0, 0) <> 0);
  {$IFDEF RETROMUL_VERIFY_QUIET_CACHE}
  if Result then
    Inc(NativeQuietHits);
  {$ENDIF}
end;

end.

