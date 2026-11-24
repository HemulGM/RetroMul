program PS2VUSelectTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, PS2.Types, PS2.VU, PS2.VU.Float, PS2.EE.CPU, HW.JIT;

type
  TMemory = array[0..4095] of Cardinal;

procedure CheckSelectKernels;
type
  TState = record
    A, B, R: TPS2Reg128;
    Status: NativeUInt;
  end;
  PState = ^TState;
const
  Edges: array[0..31] of Cardinal = (0, $80000000, 1, $80000001, $007FFFFF, $807FFFFF,
    $00800000, $80800000, $3F800000, $BF800000, $3F800001, $BF800001, $3F7FFFFF, $BF7FFFFF,
    $7F7FFFFF, $FF7FFFFF, $7F800000, $FF800000, $7FFFFFFF, $FFFFFFFF, $7FC00001, $FFC00001,
    $3F000000, $BF000000, $40000000, $C0000000, $01000000, $81000000, $7E800000, $FE800000,
    $00012345, $80012345);
var
  S: TState;
  Seed: UInt64;

  function Rnd: Cardinal;
  begin
    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 7);
    Seed := Seed xor (Seed shl 17);
    Result := Cardinal(Seed);
  end;

  function ProgramFor(J: TJitAsm; Maximum: Boolean): Pointer;
  begin
    J.ForgetLabels;
    J.Align(16);
    Result := J.Here;
    J.Enter;
    J.VectorLoad(jv0, JMem(jrSelf, Integer(NativeUInt(@PState(nil).A))));
    J.VectorLoad(jv1, JMem(jrSelf, Integer(NativeUInt(@PState(nil).B))));
    J.VectorCall(PS2RegisterSelectNative(Maximum), PS2RegisterSelectModel(Maximum), JImm(0));
    J.VectorStore(JMem(jrSelf, Integer(NativeUInt(@PState(nil).R))), jv0);
    J.Move(jw64, JMem(jrSelf, Integer(NativeUInt(@PState(nil).Status))), JT0);
    J.Leave(JImm(0));
    J.Flush;
  end;

begin
  var Model := CreateJitModel(1 shl 20);
  var Native := CreateJitAsm(1 shl 20);
  if (Native <> nil) and (not Native.HasVectors or (PS2RegisterSelectNative(False) = nil)) then
    FreeAndNil(Native);
  var SavedMode := GetRoundMode;
  var SavedControl := GetMXCSR;
  Seed := $123456789ABCDEF;
  var Vectors := 0;
  try
    for var Maximum := False to True do
    begin
      var M := ProgramFor(Model, Maximum);
      var N: Pointer := nil;
      if Native <> nil then
        N := ProgramFor(Native, Maximum);
      for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
        for var Flush := 0 to 1 do
        begin
          SetRoundMode(Mode);
          SetMXCSR((GetMXCSR and not Cardinal($8040)) or (Cardinal(Flush) * $8040));
          for var Sample := 0 to 65535 do
          begin
            for var K := 0 to 3 do
              if Sample < 1024 then
              begin
                S.A.UW[K] := Edges[(Sample + K) and 31];
                S.B.UW[K] := Edges[((Sample shr 5) + K * 3) and 31];
              end
              else
              begin
                S.A.UW[K] := Rnd;
                S.B.UW[K] := Rnd;
              end;
            Model.Invoke(M, NativeUInt(@S), 0, 0, 0);
            var Expected := S;
            for var K := 0 to 3 do
            begin
              var Value := S.B.UW[K];
              if Maximum then
              begin
                if PS2FloatKey(S.A.UW[K]) >= PS2FloatKey(Value) then
                  Value := S.A.UW[K];
              end
              else if PS2FloatKey(S.A.UW[K]) <= PS2FloatKey(Value) then
                Value := S.A.UW[K];
              if S.R.UW[K] <> Value then
                raise Exception.Create('Select model differs from scalar key');
            end;
            if Native <> nil then
            begin
              var Control := GetMXCSR;
              Native.Invoke(N, NativeUInt(@S), 0, 0, 0);
              if not CompareMem(@S.R, @Expected.R, SizeOf(S.R)) or (S.Status <> 0) or (GetMXCSR <> Control) then
                raise Exception.CreateFmt('Select native mismatch max=%s mode=%d flush=%d sample=%d',
                  [BoolToStr(Maximum, True), Ord(Mode), Flush, Sample]);
            end;
            Inc(Vectors);
          end;
        end;
    end;
    Writeln('select kernel vectors=', Vectors, ' scalar/model/native SAME, MXCSR unchanged; native=', Native <> nil);
  finally
    SetRoundMode(SavedMode);
    SetMXCSR(SavedControl);
    Model.Free;
    Native.Free;
  end;
end;

procedure CheckSelections(Model: Boolean);
const
  // MAX/MIN vector, component and I forms, plus ABS (destination is ft).
  Functions: array[0..12] of Cardinal = ($10, $11, $12, $13, $1D, $2B,
    $14, $15, $16, $17, $1F, $2F, $1FD);
  Edges: array[0..31] of Cardinal = (0, $80000000, 1, $80000001, $007FFFFF,
    $807FFFFF, $00800000, $80800000, $3F800000, $BF800000, $3F800001, $BF800001,
    $3F7FFFFF, $BF7FFFFF, $7F7FFFFF, $FF7FFFFF, $7F800000, $FF800000,
    $7FFFFFFF, $FFFFFFFF, $7FC00001, $FFC00001, $3F000000, $BF000000,
    $40000000, $C0000000, $01000000, $81000000, $7E800000, $FE800000,
    $00012345, $80012345);
var
  Code0, Code1, Data0, Data1: TMemory;
  VF0, VF1: TPS2VFArray;
  VI0, VI1: TPS2VIArray;
begin
  var SavedMode := GetRoundMode;
  var Cases := 0;
  try
    for var AliasKind := 0 to 4 do
    begin
      FillChar(Code0, SizeOf(Code0), 0);
      FillChar(Code1, SizeOf(Code1), 0);
      FillChar(Data0, SizeOf(Data0), 0);
      FillChar(Data1, SizeOf(Data1), 0);
      FillChar(VF0, SizeOf(VF0), 0);
      FillChar(VF1, SizeOf(VF1), 0);
      FillChar(VI0, SizeOf(VI0), 0);
      FillChar(VI1, SizeOf(VI1), 0);
      var VA: PPS2VFArray := @VF0;
      var VB: PPS2VFArray := @VF1;
      var IA: PPS2VIArray := @VI0;
      var IB: PPS2VIArray := @VI1;
      var DA: Pointer := @Data0;
      var DB: Pointer := @Data1;
      case AliasKind of
        1:
          begin
            VA := @Data0;
            VB := @Data1;
          end;
        2:
          begin
            IA := @Data0[256];
            IB := @Data1[256];
          end;
        3:
          begin
            DA := @Code0;
            DB := @Code1;
          end;
        4:
          begin
            IA := @VF0;
            IB := @VF1;
          end;
      end;
      var A := TPS2VUCore.Create(1, VA, IA, @Code0, DA, SizeOf(Code0), SizeOf(Data0));
      var B := TPS2VUCore.Create(1, VB, IB, @Code1, DB, SizeOf(Code1), SizeOf(Data1));
      try
        if Model then
          B.UseJitModel
        else
          B.UseJit := True;
        for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
        begin
          SetRoundMode(Mode);
          for var Funct in Functions do
            for var Mask := 0 to 15 do
              for var Sample := 0 to High(Edges) do
              begin
                // The opcode changes with Sample. Reach the two-visit JIT
                // heat threshold for this exact pair before changing it.
                for var Attempt := 0 to 2 do
                begin
                  A.Reset;
                  B.Reset;
                  for var R := 1 to 31 do
                    for var K := 0 to 3 do
                      VA[R].UW[K] := Edges[(Sample + R * 7 + K * 3) and 31];
                  for var R := 1 to 31 do
                    IA[R] := Cardinal((Sample + R) and 15);
                  VB^ := VA^;
                  IB^ := IA^;
                  A.S.I := Edges[(Sample * 3) and 31];
                  B.S := A.S;
                  var Fs := 1;
                  var Ft := 2;
                  var Fd := 3;
                  case Sample and 3 of
                    1:
                      Fs := Fd;
                    2:
                      Ft := Fd;
                    3:
                      begin
                        Fs := 0;
                        Fd := 0;
                      end;
                  end;
                  var U := Funct or (Cardinal(Fs) shl 11) or (Cardinal(Ft) shl 16) or
                    (Cardinal(Mask) shl 21) or $40000000;
                  if Funct <> $1FD then
                    U := U or (Cardinal(Fd) shl 6);
                  // Both halves can write the same register; upper wins only
                  // its selected lanes and must read the old sources first.
                  var LowerDest := Fd;
                  if Funct = $1FD then
                    LowerDest := Ft;
                  Code0[0] := $8000033C or ($F shl 21) or (4 shl 11) or (Cardinal(LowerDest) shl 16);
                  Code0[1] := U;
                  Code0[2] := $8000033C;
                  Code0[3] := $000002FF;
                  Code1 := Code0;
                  A.NoteCodeWritten;
                  B.NoteCodeWritten;
                  A.Start(0);
                  B.Start(0);
                  var Budget := 64;
                  if Odd(Sample) then
                    Budget := 1;
                  while A.S.Running do
                  begin
                    A.Run(Budget);
                    B.Run(Budget);
                    if not CompareMem(@A.S, @B.S, SizeOf(A.S)) or not CompareMem(VA, VB, SizeOf(VF0)) or
                      not CompareMem(IA, IB, SizeOf(VI0)) or not CompareMem(DA, DB, SizeOf(Data0)) or
                      not CompareMem(@Code0, @Code1, SizeOf(Code0)) then
                      raise Exception.CreateFmt('Selection mismatch model=%s alias=%d mode=%d funct=%x mask=%x sample=%d',
                        [BoolToStr(Model, True), AliasKind, Ord(Mode), Funct, Mask, Sample]);
                  end;
                  if B.S.Running then
                    raise Exception.Create('Selection did not terminate');
                  Inc(Cases);
                end;
              end;
        end;
        if B.JitRuns = 0 then
          raise Exception.Create('No generated selection pairs executed');
        if AliasKind = 0 then
        begin
          if (PS2RegisterSelectNative(False) <> nil) and (B.JitVectorOps = 0) then
            raise Exception.Create('New selection emitter was not exercised');
        end
        else if B.JitVectorOps <> 0 then
          raise Exception.Create('Aliased layout used the new selection emitter');
      finally
        A.Free;
        B.Free;
      end;
    end;
    Writeln('model=', Model, ' selection cases=', Cases,
      ' all masks/forms, edge bit patterns, overlapping halves, aliases and four rounding modes: OK');
  finally
    SetRoundMode(SavedMode);
  end;
end;

begin
  try
    SetExceptionMask(exAllArithmeticExceptions);
    CheckSelectKernels;
    CheckSelections(False);
    CheckSelections(True);
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
