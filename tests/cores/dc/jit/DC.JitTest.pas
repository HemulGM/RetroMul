unit DC.JitTest;

// The SH-4's generated code against its interpreter. Random programs run on
// two CPUs over two identical machines (RAM, and devices that only note what
// they are given): one runs its blocks as generated code, made at a block's
// first run (HW.JIT's backend on this target, then its model); the other
// interprets them. Both run to the same deadlines, get the same interrupts
// and the same writes into their code from outside: the states, the clocks,
// the RAM, its write generations and the device accesses must match after
// each run.
//
// Programs of every kind of instruction (integer, memory, branches and delay
// slots, the FPU in both transfer sizes, system ones), through RAM directly
// or through the MMU (random UTLB entries, LDTLB), storing into their own
// code; wait loops counting a word down (wait-loop skipping).

interface

uses
  System.Classes;

// Programs random programs for each code generator; Report gets a line for
// each and the result. True: no difference (and generated code ran), or no
// generated code on this target.
function RunDCJitTest(Programs: Integer; Report: TStrings): Boolean;

implementation

{$Q-}{$R-}

uses
  System.SysUtils, System.Math, Core.Snapshots, HW.SH4, HW.JIT;

const
  RAMBase = $0C000000;
  RAMSize = $40000;
  // (P1 addresses of RAM: the vectors, the code, the data.)
  VectorBase = $8C000000;
  CodeBase = $8C010000;
  CodeWords = $4000;
  DataBase = $8C020000;
  // Through the MMU: the code and the data in P0.
  MappedCode = $00010000;
  MappedData = $00020000;
  Rounds = 200;

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

type
  TMachine = class
  public
    RAM: TBytes;
    Gens: array[0..RAMSize div $10000 - 1, 0..15] of Cardinal;
    ReadPages, WritePages: TSH4PhysicalPages;
    GenPages: TSH4PhysicalGens;
    // A checksum of the device accesses.
    Log: UInt64;
    Now, Deadline: Int64;
    CPU: TSH4;
    constructor Create(Recompiler: Boolean);
    destructor Destroy; override;
    procedure Load(const Image: TBytes; const State: TSH4State);
    procedure WriteCode(Offset: Integer; Value: Word);
    function Unlike(Other: TMachine): string;
  end;

procedure Note(M: TMachine; V: UInt64);
const
  Prime: UInt64 = 1099511628211;
begin
  M.Log := (M.Log xor V) * Prime + UInt64(7);
end;

function BusRead(User: Pointer; Address: Cardinal; Size: Integer): UInt64;
const
  Golden: UInt64 = UInt64($9E3779B97F4A7C15);
begin
  // A device: a value from its address.
  Note(TMachine(User), (UInt64(Address) shl 8) or Cardinal(Size));
  var Mixed: UInt64 := UInt64(Address) * Golden;
  Result := Mixed shr Cardinal(64 - Size * 8);
end;

procedure BusWrite(User: Pointer; Address: Cardinal; Value: UInt64; Size: Integer);
begin
  Note(TMachine(User), (UInt64(Address) shl 8) or Cardinal(Size) or $80);
  Note(TMachine(User), Value);
end;

procedure BusBurst(User: Pointer; Address: Cardinal; Data: PCardinal; Count: Integer);
begin
  Note(TMachine(User), (UInt64(Address) shl 8) or Cardinal(Count) or $40);
  for var K := 0 to Count - 1 do
  begin
    Note(TMachine(User), Data^);
    Inc(Data);
  end;
end;

constructor TMachine.Create(Recompiler: Boolean);
begin
  inherited Create;
  SetLength(RAM, RAMSize);
  for var P := 0 to RAMSize div $10000 - 1 do
  begin
    ReadPages[(RAMBase shr 16) + P] := @RAM[P * $10000];
    WritePages[(RAMBase shr 16) + P] := @RAM[P * $10000];
    GenPages[(RAMBase shr 16) + P] := @Gens[P, 0];
  end;
  var Bus := Default(TSH4Bus);
  Bus.User := Self;
  Bus.Read := BusRead;
  Bus.Write := BusWrite;
  Bus.Burst := BusBurst;
  Bus.ReadPages := @ReadPages;
  Bus.WritePages := @WritePages;
  Bus.Gens := @GenPages;
  CPU := TSH4.Create(Bus, @Now, @Deadline);
  CPU.Recompiler := Recompiler;
end;

destructor TMachine.Destroy;
begin
  CPU.Free;
  inherited;
end;

procedure TMachine.Load(const Image: TBytes; const State: TSH4State);
begin
  // The RAM, then the state as a snapshot loads it (maps, blocks, the UTLB).
  Move(Image[0], RAM[0], RAMSize);
  FillChar(Gens, SizeOf(Gens), 0);
  Log := 0;
  Now := 0;
  Deadline := 0;
  CPU.S := State;
  var Stream := TMemoryStream.Create;
  try
    var Archive := TStateArchive.Create(Stream, False);
    try
      CPU.SerializeState(Archive);
    finally
      Archive.Free;
    end;
    Stream.Position := 0;
    Archive := TStateArchive.Create(Stream, True);
    try
      CPU.SerializeState(Archive);
    finally
      Archive.Free;
    end;
  finally
    Stream.Free;
  end;
end;

procedure TMachine.WriteCode(Offset: Integer; Value: Word);
begin
  // As a DMA transfer into RAM: the word and its page's write generation.
  PWord(@RAM[Offset])^ := Value;
  Inc(Gens[Offset shr 16, (Offset shr 12) and 15]);
end;

function FirstDifference(A, B: PByte; Size: Integer): Integer;
begin
  for var K := 0 to Size - 1 do
    if A[K] <> B[K] then
      Exit(K);
  Result := -1;
end;

function TMachine.Unlike(Other: TMachine): string;
begin
  Result := '';
  var At := FirstDifference(@CPU.S, @Other.CPU.S, SizeOf(TSH4State));
  if At >= 0 then
    Exit(Format('the state from byte %d (PC %.8x against %.8x)', [At, CPU.S.PC, Other.CPU.S.PC]));
  if Now <> Other.Now then
    Exit(Format('the clock (%d against %d)', [Now, Other.Now]));
  if CPU.InstructionsExecuted <> Other.CPU.InstructionsExecuted then
    Exit('the instructions counted');
  if CPU.IdleCyclesSkipped <> Other.CPU.IdleCyclesSkipped then
    Exit('the wait-loop clocks skipped');
  if CPU.ExceptionCount <> Other.CPU.ExceptionCount then
    Exit('the exceptions taken');
  At := FirstDifference(@RAM[0], @Other.RAM[0], RAMSize);
  if At >= 0 then
    Exit(Format('RAM at %.8x', [RAMBase + Cardinal(At)]));
  if not CompareMem(@Gens, @Other.Gens, SizeOf(Gens)) then
    Exit('RAM''s write generations');
  if Log <> Other.Log then
    Exit('the device accesses');
end;

{ Programs }

const
  // Instruction forms: 0 and 1 fixed, any other letter random. Repeated
  // forms are the more frequent.
  Forms: TArray<string> = [
    // Integer.
    '0110nnnnmmmm0011', '0110nnnnmmmm0011', '0110nnnnmmmm0011', '1110nnnniiiiiiii', '1110nnnniiiiiiii',
    '0111nnnniiiiiiii', '0111nnnniiiiiiii', '0011nnnnmmmm1100', '0011nnnnmmmm1100', '0011nnnnmmmm1000',
    '0010nnnnmmmm1001', '0010nnnnmmmm1011', '0010nnnnmmmm1010', '0010nnnnmmmm1000', '0010nnnnmmmm1000',
    '0011nnnnmmmm0000', '0011nnnnmmmm0010', '0011nnnnmmmm0011', '0011nnnnmmmm0110', '0011nnnnmmmm0111',
    '0110nnnnmmmm0111', '0110nnnnmmmm1011', '0110nnnnmmmm1100', '0110nnnnmmmm1101', '0110nnnnmmmm1110',
    '0110nnnnmmmm1111', '0110nnnnmmmm1001', '0110nnnnmmmm1000', '0010nnnnmmmm1101', '0011nnnnmmmm1110',
    '0011nnnnmmmm1010', '0011nnnnmmmm1111', '0011nnnnmmmm1011', '0000nnnnmmmm0111', '0011nnnnmmmm1101',
    '0011nnnnmmmm0101', '0011nnnnmmmm0100', '0011nnnnmmmm0100', '0010nnnnmmmm0111', '0000000000011001',
    '0100nnnnmmmm1100', '0100nnnnmmmm1101', '0010nnnnmmmm1111', '0010nnnnmmmm1110', '0010nnnnmmmm1100',
    '0100nnnn00000000', '0100nnnn00000001', '0100nnnn00100000', '0100nnnn00100001', '0100nnnn00000100',
    '0100nnnn00000101', '0100nnnn00100100', '0100nnnn00100100', '0100nnnn00100101', '0100nnnn00001000',
    '0100nnnn00001001', '0100nnnn00011000', '0100nnnn00011001', '0100nnnn00101000', '0100nnnn00101001',
    '0100nnnn00010000', '0100nnnn00010000', '0100nnnn00010001', '0100nnnn00010101', '0000nnnn00101001',
    '10001000iiiiiiii', '11001000iiiiiiii', '11001001iiiiiiii', '11001011iiiiiiii', '11001010iiiiiiii',
    '11000111iiiiiiii', '0000000000001000', '0000000000011000', '0000000000001001', '0000000000101000',
    '0000000001001000', '0000000001011000',
    // System registers.
    '0000nnnn00011010', '0000nnnn00001010', '0000nnnn00101010', '0100nnnn00101010', '0100nnnn00011010',
    '0100nnnn00001010', '0000nnnn00010010', '0100nnnn00011110', '0000nnnn01011010', '0100nnnn01011010',
    '0000nnnn00000010', '0000nnnn01101010', '0000nnnn01000010', '0000nnnn00110010', '0000nnnn1mmm0010',
    '0100nnnn00100010', '0100nnnn00100110', '0100nnnn00010010', '0100nnnn00010110', '0100nnnn00000010',
    '0100nnnn00000110', '0100nnnn00010011', '0100nnnn00010111', '0100nnnn01010010', '0100nnnn01010110',
    '0100nnnn00000011',
    // Branches.
    '10001001dddddddd', '10001001dddddddd', '10001011dddddddd', '10001011dddddddd', '10001101dddddddd',
    '10001111dddddddd', '1010dddddddddddd', '1010dddddddddddd', '1011dddddddddddd', '0000000000001011',
    '0000000000001011', '0000nnnn00100011', '0000nnnn00000011', '0100nnnn00101011', '0100nnnn00001011',
    // Memory.
    '0010nnnnmmmm0000', '0010nnnnmmmm0001', '0010nnnnmmmm0010', '0010nnnnmmmm0010', '0010nnnnmmmm0010',
    '0110nnnnmmmm0000', '0110nnnnmmmm0001', '0110nnnnmmmm0010', '0110nnnnmmmm0010', '0110nnnnmmmm0010',
    '0010nnnnmmmm0100', '0010nnnnmmmm0101', '0010nnnnmmmm0110', '0010nnnnmmmm0110', '0110nnnnmmmm0100',
    '0110nnnnmmmm0101', '0110nnnnmmmm0110', '0110nnnnmmmm0110', '0000nnnnmmmm0100', '0000nnnnmmmm0101',
    '0000nnnnmmmm0110', '0000nnnnmmmm1100', '0000nnnnmmmm1101', '0000nnnnmmmm1110', '0001nnnnmmmmdddd',
    '0001nnnnmmmmdddd', '0101nnnnmmmmdddd', '0101nnnnmmmmdddd', '0101nnnnmmmmdddd', '10000000nnnndddd',
    '10000001nnnndddd', '10000100mmmmdddd', '10000101mmmmdddd', '11000000dddddddd', '11000001dddddddd',
    '11000010dddddddd', '11000100dddddddd', '11000101dddddddd', '11000110dddddddd', '1101nnnndddddddd',
    '1101nnnndddddddd', '1001nnnndddddddd', '0100nnnn00011011', '11001101iiiiiiii', '11001111iiiiiiii',
    '11001110iiiiiiii', '11001100iiiiiiii', '0000nnnnmmmm1111', '0100nnnnmmmm1111', '0000nnnn10000011',
    '0000nnnn10010011', '0000nnnn11000011',
    // FPU.
    '1111nnnnmmmm1100', '1111nnnnmmmm1100', '1111nnnnmmmm1000', '1111nnnnmmmm1000', '1111nnnnmmmm1010',
    '1111nnnnmmmm1010', '1111nnnnmmmm1001', '1111nnnnmmmm1011', '1111nnnnmmmm0110', '1111nnnnmmmm0111',
    '1111nnnn10001101', '1111nnnn10011101', '1111mmmm00011101', '1111nnnn00001101', '1111nnnnmmmm0000',
    '1111nnnnmmmm0001', '1111nnnnmmmm0010', '1111nnnnmmmm0011', '1111nnnnmmmm0100', '1111nnnnmmmm0101',
    '1111nnnn01001101', '1111nnnn01011101', '1111nnnn01101101', '1111nnnn00101101', '1111mmmm00111101',
    '1111nnnnmmmm1110', '1111001111111101', '1111001111111101', '1111101111111101', '1111nnmm11101101',
    '1111nn0111111101', '1111nnn011111101', '1111nnnn01111101', '1111mmm010111101', '1111nnn010101101'];
  // One in a hundred: the status register, FPSCR, return from exception,
  // sleep, traps, the TLB, an undefined code.
  RareForms: TArray<string> = ['0100nnnn00001110', '0100nnnn01101010', '0100nnnn00000111', '0000000000101011',
    '0000000000011011', '11000011iiiiiiii', '0000000000111000', '1111111111111111'];

function Instruction: Word;
begin
  var Form := Forms[Next(Length(Forms))];
  if Next(100) = 0 then
    Form := RareForms[Next(Length(RareForms))];
  Result := 0;
  for var K := 1 to 16 do
  begin
    Result := Result shl 1;
    case Form[K] of
      '0': ;
      '1': Result := Result or 1;
    else
      Result := Result or Word(Next(2));
    end;
  end;
end;

procedure PutWord(var Image: TBytes; Address: Cardinal; Value: Word);
begin
  PWord(@Image[Address and (RAMSize - 1)])^ := Value;
end;

procedure MakeProgram(var Image: TBytes; out State: TSH4State; Mapped: Boolean);
const
  // Exceptions: past the instruction (STC SPC,R0; ADD #2,R0; LDC R0,SPC; RTE;
  // NOP: bank 1's R0). Interrupts: RTE; NOP.
  Skip: array[0..4] of Word = ($0042, $7002, $404E, $002B, $0009);
  Return: array[0..1] of Word = ($002B, $0009);
  // A wait loop on the word at R14: MOV.L @R14,R1; ADD #-1,R1; MOV.L R1,@R14;
  // TST R1,R1; BF back.
  Wait: array[0..4] of Word = ($61E2, $71FF, $2E12, $2118, $8BFB);
begin
  SetLength(Image, RAMSize);
  for var K := 0 to RAMSize div 4 - 1 do
    PCardinal(@Image[K * 4])^ := Rand32;
  for var K := 0 to High(Skip) do
  begin
    PutWord(Image, VectorBase + $100 + Cardinal(K) * 2, Skip[K]);
    PutWord(Image, VectorBase + $400 + Cardinal(K) * 2, Skip[K]);
  end;
  for var K := 0 to High(Return) do
    PutWord(Image, VectorBase + $600 + Cardinal(K) * 2, Return[K]);
  var K := 0;
  while K < CodeWords do
  begin
    if (Next(150) = 0) and (K + Length(Wait) < CodeWords) then
    begin
      for var W := 0 to High(Wait) do
        PutWord(Image, CodeBase + Cardinal(K + W) * 2, Wait[W]);
      Inc(K, Length(Wait));
      Continue;
    end;
    var Op := Instruction;
    // (The TLB only through the MMU.)
    if (Op = $0038) and not Mapped then
      Op := $0009;
    PutWord(Image, CodeBase + Cardinal(K) * 2, Op);
    Inc(K);
  end;
  // The wait loops' word: a count to go down.
  PCardinal(@Image[(DataBase + $100) and (RAMSize - 1)])^ := 20 + Next(5000);

  State := Default(TSH4State);
  var Code: Cardinal := CodeBase;
  var Data: Cardinal := DataBase;
  if Mapped then
  begin
    Code := MappedCode;
    Data := MappedData;
  end;
  for var R := 0 to 15 do
    case Next(6) of
      0, 1: State.R[R] := Data + Next($8000) * 4;
      2: State.R[R] := Data + Next($10000);
      3: State.R[R] := Code + Next(CodeWords) * 2;
      4: State.R[R] := Next(64);
    else
      State.R[R] := Rand32;
    end;
  State.R[14] := Data + $100;
  State.R[15] := Data + $FFF0;
  for var R := 0 to 7 do
    State.RBank[R] := Rand32;
  for var R := 0 to 15 do
  begin
    State.FR.U[R] := Rand32;
    State.XF.U[R] := Rand32;
  end;
  State.PC := Code;
  State.PR := Code + Next(CodeWords) * 2;
  State.GBR := Data;
  State.VBR := VectorBase;
  State.SR := $40000000 or (Next(16) shl 4);
  State.FPSCR := $00040000 or Next(2) or (Next(2) shl 19) or (Next(2) shl 20);
  State.MACH := Rand32;
  State.MACL := Rand32;
  State.FPUL := Rand32;
  if Mapped then
  begin
    // AT; UTLB entries over P0's first MiB to RAM: the code's and the data's
    // as 64 KiB pages, the rest random (4 KiB or 1 KiB, some invalid).
    State.MMUCR := 1;
    for var E := 0 to 63 do
    begin
      var Entry := Default(TSH4TLBEntry);
      if E < 2 then
      begin
        Entry.VPN := MappedCode + Cardinal(E) * $10000;
        Entry.PPN := RAMBase + $10000 + Cardinal(E) * $10000;
        // V, SZ 64 KiB, PR read/write, D, SH.
        Entry.Flags := $100 or $80 or $60 or $04 or $02;
      end
      else
      begin
        Entry.VPN := Next($100) shl 12;
        Entry.PPN := RAMBase + Next(RAMSize shr 12) shl 12;
        // (Valid one time in two.)
        Entry.Flags := (Next(2) shl 8) or (Next(2) shl 4) or $60 or (Next(2) shl 2) or 2;
        Entry.ASID := Next(2);
      end;
      State.UTLB[E] := Entry;
    end;
  end;
end;

function RunPrograms(Programs: Integer; Model: Boolean; Report: TStrings): Boolean;
begin
  Result := True;
  TSH4.JitHot := 1;
  TSH4.JitModel := Model;
  var Plain := TMachine.Create(False);
  var Coded := TMachine.Create(True);
  try
    var Instructions: Int64 := 0;
    var Image: TBytes;
    for var P := 1 to Programs do
    begin
      var State: TSH4State;
      MakeProgram(Image, State, (P mod 3) = 0);
      Plain.Load(Image, State);
      Coded.Load(Image, State);
      for var Round := 1 to Rounds do
      begin
        // The same deadline, interrupt and outside writes into the code.
        var Budget := 1 + Next(3000);
        Plain.Deadline := Plain.Now + Budget;
        Coded.Deadline := Coded.Now + Budget;
        case Next(10) of
          0:
            begin
              var Level := 1 + Integer(Next(15));
              var Code := $200 + Next(16) * $20;
              Plain.CPU.SetInterrupt(Level, Code);
              Coded.CPU.SetInterrupt(Level, Code);
            end;
          1:
            begin
              Plain.CPU.SetInterrupt(0, 0);
              Coded.CPU.SetInterrupt(0, 0);
            end;
          2:
            begin
              var Offset := Integer((CodeBase and (RAMSize - 1)) + Next(CodeWords) * 2);
              var Value := Instruction;
              Plain.WriteCode(Offset, Value);
              Coded.WriteCode(Offset, Value);
            end;
          3, 4:
            begin
              // On elsewhere in the code (random code soon keeps to a few
              // loops).
              var Target := State.PC + Next(CodeWords) * 2;
              Plain.CPU.S.PC := Target;
              Plain.CPU.S.DelaySlot := False;
              Plain.CPU.S.Sleeping := False;
              Coded.CPU.S.PC := Target;
              Coded.CPU.S.DelaySlot := False;
              Coded.CPU.S.Sleeping := False;
            end;
        end;
        Plain.CPU.Run;
        Coded.CPU.Run;
        var Difference := Coded.Unlike(Plain);
        if Difference <> '' then
        begin
          Report.Add(Format('program %d, run %d: %s', [P, Round, Difference]));
          Exit(False);
        end;
      end;
      Inc(Instructions, Plain.CPU.InstructionsExecuted);
    end;
    var Name := 'code generator';
    if Model then
      Name := 'model';
    Report.Add(Format('%s: %d programs, %d instructions, %d blocks given code, %d runs of code: no difference',
      [Name, Programs, Instructions, Coded.CPU.JitCompiled, Coded.CPU.JitRuns]));
    if Coded.CPU.JitRuns = 0 then
    begin
      Report.Add('no generated code ran');
      Result := False;
    end;
  finally
    Coded.Free;
    Plain.Free;
    TSH4.JitHot := 0;
    TSH4.JitModel := False;
  end;
end;

function RunDCJitTest(Programs: Integer; Report: TStrings): Boolean;
begin
  Rng := 12345;
  {$IF JitSupported and Defined(CPU64BITS)}
  Result := RunPrograms(Programs, False, Report) and RunPrograms(Max(1, Programs div 4), True, Report);
  {$ELSE}
  Report.Add('no generated code on this target');
  Result := True;
  {$ENDIF}
end;

end.
