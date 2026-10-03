unit SNES.NecDSP;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TNecFlags = packed record
    Carry, Zero, Overflow0, Overflow1, Sign0, Sign1: Boolean;
  end;

  TNecState = packed record
    Cycles: Int64;
    A, B, TR, TRB, PC, RP, DP, DR, SR, K, L, M, N, SerialOut, SerialIn: Word;
    FlagsA, FlagsB: TNecFlags;
    SP: Byte;
    RAM: array[0..2047] of Word;
    Stack: array[0..7] of Word;
    Waiting: Boolean;
  end;

  TSnesNecDSP = class
  private
    FProgram: TArray<Cardinal>;
    FData: TArray<Word>;
    FProgramMask, FDataMask, FRAMMask, FStackMask: Word;
    FExtended, FDirty: Boolean;
    FOp: Cardinal;
    function Source(Index: Integer): Word;
    procedure Load(Index: Integer; Value: Word);
    procedure ALU(Operation: Integer; Input: Word);
    procedure ExecuteOp;
    procedure Jump;
  public
    State: TNecState;
    constructor Create(const Firmware: TBytes; Extended: Boolean = False);
    procedure Reset;
    procedure Step;
    procedure RunUntil(Target: Int64);
    function Read(Status: Boolean): Byte;
    procedure Write(Status: Boolean; Value: Byte);
    function ReadRAMByte(Address: Cardinal): Byte;
    procedure WriteRAMByte(Address: Cardinal; Value: Byte);
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    procedure SerializeState(Archive: TStateArchive);
    property BatteryDirty: Boolean read FDirty;
  end;

implementation

constructor TSnesNecDSP.Create(const Firmware: TBytes; Extended: Boolean);
begin
  inherited Create;
  FExtended := Extended;
  var ProgramSize := $1800;
  var DataSize := $800;
  FRAMMask := $FF;
  FStackMask := 3;
  if Extended then
  begin
    ProgramSize := $C000;
    DataSize := $1000;
    FRAMMask := $7FF;
    FStackMask := 7;
  end;
  if Length(Firmware) <> ProgramSize + DataSize then
    raise EReadError.CreateFmt('NEC DSP firmware must contain %d bytes', [ProgramSize + DataSize]);
  SetLength(FProgram, ProgramSize div 3);
  SetLength(FData, DataSize div 2);
  FProgramMask := Length(FProgram) - 1;
  FDataMask := Length(FData) - 1;
  for var J := 0 to High(FProgram) do
    FProgram[J] := Firmware[J * 3] or (Cardinal(Firmware[J * 3 + 1]) shl 8) or (Cardinal(Firmware[J * 3 + 2]) shl 16);
  for var J := 0 to High(FData) do
    FData[J] := Firmware[ProgramSize + J * 2] or (Word(Firmware[ProgramSize + J * 2 + 1]) shl 8);
  Reset;
end;

procedure TSnesNecDSP.Reset;
begin
  // Mesen resets registers while preserving DSP work RAM and stack contents.
  var RAM := State.RAM;
  var Stack := State.Stack;
  State := Default(TNecState);
  State.RAM := RAM;
  State.Stack := Stack;
end;

function TSnesNecDSP.Source(Index: Integer): Word;
begin
  case Index of
    0:
      Result := State.TRB;
    1:
      Result := State.A;
    2:
      Result := State.B;
    3:
      Result := State.TR;
    4:
      Result := State.DP;
    5:
      Result := State.RP;
    6:
      Result := FData[State.RP and FDataMask];
    7:
      Result := $8000 - Ord(State.FlagsA.Sign1);
    8:
      begin
        State.SR := State.SR or $8000;
        Result := State.DR;
      end;
    9:
      Result := State.DR;
    10:
      Result := State.SR;
    11, 12:
      Result := State.SerialIn;
    13:
      Result := State.K;
    14:
      Result := State.L;
  else
    Result := State.RAM[State.DP and FRAMMask];
  end;
end;

procedure TSnesNecDSP.Load(Index: Integer; Value: Word);
begin
  case Index of
    1:
      State.A := Value;
    2:
      State.B := Value;
    3:
      State.TR := Value;
    4:
      State.DP := Value;
    5:
      State.RP := Value;
    6:
      begin
        State.DR := Value;
        State.SR := State.SR or $8000;
      end;
    7:
      State.SR := (State.SR and $907C) or (Value and not $907C);
    8, 9:
      State.SerialOut := Value;
    10:
      State.K := Value;
    11:
      begin
        State.K := Value;
        State.L := FData[State.RP and FDataMask];
      end;
    12:
      begin
        State.L := Value;
        State.K := State.RAM[(State.DP or $40) and FRAMMask];
      end;
    13:
      State.L := Value;
    14:
      State.TRB := Value;
    15:
      begin
        var Address := State.DP and FRAMMask;
        if State.RAM[Address] <> Value then
        begin
          State.RAM[Address] := Value;
          FDirty := True;
        end;
      end;
  end;
end;

procedure TSnesNecDSP.ALU(Operation: Integer; Input: Word);
begin
  var Select := (FOp and $8000) <> 0;
  var Flags := State.FlagsA;
  var Acc := State.A;
  var Carry := Ord(State.FlagsB.Carry);
  if Select then
  begin
    Flags := State.FlagsB;
    Acc := State.B;
    Carry := Ord(State.FlagsA.Carry);
  end;
  var P: Word;
  case (FOp shr 20) and 3 of
    0:
      P := State.RAM[State.DP and FRAMMask];
    1:
      P := Input;
    2:
      P := State.M;
  else
    P := State.N;
  end;
  var R: Word := 0;
  case Operation of
    1:
      R := Acc or P;
    2:
      R := Acc and P;
    3:
      R := Acc xor P;
    4:
      R := Word(Acc - P);
    5:
      R := Word(Acc + P);
    6:
      R := Word(Acc - P - Carry);
    7:
      R := Word(Acc + P + Carry);
    8:
      begin
        R := Word(Acc - 1);
        P := 1;
      end;
    9:
      begin
        R := Word(Acc + 1);
        P := 1;
      end;
    10:
      R := not Acc;
    11:
      R := (Acc shr 1) or (Acc and $8000);
    12:
      R := Word((Acc shl 1) or Carry);
    13:
      R := Word((Acc shl 2) or 3);
    14:
      R := Word((Acc shl 4) or 15);
    15:
      R := Word((Acc shl 8) or (Acc shr 8));
  end;
  Flags.Zero := R = 0;
  Flags.Sign0 := (R and $8000) <> 0;
  if not Flags.Overflow1 then
    Flags.Sign1 := Flags.Sign0;
  case Operation of
    4..9:
      begin
        var Overflow: Word;
        if (Operation and 1) <> 0 then
          Overflow := (Acc xor R) and (P xor R)
        else
          Overflow := (Acc xor R) and (P xor Acc);
        Flags.Overflow0 := (Overflow and $8000) <> 0;
        if Flags.Overflow0 and Flags.Overflow1 then
          Flags.Overflow1 := Flags.Sign0 = Flags.Sign1
        else
          Flags.Overflow1 := Flags.Overflow1 or Flags.Overflow0;
        Flags.Carry := ((Acc xor P xor R xor Overflow) and $8000) <> 0;
      end;
  else
    Flags.Carry := False;
    Flags.Overflow0 := False;
    Flags.Overflow1 := False;
    if Operation = 11 then
      Flags.Carry := (Acc and 1) <> 0;
    if Operation = 12 then
      Flags.Carry := (Acc and $8000) <> 0;
  end;
  if Select then
  begin
    State.B := R;
    State.FlagsB := Flags;
  end
  else
  begin
    State.A := R;
    State.FlagsA := Flags;
  end;
end;

procedure TSnesNecDSP.ExecuteOp;
begin
  var Input := Source((FOp shr 4) and 15);
  var Op := (FOp shr 16) and 15;
  if Op <> 0 then
    ALU(Op, Input);
  var Dest := FOp and 15;
  Load(Dest, Input);
  if Dest <> 4 then
  begin
    var DP := State.DP;
    case (FOp shr 13) and 3 of
      1:
        DP := (DP and $F0) or ((DP + 1) and 15);
      2:
        DP := (DP and $F0) or ((DP - 1) and 15);
      3:
        DP := DP and $F0;
    end;
    State.DP := DP xor (((FOp shr 9) and 15) shl 4);
  end;
  if ((FOp and $100) <> 0) and (Dest <> 5) then
    State.RP := (Integer(State.RP) - 1) and $FFFF;
end;

procedure TSnesNecDSP.Jump;
begin
  var Kind := (FOp shr 13) and $1FF;
  var Target: Word := (State.PC and $2000) or ((FOp and 3) shl 11) or ((FOp shr 2) and $7FF);
  var Taken := False;
  case Kind of
    0:
      State.PC := State.SerialOut;
    $80, $82:
      Taken := State.FlagsA.Carry;
    $84, $86:
      Taken := State.FlagsB.Carry;
    $88, $8A:
      Taken := State.FlagsA.Zero;
    $8C, $8E:
      Taken := State.FlagsB.Zero;
    $90, $92:
      Taken := State.FlagsA.Overflow0;
    $94, $96:
      Taken := State.FlagsB.Overflow0;
    $98, $9A:
      Taken := State.FlagsA.Overflow1;
    $9C, $9E:
      Taken := State.FlagsB.Overflow1;
    $A0, $A2:
      Taken := State.FlagsA.Sign0;
    $A4, $A6:
      Taken := State.FlagsB.Sign0;
    $A8, $AA:
      Taken := State.FlagsA.Sign1;
    $AC, $AE:
      Taken := State.FlagsB.Sign1;
    $B0, $B1:
      Taken := (State.DP and 15) <> 0;
    $B2:
      Taken := (State.DP and 15) = 15;
    $B3:
      Taken := (State.DP and 15) <> 15;
    $B4, $B6:
      Taken := (State.SR and $100) <> 0;
    $B8, $BA:
      Taken := (State.SR and $200) <> 0;
    $BC, $BE:
      Taken := (State.SR and $8000) <> 0;
    $100, $101, $140, $141:
      begin
        if Kind >= $140 then
        begin
          State.Stack[State.SP] := State.PC;
          State.SP := (State.SP + 1) and FStackMask;
        end;
        if (Kind and 1) = 0 then
          State.PC := Target and not $2000
        else
          State.PC := Target or $2000;
      end;
  end;
  if ((Kind >= $80) and (Kind <= $AE) and ((Kind and 3) = 0)) or
    (Kind = $B0) or (Kind = $B4) or (Kind = $B8) or (Kind = $BC) then
    Taken := not Taken;
  if Taken then
  begin
    if (Word(State.PC - 1) = Target) and ((Kind = $BC) or (Kind = $BE)) then
      State.Waiting := True;
    State.PC := Target;
  end;
end;

procedure TSnesNecDSP.Step;
begin
  FOp := FProgram[State.PC and FProgramMask];
  State.PC := (Integer(State.PC) + 1) and $FFFF;
  case FOp shr 22 of
    0:
      ExecuteOp;
    1:
      begin
        ExecuteOp;
        State.SP := (State.SP - 1) and FStackMask;
        State.PC := State.Stack[State.SP];
      end;
    2:
      Jump;
    3:
      Load(FOp and 15, Word(FOp shr 6));
  end;
  var Product := Integer(SmallInt(State.K)) * SmallInt(State.L);
  State.M := Word(Product shr 15);
  State.N := Word(Product shl 1);
  Inc(State.Cycles);
end;

procedure TSnesNecDSP.RunUntil(Target: Int64);
begin
  if State.Waiting then
    State.Cycles := Target
  else
    while State.Cycles < Target do
      Step;
end;

function TSnesNecDSP.Read(Status: Boolean): Byte;
begin
  if Status then
    Exit(State.SR shr 8);
  State.Waiting := False;
  if (State.SR and $400) <> 0 then
  begin
    State.SR := State.SR and not $8000;
    Exit(Byte(State.DR));
  end;
  if (State.SR and $1000) <> 0 then
  begin
    State.SR := State.SR and not $9000;
    Result := State.DR shr 8;
  end
  else
  begin
    State.SR := State.SR or $1000;
    Result := Byte(State.DR);
  end;
end;

procedure TSnesNecDSP.Write(Status: Boolean; Value: Byte);
begin
  if Status then
    Exit;
  State.Waiting := False;
  if (State.SR and $400) <> 0 then
  begin
    State.SR := State.SR and not $8000;
    State.DR := (State.DR and $FF00) or Value;
  end
  else if (State.SR and $1000) <> 0 then
  begin
    State.SR := State.SR and not $9000;
    State.DR := (State.DR and $FF) or (Word(Value) shl 8);
  end
  else
  begin
    State.SR := State.SR or $1000;
    State.DR := (State.DR and $FF00) or Value;
  end;
end;

function TSnesNecDSP.ReadRAMByte(Address: Cardinal): Byte;
begin
  var Value := State.RAM[(Address shr 1) and FRAMMask];
  if (Address and 1) = 0 then
    Result := Byte(Value)
  else
    Result := Value shr 8;
end;

procedure TSnesNecDSP.WriteRAMByte(Address: Cardinal; Value: Byte);
begin
  var Index := (Address shr 1) and FRAMMask;
  var Previous := State.RAM[Index];
  var Next: Word;
  if (Address and 1) = 0 then
    Next := (Previous and $FF00) or Value
  else
    Next := (Previous and $FF) or (Word(Value) shl 8);
  if Next <> Previous then
  begin
    State.RAM[Index] := Next;
    FDirty := True;
  end;
end;

procedure TSnesNecDSP.LoadBattery(const Data: TBytes);
begin
  if not FExtended or (Length(Data) <> $1000) then
    raise EReadError.Create('ST01x RAM size mismatch');
  for var J := 0 to $7FF do
    State.RAM[J] := Data[J * 2] or (Word(Data[J * 2 + 1]) shl 8);
  FDirty := False;
end;

function TSnesNecDSP.BatteryData: TBytes;
begin
  Result := nil;
  if not FExtended then
    Exit;
  SetLength(Result, $1000);
  for var J := 0 to $7FF do
  begin
    Result[J * 2] := Byte(State.RAM[J]);
    Result[J * 2 + 1] := State.RAM[J] shr 8;
  end;
end;

procedure TSnesNecDSP.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  if Archive.Loading and ((State.SP > FStackMask) or (State.Cycles < 0)) then
    raise EReadError.Create('Invalid NEC DSP snapshot state');
  if Archive.Loading and FExtended then
    FDirty := True;
end;

end.

