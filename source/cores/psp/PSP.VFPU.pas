unit PSP.VFPU;

interface

uses
  System.SysUtils, PSP.Memory;

type
  TPSPVector = array[0..3] of Cardinal;

  TPSPVFPU = record
    Registers: array[0..127] of Cardinal;
    Control: array[0..15] of Cardinal;
    procedure Reset;
    function Execute(Op: Cardinal; Memory: TPSPMemory; Base: Cardinal): Boolean;
    function ReadVector(Reg, Count: Integer; Prefix: Cardinal; ApplyPrefix: Boolean; PrefixCount: Integer = 0): TPSPVector;
    procedure WriteVector(Reg, Count: Integer; const Value: TPSPVector; ApplyPrefix: Boolean);
  end;

implementation

uses
  N64.SoftFloat, PSP.VFPUMath;

function MatrixRegister(Reg, Count, Column, Lane: Integer): Integer;
begin
  var Row := 0;
  case Count of
    1:
      Row := (Reg shr 5) and 3;
    2, 4:
      Row := (Reg shr 5) and 2;
    3:
      Row := (Reg shr 6) and 1;
  end;
  if (Count > 1) and (Reg and 32 <> 0) then
    Result := ((Reg shr 2) and 7) * 4 + ((Reg + Lane) and 3) + (((Row + Column) and 3) * 32)
  else
    Result := ((Reg shr 2) and 7) * 4 + ((Reg + Column) and 3) + (((Row + Lane) and 3) * 32);
end;

function HalfToFloat(Value: Cardinal): Cardinal;
begin
  var Sign := (Value and $8000) shl 16;
  var Exponent := (Value shr 10) and 31;
  var Mantissa := Value and $3FF;
  if Exponent = 0 then
    Exit(Sign);
  if Exponent = 31 then
    Exit(Sign or $7F800000 or Mantissa);
  Result := Sign or ((Exponent + 112) shl 23) or (Mantissa shl 13);
end;

function FloatToHalf(Value: Cardinal): Cardinal;
begin
  var Sign := (Value shr 16) and $8000;
  var Exponent := (Value shr 23) and $FF;
  if Exponent = 255 then
    Exit(Sign or $7C00 or (Value and $3FF));
  if Exponent < 113 then
    Exit(Sign);
  if Exponent >= 143 then
    Exit(Sign or $7C00);
  Result := Sign or ((Exponent - 112) shl 10) or ((Value and $7FFFFF) shr 13);
end;

function VectorRegister(Reg, Count, Lane: Integer): Integer;
begin
  var Matrix := (Reg shr 2) and 7;
  var Column := Reg and 3;
  var Row := 0;
  var Transpose := Reg and 32 <> 0;
  case Count of
    1:
      begin
        Row := (Reg shr 5) and 3;
        Transpose := False;
      end;
    2, 4:
      Row := (Reg shr 5) and 2;
    3:
      Row := (Reg shr 6) and 1;
  end;
  if Transpose then
    Result := Matrix * 4 + ((Row + Lane) and 3) + Column * 32
  else
    Result := Matrix * 4 + Column + ((Row + Lane) and 3) * 32;
end;

function Clamp(Value: Cardinal; Signed: Boolean): Cardinal;
begin
  Result := Value;
  if SFIsNaN(Value, 16) then
    Exit;
  var U, E, L: Boolean;
  var Lower: Cardinal := 0;
  if Signed then
    Lower := $BF800000;
  SFCompare(Value, Lower, 16, U, E, L);
  if L or E then
    Exit(Lower);
  SFCompare($3F800000, Value, 16, U, E, L);
  if L then
    Result := $3F800000;
end;

function MinMaxKey(Bits: Cardinal): Integer;
begin
  if Bits and $7F800000 = 0 then
    Exit(0);
  if Bits and $80000000 <> 0 then
    Result := Integer(Bits xor $7FFFFFFF)
  else
    Result := Integer(Bits);
end;

function VFMin(A, B: Cardinal): Cardinal;
begin
  if MinMaxKey(A) < MinMaxKey(B) then
    Result := A
  else
    Result := B;
end;

function VFMax(A, B: Cardinal): Cardinal;
begin
  if MinMaxKey(A) > MinMaxKey(B) then
    Result := A
  else
    Result := B;
end;

function Calculate(A, B: Cardinal; Operation: Integer): Cardinal;
begin
  var Value: TSoftFloatResult;
  // Reuse RetroMul's verified native arithmetic. Unusual operands and host
  // floating-point modes retain the software path; do not change the caller's
  // rounding, precision or exception settings here.
  {$IFDEF PSP_VFPU_SOFT}
  Value := SFCalculate(A, B, 16, Operation, 0);
  {$ELSE}
  if not SFHostReady or not SFQuick(A, B, 16, Operation, Value) then
    Value := SFCalculate(A, B, 16, Operation, 0);
  {$ENDIF}
  Result := Cardinal(Value.Bits);
  if SFIsNaN(Result, 16) then
    Result := $7FC00000;
end;

// PSP RCX recurrence, following PPSSPP's hardware-verified vrnd routines
// (PPSSPP Project and contributors, GPL-2.0-or-later; port GPL-3.0-or-later).
{$IFOPT Q+}{$DEFINE VRND_RESTORE_Q}{$ENDIF}{$Q-}
function RandomWord(var Control: array of Cardinal): Cardinal;
begin
  var A := (Control[8] and $FFFF) or (Control[12] shl 16);
  var B := (Control[9] and $FFFF) or (Control[13] shl 16);
  var C := (Control[10] and $FFFF) or (Control[14] shl 16);
  var D := (Control[11] and $FFFF) or (Control[15] shl 16);
  var E: Cardinal := 0;
  for var I := 0 to 7 do
    E := E or (((Control[8 + I] shr 16) and 15) shl (I * 4));
  A := 69069 * A + 1;
  B := B xor (B shl 13);
  B := B xor (B shr 17);
  B := B xor (B shl 5);
  var Next := 2 * D + C + E;
  E := Cardinal((UInt64(C) + UInt64(D shr 1) + E) shr 32);
  C := D;
  D := Next;
  Control[8] := $3F800000 or ((E and 15) shl 16) or (A and $FFFF);
  Control[9] := $3F800000 or (((E shr 4) and 15) shl 16) or (B and $FFFF);
  Control[10] := $3F800000 or (((E shr 8) and 15) shl 16) or (C and $FFFF);
  Control[11] := $3F800000 or (((E shr 12) and 15) shl 16) or (D and $FFFF);
  Control[12] := $3F800000 or (((E shr 16) and 15) shl 16) or (A shr 16);
  Control[13] := $3F800000 or (((E shr 20) and 15) shl 16) or (B shr 16);
  Control[14] := $3F800000 or (((E shr 24) and 15) shl 16) or (C shr 16);
  Control[15] := $3F800000 or (((E shr 28) and 15) shl 16) or (D shr 16);
  Result := A + B + D;
end;
{$IFDEF VRND_RESTORE_Q}{$Q+}{$UNDEF VRND_RESTORE_Q}{$ENDIF}

procedure TPSPVFPU.Reset;
begin
  FillChar(Self, SizeOf(Self), 0);
  Control[0] := $E4;
  Control[1] := $E4;
  Control[3] := $3F;
  Control[7] := $7772CEAB;
  for var I := 0 to 7 do
    Control[8 + I] := $3F800000;
  for var I := 0 to 3 do
    Control[8 + I] := $3F800000 or (Cardinal(1) shl I);
end;

function TPSPVFPU.ReadVector(Reg, Count: Integer; Prefix: Cardinal; ApplyPrefix: Boolean; PrefixCount: Integer): TPSPVector;
const
  Constants: array[0..7] of Cardinal = (0, $3F800000, $40000000, $3F000000, $40400000, $3EAAAAAB, $3E800000, $3E2AAAAB);
begin
  Result := Default(TPSPVector);
  for var I := 0 to Count - 1 do
    Result[I] := Registers[VectorRegister(Reg, Count, I)];
  if not ApplyPrefix then
    Exit;
  var Original := Result;
  if PrefixCount = 0 then
    PrefixCount := Count;
  for var I := 0 to PrefixCount - 1 do
  begin
    var Swizzle := Integer((Prefix shr (I * 2)) and 3);
    var absolute := Prefix and (Cardinal(1) shl (8 + I)) <> 0;
    if Prefix and (Cardinal(1) shl (12 + I)) <> 0 then
      Result[I] := Constants[Swizzle + Ord(absolute) * 4]
    else
    begin
      Result[I] := Original[Swizzle];
      if absolute then
        Result[I] := Result[I] and $7FFFFFFF;
    end;
    if Prefix and (Cardinal(1) shl (16 + I)) <> 0 then
      Result[I] := Result[I] xor $80000000;
  end;
end;

procedure TPSPVFPU.WriteVector(Reg, Count: Integer; const Value: TPSPVector; ApplyPrefix: Boolean);
begin
  for var I := 0 to Count - 1 do
  begin
    if ApplyPrefix and (Control[2] and (Cardinal(1) shl (8 + I)) <> 0) then
      Continue;
    var V := Value[I];
    if ApplyPrefix then
      case (Control[2] shr (I * 2)) and 3 of
        1:
          V := Clamp(V, False);
        3:
          V := Clamp(V, True);
      end;
    Registers[VectorRegister(Reg, Count, I)] := V;
  end;
end;

function TPSPVFPU.Execute(Op: Cardinal; Memory: TPSPMemory; Base: Cardinal): Boolean;
const
  VFPUConstants: array[0..31] of Cardinal = ($00000000, $7F7FFFFF, $3FB504F3, $3F3504F3, $3F906EBA, $3F22F983, $3EA2F983, $3F490FDB, $3FC90FDB, $40490FDB, $402DF854, $3FB8AA3B, $3EDE5BD9, $3F317218, $40135D8E, $40C90FDB, $3F060A92, $3E9A209B, $40549A78, $3F5DB3D7, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000);
begin
  Result := True;
  var Primary := Op shr 26;
  var Count := 1 + Integer((Op shr 7) and 1) + Integer((Op shr 15) and 1) * 2;
  var D := Integer(Op and 127);
  var S := Integer((Op shr 8) and 127);
  var T := Integer((Op shr 16) and 127);
  if Primary in [50, 53, 54, 58, 61, 62] then
  begin
    {$IFOPT Q+}{$DEFINE VFPU_RESTORE_Q}{$ENDIF}{$Q-}
    var Address := Base + Cardinal(Integer(SmallInt(Op and $FFFC)));
    {$IFDEF VFPU_RESTORE_Q}{$Q+}{$ENDIF}
    if Address and 3 <> 0 then
      raise EPSPMemory.Create('PSP: unaligned VFPU memory access');
    if Primary in [50, 58] then
    begin
      var Reg := Integer((Op shr 16) and 31) or Integer((Op and 3) shl 5);
      if Primary = 50 then
        Registers[Reg] := Memory.Read32(Address)
      else
        Memory.Write32(Address, Registers[Reg]);
      Exit;
    end;
    var Reg := Integer((Op shr 16) and 31) or Integer((Op and 1) shl 5);
    var Value := ReadVector(Reg, 4, 0, False);
    if Primary in [54, 62] then
    begin
      if Address and 15 <> 0 then
        raise EPSPMemory.Create('PSP: unaligned VFPU quadword access');
      for var I := 0 to 3 do
        if Primary = 54 then
          Value[I] := Memory.Read32(Address + Cardinal(I) * 4)
        else
          Memory.Write32(Address + Cardinal(I) * 4, Value[I]);
    end
    else
    begin
      var Offset := Integer((Address shr 2) and 3);
      if Op and 2 = 0 then
        for var I := 0 to Offset do
          if Primary = 53 then
            Value[3 - I] := Memory.Read32(Address - Cardinal(I) * 4)
          else
            Memory.Write32(Address - Cardinal(I) * 4, Value[3 - I])
      else
        for var I := 0 to 3 - Offset do
          if Primary = 53 then
            Value[I] := Memory.Read32(Address + Cardinal(I) * 4)
          else
            Memory.Write32(Address + Cardinal(I) * 4, Value[I]);
    end;
    if Primary in [53, 54] then
      WriteVector(Reg, 4, Value, False);
    Exit;
  end;
  if Primary = 63 then
    Exit; // vnop/vsync/vflush: coherent interpreter.
  if (Primary = 55) and ((Op shr 23) and 7 < 6) then
  begin
    var Index := (Op shr 24) and 3;
    if Index > 2 then
      Exit(False);
    Control[Index] := Op and $FFFFF;
    if Index = 2 then
      Control[Index] := Control[Index] and $FFF;
    Exit;
  end;
  var A := ReadVector(S, Count, Control[0], True);
  var B := ReadVector(T, Count, Control[1], True);
  var Value := Default(TPSPVector);
  var ResultCount := Count;
  var Operation := (Op shr 23) and 7;
  if Primary = 60 then
  begin
    var Group := (Op shr 21) and 31;
    if Group in [20..23] then
    begin
      A := ReadVector(S, Count, 0, False);
      B := ReadVector(T, Count, 0, False);
      if Count = 3 then
      begin
        Value[0] := Calculate(Calculate(A[1], B[2], 2), Calculate(A[2], B[1], 2), 1);
        Value[1] := Calculate(Calculate(A[2], B[0], 2), Calculate(A[0], B[2], 2), 1);
        A := ReadVector(S, Count, Control[0], True);
        var TP := (Control[1] and not $F00FF) or $200B1;
        B := ReadVector(T, Count, TP, True);
        for var K := 0 to Count - 1 do
          Value[2] := Calculate(Value[2], Calculate(A[K], B[K], 2), 0);
      end
      else if Count = 4 then
      begin
        Value[0] := Calculate(Calculate(Calculate(Calculate(A[0], B[3], 2), Calculate(A[1], B[2], 2), 0), Calculate(A[2], B[1], 2), 1), Calculate(A[3], B[0], 2), 0);
        Value[1] := Calculate(Calculate(Calculate(Calculate(A[0], B[2], 2) xor $80000000, Calculate(A[1], B[3], 2), 0), Calculate(A[2], B[0], 2), 0), Calculate(A[3], B[1], 2), 0);
        Value[2] := Calculate(Calculate(Calculate(Calculate(A[0], B[1], 2), Calculate(A[1], B[0], 2), 1), Calculate(A[2], B[3], 2), 0), Calculate(A[3], B[2], 2), 0);
        A := ReadVector(S, Count, Control[0], True);
        var TP := (Control[1] and not $F00FF) or $700E4;
        B := ReadVector(T, Count, TP, True);
        for var K := 0 to Count - 1 do
          Value[3] := Calculate(Value[3], Calculate(A[K], B[K], 2), 0);
      end;
      var DP := Control[2];
      Control[2] := 0;
      if Count > 1 then
        Control[2] := ((DP and $100) shl (Count - 1)) or ((DP and 3) shl ((Count - 1) * 2));
      WriteVector(D, Count, Value, True);
      Control[0] := $E4;
      Control[1] := $E4;
      Control[2] := 0;
      Exit;
    end;
    if Group = 29 then
    begin
      var Immediate := (Op shr 16) and 31;
      var SineLane := (Immediate shr 2) and 3;
      var CosineLane := Immediate and 3;
      var Scalar := ReadVector(S, 1, Control[0] and not $10000, True);
      var Raw := ReadVector(S, 1, 0, False);
      var Sine := VFPSin(Scalar[0]);
      if Immediate and 16 <> 0 then
        Sine := Sine xor $80000000;
      if SineLane = CosineLane then
        for var I := 0 to 3 do
          Value[I] := Sine
      else
        Value[SineLane] := Sine;
      var Cosine := VFPCos(Raw[0]);
      for var I := 0 to Count - 1 do
        if VectorRegister(D, Count, I) = VectorRegister(S, 1, 0) then
          Cosine := VFPCos(Value[I]);
      Value[CosineLane] := Cosine;
      Control[2] := Control[2] and not ((Cardinal(3) shl (CosineLane * 2)) or (Cardinal(1) shl (8 + CosineLane)));
      WriteVector(D, Count, Value, True);
      Control[0] := $E4;
      Control[1] := $E4;
      Control[2] := 0;
      Exit;
    end;
    var MA, MB, MD: array[0..15] of Cardinal;
    FillChar(MA, SizeOf(MA), 0);
    FillChar(MB, SizeOf(MB), 0);
    FillChar(MD, SizeOf(MD), 0);
    var Side := Count;
    if Group in [4..15] then
      Side := Integer((Op shr 23) and 3) + 1;
    for var Column := 0 to Side - 1 do
      for var Lane := 0 to Side - 1 do
      begin
        MA[Column * 4 + Lane] := Registers[MatrixRegister(S, Side, Column, Lane)];
        MB[Column * 4 + Lane] := Registers[MatrixRegister(T, Side, Column, Lane)];
      end;
    if Group in [0..3] then
      for var Column := 0 to Side - 1 do
        for var Lane := 0 to Side - 1 do
          for var K := 0 to Side - 1 do
            MD[Column * 4 + Lane] := Calculate(MD[Column * 4 + Lane], Calculate(MA[Lane * 4 + K], MB[Column * 4 + K], 2), 0)
    else if Group in [4..15] then
    begin
      B := ReadVector(T, Side, Control[1], True);
      if Count < Side then
        B[Side - 1] := $3F800000;
      for var Lane := 0 to Side - 1 do
        for var K := 0 to Side - 1 do
          Value[Lane] := Calculate(Value[Lane], Calculate(MA[Lane * 4 + K], B[K], 2), 0);
      WriteVector(D, Side, Value, True);
      Control[0] := $E4;
      Control[1] := $E4;
      Control[2] := 0;
      Exit;
    end
    else if Group in [16..19] then
    begin
      B := ReadVector(T, 1, Control[1], True);
      for var Column := 0 to Side - 1 do
        for var Lane := 0 to Side - 1 do
          MD[Column * 4 + Lane] := Calculate(MA[Column * 4 + Lane], B[0], 2);
    end
    else if Group = 28 then
    begin
      var Kind := (Op shr 16) and 15;
      if not (Kind in [0, 3, 6, 7]) then
        Exit(False);
      for var Column := 0 to Side - 1 do
        for var Lane := 0 to Side - 1 do
          case Kind of
            0:
              MD[Column * 4 + Lane] := MA[Column * 4 + Lane];
            3:
              if Column = Lane then
                MD[Column * 4 + Lane] := $3F800000;
            7:
              MD[Column * 4 + Lane] := $3F800000;
          end;
    end
    else
      Exit(False);
    for var Column := 0 to Side - 1 do
      for var Lane := 0 to Side - 1 do
        Registers[MatrixRegister(D, Side, Column, Lane)] := MD[Column * 4 + Lane];
    Control[0] := $E4;
    Control[1] := $E4;
    Control[2] := 0;
    Exit;
  end;
  case Primary of
    24:
      begin
        if not (Operation in [0, 1, 7]) then
          Exit(False);
        var Code := Integer(Operation);
        if Code = 7 then
          Code := 3;
        for var I := 0 to Count - 1 do
          Value[I] := Calculate(A[I], B[I], Code);
      end;
    25:
      case Operation of
        0:
          for var I := 0 to Count - 1 do
            Value[I] := Calculate(A[I], B[I], 2);
        1, 4:
          begin
            ResultCount := 1;
            for var I := 0 to Count - 1 do
            begin
              var V := A[I];
              if (Operation = 4) and (I = Count - 1) then
                V := $3F800000;
              Value[0] := Calculate(Value[0], Calculate(V, B[I], 2), 0);
            end;
          end;
        2:
          begin
            B := ReadVector(T, 1, Control[1], True);
            for var I := 0 to Count - 1 do
              Value[I] := Calculate(A[I], B[0], 2);
          end;
      else
        Exit(False);
      end;
    27:
      begin
        if not (Operation in [0, 2, 3, 5, 6, 7]) then
          Exit(False);
        var Conditions: Cardinal := 0;
        var Any := False;
        var All := True;
        for var I := 0 to Count - 1 do
        begin
          var Unordered, Equal, Less: Boolean;
          SFCompare(A[I], B[I], 16, Unordered, Equal, Less);
          if Operation = 0 then
          begin
            var Condition: Boolean;
            case Op and 15 of
              0:
                Condition := False;
              1:
                Condition := Equal;
              2:
                Condition := Less;
              3:
                Condition := Less or Equal;
              4:
                Condition := True;
              5:
                Condition := not Equal;
              6:
                Condition := not Unordered and not Less;
              7:
                Condition := not Unordered and not Less and not Equal;
              8:
                Condition := A[I] and $7FFFFFFF = 0;
              9:
                Condition := SFIsNaN(A[I], 16);
              10:
                Condition := A[I] and $7FFFFFFF = $7F800000;
              11:
                Condition := A[I] and $7F800000 = $7F800000;
              12:
                Condition := A[I] and $7FFFFFFF <> 0;
              13:
                Condition := not SFIsNaN(A[I], 16);
              14:
                Condition := A[I] and $7FFFFFFF <> $7F800000;
            else
              Condition := A[I] and $7F800000 <> $7F800000;
            end;
            if Condition then
              Conditions := Conditions or (Cardinal(1) shl I);
            Any := Any or Condition;
            All := All and Condition;
          end
          else
            case Operation of
              2:
                Value[I] := VFMin(A[I], B[I]);
              3:
                Value[I] := VFMax(A[I], B[I]);
              5:
                if Equal then
                  Value[I] := 0
                else if Less then
                  Value[I] := $BF800000
                else
                  Value[I] := $3F800000;
              6:
                if not Unordered and not Less then
                  Value[I] := $3F800000;
              7:
                if Less then
                  Value[I] := $3F800000;
            end;
        end;
        if Operation = 0 then
        begin
          var Mask := ((Cardinal(1) shl Count) - 1) or $30;
          Control[3] := (Control[3] and not Mask) or Conditions or (Cardinal(Ord(Any)) shl 4) or (Cardinal(Ord(All)) shl 5);
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
      end;
    52:
      begin
        var Group := (Op shr 21) and 31;
        if (Group = 1) and (T and 31 < 4) then
        begin
          var FunctionCode := T and 31;
          if FunctionCode = 0 then
          begin
            var SeedVector := ReadVector(S, 1, Control[0], True);
            var Seed := SeedVector[0];
            for var I := 0 to 7 do
              Control[8 + I] := $3F800000 or ((Seed shr ((I div 4) * 16)) and $FFFF) or (((Seed shr (I * 4)) and 15) shl 16);
          end
          else
          begin
            // Hardware generates lanes backwards. D mask/saturation bit zero
            // applies only to the last lane, rather than independently per lane.
            for var I := Count - 1 downto 0 do
            begin
              Value[I] := RandomWord(Control);
              if FunctionCode = 2 then
                Value[I] := $3F800000 or (Value[I] and $7FFFFF)
              else if FunctionCode = 3 then
                Value[I] := $40000000 or (Value[I] and $7FFFFF);
            end;
            var DP := Control[2];
            Control[2] := ((DP and $100) shl (Count - 1)) or ((DP and 3) shl ((Count - 1) * 2));
            WriteVector(D, Count, Value, True);
          end;
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
        if Group = 1 then
        begin
          var FunctionCode := T and 31;
          A := ReadVector(S, Count, Control[0], True, 4);
          case FunctionCode of
            18:
              begin
                ResultCount := (Count + 1) div 2;
                for var I := 0 to ResultCount - 1 do
                  Value[I] := FloatToHalf(A[I * 2]) or (FloatToHalf(A[I * 2 + 1]) shl 16);
              end;
            19:
              begin
                ResultCount := 2;
                if Count > 1 then
                  ResultCount := 4;
                for var I := 0 to ResultCount div 2 - 1 do
                begin
                  Value[I * 2] := HalfToFloat(A[I] and $FFFF);
                  Value[I * 2 + 1] := HalfToFloat(A[I] shr 16);
                end;
              end;
            24, 25:
              begin
                ResultCount := 4;
                for var I := 0 to 3 do
                begin
                  var ByteValue := (A[0] shr (I * 8)) and $FF;
                  if FunctionCode = 24 then
                    Value[I] := (ByteValue * $01010101) shr 1
                  else
                    Value[I] := ByteValue shl 24;
                end;
              end;
            26, 27:
              begin
                ResultCount := 2;
                if Count > 1 then
                  ResultCount := 4;
                for var I := 0 to ResultCount div 2 - 1 do
                begin
                  Value[I * 2] := (A[I] and $FFFF) shl 16;
                  Value[I * 2 + 1] := A[I] and $FFFF0000;
                  if FunctionCode = 26 then
                  begin
                    Value[I * 2] := Value[I * 2] shr 1;
                    Value[I * 2 + 1] := Value[I * 2 + 1] shr 1;
                  end;
                end;
              end;
            28, 29:
              begin
                ResultCount := 1;
                for var I := 0 to 3 do
                begin
                  var V := A[I] shr 24;
                  if FunctionCode = 28 then
                    if A[I] and $80000000 <> 0 then
                      V := 0
                    else
                      V := A[I] shr 23;
                  Value[0] := Value[0] or ((V and $FF) shl (I * 8));
                end;
              end;
            30, 31:
              begin
                ResultCount := (Count + 1) div 2;
                for var I := 0 to ResultCount * 2 - 1 do
                begin
                  var V := A[I] shr 16;
                  if FunctionCode = 30 then
                    if A[I] and $80000000 <> 0 then
                      V := 0
                    else
                      V := A[I] shr 15;
                  Value[I div 2] := Value[I div 2] or (V shl ((I and 1) * 16));
                end;
              end;
          else
            Exit(False);
          end;
          WriteVector(D, ResultCount, Value, True);
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
        if Group = 2 then
        begin
          var FunctionCode := T and 31;
          case FunctionCode of
            0, 1, 8, 9:
              begin
                var Swizzle: Cardinal := $B1;
                if FunctionCode in [1, 9] then
                  Swizzle := $1B;
                B := ReadVector(S, Count, (Control[1] and not $FF) or Swizzle, True);
                for var I := 0 to Count - 1 do
                  if ((FunctionCode = 0) and (I and 1 = 0)) or
                    ((FunctionCode = 1) and (I < 2)) or
                    ((FunctionCode = 8) and (I and 1 <> 0)) or
                    ((FunctionCode = 9) and (I >= 2)) then
                    Value[I] := VFMin(B[I], A[I])
                  else
                    Value[I] := VFMax(A[I], B[I]);
              end;
            2, 3:
              begin
                var Negates: Cardinal := $A0000;
                var Swizzle: Cardinal := $B1;
                if FunctionCode = 3 then
                begin
                  Negates := $C0000;
                  Swizzle := $4E;
                end;
                A := ReadVector(S, Count, Control[0] or Negates, True);
                B := ReadVector(S, Count, (Control[1] and not $FF) or Swizzle, True);
                for var I := 0 to Count - 1 do
                  Value[I] := Calculate(A[I], B[I], 0);
              end;
            4:
              for var I := 0 to Count - 1 do
                Value[I] := Calculate($3F800000, A[I], 1);
            5:
              begin
                ResultCount := Count * 2;
                if ResultCount > 4 then
                  ResultCount := 4;
                for var I := 0 to ResultCount div 2 - 1 do
                begin
                  Value[I * 2] := Clamp(Calculate($3F800000, A[I], 1), False);
                  Value[I * 2 + 1] := Clamp(A[I], False);
                end;
              end;
            6, 7:
              begin
                ResultCount := 1;
                var TP := (Control[1] and not $FF) or $F055;
                if FunctionCode = 7 then
                begin
                  case Count of
                    1:
                      TP := (Control[1] and not $FFF) or $F000;
                    2:
                      TP := (Control[1] and not $FFF) or $F0FF;
                    3:
                      TP := (Control[1] and not $FFF) or $FF55;
                    4:
                      TP := (Control[1] and not $FFF) or $FFAA;
                  end;
                end;
                B := ReadVector(S, Count, TP, True);
                for var I := 0 to Count - 1 do
                  Value[0] := Calculate(Value[0], Calculate(A[I], B[I], 2), 0);
              end;
            25, 26, 27:
              begin
                A := ReadVector(S, 4, Control[0], True);
                ResultCount := 2;
                if Count = 1 then
                  ResultCount := 1;
                for var I := 0 to 3 do
                begin
                  var V := A[I];
                  var Color: Cardinal := 0;
                  case FunctionCode of
                    25:
                      Color := ((V shr 4) and $F) or ((V shr 8) and $F0) or ((V shr 12) and $F00) or ((V shr 16) and $F000);
                    26:
                      Color := ((V shr 3) and $1F) or ((V shr 6) and $3E0) or ((V shr 9) and $7C00) or ((V shr 16) and $8000);
                    27:
                      Color := ((V shr 3) and $1F) or ((V shr 5) and $7E0) or ((V shr 8) and $F800);
                  end;
                  Value[I div 2] := Value[I div 2] or (Color shl ((I and 1) * 16));
                end;
              end;
            10:
              for var I := 0 to Count - 1 do
                if A[I] and $7FFFFFFF = 0 then
                  Value[I] := 0
                else if A[I] and $80000000 <> 0 then
                  Value[I] := $BF800000
                else
                  Value[I] := $3F800000;
          else
            Exit(False);
          end;
          WriteVector(D, ResultCount, Value, True);
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
        if Group = 3 then
        begin
          for var I := 0 to Count - 1 do
            Value[I] := VFPUConstants[T and 31];
          WriteVector(D, Count, Value, True);
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
        if Group in [16..20] then
        begin
          var Scale := (Op shr 16) and 31;
          for var I := 0 to Count - 1 do
            if Group = 20 then
              Value[I] := Calculate(Cardinal(SFConvert(A[I], 20, 16, 0).Bits), Cardinal(127 - Scale) shl 23, 2)
            else
            begin
              var Scaled := Calculate(A[I], Cardinal(127 + Scale) shl 23, 2);
              var Converted := SFConvert(Scaled, 16, 20, Group - 16);
              Value[I] := Cardinal(Converted.Bits);
              if Converted.Events and sfInvalid <> 0 then
                if SFIsNaN(Scaled, 16) or (Scaled and $80000000 = 0) then
                  Value[I] := $7FFFFFFF
                else
                  Value[I] := $80000000;
            end;
          WriteVector(D, Count, Value, True);
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
        if Group = 21 then
        begin
          var Condition := T and 7;
          var Invert := T and 8 <> 0;
          Value := ReadVector(D, Count, 0, False);
          for var I := 0 to Count - 1 do
          begin
            var Bit := Condition;
            if Bit = 6 then
              Bit := I;
            if (Bit < 7) and ((Control[3] and (Cardinal(1) shl Bit) <> 0) xor Invert) then
              Value[I] := A[I];
          end;
          WriteVector(D, Count, Value, True);
          Control[0] := $E4;
          Control[1] := $E4;
          Control[2] := 0;
          Exit;
        end;
        if Group <> 0 then
          Exit(False);
        var FunctionCode := (Op shr 16) and 31;
        for var I := 0 to Count - 1 do
          case FunctionCode of
            0:
              Value[I] := A[I];
            1:
              Value[I] := A[I] and $7FFFFFFF;
            2:
              Value[I] := A[I] xor $80000000;
            3:
              if I = (D and (Count - 1)) then
                Value[I] := $3F800000;
            4:
              Value[I] := Clamp(A[I], False);
            5:
              Value[I] := Clamp(A[I], True);
            6:
              Value[I] := 0;
            7:
              Value[I] := $3F800000;
            16:
              Value[I] := VFPRcp(A[I]);
            17:
              Value[I] := VFPRSqrt(A[I]);
            18:
              Value[I] := VFPSin(A[I]);
            19:
              Value[I] := VFPCos(A[I]);
            20:
              Value[I] := VFPExp2(A[I]);
            21:
              Value[I] := VFPLog2(A[I]);
            22:
              Value[I] := VFPSqrt(A[I] and $7FFFFFFF);
            23:
              Value[I] := VFPASin(A[I]);
            24:
              Value[I] := VFPRcp(A[I]) xor $80000000;
            26:
              Value[I] := VFPSin(A[I]) xor $80000000;
            28:
              Value[I] := VFPExp2(A[I] xor $80000000);
          else
            Exit(False);
          end;
      end;
    55:
      begin
        if not ((Op shr 23) and 7 in [6, 7]) then
          Exit(False);
        ResultCount := 1;
        D := T;
        if (Op shr 23) and 7 = 6 then
          Value[0] := Cardinal(SFConvert(Cardinal(Integer(SmallInt(Op and $FFFF))), 20, 16, 0).Bits)
        else
          Value[0] := HalfToFloat(Op and $FFFF);
      end;
  else
    Exit(False);
  end;
  WriteVector(D, ResultCount, Value, True);
  Control[0] := $E4;
  Control[1] := $E4;
  Control[2] := 0;
end;

end.

