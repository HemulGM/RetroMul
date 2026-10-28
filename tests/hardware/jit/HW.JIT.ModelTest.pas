unit HW.JIT.ModelTest;

// HW.JIT's backend on this target against the model (CreateJitModel): the
// same programs written by both and run (Invoke) on the same memory, filled
// the same way before each (addresses taken by the programs are the same),
// must leave the same memory and result. Programs: random ones of
// every operation over the registers and a 64 KB box (Self points to its
// start, Ctx into its middle), calls to routines (one raises: the exception
// must reach the caller through the generated frames), a shared start
// (EnterJump) with calls through memory (CallAt), and a jump site pointed
// elsewhere (Redirect). With no backend here only the model runs.

interface

{$Q-}{$R-}

uses
  System.Classes;

// Seeds random programs; Report gets a line for each part and the result.
// True: no difference.
function RunJitModelTest(Seeds: Integer; Report: TStrings): Boolean;

var
  // (To narrow a difference down: the random programs' steps, and where
  // their operations are listed, when assigned.)
  ModelTestSteps: Integer = 160;
  ModelTestTrace: TStrings;

implementation

uses
  System.SysUtils, HW.JIT;

type
  TFn = function(Box: Pointer; Ctx: Pointer): NativeInt;

var
  Calls: Integer;

procedure Boom(Box: Pointer; Ctx: Pointer);
begin
  Inc(Calls);
  raise EAbort.Create('boom from a routine called by generated code');
end;

function Echo(Box: Pointer; Ctx: Pointer): NativeInt;
begin
  Inc(Calls);
  Result := NativeInt(Ctx);
end;

function Mix(A, B, C, D: NativeUInt): NativeUInt;
begin
  // (Pointer-sized arguments, as every routine generated code calls.)
  Result := NativeUInt((UInt64(A) * UInt64($9E3779B97F4A7C15)) xor (UInt64(B) + UInt64($632BE59BD9B4E019))) * 3 +
    (C shl 7) - (D shr 3);
end;

type
  TRandom = record
    State: UInt64;
    function Next(N: Cardinal): Cardinal;
    function Bits: UInt64;
  end;

function TRandom.Next(N: Cardinal): Cardinal;
begin
  Result := Cardinal(Bits shr 33) mod N;
end;

function TRandom.Bits: UInt64;
begin
  State := State * UInt64(6364136223846793005) + UInt64(1442695040888963407);
  Result := State xor (State shr 29);
end;

const
  BoxSize = 65536;
  // Ctx points into the box's middle: negative displacements.
  CtxAt = 32768;
  // Registers every backend has (S4 not on x64).
  Regs: array[0..10] of TJitReg = (jrT0, jrT1, jrT2, jrT3, jrT4, jrT5, jrT6, jrS0, jrS1, jrS2, jrS3);
  // Call arguments: no register a call passes its arguments in on any target.
  ArgRegs: array[0..4] of TJitReg = (jrT0, jrS0, jrS1, jrS2, jrS3);
  Widths: array[0..2] of TJitWidth = (jw8, jw32, jw64);
  Conds: array[0..9] of TJitCond = (jcEq, jcNe, jcLt, jcLe, jcGt, jcGe, jcBelow, jcBelowEq, jcAbove, jcAboveEq);

function Imm(var R: TRandom; W: TJitWidth): Int64;
begin
  // Interesting constants (small, 12-bit edges, 16-bit pieces, negative)
  // as every backend takes them: 64 bits a sign-extended 32-bit one.
  case R.Next(8) of
    0: Result := R.Next(16);
    1: Result := 4095 + Integer(R.Next(3)) - 1;
    2: Result := -Integer(R.Next(5000));
    3: Result := Int64(R.Next($10000)) shl (16 * R.Next(2));
    4: Result := Integer(R.Bits);
    5: Result := Integer($FFFF0000 or R.Next($10000));
    6: Result := Int64(R.Next(4096)) shl 12;
  else
    Result := Integer(R.Bits shr 7);
  end;
  if W = jw8 then
    Result := Byte(Result)
  else if W = jw32 then
    Result := Int64(Cardinal(Result))
  else
    Result := Integer(Result);
end;

function Mem(var R: TRandom; W: TJitWidth): TJitOp;
begin
  // Within the box, aligned to W, from Self (often past 4 KB and 32 KB) or
  // from Ctx (often below it); not the first 96 bytes (the registers' place
  // at the end).
  var Size := 1;
  if W = jw32 then
    Size := 4
  else if W = jw64 then
    Size := 8;
  var At: Integer;
  case R.Next(4) of
    0: At := Integer(R.Next(256));
    1: At := Integer(R.Next(8192));
  else
    At := Integer(R.Next(BoxSize - 8));
  end;
  At := At and not (Size - 1);
  if At < 96 then
    Inc(At, 96);
  if R.Next(2) = 0 then
    Result := JMem(jrSelf, At)
  else
    Result := JMem(jrCtx, At - CtxAt);
end;

function RandomReg(var R: TRandom): TJitOp;
begin
  Result := JReg(Regs[R.Next(Length(Regs))]);
end;

procedure WriteProgram(J: TJitAsm; Seed: Integer);
begin
  var R: TRandom;
  R.State := UInt64(Seed) * $9E3779B97F4A7C15 + 1;
  J.ForgetLabels;
  J.Align(16);
  J.Enter;
  for var K := 0 to High(Regs) do
    J.Move(jw64, JReg(Regs[K]), JImm(Int64(R.Bits)));
  for var Step := 1 to ModelTestSteps do
  begin
    var W := Widths[R.Next(3)];
    var Mark := J.Offset;
    var Kind := R.Next(13);
    case Kind of
      0:
        J.Move(W, RandomReg(R), RandomReg(R));
      1:
        if W = jw64 then
          J.Move(jw64, RandomReg(R), JImm(Int64(R.Bits)))
        else
          J.Move(W, RandomReg(R), JImm(Imm(R, W)));
      2:
        J.Move(W, RandomReg(R), Mem(R, W));
      3:
        J.Move(W, Mem(R, W), RandomReg(R));
      4:
        J.Move(W, Mem(R, W), JImm(Imm(R, W) * Ord(R.Next(4) <> 0)));
      5, 6:
        begin
          var Op := TJitAlu(R.Next(5));
          var Src: TJitOp;
          case R.Next(3) of
            0: Src := RandomReg(R);
            1: Src := JImm(Imm(R, W));
          else
            Src := Mem(R, W);
          end;
          if (W = jw8) or (R.Next(3) = 0) then
          begin
            // Memory destination: a register or a constant (8 bits: only
            // there).
            if Src.Kind = okMem then
              Src := RandomReg(R);
            J.Alu(Op, W, Mem(R, W), Src);
          end
          else
            J.Alu(Op, W, RandomReg(R), Src);
        end;
      7:
        if W = jw64 then
          J.Shift(TJitShift(R.Next(3)), jw64, Regs[R.Next(Length(Regs))], Integer(R.Next(64)))
        else
          J.Shift(TJitShift(R.Next(3)), W, Regs[R.Next(Length(Regs))], Integer(R.Next(32)));
      8, 9:
        begin
          // A comparison (or test) and a branch over a mark in S3.
          var A, B: TJitOp;
          if R.Next(3) = 0 then
            A := Mem(R, W)
          else
            A := RandomReg(R);
          case R.Next(3) of
            0: B := RandomReg(R);
            1: B := JImm(Imm(R, W));
          else
            if A.Kind = okMem then
              B := RandomReg(R)
            else
              B := Mem(R, W);
          end;
          var L := J.NewLabel;
          if R.Next(4) = 0 then
          begin
            if B.Kind = okMem then
              B := RandomReg(R);
            if R.Next(3) = 0 then
              B := A;
            if B.Kind = okMem then
              B := RandomReg(R);
            J.BranchTest(Conds[R.Next(2)], W, A, B, L);
          end
          else
            J.Branch(Conds[R.Next(10)], W, A, B, L);
          J.Alu(jaAdd, jw64, JReg(jrS3), JImm(1 + R.Next(1000)));
          J.Bind(L);
        end;
      10:
        begin
          var Args: array[0..3] of TJitOp;
          for var K := 0 to 3 do
            case R.Next(4) of
              0: Args[K] := JReg(ArgRegs[R.Next(Length(ArgRegs))]);
              1: Args[K] := JImm(Imm(R, jw64));
              2: Args[K] := JAddr(jrCtx, Integer(R.Next(4096)) - 2048);
            else
              Args[K] := Mem(R, jw64);
            end;
          J.Call(@Mix, Args);
          // (The scratch registers after a call: T0 its result, the rest
          // anything.)
          for var K := 1 to 6 do
            J.Move(jw64, JReg(Regs[K]), JImm(Int64(R.Bits)));
        end;
      11:
        J.SignExtend(W, Regs[R.Next(Length(Regs))]);
    else
      J.Move(jw64, RandomReg(R), JAddr(TJitReg(Ord(jrSelf) + Integer(R.Next(2))), Integer(R.Next(65536)) - 32768));
    end;
    if Assigned(ModelTestTrace) then
      ModelTestTrace.Add(Format('step %d: kind %d, width %d, %d bytes', [Step, Kind, Ord(W), J.Offset - Mark]));
  end;
  for var K := 0 to High(Regs) do
    J.Move(jw64, JMem(jrSelf, K * 8), JReg(Regs[K]));
  J.Leave(JImm(Seed));
end;

procedure FillBox(var Box: TBytes; Seed: Integer);
begin
  var R: TRandom;
  R.State := UInt64(Seed) * 31 + 7;
  for var K := 0 to High(Box) do
    Box[K] := Byte(R.Bits shr 40);
end;

// The fixed parts, written to J: their functions' starts.
type
  TFixed = record
    Calling, Raising, Starter, Body, Sited: Pointer;
    Site, First, Second: NativeInt;
  end;

procedure WriteFixed(J: TJitAsm; out F: TFixed);
begin
  // Calls through generated frames, and exceptions out of them.
  J.ForgetLabels;
  J.Align(16);
  F.Raising := J.Here;
  J.Enter;
  J.Call(@Boom, [JSelf, JCtx]);
  J.Leave(JImm(-1));
  J.Align(16);
  F.Calling := J.Here;
  J.Enter;
  J.Call(@Echo, [JSelf, JCtx]);
  J.Alu(jaAdd, jw32, JT0, JImm(1));
  J.Leave(JT0);
  // A shared start (EnterJump) into a body that calls through memory
  // (CallAt) and raises through it.
  J.Align(16);
  F.Starter := J.Here;
  J.EnterJump;
  J.Align(16);
  F.Body := J.Here;
  J.Move(jw64, JS0, JT1);
  J.CallAt(JMem(jrSelf, SizeOf(Pointer)), [JSelf, JCtx]);
  J.Alu(jaAdd, jw64, JT0, JS0);
  J.Leave(JT0);
  // A jump site pointed elsewhere while the code stays.
  J.Align(16);
  F.Sited := J.Here;
  J.Enter;
  F.Site := J.JumpSite(J.Offset + 64);
  J.Align(64);
  F.First := J.Offset;
  J.Leave(JImm(1));
  J.Align(16);
  F.Second := J.Offset;
  J.Leave(JImm(2));
  J.ForgetLabels;
  J.Flush;
end;

function RunFixed(J: TJitAsm; const F: TFixed): string;
begin
  // What the fixed parts give, as a line (the same for every backend).
  Calls := 0;
  var A := J.Invoke(F.Calling, 0, 41, 0, 0);
  var Caught := 0;
  for var K := 1 to 3 do
    try
      J.Invoke(F.Raising, 0, 0, 0, 0);
    except
      on E: EAbort do
        Inc(Caught);
    end;
  var Table: array[0..2] of Pointer;
  Table[0] := nil;
  Table[1] := @Echo;
  Table[2] := @Boom;
  var B := J.Invoke(F.Starter, NativeUInt(@Table[0]), 41, NativeUInt(F.Body), 1000);
  var Caught2 := 0;
  try
    J.Invoke(F.Starter, NativeUInt(@Table[1]), 41, NativeUInt(F.Body), 1000);
  except
    on E: EAbort do
      Inc(Caught2);
  end;
  J.Redirect(F.Site, F.First);
  var R1 := J.Invoke(F.Sited, 0, 0, 0, 0);
  J.Redirect(F.Site, F.Second);
  var R2 := J.Invoke(F.Sited, 0, 0, 0, 0);
  Result := Format('call %d, raised %d, shared start %d, raised %d, sites %d %d, target %d, calls %d', [A, Caught, B,
    Caught2, R1, R2, Ord(J.SiteTarget(F.Site) = F.Second), Calls]);
end;

function RunJitModelTest(Seeds: Integer; Report: TStrings): Boolean;
const
  Expected = 'call 42, raised 3, shared start 1041, raised 1, sites 1 2, target 1, calls 6';
begin
  var Model := CreateJitModel(64 shl 20);
  var Native := CreateJitAsm(64 shl 20);
  try
    if Native = nil then
      Report.Add('no backend on this target: the model alone')
    else
      Report.Add('backend ' + Native.ClassName + ' against the model');
    // The fixed parts.
    var F: TFixed;
    WriteFixed(Model, F);
    var Line := RunFixed(Model, F);
    Report.Add('model: ' + Line);
    Result := Line = Expected;
    if Native <> nil then
    begin
      WriteFixed(Native, F);
      var NativeLine := RunFixed(Native, F);
      Report.Add('backend: ' + NativeLine);
      Result := Result and (NativeLine = Expected);
    end;
    // Random programs.
    var Box, BoxModel: TBytes;
    SetLength(Box, BoxSize);
    SetLength(BoxModel, BoxSize);
    var Different := 0;
    var FirstDifference := '';
    for var Seed := 1 to Seeds do
    begin
      if not Model.Room(1 shl 14) then
        Model.Reset;
      Model.Align(16);
      var ModelCode := Model.Here;
      WriteProgram(Model, Seed);
      Model.Flush;
      FillBox(Box, Seed);
      var ModelBack := Model.Invoke(ModelCode, NativeUInt(@Box[0]), NativeUInt(@Box[CtxAt]), 0, 0);
      if Native = nil then
        Continue;
      System.Move(Box[0], BoxModel[0], BoxSize);
      if not Native.Room(1 shl 16) then
        Native.Reset;
      Native.Align(16);
      var NativeCode := Native.Here;
      WriteProgram(Native, Seed);
      Native.Flush;
      FillBox(Box, Seed);
      var NativeBack := Native.Invoke(NativeCode, NativeUInt(@Box[0]), NativeUInt(@Box[CtxAt]), 0, 0);
      if (ModelBack <> NativeBack) or not CompareMem(@BoxModel[0], @Box[0], BoxSize) then
      begin
        Inc(Different);
        if FirstDifference = '' then
        begin
          FirstDifference := Format(' (first: program %d, result %d against %d', [Seed, NativeBack, ModelBack]);
          for var K := 0 to BoxSize - 1 do
            if BoxModel[K] <> Box[K] then
            begin
              FirstDifference := FirstDifference + Format(', byte %d: %.2x against %.2x', [K, Box[K], BoxModel[K]]);
              Break;
            end;
          FirstDifference := FirstDifference + ')';
        end;
      end;
    end;
    if Native = nil then
      Report.Add(Format('random programs: %d run by the model', [Seeds]))
    else
      Report.Add(Format('random programs: %d, %d unlike the model%s', [Seeds, Different, FirstDifference]));
    Result := Result and (Different = 0);
  finally
    Native.Free;
    Model.Free;
  end;
  if Result then
    Report.Add('OK')
  else
    Report.Add('FAILED');
end;

end.
