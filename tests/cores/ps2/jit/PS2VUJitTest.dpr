program PS2VUJitTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, PS2.Types, PS2.VU;

type
  TMemory = array[0..4095] of Cardinal;
  TKickProbe = class
    Core: TPS2VUCore;
    Code: PCardinal;
    Count: Integer;
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
end;

procedure Check(Model: Boolean);
const
  UpperFunctions: array[0..19] of Cardinal = ($28, $2C, $2A, $2B, $2F, $00, $18, $1D,
    $04, $08, $0C, $1C, $1E, $20, $21, $22, $23, $24, $25, $2E);
  LowerFunctions: array[0..4] of Cardinal = ($30, $31, $32, $34, $35);
  UpperSpecial: array[0..22] of Cardinal = ($00, $04, $08, $0C, $10, $11, $12, $13,
    $14, $15, $16, $17, $18, $1C, $1D, $1E, $1F, $20, $21, $28, $29, $2D, $2E);
  LowerSpecial: array[0..20] of Cardinal = ($30, $31, $34, $35, $36, $37, $38, $39,
    $3A, $3B, $3C, $3D, $3E, $3F, $40, $41, $42, $43, $64, $68, $69);
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
    for var ProgramIndex := 0 to 99 do
    begin
      // Re-upload at the same addresses: compiled entries must be replaced.
      for var K := 0 to 63 do
      begin
        var Rs := Cardinal(Random(16));
        var Rt := Cardinal(Random(16));
        var Rd := Cardinal(Random(16));
        var Mask := Cardinal(Random(16));
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
        A.Start(0); B.Start(0);
        A.Run(128); B.Run(128);
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
    if (B.JitBlocks = 0) or (B.JitRuns <= B.JitBlocks) then
      raise Exception.Create('Generated code did not execute multiple pairs per block');
    Writeln('model=', Model, ' programs=100 generated pairs=', B.JitRuns, ' entries=', B.JitBlocks,
      ' compiles=', B.JitCompiles, ' resets=', B.JitResets, ' reused=', B.JitCacheHits, ' kicks=40 OK');
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
      Code0[29] := Code0[29] or $40000000;
      if Odd(Round) then
      begin
        Code0[0] := Code0[0] xor 1;
        Code0[2] := Code0[2] xor $400000;
      end;
      Code1 := Code0;
      for var RepeatIndex := 0 to 31 do
      begin
        A.Start(0); B.Start(0);
        A.Run(64); B.Run(64);
        if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(@VF0, @VF1, SizeOf(VF0)) then
          raise Exception.CreateFmt('Version collision model=%s round=%d repeat=%d',
            [BoolToStr(Model, True), Round, RepeatIndex]);
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
      A.Start(0); B.Start(0);
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

begin
  try
    SetExceptionMask(exAllArithmeticExceptions);
    SetRoundMode(rmTruncate);
    Check(False);
    Check(True);
    CheckVersions(False);
    CheckVersions(True);
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
