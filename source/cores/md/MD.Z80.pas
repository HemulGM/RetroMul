unit MD.Z80;

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
    Halted: Boolean;
    InterruptMode, EIDelay: Byte;
  end;

  TZ80ReadCallback = function(UserData: Pointer; Address: Cardinal): Cardinal;

  TZ80WriteCallback = procedure(UserData: Pointer; Address: Cardinal; Value: Cardinal);

  TZ80ReadAndWriteCallbacks = record
    ReadCallback: TZ80ReadCallback;
    WriteCallback: TZ80WriteCallback;
    PortReadCallback: TZ80ReadCallback;
    PortWriteCallback: TZ80WriteCallback;
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

const
  FLAG_MASK_CARRY = ( 1 shl FLAG_BIT_CARRY);
  FLAG_MASK_ADD_SUBTRACT = ( 1 shl FLAG_BIT_ADD_SUBTRACT);
  FLAG_MASK_PARITY_OVERFLOW = ( 1 shl FLAG_BIT_PARITY_OVERFLOW);
  FLAG_MASK_HALF_CARRY = ( 1 shl FLAG_BIT_HALF_CARRY);
  FLAG_MASK_ZERO = ( 1 shl FLAG_BIT_ZERO);
  FLAG_MASK_SIGN = ( 1 shl FLAG_BIT_SIGN);

const
  DECODE_REGISTERS: array[0..7] of Byte = (CLOWNZ80_OPERAND_B, CLOWNZ80_OPERAND_C, CLOWNZ80_OPERAND_D, CLOWNZ80_OPERAND_E, CLOWNZ80_OPERAND_H, CLOWNZ80_OPERAND_L, CLOWNZ80_OPERAND_HL_INDIRECT, CLOWNZ80_OPERAND_A);
  DECODE_REGISTER_PAIRS: array[0..3] of Byte = (CLOWNZ80_OPERAND_BC, CLOWNZ80_OPERAND_DE, CLOWNZ80_OPERAND_HL, CLOWNZ80_OPERAND_SP);

procedure DecodeNormalInstructionMetadata(var Metadata: TZ80InstructionMetadata; RegisterMode: Integer; Opcode: Byte);
const
  STACK_REGISTER_PAIRS: array[0..3] of Byte = (CLOWNZ80_OPERAND_BC, CLOWNZ80_OPERAND_DE, CLOWNZ80_OPERAND_HL, CLOWNZ80_OPERAND_AF);
  ARITHMETIC_LOGIC_OPCODES: array[0..7] of Byte = (CLOWNZ80_OPCODE_ADD_A, CLOWNZ80_OPCODE_ADC_A, CLOWNZ80_OPCODE_SUB, CLOWNZ80_OPCODE_SBC_A, CLOWNZ80_OPCODE_AND, CLOWNZ80_OPCODE_XOR, CLOWNZ80_OPCODE_OR, CLOWNZ80_OPCODE_CP);
begin
  // Operand 0 is the source; operand 1 is the destination.
  case Opcode of
    $00:
      Metadata.Opcode := CLOWNZ80_OPCODE_NOP;
    $08:
      Metadata.Opcode := CLOWNZ80_OPCODE_EX_AF_AF;
    $10:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_DJNZ;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
      end;
    $18:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_JR_UNCONDITIONAL;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
      end;
    $20, $28, $30, $38: // JR cc, displacement
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_JR_CONDITIONAL;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
        Metadata.Condition := (Opcode - $20) shr 3;
      end;
    $01, $11, $21, $31: // LD rr, nn
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_16_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_16_BIT;
        Metadata.Operands[1] := DECODE_REGISTER_PAIRS[Opcode shr 4];
      end;
    $09, $19, $29, $39: // ADD HL, rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_ADD_HL;
        Metadata.Operands[0] := DECODE_REGISTER_PAIRS[Opcode shr 4];
        Metadata.Operands[1] := CLOWNZ80_OPERAND_HL;
      end;
    $02:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_A;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_BC_INDIRECT;
      end;
    $12:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_A;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_DE_INDIRECT;
      end;
    $0A:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_BC_INDIRECT;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_A;
      end;
    $1A:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_DE_INDIRECT;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_A;
      end;
    $22:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_16_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_HL;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_ADDRESS;
      end;
    $2A:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_16_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_ADDRESS;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_HL;
      end;
    $32:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_A;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_ADDRESS;
      end;
    $3A:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_ADDRESS;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_A;
      end;
    $03, $13, $23, $33: // INC rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_INC_16_BIT;
        Metadata.Operands[1] := DECODE_REGISTER_PAIRS[Opcode shr 4];
      end;
    $0B, $1B, $2B, $3B: // DEC rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_DEC_16_BIT;
        Metadata.Operands[1] := DECODE_REGISTER_PAIRS[Opcode shr 4];
      end;
    $04, $0C, $14, $1C, $24, $2C, $34, $3C: // INC r
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_INC_8_BIT;
        Metadata.Operands[1] := DECODE_REGISTERS[Opcode shr 3];
      end;
    $05, $0D, $15, $1D, $25, $2D, $35, $3D: // DEC r
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_DEC_8_BIT;
        Metadata.Operands[1] := DECODE_REGISTERS[Opcode shr 3];
      end;
    $06, $0E, $16, $1E, $26, $2E, $36, $3E: // LD r, n
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
        Metadata.Operands[1] := DECODE_REGISTERS[Opcode shr 3];
      end;
    $07:
      Metadata.Opcode := CLOWNZ80_OPCODE_RLCA;
    $0F:
      Metadata.Opcode := CLOWNZ80_OPCODE_RRCA;
    $17:
      Metadata.Opcode := CLOWNZ80_OPCODE_RLA;
    $1F:
      Metadata.Opcode := CLOWNZ80_OPCODE_RRA;
    $27:
      Metadata.Opcode := CLOWNZ80_OPCODE_DAA;
    $2F:
      Metadata.Opcode := CLOWNZ80_OPCODE_CPL;
    $37:
      Metadata.Opcode := CLOWNZ80_OPCODE_SCF;
    $3F:
      Metadata.Opcode := CLOWNZ80_OPCODE_CCF;
    $40..$75, $77..$7F: // LD r, r
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_8_BIT;
        Metadata.Operands[0] := DECODE_REGISTERS[Opcode and $07];
        Metadata.Operands[1] := DECODE_REGISTERS[(Opcode shr 3) and $07];
      end;
    $76:
      Metadata.Opcode := CLOWNZ80_OPCODE_HALT;
    $80..$BF: // ALU A, r
      begin
        Metadata.Opcode := ARITHMETIC_LOGIC_OPCODES[(Opcode shr 3) and $07];
        Metadata.Operands[0] := DECODE_REGISTERS[Opcode and $07];
      end;
    $C0, $C8, $D0, $D8, $E0, $E8, $F0, $F8: // RET cc
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_RET_CONDITIONAL;
        Metadata.Condition := (Opcode shr 3) and $07;
      end;
    $C1, $D1, $E1, $F1: // POP rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_POP;
        Metadata.Operands[1] := STACK_REGISTER_PAIRS[(Opcode shr 4) and $03];
      end;
    $C9:
      Metadata.Opcode := CLOWNZ80_OPCODE_RET_UNCONDITIONAL;
    $D9:
      Metadata.Opcode := CLOWNZ80_OPCODE_EXX;
    $E9:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_JP_HL;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_HL;
      end;
    $F9:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_SP_HL;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_HL;
      end;
    $C2, $CA, $D2, $DA, $E2, $EA, $F2, $FA: // JP cc, nn
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_JP_CONDITIONAL;
        Metadata.Condition := (Opcode shr 3) and $07;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_16_BIT;
      end;
    $C3:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_JP_UNCONDITIONAL;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_16_BIT;
      end;
    $CB:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_CB_PREFIX;
        Metadata.HasDisplacement := Ord(RegisterMode <> CLOWNZ80_REGISTER_MODE_HL);
      end;
    $D3:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_OUT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
      end;
    $DB:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_IN;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
      end;
    $E3:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_EX_SP_HL;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_HL;
      end;
    $EB:
      Metadata.Opcode := CLOWNZ80_OPCODE_EX_DE_HL;
    $F3:
      Metadata.Opcode := CLOWNZ80_OPCODE_DI;
    $FB:
      Metadata.Opcode := CLOWNZ80_OPCODE_EI;
    $C4, $CC, $D4, $DC, $E4, $EC, $F4, $FC: // CALL cc, nn
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_CALL_CONDITIONAL;
        Metadata.Condition := (Opcode shr 3) and $07;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_16_BIT;
      end;
    $C5, $D5, $E5, $F5: // PUSH rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_PUSH;
        Metadata.Operands[0] := STACK_REGISTER_PAIRS[(Opcode shr 4) and $03];
      end;
    $CD:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_CALL_UNCONDITIONAL;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_16_BIT;
      end;
    $DD:
      Metadata.Opcode := CLOWNZ80_OPCODE_DD_PREFIX;
    $ED:
      Metadata.Opcode := CLOWNZ80_OPCODE_ED_PREFIX;
    $FD:
      Metadata.Opcode := CLOWNZ80_OPCODE_FD_PREFIX;
    $C6, $CE, $D6, $DE, $E6, $EE, $F6, $FE: // ALU A, n
      begin
        Metadata.Opcode := ARITHMETIC_LOGIC_OPCODES[(Opcode shr 3) and $07];
        Metadata.Operands[0] := CLOWNZ80_OPERAND_LITERAL_8_BIT;
      end;
    $C7, $CF, $D7, $DF, $E7, $EF, $F7, $FF:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_RST;
        Metadata.EmbeddedLiteral := Opcode and $38;
      end;
  end;
end;

procedure DecodeBitsInstructionMetadata(var Metadata: TZ80InstructionMetadata; Opcode: Byte);
const
  ROTATE_SHIFT_OPCODES: array[0..7] of Byte = (CLOWNZ80_OPCODE_RLC, CLOWNZ80_OPCODE_RRC, CLOWNZ80_OPCODE_RL, CLOWNZ80_OPCODE_RR, CLOWNZ80_OPCODE_SLA, CLOWNZ80_OPCODE_SRA, CLOWNZ80_OPCODE_SLL, CLOWNZ80_OPCODE_SRL);
begin
  Metadata.Operands[1] := DECODE_REGISTERS[Opcode and $07];
  case Opcode of
    $00..$3F:
      Metadata.Opcode := ROTATE_SHIFT_OPCODES[Opcode shr 3];
    $40..$7F:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_BIT;
        Metadata.EmbeddedLiteral := 1 shl ((Opcode shr 3) and $07);
      end;
    $80..$BF:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_RES;
        Metadata.EmbeddedLiteral := Byte(not (1 shl ((Opcode shr 3) and $07)));
      end;
    $C0..$FF:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_SET;
        Metadata.EmbeddedLiteral := 1 shl ((Opcode shr 3) and $07);
      end;
  end;
end;

procedure DecodeMiscInstructionMetadata(var Metadata: TZ80InstructionMetadata; Opcode: Byte);
begin
  Metadata.EmbeddedLiteral := Opcode;
  case Opcode of
    $40, $48, $50, $58, $60, $68, $78:
      Metadata.Opcode := CLOWNZ80_OPCODE_IN_REGISTER;
    $70:
      Metadata.Opcode := CLOWNZ80_OPCODE_IN_NO_REGISTER;
    $41, $49, $51, $59, $61, $69, $79:
      Metadata.Opcode := CLOWNZ80_OPCODE_OUT_REGISTER;
    $71:
      Metadata.Opcode := CLOWNZ80_OPCODE_OUT_NO_REGISTER;
    $42, $52, $62, $72: // SBC HL, rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_SBC_HL;
        Metadata.Operands[0] := DECODE_REGISTER_PAIRS[(Opcode shr 4) and $03];
        Metadata.Operands[1] := CLOWNZ80_OPERAND_HL;
      end;
    $4A, $5A, $6A, $7A: // ADC HL, rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_ADC_HL;
        Metadata.Operands[0] := DECODE_REGISTER_PAIRS[(Opcode shr 4) and $03];
        Metadata.Operands[1] := CLOWNZ80_OPERAND_HL;
      end;
    $43, $53, $63, $73: // LD (nn), rr
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_16_BIT;
        Metadata.Operands[0] := DECODE_REGISTER_PAIRS[(Opcode shr 4) and $03];
        Metadata.Operands[1] := CLOWNZ80_OPERAND_ADDRESS;
      end;
    $4B, $5B, $6B, $7B: // LD rr, (nn)
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_LD_16_BIT;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_ADDRESS;
        Metadata.Operands[1] := DECODE_REGISTER_PAIRS[(Opcode shr 4) and $03];
      end;
    $44, $4C, $54, $5C, $64, $6C, $74, $7C:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_NEG;
        Metadata.Operands[0] := CLOWNZ80_OPERAND_A;
        Metadata.Operands[1] := CLOWNZ80_OPERAND_A;
      end;
    $45, $55, $5D, $65, $6D, $75, $7D:
      Metadata.Opcode := CLOWNZ80_OPCODE_RETN;
    $4D:
      Metadata.Opcode := CLOWNZ80_OPCODE_RETI;
    $46, $4E, $66, $6E:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_IM;
        Metadata.EmbeddedLiteral := 0;
      end;
    $56, $76:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_IM;
        Metadata.EmbeddedLiteral := 1;
      end;
    $5E, $7E:
      begin
        Metadata.Opcode := CLOWNZ80_OPCODE_IM;
        Metadata.EmbeddedLiteral := 2;
      end;
    $47:
      Metadata.Opcode := CLOWNZ80_OPCODE_LD_I_A;
    $4F:
      Metadata.Opcode := CLOWNZ80_OPCODE_LD_R_A;
    $57:
      Metadata.Opcode := CLOWNZ80_OPCODE_LD_A_I;
    $5F:
      Metadata.Opcode := CLOWNZ80_OPCODE_LD_A_R;
    $67:
      Metadata.Opcode := CLOWNZ80_OPCODE_RRD;
    $6F:
      Metadata.Opcode := CLOWNZ80_OPCODE_RLD;
    $A0:
      Metadata.Opcode := CLOWNZ80_OPCODE_LDI;
    $A8:
      Metadata.Opcode := CLOWNZ80_OPCODE_LDD;
    $B0:
      Metadata.Opcode := CLOWNZ80_OPCODE_LDIR;
    $B8:
      Metadata.Opcode := CLOWNZ80_OPCODE_LDDR;
    $A1:
      Metadata.Opcode := CLOWNZ80_OPCODE_CPI;
    $A9:
      Metadata.Opcode := CLOWNZ80_OPCODE_CPD;
    $B1:
      Metadata.Opcode := CLOWNZ80_OPCODE_CPIR;
    $B9:
      Metadata.Opcode := CLOWNZ80_OPCODE_CPDR;
    $A2:
      Metadata.Opcode := CLOWNZ80_OPCODE_INI;
    $AA:
      Metadata.Opcode := CLOWNZ80_OPCODE_IND;
    $B2:
      Metadata.Opcode := CLOWNZ80_OPCODE_INIR;
    $BA:
      Metadata.Opcode := CLOWNZ80_OPCODE_INDR;
    $A3:
      Metadata.Opcode := CLOWNZ80_OPCODE_OUTI;
    $AB:
      Metadata.Opcode := CLOWNZ80_OPCODE_OUTD;
    $B3:
      Metadata.Opcode := CLOWNZ80_OPCODE_OTIR;
    $BB:
      Metadata.Opcode := CLOWNZ80_OPCODE_OTDR;
  else
    Metadata.Opcode := CLOWNZ80_OPCODE_NOP;
  end;
end;

procedure ApplyInstructionRegisterMode(var Metadata: TZ80InstructionMetadata; RegisterMode: Integer);
begin
  for var i := 0 to 1 do
  begin
    var OtherOperand := i xor 1;
    if (Metadata.Operands[OtherOperand] = CLOWNZ80_OPERAND_HL_INDIRECT) or
      (Metadata.Operands[OtherOperand] = CLOWNZ80_OPERAND_IX_INDIRECT) or
      (Metadata.Operands[OtherOperand] = CLOWNZ80_OPERAND_IY_INDIRECT)
      then
      Continue;

    case Metadata.Operands[i] of
      CLOWNZ80_OPERAND_H:
        case RegisterMode of
          CLOWNZ80_REGISTER_MODE_IX:
            Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IXH);
          CLOWNZ80_REGISTER_MODE_IY:
            Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IYH);
        end;
      CLOWNZ80_OPERAND_L:
        case RegisterMode of
          CLOWNZ80_REGISTER_MODE_IX:
            Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IXL);
          CLOWNZ80_REGISTER_MODE_IY:
            Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IYL);
        end;
      CLOWNZ80_OPERAND_HL:
        case RegisterMode of
          CLOWNZ80_REGISTER_MODE_IX:
            Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IX);
          CLOWNZ80_REGISTER_MODE_IY:
            Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IY);
        end;
      CLOWNZ80_OPERAND_HL_INDIRECT:
        case RegisterMode of
          CLOWNZ80_REGISTER_MODE_IX:
            begin
              Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IX_INDIRECT);
              Metadata.HasDisplacement := 1;
            end;
          CLOWNZ80_REGISTER_MODE_IY:
            begin
              Metadata.Operands[i] := Byte(CLOWNZ80_OPERAND_IY_INDIRECT);
              Metadata.HasDisplacement := 1;
            end;
        end;
    end;
  end;
end;

procedure DecodeInstructionMetadata(var Metadata: TZ80InstructionMetadata; InstructionMode: Integer; RegisterMode: Integer; Opcode: Byte);
begin
  Metadata.HasDisplacement := 0;
  Metadata.Operands[0] := CLOWNZ80_OPERAND_NONE;
  Metadata.Operands[1] := CLOWNZ80_OPERAND_NONE;
  case InstructionMode of
    CLOWNZ80_INSTRUCTION_MODE_NORMAL:
      DecodeNormalInstructionMetadata(Metadata, RegisterMode, Opcode);
    CLOWNZ80_INSTRUCTION_MODE_BITS:
      DecodeBitsInstructionMetadata(Metadata, Opcode);
    CLOWNZ80_INSTRUCTION_MODE_MISC:
      DecodeMiscInstructionMetadata(Metadata, Opcode);
  end;
  ApplyInstructionRegisterMode(Metadata, RegisterMode);
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
  Result := Cardinal(Callbacks.ReadCallback(Callbacks.UserData, Address));
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
  Result := Data;
end;

function OpcodeFetch(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks): Cardinal;
begin
  Inc(State.Cycles);
  State.R := Byte((State.R and $80) or ((State.R + 1) and $7F));
  Result := InstructionMemoryRead(State, Callbacks);
end;

function MemoryRead16Bit(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := MemoryRead(State, Callbacks, (Address));
  Result := Value or (MemoryRead(State, Callbacks, (Add32(Address, 1) and $FFFF)) shl 8);
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
        if Instruction.Metadata.Opcode = CLOWNZ80_OPCODE_LD_16_BIT then
          Value := Value or (MemoryRead(State, Callbacks, (Add32(Instruction.Address, 1))) shl 8);
      end;
  else
    Value := Cardinal(State.A);
  end;
  Result := Value;
end;

procedure WriteOperand(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction; Operand: Integer; Value: Cardinal);
begin
  var DoublePrefixOperand: Integer;
  if State.RegisterMode = CLOWNZ80_REGISTER_MODE_IX then
    DoublePrefixOperand := CLOWNZ80_OPERAND_IX_INDIRECT
  else
    DoublePrefixOperand := CLOWNZ80_OPERAND_IY_INDIRECT;

  if (Instruction.DoublePrefixMode <> 0) and (Operand <> DoublePrefixOperand) then
    WriteOperand(State, Callbacks, Instruction, DoublePrefixOperand, Value);

  case Operand of
    CLOWNZ80_OPERAND_NONE,            //
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
        if Instruction.Metadata.Opcode = CLOWNZ80_OPCODE_LD_16_BIT then
          MemoryWrite16Bit(State, Callbacks, Instruction.Address, Value)
        else
          MemoryWrite(State, Callbacks, Instruction.Address, Value);
      end;
  end;
end;

// An 8-bit signed displacement is added in a wider signed type, then wrapped
// explicitly to the Z80's 16-bit address bus.
function RelativeAddress(Address, Displacement: Cardinal): Word; inline;
begin
  var SignedDisplacement := Integer(Displacement and $7F) - Integer(Displacement and $80);
  Result := (Integer(Address and $FFFF) + SignedDisplacement) and $FFFF;
end;

procedure DecodeInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction);
begin
  var Opcode: Cardinal := OpcodeFetch(State, Callbacks);
  var Displacement: Cardinal := 0;

  Instruction.Metadata := InstructionMetadataLookupNormal[State.RegisterMode][Opcode];
  if Instruction.Metadata.HasDisplacement <> 0 then
  begin
    Displacement := InstructionMemoryRead(State, Callbacks);
    State.Cycles := Word(State.Cycles + 5);
  end;

  Instruction.DoublePrefixMode := 0;
  case Instruction.Metadata.Opcode of
    CLOWNZ80_OPCODE_CB_PREFIX:
      if State.RegisterMode = CLOWNZ80_REGISTER_MODE_HL then
      begin
        Opcode := OpcodeFetch(State, Callbacks);
        Instruction.Metadata := InstructionMetadataLookupBits[State.RegisterMode][Opcode];
      end
      else
      begin
        Instruction.DoublePrefixMode := 1;
        Opcode := InstructionMemoryRead(State, Callbacks);
        State.Cycles := Word(State.Cycles - 3);
        if State.RegisterMode = CLOWNZ80_REGISTER_MODE_IX then
          Instruction.Address := RelativeAddress((State.IXH shl 8) or State.IXL, Displacement)
        else
          Instruction.Address := RelativeAddress((State.IYH shl 8) or State.IYL, Displacement);
        Instruction.Metadata := InstructionMetadataLookupBits[CLOWNZ80_REGISTER_MODE_HL][Opcode];
        if Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT then
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

  for var i := 0 to 1 do
    case Instruction.Metadata.Operands[i] of
      CLOWNZ80_OPERAND_BC_INDIRECT:
        Instruction.Address := (Cardinal(State.B) shl 8) or Cardinal(State.C);
      CLOWNZ80_OPERAND_DE_INDIRECT:
        Instruction.Address := (Cardinal(State.D) shl 8) or Cardinal(State.E);
      CLOWNZ80_OPERAND_HL_INDIRECT:
        Instruction.Address := (Cardinal(State.H) shl 8) or Cardinal(State.L);
      CLOWNZ80_OPERAND_IX_INDIRECT:
        Instruction.Address := RelativeAddress((State.IXH shl 8) or State.IXL, Displacement);
      CLOWNZ80_OPERAND_IY_INDIRECT:
        Instruction.Address := RelativeAddress((State.IYH shl 8) or State.IYL, Displacement);
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
  Result := Ord((Value and 1) = 0);
end;

procedure ExecuteInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks; var Instruction: TZ80Instruction);
begin
  var DestinationValue: Cardinal;
  var ResultValue: Cardinal;
  var ResultValueWithCarry: Cardinal;
  var ResultValueWithCarry16bit: Cardinal;
  var SwapHolder: Byte;
  var Carry: Byte;
  var CorrectionFactor: Cardinal;
  var OriginalA: Cardinal;
  var Hl: Cardinal;
  var HlValue: Cardinal;
  var HlHigh: Cardinal;
  var HlLow: Cardinal;
  var AHigh: Cardinal;
  var ALow: Cardinal;
  var HlScope211: Cardinal;
  var HlValueScope212: Cardinal;
  var HlHighScope213: Cardinal;
  var HlLowScope214: Cardinal;
  var AHighScope215: Cardinal;
  var ALowScope216: Cardinal;
  var De: Cardinal;
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
          State.ProgramCounter := RelativeAddress(State.ProgramCounter, Instruction.Literal);
          State.Cycles := Word(State.Cycles + 5);
        end;
      end;
    CLOWNZ80_OPCODE_JR_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State.F, Instruction.Metadata.Condition) then
            Break;

          State.ProgramCounter := RelativeAddress(State.ProgramCounter, Instruction.Literal);
          State.Cycles := Word(State.Cycles + 5);
        until True;
      end;
    CLOWNZ80_OPCODE_JR_UNCONDITIONAL:
      begin
        State.ProgramCounter := RelativeAddress(State.ProgramCounter, Instruction.Literal);
        State.Cycles := Word(State.Cycles + 5);
      end;
    CLOWNZ80_OPCODE_LD_8_BIT, CLOWNZ80_OPCODE_LD_16_BIT:
      begin
        var SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        ResultValue := SourceValue;
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
      end;
    CLOWNZ80_OPCODE_ADD_HL:
      begin
        var SourceValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
        var SourceValue: Cardinal := 1;
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
        var SourceValue: Cardinal := $FFFFFFFF;
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
      State.Halted := True;
    CLOWNZ80_OPCODE_ADD_A:
      begin
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValue := DestinationValue and SourceValue;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        State.F := Byte(State.F or FLAG_MASK_HALF_CARRY);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_XOR:
      begin
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValue := DestinationValue xor SourceValue;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_OR:
      begin
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := Cardinal(State.A);
        ResultValue := DestinationValue or SourceValue;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_CP:
      begin
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        SourceValue := not SourceValue;
        DestinationValue := Cardinal(State.A);
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), 1);
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
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        State.StackPointer := Word(SourceValue);
      end;
    CLOWNZ80_OPCODE_JP_CONDITIONAL:
      begin
        repeat
          if not EvaluateCondition(State.F, Instruction.Metadata.Condition) then
            Break;

          var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
          State.ProgramCounter := Word(SourceValue);
        until True;
      end;
    CLOWNZ80_OPCODE_JP_UNCONDITIONAL, CLOWNZ80_OPCODE_JP_HL:
      begin
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
        var Port := (Cardinal(State.A) shl 8) or ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        if Instruction.Metadata.Opcode = CLOWNZ80_OPCODE_OUT then
        begin
          if Assigned(Callbacks.PortWriteCallback) then
            Callbacks.PortWriteCallback(Callbacks.UserData, Port, State.A);
        end
        else
        begin
          State.A := $FF;
          if Assigned(Callbacks.PortReadCallback) then
            State.A := Callbacks.PortReadCallback(Callbacks.UserData, Port) and $FF;
        end;
        State.Cycles := Word(State.Cycles + 4);
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
        State.EIDelay := 0;
      end;
    CLOWNZ80_OPCODE_EI:
      begin
        State.InterruptsEnabled := 1;
        State.EIDelay := 2;
      end;
    CLOWNZ80_OPCODE_PUSH:
      begin
        State.Cycles := Word(State.Cycles + 1);
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
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
          ResultValue := ResultValue or Cardinal($01);
        State.F := 0;
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp357 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp356 := Ord((Temp357 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp356);
      end;
    CLOWNZ80_OPCODE_RRC:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := DestinationValue shr 1;
        if Carry <> 0 then
          ResultValue := ResultValue or Cardinal($80);
        State.F := 0;
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp363 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp362 := Ord((Temp363 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp362);
      end;
    CLOWNZ80_OPCODE_RL:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := (DestinationValue shl 1) and $FF;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if State.F <> 0 then
          ResultValue := ResultValue or Cardinal($01);
        State.F := 0;
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp369 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp368 := Ord((Temp369 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp368);
      end;
    CLOWNZ80_OPCODE_RR:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := DestinationValue shr 1;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if State.F <> 0 then
          ResultValue := ResultValue or Cardinal($80);
        State.F := 0;
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp375 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp374 := Ord((Temp375 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp374);
      end;
    CLOWNZ80_OPCODE_SLA:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := (DestinationValue shl 1) and $FF;
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_SIGN);
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp381 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp380 := Ord((Temp381 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp380);
      end;
    CLOWNZ80_OPCODE_SLL:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $80) <> 0);
        ResultValue := ((DestinationValue shl 1) or 1) and $FF;
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_SIGN);
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp387 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp386 := Ord((Temp387 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp386);
      end;
    CLOWNZ80_OPCODE_SRA:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := (DestinationValue shr 1) or (DestinationValue and $80);
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_SIGN);
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp393 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp392 := Ord((Temp393 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp392);
      end;
    CLOWNZ80_OPCODE_SRL:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        Carry := Ord((DestinationValue and $01) <> 0);
        ResultValue := DestinationValue shr 1;
        State.F := 0;
        if (ResultValue and $80) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_SIGN);
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        if Carry <> 0 then
          State.F := Byte(State.F or FLAG_MASK_CARRY);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp399 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp398 := Ord((Temp399 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp398);
      end;
    CLOWNZ80_OPCODE_BIT:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        if (DestinationValue and Cardinal(Instruction.Metadata.EmbeddedLiteral)) = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO or FLAG_MASK_PARITY_OVERFLOW);
        State.F := Byte(State.F or FLAG_MASK_HALF_CARRY);
        if (Instruction.Metadata.EmbeddedLiteral = $80) and (Integer(State.F and FLAG_MASK_ZERO) = 0) then
          State.F := Byte(State.F or FLAG_MASK_SIGN);
        var Temp404 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp403 := Ord((Temp404 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp403);
      end;
    CLOWNZ80_OPCODE_RES:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := DestinationValue and Cardinal(Instruction.Metadata.EmbeddedLiteral);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp406 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp405 := Ord((Temp406 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp405);
      end;
    CLOWNZ80_OPCODE_SET:
      begin
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValue := DestinationValue or Cardinal(Instruction.Metadata.EmbeddedLiteral);
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        var Temp408 := Ord((Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_HL_INDIRECT) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IX_INDIRECT));
        var Temp407 := Ord((Temp408 <> 0) or (Instruction.Metadata.Operands[1] = CLOWNZ80_OPERAND_IY_INDIRECT));
        State.Cycles := Word(State.Cycles + Temp407);
      end;
    CLOWNZ80_OPCODE_IN_REGISTER, CLOWNZ80_OPCODE_IN_NO_REGISTER, CLOWNZ80_OPCODE_OUT_REGISTER, CLOWNZ80_OPCODE_OUT_NO_REGISTER:
      begin
        var Port := (Cardinal(State.B) shl 8) or State.C;
        var Reg := DECODE_REGISTERS[(Instruction.Metadata.EmbeddedLiteral shr 3) and 7];
        if Instruction.Metadata.Opcode in [CLOWNZ80_OPCODE_OUT_REGISTER, CLOWNZ80_OPCODE_OUT_NO_REGISTER] then
        begin
          var Value: Cardinal := 0;
          if Instruction.Metadata.Opcode = CLOWNZ80_OPCODE_OUT_REGISTER then
            Value := ReadOperand(State, Callbacks, Instruction, Reg);
          if Assigned(Callbacks.PortWriteCallback) then
            Callbacks.PortWriteCallback(Callbacks.UserData, Port, Value);
        end
        else
        begin
          var Value: Cardinal := $FF;
          if Assigned(Callbacks.PortReadCallback) then
            Value := Callbacks.PortReadCallback(Callbacks.UserData, Port) and $FF;
          if Instruction.Metadata.Opcode = CLOWNZ80_OPCODE_IN_REGISTER then
            WriteOperand(State, Callbacks, Instruction, Reg, Value);
          State.F := (State.F and FLAG_MASK_CARRY) or (Value and $A8);
          if Value = 0 then
            State.F := State.F or FLAG_MASK_ZERO;
          if ComputeParity(Value) <> 0 then
            State.F := State.F or FLAG_MASK_PARITY_OVERFLOW;
        end;
        State.Cycles := Word(State.Cycles + 4);
      end;
    CLOWNZ80_OPCODE_SBC_HL:
      begin
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        SourceValue := not SourceValue;
        var Temp409: Integer;
        if Integer(State.F and FLAG_MASK_CARRY) <> 0 then
          Temp409 := 0
        else
          Temp409 := 1;
        ResultValueWithCarry16bit := Add32(Add32(SourceValue, DestinationValue), Temp409);
        ResultValue := ResultValueWithCarry16bit and $FFFF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (15 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
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
        var SourceValue: Cardinal := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[0]);
        DestinationValue := ReadOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1]);
        ResultValueWithCarry16bit := Add32(Add32(SourceValue, DestinationValue), Ord(Integer(State.F and FLAG_MASK_CARRY) <> 0));
        ResultValue := ResultValueWithCarry16bit and $FFFF;
        State.F := 0;
        State.F := Byte(State.F or ((ResultValue shr (15 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (12 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or ((((not (SourceValue xor DestinationValue)) and (SourceValue xor ResultValue)) shr (15 - FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(FLAG_MASK_PARITY_OVERFLOW)));
        State.F := Byte(State.F or ((ResultValueWithCarry16bit shr (16 - FLAG_BIT_CARRY)) and Cardinal(FLAG_MASK_CARRY)));
        WriteOperand(State, Callbacks, Instruction, Instruction.Metadata.Operands[1], ResultValue);
        State.Cycles := Word(State.Cycles + 7);
      end;
    CLOWNZ80_OPCODE_NEG:
      begin
        var SourceValue: Cardinal := Cardinal(State.A);
        SourceValue := not SourceValue;
        DestinationValue := 0;
        ResultValueWithCarry := Add32(Add32(DestinationValue, SourceValue), 1);
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
    CLOWNZ80_OPCODE_IM:
      State.InterruptMode := Instruction.Metadata.EmbeddedLiteral;
    CLOWNZ80_OPCODE_LD_I_A:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.i := State.A;
      end;
    CLOWNZ80_OPCODE_LD_R_A:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.R := State.A;
      end;
    CLOWNZ80_OPCODE_LD_A_I:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.A := State.i;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or (ArithmeticShiftRight(State.A, (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        if State.A = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
      end;
    CLOWNZ80_OPCODE_LD_A_R:
      begin
        State.Cycles := Word(State.Cycles + 1);
        State.A := State.R;
        State.F := Byte(State.F and FLAG_MASK_CARRY);
        State.F := Byte(State.F or (ArithmeticShiftRight(State.A, (7 - FLAG_BIT_SIGN)) and FLAG_MASK_SIGN));
        if State.A = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
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
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
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
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        if ComputeParity(ResultValue) <> 0 then
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.A := Byte(ResultValue);
      end;
    CLOWNZ80_OPCODE_LDI:
      begin
        De := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        var HlScope217 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_LDD:
      begin
        var DeScope218 := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        var HlScope219 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_LDIR:
      begin
        var DeScope220 := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        var HlScope221 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.Cycles := Word(State.Cycles + 2);
        if Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0 then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
        end;
      end;
    CLOWNZ80_OPCODE_LDDR:
      begin
        var DeScope222 := (Cardinal(State.D) shl 8) or Cardinal(State.E);
        var HlScope223 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.Cycles := Word(State.Cycles + 2);
        if Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0 then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
        end;
      end;
    CLOWNZ80_OPCODE_CPI:
      begin
        var HlScope224 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        var SourceValue: Cardinal := MemoryRead(State, Callbacks, HlScope224);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_CPD:
      begin
        var HlScope225 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        var SourceValue: Cardinal := MemoryRead(State, Callbacks, HlScope225);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
      end;
    CLOWNZ80_OPCODE_CPIR:
      begin
        var HlScope226 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        var SourceValue: Cardinal := MemoryRead(State, Callbacks, HlScope226);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
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
        var HlScope227 := (Cardinal(State.H) shl 8) or Cardinal(State.L);
        var SourceValue: Cardinal := MemoryRead(State, Callbacks, HlScope227);
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
          State.F := Byte(State.F or FLAG_MASK_PARITY_OVERFLOW);
        State.F := Byte(State.F or ((ResultValue shr (7 - FLAG_BIT_SIGN)) and Cardinal(FLAG_MASK_SIGN)));
        if ResultValue = 0 then
          State.F := Byte(State.F or FLAG_MASK_ZERO);
        State.F := Byte(State.F or ((((SourceValue xor DestinationValue) xor ResultValue) shr (4 - FLAG_BIT_HALF_CARRY)) and Cardinal(FLAG_MASK_HALF_CARRY)));
        State.F := Byte(State.F or FLAG_MASK_ADD_SUBTRACT);
        State.Cycles := Word(State.Cycles + 2);
        if (Integer(State.F and FLAG_MASK_PARITY_OVERFLOW) <> 0) and (Integer(State.F and FLAG_MASK_ZERO) = 0) then
        begin
          State.Cycles := Word(State.Cycles + 5);
          State.ProgramCounter := (State.ProgramCounter + $FFFE) and $FFFF;
        end;
      end;
    CLOWNZ80_OPCODE_INI, CLOWNZ80_OPCODE_IND, CLOWNZ80_OPCODE_INIR, CLOWNZ80_OPCODE_INDR, CLOWNZ80_OPCODE_OUTI, CLOWNZ80_OPCODE_OUTD, CLOWNZ80_OPCODE_OTIR, CLOWNZ80_OPCODE_OTDR:
      begin
        var Opcode := Instruction.Metadata.EmbeddedLiteral;
        var Input := (Opcode and 1) = 0;
        var Delta: Integer := 1;
        if (Opcode and 8) <> 0 then
          Delta := -1;
        var Address := (Cardinal(State.H) shl 8) or State.L;
        var Port := (Cardinal(State.B) shl 8) or State.C;
        var Data: Cardinal := $FF;
        if Input then
        begin
          if Assigned(Callbacks.PortReadCallback) then
            Data := Callbacks.PortReadCallback(Callbacks.UserData, Port) and 255;
          MemoryWrite(State, Callbacks, Address, Data);
        end
        else
          Data := MemoryRead(State, Callbacks, Address);
        State.B := (Integer(State.B) + 255) and 255;
        Address := (Integer(Address) + 65536 + Delta) and $FFFF;
        State.H := Address shr 8;
        State.L := Address and 255;
        var Sum: Integer;
        if Input then
          Sum := Integer(Data) + ((Integer(State.C) + 256 + Delta) and 255)
        else
        begin
          Sum := Integer(Data) + State.L;
          if Assigned(Callbacks.PortWriteCallback) then
            Callbacks.PortWriteCallback(Callbacks.UserData, (Cardinal(State.B) shl 8) or State.C, Data);
        end;
        State.F := State.B and $A8;
        if State.B = 0 then
          State.F := State.F or FLAG_MASK_ZERO;
        if (Data and 128) <> 0 then
          State.F := State.F or FLAG_MASK_ADD_SUBTRACT;
        if Sum > 255 then
          State.F := State.F or FLAG_MASK_HALF_CARRY or FLAG_MASK_CARRY;
        if ComputeParity((Sum and 7) xor State.B) <> 0 then
          State.F := State.F or FLAG_MASK_PARITY_OVERFLOW;
        Inc(State.Cycles, 5);
        if ((Opcode and $10) <> 0) and (State.B <> 0) then
        begin
          Inc(State.Cycles, 5);
          State.ProgramCounter := (Integer(State.ProgramCounter) + $FFFE) and $FFFF;
        end;
      end;
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
  State.Halted := False;
  State.InterruptMode := 0;
  State.EIDelay := 0;
end;

procedure Z80Interrupt(var State: TZ80State; AssertInterrupt: Byte);
begin
  State.InterruptPending := AssertInterrupt;
end;

function Z80DoInstruction(var State: TZ80State; var Callbacks: TZ80ReadAndWriteCallbacks): Cardinal;
begin
  var Instruction: TZ80Instruction;
  State.Cycles := 0;
  // Interrupts are accepted at instruction boundaries, never between DD/FD and
  // the following opcode. EI defers acceptance until one full instruction ends.
  if (State.InterruptPending <> 0) and (State.InterruptsEnabled <> 0) and
    (State.EIDelay = 0) and (State.RegisterMode = CLOWNZ80_REGISTER_MODE_HL) then
  begin
    State.InterruptsEnabled := 0;
    State.Halted := False;
    State.R := Byte((State.R and $80) or ((State.R + 1) and $7F));
    State.Cycles := 13;
    State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
    Callbacks.WriteCallback(Callbacks.UserData, State.StackPointer, ArithmeticShiftRight(State.ProgramCounter, 8));
    State.StackPointer := (State.StackPointer + $FFFF) and $FFFF;
    Callbacks.WriteCallback(Callbacks.UserData, State.StackPointer, (State.ProgramCounter and $FF));
    // The Mega Drive's undriven interrupt data bus supplies $FF (RST $38 in IM 0).
    if State.InterruptMode = 2 then
    begin
      State.ProgramCounter := Word(MemoryRead16Bit(State, Callbacks,
          (Cardinal(State.i) shl 8) or $FF));
      State.Cycles := 19;
    end
    else
      State.ProgramCounter := $38;
    Exit(State.Cycles);
  end;

  if State.Halted then
  begin
    State.R := Byte((State.R and $80) or ((State.R + 1) and $7F));
    State.Cycles := 4;
    Exit(State.Cycles);
  end;

  DecodeInstruction(State, Callbacks, Instruction);
  ExecuteInstruction(State, Callbacks, Instruction);
  if (State.EIDelay > 0) and
    (Instruction.Metadata.Opcode <> CLOWNZ80_OPCODE_DD_PREFIX) and
    (Instruction.Metadata.Opcode <> CLOWNZ80_OPCODE_FD_PREFIX) then
    Dec(State.EIDelay);
  Result := Cardinal(State.Cycles);
end;

end.

