unit PS2.IOP.Machine;

// The IOP running its own BIOS kernel (External BIOS boot): the R3000A core
// from its reset vector with hardware exceptions; the IOP bus (2 MiB RAM
// mirrored to 8 MiB, the BIOS ROM, the scratchpad, the I/O area); the
// interrupt controller (I_STAT, I_MASK, I_CTRL); the DMA controller
// (DPCR/DICR and DPCR2/DICR2, DMACEN/DMACINTEN) with the CDVD channel (3),
// SIF0 (9, chain mode from tags at TADR) and SIF1 (10, tags from the FIFO),
// while the SPU2 (4, 7) and SIO2 (11, 12) channels run in TPS2IOPHardware;
// the six root counters with their interrupts; the SBUS control register
// that interrupts the EE; and the CDVD drive. Other I/O registers (SSBUS,
// RAM size, the absent DEV9, USB and i.LINK) keep what is written.
// Timers, DMA completion and the drive use the scheduler slots IOPTimers,
// IOPSync and CDVD, which the high-level IOP does not use in this mode.
// References: ps2tek (IOP interrupts, IOP DMA, IOP timers), ps2sdk
// iop_mmio_hwport.h and sifman (AFL 2.0; register map and use).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.Scheduler, PS2.IOP.CPU,
  PS2.IOP.Hardware, PS2.SIF.Bridge, PS2.CDVD.Drive;

const
  // I_STAT bits.
  IOPIrqVBlank = 0;
  IOPIrqCDVD = 2;
  IOPIrqDMA = 3;
  IOPIrqVBlankEnd = 11;

type
  TPS2IOPTimer = record
    Mode, Target: Cardinal;
    // The count at Base (EE cycles); it advances from there.
    Count: Cardinal;
    Base: Int64;
  end;

  // Channels 3, 9 and 10 (the others live in TPS2IOPHardware).
  TPS2IOPChannel = record
    MADR, BCR, CHCR, TADR: Cardinal;
    // SIF element in progress: words left, words to drop (SIF1), tag flags.
    Active: Boolean;
    Left, Drop: Integer;
    Flags: Cardinal;
    // Words moved since the channel started (completion time).
    Moved: Int64;
    DoneAt: Int64;
  end;

  TPS2IOPMachine = class
  private
    FScheduler: TPS2Scheduler;
    FHW: TPS2IOPHardware;
    FSIF: TPS2SIFBridge;
    FDrive: TPS2CDVDDrive;
    FRAM, FROM: PByte;
    FIStat, FIMask, FICtrl: Cardinal;
    FDPCR, FDPCR2, FDICR, FDICR2, FDMACEN, FDMACINTEN: Cardinal;
    FCh: array[0..12] of TPS2IOPChannel;
    FTimer: array[0..5] of TPS2IOPTimer;
    FSBus: array[0..1] of Cardinal;
    FRunning, FAgain: array[0..12] of Boolean;
    // Diagnostics: printable text in SIF1 data.
    FText: string;
    FLineCycles: Int64;
    FOnEEInterrupt: TProc;
    function BusRead(Address: Cardinal; Size: Integer): Cardinal;
    procedure BusWrite(Address, Value: Cardinal; Size: Integer);
    procedure UpdateLine;
    // DMA.
    function ChannelOf(Address: Cardinal; out N, Reg: Integer): Boolean;
    function DMAEnabled(N: Integer): Boolean;
    procedure ChannelFlag(N: Integer);
    procedure UpdateDICR;
    procedure StartChannel(N: Integer);
    procedure RunChannel(N: Integer);
    procedure RunSIF0;
    procedure RunSIF1;
    procedure RunCDVD;
    procedure Complete(N: Integer);
    procedure ScheduleDMA;
    // Timers.
    function TimerTicks(K: Integer; Cycles: Int64): Int64;
    function TimerCount(K: Integer): Cardinal;
    procedure SetTimerCount(K: Integer; Value: Cardinal);
    function TimerLimit(K: Integer): Int64;
    procedure TimerReached(K: Integer);
    procedure ScheduleTimers;
    function CyclesToTicks(K: Integer; Ticks: Int64): Int64;
  public
    CPU: TIOPCPU;
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler; IOPRAM, BIOS: PByte; Hardware: TPS2IOPHardware;
      SIF: TPS2SIFBridge; Drive: TPS2CDVDDrive);
    destructor Destroy; override;
    procedure Reset;
    // Runs the IOP up to EE cycle Target (8 EE cycles a cycle).
    procedure Run(Target: Int64);
    procedure RaiseIRQ(Bit: Integer);
    // TPS2IOPHardware's interrupt lines (SPU2, SIO2 and their DMA channels).
    procedure HWInterrupt(Line: Integer);
    procedure VBlank(Start: Boolean);
    // Scheduler events.
    procedure TimerEvent;
    procedure DMAEvent;
    // SIF FIFO activity (the bridge's callbacks).
    procedure SIFData;
    procedure SIFRoom;
    // The CDVD drive has sector data for channel 3.
    procedure CDVDData;
    procedure SetLineCycles(Cycles: Int64);
    procedure SerializeState(State: TStateArchive);
    // The IOP raised the SBUS interrupt (EE INTC bit 1).
    property OnEEInterrupt: TProc read FOnEEInterrupt write FOnEEInterrupt;
  end;

implementation

const
  ChannelBases: array[0..12] of Cardinal = ($1F801080, $1F801090, $1F8010A0, $1F8010B0, $1F8010C0, $1F8010D0,
    $1F8010E0, $1F801500, $1F801510, $1F801520, $1F801530, $1F801540, $1F801550);
  CHCRStart = $01000000;
  // Timers 0-2 raise I_STAT 4-6, timers 3-5 I_STAT 14-16.
  TimerIrq: array[0..5] of Integer = (4, 5, 6, 14, 15, 16);

constructor TPS2IOPMachine.Create(Scheduler: TPS2Scheduler; IOPRAM, BIOS: PByte; Hardware: TPS2IOPHardware;
  SIF: TPS2SIFBridge; Drive: TPS2CDVDDrive);
begin
  inherited Create;
  FScheduler := Scheduler;
  FRAM := IOPRAM;
  FROM := BIOS;
  FHW := Hardware;
  FSIF := SIF;
  FDrive := Drive;
  FLineCycles := 18743;
  CPU := TIOPCPU.Create(IOPRAM);
  CPU.Hardware := True;
  CPU.ROM := BIOS;
  CPU.OnRead := BusRead;
  CPU.OnWrite := BusWrite;
  Reset;
end;

destructor TPS2IOPMachine.Destroy;
begin
  CPU.Free;
  inherited;
end;

procedure TPS2IOPMachine.Reset;
begin
  CPU.Reset;
  CPU.SetPC($BFC00000);
  CPU.SR := $00400000;
  CPU.IntLine := False;
  CPU.BadVAddr := 0;
  FillChar(CPU.Debug, SizeOf(CPU.Debug), 0);
  FIStat := 0;
  FIMask := 0;
  FICtrl := 0;
  FDPCR := $07777777;
  FDPCR2 := $07777777;
  FDICR := 0;
  FDICR2 := 0;
  FDMACEN := 0;
  // Channel interrupts enabled (the BIOS relies on it and never writes it).
  FDMACINTEN := 1;
  FillChar(FCh, SizeOf(FCh), 0);
  FillChar(FTimer, SizeOf(FTimer), 0);
  FSBus[0] := 0;
  FSBus[1] := 0;
  FScheduler.Cancel(TPS2Event.IOPTimers);
  FScheduler.Cancel(TPS2Event.IOPSync);
end;

procedure TPS2IOPMachine.SetLineCycles(Cycles: Int64);
begin
  FLineCycles := Max(Cycles, 1);
end;

procedure TPS2IOPMachine.Run(Target: Int64);
begin
  CPU.Run(Target div 8);
end;

{ Interrupts }

procedure TPS2IOPMachine.UpdateLine;
begin
  CPU.IntLine := ((FICtrl and 1) <> 0) and ((FIStat and FIMask) <> 0);
end;

procedure TPS2IOPMachine.RaiseIRQ(Bit: Integer);
begin
  FIStat := FIStat or (Cardinal(1) shl Bit);
  UpdateLine;
end;

procedure TPS2IOPMachine.VBlank(Start: Boolean);
begin
  if Start then
    RaiseIRQ(IOPIrqVBlank)
  else
    RaiseIRQ(IOPIrqVBlankEnd);
end;

// TPS2IOPHardware's lines: I_STAT bits below 32, DMA channels above (32 +
// channel for 0..6, 33 + channel for 7..13).
procedure TPS2IOPMachine.HWInterrupt(Line: Integer);
begin
  if Line < 32 then
    RaiseIRQ(Line)
  else if Line <= 38 then
    ChannelFlag(Line - 32)
  else
    ChannelFlag(Line - 33);
end;

{ DMA }

function TPS2IOPMachine.ChannelOf(Address: Cardinal; out N, Reg: Integer): Boolean;
begin
  for var K := 0 to 12 do
    if (Address and $FFFFFFF0) = ChannelBases[K] then
    begin
      N := K;
      Reg := Integer(Address and $C) shr 2;
      Exit(True);
    end;
  Result := False;
end;

function TPS2IOPMachine.DMAEnabled(N: Integer): Boolean;
begin
  if N < 7 then
    Result := ((FDPCR shr (N * 4)) and 8) <> 0
  else
    Result := ((FDPCR2 shr ((N - 7) * 4)) and 8) <> 0;
  Result := Result and ((FDMACEN and 1) <> 0);
end;

// A channel finished (or an IRQ tag): its flag rises if its interrupt is
// unmasked, and the master flag drives I_STAT bit 3.
procedure TPS2IOPMachine.ChannelFlag(N: Integer);
begin
  if N < 7 then
  begin
    if ((FDICR shr (16 + N)) and 1) <> 0 then
      FDICR := FDICR or (Cardinal(1) shl (24 + N));
  end
  else if ((FDICR2 shr (16 + N - 7)) and 1) <> 0 then
    FDICR2 := FDICR2 or (Cardinal(1) shl (24 + N - 7));
  UpdateDICR;
end;

procedure TPS2IOPMachine.UpdateDICR;
begin
  var Was := (FDICR and $80000000) <> 0;
  var Flags := ((FDICR shr 24) and $7F) or ((FDICR2 shr 24) and $3F);
  var Master := ((FDICR and $8000) <> 0) or (((FDICR and $800000) <> 0) and (Flags <> 0));
  if (FDMACINTEN and 1) = 0 then
    Master := (FDICR and $8000) <> 0;
  if Master then
    FDICR := FDICR or $80000000
  else
    FDICR := FDICR and not Cardinal($80000000);
  if Master and not Was and ((FDMACINTEN and 2) = 0) then
    RaiseIRQ(IOPIrqDMA);
end;

procedure TPS2IOPMachine.StartChannel(N: Integer);
begin
  FCh[N].Active := False;
  FCh[N].Moved := 0;
  RunChannel(N);
end;

// Data or room appearing while the channel runs (the other side moved
// within the transfer) makes the running transfer go on.
procedure TPS2IOPMachine.RunChannel(N: Integer);
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
      case N of
        3: RunCDVD;
        9: RunSIF0;
        10: RunSIF1;
      end;
    until not FAgain[N];
  finally
    FRunning[N] := False;
  end;
end;

// SIF0: tags at TADR (address and flags, word count; with CHCR bit 8 the
// two words after the tag, the EE DMAtag, go first), then the words.
procedure TPS2IOPMachine.RunSIF0;
const
  N = 9;
begin
  if ((FCh[N].CHCR and CHCRStart) = 0) or (FCh[N].DoneAt <> 0) then
    Exit;
  repeat
    if not FCh[N].Active then
    begin
      var T := FCh[N].TADR and PS2IOPRAMMask;
      var W0 := PCardinal(FRAM + (T and not 3))^;
      var W1 := PCardinal(FRAM + ((T + 4) and PS2IOPRAMMask and not 3))^;
      FCh[N].MADR := W0 and $FFFFFF;
      FCh[N].Flags := W0 and $C0000000;
      FCh[N].Left := Integer(W1 and $FFFFFF);
      FCh[N].BCR := W1;
      FCh[N].Active := True;
      if (FCh[N].CHCR and $100) <> 0 then
      begin
        FSIF.PushTag0(PCardinal(FRAM + ((T + 8) and PS2IOPRAMMask and not 3))^,
          PCardinal(FRAM + ((T + 12) and PS2IOPRAMMask and not 3))^);
        FCh[N].TADR := T + 16;
      end
      else
        FCh[N].TADR := T + 8;
      if (Log <> nil) and (Log.Count < 100000) then
        Log.Add(Format('iop sif0 tag %.8x %.8x at %.6x', [W0, W1, T]));
    end;
    while (FCh[N].Left > 0) and (FSIF.FIFO0.Room > 0) do
    begin
      FSIF.Push0(PCardinal(FRAM + (FCh[N].MADR and PS2IOPRAMMask and not 3))^);
      FCh[N].MADR := (FCh[N].MADR + 4) and $FFFFFF;
      Dec(FCh[N].Left);
      Inc(FCh[N].Moved);
    end;
    if FCh[N].Left > 0 then
      Exit;
    FSIF.Pad0;
    FCh[N].Active := False;
    if (FCh[N].Flags and $40000000) <> 0 then
      if ((FDICR2 shr N) and 1) <> 0 then
        ChannelFlag(N);
    if (FCh[N].Flags and $80000000) <> 0 then
    begin
      Complete(N);
      Exit;
    end;
  until False;
end;

// SIF1: each element starts with its header (the IOP tag) in the FIFO; the
// words go to the tag's address, the rest of their last quadword is dropped.
procedure TPS2IOPMachine.RunSIF1;
const
  N = 10;
begin
  if ((FCh[N].CHCR and CHCRStart) = 0) or (FCh[N].DoneAt <> 0) then
    Exit;
  repeat
    if not FCh[N].Active then
    begin
      // The header: the IOP tag, two more words with CHCR bit 8.
      var Header := 2;
      if (FCh[N].CHCR and $100) <> 0 then
        Header := 4;
      var W0, W1: Cardinal;
      if not FSIF.PullTag1(Header, W0, W1) then
        Exit;
      FCh[N].MADR := W0 and $FFFFFF;
      FCh[N].Flags := W0 and $C0000000;
      FCh[N].Left := Integer(W1 and $FFFFFF);
      // The rest of the last quadword.
      FCh[N].Drop := (4 - (Header + FCh[N].Left) mod 4) mod 4;
      FCh[N].Active := True;
      if (Log <> nil) and (Log.Count < 100000) then
        Log.Add(Format('iop sif1 tag %.8x %.8x', [W0, W1]));
    end;
    var W: Cardinal;
    while (FCh[N].Left > 0) and FSIF.Pull1(W) do
    begin
      if (Log <> nil) and (Log.Count < 100000) then
        for var K := 0 to 3 do
          if (Byte(W shr (K * 8)) >= 32) and (Byte(W shr (K * 8)) < 127) then
            FText := FText + Char(Byte(W shr (K * 8)))
          else if Length(FText) >= 6 then
          begin
            Log.Add('iop sif1 text: ' + FText);
            FText := '';
          end
          else
            FText := '';
      PCardinal(FRAM + (FCh[N].MADR and PS2IOPRAMMask and not 3))^ := W;
      FCh[N].MADR := (FCh[N].MADR + 4) and $FFFFFF;
      Dec(FCh[N].Left);
      Inc(FCh[N].Moved);
    end;
    if FCh[N].Left > 0 then
      Exit;
    while (FCh[N].Drop > 0) and FSIF.Pull1(W) do
      Dec(FCh[N].Drop);
    if FCh[N].Drop > 0 then
      Exit;
    FCh[N].Active := False;
    if (FCh[N].Flags and $40000000) <> 0 then
      if ((FDICR2 shr N) and 1) <> 0 then
        ChannelFlag(N);
    if (FCh[N].Flags and $80000000) <> 0 then
    begin
      Complete(N);
      Exit;
    end;
  until False;
end;

// CDVD: BCR blocks of BCR.size words from the drive's sector data.
procedure TPS2IOPMachine.RunCDVD;
const
  N = 3;
begin
  if ((FCh[N].CHCR and CHCRStart) = 0) or (FCh[N].DoneAt <> 0) then
    Exit;
  if not FCh[N].Active then
  begin
    var Size := Integer(FCh[N].BCR and $FFFF);
    var Blocks := Integer(FCh[N].BCR shr 16);
    FCh[N].Left := Size * Max(Blocks, 1);
    FCh[N].Active := True;
  end;
  while FCh[N].Left > 0 do
  begin
    var Want := FCh[N].Left * 4;
    var A := FCh[N].MADR and PS2IOPRAMMask;
    Want := Min(Want, Integer(PS2IOPRAMSize - A));
    var Got := FDrive.TakeData(FRAM + A, Want);
    if Got <= 0 then
      Exit;
    FCh[N].MADR := (FCh[N].MADR + Cardinal(Got)) and $FFFFFF;
    Dec(FCh[N].Left, (Got + 3) div 4);
    Inc(FCh[N].Moved, (Got + 3) div 4);
  end;
  FCh[N].BCR := FCh[N].BCR and $FFFF;
  Complete(N);
end;

// The channel ends after its words' bus time (a word an IOP cycle).
procedure TPS2IOPMachine.Complete(N: Integer);
begin
  FCh[N].DoneAt := FScheduler.Now + Max(FCh[N].Moved * 8, 64);
  ScheduleDMA;
end;

procedure TPS2IOPMachine.ScheduleDMA;
begin
  var Next := PS2Never;
  for var N := 0 to 12 do
    if (FCh[N].DoneAt <> 0) and (FCh[N].DoneAt < Next) then
      Next := FCh[N].DoneAt;
  if Next = PS2Never then
    FScheduler.Cancel(TPS2Event.IOPSync)
  else
    FScheduler.Schedule(TPS2Event.IOPSync, Next);
end;

procedure TPS2IOPMachine.DMAEvent;
begin
  for var N := 0 to 12 do
    if (FCh[N].DoneAt <> 0) and (FCh[N].DoneAt <= FScheduler.Now) then
    begin
      FCh[N].DoneAt := 0;
      FCh[N].Active := False;
      FCh[N].CHCR := FCh[N].CHCR and not Cardinal(CHCRStart);
      ChannelFlag(N);
    end;
  ScheduleDMA;
end;

procedure TPS2IOPMachine.SIFData;
begin
  RunChannel(10);
end;

procedure TPS2IOPMachine.SIFRoom;
begin
  RunChannel(9);
end;

procedure TPS2IOPMachine.CDVDData;
begin
  RunChannel(3);
end;

{ Timers }

// Ticks of timer K in Cycles EE cycles: the IOP clock (EE / 8) with the
// prescaler of timers 2, 4 and 5, or with the external signal the pixel
// clock (timer 0, 13.5 MHz) or HBLANK (timers 1 and 3).
function TPS2IOPMachine.TimerTicks(K: Integer; Cycles: Int64): Int64;
begin
  var Mode := FTimer[K].Mode;
  if (Mode and $100) <> 0 then
    case K of
      0: Exit(Cycles * 1125 div 24576);
      1, 3: Exit(Cycles div FLineCycles);
    end;
  var Divider: Int64 := 8;
  if (K = 2) and ((Mode and $200) <> 0) then
    Divider := 64
  else if K >= 4 then
    case (Mode shr 13) and 3 of
      1: Divider := 64;
      2: Divider := 128;
      3: Divider := 2048;
    end;
  Result := Cycles div Divider;
end;

// EE cycles until timer K has advanced Ticks ticks.
function TPS2IOPMachine.CyclesToTicks(K: Integer; Ticks: Int64): Int64;
begin
  var Mode := FTimer[K].Mode;
  if (Mode and $100) <> 0 then
    case K of
      0: Exit((Ticks * 24576 + 1124) div 1125);
      1, 3: Exit(Ticks * FLineCycles);
    end;
  var Divider: Int64 := 8;
  if (K = 2) and ((Mode and $200) <> 0) then
    Divider := 64
  else if K >= 4 then
    case (Mode shr 13) and 3 of
      1: Divider := 64;
      2: Divider := 128;
      3: Divider := 2048;
    end;
  Result := Ticks * Divider;
end;

function TPS2IOPMachine.TimerLimit(K: Integer): Int64;
begin
  if K < 3 then
    Result := $10000
  else
    Result := Int64($100000000);
end;

function TPS2IOPMachine.TimerCount(K: Integer): Cardinal;
begin
  var Ticks := TimerTicks(K, FScheduler.Now - FTimer[K].Base);
  Result := Cardinal((Int64(FTimer[K].Count) + Ticks) mod TimerLimit(K));
end;

procedure TPS2IOPMachine.SetTimerCount(K: Integer; Value: Cardinal);
begin
  FTimer[K].Count := Cardinal(Int64(Value) mod TimerLimit(K));
  FTimer[K].Base := FScheduler.Now;
  ScheduleTimers;
end;

// The count reached the target (compare) or wrapped (overflow): flags,
// the interrupt (mode bit 10 enables it; one-shot unless bit 6) and the
// zero return.
procedure TPS2IOPMachine.TimerReached(K: Integer);
begin
  var Now := FTimer[K].Count;
  var M := FTimer[K].Mode;
  var Irq := False;
  if Now = FTimer[K].Target then
  begin
    M := M or $800;
    if (M and $10) <> 0 then
      Irq := True;
    if (M and 8) <> 0 then
      FTimer[K].Count := 0;
  end;
  if Now = 0 then
  begin
    M := M or $1000;
    if (M and $20) <> 0 then
      Irq := True;
  end;
  if Irq and ((M and $400) <> 0) then
  begin
    RaiseIRQ(TimerIrq[K]);
    if (M and $40) = 0 then
      M := M and not Cardinal($400)
    else if (M and $80) <> 0 then
      M := M xor $400;
  end;
  FTimer[K].Mode := M;
end;

procedure TPS2IOPMachine.ScheduleTimers;
begin
  var Next := PS2Never;
  for var K := 0 to 5 do
  begin
    var M := FTimer[K].Mode;
    if (M and $38) = 0 then
      Continue;
    var C := TimerCount(K);
    var Limit := TimerLimit(K);
    var Ahead := Limit - C;
    if ((M and $10) <> 0) or ((M and 8) <> 0) then
    begin
      var ToTarget := (Int64(FTimer[K].Target) - C + Limit) mod Limit;
      if ToTarget = 0 then
        ToTarget := Limit;
      Ahead := Min(Ahead, ToTarget);
    end;
    // From the current count's tick start.
    var Elapsed := FScheduler.Now - FTimer[K].Base;
    var TicksNow := TimerTicks(K, Elapsed);
    var At := FTimer[K].Base + CyclesToTicks(K, TicksNow + Ahead);
    Next := Min(Next, Max(At, FScheduler.Now + 1));
  end;
  if Next = PS2Never then
    FScheduler.Cancel(TPS2Event.IOPTimers)
  else
    FScheduler.Schedule(TPS2Event.IOPTimers, Next);
end;

procedure TPS2IOPMachine.TimerEvent;
begin
  for var K := 0 to 5 do
  begin
    var M := FTimer[K].Mode;
    if (M and $38) = 0 then
      Continue;
    var C := TimerCount(K);
    if (C = FTimer[K].Target) or (C = 0) then
    begin
      FTimer[K].Count := C;
      FTimer[K].Base := FScheduler.Now;
      TimerReached(K);
    end;
  end;
  ScheduleTimers;
end;

{ Bus }

function TPS2IOPMachine.BusRead(Address: Cardinal; Size: Integer): Cardinal;
begin
  // Address is physical (the CPU dropped the segment bits).
  if Address >= $1FC00000 then
  begin
    var A := Address and PS2BIOSMask;
    case Size of
      1: Exit(FROM[A]);
      2: Exit(PWord(FROM + (A and not 1))^);
    else
      Exit(PCardinal(FROM + (A and not 3))^);
    end;
  end;
  if (Address >= $1D000000) and (Address < $1D000100) then
    Exit(FSIF.IOPRead(Address and $FF));
  if (Address >= $1F402000) and (Address < $1F402100) then
    Exit(FDrive.Read(Address and $FF));
  case Address of
    $1F801070: Exit(FIStat);
    $1F801074: Exit(FIMask);
    $1F801078:
      begin
        // Reading I_CTRL returns it and disables interrupts.
        Result := FICtrl;
        FICtrl := 0;
        UpdateLine;
        Exit;
      end;
    $1F8010F0: Exit(FDPCR);
    $1F8010F4: Exit(FDICR);
    $1F801570: Exit(FDPCR2);
    $1F801574: Exit(FDICR2);
    $1F801578: Exit(FDMACEN);
    $1F80157C: Exit(FDMACINTEN);
    $1F801450: Exit(FSBus[0]);
    $1F801454: Exit(FSBus[1]);
  end;
  var N, Reg: Integer;
  if ChannelOf(Address, N, Reg) and (N in [3, 9, 10]) then
    case Reg of
      0: Exit(FCh[N].MADR);
      1: Exit(FCh[N].BCR);
      2: Exit(FCh[N].CHCR);
    else
      Exit(FCh[N].TADR);
    end;
  // Root counters: count, mode (reading clears the raised flags), target.
  var K := -1;
  if (Address >= $1F801100) and (Address < $1F801130) then
    K := Integer((Address - $1F801100) shr 4)
  else if (Address >= $1F801480) and (Address < $1F8014B0) then
    K := 3 + Integer((Address - $1F801480) shr 4);
  if K >= 0 then
    case Address and $C of
      0: Exit(TimerCount(K));
      4:
        begin
          Result := FTimer[K].Mode;
          FTimer[K].Mode := FTimer[K].Mode and not Cardinal($1800);
          Exit;
        end;
      8: Exit(FTimer[K].Target);
    else
      Exit(0);
    end;
  if FHW <> nil then
    Result := FHW.Read(Address, Size)
  else
    Result := 0;
end;

procedure TPS2IOPMachine.BusWrite(Address, Value: Cardinal; Size: Integer);
begin
  if Address >= $1FC00000 then
    Exit;
  if (Log <> nil) and (Log.Count < 20000) and ((Address < $1F900000) or (Address >= $1F910000)) and
    (Address <> $1F801078) then
    Log.Add(Format('iopm w %.8x = %.8x/%d pc %.8x', [Address, Value, Size, CPU.PC]));
  if (Address >= $1D000000) and (Address < $1D000100) then
  begin
    FSIF.IOPWrite(Address and $FF, Value);
    Exit;
  end;
  if (Address >= $1F402000) and (Address < $1F402100) then
  begin
    FDrive.Write(Address and $FF, Byte(Value));
    Exit;
  end;
  case Address of
    $1F801070:
      begin
        FIStat := FIStat and Value;
        UpdateLine;
        Exit;
      end;
    $1F801074:
      begin
        FIMask := Value;
        UpdateLine;
        Exit;
      end;
    $1F801078:
      begin
        FICtrl := Value and 1;
        UpdateLine;
        Exit;
      end;
    $1F8010F0:
      begin
        FDPCR := Value;
        Exit;
      end;
    $1F8010F4:
      begin
        // Flags clear on writing 1; bit 31 is computed.
        FDICR := (Value and $00FFFFFF) or (FDICR and $7F000000 and not (Value and $7F000000));
        UpdateDICR;
        Exit;
      end;
    $1F801570:
      begin
        FDPCR2 := Value;
        Exit;
      end;
    $1F801574:
      begin
        FDICR2 := (Value and $00FFFFFF) or (FDICR2 and $3F000000 and not (Value and $3F000000));
        UpdateDICR;
        Exit;
      end;
    $1F801578:
      begin
        FDMACEN := Value;
        Exit;
      end;
    $1F80157C:
      begin
        FDMACINTEN := Value;
        UpdateDICR;
        Exit;
      end;
    $1F801450:
      begin
        // Bit 1 rising: the SBUS interrupt to the EE.
        if ((Value and 2) <> 0) and ((FSBus[0] and 2) = 0) and Assigned(FOnEEInterrupt) then
          FOnEEInterrupt();
        FSBus[0] := Value;
        Exit;
      end;
    $1F801454:
      begin
        FSBus[1] := Value;
        Exit;
      end;
  end;
  var N, Reg: Integer;
  if ChannelOf(Address, N, Reg) and (N in [3, 9, 10]) then
  begin
    case Reg of
      0: FCh[N].MADR := Value and $FFFFFF;
      1: FCh[N].BCR := Value;
      2:
        begin
          var Was := (FCh[N].CHCR and CHCRStart) <> 0;
          FCh[N].CHCR := Value;
          if (Value and CHCRStart) = 0 then
          begin
            FCh[N].Active := False;
            FCh[N].DoneAt := 0;
          end
          else if not Was then
            StartChannel(N);
        end;
    else
      FCh[N].TADR := Value and $FFFFFF;
    end;
    Exit;
  end;
  var K := -1;
  if (Address >= $1F801100) and (Address < $1F801130) then
    K := Integer((Address - $1F801100) shr 4)
  else if (Address >= $1F801480) and (Address < $1F8014B0) then
    K := 3 + Integer((Address - $1F801480) shr 4);
  if K >= 0 then
  begin
    case Address and $C of
      0: SetTimerCount(K, Value);
      4:
        begin
          // A mode write zeroes the count and enables the interrupt.
          FTimer[K].Mode := (Value and $E3FF) or $400;
          SetTimerCount(K, 0);
        end;
      8:
        begin
          if K < 3 then
            FTimer[K].Target := Value and $FFFF
          else
            FTimer[K].Target := Value;
          if (FTimer[K].Mode and $80) = 0 then
            FTimer[K].Mode := FTimer[K].Mode or $400;
          ScheduleTimers;
        end;
    end;
    Exit;
  end;
  if FHW <> nil then
    FHW.Write(Address, Value, Size);
end;

procedure TPS2IOPMachine.SerializeState(State: TStateArchive);
begin
  CPU.SerializeState(State);
  State.Field(CPU.BadVAddr, SizeOf(CPU.BadVAddr));
  State.Field(CPU.Debug, SizeOf(CPU.Debug));
  State.Field(FIStat, SizeOf(FIStat));
  State.Field(FIMask, SizeOf(FIMask));
  State.Field(FICtrl, SizeOf(FICtrl));
  State.Field(FDPCR, SizeOf(FDPCR));
  State.Field(FDPCR2, SizeOf(FDPCR2));
  State.Field(FDICR, SizeOf(FDICR));
  State.Field(FDICR2, SizeOf(FDICR2));
  State.Field(FDMACEN, SizeOf(FDMACEN));
  State.Field(FDMACINTEN, SizeOf(FDMACINTEN));
  State.Field(FCh, SizeOf(FCh));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FSBus, SizeOf(FSBus));
  State.Field(FLineCycles, SizeOf(FLineCycles));
  if State.Loading then
    UpdateLine;
end;

end.
