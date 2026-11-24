unit PS2.DMAC;

// EE DMA controller: ten channels (VIF0, VIF1, GIF, fromIPU, toIPU, SIF0,
// SIF1, SIF2, fromSPR, toSPR) with normal, chain and interleave modes, the
// call/return stack, MFIFO, stall control (D_STADR), D_CTRL/D_STAT/D_PCR/
// D_SQWC and the interrupt line (INT1).
// Data moves when a channel starts (or a stalled device takes more); the
// channel ends after the bus time of its transfer has passed.
// References: EE User's Manual (DMAC chapter), ps2tek.
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
  System.Math,
  Core.Snapshots,
  PS2.Types,
  PS2.Scheduler,
  PS2.VU1Domain;

const
  DMAVIF0 = 0;
  DMAVIF1 = 1;
  DMAGIF = 2;
  DMAFromIPU = 3;
  DMAToIPU = 4;
  DMASIF0 = 5;
  DMASIF1 = 6;
  DMASIF2 = 7;
  DMAFromSPR = 8;
  DMAToSPR = 9;

  CHCRDir = $1;
  CHCRTTE = $40;
  CHCRTIE = $80;
  CHCRSTR = $100;

type
  // A device on a channel. Push takes quadwords from memory (returns how many
  // it accepted: fewer means it stalls and the channel waits for Resume);
  // Pull delivers quadwords to memory.
  TPS2DMAPort = class
  public
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; virtual;
    function Pull(Channel: Integer; Data: PByte; Count: Integer): Integer; virtual;
    // The DMA tag of a chain transfer (before its data), for ports that
    // look at it (VIF with TTE, SIF1).
    procedure Tag(Channel: Integer; const Tag: TPS2Reg128); virtual;
    // Whether the device takes a tag's words now (TTE): while it does not,
    // the channel waits before the tag, as with data it has no room for.
    function TagRoom(Channel: Integer): Boolean; virtual;
    // EE cycles the device spent on the data taken since the last call
    // (the channel ends no earlier).
    function TakeBusyCycles: Int64; virtual;
    // Whether those cycles come from the GS (its drawing time); taken.
    function BusyFromGS: Boolean; virtual;
    // Running ahead of the EE, the device keeps a copy of what it takes
    // that the EE side checks (else the channel reads from a copy).
    function ChecksAhead: Boolean; virtual;
  end;

  TPS2DMAChannel = record
    CHCR, MADR, QWC, TADR, ASR0, ASR1, SADR: Cardinal;
    // Chain: the current tag ended the chain once its data is done.
    TagEnd: Boolean;
    // Data moved; the channel ends at DoneAt.
    Finishing: Boolean;
    DoneAt: Int64;
    // When STR was set: the bus time of the data counts from here.
    StartedAt: Int64;
  end;

  // Experimental: running ahead, channels 1 and 2 read memory from a copy
  // (Size bytes at Source; Key: data 1/2, tags 3/4; Token for the used call,
  // with the bytes the device took).
  TPS2DMAAheadRead = function(Key: Integer; Source: PByte; Size: Integer; out Token: Int64): PByte of object;
  TPS2DMAAheadReadUsed = procedure(Token: Int64; Used: Integer) of object;
  // Running ahead: how many of Count quadwords at Source the device Key is
  // given at once (1..Count).
  TPS2DMAAheadLimit = function(Key: Integer; Source: PByte; Count: Integer): Integer of object;
  // Running ahead, a decision from an EE-side register: whether its value at
  // Source, in the MFIFO ring (Mask, Offset), is Value (Decided: as found
  // now; the result: that, or what was decided when the domain does its
  // events again).
  TPS2DMAAheadCheck = function(Source: PCardinal; Mask, Offset, Value: Cardinal; Decided: Boolean): Boolean of object;

  TPS2DMAC = class
  private
    FScheduler: TPS2Scheduler;
    FRAM, FScratch: PByte;
    FRAMGen: PCardinal;
    FOnInterrupt: TProc<Boolean>;
    FLine: Boolean;
    // The last tag each channel read (channels 1 and 2 may read theirs on
    // the VU1 domain's thread).
    FLastTag: array[0..9] of TPS2Reg128;
    FRunning, FAgain: array[0..9] of Boolean;
    procedure UpdateInterrupt;
    function Memory(Address: Cardinal; out Valid: Boolean): PByte;
    procedure MarkRAM(Address, Size: Cardinal);
    procedure Run(N: Integer);
    function TransferData(N: Integer): Boolean;
    function ReadTag(N: Integer): Boolean;
    procedure Finish(N: Integer; Cycles: Int64);
    procedure RunSPR(N: Integer);
    procedure RunSIF0;
    procedure RunChannel(N: Integer);
    procedure ScheduleNext;
    // The next end of the domain's channels (Domain) or of the others.
    procedure ScheduleGroup(Domain: Boolean);
    // D_STAT bits set by channel N's transfer: with the domain running
    // ahead, a channel of its own hands them over (OnAheadStat).
    procedure ChannelStat(N: Integer; Mask: Cardinal; Update: Boolean);
    function Drain: Integer;
    function Ring(Address: Cardinal): Cardinal; inline;
    function StallSource: Integer;
    function StallDrain: Integer;
    function StallControlled(N: Integer): Boolean;
    procedure SourceMoved(N: Integer);
    function DrainEmpty(N: Integer): Boolean;
    procedure ResumeDrain(N: Integer);
    function DomainChannel(N: Integer): Boolean;
    function ChannelNow(N: Integer): Int64; inline;
    function DomainRegister(Offset: Cardinal): Boolean;
    procedure CheckDomain;
  public
    Ch: array[0..9] of TPS2DMAChannel;
    CTRL, STAT, PCR, SQWC, RBSR, RBOR, STADR, ENABLE: Cardinal;
    Ports: array[0..9] of TPS2DMAPort;
    // Quadwords moved since the channel started (for bus time).
    Moved: array[0..9] of Integer;
    // Diagnostics: writes to RAM covering WatchAddress go to WatchLog.
    WatchAddress: Cardinal;
    WatchLog: TStrings;
    // Diagnostics: register writes and ends of the channels in LogMask.
    Log: TStrings;
    LogMask: Cardinal;
    // SIF0 runs as a destination chain from its port (the IOP runs its own
    // kernel); otherwise the high-level IOP writes through SIF0Write.
    SIF0Chain: Boolean;
    // Channels 1 and 2 (and the registers they share) belong to the VU1
    // domain and take its time; their ends are events of DomainScheduler
    // (when assigned: the main scheduler's DMAC event ends the others).
    Domain: TPS2VU1Domain;
    DomainScheduler: TPS2Scheduler;
    // Experimental: the domain's D_STAT bits while it runs ahead (the EE
    // side sets them at their time, SetStat).
    OnAheadStat: TProc<Cardinal>;
    // Running ahead, the end of channel 1 or 2 whose device's time comes
    // from the GS waits for the GS side: OnAheadPortEnd hands it over (the
    // channel, its quadwords moved), the EE side ends it (PortDoneAt,
    // EndPort); meanwhile the domain leaves it alone.
    OnAheadPortEnd: TProc<Integer, Integer>;
    PortOnEE: array[DMAVIF1..DMAGIF] of Boolean;
    // When the EE side ends them (PS2Never: not known yet or none), and
    // when it last ended them (PS2Never: not since the domain went ahead).
    PortEndAt, PortEndedAt: array[DMAVIF1..DMAGIF] of Int64;
    OnAheadRead: TPS2DMAAheadRead;
    OnAheadReadUsed: TPS2DMAAheadReadUsed;
    OnAheadLimit: TPS2DMAAheadLimit;
    OnAheadCheck: TPS2DMAAheadCheck;
    // Running ahead, the EE side has a channel of the domain try again
    // (fromSPR filled the ring it drains, a shared register was written):
    // what that does to the channel as it is at the EE's time.
    OnAheadResume: TProc<Integer>;
    // The MFIFO drain waits on the empty ring (until it runs again).
    DrainWaiting: array[DMAVIF1..DMAGIF] of Boolean;
    procedure SetStat(Mask: Cardinal);
    procedure PortDoneAt(N, Moved: Integer; Busy, Now: Int64);
    // The earliest of PortEndAt.
    function PortEnd: Int64;
    // Whether the MFIFO ring is empty for a drain whose next tag is at TADR
    // (fromSPR's address as the EE side has it now).
    function RingEmptyAt(TADR: Cardinal): Boolean;
    // Ends those due by UpTo.
    procedure EndPorts(UpTo: Int64);
    constructor Create(Scheduler: TPS2Scheduler; RAM, Scratch: PByte; RAMGen: PCardinal);
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    // A channel register (Offset within the channel's block).
    class function ChannelRegister(const C: TPS2DMAChannel; Offset: Cardinal): Cardinal; static;
    procedure Write(Address, Value: Cardinal);
    // Scheduler event: channels whose bus time passed end now (with
    // DomainOnly, channels 1 and 2 only).
    procedure Event(DomainOnly: Boolean = False);
    // When channel 1 or 2 ends next (PS2Never: neither is ending).
    function DomainDue: Int64;
    // After a snapshot load: the channels' end events from their state.
    procedure Reschedule;
    // A stalled device can take data again.
    procedure Resume(N: Integer);
    // SIF0 (IOP to EE): writes Size bytes at Dest (physical); with IRQ the
    // destination chain ends there (STR clear, CIS5). False when the channel
    // is not armed.
    function SIF0Ready: Boolean;
    procedure SIF0Write(Dest: Cardinal; Data: PByte; Size: Integer; IRQ: Boolean);
    procedure SetChannelInterrupt(N: Integer);
    // RAM written outside the CPU and DMA (high-level IOP services).
    procedure MarkWritten(Address, Size: Cardinal);
    function CPCond0: Boolean;
    procedure SerializeState(State: TStateArchive);
    property OnInterrupt: TProc<Boolean> read FOnInterrupt write FOnInterrupt;
    property Line: Boolean read FLine;
  end;

implementation

const
  ChannelBase: array[0..9] of Cardinal = ($8000, $9000, $A000, $B000, $B400, $C000, $C400, $C800, $D000, $D400);
  CyclesPerQuad = 2;

{ TPS2DMAPort }

function TPS2DMAPort.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := Count;
end;

function TPS2DMAPort.Pull(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  FillChar(Data^, Count * 16, 0);
  Result := Count;
end;

procedure TPS2DMAPort.Tag(Channel: Integer; const Tag: TPS2Reg128);
begin
end;

function TPS2DMAPort.TakeBusyCycles: Int64;
begin
  Result := 0;
end;

function TPS2DMAPort.BusyFromGS: Boolean;
begin
  Result := False;
end;

function TPS2DMAPort.TagRoom(Channel: Integer): Boolean;
begin
  Result := True;
end;

function TPS2DMAPort.ChecksAhead: Boolean;
begin
  Result := False;
end;

{ TPS2DMAC }

constructor TPS2DMAC.Create(Scheduler: TPS2Scheduler; RAM, Scratch: PByte; RAMGen: PCardinal);
begin
  inherited Create;
  FScheduler := Scheduler;
  FRAM := RAM;
  FScratch := Scratch;
  FRAMGen := RAMGen;
  Reset;
end;

procedure TPS2DMAC.Reset;
begin
  for var N := 0 to 9 do
  begin
    Ch[N] := Default(TPS2DMAChannel);
    Moved[N] := 0;
  end;
  CTRL := 0;
  STAT := 0;
  PCR := 0;
  SQWC := 0;
  RBSR := 0;
  RBOR := 0;
  STADR := 0;
  ENABLE := $1201;
  FLine := False;
  for var N := DMAVIF1 to DMAGIF do
  begin
    PortOnEE[N] := False;
    PortEndAt[N] := PS2Never;
    PortEndedAt[N] := PS2Never;
    DrainWaiting[N] := False;
  end;
  FScheduler.Cancel(TPS2Event.DMAC);
  if DomainScheduler <> nil then
    DomainScheduler.Cancel(TPS2Event.DMAC);
end;

procedure TPS2DMAC.UpdateInterrupt;
begin
  var Active := ((STAT and (STAT shr 16) and $63FF) <> 0) or ((STAT and $8000) <> 0);
  if Active <> FLine then
  begin
    FLine := Active;
    if Assigned(FOnInterrupt) then
      FOnInterrupt(Active);
  end;
end;

procedure TPS2DMAC.SetChannelInterrupt(N: Integer);
begin
  STAT := STAT or (Cardinal(1) shl N);
  UpdateInterrupt;
end;

procedure TPS2DMAC.MarkWritten(Address, Size: Cardinal);
begin
  if Size > 0 then
    MarkRAM(Address and $01FFFFFF, Size);
end;

function TPS2DMAC.CPCond0: Boolean;
begin
  CheckDomain;
  Result := ((PCR and $3FF) and not STAT and $3FF) = 0;
end;

function TPS2DMAC.Memory(Address: Cardinal; out Valid: Boolean): PByte;
begin
  Valid := True;
  if (Address and $80000000) <> 0 then
    Exit(FScratch + (Address and $3FF0));
  Address := Address and $7FFFFFF0;
  if Address < PS2RAMSize then
    Exit(FRAM + Address);
  Valid := False;
  Result := nil;
end;

procedure TPS2DMAC.MarkRAM(Address, Size: Cardinal);
begin
  // A stalled input port may return no quadwords.
  if (Size = 0) or ((Address and $80000000) <> 0) then
    Exit;
  Address := Address and $01FFFFFF;
  if (WatchLog <> nil) and (WatchAddress >= Address) and (WatchAddress < Address + Size) then
    WatchLog.Add(
      Format('%d dmac write %.8x size %x (ch3 %x ch5 %x)', [FScheduler.Now, Address, Size, Ch[3].CHCR, Ch[5].CHCR])
    );
  var First := Address shr 12;
  var Last := (Address + Size - 1) shr 12;
  if Last > 8191 then
    Last := 8191;
  for var P := First to Last do
    Inc(FRAMGen[P]);
end;

// The time of channel N: the VU1 domain's for channels 1 and 2.
function TPS2DMAC.ChannelNow(N: Integer): Int64;
begin
  if (Domain <> nil) and ((N = DMAVIF1) or (N = DMAGIF)) then
    Result := Domain.Now
  else
    Result := FScheduler.Now;
end;

// Registers of channels 1 and 2 and the shared ones (D_CTRL.. writes run
// every channel).
function TPS2DMAC.DomainRegister(Offset: Cardinal): Boolean;
begin
  Result :=
    (Offset >= $E000) or ((Offset and $FF00) = ChannelBase[DMAVIF1]) or ((Offset and $FF00) = ChannelBase[DMAGIF]);
end;

// Checked builds: the caller is inside the domain. (Running ahead, the EE
// side reaches only what the domain's thread leaves alone, without entering
// it: the depth is that thread's then.)
procedure TPS2DMAC.CheckDomain;
begin
{$IF DEFINED(PS2_CHECKED) OR DEFINED(PS2_DOMAIN_CHECK)}
  if (Domain <> nil) and not Domain.Ahead then
    Domain.Check;
{$ENDIF}
end;

function TPS2DMAC.Read(Address: Cardinal): Cardinal;
begin
  var Offset := Address and $FFFF;
  if DomainRegister(Offset) then
    CheckDomain;
  if Offset >= $E000 then
  begin
    case Offset of
      $E000: Result := CTRL;
      $E010: Result := STAT;
      $E020: Result := PCR;
      $E030: Result := SQWC;
      $E040: Result := RBSR;
      $E050: Result := RBOR;
      $E060: Result := STADR;
    else
      Result := 0;
    end;
    Exit;
  end;
  for var N := 0 to 9 do
    if (Offset and $FF00) = ChannelBase[N] then
      Exit(ChannelRegister(Ch[N], Offset and $FF));
  Result := 0;
end;

class function TPS2DMAC.ChannelRegister(const C: TPS2DMAChannel; Offset: Cardinal): Cardinal;
begin
  case Offset of
    $00: Result := C.CHCR;
    $10: Result := C.MADR;
    $20: Result := C.QWC;
    $30: Result := C.TADR;
    $40: Result := C.ASR0;
    $50: Result := C.ASR1;
    $80: Result := C.SADR;
  else
    Result := 0;
  end;
end;

procedure TPS2DMAC.Write(Address, Value: Cardinal);
begin
  var Offset := Address and $FFFF;
  if DomainRegister(Offset) then
    CheckDomain;
  if Offset >= $E000 then
  begin
    case Offset of
      $E000: CTRL := Value;
      $E010:
      begin
        // Status bits clear with 1; mask bits toggle with 1.
        STAT := (STAT and not (Value and $0000E3FF)) xor (Value and $63FF0000);
        UpdateInterrupt;
      end;
      $E020: PCR := Value;
      $E030: SQWC := Value;
      $E040: RBSR := Value;
      $E050: RBOR := Value;
      $E060: STADR := Value;
    end;
    // (Ahead, a channel of the domain is its thread's: OnAheadResume.)
    for var N := 0 to 9 do
      if DomainChannel(N) and (Domain <> nil) and Domain.Ahead and Assigned(OnAheadResume) then
        OnAheadResume(N)
      else if ((Ch[N].CHCR and CHCRSTR) <> 0) and not Ch[N].Finishing then
        Run(N);
    Exit;
  end;
  for var N := 0 to 9 do
    if (Offset and $FF00) = ChannelBase[N] then
    begin
      if (Log <> nil) and (((LogMask shr N) and 1) <> 0) and (Log.Count < 200000) then
        Log.Add(
          Format(
            '%d ch%d w %.2x = %.8x (chcr %.8x madr %.8x qwc %x tadr %.8x)',
            [FScheduler.Now, N, Offset and $FF, Value, Ch[N].CHCR, Ch[N].MADR, Ch[N].QWC, Ch[N].TADR]
          )
        );
      case Offset and $FF of
        $00:
        begin
          if DomainChannel(N) and PortOnEE[N] then
          begin
            // (Its end was the EE side's: this write ends it as below.)
            PortOnEE[N] := False;
            PortEndAt[N] := PS2Never;
          end;
          var Was := (Ch[N].CHCR and CHCRSTR) <> 0;
          if Was and Ch[N].Finishing and ((Value and CHCRSTR) <> 0) then
          begin
            // The transfer has moved all its data and only waits out its
            // bus time: it ends now and the new one starts.
            Ch[N].Finishing := False;
            Ch[N].CHCR := Ch[N].CHCR and not Cardinal(CHCRSTR);
            STAT := STAT or (Cardinal(1) shl N);
            UpdateInterrupt;
            ScheduleGroup(DomainChannel(N));
            Was := False;
          end;
          if Was and ((Value and CHCRSTR) = 0) then
          begin
            // Stopping a channel: as STR is the only bit that may change
            // while it runs, the mode, direction and tag stay (software
            // that saves CHCR and later sets STR again resumes the chain).
            Ch[N].CHCR := Ch[N].CHCR and not Cardinal(CHCRSTR);
            Ch[N].Finishing := False;
            Exit;
          end;
          if Was then
          begin
            // Only STR may change while the channel runs.
            Exit;
          end;
          Ch[N].CHCR := Value;
          if (Value and CHCRSTR) <> 0 then
          begin
            Ch[N].TagEnd := False;
            // A chain started with data left (QWC) resumes its current tag:
            // that data goes first, then the tag's ID in CHCR decides as
            // after any tag: refe and end, or IRQ with TIE, end the
            // transfer instead of reading the next tag.
            if (((Value shr 2) and 3) = 1) and (Ch[N].QWC > 0) then
            begin
              var Id := (Value shr 28) and 7;
              Ch[N].TagEnd := (Id = 0) or (Id = 7) or (((Value and $80000000) <> 0) and ((Value and CHCRTIE) <> 0));
            end;
            Ch[N].Finishing := False;
            Ch[N].StartedAt := ChannelNow(N);
            Moved[N] := 0;
            Run(N);
          end;
        end;
        $10:
          if N >= DMAFromSPR then
            Ch[N].MADR := Value and $7FFFFFF0
          else
            Ch[N].MADR := Value and $FFFFFFF0;
        $20: Ch[N].QWC := Value and $FFFF;
        $30: Ch[N].TADR := Value and $FFFFFFF0;
        $40: Ch[N].ASR0 := Value and $FFFFFFF0;
        $50: Ch[N].ASR1 := Value and $FFFFFFF0;
        $80: Ch[N].SADR := Value and $3FF0;
      end;
      Exit;
    end;
end;

// The MFIFO drain channel (D_CTRL.MFD): VIF1, GIF or -1.
function TPS2DMAC.Drain: Integer;
begin
  case (CTRL shr 2) and 3 of
    2: Result := DMAVIF1;
    3: Result := DMAGIF;
  else
    Result := -1;
  end;
end;

function TPS2DMAC.Ring(Address: Cardinal): Cardinal;
begin
  Result := (Address and RBSR) or RBOR;
end;

// Stall control (EE User's Manual 5.3.2): the source channel (D_CTRL.STS:
// SIF0, fromSPR, fromIPU) copies its MADR to D_STADR as it writes normal
// mode data or cnts packets; the drain channel (D_CTRL.STD: VIF1, GIF,
// SIF1) moves normal mode data or refs packets in 8-quadword slices only
// while MADR + 8 quadwords <= D_STADR, else it waits with D_STAT.SIS set.
// SIF0 data comes from the high-level IOP without tags, so it never moves
// D_STADR.
function TPS2DMAC.StallSource: Integer;
begin
  case (CTRL shr 4) and 3 of
    1: Result := DMASIF0;
    2: Result := DMAFromSPR;
    3: Result := DMAFromIPU;
  else
    Result := -1;
  end;
end;

function TPS2DMAC.StallDrain: Integer;
begin
  case (CTRL shr 6) and 3 of
    1: Result := DMAVIF1;
    2: Result := DMAGIF;
    3: Result := DMASIF1;
  else
    Result := -1;
  end;
end;

// Whether channel N's current data is under stall control: normal mode, or
// in chain mode a refs packet (drain, source chain) or a cnts packet
// (source, destination chain).
function TPS2DMAC.StallControlled(N: Integer): Boolean;
begin
  case (Ch[N].CHCR shr 2) and 3 of
    0: Result := True;
    1:
      begin
        var Id := (Ch[N].CHCR shr 28) and 7;
        if N = StallDrain then
          Result := Id = 4
        else
          Result := Id = 1;
      end;
  else
    Result := False;
  end;
end;

// The stall source wrote up to its MADR: D_STADR follows and a drain
// waiting on it goes on.
procedure TPS2DMAC.SourceMoved(N: Integer);
begin
  if (N <> StallSource) or not StallControlled(N) then
    Exit;
  STADR := Ch[N].MADR and $7FFFFFF0;
  var D := StallDrain;
  if D >= 0 then
    Resume(D);
end;

// The data has moved; the channel ends once its bus time from the start
// has passed. A transfer that waited for its device (a full FIFO, a masked
// path) has spent that time already and ends right after its last data:
// programs that stop a channel and restart it from its tag address see it
// ended at an end tag (refe, end) rather than past it.
procedure TPS2DMAC.Finish(N: Integer; Cycles: Int64);
begin
  Ch[N].Finishing := True;
  Ch[N].DoneAt := Max(Ch[N].StartedAt + Cycles, ChannelNow(N) + 8);
  ScheduleGroup(DomainChannel(N));
end;

function TPS2DMAC.DomainChannel(N: Integer): Boolean;
begin
  Result := (DomainScheduler <> nil) and ((N = DMAVIF1) or (N = DMAGIF));
end;

procedure TPS2DMAC.ScheduleNext;
begin
  ScheduleGroup(False);
  if DomainScheduler <> nil then
    ScheduleGroup(True);
end;

procedure TPS2DMAC.ScheduleGroup(Domain: Boolean);
begin
  var Next := PS2Never;
  for var K := 0 to 9 do
    // (PortOnEE first: the EE side ending the channel clears it last.)
    if not (DomainChannel(K) and PortOnEE[K])
      and Ch[K].Finishing
      and (DomainChannel(K) = Domain)
      and (Ch[K].DoneAt < Next) then
      Next := Ch[K].DoneAt;
  var S := FScheduler;
  if Domain then
    S := DomainScheduler;
  if Next = PS2Never then
    S.Cancel(TPS2Event.DMAC)
  else if Self.Domain <> nil then
    S.ScheduleAt(TPS2Event.DMAC, Next)
  else
    S.Schedule(TPS2Event.DMAC, Next);
end;

procedure TPS2DMAC.ChannelStat(N: Integer; Mask: Cardinal; Update: Boolean);
begin
  if DomainChannel(N) and Domain.Ahead and Assigned(OnAheadStat) then
    OnAheadStat(Mask)
  else
  begin
    STAT := STAT or Mask;
    if Update then
      UpdateInterrupt;
  end;
end;

procedure TPS2DMAC.SetStat(Mask: Cardinal);
begin
  STAT := STAT or Mask;
  UpdateInterrupt;
end;

// Channel N's end as Finish has it (Busy: the GS time its data took).
procedure TPS2DMAC.PortDoneAt(N, Moved: Integer; Busy, Now: Int64);
begin
  var Cycles := Max(Int64(Moved) * CyclesPerQuad, Busy) + 8;
  Ch[N].DoneAt := Max(Ch[N].StartedAt + Cycles, Now + 8);
  PortEndAt[N] := Ch[N].DoneAt;
end;

function TPS2DMAC.PortEnd: Int64;
begin
  Result := Min(PortEndAt[DMAVIF1], PortEndAt[DMAGIF]);
end;

function TPS2DMAC.RingEmptyAt(TADR: Cardinal): Boolean;
begin
  Result := Ring(TADR) = Ring(Ch[DMAFromSPR].MADR);
end;

procedure TPS2DMAC.EndPorts(UpTo: Int64);
begin
  // (In channel order, as the event ends them.)
  for var N := DMAVIF1 to DMAGIF do
    if PortEndAt[N] <= UpTo then
    begin
      PortEndedAt[N] := PortEndAt[N];
      // (STR first: the domain resuming the channel meanwhile finds it
      // ended.)
      Ch[N].CHCR := Ch[N].CHCR and not Cardinal(CHCRSTR);
      Ch[N].Finishing := False;
      PortOnEE[N] := False;
      PortEndAt[N] := PS2Never;
      SetStat(Cardinal(1) shl N);
    end;
end;

procedure TPS2DMAC.Reschedule;
begin
  ScheduleNext;
end;

function TPS2DMAC.DomainDue: Int64;
begin
  Result := PS2Never;
  for var N in [DMAVIF1, DMAGIF] do
    if Ch[N].Finishing and (Ch[N].DoneAt < Result) then
      Result := Ch[N].DoneAt;
end;

procedure TPS2DMAC.Event(DomainOnly: Boolean);
begin
  if DomainOnly or (DomainScheduler = nil) then
    Domain.Check;
  for var N := 0 to 9 do
    // (PortOnEE first: the EE side ending the channel clears it last.)
    if not (DomainChannel(N) and PortOnEE[N])
      and Ch[N].Finishing
      and (Ch[N].DoneAt <= ChannelNow(N))
      and ((DomainScheduler = nil) and (not DomainOnly or (N = DMAVIF1) or (N = DMAGIF))
        or (DomainScheduler <> nil) and (DomainChannel(N) = DomainOnly)) then
    begin
      if (Log <> nil) and (((LogMask shr N) and 1) <> 0) and (Log.Count < 200000) then
        Log.Add(Format('%d ch%d end (madr %.8x)', [FScheduler.Now, N, Ch[N].MADR]));
      Ch[N].Finishing := False;
      Ch[N].CHCR := Ch[N].CHCR and not Cardinal(CHCRSTR);
      ChannelStat(N, Cardinal(1) shl N, False);
    end;
  if not (DomainOnly and (Domain <> nil) and Domain.Ahead) then
    UpdateInterrupt;
  if DomainScheduler = nil then
    ScheduleNext
  else
    ScheduleGroup(DomainOnly);
end;

// Whether the MFIFO ring the drain N reads is empty (fromSPR's address,
// the EE side's, at its next tag).
function TPS2DMAC.DrainEmpty(N: Integer): Boolean;
begin
  Result := Ring(Ch[N].TADR) = Ring(Ch[DMAFromSPR].MADR);
  if DomainChannel(N) and Domain.Ahead and Assigned(OnAheadCheck) then
    Result := OnAheadCheck(@Ch[DMAFromSPR].MADR, RBSR, RBOR, Ring(Ch[N].TADR), Result);
end;

procedure TPS2DMAC.ResumeDrain(N: Integer);
begin
  if DomainChannel(N) and Domain.Ahead and Assigned(OnAheadResume) then
    OnAheadResume(N)
  else
    Resume(N);
end;

procedure TPS2DMAC.Resume(N: Integer);
begin
  if ((Ch[N].CHCR and CHCRSTR) <> 0) and not Ch[N].Finishing then
    Run(N);
end;

// Moves the pending QWC of channel N; False when the port stalled.
function TPS2DMAC.TransferData(N: Integer): Boolean;
begin
  Result := True;
  while Ch[N].QWC > 0 do
  begin
    var Valid: Boolean;
    var P := Memory(Ch[N].MADR, Valid);
    if not Valid then
    begin
      // Bus error: BEIS.
      Ch[N].QWC := 0;
      ChannelStat(N, $8000, True);
      Exit;
    end;
    // Stay within one RAM/SPR region per step.
    var Count: Integer;
    if (Ch[N].MADR and $80000000) <> 0 then
      Count := Integer(((($4000 - (Ch[N].MADR and $3FF0)) shr 4)))
    else
      Count := Integer(((PS2RAMSize - (Ch[N].MADR and $01FFFFF0)) shr 4));
    if Count > Integer(Ch[N].QWC) then
      Count := Integer(Ch[N].QWC);
    var ToMemory :=
      ((N = DMAVIF1) or (N = DMASIF2)) and ((Ch[N].CHCR and CHCRDir) = 0) or (N = DMAFromIPU) or (N = DMASIF0);
    if not ToMemory and (N = StallDrain) and StallControlled(N) then
    begin
      // Whole 8-quadword slices that end at or before D_STADR.
      var Allowed: Int64 := 0;
      var From: Int64 := Ch[N].MADR and $7FFFFFF0;
      while (Allowed < Count) and (From + (Allowed + 8) * 16 <= Int64(STADR and $7FFFFFF0)) do
        Inc(Allowed, 8);
      if Allowed = 0 then
      begin
        ChannelStat(N, $2000, True);
        Exit(False);
      end;
      if Allowed < Count then
        Count := Integer(Allowed);
    end;
    var Done: Integer;
    if Ports[N] = nil then
      Done := Count
    else if ToMemory then
    begin
      Done := Ports[N].Pull(N, P, Count);
      MarkRAM(Ch[N].MADR, Cardinal(Done) * 16);
    end
    else if DomainChannel(N) and Domain.Ahead and Assigned(OnAheadRead) and not Ports[N].ChecksAhead then
    begin
      // (In pieces: the device often takes a few quadwords and waits, and
      // every copy is compared with memory.)
      if Assigned(OnAheadLimit) then
        Count := OnAheadLimit(N, P, Count);
      var Token: Int64;
      Done := Ports[N].Push(N, OnAheadRead(N, P, Count * 16, Token), Count);
      OnAheadReadUsed(Token, Done * 16);
    end
    else
      Done := Ports[N].Push(N, P, Count);
    Inc(Moved[N], Done);
    Ch[N].MADR := Add32(Ch[N].MADR, Cardinal(Done) * 16);
    Ch[N].QWC := Sub32(Ch[N].QWC, Cardinal(Done));
    if ToMemory and (Done > 0) then
      SourceMoved(N);
    if Done < Count then
      Exit(False);
  end;
end;

// Reads the next source-chain tag; False when the chain has ended.
function TPS2DMAC.ReadTag(N: Integer): Boolean;
begin
  var MFIFO := N = Drain;
  if MFIFO then
    Ch[N].TADR := Ring(Ch[N].TADR);
  var Valid: Boolean;
  var P := Memory(Ch[N].TADR, Valid);
  if not Valid then
  begin
    ChannelStat(N, $8000, True);
    Exit(False);
  end;
  var T: TPS2Reg128;
  if DomainChannel(N) and Domain.Ahead and Assigned(OnAheadRead) then
  begin
    var Token: Int64;
    T := PPS2Reg128(OnAheadRead(N + 2, P, 16, Token))^;
    OnAheadReadUsed(Token, 16);
  end
  else
    T := PPS2Reg128(P)^;
  FLastTag[N] := T;
  var Lo := Cardinal(T.Lo);
  var Addr := Cardinal(T.Lo shr 32);
  var Id := (Lo shr 28) and 7;
  if (Log <> nil) and (((LogMask shr N) and 1) <> 0) and (Log.Count < 200000) then
    Log.Add(
      Format('%d ch%d tag at %.8x: id %d qwc %x addr %.8x', [FScheduler.Now, N, Ch[N].TADR, Id, Lo and $FFFF, Addr])
    );
  Ch[N].CHCR := (Ch[N].CHCR and $0000FFFF) or (Lo and $FFFF0000);
  Ch[N].QWC := Lo and $FFFF;
  var TagAddr := Ch[N].TADR;
  case Id of
    0:
    begin
      Ch[N].MADR := Addr;
      Ch[N].TADR := TagAddr + 16;
      Ch[N].TagEnd := True;
    end;
    1:
    begin
      Ch[N].MADR := TagAddr + 16;
      Ch[N].TADR := TagAddr + 16 + Ch[N].QWC * 16;
    end;
    2:
    begin
      Ch[N].MADR := TagAddr + 16;
      Ch[N].TADR := Addr;
    end;
    3, 4:
    begin
      Ch[N].MADR := Addr;
      Ch[N].TADR := TagAddr + 16;
    end;
    5:
    begin
      Ch[N].MADR := TagAddr + 16;
      var Next := TagAddr + 16 + Ch[N].QWC * 16;
      var Asp := (Ch[N].CHCR shr 4) and 3;
      if Asp = 0 then
        Ch[N].ASR0 := Next
      else
        Ch[N].ASR1 := Next;
      Ch[N].CHCR := (Ch[N].CHCR and not Cardinal($30)) or ((Asp + 1) shl 4);
      Ch[N].TADR := Addr;
    end;
    6:
    begin
      Ch[N].MADR := TagAddr + 16;
      var Asp := (Ch[N].CHCR shr 4) and 3;
      if Asp = 2 then
      begin
        Ch[N].TADR := Ch[N].ASR1;
        Ch[N].CHCR := (Ch[N].CHCR and not Cardinal($30)) or (1 shl 4);
      end
      else if Asp = 1 then
      begin
        Ch[N].TADR := Ch[N].ASR0;
        Ch[N].CHCR := Ch[N].CHCR and not Cardinal($30);
      end
      else
        Ch[N].TagEnd := True;
    end;
    7:
    begin
      Ch[N].MADR := TagAddr + 16;
      Ch[N].TagEnd := True;
    end;
  end;
  if MFIFO then
  begin
    // Data following the tag lives in the ring too.
    if Id in [1, 2, 7] then
      Ch[N].MADR := Ring(Ch[N].MADR);
    Ch[N].TADR := Ring(Ch[N].TADR);
  end;
  if ((Lo and $80000000) <> 0) and ((Ch[N].CHCR and CHCRTIE) <> 0) then
    Ch[N].TagEnd := True;
  if (Ports[N] <> nil) and ((Ch[N].CHCR and CHCRTTE) <> 0) then
    Ports[N].Tag(N, T);
  Result := True;
end;

procedure TPS2DMAC.RunSPR(N: Integer);
begin
  // fromSPR: SPR (SADR) to memory (MADR); toSPR: memory to SPR. Normal,
  // chain (toSPR source chain, fromSPR destination chain) and interleave.
  var Mode := (Ch[N].CHCR shr 2) and 3;
  repeat
    if (Mode = 1) and (Ch[N].QWC = 0) and not Ch[N].TagEnd then
    begin
      if N = DMAToSPR then
      begin
        if not ReadTag(N) then
          Break;
        if (Ch[N].CHCR and CHCRTTE) <> 0 then
        begin
          PPS2Reg128(FScratch + (Ch[N].SADR and $3FF0))^ := FLastTag[N];
          Ch[N].SADR := (Ch[N].SADR + 16) and $3FF0;
        end;
      end
      else
      begin
        // Destination chain: the tag comes from SPR.
        var T := PPS2Reg128(FScratch + (Ch[N].SADR and $3FF0))^;
        Ch[N].SADR := (Ch[N].SADR + 16) and $3FF0;
        var Lo := Cardinal(T.Lo);
        Ch[N].CHCR := (Ch[N].CHCR and $0000FFFF) or (Lo and $FFFF0000);
        Ch[N].QWC := Lo and $FFFF;
        Ch[N].MADR := Cardinal(T.Lo shr 32);
        var Id := (Lo shr 28) and 7;
        if (Id = 7) or (((Lo and $80000000) <> 0) and ((Ch[N].CHCR and CHCRTIE) <> 0)) then
          Ch[N].TagEnd := True;
      end;
    end;
    var Skip := 0;
    var Burst := Integer(Ch[N].QWC);
    if Mode = 2 then
    begin
      Burst := Integer(SQWC shr 16) and $FF;
      Skip := Integer(SQWC and $FF);
      if (Burst = 0) or (Burst > Integer(Ch[N].QWC)) then
        Burst := Integer(Ch[N].QWC);
    end;
    while Ch[N].QWC > 0 do
    begin
      var Count := Burst;
      if Count > Integer(Ch[N].QWC) then
        Count := Integer(Ch[N].QWC);
      for var K := 0 to Count - 1 do
      begin
        var V: Boolean;
        var M := Memory(Ch[N].MADR, V);
        var SP := FScratch + (Ch[N].SADR and $3FF0);
        if V then
        begin
          if N = DMAToSPR then
            Move(M^, SP^, 16)
          else
          begin
            Move(SP^, M^, 16);
            MarkRAM(Ch[N].MADR, 16);
          end;
        end;
        Ch[N].MADR := Ch[N].MADR + 16;
        if (N = DMAFromSPR) and (Drain >= 0) then
          Ch[N].MADR := Ring(Ch[N].MADR);
        Ch[N].SADR := (Ch[N].SADR + 16) and $3FF0;
        Ch[N].QWC := Ch[N].QWC - 1;
        Inc(Moved[N]);
      end;
      if Mode = 2 then
        Ch[N].MADR := Ch[N].MADR + Cardinal(Skip) * 16;
    end;
    if N = DMAFromSPR then
      SourceMoved(N);
  until (Mode <> 1) or Ch[N].TagEnd;
  Finish(N, Int64(Moved[N]) * CyclesPerQuad + 8);
  // New data in the MFIFO ring: a drain channel waiting on it goes on.
  var D := Drain;
  if (N = DMAFromSPR) and (D >= 0) then
    ResumeDrain(D);
end;

// A device that takes or gives data again while the channel runs (a FIFO
// drained from inside the transfer) makes the running transfer go on
// instead of starting a nested one.
procedure TPS2DMAC.Run(N: Integer);
begin
  if FRunning[N] then
  begin
    FAgain[N] := True;
    Exit;
  end;
  FRunning[N] := True;
  try
    repeat
      FAgain[N] := False;
      RunChannel(N);
    until not FAgain[N];
  finally
    FRunning[N] := False;
  end;
end;

procedure TPS2DMAC.RunChannel(N: Integer);
begin
  if (N = DMAVIF1) or (N = DMAGIF) then
    Domain.Check;
  if (CTRL and 1) = 0 then
    Exit;
  if (Ch[N].CHCR and CHCRSTR) = 0 then
    Exit;
  if (N = DMAFromSPR) or (N = DMAToSPR) then
  begin
    RunSPR(N);
    Exit;
  end;
  if N = DMASIF0 then
  begin
    if SIF0Chain then
      RunSIF0;
    Exit;
  end;
  if DomainChannel(N) then
    DrainWaiting[N] := False;
  var Mode := (Ch[N].CHCR shr 2) and 3;
  repeat
    if not TransferData(N) then
      Exit;
    if Mode <> 1 then
      Break;
    if Ch[N].TagEnd then
      Break;
    // MFIFO: the drain waits while the ring is empty.
    if (N = Drain) and DrainEmpty(N) then
    begin
      Ch[N].TADR := Ring(Ch[N].TADR);
      ChannelStat(N, $4000, True);
      if DomainChannel(N) then
        DrainWaiting[N] := True;
      Exit;
    end;
    // (The device's FIFO is full: the tag waits with the channel.)
    if (Ports[N] <> nil) and ((Ch[N].CHCR and CHCRTTE) <> 0) and not Ports[N].TagRoom(N) then
      Exit;
    if not ReadTag(N) then
      Break;
  until False;
  if DomainChannel(N) and Domain.Ahead and Assigned(OnAheadPortEnd) and (Ports[N] <> nil) and Ports[N].BusyFromGS then
  begin
    Ch[N].Finishing := True;
    PortOnEE[N] := True;
    OnAheadPortEnd(N, Moved[N]);
    Exit;
  end;
  var Busy: Int64 := 0;
  if Ports[N] <> nil then
    Busy := Ports[N].TakeBusyCycles;
  Finish(N, Max(Int64(Moved[N]) * CyclesPerQuad, Busy) + 8);
end;

// SIF0 from the SIF FIFO: in chain mode each element starts with a DMAtag
// quadword (QWC, ID, IRQ, ADDR); cnt/cnts go on, end (and IRQ with TIE)
// stops after the element. The channel waits while the FIFO lacks data.
procedure TPS2DMAC.RunSIF0;
const
  N = DMASIF0;
begin
  var Chain := ((Ch[N].CHCR shr 2) and 3) = 1;
  repeat
    if Chain and (Ch[N].QWC = 0) and not Ch[N].TagEnd then
    begin
      var T: TPS2Reg128;
      if (Ports[N] = nil) or (Ports[N].Pull(N, @T, 1) = 0) then
        Exit;
      var Lo := Cardinal(T.Lo);
      Ch[N].CHCR := (Ch[N].CHCR and $0000FFFF) or (Lo and $FFFF0000);
      Ch[N].QWC := Lo and $FFFF;
      Ch[N].MADR := Cardinal(T.Lo shr 32);
      if (Log <> nil) and (((LogMask shr N) and 1) <> 0) and (Log.Count < 200000) then
        Log.Add(Format('%d ch5 tag id %d qwc %x addr %.8x', [FScheduler.Now, (Lo shr 28) and 7, Lo and $FFFF,
          Ch[N].MADR]));
      if (((Lo shr 28) and 7) = 7) or (((Lo and $80000000) <> 0) and ((Ch[N].CHCR and CHCRTIE) <> 0)) then
        Ch[N].TagEnd := True;
    end;
    if not TransferData(N) then
      Exit;
  until not Chain or Ch[N].TagEnd;
  Finish(N, Int64(Moved[N]) * CyclesPerQuad + 8);
end;

function TPS2DMAC.SIF0Ready: Boolean;
begin
  Result := ((CTRL and 1) <> 0) and ((Ch[DMASIF0].CHCR and CHCRSTR) <> 0) and not Ch[DMASIF0].Finishing;
end;

procedure TPS2DMAC.SIF0Write(Dest: Cardinal; Data: PByte; Size: Integer; IRQ: Boolean);
begin
  var Address := Dest and $01FFFFFF;
  if Size > 0 then
  begin
    if Int64(Address) + Size > PS2RAMSize then
      Size := PS2RAMSize - Integer(Address);
    Move(Data^, (FRAM + Address)^, Size);
    MarkRAM(Address, Cardinal(Size));
    Ch[DMASIF0].MADR := Address + Cardinal((Size + 15) and not 15);
    Inc(Moved[DMASIF0], (Size + 15) shr 4);
  end;
  if IRQ and ((Ch[DMASIF0].CHCR and CHCRTIE) <> 0) then
  begin
    Ch[DMASIF0].QWC := 0;
    Ch[DMASIF0].StartedAt := FScheduler.Now;
    Finish(DMASIF0, 16);
  end;
end;

procedure TPS2DMAC.SerializeState(State: TStateArchive);
begin
  State.Field(Ch, SizeOf(Ch));
  State.Field(CTRL, SizeOf(CTRL));
  State.Field(STAT, SizeOf(STAT));
  State.Field(PCR, SizeOf(PCR));
  State.Field(SQWC, SizeOf(SQWC));
  State.Field(RBSR, SizeOf(RBSR));
  State.Field(RBOR, SizeOf(RBOR));
  State.Field(STADR, SizeOf(STADR));
  State.Field(ENABLE, SizeOf(ENABLE));
  State.Field(Moved, SizeOf(Moved));
  State.Field(FLine, SizeOf(FLine));
  if State.Loading then
    for var N := DMAVIF1 to DMAGIF do
    begin
      PortOnEE[N] := False;
      PortEndAt[N] := PS2Never;
      PortEndedAt[N] := PS2Never;
    end;
end;

end.
