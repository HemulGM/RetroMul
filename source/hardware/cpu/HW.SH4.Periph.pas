unit HW.SH4.Periph;

// SH7750-series on-chip modules outside the CPU core: INTC, TMU, DMAC, SCIF,
// BSC (ports and refresh), CPG/WDT, RTC, SCI and UBC registers. Time is in
// CPU clocks; the peripheral clock is a quarter of the CPU clock.
// Reference: Renesas SH7750 Series Hardware Manual (REJ09B0366).
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, HW.SH4;

const
  SH4PeripheralDivider = 4; // CPU clocks per peripheral (Pphi) clock
  SH4Never = High(Int64);

type
  // Memory-to-memory DMA on physical addresses; Step is the signed byte
  // increment per unit for each side.
  TSH4DMACopy = procedure(User: Pointer; Source, Dest: Cardinal; UnitSize: Integer; Count: Cardinal;
    SourceStep, DestStep: Integer);
  TSH4ScheduleChanged = procedure(User: Pointer; At: Int64);

  TSH4DMAChannel = record
    SAR, DAR, DMATCR, CHCR: Cardinal;
  end;

  TSH4TimerChannel = record
    TCOR, TCR: Cardinal;
    BaseCount: Cardinal;
    BaseTime: Int64; // clock of BaseCount's latch; counting when started
  end;

  TSH4PeriphState = record
    // INTC
    ICR, IPRA, IPRB, IPRC: Cardinal;
    IRLLevel: Integer;
    // TMU
    TOCR, TSTR, TCPR2: Cardinal;
    Timers: array[0..2] of TSH4TimerChannel;
    // DMAC
    DMA: array[0..3] of TSH4DMAChannel;
    DMAOR: Cardinal;
    // SCIF
    SCSMR2, SCBRR2, SCSCR2, SCFSR2, SCFCR2, SCSPTR2, SCLSR2: Cardinal;
    // SCI
    SCSMR1, SCBRR1, SCSCR1, SCTDR1, SCSSR1, SCSPTR1: Cardinal;
    // BSC
    BCR1, BCR2, WCR1, WCR2, WCR3, MCR, PCR, RTCSR, RTCNT, RTCOR, RFCR: Cardinal;
    PCTRA, PDTRA, PCTRB, PDTRB, GPIOIC: Cardinal;
    // CPG / WDT
    FRQCR, STBCR, STBCR2, WTCNT, WTCSR: Cardinal;
    // RTC
    RTCRegs: array[0..15] of Cardinal;
    // UBC
    UBCRegs: array[0..15] of Cardinal;
  end;

  TSH4Periph = class
  private
    FCPU: TSH4;
    FNow: PInt64;
    FCopy: TSH4DMACopy;
    FScheduleChanged: TSH4ScheduleChanged;
    FUser: Pointer;
    FCableType: Integer;
    FSerial: TBytes;
    FSerialCount: Integer;
    function TimerPeriod(Channel: Integer): Int64;
    function TimerRunning(Channel: Integer): Boolean; inline;
    function TimerCount(Channel: Integer; At: Int64): Cardinal;
    function NextUnderflow(Channel: Integer): Int64;
    procedure Rebase(Channel: Integer);
    procedure UpdateInterrupts;
    procedure Reschedule;
    procedure StartDMA(Channel: Integer);
    function ReadPortA: Cardinal;
  public
    S: TSH4PeriphState;
    constructor Create(CPU: TSH4; Now: PInt64; Copy: TSH4DMACopy; ScheduleChanged: TSH4ScheduleChanged; User: Pointer);
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    // Processes timer events due at Now^ and reports the next one.
    procedure Update;
    function NextEvent: Int64;
    // Highest pending external IRL priority (0: none), driven by the ASIC.
    procedure SetIRL(Level: Integer);
    // DDT-mode channel 2 completion requested by the ASIC.
    procedure CompleteDMA(Channel: Integer);
    procedure UpdateInterruptLines;
    // Bytes written to the SCIF transmitter since the last call.
    function TakeSerial: TBytes;
    procedure SerializeState(Archive: TStateArchive);
    // 0 VGA, 2 RGB, 3 composite: the A/V cable sense pins (port A bits 8-9).
    property CableType: Integer read FCableType write FCableType;
  end;

// The on-chip read/write callbacks for TSH4Bus (User is a TSH4Periph).
function SH4PeriphRead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
procedure SH4PeriphWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);

implementation

function SH4PeriphRead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TSH4Periph(User).Read(Address, Size);
end;

procedure SH4PeriphWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TSH4Periph(User).Write(Address, Value, Size);
end;

constructor TSH4Periph.Create(CPU: TSH4; Now: PInt64; Copy: TSH4DMACopy; ScheduleChanged: TSH4ScheduleChanged; User: Pointer);
begin
  inherited Create;
  if (CPU = nil) or (Now = nil) or not Assigned(Copy) or not Assigned(ScheduleChanged) then
    raise EArgumentException.Create('SH-4 peripherals require a CPU, clock and callbacks');
  FCPU := CPU;
  FNow := Now;
  FCopy := Copy;
  FScheduleChanged := ScheduleChanged;
  FUser := User;
  FCableType := 3;
  Reset;
end;

procedure TSH4Periph.Reset;
begin
  S := Default(TSH4PeriphState);
  for var I := 0 to 2 do
  begin
    S.Timers[I].TCOR := $FFFFFFFF;
    S.Timers[I].BaseCount := $FFFFFFFF;
    S.Timers[I].BaseTime := FNow^;
  end;
  S.SCFSR2 := $0060;
  S.SCSCR2 := 0;
  S.BCR2 := $3FFC;
  S.WCR1 := $77777777;
  S.WCR2 := $FFFEEFFF;
  S.WCR3 := $07777777;
  S.FRQCR := $0E0A;
  FSerialCount := 0;
  UpdateInterrupts;
end;

{ TMU }

function TSH4Periph.TimerRunning(Channel: Integer): Boolean;
begin
  Result := (S.TSTR and (1 shl Channel)) <> 0;
end;

function TSH4Periph.TimerPeriod(Channel: Integer): Int64;
begin
  // TPSC 0..4: Pphi/4, /16, /64, /256, /1024. RTC and external clocks are
  // approximated by the slowest internal divider.
  var TPSC := S.Timers[Channel].TCR and 7;
  if TPSC > 4 then
    TPSC := 4;
  Result := Int64(SH4PeripheralDivider) * (Int64(4) shl (TPSC * 2));
end;

function TSH4Periph.TimerCount(Channel: Integer; At: Int64): Cardinal;
begin
  var T := S.Timers[Channel];
  if not TimerRunning(Channel) then
    Exit(T.BaseCount);
  var Ticks := (At - T.BaseTime) div TimerPeriod(Channel);
  if Ticks <= Int64(T.BaseCount) then
    Exit(Cardinal(Int64(T.BaseCount) - Ticks));
  Ticks := Ticks - (Int64(T.BaseCount) + 1);
  var Span := Int64(T.TCOR) + 1;
  Result := Cardinal(Int64(T.TCOR) - Ticks mod Span);
end;

function TSH4Periph.NextUnderflow(Channel: Integer): Int64;
begin
  // The first underflow after BaseTime; later ones repeat every TCOR+1 ticks.
  var T := S.Timers[Channel];
  if not TimerRunning(Channel) then
    Exit(SH4Never);
  var Period := TimerPeriod(Channel);
  Result := T.BaseTime + (Int64(T.BaseCount) + 1) * Period;
  if Result <= FNow^ then
  begin
    var Span := (Int64(T.TCOR) + 1) * Period;
    Result := Result + ((FNow^ - Result) div Span + 1) * Span;
  end;
end;

procedure TSH4Periph.Rebase(Channel: Integer);
begin
  S.Timers[Channel].BaseCount := TimerCount(Channel, FNow^);
  S.Timers[Channel].BaseTime := FNow^ - (FNow^ - S.Timers[Channel].BaseTime) mod TimerPeriod(Channel);
  if not TimerRunning(Channel) then
    S.Timers[Channel].BaseTime := FNow^;
end;

function TSH4Periph.NextEvent: Int64;
begin
  Result := SH4Never;
  for var I := 0 to 2 do
    // An underflow matters while it can raise an interrupt or set UNF.
    if TimerRunning(I) and (((S.Timers[I].TCR and $20) <> 0) or ((S.Timers[I].TCR and $100) = 0)) then
    begin
      var At := NextUnderflow(I);
      if At < Result then
        Result := At;
    end;
end;

procedure TSH4Periph.Reschedule;
begin
  FScheduleChanged(FUser, NextEvent);
end;

procedure TSH4Periph.Update;
begin
  for var I := 0 to 2 do
    if TimerRunning(I) then
    begin
      var T := S.Timers[I];
      var First := T.BaseTime + (Int64(T.BaseCount) + 1) * TimerPeriod(I);
      if First <= FNow^ then
      begin
        S.Timers[I].TCR := S.Timers[I].TCR or $100;
        // Rebase on the most recent underflow, counting down from TCOR.
        var Period := TimerPeriod(I);
        var Span := (Int64(T.TCOR) + 1) * Period;
        var Last := First + ((FNow^ - First) div Span) * Span;
        S.Timers[I].BaseTime := Last;
        S.Timers[I].BaseCount := T.TCOR;
      end;
    end;
  UpdateInterrupts;
  Reschedule;
end;

{ INTC }

procedure TSH4Periph.SetIRL(Level: Integer);
begin
  if S.IRLLevel = Level then
    Exit;
  S.IRLLevel := Level;
  UpdateInterrupts;
end;

procedure TSH4Periph.UpdateInterruptLines;
begin
  UpdateInterrupts;
end;

procedure TSH4Periph.UpdateInterrupts;
var
  Best: Integer;
  Code: Cardinal;

  procedure Offer(Level: Integer; ACode: Cardinal);
  begin
    if Level > Best then
    begin
      Best := Level;
      Code := ACode;
    end;
  end;

begin
  Best := 0;
  Code := 0;
  // IRL priority n is input 15-n; INTEVT 200h + 20h * input.
  if S.IRLLevel > 0 then
    Offer(S.IRLLevel, $200 + Cardinal(15 - S.IRLLevel) * $20);
  for var I := 0 to 2 do
    if (S.Timers[I].TCR and $120) = $120 then
      Offer(Integer((S.IPRA shr (12 - I * 4)) and 15), $400 + Cardinal(I) * $20);
  for var I := 0 to 3 do
    if (S.DMA[I].CHCR and 6) = 6 then
      Offer(Integer((S.IPRC shr 8) and 15), $640 + Cardinal(I) * $20);
  if (S.DMAOR and 4) <> 0 then
    Offer(Integer((S.IPRC shr 8) and 15), $6C0);
  FCPU.SetInterrupt(Best, Code);
end;

{ DMAC }

procedure TSH4Periph.StartDMA(Channel: Integer);
begin
  // Auto-request memory-to-memory transfers complete immediately. External
  // requests (DDT channel 2 from the ASIC) are completed by CompleteDMA.
  var C := S.DMA[Channel];
  if ((S.DMAOR and 7) <> 1) or ((C.CHCR and 3) <> 1) then
    Exit;
  if ((C.CHCR shr 8) and 15) <> 4 then
    Exit;
  var UnitSize: Integer;
  case (C.CHCR shr 4) and 7 of
    0: UnitSize := 8;
    1: UnitSize := 1;
    2: UnitSize := 2;
    3: UnitSize := 4;
  else
    UnitSize := 32;
  end;
  var Count := C.DMATCR and $FFFFFF;
  if Count = 0 then
    Count := $1000000;
  var SourceStep := 0;
  case (C.CHCR shr 12) and 3 of
    1: SourceStep := UnitSize;
    2: SourceStep := -UnitSize;
  end;
  var DestStep := 0;
  case (C.CHCR shr 14) and 3 of
    1: DestStep := UnitSize;
    2: DestStep := -UnitSize;
  end;
  FCopy(FUser, C.SAR and $1FFFFFFF, C.DAR and $1FFFFFFF, UnitSize, Count, SourceStep, DestStep);
  S.DMA[Channel].SAR := C.SAR + Cardinal(Int64(SourceStep) * Count);
  S.DMA[Channel].DAR := C.DAR + Cardinal(Int64(DestStep) * Count);
  CompleteDMA(Channel);
end;

procedure TSH4Periph.CompleteDMA(Channel: Integer);
begin
  S.DMA[Channel].DMATCR := 0;
  S.DMA[Channel].CHCR := S.DMA[Channel].CHCR or 2;
  UpdateInterrupts;
end;

{ Ports }

function TSH4Periph.ReadPortA: Cardinal;
begin
  // Each pin has two control bits: bit 2n set = output. Pins 0 and 1 are
  // looped together (pull-ups when both are inputs); pins 8-9 sense the
  // A/V cable. Outputs read back their latch.
  var Pin0Out := (S.PCTRA and 1) <> 0;
  var Pin1Out := (S.PCTRA and 4) <> 0;
  var Level0 := Cardinal(1);
  var Level1 := Cardinal(1);
  if Pin0Out then
  begin
    Level0 := S.PDTRA and 1;
    Level1 := Level0;
  end;
  if Pin1Out then
  begin
    Level1 := (S.PDTRA shr 1) and 1;
    if not Pin0Out then
      Level0 := Level1;
  end;
  Result := Level0 or (Level1 shl 1);
  for var Pin := 2 to 15 do
    if (S.PCTRA and (1 shl (Pin * 2))) <> 0 then
      Result := Result or (S.PDTRA and (1 shl Pin))
    else if Pin in [8, 9] then
      Result := Result or ((Cardinal(FCableType) shr (Pin - 8)) and 1) shl Pin;
end;

{ Registers }

function TSH4Periph.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  case Address of
    // BSC
    $FF800000: Result := S.BCR1;
    $FF800004: Result := S.BCR2;
    $FF800008: Result := S.WCR1;
    $FF80000C: Result := S.WCR2;
    $FF800010: Result := S.WCR3;
    $FF800014: Result := S.MCR;
    $FF800018: Result := S.PCR;
    $FF80001C: Result := S.RTCSR;
    $FF800020: Result := S.RTCNT;
    $FF800024: Result := S.RTCOR;
    $FF800028:
      // Refresh counter: advances with the refresh timer (about every 16 us).
      Result := Cardinal((FNow^ div 3200) and $3FF);
    $FF80002C: Result := S.PCTRA;
    $FF800030: Result := ReadPortA;
    $FF800040: Result := S.PCTRB;
    $FF800044: Result := S.PDTRB;
    $FF800048: Result := S.GPIOIC;
    // DMAC
    $FFA00000..$FFA0003F:
      begin
        var C := (Address shr 4) and 3;
        case Address and $C of
          0: Result := S.DMA[C].SAR;
          4: Result := S.DMA[C].DAR;
          8: Result := S.DMA[C].DMATCR;
        else
          Result := S.DMA[C].CHCR;
        end;
      end;
    $FFA00040: Result := S.DMAOR;
    // CPG / WDT
    $FFC00000: Result := S.FRQCR;
    $FFC00004: Result := S.STBCR;
    $FFC00008: Result := S.WTCNT;
    $FFC0000C: Result := S.WTCSR;
    $FFC00010: Result := S.STBCR2;
    // RTC
    $FFC80000..$FFC8003C:
      if Address = $FFC80000 then
        Result := Cardinal((FNow^ div (200000000 div 128)) and $7F) // R64CNT
      else
        Result := S.RTCRegs[(Address shr 2) and 15];
    // INTC
    $FFD00000: Result := S.ICR;
    $FFD00004: Result := S.IPRA;
    $FFD00008: Result := S.IPRB;
    $FFD0000C: Result := S.IPRC;
    // TMU
    $FFD80000: Result := S.TOCR;
    $FFD80004: Result := S.TSTR;
    $FFD80008: Result := S.Timers[0].TCOR;
    $FFD8000C: Result := TimerCount(0, FNow^);
    $FFD80010: Result := S.Timers[0].TCR;
    $FFD80014: Result := S.Timers[1].TCOR;
    $FFD80018: Result := TimerCount(1, FNow^);
    $FFD8001C: Result := S.Timers[1].TCR;
    $FFD80020: Result := S.Timers[2].TCOR;
    $FFD80024: Result := TimerCount(2, FNow^);
    $FFD80028: Result := S.Timers[2].TCR;
    $FFD8002C: Result := S.TCPR2;
    // SCI
    $FFE00000: Result := S.SCSMR1;
    $FFE00004: Result := S.SCBRR1;
    $FFE00008: Result := S.SCSCR1;
    $FFE0000C: Result := S.SCTDR1;
    $FFE00010: Result := S.SCSSR1 or $84;
    $FFE0001C: Result := S.SCSPTR1;
    // SCIF: the transmitter is always empty, nothing is received.
    $FFE80000: Result := S.SCSMR2;
    $FFE80004: Result := S.SCBRR2;
    $FFE80008: Result := S.SCSCR2;
    $FFE80010: Result := S.SCFSR2 or $60;
    $FFE80014: Result := 0;
    $FFE80018: Result := S.SCFCR2;
    $FFE8001C: Result := 0;
    $FFE80020: Result := S.SCSPTR2;
    $FFE80024: Result := S.SCLSR2;
    // UBC
    $FF200000..$FF20003F:
      Result := S.UBCRegs[(Address shr 2) and 15];
  end;
  case Size of
    1: Result := Result and $FF;
    2: Result := Result and $FFFF;
  end;
end;

procedure TSH4Periph.Write(Address, Value: Cardinal; Size: Integer);
begin
  case Address of
    $FF800000: S.BCR1 := Value;
    $FF800004: S.BCR2 := Value and $FFFF;
    $FF800008: S.WCR1 := Value;
    $FF80000C: S.WCR2 := Value;
    $FF800010: S.WCR3 := Value;
    $FF800014: S.MCR := Value;
    $FF800018: S.PCR := Value and $FFFF;
    $FF80001C: S.RTCSR := Value and $FF;
    $FF800020: S.RTCNT := Value and $FF;
    $FF800024: S.RTCOR := Value and $FF;
    $FF800028: S.RFCR := Value and $3FF;
    $FF80002C: S.PCTRA := Value;
    $FF800030: S.PDTRA := Value and $FFFF;
    $FF800040: S.PCTRB := Value;
    $FF800044: S.PDTRB := Value and $FFFF;
    $FF800048: S.GPIOIC := Value and $FFFF;
    $FFA00000..$FFA0003F:
      begin
        var C := (Address shr 4) and 3;
        case Address and $C of
          0: S.DMA[C].SAR := Value;
          4: S.DMA[C].DAR := Value;
          8: S.DMA[C].DMATCR := Value and $FFFFFF;
        else
          begin
            // TE clears only by writing 0 after reading 1.
            var TE := S.DMA[C].CHCR and Value and 2;
            S.DMA[C].CHCR := (Value and not Cardinal(2)) or TE;
            UpdateInterrupts;
            StartDMA(C);
          end;
        end;
      end;
    $FFA00040:
      begin
        S.DMAOR := (Value and $8307) and not Cardinal(6) or (S.DMAOR and Value and 6);
        UpdateInterrupts;
        for var C := 0 to 3 do
          StartDMA(C);
      end;
    $FFC00000: S.FRQCR := Value and $FFFF;
    $FFC00004: S.STBCR := Value and $FF;
    $FFC00008:
      if (Value shr 8) = $5A then
        S.WTCNT := Value and $FF;
    $FFC0000C:
      if (Value shr 8) = $A5 then
        S.WTCSR := Value and $FF;
    $FFC00010: S.STBCR2 := Value and $FF;
    $FFC80000..$FFC8003C:
      S.RTCRegs[(Address shr 2) and 15] := Value;
    $FFD00000: S.ICR := Value and $FFFF;
    $FFD00004:
      begin
        S.IPRA := Value and $FFFF;
        UpdateInterrupts;
      end;
    $FFD00008:
      begin
        S.IPRB := Value and $FFFF;
        UpdateInterrupts;
      end;
    $FFD0000C:
      begin
        S.IPRC := Value and $FFFF;
        UpdateInterrupts;
      end;
    $FFD80000: S.TOCR := Value and 1;
    $FFD80004:
      begin
        for var I := 0 to 2 do
          Rebase(I);
        S.TSTR := Value and 7;
        for var I := 0 to 2 do
          S.Timers[I].BaseTime := FNow^;
        Reschedule;
      end;
    $FFD80008, $FFD80014, $FFD80020:
      begin
        var I := (Address - $FFD80008) div 12;
        Rebase(I);
        S.Timers[I].TCOR := Value;
        Reschedule;
      end;
    $FFD8000C, $FFD80018, $FFD80024:
      begin
        var I := (Address - $FFD8000C) div 12;
        Rebase(I);
        S.Timers[I].BaseCount := Value;
        S.Timers[I].BaseTime := FNow^;
        Reschedule;
      end;
    $FFD80010, $FFD8001C, $FFD80028:
      begin
        var I := (Address - $FFD80010) div 12;
        Rebase(I);
        // UNF/ICPF clear by writing 0.
        var Flags := S.Timers[I].TCR and Value and $300;
        S.Timers[I].TCR := (Value and $3FF and not Cardinal($300)) or Flags;
        S.Timers[I].BaseTime := FNow^;
        UpdateInterrupts;
        Reschedule;
      end;
    $FFD8002C: S.TCPR2 := Value;
    $FFE00000: S.SCSMR1 := Value and $FF;
    $FFE00004: S.SCBRR1 := Value and $FF;
    $FFE00008: S.SCSCR1 := Value and $FF;
    $FFE0000C: S.SCTDR1 := Value and $FF;
    $FFE00010: S.SCSSR1 := S.SCSSR1 and Value and $F8;
    $FFE0001C: S.SCSPTR1 := Value and $FF;
    $FFE80000: S.SCSMR2 := Value and $FFFF;
    $FFE80004: S.SCBRR2 := Value and $FF;
    $FFE80008: S.SCSCR2 := Value and $FFFF;
    $FFE8000C:
      begin
        if FSerialCount >= Length(FSerial) then
          SetLength(FSerial, FSerialCount * 2 + 256);
        FSerial[FSerialCount] := Byte(Value);
        Inc(FSerialCount);
      end;
    $FFE80010: S.SCFSR2 := S.SCFSR2 and Value;
    $FFE80018: S.SCFCR2 := Value and $FFFF;
    $FFE80020: S.SCSPTR2 := Value and $FFFF;
    $FFE80024: S.SCLSR2 := S.SCLSR2 and Value and 1;
    $FF200000..$FF20003F:
      S.UBCRegs[(Address shr 2) and 15] := Value;
  end;
end;

function TSH4Periph.TakeSerial: TBytes;
begin
  Result := Copy(FSerial, 0, FSerialCount);
  FSerialCount := 0;
end;

procedure TSH4Periph.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading then
  begin
    if (S.IRLLevel < 0) or (S.IRLLevel > 15) then
      raise EReadError.Create('SH-4 snapshot IRL level');
    UpdateInterrupts;
  end;
end;

end.
