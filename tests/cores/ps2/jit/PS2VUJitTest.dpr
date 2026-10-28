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
  UpperFunctions: array[0..7] of Cardinal = ($28, $2C, $2A, $2B, $2F, $00, $18, $1D);
  LowerFunctions: array[0..4] of Cardinal = ($30, $31, $32, $34, $35);
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
        Code0[K * 2] := Lo;
        var Hi := UpperFunctions[Random(Length(UpperFunctions))] or (Rd shl 6) or
          (Rs shl 11) or (Rt shl 16) or (Mask shl 21);
        if K mod 5 = 0 then Hi := $000002FF; // NOP
        if K mod 7 = 0 then Hi := $000001FD or (Rs shl 11) or (Rt shl 16) or (Mask shl 21); // ABS
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
            not CompareMem(@A.LoopTrace, @B.LoopTrace, SizeOf(A.LoopTrace)) or (A.Executed <> B.Executed) then
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
    Writeln('model=', Model, ' programs=100 generated pairs=', B.JitRuns, ' blocks=', B.JitBlocks, ' kicks=40 OK');
  finally
    A.Free;
    B.Free;
  end;
end;

begin
  try
    SetExceptionMask(exAllArithmeticExceptions);
    SetRoundMode(rmTruncate);
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
