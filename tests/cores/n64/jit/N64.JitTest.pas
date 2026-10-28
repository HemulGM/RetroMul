unit N64.JitTest;

// The N64 core's generated code against its interpreter. Random programs run
// on two cores over two identical memories: one runs blocks as generated code
// (HW.JIT's backend on this target, then its model), made at a block's first
// run; the other interprets instruction by instruction (no blocks). Both get
// the same calls: what those return, the snapshots and the memories must
// match after each.
//
// The CPU: programs of every kind of instruction through random TLB
// mappings, kseg0 and kseg1, storing into their own code, with code
// rewritten from outside (RunBatch against as many Steps); loops that
// rewrite their next words in kseg0 and kseg1; loops of the integer
// instructions the code writes out itself (on values near the edges) and of
// loads and stores through kseg0 and kseg1. The RSP: programs of every
// kind of instruction in budgets (ExecuteCycles) and in run-ahead windows
// (RunAhead and ContinueAhead in parts with Least, fences, Rewind or
// EndAhead), IMEM, DMEM and the SP registers changed from outside.

interface

{$Q-}{$R-}

uses
  System.Classes;

// Programs random programs for each core and each code generator; Report
// gets a line for each and the result. True: no difference (and generated
// code ran), or no generated code on this target.
function RunN64JitTest(Programs: Integer; Report: TStrings): Boolean;

implementation

uses
  System.SysUtils, System.Math, N64.Types, N64.CPU, N64.RSP, N64.SoftFloat, Core.Snapshots;

var
  Rng: Cardinal;

function Next(Range: Cardinal): Cardinal;
begin
  // The generator's high bits (its low ones repeat with short periods).
  Rng := Cardinal((UInt64(Rng) * 1664525 + 1013904223) and $FFFFFFFF);
  Result := Cardinal((UInt64(Rng) * Range) shr 32);
end;

function Rand32: Cardinal;
begin
  Result := (Next($10000) shl 16) or Next($10000);
end;

function Pick(const Values: array of Cardinal): Cardinal;
begin
  Result := Values[Next(Length(Values))];
end;

function StateBytes(Core: TObject): TBytes;
begin
  var Stream := TMemoryStream.Create;
  try
    var State := TStateArchive.Create(Stream, False);
    try
      if Core is TN64CPU then
        TN64CPU(Core).SerializeState(State)
      else
        TN64RSP(Core).SerializeState(State);
    finally
      State.Free;
    end;
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Move(Stream.Memory^, Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function SnapshotDifference(A, B: TObject): Integer;
begin
  // The first byte where the snapshots differ (-1: none).
  var X := StateBytes(A);
  var Y := StateBytes(B);
  for var I := 0 to Min(High(X), High(Y)) do
    if X[I] <> Y[I] then
      Exit(I);
  if Length(X) <> Length(Y) then
    Exit(Min(Length(X), Length(Y)));
  Result := -1;
end;

{ The CPU }

type
  TCPUBus = class(TN64Bus)
  public
    constructor Create;
    function Read8(Address: Cardinal): Byte; override;
    procedure Write8(Address: Cardinal; Value: Byte); override;
    function Unlike(Other: TCPUBus): string;
  end;

  TCPUs = array[0..1] of TN64CPU;
  TCPUBuses = array[0..1] of TCPUBus;

constructor TCPUBus.Create;
begin
  inherited Create;
  FDirectMemory := True;
end;

function TCPUBus.Read8(Address: Cardinal): Byte;
begin
  // Past RDRAM a device: its address's low byte.
  if Address < $800000 then
    Result := FRAM[Address]
  else
    Result := Byte(Address);
end;

procedure TCPUBus.Write8(Address: Cardinal; Value: Byte);
begin
  if Address < $800000 then
    WriteRAM8(Address, Value);
end;

function TCPUBus.Unlike(Other: TCPUBus): string;
begin
  Result := '';
  if not CompareMem(@FRAM[0], @Other.FRAM[0], Length(FRAM)) then
    for var I := 0 to High(FRAM) do
      if FRAM[I] <> Other.FRAM[I] then
        Exit(Format('RDRAM %6.6x: %2.2x against %2.2x', [I, FRAM[I], Other.FRAM[I]]));
  if not CompareMem(@FHiddenRAM[0], @Other.FHiddenRAM[0], Length(FHiddenRAM)) then
    Result := 'hidden RDRAM bits';
end;

const
  // Virtual regions the CPU's programs use: kuseg pages, kseg0, kseg1, kseg2.
  Bases: array[0..5] of Cardinal = ($00400000, $00401000, $7F000000, $80100000, $A0200000, $C0000000);

var
  // Programs with the wider mix of RichInstruction, and dense with floating
  // point on mostly moderate values.
  RichMix, FPMix: Boolean;

function RichInstruction: Cardinal;
begin
  // ALU, shifts, HI/LO, multiply/divide, branches (likely too), jumps, FP
  // loads, stores, moves and arithmetic, COUNT/COMPARE/Cause writes, Random
  // reads.
  var Rs := Cardinal(8 + Next(8));
  var Rt := Cardinal(8 + Next(8));
  var Rd := Cardinal(8 + Next(8));
  case Next(16) of
    0..3:
      Result := (Rs shl 21) or (Rt shl 16) or (Rd shl 11) or (Next(32) shl 6) or
        Pick([0, 2, 3, 4, 6, 7, 33, 35, 36, 37, 38, 39, 42, 43, 16, 18, 17, 19, 24, 25, 26, 27, 32, 34, 15, 0, 0, 37,
          20, 22, 23, 28, 29, 30, 31, 44, 45, 46, 47, 56, 58, 59, 60, 62, 63]);
    4, 5:
      Result := (Cardinal(Pick([9, 10, 11, 12, 13, 14, 15, 8, 9, 13])) shl 26) or (Rs shl 21) or (Rt shl 16) or Next($10000);
    6, 7:
      if Next(3) = 0 then
        Result := (1 shl 26) or (Rs shl 21) or (Cardinal(Pick([0, 1, 2, 3, 16, 17, 18, 19])) shl 16) or
          ((Next(32) + $FFF0) and $FFFF)
      else
        Result := (Cardinal(Pick([4, 5, 6, 7, 20, 21, 22, 23])) shl 26) or (Rs shl 21) or (Rt shl 16) or
          ((Next(32) + $FFF0) and $FFFF);
    8:
      // Into the first 1 MB of the region (code everywhere there).
      Result := (Cardinal(Pick([2, 3])) shl 26) or Next($40000);
    9:
      Result := ((1 + Next(7)) shl 21) or (Rd shl 11) or Pick([8, 9]);
    10, 11:
      Result := (Cardinal(Pick([49, 57, 53, 61])) shl 26) or ((1 + Next(7)) shl 21) or (Next(32) shl 16) or
        (Next($200) * 4 + Pick([0, 0, 0, 4, 2]));
    12:
      Result := (17 shl 26) or (Cardinal(Pick([0, 1, 4, 5])) shl 21) or (Rt shl 16) or (Next(32) shl 11);
    13:
      Result := (17 shl 26) or (Cardinal(Pick([16, 17])) shl 21) or (Next(32) shl 16) or (Next(32) shl 11) or
        (Next(32) shl 6) or Pick([0, 1, 2, 3, 4, 5, 6, 7, 32, 33, 36, 13, 50, 60, 0, 1, 2, 3, 4]);
    14:
      Result := (16 shl 26) or (4 shl 21) or (Rt shl 16) or (Cardinal(Pick([11, 9, 13, 11])) shl 11);
  else
    Result := (16 shl 26) or (Rt shl 16) or (Cardinal(Pick([9, 1])) shl 11);
  end;
end;

function CPUInstruction: Cardinal;
begin
  if RichMix and (Next(2) = 0) then
    Exit(RichInstruction);
  // Registers 1..7 hold region addresses (refreshed by LUI/ORI), 8..15 data.
  var Base := 1 + Next(7);
  var Data := 8 + Next(8);
  var Offset := Next($200) * 4 + Pick([0, 0, 0, 1, 2, 3]);
  case Next(30) of
    0..9:
      // Loads and stores of every size, aligned and not.
      Result := (Pick([32, 33, 35, 36, 37, 39, 55, 34, 38, 26, 27, 40, 41, 43, 63, 42, 46, 44, 45]) shl 26) or
        (Base shl 21) or (Data shl 16) or (Offset and $FFFF);
    10, 11:
      Result := (Cardinal(Pick([9, 12, 13, 14])) shl 26) or (Data shl 21) or (Data shl 16) or Next($10000);
    12:
      // A new region address in a base register.
      Result := (15 shl 26) or (Base shl 16) or (Pick(Bases) shr 16) + Next(4);
    13:
      Result := (Data shl 21) or (Data shl 16) or ((8 + Next(8)) shl 11) or Pick([32, 33, 36, 37, 38, 42, 43, 45, 47]);
    14:
      // MTC0 EntryHi (ASID), EntryLo0/1, PageMask, Index.
      Result := (16 shl 26) or (4 shl 21) or (Data shl 16) or (Pick([10, 10, 2, 3, 5, 0]) shl 11);
    15:
      // TLBWI, TLBWR, TLBR, TLBP.
      Result := (16 shl 26) or (16 shl 21) or Pick([2, 6, 1, 8]);
    16:
      // MTC0 Status: modes, EXL, ERL, UX/SX/KX.
      Result := (16 shl 26) or (4 shl 21) or (Data shl 16) or (12 shl 11);
    17:
      // ERET.
      Result := (16 shl 26) or (16 shl 21) or 24;
    18:
      Result := (Cardinal(Pick([4, 5])) shl 26) or (Data shl 21) or (Data shl 16) or (Next(8) + 1);
    19:
      // LL/SC, LLD/SCD.
      Result := (Cardinal(Pick([48, 56, 52, 60])) shl 26) or (Base shl 21) or (Data shl 16) or (Next($100) * 8);
    20:
      // MFC0 of the TLB registers and BadVAddr/Context.
      Result := (16 shl 26) or (Data shl 16) or (Pick([0, 2, 3, 4, 5, 8, 10, 12, 13, 14]) shl 11);
  else
    // Data values for the COP0 writes.
    Result := (Cardinal(Pick([15, 13, 9])) shl 26) or (Data shl 21) or (Data shl 16) or Next($10000);
  end;
end;

procedure PutBoth(const Buses: TCPUBuses; Address, Value: Cardinal);
begin
  Buses[0].WriteRAM32(Address, Value);
  Buses[1].WriteRAM32(Address, Value);
end;

procedure FillCode(const Buses: TCPUBuses);
begin
  // Code everywhere the PC can go: the low 1 MB (the regions' pages, the
  // exception vectors, RDRAM behind the TLB mappings).
  for var Page := 0 to 255 do
  begin
    var I := 0;
    while I < 1024 do
    begin
      var Block: array[0..3] of Cardinal;
      var Count := 1;
      Block[0] := CPUInstruction;
      if Next(64) = 0 then
        Block[0] := Rand32
      else if FPMix and (Next(24) = 0) then
      begin
        // CTC1 FCR31: a rounding mode, now and then an exception enabled.
        var Value := Cardinal(Pick([0, 0, 0, 1, 2, 3]));
        if Next(3) = 0 then
          Value := Value or Cardinal(Pick([$80, $80, $100, $200, $400, $800, $F80]));
        if Next(2) = 0 then
          Value := Value or (Next(32) shl 2);
        Block[0] := (13 shl 26) or (16 shl 16) or Value;
        Block[1] := (Cardinal(17) shl 26) or (6 shl 21) or (16 shl 16) or (31 shl 11);
        Count := 2;
      end
      else if FPMix and (Next(8) = 0) then
      begin
        // A compare, then BC1F/BC1T (likely or not), its delay slot an FP add
        // or a NOP.
        Block[0] := (Cardinal(17) shl 26) or (Cardinal(16 + Next(2)) shl 21) or (Next(32) shl 16) or (Next(32) shl 11) or
          Cardinal(48 + Next(16));
        Block[1] := (Cardinal(17) shl 26) or (8 shl 21) or (Next(4) shl 16) or 2;
        Block[2] := Pick([0, (Cardinal(17) shl 26) or (16 shl 21) or (Next(32) shl 16) or (Next(32) shl 11) or
          (Next(32) shl 6)]);
        Count := 3;
      end
      else if FPMix and (Next(3) = 0) then
      begin
        // Add, sub, mul, div, sqrt (now and then abs, mov, neg), single and
        // double.
        for var K := 0 to 2 do
        begin
          var Fn := Cardinal(Next(5));
          if Next(8) = 0 then
            Fn := 5 + Next(3);
          Block[K] := (Cardinal(17) shl 26) or (Cardinal(16 + Next(2)) shl 21) or (Next(32) shl 16) or
            (Next(32) shl 11) or (Next(32) shl 6) or Fn;
        end;
        Count := 3;
      end
      else if RichMix and (Next(8) = 0) then
      begin
        // Back-to-back accesses through one base, now and then all on one
        // register (a load's target used next).
        var Base := 1 + Next(7);
        var Same := Cardinal(8 + Next(8));
        var Shared := Next(2) = 0;
        for var K := 0 to 2 do
        begin
          var Reg := Cardinal(8 + Next(8));
          if Shared then
            Reg := Same;
          Block[K] := (Cardinal(Pick([43, 35, 43, 57, 49, 41, 36, 53, 61, 55, 63, 47])) shl 26) or
            (Cardinal(Base) shl 21) or (Reg shl 16) or (Next($100) * 8);
        end;
        Count := 3;
      end
      else if Next(6) = 0 then
      begin
        // LUI/ORI r16 with a meaningful COP0 value, MTC0, maybe TLBWI/WR.
        var Reg := Pick([12, 12, 10, 10, 2, 3, 5, 0]);
        if RichMix and (Next(3) = 0) then
          Reg := Pick([12, 11, 13]);
        var Value: Cardinal;
        case Reg of
          11:
            Value := Next(20000);
          13:
            Value := Pick([$100, $200, 0]);
          12:
            if RichMix and (Next(2) = 0) then
              Value := Pick([$34008001, $3400FF01, $30008001, $34000301, $30000000])
            else
              Value := Pick([$34000000, $34000010, $34000008, $340000E0, $34000002, $34000004, $34000012, $340000F0]);
          10:
            Value := (Pick(Bases) and $FFFFE000) + Next(16) * $2000 + Next(4);
          2, 3:
            Value := (Next(256) shl 6) or (Pick([2, 3, 5]) shl 3) or Next(8);
          5:
            Value := Pick([0, $6000, $1E000]);
        else
          Value := Next(32);
        end;
        Block[0] := (15 shl 26) or (16 shl 16) or (Value shr 16);
        Block[1] := (13 shl 26) or (16 shl 21) or (16 shl 16) or (Value and $FFFF);
        Block[2] := (16 shl 26) or (4 shl 21) or (16 shl 16) or (Cardinal(Reg) shl 11);
        Count := 3;
        if (Reg in [2, 3, 0]) and (Next(2) = 0) then
        begin
          Block[3] := (16 shl 26) or (16 shl 21) or Pick([2, 6]);
          Count := 4;
        end;
      end;
      for var K := 0 to Count - 1 do
        if I < 1024 then
        begin
          PutBoth(Buses, Cardinal(Page) * $1000 + Cardinal(I) * 4, Block[K]);
          Inc(I);
        end;
    end;
  end;
end;

procedure SetUp(const CPUs: TCPUs);
begin
  // The same registers, TLB and context for both.
  var Entries: array[0..31] of TN64TLBEntry;
  for var E := 0 to 31 do
  begin
    // Pages of 4 KB..64 KB onto the low 1 MB of RDRAM.
    Entries[E] := Default(TN64TLBEntry);
    Entries[E].Mask := Pick([0, 0, $6000, $1E000]);
    var VPN := (SX(Pick(Bases), 32) and UInt64($C00000FFFFFFE000)) + UInt64(Next(16)) * $2000;
    if Next(3) = 0 then
      VPN := SX(Rand32 and $FFFFE000, 32) and UInt64($C00000FFFFFFE000);
    Entries[E].EntryHi := VPN or Next(4);
    var Global := Cardinal(Ord(Next(4) = 0));
    Entries[E].Lo0 := (Next(256) shl 6) or (Pick([2, 3, 5]) shl 3) or (Pick([2, 6, 6, 4, 0]) or Global);
    Entries[E].Lo1 := (Next(256) shl 6) or (Pick([2, 3, 5]) shl 3) or (Pick([2, 6, 6, 4, 0]) or Global);
  end;
  var FPR: array[0..31] of UInt64;
  for var R := 0 to 31 do
  begin
    var V := (UInt64(Rand32) shl 32) or Rand32;
    if FPMix then
    begin
      // Short significands now and then (results often exact), moderate
      // doubles, moderate singles.
      if Next(3) = 0 then
        V := V and not UInt64($FFFFFFFFFF0000);
      case Next(3) of
        1:
          V := (UInt64(Next(2)) shl 63) or (UInt64(1023 - 40 + Next(80)) shl 52) or (V and $FFFFFFFFFFFFF);
        2:
          V := (V and $FFFFFFFF00000000) or (Cardinal(Next(2)) shl 31) or (Cardinal(127 - 20 + Next(40)) shl 23) or
            (Cardinal(V) and $7FFFFF);
      end;
    end;
    FPR[R] := V;
  end;
  var GPR: array[1..7] of UInt64;
  for var R := 1 to 7 do
    GPR[R] := UInt64(SX(Pick(Bases) + Next($100) * 16, 32));
  var Status := UInt64(Pick([$34000000, $34000008, $34000010, $340000E0, $34000002, $34000004]));
  if RichMix then
    // FR off, interrupts on (the timer, software), a COMPARE soon.
    Status := UInt64(Pick([$34000000, $30000000, $34008001, $3400FF01, $30008001, $34000010, $34000002]));
  var Compare := UInt64(Next(6000));
  var ASID := UInt64(Next(4));
  var Start := UInt64(SX(Pick(Bases), 32));
  var HostFloat := SFHostReady and (Next(4) <> 0);
  for var C in CPUs do
  begin
    for var E := 0 to 31 do
      C.TLB[E] := Entries[E];
    C.InvalidateTLBCache;
    for var R := 0 to 31 do
      C.FPR[R] := FPR[R];
    for var R := 1 to 7 do
      C.GPR[R] := GPR[R];
    C.CP0[12] := Status;
    if RichMix then
      C.CP0[11] := Compare;
    C.CP0[10] := ASID;
    C.PC := Start;
    C.HostFloat := HostFloat;
  end;
end;

function NewCPUs(const Buses: TCPUBuses): TCPUs;
begin
  // 0 with generated code, 1 interpreting.
  Result[0] := TN64CPU.Create(Buses[0]);
  Result[1] := TN64CPU.Create(Buses[1]);
  Result[0].UseJit := True;
  Result[1].UseBlocks := False;
  Result[1].UseJit := False;
end;

function RunBoth(const CPUs: TCPUs; Most: Integer; Budget: UInt64; out Steps: Integer): string;
begin
  // A batch with generated code, its steps interpreted: the same PClocks,
  // snapshots.
  Result := '';
  var Cycles: UInt64;
  Steps := CPUs[0].RunBatch(Most, Budget, Cycles);
  var Sum: UInt64 := 0;
  for var K := 1 to Steps do
  begin
    CPUs[1].Step;
    Inc(Sum, CPUs[1].CyclesConsumed);
  end;
  if (Steps < 1) or (Steps > Most) or (Cycles <> Sum) then
    Exit(Format('batch of %d (of %d, budget %d): %d PClocks against %d', [Steps, Most, Budget, Cycles, Sum]));
  var At := SnapshotDifference(CPUs[0], CPUs[1]);
  if At < 0 then
    Exit;
  // Which register, if one.
  var Where := '';
  for var R := 31 downto 0 do
    if CPUs[0].FPR[R] <> CPUs[1].FPR[R] then
      Where := Format(', FPR[%d] %x against %x', [R, CPUs[0].FPR[R], CPUs[1].FPR[R]]);
  for var R := 31 downto 0 do
    if CPUs[0].CP0[R] <> CPUs[1].CP0[R] then
      Where := Format(', CP0[%d] %x against %x', [R, CPUs[0].CP0[R], CPUs[1].CP0[R]]);
  if CPUs[0].LO <> CPUs[1].LO then
    Where := Format(', LO %x against %x', [CPUs[0].LO, CPUs[1].LO]);
  if CPUs[0].HI <> CPUs[1].HI then
    Where := Format(', HI %x against %x', [CPUs[0].HI, CPUs[1].HI]);
  for var R := 31 downto 0 do
    if CPUs[0].GPR[R] <> CPUs[1].GPR[R] then
      Where := Format(', GPR[%d] %x against %x', [R, CPUs[0].GPR[R], CPUs[1].GPR[R]]);
  Result := Format('snapshot differs at byte %d (PC %x against %x%s)', [At, CPUs[0].PC, CPUs[1].PC, Where]);
end;

type
  TCounts = record
    Programs, Failures: Integer;
    Steps, Compiled, Runs, Windows, Rewinds, Raised: Int64;
    First: string;
    procedure Add(const Detail: string);
  end;

procedure TCounts.Add(const Detail: string);
begin
  // (A program's result, or an exception out of it: a failure.)
  Inc(Programs);
  if Detail <> '' then
  begin
    Inc(Failures);
    if First = '' then
      First := Format('program %d: %s', [Programs, Detail]);
  end;
end;

function CPUProgram(P, Steps: Integer; var Counts: TCounts): string;
begin
  Result := '';
  RichMix := (P mod 4) >= 2;
  FPMix := (P mod 4) = 3;
  var Buses: TCPUBuses;
  Buses[0] := TCPUBus.Create;
  Buses[1] := TCPUBus.Create;
  var CPUs := NewCPUs(Buses);
  try
    // One program in eight with tiny block pools: all dropped (their code
    // too) often.
    if (P mod 8) = 5 then
      CPUs[0].LimitBlocks(1 + Integer(Next(64)), 1);
    FillCode(Buses);
    SetUp(CPUs);
    var S := 0;
    var Batch := 0;
    while (S < Steps) and (Result = '') do
    begin
      // Mostly long batches (chains of blocks), now and then short ones.
      var Most := 1 + Integer(Next(400));
      var Budget := UInt64(1 + Next(3000));
      if Next(4) = 0 then
      begin
        Most := 1 + Integer(Next(16));
        Budget := 1 + Next(100);
      end;
      var N: Integer;
      Result := RunBoth(CPUs, Most, Budget, N);
      Inc(S, Max(1, N));
      Inc(Batch);
      if (Result = '') and ((Batch and 7) = 0) then
        Result := Buses[0].Unlike(Buses[1]);
      // Code rewritten from outside (as DMA does) now and then, near the PC
      // when it is unmapped.
      if (Result = '') and (Next(6) = 0) then
      begin
        var Address := Next($40000) * 4;
        var PC := CPUs[1].PC;
        if ((PC shr 29) and 7) in [4, 5] then
          Address := Cardinal((Int64(PC and $1FFFFFFC) + (Int64(Next(24)) - 8) * 4) and $FFFFC);
        var Op := CPUInstruction;
        if Next(2) = 0 then
          PutBoth(Buses, Address, Op)
        else
          // Byte by byte (as byte DMA and stores write).
          for var K := 0 to 3 do
          begin
            Buses[0].WriteRAM8(Address + Cardinal(K), Byte(Op shr ((3 - K) * 8)));
            Buses[1].WriteRAM8(Address + Cardinal(K), Byte(Op shr ((3 - K) * 8)));
          end;
      end;
    end;
    if Result = '' then
      Result := Buses[0].Unlike(Buses[1]);
    if Result <> '' then
      Result := Format('step %d: %s', [S, Result]);
    Inc(Counts.Steps, S);
    Inc(Counts.Compiled, CPUs[0].JitCompiled);
    Inc(Counts.Runs, CPUs[0].JitRuns);
  finally
    CPUs[0].Free;
    CPUs[1].Free;
    Buses[0].Free;
    Buses[1].Free;
  end;
end;

function SelfModifyProgram(Region: Cardinal; var Counts: TCounts): string;
begin
  // Straight code at Region (kseg0 or kseg1, unmapped) that stores into one
  // of its own later words (SW, SH or SB of a new ADDIU immediate) on every
  // pass, then runs that word: generated code must run the word as just
  // written, even within the block it is running.
  Result := '';
  var Buses: TCPUBuses;
  Buses[0] := TCPUBus.Create;
  Buses[1] := TCPUBus.Create;
  var CPUs := NewCPUs(Buses);
  try
    var Words: TArray<Cardinal> := [];
    // ADDIU r5, r5, 1: the next immediate of ADDIU r9, r0, imm.
    Words := Words + [(Cardinal(9) shl 26) or (5 shl 21) or (5 shl 16) or 1];
    for var K := 1 to Integer(Next(4)) do
      Words := Words + [(Cardinal(9) shl 26) or (10 shl 21) or (10 shl 16) or 3];
    var StoreAt := Length(Words);
    Words := Words + [0];
    for var K := 1 to Integer(Next(5)) do
      Words := Words + [(Cardinal(9) shl 26) or (10 shl 21) or (10 shl 16) or 3];
    var Target := Length(Words);
    Words := Words + [(Cardinal(9) shl 26) or (9 shl 16)];
    // ADDU r11, r11, r9 (what the word did shows).
    for var K := 0 to Integer(Next(3)) do
      Words := Words + [(11 shl 21) or (9 shl 16) or (11 shl 11) or 33];
    Words := Words + [(Cardinal(2) shl 26) or ((Region shr 2) and $3FFFFFF), 0];
    // The store: the whole word, its low half, or its low byte.
    case Next(3) of
      0:
        Words[StoreAt] := (Cardinal(43) shl 26) or (6 shl 21) or (5 shl 16) or Cardinal(Target * 4);
      1:
        Words[StoreAt] := (Cardinal(41) shl 26) or (6 shl 21) or (5 shl 16) or Cardinal(Target * 4 + 2);
    else
      Words[StoreAt] := (Cardinal(40) shl 26) or (6 shl 21) or (5 shl 16) or Cardinal(Target * 4 + 3);
    end;
    for var W := 0 to High(Words) do
      PutBoth(Buses, (Region and $1FFFFFFF) + Cardinal(W) * 4, Words[W]);
    for var C in CPUs do
    begin
      C.CP0[12] := $34000000;
      C.GPR[5] := $24090000;
      C.GPR[6] := SX(Region, 32);
      C.PC := SX(Region, 32);
    end;
    var S := 0;
    while (S < 2000) and (Result = '') do
    begin
      var N: Integer;
      Result := RunBoth(CPUs, 1 + Integer(Next(200)), UInt64(1 + Next(1500)), N);
      Inc(S, Max(1, N));
    end;
    if Result = '' then
      Result := Buses[0].Unlike(Buses[1]);
    if Result <> '' then
      Result := Format('region %x, store at word %d into word %d, step %d: %s', [Region, StoreAt, Target, S, Result]);
    Inc(Counts.Steps, S);
    Inc(Counts.Compiled, CPUs[0].JitCompiled);
    Inc(Counts.Runs, CPUs[0].JitRuns);
  finally
    CPUs[0].Free;
    CPUs[1].Free;
    Buses[0].Free;
    Buses[1].Free;
  end;
end;

function LoopInstruction: Cardinal;
const
  // SPECIAL functions that cannot trap: shifts, HI/LO, multiplies and
  // divides, the ALU without overflow.
  Functions: array[0..33] of Cardinal = (0, 2, 3, 4, 6, 7, 16, 17, 18, 19, 20, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    33, 35, 36, 37, 38, 39, 42, 43, 45, 47, 56, 58, 59);
  Functions32: array[0..2] of Cardinal = (60, 62, 63);
  // Immediates that cannot trap: ADDIU, SLTI, SLTIU, ANDI, ORI, XORI, LUI,
  // DADDIU.
  Immediates: array[0..7] of Cardinal = (9, 10, 11, 12, 13, 14, 15, 25);
  // Loads and stores (LB LH LWL LW LBU LHU LWR LWU, SB SH SWL SW SWR, LDL
  // LDR LD, SDL SDR SD) and the size each must be aligned to.
  Memory: array[0..18] of Cardinal = (32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46, 26, 27, 55, 44, 45, 63);
  Sizes: array[0..18] of Cardinal = (1, 2, 1, 4, 1, 2, 1, 4, 1, 2, 1, 4, 1, 1, 1, 8, 1, 1, 8);
begin
  // Registers 0..15 (r0 too: writing it does nothing), values near the
  // edges where shifts and signs differ; 16..19 the bases of the data.
  var D := Next(16);
  if Next(8) = 0 then
    D := 0;
  var S := Next(16);
  var T := Next(16);
  case Next(12) of
    0..4:
      Result := (S shl 21) or (T shl 16) or (D shl 11) or (Next(32) shl 6) or Functions[Next(Length(Functions))];
    5:
      Result := (S shl 21) or (T shl 16) or (D shl 11) or (Next(32) shl 6) or Functions32[Next(3)];
    6..8:
      begin
        var Imm := Next($10000);
        case Next(4) of
          0: Imm := Pick([0, 1, $7FFF, $8000, $FFFF, $FFFE, $0020, $001F]);
          1: Imm := Next(64);
        end;
        Result := (Immediates[Next(Length(Immediates))] shl 26) or (S shl 21) or (D shl 16) or Imm;
      end;
  else
    begin
      // Within 2 KB of a base, aligned to the access's size.
      var K := Next(Length(Memory));
      var Offset := (Next($1000) - $800) and not (Sizes[K] - 1);
      Result := (Memory[K] shl 26) or ((16 + Next(4)) shl 21) or (D shl 16) or (Offset and $FFFF);
    end;
  end;
end;

function LoopProgram(Steps: Integer; var Counts: TCounts): string;
begin
  // An endless loop in kseg0 or kseg1 (kernel mode) of integer instructions
  // the code writes out itself and of loads and stores through bases in
  // kseg0 and kseg1 (which the code reaches without a lookup): its block
  // made at its first run, then run as code thousands of times on new
  // values.
  Result := '';
  var Buses: TCPUBuses;
  Buses[0] := TCPUBus.Create;
  Buses[1] := TCPUBus.Create;
  var CPUs := NewCPUs(Buses);
  try
    var Region := Pick([$80020000, $A0020000, $80123000]);
    var Count := 4 + Integer(Next(60));
    for var K := 0 to Count - 1 do
      PutBoth(Buses, (Region and $1FFFFFFF) + Cardinal(K) * 4, LoopInstruction);
    PutBoth(Buses, (Region and $1FFFFFFF) + Cardinal(Count) * 4, (Cardinal(2) shl 26) or ((Region shr 2) and $3FFFFFF));
    PutBoth(Buses, (Region and $1FFFFFFF) + Cardinal(Count + 1) * 4, LoopInstruction);
    for var I := 0 to $3FFF do
      PutBoth(Buses, $40000 + Cardinal(I) * 4, Rand32);
    var GPR: array[1..19] of UInt64;
    for var R := 1 to 15 do
      case Next(4) of
        0: GPR[R] := SX(Pick([0, 1, $7FFFFFFF, $80000000, $FFFFFFFF, $FFFF8000, $00008000, 31, 32, 63]), 32);
        1: GPR[R] := SX(Rand32, 32);
      else
        GPR[R] := (UInt64(Rand32) shl 32) or Rand32;
      end;
    GPR[16] := SX($80042000, 32);
    GPR[17] := SX($A0046000, 32);
    GPR[18] := SX($8004A000 + Next(8) * 4, 32);
    GPR[19] := SX($A004E000 + Next(8) * 8, 32);
    var HI := (UInt64(Rand32) shl 32) or Rand32;
    var LO := (UInt64(Rand32) shl 32) or Rand32;
    var Status := Pick([$34000000, $30000000, $340000E0]);
    for var C in CPUs do
    begin
      C.CP0[12] := Status;
      for var R := 1 to 19 do
        C.GPR[R] := GPR[R];
      C.HI := HI;
      C.LO := LO;
      C.PC := SX(Region, 32);
    end;
    var S := 0;
    var Batch := 0;
    while (S < Steps) and (Result = '') do
    begin
      var N: Integer;
      Result := RunBoth(CPUs, 1 + Integer(Next(600)), UInt64(1 + Next(4000)), N);
      Inc(S, Max(1, N));
      Inc(Batch);
      if (Result = '') and ((Batch and 15) = 0) then
        Result := Buses[0].Unlike(Buses[1]);
    end;
    if Result = '' then
      Result := Buses[0].Unlike(Buses[1]);
    if Result <> '' then
      Result := Format('loop of %d at %x, step %d: %s', [Count, Region, S, Result]);
    Inc(Counts.Steps, S);
    Inc(Counts.Compiled, CPUs[0].JitCompiled);
    Inc(Counts.Runs, CPUs[0].JitRuns);
  finally
    CPUs[0].Free;
    CPUs[1].Free;
    Buses[0].Free;
    Buses[1].Free;
  end;
end;

{ The RSP }

type
  TRSPBus = class(TN64Bus)
  public
    Regs: array[0..15] of Cardinal;
    // The status the RSP runs with: an MTC0 of SP_STATUS sets or clears its
    // halt and single-step bits there, as the console's does.
    Status: PCardinal;
    constructor Create;
    function Read8(Address: Cardinal): Byte; override;
    procedure Write8(Address: Cardinal; Value: Byte); override;
    function Read32(Address: Cardinal): Cardinal; override;
    procedure Write32(Address, Value: Cardinal); override;
    function Unlike(Other: TRSPBus): string;
  end;

  TRSPs = array[0..1] of TN64RSP;
  TRSPBuses = array[0..1] of TRSPBus;

constructor TRSPBus.Create;
begin
  inherited Create;
  FDirectMemory := True;
end;

function TRSPBus.Read8(Address: Cardinal): Byte;
begin
  if (Address >= $04000000) and (Address < $04002000) then
    Result := FSP[Address - $04000000]
  else
    Result := Byte(Read32(Address and not Cardinal(3)) shr ((3 - (Address and 3)) * 8));
end;

procedure TRSPBus.Write8(Address: Cardinal; Value: Byte);
begin
  if (Address >= $04000000) and (Address < $04002000) then
    WriteSP8(Address - $04000000, Value);
end;

function TRSPBus.Read32(Address: Cardinal): Cardinal;
begin
  if (Address >= $04000000) and (Address <= $04001FFC) then
    Exit(ReadSP32(Address - $04000000));
  var I := -1;
  if (Address >= $04040000) and (Address < $04040020) then
    I := (Address - $04040000) div 4
  else if (Address >= $04100000) and (Address < $04100020) then
    I := 8 + Integer((Address - $04100000) div 4);
  Result := 0;
  if I >= 0 then
  begin
    Result := Regs[I];
    // The semaphore reads as set from then on.
    if I = 7 then
      Regs[7] := 1;
  end;
end;

procedure TRSPBus.Write32(Address, Value: Cardinal);
begin
  if (Address >= $04000000) and (Address <= $04001FFC) then
  begin
    for var K := 0 to 3 do
      WriteSP8(Address - $04000000 + Cardinal(K), Byte(Value shr ((3 - K) * 8)));
    Exit;
  end;
  if (Address >= $04040000) and (Address < $04040020) then
  begin
    Regs[(Address - $04040000) div 4] := Value;
    if (Address = $04040010) and (Status <> nil) then
    begin
      if (Value and 1) <> 0 then
        Status^ := Status^ and not Cardinal(1);
      if (Value and 2) <> 0 then
        Status^ := Status^ or 1;
      if (Value and $20) <> 0 then
        Status^ := Status^ and not Cardinal($20);
      if (Value and $40) <> 0 then
        Status^ := Status^ or $20;
    end;
  end
  else if (Address >= $04100000) and (Address < $04100020) then
    Regs[8 + (Address - $04100000) div 4] := Value;
end;

function TRSPBus.Unlike(Other: TRSPBus): string;
begin
  Result := '';
  for var I := 0 to High(FSP) do
    if FSP[I] <> Other.FSP[I] then
      Exit(Format('SP memory %4.4x: %2.2x against %2.2x', [I, FSP[I], Other.FSP[I]]));
  for var I := 0 to High(Regs) do
    if Regs[I] <> Other.Regs[I] then
      Exit(Format('SP/DP register %d: %8.8x against %8.8x', [I, Regs[I], Other.Regs[I]]));
end;

function Reg: Cardinal;
begin
  // Mostly a few registers, so results feed later instructions (hazards).
  if Next(4) <> 0 then
    Result := 1 + Next(6)
  else
    Result := Next(32);
end;

function VReg: Cardinal;
begin
  if Next(4) <> 0 then
    Result := Next(6)
  else
    Result := Next(32);
end;

function RSPInstruction(Rare: Boolean): Cardinal;
const
  Special: array[0..19] of Cardinal = (0, 2, 3, 4, 6, 7, 8, 9, 32, 33, 34, 35, 36, 37, 38, 39, 42, 43, 13, 5);
begin
  case Next(20) of
    0..2:
      begin
        // SPECIAL, BREAK now and then where Rare.
        var F := Special[Next(18)];
        if Rare and (Next(8) = 0) then
          F := 13
        else if Rare and (Next(2000) = 0) then
          F := 5;
        Result := (Reg shl 21) or (Reg shl 16) or (Reg shl 11) or (Next(32) shl 6) or F;
      end;
    3:
      Result := (1 shl 26) or (Reg shl 21) or (Cardinal(Pick([0, 1, 16, 17])) shl 16) or ((Next(32) + $FFF0) and $FFFF);
    4:
      Result := (Cardinal(2 + Next(2)) shl 26) or Next($400);
    5:
      Result := (Cardinal(4 + Next(4)) shl 26) or (Reg shl 21) or (Reg shl 16) or ((Next(32) + $FFF0) and $FFFF);
    6..8:
      Result := (Cardinal(8 + Next(8)) shl 26) or (Reg shl 21) or (Reg shl 16) or Next($10000);
    9:
      // MFC0/MTC0 of the SP and DP registers.
      Result := (16 shl 26) or (Cardinal(Pick([0, 4])) shl 21) or (Reg shl 16) or (Next(16) shl 11);
    10..13:
      // Vector computational, any function.
      Result := (18 shl 26) or ((16 + Next(16)) shl 21) or (VReg shl 16) or (VReg shl 11) or (VReg shl 6) or Next(64);
    14:
      begin
        // MFC2/CFC2/MTC2/CTC2 (a read often into r0: it stays 0).
        var Move := Cardinal(Pick([0, 2, 4, 6]));
        var RT := Reg;
        if (Move < 4) and (Next(2) = 0) then
          RT := 0;
        Result := (18 shl 26) or (Move shl 21) or (RT shl 16) or (VReg shl 11) or (Next(16) shl 7);
      end;
    15, 16:
      Result := (Cardinal(Pick([32, 33, 35, 36, 37, 40, 41, 43])) shl 26) or (Reg shl 21) or (Reg shl 16) or Next($1000);
  else
    // LWC2/SWC2, all implemented kinds.
    Result := (Cardinal(Pick([50, 58])) shl 26) or (Reg shl 21) or (VReg shl 16) or (Next(12) shl 11) or
      (Next(16) shl 7) or Next(128);
  end;
  // Now and then something unimplemented (the RSP raises).
  if Rare and (Next(20000) = 0) then
    Result := (Cardinal(Pick([17, 19, 20, 44])) shl 26) or Next($4000000);
end;

procedure PutSP(const Buses: TRSPBuses; Offset: Cardinal; Value: Byte);
begin
  Buses[0].WriteSP8(Offset, Value);
  Buses[1].WriteSP8(Offset, Value);
end;

procedure PutIMem(const Buses: TRSPBuses; Offset, Op: Cardinal);
begin
  for var K := 0 to 3 do
    PutSP(Buses, $1000 or ((Offset + Cardinal(K)) and $FFF), Byte(Op shr ((3 - K) * 8)));
end;

function RSPProgram(Clocks: Integer; var Counts: TCounts): string;
const
  StopNames: array[TRSPAheadStop] of string = ('budget', 'COP0 write', 'COP0 read', 'break', 'halt', 'fence');
var
  PCs, Statuses, Irqs: array[0..1] of Cardinal;
  Errors: array[0..1] of string;
begin
  Result := '';
  var Buses: TRSPBuses;
  var RSPs: TRSPs;
  Buses[0] := TRSPBus.Create;
  Buses[1] := TRSPBus.Create;
  // 0 with generated code, 1 interpreting.
  RSPs[0] := TN64RSP.Create(Buses[0]);
  RSPs[1] := TN64RSP.Create(Buses[1]);
  RSPs[0].UseJit := True;
  RSPs[1].UseBlocks := False;
  RSPs[1].UseJit := False;
  try
    for var I := 0 to $FFF do
      PutSP(Buses, I, Byte(Next(256)));
    var Rare := Next(2) = 0;
    for var I := 0 to 1023 do
      PutIMem(Buses, Cardinal(I) * 4, RSPInstruction(Rare));
    for var I := 0 to High(Buses[0].Regs) do
    begin
      Buses[0].Regs[I] := Rand32;
      Buses[1].Regs[I] := Buses[0].Regs[I];
    end;
    PCs[0] := Next($400) * 4;
    Statuses[0] := 0;
    if Next(4) = 0 then
    begin
      // Interrupt on break, now and then single-stepping.
      Statuses[0] := $40;
      if Next(8) = 0 then
        Statuses[0] := Statuses[0] or $20;
    end;
    Irqs[0] := 0;
    PCs[1] := PCs[0];
    Statuses[1] := Statuses[0];
    Irqs[1] := 0;
    Buses[0].Status := @Statuses[0];
    Buses[1].Status := @Statuses[1];
    var Done := 0;
    var Ran: Integer;
    var What := '';
    while (Done < Clocks) and (Result = '') do
    begin
      Errors[0] := '';
      Errors[1] := '';
      if ((Statuses[0] and $21) = 0) and (Next(3) = 0) then
      begin
        // A run-ahead window (no MFC0 or MTC0 in it), its fences the same for
        // both: with generated code in parts as the console runs one (each of
        // Least clocks at least, to a block's end), interpreted at once to
        // where the parts ended (all of the budget where a stop ended them:
        // the same stop at the same clock); then the same clocks kept.
        Inc(Counts.Windows);
        var Budget := 1 + Integer(Next(300));
        if Next(3) = 0 then
          for var K := 0 to Integer(Next(3)) do
          begin
            var Offset := Next($1000);
            var Count := 1 + Next(64);
            var Reads := Next(2) = 0;
            RSPs[0].AddFence(Offset, Count, Reads);
            RSPs[1].AddFence(Offset, Count, Reads);
          end;
        var Part := 0;
        if Next(2) = 0 then
          Part := 1 + Integer(Next(Budget));
        Ran := RSPs[0].RunAhead(PCs[0], Statuses[0], Budget, Part);
        var Parts := 1;
        while (Part > 0) and (Ran >= Part) and (Ran < Budget) and (RSPs[0].AheadStop = TRSPAheadStop.Budget) do
        begin
          Part := 1 + Integer(Next(Budget - Ran));
          Inc(Ran, RSPs[0].ContinueAhead(PCs[0], Statuses[0], Budget - Ran, Part));
          Inc(Parts);
        end;
        var Stop := RSPs[0].AheadStop;
        var Want := Ran;
        if Stop <> TRSPAheadStop.Budget then
          Want := Budget;
        var RanInterpreted := RSPs[1].RunAhead(PCs[1], Statuses[1], Want);
        What := Format('window of %d in %d parts', [Budget, Parts]);
        if (RanInterpreted <> Ran) or (RSPs[1].AheadStop <> Stop) or (PCs[0] <> PCs[1]) then
        begin
          Result := Format('%s: %d clocks (%s), PC %3.3x against %d (%s), %3.3x', [What, Ran, StopNames[Stop], PCs[0],
            RanInterpreted, StopNames[RSPs[1].AheadStop], PCs[1]]);
          Break;
        end;
        var Keep := Ran;
        if (Ran > 0) and (Next(2) = 0) then
        begin
          Keep := Integer(Next(Cardinal(Ran) + 1));
          RSPs[0].Rewind(PCs[0], Keep);
          RSPs[1].Rewind(PCs[1], Keep);
          Inc(Counts.Rewinds);
          What := What + Format(', %d kept', [Keep]);
        end
        else
        begin
          RSPs[0].EndAhead;
          RSPs[1].EndAhead;
        end;
        Ran := Keep;
      end
      else
      begin
        // A budget (the generated code only for blocks whose clocks it all
        // takes).
        var Budget := 1 + Integer(Next(400));
        var Clocks2: array[0..1] of Integer;
        for var K := 0 to 1 do
        begin
          Clocks2[K] := 0;
          try
            Clocks2[K] := RSPs[K].ExecuteCycles(PCs[K], Statuses[K], Irqs[K], Budget);
          except
            on E: Exception do
              Errors[K] := E.ClassName + ': ' + E.Message;
          end;
        end;
        What := Format('budget of %d', [Budget]);
        if Errors[0] <> Errors[1] then
        begin
          Result := Format('%s: exception "%s" against "%s"', [What, Errors[0], Errors[1]]);
          Break;
        end;
        if Clocks2[0] <> Clocks2[1] then
        begin
          Result := Format('%s: %d clocks against %d', [What, Clocks2[0], Clocks2[1]]);
          Break;
        end;
        Ran := Clocks2[1];
      end;
      if (PCs[0] <> PCs[1]) or (Statuses[0] <> Statuses[1]) or (Irqs[0] <> Irqs[1]) then
        Result := Format('%s: PC/status/interrupt %3.3x/%x/%x against %3.3x/%x/%x', [What, PCs[0], Statuses[0], Irqs[0],
          PCs[1], Statuses[1], Irqs[1]])
      else
      begin
        var At := SnapshotDifference(RSPs[0], RSPs[1]);
        if At >= 0 then
          Result := Format('%s: snapshot differs at byte %d', [What, At])
        else
          Result := Buses[0].Unlike(Buses[1]);
        if (Result <> '') and (At < 0) then
          Result := What + ': ' + Result;
      end;
      if Result <> '' then
        Break;
      if Errors[1] <> '' then
      begin
        // Both raised: the program ends there.
        Inc(Counts.Raised);
        Break;
      end;
      Inc(Done, Max(1, Ran));
      // Halted (BREAK, single step): on again, now and then elsewhere.
      if (Statuses[1] and 1) <> 0 then
      begin
        Statuses[0] := Statuses[0] and not Cardinal(3);
        Statuses[1] := Statuses[0];
        if Next(2) = 0 then
        begin
          PCs[0] := Next($400) * 4;
          PCs[1] := PCs[0];
          RSPs[0].ResetPipeline;
          RSPs[1].ResetPipeline;
        end;
      end;
      // Outside writes: DMA into DMEM or IMEM, the CPU changing code or the
      // registers.
      if Next(16) = 0 then
      begin
        var Offset := Next($2000);
        var Count := 1 + Next(64);
        if Offset >= $1000 then
          for var I := 0 to Integer(Count div 4) do
            PutIMem(Buses, (Offset and not Cardinal(3)) + Cardinal(I) * 4, RSPInstruction(Rare))
        else
          for var I := 0 to Integer(Count) - 1 do
            PutSP(Buses, (Offset + Cardinal(I)) and $FFF, Byte(Next(256)));
      end;
      if Next(32) = 0 then
      begin
        var I := Next(16);
        Buses[0].Regs[I] := Rand32;
        Buses[1].Regs[I] := Buses[0].Regs[I];
      end;
    end;
    if Result <> '' then
      Result := Format('clock %d, %s', [Done, Result]);
    Inc(Counts.Steps, Done);
    Inc(Counts.Compiled, RSPs[0].JitCompiled);
    Inc(Counts.Runs, RSPs[0].JitRuns);
  finally
    RSPs[0].Free;
    RSPs[1].Free;
    Buses[0].Free;
    Buses[1].Free;
  end;
end;

function RunN64JitTest(Programs: Integer; Report: TStrings): Boolean;
const
  CPUSteps = 20000;
  RSPClocks = 20000;
  Generators: array[Boolean] of string = ('backend', 'model');
begin
  Result := True;
  if not TN64CPU.JitAvailable and not TN64RSP.JitAvailable then
  begin
    Report.Add('no generated code on this target: nothing to test');
    Report.Add('OK');
    Exit;
  end;
  try
    for var Model := False to True do
    begin
      // Code for every block at its first run.
      TN64CPU.JitForTests(0, Model);
      TN64RSP.JitForTests(0, Model);
      if TN64CPU.JitAvailable then
      begin
        Rng := 13579;
        var Counts := Default(TCounts);
        for var P := 0 to Programs - 1 do
          try
            Counts.Add(CPUProgram(P, CPUSteps, Counts));
          except
            on E: Exception do
              Counts.Add(E.ClassName + ': ' + E.Message);
          end;
        var Plain := Counts.Programs;
        for var P := 0 to Programs div 2 do
          try
            Counts.Add(SelfModifyProgram(Pick([$80010000, $A0010000, $80123400, $A0345600]), Counts));
          except
            on E: Exception do
              Counts.Add(E.ClassName + ': ' + E.Message);
          end;
        var Rewriting := Counts.Programs - Plain;
        for var P := 0 to Programs * 4 - 1 do
          try
            Counts.Add(LoopProgram(CPUSteps div 4, Counts));
          except
            on E: Exception do
              Counts.Add(E.ClassName + ': ' + E.Message);
          end;
        Report.Add(Format('CPU, %s: %d programs, %d rewriting their code, %d loops, %d instructions: %d failures; ' +
          '%d blocks compiled, %d runs of their code', [Generators[Model], Plain, Rewriting, Counts.Programs - Plain -
          Rewriting, Counts.Steps, Counts.Failures, Counts.Compiled, Counts.Runs]));
        if Counts.First <> '' then
          Report.Add('  first: ' + Counts.First);
        if Counts.Runs = 0 then
          Report.Add('  no generated code ran');
        Result := Result and (Counts.Failures = 0) and (Counts.Runs > 0);
      end;
      if TN64RSP.JitAvailable then
      begin
        Rng := 24680;
        var Counts := Default(TCounts);
        for var P := 0 to Programs - 1 do
          try
            Counts.Add(RSPProgram(RSPClocks, Counts));
          except
            on E: Exception do
              Counts.Add(E.ClassName + ': ' + E.Message);
          end;
        Report.Add(Format('RSP, %s: %d programs, %d clocks (%d windows, %d rewound; %d stopped by an exception in ' +
          'both): %d failures; %d blocks compiled, %d runs of their code', [Generators[Model], Counts.Programs,
          Counts.Steps, Counts.Windows, Counts.Rewinds, Counts.Raised, Counts.Failures, Counts.Compiled, Counts.Runs]));
        if Counts.First <> '' then
          Report.Add('  first: ' + Counts.First);
        if Counts.Runs = 0 then
          Report.Add('  no generated code ran');
        Result := Result and (Counts.Failures = 0) and (Counts.Runs > 0);
      end;
    end;
  finally
    TN64CPU.JitForTests(16, False);
    TN64RSP.JitForTests(16, False);
  end;
  if Result then
    Report.Add('OK')
  else
    Report.Add('FAILED');
end;

end.
