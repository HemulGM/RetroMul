unit PS2.DMAC;

// EE DMA controller: ten channels (VIF0, VIF1, GIF, fromIPU, toIPU, SIF0,
// SIF1, SIF2, fromSPR, toSPR) with normal, chain and interleave modes, the
// call/return stack, D_CTRL/D_STAT/D_PCR/D_SQWC and the interrupt line (INT1).
// Data moves when a channel starts (or a stalled device takes more); the
// channel ends after the bus time of its transfer has passed.
// References: EE User's Manual (DMAC chapter), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types, PS2.Scheduler;

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
    // EE cycles the device spent on the data taken since the last call
    // (the channel ends no earlier).
    function TakeBusyCycles: Int64; virtual;
  end;

  TPS2DMAChannel = record
    CHCR, MADR, QWC, TADR, ASR0, ASR1, SADR: Cardinal;
    // Chain: the current tag ended the chain once its data is done.
    TagEnd: Boolean;
    // Data moved; the channel ends at DoneAt.
    Finishing: Boolean;
    DoneAt: Int64;
  end;

  TPS2DMAC = class
  private
    FScheduler: TPS2Scheduler;
    FRAM, FScratch: PByte;
    FRAMGen: PCardinal;
    FOnInterrupt: TProc<Boolean>;
    FLine: Boolean;
    FLastTag: TPS2Reg128;
    procedure UpdateInterrupt;
    function Memory(Address: Cardinal; out Valid: Boolean): PByte;
    procedure MarkRAM(Address, Size: Cardinal);
    procedure Run(N: Integer);
    function TransferData(N: Integer): Boolean;
    function ReadTag(N: Integer): Boolean;
    procedure Finish(N: Integer; Cycles: Int64);
    procedure RunSPR(N: Integer);
    procedure ScheduleNext;
    function Drain: Integer;
    function Ring(Address: Cardinal): Cardinal; inline;
  public
    Ch: array[0..9] of TPS2DMAChannel;
    CTRL, STAT, PCR, SQWC, RBSR, RBOR, STADR, ENABLE: Cardinal;
    Ports: array[0..9] of TPS2DMAPort;
    // Quadwords moved since the channel started (for bus time).
    Moved: array[0..9] of Integer;
    constructor Create(Scheduler: TPS2Scheduler; RAM, Scratch: PByte; RAMGen: PCardinal);
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    // Scheduler event: channels whose bus time passed end now.
    procedure Event;
    // A stalled device can take data again.
    procedure Resume(N: Integer);
    // SIF0 (IOP to EE): writes Size bytes at Dest (physical); with IRQ the
    // destination chain ends there (STR clear, CIS5). False when the channel
    // is not armed.
    function SIF0Ready: Boolean;
    procedure SIF0Write(Dest: Cardinal; Data: PByte; Size: Integer; IRQ: Boolean);
    procedure SetChannelInterrupt(N: Integer);
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
  FScheduler.Cancel(TPS2Event.DMAC);
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

function TPS2DMAC.CPCond0: Boolean;
begin
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
  if (Address and $80000000) <> 0 then
    Exit;
  Address := Address and $01FFFFFF;
  var First := Address shr 12;
  var Last := (Address + Size - 1) shr 12;
  if Last > 8191 then
    Last := 8191;
  for var P := First to Last do
    Inc(FRAMGen[P]);
end;

function TPS2DMAC.Read(Address: Cardinal): Cardinal;
begin
  var Offset := Address and $FFFF;
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
    begin
      case Offset and $FF of
        $00: Result := Ch[N].CHCR;
        $10: Result := Ch[N].MADR;
        $20: Result := Ch[N].QWC;
        $30: Result := Ch[N].TADR;
        $40: Result := Ch[N].ASR0;
        $50: Result := Ch[N].ASR1;
        $80: Result := Ch[N].SADR;
      else
        Result := 0;
      end;
      Exit;
    end;
  Result := 0;
end;

procedure TPS2DMAC.Write(Address, Value: Cardinal);
begin
  var Offset := Address and $FFFF;
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
    for var N := 0 to 9 do
      if ((Ch[N].CHCR and CHCRSTR) <> 0) and not Ch[N].Finishing then
        Run(N);
    Exit;
  end;
  for var N := 0 to 9 do
    if (Offset and $FF00) = ChannelBase[N] then
    begin
      case Offset and $FF of
        $00:
          begin
            var Was := (Ch[N].CHCR and CHCRSTR) <> 0;
            if Was and ((Value and CHCRSTR) = 0) then
            begin
              // Stopping a channel.
              Ch[N].CHCR := Value;
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
              Ch[N].Finishing := False;
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

procedure TPS2DMAC.Finish(N: Integer; Cycles: Int64);
begin
  Ch[N].Finishing := True;
  Ch[N].DoneAt := FScheduler.Now + Cycles;
  ScheduleNext;
end;

procedure TPS2DMAC.ScheduleNext;
begin
  var Next := PS2Never;
  for var K := 0 to 9 do
    if Ch[K].Finishing and (Ch[K].DoneAt < Next) then
      Next := Ch[K].DoneAt;
  if Next = PS2Never then
    FScheduler.Cancel(TPS2Event.DMAC)
  else
    FScheduler.Schedule(TPS2Event.DMAC, Next);
end;

procedure TPS2DMAC.Event;
begin
  for var N := 0 to 9 do
    if Ch[N].Finishing and (Ch[N].DoneAt <= FScheduler.Now) then
    begin
      Ch[N].Finishing := False;
      Ch[N].CHCR := Ch[N].CHCR and not Cardinal(CHCRSTR);
      STAT := STAT or (Cardinal(1) shl N);
    end;
  UpdateInterrupt;
  ScheduleNext;
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
      STAT := STAT or $8000;
      Ch[N].QWC := 0;
      UpdateInterrupt;
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
    var Done: Integer;
    var ToMemory := ((N = DMAVIF1) or (N = DMASIF2)) and ((Ch[N].CHCR and CHCRDir) = 0) or
      (N = DMAFromIPU) or (N = DMASIF0);
    if Ports[N] = nil then
      Done := Count
    else if ToMemory then
    begin
      Done := Ports[N].Pull(N, P, Count);
      MarkRAM(Ch[N].MADR, Cardinal(Done) * 16);
    end
    else
      Done := Ports[N].Push(N, P, Count);
    Inc(Moved[N], Done);
    Ch[N].MADR := Ch[N].MADR + Cardinal(Done) * 16;
    Ch[N].QWC := Ch[N].QWC - Cardinal(Done);
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
    STAT := STAT or $8000;
    UpdateInterrupt;
    Exit(False);
  end;
  var T := PPS2Reg128(P)^;
  FLastTag := T;
  var Lo := Cardinal(T.Lo);
  var Addr := Cardinal(T.Lo shr 32);
  var Id := (Lo shr 28) and 7;
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
          PPS2Reg128(FScratch + (Ch[N].SADR and $3FF0))^ := FLastTag;
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
  until (Mode <> 1) or Ch[N].TagEnd;
  Finish(N, Int64(Moved[N]) * CyclesPerQuad + 8);
  // New data in the MFIFO ring: a drain channel waiting on it goes on.
  var D := Drain;
  if (N = DMAFromSPR) and (D >= 0) then
    Resume(D);
end;

procedure TPS2DMAC.Run(N: Integer);
begin
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
    Exit;
  var Mode := (Ch[N].CHCR shr 2) and 3;
  repeat
    if not TransferData(N) then
      Exit;
    if Mode <> 1 then
      Break;
    if Ch[N].TagEnd then
      Break;
    // MFIFO: the drain waits while the ring is empty.
    if (N = Drain) and (Ring(Ch[N].TADR) = Ring(Ch[DMAFromSPR].MADR)) then
    begin
      Ch[N].TADR := Ring(Ch[N].TADR);
      if (STAT and $4000) = 0 then
      begin
        STAT := STAT or $4000;
        UpdateInterrupt;
      end;
      Exit;
    end;
    if not ReadTag(N) then
      Break;
  until False;
  var Busy: Int64 := 0;
  if Ports[N] <> nil then
    Busy := Ports[N].TakeBusyCycles;
  Finish(N, Max(Int64(Moved[N]) * CyclesPerQuad, Busy) + 8);
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
end;

end.
