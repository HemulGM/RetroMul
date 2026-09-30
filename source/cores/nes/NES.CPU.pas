unit NES.CPU;

interface

uses
  NES.State, NES.Types;

const
  FLAG_CARRY = $01;
  FLAG_ZERO = $02;
  FLAG_INTERRUPT = $04;
  FLAG_DECIMAL = $08;
  FLAG_BREAK = $10;
  FLAG_UNUSED = $20;
  FLAG_OVERFLOW = $40;
  FLAG_NEGATIVE = $80;

type
  TCpuReadFunc = function(Address: UInt16): UInt8 of object;

  TCpuWriteProc = procedure(Address: UInt16; Value: UInt8) of object;

  TInterruptKind = (ikNone, ikIrq, ikNmi);

  TCpu6502 = class
  private
    FRead: TCpuReadFunc;
    FWrite: TCpuWriteProc;
    FPendingNmi: Boolean;
    FPendingIrq: Boolean;
    FNmiAfterInstruction: Boolean;
    FIrqAfterInstruction: Boolean;
    FUnknownOpcodeCount: Integer;
    FJammed: Boolean;
    FJamOpcode: UInt8;
    FJamPc: UInt16;
    FInterruptSequenceActive: Boolean;
    FInterruptKind: TInterruptKind;
    FInterruptBreakFlag: Boolean;
    FInterruptLatchedPc: UInt16;
    FInterruptLatchedP: UInt8;
    FInterruptVectorLow: UInt8;
    FPollInterruptDisable: Boolean;
    FInstructionActive: Boolean;
    FPollCycle: Integer;
    FExecutingOpcode: Boolean;
    FQueuedWriteCount: Integer;
    FWriteAddresses: array[0..2] of UInt16;
    FWriteValues: array[0..2] of UInt8;
    FLastUnknownOpcode: UInt8;
    FLastUnknownPc: UInt16;
    function Read(Address: UInt16): UInt8;
    procedure Write(Address: UInt16; Value: UInt8);
    procedure Push(Value: UInt8);
    function Pull: UInt8;
    function Read16(Address: UInt16): UInt16;
    function Read16Bug(Address: UInt16): UInt16;
    function GetFlag(Flag: UInt8): Boolean;
    procedure SetFlag(Flag: UInt8; Value: Boolean);
    procedure SetZeroNegative(Value: UInt8);
    function Imm: UInt16;
    function Zp0: UInt16;
    function Zpx: UInt16;
    function Zpy: UInt16;
    function AbsAddr: UInt16;
    function Abx(out PageCrossed: Boolean): UInt16;
    function Aby(out PageCrossed: Boolean): UInt16;
    function Ind: UInt16;
    function Izx: UInt16;
    function Izy(out PageCrossed: Boolean): UInt16;
    function Rel: Int16;
    procedure Adc(Value: UInt8);
    procedure Sbc(Value: UInt8);
    procedure Cmp(RegValue, Value: UInt8);
    procedure Bit(Value: UInt8);
    procedure OpSlo(Address: UInt16);
    procedure OpRla(Address: UInt16);
    procedure OpSre(Address: UInt16);
    procedure OpRra(Address: UInt16);
    procedure OpDcp(Address: UInt16);
    procedure OpIsc(Address: UInt16);
    procedure LaxValue(Value: UInt8);
    procedure Anc(Value: UInt8);
    procedure Alr(Value: UInt8);
    procedure Arr(Value: UInt8);
    procedure Atx(Value: UInt8);
    procedure Branch(Condition: Boolean; Offset: Int16; out Cycles: Integer);
    procedure ClockInterrupt;
    procedure BeginInterruptSequence(Kind: TInterruptKind; BreakFlag: Boolean);
    procedure ExecuteOpcode(Opcode: UInt8);
  public
    A: UInt8;
    X: UInt8;
    Y: UInt8;
    Sp: UInt8;
    Pc: UInt16;
    P: UInt8;
    CyclesRemaining: Integer;
    TotalCycles: UInt32;
    procedure SerializeState(State: TNesStateArchive);
    constructor Create;
    procedure Connect(Reader: TCpuReadFunc; Writer: TCpuWriteProc);
    procedure Reset;
    procedure Clock;
    procedure TriggerNmi;
    procedure TriggerIrq;
    procedure SetIrqLine(Active: Boolean);
    function NextCycleIsWrite: Boolean;
    property UnknownOpcodeCount: Integer read FUnknownOpcodeCount;
    property Jammed: Boolean read FJammed;
    property JamOpcode: UInt8 read FJamOpcode;
    property JamPc: UInt16 read FJamPc;
    property LastUnknownOpcode: UInt8 read FLastUnknownOpcode;
    property LastUnknownPc: UInt16 read FLastUnknownPc;
  end;

implementation

procedure TCpu6502.SerializeState(State: TNesStateArchive);
begin
  State.Field(FPendingNmi, SizeOf(FPendingNmi));
  State.Field(FPendingIrq, SizeOf(FPendingIrq));
  State.Field(FNmiAfterInstruction, SizeOf(FNmiAfterInstruction));
  State.Field(FIrqAfterInstruction, SizeOf(FIrqAfterInstruction));
  State.Field(FUnknownOpcodeCount, SizeOf(FUnknownOpcodeCount));
  State.Field(FJammed, SizeOf(FJammed));
  State.Field(FJamOpcode, SizeOf(FJamOpcode));
  State.Field(FJamPc, SizeOf(FJamPc));
  State.Field(FInterruptSequenceActive, SizeOf(FInterruptSequenceActive));
  State.Field(FInterruptKind, SizeOf(FInterruptKind));
  State.Field(FInterruptBreakFlag, SizeOf(FInterruptBreakFlag));
  State.Field(FInterruptLatchedPc, SizeOf(FInterruptLatchedPc));
  State.Field(FInterruptLatchedP, SizeOf(FInterruptLatchedP));
  State.Field(FInterruptVectorLow, SizeOf(FInterruptVectorLow));
  State.Field(FPollInterruptDisable, SizeOf(FPollInterruptDisable));
  State.Field(FInstructionActive, SizeOf(FInstructionActive));
  State.Field(FPollCycle, SizeOf(FPollCycle));
  State.Field(FExecutingOpcode, SizeOf(FExecutingOpcode));
  State.Field(FQueuedWriteCount, SizeOf(FQueuedWriteCount));
  State.Field(FWriteAddresses, SizeOf(FWriteAddresses));
  State.Field(FWriteValues, SizeOf(FWriteValues));
  State.Field(FLastUnknownOpcode, SizeOf(FLastUnknownOpcode));
  State.Field(FLastUnknownPc, SizeOf(FLastUnknownPc));
  State.Field(A, SizeOf(A));
  State.Field(X, SizeOf(X));
  State.Field(Y, SizeOf(Y));
  State.Field(Sp, SizeOf(Sp));
  State.Field(Pc, SizeOf(Pc));
  State.Field(P, SizeOf(P));
  State.Field(CyclesRemaining, SizeOf(CyclesRemaining));
  State.Field(TotalCycles, SizeOf(TotalCycles));
end;

constructor TCpu6502.Create;
begin
  inherited Create;
  Reset;
end;

procedure TCpu6502.Connect(Reader: TCpuReadFunc; Writer: TCpuWriteProc);
begin
  FRead := Reader;
  FWrite := Writer;
end;

function TCpu6502.Read(Address: UInt16): UInt8;
begin
  Result := FRead(Address);
end;

procedure TCpu6502.Write(Address: UInt16; Value: UInt8);
begin
  if FExecutingOpcode then
  begin
    FWriteAddresses[FQueuedWriteCount] := Address;
    FWriteValues[FQueuedWriteCount] := Value;
    Inc(FQueuedWriteCount);
  end
  else
    FWrite(Address, Value);
end;

procedure TCpu6502.Push(Value: UInt8);
begin
  Write($0100 or Sp, Value);
  Sp := (Integer(Sp) - 1) and $FF;
end;

function TCpu6502.Pull: UInt8;
begin
  Sp := (Sp + 1) and $FF;
  Result := Read($0100 or Sp);
end;

function TCpu6502.Read16(Address: UInt16): UInt16;
begin
  var Lo: UInt8 := Read(Address);
  var Hi: UInt8 := Read((Address + 1) and $FFFF);
  Result := Lo or (UInt16(Hi) shl 8);
end;

function TCpu6502.Read16Bug(Address: UInt16): UInt16;
begin
  var Lo: UInt8 := Read(Address);
  var WrapAddr: UInt16 := (Address and $FF00) or ((Address + 1) and $00FF);
  var Hi: UInt8 := Read(WrapAddr);
  Result := Lo or (UInt16(Hi) shl 8);
end;

function TCpu6502.GetFlag(Flag: UInt8): Boolean;
begin
  Result := (P and Flag) <> 0;
end;

procedure TCpu6502.SetFlag(Flag: UInt8; Value: Boolean);
begin
  if Value then
    P := P or Flag
  else
    P := P and not Flag;
end;

procedure TCpu6502.SetZeroNegative(Value: UInt8);
begin
  SetFlag(FLAG_ZERO, Value = 0);
  SetFlag(FLAG_NEGATIVE, (Value and $80) <> 0);
end;

function TCpu6502.Imm: UInt16;
begin
  Result := Pc;
  Pc := (Pc + 1) and $FFFF;
end;

function TCpu6502.Zp0: UInt16;
begin
  Result := Read(Pc);
  Pc := (Pc + 1) and $FFFF;
end;

function TCpu6502.Zpx: UInt16;
begin
  Result := (Read(Pc) + X) and $FF;
  Pc := (Pc + 1) and $FFFF;
end;

function TCpu6502.Zpy: UInt16;
begin
  Result := (Read(Pc) + Y) and $FF;
  Pc := (Pc + 1) and $FFFF;
end;

function TCpu6502.AbsAddr: UInt16;
begin
  Result := Read16(Pc);
  Pc := (Pc + 2) and $FFFF;
end;

function TCpu6502.Abx(out PageCrossed: Boolean): UInt16;
begin
  var Base: UInt16 := Read16(Pc);
  Pc := (Pc + 2) and $FFFF;
  Result := (Base + X) and $FFFF;
  PageCrossed := (Base and $FF00) <> (Result and $FF00);
end;

function TCpu6502.Aby(out PageCrossed: Boolean): UInt16;
begin
  var Base: UInt16 := Read16(Pc);
  Pc := (Pc + 2) and $FFFF;
  Result := (Base + Y) and $FFFF;
  PageCrossed := (Base and $FF00) <> (Result and $FF00);
end;

function TCpu6502.Ind: UInt16;
begin
  var Ptr: UInt16 := Read16(Pc);
  Pc := (Pc + 2) and $FFFF;
  Result := Read16Bug(Ptr);
end;

function TCpu6502.Izx: UInt16;
begin
  var Ptr: UInt8 := (Read(Pc) + X) and $FF;
  Pc := (Pc + 1) and $FFFF;
  var Lo: UInt8 := Read(Ptr);
  var Hi: UInt8 := Read((Ptr + 1) and $FF);
  Result := Lo or (UInt16(Hi) shl 8);
end;

function TCpu6502.Izy(out PageCrossed: Boolean): UInt16;
begin
  var Ptr: UInt8 := Read(Pc);
  Pc := (Pc + 1) and $FFFF;
  var Lo: UInt8 := Read(Ptr);
  var Hi: UInt8 := Read((Ptr + 1) and $FF);
  var Base: UInt16 := Lo or (UInt16(Hi) shl 8);
  Result := (Base + Y) and $FFFF;
  PageCrossed := (Base and $FF00) <> (Result and $FF00);
end;

function TCpu6502.Rel: Int16;
begin
  var Offset: UInt8 := Read(Pc);
  Pc := (Pc + 1) and $FFFF;
  if Offset < $80 then
    Result := Offset
  else
    Result := Offset - $100;
end;

procedure TCpu6502.Adc(Value: UInt8);
begin
  var CarryIn: UInt16;
  if GetFlag(FLAG_CARRY) then
    CarryIn := 1
  else
    CarryIn := 0;
  var Sum: UInt16 := UInt16(A) + UInt16(Value) + CarryIn;
  var Result8: UInt8 := Sum and $FF;
  SetFlag(FLAG_CARRY, Sum > $FF);
  SetFlag(FLAG_OVERFLOW, ((not (A xor Value)) and (A xor Result8) and $80) <> 0);
  A := Result8;
  SetZeroNegative(A);
end;

procedure TCpu6502.Sbc(Value: UInt8);
begin
  Adc(Value xor $FF);
end;

procedure TCpu6502.Cmp(RegValue, Value: UInt8);
begin
  var Temp: Integer := Integer(RegValue) - Integer(Value);
  SetFlag(FLAG_CARRY, RegValue >= Value);
  SetFlag(FLAG_ZERO, (Temp and $FF) = 0);
  SetFlag(FLAG_NEGATIVE, (Temp and $80) <> 0);
end;

procedure TCpu6502.Bit(Value: UInt8);
begin
  SetFlag(FLAG_ZERO, (A and Value) = 0);
  SetFlag(FLAG_OVERFLOW, (Value and $40) <> 0);
  SetFlag(FLAG_NEGATIVE, (Value and $80) <> 0);
end;

procedure TCpu6502.OpSlo(Address: UInt16);
begin
  var Value: UInt8 := Read(Address);
  Write(Address, Value);
  SetFlag(FLAG_CARRY, (Value and $80) <> 0);
  Value := (Value shl 1) and $FF;
  Write(Address, Value);
  A := A or Value;
  SetZeroNegative(A);
end;

procedure TCpu6502.OpRla(Address: UInt16);
begin
  var Value: UInt8 := Read(Address);
  Write(Address, Value);
  var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
  SetFlag(FLAG_CARRY, (Value and $80) <> 0);
  Value := ((Value shl 1) or Carry) and $FF;
  Write(Address, Value);
  A := A and Value;
  SetZeroNegative(A);
end;

procedure TCpu6502.OpSre(Address: UInt16);
begin
  var Value: UInt8 := Read(Address);
  Write(Address, Value);
  SetFlag(FLAG_CARRY, (Value and 1) <> 0);
  Value := Value shr 1;
  Write(Address, Value);
  A := A xor Value;
  SetZeroNegative(A);
end;

procedure TCpu6502.OpRra(Address: UInt16);
begin
  var Value: UInt8 := Read(Address);
  Write(Address, Value);
  var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
  SetFlag(FLAG_CARRY, (Value and 1) <> 0);
  Value := (Value shr 1) or (Carry shl 7);
  Write(Address, Value);
  Adc(Value);
end;

procedure TCpu6502.OpDcp(Address: UInt16);
begin
  var Value: UInt8 := Read(Address);
  Write(Address, Value);
  Value := (Integer(Value) - 1) and $FF;
  Write(Address, Value);
  Cmp(A, Value);
end;

procedure TCpu6502.OpIsc(Address: UInt16);
begin
  var Value: UInt8 := Read(Address);
  Write(Address, Value);
  Value := (Value + 1) and $FF;
  Write(Address, Value);
  Sbc(Value);
end;

procedure TCpu6502.LaxValue(Value: UInt8);
begin
  A := Value;
  X := Value;
  SetZeroNegative(A);
end;

procedure TCpu6502.Anc(Value: UInt8);
begin
  A := A and Value;
  SetZeroNegative(A);
  SetFlag(FLAG_CARRY, (A and $80) <> 0);
end;

procedure TCpu6502.Alr(Value: UInt8);
begin
  A := A and Value;
  SetFlag(FLAG_CARRY, (A and 1) <> 0);
  A := A shr 1;
  SetZeroNegative(A);
end;

procedure TCpu6502.Arr(Value: UInt8);
begin
  A := A and Value;
  var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
  A := (A shr 1) or (Carry shl 7);
  SetZeroNegative(A);
  SetFlag(FLAG_CARRY, (A and $40) <> 0);
  SetFlag(FLAG_OVERFLOW, (((A shr 6) xor (A shr 5)) and 1) <> 0);
end;

procedure TCpu6502.Atx(Value: UInt8);
begin
  A := A and Value;
  X := A;
  SetZeroNegative(A);
end;

procedure TCpu6502.Branch(Condition: Boolean; Offset: Int16; out Cycles: Integer);
begin
  var OldPc: UInt16;
  var NewPc: UInt16;
  Cycles := 2;
  if not Condition then
    Exit;

  Inc(Cycles);
  OldPc := Pc;
  NewPc := (Integer(Pc) + Offset) and $FFFF;
  if (OldPc and $FF00) <> (NewPc and $FF00) then
    Inc(Cycles);
  Pc := NewPc;
end;

procedure TCpu6502.BeginInterruptSequence(Kind: TInterruptKind; BreakFlag: Boolean);
begin
  FInterruptSequenceActive := True;
  FInterruptKind := Kind;
  FInterruptBreakFlag := BreakFlag;
  FInterruptLatchedPc := Pc;
  FInterruptLatchedP := (P or FLAG_UNUSED) and not FLAG_BREAK;
  if BreakFlag then
    FInterruptLatchedP := FInterruptLatchedP or FLAG_BREAK;
  FInstructionActive := False;
  CyclesRemaining := 7;
end;

procedure TCpu6502.ClockInterrupt;
begin
  // NMI may hijack IRQ/BRK until vector selection, without changing stacked B.
  if (CyclesRemaining >= 3) and (FInterruptKind <> ikNmi) and FPendingNmi then
  begin
    FInterruptKind := ikNmi;
    FPendingNmi := False;
  end;
  var Vector: UInt16;
  if FInterruptKind = ikNmi then
    Vector := $FFFA
  else
    Vector := $FFFE;
  case CyclesRemaining of
    7, 6:
      Read(Pc);
    5:
      Push(FInterruptLatchedPc shr 8);
    4:
      Push(FInterruptLatchedPc and $FF);
    3:
      begin
        Push(FInterruptLatchedP);
        SetFlag(FLAG_INTERRUPT, True);
      end;
    2:
      FInterruptVectorLow := Read(Vector);
    1:
      begin
        Pc := FInterruptVectorLow or (UInt16(Read(Vector + 1)) shl 8);
        FInterruptSequenceActive := False;
        FInterruptKind := ikNone;
      end;
  end;
end;

procedure TCpu6502.Reset;
begin
  A := 0;
  X := 0;
  Y := 0;
  Sp := $FD;
  P := FLAG_UNUSED or FLAG_INTERRUPT;
  if Assigned(FRead) then
    Pc := Read16($FFFC)
  else
    Pc := 0;
  CyclesRemaining := 7;
  TotalCycles := 0;
  FPendingNmi := False;
  FPendingIrq := False;
  FNmiAfterInstruction := False;
  FIrqAfterInstruction := False;
  FInterruptSequenceActive := False;
  FInterruptKind := ikNone;
  FInterruptBreakFlag := False;
  FInterruptLatchedPc := 0;
  FInterruptLatchedP := 0;
  FInterruptVectorLow := 0;
  FPollInterruptDisable := True;
  FInstructionActive := False;
  FPollCycle := 2;
  FExecutingOpcode := False;
  FQueuedWriteCount := 0;
  FUnknownOpcodeCount := 0;
  FJammed := False;
  FJamOpcode := 0;
  FJamPc := 0;
  FLastUnknownOpcode := 0;
  FLastUnknownPc := 0;
end;

procedure TCpu6502.TriggerNmi;
begin
  FPendingNmi := True;
end;

procedure TCpu6502.TriggerIrq;
begin
  FPendingIrq := True;
end;

procedure TCpu6502.SetIrqLine(Active: Boolean);
begin
  FPendingIrq := Active;
end;

function TCpu6502.NextCycleIsWrite: Boolean;
begin
  Result := ((FQueuedWriteCount > 0) and (CyclesRemaining <= FQueuedWriteCount)) or
    (FInterruptSequenceActive and (CyclesRemaining >= 3) and (CyclesRemaining <= 5));
end;

procedure TCpu6502.Clock;
begin
  // KIL locks the instruction sequencer until reset; IRQ and NMI cannot resume it.
  if FJammed then
  begin
    if CyclesRemaining > 0 then
      Dec(CyclesRemaining);
    TotalCycles := (UInt64(TotalCycles) + 1) and $FFFFFFFF;
    Exit;
  end;
  var Opcode: UInt8;
  var ExecutedBrk: Boolean := False;
  if CyclesRemaining = 0 then
  begin
    if FNmiAfterInstruction then
    begin
      FNmiAfterInstruction := False;
      FIrqAfterInstruction := False;
      FPendingNmi := False;
      BeginInterruptSequence(ikNmi, False);
    end
    else if FIrqAfterInstruction then
    begin
      FIrqAfterInstruction := False;
      BeginInterruptSequence(ikIrq, False);
    end
    else
    begin
      Opcode := Read(Pc);
      FPollInterruptDisable := GetFlag(FLAG_INTERRUPT);
      FExecutingOpcode := True;
      try
        ExecuteOpcode(Opcode);
      finally
        FExecutingOpcode := False;
      end;
      ExecutedBrk := Opcode = $00;
      FInstructionActive := not ExecutedBrk;
      // CLI/SEI/PLP poll the old I flag. RTI polls the restored flag.
      if (Opcode <> $58) and (Opcode <> $78) and (Opcode <> $28) then
        FPollInterruptDisable := GetFlag(FLAG_INTERRUPT);
      FPollCycle := 2;
      // A taken branch without page crossing polls before its extra cycle.
      if ((Opcode and $1F) = $10) and (CyclesRemaining = 3) then
        FPollCycle := 3;
      // Page-crossing branches also poll before the operand fetch. Preserve
      // that result if the IRQ line falls before the later fixup-cycle poll.
      if ((Opcode and $1F) = $10) and (CyclesRemaining = 4) then
      begin
        FNmiAfterInstruction := FPendingNmi;
        FIrqAfterInstruction := FPendingIrq and not FPollInterruptDisable;
      end;
    end;
  end;

  if FInterruptSequenceActive then
  begin
    // BRK's opcode fetch already performed the first cycle.
    if not ExecutedBrk then
      ClockInterrupt;
  end
  else if FInstructionActive and (CyclesRemaining = FPollCycle) then
  begin
    FNmiAfterInstruction := FNmiAfterInstruction or FPendingNmi;
    FIrqAfterInstruction := FIrqAfterInstruction or (FPendingIrq and not FPollInterruptDisable);
  end;

  // Writes occupy the final bus cycles, including both writes of an RMW.
  if (FQueuedWriteCount > 0) and (CyclesRemaining <= FQueuedWriteCount) then
  begin
    FWrite(FWriteAddresses[0], FWriteValues[0]);
    Dec(FQueuedWriteCount);
    for var i := 0 to FQueuedWriteCount - 1 do
    begin
      FWriteAddresses[i] := FWriteAddresses[i + 1];
      FWriteValues[i] := FWriteValues[i + 1];
    end;
  end;
  if CyclesRemaining > 0 then
    Dec(CyclesRemaining);
  TotalCycles := (UInt64(TotalCycles) + 1) and $FFFFFFFF;
end;

procedure TCpu6502.ExecuteOpcode(Opcode: UInt8);
begin
  var OpcodePc: UInt16 := Pc;
  Pc := (Pc + 1) and $FFFF;
  var PageCrossed: Boolean := False;
  var Cycles: Integer := 2;
  case Opcode of
    $02, $12, $22, $32, $42, $52, $62, $72, $92, $B2, $D2, $F2:
      begin
        FJammed := True;
        FJamOpcode := Opcode;
        FJamPc := OpcodePc;
      end;
    $00:
      begin
        Pc := (Pc + 1) and $FFFF;
        BeginInterruptSequence(ikIrq, True);
        Cycles := 7;
      end;
    $01:
      begin
        A := A or Read(Izx);
        SetZeroNegative(A);
        Cycles := 6;
      end;
    $03:
      begin
        OpSlo(Izx);
        Cycles := 8;
      end;
    $04, $44, $64:
      begin
        Zp0;
        Cycles := 3;
      end;
    $05:
      begin
        A := A or Read(Zp0);
        SetZeroNegative(A);
        Cycles := 3;
      end;
    $07:
      begin
        OpSlo(Zp0);
        Cycles := 5;
      end;
    $06:
      begin
        var Addr: UInt16 := Zp0;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := (Value shl 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 5;
      end;
    $08:
      begin
        Push(P or FLAG_BREAK or FLAG_UNUSED);
        Cycles := 3;
      end;
    $0B, $2B:
      begin
        Anc(Read(Imm));
        Cycles := 2;
      end;
    $09:
      begin
        A := A or Read(Imm);
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $0A:
      begin
        SetFlag(FLAG_CARRY, (A and $80) <> 0);
        A := (A shl 1) and $FF;
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $0C:
      begin
        AbsAddr;
        Cycles := 4;
      end;
    $0D:
      begin
        A := A or Read(AbsAddr);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $0E:
      begin
        var Addr: UInt16 := AbsAddr;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := (Value shl 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $0F:
      begin
        OpSlo(AbsAddr);
        Cycles := 6;
      end;
    $10:
      begin
        Branch(not GetFlag(FLAG_NEGATIVE), Rel, Cycles);
      end;
    $11:
      begin
        A := A or Read(Izy(PageCrossed));
        SetZeroNegative(A);
        Cycles := 5 + Ord(PageCrossed);
      end;
    $13:
      begin
        OpSlo(Izy(PageCrossed));
        Cycles := 8;
      end;
    $14, $34, $54, $74, $D4, $F4:
      begin
        Zpx;
        Cycles := 4;
      end;
    $15:
      begin
        A := A or Read(Zpx);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $16:
      begin
        var Addr: UInt16 := Zpx;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := (Value shl 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $17:
      begin
        OpSlo(Zpx);
        Cycles := 6;
      end;
    $18:
      begin
        SetFlag(FLAG_CARRY, False);
        Cycles := 2;
      end;
    $19:
      begin
        A := A or Read(Aby(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $1B:
      begin
        OpSlo(Aby(PageCrossed));
        Cycles := 7;
      end;
    $1A, $3A, $5A, $7A, $DA, $FA:
      begin
        Cycles := 2;
      end;
    $1C, $3C, $5C, $7C, $DC, $FC:
      begin
        Abx(PageCrossed);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $1D:
      begin
        A := A or Read(Abx(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $1F:
      begin
        OpSlo(Abx(PageCrossed));
        Cycles := 7;
      end;
    $1E:
      begin
        var Addr: UInt16 := Abx(PageCrossed);
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := (Value shl 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 7;
      end;
    $20:
      begin
        var Addr: UInt16 := AbsAddr;
        Push((((Integer(Pc) - 1) and $FFFF) shr 8) and $FF);
        Push((Integer(Pc) - 1) and $FF);
        Pc := Addr;
        Cycles := 6;
      end;
    $21:
      begin
        A := A and Read(Izx);
        SetZeroNegative(A);
        Cycles := 6;
      end;
    $23:
      begin
        OpRla(Izx);
        Cycles := 8;
      end;
    $24:
      begin
        Bit(Read(Zp0));
        Cycles := 3;
      end;
    $25:
      begin
        A := A and Read(Zp0);
        SetZeroNegative(A);
        Cycles := 3;
      end;
    $27:
      begin
        OpRla(Zp0);
        Cycles := 5;
      end;
    $26:
      begin
        var Addr: UInt16 := Zp0;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := ((Value shl 1) or Carry) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 5;
      end;
    $28:
      begin
        P := Pull;
        P := (P or FLAG_UNUSED) and not FLAG_BREAK;
        Cycles := 4;
      end;
    $29:
      begin
        A := A and Read(Imm);
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $2A:
      begin
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (A and $80) <> 0);
        A := ((A shl 1) or Carry) and $FF;
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $2C:
      begin
        Bit(Read(AbsAddr));
        Cycles := 4;
      end;
    $2D:
      begin
        A := A and Read(AbsAddr);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $2E:
      begin
        var Addr: UInt16 := AbsAddr;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := ((Value shl 1) or Carry) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $2F:
      begin
        OpRla(AbsAddr);
        Cycles := 6;
      end;
    $30:
      begin
        Branch(GetFlag(FLAG_NEGATIVE), Rel, Cycles);
      end;
    $31:
      begin
        A := A and Read(Izy(PageCrossed));
        SetZeroNegative(A);
        Cycles := 5 + Ord(PageCrossed);
      end;
    $33:
      begin
        OpRla(Izy(PageCrossed));
        Cycles := 8;
      end;
    $35:
      begin
        A := A and Read(Zpx);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $36:
      begin
        var Addr: UInt16 := Zpx;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := ((Value shl 1) or Carry) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $37:
      begin
        OpRla(Zpx);
        Cycles := 6;
      end;
    $38:
      begin
        SetFlag(FLAG_CARRY, True);
        Cycles := 2;
      end;
    $39:
      begin
        A := A and Read(Aby(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $3B:
      begin
        OpRla(Aby(PageCrossed));
        Cycles := 7;
      end;
    $3D:
      begin
        A := A and Read(Abx(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $3F:
      begin
        OpRla(Abx(PageCrossed));
        Cycles := 7;
      end;
    $3E:
      begin
        var Addr: UInt16 := Abx(PageCrossed);
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and $80) <> 0);
        Value := ((Value shl 1) or Carry) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 7;
      end;
    $40:
      begin
        P := Pull;
        P := (P or FLAG_UNUSED) and not FLAG_BREAK;
        var Value: UInt8 := Pull;
        Pc := Value;
        Value := Pull;
        Pc := Pc or (UInt16(Value) shl 8);
        Cycles := 6;
      end;
    $41:
      begin
        A := A xor Read(Izx);
        SetZeroNegative(A);
        Cycles := 6;
      end;
    $43:
      begin
        OpSre(Izx);
        Cycles := 8;
      end;
    $45:
      begin
        A := A xor Read(Zp0);
        SetZeroNegative(A);
        Cycles := 3;
      end;
    $47:
      begin
        OpSre(Zp0);
        Cycles := 5;
      end;
    $46:
      begin
        var Addr: UInt16 := Zp0;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := Value shr 1;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 5;
      end;
    $48:
      begin
        Push(A);
        Cycles := 3;
      end;
    $49:
      begin
        A := A xor Read(Imm);
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $4B:
      begin
        Alr(Read(Imm));
        Cycles := 2;
      end;
    $4A:
      begin
        SetFlag(FLAG_CARRY, (A and 1) <> 0);
        A := A shr 1;
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $4C:
      begin
        Pc := AbsAddr;
        Cycles := 3;
      end;
    $4D:
      begin
        A := A xor Read(AbsAddr);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $4E:
      begin
        var Addr: UInt16 := AbsAddr;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := Value shr 1;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $4F:
      begin
        OpSre(AbsAddr);
        Cycles := 6;
      end;
    $50:
      begin
        Branch(not GetFlag(FLAG_OVERFLOW), Rel, Cycles);
      end;
    $51:
      begin
        A := A xor Read(Izy(PageCrossed));
        SetZeroNegative(A);
        Cycles := 5 + Ord(PageCrossed);
      end;
    $53:
      begin
        OpSre(Izy(PageCrossed));
        Cycles := 8;
      end;
    $55:
      begin
        A := A xor Read(Zpx);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $56:
      begin
        var Addr: UInt16 := Zpx;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := Value shr 1;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $57:
      begin
        OpSre(Zpx);
        Cycles := 6;
      end;
    $58:
      begin
        SetFlag(FLAG_INTERRUPT, False);
        Cycles := 2;
      end;
    $59:
      begin
        A := A xor Read(Aby(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $5B:
      begin
        OpSre(Aby(PageCrossed));
        Cycles := 7;
      end;
    $5D:
      begin
        A := A xor Read(Abx(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $5F:
      begin
        OpSre(Abx(PageCrossed));
        Cycles := 7;
      end;
    $5E:
      begin
        var Addr: UInt16 := Abx(PageCrossed);
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := Value shr 1;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 7;
      end;
    $60:
      begin
        var Value: UInt8 := Pull;
        Pc := Value;
        Value := Pull;
        Pc := Pc or (UInt16(Value) shl 8);
        Pc := (Pc + 1) and $FFFF;
        Cycles := 6;
      end;
    $61:
      begin
        Adc(Read(Izx));
        Cycles := 6;
      end;
    $63:
      begin
        OpRra(Izx);
        Cycles := 8;
      end;
    $65:
      begin
        Adc(Read(Zp0));
        Cycles := 3;
      end;
    $67:
      begin
        OpRra(Zp0);
        Cycles := 5;
      end;
    $66:
      begin
        var Addr: UInt16 := Zp0;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := (Value shr 1) or (Carry shl 7);
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 5;
      end;
    $68:
      begin
        A := Pull;
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $69:
      begin
        Adc(Read(Imm));
        Cycles := 2;
      end;
    $6B:
      begin
        Arr(Read(Imm));
        Cycles := 2;
      end;
    $6A:
      begin
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (A and 1) <> 0);
        A := (A shr 1) or (Carry shl 7);
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $6C:
      begin
        Pc := Ind;
        Cycles := 5;
      end;
    $6D:
      begin
        Adc(Read(AbsAddr));
        Cycles := 4;
      end;
    $6E:
      begin
        var Addr: UInt16 := AbsAddr;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := (Value shr 1) or (Carry shl 7);
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $6F:
      begin
        OpRra(AbsAddr);
        Cycles := 6;
      end;
    $70:
      begin
        Branch(GetFlag(FLAG_OVERFLOW), Rel, Cycles);
      end;
    $71:
      begin
        Adc(Read(Izy(PageCrossed)));
        Cycles := 5 + Ord(PageCrossed);
      end;
    $73:
      begin
        OpRra(Izy(PageCrossed));
        Cycles := 8;
      end;
    $75:
      begin
        Adc(Read(Zpx));
        Cycles := 4;
      end;
    $76:
      begin
        var Addr: UInt16 := Zpx;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := (Value shr 1) or (Carry shl 7);
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $77:
      begin
        OpRra(Zpx);
        Cycles := 6;
      end;
    $78:
      begin
        SetFlag(FLAG_INTERRUPT, True);
        Cycles := 2;
      end;
    $79:
      begin
        Adc(Read(Aby(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $7B:
      begin
        OpRra(Aby(PageCrossed));
        Cycles := 7;
      end;
    $7D:
      begin
        Adc(Read(Abx(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $7F:
      begin
        OpRra(Abx(PageCrossed));
        Cycles := 7;
      end;
    $7E:
      begin
        var Addr: UInt16 := Abx(PageCrossed);
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        var Carry: UInt8 := Ord(GetFlag(FLAG_CARRY));
        SetFlag(FLAG_CARRY, (Value and 1) <> 0);
        Value := (Value shr 1) or (Carry shl 7);
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 7;
      end;
    $80, $82, $89, $C2, $E2:
      begin
        Imm;
        Cycles := 2;
      end;
    $81:
      begin
        Write(Izx, A);
        Cycles := 6;
      end;
    $83:
      begin
        Write(Izx, A and X);
        Cycles := 6;
      end;
    $84:
      begin
        Write(Zp0, Y);
        Cycles := 3;
      end;
    $85:
      begin
        Write(Zp0, A);
        Cycles := 3;
      end;
    $86:
      begin
        Write(Zp0, X);
        Cycles := 3;
      end;
    $87:
      begin
        Write(Zp0, A and X);
        Cycles := 3;
      end;
    $88:
      begin
        Y := (Integer(Y) - 1) and $FF;
        SetZeroNegative(Y);
        Cycles := 2;
      end;
    $8A:
      begin
        A := X;
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $8B:
      begin
        Atx(Read(Imm));
        Cycles := 2;
      end;
    $8C:
      begin
        Write(AbsAddr, Y);
        Cycles := 4;
      end;
    $8D:
      begin
        Write(AbsAddr, A);
        Cycles := 4;
      end;
    $8E:
      begin
        Write(AbsAddr, X);
        Cycles := 4;
      end;
    $8F:
      begin
        Write(AbsAddr, A and X);
        Cycles := 4;
      end;
    $90:
      begin
        Branch(not GetFlag(FLAG_CARRY), Rel, Cycles);
      end;
    $91:
      begin
        Write(Izy(PageCrossed), A);
        Cycles := 6;
      end;
    $93:
      begin
        var Ptr: UInt8 := Read(Pc);
        Pc := (Pc + 1) and $FFFF;
        var Value: UInt8 := Read(Ptr);
        var Mask: UInt8 := Read((Ptr + 1) and $FF);
        var Base: UInt16 := Value or (UInt16(Mask) shl 8);
        var Addr: UInt16 := (Base + Y) and $FFFF;
        Mask := A and X and UInt8((((Base shr 8) + 1) and $FF));
        if (Base and $FF00) <> (Addr and $FF00) then
          Addr := (Addr and $00FF) or (UInt16(Mask) shl 8);
        Write(Addr, Mask);
        Cycles := 6;
      end;
    $94:
      begin
        Write(Zpx, Y);
        Cycles := 4;
      end;
    $95:
      begin
        Write(Zpx, A);
        Cycles := 4;
      end;
    $96:
      begin
        Write(Zpy, X);
        Cycles := 4;
      end;
    $97:
      begin
        Write(Zpy, A and X);
        Cycles := 4;
      end;
    $98:
      begin
        A := Y;
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $99:
      begin
        Write(Aby(PageCrossed), A);
        Cycles := 5;
      end;
    $9B:
      begin
        var Base: UInt16 := AbsAddr;
        var Addr: UInt16 := (Base + Y) and $FFFF;
        Sp := A and X;
        var Mask: UInt8 := Sp and UInt8((((Base shr 8) + 1) and $FF));
        if (Base and $FF00) <> (Addr and $FF00) then
          Addr := (Addr and $00FF) or (UInt16(Mask) shl 8);
        Write(Addr, Mask);
        Cycles := 5;
      end;
    $9C:
      begin
        var Base: UInt16 := AbsAddr;
        var Addr: UInt16 := (Base + X) and $FFFF;
        var Mask: UInt8 := Y and UInt8((((Base shr 8) + 1) and $FF));
        if (Base and $FF00) <> (Addr and $FF00) then
          Addr := (Addr and $00FF) or (UInt16(Mask) shl 8);
        Write(Addr, Mask);
        Cycles := 5;
      end;
    $9A:
      begin
        Sp := X;
        Cycles := 2;
      end;
    $9D:
      begin
        Write(Abx(PageCrossed), A);
        Cycles := 5;
      end;
    $9E:
      begin
        var Base: UInt16 := AbsAddr;
        var Addr: UInt16 := (Base + Y) and $FFFF;
        var Mask: UInt8 := X and UInt8((((Base shr 8) + 1) and $FF));
        if (Base and $FF00) <> (Addr and $FF00) then
          Addr := (Addr and $00FF) or (UInt16(Mask) shl 8);
        Write(Addr, Mask);
        Cycles := 5;
      end;
    $9F:
      begin
        var Base: UInt16 := AbsAddr;
        var Addr: UInt16 := (Base + Y) and $FFFF;
        var Mask: UInt8 := A and X and UInt8((((Base shr 8) + 1) and $FF));
        if (Base and $FF00) <> (Addr and $FF00) then
          Addr := (Addr and $00FF) or (UInt16(Mask) shl 8);
        Write(Addr, Mask);
        Cycles := 5;
      end;
    $A0:
      begin
        Y := Read(Imm);
        SetZeroNegative(Y);
        Cycles := 2;
      end;
    $A1:
      begin
        A := Read(Izx);
        SetZeroNegative(A);
        Cycles := 6;
      end;
    $A3:
      begin
        LaxValue(Read(Izx));
        Cycles := 6;
      end;
    $A2:
      begin
        X := Read(Imm);
        SetZeroNegative(X);
        Cycles := 2;
      end;
    $A4:
      begin
        Y := Read(Zp0);
        SetZeroNegative(Y);
        Cycles := 3;
      end;
    $A5:
      begin
        A := Read(Zp0);
        SetZeroNegative(A);
        Cycles := 3;
      end;
    $A6:
      begin
        X := Read(Zp0);
        SetZeroNegative(X);
        Cycles := 3;
      end;
    $A7:
      begin
        LaxValue(Read(Zp0));
        Cycles := 3;
      end;
    $A8:
      begin
        Y := A;
        SetZeroNegative(Y);
        Cycles := 2;
      end;
    $A9:
      begin
        A := Read(Imm);
        SetZeroNegative(A);
        Cycles := 2;
      end;
    $AB:
      begin
        Atx(Read(Imm));
        Cycles := 2;
      end;
    $AA:
      begin
        X := A;
        SetZeroNegative(X);
        Cycles := 2;
      end;
    $AC:
      begin
        Y := Read(AbsAddr);
        SetZeroNegative(Y);
        Cycles := 4;
      end;
    $AD:
      begin
        A := Read(AbsAddr);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $AE:
      begin
        X := Read(AbsAddr);
        SetZeroNegative(X);
        Cycles := 4;
      end;
    $AF:
      begin
        LaxValue(Read(AbsAddr));
        Cycles := 4;
      end;
    $B0:
      begin
        Branch(GetFlag(FLAG_CARRY), Rel, Cycles);
      end;
    $B1:
      begin
        A := Read(Izy(PageCrossed));
        SetZeroNegative(A);
        Cycles := 5 + Ord(PageCrossed);
      end;
    $B3:
      begin
        LaxValue(Read(Izy(PageCrossed)));
        Cycles := 5 + Ord(PageCrossed);
      end;
    $B4:
      begin
        Y := Read(Zpx);
        SetZeroNegative(Y);
        Cycles := 4;
      end;
    $B5:
      begin
        A := Read(Zpx);
        SetZeroNegative(A);
        Cycles := 4;
      end;
    $B6:
      begin
        X := Read(Zpy);
        SetZeroNegative(X);
        Cycles := 4;
      end;
    $B7:
      begin
        LaxValue(Read(Zpy));
        Cycles := 4;
      end;
    $B8:
      begin
        SetFlag(FLAG_OVERFLOW, False);
        Cycles := 2;
      end;
    $B9:
      begin
        A := Read(Aby(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $BA:
      begin
        X := Sp;
        SetZeroNegative(X);
        Cycles := 2;
      end;
    $BB:
      begin
        var Value: UInt8 := Read(Aby(PageCrossed)) and Sp;
        A := Value;
        X := Value;
        Sp := Value;
        SetZeroNegative(Value);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $BC:
      begin
        Y := Read(Abx(PageCrossed));
        SetZeroNegative(Y);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $BD:
      begin
        A := Read(Abx(PageCrossed));
        SetZeroNegative(A);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $BE:
      begin
        X := Read(Aby(PageCrossed));
        SetZeroNegative(X);
        Cycles := 4 + Ord(PageCrossed);
      end;
    $BF:
      begin
        LaxValue(Read(Aby(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $C0:
      begin
        Cmp(Y, Read(Imm));
        Cycles := 2;
      end;
    $C1:
      begin
        Cmp(A, Read(Izx));
        Cycles := 6;
      end;
    $C3:
      begin
        OpDcp(Izx);
        Cycles := 8;
      end;
    $C4:
      begin
        Cmp(Y, Read(Zp0));
        Cycles := 3;
      end;
    $C5:
      begin
        Cmp(A, Read(Zp0));
        Cycles := 3;
      end;
    $C6:
      begin
        var Addr: UInt16 := Zp0;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Integer(Value) - 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 5;
      end;
    $C7:
      begin
        OpDcp(Zp0);
        Cycles := 5;
      end;
    $C8:
      begin
        Y := (Y + 1) and $FF;
        SetZeroNegative(Y);
        Cycles := 2;
      end;
    $C9:
      begin
        Cmp(A, Read(Imm));
        Cycles := 2;
      end;
    $CA:
      begin
        X := (Integer(X) - 1) and $FF;
        SetZeroNegative(X);
        Cycles := 2;
      end;
    $CB:
      begin
        var Value: UInt8 := Read(Imm);
        var Carry: UInt8 := A and X;
        SetFlag(FLAG_CARRY, Carry >= Value);
        X := (Integer(Carry) - Integer(Value)) and $FF;
        SetZeroNegative(X);
        Cycles := 2;
      end;
    $CC:
      begin
        Cmp(Y, Read(AbsAddr));
        Cycles := 4;
      end;
    $CD:
      begin
        Cmp(A, Read(AbsAddr));
        Cycles := 4;
      end;
    $CE:
      begin
        var Addr: UInt16 := AbsAddr;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Integer(Value) - 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $CF:
      begin
        OpDcp(AbsAddr);
        Cycles := 6;
      end;
    $D0:
      begin
        Branch(not GetFlag(FLAG_ZERO), Rel, Cycles);
      end;
    $D1:
      begin
        Cmp(A, Read(Izy(PageCrossed)));
        Cycles := 5 + Ord(PageCrossed);
      end;
    $D3:
      begin
        OpDcp(Izy(PageCrossed));
        Cycles := 8;
      end;
    $D5:
      begin
        Cmp(A, Read(Zpx));
        Cycles := 4;
      end;
    $D6:
      begin
        var Addr: UInt16 := Zpx;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Integer(Value) - 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $D7:
      begin
        OpDcp(Zpx);
        Cycles := 6;
      end;
    $D8:
      begin
        SetFlag(FLAG_DECIMAL, False);
        Cycles := 2;
      end;
    $D9:
      begin
        Cmp(A, Read(Aby(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $DB:
      begin
        OpDcp(Aby(PageCrossed));
        Cycles := 7;
      end;
    $DD:
      begin
        Cmp(A, Read(Abx(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $DF:
      begin
        OpDcp(Abx(PageCrossed));
        Cycles := 7;
      end;
    $DE:
      begin
        var Addr: UInt16 := Abx(PageCrossed);
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Integer(Value) - 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 7;
      end;
    $E0:
      begin
        Cmp(X, Read(Imm));
        Cycles := 2;
      end;
    $E1:
      begin
        Sbc(Read(Izx));
        Cycles := 6;
      end;
    $E3:
      begin
        OpIsc(Izx);
        Cycles := 8;
      end;
    $E4:
      begin
        Cmp(X, Read(Zp0));
        Cycles := 3;
      end;
    $E5:
      begin
        Sbc(Read(Zp0));
        Cycles := 3;
      end;
    $E6:
      begin
        var Addr: UInt16 := Zp0;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Value + 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 5;
      end;
    $E7:
      begin
        OpIsc(Zp0);
        Cycles := 5;
      end;
    $E8:
      begin
        X := (X + 1) and $FF;
        SetZeroNegative(X);
        Cycles := 2;
      end;
    $E9, $EB:
      begin
        Sbc(Read(Imm));
        Cycles := 2;
      end;
    $EA:
      begin
        Cycles := 2;
      end;
    $EC:
      begin
        Cmp(X, Read(AbsAddr));
        Cycles := 4;
      end;
    $ED:
      begin
        Sbc(Read(AbsAddr));
        Cycles := 4;
      end;
    $EE:
      begin
        var Addr: UInt16 := AbsAddr;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Value + 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $EF:
      begin
        OpIsc(AbsAddr);
        Cycles := 6;
      end;
    $F0:
      begin
        Branch(GetFlag(FLAG_ZERO), Rel, Cycles);
      end;
    $F1:
      begin
        Sbc(Read(Izy(PageCrossed)));
        Cycles := 5 + Ord(PageCrossed);
      end;
    $F3:
      begin
        OpIsc(Izy(PageCrossed));
        Cycles := 8;
      end;
    $F5:
      begin
        Sbc(Read(Zpx));
        Cycles := 4;
      end;
    $F6:
      begin
        var Addr: UInt16 := Zpx;
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Value + 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 6;
      end;
    $F7:
      begin
        OpIsc(Zpx);
        Cycles := 6;
      end;
    $F8:
      begin
        SetFlag(FLAG_DECIMAL, True);
        Cycles := 2;
      end;
    $F9:
      begin
        Sbc(Read(Aby(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $FB:
      begin
        OpIsc(Aby(PageCrossed));
        Cycles := 7;
      end;
    $FD:
      begin
        Sbc(Read(Abx(PageCrossed)));
        Cycles := 4 + Ord(PageCrossed);
      end;
    $FF:
      begin
        OpIsc(Abx(PageCrossed));
        Cycles := 7;
      end;
    $FE:
      begin
        var Addr: UInt16 := Abx(PageCrossed);
        var Value: UInt8 := Read(Addr);
        Write(Addr, Value);
        Value := (Value + 1) and $FF;
        Write(Addr, Value);
        SetZeroNegative(Value);
        Cycles := 7;
      end;
  else
    begin
      if FUnknownOpcodeCount < High(Integer) then
        Inc(FUnknownOpcodeCount);
      FLastUnknownOpcode := Opcode;
      FLastUnknownPc := OpcodePc;
      Cycles := 2;
    end;
  end;
  CyclesRemaining := Cycles;
end;

end.

