// Included by PS2.EE.CPU: blocks as generated code (HW.JIT, TEECPU.UseJit).
//
// A block's code does what Execute does with its instructions, one after the
// other: the common ones written out as host instructions that do exactly what
// their handlers do (the fast path of a load or store, its handler for the
// rest), the others a call to their handler (Self, the instruction). A handler
// that stops the block (True) leaves through JitStop, which sets the PC as
// Execute's ending does; after the last instruction the PC follows the branch
// state. The code returns the instructions run, as Execute; RunBlocks keeps
// the time, the interrupts and the block chaining. Code is made for a block
// when it has run JitHeat times, and dropped with the blocks (ClearBlocks,
// also when the writer is full); a reset asked for while code runs waits for
// it to return.

const
  EEJitBufferSize = 64 * 1024 * 1024;

type
  TEEJitOffsets = record
    GPR, HI, LO, PC, BranchTaken, BranchTarget, Stop, ReadMap, WriteMap, GenMap: Integer;
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
  if not FJit.Room(4096 + B.Count * 512) then
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
      J.Move(jw64, JT1, JImm(Int64(NativeUInt(I))));
      J.Call(I.Handler, [JSelf, JT1]);
      J.BranchTest(jcNe, jw8, JT0, JT0, Stops[K]);
    end;
  end;
  // All ran: the PC after the last, or where its branch went.
  var Last := B.Insts + (B.Count - 1);
  var NotTaken := J.NewLabel;
  J.Move(jw8, JT0, JMem(jrSelf, O.BranchTaken));
  J.BranchTest(jcEq, jw8, JT0, JT0, NotTaken);
  J.Move(jw32, JT0, JMem(jrSelf, O.BranchTarget));
  J.Move(jw32, JMem(jrSelf, O.PC), JT0);
  J.Leave(JImm(B.Count));
  J.Bind(NotTaken);
  J.Move(jw32, JMem(jrSelf, O.PC), JImm(Int64(Integer(Last.Addr + 4))));
  J.Leave(JImm(B.Count));
  // Stopped after instruction K.
  for var K := 0 to B.Count - 1 do
  begin
    J.Bind(Stops[K]);
    J.Move(jw64, JT1, JImm(Int64(NativeUInt(B.Insts + K))));
    J.Call(@TEECPU.JitStop, [JSelf, JT1]);
    J.Leave(JImm(K + 1));
  end;
  J.ForgetLabels;
  J.Flush;
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
