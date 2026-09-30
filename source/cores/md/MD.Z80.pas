unit MD.Z80;

{$Q+}
{$R+}

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
    I: Byte;
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

  TZ80Instruction = record
    Metadata: TZ80InstructionMetadata;
    Literal: Cardinal;
    Address: Cardinal;
    DoublePrefixMode: Byte;
  end;

procedure ConstantInitialise;

procedure Z80StateInitialise(var State: TZ80State);

procedure Z80Reset(var State: TZ80State);

procedure Z80Interrupt(var State: TZ80State; AssertInterrupt: Byte);

function Z80DoInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks): Cardinal;

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
  CLOWNZ80_OPCODE_LD_16_BIT = CLOWNZ80_OPCODE_JR_CONDITIONAL + 1;
  CLOWNZ80_OPCODE_ADD_HL = CLOWNZ80_OPCODE_LD_16_BIT + 1;
  CLOWNZ80_OPCODE_LD_8_BIT = CLOWNZ80_OPCODE_ADD_HL + 1;
  CLOWNZ80_OPCODE_INC_16_BIT = CLOWNZ80_OPCODE_LD_8_BIT + 1;
  CLOWNZ80_OPCODE_DEC_16_BIT = CLOWNZ80_OPCODE_INC_16_BIT + 1;
  CLOWNZ80_OPCODE_INC_8_BIT = CLOWNZ80_OPCODE_DEC_16_BIT + 1;
  CLOWNZ80_OPCODE_DEC_8_BIT = CLOWNZ80_OPCODE_INC_8_BIT + 1;
  CLOWNZ80_OPCODE_RLCA = CLOWNZ80_OPCODE_DEC_8_BIT + 1;
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
  CLOWNZ80_OPERAND_LITERAL_8_BIT = CLOWNZ80_OPERAND_ADDRESS + 1;
  CLOWNZ80_OPERAND_LITERAL_16_BIT = CLOWNZ80_OPERAND_LITERAL_8_BIT + 1;

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

procedure DecodeInstructionMetadata(var Metadata: TZ80InstructionMetadata; InstructionMode: Integer; RegisterMode: Integer; Opcode: Byte);
const
  REGISTERS: array[0..7] of Integer = (CLOWNZ80_OPERAND_B, CLOWNZ80_OPERAND_C, CLOWNZ80_OPERAND_D, CLOWNZ80_OPERAND_E, CLOWNZ80_OPERAND_H, CLOWNZ80_OPERAND_L, CLOWNZ80_OPERAND_HL_INDIRECT, CLOWNZ80_OPERAND_A);
  REGISTER_PAIRS_1: array[0..3] of Integer = (CLOWNZ80_OPERAND_BC, CLOWNZ80_OPERAND_DE, CLOWNZ80_OPERAND_HL, CLOWNZ80_OPERAND_SP);
  REGISTER_PAIRS_2: array[0..3] of Integer = (CLOWNZ80_OPERAND_BC, CLOWNZ80_OPERAND_DE, CLOWNZ80_OPERAND_HL, CLOWNZ80_OPERAND_AF);
  ARITHMETIC_LOGIC_OPCODES: array[0..7] of Integer = (CLOWNZ80_OPCODE_ADD_A, CLOWNZ80_OPCODE_ADC_A, CLOWNZ80_OPCODE_SUB, CLOWNZ80_OPCODE_SBC_A, CLOWNZ80_OPCODE_AND, CLOWNZ80_OPCODE_XOR, CLOWNZ80_OPCODE_OR, CLOWNZ80_OPCODE_CP);
  ROTATE_SHIFT_OPCODES: array[0..7] of Integer = (CLOWNZ80_OPCODE_RLC, CLOWNZ80_OPCODE_RRC, CLOWNZ80_OPCODE_RL, CLOWNZ80_OPCODE_RR, CLOWNZ80_OPCODE_SLA, CLOWNZ80_OPCODE_SRA, CLOWNZ80_OPCODE_SLL, CLOWNZ80_OPCODE_SRL);
  BLOCK_OPCODES: array[0..3] of array[0..3] of Integer = ((CLOWNZ80_OPCODE_LDI, CLOWNZ80_OPCODE_LDD, CLOWNZ80_OPCODE_LDIR, CLOWNZ80_OPCODE_LDDR), (CLOWNZ80_OPCODE_CPI, CLOWNZ80_OPCODE_CPD, CLOWNZ80_OPCODE_CPIR, CLOWNZ80_OPCODE_CPDR), (CLOWNZ80_OPCODE_INI, CLOWNZ80_OPCODE_IND, CLOWNZ80_OPCODE_INIR, CLOWNZ80_OPCODE_INDR), (CLOWNZ80_OPCODE_OUTI, CLOWNZ80_OPCODE_OUTD, CLOWNZ80_OPCODE_OTIR, CLOWNZ80_OPCODE_OTDR));
  OPERANDS: array[0..3] of Integer = (CLOWNZ80_OPERAND_BC_INDIRECT, CLOWNZ80_OPERAND_DE_INDIRECT, CLOWNZ80_OPERAND_ADDRESS, CLOWNZ80_OPERAND_ADDRESS);
  OPCODES: array[0..7] of Integer = (CLOWNZ80_OPCODE_RLCA, CLOWNZ80_OPCODE_RRCA, CLOWNZ80_OPCODE_RLA, CLOWNZ80_OPCODE_RRA, CLOWNZ80_OPCODE_DAA, CLOWNZ80_OPCODE_CPL, CLOWNZ80_OPCODE_SCF, CLOWNZ80_OPCODE_CCF);
  INTERRUPT_MODES: array[0..3] of Cardinal = (0, 0, 1, 2);
  ASSORTED_OPCODES: array[0..7] of Integer = (CLOWNZ80_OPCODE_LD_I_A, CLOWNZ80_OPCODE_LD_R_A, CLOWNZ80_OPCODE_LD_A_I, CLOWNZ80_OPCODE_LD_A_R, CLOWNZ80_OPCODE_RRD, CLOWNZ80_OPCODE_RLD, CLOWNZ80_OPCODE_NOP, CLOWNZ80_OPCODE_NOP);
begin
  var X: Cardinal := Cardinal(ArithmeticShiftRight(Opcode, 6) and 3);
  var Y: Cardinal := Cardinal(ArithmeticShiftRight(Opcode, 3) and 7);
  var Z: Cardinal := Cardinal(ArithmeticShiftRight(Opcode, 0) and 7);
  var P: Cardinal := (Y shr 1) and 3;
  var Q: Byte := Ord((Y and 1) <> 0);
  Metadata.HasDisplacement := 0;
  Metadata.Operands[0] := CLOWNZ80_OPERAND_NONE;
  Metadata.Operands[1] := CLOWNZ80_OPERAND_NONE;
  case InstructionMode of
    CLOWNZ80_INSTRUCTION_MODE_NORMAL:
      begin
        case X of
          0:
            case Z of
              0:
                case Y of
                  0:
                    begin
                      Metadata.Opcode := Byte(CLOWNZ80_OPCODE_NOP);
                    end;
                  1:
                    begin
                      Metadata.Opcode := Byte(CLOWNZ80_OPCODE_EX_AF_AF);
                    end;
                  2:
                    begin
                      Metadata.Opcode := Byte(CLOWNZ80_OPCODE_DJNZ);
                      Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                    end;
                  3:
                    begin
                      Metadata.Opcode := Byte(CLOWNZ80_OPCODE_JR_UNCONDITIONAL);
                      Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                    end;
                  4, 5, 6, 7:
                    begin
                      Metadata.Opcode := Byte(CLOWNZ80_OPCODE_JR_CONDITIONAL);
                      Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                      Metadata.Condition := Byte(Sub32(Y, 4));
                    end;
                end;
              1:
                if Q = 0 then
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_16_BIT);
                  Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16_BIT);
                  Metadata.Operands[1] := Byte(REGISTER_PAIRS_1[P]);
                end
                else
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_ADD_HL);
                  Metadata.Operands[0] := Byte(REGISTER_PAIRS_1[P]);
                  Metadata.Operands[1] := Byte(CLOWNZ80_OPERAND_HL);
                end;
              2:
                begin
                  var OperandA: Integer;
                  if P = 2 then
                    OperandA := CLOWNZ80_OPERAND_HL
                  else
                    OperandA := CLOWNZ80_OPERAND_A;
                  var OperandB := OPERANDS[P];
                  if P = 2 then
                    Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_16_BIT)
                  else
                    Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_8_BIT);
                  if Q = 0 then
                  begin
                    Metadata.Operands[0] := Byte(OperandA);
                    Metadata.Operands[1] := Byte(OperandB);
                  end
                  else
                  begin
                    Metadata.Operands[0] := Byte(OperandB);
                    Metadata.Operands[1] := Byte(OperandA);
                  end;
                end;
              3:
                begin
                  if Q = 0 then
                    Metadata.Opcode := Byte(CLOWNZ80_OPCODE_INC_16_BIT)
                  else
                    Metadata.Opcode := Byte(CLOWNZ80_OPCODE_DEC_16_BIT);
                  Metadata.Operands[1] := Byte(REGISTER_PAIRS_1[P]);
                end;
              4:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_INC_8_BIT);
                  Metadata.Operands[1] := Byte(REGISTERS[Y]);
                end;
              5:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_DEC_8_BIT);
                  Metadata.Operands[1] := Byte(REGISTERS[Y]);
                end;
              6:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_8_BIT);
                  Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                  Metadata.Operands[1] := Byte(REGISTERS[Y]);
                end;
              7:
                begin
                  Metadata.Opcode := Byte(OPCODES[Y]);
                end;
            end;
          1:
            if (Z = 6) and (Y = 6) then
              Metadata.Opcode := Byte(CLOWNZ80_OPCODE_HALT)
            else
            begin
              Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_8_BIT);
              Metadata.Operands[0] := Byte(REGISTERS[Z]);
              Metadata.Operands[1] := Byte(REGISTERS[Y]);
            end;
          2:
            begin
              Metadata.Opcode := Byte(ARITHMETIC_LOGIC_OPCODES[Y]);
              Metadata.Operands[0] := Byte(REGISTERS[Z]);
            end;
          3:
            case Z of
              0:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_RET_CONDITIONAL);
                  Metadata.Condition := Byte(Y);
                end;
              1:
                if Q = 0 then
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_POP);
                  Metadata.Operands[1] := Byte(REGISTER_PAIRS_2[P]);
                end
                else
                begin
                  case P of
                    0:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_RET_UNCONDITIONAL);
                      end;
                    1:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_EXX);
                      end;
                    2:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_JP_HL);
                        Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_HL);
                      end;
                    3:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_SP_HL);
                        Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_HL);
                      end;
                  end;
                end;
              2:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_JP_CONDITIONAL);
                  Metadata.Condition := Byte(Y);
                  Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16_BIT);
                end;
              3:
                begin
                  case Y of
                    0:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_JP_UNCONDITIONAL);
                        Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16_BIT);
                      end;
                    1:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_CB_PREFIX);
                        if RegisterMode <> Integer(CLOWNZ80_REGISTER_MODE_HL) then
                          Metadata.HasDisplacement := 1;
                      end;
                    2:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_OUT);
                        Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                      end;
                    3:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_IN);
                        Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                      end;
                    4:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_EX_SP_HL);
                        Metadata.Operands[1] := Byte(CLOWNZ80_OPERAND_HL);
                      end;
                    5:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_EX_DE_HL);
                      end;
                    6:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_DI);
                      end;
                    7:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_EI);
                      end;
                  end;
                end;
              4:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_CALL_CONDITIONAL);
                  Metadata.Condition := Byte(Y);
                  Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16_BIT);
                end;
              5:
                if Q = 0 then
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_PUSH);
                  Metadata.Operands[0] := Byte(REGISTER_PAIRS_2[P]);
                end
                else
                  case P of
                    0:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_CALL_UNCONDITIONAL);
                        Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_16_BIT);
                      end;
                    1:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_DD_PREFIX);
                      end;
                    2:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_ED_PREFIX);
                      end;
                    3:
                      begin
                        Metadata.Opcode := Byte(CLOWNZ80_OPCODE_FD_PREFIX);
                      end;
                  end;
              6:
                begin
                  Metadata.Opcode := Byte(ARITHMETIC_LOGIC_OPCODES[Y]);
                  Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_LITERAL_8_BIT);
                end;
              7:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_RST);
                  Metadata.EmbeddedLiteral := Byte(Mul32(Y, 8));
                end;
            end;
        end;
      end;
    CLOWNZ80_INSTRUCTION_MODE_BITS:
      case X of
        0:
          begin
            Metadata.Opcode := Byte(ROTATE_SHIFT_OPCODES[Y]);
            Metadata.Operands[1] := Byte(REGISTERS[Z]);
          end;
        1:
          begin
            Metadata.Opcode := Byte(CLOWNZ80_OPCODE_BIT);
            Metadata.Operands[1] := Byte(REGISTERS[Z]);
            Metadata.EmbeddedLiteral := Byte(1 shl Y);
          end;
        2:
          begin
            Metadata.Opcode := Byte(CLOWNZ80_OPCODE_RES);
            Metadata.Operands[1] := Byte(REGISTERS[Z]);
            Metadata.EmbeddedLiteral := Byte(not (1 shl Y));
          end;
        3:
          begin
            Metadata.Opcode := Byte(CLOWNZ80_OPCODE_SET);
            Metadata.Operands[1] := Byte(REGISTERS[Z]);
            Metadata.EmbeddedLiteral := Byte(1 shl Y);
          end;
      end;
    CLOWNZ80_INSTRUCTION_MODE_MISC:
      case X of
        0, 3:
          begin
            Metadata.Opcode := Byte(CLOWNZ80_OPCODE_NOP);
          end;
        1:
          begin
            case Z of
              0:
                if Y <> 6 then
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_IN_REGISTER)
                else
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_IN_NO_REGISTER);
              1:
                if Y <> 6 then
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_OUT_REGISTER)
                else
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_OUT_NO_REGISTER);
              2:
                begin
                  if Q = 0 then
                    Metadata.Opcode := Byte(CLOWNZ80_OPCODE_SBC_HL)
                  else
                    Metadata.Opcode := Byte(CLOWNZ80_OPCODE_ADC_HL);
                  Metadata.Operands[0] := Byte(REGISTER_PAIRS_1[P]);
                  Metadata.Operands[1] := Byte(CLOWNZ80_OPERAND_HL);
                end;
              3:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_LD_16_BIT);
                  if Q = 0 then
                  begin
                    Metadata.Operands[0] := Byte(REGISTER_PAIRS_1[P]);
                    Metadata.Operands[1] := Byte(CLOWNZ80_OPERAND_ADDRESS);
                  end
                  else
                  begin
                    Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_ADDRESS);
                    Metadata.Operands[1] := Byte(REGISTER_PAIRS_1[P]);
                  end;
                end;
              4:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_NEG);
                  Metadata.Operands[0] := Byte(CLOWNZ80_OPERAND_A);
                  Metadata.Operands[1] := Byte(CLOWNZ80_OPERAND_A);
                end;
              5:
                if Y <> 1 then
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_RETN)
                else
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_RETI);
              6:
                begin
                  Metadata.Opcode := Byte(CLOWNZ80_OPCODE_IM);
                  Metadata.EmbeddedLiteral := Byte(INTERRUPT_MODES[(Y and 3)]);
                end;
              7:
                begin
                  Metadata.Opcode := Byte(ASSORTED_OPCODES[Y]);
                end;
            end;
          end;
        2:
          begin
            if (Z <= 3) and (Y >= 4) then
              Metadata.Opcode := Byte(BLOCK_OPCODES[Z][(Sub32(Y, 4))])
            else
              Metadata.Opcode := Byte(CLOWNZ80_OPCODE_NOP);
          end;
      end;
  end;

  var I: Cardinal := 0;
  while I < 2 do
  begin
    var OtherOperand := I xor 1;
    if (Metadata.Operands[OtherOperand] <> CLOWNZ80_OPERAND_HL_INDIRECT) and
      (Metadata.Operands[OtherOperand] <> CLOWNZ80_OPERAND_IX_INDIRECT) and
      (Metadata.Operands[OtherOperand] <> CLOWNZ80_OPERAND_IY_INDIRECT)
      then
      case Metadata.Operands[I] of
        CLOWNZ80_OPERAND_H:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IXH);
            CLOWNZ80_REGISTER_MODE_IY:
              Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IYH);
          end;
        CLOWNZ80_OPERAND_L:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IXL);
            CLOWNZ80_REGISTER_MODE_IY:
              Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IYL);
          end;
        CLOWNZ80_OPERAND_HL:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IX);
            CLOWNZ80_REGISTER_MODE_IY:
              Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IY);
          end;
        CLOWNZ80_OPERAND_HL_INDIRECT:
          case RegisterMode of
            CLOWNZ80_REGISTER_MODE_HL:
              ;
            CLOWNZ80_REGISTER_MODE_IX:
              begin
                Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IX_INDIRECT);
                Metadata.HasDisplacement := 1;
              end;
            CLOWNZ80_REGISTER_MODE_IY:
              begin
                Metadata.Operands[I] := Byte(CLOWNZ80_OPERAND_IY_INDIRECT);
                Metadata.HasDisplacement := 1;
              end;
          end;
      end;
    Inc(I);
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

function MemoryRead(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  State.Cycles := Word(State.Cycles + 3);
  Exit(Cardinal(Callbacks.ReadCallback(Callbacks.UserData, Address)));
end;

procedure MemoryWrite(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; Address: Cardinal; Data: Cardinal);
begin
  State.Cycles := Word(State.Cycles + 3);
  Callbacks.WriteCallback(Callbacks.UserData, Address, Data);
end;

function InstructionMemoryRead(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks): Cardinal;
begin
  var Data: Cardinal := MemoryRead(State, Callbacks, State.ProgramCounter);
  State.ProgramCounter := (State.ProgramCounter + 1) and $FFFF;
  Exit(Data);
end;

function OpcodeFetch(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks): Cardinal;
begin
  Inc(State.Cycles);
  State.R := Byte((State.R and $80) or ((State.R + 1) and $7F));
  Exit(InstructionMemoryRead(State, Callbacks));
end;

function MemoryRead16Bit(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := MemoryRead(State, Callbacks, (Address));
  Value := Value or (MemoryRead(State, Callbacks, (Add32(Address, 1) and $FFFF)) shl 8);
  Exit(Value);
end;

procedure MemoryWrite16Bit(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; Address: Cardinal; Value: Cardinal);
begin
  MemoryWrite(State, Callbacks, (Address), (Value and $FF));
  MemoryWrite(State, Callbacks, (Add32(Address, 1) and $FFFF), (Value shr 8));
end;

function ReadOperand(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction; Operand: Integer): Cardinal;
begin
  var Value: Cardinal;
  if Instruction.DoublePrefixMode <> 0 then
  begin
    if State.RegisterMode = CLOWNZ80_REGISTER_MODE_IX then
      Operand := CLOWNZ80_OPERAND_IX_INDIRECT
    else
      Operand := CLOWNZ80_OPERAND_IY_INDIRECT;
  end;
  case Operand of
    CLOWNZ80_OPERAND_NONE:
      Value := Cardinal(State.A);
    CLOWNZ80_OPERAND_A:
      Value := Cardinal(State.A);
    CLOWNZ80_OPERAND_B:
      Value := Cardinal(State.B);
    CLOWNZ80_OPERAND_C:
      Value := Cardinal(State.C);
    CLOWNZ80_OPERAND_D:
      Value := Cardinal(State.D);
    CLOWNZ80_OPERAND_E:
      Value := Cardinal(State.E);
    CLOWNZ80_OPERAND_H:
      Value := Cardinal(State.H);
    CLOWNZ80_OPERAND_L:
      Value := Cardinal(State.L);
    CLOWNZ80_OPERAND_IXH:
      Value := Cardinal(State.IXH);
    CLOWNZ80_OPERAND_IXL:
      Value := Cardinal(State.IXL);
    CLOWNZ80_OPERAND_IYH:
      Value := Cardinal(State.IYH);
    CLOWNZ80_OPERAND_IYL:
      Value := Cardinal(State.IYL);
    CLOWNZ80_OPERAND_AF:
      Value := (Cardinal(State.A) shl 8) or Cardinal(State.F);
    CLOWNZ80_OPERAND_BC:
      Value := (Cardinal(State.B) shl 8) or Cardinal(State.C);
    CLOWNZ80_OPERAND_DE:
      Value := (Cardinal(State.D) shl 8) or Cardinal(State.E);
    CLOWNZ80_OPERAND_HL:
      Value := (Cardinal(State.H) shl 8) or Cardinal(State.L);
    CLOWNZ80_OPERAND_IX:
      Value := (Cardinal(State.IXH) shl 8) or Cardinal(State.IXL);
    CLOWNZ80_OPERAND_IY:
      Value := (Cardinal(State.IYH) shl 8) or Cardinal(State.IYL);
    CLOWNZ80_OPERAND_PC:
      Value := Cardinal(State.ProgramCounter);
    CLOWNZ80_OPERAND_SP:
      Value := Cardinal(State.StackPointer);
    CLOWNZ80_OPERAND_LITERAL_8_BIT, //
    CLOWNZ80_OPERAND_LITERAL_16_BIT:
      Value := Instruction.Literal;
    CLOWNZ80_OPERAND_BC_INDIRECT,  //
    CLOWNZ80_OPERAND_DE_INDIRECT,  //
    CLOWNZ80_OPERAND_HL_INDIRECT,  //
    CLOWNZ80_OPERAND_IX_INDIRECT,  //
    CLOWNZ80_OPERAND_IY_INDIRECT,  //
    CLOWNZ80_OPERAND_ADDRESS:
      begin
        Value := MemoryRead(State, Callbacks, Instruction.Address);
        if Instruction.Metadata.Opcode = Integer(CLOWNZ80_OPCODE_LD_16_BIT) then
          Value := Value or (MemoryRead(State, Callbacks, (Add32(Instruction.Address, 1))) shl 8);
      end;
  else
    Value := Cardinal(State.A);
  end;
  Exit(Value);
end;

procedure WriteOperand(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction; Operand: Integer; Value: Cardinal);
begin
  var DoublePrefixOperand: Integer;
  if State.RegisterMode = Integer(CLOWNZ80_REGISTER_MODE_IX) then
    DoublePrefixOperand := CLOWNZ80_OPERAND_IX_INDIRECT
  else
    DoublePrefixOperand := CLOWNZ80_OPERAND_IY_INDIRECT;

  if (Instruction.DoublePrefixMode <> 0) and (Operand <> DoublePrefixOperand) then
    WriteOperand(State, Callbacks, Instruction, DoublePrefixOperand, Value);

  case Operand of
    CLOWNZ80_OPERAND_NONE,           //
    CLOWNZ80_OPERAND_LITERAL_8_BIT,   //
    CLOWNZ80_OPERAND_LITERAL_16_BIT:
      ;
    CLOWNZ80_OPERAND_A:
      State.A := Byte(Value);
    CLOWNZ80_OPERAND_B:
      State.B := Byte(Value);
    CLOWNZ80_OPERAND_C:
      State.C := Byte(Value);
    CLOWNZ80_OPERAND_D:
      State.D := Byte(Value);
    CLOWNZ80_OPERAND_E:
      State.E := Byte(Value);
    CLOWNZ80_OPERAND_H:
      State.H := Byte(Value);
    CLOWNZ80_OPERAND_L:
      State.L := Byte(Value);
    CLOWNZ80_OPERAND_IXH:
      State.IXH := Byte(Value);
    CLOWNZ80_OPERAND_IXL:
      State.IXL := Byte(Value);
    CLOWNZ80_OPERAND_IYH:
      State.IYH := Byte(Value);
    CLOWNZ80_OPERAND_IYL:
      State.IYL := Byte(Value);
    CLOWNZ80_OPERAND_AF:
      begin
        State.A := Byte(Value shr 8);
        State.F := Byte(Value and $FF);
      end;
    CLOWNZ80_OPERAND_BC:
      begin
        State.B := Byte(Value shr 8);
        State.C := Byte(Value and $FF);
      end;
    CLOWNZ80_OPERAND_DE:
      begin
        State.D := Byte(Value shr 8);
        State.E := Byte(Value and $FF);
      end;
    CLOWNZ80_OPERAND_HL:
      begin
        State.H := Byte(Value shr 8);
        State.L := Byte(Value and $FF);
      end;
    CLOWNZ80_OPERAND_IX:
      begin
        State.IXH := Byte(Value shr 8);
        State.IXL := Byte(Value and $FF);
      end;
    CLOWNZ80_OPERAND_IY:
      begin
        State.IYH := Byte(Value shr 8);
        State.IYL := Byte(Value and $FF);
      end;
    CLOWNZ80_OPERAND_PC:
      begin
        State.ProgramCounter := Word(Value);
      end;
    CLOWNZ80_OPERAND_SP:
      begin
        State.StackPointer := Word(Value);
      end;
    CLOWNZ80_OPERAND_BC_INDIRECT, //
    CLOWNZ80_OPERAND_DE_INDIRECT, //
    CLOWNZ80_OPERAND_HL_INDIRECT, //
    CLOWNZ80_OPERAND_IX_INDIRECT, //
    CLOWNZ80_OPERAND_IY_INDIRECT, //
    CLOWNZ80_OPERAND_ADDRESS:
      begin
        if Instruction.Metadata.Opcode = Integer(CLOWNZ80_OPCODE_LD_16_BIT) then
          MemoryWrite16Bit(State, Callbacks, Instruction.Address, Value)
        else
          MemoryWrite(State, Callbacks, Instruction.Address, Value);
      end;
  end;
end;

procedure DecodeInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction);
begin
  var Opcode: Cardinal := OpcodeFetch(State, Callbacks);
  var Displacement: Cardinal := 0;

  Instruction.Metadata := InstructionMetadataLookupNormal[State.RegisterMode][Opcode];
  if Instruction.Metadata.HasDisplacement <> 0 then
  begin
    Displacement := InstructionMemoryRead(State, Callbacks);
    Displacement := Sub32(Displacement and Sub32(Cardinal(1) shl 7, 1), Displacement and (Cardinal(1) shl 7));
    State.Cycles := Word(State.Cycles + 5);
  end;

  Instruction.DoublePrefixMode := 0;
  case Instruction.Metadata.Opcode of
    CLOWNZ80_OPCODE_CB_PREFIX:
      if State.RegisterMode = Integer(CLOWNZ80_REGISTER_MODE_HL) then
      begin
        Opcode := OpcodeFetch(State, Callbacks);
        Instruction.Metadata := InstructionMetadataLookupBits[State.RegisterMode][Opcode];
      end
      else
      begin
        Instruction.DoublePrefixMode := 1;
        Opcode := InstructionMemoryRead(State, Callbacks);
        State.Cycles := Word(State.Cycles - 3);
        if State.RegisterMode = Integer(CLOWNZ80_REGISTER_MODE_IX) then
          Instruction.Address := Add32((Cardinal(State.IXH) shl 8) or Cardinal(State.IXL), Displacement) and $FFFF
        else
          Instruction.Address := Add32((Cardinal(State.IYH) shl 8) or Cardinal(State.IYL), Displacement) and $FFFF;
        Instruction.Metadata := InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_HL][Opcode];
        if Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT) then
          Instruction.Metadata := InstructionMetadataLookupBits[State.RegisterMode][Opcode];
      end;
    CLOWNZ80_OPCODE_ED_PREFIX:
      begin
        Opcode := OpcodeFetch(State, Callbacks);
        Instruction.Metadata := InstructionMetadataLookupMisc[Opcode];
      end;
  end;

  case Instruction.Metadata.Operands[0] of
    CLOWNZ80_OPERAND_LITERAL_8_BIT:
      begin
        Instruction.Literal := InstructionMemoryRead(State, Callbacks);
        if Instruction.Metadata.HasDisplacement <> 0 then
          State.Cycles := Word(State.Cycles - 3);
      end;
    CLOWNZ80_OPERAND_LITERAL_16_BIT:
      begin
        Instruction.Literal := InstructionMemoryRead(State, Callbacks);
        Instruction.Literal := Instruction.Literal or (InstructionMemoryRead(State, Callbacks) shl 8);
      end;
  end;

  for var I := 0 to 1 do
    case Instruction.Metadata.Operands[I] of
      CLOWNZ80_OPERAND_BC_INDIRECT:
        Instruction.Address := (Cardinal(State.B) shl 8) or Cardinal(State.C);
      CLOWNZ80_OPERAND_DE_INDIRECT:
        Instruction.Address := (Cardinal(State.D) shl 8) or Cardinal(State.E);
      CLOWNZ80_OPERAND_HL_INDIRECT:
        Instruction.Address := (Cardinal(State.H) shl 8) or Cardinal(State.L);
      CLOWNZ80_OPERAND_IX_INDIRECT:
        Instruction.Address := Add32((Cardinal(State.IXH) shl 8) or Cardinal(State.IXL), Displacement) and $FFFF;
      CLOWNZ80_OPERAND_IY_INDIRECT:
        Instruction.Address := Add32((Cardinal(State.IYH) shl 8) or Cardinal(State.IYL), Displacement) and $FFFF;
      CLOWNZ80_OPERAND_ADDRESS:
        begin
          Instruction.Address := InstructionMemoryRead(State, Callbacks);
          Instruction.Address := Instruction.Address or (InstructionMemoryRead(State, Callbacks) shl 8);
        end;
    end;
end;

function ComputeParity(Value: Cardinal): Byte;
begin
  Value := Value xor (Value shr 4);
  Value := Value xor (Value shr 2);
  Value := Value xor (Value shr 1);
  Exit(Ord((Value and 1) = 0));
end;

procedure ExecuteInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction);
begin
  var SourceValue: Cardinal;
  var DestinationValue: Cardinal;
  var ResultValue: Cardinal;
  var ResultValueWithCarry: Cardinal;
  var ResultValueWithCarry16bit: Cardinal;
  var SwapHolder: Byte;
  var Carry: Byte;
  var CorrectionFactor: Cardinal;
  var OriginalA: Cardinal;
  var Temp345: Integer;
  var Temp346: Integer;
  var Temp347: Integer;
  var Temp348: Integer;
  var Temp349: Integer;
  var Temp350: Integer;
  var Temp351: Integer;
  var Temp352: Integer;
  var Temp353: Integer;
  var Temp354: Integer;
  var Temp355: Integer;
  var Temp356: Integer;
  var Temp357: Integer;
  var Temp358: Integer;
  var Temp359: Integer;
  var Temp360: Integer;
  var Temp361: Integer;
  var Temp362: Integer;
  var Temp363: Integer;
  var Temp364: Integer;
  var Temp365: Integer;
  var Temp366: Integer;
  var Temp367: Integer;
  var Temp368: Integer;
  var Temp369: Integer;
  var Temp370: Integer;
  var Temp371: Integer;
  var Temp372: Integer;
  var Temp373: Integer;
  var Temp374: Integer;
  var Temp375: Integer;
  var Temp376: Integer;
  var Temp377: Integer;
  var Temp378: Integer;
  var Temp379: Integer;
  var Temp380: Integer;
  var Temp381: Integer;
  var Temp382: Integer;
  var Temp383: Integer;
  var Temp384: Integer;
  var Temp385: Integer;
  var Temp386: Integer;
  var Temp387: Integer;
  var Temp388: Integer;
  var Temp389: Integer;
  var Temp390: Integer;
  var Temp391: Integer;
  var Temp392: Integer;
  var Temp393: Integer;
  var Temp394: Integer;
  var Temp395: Integer;
  var Temp396: Integer;
  var Temp397: Integer;
  var Temp398: Integer;
  var Temp399: Integer;
  var Temp400: Integer;
  var Temp401: Integer;
  var Temp403: Integer;
  var Temp404: Integer;
  var Temp405: Integer;
  var Temp406: Integer;
  var Temp407: Integer;
  var Temp408: Integer;
  var Temp409: Integer;
  var Temp410: Integer;
  var Temp411: Integer;
  var Temp412: Integer;
  var Temp413: Integer;
  var Temp414: Integer;
  var Temp415: Integer;
  var Hl: Cardinal;
  var HlValue: Cardinal;
  var HlHigh: Cardinal;
  var HlLow: Cardinal;
  var AHigh: Cardinal;
  var ALow: Cardinal;
  var Temp416: Integer;
  var Temp417: Integer;
  var HlScope211: Cardinal;
  var HlValueScope212: Cardinal;
  var HlHighScope213: Cardinal;
  var HlLowScope214: Cardinal;
  var AHighScope215: Cardinal;
  var ALowScope216: Cardinal;
  var Temp418: Integer;
  var Temp419: Integer;
  var De: Cardinal;
  var HlScope217: Cardinal;
  var Temp420: Integer;
  var DeScope218: Cardinal;
  var HlScope219: Cardinal;
  var Temp421: Integer;
  var DeScope220: Cardinal;
  var HlScope221: Cardinal;
  var Temp422: Integer;
  var DeScope222: Cardinal;
  var HlScope223: Cardinal;
  var Temp423: Integer;
  var HlScope224: Cardinal;
  var Temp424: Integer;
  var Temp425: Integer;
  var HlScope225: Cardinal;
  var Temp426: Integer;
  var Temp427: Integer;
  var HlScope226: Cardinal;
  var Temp428: Integer;
  var Temp429: Integer;
  var HlScope227: Cardinal;
  var Temp431: Integer;
  var Temp432: Integer;
  State.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_HL);
  case Instruction.Metadata.Opcode of
    CLOWNZ80_OPCODE_NOP:
      ;
    CLOWNZ80_OPCODE_EX_AF_AF:
      begin
        SwapHolder := State.A;
        State.A := State.AAlt;
        State.AAlt := SwapHolder;
        SwapHolder := State.F;
        State.F := State.FAlt;
        State.FAlt := SwapHolder;
      end;
    CLOWNZ80_OPCODE_DJNZ:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.B := (State.B + $FF) and $FF;
        if State.B <> 0 then
        begin
          State.ProgramCounter := Word(State.ProgramCounter + (Sub32(Instruction.Literal and Sub32(Cardinal(1) shl 7, 1), Instruction.Literal and (Cardinal(1) shl 7))));
          State.ProgramCounter := Word(State.ProgramCounter and $FFFF);
          State.Cycles := Word(State.Cycles + 5);
        end;
      end;
    CLOWNZ80_OPCODE_JR_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State.F, Instruction.Metadata.Condition) then
            Break;
          State.ProgramCounter := Word(State.ProgramCounter + (Sub32(Instruction.Literal and Sub32(Cardinal(1) shl 7, 1), Instruction.Literal and (Cardinal(1) shl 7))));
          State.ProgramCounter := Word(State.ProgramCounter and $FFFF);
          State.Cycles := Word(State.Cycles + 5);
        until True;
      end;
    CLOWNZ80_OPCODE_JR_UNCONDITIONAL:
      begin
        State.ProgramCounter := Word(State.ProgramCounter + (Sub32(Instruction.Literal and Sub32(Cardinal(1) shl 7, 1), Instruction.Literal and (Cardinal(1) shl 7))));
        State.ProgramCounter := Word(State.ProgramCounter and $FFFF);
        State.Cycles := Word(State.Cycles + 5);
      end;
    CLOWNZ80_OPCODE_LD_8_BIT, CLOWNZ80_OPCODE_LD_16_BIT:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        ResultValue := SourceValue;
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
      end;
    CLOWNZ80_OPCODE_ADD_HL:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValueWithCarry16bit := Add32(SourceValue, DestinationValue);
        ResultValue := ResultValueWithCarry16bit and $FFFF;
        State.F := Byte(State.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        State.F := Byte(State.F or ((ResultValueWithCarry16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.Cycles := Word(State.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_INC_16_BIT:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := Add32(DestinationValue, 1) and $FFFF;
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_DEC_16_BIT:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := Sub32(DestinationValue, 1) and $FFFF;
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_INC_8_BIT:
      begin
        SourceValue := 1;
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := Add32(DestinationValue, SourceValue) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));

        if ResultValue = 0 then
          State.F := State.F or FLAG_MASK_ZERO;
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        if (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or
          (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT) or
          (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT) then
          Inc(State.Cycles);
      end;
    CLOWNZ80_OPCODE_DEC_8_BIT:
      begin
        SourceValue := $FFFFFFFF;
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := Add32(DestinationValue, SourceValue) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := State.F or FLAG_MASK_ZERO;
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F xor FLAG_MASK_HALF_CARRY);
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        if (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or
          (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT) or
          (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT) then
          Inc(State.Cycles);
      end;
    CLOWNZ80_OPCODE_RLCA:
      begin
        Carry := Ord((State.A and $80) <> 0);
        State.A := Byte(State.A shl 1);
        State.A := Byte(State.A and $FF);
        if Carry <> 0 then
          State.A := State.A or $01;
        State.F := Byte(State.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        if Carry <> 0 then
          State.F := State.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_RRCA:
      begin
        Carry := Ord((State.A and $01) <> 0);
        State.A := Byte(ArithmeticShiftRight(State.A, 1));
        if Carry <> 0 then
          State.A := State.A or $80;
        State.F := Byte(State.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        if Carry <> 0 then
          State.F := State.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_RLA:
      begin
        Carry := Ord((State.A and $80) <> 0);
        State.A := Byte(State.A shl 1);
        State.A := Byte(State.A and $FF);
        if (State.F and FLAG_MASK_CARRY) <> 0 then
          State.A := State.A or 1;
        State.F := State.F and (FLAG_MASK_SIGN or FLAG_MASK_ZERO or FLAG_MASK_PARITY_OVERFLOW);
        if Carry <> 0 then
          State.F := State.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_RRA:
      begin
        Carry := Ord((State.A and $01) <> 0);
        State.A := Byte(ArithmeticShiftRight(State.A, 1));
        if Integer(State.F and FLAG_MASK_CARRY) <> 0 then
          State.A := Byte(State.A or $80);
        State.F := Byte(State.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        if Carry <> 0 then
          State.F := State.F or FLAG_MASK_CARRY;
      end;
    CLOWNZ80_OPCODE_DAA:
      begin
        OriginalA := Cardinal(State.A);
        CorrectionFactor := Cardinal(((State.A + $66) xor State.A) and $110);
        CorrectionFactor := CorrectionFactor or Cardinal((State.F and FLAG_MASK_CARRY) shl (8 - FLAG_BIT_CARRY));
        CorrectionFactor := CorrectionFactor or Cardinal((State.F and FLAG_MASK_HALF_CARRY) shl (4 - FLAG_BIT_HALF_CARRY));
        CorrectionFactor := (CorrectionFactor shr 2) or (CorrectionFactor shr 3);
        if Integer(State.F and FLAG_MASK_ADD_SUBTRACT) <> 0 then
          State.A := Byte(State.A - CorrectionFactor)
        else
          State.A := Byte(State.A + CorrectionFactor);
        State.A := Byte(State.A and $FF);
        State.F := Byte(State.F and FLAG_MASK_ADD_SUBTRACT);
        State.F := Byte(State.F or (ArithmeticShiftRight(State.A, (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        State.F := Byte(State.F or (Ord(State.A = 0) shl FLAG_BIT_ZERO));
        State.F := Byte(State.F or (((OriginalA xor Cardinal(State.A)) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        if ComputeParity(State.A) <> 0 then
          State.F := State.F or FLAG_MASK_PARITY_OVERFLOW;
        State.F := Byte(State.F or ((CorrectionFactor shr (6 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
      end;
    CLOWNZ80_OPCODE_CPL:
      begin
        State.A := not State.A;
        State.A := Byte(State.A and $FF);
        State.F := Byte(State.F or (FLAG_MASK_HALF_CARRY or FLAG_MASK_ADD_SUBTRACT));
      end;
    CLOWNZ80_OPCODE_SCF:
      begin
        State.F := Byte(State.F and ((FLAG_MASK_SIGN or FLAG_MASK_ZERO) or FLAG_MASK_PARITY_OVERFLOW));
        State.F := Byte(State.F or FLAG_MASK_CARRY);
      end;
    CLOWNZ80_OPCODE_CCF:
      begin
        State.F := Byte(State.F and (not (FLAG_MASK_ADD_SUBTRACT or FLAG_MASK_HALF_CARRY)));
        if (State.F and FLAG_MASK_CARRY) <> 0 then
          State.F := State.F or FLAG_MASK_HALF_CARRY;
        State.F := Byte(State.F xor FLAG_MASK_CARRY);
      end;
    CLOWNZ80_OPCODE_HALT:
      ;
    CLOWNZ80_OPCODE_ADD_A:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValueWithCarry := Add32(DestinationValue, SourceValue);
        ResultValue := ResultValueWithCarry and $FF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValueWithCarry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := State.F or FLAG_MASK_ZERO;
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_ADC_A:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), Ord((State.F and FLAG_MASK_CARRY) <> 0));
        ResultValue := ResultValueWithCarry and $FF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValueWithCarry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := State.F or FLAG_MASK_ZERO;
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_SUB:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        SourceValue := not SourceValue;
        DestinationValue := Cardinal(State.A);
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), 1);
        ResultValue := ResultValueWithCarry and $FF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValueWithCarry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := State.F or FLAG_MASK_ZERO;
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F xor FLAG_MASK_HALF_CARRY);
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_SBC_A:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        SourceValue := not SourceValue;
        DestinationValue := Cardinal(State.A);
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), Ord((State.F and FLAG_MASK_CARRY) = 0));
        ResultValue := ResultValueWithCarry and $FF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValueWithCarry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F xor FLAG_MASK_HALF_CARRY);
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_AND:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValue := DestinationValue and SourceValue;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp345 := FLAG_MASK_ZERO
        else
          Temp345 := 0;
        State.F := Byte(State.F or Temp345);
        State.F := Byte(State.F or FLAG_MASK_HALF_CARRY);
        if ComputeParity(ResultValue) <> 0 then
          Temp346 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp346 := 0;
        State.F := Byte(State.F or Temp346);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_XOR:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValue := DestinationValue xor SourceValue;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp347 := FLAG_MASK_ZERO
        else
          Temp347 := 0;
        State.F := Byte(State.F or Temp347);
        if ComputeParity(ResultValue) <> 0 then
          Temp348 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp348 := 0;
        State.F := Byte(State.F or Temp348);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_OR:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValue := DestinationValue or SourceValue;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp349 := FLAG_MASK_ZERO
        else
          Temp349 := 0;
        State.F := Byte(State.F or Temp349);
        if ComputeParity(ResultValue) <> 0 then
          Temp350 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp350 := 0;
        State.F := Byte(State.F or Temp350);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_CP:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        SourceValue := not SourceValue;
        DestinationValue := Cardinal(State.A);
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), 1);
        ResultValue := ResultValueWithCarry and $FF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValueWithCarry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp351 := FLAG_MASK_ZERO
        else
          Temp351 := 0;
        State.F := Byte(State.F or Temp351);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F xor FLAG_MASK_HALF_CARRY);
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
      end;
    CLOWNZ80_OPCODE_POP:
      begin
        ResultValue := MemoryRead16Bit(State, Callbacks, State.StackPointer);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.StackPointer := Word(State.StackPointer + 2);
        State.StackPointer := Word(State.StackPointer and $FFFF);
      end;
    CLOWNZ80_OPCODE_RET_CONDITIONAL:
      begin
        repeat
          State.Cycles := Word(State.Cycles + 1);
          if not EvaluateCondition(State.F, Instruction.Metadata.Condition) then
            Break;
          State.ProgramCounter := Word(MemoryRead16Bit(State, Callbacks, State.StackPointer));
          State.StackPointer := Word(State.StackPointer + 2);
          State.StackPointer := Word(State.StackPointer and $FFFF);
        until True;
      end;
    CLOWNZ80_OPCODE_RET_UNCONDITIONAL, CLOWNZ80_OPCODE_RETN, CLOWNZ80_OPCODE_RETI:
      begin
        State.ProgramCounter := Word(MemoryRead16Bit(State, Callbacks, State.StackPointer));
        State.StackPointer := Word(State.StackPointer + 2);
        State.StackPointer := Word(State.StackPointer and $FFFF);
      end;
    CLOWNZ80_OPCODE_EXX:
      begin
        SwapHolder := State.B;
        State.B := State.BAlt;
        State.BAlt := SwapHolder;
        SwapHolder := State.C;
        State.C := State.CAlt;
        State.CAlt := SwapHolder;
        SwapHolder := State.D;
        State.D := State.DAlt;
        State.DAlt := SwapHolder;
        SwapHolder := State.E;
        State.E := State.EAlt;
        State.EAlt := SwapHolder;
        SwapHolder := State.H;
        State.H := State.HAlt;
        State.HAlt := SwapHolder;
        SwapHolder := State.L;
        State.L := State.LAlt;
        State.LAlt := SwapHolder;
      end;
    CLOWNZ80_OPCODE_LD_SP_HL:
      begin
        State.Cycles := Word(State.Cycles + 2);
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        State.StackPointer := Word(SourceValue);
      end;
    CLOWNZ80_OPCODE_JP_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State.F, Instruction.Metadata.Condition) then
            Break;
          SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
          State.ProgramCounter := Word(SourceValue);
        until True;
      end;
    CLOWNZ80_OPCODE_JP_UNCONDITIONAL, CLOWNZ80_OPCODE_JP_HL:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        State.ProgramCounter := Word(SourceValue);
      end;
    CLOWNZ80_OPCODE_CB_PREFIX, CLOWNZ80_OPCODE_ED_PREFIX:
      begin
        Assert(0 <> 0);
      end;
    CLOWNZ80_OPCODE_DD_PREFIX:
      begin
        State.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_IX);
      end;
    CLOWNZ80_OPCODE_FD_PREFIX:
      begin
        State.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_IY);
      end;
    CLOWNZ80_OPCODE_OUT, CLOWNZ80_OPCODE_IN:
      begin
      end;
    CLOWNZ80_OPCODE_EX_SP_HL:
      begin
        State.Cycles := Word(State.Cycles + 3);
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := MemoryRead16Bit(State, Callbacks, State.StackPointer);
        MemoryWrite16Bit(State, Callbacks, State.StackPointer, DestinationValue);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
      end;
    CLOWNZ80_OPCODE_EX_DE_HL:
      begin
        SwapHolder := State.D;
        State.D := State.H;
        State.H := SwapHolder;
        SwapHolder := State.E;
        State.E := State.L;
        State.L := SwapHolder;
      end;
    CLOWNZ80_OPCODE_DI:
      begin
        State.InterruptsEnabled := 0;
      end;
    CLOWNZ80_OPCODE_EI:
      begin
        State.InterruptsEnabled := 1;
      end;
    CLOWNZ80_OPCODE_PUSH:
      begin
        State.Cycles := Word(State.Cycles + 1);
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
        MemoryWrite(State, Callbacks, State.StackPointer, (SourceValue shr 8));
        State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
        MemoryWrite(State, Callbacks, State.StackPointer, (SourceValue and $FF));
      end;
    CLOWNZ80_OPCODE_CALL_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State.F, Instruction.Metadata.Condition) then
            Break;
          State.Cycles := Word(State.Cycles + 1);
          State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
          MemoryWrite(State, Callbacks, State.StackPointer, ArithmeticShiftRight(State.ProgramCounter, 8));
          State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
          MemoryWrite(State, Callbacks, State.StackPointer, (State.ProgramCounter and $FF));
          State.ProgramCounter := Word(Instruction.Literal);
        until True;
      end;
    CLOWNZ80_OPCODE_CALL_UNCONDITIONAL:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
        MemoryWrite(State, Callbacks, State.StackPointer, ArithmeticShiftRight(State.ProgramCounter, 8));
        State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
        MemoryWrite(State, Callbacks, State.StackPointer, (State.ProgramCounter and $FF));
        State.ProgramCounter := Word(Instruction.Literal);
      end;
    CLOWNZ80_OPCODE_RST:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
        MemoryWrite(State, Callbacks, State.StackPointer, ArithmeticShiftRight(State.ProgramCounter, 8));
        State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
        MemoryWrite(State, Callbacks, State.StackPointer, (State.ProgramCounter and $FF));
        State.ProgramCounter := Word(Instruction.Metadata.EmbeddedLiteral);
      end;
    CLOWNZ80_OPCODE_RLC:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := (DestinationValue shl 1) and $FF;
        if Carry <> 0 then
          Temp352 := $01
        else
          Temp352 := 0;
        ResultValue := ResultValue or Cardinal(Temp352);
        State.F := 0;
        if Carry <> 0 then
          Temp353 := FLAG_MASK_CARRY
        else
          Temp353 := 0;
        State.F := Byte(State.F or Temp353);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp354 := FLAG_MASK_ZERO
        else
          Temp354 := 0;
        State.F := Byte(State.F or Temp354);
        if ComputeParity(ResultValue) <> 0 then
          Temp355 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp355 := 0;
        State.F := Byte(State.F or Temp355);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp357 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp356 := Ord((Temp357 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp356);
      end;
    CLOWNZ80_OPCODE_RRC:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := DestinationValue shr 1;
        if Carry <> 0 then
          Temp358 := $80
        else
          Temp358 := 0;
        ResultValue := ResultValue or Cardinal(Temp358);
        State.F := 0;
        if Carry <> 0 then
          Temp359 := FLAG_MASK_CARRY
        else
          Temp359 := 0;
        State.F := Byte(State.F or Temp359);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp360 := FLAG_MASK_ZERO
        else
          Temp360 := 0;
        State.F := Byte(State.F or Temp360);
        if ComputeParity(ResultValue) <> 0 then
          Temp361 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp361 := 0;
        State.F := Byte(State.F or Temp361);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp363 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp362 := Ord((Temp363 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp362);
      end;
    CLOWNZ80_OPCODE_RL:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := (DestinationValue shl 1) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if State.F <> 0 then
          Temp364 := $01
        else
          Temp364 := 0;
        ResultValue := ResultValue or Cardinal(Temp364);
        State.F := 0;
        if Carry <> 0 then
          Temp365 := FLAG_MASK_CARRY
        else
          Temp365 := 0;
        State.F := Byte(State.F or Temp365);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp366 := FLAG_MASK_ZERO
        else
          Temp366 := 0;
        State.F := Byte(State.F or Temp366);
        if ComputeParity(ResultValue) <> 0 then
          Temp367 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp367 := 0;
        State.F := Byte(State.F or Temp367);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp369 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp368 := Ord((Temp369 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp368);
      end;
    CLOWNZ80_OPCODE_RR:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := DestinationValue shr 1;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if State.F <> 0 then
          Temp370 := $80
        else
          Temp370 := 0;
        ResultValue := ResultValue or Cardinal(Temp370);
        State.F := 0;
        if Carry <> 0 then
          Temp371 := FLAG_MASK_CARRY
        else
          Temp371 := 0;
        State.F := Byte(State.F or Temp371);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp372 := FLAG_MASK_ZERO
        else
          Temp372 := 0;
        State.F := Byte(State.F or Temp372);
        if ComputeParity(ResultValue) <> 0 then
          Temp373 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp373 := 0;
        State.F := Byte(State.F or Temp373);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp375 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp374 := Ord((Temp375 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp374);
      end;
    CLOWNZ80_OPCODE_SLA:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := (DestinationValue shl 1) and $FF;
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          Temp376 := FLAG_MASK_SIGN
        else
          Temp376 := 0;
        State.F := Byte(State.F or Temp376);
        if ResultValue = 0 then
          Temp377 := FLAG_MASK_ZERO
        else
          Temp377 := 0;
        State.F := Byte(State.F or Temp377);
        if ComputeParity(ResultValue) <> 0 then
          Temp378 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp378 := 0;
        State.F := Byte(State.F or Temp378);
        if Carry <> 0 then
          Temp379 := FLAG_MASK_CARRY
        else
          Temp379 := 0;
        State.F := Byte(State.F or Temp379);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp381 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp380 := Ord((Temp381 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp380);
      end;
    CLOWNZ80_OPCODE_SLL:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := ((DestinationValue shl 1) or 1) and $FF;
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          Temp382 := FLAG_MASK_SIGN
        else
          Temp382 := 0;
        State.F := Byte(State.F or Temp382);
        if ResultValue = 0 then
          Temp383 := FLAG_MASK_ZERO
        else
          Temp383 := 0;
        State.F := Byte(State.F or Temp383);
        if ComputeParity(ResultValue) <> 0 then
          Temp384 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp384 := 0;
        State.F := Byte(State.F or Temp384);
        if Carry <> 0 then
          Temp385 := FLAG_MASK_CARRY
        else
          Temp385 := 0;
        State.F := Byte(State.F or Temp385);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp387 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp386 := Ord((Temp387 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp386);
      end;
    CLOWNZ80_OPCODE_SRA:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := (DestinationValue shr 1) or (DestinationValue and $80);
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          Temp388 := FLAG_MASK_SIGN
        else
          Temp388 := 0;
        State.F := Byte(State.F or Temp388);
        if ResultValue = 0 then
          Temp389 := FLAG_MASK_ZERO
        else
          Temp389 := 0;
        State.F := Byte(State.F or Temp389);
        if ComputeParity(ResultValue) <> 0 then
          Temp390 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp390 := 0;
        State.F := Byte(State.F or Temp390);
        if Carry <> 0 then
          Temp391 := FLAG_MASK_CARRY
        else
          Temp391 := 0;
        State.F := Byte(State.F or Temp391);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp393 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp392 := Ord((Temp393 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp392);
      end;
    CLOWNZ80_OPCODE_SRL:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := DestinationValue shr 1;
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          Temp394 := FLAG_MASK_SIGN
        else
          Temp394 := 0;
        State.F := Byte(State.F or Temp394);
        if ResultValue = 0 then
          Temp395 := FLAG_MASK_ZERO
        else
          Temp395 := 0;
        State.F := Byte(State.F or Temp395);
        if ComputeParity(ResultValue) <> 0 then
          Temp396 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp396 := 0;
        State.F := Byte(State.F or Temp396);
        if Carry <> 0 then
          Temp397 := FLAG_MASK_CARRY
        else
          Temp397 := 0;
        State.F := Byte(State.F or Temp397);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp399 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp398 := Ord((Temp399 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp398);
      end;
    CLOWNZ80_OPCODE_BIT:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if (DestinationValue and Cardinal(Instruction.Metadata.EmbeddedLiteral)) = 0 then
          Temp400 := FLAG_MASK_ZERO or FLAG_MASK_PARITY_OVERFLOW
        else
          Temp400 := 0;
        State.F := Byte(State.F or Temp400);
        State.F := Byte(State.F or FLAG_MASK_HALF_CARRY);
        if (Instruction.Metadata.EmbeddedLiteral = $80) and (Integer(State.F and FLAG_MASK_ZERO) = 0) then
          Temp401 := FLAG_MASK_SIGN
        else
          Temp401 := 0;
        State.F := Byte(State.F or Temp401);
        Temp404 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp403 := Ord((Temp404 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp403);
      end;
    CLOWNZ80_OPCODE_RES:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := DestinationValue and Cardinal(Instruction.Metadata.EmbeddedLiteral);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp406 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp405 := Ord((Temp406 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp405);
      end;
    CLOWNZ80_OPCODE_SET:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := DestinationValue or Cardinal(Instruction.Metadata.EmbeddedLiteral);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        Temp408 := Ord((Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_HL_INDIRECT)) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IX_INDIRECT)));
        Temp407 := Ord((Temp408 <> 0) or (Instruction.Metadata.Operands[1] = Integer(CLOWNZ80_OPERAND_IY_INDIRECT)));
        State.Cycles := Word(State.Cycles + Temp407);
      end;
    CLOWNZ80_OPCODE_IN_REGISTER, CLOWNZ80_OPCODE_IN_NO_REGISTER, CLOWNZ80_OPCODE_OUT_REGISTER, CLOWNZ80_OPCODE_OUT_NO_REGISTER:
      begin
      end;
    CLOWNZ80_OPCODE_SBC_HL:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        SourceValue := not SourceValue;
        if Integer(State.F and FLAG_MASK_CARRY) <> 0 then
          Temp409 := 0
        else
          Temp409 := 1;
        ResultValueWithCarry16bit := Add32(Add32(SourceValue, DestinationValue), Temp409);
        ResultValue := ResultValueWithCarry16bit and $FFFF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (15 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp410 := FLAG_MASK_ZERO
        else
          Temp410 := 0;
        State.F := Byte(State.F or Temp410);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (15 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F or ((ResultValueWithCarry16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F xor FLAG_MASK_HALF_CARRY);
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.Cycles := Word(State.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_ADC_HL:
      begin
        SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        if Integer(State.F and FLAG_MASK_CARRY) <> 0 then
          Temp411 := 1
        else
          Temp411 := 0;
        ResultValueWithCarry16bit := Add32(Add32(SourceValue, DestinationValue), Temp411);
        ResultValue := ResultValueWithCarry16bit and $FFFF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (15 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp412 := FLAG_MASK_ZERO
        else
          Temp412 := 0;
        State.F := Byte(State.F or Temp412);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (15 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F or ((ResultValueWithCarry16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.Cycles := Word(State.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_NEG:
      begin
        SourceValue := Cardinal(State.A);
        SourceValue := not SourceValue;
        DestinationValue := 0;
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), 1);
        ResultValue := ResultValueWithCarry and $FF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValueWithCarry shr (8 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp413 := FLAG_MASK_ZERO
        else
          Temp413 := 0;
        State.F := Byte(State.F or Temp413);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (7 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F xor FLAG_MASK_HALF_CARRY);
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_IM:
      begin
      end;
    CLOWNZ80_OPCODE_LD_I_A:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.I := State.A;
      end;
    CLOWNZ80_OPCODE_LD_R_A:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.R := State.A;
      end;
    CLOWNZ80_OPCODE_LD_A_I:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.A := State.I;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or (ArithmeticShiftRight(State.A, (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        if State.A = 0 then
          Temp414 := FLAG_MASK_ZERO
        else
          Temp414 := 0;
        State.F := Byte(State.F or Temp414);
      end;
    CLOWNZ80_OPCODE_LD_A_R:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.A := State.R;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or (ArithmeticShiftRight(State.A, (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        if State.A = 0 then
          Temp415 := FLAG_MASK_ZERO
        else
          Temp415 := 0;
        State.F := Byte(State.F or Temp415);
      end;
    CLOWNZ80_OPCODE_RRD:
      begin
        Hl := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        HlValue := MemoryRead(State, Callbacks, Hl);
        HlHigh := (HlValue shr 4) and $F;
        HlLow := HlValue and $F;
        AHigh := Cardinal(ArithmeticShiftRight(State.A, 4) and $F);
        ALow := Cardinal(ArithmeticShiftRight(State.A, 0) and $F);
        State.Cycles := Word(State.Cycles + 4);
        MemoryWrite(State, Callbacks, Hl, ((ALow shl 4) or HlHigh));
        ResultValue := (AHigh shl 4) or HlLow;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp416 := FLAG_MASK_ZERO
        else
          Temp416 := 0;
        State.F := Byte(State.F or Temp416);
        if ComputeParity(ResultValue) <> 0 then
          Temp417 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp417 := 0;
        State.F := Byte(State.F or Temp417);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_RLD:
      begin
        HlScope211 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        HlValueScope212 := MemoryRead(State, Callbacks, HlScope211);
        HlHighScope213 := (HlValueScope212 shr 4) and $F;
        HlLowScope214 := HlValueScope212 and $F;
        AHighScope215 := Cardinal(ArithmeticShiftRight(State.A, 4) and $F);
        ALowScope216 := Cardinal(ArithmeticShiftRight(State.A, 0) and $F);
        State.Cycles := Word(State.Cycles + 4);
        MemoryWrite(State, Callbacks, HlScope211, ((HlLowScope214 shl 4) or ALowScope216));
        ResultValue := (AHighScope215 shl 4) or HlHighScope213;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp418 := FLAG_MASK_ZERO
        else
          Temp418 := 0;
        State.F := Byte(State.F or Temp418);
        if ComputeParity(ResultValue) <> 0 then
          Temp419 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp419 := 0;
        State.F := Byte(State.F or Temp419);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_LDI:
      begin
        De := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        HlScope217 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        MemoryWrite(State, Callbacks, De, MemoryRead(State, Callbacks, HlScope217));
        State.L := (State.L + 1) and $FF;
        if State.L = 0 then
          State.H := (State.H + 1) and $FF;
        State.E := (State.E + 1) and $FF;
        if State.E = 0 then
          State.D := (State.D + 1) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (State.B or State.C) <> 0 then
          Temp420 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp420 := 0;
        State.F := Byte(State.F or Temp420);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_LDD:
      begin
        DeScope218 := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        HlScope219 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        MemoryWrite(State, Callbacks, DeScope218, MemoryRead(State, Callbacks, HlScope219));
        State.L := (State.L + $FF) and $FF;
        if State.L = $FF then
          State.H := (State.H + $FF) and $FF;
        State.E := (State.E + $FF) and $FF;
        if State.E = $FF then
          State.D := (State.D + $FF) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (State.B or State.C) <> 0 then
          Temp421 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp421 := 0;
        State.F := Byte(State.F or Temp421);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_LDIR:
      begin
        DeScope220 := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        HlScope221 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        MemoryWrite(State, Callbacks, DeScope220, MemoryRead(State, Callbacks, HlScope221));
        State.L := (State.L + 1) and $FF;
        if State.L = 0 then
          State.H := (State.H + 1) and $FF;
        State.E := (State.E + 1) and $FF;
        if State.E = 0 then
          State.D := (State.D + 1) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (State.B or State.C) <> 0 then
          Temp422 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp422 := 0;
        State.F := Byte(State.F or Temp422);
        State.Cycles := Word(State.Cycles + 2);
        if Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0 then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
        end;
      end;
    CLOWNZ80_OPCODE_LDDR:
      begin
        DeScope222 := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        HlScope223 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        MemoryWrite(State, Callbacks, DeScope222, MemoryRead(State, Callbacks, HlScope223));
        State.L := (State.L + $FF) and $FF;
        if State.L = $FF then
          State.H := (State.H + $FF) and $FF;
        State.E := (State.E + $FF) and $FF;
        if State.E = $FF then
          State.D := (State.D + $FF) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and ((FLAG_MASK_CARRY or FLAG_MASK_ZERO) or FLAG_MASK_SIGN));
        if (State.B or State.C) <> 0 then
          Temp423 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp423 := 0;
        State.F := Byte(State.F or Temp423);
        State.Cycles := Word(State.Cycles + 2);
        if Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0 then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
        end;
      end;
    CLOWNZ80_OPCODE_CPI:
      begin
        HlScope224 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        SourceValue := MemoryRead(State, Callbacks, HlScope224);
        DestinationValue := Cardinal(State.A);
        ResultValue := Sub32(DestinationValue, SourceValue);
        State.L := (State.L + 1) and $FF;
        if State.L = 0 then
          State.H := (State.H + 1) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if (State.B or State.C) <> 0 then
          Temp424 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp424 := 0;
        State.F := Byte(State.F or Temp424);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp425 := FLAG_MASK_ZERO
        else
          Temp425 := 0;
        State.F := Byte(State.F or Temp425);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_CPD:
      begin
        HlScope225 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        SourceValue := MemoryRead(State, Callbacks, HlScope225);
        DestinationValue := Cardinal(State.A);
        ResultValue := Sub32(DestinationValue, SourceValue);
        State.L := (State.L + $FF) and $FF;
        if State.L = $FF then
          State.H := (State.H + $FF) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if (State.B or State.C) <> 0 then
          Temp426 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp426 := 0;
        State.F := Byte(State.F or Temp426);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp427 := FLAG_MASK_ZERO
        else
          Temp427 := 0;
        State.F := Byte(State.F or Temp427);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_CPIR:
      begin
        HlScope226 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        SourceValue := MemoryRead(State, Callbacks, HlScope226);
        DestinationValue := Cardinal(State.A);
        ResultValue := Sub32(DestinationValue, SourceValue);
        State.L := (State.L + 1) and $FF;
        if State.L = 0 then
          State.H := (State.H + 1) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if (State.B or State.C) <> 0 then
          Temp428 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp428 := 0;
        State.F := Byte(State.F or Temp428);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp429 := FLAG_MASK_ZERO
        else
          Temp429 := 0;
        State.F := Byte(State.F or Temp429);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
        if (Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0) and (Integer(State.F and FLAG_MASK_ZERO) = 0) then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
        end;
      end;
    CLOWNZ80_OPCODE_CPDR:
      begin
        HlScope227 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        SourceValue := MemoryRead(State, Callbacks, HlScope227);
        DestinationValue := Cardinal(State.A);
        ResultValue := Sub32(DestinationValue, SourceValue);
        State.L := (State.L + $FF) and $FF;
        if State.L = $FF then
          State.H := (State.H + $FF) and $FF;
        State.C := (State.C + $FF) and $FF;
        if State.C = $FF then
          State.B := (State.B + $FF) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if (State.B or State.C) <> 0 then
          Temp431 := FLAG_MASK_PARITY_OVERFLOW
        else
          Temp431 := 0;
        State.F := Byte(State.F or Temp431);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          Temp432 := FLAG_MASK_ZERO
        else
          Temp432 := 0;
        State.F := Byte(State.F or Temp432);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
        if (Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0) and (Integer(State.F and FLAG_MASK_ZERO) = 0) then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
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

procedure ConstantInitialise;
begin
  for var ItemIndex := 0 to $100 - 1 do
  begin
    DecodeInstructionMetadata(InstructionMetadataLookupNormal[CLOWNZ80_REGISTER_MODE_HL][ItemIndex], CLOWNZ80_INSTRUCTION_MODE_NORMAL, CLOWNZ80_REGISTER_MODE_HL, ItemIndex);
    DecodeInstructionMetadata(InstructionMetadataLookupNormal[CLOWNZ80_REGISTER_MODE_IX][ItemIndex], CLOWNZ80_INSTRUCTION_MODE_NORMAL, CLOWNZ80_REGISTER_MODE_IX, ItemIndex);
    DecodeInstructionMetadata(InstructionMetadataLookupNormal[CLOWNZ80_REGISTER_MODE_IY][ItemIndex], CLOWNZ80_INSTRUCTION_MODE_NORMAL, CLOWNZ80_REGISTER_MODE_IY, ItemIndex);
    DecodeInstructionMetadata(InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_HL][ItemIndex], CLOWNZ80_INSTRUCTION_MODE_BITS, CLOWNZ80_REGISTER_MODE_HL, ItemIndex);
    DecodeInstructionMetadata(InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_IX][ItemIndex], CLOWNZ80_INSTRUCTION_MODE_BITS, CLOWNZ80_REGISTER_MODE_IX, ItemIndex);
    DecodeInstructionMetadata(InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_IY][ItemIndex], CLOWNZ80_INSTRUCTION_MODE_BITS, CLOWNZ80_REGISTER_MODE_IY, ItemIndex);
    DecodeInstructionMetadata(InstructionMetadataLookupMisc[ItemIndex], CLOWNZ80_INSTRUCTION_MODE_MISC, CLOWNZ80_REGISTER_MODE_HL, ItemIndex);
  end;
end;

procedure Z80StateInitialise(var State: TZ80State);
begin
  Z80Reset(State);
  State.Cycles := 1;
end;

procedure Z80Reset(var State: TZ80State);
begin
  State.RegisterMode := Byte(CLOWNZ80_REGISTER_MODE_HL);
  State.ProgramCounter := 0;
  State.InterruptsEnabled := 0;
  State.InterruptPending := 0;
end;

procedure Z80Interrupt(var State: TZ80State; AssertInterrupt: Byte);
begin
  State.InterruptPending := AssertInterrupt;
end;

function Z80DoInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks): Cardinal;
begin
  var Instruction: TZ80Instruction;
  State.Cycles := 0;
  DecodeInstruction(State, Callbacks, Instruction);
  ExecuteInstruction(State, Callbacks, Instruction);
  var Temp439: Integer := Ord(State.InterruptPending <> 0);
  if Temp439 <> 0 then
    Temp439 := Ord(State.InterruptsEnabled <> 0);
  var Temp438: Integer := Ord(Temp439 <> 0);
  if Temp438 <> 0 then
    Temp438 := Ord(Instruction.Metadata.Opcode <> Integer(CLOWNZ80_OPCODE_DD_PREFIX));
  var Temp437: Integer := Ord(Temp438 <> 0);
  if Temp437 <> 0 then
    Temp437 := Ord(Instruction.Metadata.Opcode <> Integer(CLOWNZ80_OPCODE_FD_PREFIX));
  var Temp436: Integer := Ord(Temp437 <> 0);
  if Temp436 <> 0 then
    Temp436 := Ord(Instruction.Metadata.Opcode <> Integer(CLOWNZ80_OPCODE_EI));
  if Temp436 <> 0 then
  begin
    State.InterruptsEnabled := 0;
    State.InterruptPending := 0;
    State.Cycles := Word(State.Cycles + 13);
    State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
    Callbacks.WriteCallback(Callbacks.UserData, State.StackPointer, ArithmeticShiftRight(State.ProgramCounter, 8));
    State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
    Callbacks.WriteCallback(Callbacks.UserData, State.StackPointer, (State.ProgramCounter and $FF));
    State.ProgramCounter := $38;
  end;
  Exit(Cardinal(State.Cycles));
end;

end.

