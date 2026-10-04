unit SNES.ST018;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TArmProduct = record
    Value: UInt64;
    Carry: Boolean;
    Cycles: Integer;
  end;

  TArmState = packed record
    R: array[0..15] of Cardinal;
    CPSR: Cardinal;
    UserRegs, FiqRegs: array[0..6] of Cardinal;
    BankRegs: array[0..3, 0..1] of Cardinal;
    SPSR: array[0..4] of Cardinal;
    FetchAddress, FetchOp, DecodeAddress, DecodeOp, ExecuteAddress, ExecuteOp: Cardinal;
    Reload: Boolean;
    Cycles: UInt64;
  end;

  TSt018State = packed record
    DataArm, DataSnes: Byte;
    HasArm, HasSnes, Ack, ArmReset: Boolean;
  end;

  TSnesST018 = class
  private
    FFirmware: TBytes;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure SetR(Reg: Integer; Value: Cardinal);
    function SPSRIndex: Integer;
    procedure SwitchMode(Mode: Cardinal);
    procedure ExceptionVector(Mode, Vector: Cardinal);
    function Conditions(Condition: Integer): Boolean;
    function Shift(Value: Cardinal; Kind, Amount: Integer; Immediate: Boolean; var Carry: Boolean): Cardinal;
    function Add(A, B: Cardinal; Carry, Flags: Boolean): Cardinal;
    function Logical(Value: Cardinal; Carry, Flags: Boolean): Cardinal;
    procedure RestorePSR;
  public
    CPU: TArmState;
    State: TSt018State;
    RAM: array[0..$3FFF] of Byte;
    constructor Create(const Firmware: TBytes);
    procedure PowerOn(KeepClock: Boolean);
    procedure Reset;
    procedure Step;
    procedure Execute(Op: Cardinal);
    procedure RunUntil(Target: UInt64);
    function ReadCPU(Address: Cardinal; ByteAccess: Boolean = False): Cardinal;
    procedure WriteCPU(Address, Value: Cardinal; ByteAccess: Boolean = False);
    function Read(Address: Cardinal; OpenBus: Byte): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    function Status: Byte;
    procedure SerializeState(Archive: TStateArchive);
  end;

function ArmMultiply(A, B, Accumulator: UInt64; LongResult, SignedResult: Boolean): TArmProduct;

implementation

type
  TArmWide = record
    Lo, Hi: UInt64;
  end;

function ArmAdd32(A, B: Cardinal): Cardinal; inline;
begin
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
end;

function ArmSub32(A, B: Cardinal): Cardinal; inline;
begin
  Result := Cardinal((Int64(A) - B) and $FFFFFFFF);
end;

function ArmMask(Lo, Hi: Integer): UInt64;
begin
  Result := ((UInt64(1) shl (Hi - Lo)) - 1) shl Lo;
end;

function ArmBit(X: UInt64; N: Integer): Boolean;
begin
  Result := ((X shr N) and 1) <> 0;
end;

function ArmSign(X: UInt64; FromSize, ToSize: Integer): UInt64;
begin
  Result := X;
  if ArmBit(X, FromSize - 1) then
    Result := Result or ArmMask(FromSize, ToSize);
end;

function ArmWideRor(X: TArmWide; N: Integer): TArmWide;
begin
  Result.Lo := (X.Lo shr N) or (X.Hi shl (64 - N));
  Result.Hi := (X.Hi shr N) or (X.Lo shl (64 - N));
end;

procedure ArmCSA(var Sum, Carry: UInt64; A, B: UInt64; var Acc: UInt64);
begin
  var FinalSum: UInt64 := 0;
  var FinalCarry: UInt64 := 0;
  for var J := 0 to 3 do
  begin
    var Addend: UInt64 := 0;
    var BoothCarry: UInt64 := 0;
    case (B shr (J * 2)) and 7 of
      1, 2:
        Addend := A;
      3:
        Addend := A shl 1;
      4:
        begin
          Addend := not (A shl 1);
          BoothCarry := 1;
        end;
      5, 6:
        begin
          Addend := not A;
          BoothCarry := 1;
        end;
    end;
    Addend := Addend and $3FFFFFFFF;
    Sum := Sum and $1FFFFFFFF;
    Carry := Carry and $1FFFFFFFF;
    var Recode := Addend and $1FFFFFFFF;
    var NextSum := Sum xor Recode xor Carry;
    var NextCarry := (((Sum and Recode) or (Recode and Carry) or (Carry and Sum)) shl 1) or BoothCarry;
    FinalSum := FinalSum or ((NextSum and 3) shl (J * 2));
    FinalCarry := FinalCarry or ((NextCarry and 3) shl (J * 2));
    var Magic := Ord(ArmBit(Acc, 0)) + Ord(not ArmBit(Carry, 32)) + Ord(not ArmBit(Addend, 33));
    Sum := (NextSum shr 2) or (UInt64(Magic) shl 31);
    Carry := (NextCarry shr 2) or (UInt64(Ord(not ArmBit(Acc, 1))) shl 32);
    Acc := Acc shr 2;
  end;
  Sum := FinalSum or (Sum shl 8);
  Carry := FinalCarry or (Carry shl 8);
end;

function ArmAdder(A, B: Cardinal; var Carry: Boolean): Cardinal;
begin
  var V := UInt64(A) + B + UInt64(Ord(Carry));
  Result := Cardinal(V);
  Carry := V > $FFFFFFFF;
end;

function ArmMultiply(A, B, Accumulator: UInt64; LongResult, SignedResult: Boolean): TArmProduct;
const
  Rotations: array[1..4] of Integer = (23, 15, 7, 31);
begin
  var ALUCarry := ArmBit(B, 0);
  if SignedResult then
  begin
    A := ArmSign(A, 32, 34);
    B := ArmSign(B, 32, 34);
  end
  else
  begin
    A := A and $1FFFFFFFF;
    B := B and $1FFFFFFFF;
  end;
  var Carry: UInt64 := 0;
  if ArmBit(B, 0) then
    Carry := not A;
  var Sum := Accumulator;
  var Acc := Accumulator shr 34;
  var PartialSum: TArmWide := Default(TArmWide);
  var PartialCarry: TArmWide := Default(TArmWide);
  PartialSum.Lo := Sum and 1;
  PartialCarry.Lo := Carry and 1;
  Sum := Sum shr 1;
  Carry := Carry shr 1;
  PartialSum := ArmWideRor(PartialSum, 1);
  PartialCarry := ArmWideRor(PartialCarry, 1);
  Result.Cycles := 0;
  repeat
    ArmCSA(Sum, Carry, A, B, Acc);
    PartialSum.Lo := PartialSum.Lo or (Sum and $FF);
    PartialCarry.Lo := PartialCarry.Lo or (Carry and $FF);
    Sum := Sum shr 8;
    Carry := Carry shr 8;
    PartialSum := ArmWideRor(PartialSum, 8);
    PartialCarry := ArmWideRor(PartialCarry, 8);
    B := ArmSign(B, 33, 64);
    B := B shr 8;
    if ArmBit(B, 55) then
      B := B or $FF00000000000000;
    B := B and $1FFFFFFFF;
    Inc(Result.Cycles);
  until (B = 0) or (SignedResult and (B = $1FFFFFFFF));
  PartialSum.Lo := PartialSum.Lo or Sum;
  PartialCarry.Lo := PartialCarry.Lo or Carry;
  PartialSum := ArmWideRor(PartialSum, Rotations[Result.Cycles]);
  PartialCarry := ArmWideRor(PartialCarry, Rotations[Result.Cycles]);
  var Lo: Cardinal;
  var Hi: Cardinal := 0;
  if Result.Cycles = 4 then
    Lo := ArmAdder(Cardinal(PartialSum.Hi), Cardinal(PartialCarry.Hi), ALUCarry)
  else
    Lo := ArmAdder(Cardinal(PartialSum.Hi shr 32), Cardinal(PartialCarry.Hi shr 32), ALUCarry);
  if LongResult then
  begin
    if Result.Cycles = 4 then
      Hi := ArmAdder(Cardinal(PartialSum.Hi shr 32), Cardinal(PartialCarry.Hi shr 32), ALUCarry)
    else
    begin
      var N := 2 + 8 * Result.Cycles;
      PartialCarry.Lo := ArmSign(PartialCarry.Lo, N, 64);
      PartialSum.Lo := PartialSum.Lo or (Acc shl N);
      Hi := ArmAdder(Cardinal(PartialSum.Lo), Cardinal(PartialCarry.Lo), ALUCarry);
    end;
  end;
  Result.Value := UInt64(Lo) or (UInt64(Hi) shl 32);
  if LongResult or (Result.Cycles <> 4) then
    Result.Carry := ArmBit(PartialCarry.Hi, 63)
  else
    Result.Carry := ArmBit(PartialCarry.Hi, 31);
end;


{ TSnesST018 }

constructor TSnesST018.Create(const Firmware: TBytes);
begin
  inherited Create;
  if Length(Firmware) <> $28000 then
    raise EArgumentException.Create('ST018 firmware must contain 163840 bytes');

  FFirmware := Copy(Firmware);
  PowerOn(False);
end;

procedure TSnesST018.Reset;
begin
  // Preserve ARM/mailbox contents as in Mesen, rebasing to this console's reset clock.
  CPU.Cycles := 0;
end;

function TSnesST018.Status: Byte;
begin
  Result := Ord(State.HasSnes) or (Ord(State.Ack) shl 2) or (Ord(State.HasArm) shl 3) or (Ord(not State.ArmReset) shl 7);
end;

function TSnesST018.ReadByte(Address: Cardinal): Byte;
begin
  case Address shr 28 of
    0:
      Exit(FFirmware[Address and $1FFFF]);
    4:
      case Address and $3F of
        $10:
          begin
            State.HasArm := False;
            Exit(State.DataArm);
          end;
        $20:
          Exit(Status);
      end;
    $A:
      Exit(FFirmware[$20000 + (Address and $7FFF)]);
    $E:
      Exit(RAM[Address and $3FFF]);
  end;
  Result := 0;
end;

procedure TSnesST018.WriteByte(Address: Cardinal; Value: Byte);
begin
  case Address shr 28 of
    4:
      case Address and $3F of
        0:
          begin
            State.HasSnes := True;
            State.DataSnes := Value;
          end;
        $10:
          State.Ack := True;
      end;
    $E:
      RAM[Address and $3FFF] := Value;
  end;
end;

function TSnesST018.ReadCPU(Address: Cardinal; ByteAccess: Boolean): Cardinal;
begin
  Inc(CPU.Cycles);
  if ByteAccess then
    Exit(ReadByte(Address));

  Address := Address and not Cardinal(3);
  Result := 0;
  for var J := 0 to 3 do
    Result := Result or (Cardinal(ReadByte(Address + Cardinal(J))) shl (J * 8));
end;

procedure TSnesST018.WriteCPU(Address, Value: Cardinal; ByteAccess: Boolean);
begin
  Inc(CPU.Cycles);
  if ByteAccess then
    WriteByte(Address, Byte(Value))
  else
  begin
    Address := Address and not Cardinal(3);
    for var J := 0 to 3 do
      WriteByte(Address + Cardinal(J), Byte(Value shr (J * 8)));
  end;
end;

procedure TSnesST018.SetR(Reg: Integer; Value: Cardinal);
begin
  CPU.R[Reg] := Value;
  if Reg = 15 then
    CPU.Reload := True;
end;

function BankIndex(Mode: Cardinal): Integer;
begin
  case Mode and $1F of
    $12:
      Result := 0;
    $13:
      Result := 1;
    $17:
      Result := 2;
    $1B:
      Result := 3;
  else
    Result := -1;
  end;
end;

function TSnesST018.SPSRIndex: Integer;
begin
  Result := BankIndex(CPU.CPSR) + 1;
  if (CPU.CPSR and $1F) = $11 then
    Result := 0;
end;

procedure TSnesST018.SwitchMode(Mode: Cardinal);
begin
  Mode := (Mode and $1F) or $10;
  var Original := CPU.CPSR and $1F;
  if Original = Mode then
    Exit;

  var Index := BankIndex(Original);
  if Original = $11 then
    Move(CPU.R[8], CPU.FiqRegs, SizeOf(CPU.FiqRegs))
  else
  begin
    Move(CPU.R[8], CPU.UserRegs, 5 * 4);
    if Index < 0 then
      Move(CPU.R[13], CPU.UserRegs[5], 2 * 4)
    else
      Move(CPU.R[13], CPU.BankRegs[Index], 2 * 4);
  end;
  CPU.CPSR := (CPU.CPSR and not Cardinal($1F)) or Mode;
  if Mode = $11 then
    Move(CPU.FiqRegs, CPU.R[8], SizeOf(CPU.FiqRegs))
  else
  begin
    Move(CPU.UserRegs, CPU.R[8], SizeOf(CPU.UserRegs));
    Index := BankIndex(Mode);
    if Index >= 0 then
      Move(CPU.BankRegs[Index], CPU.R[13], 2 * 4);
  end;
end;

procedure TSnesST018.ExceptionVector(Mode, Vector: Cardinal);
begin
  var PSR := CPU.CPSR;
  SwitchMode(Mode);
  CPU.SPSR[SPSRIndex] := PSR;
  CPU.CPSR := CPU.CPSR or $80;
  CPU.R[14] := CPU.DecodeAddress;
  SetR(15, Vector);
end;

procedure TSnesST018.RestorePSR;
begin
  if (CPU.CPSR and $1F) in [$10, $1F] then
    Exit;

  var PSR := CPU.SPSR[SPSRIndex];
  SwitchMode(PSR);
  CPU.CPSR := PSR;
end;

function TSnesST018.Conditions(Condition: Integer): Boolean;
begin
  var N := (CPU.CPSR and $80000000) <> 0;
  var Z := (CPU.CPSR and $40000000) <> 0;
  var C := (CPU.CPSR and $20000000) <> 0;
  var V := (CPU.CPSR and $10000000) <> 0;
  case Condition of
    0:
      Result := Z;
    1:
      Result := not Z;
    2:
      Result := C;
    3:
      Result := not C;
    4:
      Result := N;
    5:
      Result := not N;
    6:
      Result := V;
    7:
      Result := not V;
    8:
      Result := C and not Z;
    9:
      Result := not C or Z;
    10:
      Result := N = V;
    11:
      Result := N <> V;
    12:
      Result := not Z and (N = V);
    13:
      Result := Z or (N <> V);
    14:
      Result := True;
  else
    Result := False;
  end;
end;

function TSnesST018.Shift(Value: Cardinal; Kind, Amount: Integer; Immediate: Boolean; var Carry: Boolean): Cardinal;
begin
  Amount := Amount and $FF;
  Result := Value;
  if Immediate and (Amount = 0) then
    case Kind of
      1, 2:
        Amount := 32;
      3:
        begin
          Result := (Value shr 1) or (Cardinal(Ord(Carry)) shl 31);
          Carry := (Value and 1) <> 0;
          Exit;
        end;
    end;
  if Amount = 0 then
    Exit;

  case Kind of
    0:
      begin
        Carry := (Amount <= 32) and ((Value and (Cardinal(1) shl (32 - Amount))) <> 0);
        if Amount < 32 then
          Result := Value shl Amount
        else
          Result := 0;
      end;
    1:
      begin
        Carry := (Amount <= 32) and ((Value and (Cardinal(1) shl (Amount - 1))) <> 0);
        if Amount < 32 then
          Result := Value shr Amount
        else
          Result := 0;
      end;
    2:
      begin
        if Amount < 32 then
        begin
          Carry := ((Value shr (Amount - 1)) and 1) <> 0;
          Result := Value shr Amount;
          if (Value and $80000000) <> 0 then
            Result := Result or (Cardinal($FFFFFFFF) shl (32 - Amount));
        end
        else
        begin
          Carry := (Value and $80000000) <> 0;
          if Carry then
            Result := $FFFFFFFF
          else
            Result := 0;
        end;
      end;
    3:
      begin
        Amount := Amount and 31;
        if Amount <> 0 then
          Result := (Value shr Amount) or (Value shl (32 - Amount));
        Carry := (Result and $80000000) <> 0;
      end;
  end;
end;

function TSnesST018.Add(A, B: Cardinal; Carry, Flags: Boolean): Cardinal;
begin
  var Sum := UInt64(A) + B + UInt64(Ord(Carry));
  Result := Cardinal(Sum);
  if Flags then
  begin
    var Overflow := not (A xor B) and (A xor Result) and $80000000;
    CPU.CPSR := (CPU.CPSR and $FFFFFFF) or (Result and $80000000) or (Cardinal(Ord(Result = 0)) shl 30) or
      (Cardinal(Ord(Sum > $FFFFFFFF)) shl 29) or (Overflow shr 3);
  end;
end;

function TSnesST018.Logical(Value: Cardinal; Carry, Flags: Boolean): Cardinal;
begin
  Result := Value;
  if not Flags then
    Exit;

  CPU.CPSR := (CPU.CPSR and $1FFFFFFF) or (Value and $80000000) or
    (Cardinal(Ord(Value = 0)) shl 30) or (Cardinal(Ord(Carry)) shl 29);
end;

procedure TSnesST018.PowerOn(KeepClock: Boolean);
begin
  var Clock := CPU.Cycles;
  CPU := Default(TArmState);
  CPU.CPSR := $D3;
  CPU.Reload := True;
  CPU.R[15] := 0;
  CPU.FetchAddress := 0;
  CPU.DecodeAddress := 0;
  // PowerOn in Mesen performs the first pipeline fill before preserving reset clock.
  CPU.FetchOp := ReadCPU(0);
  CPU.DecodeOp := CPU.FetchOp;
  CPU.DecodeAddress := 0;
  CPU.FetchAddress := 4;
  CPU.FetchOp := ReadCPU(4);
  CPU.R[15] := 8;
  CPU.ExecuteAddress := CPU.DecodeAddress;
  CPU.ExecuteOp := CPU.DecodeOp;
  CPU.DecodeAddress := CPU.FetchAddress;
  CPU.DecodeOp := CPU.FetchOp;
  CPU.FetchAddress := 8;
  CPU.FetchOp := ReadCPU(8);
  CPU.Reload := False;
  if KeepClock then
    CPU.Cycles := Clock;
end;

procedure TSnesST018.Step;
begin
  Execute(CPU.ExecuteOp);
  if CPU.Reload then
  begin
    CPU.R[15] := CPU.R[15] and not Cardinal(3);
    CPU.DecodeAddress := CPU.R[15];
    CPU.DecodeOp := ReadCPU(CPU.R[15]);
    CPU.R[15] := ArmAdd32(CPU.R[15], 4);
    CPU.FetchAddress := CPU.R[15];
    CPU.FetchOp := ReadCPU(CPU.R[15]);
    CPU.Reload := False;
  end;
  CPU.ExecuteAddress := CPU.DecodeAddress;
  CPU.ExecuteOp := CPU.DecodeOp;
  CPU.DecodeAddress := CPU.FetchAddress;
  CPU.DecodeOp := CPU.FetchOp;
  CPU.R[15] := ArmAdd32(CPU.R[15], 4);
  CPU.FetchAddress := CPU.R[15];
  CPU.FetchOp := ReadCPU(CPU.R[15]);
end;

procedure TSnesST018.Execute(Op: Cardinal);
begin
  if not Conditions(Op shr 28) then
    Exit;

  var RN := Integer((Op shr 16) and 15);
  var RD := Integer((Op shr 12) and 15);
  var RM := Integer(Op and 15);
  var RS := Integer((Op shr 8) and 15);
  var Flags := (Op and $100000) <> 0;
  var Carry := (CPU.CPSR and $20000000) <> 0;
  var TypeIndex := ((Op and $FF00000) shr 16) or ((Op shr 4) and 15);

  if (TypeIndex and $F8F) = $009 then
  begin
    var Acc := (Op and $200000) <> 0;
    var AccValue: UInt64 := 0;
    if Acc then
      AccValue := CPU.R[RD];
    var Product := ArmMultiply(CPU.R[RM], CPU.R[RS], AccValue, False, True);
    Inc(CPU.Cycles, Product.Cycles + Ord(Acc));
    if RN <> 15 then
      SetR(RN, Cardinal(Product.Value));
    if Flags then
      Logical(Cardinal(Product.Value), Product.Carry, True);
    Exit;
  end;

  if (TypeIndex and $F8F) = $089 then
  begin
    var Acc := (Op and $200000) <> 0;
    var AccValue: UInt64 := 0;
    if Acc then
      AccValue := UInt64(CPU.R[RD]) or (UInt64(CPU.R[RN]) shl 32);
    var Product := ArmMultiply(CPU.R[RM], CPU.R[RS], AccValue, True, (Op and $400000) <> 0);
    var V := Product.Value;
    if RD <> 15 then
      SetR(RD, Cardinal(V));
    if RN <> 15 then
      SetR(RN, Cardinal(V shr 32));
    Inc(CPU.Cycles, Product.Cycles + 1 + Ord(Acc));
    if Flags then
    begin
      CPU.CPSR := (CPU.CPSR and $1FFFFFFF) or
        Cardinal((V shr 32) and $80000000) or (Cardinal(Ord(V = 0)) shl 30) or (Cardinal(Ord(Product.Carry)) shl 29);
    end;
    Exit;
  end;

  if ((TypeIndex and $F0F) = $109) then
  begin
    var ByteAccess := (Op and $400000) <> 0;
    var V := ReadCPU(CPU.R[RN], ByteAccess);
    Inc(CPU.Cycles);
    WriteCPU(CPU.R[RN], ArmAdd32(CPU.R[RM], Ord(RM = 15) * 4), ByteAccess);
    SetR(RD, V);
    Exit;
  end;

  case (Op shr 25) and 7 of
    0, 1:
      begin
        var ALU := (Op shr 21) and 15;
        if not Flags and (ALU in [8..11]) then
        begin
          var ToSPSR := (Op and $400000) <> 0;
          var Index := SPSRIndex;
          var PSR := CPU.CPSR;
          if ToSPSR and not ((CPU.CPSR and $1F) in [$10, $1F]) then
            PSR := CPU.SPSR[Index];
          if (ALU and 1) = 0 then
            SetR(RD, PSR)
          else
          begin
            if ToSPSR and ((CPU.CPSR and $1F) in [$10, $1F]) then
              Exit;
            var V := CPU.R[RM];
            if (Op and $2000000) <> 0 then
            begin
              V := Op and $FF;
              var ShiftCount := ((Op shr 8) and 15) * 2;
              if ShiftCount <> 0 then
                V := (V shr ShiftCount) or (V shl (32 - ShiftCount));
            end;
            if (Op and $80000) <> 0 then
              PSR := (PSR and $FFFFFFF) or (V and $F0000000);
            if ((Op and $10000) <> 0) and (ToSPSR or ((CPU.CPSR and $1F) <> $10)) then
              PSR := (PSR and not Cardinal($DF)) or (V and $DF);
            if ToSPSR then
              CPU.SPSR[Index] := PSR
            else
            begin
              SwitchMode(PSR);
              CPU.CPSR := PSR;
            end;
          end;
          Exit;
        end;

        var A := CPU.R[RN];
        var B: Cardinal;
        if (Op and $2000000) <> 0 then
        begin
          B := Op and $FF;
          var ShiftCount := ((Op shr 8) and 15) * 2;
          if ShiftCount <> 0 then
            B := Shift(B, 3, ShiftCount, False, Carry);
        end
        else
        begin
          B := CPU.R[RM];
          var UseReg := (Op and $10) <> 0;
          var Amount := Integer((Op shr 7) and 31);
          if UseReg then
          begin
            Inc(CPU.Cycles);
            Amount := Byte(ArmAdd32(CPU.R[RS], Ord(RS = 15) * 4));
            if RM = 15 then
              B := ArmAdd32(B, 4);
            if RN = 15 then
              A := ArmAdd32(A, 4);
          end;
          B := Shift(B, (Op shr 5) and 3, Amount, not UseReg, Carry);
        end;

        var V: Cardinal := 0;
        case ALU of
          0, 8:
            V := Logical(A and B, Carry, Flags or (ALU = 8));
          1, 9:
            V := Logical(A xor B, Carry, Flags or (ALU = 9));
          2, 10:
            V := Add(A, not B, True, Flags or (ALU = 10));
          3:
            V := Add(B, not A, True, Flags);
          4, 11:
            V := Add(A, B, False, Flags or (ALU = 11));
          5:
            V := Add(A, B, (CPU.CPSR and $20000000) <> 0, Flags);
          6:
            V := Add(A, not B, (CPU.CPSR and $20000000) <> 0, Flags);
          7:
            V := Add(B, not A, (CPU.CPSR and $20000000) <> 0, Flags);
          12:
            V := Logical(A or B, Carry, Flags);
          13:
            V := Logical(B, Carry, Flags);
          14:
            V := Logical(A and not B, Carry, Flags);
          15:
            V := Logical(not B, Carry, Flags);
        end;
        if not (ALU in [8..11]) then
          SetR(RD, V);
        if (RD = 15) and Flags then
          RestorePSR;
      end;
    2, 3:
      begin
        var Offset := Op and $FFF;
        if (Op and $2000000) <> 0 then
          Offset := Shift(CPU.R[RM], (Op shr 5) and 3, (Op shr 7) and 31, True, Carry);
        if (Op and $800000) = 0 then
          Offset := ArmSub32(0, Offset);
        var Addr := CPU.R[RN];
        var Pre := (Op and $1000000) <> 0;
        if Pre then
          Addr := ArmAdd32(Addr, Offset);
        var Load := (Op and $100000) <> 0;
        var ByteAccess := (Op and $400000) <> 0;
        if Load then
        begin
          SetR(RD, ReadCPU(Addr, ByteAccess));
          Inc(CPU.Cycles);
        end
        else
          WriteCPU(Addr, ArmAdd32(CPU.R[RD], Ord(RD = 15) * 4), ByteAccess);
        if not Pre then
          Addr := ArmAdd32(Addr, Offset);
        if ((RD <> RN) or not Load) and (((Op and $200000) <> 0) or not Pre) then
          SetR(RN, Addr);
      end;
    4:
      begin
        var Pre := (Op and $1000000) <> 0;
        var Up := (Op and $800000) <> 0;
        var User := (Op and $400000) <> 0;
        var WB := (Op and $200000) <> 0;
        var Load := (Op and $100000) <> 0;
        var Mask := Word(Op);
        var Count := 0;
        for var J := 0 to 15 do
          if (Mask and (1 shl J)) <> 0 then
            Inc(Count);
        if Mask = 0 then
        begin
          Mask := $8000;
          Count := 16;
        end;
        var Base := ArmAdd32(CPU.R[RN], Ord(RN = 15) * 4);
        var Addr := Base;
        if not Up then
          Addr := ArmSub32(Addr, (Count - Ord(not Pre)) * 4)
        else if Pre then
          Addr := ArmAdd32(Addr, 4);
        var NewBase := ArmAdd32(Base, Count * 4);
        if not Up then
          NewBase := ArmSub32(Base, Count * 4);
        if WB and Load then
          SetR(RN, NewBase);
        var Original := CPU.CPSR and $1F;
        if User and (not Load or ((Mask and $8000) = 0)) then
          SwitchMode($10);
        var First := True;
        for var J := 0 to 15 do
          if (Mask and (1 shl J)) <> 0 then
          begin
            if not Load then
              WriteCPU(Addr, ArmAdd32(CPU.R[J], Ord(J = 15) * 4));
            if First and WB then
            begin
              SetR(RN, NewBase);
              First := False;
            end;
            if Load then
              SetR(J, ReadCPU(Addr));
            Addr := ArmAdd32(Addr, 4);
          end;
        if Load then
          Inc(CPU.Cycles);
        SwitchMode(Original);
        if User and Load and ((Mask and $8000) <> 0) then
          RestorePSR;
      end;
    5:
      begin
        if (Op and $1000000) <> 0 then
          CPU.R[14] := ArmSub32(CPU.R[15], 4);
        var Offset := Integer(Op shl 8) div 64;
        SetR(15, ArmAdd32(CPU.R[15], Cardinal(Offset)));
      end;
    7:
      if (Op and $F000000) = $F000000 then
        ExceptionVector($13, 8)
      else
        ExceptionVector($1B, 4);
  else
    ExceptionVector($1B, 4);
  end;
end;

procedure TSnesST018.RunUntil(Target: UInt64);
begin
  if State.ArmReset then
    CPU.Cycles := Target
  else
    while CPU.Cycles < Target do
      Step;
end;

function TSnesST018.Read(Address: Cardinal; OpenBus: Byte): Byte;
begin
  Result := OpenBus;
  case Address and $FF06 of
    $3800:
      begin
        State.HasSnes := False;
        Result := State.DataSnes;
      end;
    $3802:
      State.Ack := False;
    $3804:
      Result := Status;
  end;
end;

procedure TSnesST018.Write(Address: Cardinal; Value: Byte);
begin
  case Address and $FF06 of
    $3802:
      begin
        State.DataArm := Value;
        State.HasArm := True;
      end;
    $3804:
      begin
        if State.ArmReset and (Value = 0) then
          PowerOn(True);
        State.ArmReset := Value <> 0;
      end;
  end;
end;

procedure TSnesST018.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(CPU, SizeOf(CPU));
  Archive.Field(State, SizeOf(State));
  Archive.Field(RAM, SizeOf(RAM));
end;

end.

