program PS2IOPCPUTest;

// Runs random IOP programs (every primary and SPECIAL opcode, reserved ones
// too, branches and jumps in delay slots, loads into the load delay slot,
// LWL/LWR merges, RAM mirrors, KSEG addresses, the scratchpad, hardware
// registers, misaligned accesses, COP0, SYSCALL, BREAK, HLE traps) through
// PS2.IOP.CPU and through a copy of it as it was (PS2IOPCPURef), with and
// without Hardware (exceptions, interrupts, BIOS fetches), in random cycle
// slices with traps that stop, jump and charge cycles: registers, PC,
// COP0, cycles, instructions, scratchpad, RAM and every device access the
// same.

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$Q-}{$R-}

uses
  System.SysUtils, System.Math, PS2.Types, PS2.IOP.CPU, PS2IOPCPURef;

const
  Region = $1000;
  RegionWords = 1024;

type
  TState = record
    R: array[0..31] of Cardinal;
    HI, LO, PC, NextPC, SR, Cause, EPC, BadVAddr: Cardinal;
    Cycles, Instructions: Int64;
    Debug: array[0..15] of Cardinal;
  end;

  // Hardware registers, traps and exceptions of one core: what they saw, in
  // order, and what they did back.
  TDevice = class
    Log: TArray<UInt64>;
    Count: Integer;
    Reads: Cardinal;
    Cpu: TIOPCPU;
    Ref: TRefIOPCPU;
    procedure Add(V: UInt64);
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure Trap(Code: Cardinal);
    procedure Exception(Code: Integer; PC: Cardinal);
    procedure Stop;
    procedure SetPC(V: Cardinal);
    procedure SetReg(N: Integer; V: Cardinal);
    procedure Charge(N: Integer);
    function Cycles: Int64;
  end;

procedure TDevice.Add(V: UInt64);
begin
  if Count >= Length(Log) then
    SetLength(Log, Count * 2 + 1024);
  Log[Count] := V;
  Inc(Count);
end;

function TDevice.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  Inc(Reads);
  Add($1000000000000000 or (UInt64(Address) shl 8) or UInt64(Size));
  Result := Cardinal(UInt64(Address) * 2654435761 + Cardinal(Size) * 40503 + Reads * 977);
end;

procedure TDevice.Write(Address, Value: Cardinal; Size: Integer);
begin
  Add($2000000000000000 or (UInt64(Address) shl 8) or UInt64(Size));
  Add(Value);
end;

procedure TDevice.Stop;
begin
  if Cpu <> nil then Cpu.Stop else Ref.Stop;
end;

procedure TDevice.SetPC(V: Cardinal);
begin
  if Cpu <> nil then Cpu.SetPC(V) else Ref.SetPC(V);
end;

procedure TDevice.SetReg(N: Integer; V: Cardinal);
begin
  if Cpu <> nil then Cpu.R[N] := V else Ref.R[N] := V;
end;

procedure TDevice.Charge(N: Integer);
begin
  if Cpu <> nil then Inc(Cpu.Cycles, N) else Inc(Ref.Cycles, N);
end;

function TDevice.Cycles: Int64;
begin
  if Cpu <> nil then Result := Cpu.Cycles else Result := Ref.Cycles;
end;

procedure TDevice.Trap(Code: Cardinal);
begin
  Add($3000000000000000 or UInt64(Code) or (UInt64(Cycles) shl 26));
  SetReg(2, Code xor Cardinal(Cycles));
  if Code mod 5 = 0 then Charge(3 + Integer(Code mod 4));
  if Code mod 7 = 0 then Stop;
  if Code mod 11 = 0 then SetPC($80000000 or Region + (Code mod RegionWords) * 4);
end;

procedure TDevice.Exception(Code: Integer; PC: Cardinal);
begin
  Add($4000000000000000 or (UInt64(Code) shl 32) or PC);
  if Code = 8 then
    SetReg(3, PC)
  else if (Code = 9) and (PC mod 3 = 0) then
    Stop;
end;

function Snap(C: TIOPCPU): TState; overload;
begin
  FillChar(Result, SizeOf(Result), 0);
  Move(C.R, Result.R, SizeOf(Result.R));
  Result.HI := C.HI; Result.LO := C.LO; Result.PC := C.PC; Result.NextPC := C.NextPC;
  Result.SR := C.SR; Result.Cause := C.Cause; Result.EPC := C.EPC; Result.BadVAddr := C.BadVAddr;
  Result.Cycles := C.Cycles; Result.Instructions := C.Instructions;
  Move(C.Debug, Result.Debug, SizeOf(Result.Debug));
end;

function Snap(C: TRefIOPCPU): TState; overload;
begin
  FillChar(Result, SizeOf(Result), 0);
  Move(C.R, Result.R, SizeOf(Result.R));
  Result.HI := C.HI; Result.LO := C.LO; Result.PC := C.PC; Result.NextPC := C.NextPC;
  Result.SR := C.SR; Result.Cause := C.Cause; Result.EPC := C.EPC; Result.BadVAddr := C.BadVAddr;
  Result.Cycles := C.Cycles; Result.Instructions := C.Instructions;
  Move(C.Debug, Result.Debug, SizeOf(Result.Debug));
end;

var
  Seed: UInt64 = $9E3779B97F4A7C15;

function Rnd: Cardinal;
begin
  Seed := Seed * 6364136223846793005 + 1442695040888963407;
  Result := Cardinal(Seed shr 32);
end;

// An address for a load or store base: RAM (mirrors, KSEG0/1), the
// scratchpad, hardware registers, unmapped space; sometimes misaligned.
function RandomBase: Cardinal;
begin
  case Rnd mod 10 of
    0..3: Result := $00002000 + (Rnd mod $1000) and not Cardinal(3);
    4: Result := $80002000 + (Rnd mod $1000);
    5: Result := $A0602000 + (Rnd mod $1000);
    6: Result := $1F800000 + (Rnd mod $400);
    7: Result := $1F801000 + (Rnd mod $2000);
    8: Result := $BFC00000 + (Rnd mod $1000);
  else
    Result := Rnd;
  end;
  if Rnd mod 6 <> 0 then
    Result := Result and not Cardinal(3);
end;

function RandomWord(K: Integer): Cardinal;
const
  Main: array[0..33] of Cardinal = ($00, $00, $00, $01, $02, $03, $04, $05, $06, $07, $08, $09, $0A, $0B, $0C, $0D,
    $0E, $0F, $10, $20, $21, $22, $23, $24, $25, $26, $28, $29, $2A, $2B, $2E, $3B, $12, $33);
begin
  var Rs := Rnd mod 32;
  var Rt := Rnd mod 32;
  var Rd := Rnd mod 32;
  var Sa := Rnd mod 32;
  // (Mostly registers 1..12, which carry addresses and small values.)
  if Rnd mod 4 <> 0 then begin Rs := 1 + Rnd mod 12; Rt := 1 + Rnd mod 12; Rd := 1 + Rnd mod 12; end;
  var Opc := Main[Rnd mod Length(Main)];
  var Imm := Rnd and $FFFF;
  case Opc of
    $00:
      begin
        var F := Rnd mod 64;
        if Rnd mod 3 = 0 then F := F and $2F;
        if (F = $0C) and (Rnd mod 4 <> 0) then F := $21;
        Exit((Rs shl 21) or (Rt shl 16) or (Rd shl 11) or (Sa shl 6) or F);
      end;
    $01: Rt := Rnd mod 32;
    $02, $03: Exit((Opc shl 26) or (((Region + Cardinal(Rnd mod RegionWords) * 4) shr 2) and $3FFFFFF));
    $04..$07: Imm := Cardinal(Integer(Rnd mod 64) - 32) and $FFFF;
    $10:
      case Rnd mod 4 of
        0: Exit(($10 shl 26) or (Rt shl 16) or ((Rnd mod 16) shl 11));            // MFC0
        1: Exit(($10 shl 26) or (4 shl 21) or (Rt shl 16) or ((Rnd mod 16) shl 11)); // MTC0
        2: Exit($42000010);                                                       // RFE
      else
        Exit(($10 shl 26) or (Rnd and $3FFFFFF));
      end;
    $20..$2E:
      Imm := Rnd mod 64 - 32;
    $3B:
      Exit(($3B shl 26) or (Rnd mod 200));
  end;
  Result := (Opc shl 26) or (Rs shl 21) or (Rt shl 16) or (Imm and $FFFF);
end;

procedure Fail(const Msg: string; Trial, Slice: Integer);
begin
  raise Exception.CreateFmt('%s (trial %d, slice %d)', [Msg, Trial, Slice]);
end;

var
  RamA, RamB, Rom: PByte;
begin
  try
    RamA := AllocMem(PS2IOPRAMSize);
    RamB := AllocMem(PS2IOPRAMSize);
    Rom := AllocMem(PS2BIOSSize);
    var A := TIOPCPU.Create(RamA);
    var B := TRefIOPCPU.Create(RamB);
    var DA := TDevice.Create;
    var DB := TDevice.Create;
    DA.Cpu := A;
    DB.Ref := B;
    A.OnRead := DA.Read; A.OnWrite := DA.Write; A.OnTrap := DA.Trap; A.OnException := DA.Exception;
    B.OnRead := DB.Read; B.OnWrite := DB.Write; B.OnTrap := DB.Trap; B.OnException := DB.Exception;
    for var K := 0 to PS2BIOSSize div 4 - 1 do
      PCardinal(Rom)[K] := RandomWord(K);
    A.ROM := Rom;
    B.ROM := Rom;
    var Total: Int64 := 0;
    var Trials := 3000;
    for var Trial := 0 to Trials - 1 do
    begin
      var Hardware := Trial mod 2 = 1;
      A.Reset; B.Reset;
      A.Hardware := Hardware; B.Hardware := Hardware;
      for var K := 0 to $3FFF do
        PCardinal(RamA)[K] := Rnd;
      for var K := 0 to RegionWords - 1 do
        PCardinal(RamA)[Region div 4 + K] := RandomWord(K);
      // (The exception vector: code that runs on, back with RFE now and then.)
      for var K := 0 to 31 do
        PCardinal(RamA)[$80 div 4 + K] := RandomWord(K);
      PCardinal(RamA)[$80 div 4 + 30] := $42000010;
      Move(RamA^, RamB^, $10000);
      for var K := 1 to 31 do
      begin
        var V := Rnd;
        case Rnd mod 3 of
          0: V := RandomBase;
          1: V := V mod 100;
        end;
        if (K = 31) or (Rnd mod 8 = 0) then V := $80000000 or Region + (Rnd mod RegionWords) * 4;
        A.R[K] := V; B.R[K] := V;
      end;
      var SR: Cardinal := 0;
      if Hardware then SR := Rnd and $00410403;
      A.SR := SR; B.SR := SR;
      FillChar(A.Scratchpad, SizeOf(A.Scratchpad), Byte(Trial));
      FillChar(B.Scratchpad, SizeOf(B.Scratchpad), Byte(Trial));
      A.SetPC($80000000 or Region); B.SetPC($80000000 or Region);
      DA.Count := 0; DB.Count := 0; DA.Reads := 0; DB.Reads := 0;
      var Target: Int64 := 0;
      for var Slice := 0 to 7 do
      begin
        Inc(Target, 1 + Rnd mod 400);
        if Hardware then
        begin
          var Line := Rnd mod 3 = 0;
          A.IntLine := Line; B.IntLine := Line;
        end;
        A.Run(Target);
        B.Run(Target);
        var SA := Snap(A);
        var SB := Snap(B);
        if not CompareMem(@SA, @SB, SizeOf(SA)) then
        begin
          for var K := 0 to 31 do
            if SA.R[K] <> SB.R[K] then Writeln(Format('r%d %.8x/%.8x', [K, SA.R[K], SB.R[K]]));
          Writeln(Format('pc %.8x/%.8x next %.8x/%.8x cycles %d/%d hw %s', [SA.PC, SB.PC, SA.NextPC, SB.NextPC,
            SA.Cycles, SB.Cycles, BoolToStr(Hardware, True)]));
          Fail('IOP core state mismatch', Trial, Slice);
        end;
        if (DA.Count <> DB.Count) or ((DA.Count > 0) and not CompareMem(@DA.Log[0], @DB.Log[0], DA.Count * 8)) then
          Fail('IOP device accesses differ', Trial, Slice);
        if not CompareMem(RamA, RamB, $10000) or not CompareMem(@A.Scratchpad, @B.Scratchpad, SizeOf(A.Scratchpad)) or
          ((Slice = 7) and not CompareMem(RamA, RamB, PS2IOPRAMSize)) then
          Fail('IOP memory differs', Trial, Slice);
        // A fetch outside memory leaves the HLE core where it stopped.
        if not Hardware and ((A.PC and $1FFFFFFF) >= $00800000) then
        begin
          A.SetPC($80000000 or Region); B.SetPC($80000000 or Region);
        end;
      end;
      Inc(Total, A.Instructions);
    end;
    if Total < 1000000 then
      raise Exception.CreateFmt('Only %d instructions ran', [Total]);
    Writeln(Format('%d random IOP programs (HLE and hardware), %d instructions, as the reference core: OK',
      [Trials, Total]));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
