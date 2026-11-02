// Included by PS2.EE.CPU: blocks as generated code (HW.JIT, TEECPU.UseJit).
//
// A block's code does what Execute does with its instructions, one after the
// other: the common ones written out as host instructions that do exactly what
// their handlers do (the fast path of a load or store, its handler for the
// rest), the others a call to their handler (Self, the instruction). A handler
// that stops the block (True) leaves through JitStop, which sets the PC as
// Execute's ending does; after the last instruction the PC follows the branch
// state. After its last instruction a block goes on into the next block's
// code (JitEmitChain) where RunBlocks would run it next: the time counted,
// no deadline, interrupt, exit or reset due, the next block compiled, valid
// and not a spin or a polling block (RunBlocks's to pass over); else back to RunBlocks. The code
// returns the instructions its last block ran (0 after a chain's check), as
// Execute, the last block in FJitLast (set as it leaves). Code is made for a block
// when it has run JitHeat times, and dropped with the blocks (ClearBlocks,
// also when the writer is full); a reset asked for while code runs waits for
// it to return.

const
  EEJitBufferSize = 64 * 1024 * 1024;

type
  TEEJitOffsets = record
    GPR, HI, LO, PC, BranchTaken, BranchTarget, Stop, ReadMap, WriteMap, GenMap, FPR: Integer;
    Now, Deadline, Executed, IntPending, ExitRequest, JitFull, JitResetPending, WatchPtr, BlockProfile,
      History, HistoryPos, JitLast: Integer;
    // TEEBlock's.
    BPC, BGenPtr, BGenPtr2, BGen, BGen2, BInner: Integer;
    // IntPending, ExitRequest, JitFull and JitResetPending are four bytes in
    // a row (one look at all of them).
    Attention: Boolean;
  end;

var
  EEJitOff: TEEJitOffsets;

procedure EEJitWorkOutOffsets;
begin
  var O := Default(TEEJitOffsets);
  O.GPR := Integer(NativeUInt(@TEECPU(nil).S.GPR[0]));
  O.HI := Integer(NativeUInt(@TEECPU(nil).S.HI));
  O.LO := Integer(NativeUInt(@TEECPU(nil).S.LO));
  O.PC := Integer(NativeUInt(@TEECPU(nil).S.PC));
  O.BranchTaken := Integer(NativeUInt(@TEECPU(nil).FBranchTaken));
  O.BranchTarget := Integer(NativeUInt(@TEECPU(nil).FBranchTarget));
  O.Stop := Integer(NativeUInt(@TEECPU(nil).FStop));
  O.ReadMap := Integer(NativeUInt(@TEECPU(nil).FReadMap));
  O.WriteMap := Integer(NativeUInt(@TEECPU(nil).FWriteMap));
  O.GenMap := Integer(NativeUInt(@TEECPU(nil).FGenMap));
  O.FPR := Integer(NativeUInt(@TEECPU(nil).S.FPR[0]));
  O.Now := Integer(NativeUInt(@TEECPU(nil).Now));
  O.Deadline := Integer(NativeUInt(@TEECPU(nil).Deadline));
  O.Executed := Integer(NativeUInt(@TEECPU(nil).InstructionsExecuted));
  O.IntPending := Integer(NativeUInt(@TEECPU(nil).FIntPending));
  O.ExitRequest := Integer(NativeUInt(@TEECPU(nil).FExitRequest));
  O.JitFull := Integer(NativeUInt(@TEECPU(nil).FJitFull));
  O.JitResetPending := Integer(NativeUInt(@TEECPU(nil).FJitResetPending));
  O.WatchPtr := Integer(NativeUInt(@TEECPU(nil).WatchPtr));
  O.BlockProfile := Integer(NativeUInt(@TEECPU(nil).BlockProfile));
  O.History := Integer(NativeUInt(@TEECPU(nil).PCHistory));
  O.HistoryPos := Integer(NativeUInt(@TEECPU(nil).PCHistoryPos));
  O.JitLast := Integer(NativeUInt(@TEECPU(nil).FJitLast));
  O.BPC := Integer(NativeUInt(@PEEBlock(nil).PC));
  O.BGenPtr := Integer(NativeUInt(@PEEBlock(nil).GenPtr));
  O.BGenPtr2 := Integer(NativeUInt(@PEEBlock(nil).GenPtr2));
  O.BGen := Integer(NativeUInt(@PEEBlock(nil).Gen));
  O.BGen2 := Integer(NativeUInt(@PEEBlock(nil).Gen2));
  O.BInner := Integer(NativeUInt(@PEEBlock(nil).NativeInner));
  O.Attention := (O.ExitRequest = O.IntPending + 1) and (O.JitFull = O.IntPending + 2) and
    (O.JitResetPending = O.IntPending + 3);
  EEJitOff := O;
end;

// A handler stopped the block at I (Execute's ending: the PC by FStop).
procedure TEECPU.JitStop(I: PEEInst);
begin
  case FStop of
    StopPC: ;
    StopSkip: S.PC := I.Addr + 8;
  else
    if ((I.Flags and IFSlot) <> 0) and FBranchTaken then
      S.PC := FBranchTarget
    else
      S.PC := I.Addr + 4;
  end;
  FStop := 0;
end;

function TEECPU.JitCompile(B: PEEBlock): Pointer;
begin
  Result := nil;
  if FJit = nil then
  begin
    // (No backend, or no memory for one: the blocks stay interpreted.)
    if FJitFailed then
      Exit;
    FJit := CreateJitAsm(EEJitBufferSize);
    if FJit = nil then
    begin
      FJitFailed := True;
      Exit;
    end;
    // (The registers first: what most instructions read and write.)
    FJit.AddWindow(EEJitOff.GPR);
  end;
  if not FJit.Room(8192 + B.Count * 512) then
  begin
    FJitFull := True;
    Exit;
  end;
  var J := FJit;
  var O := EEJitOff;
  Inc(FJitCompiles);
  J.ForgetLabels;
  J.Align(16);
  Result := J.Here;
  J.Enter;
  // Chained blocks come in here.
  B.NativeInner := J.Here;
  J.Move(jw8, JMem(jrSelf, O.BranchTaken), JImm(0));
  J.Move(jw8, JMem(jrSelf, O.Stop), JImm(0));
  var Stops: TArray<TJitLabel>;
  SetLength(Stops, B.Count);
  for var K := 0 to B.Count - 1 do
  begin
    var I := B.Insts + K;
    Stops[K] := J.NewLabel;
    if not JitEmitOwn(I, Stops[K]) then
    begin
      // A COP2 macro operation the coprocessor has as code: called at once
      // while no micro program runs (else the handler waits for it), then
      // the handler's check of an exit request.
      var Routine: Pointer := nil;
      var Target: Pointer;
      var Running: PBoolean;
      if ((I.Op shr 26) = $12) and ((I.Op and $02000000) <> 0) then
        Routine := FCop2.MacroRoutine(I.Op, Target, Running);
      var Done := J.NewLabel;
      if Routine <> nil then
      begin
        var Handler := J.NewLabel;
        J.Move(jw64, JT1, JImm(Int64(NativeUInt(Running))));
        J.Move(jw8, JT0, JMem(jrT1, 0));
        J.BranchTest(jcNe, jw8, JT0, JT0, Handler);
        J.Call(Routine, [JImm(Int64(NativeUInt(Target)))]);
        J.Move(jw8, JT0, JMem(jrSelf, O.ExitRequest));
        J.BranchTest(jcEq, jw8, JT0, JT0, Done);
        J.Move(jw8, JMem(jrSelf, O.Stop), JImm(StopLeave));
        J.Jump(Stops[K]);
        J.Bind(Handler);
      end;
      J.Move(jw64, JT1, JImm(Int64(NativeUInt(I))));
      J.Call(I.Handler, [JSelf, JT1]);
      J.BranchTest(jcNe, jw8, JT0, JT0, Stops[K]);
      J.Bind(Done);
    end;
  end;
  // All ran: the PC after the last, or where its branch went.
  var Last := B.Insts + (B.Count - 1);
  var NotTaken := J.NewLabel;
  J.Move(jw8, JT0, JMem(jrSelf, O.BranchTaken));
  J.BranchTest(jcEq, jw8, JT0, JT0, NotTaken);
  J.Move(jw32, JT0, JMem(jrSelf, O.BranchTarget));
  J.Move(jw32, JMem(jrSelf, O.PC), JT0);
  JitEmitChain(B, 0);
  J.Bind(NotTaken);
  J.Move(jw32, JT0, JImm(Int64(Integer(Last.Addr + 4))));
  J.Move(jw32, JMem(jrSelf, O.PC), JT0);
  JitEmitChain(B, 1);
  // Stopped after instruction K.
  for var K := 0 to B.Count - 1 do
  begin
    J.Bind(Stops[K]);
    J.Move(jw64, JT1, JImm(Int64(NativeUInt(B.Insts + K))));
    J.Call(@TEECPU.JitStop, [JSelf, JT1]);
    J.Move(jw64, JT1, JImm(Int64(NativeUInt(B))));
    J.Move(jw64, JMem(jrSelf, O.JitLast), JT1);
    J.Leave(JImm(K + 1));
  end;
  J.ForgetLabels;
  J.Flush;
end;

// After B's last instruction, the PC (S.PC) in T0: B's time counted, on into
// the code of the block RunBlocks would run next, the one in B.Chain[K]
// (JitLink finds and learns it), as long as RunBlocks would go on to it with
// nothing else to do first; else back to RunBlocks (all counted: 0).
procedure TEECPU.JitEmitChain(B: PEEBlock; K: Integer);
begin
  var J := FJit;
  var O := EEJitOff;
  var Again := J.NewLabel;
  var Link := J.NewLabel;
  var Back := J.NewLabel;
  J.Move(jw64, JT1, JMem(jrSelf, O.Now));
  J.Alu(jaAdd, jw64, JMem(jrT1, 0), JImm(B.Count));
  J.Alu(jaAdd, jw64, JMem(jrSelf, O.Executed), JImm(B.Count));
  J.Move(jw64, JT2, JMem(jrSelf, O.Deadline));
  J.Move(jw64, JT2, JMem(jrT2, 0));
  J.Branch(jcGe, jw64, JMem(jrT1, 0), JT2, Back);
  if O.Attention then
  begin
    J.Move(jw32, JT2, JMem(jrSelf, O.IntPending));
    J.BranchTest(jcNe, jw32, JT2, JT2, Back);
  end
  else
    for var Flag in [O.IntPending, O.ExitRequest, O.JitFull, O.JitResetPending] do
    begin
      J.Move(jw8, JT2, JMem(jrSelf, Flag));
      J.BranchTest(jcNe, jw8, JT2, JT2, Back);
    end;
  // (Diagnostics see each block in RunBlocks: code made while they are on,
  // see RunBlocks.)
  if FJitDiagnostics then
    for var Diagnostic in [O.WatchPtr, O.BlockProfile] do
    begin
      J.Move(jw64, JT2, JMem(jrSelf, Diagnostic));
      J.BranchTest(jcNe, jw64, JT2, JT2, Back);
    end;
  J.Bind(Again);
  J.Move(jw64, JT3, JImm(Int64(NativeUInt(@B.Chain[K]))));
  J.Move(jw64, JT3, JMem(jrT3, 0));
  J.BranchTest(jcEq, jw64, JT3, JT3, Link);
  J.Branch(jcNe, jw32, JMem(jrT3, O.BPC), JT0, Link);
  // Its code pages unchanged since it was found valid (else JitLink checks).
  J.Move(jw64, JT4, JMem(jrT3, O.BGenPtr));
  J.Move(jw32, JT4, JMem(jrT4, 0));
  J.Branch(jcNe, jw32, JT4, JMem(jrT3, O.BGen), Link);
  J.Move(jw64, JT4, JMem(jrT3, O.BGenPtr2));
  J.Move(jw32, JT4, JMem(jrT4, 0));
  J.Branch(jcNe, jw32, JT4, JMem(jrT3, O.BGen2), Link);
  // RunBlocks's PC history.
  J.Move(jw32, JT5, JMem(jrSelf, O.HistoryPos));
  J.Alu(jaAnd, jw32, JT5, JImm(15));
  J.Shift(jsShl, jw64, jrT5, 2);
  J.Alu(jaAdd, jw64, JT5, JReg(jrSelf));
  J.Move(jw32, JMem(jrT5, O.History), JT0);
  J.Alu(jaAdd, jw32, JMem(jrSelf, O.HistoryPos), JImm(1));
  J.JumpIndirect(JMem(jrT3, O.BInner));
  J.Bind(Link);
  J.Move(jw64, JT1, JImm(Int64(NativeUInt(B))));
  J.Call(@TEECPU.JitLink, [JSelf, JT1, JImm(K)]);
  J.BranchTest(jcEq, jw64, JT0, JT0, Back);
  J.Move(jw32, JT0, JMem(jrSelf, O.PC));
  J.Jump(Again);
  J.Bind(Back);
  J.Move(jw64, JT1, JImm(Int64(NativeUInt(B))));
  J.Move(jw64, JMem(jrSelf, O.JitLast), JT1);
  J.Leave(JImm(0));
end;

// The compiled block at S.PC for B's exit K, learned into B.Chain[K] (as
// RunBlocks would find it: valid, its code made); nil: none (RunBlocks runs
// what comes next, as without chaining).
function TEECPU.JitLink(B: PEEBlock; K: Integer): Pointer;
begin
  Result := nil;
  var PC := S.PC;
  if ((PC and 3) <> 0) or (FReadMap[PC shr 12] = nil) then
    Exit;
  var Next := FindBlock(PC);
  if (Next = nil) or (Next.NativeInner = nil) or Next.Spin or Next.Poll or (Next.CountKind <> 0) or
    PollsWith(B, Next) or PollsWith(Next, B) then
    Exit;
  B.Chain[K] := Next;
  Result := Next;
end;

// Instruction I written out as host instructions doing what its handler does
// (registers by I.S, I.T, I.D as the handler takes them); False: not one of
// these. Stop: where the block stops after I (a likely branch not taken, or
// the handler of a slow access).
function TEECPU.JitEmitOwn(I: PEEInst; Stop: TJitLabel): Boolean;
var
  J: TJitAsm;
  O: TEEJitOffsets;

  function G(R: Integer): TJitOp;
  begin
    Result := JMem(jrSelf, O.GPR + R * SizeOf(TPS2Reg128));
  end;

  function GHi(R: Integer): TJitOp;
  begin
    Result := JMem(jrSelf, O.GPR + R * SizeOf(TPS2Reg128) + 8);
  end;

  function Imm32: TJitOp;
  begin
    Result := JImm(Int64(Integer(I.Imm)));
  end;

  // GPR[R] := T0's low 32 bits sign-extended.
  procedure Put32(R: Integer);
  begin
    J.SignExtend(jw32, jrT0);
    J.Move(jw64, G(R), JT0);
  end;

  procedure Shift32(Op: TJitShift);
  begin
    J.Move(jw32, JT0, G(I.T));
    if I.Sa <> 0 then
      J.Shift(Op, jw32, jrT0, I.Sa);
    Put32(I.D);
  end;

  procedure Shift64(Op: TJitShift);
  begin
    J.Move(jw64, JT0, G(I.T));
    if I.Sa <> 0 then
      J.Shift(Op, jw64, jrT0, I.Sa);
    J.Move(jw64, G(I.D), JT0);
  end;

  procedure Arith32(Op: TJitAlu);
  begin
    J.Move(jw32, JT0, G(I.S));
    J.Alu(Op, jw32, JT0, G(I.T));
    Put32(I.D);
  end;

  procedure Logic64(Op: TJitAlu; const Src: TJitOp; R: Integer);
  begin
    J.Move(jw64, JT0, G(I.S));
    J.Alu(Op, jw64, JT0, Src);
    J.Move(jw64, G(R), JT0);
  end;

  // GPR[R] := Ord(GPR[S] Cond B), 64-bit comparison.
  procedure SetIf(Cond: TJitCond; const B: TJitOp; R: Integer);
  begin
    var L := J.NewLabel;
    J.Move(jw64, JT1, G(I.S));
    J.Move(jw32, JT0, JImm(1));
    J.Branch(Cond, jw64, JT1, B, L);
    J.Move(jw32, JT0, JImm(0));
    J.Bind(L);
    J.Move(jw64, G(R), JT0);
  end;

  // FBranchTaken := GPR[S] Cond B; FBranchTarget := I.Imm.
  procedure BranchIf(Cond: TJitCond; const B: TJitOp);
  begin
    var L := J.NewLabel;
    J.Move(jw32, JMem(jrSelf, O.BranchTarget), Imm32);
    J.Move(jw64, JT0, G(I.S));
    J.Move(jw32, JT1, JImm(1));
    J.Branch(Cond, jw64, JT0, B, L);
    J.Move(jw32, JT1, JImm(0));
    J.Bind(L);
    J.Move(jw8, JMem(jrSelf, O.BranchTaken), JT1);
  end;

  // A likely branch: taken (GPR[S] Cond B) as BranchIf; else the block
  // stops after it, skipping the delay slot.
  procedure BranchLikely(Cond: TJitCond; const B: TJitOp);
  begin
    var Taken := J.NewLabel;
    J.Move(jw64, JT0, G(I.S));
    J.Branch(Cond, jw64, JT0, B, Taken);
    J.Move(jw8, JMem(jrSelf, O.Stop), JImm(StopSkip));
    J.Jump(Stop);
    J.Bind(Taken);
    J.Move(jw8, JMem(jrSelf, O.BranchTaken), JImm(1));
    J.Move(jw32, JMem(jrSelf, O.BranchTarget), Imm32);
  end;

  // T2 := the host address of GPR[S] + Imm (masked by AddressMask) through
  // Map, T1 its page index times 8; else to Slow (no page, or Align bits set).
  procedure Address(Map: Integer; Align: Cardinal; AddressMask: Cardinal; Slow: TJitLabel);
  begin
    J.Move(jw32, JT0, G(I.S));
    J.Alu(jaAdd, jw32, JT0, Imm32);
    if AddressMask <> $FFFFFFFF then
      J.Alu(jaAnd, jw32, JT0, JImm(Int64(Integer(AddressMask))));
    if Align <> 0 then
      J.BranchTest(jcNe, jw32, JT0, JImm(Align), Slow);
    J.Move(jw32, JT1, JT0);
    J.Shift(jsShr, jw32, jrT1, 12);
    J.Shift(jsShl, jw64, jrT1, 3);
    J.Move(jw64, JT2, JMem(jrSelf, Map));
    J.Alu(jaAdd, jw64, JT2, JT1);
    J.Move(jw64, JT2, JMem(jrT2, 0));
    J.BranchTest(jcEq, jw64, JT2, JT2, Slow);
    J.Alu(jaAnd, jw32, JT0, JImm($FFF));
    J.Alu(jaAdd, jw64, JT2, JT0);
  end;

  // The handler for what the fast path left.
  procedure SlowCall(Slow, Done: TJitLabel);
  begin
    J.Jump(Done);
    J.Bind(Slow);
    J.Move(jw64, JT1, JImm(Int64(NativeUInt(I))));
    J.Call(I.Handler, [JSelf, JT1]);
    J.BranchTest(jcNe, jw8, JT0, JT0, Stop);
    J.Bind(Done);
  end;

  procedure Load(W: TJitWidth; Sign: Boolean; Align: Cardinal);
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.ReadMap, Align, $FFFFFFFF, Slow);
    J.Move(W, JT0, JMem(jrT2, 0));
    if Sign then
      J.SignExtend(W, jrT0);
    J.Move(jw64, G(I.T), JT0);
    SlowCall(Slow, Done);
  end;

  // After a store through T2 (T1 its page index times 8): its page's write
  // generation.
  procedure Generation;
  begin
    J.Move(jw64, JT2, JMem(jrSelf, O.GenMap));
    J.Alu(jaAdd, jw64, JT2, JT1);
    J.Move(jw64, JT2, JMem(jrT2, 0));
    J.Alu(jaAdd, jw32, JMem(jrT2, 0), JImm(1));
  end;

  procedure Store(W: TJitWidth; Align: Cardinal);
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.WriteMap, Align, $FFFFFFFF, Slow);
    J.Move(W, JT3, G(I.T));
    J.Move(W, JMem(jrT2, 0), JT3);
    Generation;
    SlowCall(Slow, Done);
  end;

  // A halfword load (LH, LHU): its two bytes, little-endian.
  procedure Load16(Sign: Boolean);
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.ReadMap, 1, $FFFFFFFF, Slow);
    J.Move(jw8, JT0, JMem(jrT2, 1));
    J.Shift(jsShl, jw32, jrT0, 8);
    J.Move(jw8, JT1, JMem(jrT2, 0));
    J.Alu(jaOr, jw32, JT0, JT1);
    if Sign then
    begin
      J.Shift(jsShl, jw64, jrT0, 48);
      J.Shift(jsSar, jw64, jrT0, 48);
    end;
    J.Move(jw64, G(I.T), JT0);
    SlowCall(Slow, Done);
  end;

  // FPR[R] (as the COP1 handlers number it).
  function F(R: Integer): TJitOp;
  begin
    Result := JMem(jrSelf, O.FPR + R * SizeOf(Cardinal));
  end;

  // To Slow while VU0 runs a micro program (the COP2 handlers wait for it
  // first): Running is FCop2's flag; False: no such flag, the handler only.
  function Idle(Slow: TJitLabel): Boolean;
  begin
    var Running := FCop2.RunningFlag;
    Result := Running <> nil;
    if not Result then
      Exit;
    J.Move(jw64, JT1, JImm(Int64(NativeUInt(Running))));
    J.Move(jw8, JT0, JMem(jrT1, 0));
    J.BranchTest(jcNe, jw8, JT0, JT0, Slow);
  end;

  // VF[R]'s address in T1 (a register of VU0, the EE's coprocessor 2).
  procedure VFAddress(R: Integer);
  begin
    J.Move(jw64, JT1, JImm(Int64(NativeUInt(@FCop2.VF[R]))));
  end;

begin
  J := FJit;
  O := EEJitOff;
  var H := I.Handler;
  Result := True;
  if H = @TEECPU.OpNOP then
  else if H = @TEECPU.OpSLL then
    Shift32(jsShl)
  else if H = @TEECPU.OpSRL then
    Shift32(jsShr)
  else if H = @TEECPU.OpSRA then
    Shift32(jsSar)
  else if H = @TEECPU.OpDSLL then
    Shift64(jsShl)
  else if H = @TEECPU.OpDSRL then
    Shift64(jsShr)
  else if H = @TEECPU.OpDSRA then
    Shift64(jsSar)
  else if H = @TEECPU.OpADDU then
    Arith32(jaAdd)
  else if H = @TEECPU.OpSUBU then
    Arith32(jaSub)
  else if H = @TEECPU.OpDADDU then
    Logic64(jaAdd, G(I.T), I.D)
  else if H = @TEECPU.OpDSUBU then
    Logic64(jaSub, G(I.T), I.D)
  else if H = @TEECPU.OpAND then
    Logic64(jaAnd, G(I.T), I.D)
  else if H = @TEECPU.OpOR then
    Logic64(jaOr, G(I.T), I.D)
  else if H = @TEECPU.OpXOR then
    Logic64(jaXor, G(I.T), I.D)
  else if H = @TEECPU.OpNOR then
  begin
    J.Move(jw64, JT0, G(I.S));
    J.Alu(jaOr, jw64, JT0, G(I.T));
    J.Alu(jaXor, jw64, JT0, JImm(-1));
    J.Move(jw64, G(I.D), JT0);
  end
  else if H = @TEECPU.OpSLT then
    SetIf(jcLt, G(I.T), I.D)
  else if H = @TEECPU.OpSLTU then
    SetIf(jcBelow, G(I.T), I.D)
  else if H = @TEECPU.OpADDIU then
  begin
    J.Move(jw32, JT0, G(I.S));
    J.Alu(jaAdd, jw32, JT0, Imm32);
    Put32(I.T);
  end
  else if H = @TEECPU.OpDADDIU then
    Logic64(jaAdd, Imm32, I.T)
  else if H = @TEECPU.OpANDI then
    Logic64(jaAnd, JImm(I.Imm), I.T)
  else if H = @TEECPU.OpORI then
    Logic64(jaOr, JImm(I.Imm), I.T)
  else if H = @TEECPU.OpXORI then
    Logic64(jaXor, JImm(I.Imm), I.T)
  else if H = @TEECPU.OpLUI then
    J.Move(jw64, G(I.T), Imm32)
  else if H = @TEECPU.OpSLTI then
    SetIf(jcLt, Imm32, I.T)
  else if H = @TEECPU.OpSLTIU then
    SetIf(jcBelow, Imm32, I.T)
  else if (H = @TEECPU.OpMFHI) or (H = @TEECPU.OpMFLO) then
  begin
    if H = @TEECPU.OpMFHI then
      J.Move(jw64, JT0, JMem(jrSelf, O.HI))
    else
      J.Move(jw64, JT0, JMem(jrSelf, O.LO));
    J.Move(jw64, G(I.D), JT0);
  end
  else if (H = @TEECPU.OpMTHI) or (H = @TEECPU.OpMTLO) then
  begin
    J.Move(jw64, JT0, G(I.S));
    if H = @TEECPU.OpMTHI then
      J.Move(jw64, JMem(jrSelf, O.HI), JT0)
    else
      J.Move(jw64, JMem(jrSelf, O.LO), JT0);
  end
  else if (H = @TEECPU.OpMOVZ) or (H = @TEECPU.OpMOVN) then
  begin
    var Keep := J.NewLabel;
    J.Move(jw64, JT0, G(I.T));
    if H = @TEECPU.OpMOVZ then
      J.BranchTest(jcNe, jw64, JT0, JT0, Keep)
    else
      J.BranchTest(jcEq, jw64, JT0, JT0, Keep);
    J.Move(jw64, JT0, G(I.S));
    J.Move(jw64, G(I.D), JT0);
    J.Bind(Keep);
  end
  else if H = @TEECPU.OpBEQ then
    BranchIf(jcEq, G(I.T))
  else if H = @TEECPU.OpBNE then
    BranchIf(jcNe, G(I.T))
  else if H = @TEECPU.OpBLEZ then
    BranchIf(jcLe, JImm(0))
  else if H = @TEECPU.OpBGTZ then
    BranchIf(jcGt, JImm(0))
  else if H = @TEECPU.OpBLTZ then
    BranchIf(jcLt, JImm(0))
  else if H = @TEECPU.OpBGEZ then
    BranchIf(jcGe, JImm(0))
  else if H = @TEECPU.OpBEQL then
    BranchLikely(jcEq, G(I.T))
  else if H = @TEECPU.OpBNEL then
    BranchLikely(jcNe, G(I.T))
  else if H = @TEECPU.OpBLEZL then
    BranchLikely(jcLe, JImm(0))
  else if H = @TEECPU.OpBGTZL then
    BranchLikely(jcGt, JImm(0))
  else if H = @TEECPU.OpBLTZL then
    BranchLikely(jcLt, JImm(0))
  else if H = @TEECPU.OpBGEZL then
    BranchLikely(jcGe, JImm(0))
  else if (H = @TEECPU.OpJ) or (H = @TEECPU.OpJAL) then
  begin
    J.Move(jw8, JMem(jrSelf, O.BranchTaken), JImm(1));
    J.Move(jw32, JMem(jrSelf, O.BranchTarget), Imm32);
    if H = @TEECPU.OpJAL then
      J.Move(jw64, G(31), JImm(Int64(Integer(I.Addr + 8))));
  end
  else if (H = @TEECPU.OpJR) or (H = @TEECPU.OpJALR) then
  begin
    J.Move(jw32, JT0, G(I.S));
    J.Move(jw32, JMem(jrSelf, O.BranchTarget), JT0);
    J.Move(jw8, JMem(jrSelf, O.BranchTaken), JImm(1));
    if H = @TEECPU.OpJALR then
      J.Move(jw64, G(I.D), JImm(Int64(Integer(I.Addr + 8))));
  end
  else if H = @TEECPU.OpLW then
    Load(jw32, True, 3)
  else if H = @TEECPU.OpLWU then
    Load(jw32, False, 3)
  else if H = @TEECPU.OpLD then
    Load(jw64, False, 7)
  else if H = @TEECPU.OpLB then
    Load(jw8, True, 0)
  else if H = @TEECPU.OpLBU then
    Load(jw8, False, 0)
  else if H = @TEECPU.OpSW then
    Store(jw32, 3)
  else if H = @TEECPU.OpSD then
    Store(jw64, 7)
  else if H = @TEECPU.OpSB then
    Store(jw8, 0)
  else if H = @TEECPU.OpLQ then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.ReadMap, 0, not Cardinal(15), Slow);
    J.Move(jw64, JT0, JMem(jrT2, 0));
    J.Move(jw64, G(I.T), JT0);
    J.Move(jw64, JT0, JMem(jrT2, 8));
    J.Move(jw64, GHi(I.T), JT0);
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpMMIKernel then
  begin
    // The 64-bit ones written out (both sources read before the result is
    // written: it may be either), the others a direct call of the kernel.
    var Funct := I.Op and $3F;
    if (Funct = $09) and (I.Sa = 14) then // PCPYLD
    begin
      J.Move(jw64, JT0, G(I.S));
      J.Move(jw64, JT1, G(I.T));
      J.Move(jw64, G(I.D), JT1);
      J.Move(jw64, GHi(I.D), JT0);
    end
    else if (Funct = $29) and (I.Sa = 14) then // PCPYUD
    begin
      J.Move(jw64, JT0, GHi(I.S));
      J.Move(jw64, JT1, GHi(I.T));
      J.Move(jw64, G(I.D), JT0);
      J.Move(jw64, GHi(I.D), JT1);
    end
    else if ((Funct = $09) or (Funct = $29)) and (I.Sa in [18, 19]) then // PAND PXOR POR PNOR
    begin
      var Op := jaAnd;
      if Funct = $29 then Op := jaOr else if I.Sa = 19 then Op := jaXor;
      for var Half := 0 to 1 do
      begin
        J.Move(jw64, JT0, JMem(jrSelf, O.GPR + I.S * SizeOf(TPS2Reg128) + Half * 8));
        J.Alu(Op, jw64, JT0, JMem(jrSelf, O.GPR + I.T * SizeOf(TPS2Reg128) + Half * 8));
        if (Funct = $29) and (I.Sa = 19) then
          J.Alu(jaXor, jw64, JT0, JImm(-1));
        J.Move(jw64, JMem(jrSelf, O.GPR + I.D * SizeOf(TPS2Reg128) + Half * 8), JT0);
      end;
    end
    else
      J.Call(@EEMMIKernels[I.Imm].Kernel, [JAddr(jrSelf, O.GPR + I.S * SizeOf(TPS2Reg128)),
        JAddr(jrSelf, O.GPR + I.T * SizeOf(TPS2Reg128)), JAddr(jrSelf, O.GPR + I.D * SizeOf(TPS2Reg128)), JImm(I.Sa)]);
  end
  else if (H = @TEECPU.OpMMI) and ((I.Op and $3F) in [$10..$13]) then
  begin
    // MFHI1 MTHI1 MFLO1 MTLO1: the upper pipeline's HI/LO.
    case I.Op and $3F of
      $10: begin J.Move(jw64, JT0, JMem(jrSelf, O.HI + 8)); J.Move(jw64, G(I.D), JT0); end;
      $11: begin J.Move(jw64, JT0, G(I.S)); J.Move(jw64, JMem(jrSelf, O.HI + 8), JT0); end;
      $12: begin J.Move(jw64, JT0, JMem(jrSelf, O.LO + 8)); J.Move(jw64, G(I.D), JT0); end;
    else
      begin J.Move(jw64, JT0, G(I.S)); J.Move(jw64, JMem(jrSelf, O.LO + 8), JT0); end;
    end;
  end
  else if H = @TEECPU.OpLH then
    Load16(True)
  else if H = @TEECPU.OpLHU then
    Load16(False)
  else if H = @TEECPU.OpSH then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.WriteMap, 1, $FFFFFFFF, Slow);
    J.Move(jw32, JT3, G(I.T));
    J.Move(jw8, JMem(jrT2, 0), JT3);
    J.Shift(jsShr, jw32, jrT3, 8);
    J.Move(jw8, JMem(jrT2, 1), JT3);
    Generation;
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpADDI then
  begin
    // The 64-bit sum of the sign-extended operands, unless it is not its
    // own sign extension from 32 bits (overflow: the handler raises it).
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    J.Move(jw32, JT0, G(I.S));
    J.SignExtend(jw32, jrT0);
    J.Alu(jaAdd, jw64, JT0, Imm32);
    J.Move(jw64, JT1, JT0);
    J.SignExtend(jw32, jrT1);
    J.Branch(jcNe, jw64, JT0, JT1, Slow);
    J.Move(jw64, G(I.T), JT0);
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpLWC1 then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.ReadMap, 3, $FFFFFFFF, Slow);
    J.Move(jw32, JT0, JMem(jrT2, 0));
    J.Move(jw32, F((I.Op shr 16) and 31), JT0);
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpSWC1 then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.WriteMap, 3, $FFFFFFFF, Slow);
    J.Move(jw32, JT3, F((I.Op shr 16) and 31));
    J.Move(jw32, JMem(jrT2, 0), JT3);
    Generation;
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpMFC1 then
  begin
    J.Move(jw32, JT0, F(I.S));
    Put32(I.T);
  end
  else if H = @TEECPU.OpMTC1 then
  begin
    J.Move(jw32, JT0, G(I.T));
    J.Move(jw32, F(I.S), JT0);
  end
  else if H = @TEECPU.OpLQC2 then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    if not Idle(Slow) then
      Exit(False);
    Address(O.ReadMap, 0, not Cardinal(15), Slow);
    var Ft := Integer((I.Op shr 16) and 31);
    if Ft <> 0 then
    begin
      VFAddress(Ft);
      J.Move(jw64, JT0, JMem(jrT2, 0));
      J.Move(jw64, JMem(jrT1, 0), JT0);
      J.Move(jw64, JT0, JMem(jrT2, 8));
      J.Move(jw64, JMem(jrT1, 8), JT0);
    end;
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpSQC2 then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    if not Idle(Slow) then
      Exit(False);
    Address(O.WriteMap, 0, not Cardinal(15), Slow);
    // (T1, the page index, for Generation: the register through T3.)
    J.Move(jw64, JT3, JImm(Int64(NativeUInt(@FCop2.VF[(I.Op shr 16) and 31]))));
    J.Move(jw64, JT0, JMem(jrT3, 0));
    J.Move(jw64, JMem(jrT2, 0), JT0);
    J.Move(jw64, JT0, JMem(jrT3, 8));
    J.Move(jw64, JMem(jrT2, 8), JT0);
    Generation;
    SlowCall(Slow, Done);
  end
  else if (H = @TEECPU.OpCOP2) and (((I.Op shr 21) and 31) in [1, 5]) then
  begin
    // QMFC2, QMTC2: the whole register.
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    if not Idle(Slow) then
      Exit(False);
    var Fs := Integer((I.Op shr 11) and 31);
    if ((I.Op shr 21) and 31) = 1 then
    begin
      VFAddress(Fs);
      J.Move(jw64, JT0, JMem(jrT1, 0));
      J.Move(jw64, G(I.T), JT0);
      J.Move(jw64, JT0, JMem(jrT1, 8));
      J.Move(jw64, GHi(I.T), JT0);
    end
    else if Fs <> 0 then
    begin
      VFAddress(Fs);
      J.Move(jw64, JT0, G(I.T));
      J.Move(jw64, JMem(jrT1, 0), JT0);
      J.Move(jw64, JT0, GHi(I.T));
      J.Move(jw64, JMem(jrT1, 8), JT0);
    end;
    SlowCall(Slow, Done);
  end
  else if H = @TEECPU.OpSQ then
  begin
    var Slow := J.NewLabel;
    var Done := J.NewLabel;
    Address(O.WriteMap, 0, not Cardinal(15), Slow);
    J.Move(jw64, JT3, G(I.T));
    J.Move(jw64, JMem(jrT2, 0), JT3);
    J.Move(jw64, JT3, GHi(I.T));
    J.Move(jw64, JMem(jrT2, 8), JT3);
    Generation;
    SlowCall(Slow, Done);
  end
  else
    Result := False;
end;
