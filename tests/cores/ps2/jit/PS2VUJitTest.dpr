program PS2VUJitTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, PS2.Types, PS2.VU, PS2.VU.Float, PS2.EE.CPU, HW.JIT;

type
  TMemory = array[0..4095] of Cardinal;
  TKickProbe = class
    Core: TPS2VUCore;
    Code: PCardinal;
    Count: Integer;
    RaiseAt: Integer;
    Times: array[0..63] of Int64;
    procedure Kick(Address: Cardinal; Data: PByte);
  end;

procedure TKickProbe.Kick(Address: Cardinal; Data: PByte);
begin
  if (Address <> 0) or (PCardinal(Data)^ <> $8000) then
    raise Exception.Create('Unexpected XGKICK packet');
  Times[Count] := Core.S.Cycles;
  Inc(Count);
  // Rewrite an interior pair after it has already been compiled. The next
  // guard must leave the block before executing that pair's stale code.
  Code[12] := $10020000 or Cardinal(1 + (Count and 1));
  Core.NoteCodeWritten;
  if Count = RaiseAt then
    raise EInvalidOpException.Create('XGKICK unwind probe');
end;

procedure Check(Model: Boolean);
const
  UpperFunctions: array[0..19] of Cardinal = ($28, $2C, $2A, $2B, $2F, $00, $18, $1D,
    $04, $08, $0C, $1C, $1E, $20, $21, $22, $23, $24, $25, $2E);
  LowerFunctions: array[0..4] of Cardinal = ($30, $31, $32, $34, $35);
  UpperSpecial: array[0..22] of Cardinal = ($00, $04, $08, $0C, $10, $11, $12, $13,
    $14, $15, $16, $17, $18, $1C, $1D, $1E, $1F, $20, $21, $28, $29, $2D, $2E);
  // (With the EFU ops and WAITP: P through scheduled runs.)
  LowerSpecial: array[0..29] of Cardinal = ($30, $31, $34, $35, $36, $37, $38, $39,
    $3A, $3B, $3C, $3D, $3E, $3F, $40, $41, $42, $43, $64, $68, $69, $70, $71, $72, $73, $76, $78,
    $79, $7A, $7B);
  // Lower specials writing a VF register: MOVE MR32 LQI LQD MFIR MFP.
  VFSpecial: array[0..5] of Cardinal = ($30, $31, $34, $36, $3D, $64);
  Programs = 120;
var
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
  Code0, Code1, Data0, Data1: TMemory;
begin
  FillChar(VF0, SizeOf(VF0), 0);
  FillChar(VF1, SizeOf(VF1), 0);
  FillChar(VI0, SizeOf(VI0), 0);
  FillChar(VI1, SizeOf(VI1), 0);
  FillChar(Code0, SizeOf(Code0), 0);
  FillChar(Code1, SizeOf(Code1), 0);
  FillChar(Data0, SizeOf(Data0), 0);
  FillChar(Data1, SizeOf(Data1), 0);
  var A := TPS2VUCore.Create(1, @VF0, @VI0, @Code0, @Data0, SizeOf(Code0), SizeOf(Data0));
  var B := TPS2VUCore.Create(1, @VF1, @VI1, @Code1, @Data1, SizeOf(Code1), SizeOf(Data1));
  try
    if Model then B.UseJitModel else B.UseJit := True;
    RandSeed := 71831;
    for var ProgramIndex := 0 to Programs - 1 do
    begin
      // Re-upload at the same addresses: compiled entries must be replaced.
      for var K := 0 to 63 do
      begin
        var Rs := Cardinal(Random(16));
        var Rt := Cardinal(Random(16));
        var Rd := Cardinal(Random(16));
        var Mask := Cardinal(Random(16));
        // (Programs 100 and up: lower halves writing VF registers, often a
        // register to itself or the one the upper half writes as well.)
        var VFLower := (ProgramIndex >= 100) and not Odd(K);
        if VFLower then
        begin
          if Random(2) = 0 then Rs := Rt;
          if Random(2) = 0 then Rd := Rt;
        end;
        var Lo: Cardinal;
        case K mod 11 of
          0..4: Lo := $80000000 or LowerFunctions[K mod 11] or (Rs shl 11) or (Rt shl 16) or (Rd shl 6);
          5: Lo := ($08 shl 25) or (Rs shl 11) or (Rt shl 16) or Cardinal(Random(2048));
          6: Lo := ($09 shl 25) or (Rs shl 11) or (Rt shl 16) or Cardinal(Random(2048));
          7: Lo := (Mask shl 21) or (Rs shl 11) or (Rt shl 16); // LQ
          8: Lo := ($04 shl 25) or (Mask shl 21) or (Rs shl 11) or (Rt shl 16) or $7FF; // ILW
          9: Lo := ($05 shl 25) or (Mask shl 21) or (Rs shl 11) or (Rt shl 16) or $400; // ISW
        else
          Lo := ($01 shl 25) or (Mask shl 21) or (Rs shl 11) or (Rt shl 16); // SQ
        end;
        if (ProgramIndex >= 50) and (K mod 3 = 0) then
        begin
          var Special := LowerSpecial[Random(Length(LowerSpecial))];
          Lo := $8000003C or ((Special shr 2) shl 6) or (Special and 3) or
            (Mask shl 21) or (Rs shl 11) or (Rt shl 16);
        end;
        if (ProgramIndex >= 75) and (K mod 4 = 1) then
          // FC*, FS* and FM*: queues must land before their reads.
          Lo := (Cardinal($10 + Random(13)) shl 25) or (Rt shl 16) or (Rs shl 11) or Cardinal(Random(2048));
        if VFLower then
        begin
          var Special := VFSpecial[Random(Length(VFSpecial))];
          Lo := $8000003C or ((Special shr 2) shl 6) or (Special and 3) or
            (Mask shl 21) or (Rs shl 11) or (Rt shl 16);
          if Random(7) = 0 then Lo := (Mask shl 21) or (Rs shl 11) or (Rt shl 16) or Cardinal(Random(2048)); // LQ
        end;
        Code0[K * 2] := Lo;
        var Hi := UpperFunctions[Random(Length(UpperFunctions))] or (Rd shl 6) or
          (Rs shl 11) or (Rt shl 16) or (Mask shl 21);
        if K mod 5 = 0 then Hi := $000002FF; // NOP
        if K mod 7 = 0 then Hi := $000001FD or (Rs shl 11) or (Rt shl 16) or (Mask shl 21); // ABS
        if (ProgramIndex >= 50) and (K mod 3 = 1) then
        begin
          var Special := UpperSpecial[Random(Length(UpperSpecial))];
          Hi := $3C or ((Special shr 2) shl 6) or (Special and 3) or
            (Mask shl 21) or (Rs shl 11) or (Rt shl 16);
        end;
        if K mod 13 = 0 then Hi := Hi or $80000000; // immediate after upper
        if K = 62 then Hi := Hi or $40000000;
        Code0[K * 2 + 1] := Hi;
      end;
      // A forward branch and its delay slot exercise exits in small budgets.
      Code0[20] := $40000002;
      if ProgramIndex mod 3 = 1 then Code0[20] := $50020802; // IBEQ vi1,vi2,+2
      if ProgramIndex mod 3 = 2 then Code0[20] := $52020802; // IBNE vi1,vi2,+2
      Code0[21] := $000002FF;
      Code1 := Code0;
      for var K := 1 to 31 do
      begin
        VI0[K] := Cardinal(Random(65536));
        for var C := 0 to 3 do
          VF0[K].UW[C] := Cardinal(Random(MaxInt)) xor (Cardinal(Random(2)) shl 31);
      end;
      VF1 := VF0;
      VI1 := VI0;
      for var K := 0 to High(Data0) do Data0[K] := Cardinal(Random(MaxInt));
      Data1 := Data0;
      for var RepeatIndex := 0 to 39 do
      begin
        if RepeatIndex = 32 then
        begin
          // Diagnostics force the shared prepare path; switching into and
          // out of it must not change pipeline state or instruction order.
          SetLength(A.RunTrace, 128 * 16);
          SetLength(B.RunTrace, 128 * 16);
          A.RunTraceCount := 0; B.RunTraceCount := 0;
        end;
        if RepeatIndex = 33 then
        begin
          A.RunTrace := nil; B.RunTrace := nil;
        end;
        if RepeatIndex = 30 then
        begin
          // Keep the entry word unchanged while replacing interior code.
          Code0[28] := $12010017;
          Code1[28] := Code0[28];
        end;
        A.NoteCodeWritten;
        B.NoteCodeWritten;
        A.Start(0);
        B.Start(0);
        while A.S.Running do
        begin
          var Budget := 1 + Random(11);
          if RepeatIndex mod 3 = 0 then Budget := 128;
          // Switching modes must preserve the in-flight pipeline.
          B.UseJit := RepeatIndex mod 7 <> 0;
          var EndA := A.Run(Budget);
          var EndB := B.Run(Budget);
          if (EndA <> EndB) or not CompareMem(@A.S, @B.S, SizeOf(A.S)) or
            not CompareMem(@VF0, @VF1, SizeOf(VF0)) or not CompareMem(@VI0, @VI1, SizeOf(VI0)) or
            not CompareMem(@Data0, @Data1, SizeOf(Data0)) or
            not CompareMem(@A.LoopTrace, @B.LoopTrace, SizeOf(A.LoopTrace)) or (A.Executed <> B.Executed) or
            (A.RunTraceCount <> B.RunTraceCount) or
            ((A.RunTrace <> nil) and not CompareMem(@A.RunTrace[0], @B.RunTrace[0], Length(A.RunTrace) * SizeOf(Word))) then
            raise Exception.CreateFmt('Mismatch model=%s program=%d repeat=%d pc=%x',
              [BoolToStr(Model, True), ProgramIndex, RepeatIndex, A.S.TPC]);
        end;
      end;
    end;
    var KA := TKickProbe.Create;
    var KB := TKickProbe.Create;
    try
      KA.Core := A; KA.Code := @Code0;
      KB.Core := B; KB.Code := @Code1;
      KA.RaiseAt := 25; KB.RaiseAt := 25;
      A.OnKick := KA.Kick;
      B.OnKick := KB.Kick;
      FillChar(VF0, SizeOf(VF0), 0); FillChar(VF1, SizeOf(VF1), 0);
      FillChar(VI0, SizeOf(VI0), 0); FillChar(VI1, SizeOf(VI1), 0);
      FillChar(Data0, SizeOf(Data0), 0); Data0[0] := $8000; Data1 := Data0;
      for var K := 0 to 15 do
      begin
        Code0[K * 2] := $10010001;
        Code0[K * 2 + 1] := $000002FF;
      end;
      Code0[2] := $800006FC; // XGKICK vi0
      Code0[29] := $400002FF;
      Code1 := Code0;
      A.Reset; B.Reset;
      B.UseJit := True;
      for var K := 0 to 39 do
      begin
        A.NoteCodeWritten; B.NoteCodeWritten; A.Start(0); B.Start(0);
        var RaisedA := False;
        var RaisedB := False;
        try A.Run(128); except on E: EInvalidOpException do
          if E.Message = 'XGKICK unwind probe' then RaisedA := True else raise; end;
        try B.Run(128); except on E: EInvalidOpException do
          if E.Message = 'XGKICK unwind probe' then RaisedB := True else raise; end;
        if RaisedA <> RaisedB then raise Exception.Create('Generated-frame exception unwind mismatch');
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or
          not CompareMem(@VI0, @VI1, SizeOf(VI0)) or
          not CompareMem(@Code0, @Code1, SizeOf(Code0)) or
          not CompareMem(@KA.Times, @KB.Times, SizeOf(KA.Times)) or (KA.Count <> KB.Count) then
          raise Exception.Create('XGKICK or interior rewrite mismatch');
      end;
      if KA.Count <> 40 then raise Exception.Create('Missing XGKICK callbacks');
    finally
      A.OnKick := nil; B.OnKick := nil;
      KA.Free; KB.Free;
    end;
    if B.JitRuns = 0 then raise Exception.Create('No generated code executed');
    {$IFNDEF PS2_VU_MEMORY_MATH}
    if PS2VectorAVX2 and (B.JitVectorOps = 0) then raise Exception.Create('No register arithmetic was generated');
    {$ENDIF}
    if B.JitFastPairs = 0 then raise Exception.Create('No statically scheduled pairs executed');
    if (B.JitBlocks = 0) or (B.JitRuns <= B.JitBlocks) then
      raise Exception.Create('Generated code did not execute multiple pairs per block');
    Writeln('model=', Model, ' programs=', Programs, ' generated pairs=', B.JitRuns, ' entries=', B.JitBlocks,
      ' compiles=', B.JitCompiles, ' resets=', B.JitResets, ' reused=', B.JitCacheHits, ' kicks=40 OK');
    Writeln('scheduled pairs=', B.JitFastPairs);
    Writeln('register arithmetic sites=', B.JitVectorOps);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure CheckVersions(Model: Boolean);
var
  Code0, Code1, Data0, Data1: TMemory;
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
begin
  FillChar(Code0, SizeOf(Code0), 0); FillChar(Code1, SizeOf(Code1), 0);
  FillChar(Data0, SizeOf(Data0), 0); FillChar(Data1, SizeOf(Data1), 0);
  FillChar(VF0, SizeOf(VF0), 0); FillChar(VF1, SizeOf(VF1), 0);
  FillChar(VI0, SizeOf(VI0), 0); FillChar(VI1, SizeOf(VI1), 0);
  var A := TPS2VUCore.Create(1, @VF0, @VI0, @Code0, @Data0, SizeOf(Code0), SizeOf(Data0));
  var B := TPS2VUCore.Create(1, @VF1, @VI1, @Code1, @Data1, SizeOf(Code1), SizeOf(Data1));
  try
    if Model then B.UseJitModel else B.UseJit := True;
    // These two versions have the same rolling hash: the low-word bit at
    // pair 0 is rotated by 22 more bits than the one at pair 1. A hash hit
    // must still compare every word, not execute the other version.
    for var Round := 0 to 5 do
    begin
      for var K := 0 to 15 do
      begin
        Code0[K * 2] := $3F800000;
        // I-bit ADDi.xyzw vf1,vf1 (the previous pair's I).
        Code0[K * 2 + 1] := $81E00862;
      end;
      Code0[32] := $8000033C;
      Code0[33] := $01E10868; // probe vf1 after a scheduled exit
      Code0[29] := Code0[29] or $40000000;
      if Odd(Round) then
      begin
        Code0[0] := Code0[0] xor 1;
        Code0[2] := Code0[2] xor $400000;
      end;
      Code1 := Code0;
      for var RepeatIndex := 0 to 31 do
      begin
        A.NoteCodeWritten; B.NoteCodeWritten; A.Start(0); B.Start(0);
        A.Run(256); B.Run(256);
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VF0, @VF1, SizeOf(VF0)) then
          raise Exception.CreateFmt('Version collision model=%s round=%d repeat=%d',
            [BoolToStr(Model, True), Round, RepeatIndex]);
        // Keep pending ready times: switch to the interpreter without Start().
        A.S.TPC := 128; B.S.TPC := 128;
        A.S.Running := True; B.S.Running := True;
        B.UseJit := False;
        A.Run(1); B.Run(1);
        B.UseJit := True;
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VF0, @VF1, SizeOf(VF0)) then
          raise Exception.Create('Scheduled ready state lost at mode switch');
      end;
    end;
    if B.JitCacheHits = 0 then raise Exception.Create('Uploaded block versions were not reused');
    // A counted back edge, BAL/JR and their delay slots. Use small budgets
    // as well as enough budget to chain through the loop and subroutine.
    for var K := 0 to 15 do
    begin
      Code0[K * 2] := $8000033C; // lower NOP (MOVE. vf0,vf0)
      Code0[K * 2 + 1] := $000002FF;
    end;
    Code0[0] := $10010007; // IADDIU vi1,vi0,7
    Code0[4] := $80010FF2; // IADDI vi1,vi1,-1
    Code0[6] := $5A000FFE; // IBGTZ vi1,-2 (sees the previous value)
    Code0[10] := $420F0003; // BAL vi15,+3 -> pair 9
    Code0[14] := $40000005; // B +5 -> pair 13
    Code0[18] := $48007800; // JR vi15 -> pair 7
    Code0[27] := $400002FF;
    Code1 := Code0;
    for var RepeatIndex := 0 to 63 do
    begin
      A.NoteCodeWritten; B.NoteCodeWritten; A.Start(0); B.Start(0);
      while A.S.Running do
      begin
        var Budget := 2 + (RepeatIndex mod 9);
        if Odd(RepeatIndex) then Budget := 256;
        A.Run(Budget); B.Run(Budget);
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VI0, @VI1, SizeOf(VI0)) or
          not CompareMem(@A.LoopTrace, @B.LoopTrace, SizeOf(A.LoopTrace)) then
          raise Exception.Create('Chained loop/call pipeline mismatch');
      end;
    end;
    Writeln('model=', Model, ' version collision/reuse and chained loop/call: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckScheduled(Model: Boolean);
var
  Code0, Code1, Data0, Data1: TMemory;
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
begin
  FillChar(Code0, SizeOf(Code0), 0); FillChar(Code1, SizeOf(Code1), 0);
  FillChar(Data0, SizeOf(Data0), 0); FillChar(Data1, SizeOf(Data1), 0);
  FillChar(VF0, SizeOf(VF0), 0); FillChar(VF1, SizeOf(VF1), 0);
  FillChar(VI0, SizeOf(VI0), 0); FillChar(VI1, SizeOf(VI1), 0);
  var A := TPS2VUCore.Create(1, @VF0, @VI0, @Code0, @Data0, SizeOf(Code0), SizeOf(Data0));
  var B := TPS2VUCore.Create(1, @VF1, @VI1, @Code1, @Data1, SizeOf(Code1), SizeOf(Data1));
  try
    if Model then B.UseJitModel else B.UseJit := True;
    for var ProgramIndex := 0 to 4 do
    begin
      // Cross multiple compiled spans with incoming queue tails still live.
      for var K := 0 to 63 do
      begin
        Code0[K * 2] := $10020001; // VI arithmetic with a delayed branch operand
        Code0[K * 2 + 1] := $01E10868; // ADD.xyzw vf1,vf1,vf1 (dependent FMAC)
        if (ProgramIndex = 1) and (K mod 4 <> 0) then Code0[K * 2 + 1] := $000002FF;
        if ProgramIndex = 2 then Code0[K * 2 + 1] := $000002FF;
        if ProgramIndex = 3 then Code0[K * 2 + 1] := $01E2117D; // FTOI4.xyzw vf2,vf2
        if ProgramIndex = 4 then Code0[K * 2 + 1] := $01E109BC; // MULAx.xyzw ACC,vf1,vf1
      end;
      Code0[8] := $81E3067C; // MFP.xyzw vf3
      if ProgramIndex <= 1 then Code0[11] := $01E1085C; // MULq.xyzw vf1,vf1
      Code0[125] := Code0[125] or $40000000;
      Code1 := Code0;
      for var RepeatIndex := 0 to 63 do
      begin
        A.NoteCodeWritten; B.NoteCodeWritten; A.Start(0); B.Start(0);
        var Base := A.S.Cycles;
        A.S.QDelay := 1 + RepeatIndex mod 13;
        A.S.PDelay := 1 + RepeatIndex mod 19;
        A.S.PendingQ := $3F000000 + Cardinal(RepeatIndex shl 8);
        A.S.PendingP := $3F800000 + Cardinal(RepeatIndex shl 8);
        A.S.FlagQCount := RepeatIndex mod 5;
        A.S.ClipQCount := (RepeatIndex div 5) mod 5;
        for var K := 0 to 3 do
        begin
          // Poison unused tails too: scheduled execution must reproduce
          // their exact stale values, not only the live queue entries.
          A.S.FlagQMAC[K] := Cardinal($1200 + RepeatIndex * 4 + K);
          A.S.FlagQStatus[K] := Cardinal($3400 + RepeatIndex * 4 + K);
          A.S.FlagQReady[K] := Base + K;
          A.S.ClipQValue[K] := Cardinal($5600 + RepeatIndex * 4 + K);
          A.S.ClipQReady[K] := Base + K;
          if RepeatIndex mod 11 = 0 then
          begin
            // Unusual incoming deadlines must select the general path.
            Inc(A.S.FlagQReady[K], 100);
            Inc(A.S.ClipQReady[K], 100);
          end;
        end;
        B.S := A.S;
        VF0[1].UW[0] := $3F800000; VF0[1].UW[1] := $BF800000;
        VF0[1].UW[2] := $00800001; VF0[1].UW[3] := $7FFFFFFF;
        VF0[2] := VF0[1]; VF1 := VF0;
        A.Run(256); B.Run(256);
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VF0, @VF1, SizeOf(VF0)) or
          not CompareMem(@VI0, @VI1, SizeOf(VI0)) or
          not CompareMem(@A.LoopTrace, @B.LoopTrace, SizeOf(A.LoopTrace)) then
          raise Exception.CreateFmt('Scheduled queues/Q/P model=%s program=%d repeat=%d',
            [BoolToStr(Model, True), ProgramIndex, RepeatIndex]);
      end;
    end;
    if B.JitFastPairs = 0 then raise Exception.Create('Scheduled queue test did not enter the fast path');
    Writeln('model=', Model, ' scheduled queues/tails, hazards, Q/P landing: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckRegisterKernels;
type
  TState = record
    A, B, Acc, R: TPS2Reg128;
    Status: UInt64;
  end;
  PState = ^TState;
const
  Edges: array[0..11] of Cardinal = (0, $80000000, 1, $807FFFFF, $00800000,
    $3F800000, $BF800000, $7F800000, $7FFFFFFF, $FF800000, $FFFFFFFF, $01000001);
var
  S: TState;
  Seed: UInt64;

  function Rnd: Cardinal;
  begin
    Seed := Seed xor (Seed shl 13); Seed := Seed xor (Seed shr 7); Seed := Seed xor (Seed shl 17);
    Result := Cardinal(Seed);
  end;

  function ProgramFor(J: TJitAsm; Kind: TPS2RegisterMath): Pointer;
  begin
    J.Align(16);
    Result := J.Here;
    J.Enter;
    J.VectorLoad(jv0, JMem(jrSelf, Integer(NativeUInt(@PState(nil).A))));
    J.VectorLoad(jv1, JMem(jrSelf, Integer(NativeUInt(@PState(nil).B))));
    J.VectorCall(PS2RegisterMathNative(Kind), PS2RegisterMathModel(Kind), JCtx);
    J.VectorStore(JMem(jrSelf, Integer(NativeUInt(@PState(nil).R))), jv0);
    J.Move(jw64, JMem(jrSelf, Integer(NativeUInt(@PState(nil).Status))), JT0);
    J.Leave(JImm(0));
    J.Flush;
  end;

begin
  var Model := CreateJitModel(1 shl 20);
  var Native := CreateJitAsm(1 shl 20);
  var SavedMode := GetRoundMode;
  {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  var SavedControl := GetMXCSR;
  {$ENDIF}
  try
    if (Native <> nil) and (not Native.HasVectors or (PS2RegisterMathNative(vrmAdd) = nil)) then
      FreeAndNil(Native);
    Seed := $123456789ABCDEF;
    var Vectors, Flagged: Int64;
    Vectors := 0; Flagged := 0;
    for var Kind := Low(TPS2RegisterMath) to High(TPS2RegisterMath) do
    begin
      var M := ProgramFor(Model, Kind);
      var N: Pointer := nil;
      if Native <> nil then N := ProgramFor(Native, Kind);
      for var Control := 0 to 4 do
      begin
        {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
        SetMXCSR(SavedControl);
        {$ENDIF}
        var Mode := rmTruncate;
        if Control < 4 then Mode := TRoundingMode(Control);
        SetRoundMode(Mode);
        {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
        if Control = 4 then SetMXCSR(GetMXCSR or $8040);
        {$ENDIF}
        for var Sample := 0 to 19999 do
        begin
          for var K := 0 to 3 do
          begin
            S.A.UW[K] := Rnd;
            S.B.UW[K] := Rnd;
            if Sample and 1 = 0 then
            begin
              S.A.UW[K] := (Rnd and $807FFFFF) or ((96 + Rnd mod 64) shl 23);
              S.B.UW[K] := (Rnd and $807FFFFF) or ((96 + Rnd mod 64) shl 23);
            end;
            var FM: Cardinal;
            var Product := PS2FloatMul(S.A.UW[K], S.B.UW[K], FM);
            S.Acc.UW[K] := Rnd;
            if Sample mod 4 = 0 then S.Acc.UW[K] := Edges[(Sample + K) mod Length(Edges)];
            if Sample mod 4 = 2 then S.Acc.UW[K] := Product xor $80000000;
          end;
          if Sample mod 16 = 0 then
          begin
            S.A.UW[0] := $7FFFFFFF; S.B.UW[0] := $7FFFFFFF;
            S.A.UW[1] := $00800001; S.B.UW[1] := $80800000;
            S.A.UW[2] := $80000000; S.B.UW[2] := $80000000;
          end;
          var Initial := S;
          Model.Invoke(M, NativeUInt(@S), NativeUInt(@S.Acc), 0, 0);
          var Expected := S;
          if Native <> nil then
          begin
            S := Initial;
            Native.Invoke(N, NativeUInt(@S), NativeUInt(@S.Acc), 0, 0);
            if (S.Status <> Expected.Status) or not CompareMem(@S.R, @Expected.R, SizeOf(S.R)) then
              raise Exception.CreateFmt('Register kernel/model mismatch kind=%d mode=%d sample=%d',
                [Ord(Kind), Ord(Mode), Sample]);
          end;
          var ExpectedFlags: UInt64 := 0;
          for var K := 0 to 3 do
          begin
            var F: Cardinal;
            var V: Cardinal;
            if Kind = vrmAdd then V := PS2FloatAdd(S.A.UW[K], S.B.UW[K], F)
            else V := PS2FloatMul(S.A.UW[K], S.B.UW[K], F);
            if S.R.UW[K] <> V then
              raise Exception.CreateFmt('Register kernel/scalar mismatch kind=%d sample=%d', [Ord(Kind), Sample]);
            if F and 1 <> 0 then ExpectedFlags := ExpectedFlags or (UInt64(1) shl (15 - K));
            if F and 2 <> 0 then ExpectedFlags := ExpectedFlags or (UInt64(1) shl (11 - K));
          end;
          if S.Status <> ExpectedFlags then raise Exception.Create('Register kernel scalar OU mismatch');
          Inc(Vectors);
          if S.Status <> 0 then Inc(Flagged);
        end;
      end;
    end;
    if (Vectors = 0) or (Flagged = 0) then raise Exception.Create('Register kernel paths were not exercised');
    Writeln('register kernels: exact native/model/scalar values and OU, four rounding modes, FTZ/DAZ OK');
  finally
    {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
    SetMXCSR(SavedControl);
    {$ENDIF}
    SetRoundMode(SavedMode);
    Native.Free; Model.Free;
  end;
end;

{$Q-}{$R-} // (The operand generator wraps on purpose.)
// The routines a VU run picks for its host rounding (PS2RegisterMathNativeFor):
// the truncating and round-to-nearest fast paths and their exact fallbacks,
// with and without FTZ/DAZ, against the scalar reference: random operands
// over all exponents, close magnitudes and cancellation, and products and
// sums that are exact or halfway between two floats.
procedure CheckRoundingKernels;
type
  TState = record
    A, B, R: TPS2Reg128;
    Status: UInt64;
  end;
  PState = ^TState;
var
  S: TState;
  Seed: UInt64;

  function Rnd: Cardinal;
  begin
    Seed := Seed xor (Seed shl 13); Seed := Seed xor (Seed shr 7); Seed := Seed xor (Seed shl 17);
    Result := Cardinal(Seed);
  end;

  function Operand(Other: Cardinal): Cardinal;
  begin
    case Rnd mod 8 of
      0: Result := Rnd;
      1: Result := (Rnd and $807FFFFF) or ((Rnd mod 256) shl 23);
      2: Result := Other xor (Rnd and $80000007);
      3: Result := (Other and $FF800000) or (Rnd and $7FFFFF);
      4: Result := ((Other and $7F800000) + ((Rnd mod 50) shl 23) - (25 shl 23)) or (Rnd and $807FFFFF);
      // Few mantissa bits: exact products and sums, and halfway cases.
      5: Result := (Rnd and $FF800000) or ((Rnd and $FFF) shl 11);
      6: Result := (Rnd and $FF800000) or (Rnd and $7) or ((Rnd and 1) shl 22);
    else
      Result := (Rnd and $807FFFFF) or ((40 + Rnd mod 200) shl 23);
    end;
  end;

begin
  {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  var Native := CreateJitAsm(1 shl 20);
  if (Native = nil) or not Native.HasVectors or (PS2RegisterMathNative(vrmAdd) = nil) then
  begin
    Native.Free;
    Writeln('rounding kernels: no native vector backend, skipped');
    Exit;
  end;
  var SavedControl := GetMXCSR;
  try
    Seed := $FEDCBA9876543210;
    var Count: Int64 := 0;
    for var Kind := Low(TPS2RegisterMath) to High(TPS2RegisterMath) do
      for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
      begin
        Native.Align(16);
        var Code := Native.Here;
        Native.Enter;
        Native.VectorLoad(jv0, JMem(jrSelf, Integer(NativeUInt(@PState(nil).A))));
        Native.VectorLoad(jv1, JMem(jrSelf, Integer(NativeUInt(@PState(nil).B))));
        Native.VectorCall(PS2RegisterMathNativeFor(Kind, Mode), PS2RegisterMathModel(Kind), JImm(0));
        Native.VectorStore(JMem(jrSelf, Integer(NativeUInt(@PState(nil).R))), jv0);
        Native.Move(jw64, JMem(jrSelf, Integer(NativeUInt(@PState(nil).Status))), JT0);
        Native.Leave(JImm(0));
        Native.Flush;
        for var Flush := False to True do
        begin
          SetMXCSR(SavedControl);
          SetRoundMode(Mode);
          if Flush then SetMXCSR(GetMXCSR or $8040);
          for var Sample := 0 to 399999 do
          begin
            for var K := 0 to 3 do
            begin
              S.A.UW[K] := Operand(Rnd);
              S.B.UW[K] := Operand(S.A.UW[K]);
            end;
            Native.Invoke(Code, NativeUInt(@S), 0, 0, 0);
            var Flags: UInt64 := 0;
            for var K := 0 to 3 do
            begin
              var F: Cardinal;
              var V: Cardinal;
              if Kind = vrmAdd then V := PS2FloatAdd(S.A.UW[K], S.B.UW[K], F)
              else V := PS2FloatMul(S.A.UW[K], S.B.UW[K], F);
              if S.R.UW[K] <> V then
                raise Exception.CreateFmt('Rounding kernel mismatch kind=%d mode=%d ftz=%d: %.8x, %.8x -> %.8x <> %.8x',
                  [Ord(Kind), Ord(Mode), Ord(Flush), S.A.UW[K], S.B.UW[K], S.R.UW[K], V]);
              if F and 1 <> 0 then Flags := Flags or (UInt64(1) shl (15 - K));
              if F and 2 <> 0 then Flags := Flags or (UInt64(1) shl (11 - K));
            end;
            if S.Status <> Flags then
              raise Exception.CreateFmt('Rounding kernel OU mismatch kind=%d mode=%d', [Ord(Kind), Ord(Mode)]);
            Inc(Count);
          end;
        end;
      end;
    Writeln('rounding kernels: per-mode fast paths, ', Count, ' vectors in four rounding modes with/without FTZ/DAZ OK');
  finally
    SetMXCSR(SavedControl);
    Native.Free;
  end;
  {$ELSE}
  Writeln('rounding kernels: no native vector backend, skipped');
  {$ENDIF}
end;
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ENDIF}

procedure CheckVectorAliasFallback(Model: Boolean);
var
  Code0, Code1, Memory0, Memory1: TMemory;
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
begin
  for var AliasKind := 0 to 3 do
  begin
    FillChar(Code0, SizeOf(Code0), 0); FillChar(Code1, SizeOf(Code1), 0);
    FillChar(Memory0, SizeOf(Memory0), 0); FillChar(Memory1, SizeOf(Memory1), 0);
    FillChar(VF0, SizeOf(VF0), 0); FillChar(VF1, SizeOf(VF1), 0);
    FillChar(VI0, SizeOf(VI0), 0); FillChar(VI1, SizeOf(VI1), 0);
    var VA: PPS2VFArray := @VF0; var VB: PPS2VFArray := @VF1;
    var IA: PPS2VIArray := @VI0; var IB: PPS2VIArray := @VI1;
    var DA: Pointer := @Memory0; var DB: Pointer := @Memory1;
    var At := 2;
    case AliasKind of
      0: begin VA := @Memory0; VB := @Memory1; end;
      1: begin IA := @Memory0[256]; IB := @Memory1[256]; At := 65; end;
      2: begin DA := @Code0; DB := @Code1; At := 128; end;
      3: begin IA := @VF0; IB := @VF1; end;
    end;
    var A := TPS2VUCore.Create(1, VA, IA, @Code0, DA, SizeOf(Code0), SizeOf(Memory0));
    var B := TPS2VUCore.Create(1, VB, IB, @Code1, DB, SizeOf(Code1), SizeOf(Memory1));
    try
      if Model then B.UseJitModel else B.UseJit := True;
      for var K := 0 to 15 do
      begin
        Code0[K * 2 + 1] := $28 or (3 shl 6) or (1 shl 11) or (2 shl 16) or ($F shl 21);
        Code0[K * 2] := ($01 shl 25) or ($F shl 21) or (3 shl 11) or Cardinal(At);
      end;
      Code0[29] := Code0[29] or $40000000;
      Code1 := Code0;
      for var RepeatIndex := 0 to 39 do
      begin
        for var R := 1 to 31 do
          for var K := 0 to 3 do VA[R].UW[K] := $3F000000 + Cardinal((R * 16 + K + RepeatIndex) shl 8);
        VB^ := VA^;
        A.NoteCodeWritten; B.NoteCodeWritten; A.Start(0); B.Start(0);
        A.Run(128); B.Run(128);
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(VA, VB, SizeOf(VF0)) or
          not CompareMem(IA, IB, SizeOf(VI0)) or not CompareMem(DA, DB, SizeOf(Memory0)) then
          raise Exception.CreateFmt('Aliased hardware-buffer fallback mismatch model=%s kind=%d',
            [BoolToStr(Model, True), AliasKind]);
      end;
      if B.JitVectorOps <> 0 then raise Exception.Create('Aliased buffers used register-result generation');
    finally
      A.Free; B.Free;
    end;
  end;
  Writeln('model=', Model, ' data/register/code aliasing keeps memory-result fallback: OK');
end;

// COP2 macro operations: compiled (MacroNative) against the interpreter's,
// random arithmetic (and others, which fall back) with random masks and
// registers in every host rounding.
procedure CheckMacro(Model: Boolean);
var
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
  Code, Data: TMemory;
begin
  FillChar(Code, SizeOf(Code), 0);
  FillChar(Data, SizeOf(Data), 0);
  var A := TPS2VUCore.Create(0, @VF0, @VI0, @Code, @Data, SizeOf(Code), SizeOf(Data));
  var B := TPS2VUCore.Create(0, @VF1, @VI1, @Code, @Data, SizeOf(Code), SizeOf(Data));
  var SavedMode := GetRoundMode;
  try
    if Model then B.UseJitModel else B.UseJit := True;
    RandSeed := 4242;
    var Ops := 0;
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      for var Round := 0 to 199 do
      begin
        FillChar(VI0, SizeOf(VI0), 0);
        for var K := 1 to 31 do
          for var C := 0 to 3 do
            if Random(4) = 0 then
              VF0[K].UW[C] := Cardinal(Random(MaxInt)) xor (Cardinal(Random(2)) shl 31)
            else
              VF0[K].UW[C] := (Cardinal(Random($800000))) or (Cardinal(100 + Random(56)) shl 23) or
                (Cardinal(Random(2)) shl 31);
        VF1 := VF0;
        VI1 := VI0;
        A.S.ACC := VF0[1 + Random(31)];
        A.S.Q := VF0[1 + Random(31)].UW[Random(4)];
        A.S.I := VF0[1 + Random(31)].UW[Random(4)];
        B.S := A.S;
        for var N := 0 to 63 do
        begin
          var Op: Cardinal := $4A000000 or (Cardinal(Random(16)) shl 21) or (Cardinal(Random(32)) shl 16) or
            (Cardinal(Random(32)) shl 11) or (Cardinal(Random(32)) shl 6);
          if Random(3) = 0 then
            Op := Op or $3C or Cardinal(Random(4)) // special forms (ACC, conversions, ...)
          else
            Op := Op or Cardinal(Random($30));
          if (Op and $3F) >= $3C then
            // Keep the special forms to the upper ones (fd field < 12).
            Op := (Op and not Cardinal($7C0)) or (Cardinal(Random(12)) shl 6);
          A.Macro(Op);
          B.Macro(Op);
          Inc(Ops);
          if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VF0, @VF1, SizeOf(VF0)) then
            raise Exception.CreateFmt('Macro mismatch model=%s mode=%d op=%.8x', [BoolToStr(Model, True), Ord(Mode), Op]);
        end;
      end;
    end;
    Writeln('model=', Model, ' macro operations=', Ops, ' compiled/interpreted, four rounding modes: OK');
  finally
    SetRoundMode(SavedMode);
    A.Free;
    B.Free;
  end;
end;
procedure CheckConversionClipPipeline(Model: Boolean);
const
  Edges: array[0..15] of Cardinal = (0, $80000000, 1, $807FFFFF,
    $00800000, $3F800000, $BF800000, $4EFFFFFF, $4F000000, $CF000000,
    $7F800000, $7FFFFFFF, $FF800000, $FFFFFFFF, $01000001, $80000001);
var
  Code0, Code1, Data0, Data1: TMemory;
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
begin
  FillChar(Code0, SizeOf(Code0), 0); FillChar(Code1, SizeOf(Code1), 0);
  FillChar(Data0, SizeOf(Data0), 0); FillChar(Data1, SizeOf(Data1), 0);
  FillChar(VF0, SizeOf(VF0), 0); FillChar(VF1, SizeOf(VF1), 0);
  FillChar(VI0, SizeOf(VI0), 0); FillChar(VI1, SizeOf(VI1), 0);
  var A := TPS2VUCore.Create(1, @VF0, @VI0, @Code0, @Data0, SizeOf(Code0), SizeOf(Data0));
  var B := TPS2VUCore.Create(1, @VF1, @VI1, @Code1, @Data1, SizeOf(Code1), SizeOf(Data1));
  var Saved := GetRoundMode;
  try
    if Model then B.UseJitModel else B.UseJit := True;
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      for var ProgramIndex := 0 to 15 do
      begin
        A.Reset; B.Reset;
        for var K := 0 to 15 do
        begin
          var Special := Cardinal($10 + ((ProgramIndex + K) and 7));
          if K mod 4 = 0 then Special := $1F;
          var Fs := Cardinal(1 + K mod 3);
          var Ft := Cardinal((ProgramIndex + K) mod 5); // Includes vf0 and source/target aliasing.
          var Mask := Cardinal((ProgramIndex + K) and 15);
          Code0[K * 2 + 1] := $3C or ((Special shr 2) shl 6) or (Special and 3) or
            (Fs shl 11) or (Ft shl 16) or (Mask shl 21);
          Code0[K * 2] := $10020000;
          if K mod 4 = 1 then Code0[K * 2] := (Cardinal($1C) shl 25) or (3 shl 16); // FCGET.
          if K mod 4 = 2 then Code0[K * 2] := (Ft shl 16) or (Mask shl 21); // LQ collides with upper destination.
          if K mod 8 = 7 then Code0[K * 2] := (Cardinal($11) shl 25) or $543210; // FCSET.
        end;
        Code0[29] := Code0[29] or $40000000;
        Code1 := Code0;
        for var RepeatIndex := 0 to 39 do
        begin
          for var R := 1 to 31 do
            for var K := 0 to 3 do VF0[R].UW[K] := Edges[(R + K + RepeatIndex) mod Length(Edges)];
          VF1 := VF0;
          for var K := 0 to High(Data0) do Data0[K] := Edges[(K + RepeatIndex) mod Length(Edges)];
          Data1 := Data0;
          A.NoteCodeWritten; B.NoteCodeWritten; A.Start(0); B.Start(0);
          A.S.Clip := $123456; A.S.ClipBase := $ABCDEF;
          A.S.ClipQCount := RepeatIndex mod 5;
          for var K := 0 to 3 do
          begin
            A.S.ClipQValue[K] := Cardinal($100000 + RepeatIndex * 16 + K);
            A.S.ClipQReady[K] := A.S.Cycles + K + 1;
            if RepeatIndex and 1 <> 0 then Inc(A.S.ClipQReady[K], 50);
          end;
          B.S := A.S;
          while A.S.Running do
          begin
            var Budget := 1 + RepeatIndex mod 7;
            if RepeatIndex mod 3 = 0 then Budget := 256;
            A.Run(Budget); B.Run(Budget);
            if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VF0, @VF1, SizeOf(VF0)) or
              not CompareMem(@VI0, @VI1, SizeOf(VI0)) or
              not CompareMem(@A.LoopTrace, @B.LoopTrace, SizeOf(A.LoopTrace)) then
              raise Exception.CreateFmt('Conversion/CLIP pipeline mismatch model=%s mode=%d program=%d repeat=%d',
                [BoolToStr(Model, True), Ord(Mode), ProgramIndex, RepeatIndex]);
          end;
        end;
      end;
    end;
    if B.JitRuns = 0 then raise Exception.Create('Conversion/CLIP test did not enter generated code');
    Writeln('model=', Model, ' conversion masks/aliases, CLIP queue/tails and FCGET/FCSET, four rounding modes: OK');
  finally
    SetRoundMode(Saved);
    A.Free; B.Free;
  end;
end;

// VU0 programs waiting in loops for the EE (on VI1, through a VF register,
// a data word, with flags, I-bit pairs, R or a VF result; 2, 3 and 4 pairs a
// turn) under a random EE: VF/VI/data/code/control writes, macro operations,
// VCALLMS and syncs. Known loops' turns taken without running them
// (SpinSkips) leave every register, memory and cycle count as running them
// does.
procedure CheckSpinSkips(Jit: Boolean);
const
  LowerNop = $8000033C;
  UpperNop = $000002FF;
  Loops: array[0..9] of Cardinal = ($100, $200, $300, $400, $500, $600, $700, $800, $900, $A00);
var
  CodeA, CodeB, DataA, DataB, Original: TMemory;

  function Branch(Op, It, Source: Cardinal; Imm: Integer): Cardinal;
  begin
    Result := (Op shl 25) or (It shl 16) or (Source shl 11) or (Cardinal(Imm) and $7FF);
  end;

  procedure Pair(Address, Lower, Upper: Cardinal);
  begin
    CodeA[Address div 4] := Lower;
    CodeA[Address div 4 + 1] := Upper;
  end;

  // After a loop: clear VI1, add VF1 into VF4 and store it, then back to the
  // loop at Loop if VI3 is set (clearing it), else the end.
  procedure Tail(Address, Loop: Cardinal);
  begin
    Pair(Address, $80000032 or (1 shl 16), $01E00128 or (1 shl 16) or (4 shl 11) or (4 shl 6));
    Pair(Address + 8, (1 shl 25) or ($F shl 21) or (4 shl 11) or 8, UpperNop);
    Pair(Address + 16, Branch($29, 3, 0, (Integer(Loop) - Integer(Address + 16) - 8) div 8), UpperNop);
    Pair(Address + 24, $80000032 or (3 shl 16), UpperNop);
    Pair(Address + 32, LowerNop, UpperNop or $40000000);
    Pair(Address + 40, LowerNop, UpperNop);
  end;

begin
  FillChar(CodeA, SizeOf(CodeA), 0);
  FillChar(DataA, SizeOf(DataA), 0);
  // 4 pairs on VI1, as games do: IBNE out, B back.
  Pair($100, Branch($29, 1, 0, 3), UpperNop);
  Pair($108, LowerNop, UpperNop);
  Pair($110, Branch($20, 0, 0, -3), UpperNop);
  Pair($118, LowerNop, UpperNop);
  Tail($120, $100);
  // 2 pairs: IBEQ to itself.
  Pair($200, Branch($28, 1, 0, -1), UpperNop);
  Pair($208, LowerNop, UpperNop);
  Tail($210, $200);
  // 3 pairs.
  Pair($300, LowerNop, UpperNop);
  Pair($308, Branch($28, 1, 0, -2), UpperNop);
  Pair($310, LowerNop, UpperNop);
  Tail($318, $300);
  // On a data word (ILW.x vi1, 0(vi0)): never skipped.
  Pair($400, (4 shl 25) or (8 shl 21) or (1 shl 16), UpperNop);
  Pair($408, Branch($28, 1, 0, -2), UpperNop);
  Pair($410, LowerNop, UpperNop);
  Tail($418, $400);
  // (4 pairs from here on: VF data handed over may skip them.)
  // On VF5.x (MTIR vi1, vf5x): VF data releases it.
  Pair($500, $800003FC or (1 shl 16) or (5 shl 11), UpperNop);
  Pair($508, LowerNop, UpperNop);
  Pair($510, Branch($28, 1, 0, -3), UpperNop);
  Pair($518, LowerNop, UpperNop);
  Tail($520, $500);
  // ADDA.xyzw ACC, vf6, vf0 each turn, 8 pairs (its flags land in the turn).
  Pair($600, LowerNop, $01E0003C or (6 shl 11) or ($0A shl 6));
  for var K := 1 to 5 do
    Pair($600 + Cardinal(K) * 8, LowerNop, UpperNop);
  Pair($630, Branch($28, 1, 0, -7), UpperNop);
  Pair($638, LowerNop, UpperNop);
  Tail($640, $600);
  // An I-bit pair (I := 1.0).
  Pair($700, $3F800000, UpperNop or $80000000);
  Pair($708, LowerNop, UpperNop);
  Pair($710, Branch($28, 1, 0, -3), UpperNop);
  Pair($718, LowerNop, UpperNop);
  Tail($720, $700);
  // RNEXT with no fields (R moves on each turn).
  Pair($800, $8000043C, UpperNop);
  Pair($808, LowerNop, UpperNop);
  Pair($810, Branch($28, 1, 0, -3), UpperNop);
  Pair($818, LowerNop, UpperNop);
  Tail($820, $800);
  // MOVE.x vf1, vf2 (a VF result each turn, which the tail reads).
  Pair($900, $8000033C or (8 shl 21) or (1 shl 16) or (2 shl 11), UpperNop);
  Pair($908, LowerNop, UpperNop);
  Pair($910, Branch($28, 1, 0, -3), UpperNop);
  Pair($918, LowerNop, UpperNop);
  Tail($920, $900);
  // MULi.x vf3, vf2, I (reads VF2, writes VF3 and the flags).
  Pair($A00, LowerNop, $0100001E or (2 shl 11) or (3 shl 6));
  Pair($A08, LowerNop, UpperNop);
  Pair($A10, Branch($28, 1, 0, -3), UpperNop);
  Pair($A18, LowerNop, UpperNop);
  Tail($A20, $A00);
  Original := CodeA;
  CodeB := CodeA;
  DataB := DataA;
  var A := TPS2VU0.Create(@CodeA, @DataA);
  var B := TPS2VU0.Create(@CodeB, @DataB);
  try
    A.Core.UseJit := Jit;
    B.Core.UseJit := Jit;
    RandSeed := 7919;
    var Ops := 0;
    for var Round := 0 to 299 do
    begin
      var Loop := Loops[Random(Length(Loops))];
      for var N := 0 to 299 do
      begin
        // (Everything drawn before either core takes it.)
        var R := Random(100);
        if N = 0 then R := 0;
        var NewLoop := Loops[Random(Length(Loops))];
        var Again := Cardinal(Random(2));
        // (VF5.x and data word 0 are what two of the loops wait on; VF2 and
        // VF6 what others read.)
        var Reg := 1 + Random(7);
        case Random(5) of
          0: Reg := 5;
          1: Reg := 2;
          2: Reg := 6;
        end;
        var Field := Random(4);
        if Random(2) = 0 then Field := 0;
        var Value := Cardinal(Random(MaxInt));
        if Random(2) = 0 then Value := Cardinal(Random(2));
        var Word := Random(2) * Random(64);
        var Control := Random(6);
        var Macro: Cardinal := $4A000000 or ($F shl 21) or (Cardinal(Random(8)) shl 16) or
          (Cardinal(Random(8)) shl 11) or (Cardinal(1 + Random(7)) shl 6) or $28;
        var CodeWord := (Loop + Cardinal(Random(3)) * 8) div 4 + 1;
        // Back to the original, else an upper NOP or ADD.x vf7, vf0, vf7.
        var NewUpper: Cardinal := Original[CodeWord];
        case Random(3) of
          0: NewUpper := UpperNop;
          1: NewUpper := $01000028 or (7 shl 16) or (7 shl 6);
        end;
        if R < 4 then Loop := NewLoop;
        for var V in TArray<TPS2VU0>.Create(A, B) do
        begin
          SpinSkips := V = A;
          var Code: ^TMemory := @CodeA;
          var Data: ^TMemory := @DataA;
          if V = B then begin Code := @CodeB; Data := @DataB; end;
          case R of
            0..3:
              begin
                // VCALLMS at a loop (VI1 clear: it waits; VI3 set: it waits
                // again after the tail).
                V.WriteControl(1, 0);
                V.WriteControl(3, Again);
                V.Execute($4A000038 or ((Loop shr 3) shl 6));
              end;
            4..33:
              begin
                // (As the EE's QMTC2 and LQC2: marked.)
                V.VF[Reg].UW[Field] := Value;
                V.VFWritten := V.VFWritten or (Cardinal(1) shl Reg);
              end;
            34..47: V.WriteControl(1 + Reg mod 3, Value and 1);
            48..57: Data^[Word] := Value;
            58..60:
              begin
                Code^[CodeWord] := NewUpper;
                V.Core.NoteCodeWritten;
              end;
            61..64:
              case Control of
                0: V.WriteControl(16, Value);
                1: V.WriteControl(18, Value);
                2: V.WriteControl(20, Value);
                3: V.WriteControl(21, Value);
                4: V.WriteControl(22, Value);
              else
                V.WriteControl(4, Value);
              end;
            65..68: V.Execute(Macro);
          else
            V.Sync;
          end;
        end;
        SpinSkips := True;
        Inc(Ops);
        if not CompareMem(@A.Core.S, @B.Core.S, SizeOf(A.Core.S)) or not CompareMem(@A.VF, @B.VF, SizeOf(A.VF)) or
          not CompareMem(@A.VI, @B.VI, SizeOf(A.VI)) or not CompareMem(@DataA, @DataB, SizeOf(DataA)) or
          not CompareMem(@CodeA, @CodeB, SizeOf(CodeA)) or (A.Core.Executed <> B.Core.Executed) then
          raise Exception.CreateFmt('Spin skip mismatch jit=%s round=%d op=%d loop=%x r=%d',
            [BoolToStr(Jit, True), Round, N, Loop, R]);
      end;
    end;
    if (A.SkippedTurns = 0) or (B.SkippedTurns <> 0) then
      raise Exception.CreateFmt('Spin loops not skipped (%d, %d)', [A.SkippedTurns, B.SkippedTurns]);
    Writeln(Format('jit=%s %d EE operations on waiting VU0 programs (%d pairs), %d loop turns skipped: OK',
      [BoolToStr(Jit, True), Ops, A.Core.Executed, A.SkippedTurns]));
  finally
    SpinSkips := True;
    A.Free;
    B.Free;
  end;
end;

begin
  try
    SetExceptionMask(exAllArithmeticExceptions);
    CheckRegisterKernels;
    CheckRoundingKernels;
    SetRoundMode(rmTruncate);
    Check(False);
    Check(True);
    CheckVersions(False);
    CheckVersions(True);
    CheckScheduled(False);
    CheckScheduled(True);
    CheckConversionClipPipeline(False);
    CheckConversionClipPipeline(True);
    CheckVectorAliasFallback(False);
    CheckVectorAliasFallback(True);
    CheckMacro(False);
    CheckMacro(True);
    CheckSpinSkips(False);
    CheckSpinSkips(True);
    SetRoundMode(rmNearest);
    Check(False);
    Check(True);
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
