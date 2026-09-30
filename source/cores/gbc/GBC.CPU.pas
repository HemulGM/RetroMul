unit GBC.CPU;

interface

uses
  Core.Snapshots, System.Classes, GBC.Memory, GBC.InterruptManager, GBC.Timer, GBC.GPU, System.SysUtils,
  GBC.Sound;

type
  TGBCCPU = class
  private
    FLastOpCode: Integer;
    FMemory: TGBCMemory;
    FGPU: TGBCGPU;
    FSound: TGBSound;
    FStopped: Boolean;
    FInstructionCount: UInt64;
    FCycles: UInt64;
    FRegisterA: Byte;
    FRegisterF: Byte;

    FRegisterB: Byte;
    FRegisterC: Byte;

    FRegisterD: Byte;
    FRegisterE: Byte;

    FRegisterH: Byte;
    FRegisterL: Byte;

    FIsHalted: Boolean;

    FPendingInterruptEnable: Integer;
    FSuppressPCIncrement: Boolean;
    function GetOpCode: Integer;
    procedure Decode(OpCode: Integer);

    procedure ExecuteDec(OpCode: Byte);
    procedure ExecuteJRCC(OpCode: Byte);
    procedure ExecuteDAA(OpCode: Byte);

    procedure ExecuteAdd16(OpCode: Byte);
    procedure ExecuteAdd(OpCode: Byte);
    procedure ExecuteADC(OpCode: Byte);
    procedure ExecuteSub(OpCode: Byte);
    procedure ExecuteSBC(OpCode: Byte);
    procedure ExecuteAnd(OpCode: Byte);
    procedure ExecuteXor(OpCode: Byte);
    procedure ExecuteOr(OpCode: Byte);
    procedure ExecuteLoad(OpCode: Byte);
    procedure ExecuteCP(OpCode: Byte);
    procedure ExecuteRetCC(OpCode: Byte);
    procedure ExecuteJPCC(OpCode: Byte);
    procedure ExecuteCallCC(OpCode: Byte);
    procedure ExecuteRST(Value: Byte);

    procedure ExecuteInc(OpCode: Byte);
    procedure ExecuteJmp(OpCode: Byte);

    function PopWord: Integer;
    procedure PushWord(Value: Integer);
    procedure ReturnFromCall;
    function SwapNibbles(Value: Integer): Integer;
    function ReadCBOperand(OpCode: Integer): Integer;
    procedure WriteCBOperand(OpCode, Value: Integer);

    procedure ExecuteRLC(OpCode: Word);
    procedure ExecuteRRC(OpCode: Word);
    procedure ExecuteRL(OpCode: Word);
    procedure ExecuteRR(OpCode: Word);
    procedure ExecuteSLA(OpCode: Word);
    procedure ExecuteSRA(OpCode: Word);
    procedure ExecuteSwap(OpCode: Word);
    procedure ExecuteSRL(OpCode: Word);
    procedure ExecuteBit(OpCode: Word);
    procedure ExecuteRes(OpCode: Word);
    procedure ExecuteSet(OpCode: Word);

    procedure ProcessEI(OpCode: Integer);
    procedure ProcessInterrupts;
    function GetStopped: Boolean;
  public
    StackPointer: Word;
    ProgramCounter: Word;

    function GetRegisterA: Byte;
    function GetRegisterF: Byte;
    function GetRegisterAF: Word;
    function GetRegisterB: Byte;
    function GetRegisterC: Byte;
    function GetRegisterBC: Word;
    function GetRegisterD: Byte;
    function GetRegisterE: Byte;
    function GetRegisterDE: Word;
    function GetRegisterH: Byte;
    function GetRegisterL: Byte;
    function GetRegisterHL: Word;
    function GetStackPointerLow: Byte;
    function GetStackPointerHigh: Byte;
    procedure SetRegisterA(Value: Byte);
    procedure SetRegisterF(Value: Byte);
    procedure SetRegisterAF(Value: Word);
    procedure SetRegisterB(Value: Byte);
    procedure SetRegisterC(Value: Byte);
    procedure SetRegisterBC(Value: Word);
    procedure SetRegisterD(Value: Byte);
    procedure SetRegisterE(Value: Byte);
    procedure SetRegisterDE(Value: Word);
    procedure SetRegisterH(Value: Byte);
    procedure SetRegisterL(Value: Byte);
    procedure SetRegisterHL(Value: Word);

    procedure ExecutePop(OpCode: Integer);
    procedure ExecutePush(OpCode: Integer);

    constructor Create(AMemory: TGBCMemory; AGPU: TGBCGPU; ASound: TGBSound); overload;

    procedure SetZeroFlag(Value: Boolean);
    function GetZeroFlag: Boolean;
    procedure SetSubtractFlag(Value: Boolean);
    function GetSubtractFlag: Boolean;
    procedure SetHalfCarryFlag(Value: Boolean);
    function GetHalfCarryFlag: Boolean;
    procedure SetCarryFlag(Value: Boolean);
    function GetCarryFlag: Boolean;

    procedure ConsumeClockCycles(Cycles: Integer);

    procedure Step;
    procedure SkipBIOS;
    procedure Main;
    procedure Stop;
    property Stopped: Boolean read GetStopped;
    // Base-speed clocks for video, sound and host pacing, including double speed.
    property Cycles: UInt64 read FCycles;
    property InstructionCount: UInt64 read FInstructionCount;
    property LastOpCode: Integer read FLastOpCode;

    procedure SerializeState(State: TStateArchive);
  end;

const
  CPUClockFrequency = 4194304;

implementation

uses
  System.Diagnostics;

{ TGBCPU }

procedure TGBCCPU.ExecuteADC(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $8F:
      Second := GetRegisterA;
    $88:
      Second := GetRegisterB;
    $89:
      Second := GetRegisterC;
    $8A:
      Second := GetRegisterD;
    $8B:
      Second := GetRegisterE;
    $8C:
      Second := GetRegisterH;
    $8D:
      Second := GetRegisterL;
    $8E:
      Second := FMemory.ReadByte(GetRegisterHL);
    $CE:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  var OldValue: Integer := GetRegisterA;
  var AResult: Integer := OldValue + Second;
  if GetCarryFlag then
    AResult := AResult + 1;
  SetSubtractFlag(False);
  if AResult > 255 then
  begin
    SetCarryFlag(True);
    AResult := AResult and $FF;
  end
  else
    SetCarryFlag(False);

  SetZeroFlag(AResult = 0);
  SetHalfCarryFlag(((GetRegisterA xor Second xor AResult) and $10) <> 0);
  SetRegisterA(AResult);

  if (OpCode = $8E) or (OpCode = $CE) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.ExecuteAdd16(OpCode: Byte);
begin
  var Value: Integer;
  case OpCode of
    $09:
      Value := GetRegisterBC;
    $19:
      Value := GetRegisterDE;
    $29:
      Value := GetRegisterHL;
    $39:
      Value := StackPointer;
    $E8:
      begin
        Value := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        if Value > 127 then
          Value := -((not Value + 1) and 255);
      end;
  else
    Exit;
  end;

  var HL: Integer := GetRegisterHL;
  if OpCode = $E8 then
  begin
    var NewValue := Value + StackPointer;

    SetZeroFlag(False);
    SetSubtractFlag(False);

    var ResultXor := StackPointer xor Value xor NewValue;
    SetHalfCarryFlag((ResultXor and $10) <> 0);
    SetCarryFlag((ResultXor and $100) <> 0);
    NewValue := NewValue and $FFFF;

    StackPointer := NewValue;

    ConsumeClockCycles(16);
  end
  else
  begin
    var NewValue := HL + Value;

    SetSubtractFlag(False);
    SetHalfCarryFlag((((HL and $0FFF) + (Value and $0FFF)) and $1000) <> 0);
    SetCarryFlag(NewValue > $FFFF);

    SetRegisterHL(NewValue and $FFFF);

    ConsumeClockCycles(8);
  end;
end;

procedure TGBCCPU.ExecuteAdd(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $87:
      Second := GetRegisterA;
    $80:
      Second := GetRegisterB;
    $81:
      Second := GetRegisterC;
    $82:
      Second := GetRegisterD;
    $83:
      Second := GetRegisterE;
    $84:
      Second := GetRegisterH;
    $85:
      Second := GetRegisterL;
    $86:
      Second := FMemory.ReadByte(GetRegisterHL);
    $C6:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  var OldValue: Integer := GetRegisterA;
  var Result: Integer := OldValue + Second;
  SetSubtractFlag(False);
  if Result > 255 then
  begin
    SetCarryFlag(True);
    Result := Result and $FF;
  end
  else
    SetCarryFlag(False);
  SetZeroFlag(Result = 0);
  SetHalfCarryFlag((OldValue and $F) + ($F and Second) > $F);
  SetRegisterA(Result);

  if (OpCode = $86) or (OpCode = $C6) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.ExecuteAnd(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $A7:
      Second := GetRegisterA;
    $A0:
      Second := GetRegisterB;
    $A1:
      Second := GetRegisterC;
    $A2:
      Second := GetRegisterD;
    $A3:
      Second := GetRegisterE;
    $A4:
      Second := GetRegisterH;
    $A5:
      Second := GetRegisterL;
    $A6:
      Second := FMemory.ReadByte(GetRegisterHL);
    $E6:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  SetRegisterA(GetRegisterA and Second);
  SetZeroFlag(GetRegisterA = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag(True);
  SetCarryFlag(False);

  if (OpCode = $A6) or (OpCode = $E6) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.ExecuteBit(OpCode: Word);
begin
  var Value: Integer := ReadCBOperand(OpCode);
  var BitIndex: Integer := (OpCode - $CB40) div 8;
  SetZeroFlag(((Value shr BitIndex) and 1) = 0);
  SetHalfCarryFlag(True);
  SetSubtractFlag(False);
  if (OpCode and 7) = 6 then
    ConsumeClockCycles(12)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteCallCC(OpCode: Byte);
begin
  var Condition: Boolean;
  case OpCode of
    $C4:
      Condition := not GetZeroFlag;
    $CC:
      Condition := GetZeroFlag;
    $D4:
      Condition := not GetCarryFlag;
    $DC:
      Condition := GetCarryFlag;
  else
    Exit;
  end;

  var Address: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  var Temp: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  if Condition then
  begin
    PushWord(ProgramCounter);
    Temp := Temp shl 8;
    Address := Address or Temp;
    ProgramCounter := Address;
    ConsumeClockCycles(24);
  end
  else
    ConsumeClockCycles(12)
end;

function TGBCCPU.ReadCBOperand(OpCode: Integer): Integer;
begin
  case OpCode and $0F of
    $07, $0F:
      Result := GetRegisterA;
    $00, $08:
      Result := GetRegisterB;
    $01, $09:
      Result := GetRegisterC;
    $02, $0A:
      Result := GetRegisterD;
    $03, $0B:
      Result := GetRegisterE;
    $04, $0C:
      Result := GetRegisterH;
    $05, $0D:
      Result := GetRegisterL;
    $06, $0E:
      Result := FMemory.ReadByte(GetRegisterHL);
  else
    Result := 0;
  end;
end;

procedure TGBCCPU.WriteCBOperand(OpCode, Value: Integer);
begin
  case OpCode and $0F of
    $7, $F:
      begin
        SetRegisterA(Value);
        ConsumeClockCycles(8);
      end;
    $0, $8:
      begin
        SetRegisterB(Value);
        ConsumeClockCycles(8);
      end;
    $1, $9:
      begin
        SetRegisterC(Value);
        ConsumeClockCycles(8);
      end;
    $2, $A:
      begin
        SetRegisterD(Value);
        ConsumeClockCycles(8);
      end;
    $3, $B:
      begin
        SetRegisterE(Value);
        ConsumeClockCycles(8);
      end;
    $4, $C:
      begin
        SetRegisterH(Value);
        ConsumeClockCycles(8);
      end;
    $5, $D:
      begin
        SetRegisterL(Value);
        ConsumeClockCycles(8);
      end;
    $6, $E:
      begin
        FMemory.WriteByte(GetRegisterHL, Value);
        ConsumeClockCycles(16);
      end;
  end;
end;

procedure TGBCCPU.ConsumeClockCycles(Cycles: Integer);
begin
  repeat
    var BaseCycles := Cycles;
    if FMemory.DoubleSpeed then
      BaseCycles := BaseCycles div 2;
    Inc(FCycles, BaseCycles);
    TGBCTimer.Instance.Step(Cycles);
    FGPU.Step(BaseCycles);
    if FSound <> nil then
      FSound.UpdateSound(BaseCycles);
    // General DMA queues its stall while the CPU instruction writes FF55;
    // HBlank DMA queues it from the GPU mode transition above.
    Cycles := FMemory.ConsumeDMACyclePenalty;
    if FMemory.DoubleSpeed then
      Cycles := Cycles * 2;
  until Cycles = 0;
end;

procedure TGBCCPU.ExecuteCP(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $bf:
      Second := GetRegisterA;
    $b8:
      Second := GetRegisterB;
    $b9:
      Second := GetRegisterC;
    $ba:
      Second := GetRegisterD;
    $bb:
      Second := GetRegisterE;
    $bc:
      Second := GetRegisterH;
    $bd:
      Second := GetRegisterL;
    $be:
      Second := FMemory.ReadByte(GetRegisterHL);
    $fe:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  var Result: Integer := GetRegisterA - Second;
  SetSubtractFlag(True);
  SetZeroFlag(Result = 0);
  SetCarryFlag(Second > GetRegisterA);
  SetHalfCarryFlag((GetRegisterA and $0F) < ($0F and Second));

  if (OpCode = $BE) or (OpCode = $FE) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

constructor TGBCCPU.Create(AMemory: TGBCMemory; AGPU: TGBCGPU; ASound: TGBSound);
begin
  FMemory := AMemory;
  FGPU := AGPU;
  FSound := ASound;

  SetRegisterA(0);
  SetRegisterB(0);
  SetRegisterC(0);
  SetRegisterD(0);
  SetRegisterE(0);
  SetRegisterH(0);
  SetRegisterL(0);
  ProgramCounter := 0;
  StackPointer := 0;
  FInstructionCount := 0;
end;

procedure TGBCCPU.ExecuteDAA(OpCode: Byte);
begin
  var Op: Integer := GetRegisterA;
  if not GetSubtractFlag then
  begin
    if (GetHalfCarryFlag) or ((Op and $F) > 9) then
      Op := Op + $06;
    if (GetCarryFlag) or (Op > $9F) then
      Op := Op + $60;
  end
  else
  begin
    if GetHalfCarryFlag then
      Op := (Op - 6) and $FF;
    if GetCarryFlag then
      Op := Op - $60;
  end;
  SetHalfCarryFlag(False);
  SetZeroFlag(False);
  if (Op and $100) = $100 then
    SetCarryFlag(True);
  Op := Op and $FF;
  if Op = 0 then
    SetZeroFlag(True);
  SetRegisterA(Op and $FF);
  ConsumeClockCycles(4);
end;

procedure TGBCCPU.Decode(OpCode: Integer);
begin
  case OpCode of
    $00: // NOP
      ConsumeClockCycles(4);
    $76: // HALT
      begin
        if (not TGBCInterruptManager.Instance.IsMasterEnabled) and
          ((TGBCInterruptManager.Instance.GetInterruptsRaised and
          TGBCInterruptManager.Instance.GetInterruptsEnabled and $1F) <> 0) then
          FSuppressPCIncrement := True
        else
          FIsHalted := True;
        ConsumeClockCycles(4);
      end;
    $10: // STOP 0 / CGB speed switch
      begin
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF; // skip second byte 00
        // KEY1 prepares a CGB speed switch.  The STOP instruction completes
        // it and execution resumes at the following instruction.
        if not FMemory.PerformSpeedSwitch then
          FIsHalted := True;
        ConsumeClockCycles(4);
      end;
    $F3: // DI
      begin
        FPendingInterruptEnable := 0;
        TGBCInterruptManager.Instance.MasterDisable;
        ConsumeClockCycles(4);
      end;
    $FB: // EI
      begin
        if FPendingInterruptEnable = 0 then
          FPendingInterruptEnable := 2;
        ConsumeClockCycles(4);
      end;
    $03: // INC BC
      begin
        SetRegisterBC((GetRegisterBC + 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $13: // INC DE
      begin
        SetRegisterDE((GetRegisterDE + 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $23: // INC HL
      begin
        SetRegisterHL((GetRegisterHL + 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $33: // INC SP
      begin
        StackPointer := (Integer(StackPointer) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $0b: // DEC BC
      begin
        SetRegisterBC((GetRegisterBC - 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $1b: // DEC DE
      begin
        SetRegisterDE((GetRegisterDE - 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $2b: // DEC HL
      begin
        SetRegisterHL((GetRegisterHL - 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $3b: // DEC SP
      begin
        StackPointer := (Integer(StackPointer) - 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $04, $0c, $14, $1c, $24, $2c, $34, $3c:
      ExecuteInc(OpCode);
    $05, $0d, $15, $1d, $25, $2d, $35, $3d:
      ExecuteDec(OpCode);
    $07: // RLCA
      begin
        var Value: Integer := GetRegisterA;
        var Tmp: Integer := (Value shl 1) or (Value shr 7);
        Tmp := Tmp and 255;
        SetRegisterA(Tmp);
        SetZeroFlag(False);
        SetSubtractFlag(False);
        SetHalfCarryFlag(False);
        SetCarryFlag((Value and $80) <> 0);
        ConsumeClockCycles(4);
      end;
    $0f: // RRCA
      begin
        var Value: Integer := GetRegisterA;
        var Tmp: Integer := Value and $01;
        Value := Value shr 1;
        SetRegisterA(Value or (Tmp shl 7));
        SetCarryFlag(Tmp <> 0);
        SetZeroFlag(False);
        SetSubtractFlag(False);
        SetHalfCarryFlag(False);
        ConsumeClockCycles(4);
      end;
    $17: // RLA
      begin
        var Value: Integer := GetRegisterA;
        var Tmp: Integer;
        if GetCarryFlag then
          Tmp := 1
        else
          Tmp := 0;
        SetRegisterA(((Value shl 1) or Tmp) and $FF);
        SetCarryFlag((Value shr 7) <> 0);
        SetZeroFlag(False);
        SetSubtractFlag(False);
        SetHalfCarryFlag(False);
        ConsumeClockCycles(4);
      end;
    $1f: // RRA
      begin
        var Value: Integer := GetRegisterA;
        var Tmp: Integer;
        if GetCarryFlag then
          Tmp := 1
        else
          Tmp := 0;
        SetRegisterA((Value shr 1) or (Tmp shl 7));
        SetCarryFlag((Value and $01) = 1);
        SetZeroFlag(False);
        SetSubtractFlag(False);
        SetHalfCarryFlag(False);
        ConsumeClockCycles(4);
      end;
    $18: // JR r8
      begin
        var Value: Integer := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        var Tmp: Integer := ProgramCounter;
        if (Value > 127) then
        begin
          Value := -((not Value + 1) and 255);
        end;
        Tmp := Tmp + Value;
        ProgramCounter := Tmp and $FFFF;
        ConsumeClockCycles(12);
      end;
    $e9: // JP (HL)
      begin
        ProgramCounter := GetRegisterHL;
        ConsumeClockCycles(4);
      end;
    $20, $28, $30, $38:
      ExecuteJRCC(OpCode);
    $27: // DAA
      ExecuteDAA(OpCode);
    $2F: // CPL
      begin
        SetRegisterA(not GetRegisterA and 255);
        SetSubtractFlag(True);
        SetHalfCarryFlag(True);
        ConsumeClockCycles(4);
      end;
    $37: // SCF
      begin
        SetSubtractFlag(False);
        SetHalfCarryFlag(False);
        SetCarryFlag(True);
        ConsumeClockCycles(4);
      end;
    $3F: // CCF
      begin
        SetSubtractFlag(False);
        SetHalfCarryFlag(False);
        SetCarryFlag(not GetCarryFlag);
        ConsumeClockCycles(4);
      end;
    $C9: // RET
      begin
        ProgramCounter := PopWord;
        ConsumeClockCycles(16);
      end;
    $CD: // CALL a16
      begin
        var Value: Integer := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        var Tmp: Integer := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        Tmp := Tmp shl 8;
        Value := Value or Tmp;
        PushWord(ProgramCounter);
        ProgramCounter := Value;
        ConsumeClockCycles(24);
      end;
    $D9: // RETI
      begin
        ReturnFromCall;
        TGBCInterruptManager.Instance.MasterEnable;
        ConsumeClockCycles(16);
      end;
    $39, $29, $19, $09, $E8:
      ExecuteAdd16(OpCode);
    $C1, $D1, $E1, $F1:
      ExecutePop(OpCode);
    $C5, $D5, $E5, $F5:
      ExecutePush(OpCode);
    $01, $02, $06, $08, $0a, $0e, $16, $1a, $1e, //
    $21, $22, $26, $2a, $2e, $31, $32, $36, $3a, //
    $40, $41, $42, $43, $44, $45, $46, $47, $48, //
    $49, $4a, $4b, $4c, $4d, $4e, $4f, $50, $51, //
    $52, $53, $54, $55, $56, $57, $58, $59, $5a, //
    $5b, $5c, $5d, $5e, $5f, $60, $61, $62, $63, //
    $64, $65, $66, $67, $68, $69, $6a, $6b, $6c, //
    $6d, $6e, $6f, $70, $71, $72, $73, $74, $75, //
    $77, $78, $79, $7a, $7b, $7c, $7d, $7e, $7f, //
    $f8, $f9, $fa, $3e, $f2, $e0, $e2, $ea, $f0, //
    $11, $12:
      ExecuteLoad(OpCode);
    $80, $81, $82, $83, $84, $85, $86, $87, $c6:
      ExecuteAdd(OpCode);
    $88, $89, $8a, $8b, $8c, $8d, $8e, $8f, $ce:
      ExecuteADC(OpCode);
    $90, $91, $92, $93, $94, $95, $96, $97, $d6:
      ExecuteSub(OpCode);
    $98, $99, $9a, $9b, $9c, $9d, $9e, $9f, $de:
      ExecuteSBC(OpCode);
    $a0, $a1, $a2, $a3, $a4, $a5, $a6, $a7, $e6:
      ExecuteAnd(OpCode);
    $a8, $a9, $aa, $ab, $ac, $ad, $ae, $af, $ee:
      ExecuteXor(OpCode);
    $b0, $b1, $b2, $b3, $b4, $b5, $b6, $b7, $f6:
      ExecuteOr(OpCode);
    $b8, $b9, $ba, $bb, $bc, $bd, $be, $bf, $fe:
      ExecuteCP(OpCode);
    $c0, $c8, $d0, $d8:
      ExecuteRetCC(OpCode);
    $c2, $ca, $d2, $da:
      ExecuteJPCC(OpCode);
    $C3: // JMP
      ExecuteJmp($C3);
    $c4, $cc, $d4, $dc:
      ExecuteCallCC(OpCode);
    $d3, $db, $dd, $e3, $e4, $eb, $ec, $ed, $f4, $fc, $fd:
      {opcode not support}
      ;
    $c7, $cf, $d7, $df, $e7, $ef, $ff, $f7:
      ExecuteRST(OpCode);
    $cb00, $cb01, $cb02, $cb03, $cb04, $cb05, $cb06, $cb07:
      ExecuteRLC(OpCode);
    $cb08, $cb09, $cb0a, $cb0b, $cb0c, $cb0d, $cb0e, $cb0f:
      ExecuteRRC(OpCode);
    $cb10, $cb11, $cb12, $cb13, $cb14, $cb15, $cb16, $cb17:
      ExecuteRL(OpCode);
    $cb18, $cb19, $cb1a, $cb1b, $cb1c, $cb1d, $cb1e, $cb1f:
      ExecuteRR(OpCode);
    $cb20, $cb21, $cb22, $cb23, $cb24, $cb25, $cb26, $cb27:
      ExecuteSLA(OpCode);
    $cb28, $cb29, $cb2a, $cb2b, $cb2c, $cb2d, $cb2e, $cb2f:
      ExecuteSRA(OpCode);
    $cb30, $cb31, $cb32, $cb33, $cb34, $cb35, $cb36, $cb37:
      ExecuteSwap(OpCode);
    $cb38, $cb39, $cb3a, $cb3b, $cb3c, $cb3d, $cb3e, $cb3f:
      ExecuteSRL(OpCode);
    $cb40, $cb41, $cb42, $cb43, $cb44, $cb45, $cb46, $cb47, //
    $cb48, $cb49, $cb4a, $cb4b, $cb4c, $cb4d, $cb4e, $cb4f, //
    $cb50, $cb51, $cb52, $cb53, $cb54, $cb55, $cb56, $cb57, //
    $cb58, $cb59, $cb5a, $cb5b, $cb5c, $cb5d, $cb5e, $cb5f, //
    $cb60, $cb61, $cb62, $cb63, $cb64, $cb65, $cb66, $cb67, //
    $cb68, $cb69, $cb6a, $cb6b, $cb6c, $cb6d, $cb6e, $cb6f, //
    $cb70, $cb71, $cb72, $cb73, $cb74, $cb75, $cb76, $cb77, //
    $cb78, $cb79, $cb7a, $cb7b, $cb7c, $cb7d, $cb7e, $cb7f:
      ExecuteBit(OpCode);
    $cb80, $cb81, $cb82, $cb83, $cb84, $cb85, $cb86, $cb87, //
    $cb88, $cb89, $cb8a, $cb8b, $cb8c, $cb8d, $cb8e, $cb8f, //
    $cb90, $cb91, $cb92, $cb93, $cb94, $cb95, $cb96, $cb97, //
    $cb98, $cb99, $cb9a, $cb9b, $cb9c, $cb9d, $cb9e, $cb9f, //
    $cba0, $cba1, $cba2, $cba3, $cba4, $cba5, $cba6, $cba7, //
    $cba8, $cba9, $cbaa, $cbab, $cbac, $cbad, $cbae, $cbaf, //
    $cbb0, $cbb1, $cbb2, $cbb3, $cbb4, $cbb5, $cbb6, $cbb7, //
    $cbb8, $cbb9, $cbba, $cbbb, $cbbc, $cbbd, $cbbe, $cbbf:
      ExecuteRes(OpCode);
    $cbc0, $cbc1, $cbc2, $cbc3, $cbc4, $cbc5, $cbc6, $cbc7, //
    $cbc8, $cbc9, $cbca, $cbcb, $cbcc, $cbcd, $cbce, $cbcf, //
    $cbd0, $cbd1, $cbd2, $cbd3, $cbd4, $cbd5, $cbd6, $cbd7, //
    $cbd8, $cbd9, $cbda, $cbdb, $cbdc, $cbdd, $cbde, $cbdf, //
    $cbe0, $cbe1, $cbe2, $cbe3, $cbe4, $cbe5, $cbe6, $cbe7, //
    $cbe8, $cbe9, $cbea, $cbeb, $cbec, $cbed, $cbee, $cbef, //
    $cbf0, $cbf1, $cbf2, $cbf3, $cbf4, $cbf5, $cbf6, $cbf7, //
    $cbf8, $cbf9, $cbfa, $cbfb, $cbfc, $cbfd, $cbfe, $cbff:
      ExecuteSet(OpCode);
  end;
end;

procedure TGBCCPU.ExecuteDec(OpCode: Byte);
begin
  var Value, OldValue: Byte;
  case OpCode of
    $05: //DEC B
      begin
        OldValue := GetRegisterB;
        SetRegisterB(Byte(OldValue - 1));
        Value := GetRegisterB;
      end;
    $0d: //DEC C
      begin
        OldValue := GetRegisterC;
        SetRegisterC(Byte(OldValue - 1));
        Value := GetRegisterC;
      end;
    $15: //DEC D
      begin
        OldValue := GetRegisterD;
        SetRegisterD(Byte(OldValue - 1));
        Value := GetRegisterD;
      end;
    $1d: //DEC E
      begin
        OldValue := GetRegisterE;
        SetRegisterE(Byte(OldValue - 1));
        Value := GetRegisterE;
      end;
    $25: //INC H
      begin
        OldValue := GetRegisterH;
        SetRegisterH(Byte(OldValue - 1));
        Value := GetRegisterH;
      end;
    $2d: //DEC L
      begin
        OldValue := GetRegisterL;
        SetRegisterL(Byte(OldValue - 1));
        Value := GetRegisterL;
      end;
    $35: //DEC (HL)
      begin
        var Address := GetRegisterHL;
        Value := FMemory.ReadByte(Address);
        OldValue := Value;
        Value := Byte(Value - 1);
        Value := Value and 255;
        FMemory.WriteByte(Address, Value);
      end;
    $3d: //DEC A
      begin
        OldValue := GetRegisterA;
        SetRegisterA(Byte(OldValue - 1));
        Value := GetRegisterA;
      end;
  else
    Exit;
  end;

  SetZeroFlag(Value = 0);
  SetSubtractFlag(True);

  SetHalfCarryFlag((OldValue and $0F) < 1);
  if OpCode = $35 then
    ConsumeClockCycles(12)
  else
    ConsumeClockCycles(4);
end;

function TGBCCPU.GetCarryFlag: Boolean;
begin
  Result := (GetRegisterF shr 4) and $1 = 1;
end;

function TGBCCPU.GetHalfCarryFlag: Boolean;
begin
  Result := ((GetRegisterF shr 4) and $2) shr 1 = 1;
end;

function TGBCCPU.GetSubtractFlag: Boolean;
begin
  Result := ((GetRegisterF shr 4) and $4) shr 2 = 1;
end;

function TGBCCPU.GetZeroFlag: Boolean;
begin
  Result := ((GetRegisterF shr 4) and $8) shr 3 = 1;
end;

function TGBCCPU.GetOpCode: Integer;
begin
  Result := FMemory.ReadByte(ProgramCounter);
  if FSuppressPCIncrement then
    FSuppressPCIncrement := False
  else
    ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  if Result = $cb then
  begin
    Result := Result shl 8;
    Result := Result or FMemory.ReadByte(ProgramCounter);
    ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  end;
end;

function TGBCCPU.GetRegisterA: Byte;
begin
  Result := FRegisterA;
end;

function TGBCCPU.GetRegisterF: Byte;
begin
  Result := FRegisterF;
end;

function TGBCCPU.GetRegisterAF: Word;
begin
  Result := FRegisterA * $100 + FRegisterF;
end;

function TGBCCPU.GetRegisterB: Byte;
begin
  Result := FRegisterB;
end;

function TGBCCPU.GetRegisterC: Byte;
begin
  Result := FRegisterC;
end;

function TGBCCPU.GetRegisterBC: Word;
begin
  Result := FRegisterB * $100 + FRegisterC;
end;

function TGBCCPU.GetRegisterD: Byte;
begin
  Result := FRegisterD;
end;

function TGBCCPU.GetRegisterE: Byte;
begin
  Result := FRegisterE;
end;

function TGBCCPU.GetRegisterDE: Word;
begin
  Result := FRegisterD * $100 + FRegisterE;
end;

function TGBCCPU.GetRegisterH: Byte;
begin
  Result := FRegisterH;
end;

function TGBCCPU.GetRegisterL: Byte;
begin
  Result := FRegisterL;
end;

function TGBCCPU.GetStackPointerHigh: Byte;
begin
  Result := Hi(StackPointer);
end;

function TGBCCPU.GetStackPointerLow: Byte;
begin
  Result := Lo(StackPointer);
end;

function TGBCCPU.GetStopped: Boolean;
begin
  Result := FStopped;
end;

procedure TGBCCPU.ExecuteInc(OpCode: Byte);
begin
  var Value: Integer;
  case OpCode of
    $3C:
      begin
        SetRegisterA(Byte(GetRegisterA + 1));
        Value := GetRegisterA;
      end;
    $04:
      begin
        SetRegisterB(Byte(GetRegisterB + 1));
        Value := GetRegisterB;
      end;
    $0C:
      begin
        SetRegisterC(Byte(GetRegisterC + 1));
        Value := GetRegisterC;
      end;
    $14:
      begin
        SetRegisterD(Byte(GetRegisterD + 1));
        Value := GetRegisterD;
      end;
    $1C:
      begin
        SetRegisterE(Byte(GetRegisterE + 1));
        Value := GetRegisterE;
      end;
    $24:
      begin
        SetRegisterH(Byte(GetRegisterH + 1));
        Value := GetRegisterH;
      end;
    $2C:
      begin
        SetRegisterL(Byte(GetRegisterL + 1));
        Value := GetRegisterL;
      end;
    $34:
      begin
        var Address := GetRegisterHL;
        Value := FMemory.ReadByte(Address) + 1;
        FMemory.WriteByte(Address, (Value and 255));
      end;
  else
    Exit;
  end;

  SetZeroFlag((Value and 255) = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag((((Value - 1) and $F) + ($F and 1)) > $F);
  if (OpCode = $34) then
    ConsumeClockCycles(12)
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.ExecuteJmp(OpCode: Byte);
begin
  var Address: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  var Temp: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  Temp := Temp shl 8;
  Address := Address or Temp;
  ProgramCounter := Address;
  ConsumeClockCycles(16);
end;

procedure TGBCCPU.ExecuteJPCC(OpCode: Byte);
begin
  var Condition: Boolean := False;
  case OpCode of
    $C2:
      Condition := not GetZeroFlag;
    $CA:
      Condition := GetZeroFlag;
    $D2:
      Condition := not GetCarryFlag;
    $DA:
      Condition := GetCarryFlag;
  end;
  var Address: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  var Temp: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  if Condition then
  begin
    Temp := Temp shl 8;
    Address := Address or Temp;
    ProgramCounter := Address;
    ConsumeClockCycles(16);
  end
  else
    ConsumeClockCycles(12);
end;

procedure TGBCCPU.ExecuteJRCC(OpCode: Byte);
begin
  var Condition: Boolean := False;
  case OpCode of
    $20: //JR NZ,r8
      Condition := not GetZeroFlag;
    $28: //JR Z,r8
      Condition := GetZeroFlag;
    $30: //JR NC,r8
      Condition := not GetCarryFlag;
    $38: //JR C,r8
      Condition := GetCarryFlag;
  end;
  var N: Integer := FMemory.ReadByte(ProgramCounter);
  ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
  if not Condition then
  begin
    ConsumeClockCycles(8);
    Exit;
  end;
  if N > 127 then
    N := -((not N + 1) and 255);
  ProgramCounter := (Integer(ProgramCounter) + N) and $FFFF;
  ConsumeClockCycles(12);
end;

procedure TGBCCPU.ExecuteLoad(OpCode: Byte);
begin
  case OpCode of
    $06: //LD nn, n
      begin
        SetRegisterB(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $0E:
      begin
        SetRegisterC(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $16:
      begin
        SetRegisterD(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $1E:
      begin
        SetRegisterE(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $26:
      begin
        SetRegisterH(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $2E:
      begin
        SetRegisterL(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $78: //LD r1,r2
      begin
        SetRegisterA(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $7F:
      begin
        SetRegisterA(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $79:
      begin
        SetRegisterA(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $7A:
      begin
        SetRegisterA(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $7B:
      begin
        SetRegisterA(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $7C:
      begin
        SetRegisterA(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $7D:
      begin
        SetRegisterA(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $7E:
      begin
        SetRegisterA(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $40:
      begin
        SetRegisterB(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $41:
      begin
        SetRegisterB(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $42:
      begin
        SetRegisterB(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $43:
      begin
        SetRegisterB(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $44:
      begin
        SetRegisterB(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $45:
      begin
        SetRegisterB(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $46:
      begin
        SetRegisterB(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $48:
      begin
        SetRegisterC(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $49:
      begin
        SetRegisterC(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $4A:
      begin
        SetRegisterC(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $4B:
      begin
        SetRegisterC(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $4C:
      begin
        SetRegisterC(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $4D:
      begin
        SetRegisterC(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $4E:
      begin
        SetRegisterC(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $50:
      begin
        SetRegisterD(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $51:
      begin
        SetRegisterD(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $52:
      begin
        SetRegisterD(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $53:
      begin
        SetRegisterD(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $54:
      begin
        SetRegisterD(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $55:
      begin
        SetRegisterD(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $56:
      begin
        SetRegisterD(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $58:
      begin
        SetRegisterE(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $59:
      begin
        SetRegisterE(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $5A:
      begin
        SetRegisterE(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $5B:
      begin
        SetRegisterE(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $5C:
      begin
        SetRegisterE(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $5D:
      begin
        SetRegisterE(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $5E:
      begin
        SetRegisterE(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $60:
      begin
        SetRegisterH(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $61:
      begin
        SetRegisterH(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $62:
      begin
        SetRegisterH(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $63:
      begin
        SetRegisterH(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $64:
      begin
        SetRegisterH(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $65:
      begin
        SetRegisterH(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $66:
      begin
        SetRegisterH(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $68:
      begin
        SetRegisterL(GetRegisterB);
        ConsumeClockCycles(4);
      end;
    $69:
      begin
        SetRegisterL(GetRegisterC);
        ConsumeClockCycles(4);
      end;
    $6A:
      begin
        SetRegisterL(GetRegisterD);
        ConsumeClockCycles(4);
      end;
    $6B:
      begin
        SetRegisterL(GetRegisterE);
        ConsumeClockCycles(4);
      end;
    $6C:
      begin
        SetRegisterL(GetRegisterH);
        ConsumeClockCycles(4);
      end;
    $6D:
      begin
        SetRegisterL(GetRegisterL);
        ConsumeClockCycles(4);
      end;
    $6E:
      begin
        SetRegisterL(FMemory.ReadByte(GetRegisterHL));
        ConsumeClockCycles(8);
      end;
    $70:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterB);
        ConsumeClockCycles(8);
      end;
    $71:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterC);
        ConsumeClockCycles(8);
      end;
    $72:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterD);
        ConsumeClockCycles(8);
      end;
    $73:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterE);
        ConsumeClockCycles(8);
      end;
    $74:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterH);
        ConsumeClockCycles(8);
      end;
    $75:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterL);
        ConsumeClockCycles(8);
      end;
    $36:
      begin
        FMemory.WriteByte(GetRegisterHL, FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(12);
      end;
    $0A: //LD A,n
      begin
        SetRegisterA(FMemory.ReadByte(GetRegisterBC));
        ConsumeClockCycles(8);
      end;
    $1A:
      begin
        SetRegisterA(FMemory.ReadByte(GetRegisterDE));
        ConsumeClockCycles(8);
      end;
    $FA:
      begin
        SetRegisterA(FMemory.ReadByte(FMemory.ReadWord(ProgramCounter)));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(16);
      end;
    $3E:
      begin
        SetRegisterA(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(8);
      end;
    $47: //LD n,A
      begin
        SetRegisterB(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $4F:
      begin
        SetRegisterC(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $57:
      begin
        SetRegisterD(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $5F:
      begin
        SetRegisterE(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $67:
      begin
        SetRegisterH(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $6F:
      begin
        SetRegisterL(GetRegisterA);
        ConsumeClockCycles(4);
      end;
    $02:
      begin
        FMemory.WriteByte(GetRegisterBC, GetRegisterA);
        ConsumeClockCycles(8);
      end;
    $12:
      begin
        FMemory.WriteByte(GetRegisterDE, GetRegisterA);
        ConsumeClockCycles(8);
      end;
    $77:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterA);
        ConsumeClockCycles(8);
      end;
    $EA:
      begin
        FMemory.WriteByte(FMemory.ReadWord(ProgramCounter), GetRegisterA);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(16);
      end;
    $F2:
      begin
        SetRegisterA(FMemory.ReadByte(GetRegisterC + $FF00));
        ConsumeClockCycles(8);
      end;
    $E2:
      begin
        FMemory.WriteByte($FF00 + GetRegisterC, GetRegisterA);
        ConsumeClockCycles(8);
      end;
    $3A:
      begin
        SetRegisterA(FMemory.ReadByte(GetRegisterHL));
        SetRegisterHL((GetRegisterHL - 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $32:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterA);
        SetRegisterHL((GetRegisterHL - 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $2A:
      begin
        SetRegisterA(FMemory.ReadByte(GetRegisterHL));
        SetRegisterHL((GetRegisterHL + 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $22:
      begin
        FMemory.WriteByte(GetRegisterHL, GetRegisterA);
        SetRegisterHL((GetRegisterHL + 1) and $FFFF);
        ConsumeClockCycles(8);
      end;
    $E0:
      begin
        FMemory.WriteByte($FF00 + FMemory.ReadByte(ProgramCounter), GetRegisterA);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(12);
      end;
    $F0:
      begin
        var Address := $FF00 + FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        // LDH reads I/O in its third machine cycle. In particular, LY can
        // enter VBlank during this instruction, before the pending interrupt
        // is serviced. Sampling it at opcode fetch can miss line 144 forever
        // when the VBlank handler runs into the next frame.
        ConsumeClockCycles(8);
        SetRegisterA(FMemory.ReadByte(Address));
        ConsumeClockCycles(4);
      end;
    $01: //LD BC,nn
      begin
        SetRegisterC(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        SetRegisterB(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(12);
      end;
    $11:
      begin
        SetRegisterE(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        SetRegisterD(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(12);
      end;
    $21:
      begin
        SetRegisterL(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        SetRegisterH(FMemory.ReadByte(ProgramCounter));
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(12);
      end;
    $31:
      begin
        StackPointer := FMemory.ReadWord(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        ConsumeClockCycles(12);
      end;
    $F9:
      begin
        StackPointer := GetRegisterHL;
        ConsumeClockCycles(8);
      end;
    $F8:
      begin
        var Temp: Integer := FMemory.ReadByte(ProgramCounter);
        if Temp > 127 then
          Temp := -((not Temp + 1) and 255);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        var AResult: Integer := Temp + StackPointer;
        SetRegisterH((AResult shr 8) and 255);
        SetRegisterL(AResult and 255);
        SetZeroFlag(False);
        SetSubtractFlag(False);
        SetCarryFlag(((StackPointer xor Temp xor AResult) and $100) = $100);
        SetHalfCarryFlag(((StackPointer xor Temp xor AResult) and $10) = $10);
        ConsumeClockCycles(12);
      end;
    $08:
      begin
        var Low := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        var Up := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
        var Address := ((Up shl 8) + Low);
        FMemory.WriteByte(Address, GetStackPointerLow);
        FMemory.WriteByte(Address + 1, GetStackPointerHigh);
        ConsumeClockCycles(20);
      end;
  end;
end;

procedure TGBCCPU.Main;
const
  SyncCycles = 4096;
begin
  FStopped := False;
  try
    var Stopwatch := TStopwatch.StartNew;
    var LastSyncCycles: UInt64 := 0;

    FCycles := 0;
    while not FStopped do
    begin
      Step;

      if FCycles - LastSyncCycles < SyncCycles then
        Continue;

      LastSyncCycles := FCycles;
      var CurrentTicks := Stopwatch.ElapsedTicks;
      var TargetTicks := Int64((FCycles * UInt64(TStopwatch.Frequency)) div CPUClockFrequency);

      while CurrentTicks < TargetTicks - 10 do
        CurrentTicks := Stopwatch.ElapsedTicks;
    end;
  finally
    FStopped := True;
  end;
end;

procedure TGBCCPU.ExecuteOr(OpCode: Byte);
begin
  var Second: Integer := 0;
  case OpCode of
    $B7:
      Second := GetRegisterA;
    $B0:
      Second := GetRegisterB;
    $B1:
      Second := GetRegisterC;
    $B2:
      Second := GetRegisterD;
    $B3:
      Second := GetRegisterE;
    $B4:
      Second := GetRegisterH;
    $B5:
      Second := GetRegisterL;
    $B6:
      Second := FMemory.ReadByte(GetRegisterHL);
    $F6:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  end;
  SetRegisterA(GetRegisterA or Second);
  SetZeroFlag(GetRegisterA = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  SetCarryFlag(False);
  if (OpCode = $B6) or (OpCode = $F6) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

function TGBCCPU.PopWord: Integer;
begin
  var Low: Integer := FMemory.ReadByte(StackPointer);
  // The Game Boy stack wraps across $FFFF->$0000.  Widen before adding so
  // Delphi range checks do not reject the valid 16-bit wrap.
  StackPointer := (Integer(StackPointer) + 1) and $FFFF;
  var High: Integer := FMemory.ReadByte(StackPointer);
  StackPointer := (Integer(StackPointer) + 1) and $FFFF;
  High := High shl 8;
  Result := High or Low;
end;

procedure TGBCCPU.ExecutePop(OpCode: Integer);
begin
  case OpCode of
    $F1: //POP AF
      begin
        SetRegisterAF(PopWord);
        ConsumeClockCycles(12);
      end;
    $C1: //POP BC
      begin
        SetRegisterBC(PopWord);
        ConsumeClockCycles(12);
      end;
    $D1: //POP DE
      begin
        SetRegisterDE(PopWord);
        ConsumeClockCycles(12);
      end;
    $E1: //POP HL
      begin
        SetRegisterHL(PopWord);
        ConsumeClockCycles(12);
      end;
  end;
end;

procedure TGBCCPU.ProcessEI(OpCode: Integer);
begin
  if FPendingInterruptEnable <= 0 then
    Exit;
  Dec(FPendingInterruptEnable);
  if FPendingInterruptEnable = 0 then
    TGBCInterruptManager.Instance.MasterEnable;
end;

procedure TGBCCPU.ProcessInterrupts;
begin
  var Interrupts: TGBCInterruptArray := TGBCInterruptManager.Instance.GetAllInterrupts;
  // The manager stores Joypad first and VBlank last.
  for var I := High(Interrupts) downto 0 do
  begin
    var Interrupt := Interrupts[I];
    if not (Interrupt.IsRaised and Interrupt.IsEnabled) then
      Continue;

    FIsHalted := False;
    if not TGBCInterruptManager.Instance.IsMasterEnabled then
      Exit;

    TGBCInterruptManager.Instance.ClearInterruptByIndex(I);
    TGBCInterruptManager.Instance.MasterDisable;
    FPendingInterruptEnable := 0;
    if FSuppressPCIncrement then
    begin
      // EI; HALT with a pending interrupt returns to HALT, not its successor.
      ProgramCounter := (ProgramCounter - 1) and $FFFF;
      FSuppressPCIncrement := False;
    end;
    PushWord(ProgramCounter);
    ProgramCounter := Interrupt.Handler;
    ConsumeClockCycles(20);
    Exit;
  end;
end;

procedure TGBCCPU.PushWord(Value: Integer);
begin
  StackPointer := (Integer(StackPointer) - 1) and $FFFF;
  FMemory.WriteByte(StackPointer, (Value and $FF00) shr 8);
  StackPointer := (Integer(StackPointer) - 1) and $FFFF;
  FMemory.WriteByte(StackPointer, Value and $00FF);
end;

procedure TGBCCPU.ExecutePush(OpCode: Integer);
begin
  case OpCode of
    $F5: //PUSH AF
      begin
        PushWord(GetRegisterAF);
        ConsumeClockCycles(16);
      end;
    $C5: //PUSH BC
      begin
        PushWord(GetRegisterBC);
        ConsumeClockCycles(16);
      end;
    $D5: //PUSH DE
      begin
        PushWord(GetRegisterDE);
        ConsumeClockCycles(16);
      end;
    $E5: //PUSH HL
      begin
        PushWord(GetRegisterHL);
        ConsumeClockCycles(16);
      end;
  end;
end;

procedure TGBCCPU.ExecuteRRC(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB0F:
      Value := GetRegisterA;
    $CB08:
      Value := GetRegisterB;
    $CB09:
      Value := GetRegisterC;
    $CB0A:
      Value := GetRegisterD;
    $CB0B:
      Value := GetRegisterE;
    $CB0C:
      Value := GetRegisterH;
    $CB0D:
      Value := GetRegisterL;
    $CB0E:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var Oldbit0: Integer := Value and $01;
  Value := Value shr 1;
  var Result: Integer := Value or (Oldbit0 shl 7);
  case OpCode of
    $CB0F:
      SetRegisterA(Result);
    $CB08:
      SetRegisterB(Result);
    $CB09:
      SetRegisterC(Result);
    $CB0A:
      SetRegisterD(Result);
    $CB0B:
      SetRegisterE(Result);
    $CB0C:
      SetRegisterH(Result);
    $CB0D:
      SetRegisterL(Result);
    $CB0E:
      FMemory.WriteByte(GetRegisterHL, Result);
  end;
  SetZeroFlag(Result = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  SetCarryFlag(Oldbit0 = 1);
  if OpCode = $CB0E then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteRes(OpCode: Word);
begin
  var Value: Integer := ReadCBOperand(OpCode);
  var BitIndex: Integer := (OpCode - $CB80) div 8;
  Value := Value and (not (1 shl BitIndex));
  WriteCBOperand(OpCode, Value);
end;

procedure TGBCCPU.ExecuteRetCC(OpCode: Byte);
begin
  var Condition: Boolean;
  case OpCode of
    $C0:
      Condition := not GetZeroFlag;
    $C8:
      Condition := GetZeroFlag;
    $D0:
      Condition := not GetCarryFlag;
    $D8:
      Condition := GetCarryFlag;
  else
    Exit;
  end;

  if Condition then
  begin
    ReturnFromCall;
    ConsumeClockCycles(20);
  end
  else
    ConsumeClockCycles(8)
end;

procedure TGBCCPU.ReturnFromCall;
begin
  ProgramCounter := PopWord;
end;

procedure TGBCCPU.ExecuteRLC(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB07:
      Value := GetRegisterA;
    $CB00:
      Value := GetRegisterB;
    $CB01:
      Value := GetRegisterC;
    $CB02:
      Value := GetRegisterD;
    $CB03:
      Value := GetRegisterE;
    $CB04:
      Value := GetRegisterH;
    $CB05:
      Value := GetRegisterL;
    $CB06:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var Result: Integer := (Value shl 1) or (Value shr 7);
  var Bit7: Boolean := ((Value and $80) shr 7) = 1;
  Result := Result and 255;
  case OpCode of
    $CB07:
      SetRegisterA(Result);
    $CB00:
      SetRegisterB(Result);
    $CB01:
      SetRegisterC(Result);
    $CB02:
      SetRegisterD(Result);
    $CB03:
      SetRegisterE(Result);
    $CB04:
      SetRegisterH(Result);
    $CB05:
      SetRegisterL(Result);
    $CB06:
      FMemory.WriteByte(GetRegisterHL, Result);
  end;
  SetCarryFlag(Bit7);
  SetHalfCarryFlag(False);
  SetSubtractFlag(False);
  SetZeroFlag(Result = 0);
  if OpCode = $CB06 then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteRL(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB17:
      Value := GetRegisterA;
    $CB10:
      Value := GetRegisterB;
    $CB11:
      Value := GetRegisterC;
    $CB12:
      Value := GetRegisterD;
    $CB13:
      Value := GetRegisterE;
    $CB14:
      Value := GetRegisterH;
    $CB15:
      Value := GetRegisterL;
    $CB16:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var Bit7: Boolean := (Value and $80) > 0;
  var Result: Integer := (Value shl 1) and $FF;
  if GetCarryFlag then
    Result := Result or 1
  else
    Result := Result or 0;
  case OpCode of
    $CB17:
      SetRegisterA(Result);
    $CB10:
      SetRegisterB(Result);
    $CB11:
      SetRegisterC(Result);
    $CB12:
      SetRegisterD(Result);
    $CB13:
      SetRegisterE(Result);
    $CB14:
      SetRegisterH(Result);
    $CB15:
      SetRegisterL(Result);
    $CB16:
      FMemory.WriteByte(GetRegisterHL, Result);
  end;
  SetZeroFlag(Result = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  SetCarryFlag(Bit7);
  if OpCode = $CB16 then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteRR(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB1F:
      Value := GetRegisterA;
    $CB18:
      Value := GetRegisterB;
    $CB19:
      Value := GetRegisterC;
    $CB1A:
      Value := GetRegisterD;
    $CB1B:
      Value := GetRegisterE;
    $CB1C:
      Value := GetRegisterH;
    $CB1D:
      Value := GetRegisterL;
    $CB1E:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var NewValue: Integer;
  if GetCarryFlag then
    NewValue := (Value shr 1) or (1 shl 7)
  else
    NewValue := (Value shr 1) or (0 shl 7);
  case OpCode of
    $CB1F:
      SetRegisterA(NewValue);
    $CB18:
      SetRegisterB(NewValue);
    $CB19:
      SetRegisterC(NewValue);
    $CB1A:
      SetRegisterD(NewValue);
    $CB1B:
      SetRegisterE(NewValue);
    $CB1C:
      SetRegisterH(NewValue);
    $CB1D:
      SetRegisterL(NewValue);
    $CB1E:
      FMemory.WriteByte(GetRegisterHL, NewValue);
  end;
  SetCarryFlag((Value and $1) = 1);
  SetZeroFlag(NewValue = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  if OpCode = $CB1E then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteRST(Value: Byte);
begin
  PushWord(ProgramCounter);
  case Value of
    $C7:
      ProgramCounter := $00;
    $CF:
      ProgramCounter := $08;
    $D7:
      ProgramCounter := $10;
    $DF:
      ProgramCounter := $18;
    $E7:
      ProgramCounter := $20;
    $EF:
      ProgramCounter := $28;
    $F7:
      ProgramCounter := $30;
    $FF:
      ProgramCounter := $38;
  end;
  ConsumeClockCycles(16);
end;

function TGBCCPU.GetRegisterHL: Word;
begin
  Result := FRegisterH * $100 + FRegisterL;
end;

procedure TGBCCPU.ExecuteSBC(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $9F:
      Second := GetRegisterA;
    $98:
      Second := GetRegisterB;
    $99:
      Second := GetRegisterC;
    $9A:
      Second := GetRegisterD;
    $9B:
      Second := GetRegisterE;
    $9C:
      Second := GetRegisterH;
    $9D:
      Second := GetRegisterL;
    $9E:
      Second := FMemory.ReadByte(GetRegisterHL);
    $DE:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  var Result: Integer := GetRegisterA - Second;
  if GetCarryFlag then
    Result := Result - 1;
  SetSubtractFlag(True);
  SetZeroFlag(Result and 255 = 0);
  SetCarryFlag(Result and $100 <> 0);
  SetHalfCarryFlag(((GetRegisterA xor Second xor Result) and $10) <> 0);
  if (Result > 255) or (Result < 0) then
    Result := Result and 255;
  SetRegisterA(Result);
  if (OpCode = $9E) or (OpCode = $DE) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.SetCarryFlag(Value: Boolean);
begin
  if Value then
    SetRegisterF(GetRegisterF or $10)
  else
    SetRegisterF(GetRegisterF and $EF);
end;

procedure TGBCCPU.SetHalfCarryFlag(Value: Boolean);
begin
  if Value then
    SetRegisterF(GetRegisterF or $20)
  else
    SetRegisterF(GetRegisterF and $DF);
end;

procedure TGBCCPU.SetSubtractFlag(Value: Boolean);
begin
  if Value then
    SetRegisterF(GetRegisterF or $40)
  else
    SetRegisterF(GetRegisterF and $BF);
end;

procedure TGBCCPU.SetZeroFlag(Value: Boolean);
begin
  if Value then
    SetRegisterF(GetRegisterF or $80)
  else
    SetRegisterF(GetRegisterF and $7F);
end;

procedure TGBCCPU.SetRegisterA(Value: Byte);
begin
  FRegisterA := Value;
end;

procedure TGBCCPU.SetRegisterF(Value: Byte);
begin
  FRegisterF := Value;
end;

procedure TGBCCPU.SetRegisterAF(Value: Word);
begin
  FRegisterA := Value div 256;
  FRegisterF := Byte(Value) and $F0;
end;

procedure TGBCCPU.SetRegisterB(Value: Byte);
begin
  FRegisterB := Value;
end;

procedure TGBCCPU.SetRegisterC(Value: Byte);
begin
  FRegisterC := Value;
end;

procedure TGBCCPU.SetRegisterBC(Value: Word);
begin
  FRegisterB := Hi(Value);
  FRegisterC := Lo(Value);
end;

procedure TGBCCPU.SetRegisterD(Value: Byte);
begin
  FRegisterD := Value;
end;

procedure TGBCCPU.SetRegisterE(Value: Byte);
begin
  FRegisterE := Value;
end;

procedure TGBCCPU.SetRegisterDE(Value: Word);
begin
  FRegisterD := Hi(Value);
  FRegisterE := Lo(Value);
end;

procedure TGBCCPU.SetRegisterH(Value: Byte);
begin
  FRegisterH := Value;
end;

procedure TGBCCPU.SetRegisterL(Value: Byte);
begin
  FRegisterL := Value;
end;

procedure TGBCCPU.ExecuteSet(OpCode: Word);
begin
  var Value: Integer := ReadCBOperand(OpCode);
  var BitIndex: Integer := (OpCode - $CBC0) div 8;
  var Mask: Integer := 1 shl BitIndex;
  Value := Value or Mask;
  WriteCBOperand(OpCode, Value);
end;

procedure TGBCCPU.SkipBIOS;
begin
  if FMemory.IsCGBMode then
  begin
    // CGB-only ROMs observe these registers to distinguish a real CGB boot
    // from a DMG-compatible launch.
    SetRegisterA($11);
    SetRegisterB($00);
    SetRegisterC($00);
    SetRegisterD($FF);
    SetRegisterE($56);
    SetRegisterH($00);
    SetRegisterL($0D);
  end
  else
  begin
    SetRegisterA($01);
    SetRegisterB($00);
    SetRegisterC($13);
    SetRegisterD($00);
    SetRegisterE($D8);
    SetRegisterH($01);
    SetRegisterL($4D);
  end;
  SetZeroFlag(True);
  SetSubtractFlag(False);
  SetHalfCarryFlag(not FMemory.IsCGBMode);
  SetCarryFlag(not FMemory.IsCGBMode);
  StackPointer := $FFFE;
  ProgramCounter := $100;
  TGBCTimer.Instance.SetDivider($AB);
  FMemory.WriteByte($FF0F, $E1);
  FMemory.WriteByte($FF05, $00); // TIMA
  FMemory.WriteByte($FF06, $00); // TMA
  FMemory.WriteByte($FF07, $00); // TAC
  FMemory.WriteByte($FF10, $80); // NR10
  FMemory.WriteByte($FF11, $BF); // NR11
  FMemory.WriteByte($FF12, $F3); // NR12
  FMemory.WriteByte($FF14, $BF); // NR14
  FMemory.WriteByte($FF16, $3F); // NR21
  FMemory.WriteByte($FF17, $00); // NR22
  FMemory.WriteByte($FF19, $BF); // NR24
  FMemory.WriteByte($FF1A, $7F); // NR30
  FMemory.WriteByte($FF1B, $FF); // NR31
  FMemory.WriteByte($FF1C, $9F); // NR32
  FMemory.WriteByte($FF1E, $BF); // NR33
  FMemory.WriteByte($FF20, $FF); // NR41
  FMemory.WriteByte($FF21, $00); // NR42
  FMemory.WriteByte($FF22, $00); // NR43
  FMemory.WriteByte($FF23, $BF); // NR30
  FMemory.WriteByte($FF24, $77); // NR50
  FMemory.WriteByte($FF25, $F3); // NR51
  FMemory.WriteByte($FF26, $F1); // NR52
  FMemory.WriteByte($FF40, $91); // LCDC
  FMemory.WriteByte($FF42, $00); // SCY
  FMemory.WriteByte($FF43, $00); // SCX
  FMemory.WriteByte($FF45, $00); // LYC
  FMemory.WriteByte($FF47, $FC); // BGP
  FMemory.WriteByte($FF48, $FF); // OBP0
  FMemory.WriteByte($FF49, $FF); // OBP1
  FMemory.WriteByte($FF4A, $00); // WY
  FMemory.WriteByte($FF4B, $00); // WX
  FMemory.WriteByte($FFFF, $00); // IE
end;

procedure TGBCCPU.ExecuteSLA(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB27:
      Value := GetRegisterA;
    $CB20:
      Value := GetRegisterB;
    $CB21:
      Value := GetRegisterC;
    $CB22:
      Value := GetRegisterD;
    $CB23:
      Value := GetRegisterE;
    $CB24:
      Value := GetRegisterH;
    $CB25:
      Value := GetRegisterL;
    $CB26:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var Carry: Boolean := ((Value and $80) shr 7) = 1;
  var Result: Integer := (Value shl 1) and 255;
  case OpCode of
    $CB27:
      SetRegisterA(Result);
    $CB20:
      SetRegisterB(Result);
    $CB21:
      SetRegisterC(Result);
    $CB22:
      SetRegisterD(Result);
    $CB23:
      SetRegisterE(Result);
    $CB24:
      SetRegisterH(Result);
    $CB25:
      SetRegisterL(Result);
    $CB26:
      FMemory.WriteByte(GetRegisterHL, Result);
  end;
  SetZeroFlag(Result = 0);
  SetCarryFlag(Carry);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  if OpCode = $CB26 then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteSRA(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB2F:
      Value := GetRegisterA;
    $CB28:
      Value := GetRegisterB;
    $CB29:
      Value := GetRegisterC;
    $CB2A:
      Value := GetRegisterD;
    $CB2B:
      Value := GetRegisterE;
    $CB2C:
      Value := GetRegisterH;
    $CB2D:
      Value := GetRegisterL;
    $CB2E:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var Carry: Boolean := (Value and 1) <> 0;
  var Result: Integer := (Value shr 1) or (Value and $80);
  case OpCode of
    $CB2F:
      SetRegisterA(Result);
    $CB28:
      SetRegisterB(Result);
    $CB29:
      SetRegisterC(Result);
    $CB2A:
      SetRegisterD(Result);
    $CB2B:
      SetRegisterE(Result);
    $CB2C:
      SetRegisterH(Result);
    $CB2D:
      SetRegisterL(Result);
    $CB2E:
      FMemory.WriteByte(GetRegisterHL, Result);
  end;
  SetCarryFlag(Carry);
  SetZeroFlag(Result = 0);
  SetHalfCarryFlag(False);
  SetSubtractFlag(False);
  if OpCode = $CB2E then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteSRL(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB3F:
      Value := GetRegisterA;
    $CB38:
      Value := GetRegisterB;
    $CB39:
      Value := GetRegisterC;
    $CB3A:
      Value := GetRegisterD;
    $CB3B:
      Value := GetRegisterE;
    $CB3C:
      Value := GetRegisterH;
    $CB3D:
      Value := GetRegisterL;
    $CB3E:
      Value := FMemory.ReadByte(GetRegisterHL);
  else
    Exit;
  end;

  var Carry: Boolean := Value and $1 <> 0;
  var Result: Integer := Value shr 1;
  case OpCode of
    $CB3F:
      SetRegisterA(Result);
    $CB38:
      SetRegisterB(Result);
    $CB39:
      SetRegisterC(Result);
    $CB3A:
      SetRegisterD(Result);
    $CB3B:
      SetRegisterE(Result);
    $CB3C:
      SetRegisterH(Result);
    $CB3D:
      SetRegisterL(Result);
    $CB3E:
      FMemory.WriteByte(GetRegisterHL, Result);
  end;
  SetZeroFlag(Result = 0);
  SetCarryFlag(Carry);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  if OpCode = $CB3E then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.Step;
begin
  ProcessInterrupts;
  if not FIsHalted then
  begin
    Inc(FInstructionCount);

    var OpCode := GetOpCode;
    FLastOpCode := OpCode;

    Decode(OpCode);
    ProcessEI(OpCode);
  end
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.Stop;
begin
  FStopped := True;
end;

procedure TGBCCPU.ExecuteSub(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $97:
      Second := GetRegisterA;
    $90:
      Second := GetRegisterB;
    $91:
      Second := GetRegisterC;
    $92:
      Second := GetRegisterD;
    $93:
      Second := GetRegisterE;
    $94:
      Second := GetRegisterH;
    $95:
      Second := GetRegisterL;
    $96:
      Second := FMemory.ReadByte(GetRegisterHL);
    $D6:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  var Result: Integer := GetRegisterA - Second;
  SetSubtractFlag(True);
  SetZeroFlag(Result and 255 = 0);
  SetCarryFlag(Second > GetRegisterA);
  SetHalfCarryFlag(((GetRegisterA xor Second xor Result) and $10) <> 0);
  if (Result > 255) or (Result < 0) then
    Result := Result and 255;
  SetRegisterA(Result);
  if (OpCode = $96) or (OpCode = $D6) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

function TGBCCPU.SwapNibbles(Value: Integer): Integer;
begin
  var Upper: Integer := Value and $F0;
  var Lower: Integer := Value and $0F;
  Lower := Lower shl 4;
  Upper := Upper shr 4;
  var Tmp: Integer := 0;
  Tmp := Tmp or Upper;
  Tmp := Tmp or Lower;
  Result := Tmp;
end;

procedure TGBCCPU.ExecuteSwap(OpCode: Word);
begin
  var Value: Integer;
  case OpCode of
    $CB37:
      begin
        Value := SwapNibbles(GetRegisterA);
        SetRegisterA(Value);
      end;
    $CB30:
      begin
        Value := SwapNibbles(GetRegisterB);
        SetRegisterB(Value);
      end;
    $CB31:
      begin
        Value := SwapNibbles(GetRegisterC);
        SetRegisterC(Value);
      end;
    $CB32:
      begin
        Value := SwapNibbles(GetRegisterD);
        SetRegisterD(Value);
      end;
    $CB33:
      begin
        Value := SwapNibbles(GetRegisterE);
        SetRegisterE(Value);
      end;
    $CB34:
      begin
        Value := SwapNibbles(GetRegisterH);
        SetRegisterH(Value);
      end;
    $CB35:
      begin
        Value := SwapNibbles(GetRegisterL);
        SetRegisterL(Value);
      end;
    $CB36:
      begin
        Value := SwapNibbles(FMemory.ReadByte(GetRegisterHL));
        FMemory.WriteByte(GetRegisterHL, Value);
      end;
  else
    Exit;
  end;

  SetZeroFlag(Value = 0);
  SetHalfCarryFlag(False);
  SetSubtractFlag(False);
  SetCarryFlag(False);
  if OpCode = $CB36 then
    ConsumeClockCycles(16)
  else
    ConsumeClockCycles(8);
end;

procedure TGBCCPU.ExecuteXor(OpCode: Byte);
begin
  var Second: Integer;
  case OpCode of
    $AF:
      Second := GetRegisterA;
    $A8:
      Second := GetRegisterB;
    $A9:
      Second := GetRegisterC;
    $AA:
      Second := GetRegisterD;
    $AB:
      Second := GetRegisterE;
    $AC:
      Second := GetRegisterH;
    $AD:
      Second := GetRegisterL;
    $AE:
      Second := FMemory.ReadByte(GetRegisterHL);
    $EE:
      begin
        Second := FMemory.ReadByte(ProgramCounter);
        ProgramCounter := (Integer(ProgramCounter) + 1) and $FFFF;
      end;
  else
    Exit;
  end;

  SetRegisterA(GetRegisterA xor Second);
  SetZeroFlag(GetRegisterA = 0);
  SetSubtractFlag(False);
  SetHalfCarryFlag(False);
  SetCarryFlag(False);

  if (OpCode = $AE) or (OpCode = $EE) then
    ConsumeClockCycles(8)
  else
    ConsumeClockCycles(4);
end;

procedure TGBCCPU.SetRegisterHL(Value: Word);
begin
  FRegisterH := Hi(Value);
  FRegisterL := Lo(Value);
end;


procedure TGBCCPU.SerializeState(State: TStateArchive);
begin
  State.Field(FLastOpCode, SizeOf(FLastOpCode));
  State.Field(FStopped, SizeOf(FStopped));
  State.Field(FInstructionCount, SizeOf(FInstructionCount));
  State.Field(FCycles, SizeOf(FCycles));
  State.Field(FRegisterA, SizeOf(FRegisterA));
  State.Field(FRegisterF, SizeOf(FRegisterF));
  State.Field(FRegisterB, SizeOf(FRegisterB));
  State.Field(FRegisterC, SizeOf(FRegisterC));
  State.Field(FRegisterD, SizeOf(FRegisterD));
  State.Field(FRegisterE, SizeOf(FRegisterE));
  State.Field(FRegisterH, SizeOf(FRegisterH));
  State.Field(FRegisterL, SizeOf(FRegisterL));
  State.Field(FIsHalted, SizeOf(FIsHalted));
  State.Field(FPendingInterruptEnable, SizeOf(FPendingInterruptEnable));
  State.Field(FSuppressPCIncrement, SizeOf(FSuppressPCIncrement));
  State.Field(StackPointer, SizeOf(StackPointer));
  State.Field(ProgramCounter, SizeOf(ProgramCounter));
end;

end.
