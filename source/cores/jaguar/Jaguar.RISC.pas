unit Jaguar.RISC;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TJaguarRead = function(Address: Cardinal; Size: Integer): Cardinal of object;

  TJaguarWrite = procedure(Address, Value: Cardinal; Size: Integer) of object;

  TJaguarStepTrace = procedure(PC: Cardinal) of object;

  TJaguarRISC = class
  private
    FRead: TJaguarRead;
    FWrite: TJaguarWrite;
    FRegisters: array[0..1, 0..31] of Cardinal;
    FFlags, FPC, FControl, FMatrixControl, FMatrixAddress, FEndian: Cardinal;
    FHiData, FDivideControl, FRemainder, FModulo, FBranch: Cardinal;
    FAccumulator: Int64;
    FDelay, FDSP, FExecuting: Boolean;
    FPendingFlags: Cardinal;
    FFlagsDelay: Integer;
    FCycles: Integer;
    FStepTrace: TJaguarStepTrace;
    function Bank: Integer;
    procedure ZN(Value: Cardinal);
    function Add(A, B, Carry: Cardinal): Cardinal;
    function Subtract(A, B, Carry: Cardinal): Cardinal;
    function Condition(Code: Integer): Boolean;
    procedure CheckInterrupts;
    function ReadData(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteData(Address, Value: Cardinal; Size: Integer);
  public
    constructor Create(Reader: TJaguarRead; Writer: TJaguarWrite; DSP: Boolean);
    procedure Reset;
    procedure Run(Cycles: Integer);
    procedure Step;
    procedure Interrupt(Line: Integer);
    function ReadControl(Offset: Cardinal): Cardinal;
    procedure WriteControl(Offset, Value: Cardinal);
    function ReadRegister(Index: Integer): Cardinal;
    procedure WriteRegister(Index: Integer; Value: Cardinal);
    procedure SerializeState(State: TStateArchive);
    property PC: Cardinal read FPC write FPC;
    property Control: Cardinal read FControl;
    property OnStep: TJaguarStepTrace read FStepTrace write FStepTrace;
  end;

implementation

uses
  System.Math;

// All datapath operations wrap at 32 bits, as on Tom/Jerry.
{$Q-}{$R-}

constructor TJaguarRISC.Create(Reader: TJaguarRead; Writer: TJaguarWrite; DSP: Boolean);
begin
  inherited Create;
  FRead := Reader;
  FWrite := Writer;
  FDSP := DSP;
  Reset;
end;

procedure TJaguarRISC.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FPC := $F03000;
  if FDSP then
    FPC := $F1B000;
  FFlags := 0;
  FControl := $2800;
  FMatrixControl := 0;
  FMatrixAddress := 0;
  FEndian := $70007;
  FHiData := 0;
  FDivideControl := 0;
  FRemainder := 0;
  FModulo := $FFFFFFFF;
  FAccumulator := 0;
  FBranch := 0;
  FDelay := False;
  FCycles := 0;
  FExecuting := False;
  FFlagsDelay := 0;
  FPendingFlags := 0;
end;

function TJaguarRISC.Bank: Integer;
begin
  Result := 0;
  if FFlags and 8 = 0 then
    Result := (FFlags shr 14) and 1;
end;

function TJaguarRISC.ReadRegister(Index: Integer): Cardinal;
begin
  Result := FRegisters[(Index shr 5) and 1, Index and 31];
end;

procedure TJaguarRISC.WriteRegister(Index: Integer; Value: Cardinal);
begin
  FRegisters[(Index shr 5) and 1, Index and 31] := Value;
end;

procedure TJaguarRISC.ZN(Value: Cardinal);
begin
  FFlags := (FFlags and not Cardinal(5)) or Cardinal(Ord(Value = 0)) or ((Value shr 29) and 4);
end;

function TJaguarRISC.Add(A, B, Carry: Cardinal): Cardinal;
begin
  var Sum := UInt64(A) + B + Carry;
  Result := Cardinal(Sum);
  FFlags := (FFlags and not Cardinal(2)) or Cardinal((Sum shr 31) and 2);
  ZN(Result);
end;

function TJaguarRISC.Subtract(A, B, Carry: Cardinal): Cardinal;
begin
  Result := A - B - Carry;
  FFlags := (FFlags and not Cardinal(2)) or (Cardinal(Ord(UInt64(A) < UInt64(B) + Carry)) shl 1);
  ZN(Result);
end;

function TJaguarRISC.Condition(Code: Integer): Boolean;
begin
  var Flag := (FFlags shr 1) and 1;
  if Code and 16 <> 0 then
    Flag := (FFlags shr 2) and 1;
  Result := not (((Code and 1 <> 0) and (FFlags and 1 <> 0)) or
    ((Code and 2 <> 0) and (FFlags and 1 = 0)) or
    ((Code and 4 <> 0) and (Flag <> 0)) or ((Code and 8 <> 0) and (Flag = 0)));
end;

procedure TJaguarRISC.Interrupt(Line: Integer);
begin
  if FControl and 1 = 0 then
    Exit;
  if (Line >= 0) and (Line <= 4) then
    FControl := FControl or (Cardinal(1) shl (6 + Line));
  if FDSP and (Line = 5) then
    FControl := FControl or $10000;
end;

procedure TJaguarRISC.CheckInterrupts;
begin
  if (FFlags and 8 <> 0) or FDelay or (FFlagsDelay > 0) then
    Exit;
  var IRQ := -1;
  for var i := 0 to 4 do
    if (FControl and (Cardinal(1) shl (6 + i)) <> 0) and
      (FFlags and (Cardinal(1) shl (4 + i)) <> 0) then
      IRQ := i;
  if FDSP and (FControl and $10000 <> 0) and (FFlags and $10000 <> 0) then
    IRQ := 5;
  if IRQ < 0 then
    Exit;
  FFlags := FFlags or 8;
  FRegisters[0, 31] := FRegisters[0, 31] - 4;
  FWrite(FRegisters[0, 31] and not Cardinal(3), FPC - 2, 4);
  FPC := $F03000 + Cardinal(IRQ * 16);
  if FDSP then
    FPC := $F1B000 + Cardinal(IRQ * 16);
  FRegisters[0, 30] := FPC;
end;

function TJaguarRISC.ReadData(Address: Cardinal; Size: Integer): Cardinal;
begin
  // Operand transfers occupy the memory interface independently of ALU
  // execution. Local loads need write-back; external transfers need a bus
  // transaction. The cartridge / I/O path is 16-bit, unlike DRAM.
  var local := (not FDSP and (Address >= $F02000) and (Address < $F04000)) or
    (FDSP and (Address >= $F1A100) and (Address < $F1D000));
  if local then
    Dec(FCycles)
  else if Address < $800000 then
    Dec(FCycles, 5)
  else
    Dec(FCycles, ((Size + 1) div 2) * 8 - 1);
  Result := FRead(Address, Size);
end;

procedure TJaguarRISC.WriteData(Address, Value: Cardinal; Size: Integer);
begin
  var local := (not FDSP and (Address >= $F02000) and (Address < $F04000)) or
    (FDSP and (Address >= $F1A100) and (Address < $F1D000));
  if not local then
    if Address < $800000 then
      Dec(FCycles, 5)
    else
      Dec(FCycles, ((Size + 1) div 2) * 8 - 1);
  FWrite(Address, Value, Size);
end;

function TJaguarRISC.ReadControl(Offset: Cardinal): Cardinal;
begin
  Result := 0;
  case Offset and $FC of
    0:
      Result := FFlags;
    4:
      Result := FMatrixControl;
    8:
      Result := FMatrixAddress;
    12:
      Result := FEndian;
    16:
      Result := FPC;
    20:
      Result := FControl;
    24:
      if FDSP then
        Result := FModulo
      else
        Result := FHiData;
    28:
      Result := FRemainder;
    32:
      Result := Cardinal(FAccumulator shr 32);
  end;
end;

procedure TJaguarRISC.WriteControl(Offset, Value: Cardinal);
begin
  case Offset and $FC of
    0:
      begin
        for var i := 0 to 4 do
          if Value and (Cardinal(1) shl (9 + i)) <> 0 then
            FControl := FControl and not (Cardinal(1) shl (6 + i));
        if Value and $20000 <> 0 then
          FControl := FControl and not Cardinal($10000);
        var NewFlags := Value and $1C1FF;
        NewFlags := (NewFlags and not Cardinal(8)) or (FFlags and Value and 8);
        if FExecuting then
        begin
          FPendingFlags := NewFlags;
          FFlagsDelay := 2;
        end
        else
        begin
          FFlags := NewFlags;
          FFlagsDelay := 0;
        end;
      end;
    4:
      FMatrixControl := Value;
    8:
      FMatrixAddress := Value;
    12:
      FEndian := Value;
    16:
      begin
        FPC := Value and $FFFFFE;
        FDelay := False;
      end;
    20:
      begin
        FControl := (FControl and $1F7C0) or (Value and $83B9);
        if Value and 4 <> 0 then
          Interrupt(0);
      end;
    24:
      if FDSP then
        FModulo := Value
      else
        FHiData := Value;
    28:
      FDivideControl := Value;
  end;
end;

procedure TJaguarRISC.Run(Cycles: Integer);
begin
  if FControl and 1 = 0 then
    Exit;
  Inc(FCycles, Cycles);
  while (FCycles > 0) and (FControl and 1 <> 0) do
  begin
    CheckInterrupts;
    Step;
    Dec(FCycles);
  end;
end;

procedure TJaguarRISC.Step;
begin
  if Assigned(FStepTrace) then
    FStepTrace(FPC);
  FExecuting := True;
  var InstructionPC := FPC;
  var Op := FRead(FPC, 2);
  FPC := (FPC + 2) and $FFFFFF;
  var Delay := FDelay;
  var Target := FBranch;
  FDelay := False;
  var Code := Op shr 10;
  var S := (Op shr 5) and 31;
  var D := Op and 31;
  var B := Bank;
  var A := FRegisters[B, S];
  var V := FRegisters[B, D];
  var Q := S;
  if Q = 0 then
    Q := 32;
  var R := V;
  var Store := True;
  case Code of
    0:
      R := Add(V, A, 0);
    1:
      R := Add(V, A, (FFlags shr 1) and 1);
    2:
      R := Add(V, Q, 0);
    3:
      R := V + Q;
    4:
      R := Subtract(V, A, 0);
    5:
      R := Subtract(V, A, (FFlags shr 1) and 1);
    6:
      R := Subtract(V, Q, 0);
    7:
      R := V - Q;
    8:
      R := Subtract(0, V, 0);
    9:
      begin
        R := V and A;
        ZN(R);
      end;
    10:
      begin
        R := V or A;
        ZN(R);
      end;
    11:
      begin
        R := V xor A;
        ZN(R);
      end;
    12:
      begin
        R := not V;
        ZN(R);
      end;
    13:
      begin
        FFlags := (FFlags and not Cardinal(1)) or Cardinal(Ord(V and (Cardinal(1) shl S) = 0));
        Store := False;
      end;
    14:
      begin
        R := V or (Cardinal(1) shl S);
        ZN(R);
      end;
    15:
      begin
        R := V and not (Cardinal(1) shl S);
        ZN(R);
      end;
    16:
      begin
        R := (A and $FFFF) * (V and $FFFF);
        ZN(R);
      end;
    17:
      begin
        R := Cardinal(Integer(SmallInt(A)) * Integer(SmallInt(V)));
        ZN(R);
      end;
    18:
      begin
        FAccumulator := Integer(SmallInt(A)) * Integer(SmallInt(V));
        ZN(Cardinal(FAccumulator));
        Store := False;
      end;
    19:
      R := Cardinal(FAccumulator);
    20:
      begin
        Inc(FAccumulator, Integer(SmallInt(A)) * Integer(SmallInt(V)));
        if FDSP then
        begin
          FAccumulator := FAccumulator and $FFFFFFFFFF;
          if FAccumulator and $8000000000 <> 0 then
            FAccumulator := FAccumulator or Int64($FFFFFF0000000000);
        end
        else
          FAccumulator := Integer(Cardinal(FAccumulator));
        Store := False;
      end;
    21:
      begin
        var Dividend := UInt64(V);
        if FDivideControl and 1 <> 0 then
          Dividend := Dividend shl 16;
        if A = 0 then
        begin
          R := $FFFFFFFF;
          FRemainder := V;
        end
        else
        begin
          R := Cardinal(Dividend div A);
          FRemainder := Cardinal(Dividend mod A);
        end;
        Dec(FCycles, 17);
      end;
    22:
      begin
        R := V;
        if Integer(V) < 0 then
          R := 0 - V;
        FFlags := (FFlags and not Cardinal(2)) or ((V shr 30) and 2);
        ZN(R);
      end;
    23, 26:
      begin
        if Integer(A) < 0 then
        begin
          FFlags := (FFlags and not Cardinal(2)) or ((V shr 30) and 2);
          if Integer(A) <= -32 then
            R := 0
          else
            R := V shl (-Integer(A));
        end
        else
        begin
          FFlags := (FFlags and not Cardinal(2)) or ((V and 1) shl 1);
          if A >= 32 then
            R := 0
          else
            R := V shr A;
          if (Code = 26) and (Integer(V) < 0) then
            if A >= 32 then
              R := $FFFFFFFF
            else if A <> 0 then
              R := R or ($FFFFFFFF shl (32 - A));
        end;
        ZN(R);
      end;
    24:
      begin
        R := V shl (32 - S);
        if S = 0 then
          R := 0;
        FFlags := (FFlags and not Cardinal(2)) or ((V shr 30) and 2);
        ZN(R);
      end;
    25, 27:
      begin
        R := V shr Q;
        if Q = 32 then
          R := 0;
        if (Code = 27) and (Integer(V) < 0) then
          R := R or ($FFFFFFFF shl (32 - Q));
        FFlags := (FFlags and not Cardinal(2)) or ((V and 1) shl 1);
        ZN(R);
      end;
    28, 29:
      begin
        if Code = 28 then
          Q := A and 31;
        R := (V shr (Q and 31)) or (V shl ((32 - Q) and 31));
        FFlags := (FFlags and not Cardinal(2)) or ((V shr 30) and 2);
        ZN(R);
      end;
    30:
      begin
        Subtract(V, A, 0);
        Store := False;
      end;
    31:
      begin
        Subtract(V, Cardinal((Integer(S) xor 16) - 16), 0);
        Store := False;
      end;
    32:
      if FDSP then
        R := (Subtract(V, Q, 0) and not FModulo) or (V and FModulo)
      else
      begin
        R := Cardinal(EnsureRange(Integer(V), 0, 255));
        ZN(R);
      end;
    33:
      begin
        if FDSP then
          R := Cardinal(EnsureRange(Integer(V), -32768, 32767))
        else
          R := Cardinal(EnsureRange(Integer(V), 0, 65535));
        ZN(R);
      end;
    34:
      R := A;
    35:
      R := S;
    36:
      begin
        FRegisters[1 - B, D] := A;
        Store := False;
      end;
    37:
      R := FRegisters[1 - B, S];
    38:
      begin
        R := FRead(FPC, 2) or (FRead(FPC + 2, 2) shl 16);
        Inc(FPC, 4);
        Dec(FCycles, 2);
      end;
    39:
      if ((not FDSP) and (A and $FFF000 = $F03000)) or
        (FDSP and (A >= $F1B000) and (A < $F1D000)) then
        R := ReadData(A and not Cardinal(3), 4)
      else
        R := ReadData(A, 1);
    40:
      if ((not FDSP) and (A and $FFF000 = $F03000)) or
        (FDSP and (A >= $F1B000) and (A < $F1D000)) then
        R := ReadData(A and not Cardinal(3), 4)
      else
        R := ReadData(A and not Cardinal(1), 2);
    41:
      R := ReadData(A and not Cardinal(3), 4);
    42:
      if FDSP then
      begin
        var HighPart := Integer(FAccumulator shr 32);
        if HighPart < -1 then
          R := $80000000
        else if HighPart > 0 then
          R := $7FFFFFFF
        else
          R := V;
        ZN(R);
      end
      else
      begin
        FHiData := ReadData(A and not Cardinal(7), 4);
        R := ReadData((A and not Cardinal(7)) + 4, 4);
      end;
    43, 44:
      R := ReadData(FRegisters[B, 14 + Ord(Code = 44)] + Q * 4, 4);
    45:
      begin
        if ((not FDSP) and (A and $FFF000 = $F03000)) or (FDSP and (A >= $F1B000) and (A < $F1D000)) then
          WriteData(A and not Cardinal(3), V and $FF, 4)
        else
          WriteData(A, V, 1);
        Store := False;
      end;
    46:
      begin
        if ((not FDSP) and (A and $FFF000 = $F03000)) or (FDSP and (A >= $F1B000) and (A < $F1D000)) then
          WriteData(A and not Cardinal(3), V and $FFFF, 4)
        else
          WriteData(A and not Cardinal(1), V, 2);
        Store := False;
      end;
    47:
      begin
        WriteData(A and not Cardinal(3), V, 4);
        Store := False;
      end;
    48:
      if FDSP then
      begin
        R := 0;
        for var i := 0 to 31 do
          R := (R shl 1) or ((V shr i) and 1);
        ZN(R);
      end
      else
      begin
        WriteData(A and not Cardinal(7), FHiData, 4);
        WriteData((A and not Cardinal(7)) + 4, V, 4);
        Store := False;
      end;
    49, 50:
      begin
        WriteData(FRegisters[B, 14 + Ord(Code = 50)] + Q * 4, V, 4);
        Store := False;
      end;
    51:
      R := InstructionPC;
    52:
      begin
        if Condition(D) then
        begin
          FBranch := A and $FFFFFE;
          FDelay := True;
        end;
        Store := False;
      end;
    53:
      begin
        if Condition(D) then
        begin
          FBranch := (FPC + Cardinal(((Integer(S) xor 16) - 16) * 2)) and $FFFFFE;
          FDelay := True;
        end;
        Store := False;
      end;
    54:
      begin
        var Sum: Int64 := 0;
        var Count := Integer(FMatrixControl and 15);
        var LocalBase: Cardinal := $F03000;
        if FDSP then
          LocalBase := $F1B000;
        var Address := LocalBase or (FMatrixAddress and $FFC);
        for var i := 0 to Count - 1 do
        begin
          var M := FRegisters[1, (S + Cardinal(i div 2)) and 31];
          if i and 1 <> 0 then
            M := M shr 16;
          Inc(Sum, Integer(SmallInt(M)) * Integer(SmallInt(FRead(Address + 2, 2))));
          if FMatrixControl and 16 <> 0 then
            Inc(Address, Count * 4)
          else
            Inc(Address, 4);
          Address := LocalBase or (Address and $FFC);
        end;
        R := Cardinal(Sum);
        ZN(R);
        Dec(FCycles, Count);
      end;
    55:
      begin
        R := ((A shr 8) and $FF800000) or (A and $007FFFFF);
        if A and $80000000 <> 0 then
          R := R or $FF000000;
        ZN(R);
      end;
    56:
      begin
        var Count := -32;
        if A <> 0 then
        begin
          Count := -23;
          while A shr 1 <> 0 do
          begin
            A := A shr 1;
            Inc(Count);
          end;
        end;
        R := Cardinal(Count);
        ZN(R);
      end;
    57:
      Store := False;
    58, 59:
      R := ReadData(FRegisters[B, 14 + Ord(Code = 59)] + A, 4);
    60, 61:
      begin
        WriteData(FRegisters[B, 14 + Ord(Code = 61)] + A, V, 4);
        Store := False;
      end;
    62:
      if FDSP then
        Store := False
      else
      begin
        R := Cardinal(EnsureRange(Integer(V), 0, $FFFFFF));
        ZN(R);
      end;
    63:
      if FDSP then
        R := (Add(V, Q, 0) and not FModulo) or (V and FModulo)
      else if S = 0 then
        R := ((V shr 10) and $F000) or ((V shr 5) and $F00) or (V and $FF)
      else
        R := ((V and $F000) shl 10) or ((V and $F00) shl 5) or (V and $FF);
  end;
  if Store then
    FRegisters[B, D] := R;
  if Delay then
  begin
    FPC := Target;
    // JTRM rev. 8, instruction timing: the taken branch refills the
    // instruction pipeline after its atomic delay-slot instruction.
    Dec(FCycles, 3);
  end;
  FExecuting := False;
  if FFlagsDelay > 0 then
  begin
    Dec(FFlagsDelay);
    if Delay then
      FFlagsDelay := 0;
    if FFlagsDelay = 0 then
      FFlags := FPendingFlags;
  end;
end;

procedure TJaguarRISC.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FFlags, SizeOf(FFlags));
  State.Field(FPC, SizeOf(FPC));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FMatrixControl, SizeOf(FMatrixControl));
  State.Field(FMatrixAddress, SizeOf(FMatrixAddress));
  State.Field(FEndian, SizeOf(FEndian));
  State.Field(FHiData, SizeOf(FHiData));
  State.Field(FDivideControl, SizeOf(FDivideControl));
  State.Field(FRemainder, SizeOf(FRemainder));
  State.Field(FModulo, SizeOf(FModulo));
  State.Field(FBranch, SizeOf(FBranch));
  State.Field(FAccumulator, SizeOf(FAccumulator));
  State.Field(FDelay, SizeOf(FDelay));
  State.Field(FCycles, SizeOf(FCycles));
  State.Field(FPendingFlags, SizeOf(FPendingFlags));
  State.Field(FFlagsDelay, SizeOf(FFlagsDelay));
end;

end.

