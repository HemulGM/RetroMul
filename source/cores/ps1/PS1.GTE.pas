unit PS1.GTE;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types;

type
  TPS1GTEVector = array[0..2] of SmallInt;

  TPS1GTEMatrix = array[0..2, 0..2] of SmallInt;

  // Geometry transformation engine (COP2), following psx-spx: 44-bit MAC1..3
  // accumulation with per-step overflow flags, IR/color/screen saturation and
  // the UNR perspective division.
  TPS1GTE = class
  private
    type
      TState = record
        V: array[0..2] of TPS1GTEVector;
        RGBC: Cardinal;
        OTZ: Word;
        IR: array[0..3] of SmallInt;
        SXY: array[0..2] of Cardinal;
        SZ: array[0..3] of Word;
        RGB: array[0..2] of Cardinal;
        RES1: Cardinal;
        MAC: array[0..3] of Integer;
        LZCS: Cardinal;
        RT, LLM, LCM: TPS1GTEMatrix;
        TR, BK, FC: array[0..2] of Integer;
        OFX, OFY: Integer;
        H: Word;
        DQA: SmallInt;
        DQB: Integer;
        ZSF3, ZSF4: SmallInt;
        Flag: Cardinal;
      end;
  private
    S: TState;
    FShift: Integer;
    FLimitPositive: Boolean;
    // MAC1..3 of the current command before truncation to 32 bits.
    FWide: array[1..3] of Int64;
    function A(Index: Integer; Value: Int64): Int64;
    function F(Value: Int64): Int64;
    function LimitIR(Index: Integer; Value: Int64; Positive: Boolean): SmallInt;
    procedure SetMACs(const Values: array of Int64);
    procedure SetIRFromMAC(Positive: Boolean);
    function LimitColor(Index: Integer; Value: Int64): Byte;
    procedure PushColor;
    procedure PushSZ(Value: Int64);
    function Divide: Int64;
    procedure Transform(VectorIndex: Integer; Last: Boolean);
    procedure MultiplyMatrix(const M: TPS1GTEMatrix; const V: TPS1GTEVector; Translation: Integer; out R0, R1, R2: Int64);
    procedure LightAndColor(VectorIndex: Integer);
    procedure ColorProduct(out R0, R1, R2: Int64);
    procedure DepthCue(var R0, R1, R2: Int64);
    procedure FinishColor(R0, R1, R2: Int64);
    procedure NormalColor(VectorIndex: Integer; Mode: Integer);
    function ReadIRGB: Cardinal;
    function LeadingCount: Cardinal;
    function MatrixWord(const M: TPS1GTEMatrix; Index: Integer): Cardinal;
    procedure SetMatrixWord(var M: TPS1GTEMatrix; Index: Integer; Value: Cardinal);
    function IRVector: TPS1GTEVector;
    function GarbageMatrix: TPS1GTEMatrix;
  public
    procedure Reset;
    function ReadData(Index: Integer): Cardinal;
    procedure WriteData(Index: Integer; Value: Cardinal);
    function ReadControl(Index: Integer): Cardinal;
    procedure WriteControl(Index: Integer; Value: Cardinal);
    // Returns the command latency in CPU cycles.
    function Execute(Command: Cardinal): Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

var
  UNRTable: array[0..$100] of Byte;

const
  FlagMACPositive: array[1..3] of Cardinal = ($40000000, $20000000, $10000000);
  FlagMACNegative: array[1..3] of Cardinal = ($08000000, $04000000, $02000000);
  FlagIR: array[1..3] of Cardinal = ($01000000, $00800000, $00400000);
  FlagColor: array[0..2] of Cardinal = ($00200000, $00100000, $00080000);
  FlagSZ = $00040000;
  FlagDivide = $00020000;
  FlagMAC0Positive = $00010000;
  FlagMAC0Negative = $00008000;
  FlagSX = $00004000;
  FlagSY = $00002000;
  FlagIR0 = $00001000;
  FlagErrorMask = $7F87E000;

function SAR(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function SignExtend44(Value: Int64): Int64; inline;
begin
  Result := SAR(Value shl 20, 20);
end;

function Low16(Value: Cardinal): SmallInt; inline;
begin
  Result := SmallInt(Value and $FFFF);
end;

function High16(Value: Cardinal): SmallInt; inline;
begin
  Result := SmallInt(Value shr 16);
end;

function Pack(Low, High: SmallInt): Cardinal; inline;
begin
  Result := Cardinal(Word(Low)) or (Cardinal(Word(High)) shl 16);
end;

function Extend(Value: SmallInt): Cardinal; inline;
begin
  Result := Cardinal(Integer(Value));
end;

procedure TPS1GTE.Reset;
begin
  S := Default(TState);
end;

function TPS1GTE.A(Index: Integer; Value: Int64): Int64;
begin
  if Value > $7FFFFFFFFFF then
    S.Flag := S.Flag or FlagMACPositive[Index]
  else if Value < -$80000000000 then
    S.Flag := S.Flag or FlagMACNegative[Index];
  Result := SignExtend44(Value);
end;

function TPS1GTE.F(Value: Int64): Int64;
begin
  if Value > $7FFFFFFF then
    S.Flag := S.Flag or FlagMAC0Positive
  else if Value < -$80000000 then
    S.Flag := S.Flag or FlagMAC0Negative;
  Result := Value;
end;

function TPS1GTE.LimitIR(Index: Integer; Value: Int64; Positive: Boolean): SmallInt;
begin
  var Minimum: Int64 := -$8000;
  if Positive then
    Minimum := 0;
  if Value < Minimum then
  begin
    S.Flag := S.Flag or FlagIR[Index];
    Value := Minimum;
  end
  else if Value > $7FFF then
  begin
    S.Flag := S.Flag or FlagIR[Index];
    Value := $7FFF;
  end;
  Result := SmallInt(Value);
end;

procedure TPS1GTE.SetMACs(const Values: array of Int64);
begin
  for var I := 0 to 2 do
  begin
    FWide[I + 1] := SAR(Values[I], FShift);
    S.MAC[I + 1] := Integer(FWide[I + 1]);
  end;
end;

procedure TPS1GTE.SetIRFromMAC(Positive: Boolean);
begin
  for var I := 1 to 3 do
    S.IR[I] := LimitIR(I, S.MAC[I], Positive);
end;

function TPS1GTE.LimitColor(Index: Integer; Value: Int64): Byte;
begin
  if Value < 0 then
  begin
    S.Flag := S.Flag or FlagColor[Index];
    Value := 0;
  end
  else if Value > $FF then
  begin
    S.Flag := S.Flag or FlagColor[Index];
    Value := $FF;
  end;
  Result := Byte(Value);
end;

procedure TPS1GTE.PushColor;
begin
  S.RGB[0] := S.RGB[1];
  S.RGB[1] := S.RGB[2];
  S.RGB[2] := Cardinal(LimitColor(0, SAR(S.MAC[1], 4))) or (Cardinal(LimitColor(1, SAR(S.MAC[2], 4))) shl 8) or
    (Cardinal(LimitColor(2, SAR(S.MAC[3], 4))) shl 16) or (S.RGBC and $FF000000);
end;

procedure TPS1GTE.PushSZ(Value: Int64);
begin
  S.SZ[0] := S.SZ[1];
  S.SZ[1] := S.SZ[2];
  S.SZ[2] := S.SZ[3];
  if Value < 0 then
  begin
    S.Flag := S.Flag or FlagSZ;
    Value := 0;
  end
  else if Value > $FFFF then
  begin
    S.Flag := S.Flag or FlagSZ;
    Value := $FFFF;
  end;
  S.SZ[3] := Word(Value);
end;

// UNR division of H by SZ3 (psx-spx "GTE Division Inaccuracy").
function TPS1GTE.Divide: Int64;
begin
  var Z := S.SZ[3];
  if Cardinal(S.H) >= Cardinal(Z) * 2 then
  begin
    S.Flag := S.Flag or FlagDivide;
    Exit($1FFFF);
  end;

  var Shift := 0;
  while (Shift < 16) and (((Cardinal(Z) shl Shift) and $8000) = 0) do
    Inc(Shift);
  var N := UInt64(S.H) shl Shift;
  var D := UInt64(Cardinal(Z) shl Shift);
  var U := UInt64(UNRTable[(D - $7FC0) shr 7]) + $101;
  D := ($2000080 - D * U) shr 8;
  D := ($80 + D * U) shr 8;
  Result := Int64((N * D + $8000) shr 16);
  if Result > $1FFFF then
    Result := $1FFFF;
end;

procedure TPS1GTE.MultiplyMatrix(const M: TPS1GTEMatrix; const V: TPS1GTEVector; Translation: Integer; out R0, R1, R2: Int64);
var
  R: array[0..2] of Int64;
begin
  for var I := 0 to 2 do
  begin
    var T: Int64 := 0;
    case Translation of
      0:
        T := Int64(S.TR[I]) shl 12;
      1:
        T := Int64(S.BK[I]) shl 12;
      2:
        T := Int64(S.FC[I]) shl 12;
    end;
    if Translation = 2 then
    begin
      // The far color path is broken: the first column only affects flags.
      var Lost := A(I + 1, T + Int64(M[I, 0]) * V[0]);
      LimitIR(I + 1, SAR(Lost, FShift), False);
      R[I] := A(I + 1, A(I + 1, Int64(M[I, 1]) * V[1]) + Int64(M[I, 2]) * V[2]);
    end
    else
      R[I] := A(I + 1, A(I + 1, A(I + 1, T + Int64(M[I, 0]) * V[0]) + Int64(M[I, 1]) * V[1]) + Int64(M[I, 2]) * V[2]);
  end;
  R0 := R[0];
  R1 := R[1];
  R2 := R[2];
end;

procedure TPS1GTE.Transform(VectorIndex: Integer; Last: Boolean);
var
  R0, R1, R2: Int64;
begin
  MultiplyMatrix(S.RT, S.V[VectorIndex], 0, R0, R1, R2);
  SetMACs([R0, R1, R2]);
  S.IR[1] := LimitIR(1, S.MAC[1], FLimitPositive);
  S.IR[2] := LimitIR(2, S.MAC[2], FLimitPositive);
  // The IR3 flag is checked on MAC3 SAR 12 as if lm=0; IR3 itself follows lm.
  var Z := SAR(R2, 12);
  if (Z < -$8000) or (Z > $7FFF) then
    S.Flag := S.Flag or FlagIR[3];
  var IR3 := Int64(S.MAC[3]);
  if FLimitPositive and (IR3 < 0) then
    IR3 := 0
  else if IR3 < -$8000 then
    IR3 := -$8000
  else if IR3 > $7FFF then
    IR3 := $7FFF;
  S.IR[3] := SmallInt(IR3);
  PushSZ(Z);
  var N := Divide;
  S.SXY[0] := S.SXY[1];
  S.SXY[1] := S.SXY[2];
  var X := F(N * S.IR[1] + S.OFX);
  S.MAC[0] := Integer(X);
  X := SAR(X, 16);
  if X < -$400 then
  begin
    S.Flag := S.Flag or FlagSX;
    X := -$400;
  end
  else if X > $3FF then
  begin
    S.Flag := S.Flag or FlagSX;
    X := $3FF;
  end;
  var Y := F(N * S.IR[2] + S.OFY);
  S.MAC[0] := Integer(Y);
  Y := SAR(Y, 16);
  if Y < -$400 then
  begin
    S.Flag := S.Flag or FlagSY;
    Y := -$400;
  end
  else if Y > $3FF then
  begin
    S.Flag := S.Flag or FlagSY;
    Y := $3FF;
  end;
  S.SXY[2] := Pack(SmallInt(X), SmallInt(Y));
  if Last then
  begin
    var Depth := F(N * S.DQA + S.DQB);
    S.MAC[0] := Integer(Depth);
    Depth := SAR(Depth, 12);
    if Depth < 0 then
    begin
      S.Flag := S.Flag or FlagIR0;
      Depth := 0;
    end
    else if Depth > $1000 then
    begin
      S.Flag := S.Flag or FlagIR0;
      Depth := $1000;
    end;
    S.IR[0] := SmallInt(Depth);
  end;
end;

function TPS1GTE.IRVector: TPS1GTEVector;
begin
  Result[0] := S.IR[1];
  Result[1] := S.IR[2];
  Result[2] := S.IR[3];
end;

function TPS1GTE.GarbageMatrix: TPS1GTEMatrix;
begin
  var R := Integer(S.RGBC and $FF) shl 4;
  Result[0, 0] := SmallInt(-R);
  Result[0, 1] := SmallInt(R);
  Result[0, 2] := S.IR[0];
  Result[1, 0] := S.RT[0, 2];
  Result[1, 1] := S.RT[0, 2];
  Result[1, 2] := S.RT[0, 2];
  Result[2, 0] := S.RT[1, 1];
  Result[2, 1] := S.RT[1, 1];
  Result[2, 2] := S.RT[1, 1];
end;

// IR = LLM * V, then IR = BK + LCM * IR.
procedure TPS1GTE.LightAndColor(VectorIndex: Integer);
var
  R0, R1, R2: Int64;
begin
  MultiplyMatrix(S.LLM, S.V[VectorIndex], 3, R0, R1, R2);
  SetMACs([R0, R1, R2]);
  SetIRFromMAC(FLimitPositive);
  MultiplyMatrix(S.LCM, IRVector, 1, R0, R1, R2);
  SetMACs([R0, R1, R2]);
  SetIRFromMAC(FLimitPositive);
end;

// [R*IR1, G*IR2, B*IR3] SHL 4 (pre-shift values).
procedure TPS1GTE.ColorProduct(out R0, R1, R2: Int64);
begin
  R0 := A(1, (Int64(S.RGBC and $FF) * S.IR[1]) shl 4);
  R1 := A(2, (Int64((S.RGBC shr 8) and $FF) * S.IR[2]) shl 4);
  R2 := A(3, (Int64((S.RGBC shr 16) and $FF) * S.IR[3]) shl 4);
end;

// MAC + (FC - MAC) * IR0 on pre-shift values; the intermediate IR is
// saturated as if lm=0.
procedure TPS1GTE.DepthCue(var R0, R1, R2: Int64);
var
  R: array[0..2] of Int64;
begin
  R[0] := R0;
  R[1] := R1;
  R[2] := R2;
  for var I := 0 to 2 do
  begin
    // Saturation sees the 32-bit MAC value, like every IR write.
    var Difference := A(I + 1, (Int64(S.FC[I]) shl 12) - R[I]);
    S.IR[I + 1] := LimitIR(I + 1, Integer(SAR(Difference, FShift)), False);
  end;
  for var I := 0 to 2 do
    R[I] := A(I + 1, Int64(S.IR[I + 1]) * S.IR[0] + R[I]);
  R0 := R[0];
  R1 := R[1];
  R2 := R[2];
end;

procedure TPS1GTE.FinishColor(R0, R1, R2: Int64);
begin
  SetMACs([R0, R1, R2]);
  PushColor;
  SetIRFromMAC(FLimitPositive);
end;

// Mode 0 = NCS/NCT, 1 = NCCS/NCCT, 2 = NCDS/NCDT.
procedure TPS1GTE.NormalColor(VectorIndex: Integer; Mode: Integer);
var
  R0, R1, R2: Int64;
begin
  LightAndColor(VectorIndex);
  if Mode = 0 then
  begin
    R0 := Int64(S.MAC[1]) shl FShift;
    R1 := Int64(S.MAC[2]) shl FShift;
    R2 := Int64(S.MAC[3]) shl FShift;
  end
  else
  begin
    ColorProduct(R0, R1, R2);
    if Mode = 2 then
      DepthCue(R0, R1, R2);
  end;
  FinishColor(R0, R1, R2);
end;

function TPS1GTE.Execute(Command: Cardinal): Integer;
const
  Valid =[ $01,  $06,  $0C,  $10,  $11,  $12,  $13,  $14,  $16,  $1B,  $1C,  $1E,  $20,  $28,  $29,  $2A,
      $2D,  $2E,  $30,  $3D,  $3E,  $3F];
var
  R0, R1, R2: Int64;
begin
  // Undefined command numbers leave every register, including FLAG, alone.
  if not ((Command and $3F) in Valid) then
    Exit(1);

  S.Flag := 0;
  FShift := 0;
  if (Command and $80000) <> 0 then
    FShift := 12;
  FLimitPositive := (Command and $400) <> 0;
  case Command and $3F of
    $01:
      begin
        Transform(0, True);
        Result := 15;
      end;
    $06:
      begin
        var X0 := Int64(Low16(S.SXY[0]));
        var Y0 := Int64(High16(S.SXY[0]));
        var X1 := Int64(Low16(S.SXY[1]));
        var Y1 := Int64(High16(S.SXY[1]));
        var X2 := Int64(Low16(S.SXY[2]));
        var Y2 := Int64(High16(S.SXY[2]));
        S.MAC[0] := Integer(F(X0 * Y1 + X1 * Y2 + X2 * Y0 - X0 * Y2 - X1 * Y0 - X2 * Y1));
        Result := 8;
      end;
    $0C:
      begin
        var D1 := Int64(S.RT[0, 0]);
        var D2 := Int64(S.RT[1, 1]);
        var D3 := Int64(S.RT[2, 2]);
        R0 := A(1, A(1, S.IR[3] * D2) - S.IR[2] * D3);
        R1 := A(2, A(2, S.IR[1] * D3) - S.IR[3] * D1);
        R2 := A(3, A(3, S.IR[2] * D1) - S.IR[1] * D2);
        SetMACs([R0, R1, R2]);
        SetIRFromMAC(FLimitPositive);
        Result := 6;
      end;
    $10, $2A:
      begin
        // DPCS, or DPCT on the three color FIFO entries.
        var Count := 1;
        if (Command and $3F) = $2A then
          Count := 3;
        for var I := 1 to Count do
        begin
          var Color := S.RGBC;
          if Count = 3 then
            Color := S.RGB[0];
          R0 := Int64(Color and $FF) shl 16;
          R1 := Int64((Color shr 8) and $FF) shl 16;
          R2 := Int64((Color shr 16) and $FF) shl 16;
          DepthCue(R0, R1, R2);
          FinishColor(R0, R1, R2);
        end;
        if Count = 3 then
          Result := 17
        else
          Result := 8;
      end;
    $11:
      begin
        R0 := Int64(S.IR[1]) shl 12;
        R1 := Int64(S.IR[2]) shl 12;
        R2 := Int64(S.IR[3]) shl 12;
        DepthCue(R0, R1, R2);
        FinishColor(R0, R1, R2);
        Result := 8;
      end;
    $12:
      begin
        var V: TPS1GTEVector;
        case (Command shr 15) and 3 of
          0..2:
            V := S.V[(Command shr 15) and 3];
        else
          V := IRVector;
        end;
        var M: TPS1GTEMatrix;
        case (Command shr 17) and 3 of
          0:
            M := S.RT;
          1:
            M := S.LLM;
          2:
            M := S.LCM;
        else
          M := GarbageMatrix;
        end;
        MultiplyMatrix(M, V, Integer((Command shr 13) and 3), R0, R1, R2);
        SetMACs([R0, R1, R2]);
        SetIRFromMAC(FLimitPositive);
        Result := 8;
      end;
    $13:
      begin
        NormalColor(0, 2);
        Result := 19;
      end;
    $14:
      begin
        MultiplyMatrix(S.LCM, IRVector, 1, R0, R1, R2);
        SetMACs([R0, R1, R2]);
        SetIRFromMAC(FLimitPositive);
        ColorProduct(R0, R1, R2);
        DepthCue(R0, R1, R2);
        FinishColor(R0, R1, R2);
        Result := 13;
      end;
    $16:
      begin
        for var I := 0 to 2 do
          NormalColor(I, 2);
        Result := 44;
      end;
    $1B:
      begin
        NormalColor(0, 1);
        Result := 17;
      end;
    $1C:
      begin
        MultiplyMatrix(S.LCM, IRVector, 1, R0, R1, R2);
        SetMACs([R0, R1, R2]);
        SetIRFromMAC(FLimitPositive);
        ColorProduct(R0, R1, R2);
        FinishColor(R0, R1, R2);
        Result := 11;
      end;
    $1E:
      begin
        NormalColor(0, 0);
        Result := 14;
      end;
    $20:
      begin
        for var I := 0 to 2 do
          NormalColor(I, 0);
        Result := 30;
      end;
    $28:
      begin
        R0 := A(1, Int64(S.IR[1]) * S.IR[1]);
        R1 := A(2, Int64(S.IR[2]) * S.IR[2]);
        R2 := A(3, Int64(S.IR[3]) * S.IR[3]);
        SetMACs([R0, R1, R2]);
        SetIRFromMAC(FLimitPositive);
        Result := 5;
      end;
    $29:
      begin
        ColorProduct(R0, R1, R2);
        DepthCue(R0, R1, R2);
        FinishColor(R0, R1, R2);
        Result := 8;
      end;
    $2D:
      begin
        var Sum := F(Int64(S.ZSF3) * (Int64(S.SZ[1]) + S.SZ[2] + S.SZ[3]));
        S.MAC[0] := Integer(Sum);
        var Z := SAR(Sum, 12);
        if Z < 0 then
        begin
          S.Flag := S.Flag or FlagSZ;
          Z := 0;
        end
        else if Z > $FFFF then
        begin
          S.Flag := S.Flag or FlagSZ;
          Z := $FFFF;
        end;
        S.OTZ := Word(Z);
        Result := 5;
      end;
    $2E:
      begin
        var Sum := F(Int64(S.ZSF4) * (Int64(S.SZ[0]) + S.SZ[1] + S.SZ[2] + S.SZ[3]));
        S.MAC[0] := Integer(Sum);
        var Z := SAR(Sum, 12);
        if Z < 0 then
        begin
          S.Flag := S.Flag or FlagSZ;
          Z := 0;
        end
        else if Z > $FFFF then
        begin
          S.Flag := S.Flag or FlagSZ;
          Z := $FFFF;
        end;
        S.OTZ := Word(Z);
        Result := 6;
      end;
    $30:
      begin
        Transform(0, False);
        Transform(1, False);
        Transform(2, True);
        Result := 23;
      end;
    $3D:
      begin
        R0 := A(1, Int64(S.IR[1]) * S.IR[0]);
        R1 := A(2, Int64(S.IR[2]) * S.IR[0]);
        R2 := A(3, Int64(S.IR[3]) * S.IR[0]);
        FinishColor(R0, R1, R2);
        Result := 5;
      end;
    $3E:
      begin
        R0 := A(1, A(1, Int64(S.MAC[1]) shl FShift) + Int64(S.IR[1]) * S.IR[0]);
        R1 := A(2, A(2, Int64(S.MAC[2]) shl FShift) + Int64(S.IR[2]) * S.IR[0]);
        R2 := A(3, A(3, Int64(S.MAC[3]) shl FShift) + Int64(S.IR[3]) * S.IR[0]);
        FinishColor(R0, R1, R2);
        Result := 5;
      end;
  else
    begin
      for var I := 0 to 2 do
        NormalColor(I, 1);
      Result := 39;
    end;
  end;
  if (S.Flag and FlagErrorMask) <> 0 then
    S.Flag := S.Flag or $80000000;
end;

function TPS1GTE.ReadIRGB: Cardinal;
begin
  Result := 0;
  for var I := 1 to 3 do
  begin
    var Value := S.IR[I] div $80;
    if Value < 0 then
      Value := 0
    else if Value > $1F then
      Value := $1F;
    Result := Result or (Cardinal(Value) shl ((I - 1) * 5));
  end;
end;

function TPS1GTE.LeadingCount: Cardinal;
begin
  var Value := S.LZCS;
  if (Value and $80000000) <> 0 then
    Value := not Value;
  Result := 0;
  while (Result < 32) and ((Value and $80000000) = 0) do
  begin
    Inc(Result);
    Value := Value shl 1;
  end;
end;

function TPS1GTE.MatrixWord(const M: TPS1GTEMatrix; Index: Integer): Cardinal;
begin
  // Elements are packed row-major, two per register; the ninth stands alone.
  if Index = 4 then
    Exit(Extend(M[2, 2]));
  var First := Index * 2;
  Result := Pack(M[First div 3, First mod 3], M[(First + 1) div 3, (First + 1) mod 3]);
end;

procedure TPS1GTE.SetMatrixWord(var M: TPS1GTEMatrix; Index: Integer; Value: Cardinal);
begin
  if Index = 4 then
  begin
    M[2, 2] := Low16(Value);
    Exit;
  end;
  var First := Index * 2;
  M[First div 3, First mod 3] := Low16(Value);
  M[(First + 1) div 3, (First + 1) mod 3] := High16(Value);
end;

function TPS1GTE.ReadData(Index: Integer): Cardinal;
begin
  case Index and 31 of
    0, 2, 4:
      Result := Pack(S.V[Index shr 1][0], S.V[Index shr 1][1]);
    1, 3, 5:
      Result := Extend(S.V[Index shr 1][2]);
    6:
      Result := S.RGBC;
    7:
      Result := S.OTZ;
    8..11:
      Result := Extend(S.IR[Index - 8]);
    12..14:
      Result := S.SXY[Index - 12];
    15:
      Result := S.SXY[2];
    16..19:
      Result := S.SZ[Index - 16];
    20..22:
      Result := S.RGB[Index - 20];
    23:
      Result := S.RES1;
    24..27:
      Result := Cardinal(S.MAC[Index - 24]);
    28, 29:
      Result := ReadIRGB;
    30:
      Result := S.LZCS;
  else
    Result := LeadingCount;
  end;
end;

procedure TPS1GTE.WriteData(Index: Integer; Value: Cardinal);
begin
  case Index and 31 of
    0, 2, 4:
      begin
        S.V[Index shr 1][0] := Low16(Value);
        S.V[Index shr 1][1] := High16(Value);
      end;
    1, 3, 5:
      S.V[Index shr 1][2] := Low16(Value);
    6:
      S.RGBC := Value;
    7:
      S.OTZ := Word(Value);
    8..11:
      S.IR[Index - 8] := Low16(Value);
    12..14:
      S.SXY[Index - 12] := Value;
    15:
      begin
        S.SXY[0] := S.SXY[1];
        S.SXY[1] := S.SXY[2];
        S.SXY[2] := Value;
      end;
    16..19:
      S.SZ[Index - 16] := Word(Value);
    20..22:
      S.RGB[Index - 20] := Value;
    23:
      S.RES1 := Value;
    24..27:
      S.MAC[Index - 24] := Integer(Value);
    28:
      begin
        S.IR[1] := SmallInt((Value and $1F) * $80);
        S.IR[2] := SmallInt(((Value shr 5) and $1F) * $80);
        S.IR[3] := SmallInt(((Value shr 10) and $1F) * $80);
      end;
    30:
      S.LZCS := Value;
  end;
end;

function TPS1GTE.ReadControl(Index: Integer): Cardinal;
begin
  case Index and 31 of
    0..4:
      Result := MatrixWord(S.RT, Index);
    5..7:
      Result := Cardinal(S.TR[Index - 5]);
    8..12:
      Result := MatrixWord(S.LLM, Index - 8);
    13..15:
      Result := Cardinal(S.BK[Index - 13]);
    16..20:
      Result := MatrixWord(S.LCM, Index - 16);
    21..23:
      Result := Cardinal(S.FC[Index - 21]);
    24:
      Result := Cardinal(S.OFX);
    25:
      Result := Cardinal(S.OFY);
    // H reads back sign-extended (hardware bug); it is unsigned in use.
      26:
      Result := Extend(SmallInt(S.H));
    27:
      Result := Extend(S.DQA);
    28:
      Result := Cardinal(S.DQB);
    29:
      Result := Extend(S.ZSF3);
    30:
      Result := Extend(S.ZSF4);
  else
    Result := S.Flag;
  end;
end;

procedure TPS1GTE.WriteControl(Index: Integer; Value: Cardinal);
begin
  case Index and 31 of
    0..4:
      SetMatrixWord(S.RT, Index, Value);
    5..7:
      S.TR[Index - 5] := Integer(Value);
    8..12:
      SetMatrixWord(S.LLM, Index - 8, Value);
    13..15:
      S.BK[Index - 13] := Integer(Value);
    16..20:
      SetMatrixWord(S.LCM, Index - 16, Value);
    21..23:
      S.FC[Index - 21] := Integer(Value);
    24:
      S.OFX := Integer(Value);
    25:
      S.OFY := Integer(Value);
    26:
      S.H := Word(Value);
    27:
      S.DQA := Low16(Value);
    28:
      S.DQB := Integer(Value);
    29:
      S.ZSF3 := Low16(Value);
    30:
      S.ZSF4 := Low16(Value);
  else
    begin
      S.Flag := Value and $7FFFF000;
      if (S.Flag and FlagErrorMask) <> 0 then
        S.Flag := S.Flag or $80000000;
    end;
  end;
end;

procedure TPS1GTE.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
end;

initialization
  for var I := 0 to $100 do
  begin
    var Value := ($40000 div (I + $100) + 1) div 2 - $101;
    if Value < 0 then
      Value := 0;
    UNRTable[I] := Byte(Value);
  end;

end.

