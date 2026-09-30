unit MD.M68k;

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

type
  TSplitOpcode = record
    Raw: Cardinal;
    PrimaryRegister: Cardinal;
    SecondaryRegister: Cardinal;
    Bits6and7: Cardinal;
    PrimaryAddressMode: Integer;
    SecondaryAddressMode: Integer;
    Bit8: Byte;
  end;

  TM68kState = record
    DataRegisters: array[0..7] of Cardinal;
    AddressRegisters: array[0..7] of Cardinal;
    SupervisorStackPointer: Cardinal;
    UserStackPointer: Cardinal;
    ProgramCounter: Cardinal;
    StatusRegister: Word;
    InstructionRegister: Word;
    Halted: Byte;
    Stopped: Byte;
    PendingInterrupt: Byte;
  end;

  TMemoryReadCallback = function(UserData: Pointer; Address: Cardinal; DoHighByte: Byte; DoLowByte: Byte; CurrentCycle: Cardinal; var TerminateEarly: Byte): Cardinal;

  TMemoryWriteCallback = procedure(UserData: Pointer; Address: Cardinal; DoHighByte: Byte; DoLowByte: Byte; CurrentCycle: Cardinal; var TerminateEarly: Byte; Value: Cardinal);

  TInterruptAcknowledgeCallback = procedure(UserData: Pointer);

  TM68kReadWriteCallbacks = record
    ReadCallback: TMemoryReadCallback;
    WriteCallback: TMemoryWriteCallback;
    InterruptAcknowledgeCallback: TInterruptAcknowledgeCallback;
    UserData: Pointer;
  end;

  TMemoryAccessKind = (MEMORY_ADDRESS, MEMORY_BYTE, MEMORY_WORD,
    MEMORY_LONGWORD, MEMORY_LONGWORD_BACKWARDS);

  TDecodedMemoryAddressMode = record
    Address: Cardinal;
    AccessKind: TMemoryAccessKind;
  end;

  TRegisterAddressMode = record
    IsAddressRegister: Boolean;
    RegisterIndex: Integer;
    OperationSizeBitmask: Cardinal;
  end;

  TAddressModeData = record
    Reg: TRegisterAddressMode;
    Memory: TDecodedMemoryAddressMode;
  end;

  TDecodedAddressMode = record
    ModeType: Integer;
    Data: TAddressModeData;
  end;

  // Borrowed by instruction helpers while the caller owns the live CPU state.
  // Bus callbacks must observe updates immediately; these references never escape a call.
  PM68kState = ^TM68kState;

  PM68kReadWriteCallbacks = ^TM68kReadWriteCallbacks;

  TCPUExceptionState = record
    VectorOffset: Cardinal;
  end;

  TInstructionContext = record
    State: PM68kState;
    Callbacks: PM68kReadWriteCallbacks;
    CyclesLeftInInstruction: Cardinal;
    CyclesDone: Cardinal;
    Exception: TCPUExceptionState;
    OpCode: TSplitOpcode;
    OperationSize: Cardinal;
    MSBBitIndex: Cardinal;
    SourceDecodedAddressMode: TDecodedAddressMode;
    DestinationDecodedAddressMode: TDecodedAddressMode;
    SourceValue: Cardinal;
    DestinationValue: Cardinal;
    ResultValue: Cardinal;
    StartingProgramCounter: Cardinal;
    TerminateEarly: Byte;
  end;

const
  INSTRUCTION_ABCD = 0;
  INSTRUCTION_ADD = INSTRUCTION_ABCD + 1;
  INSTRUCTION_ADDA = INSTRUCTION_ADD + 1;
  INSTRUCTION_ADDAQ = INSTRUCTION_ADDA + 1;
  INSTRUCTION_ADDI = INSTRUCTION_ADDAQ + 1;
  INSTRUCTION_ADDQ = INSTRUCTION_ADDI + 1;
  INSTRUCTION_ADDX = INSTRUCTION_ADDQ + 1;
  INSTRUCTION_AND = INSTRUCTION_ADDX + 1;
  INSTRUCTION_ANDI = INSTRUCTION_AND + 1;
  INSTRUCTION_ANDI_TO_CCR = INSTRUCTION_ANDI + 1;
  INSTRUCTION_ANDI_TO_SR = INSTRUCTION_ANDI_TO_CCR + 1;
  INSTRUCTION_ASD_MEMORY = INSTRUCTION_ANDI_TO_SR + 1;
  INSTRUCTION_ASD_REGISTER = INSTRUCTION_ASD_MEMORY + 1;
  INSTRUCTION_BCC_SHORT = INSTRUCTION_ASD_REGISTER + 1;
  INSTRUCTION_BCC_WORD = INSTRUCTION_BCC_SHORT + 1;
  INSTRUCTION_BCHG_DYNAMIC = INSTRUCTION_BCC_WORD + 1;
  INSTRUCTION_BCHG_STATIC = INSTRUCTION_BCHG_DYNAMIC + 1;
  INSTRUCTION_BCLR_DYNAMIC = INSTRUCTION_BCHG_STATIC + 1;
  INSTRUCTION_BCLR_STATIC = INSTRUCTION_BCLR_DYNAMIC + 1;
  INSTRUCTION_BRA_SHORT = INSTRUCTION_BCLR_STATIC + 1;
  INSTRUCTION_BRA_WORD = INSTRUCTION_BRA_SHORT + 1;
  INSTRUCTION_BSET_DYNAMIC = INSTRUCTION_BRA_WORD + 1;
  INSTRUCTION_BSET_STATIC = INSTRUCTION_BSET_DYNAMIC + 1;
  INSTRUCTION_BSR_SHORT = INSTRUCTION_BSET_STATIC + 1;
  INSTRUCTION_BSR_WORD = INSTRUCTION_BSR_SHORT + 1;
  INSTRUCTION_BTST_DYNAMIC = INSTRUCTION_BSR_WORD + 1;
  INSTRUCTION_BTST_STATIC = INSTRUCTION_BTST_DYNAMIC + 1;
  INSTRUCTION_CHK = INSTRUCTION_BTST_STATIC + 1;
  INSTRUCTION_CLR = INSTRUCTION_CHK + 1;
  INSTRUCTION_CMP = INSTRUCTION_CLR + 1;
  INSTRUCTION_CMPA = INSTRUCTION_CMP + 1;
  INSTRUCTION_CMPI = INSTRUCTION_CMPA + 1;
  INSTRUCTION_CMPM = INSTRUCTION_CMPI + 1;
  INSTRUCTION_DBCC = INSTRUCTION_CMPM + 1;
  INSTRUCTION_DIVS = INSTRUCTION_DBCC + 1;
  INSTRUCTION_DIVU = INSTRUCTION_DIVS + 1;
  INSTRUCTION_EOR = INSTRUCTION_DIVU + 1;
  INSTRUCTION_EORI = INSTRUCTION_EOR + 1;
  INSTRUCTION_EORI_TO_CCR = INSTRUCTION_EORI + 1;
  INSTRUCTION_EORI_TO_SR = INSTRUCTION_EORI_TO_CCR + 1;
  INSTRUCTION_EXG = INSTRUCTION_EORI_TO_SR + 1;
  INSTRUCTION_EXT = INSTRUCTION_EXG + 1;
  INSTRUCTION_ILLEGAL = INSTRUCTION_EXT + 1;
  INSTRUCTION_JMP = INSTRUCTION_ILLEGAL + 1;
  INSTRUCTION_JSR = INSTRUCTION_JMP + 1;
  INSTRUCTION_LEA = INSTRUCTION_JSR + 1;
  INSTRUCTION_LINK = INSTRUCTION_LEA + 1;
  INSTRUCTION_LSD_MEMORY = INSTRUCTION_LINK + 1;
  INSTRUCTION_LSD_REGISTER = INSTRUCTION_LSD_MEMORY + 1;
  INSTRUCTION_MOVE = INSTRUCTION_LSD_REGISTER + 1;
  INSTRUCTION_MOVE_FROM_SR = INSTRUCTION_MOVE + 1;
  INSTRUCTION_MOVE_TO_CCR = INSTRUCTION_MOVE_FROM_SR + 1;
  INSTRUCTION_MOVE_TO_SR = INSTRUCTION_MOVE_TO_CCR + 1;
  INSTRUCTION_MOVE_USP = INSTRUCTION_MOVE_TO_SR + 1;
  INSTRUCTION_MOVEA = INSTRUCTION_MOVE_USP + 1;
  INSTRUCTION_MOVEM = INSTRUCTION_MOVEA + 1;
  INSTRUCTION_MOVEP = INSTRUCTION_MOVEM + 1;
  INSTRUCTION_MOVEQ = INSTRUCTION_MOVEP + 1;
  INSTRUCTION_MULS = INSTRUCTION_MOVEQ + 1;
  INSTRUCTION_MULU = INSTRUCTION_MULS + 1;
  INSTRUCTION_NBCD = INSTRUCTION_MULU + 1;
  INSTRUCTION_NEG = INSTRUCTION_NBCD + 1;
  INSTRUCTION_NEGX = INSTRUCTION_NEG + 1;
  INSTRUCTION_NOP = INSTRUCTION_NEGX + 1;
  INSTRUCTION_NOT = INSTRUCTION_NOP + 1;
  INSTRUCTION_OR = INSTRUCTION_NOT + 1;
  INSTRUCTION_ORI = INSTRUCTION_OR + 1;
  INSTRUCTION_ORI_TO_CCR = INSTRUCTION_ORI + 1;
  INSTRUCTION_ORI_TO_SR = INSTRUCTION_ORI_TO_CCR + 1;
  INSTRUCTION_PEA = INSTRUCTION_ORI_TO_SR + 1;
  INSTRUCTION_RESET = INSTRUCTION_PEA + 1;
  INSTRUCTION_ROD_MEMORY = INSTRUCTION_RESET + 1;
  INSTRUCTION_ROD_REGISTER = INSTRUCTION_ROD_MEMORY + 1;
  INSTRUCTION_ROXD_MEMORY = INSTRUCTION_ROD_REGISTER + 1;
  INSTRUCTION_ROXD_REGISTER = INSTRUCTION_ROXD_MEMORY + 1;
  INSTRUCTION_RTE = INSTRUCTION_ROXD_REGISTER + 1;
  INSTRUCTION_RTR = INSTRUCTION_RTE + 1;
  INSTRUCTION_RTS = INSTRUCTION_RTR + 1;
  INSTRUCTION_SBCD = INSTRUCTION_RTS + 1;
  INSTRUCTION_SCC = INSTRUCTION_SBCD + 1;
  INSTRUCTION_STOP = INSTRUCTION_SCC + 1;
  INSTRUCTION_SUB = INSTRUCTION_STOP + 1;
  INSTRUCTION_SUBA = INSTRUCTION_SUB + 1;
  INSTRUCTION_SUBAQ = INSTRUCTION_SUBA + 1;
  INSTRUCTION_SUBI = INSTRUCTION_SUBAQ + 1;
  INSTRUCTION_SUBQ = INSTRUCTION_SUBI + 1;
  INSTRUCTION_SUBX = INSTRUCTION_SUBQ + 1;
  INSTRUCTION_SWAP = INSTRUCTION_SUBX + 1;
  INSTRUCTION_TAS = INSTRUCTION_SWAP + 1;
  INSTRUCTION_TRAP = INSTRUCTION_TAS + 1;
  INSTRUCTION_TRAPV = INSTRUCTION_TRAP + 1;
  INSTRUCTION_TST = INSTRUCTION_TRAPV + 1;
  INSTRUCTION_UNLK = INSTRUCTION_TST + 1;
  INSTRUCTION_UNIMPLEMENTED_1 = INSTRUCTION_UNLK + 1;
  INSTRUCTION_UNIMPLEMENTED_2 = INSTRUCTION_UNIMPLEMENTED_1 + 1;

const
  ADDRESS_MODE_DATA_REGISTER = 0;
  ADDRESS_MODE_ADDRESS_REGISTER = 1;
  ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT = 2;
  ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT = 3;
  ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT = 4;
  ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT = 5;
  ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX = 6;
  ADDRESS_MODE_SPECIAL = 7;
  ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT = 0;
  ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG = 1;
  ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT = 2;
  ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX = 3;
  ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE = 4;

const
  CONDITION_CODE_CARRY_BIT = 0;
  CONDITION_CODE_OVERFLOW_BIT = 1;
  CONDITION_CODE_ZERO_BIT = 2;
  CONDITION_CODE_NEGATIVE_BIT = 3;
  CONDITION_CODE_EXTEND_BIT = 4;
  CONDITION_CODE_CARRY = ( 1 shl CONDITION_CODE_CARRY_BIT);
  CONDITION_CODE_OVERFLOW = ( 1 shl CONDITION_CODE_OVERFLOW_BIT);
  CONDITION_CODE_ZERO = ( 1 shl CONDITION_CODE_ZERO_BIT);
  CONDITION_CODE_NEGATIVE = ( 1 shl CONDITION_CODE_NEGATIVE_BIT);
  CONDITION_CODE_EXTEND = ( 1 shl CONDITION_CODE_EXTEND_BIT);
  CONDITION_CODE_REGISTER_MASK = ( ( ( ( CONDITION_CODE_EXTEND or CONDITION_CODE_NEGATIVE) or CONDITION_CODE_ZERO) or CONDITION_CODE_OVERFLOW) or CONDITION_CODE_CARRY);

const
  STATUS_INTERRUPT_MASK = ( 7 shl 8);
  STATUS_SUPERVISOR = ( 1 shl 13);
  STATUS_TRACE = ( 1 shl 15);
  STATUS_REGISTER_MASK = ( ( ( STATUS_TRACE or STATUS_SUPERVISOR) or STATUS_INTERRUPT_MASK) or CONDITION_CODE_REGISTER_MASK);

const
  DECODED_ADDRESS_MODE_TYPE_REGISTER = 0;
  DECODED_ADDRESS_MODE_TYPE_MEMORY = DECODED_ADDRESS_MODE_TYPE_REGISTER + 1;
  DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER = DECODED_ADDRESS_MODE_TYPE_MEMORY + 1;
  DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER = DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER + 1;

type
  ECPUException = class(Exception)
  public
    Code: Integer;
    constructor CreateCode(Value: Integer);
  end;

function GetInstruction(var OpCode: TSplitOpcode): Integer;

function DecodeOpcode(var SplitOpcode: TSplitOpcode; OpCode: Cardinal): Integer;

function ReadAddress(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;

function ReadByte(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;

function ReadWord(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;

function ReadLongWord(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;

function ReadLongWordBackwards(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;

procedure WriteByte(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);

procedure WriteWord(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);

procedure WriteLongWord(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);

procedure WriteLongWordBackwards(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);

procedure SetSupervisorMode(State: PM68kState; SupervisorMode: Byte);

procedure IncrementRegister(var RegisterValue: Cardinal; Delta: Cardinal);

procedure DecrementRegister(var RegisterValue: Cardinal; Delta: Cardinal);

procedure IncrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);

procedure DecrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);

procedure IncrementProgramCounter(State: PM68kState; Delta: Cardinal);

procedure DoInterrupt(var Stuff: TInstructionContext; VectorOffset: Cardinal);

procedure Group1Or2Exception(var Stuff: TInstructionContext; VectorOffset: Cardinal);

procedure Group0Exception(var Stuff: TInstructionContext; VectorOffset: Cardinal; AccessAddress: Cardinal; IsARead: Byte);

procedure DecodeMemoryAddressMode(var Stuff: TInstructionContext; var DecodedMemoryAddressMode: TDecodedMemoryAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);

procedure DecodeAddressMode(var Stuff: TInstructionContext; var DecodedAddressMode: TDecodedAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);

function GetValueUsingDecodedAddressMode(var Stuff: TInstructionContext; var DecodedAddressMode: TDecodedAddressMode): Cardinal;

procedure SetValueUsingDecodedAddressMode(var Stuff: TInstructionContext; var DecodedAddressMode: TDecodedAddressMode; Value: Cardinal);

function IsOpcodeConditionTrue(State: PM68kState; OpCode: Cardinal): Byte;

procedure SingleOperandInstructionExecutionTimeWordOnly(var Stuff: TInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal);

procedure SingleOperandInstructionExecutionTimeLongwordOnly(var Stuff: TInstructionContext; RegisterLongword: Cardinal; MemoryLongword: Cardinal);

procedure SingleOperandInstructionExecutionTime(var Stuff: TInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal; RegisterLongword: Cardinal; MemoryLongword: Cardinal);

procedure SingleOperandInstructionExecutionTimeCommon(var Stuff: TInstructionContext);

procedure ShiftRotateInstructionExecutionTimeRegister(var Stuff: TInstructionContext; Count: Cardinal);

procedure ShiftRotateInstructionExecutionTimeMemory(var Stuff: TInstructionContext);

procedure ADDXSUBXExecutionTime(var Stuff: TInstructionContext);

procedure StandardInstructionExecutionTime(var Stuff: TInstructionContext);

procedure StandardInstructionExecutionTimeQuick(var Stuff: TInstructionContext);

procedure LEAPEAInstructionExecutionTime(var Stuff: TInstructionContext);

procedure ABCDSBCDExecutionTime(var Stuff: TInstructionContext);

procedure SupervisorCheck(var Stuff: TInstructionContext);

procedure SetSizeByte(var Stuff: TInstructionContext);

procedure SetSizeWord(var Stuff: TInstructionContext);

procedure SetSizeLongword(var Stuff: TInstructionContext);

procedure SetSizeLongwordRegisterByteMemory(var Stuff: TInstructionContext);

procedure SetSizeMove(var Stuff: TInstructionContext);

procedure SetSizeExt(var Stuff: TInstructionContext);

procedure SetSizeStandard(var Stuff: TInstructionContext);

procedure SetMSBBitIndex(var Stuff: TInstructionContext);

procedure DecodeSourceImmediateData(var Stuff: TInstructionContext);

procedure DecodeSourceDataRegisterSecondary(var Stuff: TInstructionContext);

procedure DecodeSourceImmediateDataByte(var Stuff: TInstructionContext);

procedure DecodeSourceMemoryAddressPrimary(var Stuff: TInstructionContext);

procedure DecodeSourceStatusRegister(var Stuff: TInstructionContext);

procedure DecodeSourceImmediateDataWord(var Stuff: TInstructionContext);

procedure DecodeSourceBCDX(var Stuff: TInstructionContext);

procedure DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(var Stuff: TInstructionContext);

procedure DecodeSourcePrimaryAddressModeSized(var Stuff: TInstructionContext);

procedure DecodeSourceAddressRegisterPrimaryPostIncrement(var Stuff: TInstructionContext);

procedure DecodeSourcePrimaryAddressMode(var Stuff: TInstructionContext);

procedure DecodeSourcePrimaryAddressModeWord(var Stuff: TInstructionContext);

procedure DecodeDestinationDataRegisterPrimary(var Stuff: TInstructionContext);

procedure DecodeDestinationDataRegisterSecondary(var Stuff: TInstructionContext);

procedure DecodeDestinationAddressRegisterSecondary(var Stuff: TInstructionContext);

procedure DecodeDestinationSecondaryAddressMode(var Stuff: TInstructionContext);

procedure DecodeDestinationBCDX(var Stuff: TInstructionContext);

procedure DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(var Stuff: TInstructionContext);

procedure DecodeDestinationAddressRegisterSecondaryFull(var Stuff: TInstructionContext);

procedure DecodeDestinationAddressRegisterSecondaryPostIncrement(var Stuff: TInstructionContext);

procedure DecodeDestinationPrimaryAddressMode(var Stuff: TInstructionContext);

procedure DecodeDestinationConditionCodeRegister(var Stuff: TInstructionContext);

procedure DecodeDestinationStatusRegister(var Stuff: TInstructionContext);

procedure DecodeDestinationMOVEM(var Stuff: TInstructionContext);

procedure DecodeDestinationMOVEP(var Stuff: TInstructionContext);

procedure ReadSource(var Stuff: TInstructionContext);

procedure ReadDestination(var Stuff: TInstructionContext);

procedure WriteDestination(var Stuff: TInstructionContext);

procedure CarryStandardCarry(var Stuff: TInstructionContext);

procedure CarryStandardBorrow(var Stuff: TInstructionContext);

procedure CarryNEG(var Stuff: TInstructionContext);

procedure CarryClear(var Stuff: TInstructionContext);

procedure OverflowADD(var Stuff: TInstructionContext);

procedure OverflowSUB(var Stuff: TInstructionContext);

procedure OverflowNEG(var Stuff: TInstructionContext);

procedure OverflowClear(var Stuff: TInstructionContext);

procedure ZeroClearIfNonZeroUnaffectedOtherwise(var Stuff: TInstructionContext);

procedure ZeroSetIfZeroClearOtherwise(var Stuff: TInstructionContext);

procedure NegativeSetIfNegativeClearOtherwise(var Stuff: TInstructionContext);

procedure ExtendSetToCarry(var Stuff: TInstructionContext);

procedure ActionOR(var Stuff: TInstructionContext);

procedure ActionAND(var Stuff: TInstructionContext);

procedure ActionSUBCommon(var Stuff: TInstructionContext);

procedure ActionCMP(var Stuff: TInstructionContext);

procedure ActionCMPI(var Stuff: TInstructionContext);

procedure ActionCMPM(var Stuff: TInstructionContext);

procedure ActionSUB(var Stuff: TInstructionContext);

procedure ActionADDASUBACommon(var Stuff: TInstructionContext);

procedure ActionCMPA(var Stuff: TInstructionContext);

procedure ActionSUBA(var Stuff: TInstructionContext);

procedure ActionSUBQ(var Stuff: TInstructionContext);

procedure ActionADD(var Stuff: TInstructionContext);

procedure ActionADDA(var Stuff: TInstructionContext);

procedure ActionADDQ(var Stuff: TInstructionContext);

procedure ActionEOR(var Stuff: TInstructionContext);

procedure ActionBxxx(var Stuff: TInstructionContext);

procedure ActionBTST(var Stuff: TInstructionContext);

procedure ActionBCHG(var Stuff: TInstructionContext);

procedure ActionBCLR(var Stuff: TInstructionContext);

procedure ActionBSET(var Stuff: TInstructionContext);

procedure ActionMOVEP(var Stuff: TInstructionContext);

procedure ActionMOVEA(var Stuff: TInstructionContext);

procedure ActionMOVECommon(var Stuff: TInstructionContext);

procedure ActionMOVE(var Stuff: TInstructionContext);

procedure ActionLINK(var Stuff: TInstructionContext);

procedure ActionUNLK(var Stuff: TInstructionContext);

procedure ActionNEGX(var Stuff: TInstructionContext);

procedure ActionCLR(var Stuff: TInstructionContext);

procedure ActionNEG(var Stuff: TInstructionContext);

procedure ActionNOT(var Stuff: TInstructionContext);

procedure ActionEXT(var Stuff: TInstructionContext);

procedure ActionSWAP(var Stuff: TInstructionContext);

procedure ActionPEA(var Stuff: TInstructionContext);

procedure ActionILLEGAL(var Stuff: TInstructionContext);

procedure ActionTAS(var Stuff: TInstructionContext);

procedure ActionTRAP(var Stuff: TInstructionContext);

procedure ActionMOVEUSP(var Stuff: TInstructionContext);

procedure ProgramCounterChanged(var Stuff: TInstructionContext);

procedure SetStatusRegister(var Stuff: TInstructionContext; Value: Cardinal);

procedure ActionRESET(var Stuff: TInstructionContext);

procedure ActionSTOP(var Stuff: TInstructionContext);

procedure ActionRTE(var Stuff: TInstructionContext);

procedure ActionRTS(var Stuff: TInstructionContext);

procedure ActionTRAPV(var Stuff: TInstructionContext);

procedure ActionRTR(var Stuff: TInstructionContext);

procedure ActionJMP(var Stuff: TInstructionContext);

procedure ActionJSR(var Stuff: TInstructionContext);

procedure ActionLEA(var Stuff: TInstructionContext);

procedure ActionTST(var Stuff: TInstructionContext);

procedure ActionMOVEM(var Stuff: TInstructionContext);

procedure ActionCHK(var Stuff: TInstructionContext);

procedure ActionSCC(var Stuff: TInstructionContext);

procedure ActionBRASHORT(var Stuff: TInstructionContext);

procedure ActionBRAWORD(var Stuff: TInstructionContext);

procedure ActionBSRSHORT(var Stuff: TInstructionContext);

procedure ActionBSRWORD(var Stuff: TInstructionContext);

procedure ActionBCCSHORT(var Stuff: TInstructionContext);

procedure ActionBCCWORD(var Stuff: TInstructionContext);

procedure ActionDBCC(var Stuff: TInstructionContext);

procedure ActionMOVEQ(var Stuff: TInstructionContext);

function CountBitsSet(Value: Cardinal): Cardinal;

procedure ActionDIVCommon(var Stuff: TInstructionContext; IsSigned: Boolean);

procedure ActionDIVS(var Stuff: TInstructionContext);

procedure ActionDIVU(var Stuff: TInstructionContext);

procedure ActionSUBXCommon(var Stuff: TInstructionContext);

procedure ActionSUBX(var Stuff: TInstructionContext);

procedure ActionSBCDCommon(var Stuff: TInstructionContext);

procedure ActionSBCD(var Stuff: TInstructionContext);

procedure ActionNBCD(var Stuff: TInstructionContext);

procedure ActionMULCommon(var Stuff: TInstructionContext; IsSigned: Boolean; TotalOperations: Cardinal);

procedure ActionMULS(var Stuff: TInstructionContext);

procedure ActionMULU(var Stuff: TInstructionContext);

procedure ActionADDX(var Stuff: TInstructionContext);

procedure ActionABCD(var Stuff: TInstructionContext);

procedure ActionEXG(var Stuff: TInstructionContext);

procedure ActionASDMEMORY(var Stuff: TInstructionContext);

procedure ActionASDREGISTER(var Stuff: TInstructionContext);

procedure ActionLSDMEMORY(var Stuff: TInstructionContext);

procedure ActionLSDREGISTER(var Stuff: TInstructionContext);

procedure ActionRODMEMORY(var Stuff: TInstructionContext);

procedure ActionRODREGISTER(var Stuff: TInstructionContext);

procedure ActionROXDMEMORY(var Stuff: TInstructionContext);

procedure ActionROXDREGISTER(var Stuff: TInstructionContext);

procedure ActionUNIMPLEMENTED1(var Stuff: TInstructionContext);

procedure ActionUNIMPLEMENTED2(var Stuff: TInstructionContext);

procedure Clown68000Reset(var State: TM68kState; var Callbacks: TM68kReadWriteCallbacks);

procedure Clown68000Interrupt(var State: TM68kState; Level: Cardinal);

function Clown68000DoCycles(var State: TM68kState; var Callbacks: TM68kReadWriteCallbacks; CyclesToDo: Cardinal): Cardinal;

implementation

constructor ECPUException.CreateCode(Value: Integer);
begin
  inherited Create('68000 exception');
  Code := Value;
end;

function GetInstruction(var OpCode: TSplitOpcode): Integer;
begin
  var Instruction: Integer := INSTRUCTION_ILLEGAL;
  case ((OpCode.Raw shr 12) and $F) of
    $0:
      begin
        if OpCode.Bit8 <> 0 then
        begin
          if OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER then
            Instruction := INSTRUCTION_MOVEP
          else
            case OpCode.Bits6and7 of
              0:
                Instruction := INSTRUCTION_BTST_DYNAMIC;
              1:
                Instruction := INSTRUCTION_BCHG_DYNAMIC;
              2:
                Instruction := INSTRUCTION_BCLR_DYNAMIC;
              3:
                Instruction := INSTRUCTION_BSET_DYNAMIC;
            end;
        end
        else
        begin
          case OpCode.SecondaryRegister of
            0:
              if (OpCode.PrimaryAddressMode = ADDRESS_MODE_SPECIAL) and (OpCode.PrimaryRegister = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE)) then
                case OpCode.Bits6and7 of
                  0:
                    Instruction := INSTRUCTION_ORI_TO_CCR;
                  1:
                    Instruction := INSTRUCTION_ORI_TO_SR;
                end
              else
                Instruction := INSTRUCTION_ORI;
            1:
              if (OpCode.PrimaryAddressMode = ADDRESS_MODE_SPECIAL) and (OpCode.PrimaryRegister = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE)) then
                case OpCode.Bits6and7 of
                  0:
                    Instruction := INSTRUCTION_ANDI_TO_CCR;
                  1:
                    Instruction := INSTRUCTION_ANDI_TO_SR;
                end
              else
                Instruction := INSTRUCTION_ANDI;
            2:
              Instruction := INSTRUCTION_SUBI;
            3:
              Instruction := INSTRUCTION_ADDI;
            4:
              case OpCode.Bits6and7 of
                0:
                  Instruction := INSTRUCTION_BTST_STATIC;
                1:
                  Instruction := INSTRUCTION_BCHG_STATIC;
                2:
                  Instruction := INSTRUCTION_BCLR_STATIC;
                3:
                  Instruction := INSTRUCTION_BSET_STATIC;
              end;
            5:
              if (OpCode.PrimaryAddressMode = ADDRESS_MODE_SPECIAL) and (OpCode.PrimaryRegister = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE)) then
                case OpCode.Bits6and7 of
                  0:
                    Instruction := INSTRUCTION_EORI_TO_CCR;
                  1:
                    Instruction := INSTRUCTION_EORI_TO_SR;
                end
              else
                Instruction := INSTRUCTION_EORI;
            6:
              Instruction := INSTRUCTION_CMPI;
          end;
        end;
      end;
    $1, $2, $3:
      begin
        if (OpCode.Raw and $01C0) = $0040 then
          Instruction := INSTRUCTION_MOVEA
        else
          Instruction := INSTRUCTION_MOVE;
      end;
    $4:
      begin
        if OpCode.Bit8 <> 0 then
          case OpCode.Bits6and7 of
            3:
              Instruction := INSTRUCTION_LEA;
            2:
              Instruction := INSTRUCTION_CHK;
          end
        else
        begin
          if (OpCode.Raw and $0800) = 0 then
          begin
            if OpCode.Bits6and7 = 3 then
              case OpCode.SecondaryRegister of
                0:
                  Instruction := INSTRUCTION_MOVE_FROM_SR;
                2:
                  Instruction := INSTRUCTION_MOVE_TO_CCR;
                3:
                  Instruction := INSTRUCTION_MOVE_TO_SR;
              end
            else
              case OpCode.SecondaryRegister of
                0:
                  Instruction := INSTRUCTION_NEGX;
                1:
                  Instruction := INSTRUCTION_CLR;
                2:
                  Instruction := INSTRUCTION_NEG;
                3:
                  Instruction := INSTRUCTION_NOT;
              end;
          end
          else
          begin
            if (OpCode.Raw and $0200) = 0 then
            begin
              if (OpCode.Raw and $01B8) = $0080 then
                Instruction := INSTRUCTION_EXT
              else if (OpCode.Raw and $01C0) = $0000 then
                Instruction := INSTRUCTION_NBCD
              else if (OpCode.Raw and $01F8) = $0040 then
                Instruction := INSTRUCTION_SWAP
              else if (OpCode.Raw and $01C0) = $0040 then
                Instruction := INSTRUCTION_PEA
              else if (OpCode.Raw and $0B80) = $0880 then
                Instruction := INSTRUCTION_MOVEM
            end
            else if (OpCode.Raw = $4AFA) or (OpCode.Raw = $4AFB) or (OpCode.Raw = $4AFC) then
              Instruction := INSTRUCTION_ILLEGAL
            else if (OpCode.Raw and $0FC0) = $0AC0 then
              Instruction := INSTRUCTION_TAS
            else if (OpCode.Raw and $0F00) = $0A00 then
              Instruction := INSTRUCTION_TST
            else if (OpCode.Raw and $0FF0) = $0E40 then
              Instruction := INSTRUCTION_TRAP
            else if (OpCode.Raw and $0FF8) = $0E50 then
              Instruction := INSTRUCTION_LINK
            else if (OpCode.Raw and $0FF8) = $0E58 then
              Instruction := INSTRUCTION_UNLK
            else if (OpCode.Raw and $0FF0) = $0E60 then
              Instruction := INSTRUCTION_MOVE_USP
            else if (OpCode.Raw and $0FF8) = $0E70 then
              case OpCode.PrimaryRegister of
                0:
                  Instruction := INSTRUCTION_RESET;
                1:
                  Instruction := INSTRUCTION_NOP;
                2:
                  Instruction := INSTRUCTION_STOP;
                3:
                  Instruction := INSTRUCTION_RTE;
                5:
                  Instruction := INSTRUCTION_RTS;
                6:
                  Instruction := INSTRUCTION_TRAPV;
                7:
                  Instruction := INSTRUCTION_RTR;
              end
            else if (OpCode.Raw and $0FC0) = $0E80 then
              Instruction := INSTRUCTION_JSR
            else if (OpCode.Raw and $0FC0) = $0EC0 then
              Instruction := INSTRUCTION_JMP;
          end;
        end;
      end;
    $5:
      begin
        if OpCode.Bits6and7 = 3 then
        begin
          if OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER then
            Instruction := INSTRUCTION_DBCC
          else
            Instruction := INSTRUCTION_SCC;
        end
        else
        begin
          if OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER then
          begin
            if OpCode.Bit8 <> 0 then
              Instruction := INSTRUCTION_SUBAQ
            else
              Instruction := INSTRUCTION_ADDAQ;
          end
          else
          begin
            if OpCode.Bit8 <> 0 then
              Instruction := INSTRUCTION_SUBQ
            else
              Instruction := INSTRUCTION_ADDQ;
          end;
        end;
      end;
    $6:
      begin
        if OpCode.SecondaryRegister <> 0 then
        begin
          if (OpCode.Raw and $00FF) = 0 then
            Instruction := INSTRUCTION_BCC_WORD
          else
            Instruction := INSTRUCTION_BCC_SHORT;
        end
        else
        begin
          if OpCode.Bit8 <> 0 then
          begin
            if (OpCode.Raw and $00FF) = 0 then
              Instruction := INSTRUCTION_BSR_WORD
            else
              Instruction := INSTRUCTION_BSR_SHORT;
          end
          else
          begin
            if (OpCode.Raw and $00FF) = 0 then
              Instruction := INSTRUCTION_BRA_WORD
            else
              Instruction := INSTRUCTION_BRA_SHORT;
          end;
        end;
      end;
    $7:
      Instruction := INSTRUCTION_MOVEQ;
    $8:
      begin
        if OpCode.Bits6and7 = 3 then
        begin
          if OpCode.Bit8 <> 0 then
            Instruction := INSTRUCTION_DIVS
          else
            Instruction := INSTRUCTION_DIVU;
        end
        else
        begin
          if (OpCode.Raw and $0170) = $0100 then
            Instruction := INSTRUCTION_SBCD
          else
            Instruction := INSTRUCTION_OR;
        end;
      end;
    $9:
      begin
        if OpCode.Bits6and7 = 3 then
          Instruction := INSTRUCTION_SUBA
        else
        begin
          if (OpCode.Raw and $0130) = $0100 then
            Instruction := INSTRUCTION_SUBX
          else
            Instruction := INSTRUCTION_SUB;
        end;
      end;
    $A:
      Instruction := INSTRUCTION_UNIMPLEMENTED_1;
    $B:
      begin
        if OpCode.Bits6and7 = 3 then
          Instruction := INSTRUCTION_CMPA
        else
        begin
          if OpCode.Bit8 = 0 then
            Instruction := INSTRUCTION_CMP
          else
          begin
            if OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER then
              Instruction := INSTRUCTION_CMPM
            else
              Instruction := INSTRUCTION_EOR;
          end;
        end;
      end;
    $C:
      begin
        if OpCode.Bits6and7 = 3 then
        begin
          if OpCode.Bit8 <> 0 then
            Instruction := INSTRUCTION_MULS
          else
            Instruction := INSTRUCTION_MULU;
        end
        else
        begin
          if (OpCode.Raw and $0130) = $0100 then
          begin
            if OpCode.Bits6and7 = 0 then
              Instruction := INSTRUCTION_ABCD
            else
              Instruction := INSTRUCTION_EXG;
          end
          else
            Instruction := INSTRUCTION_AND;
        end;
      end;
    $D:
      begin
        if OpCode.Bits6and7 = 3 then
          Instruction := INSTRUCTION_ADDA
        else
        begin
          if (OpCode.Raw and $0130) = $0100 then
            Instruction := INSTRUCTION_ADDX
          else
            Instruction := INSTRUCTION_ADD;
        end;
      end;
    $E:
      begin
        if OpCode.Bits6and7 = 3 then
          case OpCode.SecondaryRegister of
            0:
              Instruction := INSTRUCTION_ASD_MEMORY;
            1:
              Instruction := INSTRUCTION_LSD_MEMORY;
            2:
              Instruction := INSTRUCTION_ROXD_MEMORY;
            3:
              Instruction := INSTRUCTION_ROD_MEMORY;
          end
        else
          case OpCode.Raw and $0018 of
            $0000:
              Instruction := INSTRUCTION_ASD_REGISTER;
            $0008:
              Instruction := INSTRUCTION_LSD_REGISTER;
            $0010:
              Instruction := INSTRUCTION_ROXD_REGISTER;
            $0018:
              Instruction := INSTRUCTION_ROD_REGISTER;
          end;
      end;
    $F:
      Instruction := INSTRUCTION_UNIMPLEMENTED_2;
  end;
  Exit(Instruction);
end;

function DecodeOpcode(var SplitOpcode: TSplitOpcode; OpCode: Cardinal): Integer;
begin
  SplitOpcode.Raw := OpCode;
  SplitOpcode.Bits6and7 := (SplitOpcode.Raw shr 6) and 3;
  SplitOpcode.Bit8 := Ord((SplitOpcode.Raw and $100) <> 0);
  SplitOpcode.PrimaryRegister := SplitOpcode.Raw and 7;
  SplitOpcode.PrimaryAddressMode := Integer((SplitOpcode.Raw shr 3) and 7);
  SplitOpcode.SecondaryAddressMode := Integer((SplitOpcode.Raw shr 6) and 7);
  SplitOpcode.SecondaryRegister := (SplitOpcode.Raw shr 9) and 7;
  Exit(GetInstruction(SplitOpcode));
end;

function ReadAddress(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;
begin
  Exit(Address);
end;

function ReadByte(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;
begin
  var Callbacks := Stuff.Callbacks;
  var IsOdd := (Address and 1) <> 0;

  Result := Callbacks^.ReadCallback(
    Callbacks^.UserData,
    (Address shr 1) and $7FFFFF,
    Ord(not IsOdd),
    Ord(IsOdd),
    Stuff.CyclesDone,
    Stuff.TerminateEarly
  );

  if not IsOdd then
    Result := Result shr 8;

  Result := Result and $FF;
end;

function ReadWord(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;
begin
  var Callbacks: PM68kReadWriteCallbacks := Stuff.Callbacks;
  if (Address and 1) <> 0 then
    Group0Exception(Stuff, 3, Address, 1);
  Result := Callbacks^.ReadCallback(
    Callbacks^.UserData,
    (Cardinal(Address div 2) and $7FFFFF),
    1, 1,
    Stuff.CyclesDone,
    Stuff.TerminateEarly);
end;

function ReadLongWord(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := 0;
  Value := Value or (ReadWord(Stuff, (Address)) shl 16);
  Exit(Value or ReadWord(Stuff, (Add32(Address, 2))));
end;

function ReadLongWordBackwards(var Stuff: TInstructionContext; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := 0;
  Value := Value or ReadWord(Stuff, (Add32(Address, 2)));
  Exit(Value or (ReadWord(Stuff, (Address)) shl 16));
end;

procedure WriteByte(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);
begin
  var Callbacks: PM68kReadWriteCallbacks := Stuff.Callbacks;
  var Odd: Byte := Ord((Address and 1) <> 0);
  var ByteValue: Cardinal := Value and $FF;
  Callbacks^.WriteCallback(
    Callbacks^.UserData,
    (Cardinal(Address div 2) and $7FFFFF),
    Ord((Odd = 0)),
    Odd,
    Stuff.CyclesDone,
    Stuff.TerminateEarly,
    (ByteValue or (ByteValue shl 8)));
end;

procedure WriteWord(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);
begin
  var Callbacks: PM68kReadWriteCallbacks := Stuff.Callbacks;
  if (Address and 1) <> 0 then
    Group0Exception(Stuff, 3, Address, 0);
  Callbacks^.WriteCallback(
    Callbacks^.UserData,
    (Cardinal(Address div 2) and $7FFFFF),
    1, 1,
    Stuff.CyclesDone,
    Stuff.TerminateEarly,
    (Value and $FFFF));
end;

procedure WriteLongWord(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);
begin
  WriteWord(Stuff, (Address), (Value shr 16));
  WriteWord(Stuff, (Add32(Address, 2)), (Value));
end;

procedure WriteLongWordBackwards(var Stuff: TInstructionContext; Address: Cardinal; Value: Cardinal);
begin
  WriteWord(Stuff, (Add32(Address, 2)), (Value));
  WriteWord(Stuff, (Address), (Value shr 16));
end;

procedure SetSupervisorMode(State: PM68kState; SupervisorMode: Byte);
begin
  var AlreadySupervisorMode: Byte := Ord(Integer(State^.StatusRegister and STATUS_SUPERVISOR) <> 0);
  if SupervisorMode <> 0 then
  begin
    if AlreadySupervisorMode = 0 then
    begin
      State^.StatusRegister := Word(State^.StatusRegister or STATUS_SUPERVISOR);
      State^.UserStackPointer := State^.AddressRegisters[7];
      State^.AddressRegisters[7] := State^.SupervisorStackPointer;
    end;
  end
  else
  begin
    if AlreadySupervisorMode <> 0 then
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not STATUS_SUPERVISOR));
      State^.SupervisorStackPointer := State^.AddressRegisters[7];
      State^.AddressRegisters[7] := State^.UserStackPointer;
    end;
  end;
end;

procedure IncrementRegister(var RegisterValue: Cardinal; Delta: Cardinal);
begin
  RegisterValue := Add32(RegisterValue, Delta);
end;

procedure DecrementRegister(var RegisterValue: Cardinal; Delta: Cardinal);
begin
  RegisterValue := Sub32(RegisterValue, Delta);
end;

procedure IncrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);
begin
  IncrementRegister(State^.AddressRegisters[AddressRegisterIndex], Delta);
end;

procedure DecrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);
begin
  DecrementRegister(State^.AddressRegisters[AddressRegisterIndex], Delta);
end;

procedure IncrementProgramCounter(State: PM68kState; Delta: Cardinal);
begin
  IncrementRegister(State^.ProgramCounter, Delta);
end;

procedure DoInterrupt(var Stuff: TInstructionContext; VectorOffset: Cardinal);
begin
  var State: PM68kState := Stuff.State;
  var CopyStatusRegister: Word := State^.StatusRegister;
  State^.StatusRegister := Word(State^.StatusRegister and (not STATUS_TRACE));
  SetSupervisorMode(State, 1);
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], State^.ProgramCounter);
  DecrementAddressRegister(State, 7, 2);
  WriteWord(Stuff, State^.AddressRegisters[7], CopyStatusRegister);
  State^.ProgramCounter := ReadLongWord(Stuff, (Mul32(VectorOffset, 4)));
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 30);
end;

procedure Group1Or2Exception(var Stuff: TInstructionContext; VectorOffset: Cardinal);
begin
  Stuff.Exception.VectorOffset := VectorOffset;
  raise ECPUException.CreateCode(2);
end;

procedure Group0Exception(var Stuff: TInstructionContext; VectorOffset: Cardinal; AccessAddress: Cardinal; IsARead: Byte);
begin
  var State: PM68kState := Stuff.State;
  if (State^.AddressRegisters[7] and 1) <> 0 then
    State^.Halted := 1
  else
  begin
    DoInterrupt(Stuff, VectorOffset);
    DecrementAddressRegister(State, 7, 2);
    WriteWord(Stuff, State^.AddressRegisters[7], State^.InstructionRegister);
    DecrementAddressRegister(State, 7, 4);
    WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], AccessAddress);
    DecrementAddressRegister(State, 7, 2);
    WriteWord(Stuff, State^.AddressRegisters[7], (((State^.InstructionRegister and $FFE0) or (IsARead shl 4)) or $E));
  end;
  raise ECPUException.CreateCode(1);
end;

procedure DecodeMemoryAddressMode(var Stuff: TInstructionContext; var DecodedMemoryAddressMode: TDecodedMemoryAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);
begin
  var State := Stuff.State;
  var Address: Cardinal;
  var IsLongword := OperationSizeInBytes = 4;

  case OperationSizeInBytes of
    0:
      DecodedMemoryAddressMode.AccessKind := MEMORY_ADDRESS;
    1:
      DecodedMemoryAddressMode.AccessKind := MEMORY_BYTE;
    2:
      DecodedMemoryAddressMode.AccessKind := MEMORY_WORD;
    4:
      if AddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT then
        DecodedMemoryAddressMode.AccessKind := MEMORY_LONGWORD_BACKWARDS
      else
        DecodedMemoryAddressMode.AccessKind := MEMORY_LONGWORD;
  else
    Assert(False);
    DecodedMemoryAddressMode.AccessKind := MEMORY_BYTE;
  end;

  if (AddressMode = ADDRESS_MODE_SPECIAL) and (AddressModeRegister = ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT) then
  begin
    var ShortAddress := ReadWord(Stuff, State^.ProgramCounter);
    Address := Sub32(ShortAddress and $7FFF, ShortAddress and $8000);
    IncrementProgramCounter(State, 2);

    if IsLongword then
      Inc(Stuff.CyclesLeftInInstruction, 12)
    else
      Inc(Stuff.CyclesLeftInInstruction, 8);
  end
  else if (AddressMode = ADDRESS_MODE_SPECIAL) and (AddressModeRegister = ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG) then
  begin
    Address := ReadLongWord(Stuff, State^.ProgramCounter);
    IncrementProgramCounter(State, 4);

    if IsLongword then
      Inc(Stuff.CyclesLeftInInstruction, 16)
    else
      Inc(Stuff.CyclesLeftInInstruction, 12);
  end
  else if (AddressMode = ADDRESS_MODE_SPECIAL) and (AddressModeRegister = ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE) then
  begin
    if OperationSizeInBytes = 1 then
    begin
      Address := State^.ProgramCounter + 1;
      IncrementProgramCounter(State, 2);
    end
    else
    begin
      Address := State^.ProgramCounter;
      IncrementProgramCounter(State, OperationSizeInBytes);
    end;

    if IsLongword then
      Inc(Stuff.CyclesLeftInInstruction, 8)
    else
      Inc(Stuff.CyclesLeftInInstruction, 4);
  end
  else if AddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT then
  begin
    Address := State^.AddressRegisters[AddressModeRegister];

    if IsLongword then
      Inc(Stuff.CyclesLeftInInstruction, 8)
    else
      Inc(Stuff.CyclesLeftInInstruction, 4);
  end
  else if AddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT then
  begin
    var IncrementDecrementSize := OperationSizeInBytes;

    if (AddressModeRegister = 7) and (OperationSizeInBytes = 1) then
      IncrementDecrementSize := 2;

    DecrementAddressRegister(State, AddressModeRegister, IncrementDecrementSize);
    Address := State^.AddressRegisters[AddressModeRegister];

    if IsLongword then
      Inc(Stuff.CyclesLeftInInstruction, 10)
    else
      Inc(Stuff.CyclesLeftInInstruction, 6);
  end
  else if AddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT then
  begin
    var IncrementDecrementSize := OperationSizeInBytes;

    if (AddressModeRegister = 7) and (OperationSizeInBytes = 1) then
      IncrementDecrementSize := 2;

    Address := State^.AddressRegisters[AddressModeRegister];
    IncrementAddressRegister(State, AddressModeRegister, IncrementDecrementSize);

    if IsLongword then
      Inc(Stuff.CyclesLeftInInstruction, 8)
    else
      Inc(Stuff.CyclesLeftInInstruction, 4);
  end
  else
  begin
    var IsPCDisplacement := (AddressMode = ADDRESS_MODE_SPECIAL) and
      (AddressModeRegister = ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT);

    var IsPCIndex := (AddressMode = ADDRESS_MODE_SPECIAL) and
      (AddressModeRegister = ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX);

    if IsPCDisplacement or IsPCIndex then
      Address := State^.ProgramCounter
    else
      Address := State^.AddressRegisters[AddressModeRegister];

    if (AddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT) or IsPCDisplacement then
    begin
      var Displacement := ReadWord(Stuff, State^.ProgramCounter);
      Address := Add32(Address, Sub32(Displacement and $7FFF, Displacement and $8000));
      IncrementProgramCounter(State, 2);

      if IsLongword then
        Inc(Stuff.CyclesLeftInInstruction, 12)
      else
        Inc(Stuff.CyclesLeftInInstruction, 8);
    end
    else if (AddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX) or IsPCIndex then
    begin
      var ExtensionWord := ReadWord(Stuff, State^.ProgramCounter);
      var DisplacementRegister := (ExtensionWord shr 12) and 7;
      var DisplacementRegisterValue: Cardinal;

      if (ExtensionWord and $8000) <> 0 then
        DisplacementRegisterValue := State^.AddressRegisters[DisplacementRegister]
      else
        DisplacementRegisterValue := State^.DataRegisters[DisplacementRegister];

      if (ExtensionWord and $0800) = 0 then
        DisplacementRegisterValue := Sub32(DisplacementRegisterValue and $7FFF, DisplacementRegisterValue and $8000);

      var DisplacementLiteralValue := Sub32(ExtensionWord and $7F, ExtensionWord and $80);
      Address := Add32(Address, DisplacementRegisterValue);
      Address := Add32(Address, DisplacementLiteralValue);
      IncrementProgramCounter(State, 2);

      if IsLongword then
        Inc(Stuff.CyclesLeftInInstruction, 14)
      else
        Inc(Stuff.CyclesLeftInInstruction, 10);
    end;
  end;

  DecodedMemoryAddressMode.Address := Address;
end;

procedure DecodeAddressMode(var Stuff: TInstructionContext; var DecodedAddressMode: TDecodedAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);
begin
  case AddressMode of
    ADDRESS_MODE_DATA_REGISTER, ADDRESS_MODE_ADDRESS_REGISTER:
      begin
        DecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_REGISTER;
        if AddressMode = ADDRESS_MODE_ADDRESS_REGISTER then
          DecodedAddressMode.Data.Reg.IsAddressRegister := True
        else
          DecodedAddressMode.Data.Reg.IsAddressRegister := False;
        DecodedAddressMode.Data.Reg.RegisterIndex := AddressModeRegister;
        DecodedAddressMode.Data.Reg.OperationSizeBitmask := $FFFFFFFF shr (Sub32(32, Mul32(OperationSizeInBytes, 8)));
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX, ADDRESS_MODE_SPECIAL:
      begin
        DecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_MEMORY;
        DecodeMemoryAddressMode(Stuff, DecodedAddressMode.Data.Memory, OperationSizeInBytes, AddressMode, AddressModeRegister);
      end;
  end;
end;

function ReadDecodedRegister(const State: TM68kState; const Reg: TRegisterAddressMode): Cardinal;
begin
  if Reg.IsAddressRegister then
    Result := State.AddressRegisters[Reg.RegisterIndex]
  else
    Result := State.DataRegisters[Reg.RegisterIndex];
end;

procedure WriteDecodedRegister(var State: TM68kState; const Reg: TRegisterAddressMode; Value: Cardinal);
begin
  if Reg.IsAddressRegister then
    State.AddressRegisters[Reg.RegisterIndex] := Value
  else
    State.DataRegisters[Reg.RegisterIndex] := Value;
end;

function ReadDecodedMemory(var Stuff: TInstructionContext; const Memory: TDecodedMemoryAddressMode): Cardinal;
begin
  case Memory.AccessKind of
    MEMORY_ADDRESS:
      Result := Memory.Address;
    MEMORY_BYTE:
      Result := ReadByte(Stuff, Memory.Address);
    MEMORY_WORD:
      Result := ReadWord(Stuff, Memory.Address);
    MEMORY_LONGWORD:
      Result := ReadLongWord(Stuff, Memory.Address);
    MEMORY_LONGWORD_BACKWARDS:
      Result := ReadLongWordBackwards(Stuff, Memory.Address);
  else
    Result := 0;
  end;
end;

procedure WriteDecodedMemory(var Stuff: TInstructionContext; const Memory: TDecodedMemoryAddressMode; Value: Cardinal);
begin
  case Memory.AccessKind of
    MEMORY_BYTE:
      WriteByte(Stuff, Memory.Address, Value);
    MEMORY_WORD:
      WriteWord(Stuff, Memory.Address, Value);
    MEMORY_LONGWORD:
      WriteLongWord(Stuff, Memory.Address, Value);
    MEMORY_LONGWORD_BACKWARDS:
      WriteLongWordBackwards(Stuff, Memory.Address, Value);
  end;
end;

function GetValueUsingDecodedAddressMode(var Stuff: TInstructionContext; var DecodedAddressMode: TDecodedAddressMode): Cardinal;
begin
  var Value: Cardinal := 0;
  var State := Stuff.State;
  case DecodedAddressMode.ModeType of
    DECODED_ADDRESS_MODE_TYPE_REGISTER:
      Value := ReadDecodedRegister(State^, DecodedAddressMode.Data.Reg) and DecodedAddressMode.Data.Reg.OperationSizeBitmask;
    DECODED_ADDRESS_MODE_TYPE_MEMORY:
      Value := ReadDecodedMemory(Stuff, DecodedAddressMode.Data.Memory);
    DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER:
      Value := Cardinal(State^.StatusRegister);
    DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER:
      Value := Cardinal(State^.StatusRegister and $FF);
  end;
  Exit(Value);
end;

procedure SetValueUsingDecodedAddressMode(var Stuff: TInstructionContext; var DecodedAddressMode: TDecodedAddressMode; Value: Cardinal);
begin
  var DestinationValue: Cardinal;
  var OperationSizeBitmask: Cardinal;
  var State: PM68kState := Stuff.State;
  case DecodedAddressMode.ModeType of
    DECODED_ADDRESS_MODE_TYPE_REGISTER:
      begin
        DestinationValue := ReadDecodedRegister(State^, DecodedAddressMode.Data.Reg);
        OperationSizeBitmask := DecodedAddressMode.Data.Reg.OperationSizeBitmask;
        WriteDecodedRegister(State^, DecodedAddressMode.Data.Reg, (Value and OperationSizeBitmask) or (DestinationValue and not OperationSizeBitmask));
      end;
    DECODED_ADDRESS_MODE_TYPE_MEMORY:
      begin
        WriteDecodedMemory(Stuff, DecodedAddressMode.Data.Memory, Value);
      end;
    DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER:
      begin
        SetSupervisorMode(State, Ord((Value and Cardinal(STATUS_SUPERVISOR)) <> 0));
        State^.StatusRegister := Word(Value and Cardinal(STATUS_REGISTER_MASK));
      end;
    DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER:
      begin
        State^.StatusRegister := Word(Cardinal(State^.StatusRegister and (not CONDITION_CODE_REGISTER_MASK)) or (Value and Cardinal(CONDITION_CODE_REGISTER_MASK)));
      end;
  end;
end;

function IsOpcodeConditionTrue(State: PM68kState; OpCode: Cardinal): Byte;
begin
  var Carry: Byte := Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0);
  var Overflow: Byte := Ord(Integer(State^.StatusRegister and CONDITION_CODE_OVERFLOW) <> 0);
  var Zero: Byte := Ord(Integer(State^.StatusRegister and CONDITION_CODE_ZERO) <> 0);
  var Negative: Byte := Ord(Integer(State^.StatusRegister and CONDITION_CODE_NEGATIVE) <> 0);
  case ((OpCode shr 8) and $F) of
    $0:
      begin
        Exit(1);
      end;
    $1:
      begin
        Exit(0);
      end;
    $2:
      begin
        var Value := Ord((Carry = 0));
        if Value <> 0 then
          Value := Ord((Zero = 0));
        Exit(Byte(Value));
      end;
    $3:
      begin
        var Value := Ord(Carry <> 0);
        if Value = 0 then
          Value := Ord(Zero <> 0);
        Exit(Byte(Value));
      end;
    $4:
      begin
        Exit(Ord((Carry = 0)));
      end;
    $5:
      begin
        Exit(Carry);
      end;
    $6:
      begin
        Exit(Ord((Zero = 0)));
      end;
    $7:
      begin
        Exit(Zero);
      end;
    $8:
      begin
        Exit(Ord((Overflow = 0)));
      end;
    $9:
      begin
        Exit(Overflow);
      end;
    $A:
      begin
        Exit(Ord((Negative = 0)));
      end;
    $B:
      begin
        Exit(Negative);
      end;
    $C:
      begin
        Exit(Ord(Negative = Overflow));
      end;
    $D:
      begin
        Exit(Ord(Negative <> Overflow));
      end;
    $E:
      begin
        var Value := Ord((Zero = 0));
        if Value <> 0 then
          Value := Ord(Negative = Overflow);
        Exit(Byte(Value));
      end;
    $F:
      begin
        var Value := Ord(Zero <> 0);
        if Value = 0 then
          Value := Ord(Negative <> Overflow);
        Exit(Byte(Value));
      end;
  end;
  Assert(0 <> 0);
  Exit(0);
end;

procedure SingleOperandInstructionExecutionTimeWordOnly(var Stuff: TInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal);
begin
  var Value: Cardinal;
  if Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_REGISTER then
    Value := RegisterWord
  else
    Value := MemoryWord;
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + Value);
end;

procedure SingleOperandInstructionExecutionTimeLongwordOnly(var Stuff: TInstructionContext; RegisterLongword: Cardinal; MemoryLongword: Cardinal);
begin
  var Value: Cardinal;
  if Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_REGISTER then
    Value := RegisterLongword
  else
    Value := MemoryLongword;
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + Value);
end;

procedure SingleOperandInstructionExecutionTime(var Stuff: TInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal; RegisterLongword: Cardinal; MemoryLongword: Cardinal);
begin
  if Stuff.OperationSize = 4 then
    SingleOperandInstructionExecutionTimeLongwordOnly(Stuff, RegisterLongword, MemoryLongword)
  else
    SingleOperandInstructionExecutionTimeWordOnly(Stuff, RegisterWord, MemoryWord);
end;

procedure SingleOperandInstructionExecutionTimeCommon(var Stuff: TInstructionContext);
begin
  SingleOperandInstructionExecutionTime(Stuff, 0, 4, 2, 8);
end;

procedure ShiftRotateInstructionExecutionTimeRegister(var Stuff: TInstructionContext; Count: Cardinal);
begin
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + Add32(2, Mul32(2, Count)));
  if Stuff.OperationSize = 4 then
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
end;

procedure ShiftRotateInstructionExecutionTimeMemory(var Stuff: TInstructionContext);
begin
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
end;

procedure ADDXSUBXExecutionTime(var Stuff: TInstructionContext);
begin
  SingleOperandInstructionExecutionTime(Stuff, 0, 2, 4, 6);
end;

procedure StandardInstructionExecutionTime(var Stuff: TInstructionContext);
begin
  SingleOperandInstructionExecutionTimeCommon(Stuff);

  case Stuff.DestinationDecodedAddressMode.ModeType of
    DECODED_ADDRESS_MODE_TYPE_REGISTER:
      if (Stuff.OperationSize = 4) and (
        (Stuff.SourceDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_REGISTER) or
        ((Stuff.SourceDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_MEMORY) and
        (Stuff.SourceDecodedAddressMode.Data.Memory.Address = Sub32(Stuff.State^.ProgramCounter, 4)))
        ) then
        Inc(Stuff.CyclesLeftInInstruction, 2);
    DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER, DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER:
      Inc(Stuff.CyclesLeftInInstruction, 8);
  end;
end;

procedure StandardInstructionExecutionTimeQuick(var Stuff: TInstructionContext);
begin
  if (Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER) or
    ((Stuff.OperationSize = 4) and
    (Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_REGISTER))
    then
    Inc(Stuff.CyclesLeftInInstruction, 2);
end;

procedure LEAPEAInstructionExecutionTime(var Stuff: TInstructionContext);
begin
  case Stuff.OpCode.PrimaryAddressMode of
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT:
      begin
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX:
      begin
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
      end;
    ADDRESS_MODE_SPECIAL:
      begin
        case Stuff.OpCode.PrimaryRegister of
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT, ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG, ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
            end;
        end;
      end;
  end;
end;

procedure ABCDSBCDExecutionTime(var Stuff: TInstructionContext);
begin
  if (Stuff.OpCode.Raw and $0008) <> 0 then
    Stuff.CyclesLeftInInstruction := Cardinal(18)
  else
    Stuff.CyclesLeftInInstruction := Cardinal(6);
end;

procedure SupervisorCheck(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  if Integer(State^.StatusRegister and STATUS_SUPERVISOR) = 0 then
    Group1Or2Exception(Stuff, 8);
end;

procedure SetSizeByte(var Stuff: TInstructionContext);
begin
  Stuff.OperationSize := 1;
end;

procedure SetSizeWord(var Stuff: TInstructionContext);
begin
  Stuff.OperationSize := 2;
end;

procedure SetSizeLongword(var Stuff: TInstructionContext);
begin
  Stuff.OperationSize := 4;
end;

procedure SetSizeLongwordRegisterByteMemory(var Stuff: TInstructionContext);
begin
  if Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_DATA_REGISTER then
    Stuff.OperationSize := Cardinal(4)
  else
    Stuff.OperationSize := Cardinal(1);
end;

procedure SetSizeMove(var Stuff: TInstructionContext);
begin
  case Stuff.OpCode.Raw and $3000 of
    $0000, $1000:
      Stuff.OperationSize := 1;
    $2000:
      Stuff.OperationSize := 4;
    $3000:
      Stuff.OperationSize := 2;
  end;
end;

procedure SetSizeExt(var Stuff: TInstructionContext);
begin
  if (Stuff.OpCode.Raw and $0040) <> 0 then
    Stuff.OperationSize := Cardinal(4)
  else
    Stuff.OperationSize := Cardinal(2);
end;

procedure SetSizeStandard(var Stuff: TInstructionContext);
const
  SIZES: array[0..3] of Byte = (1, 2, 4, 4);
begin
  Stuff.OperationSize := Cardinal(SIZES[Stuff.OpCode.Bits6and7]);
end;

procedure SetMSBBitIndex(var Stuff: TInstructionContext);
begin
  Stuff.MSBBitIndex := Sub32(Mul32(Stuff.OperationSize, 8), 1);
end;

procedure DecodeSourceImmediateData(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_SPECIAL, ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE);
end;

procedure DecodeSourceDataRegisterSecondary(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_DATA_REGISTER, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeSourceImmediateDataByte(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, 1, ADDRESS_MODE_SPECIAL, ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE);
end;

procedure DecodeSourceMemoryAddressPrimary(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, 0, Stuff.OpCode.PrimaryAddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeSourceStatusRegister(var Stuff: TInstructionContext);
begin
  Stuff.SourceDecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER;
end;

procedure DecodeSourceImmediateDataWord(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, 2, ADDRESS_MODE_SPECIAL, ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE);
end;

procedure DecodeSourceBCDX(var Stuff: TInstructionContext);
begin
  var AddressMode: Integer;
  if (Stuff.OpCode.Raw and $0008) <> 0 then
    AddressMode := ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT
  else
    AddressMode := ADDRESS_MODE_DATA_REGISTER;
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, Stuff.OperationSize, AddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(var Stuff: TInstructionContext);
begin
  var AddressMode: Integer;
  var AddressModeReg: Cardinal;
  if Stuff.OpCode.Bit8 <> 0 then
    AddressMode := ADDRESS_MODE_DATA_REGISTER
  else
    AddressMode := Stuff.OpCode.PrimaryAddressMode;
  if Stuff.OpCode.Bit8 <> 0 then
    AddressModeReg := Stuff.OpCode.SecondaryRegister
  else
    AddressModeReg := Stuff.OpCode.PrimaryRegister;
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, Stuff.OperationSize, AddressMode, AddressModeReg);
end;

procedure DecodeSourcePrimaryAddressModeSized(var Stuff: TInstructionContext);
begin
  var OperationSizeInBytes: Integer;
  if Stuff.OpCode.Bit8 <> 0 then
    OperationSizeInBytes := 4
  else
    OperationSizeInBytes := 2;
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, OperationSizeInBytes, Stuff.OpCode.PrimaryAddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeSourceAddressRegisterPrimaryPostIncrement(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeSourcePrimaryAddressMode(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, Stuff.OperationSize, Stuff.OpCode.PrimaryAddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeSourcePrimaryAddressModeWord(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.SourceDecodedAddressMode, 2, Stuff.OpCode.PrimaryAddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationDataRegisterPrimary(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_DATA_REGISTER, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationDataRegisterSecondary(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_DATA_REGISTER, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationAddressRegisterSecondary(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_ADDRESS_REGISTER, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationSecondaryAddressMode(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, Stuff.OpCode.SecondaryAddressMode, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationBCDX(var Stuff: TInstructionContext);
begin
  var AddressMode: Integer;
  if (Stuff.OpCode.Raw and $0008) <> 0 then
    AddressMode := ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT
  else
    AddressMode := ADDRESS_MODE_DATA_REGISTER;
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, AddressMode, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(var Stuff: TInstructionContext);
begin
  var AddressMode: Integer;
  var AddressModeReg: Cardinal;
  if Stuff.OpCode.Bit8 <> 0 then
    AddressMode := Stuff.OpCode.PrimaryAddressMode
  else
    AddressMode := ADDRESS_MODE_DATA_REGISTER;
  if Stuff.OpCode.Bit8 <> 0 then
    AddressModeReg := Stuff.OpCode.PrimaryRegister
  else
    AddressModeReg := Stuff.OpCode.SecondaryRegister;
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, AddressMode, AddressModeReg);
end;

procedure DecodeDestinationAddressRegisterSecondaryFull(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, 4, ADDRESS_MODE_ADDRESS_REGISTER, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationAddressRegisterSecondaryPostIncrement(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT, Stuff.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationPrimaryAddressMode(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.OperationSize, Stuff.OpCode.PrimaryAddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationConditionCodeRegister(var Stuff: TInstructionContext);
begin
  Stuff.DestinationDecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER;
end;

procedure DecodeDestinationStatusRegister(var Stuff: TInstructionContext);
begin
  Stuff.DestinationDecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER;
end;

procedure DecodeDestinationMOVEM(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, 0, Stuff.OpCode.PrimaryAddressMode, Stuff.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationMOVEP(var Stuff: TInstructionContext);
begin
  DecodeAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, 0, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT, Stuff.OpCode.PrimaryRegister);
end;

procedure ReadSource(var Stuff: TInstructionContext);
begin
  Stuff.SourceValue := GetValueUsingDecodedAddressMode(Stuff, Stuff.SourceDecodedAddressMode);
end;

procedure ReadDestination(var Stuff: TInstructionContext);
begin
  Stuff.DestinationValue := GetValueUsingDecodedAddressMode(Stuff, Stuff.DestinationDecodedAddressMode);
end;

procedure WriteDestination(var Stuff: TInstructionContext);
begin
  SetValueUsingDecodedAddressMode(Stuff, Stuff.DestinationDecodedAddressMode, Stuff.ResultValue);
end;

procedure CarryStandardCarry(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  State^.StatusRegister := Word(State^.StatusRegister or ((((Stuff.SourceValue and Stuff.DestinationValue) or ((Stuff.SourceValue or Stuff.DestinationValue) and not Stuff.ResultValue)) shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_CARRY_BIT))) and Cardinal(CONDITION_CODE_CARRY)));
end;

procedure CarryStandardBorrow(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  State^.StatusRegister := Word(State^.StatusRegister or ((((Stuff.SourceValue and not Stuff.DestinationValue) or ((Stuff.SourceValue or not Stuff.DestinationValue) and Stuff.ResultValue)) shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_CARRY_BIT))) and Cardinal(CONDITION_CODE_CARRY)));
end;

procedure CarryNEG(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  State^.StatusRegister := Word(State^.StatusRegister or (((Stuff.DestinationValue or Stuff.ResultValue) shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_CARRY_BIT))) and Cardinal(CONDITION_CODE_CARRY)));
end;

procedure CarryClear(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
end;

procedure OverflowADD(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
  State^.StatusRegister := Word(State^.StatusRegister or (((((Stuff.SourceValue and Stuff.DestinationValue) and not Stuff.ResultValue) or ((not Stuff.SourceValue and not Stuff.DestinationValue) and Stuff.ResultValue)) shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_OVERFLOW_BIT))) and Cardinal(CONDITION_CODE_OVERFLOW)));
end;

procedure OverflowSUB(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
  State^.StatusRegister := Word(State^.StatusRegister or (((((not Stuff.SourceValue and Stuff.DestinationValue) and not Stuff.ResultValue) or ((Stuff.SourceValue and not Stuff.DestinationValue) and Stuff.ResultValue)) shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_OVERFLOW_BIT))) and Cardinal(CONDITION_CODE_OVERFLOW)));
end;

procedure OverflowNEG(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
  State^.StatusRegister := Word(State^.StatusRegister or (((Stuff.DestinationValue and Stuff.ResultValue) shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_OVERFLOW_BIT))) and Cardinal(CONDITION_CODE_OVERFLOW)));
end;

procedure OverflowClear(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
end;

procedure ZeroClearIfNonZeroUnaffectedOtherwise(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and ((not CONDITION_CODE_ZERO) or (0 - Ord((Stuff.ResultValue and ($FFFFFFFF shr (Sub32(Sub32(32, Stuff.MSBBitIndex), 1)))) = 0))));
end;

procedure ZeroSetIfZeroClearOtherwise(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_ZERO));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord((Stuff.ResultValue and ($FFFFFFFF shr (Sub32(Sub32(32, Stuff.MSBBitIndex), 1)))) = 0))));
end;

procedure NegativeSetIfNegativeClearOtherwise(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_NEGATIVE));
  State^.StatusRegister := Word(State^.StatusRegister or ((Cardinal(CONDITION_CODE_NEGATIVE) and (Stuff.ResultValue shr (Sub32(Stuff.MSBBitIndex, CONDITION_CODE_NEGATIVE_BIT)))) and Cardinal(CONDITION_CODE_NEGATIVE)));
end;

procedure ExtendSetToCarry(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
end;

procedure ActionOR(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Stuff.DestinationValue or Stuff.SourceValue;
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionAND(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Stuff.DestinationValue and Stuff.SourceValue;
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionSUBCommon(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Sub32(Stuff.DestinationValue, Stuff.SourceValue);
end;

procedure ActionCMP(var Stuff: TInstructionContext);
begin
  var Cycles: Integer;
  ActionSUBCommon(Stuff);
  if Stuff.OperationSize = 4 then
    Cycles := 2
  else
    Cycles := 0;
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + Cardinal(Cycles));
end;

procedure ActionCMPI(var Stuff: TInstructionContext);
begin
  ActionSUBCommon(Stuff);
  if (Stuff.OperationSize = 4) and (Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_REGISTER) then
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
end;

procedure ActionCMPM(var Stuff: TInstructionContext);
begin
  ActionSUBCommon(Stuff);
end;

procedure ActionSUB(var Stuff: TInstructionContext);
begin
  ActionSUBCommon(Stuff);
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionADDASUBACommon(var Stuff: TInstructionContext);
begin
  if Stuff.OpCode.Bit8 = 0 then
  begin
    Stuff.SourceValue := Sub32(Stuff.SourceValue and Sub32(Cardinal(1) shl 15, 1), Stuff.SourceValue and (Cardinal(1) shl 15));
    if Stuff.SourceDecodedAddressMode.ModeType <> DECODED_ADDRESS_MODE_TYPE_REGISTER then
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
  end;
end;

procedure ActionCMPA(var Stuff: TInstructionContext);
begin
  if Stuff.OpCode.Bit8 = 0 then
    Stuff.SourceValue := Sub32(Stuff.SourceValue and Sub32(Cardinal(1) shl 15, 1), Stuff.SourceValue and (Cardinal(1) shl 15));
  ActionCMP(Stuff);
end;

procedure ActionSUBA(var Stuff: TInstructionContext);
begin
  ActionADDASUBACommon(Stuff);
  ActionSUB(Stuff);
end;

procedure ActionSUBQ(var Stuff: TInstructionContext);
begin
  Stuff.SourceValue := Add32(Sub32(Stuff.OpCode.SecondaryRegister, 1) and 7, 1);
  ActionSUB(Stuff);
  StandardInstructionExecutionTimeQuick(Stuff);
end;

procedure ActionADD(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Add32(Stuff.DestinationValue, Stuff.SourceValue);
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionADDA(var Stuff: TInstructionContext);
begin
  ActionADDASUBACommon(Stuff);
  ActionADD(Stuff);
end;

procedure ActionADDQ(var Stuff: TInstructionContext);
begin
  Stuff.SourceValue := Add32(Sub32(Stuff.OpCode.SecondaryRegister, 1) and 7, 1);
  ActionADD(Stuff);
  StandardInstructionExecutionTimeQuick(Stuff);
end;

procedure ActionEOR(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Stuff.DestinationValue xor Stuff.SourceValue;
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionBxxx(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  Stuff.SourceValue := Stuff.SourceValue and Stuff.MSBBitIndex;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_ZERO));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord((Stuff.DestinationValue and Cardinal(1 shl Stuff.SourceValue)) = 0))));
end;

procedure ActionBTST(var Stuff: TInstructionContext);
begin
  ActionBxxx(Stuff);

  if (Stuff.OperationSize = 4) or
    ((Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_SPECIAL) and
    (Stuff.OpCode.PrimaryRegister = ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE)) then
    Inc(Stuff.CyclesLeftInInstruction, 2);
end;

procedure ActionBCHG(var Stuff: TInstructionContext);
begin
  ActionBxxx(Stuff);
  Stuff.ResultValue := Stuff.DestinationValue xor Cardinal(1 shl Stuff.SourceValue);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
  if (Stuff.OperationSize = 4) and (Stuff.SourceValue < 16) then
    Stuff.CyclesLeftInInstruction := Sub32(Stuff.CyclesLeftInInstruction, 2);
end;

procedure ActionBCLR(var Stuff: TInstructionContext);
begin
  ActionBxxx(Stuff);
  Stuff.ResultValue := Stuff.DestinationValue and Cardinal(not (1 shl Stuff.SourceValue));
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
  if (Stuff.OperationSize = 4) and (Stuff.SourceValue >= 16) then
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
end;

procedure ActionBSET(var Stuff: TInstructionContext);
begin
  ActionBxxx(Stuff);
  Stuff.ResultValue := Stuff.DestinationValue or Cardinal(1 shl Stuff.SourceValue);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
  if (Stuff.OperationSize = 4) and (Stuff.SourceValue < 16) then
    Stuff.CyclesLeftInInstruction := Sub32(Stuff.CyclesLeftInInstruction, 2);
end;

procedure ActionMOVEP(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  case Stuff.OpCode.Bits6and7 of
    0:
      begin
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] and Cardinal(not $FFFF);
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] or (ReadByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 0))) shl (8 * 1));
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] or (ReadByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 1))) shl (8 * 0));
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
      end;
    1:
      begin
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := 0;
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] or (ReadByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 0))) shl (8 * 3));
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] or (ReadByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 1))) shl (8 * 2));
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] or (ReadByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 2))) shl (8 * 1));
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] or (ReadByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 3))) shl (8 * 0));
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 12);
      end;
    2:
      begin
        WriteByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 0)), ((State^.DataRegisters[Stuff.OpCode.SecondaryRegister] shr (8 * 1)) and $FF));
        WriteByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 1)), ((State^.DataRegisters[Stuff.OpCode.SecondaryRegister] shr (8 * 0)) and $FF));
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
      end;
    3:
      begin
        WriteByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 0)), ((State^.DataRegisters[Stuff.OpCode.SecondaryRegister] shr (8 * 3)) and $FF));
        WriteByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 1)), ((State^.DataRegisters[Stuff.OpCode.SecondaryRegister] shr (8 * 2)) and $FF));
        WriteByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 2)), ((State^.DataRegisters[Stuff.OpCode.SecondaryRegister] shr (8 * 1)) and $FF));
        WriteByte(Stuff, (Add32(Stuff.DestinationValue, 2 * 3)), ((State^.DataRegisters[Stuff.OpCode.SecondaryRegister] shr (8 * 0)) and $FF));
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 12);
      end;
  end;
end;

procedure ActionMOVEA(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Sub32(Stuff.SourceValue and Sub32(Cardinal(1) shl Stuff.MSBBitIndex, 1), Stuff.SourceValue and (Cardinal(1) shl Stuff.MSBBitIndex));
end;

procedure ActionMOVECommon(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Stuff.SourceValue;
end;

procedure ActionMOVE(var Stuff: TInstructionContext);
begin
  ActionMOVECommon(Stuff);
  if Stuff.SourceDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER then
  begin
    if Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_REGISTER then
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2)
    else
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
  end
  else
  begin
    if (Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER) or (Stuff.DestinationDecodedAddressMode.ModeType = DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER) then
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8)
    else
    begin
      if Stuff.OpCode.SecondaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT then
        Stuff.CyclesLeftInInstruction := Sub32(Stuff.CyclesLeftInInstruction, 2);
    end;
  end;
end;

procedure ActionLINK(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var AddressRegisterContents: Cardinal := State^.AddressRegisters[Stuff.OpCode.PrimaryRegister];
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], AddressRegisterContents);
  State^.AddressRegisters[Stuff.OpCode.PrimaryRegister] := State^.AddressRegisters[7];
  IncrementAddressRegister(State, 7, (Sub32(Stuff.SourceValue and Sub32(Cardinal(1) shl 15, 1), Stuff.SourceValue and (Cardinal(1) shl 15))));
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
end;

procedure ActionUNLK(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var AddressRegisterContents: Cardinal := State^.AddressRegisters[Stuff.OpCode.PrimaryRegister];
  var Value: Cardinal := ReadLongWord(Stuff, AddressRegisterContents);
  State^.AddressRegisters[7] := AddressRegisterContents;
  IncrementAddressRegister(State, 7, 4);
  State^.AddressRegisters[Stuff.OpCode.PrimaryRegister] := Value;
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
end;

procedure ActionNEGX(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  Stuff.ResultValue := Sub32(Sub32(0, Stuff.DestinationValue), Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0));
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionCLR(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := 0;
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionNEG(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Sub32(0, Stuff.DestinationValue);
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionNOT(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := not Stuff.DestinationValue;
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionEXT(var Stuff: TInstructionContext);
begin
  var SignBit: Integer;

  if (Stuff.OpCode.Raw and $0040) <> 0 then
    SignBit := 15
  else
    SignBit := 7;

  Stuff.ResultValue := Sub32(
    Stuff.DestinationValue and ((Cardinal(1) shl SignBit) - 1),
    Stuff.DestinationValue and (Cardinal(1) shl SignBit));
end;

procedure ActionSWAP(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := ((Stuff.DestinationValue and $0000FFFF) shl 16) or ((Stuff.DestinationValue and $FFFF0000) shr 16);
end;

procedure ActionPEA(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], Stuff.SourceValue);
  Stuff.CyclesLeftInInstruction := 12;
  LEAPEAInstructionExecutionTime(Stuff);
end;

procedure ActionILLEGAL(var Stuff: TInstructionContext);
begin
  Group1Or2Exception(Stuff, 4);
end;

procedure ActionTAS(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_NEGATIVE or CONDITION_CODE_ZERO)));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_NEGATIVE and (0 - Ord((Stuff.DestinationValue and $80) <> 0))));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord(Stuff.DestinationValue = 0))));
  Stuff.ResultValue := Stuff.DestinationValue or $80;
  SingleOperandInstructionExecutionTimeWordOnly(Stuff, 0, 6);
end;

procedure ActionTRAP(var Stuff: TInstructionContext);
begin
  Stuff.SourceValue := Stuff.OpCode.Raw and $F;
  DoInterrupt(Stuff, (Add32(32, Stuff.SourceValue)));
end;

procedure ActionMOVEUSP(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  if (Stuff.OpCode.Raw and 8) <> 0 then
    State^.AddressRegisters[Stuff.OpCode.PrimaryRegister] := State^.UserStackPointer
  else
    State^.UserStackPointer := State^.AddressRegisters[Stuff.OpCode.PrimaryRegister];
end;

procedure ProgramCounterChanged(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var ProgramCounter: Cardinal := State^.ProgramCounter;
  if (ProgramCounter and 1) <> 0 then
    Group0Exception(Stuff, 3, ProgramCounter, 1);
end;

procedure SetStatusRegister(var Stuff: TInstructionContext; Value: Cardinal);
begin
  var State: PM68kState := Stuff.State;
  SetSupervisorMode(State, Ord((Value and Cardinal(STATUS_SUPERVISOR)) <> 0));
  State^.StatusRegister := Word(Value and Cardinal(STATUS_REGISTER_MASK));
end;

procedure ActionRESET(var Stuff: TInstructionContext);
begin
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 128);
end;

procedure ActionSTOP(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  SetStatusRegister(Stuff, Stuff.SourceValue);
  State^.Stopped := 1;
  Stuff.CyclesLeftInInstruction := Sub32(Stuff.CyclesLeftInInstruction, 4);
end;

procedure ActionRTE(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var NewStatus: Cardinal := ReadWord(Stuff, State^.AddressRegisters[7]) and Cardinal(STATUS_REGISTER_MASK);
  IncrementAddressRegister(State, 7, 2);
  State^.ProgramCounter := ReadLongWord(Stuff, State^.AddressRegisters[7]);
  IncrementAddressRegister(State, 7, 4);
  SetStatusRegister(Stuff, NewStatus);
  ProgramCounterChanged(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 16);
end;

procedure ActionRTS(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.ProgramCounter := ReadLongWord(Stuff, State^.AddressRegisters[7]);
  IncrementAddressRegister(State, 7, 4);
  ProgramCounterChanged(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 12);
end;

procedure ActionTRAPV(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  if Integer(State^.StatusRegister and CONDITION_CODE_OVERFLOW) <> 0 then
    DoInterrupt(Stuff, 7);
end;

procedure ActionRTR(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_REGISTER_MASK));
  State^.StatusRegister := Word(State^.StatusRegister or (ReadByte(Stuff, (Add32(State^.AddressRegisters[7], 1))) and Cardinal(CONDITION_CODE_REGISTER_MASK)));
  IncrementAddressRegister(State, 7, 2);
  State^.ProgramCounter := ReadLongWord(Stuff, State^.AddressRegisters[7]);
  IncrementAddressRegister(State, 7, 4);
  ProgramCounterChanged(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 16);
end;

procedure ActionJMP(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  State^.ProgramCounter := Stuff.SourceValue;
  ProgramCounterChanged(Stuff);
  Stuff.CyclesLeftInInstruction := 8;
  case Stuff.OpCode.PrimaryAddressMode of
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT:
      begin
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX:
      begin
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
      end;
    ADDRESS_MODE_SPECIAL:
      begin
        case Stuff.OpCode.PrimaryRegister of
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT, ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
            end;
        end;
      end;
  end;
end;

procedure ActionJSR(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var ProgramCounter: Cardinal := State^.ProgramCounter;
  ActionJMP(Stuff);
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], ProgramCounter);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
end;

procedure ActionLEA(var Stuff: TInstructionContext);
begin
  ActionMOVECommon(Stuff);
  Stuff.CyclesLeftInInstruction := 4;
  LEAPEAInstructionExecutionTime(Stuff);
end;

procedure ActionTST(var Stuff: TInstructionContext);
begin
  ActionMOVECommon(Stuff);
end;

procedure WriteMemoryByKind(var Stuff: TInstructionContext; AccessKind: TMemoryAccessKind; Address, Value: Cardinal);
begin
  var Memory: TDecodedMemoryAddressMode;
  Memory.Address := Address;
  Memory.AccessKind := AccessKind;
  WriteDecodedMemory(Stuff, Memory, Value);
end;

procedure ActionMOVEM(var Stuff: TInstructionContext);
begin
  var AddressDelta: Integer;
  var WriteKind: TMemoryAccessKind;
  var State: PM68kState := Stuff.State;
  var MemoryAddress: Cardinal := Stuff.DestinationValue;
  var MemoryToRegister: Byte := Ord((Stuff.OpCode.Raw and $0400) <> 0);
  var IsLongword: Byte := Ord((Stuff.OpCode.Raw and $0040) <> 0);
  var CycleDelta: Cardinal;
  if IsLongword <> 0 then
    CycleDelta := 8
  else
    CycleDelta := 4;
  Stuff.CyclesLeftInInstruction := 8;
  if MemoryToRegister <> 0 then
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
  case Stuff.OpCode.PrimaryAddressMode of
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT:
      begin
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX:
      begin
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
      end;
    ADDRESS_MODE_SPECIAL:
      begin
        case Stuff.OpCode.PrimaryRegister of
          ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG:
            begin
              Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
            end;
        end;
      end;
  end;
  if Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT then
  begin
    if IsLongword <> 0 then
    begin
      AddressDelta := -4;
      WriteKind := MEMORY_LONGWORD_BACKWARDS;
    end
    else
    begin
      AddressDelta := -2;
      WriteKind := MEMORY_WORD;
    end;
  end
  else
  begin
    if IsLongword <> 0 then
    begin
      AddressDelta := 4;
      WriteKind := MEMORY_LONGWORD;
    end
    else
    begin
      AddressDelta := 2;
      WriteKind := MEMORY_WORD;
    end;
  end;
  var Bitfield: Cardinal := Stuff.SourceValue;
  for var ItemIndex := 0 to 8 - 1 do
  begin
    if (Bitfield and 1) <> 0 then
    begin
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + CycleDelta);
      if MemoryToRegister <> 0 then
      begin
        if IsLongword <> 0 then
          State^.DataRegisters[ItemIndex] := ReadLongWord(Stuff, MemoryAddress)
        else
          State^.DataRegisters[ItemIndex] := Sub32(ReadWord(Stuff, MemoryAddress) and Sub32(Cardinal(1) shl 15, 1), ReadWord(Stuff, MemoryAddress) and (Cardinal(1) shl 15));
      end
      else
      begin
        if Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT then
          WriteMemoryByKind(Stuff, WriteKind, (Add32(MemoryAddress, Cardinal(AddressDelta))), State^.AddressRegisters[(Sub32(7, ItemIndex))])
        else
          WriteMemoryByKind(Stuff, WriteKind, MemoryAddress, State^.DataRegisters[ItemIndex]);
      end;
      MemoryAddress := Add32(MemoryAddress, Cardinal(AddressDelta));
      MemoryAddress := MemoryAddress and $FFFFFFFF;
    end;
    Bitfield := Bitfield shr 1;
  end;
  for var ItemIndex := 0 to 8 - 1 do
  begin
    if (Bitfield and 1) <> 0 then
    begin
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + CycleDelta);
      if MemoryToRegister <> 0 then
      begin
        if IsLongword <> 0 then
          State^.AddressRegisters[ItemIndex] := ReadLongWord(Stuff, MemoryAddress)
        else
          State^.AddressRegisters[ItemIndex] := Sub32(ReadWord(Stuff, MemoryAddress) and Sub32(Cardinal(1) shl 15, 1), ReadWord(Stuff, MemoryAddress) and (Cardinal(1) shl 15)) and $FFFFFFFF;
      end
      else
      begin
        if Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT then
          WriteMemoryByKind(Stuff, WriteKind, (Add32(MemoryAddress, Cardinal(AddressDelta))), State^.DataRegisters[(Sub32(7, ItemIndex))])
        else
          WriteMemoryByKind(Stuff, WriteKind, MemoryAddress, State^.AddressRegisters[ItemIndex]);
      end;
      MemoryAddress := Add32(MemoryAddress, Cardinal(AddressDelta));
      MemoryAddress := MemoryAddress and $FFFFFFFF;
    end;
    Bitfield := Bitfield shr 1;
  end;
  if (Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT) or (Stuff.OpCode.PrimaryAddressMode = ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT) then
    State^.AddressRegisters[Stuff.OpCode.PrimaryRegister] := MemoryAddress;
end;

procedure ActionCHK(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var Value: Cardinal := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] and $FFFF;
  State^.StatusRegister := Word(State^.StatusRegister and (not (((CONDITION_CODE_NEGATIVE or CONDITION_CODE_CARRY) or CONDITION_CODE_OVERFLOW) or CONDITION_CODE_ZERO)));
  if (Value and $8000) <> 0 then
  begin
    State^.StatusRegister := Word(State^.StatusRegister or CONDITION_CODE_NEGATIVE);
    DoInterrupt(Stuff, 6);
  end
  else
  begin
    if (Value xor $8000) > (Stuff.SourceValue xor $8000) then
      DoInterrupt(Stuff, 6);
  end;
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
end;

procedure ActionSCC(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  if IsOpcodeConditionTrue(State, Stuff.OpCode.Raw) <> 0 then
  begin
    Stuff.ResultValue := $FF;
    SingleOperandInstructionExecutionTimeWordOnly(Stuff, 2, 4);
  end
  else
  begin
    Stuff.ResultValue := 0;
    SingleOperandInstructionExecutionTimeWordOnly(Stuff, 0, 4);
  end;
end;

procedure ActionBRASHORT(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  IncrementProgramCounter(State, (Sub32(Stuff.OpCode.Raw and Sub32(Cardinal(1) shl 7, 1), Stuff.OpCode.Raw and (Cardinal(1) shl 7))));
  ProgramCounterChanged(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
end;

procedure ActionBRAWORD(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  IncrementProgramCounter(State, (Sub32(Sub32(Stuff.SourceValue and Sub32(Cardinal(1) shl 15, 1), Stuff.SourceValue and (Cardinal(1) shl 15)), 2)));
  ProgramCounterChanged(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
end;

procedure ActionBSRSHORT(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], State^.ProgramCounter);
  ActionBRASHORT(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
end;

procedure ActionBSRWORD(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], State^.ProgramCounter);
  ActionBRAWORD(Stuff);
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 8);
end;

procedure ActionBCCSHORT(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  if IsOpcodeConditionTrue(State, Stuff.OpCode.Raw) <> 0 then
    ActionBRASHORT(Stuff)
  else
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
end;

procedure ActionBCCWORD(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  if IsOpcodeConditionTrue(State, Stuff.OpCode.Raw) <> 0 then
    ActionBRAWORD(Stuff)
  else
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
end;

procedure ActionDBCC(var Stuff: TInstructionContext);
begin
  var LoopCounter: Cardinal;
  var SaveLoopCounter: Cardinal;
  var State: PM68kState := Stuff.State;
  if not (IsOpcodeConditionTrue(State, Stuff.OpCode.Raw) <> 0) then
  begin
    LoopCounter := State^.DataRegisters[Stuff.OpCode.PrimaryRegister] and $FFFF;
    SaveLoopCounter := LoopCounter;
    LoopCounter := (LoopCounter + $FFFF) and $FFFF;
    if SaveLoopCounter <> 0 then
      ActionBRAWORD(Stuff)
    else
      Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 6);
    State^.DataRegisters[Stuff.OpCode.PrimaryRegister] := State^.DataRegisters[Stuff.OpCode.PrimaryRegister] and Cardinal(not $FFFF);
    State^.DataRegisters[Stuff.OpCode.PrimaryRegister] := State^.DataRegisters[Stuff.OpCode.PrimaryRegister] or (LoopCounter and $FFFF);
  end
  else
    Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 4);
end;

procedure ActionMOVEQ(var Stuff: TInstructionContext);
begin
  Stuff.ResultValue := Sub32(Stuff.OpCode.Raw and Sub32(Cardinal(1) shl 7, 1), Stuff.OpCode.Raw and (Cardinal(1) shl 7));
end;

function CountBitsSet(Value: Cardinal): Cardinal;
begin
  var TotalBitsSet: Cardinal := 0;
  while Value <> 0 do
  begin
    Value := Value and Sub32(Value, 1);
    Inc(TotalBitsSet);
  end;
  Exit(TotalBitsSet);
end;

procedure ActionDIVCommon(var Stuff: TInstructionContext; IsSigned: Boolean);
begin
  var State := Stuff.State;
  State^.StatusRegister := State^.StatusRegister and not CONDITION_CODE_CARRY;

  if Stuff.SourceValue = 0 then
  begin
    State^.StatusRegister := State^.StatusRegister and not (
      CONDITION_CODE_NEGATIVE or
      CONDITION_CODE_ZERO or
      CONDITION_CODE_OVERFLOW
      );

    Stuff.ResultValue := Stuff.DestinationValue;
    DoInterrupt(Stuff, 5);
    Exit;
  end;

  var SourceIsNegative := IsSigned and ((Stuff.SourceValue and $8000) <> 0);
  var DestinationIsNegative := IsSigned and ((Stuff.DestinationValue and $80000000) <> 0);
  var ResultIsNegative := SourceIsNegative <> DestinationIsNegative;

  var AbsoluteSourceValue: Cardinal;
  if SourceIsNegative then
    AbsoluteSourceValue := Sub32(0, Sub32(Stuff.SourceValue and $7FFF, Stuff.SourceValue and $8000))
  else
    AbsoluteSourceValue := Stuff.SourceValue;

  var AbsoluteDestinationValue: Cardinal;
  if DestinationIsNegative then
    AbsoluteDestinationValue := Sub32(0, Stuff.DestinationValue)
  else
    AbsoluteDestinationValue := Stuff.DestinationValue;

  Inc(Stuff.CyclesLeftInInstruction, 6);

  if IsSigned then
  begin
    if DestinationIsNegative then
      Inc(Stuff.CyclesLeftInInstruction, 8)
    else
      Inc(Stuff.CyclesLeftInInstruction, 6);
  end;

  if AbsoluteSourceValue > (AbsoluteDestinationValue shr 16) then
  begin
    var AbsoluteQuotient := AbsoluteDestinationValue div AbsoluteSourceValue;
    if IsSigned then
    begin
      Inc(Stuff.CyclesLeftInInstruction, 104);

      if SourceIsNegative then
        Inc(Stuff.CyclesLeftInInstruction, 2)
      else if DestinationIsNegative then
        Inc(Stuff.CyclesLeftInInstruction, 4);

      Inc(Stuff.CyclesLeftInInstruction, Mul32(15 - CountBitsSet(AbsoluteQuotient shr 1), 2));
    end
    else
    begin
      var ShiftedDivisor := (AbsoluteSourceValue and $FFFF) shl 16;
      var WorkingDividend := AbsoluteDestinationValue;

      Inc(Stuff.CyclesLeftInInstruction, 66);

      for var i := 0 to 14 do
      begin
        var HighBitSet := (WorkingDividend and $80000000) <> 0;
        WorkingDividend := WorkingDividend shl 1;

        if not HighBitSet then
        begin
          Inc(Stuff.CyclesLeftInInstruction, 2);

          if WorkingDividend < ShiftedDivisor then
          begin
            Inc(Stuff.CyclesLeftInInstruction, 2);
            Continue;
          end;
        end;

        WorkingDividend := Sub32(WorkingDividend, ShiftedDivisor);
      end;
    end;

    var QuotientFits: Boolean;
    if not IsSigned then
      QuotientFits := True
    else if ResultIsNegative then
      QuotientFits := AbsoluteQuotient <= $8000
    else
      QuotientFits := AbsoluteQuotient <= $7FFF;

    if QuotientFits then
    begin
      var AbsoluteRemainder := AbsoluteDestinationValue mod AbsoluteSourceValue;

      var Quotient: Cardinal;
      if ResultIsNegative then
        Quotient := Sub32(0, AbsoluteQuotient)
      else
        Quotient := AbsoluteQuotient;

      var Remainder: Cardinal;
      if DestinationIsNegative then
        Remainder := Sub32(0, AbsoluteRemainder)
      else
        Remainder := AbsoluteRemainder;

      Stuff.ResultValue := (Quotient and $FFFF) or ((Remainder and $FFFF) shl 16);
      State^.StatusRegister := State^.StatusRegister and not (
        CONDITION_CODE_NEGATIVE or
        CONDITION_CODE_ZERO or
        CONDITION_CODE_OVERFLOW);

      if (Quotient and $8000) <> 0 then
        State^.StatusRegister := State^.StatusRegister or CONDITION_CODE_NEGATIVE;

      if Quotient = 0 then
        State^.StatusRegister := State^.StatusRegister or CONDITION_CODE_ZERO;

      Exit;
    end;
  end;

  State^.StatusRegister := State^.StatusRegister or CONDITION_CODE_OVERFLOW or CONDITION_CODE_NEGATIVE;
  State^.StatusRegister := State^.StatusRegister and not CONDITION_CODE_ZERO;
  Stuff.ResultValue := Stuff.DestinationValue;
end;

procedure ActionDIVS(var Stuff: TInstructionContext);
begin
  ActionDIVCommon(Stuff, True);
end;

procedure ActionDIVU(var Stuff: TInstructionContext);
begin
  ActionDIVCommon(Stuff, False);
end;

procedure ActionSUBXCommon(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  Stuff.ResultValue := Sub32(Sub32(Stuff.DestinationValue, Stuff.SourceValue), Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0));
end;

procedure ActionSUBX(var Stuff: TInstructionContext);
begin
  ActionSUBXCommon(Stuff);
  ADDXSUBXExecutionTime(Stuff);
end;

procedure ActionSBCDCommon(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  ActionSUBXCommon(Stuff);
  Stuff.SourceValue := (((Stuff.SourceValue and not Stuff.DestinationValue) or ((Stuff.SourceValue or not Stuff.DestinationValue) and Stuff.ResultValue)) and $88) shl 1;
  Stuff.SourceValue := (Stuff.SourceValue shr 2) or (Stuff.SourceValue shr 3);
  Stuff.DestinationValue := Stuff.ResultValue;
  ActionSUBCommon(Stuff);
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  if ((Stuff.SourceValue and $40) <> 0) or (((not Stuff.DestinationValue and Stuff.ResultValue) and $80) <> 0) then
    State^.StatusRegister := Word(State^.StatusRegister or CONDITION_CODE_CARRY);
end;

procedure ActionSBCD(var Stuff: TInstructionContext);
begin
  ActionSBCDCommon(Stuff);
  ABCDSBCDExecutionTime(Stuff);
end;

procedure ActionNBCD(var Stuff: TInstructionContext);
begin
  Stuff.SourceValue := Stuff.DestinationValue;
  Stuff.DestinationValue := 0;
  ActionSBCDCommon(Stuff);
  SingleOperandInstructionExecutionTimeWordOnly(Stuff, 2, 4);
end;

procedure ActionMULCommon(var Stuff: TInstructionContext; IsSigned: Boolean; TotalOperations: Cardinal);
begin
  var MultiplierIsNegative := IsSigned and ((Stuff.SourceValue and $8000) <> 0);
  var MultiplicandIsNegative := IsSigned and ((Stuff.DestinationValue and $8000) <> 0);
  var ResultIsNegative := MultiplierIsNegative <> MultiplicandIsNegative;

  var Multiplier: Cardinal;
  if MultiplierIsNegative then
    Multiplier := Sub32(0, Sub32(Stuff.SourceValue and $7FFF, Stuff.SourceValue and $8000))
  else
    Multiplier := Stuff.SourceValue and $FFFF;

  var Multiplicand: Cardinal;
  if MultiplicandIsNegative then
    Multiplicand := Sub32(0, Sub32(Stuff.DestinationValue and $7FFF, Stuff.DestinationValue and $8000))
  else
    Multiplicand := Stuff.DestinationValue and $FFFF;

  var AbsoluteResult := Mul32(Multiplicand, Multiplier);
  if ResultIsNegative then
    Stuff.ResultValue := Sub32(0, AbsoluteResult)
  else
    Stuff.ResultValue := AbsoluteResult;

  Inc(Stuff.CyclesLeftInInstruction, 34 + TotalOperations * 2);
end;

procedure ActionMULS(var Stuff: TInstructionContext);
begin
  var ShiftedSourceValue: Cardinal := Stuff.SourceValue shl 1;
  var Total10Patterns: Cardinal := CountBitsSet((ShiftedSourceValue xor (ShiftedSourceValue shl 1)) and Cardinal($AAAA shl 1));
  var Total01Patterns: Cardinal := CountBitsSet((ShiftedSourceValue xor (ShiftedSourceValue shr 1)) and Cardinal(ArithmeticShiftRight($AAAA, 1)));
  ActionMULCommon(Stuff, True, (Add32(Total10Patterns, Total01Patterns)));
end;

procedure ActionMULU(var Stuff: TInstructionContext);
begin
  ActionMULCommon(Stuff, False, CountBitsSet(Stuff.SourceValue));
end;

procedure ActionADDX(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  Stuff.ResultValue := Add32(Add32(Stuff.DestinationValue, Stuff.SourceValue), Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0));
  ADDXSUBXExecutionTime(Stuff);
end;

procedure ActionABCD(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  ActionADDX(Stuff);
  Stuff.SourceValue := (((Stuff.SourceValue and Stuff.DestinationValue) or ((Stuff.SourceValue or Stuff.DestinationValue) and not Stuff.ResultValue)) and $88) shl 1;
  Stuff.SourceValue := Stuff.SourceValue or ((Add32(Stuff.ResultValue, $66) xor Stuff.ResultValue) and $110);
  Stuff.SourceValue := (Stuff.SourceValue shr 2) or (Stuff.SourceValue shr 3);
  Stuff.DestinationValue := Stuff.ResultValue;
  ActionADD(Stuff);
  ABCDSBCDExecutionTime(Stuff);
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  if ((Stuff.SourceValue and $40) <> 0) or (((Stuff.DestinationValue and not Stuff.ResultValue) and $80) <> 0) then
    State^.StatusRegister := Word(State^.StatusRegister or CONDITION_CODE_CARRY);
end;

procedure ActionEXG(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  case (Stuff.OpCode.Raw and $00F8) of
    $0040:
      begin
        var Data := State^.DataRegisters[Stuff.OpCode.SecondaryRegister];
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.DataRegisters[Stuff.OpCode.PrimaryRegister];
        State^.DataRegisters[Stuff.OpCode.PrimaryRegister] := Data;
      end;
    $0048:
      begin
        var Data := State^.AddressRegisters[Stuff.OpCode.SecondaryRegister];
        State^.AddressRegisters[Stuff.OpCode.SecondaryRegister] := State^.AddressRegisters[Stuff.OpCode.PrimaryRegister];
        State^.AddressRegisters[Stuff.OpCode.PrimaryRegister] := Data;
      end;
    $0088:
      begin
        var Data := State^.DataRegisters[Stuff.OpCode.SecondaryRegister];
        State^.DataRegisters[Stuff.OpCode.SecondaryRegister] := State^.AddressRegisters[Stuff.OpCode.PrimaryRegister];
        State^.AddressRegisters[Stuff.OpCode.PrimaryRegister] := Data;
      end;
  end;
  Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 2);
end;

procedure ActionASDMEMORY(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  var OriginalSignBit: Cardinal := Stuff.DestinationValue and SignBitBitmask;
  Stuff.ResultValue := Stuff.DestinationValue;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
    Stuff.ResultValue := Stuff.ResultValue shl 1;
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_OVERFLOW and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> OriginalSignBit))));
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
  end
  else
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
    Stuff.ResultValue := Stuff.ResultValue shr 1;
    Stuff.ResultValue := Stuff.ResultValue or OriginalSignBit;
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionASDREGISTER(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  var OriginalSignBit: Cardinal := Stuff.DestinationValue and SignBitBitmask;
  Stuff.ResultValue := Stuff.DestinationValue;
  var Count: Cardinal;
  if (Stuff.OpCode.Raw and $0020) <> 0 then
    Count := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] mod 64
  else
    Count := Add32(Sub32(Stuff.OpCode.SecondaryRegister, 1) and 7, 1);
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
      Stuff.ResultValue := Stuff.ResultValue shl 1;
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_OVERFLOW and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> OriginalSignBit))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
    end;
  end
  else
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
      Stuff.ResultValue := Stuff.ResultValue shr 1;
      Stuff.ResultValue := Stuff.ResultValue or OriginalSignBit;
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionLSDMEMORY(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  Stuff.ResultValue := Stuff.DestinationValue;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
    Stuff.ResultValue := Stuff.ResultValue shl 1;
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
  end
  else
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
    Stuff.ResultValue := Stuff.ResultValue shr 1;
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionLSDREGISTER(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  Stuff.ResultValue := Stuff.DestinationValue;
  var Count: Cardinal;
  if (Stuff.OpCode.Raw and $0020) <> 0 then
    Count := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] mod 64
  else
    Count := Add32(Sub32(Stuff.OpCode.SecondaryRegister, 1) and 7, 1);
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
      Stuff.ResultValue := Stuff.ResultValue shl 1;
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
    end;
  end
  else
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
      Stuff.ResultValue := Stuff.ResultValue shr 1;
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionRODMEMORY(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  Stuff.ResultValue := Stuff.DestinationValue;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
    Stuff.ResultValue := (Stuff.ResultValue shl 1) or Cardinal(Ord((Stuff.ResultValue and SignBitBitmask) <> 0));
  end
  else
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
    Stuff.ResultValue := (Stuff.ResultValue shr 1) or (SignBitBitmask and Cardinal(0 - Ord((Stuff.ResultValue and 1) <> 0)));
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionRODREGISTER(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  Stuff.ResultValue := Stuff.DestinationValue;
  var Count: Cardinal;
  if (Stuff.OpCode.Raw and $0020) <> 0 then
    Count := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] mod 64
  else
    Count := Add32(Sub32(Stuff.OpCode.SecondaryRegister, 1) and 7, 1);
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
      Stuff.ResultValue := (Stuff.ResultValue shl 1) or Cardinal(Ord((Stuff.ResultValue and SignBitBitmask) <> 0));
    end;
  end
  else
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
      Stuff.ResultValue := (Stuff.ResultValue shr 1) or (SignBitBitmask and Cardinal(0 - Ord((Stuff.ResultValue and 1) <> 0)));
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionROXDMEMORY(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  Stuff.ResultValue := Stuff.DestinationValue;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0))));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
    Stuff.ResultValue := Stuff.ResultValue shl 1;
    Stuff.ResultValue := Stuff.ResultValue or Cardinal(Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0));
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
  end
  else
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
    Stuff.ResultValue := Stuff.ResultValue shr 1;
    Stuff.ResultValue := Stuff.ResultValue or (SignBitBitmask and Cardinal(0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0)));
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
    State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionROXDREGISTER(var Stuff: TInstructionContext);
begin
  var State: PM68kState := Stuff.State;
  var SignBitBitmask: Cardinal := Cardinal(1) shl Stuff.MSBBitIndex;
  Stuff.ResultValue := Stuff.DestinationValue;
  var Count: Cardinal;
  if (Stuff.OpCode.Raw and $0020) <> 0 then
    Count := State^.DataRegisters[Stuff.OpCode.SecondaryRegister] mod 64
  else
    Count := Add32(Sub32(Stuff.OpCode.SecondaryRegister, 1) and 7, 1);
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0))));
  if Stuff.OpCode.Bit8 <> 0 then
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and SignBitBitmask) <> 0))));
      Stuff.ResultValue := Stuff.ResultValue shl 1;
      Stuff.ResultValue := Stuff.ResultValue or Cardinal(Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
    end;
  end
  else
  begin
    for var i := 0 to Integer(Count) - 1 do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord((Stuff.ResultValue and 1) <> 0))));
      Stuff.ResultValue := Stuff.ResultValue shr 1;
      Stuff.ResultValue := Stuff.ResultValue or (SignBitBitmask and Cardinal(0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> 0)));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> 0))));
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionUNIMPLEMENTED1(var Stuff: TInstructionContext);
begin
  Group1Or2Exception(Stuff, 10);
end;

procedure ActionUNIMPLEMENTED2(var Stuff: TInstructionContext);
begin
  Group1Or2Exception(Stuff, 11);
end;

procedure Clown68000Reset(var State: TM68kState; var Callbacks: TM68kReadWriteCallbacks);
begin
  var StateRef: PM68kState := @State;
  var Stuff: TInstructionContext := Default(TInstructionContext);
  Stuff.State := StateRef;
  Stuff.Callbacks := @Callbacks;
  try
    StateRef^.Halted := 0;
    StateRef^.Stopped := 0;
    StateRef^.PendingInterrupt := 0;
    StateRef^.StatusRegister := Word(StateRef^.StatusRegister and (not STATUS_TRACE));
    StateRef^.StatusRegister := Word(StateRef^.StatusRegister or $0700);
    SetSupervisorMode(StateRef, 1);
    StateRef^.AddressRegisters[7] := ReadLongWord(Stuff, 0);
    StateRef^.ProgramCounter := ReadLongWord(Stuff, 4);
  except
    on E: ECPUException do
      StateRef^.Halted := 1;
  end;
end;

procedure Clown68000Interrupt(var State: TM68kState; Level: Cardinal);
begin
  var StateRef: PM68kState := @State;
  Assert(Level <= 7);
  StateRef^.PendingInterrupt := Byte(Level);
end;

function Clown68000DoCycles(var State: TM68kState; var Callbacks: TM68kReadWriteCallbacks; CyclesToDo: Cardinal): Cardinal;
begin
  var StateRef: PM68kState := @State;
  var CallbacksRef: PM68kReadWriteCallbacks := @Callbacks;
  var PendingInterrupt: Cardinal;
  var Instruction: Integer;
  if StateRef^.Halted <> 0 then
    Exit(CyclesToDo);
  var Stuff: TInstructionContext := Default(TInstructionContext);
  Stuff.State := StateRef;
  Stuff.Callbacks := CallbacksRef;
  Stuff.CyclesLeftInInstruction := 0;
  Stuff.CyclesDone := 0;
  Stuff.TerminateEarly := 0;
  while True do
  begin
    Stuff.CyclesDone := Add32(Stuff.CyclesDone, Stuff.CyclesLeftInInstruction);
    if not ((Stuff.CyclesDone < CyclesToDo) and ((Stuff.TerminateEarly = 0))) then
      Break;
    try
      PendingInterrupt := Cardinal(StateRef^.PendingInterrupt);
      Stuff.CyclesLeftInInstruction := 4;
      Stuff.StartingProgramCounter := StateRef^.ProgramCounter;
      if StateRef^.Stopped = 0 then
      begin
        Instruction := DecodeOpcode(Stuff.OpCode, ReadWord(Stuff, StateRef^.ProgramCounter));
        StateRef^.InstructionRegister := Word(Stuff.OpCode.Raw);
        IncrementProgramCounter(StateRef, 2);
        case Instruction of
          INSTRUCTION_ABCD:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceBCDX(Stuff);
              ReadSource(Stuff);
              DecodeDestinationBCDX(Stuff);
              ReadDestination(Stuff);
              ActionABCD(Stuff);
              WriteDestination(Stuff);
              OverflowADD(Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_ADD:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionADD(Stuff);
              WriteDestination(Stuff);
              CarryStandardCarry(Stuff);
              OverflowADD(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_ADDA:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeSized(Stuff);
              ReadSource(Stuff);
              DecodeDestinationAddressRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionADDA(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_ADDAQ:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionADDQ(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_ADDI:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionADD(Stuff);
              WriteDestination(Stuff);
              CarryStandardCarry(Stuff);
              OverflowADD(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_ADDQ:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionADDQ(Stuff);
              WriteDestination(Stuff);
              CarryStandardCarry(Stuff);
              OverflowADD(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_ADDX:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceBCDX(Stuff);
              ReadSource(Stuff);
              DecodeDestinationBCDX(Stuff);
              ReadDestination(Stuff);
              ActionADDX(Stuff);
              WriteDestination(Stuff);
              CarryStandardCarry(Stuff);
              OverflowADD(Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_AND:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionAND(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ANDI:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionAND(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ANDI_TO_CCR:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationConditionCodeRegister(Stuff);
              ReadDestination(Stuff);
              ActionAND(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_ANDI_TO_SR:
            begin
              SupervisorCheck(Stuff);
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationStatusRegister(Stuff);
              ReadDestination(Stuff);
              ActionAND(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_ASD_MEMORY:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionASDMEMORY(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ASD_REGISTER:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterPrimary(Stuff);
              ReadDestination(Stuff);
              ActionASDREGISTER(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_BCC_SHORT:
            begin
              ActionBCCSHORT(Stuff);
            end;
          INSTRUCTION_BCC_WORD:
            begin
              DecodeSourceImmediateDataWord(Stuff);
              ReadSource(Stuff);
              ActionBCCWORD(Stuff);
            end;
          INSTRUCTION_BCHG_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondary(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBCHG(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_BCHG_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateDataByte(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBCHG(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_BCLR_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondary(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBCLR(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_BCLR_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateDataByte(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBCLR(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_BRA_SHORT:
            begin
              ActionBRASHORT(Stuff);
            end;
          INSTRUCTION_BRA_WORD:
            begin
              DecodeSourceImmediateDataWord(Stuff);
              ReadSource(Stuff);
              ActionBRAWORD(Stuff);
            end;
          INSTRUCTION_BSET_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondary(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBSET(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_BSET_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateDataByte(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBSET(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_BSR_SHORT:
            begin
              ActionBSRSHORT(Stuff);
            end;
          INSTRUCTION_BSR_WORD:
            begin
              DecodeSourceImmediateDataWord(Stuff);
              ReadSource(Stuff);
              ActionBSRWORD(Stuff);
            end;
          INSTRUCTION_BTST_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondary(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBTST(Stuff);
            end;
          INSTRUCTION_BTST_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateDataByte(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionBTST(Stuff);
            end;
          INSTRUCTION_CHK:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              ActionCHK(Stuff);
            end;
          INSTRUCTION_CLR:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionCLR(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_CMP:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionCMP(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_CMPA:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeSized(Stuff);
              ReadSource(Stuff);
              DecodeDestinationAddressRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionCMPA(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_CMPI:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionCMPI(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_CMPM:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceAddressRegisterPrimaryPostIncrement(Stuff);
              ReadSource(Stuff);
              DecodeDestinationAddressRegisterSecondaryPostIncrement(Stuff);
              ReadDestination(Stuff);
              ActionCMPM(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_DBCC:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              ActionDBCC(Stuff);
            end;
          INSTRUCTION_DIVS:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeWord(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionDIVS(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
            end;
          INSTRUCTION_DIVU:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeWord(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionDIVU(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
            end;
          INSTRUCTION_EOR:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondary(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionEOR(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_EORI:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionEOR(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_EORI_TO_CCR:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationConditionCodeRegister(Stuff);
              ReadDestination(Stuff);
              ActionEOR(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_EORI_TO_SR:
            begin
              SupervisorCheck(Stuff);
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationStatusRegister(Stuff);
              ReadDestination(Stuff);
              ActionEOR(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_EXG:
            begin
              ActionEXG(Stuff);
            end;
          INSTRUCTION_EXT:
            begin
              SetSizeExt(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterPrimary(Stuff);
              ReadDestination(Stuff);
              ActionEXT(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ILLEGAL:
            begin
              ActionILLEGAL(Stuff);
            end;
          INSTRUCTION_JMP:
            begin
              DecodeSourceMemoryAddressPrimary(Stuff);
              ReadSource(Stuff);
              ActionJMP(Stuff);
            end;
          INSTRUCTION_JSR:
            begin
              DecodeSourceMemoryAddressPrimary(Stuff);
              ReadSource(Stuff);
              ActionJSR(Stuff);
            end;
          INSTRUCTION_LEA:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceMemoryAddressPrimary(Stuff);
              ReadSource(Stuff);
              DecodeDestinationAddressRegisterSecondary(Stuff);
              ActionLEA(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_LINK:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              ActionLINK(Stuff);
            end;
          INSTRUCTION_LSD_MEMORY:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionLSDMEMORY(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_LSD_REGISTER:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterPrimary(Stuff);
              ReadDestination(Stuff);
              ActionLSDREGISTER(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_MOVE:
            begin
              SetSizeMove(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationSecondaryAddressMode(Stuff);
              ActionMOVE(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_MOVE_FROM_SR:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceStatusRegister(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ActionMOVE(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_MOVE_TO_CCR:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationConditionCodeRegister(Stuff);
              ActionMOVE(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_MOVE_TO_SR:
            begin
              SupervisorCheck(Stuff);
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationStatusRegister(Stuff);
              ActionMOVE(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_MOVE_USP:
            begin
              SupervisorCheck(Stuff);
              ActionMOVEUSP(Stuff);
            end;
          INSTRUCTION_MOVEA:
            begin
              SetSizeMove(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationAddressRegisterSecondaryFull(Stuff);
              ActionMOVEA(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_MOVEM:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationMOVEM(Stuff);
              ReadDestination(Stuff);
              ActionMOVEM(Stuff);
            end;
          INSTRUCTION_MOVEP:
            begin
              DecodeDestinationMOVEP(Stuff);
              ReadDestination(Stuff);
              ActionMOVEP(Stuff);
            end;
          INSTRUCTION_MOVEQ:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterSecondary(Stuff);
              ActionMOVEQ(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_MULS:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeWord(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionMULS(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_MULU:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeWord(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionMULU(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_NBCD:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionNBCD(Stuff);
              WriteDestination(Stuff);
              OverflowSUB(Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_NEG:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionNEG(Stuff);
              WriteDestination(Stuff);
              CarryNEG(Stuff);
              OverflowNEG(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_NEGX:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionNEGX(Stuff);
              WriteDestination(Stuff);
              CarryNEG(Stuff);
              OverflowNEG(Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_NOP:
            ; // Fetch and base instruction timing are already accounted for.
            INSTRUCTION_NOT:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionNOT(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_OR:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionOR(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ORI:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionOR(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ORI_TO_CCR:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationConditionCodeRegister(Stuff);
              ReadDestination(Stuff);
              ActionOR(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_ORI_TO_SR:
            begin
              SupervisorCheck(Stuff);
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationStatusRegister(Stuff);
              ReadDestination(Stuff);
              ActionOR(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_PEA:
            begin
              DecodeSourceMemoryAddressPrimary(Stuff);
              ReadSource(Stuff);
              ActionPEA(Stuff);
            end;
          INSTRUCTION_RESET:
            begin
              SupervisorCheck(Stuff);
              ActionRESET(Stuff);
            end;
          INSTRUCTION_ROD_MEMORY:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionRODMEMORY(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ROD_REGISTER:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterPrimary(Stuff);
              ReadDestination(Stuff);
              ActionRODREGISTER(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ROXD_MEMORY:
            begin
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionROXDMEMORY(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_ROXD_REGISTER:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterPrimary(Stuff);
              ReadDestination(Stuff);
              ActionROXDREGISTER(Stuff);
              WriteDestination(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_RTE:
            begin
              SupervisorCheck(Stuff);
              ActionRTE(Stuff);
            end;
          INSTRUCTION_RTR:
            begin
              ActionRTR(Stuff);
            end;
          INSTRUCTION_RTS:
            begin
              ActionRTS(Stuff);
            end;
          INSTRUCTION_SBCD:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceBCDX(Stuff);
              ReadSource(Stuff);
              DecodeDestinationBCDX(Stuff);
              ReadDestination(Stuff);
              ActionSBCD(Stuff);
              WriteDestination(Stuff);
              OverflowSUB(Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_SCC:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionSCC(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_STOP:
            begin
              SupervisorCheck(Stuff);
              SetSizeWord(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              ActionSTOP(Stuff);
            end;
          INSTRUCTION_SUB:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionSUB(Stuff);
              WriteDestination(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_SUBA:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressModeSized(Stuff);
              ReadSource(Stuff);
              DecodeDestinationAddressRegisterSecondary(Stuff);
              ReadDestination(Stuff);
              ActionSUBA(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_SUBAQ:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionSUBQ(Stuff);
              WriteDestination(Stuff);
            end;
          INSTRUCTION_SUBI:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceImmediateData(Stuff);
              ReadSource(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionSUB(Stuff);
              WriteDestination(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_SUBQ:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionSUBQ(Stuff);
              WriteDestination(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_SUBX:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourceBCDX(Stuff);
              ReadSource(Stuff);
              DecodeDestinationBCDX(Stuff);
              ReadDestination(Stuff);
              ActionSUBX(Stuff);
              WriteDestination(Stuff);
              CarryStandardBorrow(Stuff);
              OverflowSUB(Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
              ExtendSetToCarry(Stuff);
            end;
          INSTRUCTION_SWAP:
            begin
              SetSizeLongword(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationDataRegisterPrimary(Stuff);
              ReadDestination(Stuff);
              ActionSWAP(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_TAS:
            begin
              SetSizeByte(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeDestinationPrimaryAddressMode(Stuff);
              ReadDestination(Stuff);
              ActionTAS(Stuff);
              WriteDestination(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
            end;
          INSTRUCTION_TRAP:
            begin
              ActionTRAP(Stuff);
            end;
          INSTRUCTION_TRAPV:
            begin
              ActionTRAPV(Stuff);
            end;
          INSTRUCTION_TST:
            begin
              SetSizeStandard(Stuff);
              SetMSBBitIndex(Stuff);
              DecodeSourcePrimaryAddressMode(Stuff);
              ReadSource(Stuff);
              ActionTST(Stuff);
              CarryClear(Stuff);
              OverflowClear(Stuff);
              ZeroSetIfZeroClearOtherwise(Stuff);
              NegativeSetIfNegativeClearOtherwise(Stuff);
            end;
          INSTRUCTION_UNLK:
            begin
              ActionUNLK(Stuff);
            end;
          INSTRUCTION_UNIMPLEMENTED_1:
            begin
              ActionUNIMPLEMENTED1(Stuff);
            end;
          INSTRUCTION_UNIMPLEMENTED_2:
            begin
              ActionUNIMPLEMENTED2(Stuff);
            end;
        end;
      end;
      if (PendingInterrupt = 7) or (PendingInterrupt > ((Cardinal(StateRef^.StatusRegister) shr 8) and 7)) then
      begin
        StateRef^.Stopped := 0;
        DoInterrupt(Stuff, (Add32(24, PendingInterrupt)));
        Stuff.CyclesLeftInInstruction := Cardinal(Stuff.CyclesLeftInInstruction + 14);
        StateRef^.StatusRegister := Word(StateRef^.StatusRegister and (not STATUS_INTERRUPT_MASK));
        StateRef^.StatusRegister := Word(StateRef^.StatusRegister or (PendingInterrupt shl 8));
        CallbacksRef^.InterruptAcknowledgeCallback(CallbacksRef^.UserData);
      end;
    except
      on E: ECPUException do
      begin
        if E.Code = 2 then
        begin
          StateRef^.ProgramCounter := Stuff.StartingProgramCounter;
          DoInterrupt(Stuff, Stuff.Exception.VectorOffset);
        end;
        if StateRef^.Halted <> 0 then
          Exit(CyclesToDo);
      end;
    end;
  end;
  Exit(Stuff.CyclesDone);
end;

end.

