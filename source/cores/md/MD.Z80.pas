unit MD.Z80;

{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

type
  TZ80InstructionMetadata = record
    c_opcode: Byte;
    c_operands: array[0..1] of Byte;
    c_condition: Byte;
    c_embedded_literal: Byte;
    c_has_displacement: Byte;
  end;

  TZ80State = record
    c_register_mode: Byte;
    c_cycles: Word;
    c_program_counter: Word;
    c_stack_pointer: Word;
    c_a: Byte;
    c_f: Byte;
    c_b: Byte;
    c_c: Byte;
    c_d: Byte;
    c_e: Byte;
    c_h: Byte;
    c_l: Byte;
    c_a_: Byte;
    c_f_: Byte;
    c_b_: Byte;
    c_c_: Byte;
    c_d_: Byte;
    c_e_: Byte;
    c_h_: Byte;
    c_l_: Byte;
    c_ixh: Byte;
    c_ixl: Byte;
    c_iyh: Byte;
    c_iyl: Byte;
    c_r: Byte;
    c_i: Byte;
    c_interrupts_enabled: Byte;
    c_interrupt_pending: Byte;
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

const
  c_CLOWNZ80_OPCODE_NOP = ( -1) + 1;
  c_CLOWNZ80_OPCODE_EX_AF_AF = ( c_CLOWNZ80_OPCODE_NOP) + 1;
  c_CLOWNZ80_OPCODE_DJNZ = ( c_CLOWNZ80_OPCODE_EX_AF_AF) + 1;
  c_CLOWNZ80_OPCODE_JR_UNCONDITIONAL = ( c_CLOWNZ80_OPCODE_DJNZ) + 1;
  c_CLOWNZ80_OPCODE_JR_CONDITIONAL = ( c_CLOWNZ80_OPCODE_JR_UNCONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_LD_16BIT = ( c_CLOWNZ80_OPCODE_JR_CONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_ADD_HL = ( c_CLOWNZ80_OPCODE_LD_16BIT) + 1;
  c_CLOWNZ80_OPCODE_LD_8BIT = ( c_CLOWNZ80_OPCODE_ADD_HL) + 1;
  c_CLOWNZ80_OPCODE_INC_16BIT = ( c_CLOWNZ80_OPCODE_LD_8BIT) + 1;
  c_CLOWNZ80_OPCODE_DEC_16BIT = ( c_CLOWNZ80_OPCODE_INC_16BIT) + 1;
  c_CLOWNZ80_OPCODE_INC_8BIT = ( c_CLOWNZ80_OPCODE_DEC_16BIT) + 1;
  c_CLOWNZ80_OPCODE_DEC_8BIT = ( c_CLOWNZ80_OPCODE_INC_8BIT) + 1;
  c_CLOWNZ80_OPCODE_RLCA = ( c_CLOWNZ80_OPCODE_DEC_8BIT) + 1;
  c_CLOWNZ80_OPCODE_RRCA = ( c_CLOWNZ80_OPCODE_RLCA) + 1;
  c_CLOWNZ80_OPCODE_RLA = ( c_CLOWNZ80_OPCODE_RRCA) + 1;
  c_CLOWNZ80_OPCODE_RRA = ( c_CLOWNZ80_OPCODE_RLA) + 1;
  c_CLOWNZ80_OPCODE_DAA = ( c_CLOWNZ80_OPCODE_RRA) + 1;
  c_CLOWNZ80_OPCODE_CPL = ( c_CLOWNZ80_OPCODE_DAA) + 1;
  c_CLOWNZ80_OPCODE_SCF = ( c_CLOWNZ80_OPCODE_CPL) + 1;
  c_CLOWNZ80_OPCODE_CCF = ( c_CLOWNZ80_OPCODE_SCF) + 1;
  c_CLOWNZ80_OPCODE_HALT = ( c_CLOWNZ80_OPCODE_CCF) + 1;
  c_CLOWNZ80_OPCODE_ADD_A = ( c_CLOWNZ80_OPCODE_HALT) + 1;
  c_CLOWNZ80_OPCODE_ADC_A = ( c_CLOWNZ80_OPCODE_ADD_A) + 1;
  c_CLOWNZ80_OPCODE_SUB = ( c_CLOWNZ80_OPCODE_ADC_A) + 1;
  c_CLOWNZ80_OPCODE_SBC_A = ( c_CLOWNZ80_OPCODE_SUB) + 1;
  c_CLOWNZ80_OPCODE_AND = ( c_CLOWNZ80_OPCODE_SBC_A) + 1;
  c_CLOWNZ80_OPCODE_XOR = ( c_CLOWNZ80_OPCODE_AND) + 1;
  c_CLOWNZ80_OPCODE_OR = ( c_CLOWNZ80_OPCODE_XOR) + 1;
  c_CLOWNZ80_OPCODE_CP = ( c_CLOWNZ80_OPCODE_OR) + 1;
  c_CLOWNZ80_OPCODE_RET_CONDITIONAL = ( c_CLOWNZ80_OPCODE_CP) + 1;
  c_CLOWNZ80_OPCODE_POP = ( c_CLOWNZ80_OPCODE_RET_CONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_RET_UNCONDITIONAL = ( c_CLOWNZ80_OPCODE_POP) + 1;
  c_CLOWNZ80_OPCODE_EXX = ( c_CLOWNZ80_OPCODE_RET_UNCONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_JP_HL = ( c_CLOWNZ80_OPCODE_EXX) + 1;
  c_CLOWNZ80_OPCODE_LD_SP_HL = ( c_CLOWNZ80_OPCODE_JP_HL) + 1;
  c_CLOWNZ80_OPCODE_JP_CONDITIONAL = ( c_CLOWNZ80_OPCODE_LD_SP_HL) + 1;
  c_CLOWNZ80_OPCODE_JP_UNCONDITIONAL = ( c_CLOWNZ80_OPCODE_JP_CONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_CB_PREFIX = ( c_CLOWNZ80_OPCODE_JP_UNCONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_OUT = ( c_CLOWNZ80_OPCODE_CB_PREFIX) + 1;
  c_CLOWNZ80_OPCODE_IN = ( c_CLOWNZ80_OPCODE_OUT) + 1;
  c_CLOWNZ80_OPCODE_EX_SP_HL = ( c_CLOWNZ80_OPCODE_IN) + 1;
  c_CLOWNZ80_OPCODE_EX_DE_HL = ( c_CLOWNZ80_OPCODE_EX_SP_HL) + 1;
  c_CLOWNZ80_OPCODE_DI = ( c_CLOWNZ80_OPCODE_EX_DE_HL) + 1;
  c_CLOWNZ80_OPCODE_EI = ( c_CLOWNZ80_OPCODE_DI) + 1;
  c_CLOWNZ80_OPCODE_CALL_CONDITIONAL = ( c_CLOWNZ80_OPCODE_EI) + 1;
  c_CLOWNZ80_OPCODE_PUSH = ( c_CLOWNZ80_OPCODE_CALL_CONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_CALL_UNCONDITIONAL = ( c_CLOWNZ80_OPCODE_PUSH) + 1;
  c_CLOWNZ80_OPCODE_DD_PREFIX = ( c_CLOWNZ80_OPCODE_CALL_UNCONDITIONAL) + 1;
  c_CLOWNZ80_OPCODE_ED_PREFIX = ( c_CLOWNZ80_OPCODE_DD_PREFIX) + 1;
  c_CLOWNZ80_OPCODE_FD_PREFIX = ( c_CLOWNZ80_OPCODE_ED_PREFIX) + 1;
  c_CLOWNZ80_OPCODE_RST = ( c_CLOWNZ80_OPCODE_FD_PREFIX) + 1;
  c_CLOWNZ80_OPCODE_RLC = ( c_CLOWNZ80_OPCODE_RST) + 1;
  c_CLOWNZ80_OPCODE_RRC = ( c_CLOWNZ80_OPCODE_RLC) + 1;
  c_CLOWNZ80_OPCODE_RL = ( c_CLOWNZ80_OPCODE_RRC) + 1;
  c_CLOWNZ80_OPCODE_RR = ( c_CLOWNZ80_OPCODE_RL) + 1;
  c_CLOWNZ80_OPCODE_SLA = ( c_CLOWNZ80_OPCODE_RR) + 1;
  c_CLOWNZ80_OPCODE_SRA = ( c_CLOWNZ80_OPCODE_SLA) + 1;
  c_CLOWNZ80_OPCODE_SLL = ( c_CLOWNZ80_OPCODE_SRA) + 1;
  c_CLOWNZ80_OPCODE_SRL = ( c_CLOWNZ80_OPCODE_SLL) + 1;
  c_CLOWNZ80_OPCODE_BIT = ( c_CLOWNZ80_OPCODE_SRL) + 1;
  c_CLOWNZ80_OPCODE_RES = ( c_CLOWNZ80_OPCODE_BIT) + 1;
  c_CLOWNZ80_OPCODE_SET = ( c_CLOWNZ80_OPCODE_RES) + 1;
  c_CLOWNZ80_OPCODE_IN_REGISTER = ( c_CLOWNZ80_OPCODE_SET) + 1;
  c_CLOWNZ80_OPCODE_IN_NO_REGISTER = ( c_CLOWNZ80_OPCODE_IN_REGISTER) + 1;
  c_CLOWNZ80_OPCODE_OUT_REGISTER = ( c_CLOWNZ80_OPCODE_IN_NO_REGISTER) + 1;
  c_CLOWNZ80_OPCODE_OUT_NO_REGISTER = ( c_CLOWNZ80_OPCODE_OUT_REGISTER) + 1;
  c_CLOWNZ80_OPCODE_SBC_HL = ( c_CLOWNZ80_OPCODE_OUT_NO_REGISTER) + 1;
  c_CLOWNZ80_OPCODE_ADC_HL = ( c_CLOWNZ80_OPCODE_SBC_HL) + 1;
  c_CLOWNZ80_OPCODE_NEG = ( c_CLOWNZ80_OPCODE_ADC_HL) + 1;
  c_CLOWNZ80_OPCODE_RETN = ( c_CLOWNZ80_OPCODE_NEG) + 1;
  c_CLOWNZ80_OPCODE_RETI = ( c_CLOWNZ80_OPCODE_RETN) + 1;
  c_CLOWNZ80_OPCODE_IM = ( c_CLOWNZ80_OPCODE_RETI) + 1;
  c_CLOWNZ80_OPCODE_LD_I_A = ( c_CLOWNZ80_OPCODE_IM) + 1;
  c_CLOWNZ80_OPCODE_LD_R_A = ( c_CLOWNZ80_OPCODE_LD_I_A) + 1;
  c_CLOWNZ80_OPCODE_LD_A_I = ( c_CLOWNZ80_OPCODE_LD_R_A) + 1;
  c_CLOWNZ80_OPCODE_LD_A_R = ( c_CLOWNZ80_OPCODE_LD_A_I) + 1;
  c_CLOWNZ80_OPCODE_RRD = ( c_CLOWNZ80_OPCODE_LD_A_R) + 1;
  c_CLOWNZ80_OPCODE_RLD = ( c_CLOWNZ80_OPCODE_RRD) + 1;
  c_CLOWNZ80_OPCODE_LDI = ( c_CLOWNZ80_OPCODE_RLD) + 1;
  c_CLOWNZ80_OPCODE_LDD = ( c_CLOWNZ80_OPCODE_LDI) + 1;
  c_CLOWNZ80_OPCODE_LDIR = ( c_CLOWNZ80_OPCODE_LDD) + 1;
  c_CLOWNZ80_OPCODE_LDDR = ( c_CLOWNZ80_OPCODE_LDIR) + 1;
  c_CLOWNZ80_OPCODE_CPI = ( c_CLOWNZ80_OPCODE_LDDR) + 1;
  c_CLOWNZ80_OPCODE_CPD = ( c_CLOWNZ80_OPCODE_CPI) + 1;
  c_CLOWNZ80_OPCODE_CPIR = ( c_CLOWNZ80_OPCODE_CPD) + 1;
  c_CLOWNZ80_OPCODE_CPDR = ( c_CLOWNZ80_OPCODE_CPIR) + 1;
  c_CLOWNZ80_OPCODE_INI = ( c_CLOWNZ80_OPCODE_CPDR) + 1;
  c_CLOWNZ80_OPCODE_IND = ( c_CLOWNZ80_OPCODE_INI) + 1;
  c_CLOWNZ80_OPCODE_INIR = ( c_CLOWNZ80_OPCODE_IND) + 1;
  c_CLOWNZ80_OPCODE_INDR = ( c_CLOWNZ80_OPCODE_INIR) + 1;
  c_CLOWNZ80_OPCODE_OUTI = ( c_CLOWNZ80_OPCODE_INDR) + 1;
  c_CLOWNZ80_OPCODE_OUTD = ( c_CLOWNZ80_OPCODE_OUTI) + 1;
  c_CLOWNZ80_OPCODE_OTIR = ( c_CLOWNZ80_OPCODE_OUTD) + 1;
  c_CLOWNZ80_OPCODE_OTDR = ( c_CLOWNZ80_OPCODE_OTIR) + 1;
  c_CLOWNZ80_OPERAND_NONE = ( -1) + 1;
  c_CLOWNZ80_OPERAND_A = ( c_CLOWNZ80_OPERAND_NONE) + 1;
  c_CLOWNZ80_OPERAND_B = ( c_CLOWNZ80_OPERAND_A) + 1;
  c_CLOWNZ80_OPERAND_C = ( c_CLOWNZ80_OPERAND_B) + 1;
  c_CLOWNZ80_OPERAND_D = ( c_CLOWNZ80_OPERAND_C) + 1;
  c_CLOWNZ80_OPERAND_E = ( c_CLOWNZ80_OPERAND_D) + 1;
  c_CLOWNZ80_OPERAND_H = ( c_CLOWNZ80_OPERAND_E) + 1;
  c_CLOWNZ80_OPERAND_L = ( c_CLOWNZ80_OPERAND_H) + 1;
  c_CLOWNZ80_OPERAND_IXH = ( c_CLOWNZ80_OPERAND_L) + 1;
  c_CLOWNZ80_OPERAND_IXL = ( c_CLOWNZ80_OPERAND_IXH) + 1;
  c_CLOWNZ80_OPERAND_IYH = ( c_CLOWNZ80_OPERAND_IXL) + 1;
  c_CLOWNZ80_OPERAND_IYL = ( c_CLOWNZ80_OPERAND_IYH) + 1;
  c_CLOWNZ80_OPERAND_AF = ( c_CLOWNZ80_OPERAND_IYL) + 1;
  c_CLOWNZ80_OPERAND_BC = ( c_CLOWNZ80_OPERAND_AF) + 1;
  c_CLOWNZ80_OPERAND_DE = ( c_CLOWNZ80_OPERAND_BC) + 1;
  c_CLOWNZ80_OPERAND_HL = ( c_CLOWNZ80_OPERAND_DE) + 1;
  c_CLOWNZ80_OPERAND_IX = ( c_CLOWNZ80_OPERAND_HL) + 1;
  c_CLOWNZ80_OPERAND_IY = ( c_CLOWNZ80_OPERAND_IX) + 1;
  c_CLOWNZ80_OPERAND_PC = ( c_CLOWNZ80_OPERAND_IY) + 1;
  c_CLOWNZ80_OPERAND_SP = ( c_CLOWNZ80_OPERAND_PC) + 1;
  c_CLOWNZ80_OPERAND_BC_INDIRECT = ( c_CLOWNZ80_OPERAND_SP) + 1;
  c_CLOWNZ80_OPERAND_DE_INDIRECT = ( c_CLOWNZ80_OPERAND_BC_INDIRECT) + 1;
  c_CLOWNZ80_OPERAND_HL_INDIRECT = ( c_CLOWNZ80_OPERAND_DE_INDIRECT) + 1;
  c_CLOWNZ80_OPERAND_IX_INDIRECT = ( c_CLOWNZ80_OPERAND_HL_INDIRECT) + 1;
  c_CLOWNZ80_OPERAND_IY_INDIRECT = ( c_CLOWNZ80_OPERAND_IX_INDIRECT) + 1;
  c_CLOWNZ80_OPERAND_ADDRESS = ( c_CLOWNZ80_OPERAND_IY_INDIRECT) + 1;
  c_CLOWNZ80_OPERAND_LITERAL_8BIT = ( c_CLOWNZ80_OPERAND_ADDRESS) + 1;
  c_CLOWNZ80_OPERAND_LITERAL_16BIT = ( c_CLOWNZ80_OPERAND_LITERAL_8BIT) + 1;
  c_CLOWNZ80_CONDITION_NOT_ZERO = 0;
  c_CLOWNZ80_CONDITION_ZERO = 1;
  c_CLOWNZ80_CONDITION_NOT_CARRY = 2;
  c_CLOWNZ80_CONDITION_CARRY = 3;
  c_CLOWNZ80_CONDITION_PARITY_OVERFLOW = 4;
  c_CLOWNZ80_CONDITION_PARITY_EQUALITY = 5;
  c_CLOWNZ80_CONDITION_PLUS = 6;
  c_CLOWNZ80_CONDITION_MINUS = 7;
  c_CLOWNZ80_INSTRUCTION_MODE_NORMAL = ( -1) + 1;
  c_CLOWNZ80_INSTRUCTION_MODE_BITS = ( c_CLOWNZ80_INSTRUCTION_MODE_NORMAL) + 1;
  c_CLOWNZ80_INSTRUCTION_MODE_MISC = ( c_CLOWNZ80_INSTRUCTION_MODE_BITS) + 1;
  c_CLOWNZ80_REGISTER_MODE_HL = ( -1) + 1;
  c_CLOWNZ80_REGISTER_MODE_IX = ( c_CLOWNZ80_REGISTER_MODE_HL) + 1;
  c_CLOWNZ80_REGISTER_MODE_IY = ( c_CLOWNZ80_REGISTER_MODE_IX) + 1;
  c_FLAG_BIT_CARRY = 0;
  c_FLAG_BIT_ADD_SUBTRACT = 1;
  c_FLAG_BIT_PARITY_OVERFLOW = 2;
  c_FLAG_BIT_HALF_CARRY = 4;
  c_FLAG_BIT_ZERO = 6;
  c_FLAG_BIT_SIGN = 7;
  c_FLAG_MASK_CARRY = ( 1 shl c_FLAG_BIT_CARRY);
  c_FLAG_MASK_ADD_SUBTRACT = ( 1 shl c_FLAG_BIT_ADD_SUBTRACT);
  c_FLAG_MASK_PARITY_OVERFLOW = ( 1 shl c_FLAG_BIT_PARITY_OVERFLOW);
  c_FLAG_MASK_HALF_CARRY = ( 1 shl c_FLAG_BIT_HALF_CARRY);
  c_FLAG_MASK_ZERO = ( 1 shl c_FLAG_BIT_ZERO);
  c_FLAG_MASK_SIGN = ( 1 shl c_FLAG_BIT_SIGN);

procedure c_ClownZ80_DecodeInstructionMetadata(Metadata: PZ80InstructionMetadata; c_instruction_mode: Integer; c_register_mode: Integer; c_opcode: Byte);

function c_EvaluateCondition(c_flags: Byte; c_condition: Integer): Byte;

function c_MemoryRead(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;

procedure c_MemoryWrite(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; c_data: Cardinal);

function c_InstructionMemoryRead(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks): Cardinal;

function c_OpcodeFetch(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks): Cardinal;

function c_MemoryRead16Bit(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;

procedure c_MemoryWrite16Bit(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; Value: Cardinal);

function c_ReadOperand(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction; c_operand: Integer): Cardinal;

procedure c_WriteOperand(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction; c_operand: Integer; Value: Cardinal);

procedure c_DecodeInstruction(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction);

function c_ComputeParity(Value: Cardinal): Byte;

procedure c_ExecuteInstruction(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction);

procedure c_ClownZ80_Constant_Initialise();

procedure c_ClownZ80_State_Initialise(c_state: PZ80State);

procedure c_ClownZ80_Reset(c_state: PZ80State);

procedure c_ClownZ80_Interrupt(c_state: PZ80State; c_assert_interrupt: Byte);

function c_ClownZ80_DoInstruction(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks): Cardinal;

implementation

var
  c_instruction_metadata_lookup_normal: array[0..2] of array[0..255] of TZ80InstructionMetadata;
  c_instruction_metadata_lookup_bits: array[0..2] of array[0..255] of TZ80InstructionMetadata;
  c_instruction_metadata_lookup_misc: array[0..255] of TZ80InstructionMetadata;

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer((Cardinal(Value) shr Bits) or (Cardinal(-Ord(Value < 0)) shl (32 - Bits)));
end;

procedure c_ClownZ80_DecodeInstructionMetadata(Metadata: PZ80InstructionMetadata; c_instruction_mode: Integer; c_register_mode: Integer; c_opcode: Byte);
const
  c_registers: array[0..7] of Integer = (c_CLOWNZ80_OPERAND_B, c_CLOWNZ80_OPERAND_C, c_CLOWNZ80_OPERAND_D, c_CLOWNZ80_OPERAND_E, c_CLOWNZ80_OPERAND_H, c_CLOWNZ80_OPERAND_L, c_CLOWNZ80_OPERAND_HL_INDIRECT, c_CLOWNZ80_OPERAND_A);
  c_register_pairs_1: array[0..3] of Integer = (c_CLOWNZ80_OPERAND_BC, c_CLOWNZ80_OPERAND_DE, c_CLOWNZ80_OPERAND_HL, c_CLOWNZ80_OPERAND_SP);
  c_register_pairs_2: array[0..3] of Integer = (c_CLOWNZ80_OPERAND_BC, c_CLOWNZ80_OPERAND_DE, c_CLOWNZ80_OPERAND_HL, c_CLOWNZ80_OPERAND_AF);
  c_arithmetic_logic_opcodes: array[0..7] of Integer = (c_CLOWNZ80_OPCODE_ADD_A, c_CLOWNZ80_OPCODE_ADC_A, c_CLOWNZ80_OPCODE_SUB, c_CLOWNZ80_OPCODE_SBC_A, c_CLOWNZ80_OPCODE_AND, c_CLOWNZ80_OPCODE_XOR, c_CLOWNZ80_OPCODE_OR, c_CLOWNZ80_OPCODE_CP);
  c_rotate_shift_opcodes: array[0..7] of Integer = (c_CLOWNZ80_OPCODE_RLC, c_CLOWNZ80_OPCODE_RRC, c_CLOWNZ80_OPCODE_RL, c_CLOWNZ80_OPCODE_RR, c_CLOWNZ80_OPCODE_SLA, c_CLOWNZ80_OPCODE_SRA, c_CLOWNZ80_OPCODE_SLL, c_CLOWNZ80_OPCODE_SRL);
  c_block_opcodes: array[0..3] of array[0..3] of Integer = ((c_CLOWNZ80_OPCODE_LDI, c_CLOWNZ80_OPCODE_LDD, c_CLOWNZ80_OPCODE_LDIR, c_CLOWNZ80_OPCODE_LDDR), (c_CLOWNZ80_OPCODE_CPI, c_CLOWNZ80_OPCODE_CPD, c_CLOWNZ80_OPCODE_CPIR, c_CLOWNZ80_OPCODE_CPDR), (c_CLOWNZ80_OPCODE_INI, c_CLOWNZ80_OPCODE_IND, c_CLOWNZ80_OPCODE_INIR, c_CLOWNZ80_OPCODE_INDR), (c_CLOWNZ80_OPCODE_OUTI, c_CLOWNZ80_OPCODE_OUTD, c_CLOWNZ80_OPCODE_OTIR, c_CLOWNZ80_OPCODE_OTDR));
  c_operands: array[0..3] of Integer = (c_CLOWNZ80_OPERAND_BC_INDIRECT, c_CLOWNZ80_OPERAND_DE_INDIRECT, c_CLOWNZ80_OPERAND_ADDRESS, c_CLOWNZ80_OPERAND_ADDRESS);
  c_opcodes: array[0..7] of Integer = (c_CLOWNZ80_OPCODE_RLCA, c_CLOWNZ80_OPCODE_RRCA, c_CLOWNZ80_OPCODE_RLA, c_CLOWNZ80_OPCODE_RRA, c_CLOWNZ80_OPCODE_DAA, c_CLOWNZ80_OPCODE_CPL, c_CLOWNZ80_OPCODE_SCF, c_CLOWNZ80_OPCODE_CCF);
  c_interrupt_modes: array[0..3] of Cardinal = (0, 0, 1, 2);
  c_assorted_opcodes: array[0..7] of Integer = (c_CLOWNZ80_OPCODE_LD_I_A, c_CLOWNZ80_OPCODE_LD_R_A, c_CLOWNZ80_OPCODE_LD_A_I, c_CLOWNZ80_OPCODE_LD_A_R, c_CLOWNZ80_OPCODE_RRD, c_CLOWNZ80_OPCODE_RLD, c_CLOWNZ80_OPCODE_NOP, c_CLOWNZ80_OPCODE_NOP);
var
  c_operand_a: Integer;
  temp42: Integer;
  c_operand_b: Integer;
  temp43: Integer;
  temp44: Integer;
  temp93: Integer;
  temp96: Integer;
  temp97: Integer;
begin
  var c_x: Cardinal := Cardinal(ArithmeticShiftRight(Integer(c_opcode), 6) and 3);
  var c_y: Cardinal := Cardinal(ArithmeticShiftRight(Integer(c_opcode), 3) and 7);
  var c_z: Cardinal := Cardinal(ArithmeticShiftRight(Integer(c_opcode), 0) and 7);
  var c_p: Cardinal := Cardinal(Cardinal(c_y shr 1) and Cardinal(3));
  var c_q: Byte := Byte(Ord(Cardinal(Cardinal(c_y) and Cardinal(1)) <> Cardinal(0)));
  Metadata^.c_has_displacement := Byte(0);
  Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_NONE);
  Metadata^.c_operands[1] := Byte(c_CLOWNZ80_OPERAND_NONE);
  case c_instruction_mode of
    c_CLOWNZ80_INSTRUCTION_MODE_NORMAL:
      begin
        case c_x of
          0:
            begin
              case c_z of
                0:
                  begin
                    case c_y of
                      0:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_NOP);
                        end;
                      1:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_EX_AF_AF);
                        end;
                      2:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_DJNZ);
                          Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                        end;
                      3:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_JR_UNCONDITIONAL);
                          Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                        end;
                      4, 5, 6, 7:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_JR_CONDITIONAL);
                          Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                          Metadata^.c_condition := Byte(Sub32(c_y, 4));
                        end;
                    end;
                  end;
                1:
                  begin
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_LD_16BIT);
                      Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_16BIT);
                      Metadata^.c_operands[1] := Byte(c_register_pairs_1[c_p]);
                    end
                    else
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_ADD_HL);
                      Metadata^.c_operands[0] := Byte(c_register_pairs_1[c_p]);
                      Metadata^.c_operands[1] := Byte(c_CLOWNZ80_OPERAND_HL);
                    end;
                  end;
                2:
                  begin
                    if (Cardinal(c_p) = Cardinal(2)) then
                    begin
                      temp42 := c_CLOWNZ80_OPERAND_HL;
                    end
                    else
                    begin
                      temp42 := c_CLOWNZ80_OPERAND_A;
                    end;
                    c_operand_a := temp42;
                    c_operand_b := c_operands[c_p];
                    if (Cardinal(c_p) = Cardinal(2)) then
                    begin
                      temp43 := c_CLOWNZ80_OPCODE_LD_16BIT;
                    end
                    else
                    begin
                      temp43 := c_CLOWNZ80_OPCODE_LD_8BIT;
                    end;
                    Metadata^.c_opcode := Byte(temp43);
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_operands[0] := Byte(c_operand_a);
                      Metadata^.c_operands[1] := Byte(c_operand_b);
                    end
                    else
                    begin
                      Metadata^.c_operands[0] := Byte(c_operand_b);
                      Metadata^.c_operands[1] := Byte(c_operand_a);
                    end;
                  end;
                3:
                  begin
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_INC_16BIT);
                    end
                    else
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_DEC_16BIT);
                    end;
                    Metadata^.c_operands[1] := Byte(c_register_pairs_1[c_p]);
                  end;
                4:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_INC_8BIT);
                    Metadata^.c_operands[1] := Byte(c_registers[c_y]);
                  end;
                5:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_DEC_8BIT);
                    Metadata^.c_operands[1] := Byte(c_registers[c_y]);
                  end;
                6:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_LD_8BIT);
                    Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                    Metadata^.c_operands[1] := Byte(c_registers[c_y]);
                  end;
                7:
                  begin
                    Metadata^.c_opcode := Byte(c_opcodes[c_y]);
                  end;
              end;
            end;
          1:
            begin
              temp44 := Ord(Cardinal(c_z) = Cardinal(6));
              if temp44 <> 0 then
              begin
                temp44 := Ord(Cardinal(c_y) = Cardinal(6));
              end;
              if (temp44 <> 0) then
              begin
                Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_HALT);
              end
              else
              begin
                Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_LD_8BIT);
                Metadata^.c_operands[0] := Byte(c_registers[c_z]);
                Metadata^.c_operands[1] := Byte(c_registers[c_y]);
              end;
            end;
          2:
            begin
              Metadata^.c_opcode := Byte(c_arithmetic_logic_opcodes[c_y]);
              Metadata^.c_operands[0] := Byte(c_registers[c_z]);
            end;
          3:
            begin
              case c_z of
                0:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_RET_CONDITIONAL);
                    Metadata^.c_condition := Byte(c_y);
                  end;
                1:
                  begin
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_POP);
                      Metadata^.c_operands[1] := Byte(c_register_pairs_2[c_p]);
                    end
                    else
                    begin
                      case c_p of
                        0:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_RET_UNCONDITIONAL);
                          end;
                        1:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_EXX);
                          end;
                        2:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_JP_HL);
                            Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_HL);
                          end;
                        3:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_LD_SP_HL);
                            Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_HL);
                          end;
                      end;
                    end;
                  end;
                2:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_JP_CONDITIONAL);
                    Metadata^.c_condition := Byte(c_y);
                    Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_16BIT);
                  end;
                3:
                  begin
                    case c_y of
                      0:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_JP_UNCONDITIONAL);
                          Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_16BIT);
                        end;
                      1:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_CB_PREFIX);
                          if (Integer(c_register_mode) <> Integer(c_CLOWNZ80_REGISTER_MODE_HL)) then
                          begin
                            Metadata^.c_has_displacement := Byte(1);
                          end;
                        end;
                      2:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_OUT);
                          Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                        end;
                      3:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_IN);
                          Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                        end;
                      4:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_EX_SP_HL);
                          Metadata^.c_operands[1] := Byte(c_CLOWNZ80_OPERAND_HL);
                        end;
                      5:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_EX_DE_HL);
                        end;
                      6:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_DI);
                        end;
                      7:
                        begin
                          Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_EI);
                        end;
                    end;
                  end;
                4:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_CALL_CONDITIONAL);
                    Metadata^.c_condition := Byte(c_y);
                    Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_16BIT);
                  end;
                5:
                  begin
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_PUSH);
                      Metadata^.c_operands[0] := Byte(c_register_pairs_2[c_p]);
                    end
                    else
                    begin
                      case c_p of
                        0:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_CALL_UNCONDITIONAL);
                            Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_16BIT);
                          end;
                        1:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_DD_PREFIX);
                          end;
                        2:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_ED_PREFIX);
                          end;
                        3:
                          begin
                            Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_FD_PREFIX);
                          end;
                      end;
                    end;
                  end;
                6:
                  begin
                    Metadata^.c_opcode := Byte(c_arithmetic_logic_opcodes[c_y]);
                    Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_LITERAL_8BIT);
                  end;
                7:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_RST);
                    Metadata^.c_embedded_literal := Byte(Mul32(c_y, 8));
                  end;
              end;
            end;
        end;
      end;
    c_CLOWNZ80_INSTRUCTION_MODE_BITS:
      begin
        case c_x of
          0:
            begin
              Metadata^.c_opcode := Byte(c_rotate_shift_opcodes[c_y]);
              Metadata^.c_operands[1] := Byte(c_registers[c_z]);
            end;
          1:
            begin
              Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_BIT);
              Metadata^.c_operands[1] := Byte(c_registers[c_z]);
              Metadata^.c_embedded_literal := Byte(1 shl c_y);
            end;
          2:
            begin
              Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_RES);
              Metadata^.c_operands[1] := Byte(c_registers[c_z]);
              Metadata^.c_embedded_literal := Byte(not (1 shl c_y));
            end;
          3:
            begin
              Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_SET);
              Metadata^.c_operands[1] := Byte(c_registers[c_z]);
              Metadata^.c_embedded_literal := Byte(1 shl c_y);
            end;
        end;
      end;
    c_CLOWNZ80_INSTRUCTION_MODE_MISC:
      begin
        case c_x of
          0, 3:
            begin
              Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_NOP);
            end;
          1:
            begin
              case c_z of
                0:
                  begin
                    if (Cardinal(c_y) <> Cardinal(6)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_IN_REGISTER);
                    end
                    else
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_IN_NO_REGISTER);
                    end;
                  end;
                1:
                  begin
                    if (Cardinal(c_y) <> Cardinal(6)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_OUT_REGISTER);
                    end
                    else
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_OUT_NO_REGISTER);
                    end;
                  end;
                2:
                  begin
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_SBC_HL);
                    end
                    else
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_ADC_HL);
                    end;
                    Metadata^.c_operands[0] := Byte(c_register_pairs_1[c_p]);
                    Metadata^.c_operands[1] := Byte(c_CLOWNZ80_OPERAND_HL);
                  end;
                3:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_LD_16BIT);
                    if (not (c_q <> 0)) then
                    begin
                      Metadata^.c_operands[0] := Byte(c_register_pairs_1[c_p]);
                      Metadata^.c_operands[1] := Byte(c_CLOWNZ80_OPERAND_ADDRESS);
                    end
                    else
                    begin
                      Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_ADDRESS);
                      Metadata^.c_operands[1] := Byte(c_register_pairs_1[c_p]);
                    end;
                  end;
                4:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_NEG);
                    Metadata^.c_operands[0] := Byte(c_CLOWNZ80_OPERAND_A);
                    Metadata^.c_operands[1] := Byte(c_CLOWNZ80_OPERAND_A);
                  end;
                5:
                  begin
                    if (Cardinal(c_y) <> Cardinal(1)) then
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_RETN);
                    end
                    else
                    begin
                      Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_RETI);
                    end;
                  end;
                6:
                  begin
                    Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_IM);
                    Metadata^.c_embedded_literal := Byte(c_interrupt_modes[(Cardinal(c_y) and Cardinal(3))]);
                  end;
                7:
                  begin
                    Metadata^.c_opcode := Byte(c_assorted_opcodes[c_y]);
                  end;
              end;
            end;
          2:
            begin
              temp93 := Ord(Cardinal(c_z) <= Cardinal(3));
              if temp93 <> 0 then
              begin
                temp93 := Ord(Cardinal(c_y) >= Cardinal(4));
              end;
              if (temp93 <> 0) then
              begin
                Metadata^.c_opcode := Byte(c_block_opcodes[c_z][(Sub32(c_y, 4))]);
              end
              else
              begin
                Metadata^.c_opcode := Byte(c_CLOWNZ80_OPCODE_NOP);
              end;
            end;
        end;
      end;
  end;
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(2)) do
  begin
    temp97 := Ord(Integer(Metadata^.c_operands[(Cardinal(c_i) xor Cardinal(1))]) <> Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
    if temp97 <> 0 then
    begin
      temp97 := Ord(Integer(Metadata^.c_operands[(Cardinal(c_i) xor Cardinal(1))]) <> Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
    end;
    temp96 := Ord(temp97 <> 0);
    if temp96 <> 0 then
    begin
      temp96 := Ord(Integer(Metadata^.c_operands[(Cardinal(c_i) xor Cardinal(1))]) <> Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
    end;
    if (temp96 <> 0) then
    begin
      case Metadata^.c_operands[c_i] of
        c_CLOWNZ80_OPERAND_H:
          begin
            case c_register_mode of
              c_CLOWNZ80_REGISTER_MODE_HL:
                begin
                end;
              c_CLOWNZ80_REGISTER_MODE_IX:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IXH);
                end;
              c_CLOWNZ80_REGISTER_MODE_IY:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IYH);
                end;
            end;
          end;
        c_CLOWNZ80_OPERAND_L:
          begin
            case c_register_mode of
              c_CLOWNZ80_REGISTER_MODE_HL:
                begin
                end;
              c_CLOWNZ80_REGISTER_MODE_IX:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IXL);
                end;
              c_CLOWNZ80_REGISTER_MODE_IY:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IYL);
                end;
            end;
          end;
        c_CLOWNZ80_OPERAND_HL:
          begin
            case c_register_mode of
              c_CLOWNZ80_REGISTER_MODE_HL:
                begin
                end;
              c_CLOWNZ80_REGISTER_MODE_IX:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IX);
                end;
              c_CLOWNZ80_REGISTER_MODE_IY:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IY);
                end;
            end;
          end;
        c_CLOWNZ80_OPERAND_HL_INDIRECT:
          begin
            case c_register_mode of
              c_CLOWNZ80_REGISTER_MODE_HL:
                begin
                end;
              c_CLOWNZ80_REGISTER_MODE_IX:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IX_INDIRECT);
                  Metadata^.c_has_displacement := Byte(1);
                end;
              c_CLOWNZ80_REGISTER_MODE_IY:
                begin
                  Metadata^.c_operands[c_i] := Byte(c_CLOWNZ80_OPERAND_IY_INDIRECT);
                  Metadata^.c_has_displacement := Byte(1);
                end;
            end;
          end;
      else
        begin
        end;
      end;
    end;
    Inc(c_i);
  end;
end;

function c_EvaluateCondition(c_flags: Byte; c_condition: Integer): Byte;
begin
  case c_condition of
    c_CLOWNZ80_CONDITION_NOT_ZERO:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_ZERO) = Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_ZERO:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_ZERO) <> Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_NOT_CARRY:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_CARRY) = Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_CARRY:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_CARRY) <> Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_PARITY_OVERFLOW:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_PARITY_OVERFLOW) = Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_PARITY_EQUALITY:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_PARITY_OVERFLOW) <> Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_PLUS:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_SIGN) = Integer(0))));
      end;
    c_CLOWNZ80_CONDITION_MINUS:
      begin
        Exit(Byte(Ord(Integer(c_flags and c_FLAG_MASK_SIGN) <> Integer(0))));
      end;
  else
    begin
      Assert(0 <> 0);
      Exit(Byte(0));
    end;
  end;
end;

function c_MemoryRead(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  c_state^.c_cycles := Word(c_state^.c_cycles + 3);
  Exit(Cardinal(c_callbacks^.ReadCallback(Pointer(c_callbacks^.UserData), Address)));
end;

procedure c_MemoryWrite(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; c_data: Cardinal);
begin
  c_state^.c_cycles := Word(c_state^.c_cycles + 3);
  c_callbacks^.WriteCallback(Pointer(c_callbacks^.UserData), Address, c_data);
end;

function c_InstructionMemoryRead(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks): Cardinal;
begin
  var c_data: Cardinal := Cardinal(c_MemoryRead(c_state, c_callbacks, c_state^.c_program_counter));
  c_state^.c_program_counter := (c_state^.c_program_counter + 1) and $FFFF;
  c_state^.c_program_counter := Word(c_state^.c_program_counter and $FFFF);
  Exit(Cardinal(c_data));
end;

function c_OpcodeFetch(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks): Cardinal;
begin
  Inc(c_state^.c_cycles);
  c_state^.c_r := Byte((c_state^.c_r and $80) or ((c_state^.c_r + 1) and $7F));
  Exit(Cardinal(c_InstructionMemoryRead(c_state, c_callbacks)));
end;

function c_MemoryRead16Bit(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := Cardinal(c_MemoryRead(c_state, c_callbacks, (Add32(Address, 0))));
  Value := Cardinal(Cardinal(Value) or Cardinal(c_MemoryRead(c_state, c_callbacks, (Cardinal(Add32(Address, 1)) and Cardinal($FFFF))) shl 8));
  Exit(Cardinal(Value));
end;

procedure c_MemoryWrite16Bit(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; Address: Cardinal; Value: Cardinal);
begin
  c_MemoryWrite(c_state, c_callbacks, (Add32(Address, 0)), (Cardinal(Value) and Cardinal($FF)));
  c_MemoryWrite(c_state, c_callbacks, (Cardinal(Add32(Address, 1)) and Cardinal($FFFF)), (Value shr 8));
end;

function c_ReadOperand(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction; c_operand: Integer): Cardinal;
var
  Value: Cardinal;
  temp130: Integer;
begin
  if (c_instruction^.DoublePrefixMode <> 0) then
  begin
    if (Integer(c_state^.c_register_mode) = Integer(c_CLOWNZ80_REGISTER_MODE_IX)) then
    begin
      temp130 := c_CLOWNZ80_OPERAND_IX_INDIRECT;
    end
    else
    begin
      temp130 := c_CLOWNZ80_OPERAND_IY_INDIRECT;
    end;
    c_operand := temp130;
  end;
  case c_operand of
    c_CLOWNZ80_OPERAND_NONE:
      begin
        Assert(0 <> 0);
        Value := Cardinal(c_state^.c_a);
      end;
    c_CLOWNZ80_OPERAND_A:
      begin
        Value := Cardinal(c_state^.c_a);
      end;
    c_CLOWNZ80_OPERAND_B:
      begin
        Value := Cardinal(c_state^.c_b);
      end;
    c_CLOWNZ80_OPERAND_C:
      begin
        Value := Cardinal(c_state^.c_c);
      end;
    c_CLOWNZ80_OPERAND_D:
      begin
        Value := Cardinal(c_state^.c_d);
      end;
    c_CLOWNZ80_OPERAND_E:
      begin
        Value := Cardinal(c_state^.c_e);
      end;
    c_CLOWNZ80_OPERAND_H:
      begin
        Value := Cardinal(c_state^.c_h);
      end;
    c_CLOWNZ80_OPERAND_L:
      begin
        Value := Cardinal(c_state^.c_l);
      end;
    c_CLOWNZ80_OPERAND_IXH:
      begin
        Value := Cardinal(c_state^.c_ixh);
      end;
    c_CLOWNZ80_OPERAND_IXL:
      begin
        Value := Cardinal(c_state^.c_ixl);
      end;
    c_CLOWNZ80_OPERAND_IYH:
      begin
        Value := Cardinal(c_state^.c_iyh);
      end;
    c_CLOWNZ80_OPERAND_IYL:
      begin
        Value := Cardinal(c_state^.c_iyl);
      end;
    c_CLOWNZ80_OPERAND_AF:
      begin
        Value := Cardinal(Cardinal(Cardinal(c_state^.c_a) shl 8) or Cardinal(c_state^.c_f));
      end;
    c_CLOWNZ80_OPERAND_BC:
      begin
        Value := Cardinal(Cardinal(Cardinal(c_state^.c_b) shl 8) or Cardinal(c_state^.c_c));
      end;
    c_CLOWNZ80_OPERAND_DE:
      begin
        Value := Cardinal(Cardinal(Cardinal(c_state^.c_d) shl 8) or Cardinal(c_state^.c_e));
      end;
    c_CLOWNZ80_OPERAND_HL:
      begin
        Value := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
      end;
    c_CLOWNZ80_OPERAND_IX:
      begin
        Value := Cardinal(Cardinal(Cardinal(c_state^.c_ixh) shl 8) or Cardinal(c_state^.c_ixl));
      end;
    c_CLOWNZ80_OPERAND_IY:
      begin
        Value := Cardinal(Cardinal(Cardinal(c_state^.c_iyh) shl 8) or Cardinal(c_state^.c_iyl));
      end;
    c_CLOWNZ80_OPERAND_PC:
      begin
        Value := Cardinal(c_state^.c_program_counter);
      end;
    c_CLOWNZ80_OPERAND_SP:
      begin
        Value := Cardinal(c_state^.c_stack_pointer);
      end;
    c_CLOWNZ80_OPERAND_LITERAL_8BIT, c_CLOWNZ80_OPERAND_LITERAL_16BIT:
      begin
        Value := Cardinal(c_instruction^.Literal);
      end;
    c_CLOWNZ80_OPERAND_BC_INDIRECT, c_CLOWNZ80_OPERAND_DE_INDIRECT, c_CLOWNZ80_OPERAND_HL_INDIRECT, c_CLOWNZ80_OPERAND_IX_INDIRECT, c_CLOWNZ80_OPERAND_IY_INDIRECT, c_CLOWNZ80_OPERAND_ADDRESS:
      begin
        Value := Cardinal(c_MemoryRead(c_state, c_callbacks, c_instruction^.Address));
        if (Integer(c_instruction^.Metadata^.c_opcode) = Integer(c_CLOWNZ80_OPCODE_LD_16BIT)) then
        begin
          Value := Cardinal(Cardinal(Value) or Cardinal(c_MemoryRead(c_state, c_callbacks, (Add32(c_instruction^.Address, 1))) shl 8));
        end;
      end;
  else
    begin
      Assert(0 <> 0);
      Value := Cardinal(c_state^.c_a);
    end;
  end;
  Exit(Cardinal(Value));
end;

procedure c_WriteOperand(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction; c_operand: Integer; Value: Cardinal);
var
  temp161: Integer;
begin
  if (Integer(c_state^.c_register_mode) = Integer(c_CLOWNZ80_REGISTER_MODE_IX)) then
  begin
    temp161 := c_CLOWNZ80_OPERAND_IX_INDIRECT;
  end
  else
  begin
    temp161 := c_CLOWNZ80_OPERAND_IY_INDIRECT;
  end;
  var c_double_prefix_operand: Integer := temp161;
  var temp162: Integer := Ord(c_instruction^.DoublePrefixMode <> 0);
  if temp162 <> 0 then
  begin
    temp162 := Ord(Integer(c_operand) <> Integer(c_double_prefix_operand));
  end;
  if (temp162 <> 0) then
  begin
    c_WriteOperand(c_state, c_callbacks, c_instruction, c_double_prefix_operand, Value);
  end;
  case c_operand of
    c_CLOWNZ80_OPERAND_NONE, c_CLOWNZ80_OPERAND_LITERAL_8BIT, c_CLOWNZ80_OPERAND_LITERAL_16BIT:
      begin
        Assert(0 <> 0);
      end;
    c_CLOWNZ80_OPERAND_A:
      begin
        c_state^.c_a := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_B:
      begin
        c_state^.c_b := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_C:
      begin
        c_state^.c_c := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_D:
      begin
        c_state^.c_d := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_E:
      begin
        c_state^.c_e := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_H:
      begin
        c_state^.c_h := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_L:
      begin
        c_state^.c_l := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_IXH:
      begin
        c_state^.c_ixh := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_IXL:
      begin
        c_state^.c_ixl := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_IYH:
      begin
        c_state^.c_iyh := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_IYL:
      begin
        c_state^.c_iyl := Byte(Value);
      end;
    c_CLOWNZ80_OPERAND_AF:
      begin
        c_state^.c_a := Byte(Value shr 8);
        c_state^.c_f := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    c_CLOWNZ80_OPERAND_BC:
      begin
        c_state^.c_b := Byte(Value shr 8);
        c_state^.c_c := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    c_CLOWNZ80_OPERAND_DE:
      begin
        c_state^.c_d := Byte(Value shr 8);
        c_state^.c_e := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    c_CLOWNZ80_OPERAND_HL:
      begin
        c_state^.c_h := Byte(Value shr 8);
        c_state^.c_l := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    c_CLOWNZ80_OPERAND_IX:
      begin
        c_state^.c_ixh := Byte(Value shr 8);
        c_state^.c_ixl := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    c_CLOWNZ80_OPERAND_IY:
      begin
        c_state^.c_iyh := Byte(Value shr 8);
        c_state^.c_iyl := Byte(Cardinal(Value) and Cardinal($FF));
      end;
    c_CLOWNZ80_OPERAND_PC:
      begin
        c_state^.c_program_counter := Word(Value);
      end;
    c_CLOWNZ80_OPERAND_SP:
      begin
        c_state^.c_stack_pointer := Word(Value);
      end;
    c_CLOWNZ80_OPERAND_BC_INDIRECT, c_CLOWNZ80_OPERAND_DE_INDIRECT, c_CLOWNZ80_OPERAND_HL_INDIRECT, c_CLOWNZ80_OPERAND_IX_INDIRECT, c_CLOWNZ80_OPERAND_IY_INDIRECT, c_CLOWNZ80_OPERAND_ADDRESS:
      begin
        if (Integer(c_instruction^.Metadata^.c_opcode) = Integer(c_CLOWNZ80_OPCODE_LD_16BIT)) then
        begin
          c_MemoryWrite16Bit(c_state, c_callbacks, c_instruction^.Address, Value);
        end
        else
        begin
          c_MemoryWrite(c_state, c_callbacks, c_instruction^.Address, Value);
        end;
      end;
  else
    begin
      Assert(0 <> 0);
    end;
  end;
end;

procedure c_DecodeInstruction(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction);
begin
  var c_opcode: Cardinal := Cardinal(c_OpcodeFetch(c_state, c_callbacks));
  var c_displacement: Cardinal := 0;
  c_instruction^.Metadata := @c_instruction_metadata_lookup_normal[c_state^.c_register_mode][c_opcode];
  if (c_instruction^.Metadata^.c_has_displacement <> 0) then
  begin
    c_displacement := Cardinal(c_InstructionMemoryRead(c_state, c_callbacks));
    c_displacement := Cardinal(Sub32(Cardinal(c_displacement) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(c_displacement) and Cardinal(Cardinal(1) shl 7)));
    c_state^.c_cycles := Word(c_state^.c_cycles + 5);
  end;
  c_instruction^.DoublePrefixMode := Byte(0);
  case Integer(c_instruction^.Metadata^.c_opcode) of
    c_CLOWNZ80_OPCODE_CB_PREFIX:
      begin
        if (Integer(c_state^.c_register_mode) = Integer(c_CLOWNZ80_REGISTER_MODE_HL)) then
        begin
          c_opcode := Cardinal(c_OpcodeFetch(c_state, c_callbacks));
          c_instruction^.Metadata := @c_instruction_metadata_lookup_bits[c_state^.c_register_mode][c_opcode];
        end
        else
        begin
          c_instruction^.DoublePrefixMode := Byte(1);
          c_opcode := Cardinal(c_InstructionMemoryRead(c_state, c_callbacks));
          c_state^.c_cycles := Word(c_state^.c_cycles - 3);
          if (Integer(c_state^.c_register_mode) = Integer(c_CLOWNZ80_REGISTER_MODE_IX)) then
          begin
            c_instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(c_state^.c_ixh) shl 8) or Cardinal(c_state^.c_ixl), c_displacement)) and Cardinal($FFFF));
          end
          else
          begin
            c_instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(c_state^.c_iyh) shl 8) or Cardinal(c_state^.c_iyl), c_displacement)) and Cardinal($FFFF));
          end;
          c_instruction^.Metadata := @c_instruction_metadata_lookup_bits[c_CLOWNZ80_REGISTER_MODE_HL][c_opcode];
          if (Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT)) then
          begin
            c_instruction^.Metadata := @c_instruction_metadata_lookup_bits[c_state^.c_register_mode][c_opcode];
          end;
        end;
      end;
    c_CLOWNZ80_OPCODE_ED_PREFIX:
      begin
        c_opcode := Cardinal(c_OpcodeFetch(c_state, c_callbacks));
        c_instruction^.Metadata := @c_instruction_metadata_lookup_misc[c_opcode];
      end;
  else
    begin
    end;
  end;
  case Integer(c_instruction^.Metadata^.c_operands[0]) of
    c_CLOWNZ80_OPERAND_LITERAL_8BIT:
      begin
        c_instruction^.Literal := Cardinal(c_InstructionMemoryRead(c_state, c_callbacks));
        if (c_instruction^.Metadata^.c_has_displacement <> 0) then
        begin
          c_state^.c_cycles := Word(c_state^.c_cycles - 3);
        end;
      end;
    c_CLOWNZ80_OPERAND_LITERAL_16BIT:
      begin
        c_instruction^.Literal := Cardinal(c_InstructionMemoryRead(c_state, c_callbacks));
        c_instruction^.Literal := Cardinal(Cardinal(c_instruction^.Literal) or Cardinal(c_InstructionMemoryRead(c_state, c_callbacks) shl 8));
      end;
  else
    begin
    end;
  end;
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal(2)) do
  begin
    case Integer(c_instruction^.Metadata^.c_operands[c_i]) of
      c_CLOWNZ80_OPERAND_BC_INDIRECT:
        begin
          c_instruction^.Address := Cardinal(Cardinal(Cardinal(c_state^.c_b) shl 8) or Cardinal(c_state^.c_c));
        end;
      c_CLOWNZ80_OPERAND_DE_INDIRECT:
        begin
          c_instruction^.Address := Cardinal(Cardinal(Cardinal(c_state^.c_d) shl 8) or Cardinal(c_state^.c_e));
        end;
      c_CLOWNZ80_OPERAND_HL_INDIRECT:
        begin
          c_instruction^.Address := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        end;
      c_CLOWNZ80_OPERAND_IX_INDIRECT:
        begin
          c_instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(c_state^.c_ixh) shl 8) or Cardinal(c_state^.c_ixl), c_displacement)) and Cardinal($FFFF));
        end;
      c_CLOWNZ80_OPERAND_IY_INDIRECT:
        begin
          c_instruction^.Address := Cardinal(Cardinal(Add32(Cardinal(Cardinal(c_state^.c_iyh) shl 8) or Cardinal(c_state^.c_iyl), c_displacement)) and Cardinal($FFFF));
        end;
      c_CLOWNZ80_OPERAND_ADDRESS:
        begin
          c_instruction^.Address := Cardinal(c_InstructionMemoryRead(c_state, c_callbacks));
          c_instruction^.Address := Cardinal(Cardinal(c_instruction^.Address) or Cardinal(c_InstructionMemoryRead(c_state, c_callbacks) shl 8));
        end;
    else
      begin
      end;
    end;
    Inc(c_i);
  end;
end;

function c_ComputeParity(Value: Cardinal): Byte;
begin
  Value := Cardinal(Cardinal(Value) xor Cardinal(Value shr 4));
  Value := Cardinal(Cardinal(Value) xor Cardinal(Value shr 2));
  Value := Cardinal(Cardinal(Value) xor Cardinal(Value shr 1));
  Exit(Byte(Ord(Cardinal(Cardinal(Value) and Cardinal(1)) = Cardinal(0))));
end;

procedure c_ExecuteInstruction(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks; c_instruction: PZ80Instruction);
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
  c_state^.c_register_mode := Byte(c_CLOWNZ80_REGISTER_MODE_HL);
  case Integer(c_instruction^.Metadata^.c_opcode) of
    c_CLOWNZ80_OPCODE_NOP:
      begin
      end;
    c_CLOWNZ80_OPCODE_EX_AF_AF:
      begin
        c_swap_holder := Byte(c_state^.c_a);
        c_state^.c_a := Byte(c_state^.c_a_);
        c_state^.c_a_ := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_f);
        c_state^.c_f := Byte(c_state^.c_f_);
        c_state^.c_f_ := Byte(c_swap_holder);
      end;
    c_CLOWNZ80_OPCODE_DJNZ:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_b := (c_state^.c_b + $FF) and $FF;
        c_state^.c_b := Byte(c_state^.c_b and $FF);
        if (Integer(c_state^.c_b) <> Integer(0)) then
        begin
          c_state^.c_program_counter := Word(c_state^.c_program_counter + (Sub32(Cardinal(c_instruction^.Literal) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(c_instruction^.Literal) and Cardinal(Cardinal(1) shl 7))));
          c_state^.c_program_counter := Word(c_state^.c_program_counter and $FFFF);
          c_state^.c_cycles := Word(c_state^.c_cycles + 5);
        end;
      end;
    c_CLOWNZ80_OPCODE_JR_CONDITIONAL:
      begin
        repeat
          if (not (c_EvaluateCondition(c_state^.c_f, Integer(c_instruction^.Metadata^.c_condition)) <> 0)) then
          begin
            Break;
          end;
          c_state^.c_program_counter := Word(c_state^.c_program_counter + (Sub32(Cardinal(c_instruction^.Literal) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(c_instruction^.Literal) and Cardinal(Cardinal(1) shl 7))));
          c_state^.c_program_counter := Word(c_state^.c_program_counter and $FFFF);
          c_state^.c_cycles := Word(c_state^.c_cycles + 5);
        until True;
      end;
    c_CLOWNZ80_OPCODE_JR_UNCONDITIONAL:
      begin
        c_state^.c_program_counter := Word(c_state^.c_program_counter + (Sub32(Cardinal(c_instruction^.Literal) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(c_instruction^.Literal) and Cardinal(Cardinal(1) shl 7))));
        c_state^.c_program_counter := Word(c_state^.c_program_counter and $FFFF);
        c_state^.c_cycles := Word(c_state^.c_cycles + 5);
      end;
    c_CLOWNZ80_OPCODE_LD_8BIT, c_CLOWNZ80_OPCODE_LD_16BIT:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_result_value := Cardinal(c_source_value);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
      end;
    c_CLOWNZ80_OPCODE_ADD_HL:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value_with_carry_16bit := Cardinal(Add32(Cardinal(c_source_value), Cardinal(c_destination_value)));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry_16bit) and Cardinal($FFFF));
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_SIGN or c_FLAG_MASK_ZERO) or c_FLAG_MASK_PARITY_OVERFLOW));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry_16bit shr (16 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (12 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        c_state^.c_cycles := Word(c_state^.c_cycles + 7);
      end;
    c_CLOWNZ80_OPCODE_INC_16BIT:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(Cardinal(Add32(c_destination_value, 1)) and Cardinal($FFFF));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
      end;
    c_CLOWNZ80_OPCODE_DEC_16BIT:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(Cardinal(Sub32(c_destination_value, 1)) and Cardinal($FFFF));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
      end;
    c_CLOWNZ80_OPCODE_INC_8BIT:
      begin
        c_source_value := Cardinal(1);
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(Cardinal(Add32(c_destination_value, c_source_value)) and Cardinal($FF));
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp323 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp323 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp323);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp325 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp325 = 0 then
        begin
          temp325 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp324 := Ord(temp325 <> 0);
        if temp324 = 0 then
        begin
          temp324 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp324);
      end;
    c_CLOWNZ80_OPCODE_DEC_8BIT:
      begin
        c_source_value := Cardinal(-1);
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(Cardinal(Add32(c_destination_value, c_source_value)) and Cardinal($FF));
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp326 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp326 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp326);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_HALF_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp328 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp328 = 0 then
        begin
          temp328 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp327 := Ord(temp328 <> 0);
        if temp327 = 0 then
        begin
          temp327 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp327);
      end;
    c_CLOWNZ80_OPCODE_RLCA:
      begin
        c_carry := Byte(Ord(Integer(c_state^.c_a and $80) <> Integer(0)));
        c_state^.c_a := Byte(c_state^.c_a shl 1);
        c_state^.c_a := Byte(c_state^.c_a and $FF);
        if (c_carry <> 0) then
        begin
          temp329 := $01;
        end
        else
        begin
          temp329 := 0;
        end;
        c_state^.c_a := Byte(c_state^.c_a or temp329);
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_SIGN or c_FLAG_MASK_ZERO) or c_FLAG_MASK_PARITY_OVERFLOW));
        if (c_carry <> 0) then
        begin
          temp330 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp330 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp330);
      end;
    c_CLOWNZ80_OPCODE_RRCA:
      begin
        c_carry := Byte(Ord(Integer(c_state^.c_a and $01) <> Integer(0)));
        c_state^.c_a := Byte(ArithmeticShiftRight(Integer(c_state^.c_a), 1));
        if (c_carry <> 0) then
        begin
          temp331 := $80;
        end
        else
        begin
          temp331 := 0;
        end;
        c_state^.c_a := Byte(c_state^.c_a or temp331);
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_SIGN or c_FLAG_MASK_ZERO) or c_FLAG_MASK_PARITY_OVERFLOW));
        if (c_carry <> 0) then
        begin
          temp332 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp332 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp332);
      end;
    c_CLOWNZ80_OPCODE_RLA:
      begin
        c_carry := Byte(Ord(Integer(c_state^.c_a and $80) <> Integer(0)));
        c_state^.c_a := Byte(c_state^.c_a shl 1);
        c_state^.c_a := Byte(c_state^.c_a and $FF);
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp333 := 1;
        end
        else
        begin
          temp333 := 0;
        end;
        c_state^.c_a := Byte(c_state^.c_a or temp333);
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_SIGN or c_FLAG_MASK_ZERO) or c_FLAG_MASK_PARITY_OVERFLOW));
        if (c_carry <> 0) then
        begin
          temp334 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp334 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp334);
      end;
    c_CLOWNZ80_OPCODE_RRA:
      begin
        c_carry := Byte(Ord(Integer(c_state^.c_a and $01) <> Integer(0)));
        c_state^.c_a := Byte(ArithmeticShiftRight(Integer(c_state^.c_a), 1));
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp335 := $80;
        end
        else
        begin
          temp335 := 0;
        end;
        c_state^.c_a := Byte(c_state^.c_a or temp335);
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_SIGN or c_FLAG_MASK_ZERO) or c_FLAG_MASK_PARITY_OVERFLOW));
        if (c_carry <> 0) then
        begin
          temp336 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp336 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp336);
      end;
    c_CLOWNZ80_OPCODE_DAA:
      begin
        c_original_a := Cardinal(c_state^.c_a);
        c_correction_factor := Cardinal(((c_state^.c_a + $66) xor c_state^.c_a) and $110);
        c_correction_factor := Cardinal(Cardinal(c_correction_factor) or Cardinal((c_state^.c_f and c_FLAG_MASK_CARRY) shl (8 - c_FLAG_BIT_CARRY)));
        c_correction_factor := Cardinal(Cardinal(c_correction_factor) or Cardinal((c_state^.c_f and c_FLAG_MASK_HALF_CARRY) shl (4 - c_FLAG_BIT_HALF_CARRY)));
        c_correction_factor := Cardinal(Cardinal(c_correction_factor shr 2) or Cardinal(c_correction_factor shr 3));
        if (Integer(c_state^.c_f and c_FLAG_MASK_ADD_SUBTRACT) <> Integer(0)) then
        begin
          c_state^.c_a := Byte(c_state^.c_a - c_correction_factor);
        end
        else
        begin
          c_state^.c_a := Byte(c_state^.c_a + c_correction_factor);
        end;
        c_state^.c_a := Byte(c_state^.c_a and $FF);
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_f := Byte(c_state^.c_f or (ArithmeticShiftRight(Integer(c_state^.c_a), (7 - c_FLAG_BIT_SIGN)) and c_FLAG_MASK_SIGN));
        c_state^.c_f := Byte(c_state^.c_f or (Ord(Integer(c_state^.c_a) = Integer(0)) shl c_FLAG_BIT_ZERO));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(c_original_a) xor Cardinal(c_state^.c_a)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        if (c_ComputeParity(c_state^.c_a) <> 0) then
        begin
          temp337 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp337 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp337);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_correction_factor shr (6 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
      end;
    c_CLOWNZ80_OPCODE_CPL:
      begin
        c_state^.c_a := Byte(not c_state^.c_a);
        c_state^.c_a := Byte(c_state^.c_a and $FF);
        c_state^.c_f := Byte(c_state^.c_f or (c_FLAG_MASK_HALF_CARRY or c_FLAG_MASK_ADD_SUBTRACT));
      end;
    c_CLOWNZ80_OPCODE_SCF:
      begin
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_SIGN or c_FLAG_MASK_ZERO) or c_FLAG_MASK_PARITY_OVERFLOW));
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_CARRY);
      end;
    c_CLOWNZ80_OPCODE_CCF:
      begin
        c_state^.c_f := Byte(c_state^.c_f and (not (c_FLAG_MASK_ADD_SUBTRACT or c_FLAG_MASK_HALF_CARRY)));
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp338 := c_FLAG_MASK_HALF_CARRY;
        end
        else
        begin
          temp338 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp338);
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_CARRY);
      end;
    c_CLOWNZ80_OPCODE_HALT:
      begin
      end;
    c_CLOWNZ80_OPCODE_ADD_A:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value_with_carry := Cardinal(Add32(c_destination_value, c_source_value));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry shr (8 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp339 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp339 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp339);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_ADC_A:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_state^.c_a);
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp340 := 1;
        end
        else
        begin
          temp340 := 0;
        end;
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), temp340));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry shr (8 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp341 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp341 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp341);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_SUB:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), 1));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry shr (8 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp342 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp342 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp342);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_HALF_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_SBC_A:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(c_state^.c_a);
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp343 := 0;
        end
        else
        begin
          temp343 := 1;
        end;
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), temp343));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry shr (8 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp344 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp344 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp344);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_HALF_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_AND:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Cardinal(c_destination_value) and Cardinal(c_source_value));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp345 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp345 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp345);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_HALF_CARRY);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp346 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp346 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp346);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_XOR:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Cardinal(c_destination_value) xor Cardinal(c_source_value));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp347 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp347 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp347);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp348 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp348 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp348);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_OR:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Cardinal(c_destination_value) or Cardinal(c_source_value));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp349 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp349 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp349);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp350 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp350 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp350);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_CP:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), 1));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry shr (8 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp351 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp351 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp351);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_HALF_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
      end;
    c_CLOWNZ80_OPCODE_POP:
      begin
        c_result_value := Cardinal(c_MemoryRead16Bit(c_state, c_callbacks, c_state^.c_stack_pointer));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer + 2);
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
      end;
    c_CLOWNZ80_OPCODE_RET_CONDITIONAL:
      begin
        repeat
          c_state^.c_cycles := Word(c_state^.c_cycles + 1);
          if (not (c_EvaluateCondition(c_state^.c_f, Integer(c_instruction^.Metadata^.c_condition)) <> 0)) then
          begin
            Break;
          end;
          c_state^.c_program_counter := Word(c_MemoryRead16Bit(c_state, c_callbacks, c_state^.c_stack_pointer));
          c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer + 2);
          c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        until True;
      end;
    c_CLOWNZ80_OPCODE_RET_UNCONDITIONAL, c_CLOWNZ80_OPCODE_RETN, c_CLOWNZ80_OPCODE_RETI:
      begin
        c_state^.c_program_counter := Word(c_MemoryRead16Bit(c_state, c_callbacks, c_state^.c_stack_pointer));
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer + 2);
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
      end;
    c_CLOWNZ80_OPCODE_EXX:
      begin
        c_swap_holder := Byte(c_state^.c_b);
        c_state^.c_b := Byte(c_state^.c_b_);
        c_state^.c_b_ := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_c);
        c_state^.c_c := Byte(c_state^.c_c_);
        c_state^.c_c_ := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_d);
        c_state^.c_d := Byte(c_state^.c_d_);
        c_state^.c_d_ := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_e);
        c_state^.c_e := Byte(c_state^.c_e_);
        c_state^.c_e_ := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_h);
        c_state^.c_h := Byte(c_state^.c_h_);
        c_state^.c_h_ := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_l);
        c_state^.c_l := Byte(c_state^.c_l_);
        c_state^.c_l_ := Byte(c_swap_holder);
      end;
    c_CLOWNZ80_OPCODE_LD_SP_HL:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_state^.c_stack_pointer := Word(c_source_value);
      end;
    c_CLOWNZ80_OPCODE_JP_CONDITIONAL:
      begin
        repeat
          if (not (c_EvaluateCondition(c_state^.c_f, Integer(c_instruction^.Metadata^.c_condition)) <> 0)) then
          begin
            Break;
          end;
          c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
          c_state^.c_program_counter := Word(c_source_value);
        until True;
      end;
    c_CLOWNZ80_OPCODE_JP_UNCONDITIONAL, c_CLOWNZ80_OPCODE_JP_HL:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_state^.c_program_counter := Word(c_source_value);
      end;
    c_CLOWNZ80_OPCODE_CB_PREFIX, c_CLOWNZ80_OPCODE_ED_PREFIX:
      begin
        Assert(0 <> 0);
      end;
    c_CLOWNZ80_OPCODE_DD_PREFIX:
      begin
        c_state^.c_register_mode := Byte(c_CLOWNZ80_REGISTER_MODE_IX);
      end;
    c_CLOWNZ80_OPCODE_FD_PREFIX:
      begin
        c_state^.c_register_mode := Byte(c_CLOWNZ80_REGISTER_MODE_IY);
      end;
    c_CLOWNZ80_OPCODE_OUT, c_CLOWNZ80_OPCODE_IN:
      begin
      end;
    c_CLOWNZ80_OPCODE_EX_SP_HL:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 3);
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(c_MemoryRead16Bit(c_state, c_callbacks, c_state^.c_stack_pointer));
        c_MemoryWrite16Bit(c_state, c_callbacks, c_state^.c_stack_pointer, c_destination_value);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
      end;
    c_CLOWNZ80_OPCODE_EX_DE_HL:
      begin
        c_swap_holder := Byte(c_state^.c_d);
        c_state^.c_d := Byte(c_state^.c_h);
        c_state^.c_h := Byte(c_swap_holder);
        c_swap_holder := Byte(c_state^.c_e);
        c_state^.c_e := Byte(c_state^.c_l);
        c_state^.c_l := Byte(c_swap_holder);
      end;
    c_CLOWNZ80_OPCODE_DI:
      begin
        c_state^.c_interrupts_enabled := Byte(0);
      end;
    c_CLOWNZ80_OPCODE_EI:
      begin
        c_state^.c_interrupts_enabled := Byte(1);
      end;
    c_CLOWNZ80_OPCODE_PUSH:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, (c_source_value shr 8));
        c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, (Cardinal(c_source_value) and Cardinal($FF)));
      end;
    c_CLOWNZ80_OPCODE_CALL_CONDITIONAL:
      begin
        repeat
          if (not (c_EvaluateCondition(c_state^.c_f, Integer(c_instruction^.Metadata^.c_condition)) <> 0)) then
          begin
            Break;
          end;
          c_state^.c_cycles := Word(c_state^.c_cycles + 1);
          c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
          c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
          c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, ArithmeticShiftRight(Integer(c_state^.c_program_counter), 8));
          c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
          c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
          c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, (c_state^.c_program_counter and $FF));
          c_state^.c_program_counter := Word(c_instruction^.Literal);
        until True;
      end;
    c_CLOWNZ80_OPCODE_CALL_UNCONDITIONAL:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, ArithmeticShiftRight(Integer(c_state^.c_program_counter), 8));
        c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, (c_state^.c_program_counter and $FF));
        c_state^.c_program_counter := Word(c_instruction^.Literal);
      end;
    c_CLOWNZ80_OPCODE_RST:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, ArithmeticShiftRight(Integer(c_state^.c_program_counter), 8));
        c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
        c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
        c_MemoryWrite(c_state, c_callbacks, c_state^.c_stack_pointer, (c_state^.c_program_counter and $FF));
        c_state^.c_program_counter := Word(c_instruction^.Metadata^.c_embedded_literal);
      end;
    c_CLOWNZ80_OPCODE_RLC:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
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
        c_state^.c_f := Byte(0);
        if (c_carry <> 0) then
        begin
          temp353 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp353 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp353);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp354 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp354 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp354);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp355 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp355 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp355);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp357 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp357 = 0 then
        begin
          temp357 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp356 := Ord(temp357 <> 0);
        if temp356 = 0 then
        begin
          temp356 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp356);
      end;
    c_CLOWNZ80_OPCODE_RRC:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
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
        c_state^.c_f := Byte(0);
        if (c_carry <> 0) then
        begin
          temp359 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp359 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp359);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp360 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp360 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp360);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp361 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp361 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp361);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp363 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp363 = 0 then
        begin
          temp363 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp362 := Ord(temp363 <> 0);
        if temp362 = 0 then
        begin
          temp362 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp362);
      end;
    c_CLOWNZ80_OPCODE_RL:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shl 1) and Cardinal($FF));
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Integer(c_state^.c_f) <> Integer(0)) then
        begin
          temp364 := $01;
        end
        else
        begin
          temp364 := 0;
        end;
        c_result_value := Cardinal(Cardinal(c_result_value) or Cardinal(temp364));
        c_state^.c_f := Byte(0);
        if (c_carry <> 0) then
        begin
          temp365 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp365 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp365);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp366 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp366 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp366);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp367 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp367 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp367);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp369 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp369 = 0 then
        begin
          temp369 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp368 := Ord(temp369 <> 0);
        if temp368 = 0 then
        begin
          temp368 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp368);
      end;
    c_CLOWNZ80_OPCODE_RR:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(c_destination_value shr 1);
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Integer(c_state^.c_f) <> Integer(0)) then
        begin
          temp370 := $80;
        end
        else
        begin
          temp370 := 0;
        end;
        c_result_value := Cardinal(Cardinal(c_result_value) or Cardinal(temp370));
        c_state^.c_f := Byte(0);
        if (c_carry <> 0) then
        begin
          temp371 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp371 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp371);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp372 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp372 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp372);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp373 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp373 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp373);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp375 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp375 = 0 then
        begin
          temp375 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp374 := Ord(temp375 <> 0);
        if temp374 = 0 then
        begin
          temp374 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp374);
      end;
    c_CLOWNZ80_OPCODE_SLA:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shl 1) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp376 := c_FLAG_MASK_SIGN;
        end
        else
        begin
          temp376 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp376);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp377 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp377 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp377);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp378 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp378 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp378);
        if (c_carry <> 0) then
        begin
          temp379 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp379 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp379);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp381 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp381 = 0 then
        begin
          temp381 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp380 := Ord(temp381 <> 0);
        if temp380 = 0 then
        begin
          temp380 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp380);
      end;
    c_CLOWNZ80_OPCODE_SLL:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($80)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(Cardinal(c_destination_value shl 1) or Cardinal(1)) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp382 := c_FLAG_MASK_SIGN;
        end
        else
        begin
          temp382 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp382);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp383 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp383 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp383);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp384 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp384 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp384);
        if (c_carry <> 0) then
        begin
          temp385 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp385 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp385);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp387 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp387 = 0 then
        begin
          temp387 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp386 := Ord(temp387 <> 0);
        if temp386 = 0 then
        begin
          temp386 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp386);
      end;
    c_CLOWNZ80_OPCODE_SRA:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(Cardinal(c_destination_value shr 1) or Cardinal(Cardinal(c_destination_value) and Cardinal($80)));
        c_state^.c_f := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp388 := c_FLAG_MASK_SIGN;
        end
        else
        begin
          temp388 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp388);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp389 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp389 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp389);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp390 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp390 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp390);
        if (c_carry <> 0) then
        begin
          temp391 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp391 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp391);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp393 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp393 = 0 then
        begin
          temp393 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp392 := Ord(temp393 <> 0);
        if temp392 = 0 then
        begin
          temp392 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp392);
      end;
    c_CLOWNZ80_OPCODE_SRL:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_carry := Byte(Ord(Cardinal(Cardinal(c_destination_value) and Cardinal($01)) <> Cardinal(0)));
        c_result_value := Cardinal(c_destination_value shr 1);
        c_state^.c_f := Byte(0);
        if (Cardinal(Cardinal(c_result_value) and Cardinal($80)) <> Cardinal(0)) then
        begin
          temp394 := c_FLAG_MASK_SIGN;
        end
        else
        begin
          temp394 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp394);
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp395 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp395 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp395);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp396 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp396 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp396);
        if (c_carry <> 0) then
        begin
          temp397 := c_FLAG_MASK_CARRY;
        end
        else
        begin
          temp397 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp397);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp399 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp399 = 0 then
        begin
          temp399 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp398 := Ord(temp399 <> 0);
        if temp398 = 0 then
        begin
          temp398 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp398);
      end;
    c_CLOWNZ80_OPCODE_BIT:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Cardinal(Cardinal(c_destination_value) and Cardinal(c_instruction^.Metadata^.c_embedded_literal)) = Cardinal(0)) then
        begin
          temp400 := (c_FLAG_MASK_ZERO or c_FLAG_MASK_PARITY_OVERFLOW);
        end
        else
        begin
          temp400 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp400);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_HALF_CARRY);
        temp402 := Ord(Integer(c_instruction^.Metadata^.c_embedded_literal) = Integer($80));
        if temp402 <> 0 then
        begin
          temp402 := Ord(Integer(c_state^.c_f and c_FLAG_MASK_ZERO) = Integer(0));
        end;
        if (temp402 <> 0) then
        begin
          temp401 := c_FLAG_MASK_SIGN;
        end
        else
        begin
          temp401 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp401);
        temp404 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp404 = 0 then
        begin
          temp404 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp403 := Ord(temp404 <> 0);
        if temp403 = 0 then
        begin
          temp403 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp403);
      end;
    c_CLOWNZ80_OPCODE_RES:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(Cardinal(c_destination_value) and Cardinal(c_instruction^.Metadata^.c_embedded_literal));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp406 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp406 = 0 then
        begin
          temp406 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp405 := Ord(temp406 <> 0);
        if temp405 = 0 then
        begin
          temp405 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp405);
      end;
    c_CLOWNZ80_OPCODE_SET:
      begin
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_result_value := Cardinal(Cardinal(c_destination_value) or Cardinal(c_instruction^.Metadata^.c_embedded_literal));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        temp408 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_HL_INDIRECT));
        if temp408 = 0 then
        begin
          temp408 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IX_INDIRECT));
        end;
        temp407 := Ord(temp408 <> 0);
        if temp407 = 0 then
        begin
          temp407 := Ord(Integer(c_instruction^.Metadata^.c_operands[1]) = Integer(c_CLOWNZ80_OPERAND_IY_INDIRECT));
        end;
        c_state^.c_cycles := Word(c_state^.c_cycles + temp407);
      end;
    c_CLOWNZ80_OPCODE_IN_REGISTER, c_CLOWNZ80_OPCODE_IN_NO_REGISTER, c_CLOWNZ80_OPCODE_OUT_REGISTER, c_CLOWNZ80_OPCODE_OUT_NO_REGISTER:
      begin
      end;
    c_CLOWNZ80_OPCODE_SBC_HL:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        c_source_value := Cardinal(not Cardinal(c_source_value));
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp409 := 0;
        end
        else
        begin
          temp409 := 1;
        end;
        c_result_value_with_carry_16bit := Cardinal(Add32(Add32(Cardinal(c_source_value), Cardinal(c_destination_value)), temp409));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry_16bit) and Cardinal($FFFF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (15 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp410 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp410 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp410);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (12 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (15 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry_16bit shr (16 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_HALF_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        c_state^.c_cycles := Word(c_state^.c_cycles + 7);
      end;
    c_CLOWNZ80_OPCODE_ADC_HL:
      begin
        c_source_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[0])));
        c_destination_value := Cardinal(c_ReadOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1])));
        if (Integer(c_state^.c_f and c_FLAG_MASK_CARRY) <> Integer(0)) then
        begin
          temp411 := 1;
        end
        else
        begin
          temp411 := 0;
        end;
        c_result_value_with_carry_16bit := Cardinal(Add32(Add32(Cardinal(c_source_value), Cardinal(c_destination_value)), temp411));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry_16bit) and Cardinal($FFFF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (15 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp412 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp412 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp412);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (12 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (15 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry_16bit shr (16 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_WriteOperand(c_state, c_callbacks, c_instruction, Integer(c_instruction^.Metadata^.c_operands[1]), c_result_value);
        c_state^.c_cycles := Word(c_state^.c_cycles + 7);
      end;
    c_CLOWNZ80_OPCODE_NEG:
      begin
        c_source_value := Cardinal(c_state^.c_a);
        c_source_value := Cardinal(not c_source_value);
        c_destination_value := Cardinal(0);
        c_result_value_with_carry := Cardinal(Add32(Add32(c_destination_value, c_source_value), 1));
        c_result_value := Cardinal(Cardinal(c_result_value_with_carry) and Cardinal($FF));
        c_state^.c_f := Byte(0);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value_with_carry shr (8 - c_FLAG_BIT_CARRY)) and Cardinal(c_FLAG_MASK_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp413 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp413 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp413);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(not (Cardinal(c_source_value) xor Cardinal(c_destination_value))) and Cardinal(Cardinal(c_source_value) xor Cardinal(c_result_value))) shr (7 - c_FLAG_BIT_PARITY_OVERFLOW)) and Cardinal(c_FLAG_MASK_PARITY_OVERFLOW)));
        c_state^.c_f := Byte(c_state^.c_f xor c_FLAG_MASK_HALF_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_IM:
      begin
      end;
    c_CLOWNZ80_OPCODE_LD_I_A:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_i := Byte(c_state^.c_a);
      end;
    c_CLOWNZ80_OPCODE_LD_R_A:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_r := Byte(c_state^.c_a);
      end;
    c_CLOWNZ80_OPCODE_LD_A_I:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_a := Byte(c_state^.c_i);
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or (ArithmeticShiftRight(Integer(c_state^.c_a), (7 - c_FLAG_BIT_SIGN)) and c_FLAG_MASK_SIGN));
        if (Integer(c_state^.c_a) = Integer(0)) then
        begin
          temp414 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp414 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp414);
      end;
    c_CLOWNZ80_OPCODE_LD_A_R:
      begin
        c_state^.c_cycles := Word(c_state^.c_cycles + 1);
        c_state^.c_a := Byte(c_state^.c_r);
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or (ArithmeticShiftRight(Integer(c_state^.c_a), (7 - c_FLAG_BIT_SIGN)) and c_FLAG_MASK_SIGN));
        if (Integer(c_state^.c_a) = Integer(0)) then
        begin
          temp415 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp415 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp415);
      end;
    c_CLOWNZ80_OPCODE_RRD:
      begin
        c_hl := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_hl_value := Cardinal(c_MemoryRead(c_state, c_callbacks, c_hl));
        c_hl_high := Cardinal(Cardinal(c_hl_value shr 4) and Cardinal($F));
        c_hl_low := Cardinal(Cardinal(c_hl_value shr 0) and Cardinal($F));
        c_a_high := Cardinal(ArithmeticShiftRight(Integer(c_state^.c_a), 4) and $F);
        c_a_low := Cardinal(ArithmeticShiftRight(Integer(c_state^.c_a), 0) and $F);
        c_state^.c_cycles := Word(c_state^.c_cycles + 4);
        c_MemoryWrite(c_state, c_callbacks, c_hl, (Cardinal(c_a_low shl 4) or Cardinal(c_hl_high shl 0)));
        c_result_value := Cardinal(Cardinal(c_a_high shl 4) or Cardinal(c_hl_low shl 0));
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp416 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp416 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp416);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp417 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp417 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp417);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_RLD:
      begin
        c_hl_scope211 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_hl_value_scope212 := Cardinal(c_MemoryRead(c_state, c_callbacks, c_hl_scope211));
        c_hl_high_scope213 := Cardinal(Cardinal(c_hl_value_scope212 shr 4) and Cardinal($F));
        c_hl_low_scope214 := Cardinal(Cardinal(c_hl_value_scope212 shr 0) and Cardinal($F));
        c_a_high_scope215 := Cardinal(ArithmeticShiftRight(Integer(c_state^.c_a), 4) and $F);
        c_a_low_scope216 := Cardinal(ArithmeticShiftRight(Integer(c_state^.c_a), 0) and $F);
        c_state^.c_cycles := Word(c_state^.c_cycles + 4);
        c_MemoryWrite(c_state, c_callbacks, c_hl_scope211, (Cardinal(c_hl_low_scope214 shl 4) or Cardinal(c_a_low_scope216 shl 0)));
        c_result_value := Cardinal(Cardinal(c_a_high_scope215 shl 4) or Cardinal(c_hl_high_scope213 shl 0));
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp418 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp418 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp418);
        if (c_ComputeParity(c_result_value) <> 0) then
        begin
          temp419 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp419 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp419);
        c_state^.c_a := Byte(c_result_value);
      end;
    c_CLOWNZ80_OPCODE_LDI:
      begin
        c_de := Cardinal(Cardinal(Cardinal(c_state^.c_d) shl 8) or Cardinal(c_state^.c_e));
        c_hl_scope217 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_MemoryWrite(c_state, c_callbacks, c_de, c_MemoryRead(c_state, c_callbacks, c_hl_scope217));
        c_state^.c_l := (c_state^.c_l + 1) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer(0)) then
        begin
          c_state^.c_h := (c_state^.c_h + 1) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_e := (c_state^.c_e + 1) and $FF;
        c_state^.c_e := Byte(c_state^.c_e and $FF);
        if (Integer(c_state^.c_e) = Integer(0)) then
        begin
          c_state^.c_d := (c_state^.c_d + 1) and $FF;
          c_state^.c_d := Byte(c_state^.c_d and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_CARRY or c_FLAG_MASK_ZERO) or c_FLAG_MASK_SIGN));
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp420 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp420 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp420);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
      end;
    c_CLOWNZ80_OPCODE_LDD:
      begin
        c_de_scope218 := Cardinal(Cardinal(Cardinal(c_state^.c_d) shl 8) or Cardinal(c_state^.c_e));
        c_hl_scope219 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_MemoryWrite(c_state, c_callbacks, c_de_scope218, c_MemoryRead(c_state, c_callbacks, c_hl_scope219));
        c_state^.c_l := (c_state^.c_l + $FF) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer($FF)) then
        begin
          c_state^.c_h := (c_state^.c_h + $FF) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_e := (c_state^.c_e + $FF) and $FF;
        c_state^.c_e := Byte(c_state^.c_e and $FF);
        if (Integer(c_state^.c_e) = Integer($FF)) then
        begin
          c_state^.c_d := (c_state^.c_d + $FF) and $FF;
          c_state^.c_d := Byte(c_state^.c_d and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_CARRY or c_FLAG_MASK_ZERO) or c_FLAG_MASK_SIGN));
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp421 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp421 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp421);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
      end;
    c_CLOWNZ80_OPCODE_LDIR:
      begin
        c_de_scope220 := Cardinal(Cardinal(Cardinal(c_state^.c_d) shl 8) or Cardinal(c_state^.c_e));
        c_hl_scope221 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_MemoryWrite(c_state, c_callbacks, c_de_scope220, c_MemoryRead(c_state, c_callbacks, c_hl_scope221));
        c_state^.c_l := (c_state^.c_l + 1) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer(0)) then
        begin
          c_state^.c_h := (c_state^.c_h + 1) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_e := (c_state^.c_e + 1) and $FF;
        c_state^.c_e := Byte(c_state^.c_e and $FF);
        if (Integer(c_state^.c_e) = Integer(0)) then
        begin
          c_state^.c_d := (c_state^.c_d + 1) and $FF;
          c_state^.c_d := Byte(c_state^.c_d and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_CARRY or c_FLAG_MASK_ZERO) or c_FLAG_MASK_SIGN));
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp422 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp422 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp422);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
        if (Integer(c_state^.c_f and c_FLAG_MASK_PARITY_OVERFLOW) <> Integer(0)) then
        begin
          c_state^.c_cycles := Word(c_state^.c_cycles + 5);
          c_state^.c_program_counter := Word(c_state^.c_program_counter - 2);
        end;
      end;
    c_CLOWNZ80_OPCODE_LDDR:
      begin
        c_de_scope222 := Cardinal(Cardinal(Cardinal(c_state^.c_d) shl 8) or Cardinal(c_state^.c_e));
        c_hl_scope223 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_MemoryWrite(c_state, c_callbacks, c_de_scope222, c_MemoryRead(c_state, c_callbacks, c_hl_scope223));
        c_state^.c_l := (c_state^.c_l + $FF) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer($FF)) then
        begin
          c_state^.c_h := (c_state^.c_h + $FF) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_e := (c_state^.c_e + $FF) and $FF;
        c_state^.c_e := Byte(c_state^.c_e and $FF);
        if (Integer(c_state^.c_e) = Integer($FF)) then
        begin
          c_state^.c_d := (c_state^.c_d + $FF) and $FF;
          c_state^.c_d := Byte(c_state^.c_d and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and ((c_FLAG_MASK_CARRY or c_FLAG_MASK_ZERO) or c_FLAG_MASK_SIGN));
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp423 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp423 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp423);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
        if (Integer(c_state^.c_f and c_FLAG_MASK_PARITY_OVERFLOW) <> Integer(0)) then
        begin
          c_state^.c_cycles := Word(c_state^.c_cycles + 5);
          c_state^.c_program_counter := Word(c_state^.c_program_counter - 2);
        end;
      end;
    c_CLOWNZ80_OPCODE_CPI:
      begin
        c_hl_scope224 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_source_value := Cardinal(c_MemoryRead(c_state, c_callbacks, c_hl_scope224));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        c_state^.c_l := (c_state^.c_l + 1) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer(0)) then
        begin
          c_state^.c_h := (c_state^.c_h + 1) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp424 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp424 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp424);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp425 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp425 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp425);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
      end;
    c_CLOWNZ80_OPCODE_CPD:
      begin
        c_hl_scope225 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_source_value := Cardinal(c_MemoryRead(c_state, c_callbacks, c_hl_scope225));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        c_state^.c_l := (c_state^.c_l + $FF) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer($FF)) then
        begin
          c_state^.c_h := (c_state^.c_h + $FF) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp426 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp426 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp426);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp427 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp427 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp427);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
      end;
    c_CLOWNZ80_OPCODE_CPIR:
      begin
        c_hl_scope226 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_source_value := Cardinal(c_MemoryRead(c_state, c_callbacks, c_hl_scope226));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        c_state^.c_l := (c_state^.c_l + 1) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer(0)) then
        begin
          c_state^.c_h := (c_state^.c_h + 1) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp428 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp428 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp428);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp429 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp429 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp429);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
        temp430 := Ord(Integer(c_state^.c_f and c_FLAG_MASK_PARITY_OVERFLOW) <> Integer(0));
        if temp430 <> 0 then
        begin
          temp430 := Ord(Integer(c_state^.c_f and c_FLAG_MASK_ZERO) = Integer(0));
        end;
        if (temp430 <> 0) then
        begin
          c_state^.c_cycles := Word(c_state^.c_cycles + 5);
          c_state^.c_program_counter := Word(c_state^.c_program_counter - 2);
        end;
      end;
    c_CLOWNZ80_OPCODE_CPDR:
      begin
        c_hl_scope227 := Cardinal(Cardinal(Cardinal(c_state^.c_h) shl 8) or Cardinal(c_state^.c_l));
        c_source_value := Cardinal(c_MemoryRead(c_state, c_callbacks, c_hl_scope227));
        c_destination_value := Cardinal(c_state^.c_a);
        c_result_value := Cardinal(Sub32(c_destination_value, c_source_value));
        c_state^.c_l := (c_state^.c_l + $FF) and $FF;
        c_state^.c_l := Byte(c_state^.c_l and $FF);
        if (Integer(c_state^.c_l) = Integer($FF)) then
        begin
          c_state^.c_h := (c_state^.c_h + $FF) and $FF;
          c_state^.c_h := Byte(c_state^.c_h and $FF);
        end;
        c_state^.c_c := (c_state^.c_c + $FF) and $FF;
        c_state^.c_c := Byte(c_state^.c_c and $FF);
        if (Integer(c_state^.c_c) = Integer($FF)) then
        begin
          c_state^.c_b := (c_state^.c_b + $FF) and $FF;
          c_state^.c_b := Byte(c_state^.c_b and $FF);
        end;
        c_state^.c_f := Byte(c_state^.c_f and c_FLAG_MASK_CARRY);
        if (Integer(c_state^.c_b or c_state^.c_c) <> Integer(0)) then
        begin
          temp431 := c_FLAG_MASK_PARITY_OVERFLOW;
        end
        else
        begin
          temp431 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp431);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal(c_result_value shr (7 - c_FLAG_BIT_SIGN)) and Cardinal(c_FLAG_MASK_SIGN)));
        if (Cardinal(c_result_value) = Cardinal(0)) then
        begin
          temp432 := c_FLAG_MASK_ZERO;
        end
        else
        begin
          temp432 := 0;
        end;
        c_state^.c_f := Byte(c_state^.c_f or temp432);
        c_state^.c_f := Byte(c_state^.c_f or (Cardinal((Cardinal(Cardinal(c_source_value) xor Cardinal(c_destination_value)) xor Cardinal(c_result_value)) shr (4 - c_FLAG_BIT_HALF_CARRY)) and Cardinal(c_FLAG_MASK_HALF_CARRY)));
        c_state^.c_f := Byte(c_state^.c_f or c_FLAG_MASK_ADD_SUBTRACT);
        c_state^.c_cycles := Word(c_state^.c_cycles + 2);
        temp433 := Ord(Integer(c_state^.c_f and c_FLAG_MASK_PARITY_OVERFLOW) <> Integer(0));
        if temp433 <> 0 then
        begin
          temp433 := Ord(Integer(c_state^.c_f and c_FLAG_MASK_ZERO) = Integer(0));
        end;
        if (temp433 <> 0) then
        begin
          c_state^.c_cycles := Word(c_state^.c_cycles + 5);
          c_state^.c_program_counter := Word(c_state^.c_program_counter - 2);
        end;
      end;
    c_CLOWNZ80_OPCODE_INI, c_CLOWNZ80_OPCODE_IND, c_CLOWNZ80_OPCODE_INIR, c_CLOWNZ80_OPCODE_INDR, c_CLOWNZ80_OPCODE_OUTI, c_CLOWNZ80_OPCODE_OUTD, c_CLOWNZ80_OPCODE_OTIR, c_CLOWNZ80_OPCODE_OTDR:
      begin
      end;
  end;
end;

procedure c_ClownZ80_Constant_Initialise();
begin
  var c_i: Cardinal := 0;
  while (Cardinal(c_i) < Cardinal($100)) do
  begin
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_normal[c_CLOWNZ80_REGISTER_MODE_HL][c_i], c_CLOWNZ80_INSTRUCTION_MODE_NORMAL, c_CLOWNZ80_REGISTER_MODE_HL, c_i);
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_normal[c_CLOWNZ80_REGISTER_MODE_IX][c_i], c_CLOWNZ80_INSTRUCTION_MODE_NORMAL, c_CLOWNZ80_REGISTER_MODE_IX, c_i);
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_normal[c_CLOWNZ80_REGISTER_MODE_IY][c_i], c_CLOWNZ80_INSTRUCTION_MODE_NORMAL, c_CLOWNZ80_REGISTER_MODE_IY, c_i);
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_bits[c_CLOWNZ80_REGISTER_MODE_HL][c_i], c_CLOWNZ80_INSTRUCTION_MODE_BITS, c_CLOWNZ80_REGISTER_MODE_HL, c_i);
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_bits[c_CLOWNZ80_REGISTER_MODE_IX][c_i], c_CLOWNZ80_INSTRUCTION_MODE_BITS, c_CLOWNZ80_REGISTER_MODE_IX, c_i);
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_bits[c_CLOWNZ80_REGISTER_MODE_IY][c_i], c_CLOWNZ80_INSTRUCTION_MODE_BITS, c_CLOWNZ80_REGISTER_MODE_IY, c_i);
    c_ClownZ80_DecodeInstructionMetadata(@c_instruction_metadata_lookup_misc[c_i], c_CLOWNZ80_INSTRUCTION_MODE_MISC, c_CLOWNZ80_REGISTER_MODE_HL, c_i);
    Inc(c_i);
  end;
end;

procedure c_ClownZ80_State_Initialise(c_state: PZ80State);
begin
  c_ClownZ80_Reset(c_state);
  c_state^.c_cycles := Word(1);
end;

procedure c_ClownZ80_Reset(c_state: PZ80State);
begin
  c_state^.c_register_mode := Byte(c_CLOWNZ80_REGISTER_MODE_HL);
  c_state^.c_program_counter := Word(0);
  c_state^.c_interrupts_enabled := Byte(0);
  c_state^.c_interrupt_pending := Byte(0);
end;

procedure c_ClownZ80_Interrupt(c_state: PZ80State; c_assert_interrupt: Byte);
begin
  c_state^.c_interrupt_pending := Byte(c_assert_interrupt);
end;

function c_ClownZ80_DoInstruction(c_state: PZ80State; c_callbacks: PZ80ReadAndWriteCallbacks): Cardinal;
var
  c_instruction: TZ80Instruction;
begin
  c_state^.c_cycles := Word(0);
  c_DecodeInstruction(c_state, c_callbacks, @c_instruction);
  c_ExecuteInstruction(c_state, c_callbacks, @c_instruction);
  var temp439: Integer := Ord(c_state^.c_interrupt_pending <> 0);
  if temp439 <> 0 then
  begin
    temp439 := Ord(c_state^.c_interrupts_enabled <> 0);
  end;
  var temp438: Integer := Ord(temp439 <> 0);
  if temp438 <> 0 then
  begin
    temp438 := Ord(Integer(c_instruction.Metadata^.c_opcode) <> Integer(c_CLOWNZ80_OPCODE_DD_PREFIX));
  end;
  var temp437: Integer := Ord(temp438 <> 0);
  if temp437 <> 0 then
  begin
    temp437 := Ord(Integer(c_instruction.Metadata^.c_opcode) <> Integer(c_CLOWNZ80_OPCODE_FD_PREFIX));
  end;
  var temp436: Integer := Ord(temp437 <> 0);
  if temp436 <> 0 then
  begin
    temp436 := Ord(Integer(c_instruction.Metadata^.c_opcode) <> Integer(c_CLOWNZ80_OPCODE_EI));
  end;
  if (temp436 <> 0) then
  begin
    c_state^.c_interrupts_enabled := Byte(0);
    c_state^.c_interrupt_pending := Byte(0);
    c_state^.c_cycles := Word(c_state^.c_cycles + 13);
    c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
    c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
    c_callbacks^.WriteCallback(Pointer(c_callbacks^.UserData), c_state^.c_stack_pointer, ArithmeticShiftRight(Integer(c_state^.c_program_counter), 8));
    c_state^.c_stack_pointer := (c_state^.c_stack_pointer + $FFFF) and $FFFF;
    c_state^.c_stack_pointer := Word(c_state^.c_stack_pointer and $FFFF);
    c_callbacks^.WriteCallback(Pointer(c_callbacks^.UserData), c_state^.c_stack_pointer, (c_state^.c_program_counter and $FF));
    c_state^.c_program_counter := Word($38);
  end;
  Exit(Cardinal(c_state^.c_cycles));
end;

end.

