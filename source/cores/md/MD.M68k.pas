unit MD.M68k;

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

{$Q-}
{$R-}

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

  TMemoryReadCallback = function(UserData: Pointer; Address: Cardinal; DoHighByte: Byte; DoLowByte: Byte; CurrentCycle: Cardinal; TerminateEarly: PByte): Cardinal;

  TMemoryWriteCallback = procedure(UserData: Pointer; Address: Cardinal; DoHighByte: Byte; DoLowByte: Byte; CurrentCycle: Cardinal; TerminateEarly: PByte; Value: Cardinal);

  TInterruptAcknowledgeCallback = procedure(UserData: Pointer);

  TM68kReadWriteCallbacks = record
    ReadCallback: TMemoryReadCallback;
    WriteCallback: TMemoryWriteCallback;
    InterruptAcknowledgeCallback: TInterruptAcknowledgeCallback;
    UserData: Pointer;
  end;

  PInstructionContext = ^TInstructionContext;

  TReadAddress = function(Stuff: PInstructionContext; Address: Cardinal): Cardinal;

  TWriteAddress = procedure(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);

  TDecodedMemoryAddressMode = record
    Address: Cardinal;
    ReadAddress: TReadAddress;
    WriteAddress: TWriteAddress;
  end;

  TRegisterAddressMode = record
    Address: PCardinal;
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
    c_operation_size: Cardinal;
    MSBBitIndex: Cardinal;
    SourceDecodedAddressMode: TDecodedAddressMode;
    DestinationDecodedAddressMode: TDecodedAddressMode;
    SourceValue: Cardinal;
    DestinationValue: Cardinal;
    ResultValue: Cardinal;
    StartingProgramCounter: Cardinal;
    TerminateEarly: Byte;
  end;

  PSplitOpcode = ^TSplitOpcode;

  PDecodedMemoryAddressMode = ^TDecodedMemoryAddressMode;

  PDecodedAddressMode = ^TDecodedAddressMode;

const
  INSTRUCTION_ABCD = ( -1) + 1;
  INSTRUCTION_ADD = ( INSTRUCTION_ABCD) + 1;
  INSTRUCTION_ADDA = ( INSTRUCTION_ADD) + 1;
  INSTRUCTION_ADDAQ = ( INSTRUCTION_ADDA) + 1;
  INSTRUCTION_ADDI = ( INSTRUCTION_ADDAQ) + 1;
  INSTRUCTION_ADDQ = ( INSTRUCTION_ADDI) + 1;
  INSTRUCTION_ADDX = ( INSTRUCTION_ADDQ) + 1;
  INSTRUCTION_AND = ( INSTRUCTION_ADDX) + 1;
  INSTRUCTION_ANDI = ( INSTRUCTION_AND) + 1;
  INSTRUCTION_ANDI_TO_CCR = ( INSTRUCTION_ANDI) + 1;
  INSTRUCTION_ANDI_TO_SR = ( INSTRUCTION_ANDI_TO_CCR) + 1;
  INSTRUCTION_ASD_MEMORY = ( INSTRUCTION_ANDI_TO_SR) + 1;
  INSTRUCTION_ASD_REGISTER = ( INSTRUCTION_ASD_MEMORY) + 1;
  INSTRUCTION_BCC_SHORT = ( INSTRUCTION_ASD_REGISTER) + 1;
  INSTRUCTION_BCC_WORD = ( INSTRUCTION_BCC_SHORT) + 1;
  INSTRUCTION_BCHG_DYNAMIC = ( INSTRUCTION_BCC_WORD) + 1;
  INSTRUCTION_BCHG_STATIC = ( INSTRUCTION_BCHG_DYNAMIC) + 1;
  INSTRUCTION_BCLR_DYNAMIC = ( INSTRUCTION_BCHG_STATIC) + 1;
  INSTRUCTION_BCLR_STATIC = ( INSTRUCTION_BCLR_DYNAMIC) + 1;
  INSTRUCTION_BRA_SHORT = ( INSTRUCTION_BCLR_STATIC) + 1;
  INSTRUCTION_BRA_WORD = ( INSTRUCTION_BRA_SHORT) + 1;
  INSTRUCTION_BSET_DYNAMIC = ( INSTRUCTION_BRA_WORD) + 1;
  INSTRUCTION_BSET_STATIC = ( INSTRUCTION_BSET_DYNAMIC) + 1;
  INSTRUCTION_BSR_SHORT = ( INSTRUCTION_BSET_STATIC) + 1;
  INSTRUCTION_BSR_WORD = ( INSTRUCTION_BSR_SHORT) + 1;
  INSTRUCTION_BTST_DYNAMIC = ( INSTRUCTION_BSR_WORD) + 1;
  INSTRUCTION_BTST_STATIC = ( INSTRUCTION_BTST_DYNAMIC) + 1;
  INSTRUCTION_CHK = ( INSTRUCTION_BTST_STATIC) + 1;
  INSTRUCTION_CLR = ( INSTRUCTION_CHK) + 1;
  INSTRUCTION_CMP = ( INSTRUCTION_CLR) + 1;
  INSTRUCTION_CMPA = ( INSTRUCTION_CMP) + 1;
  INSTRUCTION_CMPI = ( INSTRUCTION_CMPA) + 1;
  INSTRUCTION_CMPM = ( INSTRUCTION_CMPI) + 1;
  INSTRUCTION_DBCC = ( INSTRUCTION_CMPM) + 1;
  INSTRUCTION_DIVS = ( INSTRUCTION_DBCC) + 1;
  INSTRUCTION_DIVU = ( INSTRUCTION_DIVS) + 1;
  INSTRUCTION_EOR = ( INSTRUCTION_DIVU) + 1;
  INSTRUCTION_EORI = ( INSTRUCTION_EOR) + 1;
  INSTRUCTION_EORI_TO_CCR = ( INSTRUCTION_EORI) + 1;
  INSTRUCTION_EORI_TO_SR = ( INSTRUCTION_EORI_TO_CCR) + 1;
  INSTRUCTION_EXG = ( INSTRUCTION_EORI_TO_SR) + 1;
  INSTRUCTION_EXT = ( INSTRUCTION_EXG) + 1;
  INSTRUCTION_ILLEGAL = ( INSTRUCTION_EXT) + 1;
  INSTRUCTION_JMP = ( INSTRUCTION_ILLEGAL) + 1;
  INSTRUCTION_JSR = ( INSTRUCTION_JMP) + 1;
  INSTRUCTION_LEA = ( INSTRUCTION_JSR) + 1;
  INSTRUCTION_LINK = ( INSTRUCTION_LEA) + 1;
  INSTRUCTION_LSD_MEMORY = ( INSTRUCTION_LINK) + 1;
  INSTRUCTION_LSD_REGISTER = ( INSTRUCTION_LSD_MEMORY) + 1;
  INSTRUCTION_MOVE = ( INSTRUCTION_LSD_REGISTER) + 1;
  INSTRUCTION_MOVE_FROM_SR = ( INSTRUCTION_MOVE) + 1;
  INSTRUCTION_MOVE_TO_CCR = ( INSTRUCTION_MOVE_FROM_SR) + 1;
  INSTRUCTION_MOVE_TO_SR = ( INSTRUCTION_MOVE_TO_CCR) + 1;
  INSTRUCTION_MOVE_USP = ( INSTRUCTION_MOVE_TO_SR) + 1;
  INSTRUCTION_MOVEA = ( INSTRUCTION_MOVE_USP) + 1;
  INSTRUCTION_MOVEM = ( INSTRUCTION_MOVEA) + 1;
  INSTRUCTION_MOVEP = ( INSTRUCTION_MOVEM) + 1;
  INSTRUCTION_MOVEQ = ( INSTRUCTION_MOVEP) + 1;
  INSTRUCTION_MULS = ( INSTRUCTION_MOVEQ) + 1;
  INSTRUCTION_MULU = ( INSTRUCTION_MULS) + 1;
  INSTRUCTION_NBCD = ( INSTRUCTION_MULU) + 1;
  INSTRUCTION_NEG = ( INSTRUCTION_NBCD) + 1;
  INSTRUCTION_NEGX = ( INSTRUCTION_NEG) + 1;
  INSTRUCTION_NOP = ( INSTRUCTION_NEGX) + 1;
  INSTRUCTION_NOT = ( INSTRUCTION_NOP) + 1;
  INSTRUCTION_OR = ( INSTRUCTION_NOT) + 1;
  INSTRUCTION_ORI = ( INSTRUCTION_OR) + 1;
  INSTRUCTION_ORI_TO_CCR = ( INSTRUCTION_ORI) + 1;
  INSTRUCTION_ORI_TO_SR = ( INSTRUCTION_ORI_TO_CCR) + 1;
  INSTRUCTION_PEA = ( INSTRUCTION_ORI_TO_SR) + 1;
  INSTRUCTION_RESET = ( INSTRUCTION_PEA) + 1;
  INSTRUCTION_ROD_MEMORY = ( INSTRUCTION_RESET) + 1;
  INSTRUCTION_ROD_REGISTER = ( INSTRUCTION_ROD_MEMORY) + 1;
  INSTRUCTION_ROXD_MEMORY = ( INSTRUCTION_ROD_REGISTER) + 1;
  INSTRUCTION_ROXD_REGISTER = ( INSTRUCTION_ROXD_MEMORY) + 1;
  INSTRUCTION_RTE = ( INSTRUCTION_ROXD_REGISTER) + 1;
  INSTRUCTION_RTR = ( INSTRUCTION_RTE) + 1;
  INSTRUCTION_RTS = ( INSTRUCTION_RTR) + 1;
  INSTRUCTION_SBCD = ( INSTRUCTION_RTS) + 1;
  INSTRUCTION_SCC = ( INSTRUCTION_SBCD) + 1;
  INSTRUCTION_STOP = ( INSTRUCTION_SCC) + 1;
  INSTRUCTION_SUB = ( INSTRUCTION_STOP) + 1;
  INSTRUCTION_SUBA = ( INSTRUCTION_SUB) + 1;
  INSTRUCTION_SUBAQ = ( INSTRUCTION_SUBA) + 1;
  INSTRUCTION_SUBI = ( INSTRUCTION_SUBAQ) + 1;
  INSTRUCTION_SUBQ = ( INSTRUCTION_SUBI) + 1;
  INSTRUCTION_SUBX = ( INSTRUCTION_SUBQ) + 1;
  INSTRUCTION_SWAP = ( INSTRUCTION_SUBX) + 1;
  INSTRUCTION_TAS = ( INSTRUCTION_SWAP) + 1;
  INSTRUCTION_TRAP = ( INSTRUCTION_TAS) + 1;
  INSTRUCTION_TRAPV = ( INSTRUCTION_TRAP) + 1;
  INSTRUCTION_TST = ( INSTRUCTION_TRAPV) + 1;
  INSTRUCTION_UNLK = ( INSTRUCTION_TST) + 1;
  INSTRUCTION_UNIMPLEMENTED_1 = ( INSTRUCTION_UNLK) + 1;
  INSTRUCTION_UNIMPLEMENTED_2 = ( INSTRUCTION_UNIMPLEMENTED_1) + 1;
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
  STATUS_INTERRUPT_MASK = ( 7 shl 8);
  STATUS_SUPERVISOR = ( 1 shl 13);
  STATUS_TRACE = ( 1 shl 15);
  STATUS_REGISTER_MASK = ( ( ( STATUS_TRACE or STATUS_SUPERVISOR) or STATUS_INTERRUPT_MASK) or CONDITION_CODE_REGISTER_MASK);
  DECODED_ADDRESS_MODE_TYPE_REGISTER = ( -1) + 1;
  DECODED_ADDRESS_MODE_TYPE_MEMORY = ( DECODED_ADDRESS_MODE_TYPE_REGISTER) + 1;
  DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER = ( DECODED_ADDRESS_MODE_TYPE_MEMORY) + 1;
  DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER = ( DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER) + 1;

type
  ECPUException = class(Exception)
  public
    Code: Integer;
    constructor CreateCode(Value: Integer);
  end;

function GetInstruction(OpCode: PSplitOpcode): Integer;

function DecodeOpcode(SplitOpcode: PSplitOpcode; OpCode: Cardinal): Integer;

function ReadAddress(Stuff: PInstructionContext; Address: Cardinal): Cardinal;

function ReadByte(Stuff: PInstructionContext; Address: Cardinal): Cardinal;

function ReadWord(Stuff: PInstructionContext; Address: Cardinal): Cardinal;

function ReadLongWord(Stuff: PInstructionContext; Address: Cardinal): Cardinal;

function ReadLongWordBackwards(Stuff: PInstructionContext; Address: Cardinal): Cardinal;

procedure WriteByte(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);

procedure WriteWord(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);

procedure WriteLongWord(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);

procedure WriteLongWordBackwards(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);

procedure SetSupervisorMode(State: PM68kState; SupervisorMode: Byte);

procedure IncrementRegister(RegisterPointer: PCardinal; Delta: Cardinal);

procedure DecrementRegister(RegisterPointer: PCardinal; Delta: Cardinal);

procedure IncrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);

procedure DecrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);

procedure IncrementProgramCounter(State: PM68kState; Delta: Cardinal);

procedure DoInterrupt(Stuff: PInstructionContext; VectorOffset: Cardinal);

procedure Group1Or2Exception(Stuff: PInstructionContext; VectorOffset: Cardinal);

procedure Group0Exception(Stuff: PInstructionContext; VectorOffset: Cardinal; AccessAddress: Cardinal; IsARead: Byte);

procedure DecodeMemoryAddressMode(Stuff: PInstructionContext; DecodedMemoryAddressMode: PDecodedMemoryAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);

procedure DecodeAddressMode(Stuff: PInstructionContext; DecodedAddressMode: PDecodedAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);

function GetValueUsingDecodedAddressMode(Stuff: PInstructionContext; DecodedAddressMode: PDecodedAddressMode): Cardinal;

procedure SetValueUsingDecodedAddressMode(Stuff: PInstructionContext; DecodedAddressMode: PDecodedAddressMode; Value: Cardinal);

function IsOpcodeConditionTrue(State: PM68kState; OpCode: Cardinal): Byte;

procedure SingleOperandInstructionExecutionTimeWordOnly(Stuff: PInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal);

procedure SingleOperandInstructionExecutionTimeLongwordOnly(Stuff: PInstructionContext; RegisterLongword: Cardinal; MemoryLongword: Cardinal);

procedure SingleOperandInstructionExecutionTime(Stuff: PInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal; RegisterLongword: Cardinal; MemoryLongword: Cardinal);

procedure SingleOperandInstructionExecutionTimeCommon(Stuff: PInstructionContext);

procedure ShiftRotateInstructionExecutionTimeRegister(Stuff: PInstructionContext; Count: Cardinal);

procedure ShiftRotateInstructionExecutionTimeMemory(Stuff: PInstructionContext);

procedure ADDXSUBXExecutionTime(Stuff: PInstructionContext);

procedure StandardInstructionExecutionTime(Stuff: PInstructionContext);

procedure StandardInstructionExecutionTimeQuick(Stuff: PInstructionContext);

procedure LEAPEAInstructionExecutionTime(Stuff: PInstructionContext);

procedure ABCDSBCDExecutionTime(Stuff: PInstructionContext);

procedure SupervisorCheck(Stuff: PInstructionContext);

procedure SetSizeByte(Stuff: PInstructionContext);

procedure SetSizeWord(Stuff: PInstructionContext);

procedure SetSizeLongword(Stuff: PInstructionContext);

procedure SetSizeLongwordRegisterByteMemory(Stuff: PInstructionContext);

procedure SetSizeMove(Stuff: PInstructionContext);

procedure SetSizeExt(Stuff: PInstructionContext);

procedure SetSizeStandard(Stuff: PInstructionContext);

procedure SetMSBBitIndex(Stuff: PInstructionContext);

procedure DecodeSourceImmediateData(Stuff: PInstructionContext);

procedure DecodeSourceDataRegisterSecondary(Stuff: PInstructionContext);

procedure DecodeSourceImmediateDataByte(Stuff: PInstructionContext);

procedure DecodeSourceMemoryAddressPrimary(Stuff: PInstructionContext);

procedure DecodeSourceStatusRegister(Stuff: PInstructionContext);

procedure DecodeSourceImmediateDataWord(Stuff: PInstructionContext);

procedure DecodeSourceBCDX(Stuff: PInstructionContext);

procedure DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(Stuff: PInstructionContext);

procedure DecodeSourcePrimaryAddressModeSized(Stuff: PInstructionContext);

procedure DecodeSourceAddressRegisterPrimaryPostIncrement(Stuff: PInstructionContext);

procedure DecodeSourcePrimaryAddressMode(Stuff: PInstructionContext);

procedure DecodeSourcePrimaryAddressModeWord(Stuff: PInstructionContext);

procedure DecodeDestinationDataRegisterPrimary(Stuff: PInstructionContext);

procedure DecodeDestinationDataRegisterSecondary(Stuff: PInstructionContext);

procedure DecodeDestinationAddressRegisterSecondary(Stuff: PInstructionContext);

procedure DecodeDestinationSecondaryAddressMode(Stuff: PInstructionContext);

procedure DecodeDestinationBCDX(Stuff: PInstructionContext);

procedure DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(Stuff: PInstructionContext);

procedure DecodeDestinationAddressRegisterSecondaryFull(Stuff: PInstructionContext);

procedure DecodeDestinationAddressRegisterSecondaryPostIncrement(Stuff: PInstructionContext);

procedure DecodeDestinationPrimaryAddressMode(Stuff: PInstructionContext);

procedure DecodeDestinationConditionCodeRegister(Stuff: PInstructionContext);

procedure DecodeDestinationStatusRegister(Stuff: PInstructionContext);

procedure DecodeDestinationMOVEM(Stuff: PInstructionContext);

procedure DecodeDestinationMOVEP(Stuff: PInstructionContext);

procedure ReadSource(Stuff: PInstructionContext);

procedure ReadDestination(Stuff: PInstructionContext);

procedure WriteDestination(Stuff: PInstructionContext);

procedure CarryStandardCarry(Stuff: PInstructionContext);

procedure CarryStandardBorrow(Stuff: PInstructionContext);

procedure CarryNEG(Stuff: PInstructionContext);

procedure CarryClear(Stuff: PInstructionContext);

procedure OverflowADD(Stuff: PInstructionContext);

procedure OverflowSUB(Stuff: PInstructionContext);

procedure OverflowNEG(Stuff: PInstructionContext);

procedure OverflowClear(Stuff: PInstructionContext);

procedure ZeroClearIfNonZeroUnaffectedOtherwise(Stuff: PInstructionContext);

procedure ZeroSetIfZeroClearOtherwise(Stuff: PInstructionContext);

procedure NegativeSetIfNegativeClearOtherwise(Stuff: PInstructionContext);

procedure ExtendSetToCarry(Stuff: PInstructionContext);

procedure ActionOR(Stuff: PInstructionContext);

procedure ActionAND(Stuff: PInstructionContext);

procedure ActionSUBCommon(Stuff: PInstructionContext);

procedure ActionCMP(Stuff: PInstructionContext);

procedure ActionCMPI(Stuff: PInstructionContext);

procedure ActionCMPM(Stuff: PInstructionContext);

procedure ActionSUB(Stuff: PInstructionContext);

procedure ActionADDASUBACommon(Stuff: PInstructionContext);

procedure ActionCMPA(Stuff: PInstructionContext);

procedure ActionSUBA(Stuff: PInstructionContext);

procedure ActionSUBQ(Stuff: PInstructionContext);

procedure ActionADD(Stuff: PInstructionContext);

procedure ActionADDA(Stuff: PInstructionContext);

procedure ActionADDQ(Stuff: PInstructionContext);

procedure ActionEOR(Stuff: PInstructionContext);

procedure ActionBxxx(Stuff: PInstructionContext);

procedure ActionBTST(Stuff: PInstructionContext);

procedure ActionBCHG(Stuff: PInstructionContext);

procedure ActionBCLR(Stuff: PInstructionContext);

procedure ActionBSET(Stuff: PInstructionContext);

procedure ActionMOVEP(Stuff: PInstructionContext);

procedure ActionMOVEA(Stuff: PInstructionContext);

procedure ActionMOVECommon(Stuff: PInstructionContext);

procedure ActionMOVE(Stuff: PInstructionContext);

procedure ActionLINK(Stuff: PInstructionContext);

procedure ActionUNLK(Stuff: PInstructionContext);

procedure ActionNEGX(Stuff: PInstructionContext);

procedure ActionCLR(Stuff: PInstructionContext);

procedure ActionNEG(Stuff: PInstructionContext);

procedure ActionNOT(Stuff: PInstructionContext);

procedure ActionEXT(Stuff: PInstructionContext);

procedure ActionSWAP(Stuff: PInstructionContext);

procedure ActionPEA(Stuff: PInstructionContext);

procedure ActionILLEGAL(Stuff: PInstructionContext);

procedure ActionTAS(Stuff: PInstructionContext);

procedure ActionTRAP(Stuff: PInstructionContext);

procedure ActionMOVE_USP(Stuff: PInstructionContext);

procedure c_ProgramCounterChanged(Stuff: PInstructionContext);

procedure c_SetStatusRegister(Stuff: PInstructionContext; Value: Cardinal);

procedure ActionRESET(Stuff: PInstructionContext);

procedure ActionSTOP(Stuff: PInstructionContext);

procedure ActionRTE(Stuff: PInstructionContext);

procedure ActionRTS(Stuff: PInstructionContext);

procedure ActionTRAPV(Stuff: PInstructionContext);

procedure ActionRTR(Stuff: PInstructionContext);

procedure ActionJMP(Stuff: PInstructionContext);

procedure ActionJSR(Stuff: PInstructionContext);

procedure ActionLEA(Stuff: PInstructionContext);

procedure ActionTST(Stuff: PInstructionContext);

procedure ActionMOVEM(Stuff: PInstructionContext);

procedure ActionCHK(Stuff: PInstructionContext);

procedure ActionSCC(Stuff: PInstructionContext);

procedure ActionBRASHORT(Stuff: PInstructionContext);

procedure ActionBRAWORD(Stuff: PInstructionContext);

procedure ActionBSRSHORT(Stuff: PInstructionContext);

procedure ActionBSRWORD(Stuff: PInstructionContext);

procedure ActionBCCSHORT(Stuff: PInstructionContext);

procedure ActionBCCWORD(Stuff: PInstructionContext);

procedure ActionDBCC(Stuff: PInstructionContext);

procedure ActionMOVEQ(Stuff: PInstructionContext);

function CountBitsSet(Value: Cardinal): Cardinal;

procedure ActionDIVCommon(Stuff: PInstructionContext; IsSigned: Byte);

procedure ActionDIVS(Stuff: PInstructionContext);

procedure ActionDIVU(Stuff: PInstructionContext);

procedure ActionSUBXCommon(Stuff: PInstructionContext);

procedure ActionSUBX(Stuff: PInstructionContext);

procedure ActionSBCDCommon(Stuff: PInstructionContext);

procedure ActionSBCD(Stuff: PInstructionContext);

procedure ActionNBCD(Stuff: PInstructionContext);

procedure ActionMULCommon(Stuff: PInstructionContext; IsSigned: Byte; TotalOperations: Cardinal);

procedure ActionMULS(Stuff: PInstructionContext);

procedure ActionMULU(Stuff: PInstructionContext);

procedure ActionADDX(Stuff: PInstructionContext);

procedure ActionABCD(Stuff: PInstructionContext);

procedure ActionEXG(Stuff: PInstructionContext);

procedure ActionASDMEMORY(Stuff: PInstructionContext);

procedure ActionASDREGISTER(Stuff: PInstructionContext);

procedure ActionLSDMEMORY(Stuff: PInstructionContext);

procedure ActionLSDREGISTER(Stuff: PInstructionContext);

procedure ActionRODMEMORY(Stuff: PInstructionContext);

procedure ActionRODREGISTER(Stuff: PInstructionContext);

procedure ActionROXDMEMORY(Stuff: PInstructionContext);

procedure ActionROXDREGISTER(Stuff: PInstructionContext);

procedure ActionUNIMPLEMENTED1(Stuff: PInstructionContext);

procedure ActionUNIMPLEMENTED2(Stuff: PInstructionContext);

procedure ActionNOP(Stuff: PInstructionContext);

procedure Clown68000Reset(State: PM68kState; Callbacks: PM68kReadWriteCallbacks);

procedure Clown68000Interrupt(State: PM68kState; Level: Cardinal);

function Clown68000DoCycles(State: PM68kState; Callbacks: PM68kReadWriteCallbacks; CyclesToDo: Cardinal): Cardinal;

implementation

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer((Cardinal(Value) shr Bits) or (Cardinal(-Ord(Value < 0)) shl (32 - Bits)));
end;

constructor ECPUException.CreateCode(Value: Integer);
begin
  inherited Create('68000 exception');
  Code := Value;
end;

function GetInstruction(OpCode: PSplitOpcode): Integer;
var
  temp48: Integer;
  temp52: Integer;
  temp61: Integer;
  temp78: Integer;
  temp79: Integer;
  temp88: Integer;
  temp89: Integer;
  temp90: Integer;
  temp91: Integer;
  temp92: Integer;
begin
  var Instruction_: Integer := INSTRUCTION_ILLEGAL;
  case (Cardinal(OpCode^.Raw shr 12) and Cardinal($F)) of
    $0:
      begin
        if (OpCode^.Bit8 <> 0) then
        begin
          if (Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER)) then
          begin
            Instruction_ := INSTRUCTION_MOVEP;
          end
          else
          begin
            case OpCode^.Bits6and7 of
              0:
                begin
                  Instruction_ := INSTRUCTION_BTST_DYNAMIC;
                end;
              1:
                begin
                  Instruction_ := INSTRUCTION_BCHG_DYNAMIC;
                end;
              2:
                begin
                  Instruction_ := INSTRUCTION_BCLR_DYNAMIC;
                end;
              3:
                begin
                  Instruction_ := INSTRUCTION_BSET_DYNAMIC;
                end;
            end;
          end;
        end
        else
        begin
          case OpCode^.SecondaryRegister of
            0:
              begin
                temp48 := Ord(Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_SPECIAL));
                if temp48 <> 0 then
                begin
                  temp48 := Ord(Cardinal(OpCode^.PrimaryRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE));
                end;
                if (temp48 <> 0) then
                begin
                  case OpCode^.Bits6and7 of
                    0:
                      begin
                        Instruction_ := INSTRUCTION_ORI_TO_CCR;
                      end;
                    1:
                      begin
                        Instruction_ := INSTRUCTION_ORI_TO_SR;
                      end;
                  end;
                end
                else
                begin
                  Instruction_ := INSTRUCTION_ORI;
                end;
              end;
            1:
              begin
                temp52 := Ord(Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_SPECIAL));
                if temp52 <> 0 then
                begin
                  temp52 := Ord(Cardinal(OpCode^.PrimaryRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE));
                end;
                if (temp52 <> 0) then
                begin
                  case OpCode^.Bits6and7 of
                    0:
                      begin
                        Instruction_ := INSTRUCTION_ANDI_TO_CCR;
                      end;
                    1:
                      begin
                        Instruction_ := INSTRUCTION_ANDI_TO_SR;
                      end;
                  end;
                end
                else
                begin
                  Instruction_ := INSTRUCTION_ANDI;
                end;
              end;
            2:
              begin
                Instruction_ := INSTRUCTION_SUBI;
              end;
            3:
              begin
                Instruction_ := INSTRUCTION_ADDI;
              end;
            4:
              begin
                case OpCode^.Bits6and7 of
                  0:
                    begin
                      Instruction_ := INSTRUCTION_BTST_STATIC;
                    end;
                  1:
                    begin
                      Instruction_ := INSTRUCTION_BCHG_STATIC;
                    end;
                  2:
                    begin
                      Instruction_ := INSTRUCTION_BCLR_STATIC;
                    end;
                  3:
                    begin
                      Instruction_ := INSTRUCTION_BSET_STATIC;
                    end;
                end;
              end;
            5:
              begin
                temp61 := Ord(Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_SPECIAL));
                if temp61 <> 0 then
                begin
                  temp61 := Ord(Cardinal(OpCode^.PrimaryRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE));
                end;
                if (temp61 <> 0) then
                begin
                  case OpCode^.Bits6and7 of
                    0:
                      begin
                        Instruction_ := INSTRUCTION_EORI_TO_CCR;
                      end;
                    1:
                      begin
                        Instruction_ := INSTRUCTION_EORI_TO_SR;
                      end;
                  end;
                end
                else
                begin
                  Instruction_ := INSTRUCTION_EORI;
                end;
              end;
            6:
              begin
                Instruction_ := INSTRUCTION_CMPI;
              end;
          end;
        end;
      end;
    $1, $2, $3:
      begin
        if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($01C0)) = Cardinal($0040)) then
        begin
          Instruction_ := INSTRUCTION_MOVEA;
        end
        else
        begin
          Instruction_ := INSTRUCTION_MOVE;
        end;
      end;
    $4:
      begin
        if (OpCode^.Bit8 <> 0) then
        begin
          case OpCode^.Bits6and7 of
            3:
              begin
                Instruction_ := INSTRUCTION_LEA;
              end;
            2:
              begin
                Instruction_ := INSTRUCTION_CHK;
              end;
          else
            begin
            end;
          end;
        end
        else
        begin
          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0800)) = Cardinal(0)) then
          begin
            if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
            begin
              case OpCode^.SecondaryRegister of
                0:
                  begin
                    Instruction_ := INSTRUCTION_MOVE_FROM_SR;
                  end;
                2:
                  begin
                    Instruction_ := INSTRUCTION_MOVE_TO_CCR;
                  end;
                3:
                  begin
                    Instruction_ := INSTRUCTION_MOVE_TO_SR;
                  end;
              end;
            end
            else
            begin
              case OpCode^.SecondaryRegister of
                0:
                  begin
                    Instruction_ := INSTRUCTION_NEGX;
                  end;
                1:
                  begin
                    Instruction_ := INSTRUCTION_CLR;
                  end;
                2:
                  begin
                    Instruction_ := INSTRUCTION_NEG;
                  end;
                3:
                  begin
                    Instruction_ := INSTRUCTION_NOT;
                  end;
              end;
            end;
          end
          else
          begin
            if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0200)) = Cardinal(0)) then
            begin
              if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($01B8)) = Cardinal($0080)) then
              begin
                Instruction_ := INSTRUCTION_EXT;
              end
              else
              begin
                if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($01C0)) = Cardinal($0000)) then
                begin
                  Instruction_ := INSTRUCTION_NBCD;
                end
                else
                begin
                  if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($01F8)) = Cardinal($0040)) then
                  begin
                    Instruction_ := INSTRUCTION_SWAP;
                  end
                  else
                  begin
                    if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($01C0)) = Cardinal($0040)) then
                    begin
                      Instruction_ := INSTRUCTION_PEA;
                    end
                    else
                    begin
                      if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0B80)) = Cardinal($0880)) then
                      begin
                        Instruction_ := INSTRUCTION_MOVEM;
                      end;
                    end;
                  end;
                end;
              end;
            end
            else
            begin
              temp79 := Ord(Cardinal(OpCode^.Raw) = Cardinal($4AFA));
              if temp79 = 0 then
              begin
                temp79 := Ord(Cardinal(OpCode^.Raw) = Cardinal($4AFB));
              end;
              temp78 := Ord(temp79 <> 0);
              if temp78 = 0 then
              begin
                temp78 := Ord(Cardinal(OpCode^.Raw) = Cardinal($4AFC));
              end;
              if (temp78 <> 0) then
              begin
                Instruction_ := INSTRUCTION_ILLEGAL;
              end
              else
              begin
                if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FC0)) = Cardinal($0AC0)) then
                begin
                  Instruction_ := INSTRUCTION_TAS;
                end
                else
                begin
                  if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0F00)) = Cardinal($0A00)) then
                  begin
                    Instruction_ := INSTRUCTION_TST;
                  end
                  else
                  begin
                    if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FF0)) = Cardinal($0E40)) then
                    begin
                      Instruction_ := INSTRUCTION_TRAP;
                    end
                    else
                    begin
                      if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FF8)) = Cardinal($0E50)) then
                      begin
                        Instruction_ := INSTRUCTION_LINK;
                      end
                      else
                      begin
                        if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FF8)) = Cardinal($0E58)) then
                        begin
                          Instruction_ := INSTRUCTION_UNLK;
                        end
                        else
                        begin
                          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FF0)) = Cardinal($0E60)) then
                          begin
                            Instruction_ := INSTRUCTION_MOVE_USP;
                          end
                          else
                          begin
                            if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FF8)) = Cardinal($0E70)) then
                            begin
                              case OpCode^.PrimaryRegister of
                                0:
                                  begin
                                    Instruction_ := INSTRUCTION_RESET;
                                  end;
                                1:
                                  begin
                                    Instruction_ := INSTRUCTION_NOP;
                                  end;
                                2:
                                  begin
                                    Instruction_ := INSTRUCTION_STOP;
                                  end;
                                3:
                                  begin
                                    Instruction_ := INSTRUCTION_RTE;
                                  end;
                                5:
                                  begin
                                    Instruction_ := INSTRUCTION_RTS;
                                  end;
                                6:
                                  begin
                                    Instruction_ := INSTRUCTION_TRAPV;
                                  end;
                                7:
                                  begin
                                    Instruction_ := INSTRUCTION_RTR;
                                  end;
                              end;
                            end
                            else
                            begin
                              if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FC0)) = Cardinal($0E80)) then
                              begin
                                Instruction_ := INSTRUCTION_JSR;
                              end
                              else
                              begin
                                if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0FC0)) = Cardinal($0EC0)) then
                                begin
                                  Instruction_ := INSTRUCTION_JMP;
                                end;
                              end;
                            end;
                          end;
                        end;
                      end;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    $5:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          if (Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER)) then
          begin
            Instruction_ := INSTRUCTION_DBCC;
          end
          else
          begin
            Instruction_ := INSTRUCTION_SCC;
          end;
        end
        else
        begin
          if (Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER)) then
          begin
            if (OpCode^.Bit8 <> 0) then
            begin
              temp88 := INSTRUCTION_SUBAQ;
            end
            else
            begin
              temp88 := INSTRUCTION_ADDAQ;
            end;
            Instruction_ := temp88;
          end
          else
          begin
            if (OpCode^.Bit8 <> 0) then
            begin
              temp89 := INSTRUCTION_SUBQ;
            end
            else
            begin
              temp89 := INSTRUCTION_ADDQ;
            end;
            Instruction_ := temp89;
          end;
        end;
      end;
    $6:
      begin
        if (Cardinal(OpCode^.SecondaryRegister) <> Cardinal(0)) then
        begin
          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($00FF)) = Cardinal(0)) then
          begin
            temp90 := INSTRUCTION_BCC_WORD;
          end
          else
          begin
            temp90 := INSTRUCTION_BCC_SHORT;
          end;
          Instruction_ := temp90;
        end
        else
        begin
          if (OpCode^.Bit8 <> 0) then
          begin
            if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($00FF)) = Cardinal(0)) then
            begin
              temp91 := INSTRUCTION_BSR_WORD;
            end
            else
            begin
              temp91 := INSTRUCTION_BSR_SHORT;
            end;
            Instruction_ := temp91;
          end
          else
          begin
            if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($00FF)) = Cardinal(0)) then
            begin
              temp92 := INSTRUCTION_BRA_WORD;
            end
            else
            begin
              temp92 := INSTRUCTION_BRA_SHORT;
            end;
            Instruction_ := temp92;
          end;
        end;
      end;
    $7:
      begin
        Instruction_ := INSTRUCTION_MOVEQ;
      end;
    $8:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          if (OpCode^.Bit8 <> 0) then
          begin
            Instruction_ := INSTRUCTION_DIVS;
          end
          else
          begin
            Instruction_ := INSTRUCTION_DIVU;
          end;
        end
        else
        begin
          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0170)) = Cardinal($0100)) then
          begin
            Instruction_ := INSTRUCTION_SBCD;
          end
          else
          begin
            Instruction_ := INSTRUCTION_OR;
          end;
        end;
      end;
    $9:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          Instruction_ := INSTRUCTION_SUBA;
        end
        else
        begin
          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0130)) = Cardinal($0100)) then
          begin
            Instruction_ := INSTRUCTION_SUBX;
          end
          else
          begin
            Instruction_ := INSTRUCTION_SUB;
          end;
        end;
      end;
    $A:
      begin
        Instruction_ := INSTRUCTION_UNIMPLEMENTED_1;
      end;
    $B:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          Instruction_ := INSTRUCTION_CMPA;
        end
        else
        begin
          if (not (OpCode^.Bit8 <> 0)) then
          begin
            Instruction_ := INSTRUCTION_CMP;
          end
          else
          begin
            if (Integer(OpCode^.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER)) then
            begin
              Instruction_ := INSTRUCTION_CMPM;
            end
            else
            begin
              Instruction_ := INSTRUCTION_EOR;
            end;
          end;
        end;
      end;
    $C:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          if (OpCode^.Bit8 <> 0) then
          begin
            Instruction_ := INSTRUCTION_MULS;
          end
          else
          begin
            Instruction_ := INSTRUCTION_MULU;
          end;
        end
        else
        begin
          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0130)) = Cardinal($0100)) then
          begin
            if (Cardinal(OpCode^.Bits6and7) = Cardinal(0)) then
            begin
              Instruction_ := INSTRUCTION_ABCD;
            end
            else
            begin
              Instruction_ := INSTRUCTION_EXG;
            end;
          end
          else
          begin
            Instruction_ := INSTRUCTION_AND;
          end;
        end;
      end;
    $D:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          Instruction_ := INSTRUCTION_ADDA;
        end
        else
        begin
          if (Cardinal(Cardinal(OpCode^.Raw) and Cardinal($0130)) = Cardinal($0100)) then
          begin
            Instruction_ := INSTRUCTION_ADDX;
          end
          else
          begin
            Instruction_ := INSTRUCTION_ADD;
          end;
        end;
      end;
    $E:
      begin
        if (Cardinal(OpCode^.Bits6and7) = Cardinal(3)) then
        begin
          case OpCode^.SecondaryRegister of
            0:
              begin
                Instruction_ := INSTRUCTION_ASD_MEMORY;
              end;
            1:
              begin
                Instruction_ := INSTRUCTION_LSD_MEMORY;
              end;
            2:
              begin
                Instruction_ := INSTRUCTION_ROXD_MEMORY;
              end;
            3:
              begin
                Instruction_ := INSTRUCTION_ROD_MEMORY;
              end;
          end;
        end
        else
        begin
          case (Cardinal(OpCode^.Raw) and Cardinal($0018)) of
            $0000:
              begin
                Instruction_ := INSTRUCTION_ASD_REGISTER;
              end;
            $0008:
              begin
                Instruction_ := INSTRUCTION_LSD_REGISTER;
              end;
            $0010:
              begin
                Instruction_ := INSTRUCTION_ROXD_REGISTER;
              end;
            $0018:
              begin
                Instruction_ := INSTRUCTION_ROD_REGISTER;
              end;
          end;
        end;
      end;
    $F:
      begin
        Instruction_ := INSTRUCTION_UNIMPLEMENTED_2;
      end;
  end;
  Exit(Instruction_);
end;

function DecodeOpcode(SplitOpcode: PSplitOpcode; OpCode: Cardinal): Integer;
begin
  SplitOpcode^.Raw := Cardinal(OpCode);
  SplitOpcode^.Bits6and7 := Cardinal(Cardinal(SplitOpcode^.Raw shr 6) and Cardinal(3));
  SplitOpcode^.Bit8 := Byte(Ord(Cardinal(Cardinal(SplitOpcode^.Raw) and Cardinal($100)) <> Cardinal(0)));
  SplitOpcode^.PrimaryRegister := Cardinal(Cardinal(SplitOpcode^.Raw shr 0) and Cardinal(7));
  SplitOpcode^.PrimaryAddressMode := Integer(Cardinal(SplitOpcode^.Raw shr 3) and Cardinal(7));
  SplitOpcode^.SecondaryAddressMode := Integer(Cardinal(SplitOpcode^.Raw shr 6) and Cardinal(7));
  SplitOpcode^.SecondaryRegister := Cardinal(Cardinal(SplitOpcode^.Raw shr 9) and Cardinal(7));
  Exit(GetInstruction(SplitOpcode));
end;

function ReadAddress(Stuff: PInstructionContext; Address: Cardinal): Cardinal;
begin
  Exit(Cardinal(Address));
end;

function ReadByte(Stuff: PInstructionContext; Address: Cardinal): Cardinal;
var
  Callbacks: PM68kReadWriteCallbacks;
  temp103: Integer;
begin
  Callbacks := Stuff^.Callbacks;
  var c_odd: Byte := Byte(Ord(Cardinal(Cardinal(Address) and Cardinal(1)) <> Cardinal(0)));
  if (c_odd <> 0) then
  begin
    temp103 := 0;
  end
  else
  begin
    temp103 := 8;
  end;
  Exit(Cardinal(Cardinal(Callbacks^.ReadCallback(Callbacks^.UserData, (Cardinal(Cardinal(Address) div Cardinal(2)) and Cardinal($7FFFFF)), Byte(Ord(not (c_odd <> 0))), c_odd, Stuff^.CyclesDone, @Stuff^.TerminateEarly) shr temp103) and Cardinal($FF)));
end;

function ReadWord(Stuff: PInstructionContext; Address: Cardinal): Cardinal;
var
  Callbacks: PM68kReadWriteCallbacks;
begin
  Callbacks := Stuff^.Callbacks;
  if (Cardinal(Cardinal(Address) and Cardinal(1)) <> Cardinal(0)) then
  begin
    Group0Exception(Stuff, 3, Address, 1);
  end;
  Exit(Cardinal(Callbacks^.ReadCallback(Callbacks^.UserData, (Cardinal(Cardinal(Address) div Cardinal(2)) and Cardinal($7FFFFF)), 1, 1, Stuff^.CyclesDone, @Stuff^.TerminateEarly)));
end;

function ReadLongWord(Stuff: PInstructionContext; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := 0;
  Value := Cardinal(Cardinal(Value) or Cardinal(Cardinal(ReadWord(Stuff, (Add32(Address, 0)))) shl 16));
  Value := Cardinal(Cardinal(Value) or Cardinal(Cardinal(ReadWord(Stuff, (Add32(Address, 2)))) shl 0));
  Exit(Cardinal(Value));
end;

function ReadLongWordBackwards(Stuff: PInstructionContext; Address: Cardinal): Cardinal;
begin
  var Value: Cardinal := 0;
  Value := Cardinal(Cardinal(Value) or Cardinal(Cardinal(ReadWord(Stuff, (Add32(Address, 2)))) shl 0));
  Value := Cardinal(Cardinal(Value) or Cardinal(Cardinal(ReadWord(Stuff, (Add32(Address, 0)))) shl 16));
  Exit(Cardinal(Value));
end;

procedure WriteByte(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);
var
  Callbacks: PM68kReadWriteCallbacks;
begin
  Callbacks := Stuff^.Callbacks;
  var c_odd: Byte := Byte(Ord(Cardinal(Cardinal(Address) and Cardinal(1)) <> Cardinal(0)));
  var c_byte: Cardinal := Cardinal(Cardinal(Value) and Cardinal($FF));
  Callbacks^.WriteCallback(Callbacks^.UserData, (Cardinal(Cardinal(Address) div Cardinal(2)) and Cardinal($7FFFFF)), Byte(Ord(not (c_odd <> 0))), c_odd, Stuff^.CyclesDone, @Stuff^.TerminateEarly, (Cardinal(c_byte) or Cardinal(c_byte shl 8)));
end;

procedure WriteWord(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);
var
  Callbacks: PM68kReadWriteCallbacks;
begin
  Callbacks := Stuff^.Callbacks;
  if (Cardinal(Cardinal(Address) and Cardinal(1)) <> Cardinal(0)) then
  begin
    Group0Exception(Stuff, 3, Address, 0);
  end;
  Callbacks^.WriteCallback(Callbacks^.UserData, (Cardinal(Cardinal(Address) div Cardinal(2)) and Cardinal($7FFFFF)), 1, 1, Stuff^.CyclesDone, @Stuff^.TerminateEarly, (Cardinal(Value) and Cardinal($FFFF)));
end;

procedure WriteLongWord(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);
begin
  WriteWord(Stuff, (Add32(Address, 0)), (Value shr 16));
  WriteWord(Stuff, (Add32(Address, 2)), (Value shr 0));
end;

procedure WriteLongWordBackwards(Stuff: PInstructionContext; Address: Cardinal; Value: Cardinal);
begin
  WriteWord(Stuff, (Add32(Address, 2)), (Value shr 0));
  WriteWord(Stuff, (Add32(Address, 0)), (Value shr 16));
end;

procedure SetSupervisorMode(State: PM68kState; SupervisorMode: Byte);
begin
  var Already_supervisor_mode: Byte := Byte(Ord(Integer(State^.StatusRegister and STATUS_SUPERVISOR) <> Integer(0)));
  if (SupervisorMode <> 0) then
  begin
    if (not (Already_supervisor_mode <> 0)) then
    begin
      State^.StatusRegister := Word(State^.StatusRegister or STATUS_SUPERVISOR);
      State^.UserStackPointer := Cardinal(State^.AddressRegisters[7]);
      State^.AddressRegisters[7] := Cardinal(State^.SupervisorStackPointer);
    end;
  end
  else
  begin
    if (Already_supervisor_mode <> 0) then
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not STATUS_SUPERVISOR));
      State^.SupervisorStackPointer := Cardinal(State^.AddressRegisters[7]);
      State^.AddressRegisters[7] := Cardinal(State^.UserStackPointer);
    end;
  end;
end;

procedure IncrementRegister(RegisterPointer: PCardinal; Delta: Cardinal);
begin
  RegisterPointer^ := Cardinal(Add32(RegisterPointer^, Delta));
  RegisterPointer^ := Cardinal(Cardinal(RegisterPointer^) and Cardinal($FFFFFFFF));
end;

procedure DecrementRegister(RegisterPointer: PCardinal; Delta: Cardinal);
begin
  RegisterPointer^ := Cardinal(Sub32(RegisterPointer^, Delta));
  RegisterPointer^ := Cardinal(Cardinal(RegisterPointer^) and Cardinal($FFFFFFFF));
end;

procedure IncrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);
begin
  IncrementRegister(@State^.AddressRegisters[AddressRegisterIndex], Delta);
end;

procedure DecrementAddressRegister(State: PM68kState; AddressRegisterIndex: Cardinal; Delta: Cardinal);
begin
  DecrementRegister(@State^.AddressRegisters[AddressRegisterIndex], Delta);
end;

procedure IncrementProgramCounter(State: PM68kState; Delta: Cardinal);
begin
  IncrementRegister(@State^.ProgramCounter, Delta);
end;

procedure DoInterrupt(Stuff: PInstructionContext; VectorOffset: Cardinal);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  var Copy_status_register: Word := State^.StatusRegister;
  State^.StatusRegister := Word(State^.StatusRegister and (not STATUS_TRACE));
  SetSupervisorMode(State, 1);
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], State^.ProgramCounter);
  DecrementAddressRegister(State, 7, 2);
  WriteWord(Stuff, State^.AddressRegisters[7], Copy_status_register);
  State^.ProgramCounter := Cardinal(ReadLongWord(Stuff, (Mul32(VectorOffset, 4))));
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(30));
end;

procedure Group1Or2Exception(Stuff: PInstructionContext; VectorOffset: Cardinal);
begin
  Stuff^.Exception.VectorOffset := Cardinal(VectorOffset);
  raise ECPUException.CreateCode(2);
end;

procedure Group0Exception(Stuff: PInstructionContext; VectorOffset: Cardinal; AccessAddress: Cardinal; IsARead: Byte);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (Cardinal(Cardinal(State^.AddressRegisters[7]) and Cardinal(1)) <> Cardinal(0)) then
  begin
    State^.Halted := Byte(1);
  end
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

procedure DecodeMemoryAddressMode(Stuff: PInstructionContext; DecodedMemoryAddressMode: PDecodedMemoryAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);
var
  State: PM68kState;
  Address: Cardinal;
  c_short_address: Cardinal;
  temp112: Integer;
  temp113: Integer;
  temp114: Integer;
  temp115: Integer;
  temp116: Integer;
  temp117: Integer;
  Increment_decrement_size: Cardinal;
  temp118: Integer;
  temp119: Integer;
  temp120: Integer;
  Increment_decrement_size_scope104: Cardinal;
  temp121: Integer;
  temp122: Integer;
  temp123: Integer;
  temp124: Integer;
  temp125: Integer;
  temp126: Integer;
  temp127: Integer;
  c_displacement: Cardinal;
  temp128: Integer;
  temp129: Integer;
  temp130: Integer;
  c_extension_word: Cardinal;
  Is_address_register: Byte;
  c_displacement_reg: Cardinal;
  Is_longword: Byte;
  c_displacement_literal_value: Cardinal;
  c_displacement_reg_value: Cardinal;
  temp131: Cardinal;
  temp132: Integer;
  temp133: Cardinal;
  temp134: Integer;
  temp135: Integer;
begin
  State := Stuff^.State;
  var IsLongword: Byte := Byte(Ord(Cardinal(OperationSizeInBytes) = Cardinal(4)));
  case OperationSizeInBytes of
    0:
      begin
        DecodedMemoryAddressMode^.ReadAddress := @ReadAddress;
        DecodedMemoryAddressMode^.WriteAddress := nil;
      end;
    1:
      begin
        DecodedMemoryAddressMode^.ReadAddress := @ReadByte;
        DecodedMemoryAddressMode^.WriteAddress := @WriteByte;
      end;
    2:
      begin
        DecodedMemoryAddressMode^.ReadAddress := @ReadWord;
        DecodedMemoryAddressMode^.WriteAddress := @WriteWord;
      end;
    4:
      begin
        if (Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT)) then
        begin
          DecodedMemoryAddressMode^.ReadAddress := @ReadLongWordBackwards;
          DecodedMemoryAddressMode^.WriteAddress := @WriteLongWordBackwards;
        end
        else
        begin
          DecodedMemoryAddressMode^.ReadAddress := @ReadLongWord;
          DecodedMemoryAddressMode^.WriteAddress := @WriteLongWord;
        end;
      end;
  else
    begin
      Assert(0 <> 0);
      DecodedMemoryAddressMode^.ReadAddress := @ReadByte;
      DecodedMemoryAddressMode^.WriteAddress := @WriteByte;
    end;
  end;
  var temp111: Integer := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_SPECIAL));
  if temp111 <> 0 then
  begin
    temp111 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT));
  end;
  if (temp111 <> 0) then
  begin
    c_short_address := Cardinal(ReadWord(Stuff, State^.ProgramCounter));
    Address := Cardinal(Sub32(Cardinal(c_short_address) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(c_short_address) and Cardinal(Cardinal(1) shl 15)));
    IncrementProgramCounter(State, 2);
    if (IsLongword <> 0) then
    begin
      temp112 := 12;
    end
    else
    begin
      temp112 := 8;
    end;
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp112));
  end
  else
  begin
    temp113 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_SPECIAL));
    if temp113 <> 0 then
    begin
      temp113 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG));
    end;
    if (temp113 <> 0) then
    begin
      Address := Cardinal(ReadLongWord(Stuff, State^.ProgramCounter));
      IncrementProgramCounter(State, 4);
      if (IsLongword <> 0) then
      begin
        temp114 := 16;
      end
      else
      begin
        temp114 := 12;
      end;
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp114));
    end
    else
    begin
      temp115 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_SPECIAL));
      if temp115 <> 0 then
      begin
        temp115 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE));
      end;
      if (temp115 <> 0) then
      begin
        if (Cardinal(OperationSizeInBytes) = Cardinal(1)) then
        begin
          Address := Cardinal(Add32(State^.ProgramCounter, 1));
          IncrementProgramCounter(State, 2);
        end
        else
        begin
          Address := Cardinal(State^.ProgramCounter);
          IncrementProgramCounter(State, OperationSizeInBytes);
        end;
        if (IsLongword <> 0) then
        begin
          temp116 := 8;
        end
        else
        begin
          temp116 := 4;
        end;
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp116));
      end
      else
      begin
        if (Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT)) then
        begin
          Address := Cardinal(State^.AddressRegisters[AddressModeRegister]);
          if (IsLongword <> 0) then
          begin
            temp117 := 8;
          end
          else
          begin
            temp117 := 4;
          end;
          Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp117));
        end
        else
        begin
          if (Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT)) then
          begin
            temp119 := Ord(Cardinal(AddressModeRegister) = Cardinal(7));
            if temp119 <> 0 then
            begin
              temp119 := Ord(Cardinal(OperationSizeInBytes) = Cardinal(1));
            end;
            if (temp119 <> 0) then
            begin
              temp118 := 2;
            end
            else
            begin
              temp118 := OperationSizeInBytes;
            end;
            Increment_decrement_size := Cardinal(temp118);
            DecrementAddressRegister(State, AddressModeRegister, Increment_decrement_size);
            Address := Cardinal(State^.AddressRegisters[AddressModeRegister]);
            if (IsLongword <> 0) then
            begin
              temp120 := 10;
            end
            else
            begin
              temp120 := 6;
            end;
            Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp120));
          end
          else
          begin
            if (Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT)) then
            begin
              temp122 := Ord(Cardinal(AddressModeRegister) = Cardinal(7));
              if temp122 <> 0 then
              begin
                temp122 := Ord(Cardinal(OperationSizeInBytes) = Cardinal(1));
              end;
              if (temp122 <> 0) then
              begin
                temp121 := 2;
              end
              else
              begin
                temp121 := OperationSizeInBytes;
              end;
              Increment_decrement_size_scope104 := Cardinal(temp121);
              Address := Cardinal(State^.AddressRegisters[AddressModeRegister]);
              IncrementAddressRegister(State, AddressModeRegister, Increment_decrement_size_scope104);
              if (IsLongword <> 0) then
              begin
                temp123 := 8;
              end
              else
              begin
                temp123 := 4;
              end;
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp123));
            end
            else
            begin
              temp124 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_SPECIAL));
              if temp124 <> 0 then
              begin
                temp125 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT));
                if temp125 = 0 then
                begin
                  temp125 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX));
                end;
                temp124 := Ord(temp125 <> 0);
              end;
              if (temp124 <> 0) then
              begin
                Address := Cardinal(State^.ProgramCounter);
              end
              else
              begin
                Address := Cardinal(State^.AddressRegisters[AddressModeRegister]);
              end;
              temp126 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT));
              if temp126 = 0 then
              begin
                temp127 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_SPECIAL));
                if temp127 <> 0 then
                begin
                  temp127 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT));
                end;
                temp126 := Ord(temp127 <> 0);
              end;
              if (temp126 <> 0) then
              begin
                c_displacement := Cardinal(ReadWord(Stuff, State^.ProgramCounter));
                Address := Cardinal(Add32(Address, Sub32(Cardinal(c_displacement) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(c_displacement) and Cardinal(Cardinal(1) shl 15))));
                IncrementProgramCounter(State, 2);
                if (IsLongword <> 0) then
                begin
                  temp128 := 12;
                end
                else
                begin
                  temp128 := 8;
                end;
                Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp128));
              end
              else
              begin
                temp129 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX));
                if temp129 = 0 then
                begin
                  temp130 := Ord(Integer(AddressMode) = Integer(ADDRESS_MODE_SPECIAL));
                  if temp130 <> 0 then
                  begin
                    temp130 := Ord(Cardinal(AddressModeRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX));
                  end;
                  temp129 := Ord(temp130 <> 0);
                end;
                if (temp129 <> 0) then
                begin
                  c_extension_word := Cardinal(ReadWord(Stuff, State^.ProgramCounter));
                  Is_address_register := Byte(Ord(Cardinal(Cardinal(c_extension_word) and Cardinal($8000)) <> Cardinal(0)));
                  c_displacement_reg := Cardinal(Cardinal(c_extension_word shr 12) and Cardinal(7));
                  Is_longword := Byte(Ord(Cardinal(Cardinal(c_extension_word) and Cardinal($0800)) <> Cardinal(0)));
                  c_displacement_literal_value := Cardinal(Sub32(Cardinal(c_extension_word) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(c_extension_word) and Cardinal(Cardinal(1) shl 7)));
                  if (Is_address_register <> 0) then
                  begin
                    temp131 := State^.AddressRegisters[c_displacement_reg];
                  end
                  else
                  begin
                    temp131 := State^.DataRegisters[c_displacement_reg];
                  end;
                  if (Is_longword <> 0) then
                  begin
                    temp132 := 31;
                  end
                  else
                  begin
                    temp132 := 15;
                  end;
                  if (Is_address_register <> 0) then
                  begin
                    temp133 := State^.AddressRegisters[c_displacement_reg];
                  end
                  else
                  begin
                    temp133 := State^.DataRegisters[c_displacement_reg];
                  end;
                  if (Is_longword <> 0) then
                  begin
                    temp134 := 31;
                  end
                  else
                  begin
                    temp134 := 15;
                  end;
                  c_displacement_reg_value := Cardinal(Sub32(Cardinal(temp131) and Cardinal(Sub32(Cardinal(1) shl temp132, 1)), Cardinal(temp133) and Cardinal(Cardinal(1) shl temp134)));
                  Address := Cardinal(Add32(Address, c_displacement_reg_value));
                  Address := Cardinal(Add32(Address, c_displacement_literal_value));
                  IncrementProgramCounter(State, 2);
                  if (IsLongword <> 0) then
                  begin
                    temp135 := 14;
                  end
                  else
                  begin
                    temp135 := 10;
                  end;
                  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp135));
                end;
              end;
            end;
          end;
        end;
      end;
    end;
  end;
  DecodedMemoryAddressMode^.Address := Cardinal(Cardinal(Address) and Cardinal($FFFFFFFF));
end;

procedure DecodeAddressMode(Stuff: PInstructionContext; DecodedAddressMode: PDecodedAddressMode; OperationSizeInBytes: Cardinal; AddressMode: Integer; AddressModeRegister: Cardinal);
begin
  var State := Stuff^.State;
  case AddressMode of
    ADDRESS_MODE_DATA_REGISTER, ADDRESS_MODE_ADDRESS_REGISTER:
      begin
        DecodedAddressMode^.ModeType := DECODED_ADDRESS_MODE_TYPE_REGISTER;
        if (Integer(AddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER)) then
        begin
          DecodedAddressMode^.Data.Reg.Address := @State^.AddressRegisters[AddressModeRegister];
        end
        else
        begin
          DecodedAddressMode^.Data.Reg.Address := @State^.DataRegisters[AddressModeRegister];
        end;
        DecodedAddressMode^.Data.Reg.OperationSizeBitmask := Cardinal($FFFFFFFF shr (Sub32(32, Mul32(OperationSizeInBytes, 8))));
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX, ADDRESS_MODE_SPECIAL:
      begin
        DecodedAddressMode^.ModeType := DECODED_ADDRESS_MODE_TYPE_MEMORY;
        DecodeMemoryAddressMode(Stuff, @DecodedAddressMode^.Data.Memory, OperationSizeInBytes, AddressMode, AddressModeRegister);
      end;
  end;
end;

function GetValueUsingDecodedAddressMode(Stuff: PInstructionContext; DecodedAddressMode: PDecodedAddressMode): Cardinal;
begin
  var Value: Cardinal := 0;
  var State := Stuff^.State;
  case DecodedAddressMode^.ModeType of
    DECODED_ADDRESS_MODE_TYPE_REGISTER:
      begin
        Value := Cardinal(Cardinal(DecodedAddressMode^.Data.Reg.Address^) and Cardinal(DecodedAddressMode^.Data.Reg.OperationSizeBitmask));
      end;
    DECODED_ADDRESS_MODE_TYPE_MEMORY:
      begin
        Value := Cardinal(DecodedAddressMode^.Data.Memory.ReadAddress(Stuff, DecodedAddressMode^.Data.Memory.Address));
      end;
    DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER:
      begin
        Value := Cardinal(State^.StatusRegister);
      end;
    DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER:
      begin
        Value := Cardinal(State^.StatusRegister and $FF);
      end;
  end;
  Exit(Cardinal(Value));
end;

procedure SetValueUsingDecodedAddressMode(Stuff: PInstructionContext; DecodedAddressMode: PDecodedAddressMode; Value: Cardinal);
var
  State: PM68kState;
  DestinationValue: Cardinal;
  OperationSizeBitmask: Cardinal;
begin
  State := Stuff^.State;
  case DecodedAddressMode^.ModeType of
    DECODED_ADDRESS_MODE_TYPE_REGISTER:
      begin
        DestinationValue := Cardinal(DecodedAddressMode^.Data.Reg.Address^);
        OperationSizeBitmask := Cardinal(DecodedAddressMode^.Data.Reg.OperationSizeBitmask);
        DecodedAddressMode^.Data.Reg.Address^ := Cardinal(Cardinal(Cardinal(Value) and Cardinal(OperationSizeBitmask)) or Cardinal(Cardinal(DestinationValue) and Cardinal(not OperationSizeBitmask)));
      end;
    DECODED_ADDRESS_MODE_TYPE_MEMORY:
      begin
        DecodedAddressMode^.Data.Memory.WriteAddress(Stuff, DecodedAddressMode^.Data.Memory.Address, Value);
      end;
    DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER:
      begin
        SetSupervisorMode(State, Ord(Cardinal(Cardinal(Value) and Cardinal(STATUS_SUPERVISOR)) <> Cardinal(0)));
        State^.StatusRegister := Word(Cardinal(Value) and Cardinal(STATUS_REGISTER_MASK));
      end;
    DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER:
      begin
        State^.StatusRegister := Word(Cardinal(State^.StatusRegister and (not CONDITION_CODE_REGISTER_MASK)) or Cardinal(Cardinal(Value) and Cardinal(CONDITION_CODE_REGISTER_MASK)));
      end;
  end;
end;

function IsOpcodeConditionTrue(State: PM68kState; OpCode: Cardinal): Byte;
begin
  var Carry: Byte := Byte(Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)));
  var Overflow: Byte := Byte(Ord(Integer(State^.StatusRegister and CONDITION_CODE_OVERFLOW) <> Integer(0)));
  var Zero: Byte := Byte(Ord(Integer(State^.StatusRegister and CONDITION_CODE_ZERO) <> Integer(0)));
  var Negative: Byte := Byte(Ord(Integer(State^.StatusRegister and CONDITION_CODE_NEGATIVE) <> Integer(0)));
  case (Cardinal(OpCode shr 8) and Cardinal($F)) of
    $0:
      begin
        Exit(Byte(1));
      end;
    $1:
      begin
        Exit(Byte(0));
      end;
    $2:
      begin
        var Value := Ord(not (Carry <> 0));
        if Value <> 0 then
        begin
          Value := Ord(not (Zero <> 0));
        end;
        Exit(Byte(Value));
      end;
    $3:
      begin
        var Value := Ord(Carry <> 0);
        if Value = 0 then
        begin
          Value := Ord(Zero <> 0);
        end;
        Exit(Byte(Value));
      end;
    $4:
      begin
        Exit(Byte(Ord(not (Carry <> 0))));
      end;
    $5:
      begin
        Exit(Byte(Carry));
      end;
    $6:
      begin
        Exit(Byte(Ord(not (Zero <> 0))));
      end;
    $7:
      begin
        Exit(Byte(Zero));
      end;
    $8:
      begin
        Exit(Byte(Ord(not (Overflow <> 0))));
      end;
    $9:
      begin
        Exit(Byte(Overflow));
      end;
    $A:
      begin
        Exit(Byte(Ord(not (Negative <> 0))));
      end;
    $B:
      begin
        Exit(Byte(Negative));
      end;
    $C:
      begin
        Exit(Byte(Ord(Integer(Negative) = Integer(Overflow))));
      end;
    $D:
      begin
        Exit(Byte(Ord(Integer(Negative) <> Integer(Overflow))));
      end;
    $E:
      begin
        var Value := Ord(not (Zero <> 0));
        if Value <> 0 then
        begin
          Value := Ord(Integer(Negative) = Integer(Overflow));
        end;
        Exit(Byte(Value));
      end;
    $F:
      begin
        var Value := Ord(Zero <> 0);
        if Value = 0 then
        begin
          Value := Ord(Integer(Negative) <> Integer(Overflow));
        end;
        Exit(Byte(Value));
      end;
  end;
  Assert(0 <> 0);
  Exit(Byte(0));
end;

procedure SingleOperandInstructionExecutionTimeWordOnly(Stuff: PInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal);
var
  Value: Cardinal;
begin
  if (Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER)) then
  begin
    Value := RegisterWord;
  end
  else
  begin
    Value := MemoryWord;
  end;
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Value));
end;

procedure SingleOperandInstructionExecutionTimeLongwordOnly(Stuff: PInstructionContext; RegisterLongword: Cardinal; MemoryLongword: Cardinal);
var
  Value: Cardinal;
begin
  if (Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER)) then
  begin
    Value := RegisterLongword;
  end
  else
  begin
    Value := MemoryLongword;
  end;
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Value));
end;

procedure SingleOperandInstructionExecutionTime(Stuff: PInstructionContext; RegisterWord: Cardinal; MemoryWord: Cardinal; RegisterLongword: Cardinal; MemoryLongword: Cardinal);
begin
  if (Cardinal(Stuff^.c_operation_size) = Cardinal(4)) then
  begin
    SingleOperandInstructionExecutionTimeLongwordOnly(Stuff, RegisterLongword, MemoryLongword);
  end
  else
  begin
    SingleOperandInstructionExecutionTimeWordOnly(Stuff, RegisterWord, MemoryWord);
  end;
end;

procedure SingleOperandInstructionExecutionTimeCommon(Stuff: PInstructionContext);
begin
  SingleOperandInstructionExecutionTime(Stuff, 0, 4, 2, 8);
end;

procedure ShiftRotateInstructionExecutionTimeRegister(Stuff: PInstructionContext; Count: Cardinal);
begin
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Add32(2, Mul32(2, Count))));
  if (Cardinal(Stuff^.c_operation_size) = Cardinal(4)) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
  end;
end;

procedure ShiftRotateInstructionExecutionTimeMemory(Stuff: PInstructionContext);
begin
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
end;

procedure ADDXSUBXExecutionTime(Stuff: PInstructionContext);
begin
  SingleOperandInstructionExecutionTime(Stuff, 0, 2, 4, 6);
end;

procedure StandardInstructionExecutionTime(Stuff: PInstructionContext);
var
  temp184: Integer;
  temp185: Integer;
  temp186: Integer;
begin
  SingleOperandInstructionExecutionTimeCommon(Stuff);
  case Stuff^.DestinationDecodedAddressMode.ModeType of
    DECODED_ADDRESS_MODE_TYPE_REGISTER:
      begin
        temp184 := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
        if temp184 <> 0 then
        begin
          temp185 := Ord(Integer(Stuff^.SourceDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER));
          if temp185 = 0 then
          begin
            temp186 := Ord(Integer(Stuff^.SourceDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_MEMORY));
            if temp186 <> 0 then
            begin
              temp186 := Ord(Cardinal(Stuff^.SourceDecodedAddressMode.Data.Memory.Address) = Cardinal(Sub32(Stuff^.State^.ProgramCounter, 4)));
            end;
            temp185 := Ord(temp186 <> 0);
          end;
          temp184 := Ord(temp185 <> 0);
        end;
        if (temp184 <> 0) then
        begin
          Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
        end;
      end;
    DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER, DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
      end;
  else
    begin
    end;
  end;
end;

procedure StandardInstructionExecutionTimeQuick(Stuff: PInstructionContext);
var
  temp188: Integer;
begin
  var temp187: Integer := Ord(Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER));
  if temp187 = 0 then
  begin
    temp188 := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
    if temp188 <> 0 then
    begin
      temp188 := Ord(Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER));
    end;
    temp187 := Ord(temp188 <> 0);
  end;
  if (temp187 <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
  end;
end;

procedure LEAPEAInstructionExecutionTime(Stuff: PInstructionContext);
begin
  case Stuff^.OpCode.PrimaryAddressMode of
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
      end;
    ADDRESS_MODE_SPECIAL:
      begin
        case Stuff^.OpCode.PrimaryRegister of
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT, ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG, ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
            end;
        else
          begin
          end;
        end;
      end;
  else
    begin
    end;
  end;
end;

procedure ABCDSBCDExecutionTime(Stuff: PInstructionContext);
var
  temp200: Integer;
begin
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0008)) <> Cardinal(0)) then
  begin
    temp200 := 18;
  end
  else
  begin
    temp200 := 6;
  end;
  Stuff^.CyclesLeftInInstruction := Cardinal(temp200);
end;

procedure SupervisorCheck(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (Integer(State^.StatusRegister and STATUS_SUPERVISOR) = Integer(0)) then
  begin
    Group1Or2Exception(Stuff, 8);
  end;
end;

procedure SetSizeByte(Stuff: PInstructionContext);
begin
  Stuff^.c_operation_size := Cardinal(1);
end;

procedure SetSizeWord(Stuff: PInstructionContext);
begin
  Stuff^.c_operation_size := Cardinal(2);
end;

procedure SetSizeLongword(Stuff: PInstructionContext);
begin
  Stuff^.c_operation_size := Cardinal(4);
end;

procedure SetSizeLongwordRegisterByteMemory(Stuff: PInstructionContext);
var
  temp201: Integer;
begin
  if (Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_DATA_REGISTER)) then
  begin
    temp201 := 4;
  end
  else
  begin
    temp201 := 1;
  end;
  Stuff^.c_operation_size := Cardinal(temp201);
end;

procedure SetSizeMove(Stuff: PInstructionContext);
begin
  case (Cardinal(Stuff^.OpCode.Raw) and Cardinal($3000)) of
    $0000, $1000:
      begin
        Stuff^.c_operation_size := Cardinal(1);
      end;
    $2000:
      begin
        Stuff^.c_operation_size := Cardinal(4);
      end;
    $3000:
      begin
        Stuff^.c_operation_size := Cardinal(2);
      end;
  end;
end;

procedure SetSizeExt(Stuff: PInstructionContext);
var
  temp207: Integer;
begin
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0040)) <> Cardinal(0)) then
  begin
    temp207 := 4;
  end
  else
  begin
    temp207 := 2;
  end;
  Stuff^.c_operation_size := Cardinal(temp207);
end;

procedure SetSizeStandard(Stuff: PInstructionContext);
const
  c_sizes: array[0..3] of Byte = (1, 2, 4, 4);
begin
  Stuff^.c_operation_size := Cardinal(c_sizes[Stuff^.OpCode.Bits6and7]);
end;

procedure SetMSBBitIndex(Stuff: PInstructionContext);
begin
  Stuff^.MSBBitIndex := Cardinal(Sub32(Mul32(Stuff^.c_operation_size, 8), 1));
end;

procedure DecodeSourceImmediateData(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_SPECIAL, ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE);
end;

procedure DecodeSourceDataRegisterSecondary(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_DATA_REGISTER, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeSourceImmediateDataByte(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, 1, ADDRESS_MODE_SPECIAL, ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE);
end;

procedure DecodeSourceMemoryAddressPrimary(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, 0, Stuff^.OpCode.PrimaryAddressMode, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeSourceStatusRegister(Stuff: PInstructionContext);
begin
  Stuff^.SourceDecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER;
end;

procedure DecodeSourceImmediateDataWord(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, 2, ADDRESS_MODE_SPECIAL, ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE);
end;

procedure DecodeSourceBCDX(Stuff: PInstructionContext);
var
  temp209: Integer;
begin
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0008)) <> Cardinal(0)) then
  begin
    temp209 := ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT;
  end
  else
  begin
    temp209 := ADDRESS_MODE_DATA_REGISTER;
  end;
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, Stuff^.c_operation_size, temp209, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(Stuff: PInstructionContext);
var
  temp210: Integer;
  temp211: Cardinal;
begin
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    temp210 := ADDRESS_MODE_DATA_REGISTER;
  end
  else
  begin
    temp210 := Stuff^.OpCode.PrimaryAddressMode;
  end;
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    temp211 := Stuff^.OpCode.SecondaryRegister;
  end
  else
  begin
    temp211 := Stuff^.OpCode.PrimaryRegister;
  end;
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, Stuff^.c_operation_size, temp210, temp211);
end;

procedure DecodeSourcePrimaryAddressModeSized(Stuff: PInstructionContext);
var
  temp212: Integer;
begin
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    temp212 := 4;
  end
  else
  begin
    temp212 := 2;
  end;
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, temp212, Stuff^.OpCode.PrimaryAddressMode, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeSourceAddressRegisterPrimaryPostIncrement(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeSourcePrimaryAddressMode(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, Stuff^.c_operation_size, Stuff^.OpCode.PrimaryAddressMode, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeSourcePrimaryAddressModeWord(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode, 2, Stuff^.OpCode.PrimaryAddressMode, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationDataRegisterPrimary(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_DATA_REGISTER, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationDataRegisterSecondary(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_DATA_REGISTER, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationAddressRegisterSecondary(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_ADDRESS_REGISTER, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationSecondaryAddressMode(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, Stuff^.OpCode.SecondaryAddressMode, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationBCDX(Stuff: PInstructionContext);
var
  temp213: Integer;
begin
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0008)) <> Cardinal(0)) then
  begin
    temp213 := ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT;
  end
  else
  begin
    temp213 := ADDRESS_MODE_DATA_REGISTER;
  end;
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, temp213, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(Stuff: PInstructionContext);
var
  temp214: Integer;
  temp215: Cardinal;
begin
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    temp214 := Stuff^.OpCode.PrimaryAddressMode;
  end
  else
  begin
    temp214 := ADDRESS_MODE_DATA_REGISTER;
  end;
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    temp215 := Stuff^.OpCode.PrimaryRegister;
  end
  else
  begin
    temp215 := Stuff^.OpCode.SecondaryRegister;
  end;
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, temp214, temp215);
end;

procedure DecodeDestinationAddressRegisterSecondaryFull(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, 4, ADDRESS_MODE_ADDRESS_REGISTER, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationAddressRegisterSecondaryPostIncrement(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT, Stuff^.OpCode.SecondaryRegister);
end;

procedure DecodeDestinationPrimaryAddressMode(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.c_operation_size, Stuff^.OpCode.PrimaryAddressMode, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationConditionCodeRegister(Stuff: PInstructionContext);
begin
  Stuff^.DestinationDecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER;
end;

procedure DecodeDestinationStatusRegister(Stuff: PInstructionContext);
begin
  Stuff^.DestinationDecodedAddressMode.ModeType := DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER;
end;

procedure DecodeDestinationMOVEM(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, 0, Stuff^.OpCode.PrimaryAddressMode, Stuff^.OpCode.PrimaryRegister);
end;

procedure DecodeDestinationMOVEP(Stuff: PInstructionContext);
begin
  DecodeAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, 0, ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT, Stuff^.OpCode.PrimaryRegister);
end;

procedure ReadSource(Stuff: PInstructionContext);
begin
  Stuff^.SourceValue := Cardinal(GetValueUsingDecodedAddressMode(Stuff, @Stuff^.SourceDecodedAddressMode));
end;

procedure ReadDestination(Stuff: PInstructionContext);
begin
  Stuff^.DestinationValue := Cardinal(GetValueUsingDecodedAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode));
end;

procedure WriteDestination(Stuff: PInstructionContext);
begin
  SetValueUsingDecodedAddressMode(Stuff, @Stuff^.DestinationDecodedAddressMode, Stuff^.ResultValue);
end;

procedure CarryStandardCarry(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal((Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(Stuff^.DestinationValue)) or Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) or Cardinal(Stuff^.DestinationValue)) and Cardinal(not Stuff^.ResultValue))) shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_CARRY_BIT))) and Cardinal(CONDITION_CODE_CARRY)));
end;

procedure CarryStandardBorrow(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal((Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(not Stuff^.DestinationValue)) or Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) or Cardinal(not Stuff^.DestinationValue)) and Cardinal(Stuff^.ResultValue))) shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_CARRY_BIT))) and Cardinal(CONDITION_CODE_CARRY)));
end;

procedure CarryNEG(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal((Cardinal(Stuff^.DestinationValue) or Cardinal(Stuff^.ResultValue)) shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_CARRY_BIT))) and Cardinal(CONDITION_CODE_CARRY)));
end;

procedure CarryClear(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
end;

procedure OverflowADD(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal((Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(Stuff^.DestinationValue)) and Cardinal(not Stuff^.ResultValue)) or Cardinal(Cardinal(Cardinal(not Stuff^.SourceValue) and Cardinal(not Stuff^.DestinationValue)) and Cardinal(Stuff^.ResultValue))) shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_OVERFLOW_BIT))) and Cardinal(CONDITION_CODE_OVERFLOW)));
end;

procedure OverflowSUB(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal((Cardinal(Cardinal(Cardinal(not Stuff^.SourceValue) and Cardinal(Stuff^.DestinationValue)) and Cardinal(not Stuff^.ResultValue)) or Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(not Stuff^.DestinationValue)) and Cardinal(Stuff^.ResultValue))) shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_OVERFLOW_BIT))) and Cardinal(CONDITION_CODE_OVERFLOW)));
end;

procedure OverflowNEG(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal((Cardinal(Stuff^.DestinationValue) and Cardinal(Stuff^.ResultValue)) shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_OVERFLOW_BIT))) and Cardinal(CONDITION_CODE_OVERFLOW)));
end;

procedure OverflowClear(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_OVERFLOW));
end;

procedure ZeroClearIfNonZeroUnaffectedOtherwise(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and ((not CONDITION_CODE_ZERO) or (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal($FFFFFFFF shr (Sub32(Sub32(32, Stuff^.MSBBitIndex), 1)))) = Cardinal(0)))));
end;

procedure ZeroSetIfZeroClearOtherwise(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_ZERO));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal($FFFFFFFF shr (Sub32(Sub32(32, Stuff^.MSBBitIndex), 1)))) = Cardinal(0)))));
end;

procedure NegativeSetIfNegativeClearOtherwise(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_NEGATIVE));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal(Cardinal(CONDITION_CODE_NEGATIVE) and Cardinal(Stuff^.ResultValue shr (Sub32(Stuff^.MSBBitIndex, CONDITION_CODE_NEGATIVE_BIT)))) and Cardinal(CONDITION_CODE_NEGATIVE)));
end;

procedure ExtendSetToCarry(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
end;

procedure ActionOR(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) or Cardinal(Stuff^.SourceValue));
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionAND(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal(Stuff^.SourceValue));
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionSUBCommon(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Sub32(Stuff^.DestinationValue, Stuff^.SourceValue));
end;

procedure ActionCMP(Stuff: PInstructionContext);
var
  temp216: Integer;
begin
  ActionSUBCommon(Stuff);
  if (Cardinal(Stuff^.c_operation_size) = Cardinal(4)) then
  begin
    temp216 := 2;
  end
  else
  begin
    temp216 := 0;
  end;
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp216));
end;

procedure ActionCMPI(Stuff: PInstructionContext);
begin
  ActionSUBCommon(Stuff);
  var temp217: Integer := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
  if temp217 <> 0 then
  begin
    temp217 := Ord(Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER));
  end;
  if (temp217 <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
  end;
end;

procedure ActionCMPM(Stuff: PInstructionContext);
begin
  ActionSUBCommon(Stuff);
end;

procedure ActionSUB(Stuff: PInstructionContext);
begin
  ActionSUBCommon(Stuff);
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionADDASUBACommon(Stuff: PInstructionContext);
begin
  if (not (Stuff^.OpCode.Bit8 <> 0)) then
  begin
    Stuff^.SourceValue := Cardinal(Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl 15)));
    if (Integer(Stuff^.SourceDecodedAddressMode.ModeType) <> Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER)) then
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
    end;
  end;
end;

procedure ActionCMPA(Stuff: PInstructionContext);
begin
  if (not (Stuff^.OpCode.Bit8 <> 0)) then
  begin
    Stuff^.SourceValue := Cardinal(Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl 15)));
  end;
  ActionCMP(Stuff);
end;

procedure ActionSUBA(Stuff: PInstructionContext);
begin
  ActionADDASUBACommon(Stuff);
  ActionSUB(Stuff);
end;

procedure ActionSUBQ(Stuff: PInstructionContext);
begin
  Stuff^.SourceValue := Cardinal(Add32(Cardinal(Sub32(Stuff^.OpCode.SecondaryRegister, 1)) and Cardinal(7), 1));
  ActionSUB(Stuff);
  StandardInstructionExecutionTimeQuick(Stuff);
end;

procedure ActionADD(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Add32(Stuff^.DestinationValue, Stuff^.SourceValue));
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionADDA(Stuff: PInstructionContext);
begin
  ActionADDASUBACommon(Stuff);
  ActionADD(Stuff);
end;

procedure ActionADDQ(Stuff: PInstructionContext);
begin
  Stuff^.SourceValue := Cardinal(Add32(Cardinal(Sub32(Stuff^.OpCode.SecondaryRegister, 1)) and Cardinal(7), 1));
  ActionADD(Stuff);
  StandardInstructionExecutionTimeQuick(Stuff);
end;

procedure ActionEOR(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) xor Cardinal(Stuff^.SourceValue));
  StandardInstructionExecutionTime(Stuff);
end;

procedure ActionBxxx(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  Stuff^.SourceValue := Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(Stuff^.MSBBitIndex));
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_ZERO));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord(Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal(1 shl Stuff^.SourceValue)) = Cardinal(0)))));
end;

procedure ActionBTST(Stuff: PInstructionContext);
var
  temp219: Integer;
begin
  ActionBxxx(Stuff);
  var temp218: Integer := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
  if temp218 = 0 then
  begin
    temp219 := Ord(Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_SPECIAL));
    if temp219 <> 0 then
    begin
      temp219 := Ord(Cardinal(Stuff^.OpCode.PrimaryRegister) = Cardinal(ADDRESS_MODE_REGISTER_SPECIAL_IMMEDIATE));
    end;
    temp218 := Ord(temp219 <> 0);
  end;
  if (temp218 <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
  end;
end;

procedure ActionBCHG(Stuff: PInstructionContext);
begin
  ActionBxxx(Stuff);
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) xor Cardinal(1 shl Stuff^.SourceValue));
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  var temp220: Integer := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
  if temp220 <> 0 then
  begin
    temp220 := Ord(Cardinal(Stuff^.SourceValue) < Cardinal(16));
  end;
  if (temp220 <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Sub32(Stuff^.CyclesLeftInInstruction, 2));
  end;
end;

procedure ActionBCLR(Stuff: PInstructionContext);
begin
  ActionBxxx(Stuff);
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal(not (1 shl Stuff^.SourceValue)));
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  var temp221: Integer := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
  if temp221 <> 0 then
  begin
    temp221 := Ord(Cardinal(Stuff^.SourceValue) >= Cardinal(16));
  end;
  if (temp221 <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
  end;
end;

procedure ActionBSET(Stuff: PInstructionContext);
begin
  ActionBxxx(Stuff);
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) or Cardinal(1 shl Stuff^.SourceValue));
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  var temp222: Integer := Ord(Cardinal(Stuff^.c_operation_size) = Cardinal(4));
  if temp222 <> 0 then
  begin
    temp222 := Ord(Cardinal(Stuff^.SourceValue) < Cardinal(16));
  end;
  if (temp222 <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Sub32(Stuff^.CyclesLeftInInstruction, 2));
  end;
end;

procedure ActionMOVEP(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  case Stuff^.OpCode.Bits6and7 of
    0:
      begin
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) and Cardinal(not $FFFF));
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) or Cardinal(ReadByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 0))) shl (8 * 1)));
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) or Cardinal(ReadByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 1))) shl (8 * 0)));
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
      end;
    1:
      begin
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(0);
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) or Cardinal(ReadByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 0))) shl (8 * 3)));
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) or Cardinal(ReadByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 1))) shl (8 * 2)));
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) or Cardinal(ReadByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 2))) shl (8 * 1)));
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) or Cardinal(ReadByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 3))) shl (8 * 0)));
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(12));
      end;
    2:
      begin
        WriteByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 0)), (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] shr (8 * 1)) and Cardinal($FF)));
        WriteByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 1)), (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] shr (8 * 0)) and Cardinal($FF)));
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
      end;
    3:
      begin
        WriteByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 0)), (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] shr (8 * 3)) and Cardinal($FF)));
        WriteByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 1)), (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] shr (8 * 2)) and Cardinal($FF)));
        WriteByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 2)), (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] shr (8 * 1)) and Cardinal($FF)));
        WriteByte(Stuff, (Add32(Stuff^.DestinationValue, 2 * 3)), (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] shr (8 * 0)) and Cardinal($FF)));
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(12));
      end;
  end;
end;

procedure ActionMOVEA(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl Stuff^.MSBBitIndex, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex)));
end;

procedure ActionMOVECommon(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Stuff^.SourceValue);
end;

procedure ActionMOVE(Stuff: PInstructionContext);
var
  temp228: Integer;
begin
  ActionMOVECommon(Stuff);
  if (Integer(Stuff^.SourceDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER)) then
  begin
    if (Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_REGISTER)) then
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
    end
    else
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
    end;
  end
  else
  begin
    temp228 := Ord(Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_STATUS_REGISTER));
    if temp228 = 0 then
    begin
      temp228 := Ord(Integer(Stuff^.DestinationDecodedAddressMode.ModeType) = Integer(DECODED_ADDRESS_MODE_TYPE_CONDITION_CODE_REGISTER));
    end;
    if (temp228 <> 0) then
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
    end
    else
    begin
      if (Integer(Stuff^.OpCode.SecondaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT)) then
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Sub32(Stuff^.CyclesLeftInInstruction, 2));
      end;
    end;
  end;
end;

procedure ActionLINK(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  var Address_register_contents: Cardinal := State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister];
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], Address_register_contents);
  State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(State^.AddressRegisters[7]);
  IncrementAddressRegister(State, 7, (Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl 15))));
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
end;

procedure ActionUNLK(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  var Address_register_contents: Cardinal := State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister];
  var Value: Cardinal := Cardinal(ReadLongWord(Stuff, Address_register_contents));
  State^.AddressRegisters[7] := Cardinal(Address_register_contents);
  IncrementAddressRegister(State, 7, 4);
  State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(Value);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
end;

procedure ActionNEGX(Stuff: PInstructionContext);
var
  State: PM68kState;
  temp229: Integer;
begin
  State := Stuff^.State;
  if (Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)) then
  begin
    temp229 := 1;
  end
  else
  begin
    temp229 := 0;
  end;
  Stuff^.ResultValue := Cardinal(Sub32(Sub32(0, Stuff^.DestinationValue), temp229));
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionCLR(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(0);
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionNEG(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Sub32(0, Stuff^.DestinationValue));
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionNOT(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(not Stuff^.DestinationValue);
  SingleOperandInstructionExecutionTimeCommon(Stuff);
end;

procedure ActionEXT(Stuff: PInstructionContext);
var
  temp230: Integer;
  temp231: Integer;
begin
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0040)) <> Cardinal(0)) then
  begin
    temp230 := 15;
  end
  else
  begin
    temp230 := 7;
  end;
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0040)) <> Cardinal(0)) then
  begin
    temp231 := 15;
  end
  else
  begin
    temp231 := 7;
  end;
  Stuff^.ResultValue := Cardinal(Sub32(Cardinal(Stuff^.DestinationValue) and Cardinal(Sub32(Cardinal(1) shl temp230, 1)), Cardinal(Stuff^.DestinationValue) and Cardinal(Cardinal(1) shl temp231)));
end;

procedure ActionSWAP(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Cardinal((Cardinal(Stuff^.DestinationValue) and Cardinal($0000FFFF)) shl 16) or Cardinal((Cardinal(Stuff^.DestinationValue) and Cardinal($FFFF0000)) shr 16));
end;

procedure ActionPEA(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], Stuff^.SourceValue);
  Stuff^.CyclesLeftInInstruction := Cardinal(12);
  LEAPEAInstructionExecutionTime(Stuff);
end;

procedure ActionILLEGAL(Stuff: PInstructionContext);
begin
  Group1Or2Exception(Stuff, 4);
end;

procedure ActionTAS(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_NEGATIVE or CONDITION_CODE_ZERO)));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_NEGATIVE and (0 - Ord(Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal($80)) <> Cardinal(0)))));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord(Cardinal(Stuff^.DestinationValue) = Cardinal(0)))));
  Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.DestinationValue) or Cardinal($80));
  SingleOperandInstructionExecutionTimeWordOnly(Stuff, 0, 6);
end;

procedure ActionTRAP(Stuff: PInstructionContext);
begin
  Stuff^.SourceValue := Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($F));
  DoInterrupt(Stuff, (Add32(32, Stuff^.SourceValue)));
end;

procedure ActionMOVE_USP(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal(8)) <> Cardinal(0)) then
  begin
    State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(State^.UserStackPointer);
  end
  else
  begin
    State^.UserStackPointer := Cardinal(State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister]);
  end;
end;

procedure c_ProgramCounterChanged(Stuff: PInstructionContext);
var
  State: PM68kState;
  ProgramCounter: Cardinal;
begin
  State := Stuff^.State;
  ProgramCounter := Cardinal(State^.ProgramCounter);
  if (Cardinal(Cardinal(ProgramCounter) and Cardinal(1)) <> Cardinal(0)) then
  begin
    Group0Exception(Stuff, 3, ProgramCounter, 1);
  end;
end;

procedure c_SetStatusRegister(Stuff: PInstructionContext; Value: Cardinal);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  SetSupervisorMode(State, Ord(Cardinal(Cardinal(Value) and Cardinal(STATUS_SUPERVISOR)) <> Cardinal(0)));
  State^.StatusRegister := Word(Cardinal(Value) and Cardinal(STATUS_REGISTER_MASK));
end;

procedure ActionRESET(Stuff: PInstructionContext);
begin
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(128));
end;

procedure ActionSTOP(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  c_SetStatusRegister(Stuff, Stuff^.SourceValue);
  State^.Stopped := Byte(1);
  Stuff^.CyclesLeftInInstruction := Cardinal(Sub32(Stuff^.CyclesLeftInInstruction, 4));
end;

procedure ActionRTE(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  var c_new_status: Cardinal := Cardinal(Cardinal(ReadWord(Stuff, State^.AddressRegisters[7])) and Cardinal(STATUS_REGISTER_MASK));
  IncrementAddressRegister(State, 7, 2);
  State^.ProgramCounter := Cardinal(ReadLongWord(Stuff, State^.AddressRegisters[7]));
  IncrementAddressRegister(State, 7, 4);
  c_SetStatusRegister(Stuff, c_new_status);
  c_ProgramCounterChanged(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(16));
end;

procedure ActionRTS(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.ProgramCounter := Cardinal(ReadLongWord(Stuff, State^.AddressRegisters[7]));
  IncrementAddressRegister(State, 7, 4);
  c_ProgramCounterChanged(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(12));
end;

procedure ActionTRAPV(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (Integer(State^.StatusRegister and CONDITION_CODE_OVERFLOW) <> Integer(0)) then
  begin
    DoInterrupt(Stuff, 7);
  end;
end;

procedure ActionRTR(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_REGISTER_MASK));
  State^.StatusRegister := Word(State^.StatusRegister or (Cardinal(ReadByte(Stuff, (Add32(State^.AddressRegisters[7], 1)))) and Cardinal(CONDITION_CODE_REGISTER_MASK)));
  IncrementAddressRegister(State, 7, 2);
  State^.ProgramCounter := Cardinal(ReadLongWord(Stuff, State^.AddressRegisters[7]));
  IncrementAddressRegister(State, 7, 4);
  c_ProgramCounterChanged(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(16));
end;

procedure ActionJMP(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  State^.ProgramCounter := Cardinal(Stuff^.SourceValue);
  c_ProgramCounterChanged(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(8);
  case Stuff^.OpCode.PrimaryAddressMode of
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
      end;
    ADDRESS_MODE_SPECIAL:
      begin
        case Stuff^.OpCode.PrimaryRegister of
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT, ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
            end;
        else
          begin
          end;
        end;
      end;
  else
    begin
    end;
  end;
end;

procedure ActionJSR(Stuff: PInstructionContext);
var
  State: PM68kState;
  ProgramCounter: Cardinal;
begin
  State := Stuff^.State;
  ProgramCounter := Cardinal(State^.ProgramCounter);
  ActionJMP(Stuff);
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], ProgramCounter);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
end;

procedure ActionLEA(Stuff: PInstructionContext);
begin
  ActionMOVECommon(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(4);
  LEAPEAInstructionExecutionTime(Stuff);
end;

procedure ActionTST(Stuff: PInstructionContext);
begin
  ActionMOVECommon(Stuff);
end;

procedure ActionMOVEM(Stuff: PInstructionContext);
var
  State: PM68kState;
  Address_delta: Integer;
  c_write_function: TWriteAddress;
  temp243: Integer;
begin
  State := Stuff^.State;
  var c_memory_address: Cardinal := Stuff^.DestinationValue;
  var c_memory_to_register: Byte := Byte(Ord(Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0400)) <> Cardinal(0)));
  var Is_longword: Byte := Byte(Ord(Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0040)) <> Cardinal(0)));
  if (Is_longword <> 0) then
  begin
    temp243 := 8;
  end
  else
  begin
    temp243 := 4;
  end;
  var Cycle_delta: Cardinal := temp243;
  Stuff^.CyclesLeftInInstruction := Cardinal(8);
  if (c_memory_to_register <> 0) then
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  end;
  case Stuff^.OpCode.PrimaryAddressMode of
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_DISPLACEMENT:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
      end;
    ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_INDEX:
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
      end;
    ADDRESS_MODE_SPECIAL:
      begin
        case Stuff^.OpCode.PrimaryRegister of
          ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_DISPLACEMENT:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_PROGRAM_COUNTER_WITH_INDEX:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_SHORT:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
            end;
          ADDRESS_MODE_REGISTER_SPECIAL_ABSOLUTE_LONG:
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
            end;
        else
          begin
          end;
        end;
      end;
  else
    begin
    end;
  end;
  if (Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT)) then
  begin
    if (Is_longword <> 0) then
    begin
      Address_delta := Integer(-4);
      c_write_function := @WriteLongWordBackwards;
    end
    else
    begin
      Address_delta := Integer(-2);
      c_write_function := @WriteWord;
    end;
  end
  else
  begin
    if (Is_longword <> 0) then
    begin
      Address_delta := Integer(4);
      c_write_function := @WriteLongWord;
    end
    else
    begin
      Address_delta := Integer(2);
      c_write_function := @WriteWord;
    end;
  end;
  var c_bitfield: Cardinal := Stuff^.SourceValue;
  var I: Cardinal := 0;
  while (Cardinal(I) < Cardinal(8)) do
  begin
    if (Cardinal(Cardinal(c_bitfield) and Cardinal(1)) <> Cardinal(0)) then
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Cycle_delta));
      if (c_memory_to_register <> 0) then
      begin
        if (Is_longword <> 0) then
        begin
          State^.DataRegisters[I] := Cardinal(ReadLongWord(Stuff, c_memory_address));
        end
        else
        begin
          State^.DataRegisters[I] := Cardinal(Sub32(Cardinal(ReadWord(Stuff, c_memory_address)) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(ReadWord(Stuff, c_memory_address)) and Cardinal(Cardinal(1) shl 15)));
        end;
      end
      else
      begin
        if (Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT)) then
        begin
          c_write_function(Stuff, (Add32(c_memory_address, Cardinal(Address_delta))), State^.AddressRegisters[(Sub32(7, I))]);
        end
        else
        begin
          c_write_function(Stuff, c_memory_address, State^.DataRegisters[I]);
        end;
      end;
      c_memory_address := Cardinal(Add32(c_memory_address, Cardinal(Address_delta)));
      c_memory_address := Cardinal(Cardinal(c_memory_address) and Cardinal($FFFFFFFF));
    end;
    c_bitfield := Cardinal(c_bitfield shr 1);
    Inc(I);
  end;
  I := Cardinal(0);
  while (Cardinal(I) < Cardinal(8)) do
  begin
    if (Cardinal(Cardinal(c_bitfield) and Cardinal(1)) <> Cardinal(0)) then
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Cycle_delta));
      if (c_memory_to_register <> 0) then
      begin
        if (Is_longword <> 0) then
        begin
          State^.AddressRegisters[I] := Cardinal(ReadLongWord(Stuff, c_memory_address));
        end
        else
        begin
          State^.AddressRegisters[I] := Cardinal(Cardinal(Sub32(Cardinal(ReadWord(Stuff, c_memory_address)) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(ReadWord(Stuff, c_memory_address)) and Cardinal(Cardinal(1) shl 15))) and Cardinal($FFFFFFFF));
        end;
      end
      else
      begin
        if (Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT)) then
        begin
          c_write_function(Stuff, (Add32(c_memory_address, Cardinal(Address_delta))), State^.DataRegisters[(Sub32(7, I))]);
        end
        else
        begin
          c_write_function(Stuff, c_memory_address, State^.AddressRegisters[I]);
        end;
      end;
      c_memory_address := Cardinal(Add32(c_memory_address, Cardinal(Address_delta)));
      c_memory_address := Cardinal(Cardinal(c_memory_address) and Cardinal($FFFFFFFF));
    end;
    c_bitfield := Cardinal(c_bitfield shr 1);
    Inc(I);
  end;
  var temp259: Integer := Ord(Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_PREDECREMENT));
  if temp259 = 0 then
  begin
    temp259 := Ord(Integer(Stuff^.OpCode.PrimaryAddressMode) = Integer(ADDRESS_MODE_ADDRESS_REGISTER_INDIRECT_WITH_POSTINCREMENT));
  end;
  if (temp259 <> 0) then
  begin
    State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(c_memory_address);
  end;
end;

procedure ActionCHK(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  var Value: Cardinal := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) and Cardinal($FFFF));
  State^.StatusRegister := Word(State^.StatusRegister and (not (((CONDITION_CODE_NEGATIVE or CONDITION_CODE_CARRY) or CONDITION_CODE_OVERFLOW) or CONDITION_CODE_ZERO)));
  if (Cardinal(Cardinal(Value) and Cardinal($8000)) <> Cardinal(0)) then
  begin
    State^.StatusRegister := Word(State^.StatusRegister or CONDITION_CODE_NEGATIVE);
    DoInterrupt(Stuff, 6);
  end
  else
  begin
    if (Cardinal(Cardinal(Value) xor Cardinal($8000)) > Cardinal(Cardinal(Stuff^.SourceValue) xor Cardinal($8000))) then
    begin
      DoInterrupt(Stuff, 6);
    end;
  end;
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
end;

procedure ActionSCC(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (IsOpcodeConditionTrue(State, Stuff^.OpCode.Raw) <> 0) then
  begin
    Stuff^.ResultValue := Cardinal($FF);
    SingleOperandInstructionExecutionTimeWordOnly(Stuff, 2, 4);
  end
  else
  begin
    Stuff^.ResultValue := Cardinal(0);
    SingleOperandInstructionExecutionTimeWordOnly(Stuff, 0, 4);
  end;
end;

procedure ActionBRASHORT(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  IncrementProgramCounter(State, (Sub32(Cardinal(Stuff^.OpCode.Raw) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(Stuff^.OpCode.Raw) and Cardinal(Cardinal(1) shl 7))));
  c_ProgramCounterChanged(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
end;

procedure ActionBRAWORD(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  IncrementProgramCounter(State, (Sub32(Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl 15)), 2)));
  c_ProgramCounterChanged(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
end;

procedure ActionBSRSHORT(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], State^.ProgramCounter);
  ActionBRASHORT(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
end;

procedure ActionBSRWORD(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  DecrementAddressRegister(State, 7, 4);
  WriteLongWordBackwards(Stuff, State^.AddressRegisters[7], State^.ProgramCounter);
  ActionBRAWORD(Stuff);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(8));
end;

procedure ActionBCCSHORT(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (IsOpcodeConditionTrue(State, Stuff^.OpCode.Raw) <> 0) then
  begin
    ActionBRASHORT(Stuff);
  end
  else
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  end;
end;

procedure ActionBCCWORD(Stuff: PInstructionContext);
var
  State: PM68kState;
begin
  State := Stuff^.State;
  if (IsOpcodeConditionTrue(State, Stuff^.OpCode.Raw) <> 0) then
  begin
    ActionBRAWORD(Stuff);
  end
  else
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  end;
end;

procedure ActionDBCC(Stuff: PInstructionContext);
var
  State: PM68kState;
  c_loop_counter: Cardinal;
  temp260: Cardinal;
begin
  State := Stuff^.State;
  if (not (IsOpcodeConditionTrue(State, Stuff^.OpCode.Raw) <> 0)) then
  begin
    c_loop_counter := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.PrimaryRegister]) and Cardinal($FFFF));
    temp260 := c_loop_counter;
    Dec(c_loop_counter);
    if (Cardinal(temp260) <> Cardinal(0)) then
    begin
      ActionBRAWORD(Stuff);
    end
    else
    begin
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
    end;
    State^.DataRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.PrimaryRegister]) and Cardinal(not $FFFF));
    State^.DataRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(Cardinal(State^.DataRegisters[Stuff^.OpCode.PrimaryRegister]) or Cardinal(Cardinal(c_loop_counter) and Cardinal($FFFF)));
  end
  else
  begin
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
  end;
end;

procedure ActionMOVEQ(Stuff: PInstructionContext);
begin
  Stuff^.ResultValue := Cardinal(Sub32(Cardinal(Stuff^.OpCode.Raw) and Cardinal(Sub32(Cardinal(1) shl 7, 1)), Cardinal(Stuff^.OpCode.Raw) and Cardinal(Cardinal(1) shl 7)));
end;

function CountBitsSet(Value: Cardinal): Cardinal;
begin
  var c_total_bits_set: Cardinal := 0;
  while (Cardinal(Value) <> Cardinal(0)) do
  begin
    Value := Cardinal(Cardinal(Value) and Cardinal(Sub32(Value, 1)));
    Inc(c_total_bits_set);
  end;
  Exit(Cardinal(c_total_bits_set));
end;

procedure ActionDIVCommon(Stuff: PInstructionContext; IsSigned: Byte);
var
  State: PM68kState;
  c_source_is_negative: Byte;
  temp263: Integer;
  c_destination_is_negative: Byte;
  temp264: Integer;
  c_result_is_negative: Byte;
  Absolute_source_value: Cardinal;
  temp265: Cardinal;
  Absolute_destination_value: Cardinal;
  temp266: Cardinal;
  temp267: Integer;
  Absolute_quotient: Cardinal;
  c_shifted_divisor: Cardinal;
  c_working_dividend: Cardinal;
  I: Cardinal;
  c_high_bit_set: Byte;
  temp270: Integer;
  temp271: Cardinal;
  Absolute_remainder: Cardinal;
  c_quotient: Cardinal;
  temp272: Cardinal;
  c_remainder: Cardinal;
  temp273: Cardinal;
begin
  State := Stuff^.State;
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  if (Cardinal(Stuff^.SourceValue) = Cardinal(0)) then
  begin
    State^.StatusRegister := Word(State^.StatusRegister and (not ((CONDITION_CODE_NEGATIVE or CONDITION_CODE_ZERO) or CONDITION_CODE_OVERFLOW)));
    Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
    DoInterrupt(Stuff, 5);
  end
  else
  begin
    temp263 := Ord(IsSigned <> 0);
    if temp263 <> 0 then
    begin
      temp263 := Ord(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal($8000)) <> Cardinal(0));
    end;
    c_source_is_negative := Byte(temp263);
    temp264 := Ord(IsSigned <> 0);
    if temp264 <> 0 then
    begin
      temp264 := Ord(Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal($80000000)) <> Cardinal(0));
    end;
    c_destination_is_negative := Byte(temp264);
    c_result_is_negative := Byte(Ord(Integer(c_source_is_negative) <> Integer(c_destination_is_negative)));
    if (c_source_is_negative <> 0) then
    begin
      temp265 := (Sub32(0, Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl 15))));
    end
    else
    begin
      temp265 := Stuff^.SourceValue;
    end;
    Absolute_source_value := Cardinal(temp265);
    if (c_destination_is_negative <> 0) then
    begin
      temp266 := (Sub32(0, Sub32(Cardinal(Stuff^.DestinationValue) and Cardinal(Sub32(Cardinal(1) shl 31, 1)), Cardinal(Stuff^.DestinationValue) and Cardinal(Cardinal(1) shl 31))));
    end
    else
    begin
      temp266 := Stuff^.DestinationValue;
    end;
    Absolute_destination_value := Cardinal(temp266);
    Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(6));
    if (IsSigned <> 0) then
    begin
      if (c_destination_is_negative <> 0) then
      begin
        temp267 := 8;
      end
      else
      begin
        temp267 := 6;
      end;
      Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(temp267));
    end;
    if (Cardinal(Absolute_source_value) > Cardinal(Absolute_destination_value shr 16)) then
    begin
      Absolute_quotient := Cardinal(Cardinal(Absolute_destination_value) div Cardinal(Absolute_source_value));
      if (IsSigned <> 0) then
      begin
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(104));
        if (c_source_is_negative <> 0) then
        begin
          Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
        end
        else
        begin
          if (c_destination_is_negative <> 0) then
          begin
            Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(4));
          end;
        end;
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Mul32(Sub32(15, CountBitsSet(Absolute_quotient shr 1)), 2)));
      end
      else
      begin
        c_shifted_divisor := Cardinal((Cardinal(Absolute_source_value) and Cardinal($FFFF)) shl 16);
        c_working_dividend := Cardinal(Absolute_destination_value);
        Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(66));
        I := Cardinal(0);
        while (Cardinal(I) < Cardinal(15)) do
        begin
          c_high_bit_set := Byte(Ord(Cardinal(Cardinal(c_working_dividend) and Cardinal($80000000)) <> Cardinal(0)));
          c_working_dividend := Cardinal(c_working_dividend shl 1);
          if (not (c_high_bit_set <> 0)) then
          begin
            Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
            if (Cardinal(c_working_dividend) < Cardinal(c_shifted_divisor)) then
            begin
              Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
              Inc(I);
              Continue;
            end;
          end;
          c_working_dividend := Cardinal(Sub32(c_working_dividend, c_shifted_divisor));
          Inc(I);
        end;
      end;
      temp270 := Ord(not (IsSigned <> 0));
      if temp270 = 0 then
      begin
        if (c_result_is_negative <> 0) then
        begin
          temp271 := $8000;
        end
        else
        begin
          temp271 := $7FFF;
        end;
        temp270 := Ord(Cardinal(Absolute_quotient) <= Cardinal(temp271));
      end;
      if (temp270 <> 0) then
      begin
        Absolute_remainder := Cardinal(Cardinal(Absolute_destination_value) mod Cardinal(Absolute_source_value));
        if (c_result_is_negative <> 0) then
        begin
          temp272 := (Sub32(0, Absolute_quotient));
        end
        else
        begin
          temp272 := Absolute_quotient;
        end;
        c_quotient := Cardinal(temp272);
        if (c_destination_is_negative <> 0) then
        begin
          temp273 := (Sub32(0, Absolute_remainder));
        end
        else
        begin
          temp273 := Absolute_remainder;
        end;
        c_remainder := Cardinal(temp273);
        Stuff^.ResultValue := Cardinal(Cardinal(Cardinal(c_quotient) and Cardinal($FFFF)) or Cardinal((Cardinal(c_remainder) and Cardinal($FFFF)) shl 16));
        State^.StatusRegister := Word(State^.StatusRegister and (not ((CONDITION_CODE_NEGATIVE or CONDITION_CODE_ZERO) or CONDITION_CODE_OVERFLOW)));
        State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_NEGATIVE and (0 - Ord(Cardinal(Cardinal(c_quotient) and Cardinal($8000)) <> Cardinal(0)))));
        State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_ZERO and (0 - Ord(Cardinal(c_quotient) = Cardinal(0)))));
        Exit;
      end;
    end;
    State^.StatusRegister := Word(State^.StatusRegister or CONDITION_CODE_OVERFLOW);
    State^.StatusRegister := Word(State^.StatusRegister or CONDITION_CODE_NEGATIVE);
    State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_ZERO));
    Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  end;
end;

procedure ActionDIVS(Stuff: PInstructionContext);
begin
  ActionDIVCommon(Stuff, 1);
end;

procedure ActionDIVU(Stuff: PInstructionContext);
begin
  ActionDIVCommon(Stuff, 0);
end;

procedure ActionSUBXCommon(Stuff: PInstructionContext);
var
  State: PM68kState;
  temp274: Integer;
begin
  State := Stuff^.State;
  if (Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)) then
  begin
    temp274 := 1;
  end
  else
  begin
    temp274 := 0;
  end;
  Stuff^.ResultValue := Cardinal(Sub32(Sub32(Stuff^.DestinationValue, Stuff^.SourceValue), temp274));
end;

procedure ActionSUBX(Stuff: PInstructionContext);
begin
  ActionSUBXCommon(Stuff);
  ADDXSUBXExecutionTime(Stuff);
end;

procedure ActionSBCDCommon(Stuff: PInstructionContext);
var
  State: PM68kState;
  temp275: Integer;
begin
  State := Stuff^.State;
  ActionSUBXCommon(Stuff);
  Stuff^.SourceValue := Cardinal((Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(not Stuff^.DestinationValue)) or Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) or Cardinal(not Stuff^.DestinationValue)) and Cardinal(Stuff^.ResultValue))) and Cardinal($88)) shl 1);
  Stuff^.SourceValue := Cardinal(Cardinal(Stuff^.SourceValue shr 2) or Cardinal(Stuff^.SourceValue shr 3));
  Stuff^.DestinationValue := Cardinal(Stuff^.ResultValue);
  ActionSUBCommon(Stuff);
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  var temp276: Integer := Ord(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal($40)) <> Cardinal(0));
  if temp276 = 0 then
  begin
    temp276 := Ord(Cardinal(Cardinal(Cardinal(not Stuff^.DestinationValue) and Cardinal(Stuff^.ResultValue)) and Cardinal($80)) <> Cardinal(0));
  end;
  if (temp276 <> 0) then
  begin
    temp275 := CONDITION_CODE_CARRY;
  end
  else
  begin
    temp275 := 0;
  end;
  State^.StatusRegister := Word(State^.StatusRegister or temp275);
end;

procedure ActionSBCD(Stuff: PInstructionContext);
begin
  ActionSBCDCommon(Stuff);
  ABCDSBCDExecutionTime(Stuff);
end;

procedure ActionNBCD(Stuff: PInstructionContext);
begin
  Stuff^.SourceValue := Cardinal(Stuff^.DestinationValue);
  Stuff^.DestinationValue := Cardinal(0);
  ActionSBCDCommon(Stuff);
  SingleOperandInstructionExecutionTimeWordOnly(Stuff, 2, 4);
end;

procedure ActionMULCommon(Stuff: PInstructionContext; IsSigned: Byte; TotalOperations: Cardinal);
var
  temp279: Cardinal;
  temp280: Cardinal;
  temp281: Cardinal;
begin
  var temp277: Integer := Ord(IsSigned <> 0);
  if temp277 <> 0 then
  begin
    temp277 := Ord(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal($8000)) <> Cardinal(0));
  end;
  var c_multiplier_is_negative: Byte := temp277;
  var temp278: Integer := Ord(IsSigned <> 0);
  if temp278 <> 0 then
  begin
    temp278 := Ord(Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal($8000)) <> Cardinal(0));
  end;
  var c_multiplicand_is_negative: Byte := temp278;
  var c_result_is_negative: Byte := Byte(Ord(Integer(c_multiplier_is_negative) <> Integer(c_multiplicand_is_negative)));
  if (c_multiplier_is_negative <> 0) then
  begin
    temp279 := (Sub32(0, Sub32(Cardinal(Stuff^.SourceValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.SourceValue) and Cardinal(Cardinal(1) shl 15))));
  end
  else
  begin
    temp279 := Stuff^.SourceValue;
  end;
  var c_multiplier: Cardinal := temp279;
  if (c_multiplicand_is_negative <> 0) then
  begin
    temp280 := (Sub32(0, Sub32(Cardinal(Stuff^.DestinationValue) and Cardinal(Sub32(Cardinal(1) shl 15, 1)), Cardinal(Stuff^.DestinationValue) and Cardinal(Cardinal(1) shl 15))));
  end
  else
  begin
    temp280 := (Cardinal(Stuff^.DestinationValue) and Cardinal($FFFF));
  end;
  var c_multiplicand: Cardinal := temp280;
  var Absolute_result: Cardinal := Cardinal(Mul32(c_multiplicand, c_multiplier));
  if (c_result_is_negative <> 0) then
  begin
    temp281 := (Sub32(0, Absolute_result));
  end
  else
  begin
    temp281 := Absolute_result;
  end;
  Stuff^.ResultValue := Cardinal(temp281);
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(Add32(34, Mul32(TotalOperations, 2))));
end;

procedure ActionMULS(Stuff: PInstructionContext);
begin
  var c_shifted_source_value: Cardinal := Stuff^.SourceValue shl 1;
  var c_total_10_patterns: Cardinal := Cardinal(CountBitsSet(Cardinal(Cardinal(c_shifted_source_value) xor Cardinal(c_shifted_source_value shl 1)) and Cardinal($AAAA shl 1)));
  var c_total_01_patterns: Cardinal := Cardinal(CountBitsSet(Cardinal(Cardinal(c_shifted_source_value) xor Cardinal(c_shifted_source_value shr 1)) and Cardinal(ArithmeticShiftRight(Integer($AAAA), 1))));
  ActionMULCommon(Stuff, 1, (Add32(c_total_10_patterns, c_total_01_patterns)));
end;

procedure ActionMULU(Stuff: PInstructionContext);
begin
  ActionMULCommon(Stuff, 0, CountBitsSet(Stuff^.SourceValue));
end;

procedure ActionADDX(Stuff: PInstructionContext);
var
  State: PM68kState;
  temp282: Integer;
begin
  State := Stuff^.State;
  if (Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)) then
  begin
    temp282 := 1;
  end
  else
  begin
    temp282 := 0;
  end;
  Stuff^.ResultValue := Cardinal(Add32(Add32(Stuff^.DestinationValue, Stuff^.SourceValue), temp282));
  ADDXSUBXExecutionTime(Stuff);
end;

procedure ActionABCD(Stuff: PInstructionContext);
var
  State: PM68kState;
  temp283: Integer;
begin
  State := Stuff^.State;
  ActionADDX(Stuff);
  Stuff^.SourceValue := Cardinal((Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal(Stuff^.DestinationValue)) or Cardinal(Cardinal(Cardinal(Stuff^.SourceValue) or Cardinal(Stuff^.DestinationValue)) and Cardinal(not Stuff^.ResultValue))) and Cardinal($88)) shl 1);
  Stuff^.SourceValue := Cardinal(Cardinal(Stuff^.SourceValue) or Cardinal(Cardinal(Cardinal(Add32(Stuff^.ResultValue, $66)) xor Cardinal(Stuff^.ResultValue)) and Cardinal($110)));
  Stuff^.SourceValue := Cardinal(Cardinal(Stuff^.SourceValue shr 2) or Cardinal(Stuff^.SourceValue shr 3));
  Stuff^.DestinationValue := Cardinal(Stuff^.ResultValue);
  ActionADD(Stuff);
  ABCDSBCDExecutionTime(Stuff);
  State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
  var temp284: Integer := Ord(Cardinal(Cardinal(Stuff^.SourceValue) and Cardinal($40)) <> Cardinal(0));
  if temp284 = 0 then
  begin
    temp284 := Ord(Cardinal(Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal(not Stuff^.ResultValue)) and Cardinal($80)) <> Cardinal(0));
  end;
  if (temp284 <> 0) then
  begin
    temp283 := CONDITION_CODE_CARRY;
  end
  else
  begin
    temp283 := 0;
  end;
  State^.StatusRegister := Word(State^.StatusRegister or temp283);
end;

procedure ActionEXG(Stuff: PInstructionContext);
var
  State: PM68kState;
  c_temp: Cardinal;
begin
  State := Stuff^.State;
  case (Cardinal(Stuff^.OpCode.Raw) and Cardinal($00F8)) of
    $0040:
      begin
        c_temp := Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]);
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(State^.DataRegisters[Stuff^.OpCode.PrimaryRegister]);
        State^.DataRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(c_temp);
      end;
    $0048:
      begin
        c_temp := Cardinal(State^.AddressRegisters[Stuff^.OpCode.SecondaryRegister]);
        State^.AddressRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister]);
        State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(c_temp);
      end;
    $0088:
      begin
        c_temp := Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]);
        State^.DataRegisters[Stuff^.OpCode.SecondaryRegister] := Cardinal(State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister]);
        State^.AddressRegisters[Stuff^.OpCode.PrimaryRegister] := Cardinal(c_temp);
      end;
  end;
  Stuff^.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff^.CyclesLeftInInstruction) + Cardinal(2));
end;

procedure ActionASDMEMORY(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  var c_original_sign_bit: Cardinal := Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal(c_sign_bit_bitmask));
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  var Count: Cardinal := 1;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shl 1);
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_OVERFLOW and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(c_original_sign_bit)))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shr 1);
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue) or Cardinal(c_original_sign_bit));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionASDREGISTER(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
  temp293: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  var c_original_sign_bit: Cardinal := Cardinal(Cardinal(Stuff^.DestinationValue) and Cardinal(c_sign_bit_bitmask));
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0020)) <> Cardinal(0)) then
  begin
    temp293 := (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) mod Cardinal(64));
  end
  else
  begin
    temp293 := (Add32(Cardinal(Sub32(Stuff^.OpCode.SecondaryRegister, 1)) and Cardinal(7), 1));
  end;
  var Count: Cardinal := temp293;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shl 1);
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_OVERFLOW and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(c_original_sign_bit)))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shr 1);
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue) or Cardinal(c_original_sign_bit));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionLSDMEMORY(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  var Count: Cardinal := 1;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shl 1);
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shr 1);
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionLSDREGISTER(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
  temp302: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0020)) <> Cardinal(0)) then
  begin
    temp302 := (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) mod Cardinal(64));
  end
  else
  begin
    temp302 := (Add32(Cardinal(Sub32(Stuff^.OpCode.SecondaryRegister, 1)) and Cardinal(7), 1));
  end;
  var Count: Cardinal := temp302;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shl 1);
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shr 1);
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionRODMEMORY(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  var Count: Cardinal := 1;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue shl 1) or Cardinal(Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue shr 1) or Cardinal(Cardinal(c_sign_bit_bitmask) and Cardinal(0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionRODREGISTER(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
  temp311: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0020)) <> Cardinal(0)) then
  begin
    temp311 := (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) mod Cardinal(64));
  end
  else
  begin
    temp311 := (Add32(Cardinal(Sub32(Stuff^.OpCode.SecondaryRegister, 1)) and Cardinal(7), 1));
  end;
  var Count: Cardinal := temp311;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue shl 1) or Cardinal(Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue shr 1) or Cardinal(Cardinal(c_sign_bit_bitmask) and Cardinal(0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionROXDMEMORY(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  var Count: Cardinal := 1;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)))));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shl 1);
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue) or Cardinal(Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shr 1);
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue) or Cardinal(Cardinal(c_sign_bit_bitmask) and Cardinal(0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeMemory(Stuff);
end;

procedure ActionROXDREGISTER(Stuff: PInstructionContext);
var
  State: PM68kState;
  I: Cardinal;
  temp320: Cardinal;
begin
  State := Stuff^.State;
  var c_sign_bit_bitmask: Cardinal := Cardinal(Cardinal(1) shl Stuff^.MSBBitIndex);
  Stuff^.ResultValue := Cardinal(Stuff^.DestinationValue);
  if (Cardinal(Cardinal(Stuff^.OpCode.Raw) and Cardinal($0020)) <> Cardinal(0)) then
  begin
    temp320 := (Cardinal(State^.DataRegisters[Stuff^.OpCode.SecondaryRegister]) mod Cardinal(64));
  end
  else
  begin
    temp320 := (Add32(Cardinal(Sub32(Stuff^.OpCode.SecondaryRegister, 1)) and Cardinal(7), 1));
  end;
  var Count: Cardinal := temp320;
  State^.StatusRegister := Word(State^.StatusRegister and (not (CONDITION_CODE_OVERFLOW or CONDITION_CODE_CARRY)));
  State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)))));
  if (Stuff^.OpCode.Bit8 <> 0) then
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(c_sign_bit_bitmask)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shl 1);
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue) or Cardinal(Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end
  else
  begin
    I := Cardinal(0);
    while (Cardinal(I) < Cardinal(Count)) do
    begin
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_CARRY));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_CARRY and (0 - Ord(Cardinal(Cardinal(Stuff^.ResultValue) and Cardinal(1)) <> Cardinal(0)))));
      Stuff^.ResultValue := Cardinal(Stuff^.ResultValue shr 1);
      Stuff^.ResultValue := Cardinal(Cardinal(Stuff^.ResultValue) or Cardinal(Cardinal(c_sign_bit_bitmask) and Cardinal(0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_EXTEND) <> Integer(0)))));
      State^.StatusRegister := Word(State^.StatusRegister and (not CONDITION_CODE_EXTEND));
      State^.StatusRegister := Word(State^.StatusRegister or (CONDITION_CODE_EXTEND and (0 - Ord(Integer(State^.StatusRegister and CONDITION_CODE_CARRY) <> Integer(0)))));
      Inc(I);
    end;
  end;
  ShiftRotateInstructionExecutionTimeRegister(Stuff, Count);
end;

procedure ActionUNIMPLEMENTED1(Stuff: PInstructionContext);
begin
  Group1Or2Exception(Stuff, 10);
end;

procedure ActionUNIMPLEMENTED2(Stuff: PInstructionContext);
begin
  Group1Or2Exception(Stuff, 11);
end;

procedure ActionNOP(Stuff: PInstructionContext);
begin
end;

procedure Clown68000Reset(State: PM68kState; Callbacks: PM68kReadWriteCallbacks);
begin
  var Stuff: TInstructionContext := Default(TInstructionContext);
  Stuff.State := State;
  Stuff.Callbacks := Callbacks;
  try
    State^.Halted := Byte(0);
    State^.Stopped := Byte(0);
    State^.PendingInterrupt := Byte(0);
    State^.StatusRegister := Word(State^.StatusRegister and (not STATUS_TRACE));
    State^.StatusRegister := Word(State^.StatusRegister or $0700);
    SetSupervisorMode(State, 1);
    State^.AddressRegisters[7] := Cardinal(ReadLongWord(@Stuff, 0));
    State^.ProgramCounter := Cardinal(ReadLongWord(@Stuff, 4));
  except
    on E: ECPUException do
      State^.Halted := 1;
  end;
end;

procedure Clown68000Interrupt(State: PM68kState; Level: Cardinal);
begin
  Assert(Cardinal(Level) <= Cardinal(7));
  State^.PendingInterrupt := Byte(Level);
end;

function Clown68000DoCycles(State: PM68kState; Callbacks: PM68kReadWriteCallbacks; CyclesToDo: Cardinal): Cardinal;
var
  temp330: Integer;
  PendingInterrupt: Cardinal;
  Instruction_: Integer;
  temp427: Integer;
begin
  if (State^.Halted <> 0) then
  begin
    Exit(Cardinal(CyclesToDo));
  end;
  var Stuff: TInstructionContext := Default(TInstructionContext);
  Stuff.State := State;
  Stuff.Callbacks := Callbacks;
  Stuff.CyclesLeftInInstruction := Cardinal(0);
  Stuff.CyclesDone := Cardinal(0);
  Stuff.TerminateEarly := Byte(0);
  while True do
  begin
    Stuff.CyclesDone := Cardinal(Add32(Stuff.CyclesDone, Stuff.CyclesLeftInInstruction));
    temp330 := Ord(Cardinal(Stuff.CyclesDone) < Cardinal(CyclesToDo));
    if temp330 <> 0 then
    begin
      temp330 := Ord(not (Stuff.TerminateEarly <> 0));
    end;
    if not (temp330 <> 0) then
      Break;
    try
      PendingInterrupt := Cardinal(State^.PendingInterrupt);
      Stuff.CyclesLeftInInstruction := Cardinal(4);
      Stuff.StartingProgramCounter := Cardinal(State^.ProgramCounter);
      if (not (State^.Stopped <> 0)) then
      begin
        Instruction_ := DecodeOpcode(@Stuff.OpCode, ReadWord(@Stuff, State^.ProgramCounter));
        State^.InstructionRegister := Word(Stuff.OpCode.Raw);
        IncrementProgramCounter(State, 2);
        case Instruction_ of
          INSTRUCTION_ABCD:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceBCDX(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationBCDX(@Stuff);
              ReadDestination(@Stuff);
              ActionABCD(@Stuff);
              WriteDestination(@Stuff);
              OverflowADD(@Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_ADD:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionADD(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardCarry(@Stuff);
              OverflowADD(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_ADDA:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeSized(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationAddressRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionADDA(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_ADDAQ:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionADDQ(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_ADDI:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionADD(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardCarry(@Stuff);
              OverflowADD(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_ADDQ:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionADDQ(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardCarry(@Stuff);
              OverflowADD(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_ADDX:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceBCDX(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationBCDX(@Stuff);
              ReadDestination(@Stuff);
              ActionADDX(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardCarry(@Stuff);
              OverflowADD(@Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_AND:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionAND(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ANDI:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionAND(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ANDI_TO_CCR:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationConditionCodeRegister(@Stuff);
              ReadDestination(@Stuff);
              ActionAND(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_ANDI_TO_SR:
            begin
              SupervisorCheck(@Stuff);
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationStatusRegister(@Stuff);
              ReadDestination(@Stuff);
              ActionAND(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_ASD_MEMORY:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionASDMEMORY(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ASD_REGISTER:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterPrimary(@Stuff);
              ReadDestination(@Stuff);
              ActionASDREGISTER(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_BCC_SHORT:
            begin
              ActionBCCSHORT(@Stuff);
            end;
          INSTRUCTION_BCC_WORD:
            begin
              DecodeSourceImmediateDataWord(@Stuff);
              ReadSource(@Stuff);
              ActionBCCWORD(@Stuff);
            end;
          INSTRUCTION_BCHG_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondary(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBCHG(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_BCHG_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateDataByte(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBCHG(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_BCLR_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondary(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBCLR(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_BCLR_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateDataByte(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBCLR(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_BRA_SHORT:
            begin
              ActionBRASHORT(@Stuff);
            end;
          INSTRUCTION_BRA_WORD:
            begin
              DecodeSourceImmediateDataWord(@Stuff);
              ReadSource(@Stuff);
              ActionBRAWORD(@Stuff);
            end;
          INSTRUCTION_BSET_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondary(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBSET(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_BSET_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateDataByte(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBSET(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_BSR_SHORT:
            begin
              ActionBSRSHORT(@Stuff);
            end;
          INSTRUCTION_BSR_WORD:
            begin
              DecodeSourceImmediateDataWord(@Stuff);
              ReadSource(@Stuff);
              ActionBSRWORD(@Stuff);
            end;
          INSTRUCTION_BTST_DYNAMIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondary(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBTST(@Stuff);
            end;
          INSTRUCTION_BTST_STATIC:
            begin
              SetSizeLongwordRegisterByteMemory(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateDataByte(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionBTST(@Stuff);
            end;
          INSTRUCTION_CHK:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              ActionCHK(@Stuff);
            end;
          INSTRUCTION_CLR:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionCLR(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_CMP:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionCMP(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_CMPA:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeSized(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationAddressRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionCMPA(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_CMPI:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionCMPI(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_CMPM:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceAddressRegisterPrimaryPostIncrement(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationAddressRegisterSecondaryPostIncrement(@Stuff);
              ReadDestination(@Stuff);
              ActionCMPM(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_DBCC:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              ActionDBCC(@Stuff);
            end;
          INSTRUCTION_DIVS:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeWord(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionDIVS(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
            end;
          INSTRUCTION_DIVU:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeWord(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionDIVU(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
            end;
          INSTRUCTION_EOR:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondary(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionEOR(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_EORI:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionEOR(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_EORI_TO_CCR:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationConditionCodeRegister(@Stuff);
              ReadDestination(@Stuff);
              ActionEOR(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_EORI_TO_SR:
            begin
              SupervisorCheck(@Stuff);
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationStatusRegister(@Stuff);
              ReadDestination(@Stuff);
              ActionEOR(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_EXG:
            begin
              ActionEXG(@Stuff);
            end;
          INSTRUCTION_EXT:
            begin
              SetSizeExt(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterPrimary(@Stuff);
              ReadDestination(@Stuff);
              ActionEXT(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ILLEGAL:
            begin
              ActionILLEGAL(@Stuff);
            end;
          INSTRUCTION_JMP:
            begin
              DecodeSourceMemoryAddressPrimary(@Stuff);
              ReadSource(@Stuff);
              ActionJMP(@Stuff);
            end;
          INSTRUCTION_JSR:
            begin
              DecodeSourceMemoryAddressPrimary(@Stuff);
              ReadSource(@Stuff);
              ActionJSR(@Stuff);
            end;
          INSTRUCTION_LEA:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceMemoryAddressPrimary(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationAddressRegisterSecondary(@Stuff);
              ActionLEA(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_LINK:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              ActionLINK(@Stuff);
            end;
          INSTRUCTION_LSD_MEMORY:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionLSDMEMORY(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_LSD_REGISTER:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterPrimary(@Stuff);
              ReadDestination(@Stuff);
              ActionLSDREGISTER(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_MOVE:
            begin
              SetSizeMove(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationSecondaryAddressMode(@Stuff);
              ActionMOVE(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_MOVE_FROM_SR:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceStatusRegister(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ActionMOVE(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_MOVE_TO_CCR:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationConditionCodeRegister(@Stuff);
              ActionMOVE(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_MOVE_TO_SR:
            begin
              SupervisorCheck(@Stuff);
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationStatusRegister(@Stuff);
              ActionMOVE(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_MOVE_USP:
            begin
              SupervisorCheck(@Stuff);
              ActionMOVE_USP(@Stuff);
            end;
          INSTRUCTION_MOVEA:
            begin
              SetSizeMove(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationAddressRegisterSecondaryFull(@Stuff);
              ActionMOVEA(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_MOVEM:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationMOVEM(@Stuff);
              ReadDestination(@Stuff);
              ActionMOVEM(@Stuff);
            end;
          INSTRUCTION_MOVEP:
            begin
              DecodeDestinationMOVEP(@Stuff);
              ReadDestination(@Stuff);
              ActionMOVEP(@Stuff);
            end;
          INSTRUCTION_MOVEQ:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterSecondary(@Stuff);
              ActionMOVEQ(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_MULS:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeWord(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionMULS(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_MULU:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeWord(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionMULU(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_NBCD:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionNBCD(@Stuff);
              WriteDestination(@Stuff);
              OverflowSUB(@Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_NEG:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionNEG(@Stuff);
              WriteDestination(@Stuff);
              CarryNEG(@Stuff);
              OverflowNEG(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_NEGX:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionNEGX(@Stuff);
              WriteDestination(@Stuff);
              CarryNEG(@Stuff);
              OverflowNEG(@Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_NOP:
            begin
              ActionNOP(@Stuff);
            end;
          INSTRUCTION_NOT:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionNOT(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_OR:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionOR(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ORI:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionOR(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ORI_TO_CCR:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationConditionCodeRegister(@Stuff);
              ReadDestination(@Stuff);
              ActionOR(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_ORI_TO_SR:
            begin
              SupervisorCheck(@Stuff);
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationStatusRegister(@Stuff);
              ReadDestination(@Stuff);
              ActionOR(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_PEA:
            begin
              DecodeSourceMemoryAddressPrimary(@Stuff);
              ReadSource(@Stuff);
              ActionPEA(@Stuff);
            end;
          INSTRUCTION_RESET:
            begin
              SupervisorCheck(@Stuff);
              ActionRESET(@Stuff);
            end;
          INSTRUCTION_ROD_MEMORY:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionRODMEMORY(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ROD_REGISTER:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterPrimary(@Stuff);
              ReadDestination(@Stuff);
              ActionRODREGISTER(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ROXD_MEMORY:
            begin
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionROXDMEMORY(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_ROXD_REGISTER:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterPrimary(@Stuff);
              ReadDestination(@Stuff);
              ActionROXDREGISTER(@Stuff);
              WriteDestination(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_RTE:
            begin
              SupervisorCheck(@Stuff);
              ActionRTE(@Stuff);
            end;
          INSTRUCTION_RTR:
            begin
              ActionRTR(@Stuff);
            end;
          INSTRUCTION_RTS:
            begin
              ActionRTS(@Stuff);
            end;
          INSTRUCTION_SBCD:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceBCDX(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationBCDX(@Stuff);
              ReadDestination(@Stuff);
              ActionSBCD(@Stuff);
              WriteDestination(@Stuff);
              OverflowSUB(@Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_SCC:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionSCC(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_STOP:
            begin
              SupervisorCheck(@Stuff);
              SetSizeWord(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              ActionSTOP(@Stuff);
            end;
          INSTRUCTION_SUB:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationDataRegisterSecondaryOrPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionSUB(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_SUBA:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressModeSized(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationAddressRegisterSecondary(@Stuff);
              ReadDestination(@Stuff);
              ActionSUBA(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_SUBAQ:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionSUBQ(@Stuff);
              WriteDestination(@Stuff);
            end;
          INSTRUCTION_SUBI:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceImmediateData(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionSUB(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_SUBQ:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionSUBQ(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_SUBX:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourceBCDX(@Stuff);
              ReadSource(@Stuff);
              DecodeDestinationBCDX(@Stuff);
              ReadDestination(@Stuff);
              ActionSUBX(@Stuff);
              WriteDestination(@Stuff);
              CarryStandardBorrow(@Stuff);
              OverflowSUB(@Stuff);
              ZeroClearIfNonZeroUnaffectedOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
              ExtendSetToCarry(@Stuff);
            end;
          INSTRUCTION_SWAP:
            begin
              SetSizeLongword(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationDataRegisterPrimary(@Stuff);
              ReadDestination(@Stuff);
              ActionSWAP(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_TAS:
            begin
              SetSizeByte(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeDestinationPrimaryAddressMode(@Stuff);
              ReadDestination(@Stuff);
              ActionTAS(@Stuff);
              WriteDestination(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
            end;
          INSTRUCTION_TRAP:
            begin
              ActionTRAP(@Stuff);
            end;
          INSTRUCTION_TRAPV:
            begin
              ActionTRAPV(@Stuff);
            end;
          INSTRUCTION_TST:
            begin
              SetSizeStandard(@Stuff);
              SetMSBBitIndex(@Stuff);
              DecodeSourcePrimaryAddressMode(@Stuff);
              ReadSource(@Stuff);
              ActionTST(@Stuff);
              CarryClear(@Stuff);
              OverflowClear(@Stuff);
              ZeroSetIfZeroClearOtherwise(@Stuff);
              NegativeSetIfNegativeClearOtherwise(@Stuff);
            end;
          INSTRUCTION_UNLK:
            begin
              ActionUNLK(@Stuff);
            end;
          INSTRUCTION_UNIMPLEMENTED_1:
            begin
              ActionUNIMPLEMENTED1(@Stuff);
            end;
          INSTRUCTION_UNIMPLEMENTED_2:
            begin
              ActionUNIMPLEMENTED2(@Stuff);
            end;
        end;
      end;
      temp427 := Ord(Cardinal(PendingInterrupt) = Cardinal(7));
      if temp427 = 0 then
      begin
        temp427 := Ord(Cardinal(PendingInterrupt) > Cardinal(Cardinal(Cardinal(State^.StatusRegister) shr 8) and Cardinal(7)));
      end;
      if (temp427 <> 0) then
      begin
        State^.Stopped := Byte(0);
        DoInterrupt(@Stuff, (Add32(24, PendingInterrupt)));
        Stuff.CyclesLeftInInstruction := Cardinal(Cardinal(Stuff.CyclesLeftInInstruction) + Cardinal(14));
        State^.StatusRegister := Word(State^.StatusRegister and (not STATUS_INTERRUPT_MASK));
        State^.StatusRegister := Word(State^.StatusRegister or (PendingInterrupt shl 8));
        Callbacks^.InterruptAcknowledgeCallback(Callbacks^.UserData);
      end;
    except
      on E: ECPUException do
      begin
        if E.Code = 2 then
        begin
          State^.ProgramCounter := Stuff.StartingProgramCounter;
          DoInterrupt(@Stuff, Stuff.Exception.VectorOffset);
        end;
        if State^.Halted <> 0 then
          Exit(CyclesToDo);
      end;
    end;
  end;
  Exit(Cardinal(Stuff.CyclesDone));
end;

end.

