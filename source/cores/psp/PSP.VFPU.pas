unit PSP.VFPU;

// The VFPU (COP2): 128 single-precision registers in 8 4x4 matrices, prefixes,
// and its load/store instructions. Installs its decoder into PSP.CPU.
// A register field names S<m><c><r>; Ctx.V holds it at m*16 + c*4 + r, so a
// column is four consecutive words.
{$IFDEF PSP_CHECKED}{$Q-}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.CPU, PSP.VFPU.Math;

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;

implementation

type
  TV4 = array[0..3] of Cardinal;
  TIdx4 = array[0..3] of Byte;
  PIdx4 = ^TIdx4;
  TBinFn = function(A, B: Cardinal): Cardinal;
  TUnFn = function(A: Cardinal): Cardinal;

const
  PFX_NONE = $E4;
  PfxConst: array[0..7] of Cardinal = ($00000000, $3F800000, $40000000, $3F000000,
    $40400000, $3EAAAAAB, $3E800000, $3E2AAAAB);
  PastLanes: array[1..4] of Cardinal = ($E, $C, $8, $0);
  Ones: TV4 = ($3F800000, $3F800000, $3F800000, $3F800000);

var
  VecIdx: array[0..3, 0..127] of TIdx4;
  MatIdx: array[0..3, 0..127, 0..3] of TIdx4;

procedure InitTables;
begin
  for var R := 0 to 127 do
  begin
    var M := (R shr 2) and 7;
    var A := R and 3;
    var Tr := (R shr 5) and 1;
    for var N := 1 to 4 do
    begin
      var B: Integer;
      case N of
        1:
          B := (R shr 5) and 3;
        3:
          B := (R shr 6) and 1;
      else
        B := (R shr 5) and 2;
      end;
      for var K := 0 to 3 do
        for var I := 0 to 3 do
        begin
          var Col, Row: Integer;
          if N = 1 then
          begin
            Col := A;
            Row := B;
          end
          else if Tr = 0 then
          begin
            Col := (A + K) and 3;
            Row := (B + I) and 3;
          end
          else
          begin
            Col := (B + I) and 3;
            Row := (A + K) and 3;
          end;
          MatIdx[N - 1, R, K][I] := M * 16 + Col * 4 + Row;
        end;
      VecIdx[N - 1, R] := MatIdx[N - 1, R, 0];
    end;
  end;
end;

{ Fields }

function RegD(Op: Cardinal): Cardinal; inline;
begin
  Result := Op and $7F;
end;

function RegS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 8) and $7F;
end;

function RegT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and $7F;
end;

function VSz(Op: Cardinal): Integer; inline;
begin
  Result := 1 + Integer((Op shr 7) and 1) + Integer((Op shr 14) and 2);
end;

function GPRs(C: TPSPCPU; Op: Cardinal): Cardinal; inline;
begin
  Result := C.Ctx.GPR[(Op shr 21) and 31];
end;

function Imm16(Op: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt(Word(Op and $FFFC))));
end;

{ Registers and prefixes }

procedure LoadV(C: TPSPCPU; Reg: Cardinal; N: Integer; var R: TV4); inline;
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  R[0] := C.Ctx.V[P[0]];
  if N = 4 then
  begin
    R[1] := C.Ctx.V[P[1]];
    R[2] := C.Ctx.V[P[2]];
    R[3] := C.Ctx.V[P[3]];
  end
  else
  begin
    R[1] := 0;
    R[2] := 0;
    R[3] := 0;
    for var I := 1 to N - 1 do
      R[I] := C.Ctx.V[P[I]];
  end;
end;

procedure StoreV(C: TPSPCPU; Reg: Cardinal; N: Integer; const R: TV4); inline;
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  if N = 4 then
  begin
    C.Ctx.V[P[0]] := R[0];
    C.Ctx.V[P[1]] := R[1];
    C.Ctx.V[P[2]] := R[2];
    C.Ctx.V[P[3]] := R[3];
  end
  else
    for var I := 0 to N - 1 do
      C.Ctx.V[P[I]] := R[I];
end;

// Applies an S/T prefix to the lanes read; returns the lanes whose swizzle
// points past the vector, which come out as zero.
function ApplyPfx(const Src: TV4; N: Integer; Pfx: Cardinal; var Dst: TV4): Cardinal;
begin
  Result := 0;
  for var I := 0 to 3 do
  begin
    var Swz := (Pfx shr (I * 2)) and 3;
    var V: Cardinal;
    if ((Pfx shr (12 + I)) and 1) <> 0 then
      V := PfxConst[Swz or (((Pfx shr (8 + I)) and 1) shl 2)]
    else if Integer(Swz) >= N then
    begin
      Result := Result or (Cardinal(1) shl I);
      V := 0;
    end
    else
    begin
      V := Src[Swz];
      if ((Pfx shr (8 + I)) and 1) <> 0 then
        V := V and $7FFFFFFF;
    end;
    if ((Pfx shr (16 + I)) and 1) <> 0 then
      V := V xor $80000000;
    Dst[I] := V;
  end;
end;

function ReadPfx(C: TPSPCPU; Reg: Cardinal; N: Integer; Pfx: Cardinal; var R: TV4): Cardinal;
begin
  if Pfx = PFX_NONE then
  begin
    LoadV(C, Reg, N, R);
    Result := PastLanes[N];
  end
  else
  begin
    var Raw: TV4;
    LoadV(C, Reg, N, Raw);
    Result := ApplyPfx(Raw, N, Pfx, R);
  end;
end;

procedure Latch(C: TPSPCPU; const R: TV4; Lanes: Cardinal); inline;
begin
  if Lanes = $F then
  begin
    C.VLatch[0] := R[0];
    C.VLatch[1] := R[1];
    C.VLatch[2] := R[2];
    C.VLatch[3] := R[3];
  end
  else
    for var I := 0 to 3 do
      if ((Lanes shr I) and 1) <> 0 then
        C.VLatch[I] := R[I];
end;

function ReadS(C: TPSPCPU; Op: Cardinal; N: Integer; var R: TV4): Cardinal; inline;
begin
  Result := ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXS], R);
  if C.Ctx.VC[VFPU_PFXS] <> PFX_NONE then
    Latch(C, R, not Result and $F);
end;

// The S read of the unpack instructions: lanes the swizzle can't reach replay
// the latch instead of reading zero, and unprefixed reads latch too.
procedure ReadSL(C: TPSPCPU; Op: Cardinal; N: Integer; var R: TV4);
begin
  var Pfx := C.Ctx.VC[VFPU_PFXS];
  if Pfx = PFX_NONE then
  begin
    LoadV(C, RegS(Op), N, R);
    Latch(C, R, (Cardinal(1) shl N) - 1);
    Exit;
  end;
  var Raw: TV4;
  LoadV(C, RegS(Op), N, Raw);
  var Z := ApplyPfx(Raw, N, Pfx, R);
  Latch(C, R, not Z and $F);
  for var I := 0 to 3 do
    if ((Z shr I) and 1) <> 0 then
      R[I] := C.VLatch[I];
end;

function ReadT(C: TPSPCPU; Op: Cardinal; N: Integer; var R: TV4): Cardinal; inline;
begin
  Result := ReadPfx(C, RegT(Op), N, C.Ctx.VC[VFPU_PFXT], R);
end;

function SatLane(V, Mode: Cardinal): Cardinal; inline;
begin
  case Mode of
    1:
      Result := VSat0(V);
    3:
      Result := VSat1(V);
  else
    Result := V;
  end;
end;

procedure WritePfx(C: TPSPCPU; Reg: Cardinal; N: Integer; const R: TV4; Zero, DPfx: Cardinal);
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  Zero := Zero and ((Cardinal(1) shl N) - 1);
  if (DPfx or Zero) = 0 then
  begin
    StoreV(C, Reg, N, R);
    Exit;
  end;
  for var I := 0 to N - 1 do
  begin
    if ((DPfx shr (8 + I)) and 1) <> 0 then
      Continue;
    var V := R[I];
    if ((Zero shr I) and 1) <> 0 then
      V := 0;
    C.Ctx.V[P[I]] := SatLane(V, (DPfx shr (I * 2)) and 3);
  end;
end;

procedure WriteD(C: TPSPCPU; Op: Cardinal; N: Integer; const R: TV4; Zero: Cardinal); inline;
begin
  WritePfx(C, RegD(Op), N, R, Zero, C.Ctx.VC[VFPU_PFXD]);
end;

procedure EatPfx(C: TPSPCPU); inline;
begin
  C.Ctx.VC[VFPU_PFXS] := PFX_NONE;
  C.Ctx.VC[VFPU_PFXT] := PFX_NONE;
  C.Ctx.VC[VFPU_PFXD] := 0;
end;

// The function unit and the dividers work lane by lane; only the last lane
// they produce sees the prefixes, and it sees lane 0 of them, with x naming
// its own value.
function LastIn(Pfx, V: Cardinal; var Zero: Boolean): Cardinal;
begin
  if ((Pfx shr 12) and 1) <> 0 then
    Result := PfxConst[(Pfx and 3) or (((Pfx shr 8) and 1) shl 2)]
  else if (Pfx and 3) <> 0 then
  begin
    Zero := True;
    Result := 0;
  end
  else
  begin
    Result := V;
    if ((Pfx shr 8) and 1) <> 0 then
      Result := Result and $7FFFFFFF;
  end;
  if ((Pfx shr 16) and 1) <> 0 then
    Result := Result xor $80000000;
end;

procedure WriteLast(C: TPSPCPU; Reg: Cardinal; N: Integer; const R: TV4; Zero: Boolean);
begin
  if not Zero and (C.Ctx.VC[VFPU_PFXD] = 0) then
  begin
    StoreV(C, Reg, N, R);
    Exit;
  end;
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  for var I := 0 to N - 2 do
    C.Ctx.V[P[I]] := R[I];
  var D := C.Ctx.VC[VFPU_PFXD];
  if (D and $100) <> 0 then
    Exit;
  var V := R[N - 1];
  if Zero then
    V := 0;
  C.Ctx.V[P[N - 1]] := SatLane(V, D and 3);
end;

{ Element-wise arithmetic }

procedure DoBinary(C: TPSPCPU; Op: Cardinal; Fn: TBinFn);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadS(C, Op, N, S) or ReadT(C, Op, N, T);
  for var I := 0 to N - 1 do
    D[I] := Fn(S[I], T[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

function FnMin(A, B: Cardinal): Cardinal;
begin
  if VKey(A) < VKey(B) then
    Result := A
  else
    Result := B;
end;

function FnMax(A, B: Cardinal): Cardinal;
begin
  if VKey(A) > VKey(B) then
    Result := A
  else
    Result := B;
end;

function FnSge(A, B: Cardinal): Cardinal;
begin
  if not VIsNaN(A) and not VIsNaN(B) and (VKey(A) >= VKey(B)) then
    Result := VF_ONE
  else
    Result := 0;
end;

function FnSlt(A, B: Cardinal): Cardinal;
begin
  if not VIsNaN(A) and not VIsNaN(B) and (VKey(A) < VKey(B)) then
    Result := VF_ONE
  else
    Result := 0;
end;

function FnScmp(A, B: Cardinal): Cardinal;
begin
  var KA := VKey(A);
  var KB := VKey(B);
  if KA > KB then
    Result := VF_ONE
  else if KA < KB then
    Result := $BF800000
  else
    Result := 0;
end;

function FnSbn(A, B: Cardinal): Cardinal;
begin
  var E := A and $7F800000;
  if (E = 0) or (E = $7F800000) then
    Result := A
  else
    Result := (A and $807FFFFF) or ((Cardinal(127 + Integer(B)) and $FF) shl 23);
end;

procedure OpVADD(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, VAdd);
end;

procedure OpVSUB(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, VSub);
end;

procedure OpVMUL(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, VMul);
end;

procedure OpVMIN(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnMin);
end;

procedure OpVMAX(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnMax);
end;

procedure OpVSGE(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnSge);
end;

procedure OpVSLT(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnSlt);
end;

procedure OpVSCMP(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnScmp);
end;

procedure OpVSBN(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnSbn);
end;

procedure OpVDIV(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  LoadV(C, RegS(Op), N, S);
  LoadV(C, RegT(Op), N, T);
  for var I := 0 to N - 2 do
    D[I] := VDiv(S[I], T[I]);
  var Zero := False;
  var A := LastIn(C.Ctx.VC[VFPU_PFXS], S[N - 1], Zero);
  var B := LastIn(C.Ctx.VC[VFPU_PFXT], T[N - 1], Zero);
  D[N - 1] := VDiv(A, B);
  WriteLast(C, RegD(Op), N, D, Zero);
  EatPfx(C);
end;

procedure OpVSCL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, Raw, D: TV4;
  var Z := ReadS(C, Op, N, S);
  LoadV(C, RegT(Op), 1, Raw);
  Z := Z or ApplyPfx(Raw, 1, C.Ctx.VC[VFPU_PFXT] and not Cardinal($FF), T);
  for var I := 0 to N - 1 do
    D[I] := VMul(S[I], T[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVCRS(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadPfx(C, RegS(Op), N, (C.Ctx.VC[VFPU_PFXS] and not Cardinal($3F)) or $09, S) or ReadPfx(C, RegT(Op), N,
    (C.Ctx.VC[VFPU_PFXT] and not Cardinal($3F)) or $12, T);
  for var I := 0 to N - 1 do
    D[I] := VMul(S[I], T[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

{ Sums of products }

procedure OpVDOT(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadS(C, Op, N, S) or ReadT(C, Op, N, T);
  D[0] := VSum4(S, T, 4, Z);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVHDP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var ZS := ReadS(C, Op, N, S);
  var ZT := ReadT(C, Op, N, T);
  S[N - 1] := VF_ONE;
  ZS := ZS and not (Cardinal(1) shl (N - 1));
  D[0] := VSum4(S, T, 4, ZS or ZT);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVDET(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXS] xor $20000, S) or ReadPfx(C, RegT(Op), N,
    (C.Ctx.VC[VFPU_PFXT] and not Cardinal($F)) or $1, T);
  D[0] := VSum4(S, T, 4, Z);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVFAD(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  // A pending T prefix is merged into the constant ones vfad sums against.
  var P := C.Ctx.VC[VFPU_PFXT];
  if P = PFX_NONE then
    D[0] := VSum4(S, Ones, 4, Z)
  else
  begin
    var T: TV4;
    ApplyPfx(S, N, P or $F055, T);
    D[0] := VSum4(S, T, 4, Z);
  end;
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVAVG(C: TPSPCPU; Op: Cardinal);
const
  Counts: array[1..4] of Cardinal = ($3F800000, $40000000, $40400000, $40800000);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := VDiv(VSum4(S, Ones, 4, Z), Counts[N]);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

{ Compare }

function CmpTest(Cond, A, B: Cardinal): Boolean;
begin
  A := VFlush(A);
  B := VFlush(B);
  case Cond of
    0:
      Result := False;
    1:
      Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) = VKey(B));
    2:
      Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) < VKey(B));
    3:
      Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) <= VKey(B));
    4:
      Result := True;
    5:
      Result := VIsNaN(A) or VIsNaN(B) or (VKey(A) <> VKey(B));
    6:
      Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) >= VKey(B));
    7:
      Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) > VKey(B));
    8:
      Result := (A and $7FFFFFFF) = 0;
    9:
      Result := VIsNaN(A);
    10:
      Result := (A and $7FFFFFFF) = $7F800000;
    11:
      Result := (A and $7F800000) = $7F800000;
    12:
      Result := (A and $7FFFFFFF) <> 0;
    13:
      Result := not VIsNaN(A);
    14:
      Result := (A and $7FFFFFFF) <> $7F800000;
  else
    Result := (A and $7F800000) <> $7F800000;
  end;
end;

procedure OpVCMP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T: TV4;
  ReadS(C, Op, N, S);
  ReadT(C, Op, N, T);
  var Cond := Op and 15;
  var Bits: Cardinal := 0;
  for var I := 0 to N - 1 do
    if CmpTest(Cond, S[I], T[I]) then
      Bits := Bits or (Cardinal(1) shl I);
  var All := (Cardinal(1) shl N) - 1;
  if Bits <> 0 then
    Bits := Bits or $10;
  if (Bits and All) = All then
    Bits := Bits or $20;
  C.VcmpPC := C.CurPC;
  C.VcmpOld := C.Ctx.VC[VFPU_CC];
  C.VccWritePC := 0;
  // Lanes past the size keep their bits.
  C.Ctx.VC[VFPU_CC] := (C.Ctx.VC[VFPU_CC] and not (All or $30)) or Bits;
  EatPfx(C);
end;

{ Moves }

procedure DoMove(C: TPSPCPU; Op, SPfx, DPfx: Cardinal);
begin
  var N := VSz(Op);
  var S: TV4;
  var Z := ReadPfx(C, RegS(Op), N, SPfx, S);
  Latch(C, S, not Z and $F);
  WritePfx(C, RegD(Op), N, S, Z, DPfx);
  EatPfx(C);
end;

procedure OpVMOV(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS], C.Ctx.VC[VFPU_PFXD]);
end;

procedure OpVABS(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS] or $F00, C.Ctx.VC[VFPU_PFXD]);
end;

procedure OpVNEG(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS] or $F0000, C.Ctx.VC[VFPU_PFXD]);
end;

procedure OpVSAT0(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS], (C.Ctx.VC[VFPU_PFXD] and $F00) or $55);
end;

procedure OpVSAT1(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS], (C.Ctx.VC[VFPU_PFXD] and $F00) or $FF);
end;

procedure DoConst(C: TPSPCPU; Op: Cardinal; const V: TV4);
begin
  var N := VSz(Op);
  var D: TV4;
  var P := C.Ctx.VC[VFPU_PFXS];
  for var I := 0 to 3 do
    if ((P shr (16 + I)) and 1) <> 0 then
      D[I] := V[I] xor $80000000
    else
      D[I] := V[I];
  WriteD(C, Op, N, D, 0);
  EatPfx(C);
end;

procedure OpVZERO(C: TPSPCPU; Op: Cardinal);
const
  Z: TV4 = (0, 0, 0, 0);
begin
  DoConst(C, Op, Z);
end;

procedure OpVONE(C: TPSPCPU; Op: Cardinal);
begin
  DoConst(C, Op, Ones);
end;

procedure OpVIDT(C: TPSPCPU; Op: Cardinal);
begin
  var V: TV4 := Default(TV4);
  var K: Cardinal;
  if VSz(Op) = 2 then
    K := RegD(Op) and 1
  else
    K := RegD(Op) and 3;
  V[K] := VF_ONE;
  DoConst(C, Op, V);
end;

{ Function unit }

procedure DoFunc(C: TPSPCPU; Op: Cardinal; Fn: TUnFn);
begin
  var N := VSz(Op);
  var S, D: TV4;
  LoadV(C, RegS(Op), N, S);
  for var I := 0 to N - 2 do
    D[I] := Fn(S[I]);
  var Zero := False;
  var A := LastIn(C.Ctx.VC[VFPU_PFXS], S[N - 1], Zero);
  D[N - 1] := Fn(A);
  WriteLast(C, RegD(Op), N, D, Zero);
  EatPfx(C);
end;

procedure OpVRCP(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VRcp);
end;

procedure OpVRSQ(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VRsq);
end;

procedure OpVSIN(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VSin);
end;

procedure OpVCOS(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VCos);
end;

procedure OpVEXP2(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VExp2);
end;

procedure OpVLOG2(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VLog2);
end;

procedure OpVSQRT(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VSqrt);
end;

procedure OpVASIN(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VAsin);
end;

procedure OpVNRCP(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VNRcp);
end;

procedure OpVNSIN(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VNSin);
end;

procedure OpVREXP2(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VRExp2);
end;

{ Lane shuffles }

// The butterflies add a swizzled copy of S to S. With a T prefix pending, the
// two prefixed reads of S take the place of the swizzled pair, lane for lane.
procedure DoBfy(C: TPSPCPU; Op: Cardinal; const IA, IB: TIdx4; Subs: Cardinal);
begin
  var N := VSz(Op);
  var S, A, B, D: TV4;
  var Z := ReadS(C, Op, N, S);
  if C.Ctx.VC[VFPU_PFXT] = PFX_NONE then
    for var I := 0 to 3 do
    begin
      A[I] := S[IA[I]];
      B[I] := S[IB[I]];
    end
  else
  begin
    A := S;
    Z := Z or ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXT], B);
  end;
  for var I := 0 to 3 do
    if ((Subs shr I) and 1) <> 0 then
      D[I] := VSub(A[I], B[I])
    else
      D[I] := VAdd(A[I], B[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVBFY1(C: TPSPCPU; Op: Cardinal);
const
  IA: TIdx4 = (0, 0, 2, 2);
  IB: TIdx4 = (1, 1, 3, 3);
begin
  DoBfy(C, Op, IA, IB, $A);
end;

procedure OpVBFY2(C: TPSPCPU; Op: Cardinal);
const
  IA: TIdx4 = (0, 1, 0, 1);
  IB: TIdx4 = (2, 3, 2, 3);
begin
  DoBfy(C, Op, IA, IB, $C);
end;

function SortMin(A, B: Cardinal): Cardinal; inline;
begin
  if VKey(A) <= VKey(B) then
    Result := A
  else
    Result := B;
end;

function SortMax(A, B: Cardinal): Cardinal; inline;
begin
  if VKey(A) >= VKey(B) then
    Result := A
  else
    Result := B;
end;

procedure OpVSRT1(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMin(S[0], S[1]);
  D[1] := SortMax(S[0], S[1]);
  D[2] := SortMin(S[2], S[3]);
  D[3] := SortMax(S[2], S[3]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSRT2(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMin(S[0], S[3]);
  D[1] := SortMin(S[1], S[2]);
  D[2] := SortMax(S[1], S[2]);
  D[3] := SortMax(S[0], S[3]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSRT3(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMax(S[1], S[0]);
  D[1] := SortMin(S[1], S[0]);
  D[2] := SortMax(S[3], S[2]);
  D[3] := SortMin(S[3], S[2]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSRT4(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMax(S[3], S[0]);
  D[1] := SortMax(S[2], S[1]);
  D[2] := SortMin(S[2], S[1]);
  D[3] := SortMin(S[3], S[0]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVOCP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXS] or $F0000, S);
  for var I := 0 to N - 1 do
    D[I] := VAdd(S[I], VF_ONE);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSOCP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N * 2;
  if M > 4 then
    M := 4;
  for var I := 0 to (M div 2) - 1 do
  begin
    D[I * 2] := VSat0(VSub(VF_ONE, S[I]));
    D[I * 2 + 1] := VSat0(VAdd(S[I], 0));
  end;
  WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVSGN(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    var K := VKey(S[I]);
    if K > 0 then
      D[I] := VF_ONE
    else if K < 0 then
      D[I] := $BF800000
    else
      D[I] := 0;
  end;
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

{ Size-specialized arithmetic. Prefixes are runtime state even in a decoded block. }

procedure FloatBinary(C: TPSPCPU; Op: Cardinal; N, Kind: Integer); inline;
begin
  if (C.Ctx.VC[VFPU_PFXS] <> PFX_NONE) or (C.Ctx.VC[VFPU_PFXT] <> PFX_NONE) or (C.Ctx.VC[VFPU_PFXD] <> 0) then
  begin
    case Kind of
      0:
        OpVADD(C, Op);
      1:
        OpVSUB(C, Op);
      2:
        OpVMUL(C, Op);
    end;
    Exit;
  end;
  var S: PIdx4 := @VecIdx[N - 1, RegS(Op)];
  var T: PIdx4 := @VecIdx[N - 1, RegT(Op)];
  var D: PIdx4 := @VecIdx[N - 1, RegD(Op)];
  var R: TV4;
  for var I := 0 to N - 1 do
    case Kind of
      0:
        R[I] := VAdd(C.Ctx.V[S[I]], C.Ctx.V[T[I]]);
      1:
        R[I] := VSub(C.Ctx.V[S[I]], C.Ctx.V[T[I]]);
      2:
        R[I] := VMul(C.Ctx.V[S[I]], C.Ctx.V[T[I]]);
    end;
  for var I := 0 to N - 1 do
    C.Ctx.V[D[I]] := R[I];
end;

procedure OpVADD1(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 1, 0);
end;

procedure OpVADD2(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 2, 0);
end;

procedure OpVADD3(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 3, 0);
end;

procedure OpVADD4(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 4, 0);
end;

procedure OpVSUB1(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 1, 1);
end;

procedure OpVSUB2(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 2, 1);
end;

procedure OpVSUB3(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 3, 1);
end;

procedure OpVSUB4(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 4, 1);
end;

procedure OpVMUL1(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 1, 2);
end;

procedure OpVMUL2(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 2, 2);
end;

procedure OpVMUL3(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 3, 2);
end;

procedure OpVMUL4(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 4, 2);
end;

const
  FloatBinaryHandlers: array[0..2, 0..3] of TPSPOpHandler = (
    (OpVADD1, OpVADD2, OpVADD3, OpVADD4),
    (OpVSUB1, OpVSUB2, OpVSUB3, OpVSUB4),
    (OpVMUL1, OpVMUL2, OpVMUL3, OpVMUL4));

{ Float <-> integer }

// Mode 0 nearest even, 1 toward zero, 2 up, 3 down.
function FloatToInt(X: Cardinal; Scale: Integer; Mode: Integer): Cardinal;
begin
  if (X and $7FFFFFFF) > $7F800000 then
    Exit($7FFFFFFF);
  var E := Integer((X shr 23) and $FF);
  if E = 0 then
    Exit(0);
  var Neg := (X and $80000000) <> 0;
  var K := E - 150 + Scale;
  var Mag: UInt64;
  if K >= 8 then
    Mag := UInt64(1) shl 32
  else
  begin
    var M := UInt64((X and $7FFFFF) or $800000);
    if K >= 0 then
      Mag := M shl K
    else if K <= -26 then
    begin
      // Below one half: only rounding away from zero can make it 1.
      Mag := 0;
      if ((Mode = 2) and not Neg) or ((Mode = 3) and Neg) then
        Mag := 1;
    end
    else
    begin
      var Sh := -K;
      Mag := M shr Sh;
      var Rem := M and ((UInt64(1) shl Sh) - 1);
      var Half := UInt64(1) shl (Sh - 1);
      case Mode of
        0:
          if (Rem > Half) or ((Rem = Half) and ((Mag and 1) <> 0)) then
            Inc(Mag);
        2:
          if (Rem <> 0) and not Neg then
            Inc(Mag);
        3:
          if (Rem <> 0) and Neg then
            Inc(Mag);
      end;
    end;
  end;
  if Neg then
  begin
    if Mag >= UInt64($80000000) then
      Exit($80000000);
    Result := Cardinal(-Int64(Mag));
  end
  else
  begin
    if Mag >= UInt64($80000000) then
      Exit($7FFFFFFF);
    Result := Cardinal(Mag);
  end;
end;

procedure DoF2I(C: TPSPCPU; Op: Cardinal; Mode: Integer);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  var Scale := Integer((Op shr 16) and 31);
  for var I := 0 to N - 1 do
    D[I] := FloatToInt(S[I], Scale, Mode);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVF2IN(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 0);
end;

procedure OpVF2IZ(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 1);
end;

procedure OpVF2IU(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 2);
end;

procedure OpVF2ID(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 3);
end;

procedure OpVI2F(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  var Scale := Integer((Op shr 16) and 31);
  for var I := 0 to N - 1 do
  begin
    var F: Single := Double(Integer(S[I])) * Power(2.0, -Scale);
    D[I] := VFlush(SingleToBits(F));
  end;
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

{ Half floats }

function FloatToHalf(X: Cardinal): Cardinal;
begin
  var Sign := (X shr 16) and $8000;
  var E := Integer((X shr 23) and $FF);
  var M := X and $7FFFFF;
  if E = $FF then
  begin
    if M <> 0 then
      Exit(Sign or $7C00 or (M and $3FF));
    Exit(Sign or $7C00);
  end;
  var HE := E - 127 + 15;
  if HE >= 31 then
    Exit(Sign or $7C00);
  if HE <= 0 then
    Exit(Sign);
  var HM := M shr 13;
  if (M and $1FFF) > $1000 then
  begin
    Inc(HM);
    if HM = $400 then
    begin
      HM := 0;
      Inc(HE);
      if HE >= 31 then
        Exit(Sign or $7C00);
    end;
  end;
  Result := Sign or (Cardinal(HE) shl 10) or HM;
end;

function HalfToFloat(H: Cardinal): Cardinal;
begin
  var Sign := (H and $8000) shl 16;
  var E := (H shr 10) and 31;
  var M := H and $3FF;
  if E = 31 then
    Result := Sign or $7F800000 or M
  else if E = 0 then
    Result := Sign
  else
    Result := Sign or ((E + 112) shl 23) or (M shl 13);
end;

procedure OpVF2H(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
    D[I] := FloatToHalf(S[I * 2]) or (FloatToHalf(S[I * 2 + 1]) shl 16);
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVH2F(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  if N > 2 then
    N := 2;
  var S, D: TV4;
  ReadS(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    D[I * 2] := HalfToFloat(S[I] and $FFFF);
    D[I * 2 + 1] := HalfToFloat(S[I] shr 16);
  end;
  WriteD(C, Op, N * 2, D, 0);
  EatPfx(C);
end;

{ Packed integers }

procedure OpVUC2I(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  ReadSL(C, Op, 1, S);
  for var I := 0 to 3 do
    D[I] := (((S[0] shr (I * 8)) and $FF) * $01010101) shr 1;
  WriteD(C, Op, 4, D, 0);
  EatPfx(C);
end;

procedure OpVC2I(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  ReadSL(C, Op, 1, S);
  for var I := 0 to 3 do
    D[I] := ((S[0] shr (I * 8)) and $FF) shl 24;
  WriteD(C, Op, 4, D, 0);
  EatPfx(C);
end;

procedure OpVUS2I(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  if N > 2 then
    N := 2;
  var S, D: TV4;
  ReadSL(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    D[I * 2] := (S[I] and $FFFF) shl 15;
    D[I * 2 + 1] := (S[I] shr 16) shl 15;
  end;
  WriteD(C, Op, N * 2, D, 0);
  EatPfx(C);
end;

procedure OpVS2I(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  if N > 2 then
    N := 2;
  var S, D: TV4;
  ReadSL(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    D[I * 2] := (S[I] and $FFFF) shl 16;
    D[I * 2 + 1] := S[I] and $FFFF0000;
  end;
  WriteD(C, Op, N * 2, D, 0);
  EatPfx(C);
end;

procedure OpVI2UC(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var R: Cardinal := 0;
  for var I := 0 to N - 1 do
    if Integer(S[I]) > 0 then
      R := R or (((S[I] shr 23) and $FF) shl (I * 8));
  D[0] := R;
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVI2C(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var R: Cardinal := 0;
  for var I := 0 to N - 1 do
    R := R or ((S[I] shr 24) shl (I * 8));
  D[0] := R;
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVI2US(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
  begin
    var Lo: Cardinal := 0;
    var Hi: Cardinal := 0;
    if Integer(S[I * 2]) > 0 then
      Lo := (S[I * 2] shr 15) and $FFFF;
    if Integer(S[I * 2 + 1]) > 0 then
      Hi := (S[I * 2 + 1] shr 15) and $FFFF;
    D[I] := Lo or (Hi shl 16);
  end;
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVI2S(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
    D[I] := (S[I * 2] shr 16) or (S[I * 2 + 1] and $FFFF0000);
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

{ Colours }

function Pack4444(X: Cardinal): Cardinal; inline;
begin
  Result := ((X shr 4) and $F) or ((X shr 8) and $F0) or ((X shr 12) and $F00) or ((X shr 16) and $F000);
end;

function Pack5551(X: Cardinal): Cardinal; inline;
begin
  Result := ((X shr 3) and $1F) or ((X shr 6) and $3E0) or ((X shr 9) and $7C00) or ((X shr 16) and $8000);
end;

function Pack5650(X: Cardinal): Cardinal; inline;
begin
  Result := ((X shr 3) and $1F) or ((X shr 5) and $7E0) or ((X shr 8) and $F800);
end;

procedure DoColor(C: TPSPCPU; Op: Cardinal; Kind: Integer);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
    case Kind of
      0:
        D[I] := Pack4444(S[I * 2]) or (Pack4444(S[I * 2 + 1]) shl 16);
      1:
        D[I] := Pack5551(S[I * 2]) or (Pack5551(S[I * 2 + 1]) shl 16);
    else
      D[I] := Pack5650(S[I * 2]) or (Pack5650(S[I * 2 + 1]) shl 16);
    end;
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVT4444(C: TPSPCPU; Op: Cardinal);
begin
  DoColor(C, Op, 0);
end;

procedure OpVT5551(C: TPSPCPU; Op: Cardinal);
begin
  DoColor(C, Op, 1);
end;

procedure OpVT5650(C: TPSPCPU; Op: Cardinal);
begin
  DoColor(C, Op, 2);
end;

{ Exponent tricks }

procedure OpVSBZ(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  var Z := ReadS(C, Op, 1, S);
  D[0] := (S[0] and $807FFFFF) or $3F800000;
  WriteD(C, Op, 1, D, Z);
  EatPfx(C);
end;

procedure OpVLGB(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  var Z := ReadS(C, Op, 1, S);
  var F: Single := Integer((S[0] shr 23) and $FF) - 127;
  D[0] := SingleToBits(F);
  WriteD(C, Op, 1, D, Z);
  EatPfx(C);
end;

// The exponent becomes the immediate; the mantissa (with its hidden bit) is
// shifted left by the old exponent's low four bits and wraps.
procedure OpVWBN(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  var Z := ReadS(C, Op, 1, S);
  var E := (S[0] shr 23) and $FF;
  var M := S[0] and $7FFFFF;
  if E <> 0 then
    M := M or $800000;
  D[0] := (S[0] and $80000000) or (((Op shr 16) and $FF) shl 23) or ((M shl (E and 15)) and $7FFFFF);
  WriteD(C, Op, 1, D, Z);
  EatPfx(C);
end;

{ Constants and immediates }

const
  VcstTable: array[0..31] of Cardinal = (
    $00000000, $7F7FFFFF, $3FB504F3, $3F3504F3, $3F906EBB, $3F22F983, $3EA2F983, $3F490FDB,
    $3FC90FDB, $40490FDB, $402DF854, $3FB8AA3B, $3EDE5BD9, $3F317218, $40135D8E, $40C90FDB,
    $3F060A92, $3E9A209B, $40549A78, $3F5DB3D7, $00000000, $00000000, $00000000, $00000000,
    $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000);

procedure OpVCST(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var D: TV4;
  var V := VcstTable[(Op shr 16) and 31];
  for var I := 0 to 3 do
    D[I] := V;
  WriteD(C, Op, N, D, 0);
  EatPfx(C);
end;

procedure OpVIIM(C: TPSPCPU; Op: Cardinal);
begin
  var F: Single := SmallInt(Word(Op));
  C.Ctx.V[VecIdx[0, RegT(Op)][0]] := SingleToBits(F);
end;

procedure OpVFIM(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.V[VecIdx[0, RegT(Op)][0]] := HalfToFloat(Op and $FFFF);
end;

{ Conditional move }

procedure OpVCMOV(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S: TV4;
  var Z := ReadS(C, Op, N, S);
  var Imm := (Op shr 16) and 7;
  var IfFalse := ((Op shr 19) and 1) <> 0;
  var CC := C.Ctx.VC[VFPU_CC];
  var Keep: Cardinal := 0;
  for var I := 0 to N - 1 do
  begin
    var Cond: Boolean;
    if Imm < 6 then
      Cond := ((CC shr Imm) and 1) <> 0
    else if Imm = 6 then
      Cond := ((CC shr I) and 1) <> 0
    else
      Cond := False;
    if Cond = IfFalse then
      Keep := Keep or (Cardinal(1) shl (8 + I));
  end;
  WritePfx(C, RegD(Op), N, S, Z, C.Ctx.VC[VFPU_PFXD] or Keep);
  EatPfx(C);
end;

{ Random numbers }

// The generator is three 32-bit sources added together: a 69069x+1 congruential
// one, a 13/17/5 xorshift and a lag-2 add-with-carry (x' = 2x + x_prev + c). RCXi
// holds the low halves of the four words in i and the high halves in i+4, as
// the mantissas of numbers in [1, 2); the carry is spread over bits 16-19.
procedure RndUnpack(C: TPSPCPU; var W: TV4; var Carry: Cardinal);
begin
  Carry := 0;
  for var I := 0 to 3 do
    W[I] := (C.Ctx.VC[VFPU_RCX0 + I] and $FFFF) or ((C.Ctx.VC[VFPU_RCX0 + 4 + I] and $FFFF) shl 16);
  for var I := 0 to 7 do
    Carry := Carry or (((C.Ctx.VC[VFPU_RCX0 + I] shr 16) and $F) shl (I * 4));
end;

procedure RndPack(C: TPSPCPU; const W: TV4; Carry: Cardinal);
begin
  for var I := 0 to 3 do
  begin
    C.Ctx.VC[VFPU_RCX0 + I] := $3F800000 or (W[I] and $FFFF) or (((Carry shr (I * 4)) and $F) shl 16);
    C.Ctx.VC[VFPU_RCX0 + 4 + I] := $3F800000 or (W[I] shr 16) or (((Carry shr (16 + I * 4)) and $F) shl 16);
  end;
end;

function RndNext(C: TPSPCPU): Cardinal;
begin
  var W: TV4;
  var Carry: Cardinal;
  RndUnpack(C, W, Carry);
  W[0] := W[0] * 69069 + 1;
  var J := W[1];
  J := J xor (J shl 13);
  J := J xor (J shr 17);
  J := J xor (J shl 5);
  W[1] := J;
  // The carry kept for the next step isn't this sum's: it is the overflow of
  // 2*prev + x + c past 2^32, less one, where x above prev adds up to c more.
  var T := UInt64(W[2]) * 2 + W[3] + Carry;
  if W[3] > W[2] then
    if W[3] - W[2] < Carry then
      Inc(T, W[3] - W[2])
    else
      Inc(T, Carry);
  var S := Cardinal(UInt64(W[3]) * 2 + W[2] + Carry);
  W[2] := W[3];
  W[3] := S;
  Carry := Cardinal(T shr 32);
  if Carry > 0 then
    Dec(Carry);
  RndPack(C, W, Carry);
  Result := W[0] + W[1] + W[3];
end;

procedure OpVRNDS(C: TPSPCPU; Op: Cardinal);
begin
  var Seed := C.Ctx.V[VecIdx[0, RegS(Op)][0]];
  var W: TV4;
  for var I := 0 to 3 do
    W[I] := Seed;
  RndPack(C, W, Seed);
  EatPfx(C);
end;

// Lanes are drawn from the last one down; only the first draw sees the D prefix.
procedure DoRnd(C: TPSPCPU; Op: Cardinal; Kind: Integer);
begin
  var N := VSz(Op);
  var D: TV4;
  for var I := N - 1 downto 0 do
  begin
    var X := RndNext(C);
    case Kind of
      0:
        D[I] := X;
      1:
        D[I] := $3F800000 or (X and $7FFFFF);
    else
      D[I] := $40000000 or (X and $7FFFFF);
    end;
  end;
  WriteLast(C, RegD(Op), N, D, False);
  EatPfx(C);
end;

procedure OpVRNDI(C: TPSPCPU; Op: Cardinal);
begin
  DoRnd(C, Op, 0);
end;

procedure OpVRNDF1(C: TPSPCPU; Op: Cardinal);
begin
  DoRnd(C, Op, 1);
end;

procedure OpVRNDF2(C: TPSPCPU; Op: Cardinal);
begin
  DoRnd(C, Op, 2);
end;

{ Control registers }

function ReadCtrl(C: TPSPCPU; Index: Cardinal): Cardinal; inline;
begin
  if Index < 16 then
    Result := C.Ctx.VC[Index]
  else
    Result := 0;
end;

procedure WriteCtrl(C: TPSPCPU; Index, Value: Cardinal);
begin
  case Index of
    0, 1:
      C.Ctx.VC[Index] := Value and $FFFFF;
    2:
      C.Ctx.VC[Index] := Value and $FFF;
    3:
      C.Ctx.VC[Index] := Value and $3F;
    4..6:
      C.Ctx.VC[Index] := Value;
    8..15:
      C.Ctx.VC[Index] := $3F800000 or (Value and $FFFFF);
  end;
end;

procedure OpVMFVC(C: TPSPCPU; Op: Cardinal);
begin
  var D: TV4;
  D[0] := ReadCtrl(C, RegS(Op));
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVMTVC(C: TPSPCPU; Op: Cardinal);
begin
  WriteCtrl(C, RegD(Op), C.Ctx.V[VecIdx[0, RegS(Op)][0]]);
  EatPfx(C);
end;

{ Matrices }

type
  TM4 = array[0..3] of TV4;

procedure LoadM(C: TPSPCPU; Reg: Cardinal; N: Integer; var M: TM4);
begin
  if N = 4 then
  begin
    for var K := 0 to 3 do
    begin
      var P: PIdx4 := @MatIdx[3, Reg, K];
      M[K][0] := C.Ctx.V[P[0]];
      M[K][1] := C.Ctx.V[P[1]];
      M[K][2] := C.Ctx.V[P[2]];
      M[K][3] := C.Ctx.V[P[3]];
    end;
    Exit;
  end;
  for var K := 0 to 3 do
    for var I := 0 to 3 do
      if (K < N) and (I < N) then
        M[K][I] := C.Ctx.V[MatIdx[N - 1, Reg, K][I]]
      else
        M[K][I] := 0;
end;

procedure StoreM(C: TPSPCPU; Reg: Cardinal; N: Integer; const M: TM4);
begin
  for var K := 0 to N - 1 do
    for var I := 0 to N - 1 do
      C.Ctx.V[MatIdx[N - 1, Reg, K][I]] := M[K][I];
end;

procedure OpVMMUL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TM4;
  LoadM(C, RegS(Op), N, S);
  LoadM(C, RegT(Op), N, T);
  for var I := 0 to N - 1 do
    for var J := 0 to N - 1 do
      D[I][J] := VSum4(S[J], T[I], N, 0);
  StoreM(C, RegD(Op), N, D);
  EatPfx(C);
end;

// vtfmN/vhtfmN: the function picks the matrix size, the size field how much
// of the vector is real; a short vector is padded with zeros and a final 1.
procedure OpVTFM(C: TPSPCPU; Op: Cardinal);
begin
  var N := Integer((Op shr 23) and 7) + 1;
  var Sz := VSz(Op);
  var M: TM4;
  var T, Raw, D: TV4;
  LoadM(C, RegS(Op), N, M);
  var Real := Sz;
  if Real > N then
    Real := N;
  LoadV(C, RegT(Op), Real, Raw);
  for var K := 0 to 3 do
    if K < Real then
      T[K] := Raw[K]
    else
      T[K] := 0;
  if Sz < N then
    T[N - 1] := VF_ONE;
  for var I := 0 to N - 2 do
    D[I] := VSum4(M[I], T, N, 0);
  var PS := C.Ctx.VC[VFPU_PFXS];
  var PT := C.Ctx.VC[VFPU_PFXT];
  if (PS = PFX_NONE) and (PT = PFX_NONE) then
    D[N - 1] := VSum4(M[N - 1], T, N, 0)
  else
  begin
    var S2, T2: TV4;
    var Z := ApplyPfx(M[N - 1], N, PS, S2) or ApplyPfx(T, N, PT, T2);
    D[N - 1] := VSum4(S2, T2, N, Z);
  end;
  WriteLast(C, RegD(Op), N, D, False);
  EatPfx(C);
end;

procedure OpVMSCL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TM4;
  LoadM(C, RegS(Op), N, S);
  var T := C.Ctx.V[VecIdx[0, RegT(Op)][0]];
  for var K := 0 to N - 1 do
    for var I := 0 to N - 1 do
      D[K][I] := VMul(S[K][I], T);
  StoreM(C, RegD(Op), N, D);
  EatPfx(C);
end;

function Sum2(A, B, X, Y: Cardinal): Cardinal; inline;
var
  P, Q: TV4;
begin
  P[0] := A;
  P[1] := X;
  Q[0] := B;
  Q[1] := Y;
  Result := VSum4(P, Q, 2, 0);
end;

procedure OpVCRSPQMUL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  LoadV(C, RegS(Op), N, S);
  LoadV(C, RegT(Op), N, T);
  var Zero := False;
  LastIn(C.Ctx.VC[VFPU_PFXS], 0, Zero);
  LastIn(C.Ctx.VC[VFPU_PFXT], 0, Zero);
  case N of
    3:
      begin
        // Lane by lane, z first, each from the register file as it stands.
        var P: PIdx4 := @VecIdx[2, RegD(Op)];
        var DPfx := C.Ctx.VC[VFPU_PFXD];
        var Z := Sum2(S[0], T[1], S[1] xor $80000000, T[0]);
        if Zero then
          Z := 0;
        if (DPfx and $100) = 0 then
          C.Ctx.V[P[2]] := SatLane(Z, DPfx and 3);
        LoadV(C, RegS(Op), N, S);
        LoadV(C, RegT(Op), N, T);
        C.Ctx.V[P[1]] := Sum2(S[2], T[0], S[0] xor $80000000, T[2]);
        LoadV(C, RegS(Op), N, S);
        LoadV(C, RegT(Op), N, T);
        C.Ctx.V[P[0]] := Sum2(S[1], T[2], S[2] xor $80000000, T[1]);
        EatPfx(C);
        Exit;
      end;
    4:
      begin
        var P, Q: TV4;
        P[0] := S[0];
        P[1] := S[1];
        P[2] := S[2] xor $80000000;
        P[3] := S[3];
        Q[0] := T[3];
        Q[1] := T[2];
        Q[2] := T[1];
        Q[3] := T[0];
        D[0] := VSum4(P, Q, 4, 0);
        P[0] := S[0] xor $80000000;
        P[1] := S[1];
        P[2] := S[2];
        P[3] := S[3];
        Q[0] := T[2];
        Q[1] := T[3];
        Q[2] := T[0];
        Q[3] := T[1];
        D[1] := VSum4(P, Q, 4, 0);
        P[0] := S[0];
        P[1] := S[1] xor $80000000;
        P[2] := S[2];
        P[3] := S[3];
        Q[0] := T[1];
        Q[1] := T[0];
        Q[2] := T[3];
        Q[3] := T[2];
        D[2] := VSum4(P, Q, 4, 0);
        P[0] := S[0] xor $80000000;
        P[1] := S[1] xor $80000000;
        P[2] := S[2] xor $80000000;
        P[3] := S[3];
        Q[0] := T[0];
        Q[1] := T[1];
        Q[2] := T[2];
        Q[3] := T[3];
        D[3] := VSum4(P, Q, 4, 0);
      end;
  else
    D := Default(TV4);
    Zero := False;
  end;
  WriteLast(C, RegD(Op), N, D, Zero);
  EatPfx(C);
end;

procedure OpVMMOV(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S: TM4;
  LoadM(C, RegS(Op), N, S);
  StoreM(C, RegD(Op), N, S);
  EatPfx(C);
end;

procedure DoMatFill(C: TPSPCPU; Op: Cardinal; Kind: Integer);
begin
  var N := VSz(Op);
  var D: TM4;
  for var K := 0 to 3 do
    for var I := 0 to 3 do
      case Kind of
        0:
          D[K][I] := 0;
        1:
          D[K][I] := VF_ONE;
      else
        if K = I then
          D[K][I] := VF_ONE
        else
          D[K][I] := 0;
      end;
  StoreM(C, RegD(Op), N, D);
  EatPfx(C);
end;

procedure OpVMIDT(C: TPSPCPU; Op: Cardinal);
begin
  DoMatFill(C, Op, 2);
end;

procedure OpVMZERO(C: TPSPCPU; Op: Cardinal);
begin
  DoMatFill(C, Op, 0);
end;

procedure OpVMONE(C: TPSPCPU; Op: Cardinal);
begin
  DoMatFill(C, Op, 1);
end;

// The sine lanes (and zeros) are written first, the cosine after, from the
// angle register as it is then.
procedure OpVROT(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var AngleIdx := VecIdx[0, RegS(Op)][0];
  var Imm := (Op shr 16) and 31;
  var Zero := False;
  var SA := LastIn(C.Ctx.VC[VFPU_PFXS], C.Ctx.V[AngleIdx], Zero);
  var Si: Cardinal := 0;
  if not Zero then
    Si := VSin(SA);
  if (Imm and 16) <> 0 then
    Si := Si xor $80000000;
  var CL := Integer(Imm and 3);
  var SL := Integer((Imm shr 2) and 3);
  var D: TV4;
  for var I := 0 to 3 do
    if (SL = CL) or (I = SL) then
      D[I] := Si
    else
      D[I] := 0;
  StoreV(C, RegD(Op), N, D);
  if CL < N then
    C.Ctx.V[VecIdx[N - 1, RegD(Op)][CL]] := VCos(C.Ctx.V[AngleIdx]);
  EatPfx(C);
end;

{ Prefixes and no-ops }

procedure OpVPFXS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.VC[VFPU_PFXS] := Op and $FFFFF;
end;

procedure OpVPFXT(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.VC[VFPU_PFXT] := Op and $FFFFF;
end;

procedure OpVPFXD(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.VC[VFPU_PFXD] := Op and $FFF;
end;

procedure OpVNOP(C: TPSPCPU; Op: Cardinal);
begin
end;

{ Loads and stores }

procedure OpLVS(C: TPSPCPU; Op: Cardinal);
begin
  var Reg := ((Op shr 16) and $1F) or ((Op and 3) shl 5);
  C.Ctx.V[VecIdx[0, Reg][0]] := C.Memory.Read32(GPRs(C, Op) + Imm16(Op));
end;

procedure OpSVS(C: TPSPCPU; Op: Cardinal);
begin
  var Reg := ((Op shr 16) and $1F) or ((Op and 3) shl 5);
  C.Memory.Write32(GPRs(C, Op) + Imm16(Op), C.Ctx.V[VecIdx[0, Reg][0]]);
end;

function QuadReg(Op: Cardinal): Cardinal; inline;
begin
  Result := ((Op shr 16) and $1F) or ((Op and 1) shl 5);
end;

procedure OpLVQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  for var I := 0 to 3 do
    C.Ctx.V[P[I]] := C.Memory.Read32(A + Cardinal(I) * 4);
end;

procedure OpSVQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  for var I := 0 to 3 do
    C.Memory.Write32(A + Cardinal(I) * 4, C.Ctx.V[P[I]]);
end;

procedure OpLVLRQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  var K := Integer((A shr 2) and 3);
  if (Op and 2) = 0 then
  begin
    var Base := A and not Cardinal($F);
    for var I := 0 to K do
      C.Ctx.V[P[3 - K + I]] := C.Memory.Read32(Base + Cardinal(I) * 4);
  end
  else
    for var I := 0 to 3 - K do
      C.Ctx.V[P[I]] := C.Memory.Read32(A + Cardinal(I) * 4);
end;

procedure OpSVLRQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  var K := Integer((A shr 2) and 3);
  if (Op and 2) = 0 then
  begin
    var Base := A and not Cardinal($F);
    for var I := 0 to K do
      C.Memory.Write32(Base + Cardinal(I) * 4, C.Ctx.V[P[3 - K + I]]);
  end
  else
    for var I := 0 to 3 - K do
      C.Memory.Write32(A + Cardinal(I) * 4, C.Ctx.V[P[I]]);
end;

{ COP2 moves and branches }

// mfvc right behind a vcmp still reads the CC from before it.
procedure OpMFV(C: TPSPCPU; Op: Cardinal);
begin
  var T := (Op shr 16) and 31;
  if T = 0 then
    Exit;
  if (Op and $80) = 0 then
    C.Ctx.GPR[T] := C.Ctx.V[VecIdx[0, Op and $7F][0]]
  else if ((Op and $7F) = VFPU_CC) and (C.CurPC = C.VcmpPC + 4) then
    C.Ctx.GPR[T] := C.VcmpOld
  else
    C.Ctx.GPR[T] := ReadCtrl(C, Op and $7F);
end;

// A CC written with mtvc reaches the branch unit a few instructions later,
// unless a vcmp right before it holds the pipeline.
procedure OpMTV(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[(Op shr 16) and 31];
  if (Op and $80) = 0 then
    C.Ctx.V[VecIdx[0, Op and $7F][0]] := V
  else
  begin
    if (Op and $7F) = VFPU_CC then
    begin
      if C.CurPC = C.VcmpPC + 4 then
        C.VccWritePC := 0
      else
      begin
        C.VccWritePC := C.CurPC;
        C.VccWriteOld := C.Ctx.VC[VFPU_CC];
      end;
    end;
    WriteCtrl(C, Op and $7F, V);
  end;
end;

procedure OpBVC(C: TPSPCPU; Op: Cardinal);
begin
  var CC := C.Ctx.VC[VFPU_CC];
  if (C.VccWritePC <> 0) and (C.CurPC - C.VccWritePC <= 12) then
    CC := C.VccWriteOld;
  var Bit := ((CC shr ((Op shr 18) and 7)) and 1) <> 0;
  var Kind := (Op shr 16) and 3;
  var Taken := Bit = ((Kind and 1) <> 0);
  if Taken then
    C.Ctx.NPC := C.CurPC + 4 + (Cardinal(Integer(SmallInt(Word(Op)))) shl 2)
  else if (Kind and 2) <> 0 then
  begin
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
  end;
end;

{ Decoder }

function DecodeVFPU4(Op: Cardinal): TPSPOpHandler;
begin
  var Sub := (Op shr 16) and 31;
  Result := OpReserved;
  case (Op shr 21) and 31 of
    0:
      case Sub of
        $00:
          Result := OpVMOV;
        $01:
          Result := OpVABS;
        $02:
          Result := OpVNEG;
        $03:
          Result := OpVIDT;
        $04:
          Result := OpVSAT0;
        $05:
          Result := OpVSAT1;
        $06:
          Result := OpVZERO;
        $07:
          Result := OpVONE;
        $10:
          Result := OpVRCP;
        $11:
          Result := OpVRSQ;
        $12:
          Result := OpVSIN;
        $13:
          Result := OpVCOS;
        $14:
          Result := OpVEXP2;
        $15:
          Result := OpVLOG2;
        $16:
          Result := OpVSQRT;
        $17:
          Result := OpVASIN;
        $18:
          Result := OpVNRCP;
        $1A:
          Result := OpVNSIN;
        $1C:
          Result := OpVREXP2;
      end;
    1:
      case Sub of
        $00:
          Result := OpVRNDS;
        $01:
          Result := OpVRNDI;
        $02:
          Result := OpVRNDF1;
        $03:
          Result := OpVRNDF2;
        $12:
          Result := OpVF2H;
        $13:
          Result := OpVH2F;
        $16:
          Result := OpVSBZ;
        $17:
          Result := OpVLGB;
        $18:
          Result := OpVUC2I;
        $19:
          Result := OpVC2I;
        $1A:
          Result := OpVUS2I;
        $1B:
          Result := OpVS2I;
        $1C:
          Result := OpVI2UC;
        $1D:
          Result := OpVI2C;
        $1E:
          Result := OpVI2US;
        $1F:
          Result := OpVI2S;
      end;
    2:
      case Sub of
        $00:
          Result := OpVSRT1;
        $01:
          Result := OpVSRT2;
        $02:
          Result := OpVBFY1;
        $03:
          Result := OpVBFY2;
        $04:
          Result := OpVOCP;
        $05:
          Result := OpVSOCP;
        $06:
          Result := OpVFAD;
        $07:
          Result := OpVAVG;
        $08:
          Result := OpVSRT3;
        $09:
          Result := OpVSRT4;
        $0A:
          Result := OpVSGN;
        $10:
          Result := OpVMFVC;
        $11:
          Result := OpVMTVC;
        $19:
          Result := OpVT4444;
        $1A:
          Result := OpVT5551;
        $1B:
          Result := OpVT5650;
      end;
    3:
      Result := OpVCST;
    $10:
      Result := OpVF2IN;
    $11:
      Result := OpVF2IZ;
    $12:
      Result := OpVF2IU;
    $13:
      Result := OpVF2ID;
    $14:
      Result := OpVI2F;
    $15:
      Result := OpVCMOV;
    $18..$1F:
      Result := OpVWBN;
  end;
end;

function DecodeVFPU6(Op: Cardinal): TPSPOpHandler;
begin
  case (Op shr 23) and 7 of
    0:
      Result := OpVMMUL;
    1, 2, 3:
      Result := OpVTFM;
    4:
      Result := OpVMSCL;
    5:
      Result := OpVCRSPQMUL;
    7:
      if ((Op shr 21) and 3) = 1 then
        Result := OpVROT
      else if ((Op shr 21) and 3) = 0 then
        case (Op shr 16) and 31 of
          0:
            Result := OpVMMOV;
          3:
            Result := OpVMIDT;
          6:
            Result := OpVMZERO;
          7:
            Result := OpVMONE;
        else
          Result := OpReserved;
        end
      else
        Result := OpReserved;
  else
    Result := OpReserved;
  end;
end;

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;
begin
  Result := OpReserved;
  case Op shr 26 of
    $12:
      case (Op shr 21) and 31 of
        3:
          Result := OpMFV;
        7:
          Result := OpMTV;
        8:
          Result := OpBVC;
      end;
    $18:
      case (Op shr 23) and 7 of
        0:
          Result := FloatBinaryHandlers[0, VSz(Op) - 1];
        1:
          Result := FloatBinaryHandlers[1, VSz(Op) - 1];
        2:
          Result := OpVSBN;
        7:
          Result := OpVDIV;
      end;
    $19:
      case (Op shr 23) and 7 of
        0:
          Result := FloatBinaryHandlers[2, VSz(Op) - 1];
        1:
          Result := OpVDOT;
        2:
          Result := OpVSCL;
        4:
          Result := OpVHDP;
        5:
          Result := OpVCRS;
        6:
          Result := OpVDET;
      end;
    $1B:
      case (Op shr 23) and 7 of
        0:
          Result := OpVCMP;
        2:
          Result := OpVMIN;
        3:
          Result := OpVMAX;
        5:
          Result := OpVSCMP;
        6:
          Result := OpVSGE;
        7:
          Result := OpVSLT;
      end;
    $32:
      Result := OpLVS;
    $34:
      Result := DecodeVFPU4(Op);
    $35:
      Result := OpLVLRQ;
    $36:
      Result := OpLVQ;
    $37:
      case (Op shr 23) and 7 of
        0, 1:
          Result := OpVPFXS;
        2, 3:
          Result := OpVPFXT;
        4, 5:
          Result := OpVPFXD;
        6:
          Result := OpVIIM;
        7:
          Result := OpVFIM;
      end;
    $3A:
      Result := OpSVS;
    $3C:
      Result := DecodeVFPU6(Op);
    $3D:
      Result := OpSVLRQ;
    $3E:
      Result := OpSVQ;
    $3F:
      if (Op shr 16) = $FFFF then
        Result := OpVNOP;
  end;
end;

initialization
  InitTables;
  PSPVFPUDecoder := DecodeVFPU;

end.
