unit N64.RDPWorker;
// Queue indices are masked; N64_CHECKED restores diagnostics in this hot path.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

// Full TN64RDPs on their own threads.
//
// The emulation thread runs a timing TN64RDP (TimingOnly): the same command,
// edge and coverage code without pixels, so its Execute gives the exact
// Consumed, Full Sync, WorkClocks and crash state at once. Every command word
// pair that Execute reads is queued here (Put), and each band thread feeds
// all of them, in order, to its own full RDP. With one band that RDP draws
// everything; with several, each draws its band of rows (TN64RDPGroup). A
// list is the words of one Execute call; lists are numbered from 1 in queue
// order and complete when every band has run them.
//
// While a list is queued, the timing RDP marks the RDRAM the full RDPs may
// read or write, in 64-byte lines (TN64Bus.MarkRDPRead/Write). Every other
// access to RDRAM (CPU, RSP/PI/SI/AI DMA, VI) goes through TN64Bus's checked
// accessors, which wait for the lists on those lines (TN64Bus.WaitRDP ->
// WaitList). Texture and TLUT bytes that no queued list writes travel with
// the command words instead (TN64RDP.OnDataOut), so they need no marks. Memory
// is then the same, at the same guest time, as with a synchronous RDP.

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Diagnostics, System.Math, N64.Types, N64.RDP, N64.Host;

type
  TN64RDPWorker = class
  private
    const
      RingBits = 16;
      RingSize = 1 shl RingBits;
      RingMask = RingSize - 1;
    // Segment header: word count, first segment of a list, last segment,
    // a copy's (QueueCopy: a list of its own, no words).
      CountMask = $1FFFFFFF;
      CopyFlag = $20000000;
      FirstFlag = $40000000;
      LastFlag = $80000000;
      SpinRounds = 4000;
    // Copies that may be queued at once.
      CopySlots = 4;
  private
    type
      TCopy = record
        Target: TN64Bus;
        Address, Count: Cardinal;
        Ready: TEvent;
        Pending: Integer;
      end;

      TWaitTarget = (Consumed, Done);

      TBand = class(TThread)
      private
        FOwner: TN64RDPWorker;
        FIndex: Integer;
        FRDP: TN64RDP;
        FCursor, FEnd: Int64;
        FNoise: Cardinal;
      // The logical processors this band may run on (empty: anywhere), and
      // the one it prefers (-1: none).
        FCPUs: TN64CPUSet;
        FPreferred: Integer;
        function NextWord: Cardinal;
      protected
        procedure Execute; override;
      public
        constructor Create(Owner: TN64RDPWorker; Index: Integer; RDP: TN64RDP; const CPUs: TN64CPUSet; Preferred: Integer);
      end;

    // What one band thread writes, a cache line apart from the others.
      TBandSlot = record
        Consumed, Done: Int64;
        Sleeping: Integer;
        DataReady: TEvent;
        Pad: array[0..3] of Int64;
      end;
  private
    FRDPs: TArray<TN64RDP>;
    FBus: TN64Bus;
    FThreads: TArray<TBand>;
    FSlots: TArray<TBandSlot>;
    FGroup: TN64RDPGroup;
    FProgress: TEvent;
    FStress: Boolean;
    // Single-producer ring of segments that every band reads: a header word,
    // then command word pairs, each followed by the data words of the
    // command it completes (TN64RDP.OnDataOut). Positions count words and
    // never wrap.
    FRing: array of Cardinal;
    // Producer state (emulation thread only).
    FWrite: Int64;
    FHeader: Int64;
    FWords: Cardinal;
    FFirst: Boolean;
    FOpen: Boolean;
    FEnded: Int64;
    FRoomUntil: Int64;
    FProducerNoise: Cardinal;
    // The time the producer waited for the bands (TStopwatch ticks).
    FWaitTime: Int64;
    // The copies queued (QueueCopy), used in turn (FCopyNext the next):
    // Pending 1 until made.
    FCopies: array[0..CopySlots - 1] of TCopy;
    FCopyNext: Integer;
    // With bands: the copy band 0 makes at the barrier (CopyAt).
    FCopyAt: Integer;
    FMakeCopy: TProc;
  protected
    // Fields written by different threads sit on different cache lines.
    FPad0: array[0..7] of Int64;
  private
    // Written by the producer.
    FPublished: Int64;
    FMainWaiting: Integer;
  protected
    FPad1: array[0..7] of Int64;
  private
    // Written by the first band thread that fails.
    FFailed: Integer;
    FError: string;
    procedure Reserve(Words: Integer);
    procedure OpenSegment;
    procedure CloseSegment(Last: Boolean);
    procedure Publish;
    procedure WakeBands(Index: Integer);
    function MinConsumed: Int64;
    function Reached(Target: TWaitTarget; Value: Int64): Boolean;
    procedure WaitFor(Target: TWaitTarget; Value: Int64);
    procedure Fail(const Message: string);
    // A band at a copy's segment: the copy, once every band is there.
    procedure CopyAt(RDP: TN64RDP; Index: Integer);
    procedure MakeCopy(Index: Integer);
    function Failed: Boolean;
    function published: Int64; inline;
    class procedure Signal(var Waiting: Integer; Event: TEvent); static;
    class function Noise(var State: Cardinal): Cardinal; static;
    class procedure StressDelay(var State: Cardinal); static;
  public
    // RDP is the full RDP of band 0; Bands - 1 more are created on Bus with
    // its state. Lists up to Completed count as complete (the first list
    // queued is Completed + 1). Stress adds random stalls to every thread.
    // The bands run on the logical processors BandCPUs (if not empty), band
    // I preferably on Preferred[I] (if given).
    constructor Create(RDP: TN64RDP; Bus: TN64Bus; Bands: Integer; Completed: Int64; Stress: Boolean; const BandCPUs: TN64CPUSet; const Preferred: TArray<Integer>); overload;
    // The same, the bands placed by the scheduler.
    constructor Create(RDP: TN64RDP; Bus: TN64Bus; Bands: Integer; Completed: Int64; Stress: Boolean); overload;
    destructor Destroy; override;
    // Producer side, emulation thread: BeginList, then Put for each word pair
    // (each followed by the PutData words of its command, if any), EndList.
    procedure BeginList;
    procedure Put(W0, W1: Cardinal);
    procedure PutData(Value: Cardinal);
    procedure EndList;
    // A list of its own (no list open): Count bytes of RDRAM at Address
    // copied to Target's RDRAM (TN64Bus.CopyRAMTo) once every list queued
    // before is complete and before any band runs one queued after; then
    // Ready is set. At most CopySlots - 1 copies may be queued and not made.
    procedure QueueCopy(Target: TN64Bus; Address, Count: Cardinal; Ready: TEvent);
    // The number of lists completed so far.
    function Done: Int64;
    // Waits until list List is complete. For the open list (List above the
    // lists ended so far) it waits until every word queued so far has run.
    procedure WaitList(List: Int64);
    // Waits until everything queued has run; no list may be open.
    procedure Drain;
    // Raises the first band's exception if one stopped on it.
    procedure CheckFailure;
    // With the queue drained: band 0's RDP takes the latest per-pixel state
    // of all bands (for snapshots and synchronous use).
    procedure MergeState;
    // With the queue drained: every band continues from band 0's state
    // (after band 0's RDP ran lists itself, Reset or a state load).
    procedure Resync;
    property Open: Boolean read FOpen;
    // Set only while the queue is drained.
    property Stress: Boolean read FStress write FStress;
    // Diagnostics: the emulation thread's time waiting for the bands
    // (TStopwatch ticks).
    property WaitTime: Int64 read FWaitTime;
  end;

implementation

{ TN64RDPWorker.TBand }

constructor TN64RDPWorker.TBand.Create(Owner: TN64RDPWorker; Index: Integer; RDP: TN64RDP; const CPUs: TN64CPUSet; Preferred: Integer);
begin
  FOwner := Owner;
  FIndex := Index;
  FRDP := RDP;
  FCPUs := CPUs;
  FPreferred := Preferred;
  FNoise := Cardinal($9E3779B9 + Cardinal(Index) * 7919);
  inherited Create(False);
end;

function TN64RDPWorker.TBand.NextWord: Cardinal;
begin
  // Inside Feed: the data words of the current command.
  if FCursor >= FEnd then
    raise EN64Unsupported.Create('RDP data words missing');
  Result := FOwner.FRing[FCursor and RingMask];
  Inc(FCursor);
end;

procedure TN64RDPWorker.TBand.Execute;
begin
  if not FCPUs.IsEmpty then
  begin
    var Previous: TN64CPUSet;
    PinCurrentThread(FCPUs, Previous);
  end;
  if FPreferred >= 0 then
    PreferProcessor(FPreferred);
  var Position: Int64 := 0;
  while not Terminated do
  begin
    if (FOwner.published <= Position) or FOwner.Failed then
    begin
      // Idle (or stopped by an exception): spin a little, then sleep until
      // the producer publishes or the thread is terminated.
      var Spins := 0;
      while (Spins < SpinRounds) and (FOwner.published <= Position) and not Terminated do
      begin
        Inc(Spins);
        YieldProcessor;
      end;
      TInterlocked.Exchange(FOwner.FSlots[FIndex].Sleeping, 1);
      if not Terminated and ((FOwner.published <= Position) or FOwner.Failed) then
        FOwner.FSlots[FIndex].DataReady.WaitFor(INFINITE)
      else
        TInterlocked.Exchange(FOwner.FSlots[FIndex].Sleeping, 0);
      Continue;
    end;
    // (Before a copy's barrier too, where every band must come.)
    FOwner.WakeBands(FIndex);
    if FOwner.FStress then
      StressDelay(FNoise);
    var Header := FOwner.FRing[Position and RingMask];
    FCursor := Position + 1;
    FEnd := FCursor + Int64(Header and CountMask);
    try
      if (Header and CopyFlag) <> 0 then
        // (Its one word: the copy's slot.)
        FOwner.CopyAt(FRDP, Integer(FOwner.FRing[FCursor and RingMask]))
      else
      begin
        if (Header and FirstFlag) <> 0 then
          FRDP.BeginList;
        FRDP.OnDataIn := NextWord;
        while FCursor < FEnd do
        begin
          var W0 := FOwner.FRing[FCursor and RingMask];
          var W1 := FOwner.FRing[(FCursor + 1) and RingMask];
          Inc(FCursor, 2);
          FRDP.Feed(W0, W1);
        end;
        FRDP.OnDataIn := nil;
      end;
    except
      on E: Exception do
      begin
        // This RDP's state is now unknown: no band runs anything more.
        FRDP.OnDataIn := nil;
        FOwner.Fail(E.ClassName + ': ' + E.Message);
        Continue;
      end;
    end;
    Position := FEnd;
    // The counters move after the memory Feed wrote (full barriers).
    TInterlocked.Exchange(FOwner.FSlots[FIndex].Consumed, Position);
    if (Header and LastFlag) <> 0 then
      TInterlocked.Increment(FOwner.FSlots[FIndex].Done);
    Signal(FOwner.FMainWaiting, FOwner.FProgress);
  end;
end;

{ TN64RDPWorker }

constructor TN64RDPWorker.Create(RDP: TN64RDP; Bus: TN64Bus; Bands: Integer; Completed: Int64; Stress: Boolean; const BandCPUs: TN64CPUSet; const Preferred: TArray<Integer>);
begin
  inherited Create;
  FBus := Bus;
  FStress := Stress;
  FProducerNoise := $2545F491;
  SetLength(FRing, RingSize);
  FRoomUntil := RingSize;
  FProgress := TEvent.Create(nil, False, False, '');
  if Bands < 1 then
    Bands := 1;
  SetLength(FRDPs, Bands);
  FRDPs[0] := RDP;
  for var I := 1 to Bands - 1 do
  begin
    FRDPs[I] := TN64RDP.Create(Bus);
    FRDPs[I].Assign(RDP);
  end;
  if Bands > 1 then
    FGroup := TN64RDPGroup.Create(FRDPs);
  FMakeCopy :=
    procedure
    begin
      MakeCopy(FCopyAt);
    end;
  FEnded := Completed;
  SetLength(FSlots, Bands);
  for var I := 0 to Bands - 1 do
  begin
    FSlots[I].Done := Completed;
    FSlots[I].DataReady := TEvent.Create(nil, False, False, '');
  end;
  SetLength(FThreads, Bands);
  for var I := 0 to Bands - 1 do
  begin
    var Prefer := -1;
    if I < Length(Preferred) then
      Prefer := Preferred[I];
    FThreads[I] := TBand.Create(Self, I, FRDPs[I], BandCPUs, Prefer);
  end;
end;

constructor TN64RDPWorker.Create(RDP: TN64RDP; Bus: TN64Bus; Bands: Integer; Completed: Int64; Stress: Boolean);
begin
  Create(RDP, Bus, Bands, Completed, Stress, Default(TN64CPUSet), nil);
end;

destructor TN64RDPWorker.Destroy;
begin
  for var Thread in FThreads do
    Thread.Terminate;
  // Bands waiting at a group barrier give up as well.
  if FGroup <> nil then
    FGroup.Abort;
  for var I := 0 to High(FSlots) do
    FSlots[I].DataReady.SetEvent;
  for var Thread in FThreads do
    Thread.Free; // waits for Execute to return
  for var I := 0 to High(FSlots) do
    FSlots[I].DataReady.Free;
  FGroup.Free;
  for var I := 1 to High(FRDPs) do
    FRDPs[I].Free;
  FProgress.Free;
  inherited;
end;

class function TN64RDPWorker.Noise(var State: Cardinal): Cardinal;
begin
  // xorshift32; each thread has its own state.
  State := State xor ((State shl 13) and $FFFFFFFF);
  State := State xor (State shr 17);
  State := State xor ((State shl 5) and $FFFFFFFF);
  Result := State;
end;

class procedure TN64RDPWorker.StressDelay(var State: Cardinal);
begin
  // Random stalls: the emulation thread sometimes runs far ahead of the
  // bands, and sometimes finds them idle; bands drift apart.
  case Noise(State) and 63 of
    0:
      Sleep(1);
    1..4:
      Sleep(0);
    5..12:
      for var I := 0 to Integer(Noise(State) and 4095) do
        YieldProcessor;
  end;
end;

class procedure TN64RDPWorker.Signal(var Waiting: Integer; Event: TEvent);
begin
  // A waiter sets its flag before its final check and both sides use full
  // barriers, so a wake-up cannot be lost.
  if TInterlocked.CompareExchange(Waiting, 0, 1) = 1 then
    Event.SetEvent;
end;

procedure TN64RDPWorker.Fail(const Message: string);
begin
  if TInterlocked.CompareExchange(FFailed, 2, 0) = 0 then
  begin
    FError := Message;
    TInterlocked.Exchange(FFailed, 1);
  end;
  if FGroup <> nil then
    FGroup.Abort;
  FProgress.SetEvent;
  // (Copies waited for come no more: whoever waits goes on, the producer
  // raises as it next looks.)
  for var I := 0 to CopySlots - 1 do
    if TInterlocked.Exchange(FCopies[I].Pending, 0) = 1 then
      FCopies[I].Ready.SetEvent;
end;

procedure TN64RDPWorker.MakeCopy(Index: Integer);
begin
  FBus.CopyRAMTo(FCopies[Index].Target, FCopies[Index].Address, FCopies[Index].Count);
  if TInterlocked.Exchange(FCopies[Index].Pending, 0) = 1 then
    FCopies[Index].Ready.SetEvent;
end;

procedure TN64RDPWorker.CopyAt(RDP: TN64RDP; Index: Integer);
begin
  // Every band has finished the lists before (band 0 copies at the
  // barrier, while the others wait). FMakeCopy, made once (no memory manager
  // call on the band threads), copies FCopyAt, which band 0 sets.
  if FGroup = nil then
    MakeCopy(Index)
  else
  begin
    if RDP = FRDPs[0] then
      FCopyAt := Index;
    FGroup.Barrier(RDP, FMakeCopy);
  end;
end;

procedure TN64RDPWorker.QueueCopy(Target: TN64Bus; Address, Count: Cardinal; Ready: TEvent);
begin
  var Index := FCopyNext;
  if TInterlocked.CompareExchange(FCopies[Index].Pending, 0, 0) <> 0 then
    raise EN64Unsupported.Create('RDP worker: too many copies queued');
  FCopyNext := (Index + 1) mod CopySlots;
  FCopies[Index].Target := Target;
  FCopies[Index].Address := Address;
  FCopies[Index].Count := Count;
  FCopies[Index].Ready := Ready;
  TInterlocked.Exchange(FCopies[Index].Pending, 1);
  OpenSegment;
  FRing[FWrite and RingMask] := Cardinal(Index);
  Inc(FWrite);
  FRing[FHeader and RingMask] := 1 or FirstFlag or LastFlag or CopyFlag;
  Inc(FEnded);
  Publish;
end;

function TN64RDPWorker.published: Int64;
begin
  {$IFDEF CPUX64}
  // Aligned 64-bit loads are atomic and acquire-ordered on x64. Publication
  // uses Interlocked.Exchange; consumers must not request exclusive cache
  // ownership of this shared line merely to poll it. Other hosts retain
  // the RTL's atomic load and memory barriers.
  Result := FPublished;
  {$ELSE}
  Result := TInterlocked.Read(FPublished);
  {$ENDIF}
end;

function TN64RDPWorker.Failed: Boolean;
begin
  Result := TInterlocked.CompareExchange(FFailed, 0, 0) <> 0;
end;

function TN64RDPWorker.MinConsumed: Int64;
begin
  Result := TInterlocked.Read(FSlots[0].Consumed);
  for var I := 1 to High(FSlots) do
  begin
    var Value := TInterlocked.Read(FSlots[I].Consumed);
    if Value < Result then
      Result := Value;
  end;
end;

function TN64RDPWorker.Reached(Target: TWaitTarget; Value: Int64): Boolean;
begin
  for var I := 0 to High(FSlots) do
    if Target = TWaitTarget.Consumed then
    begin
      if TInterlocked.Read(FSlots[I].Consumed) < Value then
        Exit(False);
    end
    else if TInterlocked.Read(FSlots[I].Done) < Value then
      Exit(False);
  Result := True;
end;

procedure TN64RDPWorker.WaitFor(Target: TWaitTarget; Value: Int64);
begin
  // Spin briefly (the bands are usually close), then sleep until a band
  // reports progress. A failed band makes no progress: raise instead.
  var Spins := 0;
  // (Timed only when the bands are behind.)
  var Started: Int64 := 0;
  while not Reached(Target, Value) do
  begin
    if Started = 0 then
      Started := TStopwatch.GetTimeStamp;
    CheckFailure;
    if Spins < SpinRounds then
    begin
      Inc(Spins);
      YieldProcessor;
      Continue;
    end;
    TInterlocked.Exchange(FMainWaiting, 1);
    if Reached(Target, Value) or Failed then
    begin
      TInterlocked.Exchange(FMainWaiting, 0);
      Continue;
    end;
    FProgress.WaitFor(INFINITE);
  end;
  if Started <> 0 then
    Inc(FWaitTime, TStopwatch.GetTimeStamp - Started);
end;

procedure TN64RDPWorker.Reserve(Words: Integer);
begin
  // Room for Words more words; the bands free space as they all run them.
  if FWrite + Words <= FRoomUntil then
    Exit;
  FRoomUntil := MinConsumed + RingSize;
  if FWrite + Words <= FRoomUntil then
    Exit;
  WaitFor(TWaitTarget.Consumed, FWrite + Words - RingSize);
  FRoomUntil := MinConsumed + RingSize;
end;

procedure TN64RDPWorker.OpenSegment;
begin
  Reserve(3 + TN64RDP.MaxDataWords);
  FHeader := FWrite;
  Inc(FWrite);
  FWords := 0;
end;

procedure TN64RDPWorker.CloseSegment(Last: Boolean);
begin
  var Header := FWords;
  if FFirst then
    Header := Header or FirstFlag;
  if Last then
    Header := Header or LastFlag;
  FRing[FHeader and RingMask] := Header;
  FFirst := False;
end;

procedure TN64RDPWorker.Publish;
begin
  // Band 0 only: the bands wake each other (WakeBands), so a publication
  // costs this thread one wake-up at most.
  TInterlocked.Exchange(FPublished, FWrite);
  Signal(FSlots[0].Sleeping, FSlots[0].DataReady);
end;

procedure TN64RDPWorker.WakeBands(Index: Integer);
begin
  // Band Index, taking a segment, wakes bands 2 Index + 1 and 2 Index + 2:
  // from band 0 every band in turn. A band sleeps only after setting its flag
  // and finding nothing published, and this runs only after the segment was
  // published, so none sleeps through it.
  for var C := 2 * Index + 1 to Min(2 * Index + 2, High(FSlots)) do
    Signal(FSlots[C].Sleeping, FSlots[C].DataReady);
end;

procedure TN64RDPWorker.BeginList;
begin
  FOpen := True;
  FFirst := True;
  OpenSegment;
end;

procedure TN64RDPWorker.Put(W0, W1: Cardinal);
begin
  // Room for the pair and any data words of a command it completes: the
  // full RDPs read those from the same segment.
  if FWrite + 2 + TN64RDP.MaxDataWords > FRoomUntil then
  begin
    FRoomUntil := MinConsumed + RingSize;
    if FWrite + 2 + TN64RDP.MaxDataWords > FRoomUntil then
    begin
      // A long list fills the ring: hand over what is queued (the bands
      // cannot run an unpublished segment) and go on in a new segment.
      CloseSegment(False);
      Publish;
      OpenSegment;
    end;
  end;
  FRing[FWrite and RingMask] := W0;
  FRing[(FWrite + 1) and RingMask] := W1;
  Inc(FWrite, 2);
  Inc(FWords, 2);
end;

procedure TN64RDPWorker.PutData(Value: Cardinal);
begin
  FRing[FWrite and RingMask] := Value;
  Inc(FWrite);
  Inc(FWords);
end;

procedure TN64RDPWorker.EndList;
begin
  CloseSegment(True);
  FOpen := False;
  Inc(FEnded);
  Publish;
  if FStress then
    StressDelay(FProducerNoise);
end;

function TN64RDPWorker.Done: Int64;
begin
  Result := TInterlocked.Read(FSlots[0].Done);
  for var I := 1 to High(FSlots) do
  begin
    var Value := TInterlocked.Read(FSlots[I].Done);
    if Value < Result then
      Result := Value;
  end;
end;

procedure TN64RDPWorker.CheckFailure;
begin
  if TInterlocked.CompareExchange(FFailed, 0, 0) = 1 then
    raise EN64Unsupported.Create('RDP worker: ' + FError);
end;

procedure TN64RDPWorker.WaitList(List: Int64);
begin
  if FOpen and (List > FEnded) then
  begin
    // A command word on a line that an earlier command of the same list
    // writes: run everything queued so far, then continue the list.
    CloseSegment(False);
    Publish;
    WaitFor(TWaitTarget.Consumed, FWrite);
    OpenSegment;
  end
  else
    WaitFor(TWaitTarget.Done, List);
end;

procedure TN64RDPWorker.Drain;
begin
  WaitFor(TWaitTarget.Consumed, FWrite);
  CheckFailure;
end;

procedure TN64RDPWorker.MergeState;
begin
  if FGroup <> nil then
    FGroup.MergeInto(FRDPs[0]);
end;

procedure TN64RDPWorker.Resync;
begin
  if FGroup = nil then
    Exit;
  for var I := 1 to High(FRDPs) do
    FRDPs[I].Assign(FRDPs[0]);
  FGroup.Restart;
end;

end.

