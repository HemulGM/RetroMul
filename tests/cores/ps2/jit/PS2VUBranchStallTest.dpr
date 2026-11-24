program PS2VUBranchStallTest;

{$APPTYPE CONSOLE}

// Only an unstalled immediately following branch observes the old VI value.
uses
  System.SysUtils, PS2.Types, PS2.VU;

type
  TMemory = array[0..4095] of Cardinal;

const
  LowerNop = $8000033C;
  UpperNop = $000002FF;
  BranchOps: array[0..7] of Cardinal = ($28, $28, $29, $29, $2C, $2D, $2E, $2F);
  OldValues: array[0..2] of Integer = (-1, 0, 1);
  NewValues: array[0..2] of Integer = (0, 1, -1);

procedure PutPair(var Code: TMemory; PC, Lower, Upper: Cardinal);
begin
  Code[PC div 4] := Lower;
  Code[PC div 4 + 1] := Upper;
end;

function Add(Dest, Source, Mask: Cardinal): Cardinal;
begin
  Result := (Mask shl 21) or (Source shl 11) or (Dest shl 6) or $28;
end;

function Branch(Op, Source, Other: Cardinal; Offset: Integer): Cardinal;
begin
  Result := (Op shl 25) or (Other shl 16) or (Source shl 11) or (Cardinal(Offset) and $7FF);
end;

function Taken(Op: Cardinal; Value: Integer): Boolean;
begin
  case Op of
    $28:
      Result := Value = 0;
    $29:
      Result := Value <> 0;
    $2C:
      Result := Value < 0;
    $2D:
      Result := Value > 0;
    $2E:
      Result := Value <= 0;
  else
    Result := Value >= 0;
  end;
end;

procedure Configure(Core: TPS2VUCore; Mode: Integer);
begin
  Core.UseJit := Mode <> 0;
  if Mode = 2 then
    Core.UseJitModel;
  if Mode = 3 then
    SetLength(Core.RunTrace, 16000);
end;

procedure CheckBranch(Mode, Kind, Age, Overlap, Writer, Values: Integer; var Checks: Integer);
var
  Code, Data: TMemory;
  VF: TPS2VFArray;
  VI: TPS2VIArray;
begin
  FillChar(Code, SizeOf(Code), 0);
  FillChar(Data, SizeOf(Data), 0);
  for var Index := 0 to High(Code) div 2 do
    PutPair(Code, Cardinal(Index * 8), LowerNop, UpperNop);
  PutPair(Code, 0, LowerNop, Add(2, 0, 8));
  var WriteOp: Cardinal := $80000030 or (2 shl 11) or (1 shl 6);
  case Writer of
    1:
      WriteOp := $80000031 or (2 shl 11) or (1 shl 6);
    2:
      WriteOp := $10000000 or (1 shl 16) or (2 shl 11);
  end;
  var WriteUpper := UpperNop;
  if Age = 0 then
    WriteUpper := Add(2, 0, 8);
  PutPair(Code, Cardinal(Age * 8), WriteOp, WriteUpper);
  var Source: Cardinal := 1;
  var Other: Cardinal := 0;
  if (Kind < 4) and Odd(Kind) then
  begin
    Source := 0;
    Other := 1;
  end;
  var ReadMask: Cardinal := 4;
  if Overlap <> 0 then
    ReadMask := 8;
  var PC := Cardinal((Age + 1) * 8);
  PutPair(Code, PC, Branch(BranchOps[Kind], Source, Other, 4), Add(3, 2, ReadMask));
  PutPair(Code, PC + 16, $10050002, UpperNop);
  PutPair(Code, PC + 24, Branch($20, 0, 0, 2), UpperNop);
  PutPair(Code, PC + 40, $10050001, UpperNop);
  PutPair(Code, PC + 48, LowerNop, UpperNop or $40000000);
  var Core := TPS2VUCore.Create(1, @VF, @VI, @Code, @Data, SizeOf(Code), SizeOf(Data));
  try
    Configure(Core, Mode);
    var Value := OldValues[Values];
    if (Overlap <> 0) and (Age < 3) then
      Value := NewValues[Values];
    var Expected: Cardinal := 2;
    if Taken(BranchOps[Kind], Value) then
      Expected := 1;
    for var RepeatIndex := 0 to 7 do
    begin
      FillChar(VF, SizeOf(VF), 0);
      FillChar(VI, SizeOf(VI), 0);
      VF[0].UW[3] := $3F800000;
      VI[1] := Cardinal(65536 + OldValues[Values]) and $FFFF;
      VI[2] := Cardinal(65536 + NewValues[Values]) and $FFFF;
      Core.RunTraceCount := 0;
      Core.Start(0);
      if not Core.Run(1000) then
        raise Exception.Create('Branch program did not finish');
      if VI[5] <> Expected then
        raise Exception.CreateFmt('mode=%d branch=%d age=%d overlap=%d writer=%d old=%d new=%d: %d expected %d',
          [Mode, Kind, Age, Overlap, Writer, OldValues[Values], NewValues[Values], VI[5], Expected]);
      Inc(Checks);
    end;
    if (Mode <> 0) and (Core.JitRuns = 0) then
      raise Exception.Create('JIT branch path was not exercised');
    if (Mode in [1, 2]) and (Core.JitFastPairs = 0) then
      raise Exception.Create('Scheduled branch path was not exercised');
  finally
    Core.Free;
  end;
end;

procedure CheckLoop(Mode, Overlap, Count, Budget: Integer; var Checks: Integer);
var
  Code, Data: TMemory;
  VF: TPS2VFArray;
  VI: TPS2VIArray;
begin
  FillChar(Code, SizeOf(Code), 0);
  FillChar(Data, SizeOf(Data), 0);
  var Mask: Cardinal := 4;
  if Overlap <> 0 then
    Mask := 8;
  PutPair(Code, 0, $80010FF2, Add(2, 0, 8));
  PutPair(Code, 8, Branch($2D, 1, 0, -2), Add(3, 2, Mask));
  PutPair(Code, 16, $80052872, UpperNop);
  PutPair(Code, 24, LowerNop, UpperNop or $40000000);
  PutPair(Code, 32, LowerNop, UpperNop);
  var Core := TPS2VUCore.Create(1, @VF, @VI, @Code, @Data, SizeOf(Code), SizeOf(Data));
  try
    Configure(Core, Mode);
    var Turns := Count + 1;
    if Overlap <> 0 then
      Turns := Count;
    if Turns = 0 then
      Turns := 1;
    for var RepeatIndex := 0 to 7 do
    begin
      FillChar(VF, SizeOf(VF), 0);
      FillChar(VI, SizeOf(VI), 0);
      VF[0].UW[3] := $3F800000;
      VI[1] := Cardinal(Count);
      Core.RunTraceCount := 0;
      Core.Start(0);
      var Before := Core.S.Cycles;
      var Calls := 0;
      repeat
        Inc(Calls);
        Core.Run(Budget);
      until not Core.S.Running or (Calls > 1000);
      if Core.S.Running or (VI[5] <> Cardinal(Turns)) then
        raise Exception.CreateFmt('Loop mode=%d overlap=%d count=%d budget=%d: %d expected %d',
          [Mode, Overlap, Count, Budget, VI[5], Turns]);
      var ExpectedCycles := Int64(Turns * 3 + 2);
      if Overlap <> 0 then
        Inc(ExpectedCycles, Turns * 3);
      if Core.S.Cycles - Before <> ExpectedCycles then
        raise Exception.CreateFmt('Loop timing: %d expected %d', [Core.S.Cycles - Before, ExpectedCycles]);
      Inc(Checks);
    end;
  finally
    Core.Free;
  end;
end;

procedure Run;
begin
  var Checks := 0;
  for var Mode := 0 to 3 do
  begin
    for var Kind := 0 to High(BranchOps) do
      for var Age := 0 to 3 do
        for var Overlap := 0 to 1 do
          for var Writer := 0 to 2 do
            for var Values := 0 to High(OldValues) do
              CheckBranch(Mode, Kind, Age, Overlap, Writer, Values, Checks);
    for var Overlap := 0 to 1 do
      for var Count in [0, 1, 2, 8] do
      begin
        CheckLoop(Mode, Overlap, Count, 1, Checks);
        CheckLoop(Mode, Overlap, Count, 1000, Checks);
      end;
  end;
  Writeln('VU branch VI results mature during FMAC stalls: ', Checks,
    ' interpreter/native/model/general, overlap, delay and loop checks: OK');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
