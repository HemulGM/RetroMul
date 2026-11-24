unit PS2.GIF;

// GS interface: GIF tags in PACKED, REGLIST and IMAGE modes for the three
// paths (PATH1 from VU1 XGKICK, PATH2 from VIF1 DIRECT, PATH3 from DMA
// channel 2 or the FIFO), each with its own tag state so that packets of
// different paths may alternate between whole packets; the GIF registers
// (CTRL, MODE, STAT, TAG0-3, CNT, P3CNT, P3TAG) and PATH3 masking. Masking
// takes effect between packets: once unmasked, PATH3 DMA moves to the end of
// a packet and only goes on after that packet's transfer time, so a mask set
// again right away (VIF1 MSKPATH3 1 after MSKPATH3 0) lets exactly one packet
// through, as programs that interleave texture uploads with drawing expect.
// The VU1 domain side (FrontTake) follows PATH3's tags only to decide how
// much PATH3 takes; the GS side (TransferHere, the kick thread) parses
// every path and writes the GS. What the domain gives the GS side is work
// with its time (Post), done in that order (CommitWork) at that time
// (CommitNow, the GS side's clock).
// References: EE User's Manual (GIF chapter), GS User's Manual, ps2tek.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils,
  System.Classes,
  Core.Snapshots,
  PS2.Types,
  PS2.EE.Bus,
  PS2.DMAC,
  PS2.GS,
  PS2.VU1Domain;

const
  // GS drawing speed for DMA timing: about four pixels per EE cycle (the GS
  // fills 8..16 per 147 MHz clock).
  GSPixelsPerCycle = 4;

type
  TPS2GIFPathState = record
    Tag: TPS2Reg128;
    Active: Boolean;
    NLoop, NReg, Flg, Reg, Loop: Integer;
    Regs: UInt64;
    Q: Cardinal;
    // REGLIST: the second 64 bits of a quadword are pending.
    EOP: Boolean;
  end;
  PPS2GIFPathState = ^TPS2GIFPathState;

  // Work the VU1 domain gives the GS side: a PATH1 packet, PATH2 quadwords
  // (one or a run), a path's quadwords, DMA channel 2's.
  TPS2GIFWorkKind = (gwKick, gwDirect, gwDirectRun, gwPath, gwPort, gwPortEnd);
  TPS2GIFWork = record
    Time, Start: Int64;
    Count, Path: Integer;
    // gwPortEnd: the channel's quadwords moved.
    Value: Integer;
    // The host control word the domain had (the GS rounds with it).
    Control: Cardinal;
    Kind: TPS2GIFWorkKind;
    FromDMA: Boolean;
    // Running ahead: where the quadwords are when not in the ring (a copy
    // kept while the domain runs ahead; nil: in the ring).
    External: PByte;
  end;

  // The GIF's part of the VU1 domain (PATH3 as the domain follows it), kept
  // to go back to.
  TPS2GIFSaved = record
    Front3: TPS2GIFPathState;
    MaskedPath3, Path3Burst, Path3Held: Boolean;
    Path3BurstQuads, PostValue: Integer;
    KickLeft: Integer;
    KickEOP: Boolean;
  end;

  TPS2GIF = class(TPS2Device)
  private
    FGS: TPS2GS;
    FLocalMemory: PByte; // Stable front-raster allocation; no synchronizing getter in a run.
    // The EE clock: the scheduler's (FSchedulerClock), or the time of the
    // packet the kick thread is drawing (FKickNow) while it does.
    FClock, FSchedulerClock: PInt64;
    FKickNow: Int64;
    // The GS drawing timeline: the EE cycle the GS is busy until, and the
    // pixel count it has been brought up to.
    FBusyUntil, FBusyPixels: Int64;
    // XGKICK packets on a thread of their own (Threaded; created with the
    // first, nil before).
    FThreaded: Boolean;
    FKicker: TObject;
    // PATH2's tag state and whether PATH1 is inside a packet, after what was
    // given to the kick thread (as the paths are while it is idle).
    FDirectPath: TPS2GIFPathState;
    FKickActive: Boolean;
    // PATH3's tag state as the domain side follows it (the GS side's is
    // Path[3]; both see the same quadwords).
    FFront3: TPS2GIFPathState;
    // PATH1 as the domain side follows it: the quadwords to come of the tag
    // a packet left open (VU1 hands over at most 1024 a packet) and that
    // tag's EOP.
    FKickLeft: Integer;
    FKickEOP: Boolean;
    // Pixels the GS drew from data DMA channel 2 moved (not yet taken).
    FPortPixels: Int64;
    // The domain's clock (work posted takes its time) and the GS side's
    // (the work being done).
    FPostClock: PInt64;
    FCommitNow: Int64;
    // Work posted and done; with DeferWork its quadwords wait in FWorkData
    // (FWorkWrite: where the next go), else it is done at once from the
    // caller's data.
    FWork: array of TPS2GIFWork;
    FWorkData: TArray<TPS2Reg128>;
    FWorkPosted, FWorkDone, FWorkWrite, FWorkDataDone: Int64;
    FCommitting, FDeferWork: Boolean;
    FWorkWaiting: Integer;
    FPostValue: Integer;
    // Work the domain posts from now on is dropped (taken back past the EE's
    // time).
    FDiscarding: Integer;
  public
  private
    function WorkRoom(Count: Integer; out Start: Int64): Boolean;
    function NewWork(Kind: TPS2GIFWorkKind; Path: Integer; FromDMA: Boolean; Count: Integer): TPS2GIFWork;
    function WorkPlace(Count: Integer): Int64;
    procedure PublishWork(const W: TPS2GIFWork);
    function TransferPortAhead(Data: PByte; Count: Integer): Integer;
    function FrontTake(Data: PByte; Count: Integer; FromDMA: Boolean): Integer;
    function PostNow: Int64; inline;
    procedure Post(Kind: TPS2GIFWorkKind; Path: Integer; FromDMA: Boolean; Data: PByte; Count: Integer);
    procedure DoWork(const W: TPS2GIFWork; Data: PByte);
    procedure DoWorkHere(const W: TPS2GIFWork; Data: PByte);
    procedure KickPacketHere(Data: PByte; Count: Integer);
    procedure TransferDirectHere(const Data: TPS2Reg128);
    function TransferDirectRunHere(Data: PCardinal; Count: Integer): Integer;
    procedure SetDeferWork(Value: Boolean);
    procedure UpdateBusy;
    procedure PackedWrite(var P: TPS2GIFPathState; Reg: Integer; const D: TPS2Reg128);
    procedure ReglistWrite(var P: TPS2GIFPathState; Value: UInt64);
    procedure StartPath3Burst;
    function TransferHere(PathIndex: Integer; Data: PByte; Count: Integer; FromDMA: Boolean): Integer;
    function TransferImageRun(Data: PByte; Count: Integer): Integer;
    procedure KickHere(Memory: PByte; Address, Mask: Cardinal; Count: Integer);
    procedure DrawAt(Data: PByte; Count: Integer; Direct: Boolean; Now: Int64);
    function Detachable(Data: PByte; Limit: Integer; out Count: Integer): Boolean;
    function Kicker: TObject;
    procedure SetClock(Value: PInt64);
    procedure SetThreaded(Value: Boolean);
  public
    Path: array[1..3] of TPS2GIFPathState;
    CTRL, MODE: Cardinal;
    // Set while PATH3 is masked by VIF1 MSKPATH3.
    MaskedPath3: Boolean;
    // After an unmask: PATH3 DMA stops at the next packet end (Burst), then
    // waits (Held) until ReleasePath3; BurstQuads counts its quadwords.
    Path3Burst, Path3Held: Boolean;
    Path3BurstQuads: Integer;
    // PATH3 may move again (unmasked): the GIF DMA channel goes on.
    OnPath3Resume: TProc;
    // A PATH3 DMA burst ended after Cycles (EE cycles): ReleasePath3 then.
    OnPath3Held: TProc<Int64>;
    // Diagnostics: tags started when assigned.
    TagLog: TStrings;
    // Experimental: the domain posts from a thread of its own, the EE side
    // commits (CommitTo) and answers what the domain asks of the GS side
    // (OnRequest: 1 channel 2's GS time, 2 the GS busy time).
    Ahead: Boolean;
    OnRequest: TFunc<Integer, Int64, Int64>;
    // Running ahead, channel 2's quadwords come from a copy (as the DMAC's
    // channels read memory); replaying, the work was handed over already.
    OnAheadRead: TPS2DMAAheadRead;
    OnAheadReadUsed: TPS2DMAAheadReadUsed;
    Replaying: Boolean;
    // Channel 1 or 2 ended its data at the work's time (channel, its
    // quadwords moved): the GS side has its device's time.
    OnPortEnd: TProc<Integer, Integer, Int64>;
    // The EE side's time (Join commits up to it; nil: everything).
    CommitClock: PInt64;
    // The VU1 domain the GIF belongs to (its Now is the clock).
    Domain: TPS2VU1Domain;
    constructor Create(GS: TPS2GS);
    destructor Destroy; override;
    property GS: TPS2GS read FGS;
    // The EE cycle counter, for the drawing timeline.
    property Clock: PInt64 write SetClock;
    // The EE cycle the GS has drawn what it was sent by: pixels take
    // 1 / GSPixelsPerCycle EE cycles each, from the time their data came.
    function GSBusyUntil: Int64;
    // EE cycles from now until then (0 when the GS is idle).
    function GSBusyCycles: Int64;
    procedure SerializeTimeline(State: TStateArchive);
    procedure Reset;
    // Feeds quadwords to a path; returns how many were taken (PATH3 stops
    // at the end of a packet while it is masked).
    function Transfer(PathIndex: Integer; Data: PByte; Count: Integer; FromDMA: Boolean = False): Integer;
    // Diagnostics: the tag just read on path PathIndex (apart from Transfer:
    // no string temporaries there).
    procedure LogTag(PathIndex: Integer);
    function PathIdle(PathIndex: Integer): Boolean;
    // MSKPATH3 or MODE.M3R: PATH3 masked or unmasked.
    procedure SetPath3Mask(Masked: Boolean);
    // The end of a burst's transfer time: PATH3 DMA goes on unless masked.
    procedure ReleasePath3;
    // XGKICK: GIF packets from VU1 data memory at Address until one ends
    // with EOP.
    procedure Kick(Memory: PByte; Address, Mask: Cardinal);
    // The same for the packet VU1 kicked, as it took it into Data (up to 1024
    // quadwords, from the start). Threaded, the GS takes a packet that only
    // draws (no A+D write to SIGNAL or FINISH, no interrupt its register
    // writes would raise, PATH1 between packets, the GS drawing on its
    // worker) on the kick thread while this thread goes on; anything else
    // reaching the GIF or the GS waits for that thread first (Join), so all
    // happens in the same order and at the same EE times as here.
    procedure KickPacket(Data: PByte);
    // VIF1 DIRECT: a quadword to PATH2 (threaded the same way).
    procedure TransferDirect(const Data: TPS2Reg128);
    // Accept only a safe asynchronous prefix. The caller retains barriers
    // and command completion on its original per-quadword path.
    function TransferDirectRun(Data: PCardinal; Count: Integer): Integer;
    // Does the work posted, then waits until the kick thread drew what it
    // was given.
    procedure Join;
    // The work posted, done in order (on the GS side).
    procedure CommitWork;
    // The GS side's time: that of the work being done.
    property CommitNow: Int64 read FCommitNow;
    // Diagnostics: posted work waits as a copy until CommitWork (a later GS
    // side does it), instead of being done at once.
    property DeferWork: Boolean read FDeferWork write SetDeferWork;
    procedure CommitTo(UpTo: Int64);
    // The oldest work not done (High(Int64): none).
    function WorkHead: Int64;
    // EE side: what the domain posts from now on is dropped, or no longer;
    // going back, the work not done yet is dropped (the domain makes it
    // again).
    procedure Discard(Value: Boolean);
    procedure DropWork;
    procedure SaveDomain(out C: TPS2GIFSaved);
    procedure RestoreDomain(const C: TPS2GIFSaved);
    // The domain waits for room to post (EE side: the ring is full).
    function WorkWaiting: Boolean;
    function TakePortCyclesHere: Int64;
    procedure PostPortEnd(Channel, Moved: Integer);
    function GSBusyCyclesAt(Now: Int64): Int64;
    property Threaded: Boolean read FThreaded write SetThreaded;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    // The register at Address with PATH3 masked or not as given (running
    // ahead: as the domain had it at the EE time; the rest is the GS
    // side's).
    function ReadRegister(Address: Cardinal; Masked3: Boolean): Cardinal;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); override;
    procedure SerializeState(State: TStateArchive);
    // DMA channel 2: Transfer on PATH3 from DMA, the pixels drawn counted for
    // TakePortCycles (the channel's GS time).
    function TransferPort(Data: PByte; Count: Integer): Integer;
    function TakePortCycles: Int64;
  end;

  // DMA channel 2 into PATH3.
  TPS2GIFPort = class(TPS2DMAPort)
  private
    FGIF: TPS2GIF;
  public
    constructor Create(GIF: TPS2GIF);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    function TakeBusyCycles: Int64; override;
    function BusyFromGS: Boolean; override;
    function ChecksAhead: Boolean; override;
  end;

implementation

uses
  System.SyncObjs,
  System.Diagnostics;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
const
  KickThreadSupported = True;

// This thread's SSE control word: MXCSR without its status flags.
function ControlWord: Cardinal;
asm
  .NOFRAME
  stmxcsr [rsp + 8]
  mov eax, [rsp + 8]
  and eax, $FFC0
end;

// Loads Value into this thread's MXCSR only (not the run-time library's
// DefaultMXCSR, which other threads load).
procedure LoadControlWord(Value: Cardinal);
asm
  .NOFRAME
  mov [rsp + 8], ecx
  ldmxcsr [rsp + 8]
end;
{$ELSE}
const
  KickThreadSupported = False;

function ControlWord: Cardinal;
begin
  Result := 0;
end;

procedure LoadControlWord(Value: Cardinal);
begin
end;
{$ENDIF}

type
  // The kick thread (TPS2GIF.Threaded): XGKICK packets and PATH2 quadwords
  // drawn in order, each at the EE time it came and with the control word
  // (host rounding) the emulation thread had then.
  TPS2GIFKicker = class(TThread)
  private
    const
      SpinRounds = 4000;
      EntrySize = 4096;
      EntryMask = EntrySize - 1;
      // Quadwords in flight (a packet is at most 1024).
      DataSize = 1 shl 16;
      DataMask = DataSize - 1;
      // PATH2 quadwords of one time gathered into an entry before it goes.
      DirectBatch = 64;
    type
      TEntry = record
        Start, Now: Int64;
        Count: Integer;
        Control: Cardinal;
        // A PATH1 packet, or PATH2 quadwords one by one.
        Direct: Boolean;
      end;
      PEntry = ^TEntry;
    var
      FGIF: TPS2GIF;
      // This thread's wake-up, and the emulation thread's while it waits for
      // this one (FWaiting).
      FWake, FProgress: TEvent;
      FEntries: array[0..EntrySize - 1] of TEntry;
      FData: TArray<TPS2Reg128>;
      // The emulation thread's: entries and quadwords put, the entry at
      // FPosted still gathering PATH2 quadwords (FOpen), and what it saw of
      // FDone and FDataDone last.
      FPosted, FDataWrite, FDoneSeen, FDataDoneSeen: Int64;
      FOpen: Boolean;
      FPad0: array[0..7] of Int64;
      // Entries handed over, and this thread waiting for more.
      FPublished: Int64;
      FSleeping, FWaiting: Integer;
      FPad1: array[0..7] of Int64;
      // This thread's: entries and quadwords drawn, and a failure.
      FDone, FDataDone: Int64;
      FFailed: Integer;
      FFailure: string;
      FPad2: array[0..7] of Int64;
    // Room for an entry of Count contiguous quadwords: where they start.
    function Reserve(Count: Integer): Int64;
    function Room(Last: Int64): Boolean; inline;
    procedure Close;
    // Spins, then sleeps until this thread drew more (Spins: so far).
    procedure Wait(var Spins: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(GIF: TPS2GIF);
    destructor Destroy; override;
    procedure PutPacket(Data: PByte; Count: Integer; Now: Int64);
    procedure PutDirect(const Data: TPS2Reg128; Now: Int64);
    procedure PutDirectRun(Data: PByte; Count: Integer; Now: Int64; Control: Cardinal);
    // Nothing given is still to draw.
    function Idle: Boolean; inline;
    procedure Join;
  end;

constructor TPS2GIFKicker.Create(GIF: TPS2GIF);
begin
  FGIF := GIF;
  FWake := TEvent.Create(nil, False, False, '');
  FProgress := TEvent.Create(nil, False, False, '');
  SetLength(FData, DataSize);
  inherited Create(False);
end;

destructor TPS2GIFKicker.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  inherited;
  FWake.Free;
  FProgress.Free;
end;

procedure TPS2GIFKicker.Execute;
begin
  NameThreadForDebugging('PS2 GIF kicks');
  var Control := ControlWord;
  var Done: Int64 := 0;
  while not Terminated do
  begin
    var Spins := 0;
    // (Spinning on a plain read, an aligned 64-bit one: a locked one would
    // take the line from the emulation thread each round.)
    while (FPublished = Done) and not Terminated do
    begin
      if Spins < SpinRounds then
      begin
        Inc(Spins);
        YieldProcessor;
        Continue;
      end;
      TInterlocked.Exchange(FSleeping, 1);
      if (TInterlocked.Read(FPublished) = Done) and not Terminated then
        FWake.WaitFor(INFINITE);
      TInterlocked.Exchange(FSleeping, 0);
      Spins := 0;
    end;
    if Terminated then
      Break;
    var Last := TInterlocked.Read(FPublished);
    while Done < Last do
    begin
      var E: PEntry := @FEntries[Done and EntryMask];
      if E.Control <> Control then
      begin
        Control := E.Control;
        LoadControlWord(Control);
      end;
      try
        FGIF.DrawAt(@FData[E.Start and DataMask], E.Count, E.Direct, E.Now);
      except
        on X: Exception do
          if TInterlocked.CompareExchange(FFailed, 2, 0) = 0 then
          begin
            FFailure := X.ClassName + ': ' + X.Message;
            TInterlocked.Exchange(FFailed, 1);
          end;
      end;
      Inc(Done);
      TInterlocked.Exchange(FDataDone, E.Start + E.Count);
      TInterlocked.Exchange(FDone, Done);
      if FWaiting <> 0 then
        FProgress.SetEvent;
    end;
  end;
end;

function TPS2GIFKicker.Room(Last: Int64): Boolean;
begin
  if Last - FDataDoneSeen > DataSize then
    FDataDoneSeen := TInterlocked.Read(FDataDone);
  Result := Last - FDataDoneSeen <= DataSize;
end;

function TPS2GIFKicker.Reserve(Count: Integer): Int64;
begin
  // Contiguous: quadwords that would wrap start the ring over.
  Result := FDataWrite;
  if (Result and DataMask) + Count > DataSize then
    Result := (Result or DataMask) + 1;
  var Spins := 0;
  while True do
  begin
    if FPosted - FDoneSeen >= EntrySize then
      FDoneSeen := TInterlocked.Read(FDone);
    if (FPosted - FDoneSeen < EntrySize) and Room(Result + Count) then
      Break;
    Wait(Spins);
  end;
end;

procedure TPS2GIFKicker.Close;
begin
  if not FOpen then
    Exit;
  FOpen := False;
  Inc(FPosted);
  TInterlocked.Exchange(FPublished, FPosted);
  if FSleeping <> 0 then
    FWake.SetEvent;
end;

procedure TPS2GIFKicker.PutPacket(Data: PByte; Count: Integer; Now: Int64);
begin
  Close;
  var Start := Reserve(Count);
  Move(Data^, FData[Start and DataMask], Count * SizeOf(TPS2Reg128));
  var E: PEntry := @FEntries[FPosted and EntryMask];
  E.Start := Start;
  E.Count := Count;
  E.Now := Now;
  E.Control := ControlWord;
  E.Direct := False;
  FDataWrite := Start + Count;
  FOpen := True;
  Close;
end;

procedure TPS2GIFKicker.PutDirect(const Data: TPS2Reg128; Now: Int64);
begin
  var Control := ControlWord;
  if FOpen then
  begin
    var E: PEntry := @FEntries[FPosted and EntryMask];
    var Next := E.Start + E.Count;
    if (E.Now = Now) and (E.Control = Control) and ((Next and DataMask) <> 0) and Room(Next + 1) then
    begin
      FData[Next and DataMask] := Data;
      Inc(E.Count);
      FDataWrite := Next + 1;
      if E.Count >= DirectBatch then
        Close;
      Exit;
    end;
    Close;
  end;
  var Start := Reserve(1);
  FData[Start and DataMask] := Data;
  var E: PEntry := @FEntries[FPosted and EntryMask];
  E.Start := Start;
  E.Count := 1;
  E.Now := Now;
  E.Control := Control;
  E.Direct := True;
  FDataWrite := Start + 1;
  FOpen := True;
end;

procedure TPS2GIFKicker.PutDirectRun(Data: PByte; Count: Integer; Now: Int64; Control: Cardinal);
begin
  while Count > 0 do
  begin
    var E: PEntry := @FEntries[FPosted and EntryMask];
    var Next: Int64;
    if FOpen then
    begin
      Next := E.Start + E.Count;
      if (E.Now <> Now) or (E.Control <> Control) or ((Next and DataMask) = 0) or not Room(Next + 1) then
      begin
        Close;
        Continue;
      end;
    end
    else
    begin
      Next := Reserve(1);
      E.Start := Next;
      E.Count := 0;
      E.Now := Now;
      E.Control := Control;
      E.Direct := True;
      FOpen := True;
    end;
    // Same 64-quad entry bound and wrap boundary as repeated PutDirect.
    // Only this producer writes the open entry; the consumer sees it after Close.
    var N := Count;
    if N > DirectBatch - E.Count then
      N := DirectBatch - E.Count;
    var Tail := DataSize - Integer(Next and DataMask);
    if N > Tail then
      N := Tail;
    var Free := DataSize - Integer(Next - FDataDoneSeen);
    if N > Free then
      N := Free;
    Move(Data^, FData[Next and DataMask], N * SizeOf(TPS2Reg128));
    Inc(E.Count, N);
    FDataWrite := Next + N;
    Inc(Data, N * SizeOf(TPS2Reg128));
    Dec(Count, N);
    if E.Count >= DirectBatch then
      Close;
  end;
end;

procedure TPS2GIFKicker.Wait(var Spins: Integer);
begin
  if Spins < SpinRounds then
  begin
    Inc(Spins);
    YieldProcessor;
    Exit;
  end;
  // (Any entry drawn wakes it; the caller looks again.)
  TInterlocked.Exchange(FWaiting, 1);
  var Done := TInterlocked.Read(FDone);
  if Done <> FPosted then
    FProgress.WaitFor(1);
  TInterlocked.Exchange(FWaiting, 0);
end;

function TPS2GIFKicker.Idle: Boolean;
begin
  // (A plain read: x64 loads of aligned 64-bit fields are atomic.)
  Result := not FOpen and (FDone = FPosted);
end;

procedure TPS2GIFKicker.Join;
begin
  if not Idle then
  begin
    Close;
    var Spins := 0;
    // (A plain read, as above.)
    while FDone <> FPosted do
      Wait(Spins);
  end;
  if FFailed = 1 then
  begin
    FFailed := 0;
    raise Exception.Create('GIF kick thread: ' + FFailure);
  end;
end;

// The GIF's tag state after quadword Q on PATH2 (as TransferHere goes): False
// when Q is A+D data for SIGNAL or FINISH.
function NextDirect(var P: TPS2GIFPathState; const Q: TPS2Reg128): Boolean;

  procedure NextRegister;
  begin
    Inc(P.Reg);
    if P.Reg >= P.NReg then
    begin
      P.Reg := 0;
      Inc(P.Loop);
    end;
  end;

begin
  Result := True;
  if not P.Active then
  begin
    P.NLoop := Integer(Q.Lo and $7FFF);
    P.Flg := Integer((Q.Lo shr 58) and 3);
    P.NReg := Integer((Q.Lo shr 60) and $F);
    if P.NReg = 0 then
      P.NReg := 16;
    P.Regs := Q.Hi;
    P.Reg := 0;
    P.Loop := 0;
    P.Active := P.NLoop > 0;
    Exit;
  end;
  case P.Flg of
    0:
      begin
        if ((P.Regs shr (P.Reg * 4)) and $F) = $E then
          if ((Q.Hi and $7F) = $60) or ((Q.Hi and $7F) = $61) then
            Exit(False);
        NextRegister;
      end;
    1:
      begin
        NextRegister;
        if P.Loop < P.NLoop then
          NextRegister;
      end;
  else
    Inc(P.Loop);
  end;
  if P.Loop >= P.NLoop then
    P.Active := False;
end;
{ TPS2GIF }

constructor TPS2GIF.Create(GS: TPS2GS);
begin
  inherited Create;
  FGS := GS;
  FLocalMemory := FGS.Raster.Memory.Data;
  FGS.BeforeAccess := Join;
  FClock := @FCommitNow;
  FSchedulerClock := @FCommitNow;
  SetLength(FWork, 1 shl 16);
  Reset;
end;

destructor TPS2GIF.Destroy;
begin
  FKicker.Free;
  inherited;
end;

procedure TPS2GIF.SetClock(Value: PInt64);
begin
  Join;
  FPostClock := Value;
end;

procedure TPS2GIF.SetDeferWork(Value: Boolean);
begin
  Join;
  FDeferWork := Value;
  if Value and (FWorkData = nil) then
    SetLength(FWorkData, 1 shl 20);
end;

function TPS2GIF.PostNow: Int64;
begin
  if FPostClock <> nil then
    Result := FPostClock^
  else
    Result := 0;
end;

// Work from the domain at its time: done now (from Data), or with DeferWork
// copied for CommitWork.
procedure TPS2GIF.Post(Kind: TPS2GIFWorkKind; Path: Integer; FromDMA: Boolean; Data: PByte; Count: Integer);
begin
  var W := NewWork(Kind, Path, FromDMA, Count);
  if not FDeferWork then
  begin
    CommitWork;
    DoWork(W, Data);
    Exit;
  end;
  if Replaying or (LoadShared(FDiscarding) <> 0) then
    Exit;
  W.Start := WorkPlace(Count);
  if W.Start < 0 then
    Exit;
  if Count > 0 then
    Move(Data^, FWorkData[W.Start and (Length(FWorkData) - 1)], Count * SizeOf(TPS2Reg128));
  PublishWork(W);
end;

function TPS2GIF.NewWork(Kind: TPS2GIFWorkKind; Path: Integer; FromDMA: Boolean; Count: Integer): TPS2GIFWork;
begin
  Result.Time := PostNow;
  Result.Count := Count;
  Result.Path := Path;
  Result.Kind := Kind;
  Result.FromDMA := FromDMA;
  Result.Start := 0;
  Result.Value := FPostValue;
  Result.Control := ControlWord;
  Result.External := nil;
end;

// Room for the entry and Count contiguous quadwords (a run that would wrap
// starts the ring over), where they go; ahead, the EE side makes it (-1:
// the work is dropped meanwhile).
function TPS2GIF.WorkPlace(Count: Integer): Int64;
begin
  if WorkRoom(Count, Result) then
    Exit;
  var Rounds := 0;
  while not WorkRoom(Count, Result) do
    if Ahead then
    begin
      if LoadShared(FDiscarding) <> 0 then
      begin
        Result := -1;
        Break;
      end;
      TInterlocked.Exchange(FWorkWaiting, 1);
      WaitRound(Rounds);
    end
    else
      CommitWork;
  TInterlocked.Exchange(FWorkWaiting, 0);
end;

// W with its quadwords at W.Start in the ring (or External).
procedure TPS2GIF.PublishWork(const W: TPS2GIFWork);
begin
  if W.External = nil then
    FWorkWrite := W.Start + W.Count;
  FWork[FWorkPosted and (Length(FWork) - 1)] := W;
  StoreShared(FWorkPosted, FWorkPosted + 1);
  if not Ahead then
    CommitWork;
end;

function TPS2GIF.WorkRoom(Count: Integer; out Start: Int64): Boolean;
begin
  var Size := Length(FWorkData);
  Start := FWorkWrite;
  if (Start and (Size - 1)) + Count > Size then
    Start := (Start or (Size - 1)) + 1;
  Result :=
    (FWorkPosted - LoadShared(FWorkDone) < Length(FWork)) and (Start + Count - LoadShared(FWorkDataDone) <= Size);
end;

procedure TPS2GIF.Discard(Value: Boolean);
begin
  StoreShared(FDiscarding, Ord(Value));
end;

procedure TPS2GIF.DropWork;
begin
  FWorkPosted := FWorkDone;
  FWorkWrite := FWorkDataDone;
end;

procedure TPS2GIF.SaveDomain(out C: TPS2GIFSaved);
begin
  C.Front3 := FFront3;
  C.MaskedPath3 := MaskedPath3;
  C.Path3Burst := Path3Burst;
  C.Path3Held := Path3Held;
  C.Path3BurstQuads := Path3BurstQuads;
  C.PostValue := FPostValue;
  C.KickLeft := FKickLeft;
  C.KickEOP := FKickEOP;
end;

procedure TPS2GIF.RestoreDomain(const C: TPS2GIFSaved);
begin
  FFront3 := C.Front3;
  MaskedPath3 := C.MaskedPath3;
  Path3Burst := C.Path3Burst;
  Path3Held := C.Path3Held;
  Path3BurstQuads := C.Path3BurstQuads;
  FPostValue := C.PostValue;
  FKickLeft := C.KickLeft;
  FKickEOP := C.KickEOP;
end;

function TPS2GIF.WorkWaiting: Boolean;
begin
  Result := TInterlocked.CompareExchange(FWorkWaiting, 0, 0) <> 0;
end;

function TPS2GIF.WorkHead: Int64;
begin
  Result := High(Int64);
  if FWorkDone < LoadShared(FWorkPosted) then
    Result := FWork[FWorkDone and (Length(FWork) - 1)].Time;
end;

procedure TPS2GIF.CommitWork;
begin
  CommitTo(High(Int64));
end;

procedure TPS2GIF.CommitTo(UpTo: Int64);
begin
  if FCommitting then
    Exit;
  FCommitting := True;
  try
    var Posted := LoadShared(FWorkPosted);
    while FWorkDone < Posted do
    begin
      // (Move: see TPS2GSRaster.Draw.)
      var W: TPS2GIFWork;
      Move(FWork[FWorkDone and (Length(FWork) - 1)], W, SizeOf(W));
      if W.Time > UpTo then
        Break;
      var Data := W.External;
      if Data = nil then
        Data := PByte(@FWorkData[W.Start and (Length(FWorkData) - 1)]);
      // (Done or failed: not again.)
      try
        DoWork(W, Data);
      finally
        if W.External = nil then
          StoreShared(FWorkDataDone, W.Start + W.Count);
        StoreShared(FWorkDone, FWorkDone + 1);
      end;
    end;
  finally
    FCommitting := False;
  end;
end;

// One piece of work on the GS side, at its time.
procedure TPS2GIF.DoWork(const W: TPS2GIFWork; Data: PByte);
begin
  FCommitNow := W.Time;
  var Saved := ControlWord;
  if Saved <> W.Control then
  begin
    LoadControlWord(W.Control);
    try
      DoWorkHere(W, Data);
    finally
      LoadControlWord(Saved);
    end;
  end
  else
    DoWorkHere(W, Data);
end;

procedure TPS2GIF.DoWorkHere(const W: TPS2GIFWork; Data: PByte);
begin
  case W.Kind of
    gwKick: KickPacketHere(Data, W.Count);
    gwDirect: TransferDirectHere(PPS2Reg128(Data)^);
    gwDirectRun:
    begin
      // What the kick thread does not take goes as single quadwords (as
      // the VIF hands them over then).
      var Taken := TransferDirectRunHere(PCardinal(Data), W.Count);
      for var K := Taken to W.Count - 1 do
        TransferDirectHere(PPS2Reg128(Data)[K]);
    end;
    gwPath:
    begin
      Join;
      TransferHere(W.Path, Data, W.Count, W.FromDMA);
    end;
    gwPortEnd:
      if Assigned(OnPortEnd) then
        OnPortEnd(W.Path, W.Value, W.Time);
    gwPort:
    begin
      Join;
      var Pixels := FGS.Raster.PixelsDrawn;
      TransferHere(3, Data, W.Count, True);
      Inc(FPortPixels, FGS.Raster.PixelsDrawn - Pixels);
    end;
  end;
end;

procedure TPS2GIF.SetThreaded(Value: Boolean);
begin
  if not KickThreadSupported then
    Value := False;
  if Value = FThreaded then
    Exit;
  Join;
  FThreaded := Value;
  if not Value then
    FreeAndNil(FKicker);
end;

procedure TPS2GIF.Join;
begin
  if CommitClock <> nil then
    CommitTo(CommitClock^)
  else
    CommitWork;
  if FKicker <> nil then
    TPS2GIFKicker(FKicker).Join;
end;

// Whether the kick thread may draw the packet VU1 kicked into Data (Count:
// its quadwords): its tags end with EOP within the Limit quadwords PATH1
// takes of it and no A+D write reaches SIGNAL or FINISH (their events reach
// the EE).
function TPS2GIF.Detachable(Data: PByte; Limit: Integer; out Count: Integer): Boolean;
begin
  Result := False;
  Count := 0;
  var Q := PPS2Reg128(Data);
  var K := 0;
  while K < Limit do
  begin
    var Tag := Q[K];
    var NLoop := Integer(Tag.Lo and $7FFF);
    var Flg := Integer((Tag.Lo shr 58) and 3);
    var NReg := Integer((Tag.Lo shr 60) and $F);
    if NReg = 0 then
      NReg := 16;
    Inc(K);
    case Flg of
      0:
      begin
        // A+D descriptors only.
        for var R := 0 to NReg - 1 do
          if ((Tag.Hi shr (R * 4)) and $F) = $E then
            for var L := 0 to NLoop - 1 do
            begin
              var At := K + L * NReg + R;
              if At >= Limit then
                Exit;
              var Reg := Integer(Q[At].Hi and $7F);
              if (Reg = $60) or (Reg = $61) then
                Exit;
            end;
        Inc(K, NLoop * NReg);
      end;
      1: Inc(K, (NLoop * NReg + 1) div 2);
    else
      Inc(K, NLoop);
    end;
    if (Tag.Lo and $8000) <> 0 then
    begin
      if K > Limit then
        Exit;
      Count := K;
      Exit(True);
    end;
  end;
end;

// The kick thread, created first; while it is idle, the paths' states it
// starts from (main thread: only after it joined do they change here).
function TPS2GIF.Kicker: TObject;
begin
  if FKicker = nil then
    FKicker := TPS2GIFKicker.Create(Self);
  if TPS2GIFKicker(FKicker).Idle then
  begin
    FDirectPath := Path[2];
    FKickActive := Path[1].Active;
  end;
  Result := FKicker;
end;

// The quadwords of P's tag yet to come (0: between tags).
function PathLeft(const P: TPS2GIFPathState): Integer;
begin
  Result := 0;
  if not P.Active then
    Exit;
  case P.Flg of
    0: Result := (P.NLoop - P.Loop) * P.NReg - P.Reg;
    1: Result := ((P.NLoop - P.Loop) * P.NReg - P.Reg + 1) div 2;
  else
    Result := P.NLoop - P.Loop;
  end;
end;

// The quadwords PATH1 takes of the packet VU1 kicked into Data: up to the
// end of the tag with EOP, at most 1024 (as VU1 took it), going on in the
// tag an earlier packet left open (Left quadwords of it to come, EOP its
// bit; both as this packet leaves them).
function KickSize(Data: PByte; var Left: Integer; var EOP: Boolean): Integer;
const
  Limit = 1024;
begin
  var Q := PPS2Reg128(Data);
  var K := 0;
  while K < Limit do
  begin
    if Left = 0 then
    begin
      var Lo := Q[K].Lo;
      var NLoop := Integer(Lo and $7FFF);
      var NReg := Integer((Lo shr 60) and $F);
      if NReg = 0 then
        NReg := 16;
      case Integer((Lo shr 58) and 3) of
        0: Left := NLoop * NReg;
        1: Left := (NLoop * NReg + 1) div 2;
      else
        Left := NLoop;
      end;
      EOP := (Lo and $8000) <> 0;
      Inc(K);
    end;
    var Run := Left;
    if Run > Limit - K then
      Run := Limit - K;
    Inc(K, Run);
    Dec(Left, Run);
    if (Left = 0) and EOP then
      Break;
  end;
  Result := K;
end;

procedure TPS2GIF.KickPacket(Data: PByte);
begin
  Domain.Check;
  Post(gwKick, 1, False, Data, KickSize(Data, FKickLeft, FKickEOP));
end;

// The GS side: Count quadwords of the packet are PATH1's (KickSize).
procedure TPS2GIF.KickPacketHere(Data: PByte; Count: Integer);
begin
  var Packet: Integer;
  if FThreaded
    and (TagLog = nil)
    and (FSchedulerClock <> nil)
    and FGS.Raster.Async
    and not FGS.WriteInterrupts
    and Detachable(Data, Count, Packet) then
  begin
    var K := TPS2GIFKicker(Kicker);
    // PATH1 between packets (each packet given ends with EOP).
    if not FKickActive then
    begin
      K.PutPacket(Data, Packet, FSchedulerClock^);
      Exit;
    end;
  end;
  Join;
  KickHere(Data, 0, $3FFF, Count);
end;

procedure TPS2GIF.TransferDirect(const Data: TPS2Reg128);
begin
  Domain.Check;
  var Q := Data;
  Post(gwDirect, 2, False, @Q, 1);
end;

procedure TPS2GIF.TransferDirectHere(const Data: TPS2Reg128);
begin
  if FThreaded and (TagLog = nil) and (FSchedulerClock <> nil) and FGS.Raster.Async and not FGS.WriteInterrupts then
  begin
    var K := TPS2GIFKicker(Kicker);
    if NextDirect(FDirectPath, Data) then
    begin
      K.PutDirect(Data, FSchedulerClock^);
      Exit;
    end;
  end;
  var Q := Data;
  Join;
  TransferHere(2, @Q, 1, False);
end;

function TPS2GIF.TransferDirectRun(Data: PCardinal; Count: Integer): Integer;
var
  Source, Bytes: NativeUInt;

  function ClearOf(Base: Pointer; Size: NativeUInt): Boolean;
  begin
    var At := NativeUInt(Base);
    Result := (At <= High(NativeUInt) - Size) and ((Source + Bytes <= At) or (Source >= At + Size));
  end;

begin
  Domain.Check;
  // Data the GIF or the GS could change while it goes stays with single
  // quadwords; otherwise the whole run is taken.
  Result := 0;
  if (Count < 2) or (NativeUInt(Count) > High(NativeUInt) div SizeOf(TPS2Reg128)) then
    Exit;
  Source := NativeUInt(Data);
  Bytes := NativeUInt(Count) * SizeOf(TPS2Reg128);
  if (Source > High(NativeUInt) - Bytes)
    or not ClearOf(Self, InstanceSize)
    or not ClearOf(FGS, FGS.InstanceSize)
    or not ClearOf(FGS.Raster, FGS.Raster.InstanceSize)
    or not ClearOf(FLocalMemory, PS2GSMemorySize) then
    Exit;
  Result := Count;
  Post(gwDirectRun, 2, False, PByte(Data), Count);
end;

function TPS2GIF.TransferDirectRunHere(Data: PCardinal; Count: Integer): Integer;
var
  Source, Bytes: NativeUInt;

  function ClearOf(Base: Pointer; Size: NativeUInt): Boolean;
  begin
    var At := NativeUInt(Base);
    Result := (At <= High(NativeUInt) - Size) and ((Source + Bytes <= At) or (Source >= At + Size));
  end;

begin
  Result := 0;
  if (Count < 2)
    or not FThreaded
    or (TagLog <> nil)
    or (FSchedulerClock = nil)
    or not FGS.Raster.Async
    or FGS.WriteInterrupts then
    Exit;
  if NativeUInt(Count) > High(NativeUInt) div SizeOf(TPS2Reg128) then
    Exit;
  Source := NativeUInt(Data);
  Bytes := NativeUInt(Count) * SizeOf(TPS2Reg128);
  if Source > High(NativeUInt) - Bytes then
    Exit;
  // Synthetic aliased callers retain the per-quad read/commit ordering.
  if not ClearOf(Self, InstanceSize)
    or not ClearOf(FGS, FGS.InstanceSize)
    or not ClearOf(FGS.Raster, FGS.Raster.InstanceSize)
    or not ClearOf(FLocalMemory, PS2GSMemorySize) then
    Exit;
  var K := TPS2GIFKicker(Kicker);
  var Q := PPS2Reg128(Data);
  var State := FDirectPath;
  while (Result < Count) and NextDirect(State, Q[Result]) do
    Inc(Result);
  if Result = 0 then
    Exit;
  FDirectPath := State;
  // No guest instruction or synchronous GS operation runs in this prefix.
  // Its EE time and control word are identical for every quadword.
  K.PutDirectRun(PByte(Data), Result, FSchedulerClock^, ControlWord);
end;

procedure TPS2GIF.DrawAt(Data: PByte; Count: Integer; Direct: Boolean; Now: Int64);
begin
  FKickNow := Now;
  FClock := @FKickNow;
  // (An interrupt the GS would raise again was found raised already when
  // this was given: nothing to do, and not from this thread.)
  FGS.InterruptsQuiet := True;
  try
    var Groupable :=
      (Count >= 4)
        and (TagLog = nil)
        and (FGS.Raster.PrimLog = nil)
        and (FGS.Raster.TransferLog = nil)
        and (FGS.Raster.WatchX < 0);
    if Groupable then
    begin
      var Pixels := FGS.Raster.PixelsDrawn;
      // Counter headroom for two full-scissor draws per quadword.
      var Margin: Int64 := Int64(Count) * $800000;
      if (Pixels < 0) or (FBusyPixels < 0) or (FBusyPixels > Pixels) or (Pixels > High(Int64) - Margin) then
        Groupable := False
      else
      begin
        var Limit := High(Int64) - Margin - (Pixels - FBusyPixels) div GSPixelsPerCycle;
        Groupable := (FBusyUntil <= Limit) and (FKickNow <= Limit);
      end;
    end;
    if Groupable then
    begin
      var PathIndex := 1;
      if Direct then
        PathIndex := 2;
      // Owned data, one EE time, no IRQ writes. Keep the last quad separate:
      // its preceding busy update then leaves exactly the scalar timeline.
      TransferHere(PathIndex, Data, Count - 1, False);
      TransferHere(PathIndex, Data + (Count - 1) * SizeOf(TPS2Reg128), 1, False);
    end
    else if not Direct then
      KickHere(Data, 0, $3FFF, Count)
    else
      for var K := 0 to Count - 1 do
        TransferHere(2, Data + K * SizeOf(TPS2Reg128), 1, False);
  finally
    FGS.InterruptsQuiet := False;
    FClock := FSchedulerClock;
  end;
end;

// Pixels drawn since the last update started drawing no earlier than now
// (the data that drew them came before).
procedure TPS2GIF.UpdateBusy;
begin
  var Pixels := FGS.Raster.PixelsDrawn;
  if Pixels < FBusyPixels then
    FBusyPixels := Pixels
  else if Pixels - FBusyPixels >= GSPixelsPerCycle then
  begin
    var Cycles := (Pixels - FBusyPixels) div GSPixelsPerCycle;
    var Now: Int64 := 0;
    if FClock <> nil then
      Now := FClock^;
    if FBusyUntil < Now then
      FBusyUntil := Now;
    Inc(FBusyUntil, Cycles);
    Inc(FBusyPixels, Cycles * GSPixelsPerCycle);
  end;
end;

function TPS2GIF.GSBusyUntil: Int64;
begin
  Join;
  UpdateBusy;
  Result := FBusyUntil;
end;

function TPS2GIF.GSBusyCycles: Int64;
begin
  Domain.Check;
  if Ahead then
    Result := OnRequest(2, PostNow)
  else
    Result := GSBusyCyclesAt(PostNow);
end;

function TPS2GIF.GSBusyCyclesAt(Now: Int64): Int64;
begin
  CommitTo(Now);
  Join;
  // (The GS side's time comes up to the caller's.)
  FCommitNow := Now;
  UpdateBusy;
  Result := FBusyUntil - FCommitNow;
  if Result < 0 then
    Result := 0;
end;

procedure TPS2GIF.SerializeTimeline(State: TStateArchive);
begin
  Join;
  // The pixel counter itself is not part of the state: keep what it is
  // still ahead of the timeline.
  var Ahead := FGS.Raster.PixelsDrawn - FBusyPixels;
  State.Field(FBusyUntil, SizeOf(FBusyUntil));
  State.Field(Ahead, SizeOf(Ahead));
  FBusyPixels := FGS.Raster.PixelsDrawn - Ahead;
end;

procedure TPS2GIF.Reset;
begin
  Join;
  FBusyUntil := 0;
  FBusyPixels := FGS.Raster.PixelsDrawn;
  for var K := 1 to 3 do
    Path[K] := Default(TPS2GIFPathState);
  FFront3 := Default(TPS2GIFPathState);
  FKickLeft := 0;
  FKickEOP := False;
  FPortPixels := 0;
  FCommitNow := PostNow;
  CTRL := 0;
  MODE := 0;
  MaskedPath3 := False;
  Path3Burst := False;
  Path3Held := False;
  Path3BurstQuads := 0;
end;

procedure TPS2GIF.StartPath3Burst;
begin
  Path3Burst := True;
  Path3Held := False;
  Path3BurstQuads := 0;
  if Assigned(OnPath3Resume) then
    OnPath3Resume();
end;

procedure TPS2GIF.SetPath3Mask(Masked: Boolean);
begin
  Domain.Check;
  var Was := MaskedPath3;
  MaskedPath3 := Masked;
  if Was and not Masked and ((MODE and 1) = 0) then
    StartPath3Burst;
end;

procedure TPS2GIF.ReleasePath3;
begin
  Domain.Check;
  if not Path3Held then
    Exit;
  Path3Held := False;
  if not MaskedPath3 and ((MODE and 1) = 0) and Assigned(OnPath3Resume) then
    OnPath3Resume();
end;

function TPS2GIF.PathIdle(PathIndex: Integer): Boolean;
begin
  Domain.Check;
  Join;
  Result := not Path[PathIndex].Active;
end;

procedure TPS2GIF.PackedWrite(var P: TPS2GIFPathState; Reg: Integer; const D: TPS2Reg128);
begin
  case Reg of
    $0: FGS.WriteRegister($00, D.Lo and $7FF);
    $1:
      FGS.WriteRegister($01, (D.UW[0] and $FF) or ((D.UW[1] and $FF) shl 8) or ((D.UW[2] and $FF) shl 16) or
        (UInt64(D.UW[3] and $FF) shl 24) or (UInt64(P.Q) shl 32));
    $2:
      begin
        P.Q := D.UW[2];
        FGS.WriteRegister($02, D.Lo);
      end;
    $3: FGS.WriteRegister($03, (D.UW[0] and $3FFF) or ((D.UW[1] and $3FFF) shl 16));
    $4:
      begin
        var V := UInt64(D.UW[0] and $FFFF) or (UInt64(D.UW[1] and $FFFF) shl 16) or
          (UInt64((D.UW[2] shr 4) and $FFFFFF) shl 32) or (UInt64((D.UW[3] shr 4) and $FF) shl 56);
        if (D.UW[3] and $8000) <> 0 then
          FGS.WriteRegister($0C, V)
        else
          FGS.WriteRegister($04, V);
      end;
    $5:
      begin
        var V := UInt64(D.UW[0] and $FFFF) or (UInt64(D.UW[1] and $FFFF) shl 16) or (UInt64(D.UW[2]) shl 32);
        if (D.UW[3] and $8000) <> 0 then
          FGS.WriteRegister($0D, V)
        else
          FGS.WriteRegister($05, V);
      end;
    $6, $7, $8, $9:
      FGS.WriteRegister(Reg, D.Lo);
    $A: FGS.WriteRegister($0A, UInt64((D.UW[3] shr 4) and $FF) shl 56);
    $C: FGS.WriteRegister($0C, D.Lo);
    $D: FGS.WriteRegister($0D, D.Lo);
    $E: FGS.WriteRegister(Integer(D.Hi and $FF), D.Lo);
    $F: ;
  end;
end;

procedure TPS2GIF.ReglistWrite(var P: TPS2GIFPathState; Value: UInt64);
begin
  var Reg := Integer((P.Regs shr (P.Reg * 4)) and $F);
  // In REGLIST mode registers take their 64-bit form; A+D is not allowed.
  if Reg < $E then
    FGS.WriteRegister(Reg, Value);
  Inc(P.Reg);
  if P.Reg >= P.NReg then
  begin
    P.Reg := 0;
    Inc(P.Loop);
  end;
end;

procedure TPS2GIF.LogTag(PathIndex: Integer);
begin
  var P: PPS2GIFPathState := @Path[PathIndex];
  TagLog.Add(Format('tag path%d nloop=%d eop=%d flg=%d nreg=%d regs=%x pre=%d prim=%x', [PathIndex, P.NLoop, Ord(P.EOP), P.Flg,
    P.NReg, P.Regs, (P.Tag.Lo shr 46) and 1, (P.Tag.Lo shr 47) and $7FF]));
end;

function TPS2GIF.Transfer(PathIndex: Integer; Data: PByte; Count: Integer; FromDMA: Boolean): Integer;
begin
  Domain.Check;
  Result := Count;
  if PathIndex = 3 then
    Result := FrontTake(Data, Count, FromDMA);
  // (Also with nothing taken: the GS side brings its timeline up to now.)
  Post(gwPath, PathIndex, FromDMA, Data, Result);
end;

function TPS2GIF.TransferPort(Data: PByte; Count: Integer): Integer;
begin
  Domain.Check;
  if Ahead and FDeferWork and Assigned(OnAheadRead) then
    Exit(TransferPortAhead(Data, Count));
  Result := FrontTake(Data, Count, True);
  Post(gwPort, 3, True, Data, Result);
end;

// Running ahead: PATH3 takes the quadwords from a copy the EE side checks
// against memory at their time; the work reads the copy (kept while the
// domain runs ahead).
function TPS2GIF.TransferPortAhead(Data: PByte; Count: Integer): Integer;
begin
  var Token: Int64;
  var Copy := OnAheadRead(2, Data, Count * SizeOf(TPS2Reg128), Token);
  Result := FrontTake(Copy, Count, True);
  OnAheadReadUsed(Token, Result * SizeOf(TPS2Reg128));
  if Replaying or (LoadShared(FDiscarding) <> 0) then
    Exit;
  var W := NewWork(gwPort, 3, True, Result);
  W.External := Copy;
  W.Start := WorkPlace(0);
  if W.Start >= 0 then
    PublishWork(W);
end;

function TPS2GIF.TakePortCycles: Int64;
begin
  Domain.Check;
  if Ahead then
    Result := OnRequest(1, PostNow)
  else
  begin
    CommitTo(PostNow);
    Result := TakePortCyclesHere;
  end;
end;

procedure TPS2GIF.PostPortEnd(Channel, Moved: Integer);
begin
  FPostValue := Moved;
  Post(gwPortEnd, Channel, False, nil, 0);
end;

function TPS2GIF.TakePortCyclesHere: Int64;
begin
  Result := FPortPixels div GSPixelsPerCycle;
  FPortPixels := 0;
end;

// PATH3 as TransferHere goes through it, tags and counts only: how many of
// Count quadwords it takes now (masked, or held after a burst, it stops
// between packets), with the burst bookkeeping.
function TPS2GIF.FrontTake(Data: PByte; Count: Integer; FromDMA: Boolean): Integer;
var
  P: PPS2GIFPathState;

  procedure PacketEnd(Done: Integer);
  begin
    if FromDMA and Path3Burst then
    begin
      Path3Burst := False;
      Path3Held := True;
      // The GS takes about a quadword per bus clock (two EE cycles).
      if Assigned(OnPath3Held) then
        OnPath3Held(Int64(Path3BurstQuads + Done) * 2 + 64);
    end;
  end;

  procedure NextRegister;
  begin
    Inc(P.Reg);
    if P.Reg >= P.NReg then
    begin
      P.Reg := 0;
      Inc(P.Loop);
    end;
  end;

begin
  Result := 0;
  P := @FFront3;
  var Q := PPS2Reg128(Data);
  while Result < Count do
  begin
    if not P.Active then
    begin
      // Masked or held after a burst: stop between packets.
      if MaskedPath3 or ((MODE and 1) <> 0) or FromDMA and Path3Held then
        Break;
      P.Tag := Q^;
      P.NLoop := Integer(P.Tag.Lo and $7FFF);
      P.EOP := (P.Tag.Lo and $8000) <> 0;
      P.Flg := Integer((P.Tag.Lo shr 58) and 3);
      P.NReg := Integer((P.Tag.Lo shr 60) and $F);
      if P.NReg = 0 then
        P.NReg := 16;
      P.Regs := P.Tag.Hi;
      P.Reg := 0;
      P.Loop := 0;
      P.Active := P.NLoop > 0;
      Inc(Result);
      Inc(Q);
      if not P.Active and P.EOP then
        PacketEnd(Result);
      Continue;
    end;
    case P.Flg of
      0: NextRegister;
      1:
      begin
        NextRegister;
        if P.Loop < P.NLoop then
          NextRegister;
      end;
    else
      begin
        // IMAGE: the quadwords up to the end of the tag at once.
        var Chunk := Count - Result;
        if Chunk > P.NLoop - P.Loop then
          Chunk := P.NLoop - P.Loop;
        Inc(P.Loop, Chunk);
        Inc(Result, Chunk - 1);
        Inc(Q, Chunk - 1);
      end;
    end;
    Inc(Result);
    Inc(Q);
    if P.Loop >= P.NLoop then
    begin
      P.Active := False;
      if P.EOP then
        PacketEnd(Result);
    end;
  end;
  if FromDMA then
    Inc(Path3BurstQuads, Result);
end;

function TPS2GIF.TransferImageRun(Data: PByte; Count: Integer): Integer;
var
  Source, Bytes: NativeUInt;

  function ClearOf(Base: Pointer; Size: NativeUInt): Boolean;
  begin
    var At := NativeUInt(Base);
    Result := (At <= High(NativeUInt) - Size) and ((Source + Bytes <= At) or (Source >= At + Size));
  end;

begin
  Result := 0;
  if (Count < 2) or not FGS.Raster.Async or (NativeUInt(Count) > High(NativeUInt) div SizeOf(TPS2Reg128)) then
    Exit;
  Source := NativeUInt(Data);
  Bytes := NativeUInt(Count) * SizeOf(TPS2Reg128);
  if Source > High(NativeUInt) - Bytes then
    Exit;
  if not ClearOf(Self, InstanceSize)
    or not ClearOf(FGS, FGS.InstanceSize)
    or not ClearOf(FGS.Raster, FGS.Raster.InstanceSize)
    or not ClearOf(FLocalMemory, PS2GSMemorySize) then
    Exit;
  Result := FGS.WriteImageRun(Data, Count);
end;

// The GS side of Transfer: every one of the Count quadwords (PATH3's were
// counted by FrontTake already).
function TPS2GIF.TransferHere(PathIndex: Integer; Data: PByte; Count: Integer; FromDMA: Boolean): Integer;
begin
  UpdateBusy;
  Result := 0;
  var Q := PPS2Reg128(Data);
  while Result < Count do
  begin
    var P: PPS2GIFPathState := @Path[PathIndex];
    if not P.Active then
    begin
      // A new tag.
      P.Tag := Q^;
      P.NLoop := Integer(P.Tag.Lo and $7FFF);
      P.EOP := (P.Tag.Lo and $8000) <> 0;
      P.Flg := Integer((P.Tag.Lo shr 58) and 3);
      P.NReg := Integer((P.Tag.Lo shr 60) and $F);
      if P.NReg = 0 then
        P.NReg := 16;
      P.Regs := P.Tag.Hi;
      P.Reg := 0;
      P.Loop := 0;
      P.Q := $3F800000;
      if (P.Tag.Lo and (UInt64(1) shl 46)) <> 0 then
        FGS.WriteRegister($00, (P.Tag.Lo shr 47) and $7FF);
      P.Active := P.NLoop > 0;
      if (TagLog <> nil) and (TagLog.Count < 200000) then
        LogTag(PathIndex);
      Inc(Result);
      Inc(Q);
      Continue;
    end;
    case P.Flg of
      0:
      begin
        var Reg := Integer((P.Regs shr (P.Reg * 4)) and $F);
        PackedWrite(P^, Reg, Q^);
        Inc(P.Reg);
        if P.Reg >= P.NReg then
        begin
          P.Reg := 0;
          Inc(P.Loop);
        end;
      end;
      1:
      begin
        ReglistWrite(P^, Q.Lo);
        if P.Loop < P.NLoop then
          ReglistWrite(P^, Q.Hi);
      end;
    else
      begin
        var Chunk := Count - Result;
        if Chunk > P.NLoop - P.Loop then
          Chunk := P.NLoop - P.Loop;
        var Taken := TransferImageRun(PByte(Q), Chunk);
        if Taken = 0 then
        begin
          FGS.WriteImage(Q^);
          Taken := 1;
        end;
        Inc(P.Loop, Taken);
        Inc(Result, Taken - 1);
        Inc(Q, Taken - 1);
      end;
    end;
    Inc(Result);
    Inc(Q);
    if P.Loop >= P.NLoop then
      P.Active := False;
  end;
end;

procedure TPS2GIF.Kick(Memory: PByte; Address, Mask: Cardinal);
begin
  Domain.Check;
  Join;
  FCommitNow := PostNow;
  // (At most the whole memory.)
  KickHere(Memory, Address, Mask, Integer((Mask + 1) div 16));
  FKickLeft := PathLeft(Path[1]);
  FKickEOP := Path[1].EOP;
end;

procedure TPS2GIF.KickHere(Memory: PByte; Address, Mask: Cardinal; Count: Integer);
begin
  // At most Count quadwords; stops after the packet with EOP is done.
  for var K := 0 to Count - 1 do
  begin
    var Q := PPS2Reg128(Memory + (Address and Mask))^;
    TransferHere(1, @Q, 1, False);
    Address := Address + 16;
    if not Path[1].Active and Path[1].EOP then
      Break;
  end;
end;

function TPS2GIF.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  Domain.Check;
  Result := ReadRegister(Address, MaskedPath3);
end;

function TPS2GIF.ReadRegister(Address: Cardinal; Masked3: Boolean): Cardinal;
begin
  Join;
  case Address and $FF0 of
    $000: Result := CTRL;
    $010: Result := MODE;
    $020:
    begin
      // STAT: M3R, M3P, IMT, OPH and APATH while a path is active.
      Result := (MODE and 1) or (Cardinal(Ord(Masked3)) shl 1) or (MODE and 4);
      // PATH1 (XGKICK) runs to completion at once: never reported busy (an
      // unterminated VU packet left it 'active' and sceGsSyncPath timed out).
      for var K := 2 to 3 do
        if Path[K].Active then
        begin
          Result := Result or $200 or (Cardinal(K) shl 10);
          Break;
        end;
    end;
    $040: Result := Cardinal(Path[3].Tag.UW[0]);
    $050: Result := Cardinal(Path[3].Tag.UW[1]);
    $060: Result := Cardinal(Path[3].Tag.UW[2]);
    $070: Result := Cardinal(Path[3].Tag.UW[3]);
    $080: Result := Cardinal(Path[3].NLoop - Path[3].Loop) or (Cardinal(Path[3].Reg) shl 16);
    $090: Result := Cardinal(Path[3].NLoop - Path[3].Loop);
    $0A0: Result := Cardinal(Path[3].Tag.UW[0]);
  else
    Result := 0;
  end;
end;

procedure TPS2GIF.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  Domain.Check;
  Join;
  case Address and $FF0 of
    $000:
    begin
      CTRL := Cardinal(Value) and 8;
      if (Value and 1) <> 0 then
      begin
        for var K := 1 to 3 do
          Path[K] := Default(TPS2GIFPathState);
        FFront3 := Default(TPS2GIFPathState);
        FKickLeft := 0;
        FKickEOP := False;
      end;
    end;
    $010:
    begin
      var WasMasked := (MODE and 1) <> 0;
      MODE := Cardinal(Value) and 5;
      if WasMasked and ((MODE and 1) = 0) and not MaskedPath3 then
        StartPath3Burst
      else if ((MODE and 1) = 0) and Assigned(OnPath3Resume) then
        OnPath3Resume();
    end;
  end;
end;

procedure TPS2GIF.WriteFIFO(Address: Cardinal; const Value: TPS2Reg128);
begin
  Domain.Check;
  var V := Value;
  Transfer(3, @V, 1);
end;

procedure TPS2GIF.SerializeState(State: TStateArchive);
begin
  Join;
  State.Field(Path, SizeOf(Path));
  State.Field(CTRL, SizeOf(CTRL));
  State.Field(MODE, SizeOf(MODE));
  State.Field(MaskedPath3, SizeOf(MaskedPath3));
  State.Field(Path3Burst, SizeOf(Path3Burst));
  State.Field(Path3Held, SizeOf(Path3Held));
  State.Field(Path3BurstQuads, SizeOf(Path3BurstQuads));
  if State.Loading then
  begin
    FFront3 := Path[3];
    FKickLeft := PathLeft(Path[1]);
    FKickEOP := Path[1].EOP;
  end;
end;

{ TPS2GIFPort }

constructor TPS2GIFPort.Create(GIF: TPS2GIF);
begin
  inherited Create;
  FGIF := GIF;
end;

function TPS2GIFPort.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := FGIF.TransferPort(Data, Count);
end;

// The GS time of what this channel's data drew. Drawing from the other paths
// does not hold the channel.
function TPS2GIFPort.TakeBusyCycles: Int64;
begin
  Result := FGIF.TakePortCycles;
end;

function TPS2GIFPort.BusyFromGS: Boolean;
begin
  Result := True;
end;

function TPS2GIFPort.ChecksAhead: Boolean;
begin
  Result := True;
end;

end.
