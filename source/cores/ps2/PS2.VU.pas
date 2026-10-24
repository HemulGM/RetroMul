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
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types, PS2.EE.CPU;

type
  TPS2VFArray = array[0..31] of TPS2Reg128;
  PPS2VFArray = ^TPS2VFArray;
  TPS2VIArray = array[0..31] of Cardinal;
  PPS2VIArray = ^TPS2VIArray;

  TPS2VUKick = procedure(Address: Cardinal) of object;

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
  end;

  TPS2VUCore = class
  private
    FIndex: Integer;
    FVF: PPS2VFArray;
    FVI: PPS2VIArray;
    FCode, FData: PByte;
    FCodeMask, FDataMask: Cardinal;
    FOnKick: TPS2VUKick;
    // Results of the current pair (written after both halves ran).
    FUpperReg, FLowerReg: Integer;
    FUpperValue, FLowerValue: TPS2Reg128;
    FUpperMask, FLowerMask: Cardinal;
    procedure SetFlags(const R: TPS2Reg128; Dest: Cardinal; Flags: Cardinal);
    function FAdd(A, B: Cardinal; var Flags: Cardinal): Cardinal; inline;
    function FMul(A, B: Cardinal; var Flags: Cardinal): Cardinal;
    procedure Upper(Op: Cardinal; Micro: Boolean);
    procedure Lower(Op: Cardinal);
    procedure LowerSpecial(Op: Cardinal);
    procedure CommitVF(Reg: Integer; const V: TPS2Reg128; Dest: Cardinal);
    function DataAddress(Base: Cardinal): PPS2Reg128; inline;
    function Bc(const V: TPS2Reg128; Op: Cardinal): Cardinal; inline;
  public
    S: TPS2VUState;
    // Micro instructions executed (diagnostics).
    Executed: Int64;
    constructor Create(Index: Integer; VF: PPS2VFArray; VI: PPS2VIArray; Code, Data: PByte;
      CodeSize, DataSize: Cardinal);
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
  public
    constructor Create(Code, Data: PByte);
    destructor Destroy; override;
    procedure Reset; override;
    function ReadControl(Index: Integer): Cardinal; override;
    procedure WriteControl(Index: Integer; Value: Cardinal); override;
    function Execute(Op: Cardinal): Boolean; override;
    procedure Interlock; override;
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
  Reset;
end;

procedure TPS2VUCore.Reset;
begin
  S := Default(TPS2VUState);
  S.Q := $3F800000;
  S.R := $3F800000;
  FVF[0].UW[0] := 0;
  FVF[0].UW[1] := 0;
  FVF[0].UW[2] := 0;
  FVF[0].UW[3] := $3F800000;
end;

function TPS2VUCore.FAdd(A, B: Cardinal; var Flags: Cardinal): Cardinal;
var
  F: Cardinal;
begin
  Result := PS2FloatAdd(A, B, F);
  Flags := Flags or F;
end;

function TPS2VUCore.FMul(A, B: Cardinal; var Flags: Cardinal): Cardinal;
begin
  if ((A and $7F800000) = 0) or ((B and $7F800000) = 0) then
    Exit((A xor B) and $80000000);
  var D := EEFloatIn(A) * EEFloatIn(B);
  var Bits := PUInt64(@D)^;
  var Sign := Cardinal(Bits shr 32) and $80000000;
  var E := Integer((Bits shr 52) and $7FF) - (1023 - 127);
  if E > 255 then
  begin
    Flags := Flags or 1;
    Exit(Sign or $7FFFFFFF);
  end;
  if E <= 0 then
  begin
    Flags := Flags or 2;
    Exit(Sign);
  end;
  Result := Sign or (Cardinal(E) shl 23) or (Cardinal(Bits shr 29) and $7FFFFF);
end;

procedure TPS2VUCore.SetFlags(const R: TPS2Reg128; Dest: Cardinal; Flags: Cardinal);
begin
  // MAC: Z bits 0..3, S 4..7, U 8..11, O 12..15; bit 3 of each group is x.
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
    end;
  if (Flags and 2) <> 0 then
    M := M or (Dest shl 8);
  if (Flags and 1) <> 0 then
    M := M or (Dest shl 12);
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
var
  R: TPS2Reg128;
  Flags: Cardinal;
begin
  var Dest := (Op shr 21) and $F;
  var Ft := Integer((Op shr 16) and 31);
  var Fs := Integer((Op shr 11) and 31);
  var Fd := Integer((Op shr 6) and 31);
  var A := FVF[Fs];
  var B := FVF[Ft];
  Flags := 0;
  R := Default(TPS2Reg128);
  FUpperReg := -1;
  var Funct := Op and $3F;
  var Target := Fd;
  var SetMac := True;
  if Funct >= $3C then
  begin
    // Special: ACC forms and conversions; index = fd field << 2 | bc.
    Funct := ((Op shr 4) and $7C) or (Op and 3);
    Target := 32;
    case Funct of
      $00..$03: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], Bc(B, Op), Flags);
      $04..$07: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], Bc(B, Op) xor $80000000, Flags);
      $08..$0B: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], Bc(B, Op), Flags), Flags);
      $0C..$0F: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], Bc(B, Op), Flags) xor $80000000, Flags);
      $10..$13:
        begin
          // ITOF0/4/12/15: fixed point to float.
          var Scale: Double := 1;
          case Funct of
            $11: Scale := 1 / 16;
            $12: Scale := 1 / 4096;
            $13: Scale := 1 / 32768;
          end;
          for var K := 0 to 3 do
          begin
            var F: Single := A.SW[K] * Scale;
            R.UW[K] := PCardinal(@F)^;
          end;
          Target := Ft;
          SetMac := False;
        end;
      $14..$17:
        begin
          var Scale: Double := 1;
          case Funct of
            $15: Scale := 16;
            $16: Scale := 4096;
            $17: Scale := 32768;
          end;
          for var K := 0 to 3 do
          begin
            var D := EEFloatIn(A.UW[K]) * Scale;
            if D >= 2147483647.0 then
              R.UW[K] := $7FFFFFFF
            else if D <= -2147483648.0 then
              R.UW[K] := $80000000
            else
              R.SW[K] := Trunc(D);
          end;
          Target := Ft;
          SetMac := False;
        end;
      $18..$1B: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], Bc(B, Op), Flags);
      $1C: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], S.Q, Flags);
      $1D:
        begin
          for var K := 0 to 3 do
            R.UW[K] := A.UW[K] and $7FFFFFFF;
          Target := Ft;
          SetMac := False;
        end;
      $1E: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], S.I, Flags);
      $1F:
        begin
          // CLIP: |fs.xyz| against |ft.w|.
          var W := Abs(EEFloatIn(B.UW[3]));
          var C: Cardinal := 0;
          for var K := 0 to 2 do
          begin
            var V := EEFloatIn(A.UW[K]);
            if V > W then
              C := C or (Cardinal(1) shl (K * 2));
            if V < -W then
              C := C or (Cardinal(2) shl (K * 2));
          end;
          S.Clip := ((S.Clip shl 6) or C) and $FFFFFF;
          Exit;
        end;
      $20: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.Q, Flags);
      $21: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.Q, Flags), Flags);
      $22: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.I, Flags);
      $23: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.I, Flags), Flags);
      $24: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.Q xor $80000000, Flags);
      $25: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.Q, Flags) xor $80000000, Flags);
      $26: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.I xor $80000000, Flags);
      $27: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.I, Flags) xor $80000000, Flags);
      $28: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], B.UW[K], Flags);
      $29: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], B.UW[K], Flags), Flags);
      $2A: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], B.UW[K], Flags);
      $2C: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], B.UW[K] xor $80000000, Flags);
      $2D: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], B.UW[K], Flags) xor $80000000, Flags);
      $2E:
        begin
          // OPMULA: ACC.xyz = fs.yzx * ft.zxy
          R.UW[0] := FMul(A.UW[1], B.UW[2], Flags);
          R.UW[1] := FMul(A.UW[2], B.UW[0], Flags);
          R.UW[2] := FMul(A.UW[0], B.UW[1], Flags);
          Dest := Dest and $E;
        end;
      $2F: Exit;
    else
      if not Micro then
        Exit;
      Exit;
    end;
  end
  else
    case Funct of
      $00..$03: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], Bc(B, Op), Flags);
      $04..$07: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], Bc(B, Op) xor $80000000, Flags);
      $08..$0B: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], Bc(B, Op), Flags), Flags);
      $0C..$0F: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], Bc(B, Op), Flags) xor $80000000, Flags);
      $10..$13, $1D, $2B:
        begin
          var Other: Cardinal;
          for var K := 0 to 3 do
          begin
            case Funct of
              $1D: Other := S.I;
              $2B: Other := B.UW[K];
            else
              Other := Bc(B, Op);
            end;
            if PS2FloatKey(A.UW[K]) >= PS2FloatKey(Other) then
              R.UW[K] := A.UW[K]
            else
              R.UW[K] := Other;
          end;
          SetMac := False;
        end;
      $14..$17, $1F, $2F:
        begin
          var Other: Cardinal;
          for var K := 0 to 3 do
          begin
            case Funct of
              $1F: Other := S.I;
              $2F: Other := B.UW[K];
            else
              Other := Bc(B, Op);
            end;
            if PS2FloatKey(A.UW[K]) <= PS2FloatKey(Other) then
              R.UW[K] := A.UW[K]
            else
              R.UW[K] := Other;
          end;
          SetMac := False;
        end;
      $18..$1B: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], Bc(B, Op), Flags);
      $1C: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], S.Q, Flags);
      $1E: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], S.I, Flags);
      $20: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.Q, Flags);
      $21: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.Q, Flags), Flags);
      $22: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.I, Flags);
      $23: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.I, Flags), Flags);
      $24: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.Q xor $80000000, Flags);
      $25: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.Q, Flags) xor $80000000, Flags);
      $26: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], S.I xor $80000000, Flags);
      $27: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], S.I, Flags) xor $80000000, Flags);
      $28: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], B.UW[K], Flags);
      $29: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], B.UW[K], Flags), Flags);
      $2A: for var K := 0 to 3 do R.UW[K] := FMul(A.UW[K], B.UW[K], Flags);
      $2C: for var K := 0 to 3 do R.UW[K] := FAdd(A.UW[K], B.UW[K] xor $80000000, Flags);
      $2D: for var K := 0 to 3 do R.UW[K] := FAdd(S.ACC.UW[K], FMul(A.UW[K], B.UW[K], Flags) xor $80000000, Flags);
      $2E:
        begin
          // OPMSUB: fd.xyz = ACC.xyz - fs.yzx * ft.zxy
          R.UW[0] := FAdd(S.ACC.UW[0], FMul(A.UW[1], B.UW[2], Flags) xor $80000000, Flags);
          R.UW[1] := FAdd(S.ACC.UW[1], FMul(A.UW[2], B.UW[0], Flags) xor $80000000, Flags);
          R.UW[2] := FAdd(S.ACC.UW[2], FMul(A.UW[0], B.UW[1], Flags) xor $80000000, Flags);
          Dest := Dest and $E;
        end;
    else
      Exit;
    end;
  if SetMac then
    SetFlags(R, Dest, Flags);
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
    $10: FVI[1] := Ord((S.Clip and $FFFFFF) = (Op and $FFFFFF));
    $11: S.Clip := Op and $FFFFFF;
    $12: FVI[1] := Ord((S.Clip and Op and $FFFFFF) <> 0);
    $13: FVI[1] := Ord(((S.Clip or Op) and $FFFFFF) = $FFFFFF);
    $14: if (It and 15) <> 0 then FVI[It and 15] := Ord((S.Status and $FFF) = (((Op shr 10) and $800) or (Op and $7FF)));
    $15: S.Status := (S.Status and $3F) or ((((Op shr 10) and $800) or (Op and $7FF)) and $FC0);
    $16: if (It and 15) <> 0 then FVI[It and 15] := S.Status and (((Op shr 10) and $800) or (Op and $7FF));
    $17: if (It and 15) <> 0 then FVI[It and 15] := (S.Status or (((Op shr 10) and $800) or (Op and $7FF))) and $FFF;
    $18: if (It and 15) <> 0 then FVI[It and 15] := Ord((S.MAC and $FFFF) = (FVI[Is_ and 15] and $FFFF));
    $1A: if (It and 15) <> 0 then FVI[It and 15] := S.MAC and FVI[Is_ and 15] and $FFFF;
    $1B: if (It and 15) <> 0 then FVI[It and 15] := (S.MAC or FVI[Is_ and 15]) and $FFFF;
    $1C: FVI[1] := S.Clip and $FFF;
    $20, $21, $28, $29, $2C, $2D, $2E, $2F:
      begin
        var Take: Boolean;
        var A := SmallInt(Word(FVI[Is_ and 15]));
        var B := SmallInt(Word(FVI[It and 15]));
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
        FOnKick((FVI[Fs and 15] * 16) and FDataMask);
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

procedure TPS2VUCore.Start(Address: Cardinal);
begin
  S.TPC := Address and FCodeMask;
  S.Running := True;
  S.BranchPending := False;
  S.EndPending := False;
end;

function TPS2VUCore.Run(MaxPairs: Integer): Boolean;
begin
  var Count := 0;
  while S.Running and (Count < MaxPairs) do
  begin
    var PC := S.TPC and FCodeMask;
    var LowerOp := PCardinal(FCode + PC)^;
    var UpperOp := PCardinal(FCode + PC + 4)^;
    var Branching := S.BranchPending;
    var Target := S.BranchTarget;
    var Ending := S.EndPending;
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
    FUpperReg := -1;
    FLowerReg := -1;
    Upper(UpperOp, True);
    if (UpperOp and $80000000) <> 0 then
      S.I := LowerOp
    else
      Lower(LowerOp);
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
    Inc(Executed);
    Inc(S.Cycles);
    Inc(Count);
    S.TPC := (PC + 8) and FCodeMask;
    if Branching then
      S.TPC := Target;
    if Ending then
    begin
      S.Running := False;
      S.EndPending := False;
      Break;
    end;
    if (UpperOp and $40000000) <> 0 then
      S.EndPending := True;
  end;
  Result := not S.Running;
end;

procedure TPS2VUCore.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
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
        FCore.Start(Address);
        FCore.Run(1000000);
        Exit(True);
      end;
  end;
  Result := FCore.Macro(Op);
end;

procedure TPS2VU0.Interlock;
begin
  if FCore.S.Running then
    FCore.Run(1000000);
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
