unit MD.Z80;

{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

type
  TZ80InstructionMetadata = record
    Opcode: Byte;
    Operands: array[0..1] of Byte;
    Condition: Byte;
    EmbeddedLiteral: Byte;
    HasDisplacement: Byte;
  end;

  TZ80State = record
    RegisterMode: Byte;
    Cycles: Word;
    ProgramCounter: Word;
    StackPointer: Word;
    A: Byte;
    F: Byte;
    B: Byte;
    C: Byte;
    D: Byte;
    E: Byte;
    H: Byte;
    L: Byte;
    AAlt: Byte;
    FAlt: Byte;
    BAlt: Byte;
    CAlt: Byte;
    DAlt: Byte;
    EAlt: Byte;
    HAlt: Byte;
    LAlt: Byte;
    IXH: Byte;
    IXL: Byte;
    IYH: Byte;
    IYL: Byte;
    R: Byte;
    i: Byte;
    InterruptsEnabled: Byte;
    InterruptPending: Byte;
  end;

  TZ80ReadCallback = function(UserData: Pointer; Address: Cardinal): Cardinal;

  TZ80WriteCallback = procedure(UserData: Pointer; Address: Cardinal; Value: Cardinal);

  TZ80ReadAndWriteCallbacks = record
    ReadCallback: TZ80ReadCallback;
    WriteCallback: TZ80WriteCallback;
    UserData: Pointer;
  end;

  PZ80InstructionMetadata = ^TZ80InstructionMetadata;

  TZ80Instruction = record
    Metadata: PZ80InstructionMetadata;
    Literal: Cardinal;
    Address: Cardinal;
    DoublePrefixMode: Byte;
  end;

  PZ80State = ^TZ80State;

  PZ80ReadAndWriteCallbacks = ^TZ80ReadAndWriteCallbacks;

  PZ80Instruction = ^TZ80Instruction;


//procedure DecodeInstructionMetadata(Metadata: PZ80InstructionMetadata; InstructionMode: Integer; RegisterMode: Integer; Opcode: Byte);

//function EvaluateCondition(Flags: Byte; Condition: Integer): Boolean;

//function MemoryRead(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;

//procedure MemoryWrite(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; Data: Cardinal);

//function InstructionMemoryRead(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks): Cardinal;

//function OpcodeFetch(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks): Cardinal;

//function MemoryRead16Bit(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;

//procedure MemoryWrite16Bit(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; Value: Cardinal);

//function ReadOperand(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction; Operand: Integer): Cardinal;

//procedure WriteOperand(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction; Operand: Integer; Value: Cardinal);

//procedure DecodeInstruction(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction);

//function ComputeParity(Value: Cardinal): Byte;

//procedure ExecuteInstruction(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction);

procedure ConstantInitialise();

procedure Z80StateInitialise(State: PZ80State);

procedure Z80Reset(State: PZ80State);

procedure Z80Interrupt(State: PZ80State; AssertInterrupt: Byte);

function Z80DoInstruction(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks): Cardinal;

implementation

var
  InstructionMetadataLookupNormal: array[0..2] of array[0..255] of TZ80InstructionMetadata;
  InstructionMetadataLookupBits: array[0..2] of array[0..255] of TZ80InstructionMetadata;
  InstructionMetadataLookupMisc: array[0..255] of TZ80InstructionMetadata;

const
  CLOWNZ80_OPCODE_NOP = 0;
  CLOWNZ80_OPCODE_EX_AF_AF = CLOWNZ80_OPCODE_NOP + 1;
  CLOWNZ80_OPCODE_DJNZ = CLOWNZ80_OPCODE_EX_AF_AF + 1;
  CLOWNZ80_OPCODE_JR_UNCONDITIONAL = CLOWNZ80_OPCODE_DJNZ + 1;
  CLOWNZ80_OPCODE_JR_CONDITIONAL = CLOWNZ80_OPCODE_JR_UNCONDITIONAL + 1;
  CLOWNZ80_OPCODE_LD_16BIT = CLOWNZ80_OPCODE_JR_CONDITIONAL + 1;
  CLOWNZ80_OPCODE_ADD_HL = CLOWNZ80_OPCODE_LD_16BIT + 1;
  CLOWNZ80_OPCODE_LD_8BIT = CLOWNZ80_OPCODE_ADD_HL + 1;
  CLOWNZ80_OPCODE_INC_16BIT = CLOWNZ80_OPCODE_LD_8BIT + 1;
  CLOWNZ80_OPCODE_DEC_16BIT = CLOWNZ80_OPCODE_INC_16BIT + 1;
  CLOWNZ80_OPCODE_INC_8BIT = CLOWNZ80_OPCODE_DEC_16BIT + 1;
  CLOWNZ80_OPCODE_DEC_8BIT = CLOWNZ80_OPCODE_INC_8BIT + 1;
  CLOWNZ80_OPCODE_RLCA = CLOWNZ80_OPCODE_DEC_8BIT + 1;
  CLOWNZ80_OPCODE_RRCA = CLOWNZ80_OPCODE_RLCA + 1;
  CLOWNZ80_OPCODE_RLA = CLOWNZ80_OPCODE_RRCA + 1;
  CLOWNZ80_OPCODE_RRA = CLOWNZ80_OPCODE_RLA + 1;
  CLOWNZ80_OPCODE_DAA = CLOWNZ80_OPCODE_RRA + 1;
  CLOWNZ80_OPCODE_CPL = CLOWNZ80_OPCODE_DAA + 1;
  CLOWNZ80_OPCODE_SCF = CLOWNZ80_OPCODE_CPL + 1;
  CLOWNZ80_OPCODE_CCF = CLOWNZ80_OPCODE_SCF + 1;
  CLOWNZ80_OPCODE_HALT = CLOWNZ80_OPCODE_CCF + 1;
  CLOWNZ80_OPCODE_ADD_A = CLOWNZ80_OPCODE_HALT + 1;
  CLOWNZ80_OPCODE_ADC_A = CLOWNZ80_OPCODE_ADD_A + 1;
  CLOWNZ80_OPCODE_SUB = CLOWNZ80_OPCODE_ADC_A + 1;
  CLOWNZ80_OPCODE_SBC_A = CLOWNZ80_OPCODE_SUB + 1;
  CLOWNZ80_OPCODE_AND = CLOWNZ80_OPCODE_SBC_A + 1;
  CLOWNZ80_OPCODE_XOR = CLOWNZ80_OPCODE_AND + 1;
  CLOWNZ80_OPCODE_OR = CLOWNZ80_OPCODE_XOR + 1;
  CLOWNZ80_OPCODE_CP = CLOWNZ80_OPCODE_OR + 1;
  CLOWNZ80_OPCODE_RET_CONDITIONAL = CLOWNZ80_OPCODE_CP + 1;
  CLOWNZ80_OPCODE_POP = CLOWNZ80_OPCODE_RET_CONDITIONAL + 1;
  CLOWNZ80_OPCODE_RET_UNCONDITIONAL = CLOWNZ80_OPCODE_POP + 1;
  CLOWNZ80_OPCODE_EXX = CLOWNZ80_OPCODE_RET_UNCONDITIONAL + 1;
  CLOWNZ80_OPCODE_JP_HL = CLOWNZ80_OPCODE_EXX + 1;
  CLOWNZ80_OPCODE_LD_SP_HL = CLOWNZ80_OPCODE_JP_HL + 1;
  CLOWNZ80_OPCODE_JP_CONDITIONAL = CLOWNZ80_OPCODE_LD_SP_HL + 1;
  CLOWNZ80_OPCODE_JP_UNCONDITIONAL = CLOWNZ80_OPCODE_JP_CONDITIONAL + 1;
  CLOWNZ80_OPCODE_CB_PREFIX = CLOWNZ80_OPCODE_JP_UNCONDITIONAL + 1;
  CLOWNZ80_OPCODE_OUT = CLOWNZ80_OPCODE_CB_PREFIX + 1;
  CLOWNZ80_OPCODE_IN = CLOWNZ80_OPCODE_OUT + 1;
  CLOWNZ80_OPCODE_EX_SP_HL = CLOWNZ80_OPCODE_IN + 1;
  CLOWNZ80_OPCODE_EX_DE_HL = CLOWNZ80_OPCODE_EX_SP_HL + 1;
  CLOWNZ80_OPCODE_DI = CLOWNZ80_OPCODE_EX_DE_HL + 1;
  CLOWNZ80_OPCODE_EI = CLOWNZ80_OPCODE_DI + 1;
  CLOWNZ80_OPCODE_CALL_CONDITIONAL = CLOWNZ80_OPCODE_EI + 1;
  CLOWNZ80_OPCODE_PUSH = CLOWNZ80_OPCODE_CALL_CONDITIONAL + 1;
  CLOWNZ80_OPCODE_CALL_UNCONDITIONAL = CLOWNZ80_OPCODE_PUSH + 1;
  CLOWNZ80_OPCODE_DD_PREFIX = CLOWNZ80_OPCODE_CALL_UNCONDITIONAL + 1;
  CLOWNZ80_OPCODE_ED_PREFIX = CLOWNZ80_OPCODE_DD_PREFIX + 1;
  CLOWNZ80_OPCODE_FD_PREFIX = CLOWNZ80_OPCODE_ED_PREFIX + 1;
  CLOWNZ80_OPCODE_RST = CLOWNZ80_OPCODE_FD_PREFIX + 1;
  CLOWNZ80_OPCODE_RLC = CLOWNZ80_OPCODE_RST + 1;
  CLOWNZ80_OPCODE_RRC = CLOWNZ80_OPCODE_RLC + 1;
  CLOWNZ80_OPCODE_RL = CLOWNZ80_OPCODE_RRC + 1;
  CLOWNZ80_OPCODE_RR = CLOWNZ80_OPCODE_RL + 1;
  CLOWNZ80_OPCODE_SLA = CLOWNZ80_OPCODE_RR + 1;
  CLOWNZ80_OPCODE_SRA = CLOWNZ80_OPCODE_SLA + 1;
  CLOWNZ80_OPCODE_SLL = CLOWNZ80_OPCODE_SRA + 1;
  CLOWNZ80_OPCODE_SRL = CLOWNZ80_OPCODE_SLL + 1;
  CLOWNZ80_OPCODE_BIT = CLOWNZ80_OPCODE_SRL + 1;
  CLOWNZ80_OPCODE_RES = CLOWNZ80_OPCODE_BIT + 1;
  CLOWNZ80_OPCODE_SET = CLOWNZ80_OPCODE_RES + 1;
  CLOWNZ80_OPCODE_IN_REGISTER = CLOWNZ80_OPCODE_SET + 1;
  CLOWNZ80_OPCODE_IN_NO_REGISTER = CLOWNZ80_OPCODE_IN_REGISTER + 1;
  CLOWNZ80_OPCODE_OUT_REGISTER = CLOWNZ80_OPCODE_IN_NO_REGISTER + 1;
  CLOWNZ80_OPCODE_OUT_NO_REGISTER = CLOWNZ80_OPCODE_OUT_REGISTER + 1;
  CLOWNZ80_OPCODE_SBC_HL = CLOWNZ80_OPCODE_OUT_NO_REGISTER + 1;
  CLOWNZ80_OPCODE_ADC_HL = CLOWNZ80_OPCODE_SBC_HL + 1;
  CLOWNZ80_OPCODE_NEG = CLOWNZ80_OPCODE_ADC_HL + 1;
  CLOWNZ80_OPCODE_RETN = CLOWNZ80_OPCODE_NEG + 1;
  CLOWNZ80_OPCODE_RETI = CLOWNZ80_OPCODE_RETN + 1;
  CLOWNZ80_OPCODE_IM = CLOWNZ80_OPCODE_RETI + 1;
  CLOWNZ80_OPCODE_LD_I_A = CLOWNZ80_OPCODE_IM + 1;
  CLOWNZ80_OPCODE_LD_R_A = CLOWNZ80_OPCODE_LD_I_A + 1;
  CLOWNZ80_OPCODE_LD_A_I = CLOWNZ80_OPCODE_LD_R_A + 1;
  CLOWNZ80_OPCODE_LD_A_R = CLOWNZ80_OPCODE_LD_A_I + 1;
  CLOWNZ80_OPCODE_RRD = CLOWNZ80_OPCODE_LD_A_R + 1;
  CLOWNZ80_OPCODE_RLD = CLOWNZ80_OPCODE_RRD + 1;
  CLOWNZ80_OPCODE_LDI = CLOWNZ80_OPCODE_RLD + 1;
  CLOWNZ80_OPCODE_LDD = CLOWNZ80_OPCODE_LDI + 1;
  CLOWNZ80_OPCODE_LDIR = CLOWNZ80_OPCODE_LDD + 1;
  CLOWNZ80_OPCODE_LDDR = CLOWNZ80_OPCODE_LDIR + 1;
  CLOWNZ80_OPCODE_CPI = CLOWNZ80_OPCODE_LDDR + 1;
  CLOWNZ80_OPCODE_CPD = CLOWNZ80_OPCODE_CPI + 1;
  CLOWNZ80_OPCODE_CPIR = CLOWNZ80_OPCODE_CPD + 1;
  CLOWNZ80_OPCODE_CPDR = CLOWNZ80_OPCODE_CPIR + 1;
  CLOWNZ80_OPCODE_INI = CLOWNZ80_OPCODE_CPDR + 1;
  CLOWNZ80_OPCODE_IND = CLOWNZ80_OPCODE_INI + 1;
  CLOWNZ80_OPCODE_INIR = CLOWNZ80_OPCODE_IND + 1;
  CLOWNZ80_OPCODE_INDR = CLOWNZ80_OPCODE_INIR + 1;
  CLOWNZ80_OPCODE_OUTI = CLOWNZ80_OPCODE_INDR + 1;
  CLOWNZ80_OPCODE_OUTD = CLOWNZ80_OPCODE_OUTI + 1;
  CLOWNZ80_OPCODE_OTIR = CLOWNZ80_OPCODE_OUTD + 1;
  CLOWNZ80_OPCODE_OTDR = CLOWNZ80_OPCODE_OTIR + 1;

const
  CLOWNZ80_OPERAND_NONE = 0;
  CLOWNZ80_OPERAND_A = CLOWNZ80_OPERAND_NONE + 1;
  CLOWNZ80_OPERAND_B = CLOWNZ80_OPERAND_A + 1;
  CLOWNZ80_OPERAND_C = CLOWNZ80_OPERAND_B + 1;
  CLOWNZ80_OPERAND_D = CLOWNZ80_OPERAND_C + 1;
  CLOWNZ80_OPERAND_E = CLOWNZ80_OPERAND_D + 1;
  CLOWNZ80_OPERAND_H = CLOWNZ80_OPERAND_E + 1;
  CLOWNZ80_OPERAND_L = CLOWNZ80_OPERAND_H + 1;
  CLOWNZ80_OPERAND_IXH = CLOWNZ80_OPERAND_L + 1;
  CLOWNZ80_OPERAND_IXL = CLOWNZ80_OPERAND_IXH + 1;
  CLOWNZ80_OPERAND_IYH = CLOWNZ80_OPERAND_IXL + 1;
  CLOWNZ80_OPERAND_IYL = CLOWNZ80_OPERAND_IYH + 1;
  CLOWNZ80_OPERAND_AF = CLOWNZ80_OPERAND_IYL + 1;
  CLOWNZ80_OPERAND_BC = CLOWNZ80_OPERAND_AF + 1;
  CLOWNZ80_OPERAND_DE = CLOWNZ80_OPERAND_BC + 1;
  CLOWNZ80_OPERAND_HL = CLOWNZ80_OPERAND_DE + 1;
  CLOWNZ80_OPERAND_IX = CLOWNZ80_OPERAND_HL + 1;
  CLOWNZ80_OPERAND_IY = CLOWNZ80_OPERAND_IX + 1;
  CLOWNZ80_OPERAND_PC = CLOWNZ80_OPERAND_IY + 1;
  CLOWNZ80_OPERAND_SP = CLOWNZ80_OPERAND_PC + 1;
  CLOWNZ80_OPERAND_BC_INDIRECT = CLOWNZ80_OPERAND_SP + 1;
  CLOWNZ80_OPERAND_DE_INDIRECT = CLOWNZ80_OPERAND_BC_INDIRECT + 1;
  CLOWNZ80_OPERAND_HL_INDIRECT = CLOWNZ80_OPERAND_DE_INDIRECT + 1;
  CLOWNZ80_OPERAND_IX_INDIRECT = CLOWNZ80_OPERAND_HL_INDIRECT + 1;
  CLOWNZ80_OPERAND_IY_INDIRECT = CLOWNZ80_OPERAND_IX_INDIRECT + 1;
  CLOWNZ80_OPERAND_ADDRESS = CLOWNZ80_OPERAND_IY_INDIRECT + 1;
  CLOWNZ80_OPERAND_LITERAL_8BIT = CLOWNZ80_OPERAND_ADDRESS + 1;
  CLOWNZ80_OPERAND_LITERAL_16BIT = CLOWNZ80_OPERAND_LITERAL_8BIT + 1;

const
  CLOWNZ80_CONDITION_NOT_ZERO = 0;
  CLOWNZ80_CONDITION_ZERO = 1;
  CLOWNZ80_CONDITION_NOT_CARRY = 2;
  CLOWNZ80_CONDITION_CARRY = 3;
  CLOWNZ80_CONDITION_PARITY_OVERFLOW = 4;
  CLOWNZ80_CONDITION_PARITY_EQUALITY = 5;
  CLOWNZ80_CONDITION_PLUS = 6;
  CLOWNZ80_CONDITION_MINUS = 7;

const
  CLOWNZ80_INSTRUCTION_MODE_NORMAL = 0;
  CLOWNZ80_INSTRUCTION_MODE_BITS = CLOWNZ80_INSTRUCTION_MODE_NORMAL + 1;
  CLOWNZ80_INSTRUCTION_MODE_MISC = CLOWNZ80_INSTRUCTION_MODE_BITS + 1;

const
  CLOWNZ80_REGISTER_MODE_HL = 0;
  CLOWNZ80_REGISTER_MODE_IX = CLOWNZ80_REGISTER_MODE_HL + 1;
  CLOWNZ80_REGISTER_MODE_IY = CLOWNZ80_REGISTER_MODE_IX + 1;

const
  FLAG_BIT_CARRY = 0;
  FLAG_BIT_ADD_SUBTRACT = 1;
  FLAG_BIT_PARITY_OVERFLOW = 2;
  FLAG_BIT_HALF_CARRY = 4;
  FLAG_BIT_ZERO = 6;
  FLAG_BIT_SIGN = 7;
  FLAG_MASK_CARRY = ( 1 shl FLAG_BIT_CARRY);
  FLAG_MASK_ADD_SUBTRACT = ( 1 shl FLAG_BIT_ADD_SUBTRACT);
  FLAG_MASK_PARITY_OVERFLOW = ( 1 shl FLAG_BIT_PARITY_OVERFLOW);
  FLAG_MASK_HALF_CARRY = ( 1 shl FLAG_BIT_HALF_CARRY);
  FLAG_MASK_ZERO = ( 1 shl FLAG_BIT_ZERO);
  FLAG_MASK_SIGN = ( 1 shl FLAG_BIT_SIGN);

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer((Cardinal(Value) shr Bits) or (Cardinal(-Ord(Value < 0)) shl (32 - Bits)));
end;

procedure DecodeInstructionMetadata(Metadata: PZ80InstructionMetadata; InstructionMode: Integer; RegisterMode: Integer; Opcode: Byte);
const
  Registers: array[0..7] of Integer = (CLOWNZ80_OPERAND_B, CLOWNZ80_OPERAND_C, CLOWNZ80_OPERAND_D, CLOWNZ80_OPERAND_E, CLOWNZ80_OPERAND_H, CLOWNZ80_OPERAND_L, CLOWNZ80_OPERAND_HL_INDIRECT, CLOWNZ80_OPERAND_A);
  RegisterPairs_1: array[0..3] of Integer = (CLOWNZ80_OPERAND_BC, CLOWNZ80_OPERAND_DE, CLOWNZ80_OPERAND_HL, CLOWNZ80_OPERAND_SP);
  RegisterPairs_2: array[0..3] of Integer = (CLOWNZ80_OPERAND_BC, CLOWNZ80_OPERAND_DE, CLOWNZ80_OPERAND_HL, CLOWNZ80_OPERAND_AF);
  ArithmeticLogicOpcodes: array[0..7] of Integer = (CLOWNZ80_OPCODE_ADD_A, CLOWNZ80_OPCODE_ADC_A, CLOWNZ80_OPCODE_SUB, CLOWNZ80_OPCODE_SBC_A, CLOWNZ80_OPCODE_AND, CLOWNZ80_OPCODE_XOR, CLOWNZ80_OPCODE_OR, CLOWNZ80_OPCODE_CP);
  RotateShiftOpcodes: array[0..7] of Integer = (CLOWNZ80_OPCODE_RLC, CLOWNZ80_OPCODE_RRC, CLOWNZ80_OPCODE_RL, CLOWNZ80_OPCODE_RR, CLOWNZ80_OPCODE_SLA, CLOWNZ80_OPCODE_SRA, CLOWNZ80_OPCODE_SLL, CLOWNZ80_OPCODE_SRL);
  BlockOpcodes: array[0..3] of array[0..3] of Integer = ((CLOWNZ80_OPCODE_LDI, CLOWNZ80_OPCODE_LDD, CLOWNZ80_OPCODE_LDIR, CLOWNZ80_OPCODE_LDDR), (CLOWNZ80_OPCODE_CPI, CLOWNZ80_OPCODE_CPD, CLOWNZ80_OPCODE_CPIR, CLOWNZ80_OPCODE_CPDR), (CLOWNZ80_OPCODE_INI, CLOWNZ80_OPCODE_IND, CLOWNZ80_OPCODE_INIR, CLOWNZ80_OPCODE_INDR), (CLOWNZ80_OPCODE_OUTI, CLOWNZ80_OPCODE_OUTD, CLOWNZ80_OPCODE_OTIR, CLOWNZ80_OPCODE_OTDR));
  Operands: array[0..3] of Integer = (CLOWNZ80_OPERAND_BC_INDIRECT, CLOWNZ80_OPERAND_DE_INDIRECT, CLOWNZ80_OPERAND_ADDRESS, CLOWNZ80_OPERAND_ADDRESS);
  Opcodes: array[0..7] of Integer = (CLOWNZ80_OPCODE_RLCA, CLOWNZ80_OPCODE_RRCA, CLOWNZ80_OPCODE_RLA, CLOWNZ80_OPCODE_RRA, CLOWNZ80_OPCODE_DAA, CLOWNZ80_OPCODE_CPL, CLOWNZ80_OPCODE_SCF, CLOWNZ80_OPCODE_CCF);
  InterruptModes: array[0..3] of Cardinal = (0, 0, 1, 2);
  AssortedOpcodes: array[0..7] of Integer = (CLOWNZ80_OPCODE_LD_I_A, CLOWNZ80_OPCODE_LD_R_A, CLOWNZ80_OPCODE_LD_A_I, CLOWNZ80_OPCODE_LD_A_R, CLOWNZ80_OPCODE_RRD, CLOWNZ80_OPCODE_RLD, CLOWNZ80_OPCODE_NOP, CLOWNZ80_OPCODE_NOP);
begin
  var c_x: Cardinal := Cardinal(ArithmeticShiftRight(Integer(Opcode), 6) and 3);
  var c_y: Cardinal := Cardinal(ArithmeticShiftRight(Integer(Opcode), 3) and 7);
  var c_z: Cardinal := Cardinal(ArithmeticShiftRight(Integer(Opcode), 0) and 7);
  var c_p: Cardinal := Cardinal(Cardinal(c_y shr 1) and Cardinal(3));
  var c_q: Byte := Byte(Ord(Cardinal(Cardinal(c_y) and Cardinal(1)) <> Cardinal(0)));
  Metadata^.HasDisplacement := 0;
  Metadata^.Operands[0] := CLOWNZ80_OPERAND_NONE;
  Metadata^.Operands[1] := CLOWNZ80_OPERAND_NONE;
  case InstructionMode of
    CLOWNZ80_INSTRUCTION_MODE_NORMAL:
      begin
        case c_x of
          0:
            case c_z of
              0:
                case c_y of
                  0:
                    begin
                      Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_NOP);
                    end;
                  1:
                    begin
                      Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_EX_AF_AF);
                    end;
                  2:
                    begin
                      Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_DJNZ);
                      Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                    end;
                  3:
                    begin
                      Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_JR_UNCONDITIONAL);
                      Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                    end;
                  4, 5, 6, 7:
                    begin
                      Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_JR_CONDITIONAL);
                      Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                      Metadata^.Condition := Byte(Sub32(c_y, 4));
                    end;
                end;
              1:
                if c_q = 0 then
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_16BIT);
                  Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16BIT);
                  Metadata^.Operands[1] := Byte(RegisterPairs_1[c_p]);
                end
                else
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_ADD_HL);
                  Metadata^.Operands[0] := Byte(RegisterPairs_1[c_p]);
                  Metadata^.Operands[1] := Byte(CLOWNZ80_OPERAND_HL);
                end;
              2:
                begin
                  var OperandA: Integer;
                  if c_p = 2 then
                    OperandA := CLOWNZ80_OPERAND_HL
                  else
                    OperandA := CLOWNZ80_OPERAND_A;
                  var OperandB := Operands[c_p];
                  if c_p = 2 then
                    Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_16BIT)
                  else
                    Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_8BIT);
                  if (not (c_q <> 0)) then
                  begin
                    Metadata^.Operands[0] := Byte(OperandA);
                    Metadata^.Operands[1] := Byte(OperandB);
                  end
                  else
                  begin
                    Metadata^.Operands[0] := Byte(OperandB);
                    Metadata^.Operands[1] := Byte(OperandA);
                  end;
                end;
              3:
                begin
                  if c_q = 0 then
                    Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_INC_16BIT)
                  else
                    Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_DEC_16BIT);
                  Metadata^.Operands[1] := Byte(RegisterPairs_1[c_p]);
                end;
              4:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_INC_8BIT);
                  Metadata^.Operands[1] := Byte(Registers[c_y]);
                end;
              5:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_DEC_8BIT);
                  Metadata^.Operands[1] := Byte(Registers[c_y]);
                end;
              6:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_8BIT);
                  Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                  Metadata^.Operands[1] := Byte(Registers[c_y]);
                end;
              7:
                begin
                  Metadata^.Opcode := Byte(Opcodes[c_y]);
                end;
            end;
          1:
            if (c_z = 6) and (c_y = 6) then
            begin
              Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_HALT);
            end
            else
            begin
              Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_8BIT);
              Metadata^.Operands[0] := Byte(Registers[c_z]);
              Metadata^.Operands[1] := Byte(Registers[c_y]);
            end;
          2:
            begin
              Metadata^.Opcode := Byte(ArithmeticLogicOpcodes[c_y]);
              Metadata^.Operands[0] := Byte(Registers[c_z]);
            end;
          3:
            case c_z of
              0:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_RET_CONDITIONAL);
                  Metadata^.Condition := Byte(c_y);
                end;
              1:
                if (not (c_q <> 0)) then
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_POP);
                  Metadata^.Operands[1] := Byte(RegisterPairs_2[c_p]);
                end
                else
                begin
                  case c_p of
                    0:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_RET_UNCONDITIONAL);
                      end;
                    1:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_EXX);
                      end;
                    2:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_JP_HL);
                        Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_HL);
                      end;
                    3:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_SP_HL);
                        Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_HL);
                      end;
                  end;
                end;
              2:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_JP_CONDITIONAL);
                  Metadata^.Condition := Byte(c_y);
                  Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16BIT);
                end;
              3:
                begin
                  case c_y of
                    0:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_JP_UNCONDITIONAL);
                        Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16BIT);
                      end;
                    1:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_CB_PREFIX);
                        if (Integer(RegisterMode) <> Integer(CLOWNZ80_REGISTER_MODE_HL)) then
                        begin
                          Metadata^.HasDisplacement := Byte(1);
                        end;
                      end;
                    2:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_OUT);
                        Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                      end;
                    3:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_IN);
                        Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                      end;
                    4:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_EX_SP_HL);
                        Metadata^.Operands[1] := Byte(CLOWNZ80_OPERAND_HL);
                      end;
                    5:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_EX_DE_HL);
                      end;
                    6:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_DI);
                      end;
                    7:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_EI);
                      end;
                  end;
                end;
              4:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_CALL_CONDITIONAL);
                  Metadata^.Condition := Byte(c_y);
                  Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16BIT);
                end;
              5:
                if c_q = 0 then
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_PUSH);
                  Metadata^.Operands[0] := Byte(RegisterPairs_2[c_p]);
                end
                else
                  case c_p of
                    0:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_CALL_UNCONDITIONAL);
                        Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16BIT);
                      end;
                    1:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_DD_PREFIX);
                      end;
                    2:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_ED_PREFIX);
                      end;
                    3:
                      begin
                        Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_FD_PREFIX);
                      end;
                  end;
              6:
                begin
                  Metadata^.Opcode := Byte(ArithmeticLogicOpcodes[c_y]);
                  Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8BIT);
                end;
              7:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_RST);
                  Metadata^.EmbeddedLiteral := Byte(Mul32(c_y, 8));
                end;
            end;
        end;
      end;
    CLOWNZ80_INSTRUCTION_MODE_BITS:
      case c_x of
        0:
          begin
            Metadata^.Opcode := Byte(RotateShiftOpcodes[c_y]);
            Metadata^.Operands[1] := Byte(Registers[c_z]);
          end;
        1:
          begin
            Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_BIT);
            Metadata^.Operands[1] := Byte(Registers[c_z]);
            Metadata^.EmbeddedLiteral := Byte(1 shl c_y);
          end;
        2:
          begin
            Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_RES);
            Metadata^.Operands[1] := Byte(Registers[c_z]);
            Metadata^.EmbeddedLiteral := Byte(not (1 shl c_y));
          end;
        3:
          begin
            Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_SET);
            Metadata^.Operands[1] := Byte(Registers[c_z]);
            Metadata^.EmbeddedLiteral := Byte(1 shl c_y);
          end;
      end;
    CLOWNZ80_INSTRUCTION_MODE_MISC:
      case c_x of
        0, 3:
          begin
            Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_NOP);
          end;
        1:
          begin
            case c_z of
              0:
                if c_y <> 6 then
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_IN_REGISTER)
                else
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_IN_NO_REGISTER);
              1:
                if c_y <> 6 then
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_OUT_REGISTER)
                else
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_OUT_NO_REGISTER);
              2:
                begin
                  if c_q = 0 then
                    Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_SBC_HL)
                  else
                    Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_ADC_HL);
                  Metadata^.Operands[0] := Byte(RegisterPairs_1[c_p]);
                  Metadata^.Operands[1] := Byte(CLOWNZ80_OPERAND_HL);
                end;
              3:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_LD_16BIT);
                  if c_q = 0 then
                  begin
                    Metadata^.Operands[0] := Byte(RegisterPairs_1[c_p]);
                    Metadata^.Operands[1] := Byte(CLOWNZ80_OPERAND_ADDRESS);
                  end
                  else
                  begin
                    Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_ADDRESS);
                    Metadata^.Operands[1] := Byte(RegisterPairs_1[c_p]);
                  end;
                end;
              4:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_NEG);
                  Metadata^.Operands[0] := Byte(CLOWNZ80_OPERAND_A);
                  Metadata^.Operands[1] := Byte(CLOWNZ80_OPERAND_A);
                end;
              5:
                if c_y <> 1 then
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_RETN)
                else
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_RETI);
              6:
                begin
                  Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_IM);
                  Metadata^.EmbeddedLiteral := Byte(InterruptModes[(Cardinal(c_y) and Cardinal(3))]);
                end;
              7:
                begin
                  Metadata^.Opcode := Byte(AssortedOpcodes[c_y]);
                end;
            end;
          end;
        2:
          begin
            if (c_z <= 3) and (c_y >= 4) then
              Metadata^.Opcode := Byte(BlockOpcodes[c_z][(Sub32(c_y, 4))])
            else
              Metadata^.Opcode := Byte(CLOWNZ80_OPCODE_NOP);
          end;
      end;
  end;

  var i: Cardinal := 0;
  while i < 2 do
  begin
    var OtherOperand := Cardinal(i) xor 1;
    if (Metadata^.Operands[OtherOperand] <> CLOWNZ80_OPERAND_HL_INDIRECT) and
      (Metadata^.Operands[OtherOperand] <> CLOWNZ80_OPERAND_IX_INDIRECT) and
      (Metadata^.Operands[OtherOperand] <> CLOWNZ80_OPERAND_IY_INDIRECT)
      then
      case Metadata^.Operands[i] of
        CLOWNZ80_OPERAND_H:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IXH);
            CLOWNZ80_REGISTER_MODE_IY:
              Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IYH);
          end;
        CLOWNZ80_OPERAND_L:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IXL);
            CLOWNZ80_REGISTER_MODE_IY:
              Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IYL);
          end;
        CLOWNZ80_OPERAND_HL:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IX);
            CLOWNZ80_REGISTER_MODE_IY:
              Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IY);
          end;
        CLOWNZ80_OPERAND_HL_INDIRECT:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              begin
                Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IX_INDIRECT);
                Metadata^.HasDisplacement := 1;
              end;
            CLOWNZ80_REGISTER_MODE_IY:
              begin
                Metadata^.Operands[i] := Byte(CLOWNZ80_OPERAND_IY_INDIRECT);
                Metadata^.HasDisplacement := 1;
              end;
          end;
      end;
    Inc(i);
  end;
end;

function EvaluateCondition(Flags: Byte; Condition: Integer): Boolean;
begin
  case Condition of
    CLOWNZ80_CONDITION_NOT_ZERO:
      Result := (Flags and FLAG_MASK_ZERO) = 0;
    CLOWNZ80_CONDITION_ZERO:
      Result := (Flags and FLAG_MASK_ZERO) <> 0;
    CLOWNZ80_CONDITION_NOT_CARRY:
      Result := (Flags and FLAG_MASK_CARRY) = 0;
    CLOWNZ80_CONDITION_CARRY:
      Result := (Flags and FLAG_MASK_CARRY) <> 0;
    CLOWNZ80_CONDITION_PARITY_OVERFLOW:
      Result := (Flags and FLAG_MASK_PARITY_OVERFLOW) = 0;
    CLOWNZ80_CONDITION_PARITY_EQUALITY:
      Result := (Flags and FLAG_MASK_PARITY_OVERFLOW) <> 0;
    CLOWNZ80_CONDITION_PLUS:
      Result := (Flags and FLAG_MASK_SIGN) = 0;
    CLOWNZ80_CONDITION_MINUS:
      Result := (Flags and FLAG_MASK_SIGN) <> 0;
  else
    Assert(False);
    Result := False;
  end;
end;

function MemoryRead(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  State^.Cycles := Word(State^.Cycles + 3);
  Exit(Cardinal(Callbacks^.ReadCallback(Pointer(Callbacks^.UserData), Address)));
end;

procedure MemoryWrite(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; Data: Cardinal);
begin
  State^.Cycles := Word(State^.Cycles + 3);
  Callbacks^.WriteCallback(Pointer(Callbacks^.UserData), Address, Data);
end;

function InstructionMemoryRead(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks): Cardinal;
begin
  var Data: Cardinal := Cardinal(MemoryRead(State, Callbacks, State^.ProgramCounter));
  State^.ProgramCounter := (State^.ProgramCounter + 1) and $FFFF;
  State^.ProgramCounter := Word(State^.ProgramCounter and $FFFF);
  Exit(Cardinal(Data));
end;

function OpcodeFetch(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks): Cardinal;
begin
  Inc(State^.Cycles);
  State^.R := Byte((State^.R and $80) or ((State^.R + 1) and $7F));
  Exit(Cardinal(InstructionMemoryRead(State, Callbacks)));
end;

function MemoryRead16Bit(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := Cardinal(MemoryRead(State, Callbacks, (Add32(Address, 0))));
  Value := Cardinal(Cardinal(Value) or Cardinal(MemoryRead(State, Callbacks, (Cardinal(Add32(Address, 1)) and Cardinal($FFFF))) shl 8));
  Exit(Cardinal(Value));
end;

procedure MemoryWrite16Bit(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; Value: Cardinal);
begin
  MemoryWrite(State, Callbacks, (Add32(Address, 0)), (Cardinal(Value) and Cardinal($FF)));
  MemoryWrite(State, Callbacks, (Cardinal(Add32(Address, 1)) and Cardinal($FFFF)), (Value shr 8));
end;

function ReadOperand(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction; Operand: Integer): Cardinal;
var
  Value: Cardinal;
begin
  if Instruction^.DoublePrefixMode <> 0 then
  begin
    if State^.RegisterMode = CLOWNZ80_REGISTER_MODE_IX then
      Operand := CLOWNZ80_OPERAND_IX_INDIRECT
    else
      Operand := CLOWNZ80_OPERAND_IY_INDIRECT;
  end;
  case Operand of
    CLOWNZ80_OPERAND_NONE:
      Value := Cardinal(State^.A);
    CLOWNZ80_OPERAND_A:
      Value := Cardinal(State^.A);
    CLOWNZ80_OPERAND_B:
      Value := Cardinal(State^.B);
    CLOWNZ80_OPERAND_C:
      Value := Cardinal(State^.C);
    CLOWNZ80_OPERAND_D:
      Value := Cardinal(State^.D);
    CLOWNZ80_OPERAND_E:
      Value := Cardinal(State^.E);
    CLOWNZ80_OPERAND_H:
      Value := Cardinal(State^.H);
    CLOWNZ80_OPERAND_L:
      Value := Cardinal(State^.L);
    CLOWNZ80_OPERAND_IXH:
      Value := Cardinal(State^.IXH);
    CLOWNZ80_OPERAND_IXL:
      Value := Cardinal(State^.IXL);
    CLOWNZ80_OPERAND_IYH:
      Value := Cardinal(State^.IYH);
    CLOWNZ80_OPERAND_IYL:
      Value := Cardinal(State^.IYL);
    CLOWNZ80_OPERAND_AF:
      Value := Cardinal(Cardinal(Cardinal(State^.A) shl 8) or Cardinal(State^.F));
    CLOWNZ80_OPERAND_BC:
      Value := Cardinal(Cardinal(Cardinal(State^.B) shl 8) or Cardinal(State^.C));
    CLOWNZ80_OPERAND_DE:
      Value := Cardinal(Cardinal(Cardinal(State^.D) shl 8) or Cardinal(State^.E));
    CLOWNZ80_OPERAND_HL:
      Value := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
    CLOWNZ80_OPERAND_IX:
      Value := Cardinal(Cardinal(Cardinal(State^.IXH) shl 8) or Cardinal(State^.IXL));
    CLOWNZ80_OPERAND_IY:
      Value := Cardinal(Cardinal(Cardinal(State^.IYH) shl 8) or Cardinal(State^.IYL));
    CLOWNZ80_OPERAND_PC:
      Value := Cardinal(State^.ProgramCounter);
    CLOWNZ80_OPERAND_SP:
      Value := Cardinal(State^.StackPointer);
    CLOWNZ80_OPERAND_LITERAL_8BIT, //
    CLOWNZ80_OPERAND_LITERAL_16BIT:
      Value := Cardinal(Instruction^.Literal);
    CLOWNZ80_OPERAND_BC_INDIRECT,  //
    CLOWNZ80_OPERAND_DE_INDIRECT,  //
    CLOWNZ80_OPERAND_HL_INDIRECT,  //
    CLOWNZ80_OPERAND_IX_INDIRECT,  //
    CLOWNZ80_OPERAND_IY_INDIRECT,  //
    CLOWNZ80_OPERAND_ADDRESS:
      begin
        Value := Cardinal(MemoryRead(State, Callbacks, Instruction^.Address));
        if (Integer(Instruction^.Metadata^.Opcode) = Integer(CLOWNZ80_OPCODE_LD_16BIT)) then
        begin
          Value := Cardinal(Cardinal(Value) or Cardinal(MemoryRead(State, Callbacks, (Add32(Instruction^.Address, 1))) shl 8));
        end;
      end;
  else
    Value := Cardinal(State^.A);
  end;
  Exit(Value);
end;

procedure WriteOperand(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction; Operand: Integer; Value: Cardinal);
begin
  var DoublePrefixOperand: Integer;
  if (Integer(State^.RegisterMode) = Integer(CLOWNZ80_REGISTER_MODE_IX)) then
    DoublePrefixOperand := CLOWNZ80_OPERAND_IX_INDIRECT
  else
    DoublePrefixOperand := CLOWNZ80_OPERAND_IY_INDIRECT;

  if (Instruction^.DoublePrefixMode <> 0) and (Operand <> DoublePrefixOperand) then
  begin
    WriteOperand(State, Callbacks, Instruction, DoublePrefixOperand, Value);
  end;

  case Operand of
    CLOWNZ80_OPERAND_NONE,           //
    CLOWNZ80_OPERAND_LITERAL_8BIT,   //
    CLOWNZ80_OPERAND_LITERAL_16BIT:
      ;
    CLOWNZ80_OPERAND_A:
      State^.A := Byte(Value);
    CLOWNZ80_OPERAND_B:
      State^.B := Byte(Value);
    CLOWNZ80_OPERAND_C:
      State^.C := Byte(Value);
    CLOWNZ80_OPERAND_D:
      State^.D := Byte(Value);
    CLOWNZ80_OPERAND_E:
      State^.E := Byte(Value);
    CLOWNZ80_OPERAND_H:
      State^.H := Byte(Value);
    CLOWNZ80_OPERAND_L:
      State^.L := Byte(Value);
    CLOWNZ80_OPERAND_IXH:
      State^.IXH := Byte(Value);
    CLOWNZ80_OPERAND_IXL:
      State^.IXL := Byte(Value);
    CLOWNZ80_OPERAND_IYH:
      State^.IYH := Byte(Value);
    CLOWNZ80_OPERAND_IYL:
      State^.IYL := Byte(Value);
    CLOWNZ80_OPERAND_AF:
      begin
        State^.A := Byte(Value shr 8);
        State^.F := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    CLOWNZ80_OPERAND_BC:
      begin
        State^.B := Byte(Value shr 8);
        State^.C := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    CLOWNZ80_OPERAND_DE:
      begin
        State^.D := Byte(Value shr 8);
        State^.E := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    CLOWNZ80_OPERAND_HL:
      begin
        State^.H := Byte(Value shr 8);
        State^.L := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    CLOWNZ80_OPERAND_IX:
      begin
        State^.IXH := Byte(Value shr 8);
        State^.IXL := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    CLOWNZ80_OPERAND_IY:
      begin
        State^.IYH := Byte(Value shr 8);
        State^.IYL := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    CLOWNZ80_OPERAND_PC:
      begin
        State^.ProgramCounter := Word(Value);
      end;
    CLOWNZ80_OPERAND_SP:
      begin
        State^.StackPointer := Word(Value);
      end;
    CLOWNZ80_OPERAND_BC_INDIRECT, //
    CLOWNZ80_OPERAND_DE_INDIRECT, //
    CLOWNZ80_OPERAND_HL_INDIRECT, //
    CLOWNZ80_OPERAND_IX_INDIRECT, //
    CLOWNZ80_OPERAND_IY_INDIRECT, //
    CLOWNZ80_OPERAND_ADDRESS:
      begin
        if (Integer(Instruction^.Metadata^.Opcode) = Integer(CLOWNZ80_OPCODE_LD_16BIT)) then
          MemoryWrite16Bit(State, Callbacks, Instruction^.Address, Value)
        else
          MemoryWrite(State, Callbacks, Instruction^.Address, Value);
      end;
  end;
end;

procedure DecodeInstruction(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction);
begin
  var Opcode: Cardinal := Cardinal(OpcodeFetch(State, Callbacks));
  var Displacement: Cardinal := 0;

  Instruction^.Metadata := @InstructionMetadataLookupNormal[State^.RegisterMode][Opcode];
  if (Instruction^.Metadata^.HasDisplacement <> 0) then
  begin
    Displacement := Cardinal(InstructionMemoryRead(State, Callbacks));
    Displacement := Cardinal(Sub32(Cardinal(Displacement) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(Displacement) and Cardinal(Cardinal(1) shl 7)));
    State^.Cycles := Word(State^.Cycles + 5);
  end;

  Instruction^.DoublePrefixMode := Byte(0);
  case Integer(Instruction^.Metadata^.Opcode) of
    CLOWNZ80_OPCODE_CB_PREFIX:
      if (Integer(State^.RegisterMode) = Integer(CLOWNZ80_REGISTER_MODE_HL)) then
      begin
        Opcode := Cardinal(OpcodeFetch(State, Callbacks));
        Instruction^.Metadata := @InstructionMetadataLookupBits[State^.RegisterMode][Opcode];
      end
      else
      begin
        Instruction^.DoublePrefixMode := Byte(1);
        Opcode := Cardinal(InstructionMemoryRead(State, Callbacks));
        State^.Cycles := Word(State^.Cycles - 3);
        if (Integer(State^.RegisterMode) = Integer(CLOWNZ80_REGISTER_MODE_IX)) then
        begin
          Instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(State^.IXH) shl 8) or Cardinal(State^.IXL), Displacement)) and Cardinal($FFFF));
        end
        else
        begin
          Instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(State^.IYH) shl 8) or Cardinal(State^.IYL), Displacement)) and Cardinal($FFFF));
        end;
        Instruction^.Metadata := @InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_HL][Opcode];
        if (Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) then
        begin
          Instruction^.Metadata := @InstructionMetadataLookupBits[State^.RegisterMode][Opcode];
        end;
      end;
    CLOWNZ80_OPCODE_ED_PREFIX:
      begin
        Opcode := Cardinal(OpcodeFetch(State, Callbacks));
        Instruction^.Metadata := @InstructionMetadataLookupMisc[Opcode];
      end;
  end;

  case Integer(Instruction^.Metadata^.Operands[0]) of
    CLOWNZ80_OPERAND_LITERAL_8BIT:
      begin
        Instruction^.Literal := Cardinal(InstructionMemoryRead(State, Callbacks));
        if (Instruction^.Metadata^.HasDisplacement <> 0) then
        begin
          State^.Cycles := Word(State^.Cycles - 3);
        end;
      end;
    CLOWNZ80_OPERAND_LITERAL_16BIT:
      begin
        Instruction^.Literal := Cardinal(InstructionMemoryRead(State, Callbacks));
        Instruction^.Literal := Cardinal(Cardinal(Instruction^.Literal) or Cardinal(InstructionMemoryRead(State, Callbacks) shl 8));
      end;
  end;

  for var i := 0 to 1 do
    case Integer(Instruction^.Metadata^.Operands[i]) of
      CLOWNZ80_OPERAND_BC_INDIRECT:
        Instruction^.Address := Cardinal(Cardinal(Cardinal(State^.B) shl 8) or Cardinal(State^.C));
      CLOWNZ80_OPERAND_DE_INDIRECT:
        Instruction^.Address := Cardinal(Cardinal(Cardinal(State^.D) shl 8) or Cardinal(State^.E));
      CLOWNZ80_OPERAND_HL_INDIRECT:
        Instruction^.Address := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
      CLOWNZ80_OPERAND_IX_INDIRECT:
        Instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(State^.IXH) shl 8) or Cardinal(State^.IXL), Displacement)) and Cardinal($FFFF));
      CLOWNZ80_OPERAND_IY_INDIRECT:
        Instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(State^.IYH) shl 8) or Cardinal(State^.IYL), Displacement)) and Cardinal($FFFF));
      CLOWNZ80_OPERAND_ADDRESS:
        begin
          Instruction^.Address := Cardinal(InstructionMemoryRead(State, Callbacks));
          Instruction^.Address := Cardinal(Cardinal(Instruction^.Address) or Cardinal(InstructionMemoryRead(State, Callbacks) shl 8));
        end;
    end;
end;

function ComputeParity(Value: Cardinal): Byte;
begin
  Value := Cardinal(Cardinal(Value) xor Cardinal(Value shr 4));
  Value := Cardinal(Cardinal(Value) xor Cardinal(Value shr 2));
  Value := Cardinal(Cardinal(Value) xor Cardinal(Value shr 1));
  Exit(Byte(Ord(Cardinal(Cardinal(Value) and Cardinal(1)) = Cardinal(0))));
end;

procedure ExecuteInstruction(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks; Instruction: PZ80Instruction);
var
  c_source_value: Cardinal;
  c_destination_value: Cardinal;
  c_result_value: Cardinal;
  c_result_value_with_carry: Cardinal;
  c_result_value_with_carry_16bit: Cardinal;
  c_swap_holder: Byte;
  c_carry: Byte;
  temp323: Integer;
  temp324: Integer;
  temp325: Integer;
  temp326: Integer;
  temp327: Integer;
  temp328: Integer;
  temp329: Integer;
  temp330: Integer;
  temp331: Integer;
  temp332: Integer;
  temp333: Integer;
  temp334: Integer;
  temp335: Integer;
  temp336: Integer;
  c_correction_factor: Cardinal;
  c_original_a: Cardinal;
  temp337: Integer;
  temp338: Integer;
  temp339: Integer;
  temp340: Integer;
  temp341: Integer;
  temp342: Integer;
  temp343: Integer;
  temp344: Integer;
  temp345: Integer;
  temp346: Integer;
  temp347: Integer;
  temp348: Integer;
  temp349: Integer;
  temp350: Integer;
  temp351: Integer;
  temp352: Integer;
  temp353: Integer;
  temp354: Integer;
  temp355: Integer;
  temp356: Integer;
  temp357: Integer;
  temp358: Integer;
  temp359: Integer;
  temp360: Integer;
  temp361: Integer;
  temp362: Integer;
  temp363: Integer;
  temp364: Integer;
  temp365: Integer;
  temp366: Integer;
  temp367: Integer;
  temp368: Integer;
  temp369: Integer;
  temp370: Integer;
  temp371: Integer;
  temp372: Integer;
  temp373: Integer;
  temp374: Integer;
  temp375: Integer;
  temp376: Integer;
  temp377: Integer;
  temp378: Integer;
  temp379: Integer;
  temp380: Integer;
  temp381: Integer;
  temp382: Integer;
  temp383: Integer;
  temp384: Integer;
  temp385: Integer;
  temp386: Integer;
  temp387: Integer;
  temp388: Integer;
  temp389: Integer;
  temp390: Integer;
  temp391: Integer;
  temp392: Integer;
  temp393: Integer;
  temp394: Integer;
  temp395: Integer;
  temp396: Integer;
  temp397: Integer;
  temp398: Integer;
  temp399: Integer;
  temp400: Integer;
  temp401: Integer;
  temp402: Integer;
  temp403: Integer;
  temp404: Integer;
  temp405: Integer;
  temp406: Integer;
  temp407: Integer;
  temp408: Integer;
  temp409: Integer;
  temp410: Integer;
  temp411: Integer;
  temp412: Integer;
  temp413: Integer;
  temp414: Integer;
  temp415: Integer;
  c_hl: Cardinal;
  c_hl_value: Cardinal;
  c_hl_high: Cardinal;
  c_hl_low: Cardinal;
  c_a_high: Cardinal;
  c_a_low: Cardinal;
  temp416: Integer;
  temp417: Integer;
  c_hl_scope211: Cardinal;
  c_hl_value_scope212: Cardinal;
  c_hl_high_scope213: Cardinal;
  c_hl_low_scope214: Cardinal;
  c_a_high_scope215: Cardinal;
  c_a_low_scope216: Cardinal;
  temp418: Integer;
  temp419: Integer;
  c_de: Cardinal;
  c_hl_scope217: Cardinal;
  temp420: Integer;
  c_de_scope218: Cardinal;
  c_hl_scope219: Cardinal;
  temp421: Integer;
  c_de_scope220: Cardinal;
  c_hl_scope221: Cardinal;
  temp422: Integer;
  c_de_scope222: Cardinal;
  c_hl_scope223: Cardinal;
  temp423: Integer;
  c_hl_scope224: Cardinal;
  temp424: Integer;
  temp425: Integer;
  c_hl_scope225: Cardinal;
  temp426: Integer;
  temp427: Integer;
  c_hl_scope226: Cardinal;
  temp428: Integer;
  temp429: Integer;
  temp430: Integer;
  c_hl_scope227: Cardinal;
  temp431: Integer;
  temp432: Integer;
  temp433: Integer;
begin
  State^.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_HL);
  case Instruction^.Metadata^.Opcode of
    CLOWNZ80_OPCODE_NOP:
      ;
    CLOWNZ80_OPCODE_EX_AF_AF:
      begin
        c_swap_holder := Byte(State^.A);
        State^.A := Byte(State^.AAlt);
        State^.AAlt := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.F);
        State^.F := Byte(State^.FAlt);
        State^.FAlt := Byte(c_swap_holder);
      end;
    CLOWNZ80_OPCODE_DJNZ:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.B := (State^.B + $FF) and $FF;
        State^.B := Byte(State^.B and $FF);
        if (Integer(State^.B) <> Integer(0)) then
        begin
          State^.ProgramCounter := Word(State^.ProgramCounter + (Sub32(Cardinal(Instruction^.Literal) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(Instruction^.Literal) and Cardinal(Cardinal(1) shl 7))));
          State^.ProgramCounter := Word(State^.ProgramCounter and $FFFF);
          State^.Cycles := Word(State^.Cycles + 5);
        end;
      end;
    CLOWNZ80_OPCODE_JR_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State^.F, Integer(Instruction^.Metadata^.Condition)) then
          begin
            Break;
          end;
          State^.ProgramCounter := Word(State^.ProgramCounter + (Sub32(Cardinal(Instruction^.Literal) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(Instruction^.Literal) and Cardinal(Cardinal(1) shl 7))));
          State^.ProgramCounter := Word(State^.ProgramCounter and $FFFF);
          State^.Cycles := Word(State^.Cycles + 5);
        until True;
      end;
    CLOWNZ80_OPCODE_JR_UNCONDITIONAL:
      begin
        State^.ProgramCounter := Word(State^.ProgramCounter + (Sub32(Cardinal(Instruction^.Literal) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(Instruction^.Literal) and Cardinal(Cardinal(1) shl 7))));
        State^.ProgramCounter := Word(State^.ProgramCounter and $FFFF);
        State^.Cycles := Word(State^.Cycles + 5);
      end;
    CLOWNZ80_OPCODE_LD_8BIT, CLOWNZ80_OPCODE_LD_16BIT:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_result_value := Cardinal(c_source_value);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
      end;
    CLOWNZ80_OPCODE_ADD_HL:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value_with_carry_16bit := Cardinal(Add32(Cardinal(c_source_value), Cardinal(c_destination_value)));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry_16bit) and Cardinal($FFFF));
        State^.F := Byte(State^.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry_16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        State^.Cycles := Word(State^.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_INC_16BIT:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(Cardinal(Add32(c_destination_value, 1)) and Cardinal($FFFF));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        State^.Cycles := Word(State^.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_DEC_16BIT:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(Cardinal(Sub32(c_destination_value, 1)) and Cardinal($FFFF));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        State^.Cycles := Word(State^.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_INC_8BIT:
      begin
        c_source_value := Cardinal(1);
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(Cardinal(Add32(c_destination_value, c_source_value)) and Cardinal($FF));
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));

        if c_result_value = 0 then
          State^.F := State^.F or FLAG_MASK_ZERO;
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        if (Instruction^.Metadata^.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or
          (Instruction^.Metadata^.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT) or
          (Instruction^.Metadata^.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT) then
          Inc(State^.Cycles);
      end;
    CLOWNZ80_OPCODE_DEC_8BIT:
      begin
        c_source_value := Cardinal(-1);
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(Cardinal(Add32(c_destination_value, c_source_value)) and Cardinal($FF));
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if c_result_value = 0 then
          State^.F := State^.F or FLAG_MASK_ZERO;
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F xor FLAG_MASK_HALF_CARRY);
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        if (Instruction^.Metadata^.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or
          (Instruction^.Metadata^.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT) or
          (Instruction^.Metadata^.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT) then
          Inc(State^.Cycles);
      end;
    CLOWNZ80_OPCODE_RLCA:
      begin
        c_carry := Byte(Ord(Integer(State^.A and $80) <> Integer(0)));
        State^.A := Byte(State^.A shl 1);
        State^.A := Byte(State^.A and $FF);
        if c_carry <> 0 then
          State^.A := State^.A or $01;
        State^.F := Byte(State^.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        if c_carry <> 0 then
          State^.F := State^.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_RRCA:
      begin
        c_carry := Byte(Ord(Integer(State^.A and $01) <> Integer(0)));
        State^.A := Byte(ArithmeticShiftRight(Integer(State^.A), 1));
        if c_carry <> 0 then
          State^.A := State^.A or $80;
        State^.F := Byte(State^.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        if c_carry <> 0 then
          State^.F := State^.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_RLA:
      begin
        c_carry := Byte(Ord(Integer(State^.A and $80) <> Integer(0)));
        State^.A := Byte(State^.A shl 1);
        State^.A := Byte(State^.A and $FF);
        if (State^.F and FLAG_MASK_CARRY) <> 0 then
          State^.A := State^.A or 1;
        State^.F := State^.F and (FLAG_MASK_SIGN or FLAG_MASK_ZERO or FLAG_MASK_PARITY_OVERFLOW);
        if c_carry <> 0 then
          State^.F := State^.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_RRA:
      begin
        c_carry := Byte(Ord(Integer(State^.A and $01) <> Integer(0)));
        State^.A := Byte(ArithmeticShiftRight(Integer(State^.A), 1));
        if Integer(State^.F and FLAG_MASK_CARRY) <> 0 then
          State^.A := Byte(State^.A or $80);
        State^.F := Byte(State^.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        if c_carry <> 0 then
          State^.F := State^.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_DAA:
      begin
        c_original_a := Cardinal(State^.A);
        c_correction_factor := Cardinal(((State^.A + $66) xor State^.A) and $110);
        c_correction_factor := Cardinal(Cardinal(c_correction_factor) or Cardinal((State^.F and FLAG_MASK_CARRY) shl (8 - FLAG_BIT_CARRY)));
        c_correction_factor := Cardinal(Cardinal(c_correction_factor) or Cardinal((State^.F and FLAG_MASK_HALF_CARRY) shl (4 - FLAG_BIT_HALF_CARRY)));
        c_correction_factor := Cardinal(Cardinal(c_correction_factor shr 2) or Cardinal(c_correction_factor shr 3));
        if (Integer(State^.F and FLAG_MASK_ADD_SUBTRACT) <> Integer(0)) then
        begin
          State^.A := Byte(State^.A - c_correction_factor);
        end
        else
        begin
          State^.A := Byte(State^.A + c_correction_factor);
        end;
        State^.A := Byte(State^.A and $FF);
        State^.F := Byte(State^.F and FLAG_MASK_ADD_SUBTRACT);
        State^.F := Byte(State^.F or (ArithmeticShiftRight(Integer(State^.A), (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        State^.F := Byte(State^.F or (Ord(Integer(State^.A) = Integer(0)) shl FLAG_BIT_ZERO));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(c_original_a) xor Cardinal(State^.A)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        if ComputeParity(State^.A) <> 0 then
          State^.F := State^.F or FLAG_MASK_PARITY_OVERFLOW;
        State^.F := Byte(State^.F or (Cardinal(c_correction_factor shr (6 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
      end;
    CLOWNZ80_OPCODE_CPL:
      begin
        State^.A := Byte(not State^.A);
        State^.A := Byte(State^.A and $FF);
        State^.F := Byte(State^.F or (FLAG_MASK_HALF_CARRY or FLAG_MASK_ADD_SUBTRACT));
      end;
    CLOWNZ80_OPCODE_SCF:
      begin
        State^.F := Byte(State^.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        State^.F := Byte(State^.F or FLAG_MASK_CARRY);
      end;
    CLOWNZ80_OPCODE_CCF:
      begin
        State^.F := Byte(State^.F and (not (FLAG_MASK_ADD_SUBTRACT or FLAG_MASK_HALF_CARRY)));
        if (State^.F and FLAG_MASK_CARRY) <> 0 then
          State^.F := State^.F or FLAG_MASK_HALF_CARRY;
        State^.F := Byte(State^.F xor FLAG_MASK_CARRY);
      end;
    CLOWNZ80_OPCODE_HALT:
      ;
    CLOWNZ80_OPCODE_ADD_A:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(State^.A);
        c_result_value_with_carry := Cardinal(Add32(c_destination_value, c_source_value));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if Cardinal(c_result_value) = 0 then
          State^.F := State^.F or FLAG_MASK_ZERO;
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_ADC_A:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(State^.A);
        c_result_value_with_carry := Add32(Add32(c_destination_value, c_source_value), Ord((State^.F and FLAG_MASK_CARRY) <> 0));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if Cardinal(c_result_value) = 0 then
          State^.F := State^.F or FLAG_MASK_ZERO;
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_SUB:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(State^.A);
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), 1));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if Cardinal(c_result_value) = 0 then
          State^.F := State^.F or FLAG_MASK_ZERO;
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F xor FLAG_MASK_HALF_CARRY);
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_SBC_A:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(State^.A);
        c_result_value_with_carry := Add32(Add32(c_destination_value, c_source_value), Ord((State^.F and FLAG_MASK_CARRY) = 0));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if Cardinal(c_result_value) = 0 then
          State^.F := Byte(State^.F or FLAG_MASK_ZERO);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F xor FLAG_MASK_HALF_CARRY);
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_AND:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Cardinal(c_destination_value) and Cardinal(c_source_value));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp345 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp345 := 0;
        end;
        State^.F := Byte(State^.F or temp345);
        State^.F := Byte(State^.F or FLAG_MASK_HALF_CARRY);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp346 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp346 := 0;
        end;
        State^.F := Byte(State^.F or temp346);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_XOR:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Cardinal(c_destination_value) xor Cardinal(c_source_value));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp347 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp347 := 0;
        end;
        State^.F := Byte(State^.F or temp347);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp348 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp348 := 0;
        end;
        State^.F := Byte(State^.F or temp348);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_OR:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Cardinal(c_destination_value) or Cardinal(c_source_value));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp349 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp349 := 0;
        end;
        State^.F := Byte(State^.F or temp349);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp350 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp350 := 0;
        end;
        State^.F := Byte(State^.F or temp350);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_CP:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(State^.A);
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), 1));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp351 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp351 := 0;
        end;
        State^.F := Byte(State^.F or temp351);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F xor FLAG_MASK_HALF_CARRY);
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
      end;
    CLOWNZ80_OPCODE_POP:
      begin
        c_result_value := Cardinal(MemoryRead16Bit(State, Callbacks, State^.StackPointer));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        State^.StackPointer := Word(State^.StackPointer + 2);
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
      end;
    CLOWNZ80_OPCODE_RET_CONDITIONAL:
      begin
        repeat
          State^.Cycles := Word(State^.Cycles + 1);
          if not EvaluateCondition(State^.F, Integer(Instruction^.Metadata^.Condition)) then
          begin
            Break;
          end;
          State^.ProgramCounter := Word(MemoryRead16Bit(State, Callbacks, State^.StackPointer));
          State^.StackPointer := Word(State^.StackPointer + 2);
          State^.StackPointer := Word(State^.StackPointer and $FFFF);
        until True;
      end;
    CLOWNZ80_OPCODE_RET_UNCONDITIONAL, CLOWNZ80_OPCODE_RETN, CLOWNZ80_OPCODE_RETI:
      begin
        State^.ProgramCounter := Word(MemoryRead16Bit(State, Callbacks, State^.StackPointer));
        State^.StackPointer := Word(State^.StackPointer + 2);
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
      end;
    CLOWNZ80_OPCODE_EXX:
      begin
        c_swap_holder := Byte(State^.B);
        State^.B := Byte(State^.BAlt);
        State^.BAlt := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.C);
        State^.C := Byte(State^.CAlt);
        State^.CAlt := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.D);
        State^.D := Byte(State^.DAlt);
        State^.DAlt := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.E);
        State^.E := Byte(State^.EAlt);
        State^.EAlt := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.H);
        State^.H := Byte(State^.HAlt);
        State^.HAlt := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.L);
        State^.L := Byte(State^.LAlt);
        State^.LAlt := Byte(c_swap_holder);
      end;
    CLOWNZ80_OPCODE_LD_SP_HL:
      begin
        State^.Cycles := Word(State^.Cycles + 2);
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        State^.StackPointer := Word(c_source_value);
      end;
    CLOWNZ80_OPCODE_JP_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State^.F, Integer(Instruction^.Metadata^.Condition)) then
          begin
            Break;
          end;
          c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
          State^.ProgramCounter := Word(c_source_value);
        until True;
      end;
    CLOWNZ80_OPCODE_JP_UNCONDITIONAL, CLOWNZ80_OPCODE_JP_HL:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        State^.ProgramCounter := Word(c_source_value);
      end;
    CLOWNZ80_OPCODE_CB_PREFIX, CLOWNZ80_OPCODE_ED_PREFIX:
      begin
        Assert(0 <> 0);
      end;
    CLOWNZ80_OPCODE_DD_PREFIX:
      begin
        State^.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_IX);
      end;
    CLOWNZ80_OPCODE_FD_PREFIX:
      begin
        State^.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_IY);
      end;
    CLOWNZ80_OPCODE_OUT, CLOWNZ80_OPCODE_IN:
      begin
      end;
    CLOWNZ80_OPCODE_EX_SP_HL:
      begin
        State^.Cycles := Word(State^.Cycles + 3);
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(MemoryRead16Bit(State, Callbacks, State^.StackPointer));
        MemoryWrite16Bit(State, Callbacks, State^.StackPointer, c_destination_value);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
      end;
    CLOWNZ80_OPCODE_EX_DE_HL:
      begin
        c_swap_holder := Byte(State^.D);
        State^.D := Byte(State^.H);
        State^.H := Byte(c_swap_holder);
        c_swap_holder := Byte(State^.E);
        State^.E := Byte(State^.L);
        State^.L := Byte(c_swap_holder);
      end;
    CLOWNZ80_OPCODE_DI:
      begin
        State^.InterruptsEnabled := Byte(0);
      end;
    CLOWNZ80_OPCODE_EI:
      begin
        State^.InterruptsEnabled := Byte(1);
      end;
    CLOWNZ80_OPCODE_PUSH:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
        MemoryWrite(State, Callbacks, State^.StackPointer, (c_source_value shr 8));
        State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
        MemoryWrite(State, Callbacks, State^.StackPointer, (Cardinal(c_source_value) and Cardinal($FF)));
      end;
    CLOWNZ80_OPCODE_CALL_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State^.F, Integer(Instruction^.Metadata^.Condition)) then
          begin
            Break;
          end;
          State^.Cycles := Word(State^.Cycles + 1);
          State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
          State^.StackPointer := Word(State^.StackPointer and $FFFF);
          MemoryWrite(State, Callbacks, State^.StackPointer, ArithmeticShiftRight(Integer(State^.ProgramCounter), 8));
          State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
          State^.StackPointer := Word(State^.StackPointer and $FFFF);
          MemoryWrite(State, Callbacks, State^.StackPointer, (State^.ProgramCounter and $FF));
          State^.ProgramCounter := Word(Instruction^.Literal);
        until True;
      end;
    CLOWNZ80_OPCODE_CALL_UNCONDITIONAL:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
        MemoryWrite(State, Callbacks, State^.StackPointer, ArithmeticShiftRight(Integer(State^.ProgramCounter), 8));
        State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
        MemoryWrite(State, Callbacks, State^.StackPointer, (State^.ProgramCounter and $FF));
        State^.ProgramCounter := Word(Instruction^.Literal);
      end;
    CLOWNZ80_OPCODE_RST:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
        MemoryWrite(State, Callbacks, State^.StackPointer, ArithmeticShiftRight(Integer(State^.ProgramCounter), 8));
        State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
        State^.StackPointer := Word(State^.StackPointer and $FFFF);
        MemoryWrite(State, Callbacks, State^.StackPointer, (State^.ProgramCounter and $FF));
        State^.ProgramCounter := Word(Instruction^.Metadata^.EmbeddedLiteral);
      end;
    CLOWNZ80_OPCODE_RLC:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shl 1) and Cardinal($FF));
        if (c_carry <> 0) then
        begin
          temp352 := $01;
        end
        else
        begin
          temp352 := 0;
        end;
        c_result_value := Cardinal(Cardinal(c_result_value) or Cardinal(temp352));
        State^.F := Byte(0);
        if (c_carry <> 0) then
        begin
          temp353 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp353 := 0;
        end;
        State^.F := Byte(State^.F or temp353);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp354 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp354 := 0;
        end;
        State^.F := Byte(State^.F or temp354);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp355 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp355 := 0;
        end;
        State^.F := Byte(State^.F or temp355);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp357 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp357 = 0 then
        begin
          temp357 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp356 := Ord(temp357 <> 0);
        if temp356 = 0 then
        begin
          temp356 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp356);
      end;
    CLOWNZ80_OPCODE_RRC:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(c_destination_value shr 1);
        if (c_carry <> 0) then
        begin
          temp358 := $80;
        end
        else
        begin
          temp358 := 0;
        end;
        c_result_value := Cardinal(Cardinal(c_result_value) or Cardinal(temp358));
        State^.F := Byte(0);
        if (c_carry <> 0) then
        begin
          temp359 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp359 := 0;
        end;
        State^.F := Byte(State^.F or temp359);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp360 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp360 := 0;
        end;
        State^.F := Byte(State^.F or temp360);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp361 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp361 := 0;
        end;
        State^.F := Byte(State^.F or temp361);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp363 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp363 = 0 then
        begin
          temp363 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp362 := Ord(temp363 <> 0);
        if temp362 = 0 then
        begin
          temp362 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp362);
      end;
    CLOWNZ80_OPCODE_RL:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shl 1) and Cardinal($FF));
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Integer(State^.F) <> Integer(0)) then
        begin
          temp364 := $01;
        end
        else
        begin
          temp364 := 0;
        end;
        c_result_value := Cardinal(Cardinal(c_result_value) or Cardinal(temp364));
        State^.F := Byte(0);
        if (c_carry <> 0) then
        begin
          temp365 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp365 := 0;
        end;
        State^.F := Byte(State^.F or temp365);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp366 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp366 := 0;
        end;
        State^.F := Byte(State^.F or temp366);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp367 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp367 := 0;
        end;
        State^.F := Byte(State^.F or temp367);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp369 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp369 = 0 then
        begin
          temp369 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp368 := Ord(temp369 <> 0);
        if temp368 = 0 then
        begin
          temp368 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp368);
      end;
    CLOWNZ80_OPCODE_RR:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(c_destination_value shr 1);
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Integer(State^.F) <> Integer(0)) then
        begin
          temp370 := $80;
        end
        else
        begin
          temp370 := 0;
        end;
        c_result_value := Cardinal(Cardinal(c_result_value) or Cardinal(temp370));
        State^.F := Byte(0);
        if (c_carry <> 0) then
        begin
          temp371 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp371 := 0;
        end;
        State^.F := Byte(State^.F or temp371);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp372 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp372 := 0;
        end;
        State^.F := Byte(State^.F or temp372);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp373 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp373 := 0;
        end;
        State^.F := Byte(State^.F or temp373);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp375 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp375 = 0 then
        begin
          temp375 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp374 := Ord(temp375 <> 0);
        if temp374 = 0 then
        begin
          temp374 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp374);
      end;
    CLOWNZ80_OPCODE_SLA:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shl 1) and Cardinal($FF));
        State^.F := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp376 := FLAG_MASK_SIGN;
        end
        else
        begin
          temp376 := 0;
        end;
        State^.F := Byte(State^.F or temp376);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp377 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp377 := 0;
        end;
        State^.F := Byte(State^.F or temp377);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp378 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp378 := 0;
        end;
        State^.F := Byte(State^.F or temp378);
        if (c_carry <> 0) then
        begin
          temp379 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp379 := 0;
        end;
        State^.F := Byte(State^.F or temp379);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp381 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp381 = 0 then
        begin
          temp381 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp380 := Ord(temp381 <> 0);
        if temp380 = 0 then
        begin
          temp380 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp380);
      end;
    CLOWNZ80_OPCODE_SLL:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(Cardinal(c_destination_value shl 1) or Cardinal(1)) and Cardinal($FF));
        State^.F := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp382 := FLAG_MASK_SIGN;
        end
        else
        begin
          temp382 := 0;
        end;
        State^.F := Byte(State^.F or temp382);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp383 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp383 := 0;
        end;
        State^.F := Byte(State^.F or temp383);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp384 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp384 := 0;
        end;
        State^.F := Byte(State^.F or temp384);
        if (c_carry <> 0) then
        begin
          temp385 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp385 := 0;
        end;
        State^.F := Byte(State^.F or temp385);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp387 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp387 = 0 then
        begin
          temp387 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp386 := Ord(temp387 <> 0);
        if temp386 = 0 then
        begin
          temp386 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp386);
      end;
    CLOWNZ80_OPCODE_SRA:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shr 1) or Cardinal(Cardinal(c_destination_value) and Cardinal($80)));
        State^.F := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp388 := FLAG_MASK_SIGN;
        end
        else
        begin
          temp388 := 0;
        end;
        State^.F := Byte(State^.F or temp388);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp389 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp389 := 0;
        end;
        State^.F := Byte(State^.F or temp389);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp390 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp390 := 0;
        end;
        State^.F := Byte(State^.F or temp390);
        if (c_carry <> 0) then
        begin
          temp391 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp391 := 0;
        end;
        State^.F := Byte(State^.F or temp391);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp393 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp393 = 0 then
        begin
          temp393 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp392 := Ord(temp393 <> 0);
        if temp392 = 0 then
        begin
          temp392 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp392);
      end;
    CLOWNZ80_OPCODE_SRL:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(c_destination_value shr 1);
        State^.F := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp394 := FLAG_MASK_SIGN;
        end
        else
        begin
          temp394 := 0;
        end;
        State^.F := Byte(State^.F or temp394);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp395 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp395 := 0;
        end;
        State^.F := Byte(State^.F or temp395);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp396 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp396 := 0;
        end;
        State^.F := Byte(State^.F or temp396);
        if (c_carry <> 0) then
        begin
          temp397 := FLAG_MASK_CARRY;
        end
        else
        begin
          temp397 := 0;
        end;
        State^.F := Byte(State^.F or temp397);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp399 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp399 = 0 then
        begin
          temp399 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp398 := Ord(temp399 <> 0);
        if temp398 = 0 then
        begin
          temp398 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp398);
      end;
    CLOWNZ80_OPCODE_BIT:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Cardinal(Cardinal(c_destination_value) and Cardinal(Instruction^.Metadata^.EmbeddedLiteral)) = Cardinal(0)) then
        begin
          temp400 := (FLAG_MASK_ZERO or FLAG_MASK_PARITY_OVERFLOW);
        end
        else
        begin
          temp400 := 0;
        end;
        State^.F := Byte(State^.F or temp400);
        State^.F := Byte(State^.F or FLAG_MASK_HALF_CARRY);
        temp402 := Ord(Integer(Instruction^.Metadata^.EmbeddedLiteral) = Integer($80));
        if temp402 <> 0 then
        begin
          temp402 := Ord(Integer(State^.F and FLAG_MASK_ZERO) = Integer(0));
        end;
        if (temp402 <> 0) then
        begin
          temp401 := FLAG_MASK_SIGN;
        end
        else
        begin
          temp401 := 0;
        end;
        State^.F := Byte(State^.F or temp401);
        temp404 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp404 = 0 then
        begin
          temp404 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp403 := Ord(temp404 <> 0);
        if temp403 = 0 then
        begin
          temp403 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp403);
      end;
    CLOWNZ80_OPCODE_RES:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(Cardinal(c_destination_value) and Cardinal(Instruction^.Metadata^.EmbeddedLiteral));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp406 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp406 = 0 then
        begin
          temp406 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp405 := Ord(temp406 <> 0);
        if temp405 = 0 then
        begin
          temp405 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp405);
      end;
    CLOWNZ80_OPCODE_SET:
      begin
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_result_value := Cardinal(Cardinal(c_destination_value) or Cardinal(Instruction^.Metadata^.EmbeddedLiteral));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        temp408 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp408 = 0 then
        begin
          temp408 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp407 := Ord(temp408 <> 0);
        if temp407 = 0 then
        begin
          temp407 := Ord(Integer(Instruction^.Metadata^.Operands[1]) = Integer(CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        State^.Cycles := Word(State^.Cycles + temp407);
      end;
    CLOWNZ80_OPCODE_IN_REGISTER, CLOWNZ80_OPCODE_IN_NO_REGISTER, CLOWNZ80_OPCODE_OUT_REGISTER, CLOWNZ80_OPCODE_OUT_NO_REGISTER:
      begin
      end;
    CLOWNZ80_OPCODE_SBC_HL:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        c_source_value := Cardinal(not Cardinal(c_source_value));
        if (Integer(State^.F and FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp409 := 0;
        end
        else
        begin
          temp409 := 1;
        end;
        c_result_value_with_carry_16bit := Cardinal(Add32(Add32(Cardinal(c_source_value), Cardinal(c_destination_value)), temp409));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry_16bit) and Cardinal($FFFF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (15 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp410 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp410 := 0;
        end;
        State^.F := Byte(State^.F or temp410);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (15 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry_16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F xor FLAG_MASK_HALF_CARRY);
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        State^.Cycles := Word(State^.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_ADC_HL:
      begin
        c_source_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[0])));
        c_destination_value := Cardinal(ReadOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1])));
        if (Integer(State^.F and FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp411 := 1;
        end
        else
        begin
          temp411 := 0;
        end;
        c_result_value_with_carry_16bit := Cardinal(Add32(Add32(Cardinal(c_source_value), Cardinal(c_destination_value)), temp411));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry_16bit) and Cardinal($FFFF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (15 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp412 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp412 := 0;
        end;
        State^.F := Byte(State^.F or temp412);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (15 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry_16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        WriteOperand(State, Callbacks, Instruction, Integer(Instruction^.Metadata^.Operands[1]), c_result_value);
        State^.Cycles := Word(State^.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_NEG:
      begin
        c_source_value := Cardinal(State^.A);
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(0);
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), 1));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        State^.F := Byte(0);
        State^.F := Byte(State^.F or (Cardinal(c_result_value_with_carry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp413 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp413 := 0;
        end;
        State^.F := Byte(State^.F or temp413);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State^.F := Byte(State^.F xor FLAG_MASK_HALF_CARRY);
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_IM:
      begin
      end;
    CLOWNZ80_OPCODE_LD_I_A:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.i := Byte(State^.A);
      end;
    CLOWNZ80_OPCODE_LD_R_A:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.R := Byte(State^.A);
      end;
    CLOWNZ80_OPCODE_LD_A_I:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.A := Byte(State^.i);
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        State^.F := Byte(State^.F or (ArithmeticShiftRight(Integer(State^.A), (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        if (Integer(State^.A) = Integer(0)) then
        begin
          temp414 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp414 := 0;
        end;
        State^.F := Byte(State^.F or temp414);
      end;
    CLOWNZ80_OPCODE_LD_A_R:
      begin
        State^.Cycles := Word(State^.Cycles + 1);
        State^.A := Byte(State^.R);
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        State^.F := Byte(State^.F or (ArithmeticShiftRight(Integer(State^.A), (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        if (Integer(State^.A) = Integer(0)) then
        begin
          temp415 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp415 := 0;
        end;
        State^.F := Byte(State^.F or temp415);
      end;
    CLOWNZ80_OPCODE_RRD:
      begin
        c_hl := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        c_hl_value := Cardinal(MemoryRead(State, Callbacks, c_hl));
        c_hl_high := Cardinal(Cardinal(c_hl_value shr 4) and Cardinal($F));
        c_hl_low := Cardinal(Cardinal(c_hl_value shr 0) and Cardinal($F));
        c_a_high := Cardinal(ArithmeticShiftRight(Integer(State^.A), 4) and $F);
        c_a_low := Cardinal(ArithmeticShiftRight(Integer(State^.A), 0) and $F);
        State^.Cycles := Word(State^.Cycles + 4);
        MemoryWrite(State, Callbacks, c_hl, (Cardinal(c_a_low shl 4) or Cardinal(c_hl_high shl 0)));
        c_result_value := Cardinal(Cardinal(c_a_high shl 4) or Cardinal(c_hl_low shl 0));
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp416 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp416 := 0;
        end;
        State^.F := Byte(State^.F or temp416);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp417 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp417 := 0;
        end;
        State^.F := Byte(State^.F or temp417);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_RLD:
      begin
        c_hl_scope211 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        c_hl_value_scope212 := Cardinal(MemoryRead(State, Callbacks, c_hl_scope211));
        c_hl_high_scope213 := Cardinal(Cardinal(c_hl_value_scope212 shr 4) and Cardinal($F));
        c_hl_low_scope214 := Cardinal(Cardinal(c_hl_value_scope212 shr 0) and Cardinal($F));
        c_a_high_scope215 := Cardinal(ArithmeticShiftRight(Integer(State^.A), 4) and $F);
        c_a_low_scope216 := Cardinal(ArithmeticShiftRight(Integer(State^.A), 0) and $F);
        State^.Cycles := Word(State^.Cycles + 4);
        MemoryWrite(State, Callbacks, c_hl_scope211, (Cardinal(c_hl_low_scope214 shl 4) or Cardinal(c_a_low_scope216 shl 0)));
        c_result_value := Cardinal(Cardinal(c_a_high_scope215 shl 4) or Cardinal(c_hl_high_scope213 shl 0));
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp418 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp418 := 0;
        end;
        State^.F := Byte(State^.F or temp418);
        if (ComputeParity(c_result_value) <> 0) then
        begin
          temp419 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp419 := 0;
        end;
        State^.F := Byte(State^.F or temp419);
        State^.A := Byte(c_result_value);
      end;
    CLOWNZ80_OPCODE_LDI:
      begin
        c_de := Cardinal(Cardinal(Cardinal(State^.D) shl 8) or Cardinal(State^.E));
        c_hl_scope217 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        MemoryWrite(State, Callbacks, c_de, MemoryRead(State, Callbacks, c_hl_scope217));
        State^.L := (State^.L + 1) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer(0)) then
        begin
          State^.H := (State^.H + 1) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.E := (State^.E + 1) and $FF;
        State^.E := Byte(State^.E and $FF);
        if (Integer(State^.E) = Integer(0)) then
        begin
          State^.D := (State^.D + 1) and $FF;
          State^.D := Byte(State^.D and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp420 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp420 := 0;
        end;
        State^.F := Byte(State^.F or temp420);
        State^.Cycles := Word(State^.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_LDD:
      begin
        c_de_scope218 := Cardinal(Cardinal(Cardinal(State^.D) shl 8) or Cardinal(State^.E));
        c_hl_scope219 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        MemoryWrite(State, Callbacks, c_de_scope218, MemoryRead(State, Callbacks, c_hl_scope219));
        State^.L := (State^.L + $FF) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer($FF)) then
        begin
          State^.H := (State^.H + $FF) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.E := (State^.E + $FF) and $FF;
        State^.E := Byte(State^.E and $FF);
        if (Integer(State^.E) = Integer($FF)) then
        begin
          State^.D := (State^.D + $FF) and $FF;
          State^.D := Byte(State^.D and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp421 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp421 := 0;
        end;
        State^.F := Byte(State^.F or temp421);
        State^.Cycles := Word(State^.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_LDIR:
      begin
        c_de_scope220 := Cardinal(Cardinal(Cardinal(State^.D) shl 8) or Cardinal(State^.E));
        c_hl_scope221 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        MemoryWrite(State, Callbacks, c_de_scope220, MemoryRead(State, Callbacks, c_hl_scope221));
        State^.L := (State^.L + 1) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer(0)) then
        begin
          State^.H := (State^.H + 1) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.E := (State^.E + 1) and $FF;
        State^.E := Byte(State^.E and $FF);
        if (Integer(State^.E) = Integer(0)) then
        begin
          State^.D := (State^.D + 1) and $FF;
          State^.D := Byte(State^.D and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp422 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp422 := 0;
        end;
        State^.F := Byte(State^.F or temp422);
        State^.Cycles := Word(State^.Cycles + 2);
        if (Integer(State^.F and FLAG_MASK_PARITY_OVERFLOW) <> Integer(0)) then
        begin
          State^.Cycles := Word(State^.Cycles + 5);
          State^.ProgramCounter := Word(State^.ProgramCounter - 2);
        end;
      end;
    CLOWNZ80_OPCODE_LDDR:
      begin
        c_de_scope222 := Cardinal(Cardinal(Cardinal(State^.D) shl 8) or Cardinal(State^.E));
        c_hl_scope223 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        MemoryWrite(State, Callbacks, c_de_scope222, MemoryRead(State, Callbacks, c_hl_scope223));
        State^.L := (State^.L + $FF) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer($FF)) then
        begin
          State^.H := (State^.H + $FF) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.E := (State^.E + $FF) and $FF;
        State^.E := Byte(State^.E and $FF);
        if (Integer(State^.E) = Integer($FF)) then
        begin
          State^.D := (State^.D + $FF) and $FF;
          State^.D := Byte(State^.D and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp423 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp423 := 0;
        end;
        State^.F := Byte(State^.F or temp423);
        State^.Cycles := Word(State^.Cycles + 2);
        if (Integer(State^.F and FLAG_MASK_PARITY_OVERFLOW) <> Integer(0)) then
        begin
          State^.Cycles := Word(State^.Cycles + 5);
          State^.ProgramCounter := Word(State^.ProgramCounter - 2);
        end;
      end;
    CLOWNZ80_OPCODE_CPI:
      begin
        c_hl_scope224 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        c_source_value := Cardinal(MemoryRead(State, Callbacks, c_hl_scope224));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        State^.L := (State^.L + 1) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer(0)) then
        begin
          State^.H := (State^.H + 1) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp424 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp424 := 0;
        end;
        State^.F := Byte(State^.F or temp424);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp425 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp425 := 0;
        end;
        State^.F := Byte(State^.F or temp425);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.Cycles := Word(State^.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_CPD:
      begin
        c_hl_scope225 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        c_source_value := Cardinal(MemoryRead(State, Callbacks, c_hl_scope225));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        State^.L := (State^.L + $FF) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer($FF)) then
        begin
          State^.H := (State^.H + $FF) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp426 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp426 := 0;
        end;
        State^.F := Byte(State^.F or temp426);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp427 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp427 := 0;
        end;
        State^.F := Byte(State^.F or temp427);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.Cycles := Word(State^.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_CPIR:
      begin
        c_hl_scope226 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        c_source_value := Cardinal(MemoryRead(State, Callbacks, c_hl_scope226));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        State^.L := (State^.L + 1) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer(0)) then
        begin
          State^.H := (State^.H + 1) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp428 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp428 := 0;
        end;
        State^.F := Byte(State^.F or temp428);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp429 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp429 := 0;
        end;
        State^.F := Byte(State^.F or temp429);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.Cycles := Word(State^.Cycles + 2);
        temp430 := Ord(Integer(State^.F and FLAG_MASK_PARITY_OVERFLOW) <> Integer(0));
        if temp430 <> 0 then
        begin
          temp430 := Ord(Integer(State^.F and FLAG_MASK_ZERO) = Integer(0));
        end;
        if (temp430 <> 0) then
        begin
          State^.Cycles := Word(State^.Cycles + 5);
          State^.ProgramCounter := Word(State^.ProgramCounter - 2);
        end;
      end;
    CLOWNZ80_OPCODE_CPDR:
      begin
        c_hl_scope227 := Cardinal(Cardinal(Cardinal(State^.H) shl 8) or Cardinal(State^.L));
        c_source_value := Cardinal(MemoryRead(State, Callbacks, c_hl_scope227));
        c_destination_value := Cardinal(State^.A);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        State^.L := (State^.L + $FF) and $FF;
        State^.L := Byte(State^.L and $FF);
        if (Integer(State^.L) = Integer($FF)) then
        begin
          State^.H := (State^.H + $FF) and $FF;
          State^.H := Byte(State^.H and $FF);
        end;
        State^.C := (State^.C + $FF) and $FF;
        State^.C := Byte(State^.C and $FF);
        if (Integer(State^.C) = Integer($FF)) then
        begin
          State^.B := (State^.B + $FF) and $FF;
          State^.B := Byte(State^.B and $FF);
        end;
        State^.F := Byte(State^.F and FLAG_MASK_CARRY);
        if (Integer(State^.B or State^.C) <> Integer(0)) then
        begin
          temp431 := FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp431 := 0;
        end;
        State^.F := Byte(State^.F or temp431);
        State^.F := Byte(State^.F or (Cardinal(c_result_value shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp432 := FLAG_MASK_ZERO;
        end
        else
        begin
          temp432 := 0;
        end;
        State^.F := Byte(State^.F or temp432);
        State^.F := Byte(State^.F or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State^.F := Byte(State^.F or FLAG_MASK_ADD_SUBTRACT);
        State^.Cycles := Word(State^.Cycles + 2);
        temp433 := Ord(Integer(State^.F and FLAG_MASK_PARITY_OVERFLOW) <> Integer(0));
        if temp433 <> 0 then
        begin
          temp433 := Ord(Integer(State^.F and FLAG_MASK_ZERO) = Integer(0));
        end;
        if (temp433 <> 0) then
        begin
          State^.Cycles := Word(State^.Cycles + 5);
          State^.ProgramCounter := Word(State^.ProgramCounter - 2);
        end;
      end;
    CLOWNZ80_OPCODE_INI,  //
    CLOWNZ80_OPCODE_IND,  //
    CLOWNZ80_OPCODE_INIR, //
    CLOWNZ80_OPCODE_INDR, //
    CLOWNZ80_OPCODE_OUTI, //
    CLOWNZ80_OPCODE_OUTD, //
    CLOWNZ80_OPCODE_OTIR, //
    CLOWNZ80_OPCODE_OTDR: //
      ;
  end;
end;

procedure ConstantInitialise();
begin
  var i: Cardinal := 0;
  while (Cardinal(i) < Cardinal($100)) do
  begin
    DecodeInstructionMetadata(@InstructionMetadataLookupNormal[CLOWNZ80_REGISTER_MODE_HL][i], CLOWNZ80_INSTRUCTION_MODE_NORMAL, CLOWNZ80_REGISTER_MODE_HL, i);
    DecodeInstructionMetadata(@InstructionMetadataLookupNormal[CLOWNZ80_REGISTER_MODE_IX][i], CLOWNZ80_INSTRUCTION_MODE_NORMAL, CLOWNZ80_REGISTER_MODE_IX, i);
    DecodeInstructionMetadata(@InstructionMetadataLookupNormal[CLOWNZ80_REGISTER_MODE_IY][i], CLOWNZ80_INSTRUCTION_MODE_NORMAL, CLOWNZ80_REGISTER_MODE_IY, i);
    DecodeInstructionMetadata(@InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_HL][i], CLOWNZ80_INSTRUCTION_MODE_BITS, CLOWNZ80_REGISTER_MODE_HL, i);
    DecodeInstructionMetadata(@InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_IX][i], CLOWNZ80_INSTRUCTION_MODE_BITS, CLOWNZ80_REGISTER_MODE_IX, i);
    DecodeInstructionMetadata(@InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_IY][i], CLOWNZ80_INSTRUCTION_MODE_BITS, CLOWNZ80_REGISTER_MODE_IY, i);
    DecodeInstructionMetadata(@InstructionMetadataLookupMisc[i], CLOWNZ80_INSTRUCTION_MODE_MISC, CLOWNZ80_REGISTER_MODE_HL, i);
    Inc(i);
  end;
end;

procedure Z80StateInitialise(State: PZ80State);
begin
  Z80Reset(State);
  State^.Cycles := Word(1);
end;

procedure Z80Reset(State: PZ80State);
begin
  State^.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_HL);
  State^.ProgramCounter := Word(0);
  State^.InterruptsEnabled := Byte(0);
  State^.InterruptPending := Byte(0);
end;

procedure Z80Interrupt(State: PZ80State; AssertInterrupt: Byte);
begin
  State^.InterruptPending := Byte(AssertInterrupt);
end;

function Z80DoInstruction(State: PZ80State; Callbacks: PZ80ReadAndWriteCallbacks): Cardinal;
var
  Instruction: TZ80Instruction;
begin
  State^.Cycles := Word(0);
  DecodeInstruction(State, Callbacks, @Instruction);
  ExecuteInstruction(State, Callbacks, @Instruction);
  var temp439: Integer := Ord(State^.InterruptPending <> 0);
  if temp439 <> 0 then
  begin
    temp439 := Ord(State^.InterruptsEnabled <> 0);
  end;
  var temp438: Integer := Ord(temp439 <> 0);
  if temp438 <> 0 then
  begin
    temp438 := Ord(Integer(Instruction.Metadata^.Opcode) <> Integer(CLOWNZ80_OPCODE_DD_PREFIX));
  end;
  var temp437: Integer := Ord(temp438 <> 0);
  if temp437 <> 0 then
  begin
    temp437 := Ord(Integer(Instruction.Metadata^.Opcode) <> Integer(CLOWNZ80_OPCODE_FD_PREFIX));
  end;
  var temp436: Integer := Ord(temp437 <> 0);
  if temp436 <> 0 then
  begin
    temp436 := Ord(Integer(Instruction.Metadata^.Opcode) <> Integer(CLOWNZ80_OPCODE_EI));
  end;
  if (temp436 <> 0) then
  begin
    State^.InterruptsEnabled := Byte(0);
    State^.InterruptPending := Byte(0);
    State^.Cycles := Word(State^.Cycles + 13);
    State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
    State^.StackPointer := Word(State^.StackPointer and $FFFF);
    Callbacks^.WriteCallback(Pointer(Callbacks^.UserData), State^.StackPointer, ArithmeticShiftRight(Integer(State^.ProgramCounter), 8));
    State^.StackPointer := (State^.StackPointer + $FFFF) and $FFFF;
    State^.StackPointer := Word(State^.StackPointer and $FFFF);
    Callbacks^.WriteCallback(Pointer(Callbacks^.UserData), State^.StackPointer, (State^.ProgramCounter and $FF));
    State^.ProgramCounter := Word($38);
  end;
  Exit(Cardinal(State^.Cycles));
end;

end.

