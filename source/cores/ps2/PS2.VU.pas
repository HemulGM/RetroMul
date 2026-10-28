unit PS2.VU;

// Vector units: the VU core shared by VU0 and VU1 (FMAC upper instructions,
// lower integer/load-store/branch/flag/EFU instructions, Q and P with their
// latencies, MAC/status/clip flags), micro-mode execution of 64-bit
// instruction pairs up to the E bit, VU0 as EE coprocessor 2 (macro mode,
// VCALLMS/VCALLMSR, control registers) and XGKICK to GIF PATH1 from VU1.
// Floats follow the PS2 rules of the FPU (no infinity/NaN, exponent 255 is a
// number, round toward zero, denormals as zero).
// References: VU User's Manual (PS2 Linux Kit), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types, PS2.EE.CPU, PS2.VU.Float, HW.JIT;

type
  TPS2VFArray = array[0..31] of TPS2Reg128;
  PPS2VFArray = ^TPS2VFArray;
  TPS2VIArray = array[0..31] of Cardinal;
  PPS2VIArray = ^TPS2VIArray;

  // An XGKICK packet as the GIF took it (Data) from VU memory at Address.
  TPS2VUKick = procedure(Address: Cardinal; Data: PByte) of object;

  TPS2VUState = record
    ACC: TPS2Reg128;
    Q, P, I, R: Cardinal;
    Status, MAC, Clip: Cardinal;
    TPC: Cardinal;
    // Pending Q/P results and the pairs until they land.
    PendingQ, PendingP: Cardinal;
    QDelay, PDelay: Integer;
    Running: Boolean;
    // Branch in flight (taken after the next pair) and E bit seen.
    BranchPending, EndPending: Boolean;
    BranchTarget: Cardinal;
    Cycles: Int64;
    // Clip flag as FC* instructions see it: CLIP results land four cycles
    // after issue (FMAC latency); queued until then.
    ClipBase: Cardinal;
    ClipQValue: array[0..3] of Cardinal;
    ClipQReady: array[0..3] of Int64;
    ClipQCount: Integer;
    // MAC and status flags as FM*/FS* instructions see them, the same way.
    MACBase, StatusBase: Cardinal;
    FlagQMAC, FlagQStatus: array[0..3] of Cardinal;
    FlagQReady: array[0..3] of Int64;
    FlagQCount: Integer;
  end;

  // The VF registers an instruction writes and reads, with field masks.
  TPS2VURegUse = record
    Dest, S1, S2: Integer;
    DestMask, M1, M2: Cardinal;
  end;

  // A pair decoded once: its words (it is decoded again when they differ),
  // the registers its halves read and write (none for the lower half of an
  // I-bit pair) and whether its upper op sets the MAC and status flags.
  TPS2VUPair = record
    Lower, Upper: Cardinal;
    Valid, SetsFlags, NativeCandidate: Boolean;
    U, L: TPS2VURegUse;
    Native: Pointer;
    Heat: Integer;
  end;
  PPS2VUPair = ^TPS2VUPair;

  // Per Run call, shared by interpreted pairs and generated blocks. Nothing
  // here persists across calls or belongs in a save state.
  TPS2VURun = record
    Count, Limit: Integer;
    PC, Target: Cardinal;
    Pair: PPS2VUPair;
    Branching, Ending, Invalid: Boolean;
  end;
  PPS2VURun = ^TPS2VURun;

  TPS2VUCore = class
  private
    FIndex: Integer;
    FVF: PPS2VFArray;
    FVI: PPS2VIArray;
    FCode, FData: PByte;
    FCodeMask, FDataMask: Cardinal;
    FOnKick: TPS2VUKick;
    // A VI register the current pair's integer unit writes and its value
    // before; a branch in the next pair sees that older value (FBranchReg,
    // FBranchOld). -1: none.
    FLoadReg, FBranchReg: Integer;
    FLoadOld, FBranchOld: Cardinal;
    // XGKICK in progress: the GIF takes quadword K of the packet at
    // FKickStart + 2K (VU cycles; FKickStart includes the latency), into
    // FKickBuf; FKickNextTag is the next GIF tag's position, FKickEnd the
    // packet's length once its EOP tag is in (-1 before).
    FKickPending: Boolean;
    FKickAddress: Cardinal;
    FKickStart: Int64;
    FKickCount, FKickNextTag, FKickEnd: Integer;
    FKickBuf: array of TPS2Reg128;
    // The clip flag the current pair's FC* instructions see.
    FClipVisible: Cardinal;
    // Cycle from which each VF register field (x..w) holds its pending result.
    FReady: array[0..31, 0..3] of Int64;
    // The latest of a register's four (nothing pending once S.Cycles reaches it).
    FReadyAny: array[0..31] of Int64;
    // Results of the current pair (written after both halves ran).
    FUpperReg, FLowerReg: Integer;
    FUpperValue, FLowerValue: TPS2Reg128;
    FUpperMask, FLowerMask: Cardinal;
    FPairs: array of TPS2VUPair;
    FJit: TJitAsm;
    FUseJit: Boolean;
    FJitRuns: Int64;
    FJitBlocks: Int64;
    function CompileBlock(PC: Cardinal): Pointer;
    procedure EmitPair(const P: TPS2VUPair);
    procedure PreparePair(var Run: TPS2VURun); inline;
    procedure FinishPair(var Run: TPS2VURun); inline;
    function DecodedPair(PC, LowerOp, UpperOp: Cardinal): PPS2VUPair; inline;
    procedure DecodePair(var P: TPS2VUPair; LowerOp, UpperOp: Cardinal);
    procedure UpperRegs(Op: Cardinal; out R: TPS2VURegUse);
    procedure LowerRegs(Op: Cardinal; out R: TPS2VURegUse);
    function ReadyAt(Reg: Integer; Mask: Cardinal): Int64;
    function HazardStall(const P: TPS2VUPair): Integer;
    procedure NoteWrites(const P: TPS2VUPair);
    procedure AdvanceCycles(N: Integer);
    function UpperSetsFlags(Op: Cardinal): Boolean;
    procedure SetFlags(const R: TPS2Reg128; Dest: Cardinal; Flags: Cardinal);
    procedure Upper(Op: Cardinal; Micro: Boolean);
    procedure Lower(Op: Cardinal);
    procedure LowerSpecial(Op: Cardinal);
    procedure CommitVF(Reg: Integer; const V: TPS2Reg128; Dest: Cardinal);
    function DataAddress(Base: Cardinal): PPS2Reg128; inline;
    function Bc(const V: TPS2Reg128; Op: Cardinal): Cardinal; inline;
    procedure StartKick(Address: Cardinal);
    procedure TakeKick(All: Boolean);
  public
    S: TPS2VUState;
    // Micro instructions executed (diagnostics).
    Executed: Int64;
    // Diagnostics: the last pairs of a run that hit its limit.
    LoopTrace: array[0..63] of Cardinal;
    // Diagnostics: when assigned, the PC and VI1-15 before each of the first
    // pairs of the current run (16 words per pair).
    RunTrace: TArray<Word>;
    RunTraceCount: Integer;
    constructor Create(Index: Integer; VF: PPS2VFArray; VI: PPS2VIArray; Code, Data: PByte;
      CodeSize, DataSize: Cardinal);
    destructor Destroy; override;
    // Experimental block compiler; timing and pipeline commits stay shared.
    property UseJit: Boolean read FUseJit write FUseJit;
    property JitRuns: Int64 read FJitRuns;
    property JitBlocks: Int64 read FJitBlocks;
    // Select the portable generator model before running a differential test.
    procedure UseJitModel;
    procedure Reset;
    // A macro instruction (VU0 COP2, bit 25 set): True when it is one.
    function Macro(Op: Cardinal): Boolean;
    // Starts a micro program at Address (in 8-byte units times 8) and runs
    // it to its end (at most MaxPairs pairs; False when it is still running).
    procedure Start(Address: Cardinal);
    function Run(MaxPairs: Integer): Boolean;
    procedure SerializeState(State: TStateArchive);
    property VF: PPS2VFArray read FVF;
    property VI: PPS2VIArray read FVI;
    property Data: PByte read FData;
    property Code: PByte read FCode;
    property OnKick: TPS2VUKick read FOnKick write FOnKick;
  end;

  // VU0 as coprocessor 2 of the EE.
  TPS2VU0 = class(TEECop2)
  private
    FCore: TPS2VUCore;
    FVU1: TPS2VUCore;
    FCMSAR1Start: TProc<Cardinal>;
    // The micro program spins waiting for the EE; FBlockVF/FBlockVI are the
    // registers then (it stays blocked while they stay so).
    FBlocked: Boolean;
    FBlockVF: array[0..31] of TPS2Reg128;
    FBlockVI: array[0..15] of Cardinal;
    procedure RunUntilBlocked;
    function Spins: Boolean;
  public
    constructor Create(Code, Data: PByte);
    destructor Destroy; override;
    procedure Reset; override;
    function ReadControl(Index: Integer): Cardinal; override;
    procedure WriteControl(Index: Integer; Value: Cardinal); override;
    function Execute(Op: Cardinal): Boolean; override;
    procedure Interlock; override;
    procedure Sync; override;
    function Condition: Boolean; override;
    procedure SerializeState(State: TStateArchive); override;
    property Core: TPS2VUCore read FCore;
    property VU1: TPS2VUCore read FVU1 write FVU1;
    // CTC2 to CMSAR1 starts VU1.
    property OnStartVU1: TProc<Cardinal> read FCMSAR1Start write FCMSAR1Start;
  end;

  // VU1 with its own registers.
  TPS2VU1 = class
  private
    FVF: TPS2VFArray;
    FVI: TPS2VIArray;
    FCore: TPS2VUCore;
  public
    constructor Create(Code, Data: PByte);
    destructor Destroy; override;
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    property Core: TPS2VUCore read FCore;
  end;

implementation

const
  // dest bits: x = 8, y = 4, z = 2, w = 1 (instruction bits 24..21).
  DestX = 8;
  DestY = 4;
  DestZ = 2;
  DestW = 1;
  // VU cycles from an XGKICK to the GIF's first read of the packet: a store
  // to the packet in the next two pairs goes out with it, one in the third
  // pair does not.
  KickLatency = 3;

function FieldBit(K: Integer): Cardinal; inline;
begin
  // Field index 0..3 (x..w) to its dest bit.
  Result := Cardinal(8) shr K;
end;

{ TPS2VUCore }

constructor TPS2VUCore.Create(Index: Integer; VF: PPS2VFArray; VI: PPS2VIArray; Code, Data: PByte;
  CodeSize, DataSize: Cardinal);
begin
  inherited Create;
  FIndex := Index;
  FVF := VF;
  FVI := VI;
  FCode := Code;
  FData := Data;
  FCodeMask := CodeSize - 1;
  FDataMask := DataSize - 1;
  SetLength(FPairs, CodeSize div 8);
  Reset;
end;

destructor TPS2VUCore.Destroy;
begin
  FJit.Free;
  inherited;
end;

procedure TPS2VUCore.UseJitModel;
begin
  FreeAndNil(FJit);
  for var K := 0 to High(FPairs) do
  begin
    FPairs[K].Native := nil;
    FPairs[K].Heat := 0;
  end;
  FJit := CreateJitModel(8 * 1024 * 1024);
  FUseJit := True;
end;

function TPS2VUCore.CompileBlock(PC: Cardinal): Pointer;
begin
  Result := nil;
  if FJit = nil then
    FJit := CreateJitAsm(8 * 1024 * 1024);
  if FJit = nil then
    Exit;
  if not FJit.Room(16 * 4096) then
  begin
    // No generated function is running here. Re-uploaded microprograms may
    // replace every pair, so bound the cache rather than retaining old code.
    FJit.Reset;
    for var K := 0 to High(FPairs) do
      FPairs[K].Native := nil;
  end;
  var J := FJit;
  J.ForgetLabels;
  J.Align(16);
  Result := J.Here;
  J.Enter;
  var Done := J.NewLabel;
  var Stale := J.NewLabel;
  var Last := False;
  for var K := 0 to 15 do
  begin
    var LowerOp := PCardinal(FCode + PC)^;
    var UpperOp := PCardinal(FCode + PC + 4)^;
    var P := DecodedPair(PC, LowerOp, UpperOp);
    // Guard every pair, not just the block entry. A callback can replace
    // code while a block is running, and a small budget may end anywhere.
    J.Move(jw8, JT0, JMem(jrSelf, Integer(NativeInt(@S.Running) - NativeInt(Self))));
    J.Branch(jcEq, jw32, JT0, JImm(0), Done);
    J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Count))));
    J.Branch(jcGe, jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Limit))), Done);
    J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@S.TPC) - NativeInt(Self))));
    J.Alu(jaAnd, jw32, JT0, JImm(FCodeMask));
    J.Branch(jcNe, jw32, JT0, JImm(PC), Done);
    J.Move(jw64, JT0, JMem(jrSelf, Integer(NativeInt(@FCode) - NativeInt(Self))));
    J.Branch(jcNe, jw32, JMem(jrT0, Integer(PC)), JImm(LowerOp), Stale);
    J.Branch(jcNe, jw32, JMem(jrT0, Integer(PC + 4)), JImm(UpperOp), Stale);
    J.Move(jw64, JT1, JImm(NativeInt(P)));
    // Another block may have decoded this address since this one was
    // compiled. Its cached hazard/flag metadata must agree as well.
    J.Branch(jcNe, jw32, JMem(jrT1, Integer(NativeUInt(@PPS2VUPair(nil).Lower))), JImm(LowerOp), Stale);
    J.Branch(jcNe, jw32, JMem(jrT1, Integer(NativeUInt(@PPS2VUPair(nil).Upper))), JImm(UpperOp), Stale);
    J.Move(jw32, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))), JImm(PC));
    J.Move(jw64, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Pair))), JT1);
    J.Call(@TPS2VUCore.PreparePair, [JSelf, JCtx]);
    EmitPair(P^);
    J.Call(@TPS2VUCore.FinishPair, [JSelf, JCtx]);
    if Last then Break;
    // End after the delay pair of a branch or E-bit pair. Conditional
    // branches return to the dispatcher on either outcome.
    Last := (UpperOp and $40000000) <> 0;
    if (UpperOp and $80000000) = 0 then
      Last := Last or ((LowerOp shr 25) in [$20, $21, $24, $25, $28, $29, $2C..$2F]);
    PC := (PC + 8) and FCodeMask;
  end;
  J.Jump(Done);
  J.Bind(Stale);
  J.Move(jw8, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Invalid))), JImm(1));
  J.Bind(Done);
  J.Leave(JImm(0));
  J.ForgetLabels;
  J.Flush;
end;

procedure TPS2VUCore.EmitPair(const P: TPS2VUPair);
begin
  var J := FJit;
  // Floating-point arithmetic still uses the interpreter's PS2-specific
  // operations. NOP needs no call; all commits happen after both halves.
  var U := P.Upper;
  var Funct := U and $3F;
  var Special := ((U shr 4) and $7C) or (U and 3);
  var IsAbs := (Funct >= $3C) and (Special = $1D);
  var IsMax := (Funct in [$10..$13, $1D, $2B]);
  var IsMin := (Funct in [$14..$17, $1F, $2F]);
  if IsAbs or IsMax or IsMin then
  begin
    var Fs := Integer((U shr 11) and 31);
    var Ft := Integer((U shr 16) and 31);
    var Target := Integer((U shr 6) and 31);
    if IsAbs then Target := Ft;
    J.Move(jw64, JT6, JMem(jrSelf, Integer(NativeInt(@FVF) - NativeInt(Self))));
    for var K := 0 to 3 do
    begin
      J.Move(jw32, JT0, JMem(jrT6, Fs * 16 + K * 4));
      if IsAbs then
        J.Alu(jaAnd, jw32, JT0, JImm($7FFFFFFF))
      else
      begin
        if Funct in [$1D, $1F] then
          J.Move(jw32, JT1, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))))
        else if Funct in [$2B, $2F] then
          J.Move(jw32, JT1, JMem(jrT6, Ft * 16 + K * 4))
        else
          J.Move(jw32, JT1, JMem(jrT6, Ft * 16 + Integer(U and 3) * 4));
        // PS2FloatKey: invert the magnitude of negative values, retaining
        // their sign bit. Signed comparison also distinguishes -0 from +0.
        J.Move(jw32, JT2, JT0);
        J.Move(jw32, JT3, JT1);
        var PositiveA := J.NewLabel;
        var PositiveB := J.NewLabel;
        var Selected := J.NewLabel;
        J.Branch(jcGe, jw32, JT2, JImm(0), PositiveA);
        J.Alu(jaXor, jw32, JT2, JImm($7FFFFFFF));
        J.Bind(PositiveA);
        J.Branch(jcGe, jw32, JT3, JImm(0), PositiveB);
        J.Alu(jaXor, jw32, JT3, JImm($7FFFFFFF));
        J.Bind(PositiveB);
        if IsMax then J.Branch(jcGe, jw32, JT2, JT3, Selected)
        else J.Branch(jcLe, jw32, JT2, JT3, Selected);
        J.Move(jw32, JT0, JT1);
        J.Bind(Selected);
      end;
      J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperValue) - NativeInt(Self)) + K * 4), JT0);
    end;
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperReg) - NativeInt(Self))), JImm(Target));
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperMask) - NativeInt(Self))), JImm((U shr 21) and 15));
  end
  else if not ((Funct >= $3C) and (Special = $2F)) then
    J.Call(@TPS2VUCore.Upper, [JSelf, JImm(U), JImm(1)]);
  if (U and $80000000) <> 0 then
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))), JImm(P.Lower))
  else
  begin
    var Op := P.Lower;
    var D := -1;
    var Is_ := Integer((Op shr 11) and 15);
    var It := Integer((Op shr 16) and 15);
    var Id := Integer((Op shr 6) and 15);
    var Alu := jaAdd;
    var Imm := 0;
    var Immediate := False;
    var Truncate16 := True;
    if (Op and $80000000) <> 0 then
      case Op and $3F of
        $30: D := Id;
        $31: begin D := Id; Alu := jaSub; end;
        $32:
          begin
            D := It;
            Immediate := True;
            Imm := Integer((Op shr 6) and 31);
            if Imm >= 16 then Dec(Imm, 32);
          end;
        $34: begin D := Id; Alu := jaAnd; Truncate16 := False; end;
        $35: begin D := Id; Alu := jaOr; Truncate16 := False; end;
      end
    else if (Op shr 25) in [$08, $09] then
    begin
      D := It;
      Immediate := True;
      Imm := Integer((Op and $7FF) or ((Op shr 10) and $7800));
      if (Op shr 25) = $09 then Alu := jaSub;
    end;
    if D > 0 then
    begin
      J.Move(jw64, JT2, JMem(jrSelf, Integer(NativeInt(@FVI) - NativeInt(Self))));
      J.Move(jw32, JT0, JMem(jrT2, Is_ * 4));
      if Immediate then
        J.Alu(Alu, jw32, JT0, JImm(Imm))
      else
        J.Alu(Alu, jw32, JT0, JMem(jrT2, It * 4));
      if Truncate16 then
        J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
      J.Move(jw32, JMem(jrT2, D * 4), JT0);
    end
    else if (D < 0) and ((Op shr 25) in [$00, $01, $04, $05]) then
    begin
      var Kind := Op shr 25;
      var Base := Is_;
      if Kind = $01 then Base := It;
      var Imm11 := Integer(Op and $7FF);
      if Imm11 >= $400 then Dec(Imm11, $800);
      J.Move(jw64, JT2, JMem(jrSelf, Integer(NativeInt(@FVI) - NativeInt(Self))));
      J.Move(jw32, JT0, JMem(jrT2, Base * 4));
      J.Alu(jaAdd, jw32, JT0, JImm(Imm11));
      J.Shift(jsShl, jw32, jrT0, 4);
      J.Alu(jaAnd, jw32, JT0, JImm(FDataMask));
      J.Move(jw64, JT3, JMem(jrSelf, Integer(NativeInt(@FData) - NativeInt(Self))));
      J.Alu(jaAdd, jw64, JT3, JT0);
      var Mask := (Op shr 21) and 15;
      case Kind of
        $00:
          begin
            // LQ stages all lanes, even the masked ones; common commit
            // code preserves upper/lower overlap and the VF00 constant.
            for var K := 0 to 3 do
            begin
              J.Move(jw32, JT0, JMem(jrT3, K * 4));
              J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FLowerValue) - NativeInt(Self)) + K * 4), JT0);
            end;
            J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FLowerReg) - NativeInt(Self))), JImm((Op shr 16) and 31));
            J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FLowerMask) - NativeInt(Self))), JImm(Mask));
          end;
        $01:
          begin
            J.Move(jw64, JT4, JMem(jrSelf, Integer(NativeInt(@FVF) - NativeInt(Self))));
            for var K := 0 to 3 do
              if (Mask and (8 shr K)) <> 0 then
              begin
                J.Move(jw32, JT0, JMem(jrT4, Integer((Op shr 11) and 31) * 16 + K * 4));
                J.Move(jw32, JMem(jrT3, K * 4), JT0);
              end;
          end;
        $04:
          if It <> 0 then
            for var K := 0 to 3 do
              if (Mask and (8 shr K)) <> 0 then
              begin
                J.Move(jw32, JT0, JMem(jrT3, K * 4));
                J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
                J.Move(jw32, JMem(jrT2, It * 4), JT0);
                Break;
              end;
        $05:
          begin
            J.Move(jw32, JT0, JMem(jrT2, It * 4));
            J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
            for var K := 0 to 3 do
              if (Mask and (8 shr K)) <> 0 then
                J.Move(jw32, JMem(jrT3, K * 4), JT0);
          end;
      end;
    end
    else if D < 0 then
      J.Call(@TPS2VUCore.Lower, [JSelf, JImm(Op)]);
  end;
end;

procedure TPS2VUCore.Reset;
begin
  S := Default(TPS2VUState);
  FKickPending := False;
  S.Q := $3F800000;
  S.R := $3F800000;
  FVF[0].UW[0] := 0;
  FVF[0].UW[1] := 0;
  FVF[0].UW[2] := 0;
  FVF[0].UW[3] := $3F800000;
end;

procedure TPS2VUCore.SetFlags(const R: TPS2Reg128; Dest: Cardinal; Flags: Cardinal);
begin
  // MAC: Z bits 0..3, S 4..7, U 8..11, O 12..15; bit 3 of each group is x.
  // Flags: bit K overflow and bit K + 4 underflow of field K.
  var M: Cardinal := 0;
  for var K := 0 to 3 do
    if (Dest and FieldBit(K)) <> 0 then
    begin
      var V := R.UW[K];
      var B := Cardinal(3 - K);
      if (V and $7FFFFFFF) = 0 then
        M := M or (Cardinal(1) shl B);
      if (V and $80000000) <> 0 then
        M := M or (Cardinal(1) shl (B + 4));
      if (Flags and (Cardinal(16) shl K)) <> 0 then
        M := M or (Cardinal(1) shl (B + 8));
      if (Flags and (Cardinal(1) shl K)) <> 0 then
        M := M or (Cardinal(1) shl (B + 12));
    end;
  S.MAC := M;
  var St := S.Status and $FF0;
  if (M and $F) <> 0 then
    St := St or 1;
  if (M and $F0) <> 0 then
    St := St or 2;
  if (M and $F00) <> 0 then
    St := St or 4;
  if (M and $F000) <> 0 then
    St := St or 8;
  St := St or ((St and $F) shl 6);
  S.Status := St;
end;

function TPS2VUCore.Bc(const V: TPS2Reg128; Op: Cardinal): Cardinal;
begin
  Result := V.UW[Op and 3];
end;

procedure TPS2VUCore.CommitVF(Reg: Integer; const V: TPS2Reg128; Dest: Cardinal);
begin
  if Reg = 0 then
    Exit;
  for var K := 0 to 3 do
    if (Dest and FieldBit(K)) <> 0 then
      FVF[Reg].UW[K] := V.UW[K];
end;

// Upper (FMAC) instruction: computes into FUpperValue/FUpperReg; the ACC
// forms write ACC directly at commit time (register 32).
procedure TPS2VUCore.Upper(Op: Cardinal; Micro: Boolean);
type
  TKind = (ukAdd, ukSub, ukMul, ukMadd, ukMsub, ukMax, ukMin, ukItof, ukFtoi, ukAbs, ukOpMula, ukOpMsub);
  // The second operand: ft's own field, ft's broadcast field, Q or I.
  TSource = (usVector, usBroadcast, usQ, usI);
var
  R: TPS2Reg128;
begin
  var Dest := (Op shr 21) and $F;
  var Ft := Integer((Op shr 16) and 31);
  var Fs := Integer((Op shr 11) and 31);
  var Fd := Integer((Op shr 6) and 31);
  FUpperReg := -1;
  var Funct := Op and $3F;
  var Target := Fd;
  var Kind: TKind;
  var Source := usBroadcast;
  if Funct >= $3C then
  begin
    // Special: ACC forms and conversions; index = fd field << 2 | bc.
    Funct := ((Op shr 4) and $7C) or (Op and 3);
    Target := 32;
    case Funct of
      $00..$03: Kind := ukAdd;
      $04..$07: Kind := ukSub;
      $08..$0B: Kind := ukMadd;
      $0C..$0F: Kind := ukMsub;
      $10..$13:
        begin
          Kind := ukItof;
          Target := Ft;
        end;
      $14..$17:
        begin
          Kind := ukFtoi;
          Target := Ft;
        end;
      $18..$1B: Kind := ukMul;
      $1C:
        begin
          Kind := ukMul;
          Source := usQ;
        end;
      $1D:
        begin
          Kind := ukAbs;
          Target := Ft;
        end;
      $1E:
        begin
          Kind := ukMul;
          Source := usI;
        end;
      $1F:
        begin
          // CLIP: |fs.xyz| against |ft.w|.
          var W := Abs(EEFloatIn(FVF[Ft].UW[3]));
          var C: Cardinal := 0;
          for var K := 0 to 2 do
          begin
            var V := EEFloatIn(FVF[Fs].UW[K]);
            if V > W then
              C := C or (Cardinal(1) shl (K * 2));
            if V < -W then
              C := C or (Cardinal(2) shl (K * 2));
          end;
          S.Clip := ((S.Clip shl 6) or C) and $FFFFFF;
          if Micro and (S.ClipQCount < 4) then
          begin
            S.ClipQValue[S.ClipQCount] := S.Clip;
            S.ClipQReady[S.ClipQCount] := S.Cycles + 4;
            Inc(S.ClipQCount);
          end
          else if not Micro then
            S.ClipBase := S.Clip;
          Exit;
        end;
      $20, $22, $24, $26:
        begin
          if Funct >= $24 then
            Kind := ukSub
          else
            Kind := ukAdd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $21, $23, $25, $27:
        begin
          if Funct >= $24 then
            Kind := ukMsub
          else
            Kind := ukMadd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $28, $29, $2A, $2C, $2D:
        begin
          case Funct of
            $28: Kind := ukAdd;
            $29: Kind := ukMadd;
            $2A: Kind := ukMul;
            $2C: Kind := ukSub;
          else
            Kind := ukMsub;
          end;
          Source := usVector;
        end;
      $2E:
        begin
          // OPMULA: ACC.xyz = fs.yzx * ft.zxy
          Kind := ukOpMula;
          Dest := Dest and $E;
        end;
    else
      // NOP and the undefined forms.
      Exit;
    end;
  end
  else
    case Funct of
      $00..$03: Kind := ukAdd;
      $04..$07: Kind := ukSub;
      $08..$0B: Kind := ukMadd;
      $0C..$0F: Kind := ukMsub;
      $10..$13: Kind := ukMax;
      $14..$17: Kind := ukMin;
      $18..$1B: Kind := ukMul;
      $1C:
        begin
          Kind := ukMul;
          Source := usQ;
        end;
      $1D:
        begin
          Kind := ukMax;
          Source := usI;
        end;
      $1E:
        begin
          Kind := ukMul;
          Source := usI;
        end;
      $1F:
        begin
          Kind := ukMin;
          Source := usI;
        end;
      $20, $22, $24, $26:
        begin
          if Funct >= $24 then
            Kind := ukSub
          else
            Kind := ukAdd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $21, $23, $25, $27:
        begin
          if Funct >= $24 then
            Kind := ukMsub
          else
            Kind := ukMadd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $28..$2D:
        begin
          case Funct of
            $28: Kind := ukAdd;
            $29: Kind := ukMadd;
            $2A: Kind := ukMul;
            $2B: Kind := ukMax;
            $2C: Kind := ukSub;
          else
            Kind := ukMsub;
          end;
          Source := usVector;
        end;
      $2E:
        begin
          // OPMSUB: fd.xyz = ACC.xyz - fs.yzx * ft.zxy
          Kind := ukOpMsub;
          Dest := Dest and $E;
        end;
      $2F:
        begin
          Kind := ukMin;
          Source := usVector;
        end;
    else
      Exit;
    end;
  // The arithmetic on all four fields at once (the fields not written are
  // dropped, with their flags); the rest field by field.
  var A := PPS2Reg128(@FVF[Fs]);
  var B := PPS2Reg128(@FVF[Ft]);
  var Other: TPS2Reg128;
  case Source of
    usVector: Other := B^;
    usBroadcast:
      begin
        var V := B.UW[Op and 3];
        Other.UW[0] := V;
        Other.UW[1] := V;
        Other.UW[2] := V;
        Other.UW[3] := V;
      end;
    usQ:
      begin
        Other.UW[0] := S.Q;
        Other.UW[1] := S.Q;
        Other.UW[2] := S.Q;
        Other.UW[3] := S.Q;
      end;
    usI:
      begin
        Other.UW[0] := S.I;
        Other.UW[1] := S.I;
        Other.UW[2] := S.I;
        Other.UW[3] := S.I;
      end;
  end;
  var F: Cardinal := 0;
  case Kind of
    ukAdd:
      PS2Add4(A^, Other, R, F);
    ukSub:
      begin
        Other.Lo := Other.Lo xor UInt64($8000000080000000);
        Other.Hi := Other.Hi xor UInt64($8000000080000000);
        PS2Add4(A^, Other, R, F);
      end;
    ukMul:
      PS2Mul4(A^, Other, R, F);
    ukMadd, ukMsub, ukOpMula, ukOpMsub:
      begin
        var M: TPS2Reg128;
        if Kind in [ukOpMula, ukOpMsub] then
        begin
          // fs.yzx * ft.zxy.
          var X: TPS2Reg128;
          X.UW[0] := A.UW[1];
          X.UW[1] := A.UW[2];
          X.UW[2] := A.UW[0];
          X.UW[3] := 0;
          Other.UW[0] := B.UW[2];
          Other.UW[1] := B.UW[0];
          Other.UW[2] := B.UW[1];
          Other.UW[3] := 0;
          PS2Mul4(X, Other, M, F);
        end
        else
          PS2Mul4(A^, Other, M, F);
        if Kind = ukOpMula then
          R := M
        else
        begin
          if Kind <> ukMadd then
          begin
            M.Lo := M.Lo xor UInt64($8000000080000000);
            M.Hi := M.Hi xor UInt64($8000000080000000);
          end;
          var F2: Cardinal;
          PS2Add4(S.ACC, M, R, F2);
          F := F or F2;
        end;
      end;
  else
    R := Default(TPS2Reg128);
    for var K := 0 to 3 do
    begin
      if (Dest and FieldBit(K)) = 0 then
        Continue;
      var V := Other.UW[K];
      case Kind of
        ukMax:
          if PS2FloatKey(A.UW[K]) >= PS2FloatKey(V) then
            R.UW[K] := A.UW[K]
          else
            R.UW[K] := V;
        ukMin:
          if PS2FloatKey(A.UW[K]) <= PS2FloatKey(V) then
            R.UW[K] := A.UW[K]
          else
            R.UW[K] := V;
        ukItof:
          begin
            // ITOF0/4/12/15: fixed point to float.
            var Scale: Double := 1;
            case Funct of
              $11: Scale := 1 / 16;
              $12: Scale := 1 / 4096;
              $13: Scale := 1 / 32768;
            end;
            var X: Single := A.SW[K] * Scale;
            R.UW[K] := PCardinal(@X)^;
          end;
        ukFtoi:
          begin
            var Scale: Double := 1;
            case Funct of
              $15: Scale := 16;
              $16: Scale := 4096;
              $17: Scale := 32768;
            end;
            var D := EEFloatIn(A.UW[K]) * Scale;
            if D >= 2147483647.0 then
              R.UW[K] := $7FFFFFFF
            else if D <= -2147483648.0 then
              R.UW[K] := $80000000
            else
              R.SW[K] := Trunc(D);
          end;
        ukAbs:
          R.UW[K] := A.UW[K] and $7FFFFFFF;
      end;
    end;
    FUpperReg := Target;
    FUpperValue := R;
    FUpperMask := Dest;
    Exit;
  end;
  SetFlags(R, Dest, F);
  FUpperReg := Target;
  FUpperValue := R;
  FUpperMask := Dest;
end;

function TPS2VUCore.DataAddress(Base: Cardinal): PPS2Reg128;
begin
  Result := PPS2Reg128(FData + ((Base shl 4) and FDataMask));
end;

function SignExt11(V: Cardinal): Integer; inline;
begin
  Result := Integer(V and $7FF);
  if (Result and $400) <> 0 then
    Result := Result - $800;
end;

// Lower instruction: integer results land at once; VF results in
// FLowerValue for the commit.
procedure TPS2VUCore.Lower(Op: Cardinal);
begin
  FLowerReg := -1;
  if (Op and $80000000) <> 0 then
  begin
    var Funct := Op and $3F;
    var It := Integer((Op shr 16) and 15);
    var Is_ := Integer((Op shr 11) and 15);
    var Id := Integer((Op shr 6) and 15);
    case Funct of
      $30: if Id <> 0 then FVI[Id] := Word(Integer(FVI[Is_]) + Integer(FVI[It]));
      $31: if Id <> 0 then FVI[Id] := Word(Integer(FVI[Is_]) - Integer(FVI[It]));
      $32:
        if It <> 0 then
        begin
          var Imm := Integer((Op shr 6) and 31);
          if (Imm and 16) <> 0 then
            Imm := Imm - 32;
          FVI[It] := Word(Integer(FVI[Is_]) + Imm);
        end;
      $34: if Id <> 0 then FVI[Id] := FVI[Is_] and FVI[It];
      $35: if Id <> 0 then FVI[Id] := FVI[Is_] or FVI[It];
      $3C..$3F: LowerSpecial(Op);
    end;
    Exit;
  end;
  var Dest := (Op shr 21) and $F;
  var It := Integer((Op shr 16) and 31);
  var Is_ := Integer((Op shr 11) and 31);
  var Imm11 := SignExt11(Op);
  case Op shr 25 of
    $00: // LQ
      begin
        FLowerValue := DataAddress(Cardinal(Integer(FVI[Is_ and 15]) + Imm11))^;
        FLowerReg := It;
        FLowerMask := Dest;
      end;
    $01: // SQ
      begin
        var P := DataAddress(Cardinal(Integer(FVI[It and 15]) + Imm11));
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVF[Is_].UW[K];
      end;
    $04: // ILW
      begin
        var P := DataAddress(Cardinal(Integer(FVI[Is_ and 15]) + Imm11));
        if (It and 15) <> 0 then
          for var K := 0 to 3 do
            if (Dest and FieldBit(K)) <> 0 then
            begin
              FVI[It and 15] := P.UW[K] and $FFFF;
              Break;
            end;
      end;
    $05: // ISW
      begin
        var P := DataAddress(Cardinal(Integer(FVI[Is_ and 15]) + Imm11));
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVI[It and 15] and $FFFF;
      end;
    $08, $09: // IADDIU, ISUBIU
      if (It and 15) <> 0 then
      begin
        var Imm := (Op and $7FF) or ((Op shr 10) and $7800);
        if (Op shr 25) = $08 then
          FVI[It and 15] := Word(Integer(FVI[Is_ and 15]) + Integer(Imm))
        else
          FVI[It and 15] := Word(Integer(FVI[Is_ and 15]) - Integer(Imm));
      end;
    $10: FVI[1] := Ord((FClipVisible and $FFFFFF) = (Op and $FFFFFF));
    $11:
      begin
        S.Clip := Op and $FFFFFF;
        S.ClipBase := S.Clip;
        S.ClipQCount := 0;
        FClipVisible := S.Clip;
      end;
    $12: FVI[1] := Ord((FClipVisible and Op and $FFFFFF) <> 0);
    $13: FVI[1] := Ord(((FClipVisible or Op) and $FFFFFF) = $FFFFFF);
    $14: if (It and 15) <> 0 then FVI[It and 15] := Ord((S.StatusBase and $FFF) = (((Op shr 10) and $800) or (Op and $7FF)));
    $15:
      begin
        var Sticky := (((Op shr 10) and $800) or (Op and $7FF)) and $FC0;
        S.Status := (S.Status and $3F) or Sticky;
        S.StatusBase := (S.StatusBase and $3F) or Sticky;
        for var K := 0 to S.FlagQCount - 1 do
          S.FlagQStatus[K] := (S.FlagQStatus[K] and $3F) or Sticky;
      end;
    $16: if (It and 15) <> 0 then FVI[It and 15] := S.StatusBase and (((Op shr 10) and $800) or (Op and $7FF));
    $17: if (It and 15) <> 0 then FVI[It and 15] := (S.StatusBase or (((Op shr 10) and $800) or (Op and $7FF))) and $FFF;
    $18: if (It and 15) <> 0 then FVI[It and 15] := Ord((S.MACBase and $FFFF) = (FVI[Is_ and 15] and $FFFF));
    $1A: if (It and 15) <> 0 then FVI[It and 15] := S.MACBase and FVI[Is_ and 15] and $FFFF;
    $1B: if (It and 15) <> 0 then FVI[It and 15] := (S.MACBase or FVI[Is_ and 15]) and $FFFF;
    $1C: if (It and 15) <> 0 then FVI[It and 15] := FClipVisible and $FFF;
    $20, $21, $28, $29, $2C, $2D, $2E, $2F:
      begin
        var Take: Boolean;
        var A := SmallInt(Word(FVI[Is_ and 15]));
        var B := SmallInt(Word(FVI[It and 15]));
        if (Is_ and 15) = FBranchReg then
          A := SmallInt(Word(FBranchOld));
        if (It and 15) = FBranchReg then
          B := SmallInt(Word(FBranchOld));
        case Op shr 25 of
          $20, $21: Take := True;
          $28: Take := Word(A) = Word(B);
          $29: Take := Word(A) <> Word(B);
          $2C: Take := A < 0;
          $2D: Take := A > 0;
          $2E: Take := A <= 0;
        else
          Take := A >= 0;
        end;
        if (Op shr 25) = $21 then
        begin
          if (It and 15) <> 0 then
            FVI[It and 15] := ((S.TPC + 16) shr 3) and $FFFF;
        end;
        if Take then
        begin
          S.BranchPending := True;
          S.BranchTarget := Cardinal(Integer(S.TPC) + 8 + Imm11 * 8) and FCodeMask;
        end;
      end;
    $24, $25: // JR, JALR
      begin
        var Target := (FVI[Is_ and 15] * 8) and FCodeMask;
        if ((Op shr 25) = $25) and ((It and 15) <> 0) then
          FVI[It and 15] := ((S.TPC + 16) shr 3) and $FFFF;
        S.BranchPending := True;
        S.BranchTarget := Target;
      end;
  end;
end;

procedure TPS2VUCore.LowerSpecial(Op: Cardinal);
var
  Flags: Cardinal;
begin
  var Index := ((Op shr 4) and $7C) or (Op and 3);
  var Dest := (Op shr 21) and $F;
  var Ft := Integer((Op shr 16) and 31);
  var Fs := Integer((Op shr 11) and 31);
  var Fsf := Integer((Op shr 21) and 3);
  var Ftf := Integer((Op shr 23) and 3);
  case Index of
    $30: // MOVE
      begin
        FLowerValue := FVF[Fs];
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $31: // MR32
      begin
        var A := FVF[Fs];
        FLowerValue.UW[0] := A.UW[1];
        FLowerValue.UW[1] := A.UW[2];
        FLowerValue.UW[2] := A.UW[3];
        FLowerValue.UW[3] := A.UW[0];
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $34, $36: // LQI, LQD (fs field holds the integer register)
      begin
        var R := Fs and 15;
        if Index = $36 then
        begin
          if R <> 0 then
            FVI[R] := Word(Integer(FVI[R]) - 1);
          FLowerValue := DataAddress(FVI[R])^;
        end
        else
        begin
          FLowerValue := DataAddress(FVI[R])^;
          if R <> 0 then
            FVI[R] := Word(Integer(FVI[R]) + 1);
        end;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $35, $37: // SQI, SQD: fs is the VF, ft the integer register
      begin
        var R := Ft and 15;
        if (Index = $37) and (R <> 0) then
          FVI[R] := Word(Integer(FVI[R]) - 1);
        var P := DataAddress(FVI[R]);
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVF[Fs].UW[K];
        if (Index = $35) and (R <> 0) then
          FVI[R] := Word(Integer(FVI[R]) + 1);
      end;
    $38, $39, $3A: // DIV, SQRT, RSQRT -> Q
      begin
        // The divider takes one operation at a time: a new one waits for
        // the previous result.
        if S.QDelay > 0 then
        begin
          S.Q := S.PendingQ;
          S.QDelay := 0;
        end;
        var A := FVF[Fs].UW[Fsf];
        var B := FVF[Ft].UW[Ftf];
        var R: Cardinal;
        S.Status := S.Status and not Cardinal($30);
        case Index of
          $38:
            if (B and $7F800000) = 0 then
            begin
              if (A and $7F800000) = 0 then
                S.Status := S.Status or $410
              else
                S.Status := S.Status or $820;
              R := ((A xor B) and $80000000) or $7FFFFFFF;
            end
            else
            begin
              Flags := 0;
              var D := EEFloatIn(A) / EEFloatIn(B);
              var F: Single := D;
              R := PCardinal(@F)^;
              if (A and $7F800000) = 0 then
                R := (A xor B) and $80000000;
            end;
          $39:
            begin
              if (B and $80000000) <> 0 then
                S.Status := S.Status or $410;
              if (B and $7F800000) = 0 then
                R := 0
              else
              begin
                var F: Single := Sqrt(Abs(EEFloatIn(B)));
                R := PCardinal(@F)^;
              end;
            end;
        else
          begin
            if (B and $7F800000) = 0 then
            begin
              S.Status := S.Status or $820;
              R := (A and $80000000) or $7FFFFFFF;
            end
            else
            begin
              if (B and $80000000) <> 0 then
                S.Status := S.Status or $410;
              var F: Single := EEFloatIn(A) / Sqrt(Abs(EEFloatIn(B)));
              R := PCardinal(@F)^;
              if (A and $7F800000) = 0 then
                R := A and $80000000;
            end;
          end;
        end;
        S.PendingQ := R;
        if Index = $3A then
          S.QDelay := 13
        else
          S.QDelay := 7;
      end;
    $3B: // WAITQ
      if S.QDelay > 0 then
      begin
        S.Q := S.PendingQ;
        S.QDelay := 0;
      end;
    $3C: // MTIR
      if (Ft and 15) <> 0 then
        FVI[Ft and 15] := FVF[Fs].UW[Fsf] and $FFFF;
    $3D: // MFIR
      begin
        var V := Cardinal(Integer(SmallInt(Word(FVI[Fs and 15]))));
        for var K := 0 to 3 do
          FLowerValue.UW[K] := V;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $3E: // ILWR
      if (Ft and 15) <> 0 then
      begin
        var P := DataAddress(FVI[Fs and 15]);
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
          begin
            FVI[Ft and 15] := P.UW[K] and $FFFF;
            Break;
          end;
      end;
    $3F: // ISWR
      begin
        var P := DataAddress(FVI[Fs and 15]);
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVI[Ft and 15] and $FFFF;
      end;
    $40, $41: // RNEXT, RGET
      begin
        if Index = $40 then
        begin
          // 23-bit generator (x^23 + x^5 + 1 style feedback).
          var X := S.R and $7FFFFF;
          var Bit := ((X shr 4) xor (X shr 22)) and 1;
          S.R := $3F800000 or (((X shl 1) or Bit) and $7FFFFF);
        end;
        for var K := 0 to 3 do
          FLowerValue.UW[K] := S.R;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $42: S.R := $3F800000 or (FVF[Fs].UW[Fsf] and $7FFFFF);
    $43: S.R := $3F800000 or ((S.R xor FVF[Fs].UW[Fsf]) and $7FFFFF);
    $64: // MFP
      begin
        for var K := 0 to 3 do
          FLowerValue.UW[K] := S.P;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $68: // XTOP
      if (Ft and 15) <> 0 then
        FVI[Ft and 15] := FVI[16 + 10];
    $69: // XITOP
      if (Ft and 15) <> 0 then
        FVI[Ft and 15] := FVI[16 + 11];
    $6C: // XGKICK
      if Assigned(FOnKick) then
        StartKick((FVI[Fs and 15] * 16) and FDataMask);
    $70..$7E: // EFU -> P
      begin
        var V := FVF[Fs];
        var X := EEFloatIn(V.UW[0]);
        var Y := EEFloatIn(V.UW[1]);
        var Z := EEFloatIn(V.UW[2]);
        var W := EEFloatIn(V.UW[3]);
        var F := EEFloatIn(V.UW[Fsf]);
        var D: Double := 0;
        case Index of
          $70: D := X * X + Y * Y + Z * Z;
          $71: if X * X + Y * Y + Z * Z <> 0 then D := 1 / (X * X + Y * Y + Z * Z);
          $72: D := Sqrt(X * X + Y * Y + Z * Z);
          $73: if X * X + Y * Y + Z * Z <> 0 then D := 1 / Sqrt(X * X + Y * Y + Z * Z);
          $74: if X <> 0 then D := ArcTan(Y / X);
          $75: if X <> 0 then D := ArcTan(Z / X);
          $76: D := X + Y + Z + W;
          $78: D := Sqrt(Abs(F));
          $79: if F <> 0 then D := 1 / Sqrt(Abs(F));
          $7A: if F <> 0 then D := 1 / F;
          $7B: ; // WAITP
          $7C: D := Sin(F);
          $7D: D := ArcTan(F);
          $7E: D := Exp(-F);
        end;
        if Index = $7B then
        begin
          if S.PDelay > 0 then
          begin
            S.P := S.PendingP;
            S.PDelay := 0;
          end;
        end
        else
        begin
          var R: Single := D;
          S.PendingP := PCardinal(@R)^;
          S.PDelay := 12;
        end;
      end;
  end;
end;

function TPS2VUCore.Macro(Op: Cardinal): Boolean;
begin
  // COP2 macro: upper-style operations and the lower ones VU0 offers.
  Result := True;
  var Funct := Op and $3F;
  FUpperReg := -1;
  FLowerReg := -1;
  // Macro-mode Q results are available at once.
  case Funct of
    $30..$35:
      begin
        Lower(Op or $80000000);
        Exit;
      end;
    $38, $39: Exit(True);
    $3C..$3F:
      begin
        var Index := ((Op shr 4) and $7C) or (Op and 3);
        if Index >= $30 then
        begin
          LowerSpecial(Op);
          if S.QDelay > 0 then
          begin
            S.Q := S.PendingQ;
            S.QDelay := 0;
          end;
          if FLowerReg >= 0 then
            CommitVF(FLowerReg, FLowerValue, FLowerMask);
          Exit;
        end;
      end;
  end;
  Upper(Op, False);
  if FUpperReg = 32 then
  begin
    for var K := 0 to 3 do
      if (FUpperMask and FieldBit(K)) <> 0 then
        S.ACC.UW[K] := FUpperValue.UW[K];
  end
  else if FUpperReg >= 0 then
    CommitVF(FUpperReg, FUpperValue, FUpperMask);
end;

{ Pipeline timing }

// The VF registers an upper op reads and writes with their fields (x 8,
// y 4, z 2, w 1; register -1: none). Results going to ACC are not tracked:
// there are no hazard checks on ACC.
procedure TPS2VUCore.UpperRegs(Op: Cardinal; out R: TPS2VURegUse);
begin
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Fd := Integer((Op shr 6) and 31);
  var Mask := (Op shr 21) and $F;
  // Broadcast ops read one field of ft.
  var Bc := FieldBit(Integer(Op and 3));
  R.Dest := -1;
  R.DestMask := Mask;
  R.S1 := -1;
  R.S2 := -1;
  R.M1 := Mask;
  R.M2 := Mask;
  var F := Integer(Op and $3F);
  if F >= $3C then
  begin
    var X := (Integer((Op shr 6) and 31) shl 2) or (F and 3);
    case X of
      $00..$0F, $18..$1B:
        begin
          R.S1 := Fs;
          R.S2 := Ft;
          R.M2 := Bc;
        end;
      $28..$2D:
        begin
          R.S1 := Fs;
          R.S2 := Ft;
        end;
      $2E:
        begin
          // OPMULA: the cross product reads x, y and z of both.
          R.S1 := Fs;
          R.S2 := Ft;
          R.M1 := $E;
          R.M2 := $E;
        end;
      $10..$17, $1D:
        begin
          R.S1 := Fs;
          R.Dest := Ft;
        end;
      $1C, $1E, $20..$27:
        R.S1 := Fs;
      $1F:
        begin
          // CLIP: fs.xyz against ft.w.
          R.S1 := Fs;
          R.S2 := Ft;
          R.M1 := $E;
          R.M2 := 1;
        end;
    end;
    Exit;
  end;
  case F of
    $00..$1B:
      begin
        R.S1 := Fs;
        R.S2 := Ft;
        R.M2 := Bc;
        R.Dest := Fd;
      end;
    $28..$2D, $2F:
      begin
        R.S1 := Fs;
        R.S2 := Ft;
        R.Dest := Fd;
      end;
    $2E:
      begin
        // OPMSUB
        R.S1 := Fs;
        R.S2 := Ft;
        R.M1 := $E;
        R.M2 := $E;
        R.Dest := Fd;
      end;
    $1C..$27:
      begin
        R.S1 := Fs;
        R.Dest := Fd;
      end;
  end;
end;

// The VF registers a lower op reads and writes with their fields.
procedure TPS2VUCore.LowerRegs(Op: Cardinal; out R: TPS2VURegUse);
begin
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Mask := (Op shr 21) and $F;
  // Single-field operands (DIV, SQRT, RSQRT, MTIR, EFU): fsf, ftf.
  var Fsf := FieldBit(Integer((Op shr 21) and 3));
  var Ftf := FieldBit(Integer((Op shr 23) and 3));
  R.Dest := -1;
  R.DestMask := Mask;
  R.S1 := -1;
  R.S2 := -1;
  R.M1 := Mask;
  R.M2 := Mask;
  case Op shr 25 of
    $00: R.Dest := Ft;
    $01: R.S1 := Fs;
    $40:
      if (Op and $3F) >= $3C then
        case (Integer((Op shr 6) and 31) shl 2) or Integer(Op and 3) of
          $30:
            begin
              R.S1 := Fs;
              R.Dest := Ft;
            end;
          $31:
            begin
              // MR32: x from y, y from z, z from w, w from x.
              R.S1 := Fs;
              R.M1 := ((Mask shr 1) and 7) or ((Mask and 1) shl 3);
              R.Dest := Ft;
            end;
          $34, $36, $3D, $64: R.Dest := Ft;
          $35, $37: R.S1 := Fs;
          $3C:
            begin
              R.S1 := Fs;
              R.M1 := Fsf;
            end;
          $70..$7E:
            begin
              R.S1 := Fs;
              R.M1 := $F;
            end;
          $38, $3A:
            begin
              R.S1 := Fs;
              R.M1 := Fsf;
              R.S2 := Ft;
              R.M2 := Ftf;
            end;
          $39:
            begin
              R.S1 := Ft;
              R.M1 := Ftf;
            end;
        end;
  end;
end;

function TPS2VUCore.ReadyAt(Reg: Integer; Mask: Cardinal): Int64;
begin
  Result := 0;
  if (Reg <= 0) or (FReadyAny[Reg] <= S.Cycles) then
    Exit;
  for var K := 0 to 3 do
    if ((Mask and FieldBit(K)) <> 0) and (FReady[Reg, K] > Result) then
      Result := FReady[Reg, K];
end;

// Cycles the pair waits for its source fields (hazard checks are per
// field; none on ACC, VF00, I, Q, P, R).
procedure TPS2VUCore.DecodePair(var P: TPS2VUPair; LowerOp, UpperOp: Cardinal);
begin
  P.Native := nil;
  P.Heat := 0;
  var UF := UpperOp and $3F;
  var US := ((UpperOp shr 4) and $7C) or (UpperOp and 3);
  P.NativeCandidate := (UF in [$10..$17, $1D, $1F, $2B, $2F]) or
    ((UF >= $3C) and (US = $1D)) or ((UpperOp and $80000000) <> 0);
  if (UpperOp and $80000000) = 0 then
    if (LowerOp and $80000000) <> 0 then
      P.NativeCandidate := P.NativeCandidate or ((LowerOp and $3F) in [$30..$32, $34, $35])
    else
      P.NativeCandidate := P.NativeCandidate or ((LowerOp shr 25) in [$00, $01, $04, $05, $08, $09]);
  P.Lower := LowerOp;
  P.Upper := UpperOp;
  UpperRegs(UpperOp, P.U);
  if (UpperOp and $80000000) = 0 then
    LowerRegs(LowerOp, P.L)
  else
  begin
    P.L := Default(TPS2VURegUse);
    P.L.Dest := -1;
    P.L.S1 := -1;
    P.L.S2 := -1;
  end;
  P.SetsFlags := UpperSetsFlags(UpperOp);
  P.Valid := True;
end;

function TPS2VUCore.DecodedPair(PC, LowerOp, UpperOp: Cardinal): PPS2VUPair;
begin
  Result := @FPairs[PC shr 3];
  if not Result.Valid or (Result.Lower <> LowerOp) or (Result.Upper <> UpperOp) then
    DecodePair(Result^, LowerOp, UpperOp);
end;

function TPS2VUCore.HazardStall(const P: TPS2VUPair): Integer;
begin
  var Need := Max(ReadyAt(P.U.S1, P.U.M1), ReadyAt(P.U.S2, P.U.M2));
  Need := Max(Need, Max(ReadyAt(P.L.S1, P.L.M1), ReadyAt(P.L.S2, P.L.M2)));
  Result := 0;
  if Need > S.Cycles then
    Result := Integer(Need - S.Cycles);
end;

// The pair's results are ready four cycles after issue.
procedure TPS2VUCore.NoteWrites(const P: TPS2VUPair);
begin
  if (P.U.Dest > 0) and (P.U.DestMask <> 0) then
  begin
    for var K := 0 to 3 do
      if (P.U.DestMask and FieldBit(K)) <> 0 then
        FReady[P.U.Dest, K] := S.Cycles + 4;
    FReadyAny[P.U.Dest] := S.Cycles + 4;
  end;
  if (P.L.Dest > 0) and (P.L.DestMask <> 0) then
  begin
    for var K := 0 to 3 do
      if (P.L.DestMask and FieldBit(K)) <> 0 then
        FReady[P.L.Dest, K] := S.Cycles + 4;
    FReadyAny[P.L.Dest] := S.Cycles + 4;
  end;
end;

// FMAC ops that update the MAC and status flags (not MAX/MINI, ITOF/FTOI,
// ABS, CLIP, NOP).
function TPS2VUCore.UpperSetsFlags(Op: Cardinal): Boolean;
begin
  var F := Integer(Op and $3F);
  if F >= $3C then
  begin
    var X := (Integer((Op shr 6) and 31) shl 2) or (F and 3);
    Result := not (X in [$10..$17, $1D, $1F, $2B, $2F]);
  end
  else
    Result := (F <= $2F) and not (F in [$10..$17, $1D, $1F, $2B, $2F]);
end;

procedure TPS2VUCore.AdvanceCycles(N: Integer);
begin
  Inc(S.Cycles, N);
  if S.QDelay > 0 then
  begin
    Dec(S.QDelay, N);
    if S.QDelay <= 0 then
    begin
      S.QDelay := 0;
      S.Q := S.PendingQ;
    end;
  end;
  if S.PDelay > 0 then
  begin
    Dec(S.PDelay, N);
    if S.PDelay <= 0 then
    begin
      S.PDelay := 0;
      S.P := S.PendingP;
    end;
  end;
end;

// XGKICK: the GIF starts reading the packet from VU memory a few cycles
// after the XGKICK (KickLatency) and then takes a quadword every two VU
// cycles while the program goes on, so stores the program makes to the
// packet right after the XGKICK still go out with it (programs kick a
// packet and write its GIF tag or its last quadword in the next pairs). A
// second XGKICK waits for the first transfer; the end of the program or of
// the run hands the rest over at once.
procedure TPS2VUCore.StartKick(Address: Cardinal);
begin
  if FKickPending then
    TakeKick(True);
  if Length(FKickBuf) = 0 then
    SetLength(FKickBuf, (FDataMask + 1) div 16);
  FKickPending := True;
  FKickAddress := Address;
  FKickStart := S.Cycles + KickLatency;
  FKickCount := 0;
  FKickNextTag := 0;
  FKickEnd := -1;
  TakeKick(False);
end;

procedure TPS2VUCore.TakeKick(All: Boolean);
begin
  var Limit := Length(FKickBuf);
  while ((FKickEnd < 0) or (FKickCount < FKickEnd)) and (FKickCount < Limit) and
    (All or (FKickStart + 2 * FKickCount <= S.Cycles)) do
  begin
    var Q := PPS2Reg128(FData + ((FKickAddress + Cardinal(FKickCount) * 16) and FDataMask))^;
    FKickBuf[FKickCount] := Q;
    if FKickCount = FKickNextTag then
    begin
      var NLoop := Integer(Q.UW[0] and $7FFF);
      var Flg := (Q.UW[1] shr 26) and 3;
      var NReg := Integer(Q.UW[1] shr 28);
      if NReg = 0 then
        NReg := 16;
      var Size: Integer;
      case Flg of
        0: Size := NLoop * NReg;
        1: Size := (NLoop * NReg + 1) div 2;
      else
        Size := NLoop;
      end;
      FKickNextTag := FKickCount + 1 + Size;
      if (Q.UW[0] and $8000) <> 0 then
        FKickEnd := FKickNextTag;
    end;
    Inc(FKickCount);
  end;
  if ((FKickEnd >= 0) and (FKickCount >= FKickEnd)) or (FKickCount >= Limit) then
  begin
    FKickPending := False;
    if Assigned(FOnKick) then
      FOnKick(FKickAddress, @FKickBuf[0]);
  end;
end;

procedure TPS2VUCore.Start(Address: Cardinal);
begin
  FLoadReg := -1;
  S.TPC := Address and FCodeMask;
  S.Running := True;
  S.BranchPending := False;
  S.EndPending := False;
  S.ClipBase := S.Clip;
  S.ClipQCount := 0;
  S.MACBase := S.MAC;
  S.StatusBase := S.Status;
  S.FlagQCount := 0;
  FillChar(FReady, SizeOf(FReady), 0);
  FillChar(FReadyAny, SizeOf(FReadyAny), 0);
end;

procedure TPS2VUCore.PreparePair(var Run: TPS2VURun);
begin
    var PC := Run.PC;
    var Pair := Run.Pair;
    var LowerOp := Pair.Lower;
    var UpperOp := Pair.Upper;
    // Registers still in the FMAC pipeline stall the pair; Q/P and the
    // clip flag move on meanwhile.
    var Stall := HazardStall(Pair^);
    if Stall > 0 then
      AdvanceCycles(Stall);
    if FKickPending then
      TakeKick(False);
    while (S.ClipQCount > 0) and (S.ClipQReady[0] <= S.Cycles) do
    begin
      S.ClipBase := S.ClipQValue[0];
      for var K := 1 to S.ClipQCount - 1 do
      begin
        S.ClipQValue[K - 1] := S.ClipQValue[K];
        S.ClipQReady[K - 1] := S.ClipQReady[K];
      end;
      Dec(S.ClipQCount);
    end;
    FClipVisible := S.ClipBase;
    while (S.FlagQCount > 0) and (S.FlagQReady[0] <= S.Cycles) do
    begin
      S.MACBase := S.FlagQMAC[0];
      S.StatusBase := S.FlagQStatus[0];
      for var K := 1 to S.FlagQCount - 1 do
      begin
        S.FlagQMAC[K - 1] := S.FlagQMAC[K];
        S.FlagQStatus[K - 1] := S.FlagQStatus[K];
        S.FlagQReady[K - 1] := S.FlagQReady[K];
      end;
      Dec(S.FlagQCount);
    end;
    Run.Branching := S.BranchPending;
    Run.Target := S.BranchTarget;
    Run.Ending := S.EndPending;
    S.BranchPending := False;
    // Q and P land after their latency.
    if S.QDelay > 0 then
    begin
      Dec(S.QDelay);
      if S.QDelay = 0 then
        S.Q := S.PendingQ;
    end;
    if S.PDelay > 0 then
    begin
      Dec(S.PDelay);
      if S.PDelay = 0 then
        S.P := S.PendingP;
    end;
    // WAITQ/WAITP stall the whole pair: its upper op sees the new Q/P.
    if (UpperOp and $80000000) = 0 then
      if ((LowerOp and $FE0007FF) = $800003BF) and (S.QDelay > 0) then
      begin
        S.Q := S.PendingQ;
        S.QDelay := 0;
      end
      else if ((LowerOp and $FE0007FF) = $800007BF) and (S.PDelay > 0) then
      begin
        S.P := S.PendingP;
        S.PDelay := 0;
      end;
    if (RunTrace <> nil) and ((RunTraceCount + 1) * 16 <= Length(RunTrace)) then
    begin
      RunTrace[RunTraceCount * 16] := Word(PC);
      for var K := 1 to 15 do
        RunTrace[RunTraceCount * 16 + K] := Word(FVI[K]);
      Inc(RunTraceCount);
    end;
    // An integer register written by the integer unit (ILW, ILWR, MTIR,
    // the integer ALU, LQI/LQD/SQI/SQD address updates) reaches a
    // conditional branch in the next pair only after it has read its
    // operands. Flag reads (FS*/FM*/FC*) reach it at once.
    FBranchReg := FLoadReg;
    FBranchOld := FLoadOld;
    FLoadReg := -1;
    if (UpperOp and $80000000) = 0 then
      if (LowerOp and $80000000) = 0 then
      begin
        case LowerOp shr 25 of
          $04, $08, $09: // ILW, IADDIU, ISUBIU
            FLoadReg := Integer((LowerOp shr 16) and 15);
        end;
      end
      else
        case LowerOp and $3F of
          $30, $31, $34, $35: // IADD, ISUB, IAND, IOR
            FLoadReg := Integer((LowerOp shr 6) and 15);
          $32: // IADDI
            FLoadReg := Integer((LowerOp shr 16) and 15);
          $3C..$3F:
            case ((LowerOp shr 4) and $7C) or (LowerOp and 3) of
              $3C, $3E: // MTIR, ILWR
                FLoadReg := Integer((LowerOp shr 16) and 15);
              $34, $36: // LQI, LQD
                FLoadReg := Integer((LowerOp shr 11) and 15);
              $35, $37: // SQI, SQD
                FLoadReg := Integer((LowerOp shr 16) and 15);
            end;
        end;
    if FLoadReg = 0 then
      FLoadReg := -1;
    if FLoadReg >= 0 then
      FLoadOld := FVI[FLoadReg];
    FUpperReg := -1;
    FLowerReg := -1;
end;

procedure TPS2VUCore.FinishPair(var Run: TPS2VURun);
begin
    var PC := Run.PC;
    var Pair := Run.Pair;
    var UpperOp := Pair.Upper;
    // Lower writes first; the upper result wins on the same register.
    if FLowerReg >= 0 then
      CommitVF(FLowerReg, FLowerValue, FLowerMask);
    if FUpperReg = 32 then
    begin
      for var K := 0 to 3 do
        if (FUpperMask and FieldBit(K)) <> 0 then
          S.ACC.UW[K] := FUpperValue.UW[K];
    end
    else if FUpperReg >= 0 then
      CommitVF(FUpperReg, FUpperValue, FUpperMask);
    NoteWrites(Pair^);
    if Pair.SetsFlags and (S.FlagQCount < 4) then
    begin
      S.FlagQMAC[S.FlagQCount] := S.MAC;
      S.FlagQStatus[S.FlagQCount] := S.Status;
      S.FlagQReady[S.FlagQCount] := S.Cycles + 4;
      Inc(S.FlagQCount);
    end;
    Inc(Executed);
    Inc(S.Cycles);
    Inc(Run.Count);
    if Run.Count > Run.Limit - Length(LoopTrace) then
      LoopTrace[Run.Count - (Run.Limit - Length(LoopTrace)) - 1] := PC;
    S.TPC := (PC + 8) and FCodeMask;
    if Run.Branching then
      S.TPC := Run.Target;
    if Run.Ending then
    begin
      S.Running := False;
      S.EndPending := False;
      Exit;
    end;
    if (UpperOp and $40000000) <> 0 then
      S.EndPending := True;
end;

function TPS2VUCore.Run(MaxPairs: Integer): Boolean;
begin
  var Context := Default(TPS2VURun);
  Context.Limit := MaxPairs;
  while S.Running and (Context.Count < Context.Limit) do
  begin
    var PC := S.TPC and FCodeMask;
    var LowerOp := PCardinal(FCode + PC)^;
    var UpperOp := PCardinal(FCode + PC + 4)^;
    var Pair := DecodedPair(PC, LowerOp, UpperOp);
    if FUseJit and Pair.NativeCandidate and (FIndex = 1) and (JitSupported or (FJit <> nil)) then
    begin
      if Pair.Native = nil then
      begin
        Inc(Pair.Heat);
        if Pair.Heat >= 16 then
          Pair.Native := CompileBlock(PC);
      end;
    end;
    if FUseJit and (Pair.Native <> nil) then
    begin
      var Before := Context.Count;
      Context.Invalid := False;
      FJit.Invoke(Pair.Native, NativeUInt(Self), NativeUInt(@Context), 0, 0);
      Inc(FJitBlocks);
      Inc(FJitRuns, Context.Count - Before);
      if Context.Invalid then Pair.Native := nil;
      if Context.Count <> Before then Continue;
    end;
    Context.PC := PC;
    Context.Pair := Pair;
    PreparePair(Context);
    Upper(UpperOp, True);
    if (UpperOp and $80000000) <> 0 then
      S.I := LowerOp
    else
      Lower(LowerOp);
    FinishPair(Context);
  end;
  if FKickPending then
    TakeKick(True);
  Result := not S.Running;
end;

procedure TPS2VUCore.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
  if State.Loading then
    FLoadReg := -1;
end;

{ TPS2VU0 }

constructor TPS2VU0.Create(Code, Data: PByte);
begin
  FCore := TPS2VUCore.Create(0, @VF, @VI, Code, Data, $1000, $1000);
  inherited Create;
end;

destructor TPS2VU0.Destroy;
begin
  FCore.Free;
  inherited;
end;

procedure TPS2VU0.Reset;
begin
  inherited Reset;
  if FCore <> nil then
    FCore.Reset;
  FBlocked := False;
end;

function TPS2VU0.ReadControl(Index: Integer): Cardinal;
begin
  case Index of
    0..15: Result := VI[Index] and $FFFF;
    16: Result := FCore.S.Status;
    17: Result := FCore.S.MAC;
    18: Result := FCore.S.Clip;
    20: Result := FCore.S.R;
    21: Result := FCore.S.I;
    22: Result := FCore.S.Q;
    23: Result := FCore.S.P;
    26: Result := FCore.S.TPC shr 3;
    29:
      begin
        // VPU-STAT: VBS0 (VU0 busy) bit 0, VBS1 bit 8.
        Result := Ord(FCore.S.Running);
        if (FVU1 <> nil) and FVU1.S.Running then
          Result := Result or $100;
      end;
  else
    Result := VI[Index and 31];
  end;
end;

procedure TPS2VU0.WriteControl(Index: Integer; Value: Cardinal);
begin
  case Index of
    0: ;
    1..15: VI[Index] := Value and $FFFF;
    16: FCore.S.Status := (FCore.S.Status and $3F) or (Value and $FC0);
    17: FCore.S.MAC := Value and $FFFF;
    18: FCore.S.Clip := Value and $FFFFFF;
    20: FCore.S.R := Value and $7FFFFF;
    21: FCore.S.I := Value;
    22: FCore.S.Q := Value;
    27: VI[27] := Value;
    28:
      begin
        // FBRST: reset VU0 (bit 1) / VU1 (bit 9).
        if (Value and 2) <> 0 then
          FCore.Reset;
        if ((Value and $200) <> 0) and (FVU1 <> nil) then
          FVU1.Reset;
      end;
    31:
      if Assigned(FCMSAR1Start) then
        FCMSAR1Start(Value);
  else
    VI[Index and 31] := Value;
  end;
end;

function TPS2VU0.Execute(Op: Cardinal): Boolean;
begin
  case Op and $3F of
    $38, $39:
      begin
        // VCALLMS imm15 / VCALLMSR (CMSAR0): run the micro program now.
        var Address: Cardinal;
        if (Op and $3F) = $38 then
          Address := ((Op shr 6) and $7FFF) * 8
        else
          Address := (VI[27] and $FFFF) * 8;
        // A program still running is waited for first.
        Interlock;
        FBlocked := False;
        FCore.Start(Address);
        RunUntilBlocked;
        Exit(True);
      end;
  end;
  // Macro instructions wait for a running micro program.
  Interlock;
  Result := FCore.Macro(Op);
end;

// A micro program runs alongside the EE. Programs wait in loops on
// registers the EE writes (a VI flag released by CTC2, VF data handed over
// by QMTC2) and hand results back the same way, so the program runs as far
// as it can whenever the EE starts it or looks at VU0: to its end, or until
// it spins without changing anything (Spins). Once it spins, it is only
// probed again (one turn of the loop, which also sees VU memory the EE
// wrote) until the EE changes its registers.
procedure TPS2VU0.RunUntilBlocked;
begin
  if FBlocked and CompareMem(@VF[0], @FBlockVF[0], SizeOf(FBlockVF)) and
    CompareMem(@VI[0], @FBlockVI[0], SizeOf(FBlockVI)) and Spins then
    Exit;
  FBlocked := False;
  // Short runs first: a released program often goes back to waiting soon.
  var Chunk := 16;
  var Budget := 1000000;
  while FCore.S.Running and (Budget > 0) do
  begin
    FCore.Run(Chunk);
    Dec(Budget, Chunk);
    Chunk := Min(Chunk * 2, 4096);
    if FCore.S.Running and Spins then
    begin
      FBlocked := True;
      Move(VF[0], FBlockVF[0], SizeOf(FBlockVF));
      Move(VI[0], FBlockVI[0], SizeOf(FBlockVI));
      Break;
    end;
  end;
end;

// Runs up to 64 pairs: True when the program came back to the same TPC with
// the same registers (a loop that waits).
function TPS2VU0.Spins: Boolean;
var
  SavedVF: array[0..31] of TPS2Reg128;
  SavedVI: array[0..15] of Cardinal;
begin
  var TPC := FCore.S.TPC;
  var Acc := FCore.S.ACC;
  var Q := FCore.S.Q;
  var P := FCore.S.P;
  Move(VF[0], SavedVF[0], SizeOf(SavedVF));
  Move(VI[0], SavedVI[0], SizeOf(SavedVI));
  for var K := 1 to 64 do
  begin
    FCore.Run(1);
    if not FCore.S.Running then
      Exit(False);
    if (FCore.S.TPC = TPC) and (FCore.S.Q = Q) and (FCore.S.P = P) and CompareMem(@FCore.S.ACC, @Acc, SizeOf(Acc))
      and CompareMem(@VF[0], @SavedVF[0], SizeOf(SavedVF)) and CompareMem(@VI[0], @SavedVI[0], SizeOf(SavedVI)) then
      Exit(True);
  end;
  Result := False;
end;

procedure TPS2VU0.Interlock;
begin
  if FCore.S.Running then
    RunUntilBlocked;
end;

procedure TPS2VU0.Sync;
begin
  if FCore.S.Running then
    RunUntilBlocked;
end;

function TPS2VU0.Condition: Boolean;
begin
  Result := FCore.S.Running;
end;

procedure TPS2VU0.SerializeState(State: TStateArchive);
begin
  inherited SerializeState(State);
  FCore.SerializeState(State);
end;

{ TPS2VU1 }

constructor TPS2VU1.Create(Code, Data: PByte);
begin
  inherited Create;
  FCore := TPS2VUCore.Create(1, @FVF, @FVI, Code, Data, $4000, $4000);
  Reset;
end;

destructor TPS2VU1.Destroy;
begin
  FCore.Free;
  inherited;
end;

procedure TPS2VU1.Reset;
begin
  FillChar(FVF, SizeOf(FVF), 0);
  FillChar(FVI, SizeOf(FVI), 0);
  FCore.Reset;
end;

procedure TPS2VU1.SerializeState(State: TStateArchive);
begin
  State.Field(FVF, SizeOf(FVF));
  State.Field(FVI, SizeOf(FVI));
  FCore.SerializeState(State);
end;

end.
