unit HW.V60;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

type
  TV60Read = function(Address: Cardinal): Byte of object;

  TV60ReadWord = function(Address: Cardinal): Word of object;

  TV60WriteWord = procedure(Address: Cardinal; Value: Word) of object;

  TV60Write = procedure(Address: Cardinal; Value: Byte) of object;

  TV60IRQ = function: Byte of object;

  TV60Clock = procedure(Cycles: Integer) of object;

  TV60CycleModel = (vcmReference8, vcmBusConstraints);

  TV60BusClocks = function(Address: Cardinal; IsWrite: Boolean): Integer of object;

  TV60StringState = packed record
    Kind, Size, Phase, Mode, Logic: Byte;
    PC, Task, Source, Destination, Len1, Len2, Limit, Progress, InstructionLength: Cardinal;
    Index, SrcBit, DstBit: Int64;
    SrcValue, BusAddress, BusValue: Cardinal;
    BusWidth, BusIndex, BusWrite, BusNextPhase, DestinationRegister: Byte;
    DataClocks, CodeClocks: Int64;
    LastRead, LastWrite, SrcAddress, DstAddress: Cardinal;
    ReadValid, WriteValid, SrcValid, DstValid, SrcByte, DstByte: Byte;
  end;

  TV60StringFrame = packed record
    Frame: Cardinal;
    State: TV60StringState;
  end;

  TV60 = class
  private
    m_reg: array[0..67] of Cardinal;
    m_flags: record
      CY, OV, S, Z: Byte;
    end;
    m_op1, m_op2, m_lenop1, m_lenop2, m_bamoffset1, m_bamoffset2: Cardinal;
    m_amout, m_bamoffset, m_amlength1, m_amlength2, m_modadd: Cardinal;
    m_flag1, m_flag2, m_instflags, m_subop, m_amflag: Byte;
    m_modm, m_modval, m_modval2, m_modwritevalb, m_moddim: Byte;
    m_modwritevalh: Word;
    m_modwritevalw: Cardinal;
    m_stall_io: Integer;
    FRead, FIORead: TV60Read;
    FReadWord: TV60ReadWord;
    FWriteWord: TV60WriteWord;
    FWrite, FIOWrite: TV60Write;
    FIRQ: TV60IRQ;
    FIRQLine: Boolean;
    FHalted: Boolean;
    FCycleDebt, FLastInstructionCycles: Int64;
    FCycleModel: TV60CycleModel;
    FBusClocks: TV60BusClocks;
    FPrefetchAddress: Cardinal;
    FPrefetchCount, FPrefetchCredit, FPrefetchCost: Integer;
    FInstructionPC: Cardinal;
    FCodeStalls, FDataClocks: Int64;
    FCountingBus, FStringBus: Boolean;
    FLastReadByte, FLastWriteByte: Cardinal;
    FLastReadValid, FLastWriteValid: Boolean;
    FClockCallback: TV60Clock;
    FStringState: TV60StringState;
    FStringFrames: TArray<TV60StringFrame>;
    function GetStringPending: Boolean;
    procedure StartString(AKind, ASize, AMode: Byte);
    procedure StringTransfer(Address: Cardinal; Width: Byte; WriteAccess: Boolean; Value: Cardinal; NextPhase: Byte);
    procedure StringPointers;
    function StringStep(AllowBus: Boolean = True): Int64;
    procedure SuspendString(Frame: Cardinal);
    procedure RestoreString(Frame, NewPSW: Cardinal);
    procedure RestoreTaskString;
    procedure SerializeStrings(State: TStateArchive);

    procedure ResetPrefetch(Address: Cardinal);
    procedure ConsumeCode(Address: Cardinal);
    procedure BackgroundPrefetch(Clocks: Int64);
    function PrefetchBusClocks: Integer;
    function DataBusClocks(Address: Cardinal; IsWrite: Boolean): Integer;
    procedure AccountBus(Address: Cardinal; Width: Integer; IsWrite: Boolean);
    procedure BeginTiming;
    function FinishTiming(Opcode, Step: Cardinal): Int64;
    function Fetch8(Address: Cardinal): Byte;
    function Fetch16(Address: Cardinal): Word;
    function Fetch32(Address: Cardinal): Cardinal;
    function Read8(Address: Cardinal): Byte;
    function Read16(Address: Cardinal): Word;
    function Read32(Address: Cardinal): Cardinal;
    function Read64(Address: Cardinal): UInt64;
    procedure Write8(Address: Cardinal; Value: Byte);
    procedure Write16(Address: Cardinal; Value: Word);
    procedure Write32(Address: Cardinal; Value: Cardinal);
    procedure Write64(Address: Cardinal; Value: UInt64);
    function IORead8(Address: Cardinal): Byte;
    function IORead16(Address: Cardinal): Word;
    function IORead32(Address: Cardinal): Cardinal;
    procedure IOWrite8(Address: Cardinal; Value: Byte);
    procedure IOWrite16(Address: Cardinal; Value: Word);
    procedure IOWrite32(Address: Cardinal; Value: Cardinal);
    function ShiftRotateInteger(Size, Kind: Integer): Cardinal;
    function MultiplySignedInteger(Size: Integer): Cardinal;
    function SearchCharacters(Size: Integer; Search, Downward: Boolean): Cardinal;
    function SearchBits(SearchOne, Downward: Boolean): Cardinal;
    procedure IntegerException(Code: Word; InstructionLength: Cardinal);
    function DivideInteger(Size: Integer; Unsigned, Extended: Boolean): Cardinal;
    procedure Illegal;
    function Dispatch(Index: Integer; Reg: Integer = 0): Cardinal; reintroduce;
    procedure v60SaveStack;
    procedure v60ReloadStack;
    function v60ReadPSW: Cardinal;
    procedure v60WritePSW(newval: Cardinal);
    function v60_update_psw_for_exception(is_interrupt: Integer; target_level: Integer): Cardinal;
    function am1Register: Cardinal;
    function am1RegisterIndirect: Cardinal;
    function bam1RegisterIndirect: Cardinal;
    function am1RegisterIndirectIndexed: Cardinal;
    function bam1RegisterIndirectIndexed: Cardinal;
    function am1Autoincrement: Cardinal;
    function bam1Autoincrement: Cardinal;
    function am1Autodecrement: Cardinal;
    function bam1Autodecrement: Cardinal;
    function am1Displacement8: Cardinal;
    function bam1Displacement8: Cardinal;
    function am1Displacement16: Cardinal;
    function bam1Displacement16: Cardinal;
    function am1Displacement32: Cardinal;
    function bam1Displacement32: Cardinal;
    function am1DisplacementIndexed8: Cardinal;
    function bam1DisplacementIndexed8: Cardinal;
    function am1DisplacementIndexed16: Cardinal;
    function bam1DisplacementIndexed16: Cardinal;
    function am1DisplacementIndexed32: Cardinal;
    function bam1DisplacementIndexed32: Cardinal;
    function am1PCDisplacement8: Cardinal;
    function bam1PCDisplacement8: Cardinal;
    function am1PCDisplacement16: Cardinal;
    function bam1PCDisplacement16: Cardinal;
    function am1PCDisplacement32: Cardinal;
    function bam1PCDisplacement32: Cardinal;
    function am1PCDisplacementIndexed8: Cardinal;
    function bam1PCDisplacementIndexed8: Cardinal;
    function am1PCDisplacementIndexed16: Cardinal;
    function bam1PCDisplacementIndexed16: Cardinal;
    function am1PCDisplacementIndexed32: Cardinal;
    function bam1PCDisplacementIndexed32: Cardinal;
    function am1DisplacementIndirect8: Cardinal;
    function bam1DisplacementIndirect8: Cardinal;
    function am1DisplacementIndirect16: Cardinal;
    function bam1DisplacementIndirect16: Cardinal;
    function am1DisplacementIndirect32: Cardinal;
    function bam1DisplacementIndirect32: Cardinal;
    function am1DisplacementIndirectIndexed8: Cardinal;
    function bam1DisplacementIndirectIndexed8: Cardinal;
    function am1DisplacementIndirectIndexed16: Cardinal;
    function bam1DisplacementIndirectIndexed16: Cardinal;
    function am1DisplacementIndirectIndexed32: Cardinal;
    function bam1DisplacementIndirectIndexed32: Cardinal;
    function am1PCDisplacementIndirect8: Cardinal;
    function bam1PCDisplacementIndirect8: Cardinal;
    function am1PCDisplacementIndirect16: Cardinal;
    function bam1PCDisplacementIndirect16: Cardinal;
    function am1PCDisplacementIndirect32: Cardinal;
    function bam1PCDisplacementIndirect32: Cardinal;
    function am1PCDisplacementIndirectIndexed8: Cardinal;
    function bam1PCDisplacementIndirectIndexed8: Cardinal;
    function am1PCDisplacementIndirectIndexed16: Cardinal;
    function bam1PCDisplacementIndirectIndexed16: Cardinal;
    function am1PCDisplacementIndirectIndexed32: Cardinal;
    function bam1PCDisplacementIndirectIndexed32: Cardinal;
    function am1DoubleDisplacement8: Cardinal;
    function bam1DoubleDisplacement8: Cardinal;
    function am1DoubleDisplacement16: Cardinal;
    function bam1DoubleDisplacement16: Cardinal;
    function am1DoubleDisplacement32: Cardinal;
    function bam1DoubleDisplacement32: Cardinal;
    function am1PCDoubleDisplacement8: Cardinal;
    function bam1PCDoubleDisplacement8: Cardinal;
    function am1PCDoubleDisplacement16: Cardinal;
    function bam1PCDoubleDisplacement16: Cardinal;
    function am1PCDoubleDisplacement32: Cardinal;
    function bam1PCDoubleDisplacement32: Cardinal;
    function am1DirectAddress: Cardinal;
    function bam1DirectAddress: Cardinal;
    function am1DirectAddressIndexed: Cardinal;
    function bam1DirectAddressIndexed: Cardinal;
    function am1DirectAddressDeferred: Cardinal;
    function bam1DirectAddressDeferred: Cardinal;
    function am1DirectAddressDeferredIndexed: Cardinal;
    function bam1DirectAddressDeferredIndexed: Cardinal;
    function am1Immediate: Cardinal;
    function am1ImmediateQuick: Cardinal;
    function am1Error1: Cardinal;
    function bam1Error1: Cardinal;
    function am1Error2: Cardinal;
    function bam1Error2: Cardinal;
    function am1Error4: Cardinal;
    function bam1Error4: Cardinal;
    function am1Error5: Cardinal;
    function bam1Error5: Cardinal;
    function bam1Error6: Cardinal;
    function am1Group7a: Cardinal;
    function bam1Group7a: Cardinal;
    function am1Group6: Cardinal;
    function bam1Group6: Cardinal;
    function am1Group7: Cardinal;
    function bam1Group7: Cardinal;
    function am2Register: Cardinal;
    function am2RegisterIndirect: Cardinal;
    function bam2RegisterIndirect: Cardinal;
    function am2RegisterIndirectIndexed: Cardinal;
    function bam2RegisterIndirectIndexed: Cardinal;
    function am2Autoincrement: Cardinal;
    function bam2Autoincrement: Cardinal;
    function am2Autodecrement: Cardinal;
    function bam2Autodecrement: Cardinal;
    function am2Displacement8: Cardinal;
    function bam2Displacement8: Cardinal;
    function am2Displacement16: Cardinal;
    function bam2Displacement16: Cardinal;
    function am2Displacement32: Cardinal;
    function bam2Displacement32: Cardinal;
    function am2DisplacementIndexed8: Cardinal;
    function bam2DisplacementIndexed8: Cardinal;
    function am2DisplacementIndexed16: Cardinal;
    function bam2DisplacementIndexed16: Cardinal;
    function am2DisplacementIndexed32: Cardinal;
    function bam2DisplacementIndexed32: Cardinal;
    function am2PCDisplacement8: Cardinal;
    function bam2PCDisplacement8: Cardinal;
    function am2PCDisplacement16: Cardinal;
    function bam2PCDisplacement16: Cardinal;
    function am2PCDisplacement32: Cardinal;
    function bam2PCDisplacement32: Cardinal;
    function am2PCDisplacementIndexed8: Cardinal;
    function bam2PCDisplacementIndexed8: Cardinal;
    function am2PCDisplacementIndexed16: Cardinal;
    function bam2PCDisplacementIndexed16: Cardinal;
    function am2PCDisplacementIndexed32: Cardinal;
    function bam2PCDisplacementIndexed32: Cardinal;
    function am2DisplacementIndirect8: Cardinal;
    function bam2DisplacementIndirect8: Cardinal;
    function am2DisplacementIndirect16: Cardinal;
    function bam2DisplacementIndirect16: Cardinal;
    function am2DisplacementIndirect32: Cardinal;
    function bam2DisplacementIndirect32: Cardinal;
    function am2DisplacementIndirectIndexed8: Cardinal;
    function bam2DisplacementIndirectIndexed8: Cardinal;
    function am2DisplacementIndirectIndexed16: Cardinal;
    function bam2DisplacementIndirectIndexed16: Cardinal;
    function am2DisplacementIndirectIndexed32: Cardinal;
    function bam2DisplacementIndirectIndexed32: Cardinal;
    function am2PCDisplacementIndirect8: Cardinal;
    function bam2PCDisplacementIndirect8: Cardinal;
    function am2PCDisplacementIndirect16: Cardinal;
    function bam2PCDisplacementIndirect16: Cardinal;
    function am2PCDisplacementIndirect32: Cardinal;
    function bam2PCDisplacementIndirect32: Cardinal;
    function am2PCDisplacementIndirectIndexed8: Cardinal;
    function bam2PCDisplacementIndirectIndexed8: Cardinal;
    function am2PCDisplacementIndirectIndexed16: Cardinal;
    function bam2PCDisplacementIndirectIndexed16: Cardinal;
    function am2PCDisplacementIndirectIndexed32: Cardinal;
    function bam2PCDisplacementIndirectIndexed32: Cardinal;
    function am2DoubleDisplacement8: Cardinal;
    function bam2DoubleDisplacement8: Cardinal;
    function am2DoubleDisplacement16: Cardinal;
    function bam2DoubleDisplacement16: Cardinal;
    function am2DoubleDisplacement32: Cardinal;
    function bam2DoubleDisplacement32: Cardinal;
    function am2PCDoubleDisplacement8: Cardinal;
    function bam2PCDoubleDisplacement8: Cardinal;
    function am2PCDoubleDisplacement16: Cardinal;
    function bam2PCDoubleDisplacement16: Cardinal;
    function am2PCDoubleDisplacement32: Cardinal;
    function bam2PCDoubleDisplacement32: Cardinal;
    function am2DirectAddress: Cardinal;
    function bam2DirectAddress: Cardinal;
    function am2DirectAddressIndexed: Cardinal;
    function bam2DirectAddressIndexed: Cardinal;
    function am2DirectAddressDeferred: Cardinal;
    function bam2DirectAddressDeferred: Cardinal;
    function am2DirectAddressDeferredIndexed: Cardinal;
    function bam2DirectAddressDeferredIndexed: Cardinal;
    function am2Immediate: Cardinal;
    function am2ImmediateQuick: Cardinal;
    function am2Error1: Cardinal;
    function am2Error2: Cardinal;
    function am2Error4: Cardinal;
    function am2Error5: Cardinal;
    function bam2Error1: Cardinal;
    function bam2Error2: Cardinal;
    function bam2Error4: Cardinal;
    function bam2Error5: Cardinal;
    function bam2Error6: Cardinal;
    function am2Group7a: Cardinal;
    function bam2Group7a: Cardinal;
    function am2Group6: Cardinal;
    function bam2Group6: Cardinal;
    function am2Group7: Cardinal;
    function bam2Group7: Cardinal;
    function am3Register: Cardinal;
    function am3RegisterIndirect: Cardinal;
    function am3RegisterIndirectIndexed: Cardinal;
    function am3Autoincrement: Cardinal;
    function am3Autodecrement: Cardinal;
    function am3Displacement8: Cardinal;
    function am3Displacement16: Cardinal;
    function am3Displacement32: Cardinal;
    function am3DisplacementIndexed8: Cardinal;
    function am3DisplacementIndexed16: Cardinal;
    function am3DisplacementIndexed32: Cardinal;
    function am3PCDisplacement8: Cardinal;
    function am3PCDisplacement16: Cardinal;
    function am3PCDisplacement32: Cardinal;
    function am3PCDisplacementIndexed8: Cardinal;
    function am3PCDisplacementIndexed16: Cardinal;
    function am3PCDisplacementIndexed32: Cardinal;
    function am3DisplacementIndirect8: Cardinal;
    function am3DisplacementIndirect16: Cardinal;
    function am3DisplacementIndirect32: Cardinal;
    function am3DisplacementIndirectIndexed8: Cardinal;
    function am3DisplacementIndirectIndexed16: Cardinal;
    function am3DisplacementIndirectIndexed32: Cardinal;
    function am3PCDisplacementIndirect8: Cardinal;
    function am3PCDisplacementIndirect16: Cardinal;
    function am3PCDisplacementIndirect32: Cardinal;
    function am3PCDisplacementIndirectIndexed8: Cardinal;
    function am3PCDisplacementIndirectIndexed16: Cardinal;
    function am3PCDisplacementIndirectIndexed32: Cardinal;
    function am3DoubleDisplacement8: Cardinal;
    function am3DoubleDisplacement16: Cardinal;
    function am3DoubleDisplacement32: Cardinal;
    function am3PCDoubleDisplacement8: Cardinal;
    function am3PCDoubleDisplacement16: Cardinal;
    function am3PCDoubleDisplacement32: Cardinal;
    function am3DirectAddress: Cardinal;
    function am3DirectAddressIndexed: Cardinal;
    function am3DirectAddressDeferred: Cardinal;
    function am3DirectAddressDeferredIndexed: Cardinal;
    function am3Immediate: Cardinal;
    function am3ImmediateQuick: Cardinal;
    function am3Error1: Cardinal;
    function am3Error2: Cardinal;
    function am3Error4: Cardinal;
    function am3Error5: Cardinal;
    function am3Group7a: Cardinal;
    function am3Group6: Cardinal;
    function am3Group7: Cardinal;
    function ReadAM: Cardinal;
    function BitReadAM: Cardinal;
    function ReadAMAddress: Cardinal;
    function BitReadAMAddress: Cardinal;
    function WriteAM: Cardinal;
    procedure F12DecodeFirstOperand(DecodeOp1: Integer; dim1: Byte);
    procedure F12WriteSecondOperand(dim2: Byte);
    procedure F12DecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
    function opADDB: Cardinal;
    function opADDH: Cardinal;
    function opADDW: Cardinal;
    function opADDCB: Cardinal;
    function opADDCH: Cardinal;
    function opADDCW: Cardinal;
    function opANDB: Cardinal;
    function opANDH: Cardinal;
    function opANDW: Cardinal;
    function opCALL: Cardinal;
    function opCHKAR: Cardinal;
    function opCHKAW: Cardinal;
    function opCHKAE: Cardinal;
    function opCHLVL: Cardinal;
    function opCLR1: Cardinal;
    function opCMPB: Cardinal;
    function opCMPH: Cardinal;
    function opCMPW: Cardinal;
    function opDIVB: Cardinal;
    function opDIVH: Cardinal;
    function opDIVW: Cardinal;
    function opDIVX: Cardinal;
    function opDIVUX: Cardinal;
    function opDIVUB: Cardinal;
    function opDIVUH: Cardinal;
    function opDIVUW: Cardinal;
    function opINB: Cardinal;
    function opINH: Cardinal;
    function opINW: Cardinal;
    function opLDPR: Cardinal;
    function opLDTASK: Cardinal;
    function opMOVD: Cardinal;
    function opMOVB: Cardinal;
    function opMOVH: Cardinal;
    function opMOVW: Cardinal;
    function opMOVEAB: Cardinal;
    function opMOVEAH: Cardinal;
    function opMOVEAW: Cardinal;
    function opMOVSBH: Cardinal;
    function opMOVSBW: Cardinal;
    function opMOVSHW: Cardinal;
    function opMOVTHB: Cardinal;
    function opMOVTWB: Cardinal;
    function opMOVTWH: Cardinal;
    function opMOVZBH: Cardinal;
    function opMOVZBW: Cardinal;
    function opMOVZHW: Cardinal;
    function opMULB: Cardinal;
    function opMULH: Cardinal;
    function opMULW: Cardinal;
    function opMULUB: Cardinal;
    function opMULUH: Cardinal;
    function opMULUW: Cardinal;
    function opNEGB: Cardinal;
    function opNEGH: Cardinal;
    function opNEGW: Cardinal;
    function opNOTB: Cardinal;
    function opNOTH: Cardinal;
    function opNOTW: Cardinal;
    function opNOT1: Cardinal;
    function opORB: Cardinal;
    function opORH: Cardinal;
    function opORW: Cardinal;
    function opOUTB: Cardinal;
    function opOUTH: Cardinal;
    function opOUTW: Cardinal;
    function opREMB: Cardinal;
    function opREMH: Cardinal;
    function opREMW: Cardinal;
    function opREMUB: Cardinal;
    function opREMUH: Cardinal;
    function opREMUW: Cardinal;
    function opROTB: Cardinal;
    function opROTH: Cardinal;
    function opROTW: Cardinal;
    function opROTCB: Cardinal;
    function opROTCH: Cardinal;
    function opROTCW: Cardinal;
    function opRVBIT: Cardinal;
    function opRVBYT: Cardinal;
    function opSET1: Cardinal;
    function opSETF: Cardinal;
    function opSHAB: Cardinal;
    function opSHAH: Cardinal;
    function opSHAW: Cardinal;
    function opSHLB: Cardinal;
    function opSHLH: Cardinal;
    function opSHLW: Cardinal;
    function opSTPR: Cardinal;
    function opSUBB: Cardinal;
    function opSUBH: Cardinal;
    function opSUBW: Cardinal;
    function opSUBCB: Cardinal;
    function opSUBCH: Cardinal;
    function opSUBCW: Cardinal;
    function opTEST1: Cardinal;
    function opUPDPSWW: Cardinal;
    function opUPDPSWH: Cardinal;
    function opXCHB: Cardinal;
    function opXCHH: Cardinal;
    function opXCHW: Cardinal;
    function opXORB: Cardinal;
    function opXORH: Cardinal;
    function opXORW: Cardinal;
    function opMULX: Cardinal;
    function opMULUX: Cardinal;
    procedure F2DecodeFirstOperand(DecodeOp1: Integer; dim1: Byte);
    procedure F2DecodeSecondOperand(DecodeOp2: Integer; dim2: Byte);
    procedure F2WriteSecondOperand(dim2: Byte);
    function opCVTWS: Cardinal;
    function opCVTSW: Cardinal;
    function opMOVFS: Cardinal;
    function opNEGFS: Cardinal;
    function opABSFS: Cardinal;
    function opADDFS: Cardinal;
    function opSUBFS: Cardinal;
    function opMULFS: Cardinal;
    function opDIVFS: Cardinal;
    function opSCLFS: Cardinal;
    function opCMPF: Cardinal;
    function op5FUNHANDLED: Cardinal;
    function op5CUNHANDLED: Cardinal;
    function op5F: Cardinal;
    function op5C: Cardinal;
    function opINCB: Cardinal;
    function opINCH: Cardinal;
    function opINCW: Cardinal;
    function opDECB: Cardinal;
    function opDECH: Cardinal;
    function opDECW: Cardinal;
    function opJMP: Cardinal;
    function opJSR: Cardinal;
    function opPREPARE: Cardinal;
    function opRET: Cardinal;
    function opTRAP: Cardinal;
    function opRETIU: Cardinal;
    function opRETIS: Cardinal;
    function opSTTASK: Cardinal;
    function opGETPSW: Cardinal;
    function opTASI: Cardinal;
    function opCLRTLB: Cardinal;
    function opPOPM: Cardinal;
    function opPUSHM: Cardinal;
    function opTESTB: Cardinal;
    function opTESTH: Cardinal;
    function opTESTW: Cardinal;
    function opPUSH: Cardinal;
    function opPOP: Cardinal;
    function opINCB_0: Cardinal;
    function opINCB_1: Cardinal;
    function opINCH_0: Cardinal;
    function opINCH_1: Cardinal;
    function opINCW_0: Cardinal;
    function opINCW_1: Cardinal;
    function opDECB_0: Cardinal;
    function opDECB_1: Cardinal;
    function opDECH_0: Cardinal;
    function opDECH_1: Cardinal;
    function opDECW_0: Cardinal;
    function opDECW_1: Cardinal;
    function opJMP_0: Cardinal;
    function opJMP_1: Cardinal;
    function opJSR_0: Cardinal;
    function opJSR_1: Cardinal;
    function opPREPARE_0: Cardinal;
    function opPREPARE_1: Cardinal;
    function opRET_0: Cardinal;
    function opRET_1: Cardinal;
    function opTRAP_0: Cardinal;
    function opTRAP_1: Cardinal;
    function opRETIU_0: Cardinal;
    function opRETIU_1: Cardinal;
    function opRETIS_0: Cardinal;
    function opRETIS_1: Cardinal;
    function opGETPSW_0: Cardinal;
    function opGETPSW_1: Cardinal;
    function opTASI_0: Cardinal;
    function opTASI_1: Cardinal;
    function opCLRTLB_0: Cardinal;
    function opCLRTLB_1: Cardinal;
    function opPOPM_0: Cardinal;
    function opPOPM_1: Cardinal;
    function opPUSHM_0: Cardinal;
    function opPUSHM_1: Cardinal;
    function opTESTB_0: Cardinal;
    function opTESTB_1: Cardinal;
    function opTESTH_0: Cardinal;
    function opTESTH_1: Cardinal;
    function opTESTW_0: Cardinal;
    function opTESTW_1: Cardinal;
    function opPUSH_0: Cardinal;
    function opPUSH_1: Cardinal;
    function opPOP_0: Cardinal;
    function opPOP_1: Cardinal;
    function opSTTASK_0: Cardinal;
    function opSTTASK_1: Cardinal;
    function opBGT8: Cardinal;
    function opBGT16: Cardinal;
    function opBGE8: Cardinal;
    function opBGE16: Cardinal;
    function opBLT8: Cardinal;
    function opBLT16: Cardinal;
    function opBLE8: Cardinal;
    function opBLE16: Cardinal;
    function opBH8: Cardinal;
    function opBH16: Cardinal;
    function opBNH8: Cardinal;
    function opBNH16: Cardinal;
    function opBNL8: Cardinal;
    function opBNL16: Cardinal;
    function opBL8: Cardinal;
    function opBL16: Cardinal;
    function opBNE8: Cardinal;
    function opBNE16: Cardinal;
    function opBE8: Cardinal;
    function opBE16: Cardinal;
    function opBNV8: Cardinal;
    function opBNV16: Cardinal;
    function opBV8: Cardinal;
    function opBV16: Cardinal;
    function opBP8: Cardinal;
    function opBP16: Cardinal;
    function opBN8: Cardinal;
    function opBN16: Cardinal;
    function opBR8: Cardinal;
    function opBR16: Cardinal;
    function opBSR: Cardinal;
    function opBRK: Cardinal;
    function opBRKV: Cardinal;
    function opCLRTLBA: Cardinal;
    function opDISPOSE: Cardinal;
    function opHALT: Cardinal;
    function opNOP: Cardinal;
    function opRSR: Cardinal;
    function opTRAPFL: Cardinal;
    function opTB(reg: Integer): Cardinal;
    function opDBGT(reg: Integer): Cardinal;
    function opDBLE(reg: Integer): Cardinal;
    function opDBGE(reg: Integer): Cardinal;
    function opDBLT(reg: Integer): Cardinal;
    function opDBH(reg: Integer): Cardinal;
    function opDBNH(reg: Integer): Cardinal;
    function opDBL(reg: Integer): Cardinal;
    function opDBNL(reg: Integer): Cardinal;
    function opDBE(reg: Integer): Cardinal;
    function opDBNE(reg: Integer): Cardinal;
    function opDBV(reg: Integer): Cardinal;
    function opDBNV(reg: Integer): Cardinal;
    function opDBN(reg: Integer): Cardinal;
    function opDBP(reg: Integer): Cardinal;
    function opDBR(reg: Integer): Cardinal;
    function opC6: Cardinal;
    function opC7: Cardinal;
    procedure F7aDecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
    procedure F7bDecodeFirstOperand(DecodeOp1: Integer; dim1: Byte);
    procedure F7bWriteSecondOperand(dim2: Byte);
    procedure F7bDecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
    procedure F7cDecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
    function opCMPSTRB(bFill: Byte; bStop: Byte): Cardinal;
    function opCMPSTRH(bFill: Byte; bStop: Byte): Cardinal;
    function opMOVSTRUB(bFill: Byte; bStop: Byte): Cardinal;
    function opMOVSTRDB(bFill: Byte; bStop: Byte): Cardinal;
    function opMOVSTRUH(bFill: Byte; bStop: Byte): Cardinal;
    function opMOVSTRDH(bFill: Byte; bStop: Byte): Cardinal;
    function opSEARCHUB(bSearch: Byte): Cardinal;
    function opSEARCHUH(bSearch: Byte): Cardinal;
    function opSEARCHDB(bSearch: Byte): Cardinal;
    function opSEARCHDH(bSearch: Byte): Cardinal;
    function opSCHCUB: Cardinal;
    function opSCHCUH: Cardinal;
    function opSCHCDB: Cardinal;
    function opSCHCDH: Cardinal;
    function opSKPCUB: Cardinal;
    function opSKPCUH: Cardinal;
    function opSKPCDB: Cardinal;
    function opSKPCDH: Cardinal;
    function opCMPCB: Cardinal;
    function opCMPCH: Cardinal;
    function opCMPCFB: Cardinal;
    function opCMPCFH: Cardinal;
    function opCMPCSB: Cardinal;
    function opCMPCSH: Cardinal;
    function opMOVCUB: Cardinal;
    function opMOVCUH: Cardinal;
    function opMOVCFUB: Cardinal;
    function opMOVCFUH: Cardinal;
    function opMOVCSUB: Cardinal;
    function opMOVCSUH: Cardinal;
    function opMOVCDB: Cardinal;
    function opMOVCDH: Cardinal;
    function opMOVCFDB: Cardinal;
    function opMOVCFDH: Cardinal;
    function opEXTBFZ: Cardinal;
    function opEXTBFS: Cardinal;
    function opEXTBFL: Cardinal;
    function opSCHBS(bSearch1: Cardinal): Cardinal;
    function opSCH0BSU: Cardinal;
    function opSCH1BSU: Cardinal;
    function opINSBFR: Cardinal;
    function opINSBFL: Cardinal;
    function opMOVBSD: Cardinal;
    function opMOVBSU: Cardinal;
    function opADDDC: Cardinal;
    function opSUBDC: Cardinal;
    function opSUBRDC: Cardinal;
    function opCVTDPZ: Cardinal;
    function opCVTDZP: Cardinal;
    function op58UNHANDLED: Cardinal;
    function op5AUNHANDLED: Cardinal;
    function op5BUNHANDLED: Cardinal;
    function op5DUNHANDLED: Cardinal;
    function op59UNHANDLED: Cardinal;
    function op58: Cardinal;
    function op5A: Cardinal;
    function op5B: Cardinal;
    function op5D: Cardinal;
    function op59: Cardinal;
    function opUNHANDLED: Cardinal;
  public
    constructor Create(Read: TV60Read; Write: TV60Write; IRQ: TV60IRQ = nil);
    procedure Reset;
    function Run(Cycles: Integer): Integer;
    procedure SerializeState(State: TStateArchive);
    property ReadWord: TV60ReadWord read FReadWord write FReadWord;
    property WriteWord: TV60WriteWord read FWriteWord write FWriteWord;
    property IRQLine: Boolean read FIRQLine write FIRQLine;
    property ClockCallback: TV60Clock read FClockCallback write FClockCallback;
    property CycleModel: TV60CycleModel read FCycleModel write FCycleModel;
    property BusClocks: TV60BusClocks read FBusClocks write FBusClocks;
    property StringPending: Boolean read GetStringPending;
    property LastInstructionCycles: Int64 read FLastInstructionCycles;
    property IORead: TV60Read read FIORead write FIORead;
    property IOWrite: TV60Write read FIOWrite write FIOWrite;
    function GetRegister(Index: Integer): Cardinal;
    procedure SetRegister(Index: Integer; Value: Cardinal);
  end;

implementation

{$Q-}{$R-}{$B-}

function SelectValue(Condition: Boolean; A, B: Int64): Int64; inline;
begin
  if Condition then
    Result := A
  else
    Result := B;
end;

function u2f(Value: Cardinal): Single; inline;
begin
  Move(Value, Result, 4);
end;

function f2u(Value: Single): Cardinal; inline;
begin
  Move(Value, Result, 4);
end;

function roundf(Value: Single): Single;
begin
  if Value < 0 then
    Result := -Floor(-Value + 0.5)
  else
    Result := Floor(Value + 0.5);
end;

function floorf(Value: Single): Single;
begin
  Result := Floor(Value);
end;

function ceilf(Value: Single): Single;
begin
  Result := Ceil(Value);
end;

function truncf(Value: Single): Single;
begin
  Result := Trunc(Value);
end;

function fabsf(Value: Single): Single;
begin
  Result := Abs(Value);
end;

function ArithmeticShift(Value: Int64; Count: Integer): Int64;
begin
  if Count <= 0 then
    Exit(Value);
  if Count >= 64 then
    Exit(-Ord(Value < 0));
  Result := Int64(UInt64(Value) shr Count);
  if Value < 0 then
    Result := Result or Int64(High(UInt64) shl (64 - Count));
end;

function mul_32x32(A, B: Integer): Int64; inline;
begin
  Result := Int64(A) * B;
end;

function mulu_32x32(A, B: Cardinal): UInt64; inline;
begin
  Result := UInt64(A) * B;
end;

function div_64x32_rem(A: Int64; B: Integer; out Remain: Integer): Integer;
begin
  Remain := A mod B;
  Result := A div B;
end;

function divu_64x32_rem(A: UInt64; B: Cardinal; out Remain: Cardinal): Cardinal;
begin
  Remain := A mod B;
  Result := A div B;
end;

function ReverseBits8(Value, B0, B1, B2, B3, B4, B5, B6, B7: Cardinal): Byte;
begin
  Value := ((Value and $55) shl 1) or ((Value shr 1) and $55);
  Value := ((Value and $33) shl 2) or ((Value shr 2) and $33);
  Result := Byte((Value shl 4) or ((Value shr 4) and $F));
end;

function swapendian_int32(Value: Cardinal): Cardinal;
begin
  Result := (Value shl 24) or ((Value and $FF00) shl 8) or ((Value shr 8) and $FF00) or (Value shr 24);
end;

const
  s_AMTable1_G7a: array[0..15] of Integer = (0,
    1,
    2,
    3,
    4,
    4,
    4,
    4,
    5,
    6,
    7,
    8,
    4,
    4,
    4,
    4);
  s_BAMTable1_G7a: array[0..15] of Integer = (9,
    10,
    11,
    12,
    13,
    13,
    13,
    13,
    14,
    15,
    16,
    17,
    13,
    13,
    13,
    13);
  s_AMTable1_G7: array[0..31] of Integer = (18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    24,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31,
    24);
  s_BAMTable1_G7: array[0..31] of Integer = (32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    32,
    33,
    34,
    35,
    36,
    32,
    37,
    37,
    37,
    38,
    39,
    40,
    41,
    42,
    43,
    44,
    37);
  s_AMTable1_G6: array[0..7] of Integer = (45,
    46,
    47,
    48,
    49,
    50,
    51,
    52);
  s_BAMTable1_G6: array[0..7] of Integer = (53,
    54,
    55,
    56,
    57,
    58,
    59,
    60);
  s_AMTable1: array[0..1, 0..7] of Integer = ((61,
    62,
    63,
    64,
    65,
    66,
    67,
    68),
    (69,
    70,
    71,
    72,
    73,
    74,
    75,
    76));
  s_BAMTable1: array[0..1, 0..7] of Integer = ((77,
    78,
    79,
    80,
    81,
    82,
    83,
    84),
    (85,
    86,
    87,
    32,
    88,
    89,
    90,
    91));
  s_AMTable2_G7a: array[0..15] of Integer = (92,
    93,
    94,
    95,
    96,
    96,
    96,
    96,
    97,
    98,
    99,
    100,
    96,
    96,
    96,
    96);
  s_BAMTable2_G7a: array[0..15] of Integer = (101,
    102,
    103,
    104,
    105,
    105,
    105,
    105,
    106,
    107,
    108,
    109,
    105,
    105,
    105,
    105);
  s_AMTable2_G7: array[0..31] of Integer = (110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    110,
    111,
    112,
    113,
    114,
    115,
    116,
    116,
    116,
    117,
    118,
    119,
    120,
    121,
    122,
    123,
    116);
  s_BAMTable2_G7: array[0..31] of Integer = (124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    124,
    125,
    126,
    127,
    128,
    124,
    129,
    129,
    129,
    130,
    131,
    132,
    133,
    134,
    135,
    136,
    129);
  s_AMTable2_G6: array[0..7] of Integer = (137,
    138,
    139,
    140,
    141,
    142,
    143,
    144);
  s_BAMTable2_G6: array[0..7] of Integer = (145,
    146,
    147,
    148,
    149,
    150,
    151,
    152);
  s_AMTable2: array[0..1, 0..7] of Integer = ((153,
    154,
    155,
    156,
    157,
    158,
    159,
    160),
    (161,
    162,
    163,
    164,
    165,
    166,
    167,
    168));
  s_BAMTable2: array[0..1, 0..7] of Integer = ((169,
    170,
    171,
    172,
    173,
    174,
    175,
    176),
    (177,
    178,
    179,
    124,
    180,
    181,
    182,
    183));
  s_AMTable3_G7a: array[0..15] of Integer = (184,
    185,
    186,
    187,
    188,
    188,
    188,
    188,
    189,
    190,
    191,
    192,
    188,
    188,
    188,
    188);
  s_AMTable3_G7: array[0..31] of Integer = (193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    193,
    194,
    195,
    196,
    197,
    198,
    199,
    199,
    199,
    200,
    201,
    202,
    203,
    204,
    205,
    206,
    199);
  s_AMTable3_G6: array[0..7] of Integer = (207,
    208,
    209,
    210,
    211,
    212,
    213,
    214);
  s_AMTable3: array[0..1, 0..7] of Integer = ((215,
    216,
    217,
    218,
    219,
    220,
    221,
    222),
    (223,
    224,
    225,
    226,
    227,
    228,
    229,
    230));
  s_Op5FTable: array[0..31] of Integer = (233,
    234,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235,
    235);
  s_Op5CTable: array[0..31] of Integer = (236,
    237,
    237,
    237,
    237,
    237,
    237,
    237,
    238,
    239,
    240,
    237,
    237,
    237,
    237,
    237,
    241,
    237,
    237,
    237,
    237,
    237,
    237,
    237,
    242,
    243,
    244,
    245,
    237,
    237,
    237,
    237);
  s_OpC6Table: array[0..7] of Integer = (246,
    247,
    248,
    249,
    250,
    251,
    252,
    253);
  s_OpC7Table: array[0..7] of Integer = (254,
    255,
    256,
    257,
    258,
    259,
    260,
    261);
  s_Op59Table: array[0..31] of Integer = (264,
    265,
    266,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    268,
    267,
    267,
    267,
    267,
    267,
    267,
    267,
    269,
    267,
    267,
    267,
    267,
    267,
    267,
    267);
  s_Op5BTable: array[0..31] of Integer = (270,
    271,
    272,
    271,
    271,
    271,
    271,
    271,
    273,
    274,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271,
    271);
  s_Op5DTable: array[0..31] of Integer = (275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    276,
    277,
    278,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    275,
    279,
    280,
    275,
    275,
    275,
    275,
    275,
    275);
  s_Op58Table: array[0..31] of Integer = (281,
    282,
    283,
    284,
    284,
    284,
    284,
    284,
    285,
    286,
    287,
    288,
    289,
    284,
    284,
    284,
    284,
    284,
    284,
    284,
    284,
    284,
    284,
    284,
    290,
    291,
    292,
    293,
    284,
    284,
    284,
    284);
  s_Op5ATable: array[0..31] of Integer = (294,
    295,
    296,
    297,
    297,
    297,
    297,
    297,
    298,
    299,
    300,
    301,
    302,
    297,
    297,
    297,
    297,
    297,
    297,
    297,
    297,
    297,
    297,
    297,
    303,
    304,
    305,
    306,
    297,
    297,
    297,
    297);
  s_OpCodeTable: array[0..255] of Integer = (307,
    308,
    309,
    310,
    310,
    310,
    310,
    310,
    311,
    312,
    313,
    314,
    315,
    316,
    310,
    310,
    317,
    310,
    318,
    319,
    310,
    310,
    310,
    310,
    310,
    320,
    310,
    321,
    322,
    323,
    310,
    310,
    324,
    325,
    326,
    327,
    328,
    329,
    310,
    310,
    310,
    330,
    310,
    331,
    332,
    333,
    310,
    310,
    310,
    310,
    310,
    310,
    310,
    310,
    310,
    310,
    334,
    335,
    336,
    337,
    338,
    339,
    310,
    340,
    341,
    342,
    343,
    344,
    345,
    346,
    310,
    347,
    348,
    349,
    350,
    351,
    310,
    352,
    353,
    354,
    355,
    356,
    357,
    358,
    359,
    360,
    310,
    310,
    361,
    362,
    363,
    364,
    365,
    366,
    310,
    367,
    368,
    369,
    370,
    371,
    372,
    373,
    374,
    375,
    376,
    377,
    378,
    310,
    379,
    380,
    381,
    382,
    383,
    384,
    385,
    386,
    387,
    388,
    389,
    390,
    391,
    392,
    393,
    310,
    394,
    395,
    396,
    397,
    398,
    399,
    400,
    401,
    402,
    403,
    404,
    405,
    406,
    407,
    408,
    409,
    410,
    411,
    310,
    310,
    412,
    413,
    414,
    415,
    416,
    417,
    418,
    419,
    420,
    421,
    422,
    423,
    424,
    425,
    310,
    310,
    426,
    427,
    428,
    429,
    430,
    431,
    432,
    433,
    434,
    435,
    436,
    437,
    438,
    439,
    310,
    310,
    440,
    441,
    442,
    443,
    444,
    445,
    446,
    447,
    448,
    449,
    450,
    451,
    452,
    453,
    310,
    310,
    310,
    310,
    310,
    310,
    310,
    310,
    454,
    455,
    456,
    457,
    458,
    459,
    460,
    461,
    310,
    310,
    462,
    463,
    464,
    465,
    466,
    467,
    468,
    469,
    470,
    471,
    472,
    473,
    474,
    475,
    476,
    477,
    478,
    479,
    480,
    481,
    482,
    483,
    484,
    485,
    486,
    487,
    488,
    489,
    490,
    491,
    492,
    493,
    494,
    495,
    496,
    497,
    498,
    499,
    500,
    501,
    502,
    503,
    504,
    505,
    506,
    507,
    508,
    509);

procedure TV60.v60SaveStack;
begin
  if (Cardinal((Cardinal(m_reg[33]) and Cardinal($10000000))) <> 0) then
    m_reg[36] := m_reg[31]
  else
    m_reg[Cardinal((Cardinal(37) + Cardinal(Cardinal((Cardinal(Cardinal((m_reg[33] shr 24))) and Cardinal(3))))))] := m_reg[31];
end;

procedure TV60.v60ReloadStack;
begin
  if (Cardinal((Cardinal(m_reg[33]) and Cardinal($10000000))) <> 0) then
    m_reg[31] := m_reg[36]
  else
    m_reg[31] := m_reg[Cardinal((Cardinal(37) + Cardinal(Cardinal((Cardinal(Cardinal((m_reg[33] shr 24))) and Cardinal(3))))))];
end;

function TV60.v60ReadPSW: Cardinal;
begin
  m_reg[33] := Cardinal((m_reg[33] and $fffffff0));
  m_reg[33] := Cardinal((m_reg[33] or Cardinal((Cardinal((Cardinal((SelectValue((m_flags.Z <> 0), 1, 0) or SelectValue((m_flags.S <> 0), 2, 0))) or SelectValue((m_flags.OV <> 0), 4, 0))) or SelectValue((m_flags.CY <> 0), 8, 0)))));
  Exit(m_reg[33]);
end;

procedure TV60.v60WritePSW(newval: Cardinal);
begin
  var updateStack: Integer := 0;
  if (Cardinal((Cardinal(Cardinal((newval xor m_reg[33]))) and Cardinal($10000000))) <> 0) then
    updateStack := 1
  else if ((not (Cardinal((Cardinal(m_reg[33]) and Cardinal($10000000))) <> 0)) and (Cardinal((Cardinal(Cardinal((newval xor m_reg[33]))) and Cardinal($03000000))) <> 0)) then
    updateStack := 1;
  if (updateStack <> 0) then
    v60SaveStack();
  m_reg[33] := newval;
  m_flags.Z := Byte(Cardinal((Cardinal(m_reg[33]) and Cardinal(1))));
  m_flags.S := Byte(Cardinal((Cardinal(m_reg[33]) and Cardinal(2))));
  m_flags.OV := Byte(Cardinal((Cardinal(m_reg[33]) and Cardinal(4))));
  m_flags.CY := Byte(Cardinal((Cardinal(m_reg[33]) and Cardinal(8))));
  if (updateStack <> 0) then
    v60ReloadStack();
end;

function TV60.v60_update_psw_for_exception(is_interrupt: Integer; target_level: Integer): Cardinal;
begin
  var oldPSW: Cardinal := v60ReadPSW();
  var newPSW: Cardinal := oldPSW;
  newPSW := Cardinal((Cardinal(newPSW) and Cardinal((not Integer((3 shl 24))))));
  newPSW := Cardinal((newPSW or Cardinal((target_level shl 24))));
  if is_interrupt <> 0 then
    newPSW := newPSW and not Cardinal(1 shl 18);
  newPSW := Cardinal((Cardinal(newPSW) and Cardinal((not Integer((1 shl 16))))));
  newPSW := Cardinal((Cardinal(newPSW) and Cardinal((not Integer((1 shl 27))))));
  newPSW := Cardinal((Cardinal(newPSW) and Cardinal((not Integer((1 shl 17))))));
  newPSW := Cardinal((Cardinal(newPSW) and Cardinal((not Integer((1 shl 29))))));
  if (is_interrupt <> 0) then
    newPSW := Cardinal((Cardinal(newPSW) or Cardinal(Integer((1 shl 28)))));
  newPSW := Cardinal((Cardinal(newPSW) or Cardinal(Integer((1 shl 31)))));
  newPSW := newPSW and not Cardinal($04000000);
  v60WritePSW(newPSW);
  Exit(oldPSW);
end;

function TV60.am1Register: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Byte(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    1:
      begin
        m_amout := Word(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    2:
      begin
        m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
      end;
  end;
  Exit(1);
end;

function TV60.am1RegisterIndirect: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    1:
      begin
        m_amout := Read16(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    2:
      begin
        m_amout := Read32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
  end;
  Exit(1);
end;

function TV60.bam1RegisterIndirect: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
  Exit(1);
end;

function TV60.am1RegisterIndirectIndexed: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(2);
end;

function TV60.bam1RegisterIndirectIndexed: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(2);
end;

function TV60.am1Autoincrement: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
        Inc(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    1:
      begin
        m_amout := Read16(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(2)));
      end;
    2:
      begin
        m_amout := Read32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(4)));
      end;
  end;
  Exit(1);
end;

function TV60.bam1Autoincrement: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
  case m_moddim of
    10:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(1)));
      end;
    11:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(4)));
      end;
  else
    begin
      Illegal();
    end;
  end;
  Exit(1);
end;

function TV60.am1Autodecrement: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Dec(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
        m_amout := Read8(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    1:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(2)));
        m_amout := Read16(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
    2:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(4)));
        m_amout := Read32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
      end;
  end;
  Exit(1);
end;

function TV60.bam1Autodecrement: Cardinal;
begin
  m_bamoffset := 0;
  case m_moddim of
    10:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(1)));
      end;
    11:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(4)));
      end;
  else
    begin
      Illegal();
    end;
  end;
  m_amout := Read32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]);
  Exit(1);
end;

function TV60.am1Displacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
  end;
  Exit(2);
end;

function TV60.bam1Displacement8: Cardinal;
begin
  m_bamoffset := Read8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(2);
end;

function TV60.am1Displacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1Displacement16: Cardinal;
begin
  m_bamoffset := Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1Displacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1Displacement32: Cardinal;
begin
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(5);
end;

function TV60.am1DisplacementIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1DisplacementIndexed8: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1DisplacementIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(4);
end;

function TV60.bam1DisplacementIndexed16: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(4);
end;

function TV60.am1DisplacementIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(6);
end;

function TV60.bam1DisplacementIndexed32: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(6);
end;

function TV60.am1PCDisplacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
  end;
  Exit(2);
end;

function TV60.bam1PCDisplacement8: Cardinal;
begin
  m_bamoffset := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_amout := Read32(Cardinal((m_reg[32] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(2);
end;

function TV60.am1PCDisplacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1PCDisplacement16: Cardinal;
begin
  m_bamoffset := Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_amout := Read32(Cardinal((m_reg[32] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1PCDisplacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1PCDisplacement32: Cardinal;
begin
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_amout := Read32(Cardinal((m_reg[32] + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(5);
end;

function TV60.am1PCDisplacementIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1PCDisplacementIndexed8: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1PCDisplacementIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(4);
end;

function TV60.bam1PCDisplacementIndexed16: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(4);
end;

function TV60.am1PCDisplacementIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(6);
end;

function TV60.bam1PCDisplacementIndexed32: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(6);
end;

function TV60.am1DisplacementIndirect8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
  end;
  Exit(2);
end;

function TV60.bam1DisplacementIndirect8: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
  Exit(2);
end;

function TV60.am1DisplacementIndirect16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1DisplacementIndirect16: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
  Exit(3);
end;

function TV60.am1DisplacementIndirect32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1DisplacementIndirect32: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
  Exit(5);
end;

function TV60.am1DisplacementIndirectIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1DisplacementIndirectIndexed8: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1DisplacementIndirectIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(4);
end;

function TV60.bam1DisplacementIndirectIndexed16: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(4);
end;

function TV60.am1DisplacementIndirectIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(6);
end;

function TV60.bam1DisplacementIndirectIndexed32: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(6);
end;

function TV60.am1PCDisplacementIndirect8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
  end;
  Exit(2);
end;

function TV60.bam1PCDisplacementIndirect8: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
  Exit(2);
end;

function TV60.am1PCDisplacementIndirect16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1PCDisplacementIndirect16: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))));
  Exit(3);
end;

function TV60.am1PCDisplacementIndirect32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1PCDisplacementIndirect32: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
  Exit(5);
end;

function TV60.am1PCDisplacementIndirectIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1PCDisplacementIndirectIndexed8: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1PCDisplacementIndirectIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(4);
end;

function TV60.bam1PCDisplacementIndirectIndexed16: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(4);
end;

function TV60.am1PCDisplacementIndirectIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(6);
end;

function TV60.bam1PCDisplacementIndirectIndexed32: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(6);
end;

function TV60.am1DoubleDisplacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1DoubleDisplacement8: Cardinal;
begin
  m_bamoffset := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))));
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1DoubleDisplacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1DoubleDisplacement16: Cardinal;
begin
  m_bamoffset := Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3))));
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(5);
end;

function TV60.am1DoubleDisplacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))));
      end;
  end;
  Exit(9);
end;

function TV60.bam1DoubleDisplacement32: Cardinal;
begin
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5))));
  m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(9);
end;

function TV60.am1PCDoubleDisplacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
      end;
  end;
  Exit(3);
end;

function TV60.bam1PCDoubleDisplacement8: Cardinal;
begin
  m_bamoffset := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))));
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(3);
end;

function TV60.am1PCDoubleDisplacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1PCDoubleDisplacement16: Cardinal;
begin
  m_bamoffset := Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3))));
  m_amout := Read32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(5);
end;

function TV60.am1PCDoubleDisplacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))));
      end;
  end;
  Exit(9);
end;

function TV60.bam1PCDoubleDisplacement32: Cardinal;
begin
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5))));
  m_amout := Read32(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(9);
end;

function TV60.am1DirectAddress: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
      end;
    1:
      begin
        m_amout := Read16(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
      end;
    2:
      begin
        m_amout := Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1DirectAddress: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  Exit(5);
end;

function TV60.am1DirectAddressIndexed: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(6);
end;

function TV60.bam1DirectAddressIndexed: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(6);
end;

function TV60.am1DirectAddressDeferred: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))));
      end;
    1:
      begin
        m_amout := Read16(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))));
      end;
    2:
      begin
        m_amout := Read32(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))));
      end;
  end;
  Exit(5);
end;

function TV60.bam1DirectAddressDeferred: Cardinal;
begin
  m_bamoffset := 0;
  m_amout := Read32(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))));
  Exit(5);
end;

function TV60.am1DirectAddressDeferredIndexed: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Read8(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])));
      end;
    1:
      begin
        m_amout := Read16(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))));
      end;
    2:
      begin
        m_amout := Read32(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))));
      end;
  end;
  Exit(6);
end;

function TV60.bam1DirectAddressDeferredIndexed: Cardinal;
begin
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_amout := Read32(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + (Cardinal(m_bamoffset) div Cardinal(8)))));
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  Exit(6);
end;

function TV60.am1Immediate: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_amout := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
        Exit(2);
      end;
    1:
      begin
        m_amout := Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
        Exit(3);
      end;
    2:
      begin
        m_amout := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
        Exit(5);
      end;
  end;
  Assert((0 <> 0));
  Exit(1);
end;

function TV60.am1ImmediateQuick: Cardinal;
begin
  m_amout := Cardinal((Cardinal(m_modval) and Cardinal($F)));
  Exit(1);
end;

function TV60.am1Error1: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam1Error1: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am1Error2: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam1Error2: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am1Error4: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam1Error4: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am1Error5: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam1Error5: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam1Error6: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am1Group7a: Cardinal;
begin
  if (not (Cardinal((Cardinal(m_modval2) and Cardinal($10))) <> 0)) then
    Exit(am1Error4());
  Exit(Dispatch(s_AMTable1_G7a[Cardinal((Cardinal(m_modval2) and Cardinal($F)))], 0));
end;

function TV60.bam1Group7a: Cardinal;
begin
  if (not (Cardinal((Cardinal(m_modval2) and Cardinal($10))) <> 0)) then
    Exit(bam1Error4());
  Exit(Dispatch(s_BAMTable1_G7a[Cardinal((Cardinal(m_modval2) and Cardinal($F)))], 0));
end;

function TV60.am1Group6: Cardinal;
begin
  m_modval2 := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(Dispatch(s_AMTable1_G6[Cardinal((m_modval2 shr 5))], 0));
end;

function TV60.bam1Group6: Cardinal;
begin
  m_modval2 := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(Dispatch(s_BAMTable1_G6[Cardinal((m_modval2 shr 5))], 0));
end;

function TV60.am1Group7: Cardinal;
begin
  Exit(Dispatch(s_AMTable1_G7[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], 0));
end;

function TV60.bam1Group7: Cardinal;
begin
  Exit(Dispatch(s_BAMTable1_G7[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], 0));
end;

function TV60.am2Register: Cardinal;
begin
  m_amflag := 1;
  m_amout := Cardinal((Cardinal(m_modval) and Cardinal($1F)));
  Exit(1);
end;

function TV60.am2RegisterIndirect: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(1);
end;

function TV60.bam2RegisterIndirect: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_bamoffset := 0;
  Exit(1);
end;

function TV60.am2RegisterIndirectIndexed: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(2);
end;

function TV60.bam2RegisterIndirectIndexed: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))];
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(2);
end;

function TV60.am2Autoincrement: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  case m_moddim of
    0:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(1)));
      end;
    1:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(2)));
      end;
    2:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(4)));
      end;
    3:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(8)));
      end;
  end;
  Exit(1);
end;

function TV60.bam2Autoincrement: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_bamoffset := 0;
  case m_moddim of
    10:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(1)));
      end;
    11:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(4)));
      end;
  else
    begin
      Illegal();
    end;
  end;
  Exit(1);
end;

function TV60.am2Autodecrement: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(1)));
      end;
    1:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(2)));
      end;
    2:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(4)));
      end;
    3:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(8)));
      end;
  end;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(1);
end;

function TV60.bam2Autodecrement: Cardinal;
begin
  m_amflag := 0;
  m_bamoffset := 0;
  case m_moddim of
    10:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(1)));
      end;
    11:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(4)));
      end;
  else
    begin
      Illegal();
    end;
  end;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(1);
end;

function TV60.am2Displacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
  Exit(2);
end;

function TV60.bam2Displacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_bamoffset := ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  Exit(2);
end;

function TV60.am2Displacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
  Exit(3);
end;

function TV60.bam2Displacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_bamoffset := SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  Exit(3);
end;

function TV60.am2Displacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))));
  Exit(5);
end;

function TV60.bam2Displacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(5);
end;

function TV60.am2DisplacementIndexed8: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(3);
end;

function TV60.bam2DisplacementIndexed8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(3);
end;

function TV60.am2DisplacementIndexed16: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(4);
end;

function TV60.bam2DisplacementIndexed16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(4);
end;

function TV60.am2DisplacementIndexed32: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(6);
end;

function TV60.bam2DisplacementIndexed32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(6);
end;

function TV60.am2PCDisplacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
  Exit(2);
end;

function TV60.bam2PCDisplacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[32];
  m_bamoffset := ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  Exit(2);
end;

function TV60.am2PCDisplacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))));
  Exit(3);
end;

function TV60.bam2PCDisplacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[32];
  m_bamoffset := SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  Exit(3);
end;

function TV60.am2PCDisplacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))));
  Exit(5);
end;

function TV60.bam2PCDisplacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := m_reg[32];
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(5);
end;

function TV60.am2PCDisplacementIndexed8: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(3);
end;

function TV60.bam2PCDisplacementIndexed8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(3);
end;

function TV60.am2PCDisplacementIndexed16: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(4);
end;

function TV60.bam2PCDisplacementIndexed16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(4);
end;

function TV60.am2PCDisplacementIndexed32: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(6);
end;

function TV60.bam2PCDisplacementIndexed32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(6);
end;

function TV60.am2DisplacementIndirect8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  Exit(2);
end;

function TV60.bam2DisplacementIndirect8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := 0;
  Exit(2);
end;

function TV60.am2DisplacementIndirect16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  Exit(3);
end;

function TV60.bam2DisplacementIndirect16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := 0;
  Exit(3);
end;

function TV60.am2DisplacementIndirect32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
  Exit(5);
end;

function TV60.bam2DisplacementIndirect32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
  m_bamoffset := 0;
  Exit(5);
end;

function TV60.am2DisplacementIndirectIndexed8: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(3);
end;

function TV60.bam2DisplacementIndirectIndexed8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(3);
end;

function TV60.am2DisplacementIndirectIndexed16: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(4);
end;

function TV60.bam2DisplacementIndirectIndexed16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(4);
end;

function TV60.am2DisplacementIndirectIndexed32: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(6);
end;

function TV60.bam2DisplacementIndirectIndexed32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(6);
end;

function TV60.am2PCDisplacementIndirect8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  Exit(2);
end;

function TV60.bam2PCDisplacementIndirect8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := 0;
  Exit(2);
end;

function TV60.am2PCDisplacementIndirect16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  Exit(3);
end;

function TV60.bam2PCDisplacementIndirect16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := 0;
  Exit(3);
end;

function TV60.am2PCDisplacementIndirect32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
  Exit(5);
end;

function TV60.bam2PCDisplacementIndirect32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
  m_bamoffset := 0;
  Exit(5);
end;

function TV60.am2PCDisplacementIndirectIndexed8: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(3);
end;

function TV60.bam2PCDisplacementIndirectIndexed8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(3);
end;

function TV60.am2PCDisplacementIndirectIndexed16: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(4);
end;

function TV60.bam2PCDisplacementIndirectIndexed16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(4);
end;

function TV60.am2PCDisplacementIndirectIndexed32: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(6);
end;

function TV60.bam2PCDisplacementIndirectIndexed32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(6);
end;

function TV60.am2DoubleDisplacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))));
  Exit(3);
end;

function TV60.bam2DoubleDisplacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))));
  Exit(3);
end;

function TV60.am2DoubleDisplacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3))))))));
  Exit(5);
end;

function TV60.bam2DoubleDisplacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(3)))));
  Exit(5);
end;

function TV60.am2DoubleDisplacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5))))));
  Exit(9);
end;

function TV60.bam2DoubleDisplacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5))));
  Exit(9);
end;

function TV60.am2PCDoubleDisplacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))));
  Exit(3);
end;

function TV60.bam2PCDoubleDisplacement8: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))));
  Exit(3);
end;

function TV60.am2PCDoubleDisplacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3))))))));
  Exit(5);
end;

function TV60.bam2PCDoubleDisplacement16: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))));
  m_bamoffset := ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(3)))));
  Exit(5);
end;

function TV60.am2PCDoubleDisplacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5))))));
  Exit(9);
end;

function TV60.bam2PCDoubleDisplacement32: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))));
  m_bamoffset := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5))));
  Exit(9);
end;

function TV60.am2DirectAddress: Cardinal;
begin
  m_amflag := 0;
  m_amout := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(5);
end;

function TV60.bam2DirectAddress: Cardinal;
begin
  m_amflag := 0;
  m_amout := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  m_bamoffset := 0;
  Exit(5);
end;

function TV60.am2DirectAddressIndexed: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(6);
end;

function TV60.bam2DirectAddressIndexed: Cardinal;
begin
  m_amflag := 0;
  m_amout := Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(6);
end;

function TV60.am2DirectAddressDeferred: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  Exit(5);
end;

function TV60.bam2DirectAddressDeferred: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))));
  m_bamoffset := 0;
  Exit(5);
end;

function TV60.am2DirectAddressDeferredIndexed: Cardinal;
begin
  m_amflag := 0;
  case m_moddim of
    0:
      begin
        m_amout := Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]));
      end;
    1:
      begin
        m_amout := Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2)))));
      end;
    2:
      begin
        m_amout := Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4)))));
      end;
    3:
      begin
        m_amout := Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(8)))));
      end;
  end;
  Exit(6);
end;

function TV60.bam2DirectAddressDeferredIndexed: Cardinal;
begin
  m_amflag := 0;
  m_amout := Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))));
  m_bamoffset := m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))];
  Exit(6);
end;

function TV60.am2Immediate: Cardinal;
begin
  m_amflag := 0;
  Exit(am1Immediate());
end;

function TV60.am2ImmediateQuick: Cardinal;
begin
  m_amflag := 0;
  Exit(am1ImmediateQuick());
end;

function TV60.am2Error1: Cardinal;
begin
  Illegal();
  Exit(0);
end;

function TV60.am2Error2: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am2Error4: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am2Error5: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam2Error1: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam2Error2: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam2Error4: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam2Error5: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.bam2Error6: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am2Group7a: Cardinal;
begin
  if (not (Cardinal((Cardinal(m_modval2) and Cardinal($10))) <> 0)) then
    Exit(am2Error4());
  Exit(Dispatch(s_AMTable2_G7a[Cardinal((Cardinal(m_modval2) and Cardinal($F)))], 0));
end;

function TV60.bam2Group7a: Cardinal;
begin
  if (not (Cardinal((Cardinal(m_modval2) and Cardinal($10))) <> 0)) then
    Exit(bam2Error4());
  Exit(Dispatch(s_BAMTable2_G7a[Cardinal((Cardinal(m_modval2) and Cardinal($F)))], 0));
end;

function TV60.am2Group6: Cardinal;
begin
  m_modval2 := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(Dispatch(s_AMTable2_G6[Cardinal((m_modval2 shr 5))], 0));
end;

function TV60.bam2Group6: Cardinal;
begin
  m_modval2 := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(Dispatch(s_BAMTable2_G6[Cardinal((m_modval2 shr 5))], 0));
end;

function TV60.am2Group7: Cardinal;
begin
  Exit(Dispatch(s_AMTable2_G7[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], 0));
end;

function TV60.bam2Group7: Cardinal;
begin
  Exit(Dispatch(s_BAMTable2_G7[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], 0));
end;

function TV60.am3Register: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) and Cardinal((not $ff)))) or Cardinal((Cardinal(m_modwritevalb) and Cardinal($ff)))));
      end;
    1:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) and Cardinal((not $ffff)))) or Cardinal((Cardinal(m_modwritevalh) and Cardinal($ffff)))));
      end;
    2:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := m_modwritevalw;
      end;
  end;
  Exit(1);
end;

function TV60.am3RegisterIndirect: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalb);
      end;
    1:
      begin
        Write16(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalh);
      end;
    2:
      begin
        Write32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalw);
      end;
  end;
  Exit(1);
end;

function TV60.am3RegisterIndirectIndexed: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(2);
end;

function TV60.am3Autoincrement: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalb);
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(1)));
      end;
    1:
      begin
        Write16(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalh);
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(2)));
      end;
    2:
      begin
        Write32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalw);
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(4)));
      end;
  end;
  Exit(1);
end;

function TV60.am3Autodecrement: Cardinal;
begin
  case m_moddim of
    0:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(1)));
        Write8(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalb);
      end;
    1:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(2)));
        Write16(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalh);
      end;
    2:
      begin
        m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] := Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) - Cardinal(4)));
        Write32(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], m_modwritevalw);
      end;
  end;
  Exit(1);
end;

function TV60.am3Displacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalw);
      end;
  end;
  Exit(2);
end;

function TV60.am3Displacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3Displacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3DisplacementIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3DisplacementIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(4);
end;

function TV60.am3DisplacementIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(6);
end;

function TV60.am3PCDisplacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalw);
      end;
  end;
  Exit(2);
end;

function TV60.am3PCDisplacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3PCDisplacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3PCDisplacementIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3PCDisplacementIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(4);
end;

function TV60.am3PCDisplacementIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(6);
end;

function TV60.am3DisplacementIndirect8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalw);
      end;
  end;
  Exit(2);
end;

function TV60.am3DisplacementIndirect16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3DisplacementIndirect32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3DisplacementIndirectIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3DisplacementIndirectIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(4);
end;

function TV60.am3DisplacementIndirectIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval2) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(6);
end;

function TV60.am3PCDisplacementIndirect8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalw);
      end;
  end;
  Exit(2);
end;

function TV60.am3PCDisplacementIndirect16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3PCDisplacementIndirect32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3PCDisplacementIndirectIndexed8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3PCDisplacementIndirectIndexed16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(4);
end;

function TV60.am3PCDisplacementIndirectIndexed32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(6);
end;

function TV60.am3DoubleDisplacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3DoubleDisplacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3DoubleDisplacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))), m_modwritevalw);
      end;
  end;
  Exit(9);
end;

function TV60.am3PCDoubleDisplacement8: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(2)))))))), m_modwritevalw);
      end;
  end;
  Exit(3);
end;

function TV60.am3PCDoubleDisplacement16: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Cardinal(Read32(Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(1)))))))))) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_modadd) + Cardinal(3)))))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3PCDoubleDisplacement32: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Cardinal((m_reg[32] + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))))) + Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(5)))))), m_modwritevalw);
      end;
  end;
  Exit(9);
end;

function TV60.am3DirectAddress: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1)))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3DirectAddressIndexed: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(2))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2)))) + Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))]) * Cardinal(4))))), m_modwritevalw);
      end;
  end;
  Exit(6);
end;

function TV60.am3DirectAddressDeferred: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))), m_modwritevalb);
      end;
    1:
      begin
        Write16(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))), m_modwritevalh);
      end;
    2:
      begin
        Write32(Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(1))))), m_modwritevalw);
      end;
  end;
  Exit(5);
end;

function TV60.am3DirectAddressDeferredIndexed: Cardinal;
begin
  case m_moddim of
    0:
      begin
        Write8(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalb);
      end;
    1:
      begin
        Write16(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalh);
      end;
    2:
      begin
        Write32(Cardinal((Read32(Fetch32(Cardinal((Cardinal(m_modadd) + Cardinal(2))))) + m_reg[Cardinal((Cardinal(m_modval) and Cardinal($1F)))])), m_modwritevalw);
      end;
  end;
  Exit(6);
end;

function TV60.am3Immediate: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am3ImmediateQuick: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am3Error1: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am3Error2: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am3Error4: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am3Error5: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.am3Group7a: Cardinal;
begin
  if (not (Cardinal((Cardinal(m_modval2) and Cardinal($10))) <> 0)) then
    Exit(am3Error4());
  Exit(Dispatch(s_AMTable3_G7a[Cardinal((Cardinal(m_modval2) and Cardinal($F)))], 0));
end;

function TV60.am3Group6: Cardinal;
begin
  m_modval2 := Fetch8(Cardinal((Cardinal(m_modadd) + Cardinal(1))));
  Exit(Dispatch(s_AMTable3_G6[Cardinal((m_modval2 shr 5))], 0));
end;

function TV60.am3Group7: Cardinal;
begin
  Exit(Dispatch(s_AMTable3_G7[Cardinal((Cardinal(m_modval) and Cardinal($1F)))], 0));
end;

function TV60.ReadAM: Cardinal;
begin
  m_modm := SelectValue((m_modm <> 0), 1, 0);
  m_modval := Fetch8(m_modadd);
  Exit(Dispatch(s_AMTable1[m_modm][Cardinal((m_modval shr 5))], 0));
end;

function TV60.BitReadAM: Cardinal;
begin
  m_modm := SelectValue((m_modm <> 0), 1, 0);
  m_modval := Fetch8(m_modadd);
  Exit(Dispatch(s_BAMTable1[m_modm][Cardinal((m_modval shr 5))], 0));
end;

function TV60.ReadAMAddress: Cardinal;
begin
  m_modm := SelectValue((m_modm <> 0), 1, 0);
  m_modval := Fetch8(m_modadd);
  Exit(Dispatch(s_AMTable2[m_modm][Cardinal((m_modval shr 5))], 0));
end;

function TV60.BitReadAMAddress: Cardinal;
begin
  m_modm := SelectValue((m_modm <> 0), 1, 0);
  m_modval := Fetch8(m_modadd);
  Exit(Dispatch(s_BAMTable2[m_modm][Cardinal((m_modval shr 5))], 0));
end;

function TV60.WriteAM: Cardinal;
begin
  m_modm := SelectValue((m_modm <> 0), 1, 0);
  m_modval := Fetch8(m_modadd);
  Exit(Dispatch(s_AMTable3[m_modm][Cardinal((m_modval shr 5))], 0));
end;

procedure TV60.F12DecodeFirstOperand(DecodeOp1: Integer; dim1: Byte);
begin
  m_instflags := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  if (Cardinal((Cardinal(m_instflags) and Cardinal($80))) <> 0) then
  begin
    m_moddim := dim1;
    m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($40)));
    m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
    m_amlength1 := Dispatch(DecodeOp1, 0);
    m_op1 := m_amout;
    m_flag1 := m_amflag;
  end
  else
  begin
    if (Cardinal((Cardinal(m_instflags) and Cardinal($20))) <> 0) then
    begin
      m_moddim := dim1;
      m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($40)));
      m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
      m_amlength1 := Dispatch(DecodeOp1, 0);
      m_op1 := m_amout;
      m_flag1 := m_amflag;
    end
    else
    begin
      if (Cardinal(DecodeOp1) = Cardinal(231)) then
      begin
        case dim1 of
          0:
            begin
              m_op1 := Byte(m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))]);
            end;
          1:
            begin
              m_op1 := Word(m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))]);
            end;
          2:
            begin
              m_op1 := m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))];
            end;
        end;
        m_flag1 := 0;
      end
      else
      begin
        m_flag1 := 1;
        m_op1 := Cardinal((Cardinal(m_instflags) and Cardinal($1F)));
      end;
      m_amlength1 := 0;
    end;
  end;
end;

procedure TV60.F12WriteSecondOperand(dim2: Byte);
begin
  m_moddim := dim2;
  if (Cardinal((Cardinal(m_instflags) and Cardinal($80))) <> 0) then
  begin
    m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($20)));
    m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1));
    m_moddim := dim2;
    m_amlength2 := WriteAM();
  end
  else
  begin
    if (Cardinal((Cardinal(m_instflags) and Cardinal($20))) <> 0) then
    begin
      case dim2 of
        0:
          begin
            m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))] := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))]) and Cardinal((not $ff)))) or Cardinal((Cardinal(m_modwritevalb) and Cardinal($ff)))));
          end;
        1:
          begin
            m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))] := Cardinal((Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))]) and Cardinal((not $ffff)))) or Cardinal((Cardinal(m_modwritevalh) and Cardinal($ffff)))));
          end;
        2:
          begin
            m_reg[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))] := m_modwritevalw;
          end;
      end;
      m_amlength2 := 0;
    end
    else
    begin
      m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($40)));
      m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
      m_moddim := dim2;
      m_amlength2 := WriteAM();
    end;
  end;
end;

procedure TV60.F12DecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
begin
  var _if12: Byte := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  if (Integer((_if12 and $80)) <> 0) then
  begin
    m_moddim := dim1;
    m_modm := Integer((_if12 and $40));
    m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
    m_amlength1 := Dispatch(DecodeOp1, 0);
    m_op1 := m_amout;
    m_flag1 := m_amflag;
    m_moddim := dim2;
    m_modm := Integer((_if12 and $20));
    m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1));
    m_amlength2 := Dispatch(DecodeOp2, 0);
    m_op2 := m_amout;
    m_flag2 := m_amflag;
  end
  else
  begin
    if (Integer((_if12 and $20)) <> 0) then
    begin
      if (Cardinal(DecodeOp2) = Cardinal(232)) then
      begin
        m_op2 := Integer((_if12 and $1F));
        m_flag2 := 1;
      end
      else
      begin
        case dim2 of
          0:
            begin
              m_op2 := Byte(m_reg[Integer((_if12 and $1F))]);
            end;
          1:
            begin
              m_op2 := Word(m_reg[Integer((_if12 and $1F))]);
            end;
          2:
            begin
              m_op2 := m_reg[Integer((_if12 and $1F))];
            end;
        end;
      end;
      m_amlength2 := 0;
      m_moddim := dim1;
      m_modm := Integer((_if12 and $40));
      m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
      m_amlength1 := Dispatch(DecodeOp1, 0);
      m_op1 := m_amout;
      m_flag1 := m_amflag;
    end
    else
    begin
      if (Cardinal(DecodeOp1) = Cardinal(232)) then
      begin
        m_op1 := Integer((_if12 and $1F));
        m_flag1 := 1;
      end
      else
      begin
        case dim1 of
          0:
            begin
              m_op1 := Byte(m_reg[Integer((_if12 and $1F))]);
            end;
          1:
            begin
              m_op1 := Word(m_reg[Integer((_if12 and $1F))]);
            end;
          2:
            begin
              m_op1 := m_reg[Integer((_if12 and $1F))];
            end;
        end;
      end;
      m_amlength1 := 0;
      m_moddim := dim2;
      m_modm := Integer((_if12 and $40));
      m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1));
      m_amlength2 := Dispatch(DecodeOp2, 0);
      m_op2 := m_amout;
      m_flag2 := m_amflag;
    end;
  end;
end;

function TV60.opADDB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  begin
    var res: Cardinal := Integer((Integer((appb + Byte(m_op1))) + 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(res) xor Cardinal(Byte(m_op1)))) and Cardinal((Cardinal(res) xor Cardinal(appb)))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    appb := Byte(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opADDH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  begin
    var res: Cardinal := Integer((Integer((apph + Word(m_op1))) + 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(res) xor Cardinal(Word(m_op1)))) and Cardinal((Cardinal(res) xor Cardinal(apph)))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    apph := Word(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opADDW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  begin
    var res: UInt64 := (UInt64((UInt64(appw) + UInt64(Cardinal(m_op1)))) + UInt64(0));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64(((UInt64(res) xor UInt64(Cardinal(m_op1))) and (UInt64(res) xor UInt64(appw)))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    appw := Cardinal(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opADDCB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  begin
    var res: Cardinal := Cardinal((Cardinal(Integer((appb + Byte(m_op1)))) + Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(res) xor Cardinal(Byte(m_op1)))) and Cardinal((Cardinal(res) xor Cardinal(appb)))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    appb := Byte(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opADDCH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  begin
    var res: Cardinal := Cardinal((Cardinal(Integer((apph + Word(m_op1)))) + Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(res) xor Cardinal(Word(m_op1)))) and Cardinal((Cardinal(res) xor Cardinal(apph)))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    apph := Word(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opADDCW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  begin
    var res: UInt64 := (UInt64((UInt64(appw) + UInt64(Cardinal(m_op1)))) + UInt64(SelectValue((m_flags.CY <> 0), 1, 0)));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64(((UInt64(res) xor UInt64(Cardinal(m_op1))) and (UInt64(res) xor UInt64(appw)))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    appw := Cardinal(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opANDB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  appb := Cardinal((Cardinal(appb) and Cardinal(m_op1)));
  m_flags.OV := 0;
  m_flags.S := Ord((Integer((appb and $80)) <> 0));
  m_flags.Z := Ord((appb = 0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opANDH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  apph := Cardinal((Cardinal(apph) and Cardinal(m_op1)));
  m_flags.OV := 0;
  m_flags.S := Ord((Integer((apph and $8000)) <> 0));
  m_flags.Z := Ord((apph = 0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opANDW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  appw := Cardinal((appw and m_op1));
  m_flags.OV := 0;
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCALL: Cardinal;
begin
  F12DecodeOperands(232, 0, 232, 2);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], m_reg[29]);
  m_reg[29] := m_op2;
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(Cardinal((Cardinal((m_reg[32] + m_amlength1)) + m_amlength2))) + Cardinal(2))));
  m_reg[32] := m_op1;
  Exit(0);
end;

function TV60.opCHKAR: Cardinal;
begin
  F12DecodeOperands(231, 0, 231, 0);
  m_flags.Z := 1;
  m_flags.CY := 0;
  m_flags.S := 0;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCHKAW: Cardinal;
begin
  F12DecodeOperands(231, 0, 231, 0);
  m_flags.Z := 1;
  m_flags.CY := 0;
  m_flags.S := 0;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCHKAE: Cardinal;
begin
  F12DecodeOperands(231, 0, 231, 0);
  m_flags.Z := 1;
  m_flags.CY := 0;
  m_flags.S := 0;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCHLVL: Cardinal;
begin
  var oldPSW: Cardinal;
  F12DecodeOperands(231, 0, 231, 0);
  if (Cardinal(m_op1) > Cardinal(3)) then
  begin
    Illegal();
  end;
  oldPSW := v60_update_psw_for_exception(0, m_op1);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], m_op2);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(Cardinal((Cardinal((Cardinal($1800) + Cardinal(Cardinal((Cardinal(m_op1) * Cardinal($100)))))) shl 16))) or Cardinal(8))));
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], oldPSW);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(Cardinal((Cardinal((m_reg[32] + m_amlength1)) + m_amlength2))) + Cardinal(2))));
  m_reg[32] := Read32(Cardinal((Cardinal((Cardinal(m_reg[41]) and Cardinal((not $fff)))) + Cardinal((Cardinal(Cardinal((Cardinal(24) + Cardinal(m_op1)))) * Cardinal(4))))));
  Exit(0);
end;

function TV60.opCLR1: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  m_flags.CY := Ord((Cardinal(Cardinal((Cardinal(appw) and Cardinal(Integer((1 shl m_op1)))))) <> Cardinal(0)));
  m_flags.Z := Ord((not (m_flags.CY <> 0)));
  appw := Cardinal((Cardinal(appw) and Cardinal((not Integer((1 shl m_op1))))));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCMPB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 231, 0);
  appb := Byte(m_op2);
  begin
    var res: Cardinal := Integer((Integer((appb - Byte(m_op1))) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((appb xor Byte(m_op1)))) and Cardinal(Cardinal((Cardinal(appb) xor Cardinal(res))))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCMPH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 231, 1);
  apph := Word(m_op2);
  begin
    var res: Cardinal := Integer((Integer((apph - Word(m_op1))) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((apph xor Word(m_op1)))) and Cardinal(Cardinal((Cardinal(apph) xor Cardinal(res))))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opCMPW: Cardinal;
begin
  F12DecodeOperands(231, 2, 231, 2);
  begin
    var res: UInt64 := (UInt64((UInt64(UInt64(m_op2)) - UInt64(Int64(Cardinal(m_op1))))) - UInt64(0));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64((UInt64(Cardinal((m_op2 xor Cardinal(m_op1)))) and UInt64((UInt64(m_op2) xor UInt64(res))))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    m_op2 := Cardinal(res);
  end;
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opDIVB: Cardinal;
begin
  Result := DivideInteger(0, False, False);
end;

function TV60.opDIVH: Cardinal;
begin
  Result := DivideInteger(1, False, False);
end;

function TV60.opDIVW: Cardinal;
begin
  Result := DivideInteger(2, False, False);
end;

function TV60.opDIVX: Cardinal;
begin
  Result := DivideInteger(2, False, True);
end;

function TV60.opDIVUX: Cardinal;
begin
  Result := DivideInteger(2, True, True);
end;

function TV60.opDIVUB: Cardinal;
begin
  Result := DivideInteger(0, True, False);
end;

function TV60.opDIVUH: Cardinal;
begin
  Result := DivideInteger(1, True, False);
end;

function TV60.opDIVUW: Cardinal;
begin
  Result := DivideInteger(2, True, False);
end;

function TV60.opINB: Cardinal;
begin
  F12DecodeFirstOperand(232, 0);
  m_modwritevalb := IORead8(m_op1);
  if (m_stall_io <> 0) then
  begin
    m_stall_io := 0;
    Exit(0);
  end;
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opINH: Cardinal;
begin
  F12DecodeFirstOperand(232, 1);
  m_modwritevalh := IORead16(m_op1);
  if (m_stall_io <> 0) then
  begin
    m_stall_io := 0;
    Exit(0);
  end;
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opINW: Cardinal;
begin
  F12DecodeFirstOperand(232, 2);
  m_modwritevalw := IORead32(m_op1);
  if (m_stall_io <> 0) then
  begin
    m_stall_io := 0;
    Exit(0);
  end;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opLDPR: Cardinal;
begin
  F12DecodeOperands(232, 2, 231, 2);
  if (Cardinal(m_op2) <= Cardinal(28)) then
  begin
    if (m_flag1 <> 0) then
      m_reg[Cardinal((Cardinal(m_op2) + Cardinal(36)))] := m_reg[m_op1]
    else
      m_reg[Cardinal((Cardinal(m_op2) + Cardinal(36)))] := m_op1;
  end
  else
  begin
    Illegal();
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opLDTASK: Cardinal;
begin
  var i: Integer;
  F12DecodeOperands(232, 2, 231, 2);
  v60WritePSW(Cardinal((v60ReadPSW() and $efffffff)));
  m_reg[42] := m_op2;
  m_reg[44] := Read32(m_op2);
  m_op2 := Cardinal((Cardinal(m_op2) + Cardinal(4)));
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($100))) <> 0) then
  begin
    m_reg[37] := Read32(m_op2);
    m_op2 := Cardinal((Cardinal(m_op2) + Cardinal(4)));
  end;
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($200))) <> 0) then
  begin
    m_reg[38] := Read32(m_op2);
    m_op2 := Cardinal((Cardinal(m_op2) + Cardinal(4)));
  end;
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($400))) <> 0) then
  begin
    m_reg[39] := Read32(m_op2);
    m_op2 := Cardinal((Cardinal(m_op2) + Cardinal(4)));
  end;
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($800))) <> 0) then
  begin
    m_reg[40] := Read32(m_op2);
    m_op2 := Cardinal((Cardinal(m_op2) + Cardinal(4)));
  end;
  v60ReloadStack();
  i := 0;
  while (i < 31) do
  begin
    if (Cardinal((Cardinal(m_op1) and Cardinal(Integer((1 shl i))))) <> 0) then
    begin
      m_reg[i] := Read32(m_op2);
      m_op2 := Cardinal((Cardinal(m_op2) + Cardinal(4)));
    end;
    Inc(i);
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVD: Cardinal;
begin
  var d: UInt64;
  F12DecodeOperands(232, 3, 232, 3);
  if (m_flag1 <> 0) then
    d := (UInt64((UInt64(m_reg[Cardinal((Cardinal(Cardinal((Cardinal(m_op1) and Cardinal($1F)))) + Cardinal(1)))]) shl 32)) or UInt64(m_reg[Cardinal((Cardinal(m_op1) and Cardinal($1F)))]))
  else
    d := Read64(m_op1);
  if (m_flag2 <> 0) then
  begin
    m_reg[Cardinal((Cardinal(m_op2) and Cardinal($1F)))] := Cardinal(d);
    m_reg[Cardinal((Cardinal(Cardinal((Cardinal(m_op2) and Cardinal($1F)))) + Cardinal(1)))] := Cardinal((d shr 32));
  end
  else
    Write64(m_op2, d);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVB: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalb := Byte(m_op1);
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVH: Cardinal;
begin
  F12DecodeFirstOperand(231, 1);
  m_modwritevalh := Word(m_op1);
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVW: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  m_modwritevalw := m_op1;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVEAB: Cardinal;
begin
  F12DecodeFirstOperand(232, 0);
  m_modwritevalw := m_op1;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVEAH: Cardinal;
begin
  F12DecodeFirstOperand(232, 1);
  m_modwritevalw := m_op1;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVEAW: Cardinal;
begin
  F12DecodeFirstOperand(232, 2);
  m_modwritevalw := m_op1;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVSBH: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalh := ShortInt(Cardinal((Cardinal(m_op1) and Cardinal($FF))));
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVSBW: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalw := ShortInt(Cardinal((Cardinal(m_op1) and Cardinal($FF))));
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVSHW: Cardinal;
begin
  F12DecodeFirstOperand(231, 1);
  m_modwritevalw := SmallInt(Cardinal((Cardinal(m_op1) and Cardinal($FFFF))));
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVTHB: Cardinal;
begin
  F12DecodeFirstOperand(231, 1);
  m_modwritevalb := Byte(Cardinal((Cardinal(m_op1) and Cardinal($FF))));
  if (((Cardinal(Cardinal((Cardinal(m_modwritevalb) and Cardinal($80)))) = Cardinal($80)) and (Cardinal(Cardinal((Cardinal(m_op1) and Cardinal($FF00)))) = Cardinal($FF00))) or ((Cardinal(Cardinal((Cardinal(m_modwritevalb) and Cardinal($80)))) = Cardinal(0)) and (Cardinal(Cardinal((Cardinal(m_op1) and Cardinal($FF00)))) = Cardinal($0000)))) then
    m_flags.OV := 0
  else
    m_flags.OV := 1;
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVTWB: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  m_modwritevalb := Byte(Cardinal((Cardinal(m_op1) and Cardinal($FF))));
  if (((Cardinal(Cardinal((Cardinal(m_modwritevalb) and Cardinal($80)))) = Cardinal($80)) and (Cardinal((m_op1 and $FFFFFF00)) = $FFFFFF00)) or ((Cardinal(Cardinal((Cardinal(m_modwritevalb) and Cardinal($80)))) = Cardinal(0)) and (Cardinal(Cardinal((m_op1 and $FFFFFF00))) = Cardinal($00000000)))) then
    m_flags.OV := 0
  else
    m_flags.OV := 1;
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVTWH: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  m_modwritevalh := Word(Cardinal((Cardinal(m_op1) and Cardinal($FFFF))));
  if (((Cardinal(Cardinal((Cardinal(m_modwritevalh) and Cardinal($8000)))) = Cardinal($8000)) and (Cardinal((m_op1 and $FFFF0000)) = $FFFF0000)) or ((Cardinal(Cardinal((Cardinal(m_modwritevalh) and Cardinal($8000)))) = Cardinal(0)) and (Cardinal(Cardinal((m_op1 and $FFFF0000))) = Cardinal($00000000)))) then
    m_flags.OV := 0
  else
    m_flags.OV := 1;
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVZBH: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalh := Word(m_op1);
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVZBW: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalw := m_op1;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMOVZHW: Cardinal;
begin
  F12DecodeFirstOperand(231, 1);
  m_modwritevalw := m_op1;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMULB: Cardinal;
begin
  Result := MultiplySignedInteger(0);
end;

function TV60.opMULH: Cardinal;
begin
  Result := MultiplySignedInteger(1);
end;

function TV60.opMULW: Cardinal;
begin
  Result := MultiplySignedInteger(2);
end;

function TV60.opMULUB: Cardinal;
begin
  var appb: Byte;
  var tmp: Cardinal;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  tmp := Integer((appb * Byte(m_op1)));
  appb := tmp;
  m_flags.Z := Ord((appb = 0));
  m_flags.S := Ord((Integer((appb and $80)) <> 0));
  m_flags.OV := Ord((Cardinal(Cardinal((tmp shr 8))) <> Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMULUH: Cardinal;
begin
  var apph: Word;
  var tmp: Cardinal;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  tmp := Integer((apph * Word(m_op1)));
  apph := tmp;
  m_flags.Z := Ord((apph = 0));
  m_flags.S := Ord((Integer((apph and $8000)) <> 0));
  m_flags.OV := Ord((Cardinal(Cardinal((tmp shr 16))) <> Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMULUW: Cardinal;
begin
  var appw: Cardinal;
  var tmp: UInt64;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  tmp := mulu_32x32(appw, m_op1);
  appw := tmp;
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.OV := Ord((UInt64((tmp shr 32)) <> UInt64(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNEGB: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalb := 0;
  begin
    var res: Cardinal := Cardinal((Cardinal(Cardinal((Cardinal(m_modwritevalb) - Cardinal(ShortInt(m_op1))))) - Cardinal(0)));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(m_modwritevalb) xor Cardinal(ShortInt(m_op1)))) and Cardinal((m_modwritevalb xor res))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    m_modwritevalb := Byte(res);
  end;
  ;
  m_flags.CY := SelectValue((m_modwritevalb <> 0), 1, 0);
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNEGH: Cardinal;
begin
  F12DecodeFirstOperand(231, 1);
  m_modwritevalh := 0;
  begin
    var res: Cardinal := Cardinal((Cardinal(Cardinal((Cardinal(m_modwritevalh) - Cardinal(SmallInt(m_op1))))) - Cardinal(0)));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(m_modwritevalh) xor Cardinal(SmallInt(m_op1)))) and Cardinal((m_modwritevalh xor res))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    m_modwritevalh := Word(res);
  end;
  ;
  m_flags.CY := SelectValue((m_modwritevalh <> 0), 1, 0);
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNEGW: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  m_modwritevalw := 0;
  begin
    var res: UInt64 := (UInt64((UInt64(UInt64(m_modwritevalw)) - UInt64(Int64(Integer(m_op1))))) - UInt64(0));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64((UInt64(Cardinal((Cardinal(m_modwritevalw) xor Cardinal(Integer(m_op1))))) and UInt64((UInt64(m_modwritevalw) xor UInt64(res))))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    m_modwritevalw := Cardinal(res);
  end;
  ;
  m_flags.CY := SelectValue((m_modwritevalw <> 0), 1, 0);
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNOTB: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalb := (not m_op1);
  m_flags.OV := 0;
  m_flags.S := Ord((Cardinal(Cardinal((Cardinal(m_modwritevalb) and Cardinal($80)))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(m_modwritevalb) = Cardinal(0)));
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNOTH: Cardinal;
begin
  F12DecodeFirstOperand(231, 1);
  m_modwritevalh := (not m_op1);
  m_flags.OV := 0;
  m_flags.S := Ord((Cardinal(Cardinal((Cardinal(m_modwritevalh) and Cardinal($8000)))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(m_modwritevalh) = Cardinal(0)));
  F12WriteSecondOperand(1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNOTW: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  m_modwritevalw := (not m_op1);
  m_flags.OV := 0;
  m_flags.S := Ord((Cardinal(Cardinal((m_modwritevalw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(m_modwritevalw) = Cardinal(0)));
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opNOT1: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  m_flags.CY := Ord((Cardinal(Cardinal((Cardinal(appw) and Cardinal(Integer((1 shl m_op1)))))) <> Cardinal(0)));
  m_flags.Z := Ord((not (m_flags.CY <> 0)));
  if (m_flags.CY <> 0) then
    appw := Cardinal((Cardinal(appw) and Cardinal((not Integer((1 shl m_op1))))))
  else
    appw := Cardinal((Cardinal(appw) or Cardinal(Integer((1 shl m_op1)))));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opORB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  begin
    appb := Integer((appb or Byte(m_op1)));
    m_flags.OV := 0;
    begin
      m_flags.Z := Ord((Byte(appb) = 0));
      m_flags.S := SelectValue((Integer((appb and $80)) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opORH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  begin
    apph := Integer((apph or Word(m_op1)));
    m_flags.OV := 0;
    begin
      m_flags.Z := Ord((Word(apph) = 0));
      m_flags.S := SelectValue((Integer((apph and $8000)) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opORW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  begin
    appw := Cardinal((appw or Cardinal(m_op1)));
    m_flags.OV := 0;
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(appw)) = Cardinal(0)));
      m_flags.S := SelectValue((Cardinal((appw and $80000000)) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opOUTB: Cardinal;
begin
  F12DecodeOperands(231, 0, 232, 2);
  IOWrite8(m_op2, Byte(m_op1));
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opOUTH: Cardinal;
begin
  F12DecodeOperands(231, 1, 232, 2);
  IOWrite16(m_op2, Word(m_op1));
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opOUTW: Cardinal;
begin
  F12DecodeOperands(231, 2, 232, 2);
  IOWrite32(m_op2, m_op1);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opREMB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  m_flags.OV := 0;
  if (m_op1 <> 0) then
    appb := (ShortInt(appb) mod ShortInt(m_op1));
  m_flags.Z := Ord((appb = 0));
  m_flags.S := Ord((Integer((appb and $80)) <> 0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opREMH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  m_flags.OV := 0;
  if (m_op1 <> 0) then
    apph := (SmallInt(apph) mod SmallInt(m_op1));
  m_flags.Z := Ord((apph = 0));
  m_flags.S := Ord((Integer((apph and $8000)) <> 0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opREMW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  m_flags.OV := 0;
  if (m_op1 <> 0) then
    appw := (Integer(appw) mod Integer(m_op1));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opREMUB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  m_flags.OV := 0;
  if (m_op1 <> 0) then
    appb := (appb mod Byte(m_op1));
  m_flags.Z := Ord((appb = 0));
  m_flags.S := Ord((Integer((appb and $80)) <> 0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opREMUH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  m_flags.OV := 0;
  if (m_op1 <> 0) then
    apph := (apph mod Word(m_op1));
  m_flags.Z := Ord((apph = 0));
  m_flags.S := Ord((Integer((apph and $8000)) <> 0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opREMUW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  m_flags.OV := 0;
  if (m_op1 <> 0) then
    appw := (appw mod m_op1);
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opROTB: Cardinal;
begin
  Result := ShiftRotateInteger(0, 2);
end;

function TV60.opROTH: Cardinal;
begin
  Result := ShiftRotateInteger(1, 2);
end;

function TV60.opROTW: Cardinal;
begin
  Result := ShiftRotateInteger(2, 2);
end;

function TV60.opROTCB: Cardinal;
begin
  Result := ShiftRotateInteger(0, 3);
end;

function TV60.opROTCH: Cardinal;
begin
  Result := ShiftRotateInteger(1, 3);
end;

function TV60.opROTCW: Cardinal;
begin
  Result := ShiftRotateInteger(2, 3);
end;

function TV60.opRVBIT: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  m_modwritevalb := ReverseBits8(m_op1, 0, 1, 2, 3, 4, 5, 6, 7);
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opRVBYT: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  m_modwritevalw := swapendian_int32(m_op1);
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSET1: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  m_flags.CY := Ord((Cardinal(Cardinal((Cardinal(appw) and Cardinal(Integer((1 shl m_op1)))))) <> Cardinal(0)));
  m_flags.Z := Ord((not (m_flags.CY <> 0)));
  appw := Cardinal((Cardinal(appw) or Cardinal(Integer((1 shl m_op1)))));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSETF: Cardinal;
begin
  F12DecodeFirstOperand(231, 0);
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  case Cardinal((Cardinal(m_op1) and Cardinal($F))) of
    0:
      begin
        if (not (m_flags.OV <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    1:
      begin
        if (m_flags.OV <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    2:
      begin
        if (not (m_flags.CY <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    3:
      begin
        if (m_flags.CY <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    4:
      begin
        if (not (m_flags.Z <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    5:
      begin
        if (m_flags.Z <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    6:
      begin
        if (not (Integer((m_flags.CY or m_flags.Z)) <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    7:
      begin
        if (Integer((m_flags.CY or m_flags.Z)) <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    8:
      begin
        if (not (m_flags.S <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    9:
      begin
        if (m_flags.S <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    10:
      begin
        m_modwritevalb := 1;
      end;
    11:
      begin
        m_modwritevalb := 0;
      end;
    12:
      begin
        if (not (Integer((m_flags.S xor m_flags.OV)) <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    13:
      begin
        if (Integer((m_flags.S xor m_flags.OV)) <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    14:
      begin
        if (not (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0)) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
    15:
      begin
        if (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0) then
          m_modwritevalb := 0
        else
          m_modwritevalb := 1;
      end;
  end;
  F12WriteSecondOperand(0);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSHAB: Cardinal;
begin
  Result := ShiftRotateInteger(0, 0);
end;

function TV60.opSHAH: Cardinal;
begin
  Result := ShiftRotateInteger(1, 0);
end;

function TV60.opSHAW: Cardinal;
begin
  Result := ShiftRotateInteger(2, 0);
end;

function TV60.opSHLB: Cardinal;
begin
  Result := ShiftRotateInteger(0, 1);
end;

function TV60.opSHLH: Cardinal;
begin
  Result := ShiftRotateInteger(1, 1);
end;

function TV60.opSHLW: Cardinal;
begin
  Result := ShiftRotateInteger(2, 1);
end;

function TV60.opSTPR: Cardinal;
begin
  F12DecodeFirstOperand(231, 2);
  if (Cardinal(m_op1) <= Cardinal(28)) then
    m_modwritevalw := m_reg[Cardinal((Cardinal(m_op1) + Cardinal(36)))]
  else
  begin
    Illegal();
  end;
  F12WriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSUBB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  begin
    var res: Cardinal := Integer((Integer((appb - Byte(m_op1))) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((appb xor Byte(m_op1)))) and Cardinal(Cardinal((Cardinal(appb) xor Cardinal(res))))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    appb := Byte(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSUBH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  begin
    var res: Cardinal := Integer((Integer((apph - Word(m_op1))) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((apph xor Word(m_op1)))) and Cardinal(Cardinal((Cardinal(apph) xor Cardinal(res))))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    apph := Word(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSUBW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  begin
    var res: UInt64 := (UInt64((UInt64(UInt64(appw)) - UInt64(Int64(Cardinal(m_op1))))) - UInt64(0));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64((UInt64(Cardinal((appw xor Cardinal(m_op1)))) and UInt64((UInt64(appw) xor UInt64(res))))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    appw := Cardinal(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSUBCB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  begin
    var res: Cardinal := Cardinal((Cardinal(Integer((appb - Byte(m_op1)))) - Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((appb xor Byte(m_op1)))) and Cardinal(Cardinal((Cardinal(appb) xor Cardinal(res))))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    appb := Byte(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSUBCH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  begin
    var res: Cardinal := Cardinal((Cardinal(Integer((apph - Word(m_op1)))) - Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((apph xor Word(m_op1)))) and Cardinal(Cardinal((Cardinal(apph) xor Cardinal(res))))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    apph := Word(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opSUBCW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  begin
    var res: UInt64 := (UInt64((UInt64(UInt64(appw)) - UInt64(Int64(Cardinal(m_op1))))) - UInt64(SelectValue((m_flags.CY <> 0), 1, 0)));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64((UInt64(Cardinal((appw xor Cardinal(m_op1)))) and UInt64((UInt64(appw) xor UInt64(res))))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    appw := Cardinal(res);
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opTEST1: Cardinal;
begin
  F12DecodeOperands(231, 2, 231, 2);
  m_flags.CY := Ord((Cardinal(Cardinal((Cardinal(m_op2) and Cardinal(Integer((1 shl m_op1)))))) <> Cardinal(0)));
  m_flags.Z := Ord((not (m_flags.CY <> 0)));
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opUPDPSWW: Cardinal;
begin
  F12DecodeOperands(231, 2, 231, 2);
  m_op2 := Cardinal((Cardinal(m_op2) and Cardinal($FFFFFF)));
  m_op1 := Cardinal((Cardinal(m_op1) and Cardinal($FFFFFF)));
  v60WritePSW(Cardinal((Cardinal((v60ReadPSW() and (not m_op2))) or Cardinal((m_op1 and m_op2)))));
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opUPDPSWH: Cardinal;
begin
  F12DecodeOperands(231, 2, 231, 2);
  m_op2 := Cardinal((Cardinal(m_op2) and Cardinal($FFFF)));
  m_op1 := Cardinal((Cardinal(m_op1) and Cardinal($FFFF)));
  v60WritePSW(Cardinal((Cardinal((v60ReadPSW() and (not m_op2))) or Cardinal((m_op1 and m_op2)))));
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opXCHB: Cardinal;
begin
  var appb: Byte;
  var temp: Byte;
  F12DecodeOperands(232, 0, 232, 0);
  if (m_flag1 <> 0) then
    appb := Byte(m_reg[m_op1])
  else
    appb := Read8(m_op1);
  ;
  temp := appb;
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  if (m_flag1 <> 0) then
    m_reg[m_op1] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op1]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op1, appb);
  ;
  appb := temp;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
end;

function TV60.opXCHH: Cardinal;
begin
  var apph: Word;
  var temp: Word;
  F12DecodeOperands(232, 1, 232, 1);
  if (m_flag1 <> 0) then
    apph := Word(m_reg[m_op1])
  else
    apph := Read16(m_op1);
  ;
  temp := apph;
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  if (m_flag1 <> 0) then
    m_reg[m_op1] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op1]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op1, apph);
  ;
  apph := temp;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
end;

function TV60.opXCHW: Cardinal;
begin
  var appw: Cardinal;
  var temp: Cardinal;
  F12DecodeOperands(232, 2, 232, 2);
  if (m_flag1 <> 0) then
    appw := m_reg[m_op1]
  else
    appw := Read32(m_op1);
  ;
  temp := appw;
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  if (m_flag1 <> 0) then
    m_reg[m_op1] := appw
  else
    Write32(m_op1, appw);
  ;
  appw := temp;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
end;

function TV60.opXORB: Cardinal;
begin
  var appb: Byte;
  F12DecodeOperands(231, 0, 232, 0);
  if (m_flag2 <> 0) then
    appb := Byte(m_reg[m_op2])
  else
    appb := Read8(m_op2);
  ;
  begin
    appb := Integer((appb xor Byte(m_op1)));
    m_flags.OV := 0;
    begin
      m_flags.Z := Ord((Byte(appb) = 0));
      m_flags.S := SelectValue((Integer((appb and $80)) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opXORH: Cardinal;
begin
  var apph: Word;
  F12DecodeOperands(231, 1, 232, 1);
  if (m_flag2 <> 0) then
    apph := Word(m_reg[m_op2])
  else
    apph := Read16(m_op2);
  ;
  begin
    apph := Integer((apph xor Word(m_op1)));
    m_flags.OV := 0;
    begin
      m_flags.Z := Ord((Word(apph) = 0));
      m_flags.S := SelectValue((Integer((apph and $8000)) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opXORW: Cardinal;
begin
  var appw: Cardinal;
  F12DecodeOperands(231, 2, 232, 2);
  if (m_flag2 <> 0) then
    appw := m_reg[m_op2]
  else
    appw := Read32(m_op2);
  ;
  begin
    appw := Cardinal((appw xor Cardinal(m_op1)));
    m_flags.OV := 0;
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(appw)) = Cardinal(0)));
      m_flags.S := SelectValue((Cardinal((appw and $80000000)) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := appw
  else
    Write32(m_op2, appw);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMULX: Cardinal;
begin
  var a: Integer;
  var b: Integer;
  var res: Int64;
  F12DecodeOperands(231, 2, 232, 3);
  if (m_flag2 <> 0) then
  begin
    a := m_reg[Cardinal((Cardinal(m_op2) and Cardinal($1F)))];
  end
  else
  begin
    a := Read32(m_op2);
  end;
  res := mul_32x32(a, m_op1);
  b := Integer((Int64(ArithmeticShift(res, 32)) and Int64($ffffffff)));
  a := Integer((Int64(res) and Int64($ffffffff)));
  m_flags.S := Ord((Cardinal(Cardinal((Cardinal(b) and Cardinal($80000000)))) <> Cardinal(0)));
  m_flags.Z := Ord(((a = 0) and (b = 0)));
  if (m_flag2 <> 0) then
  begin
    m_reg[Cardinal((Cardinal(m_op2) and Cardinal($1F)))] := a;
    m_reg[Cardinal((Cardinal(Cardinal((Cardinal(m_op2) and Cardinal($1F)))) + Cardinal(1)))] := b;
  end
  else
    Write64(m_op2, res);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

function TV60.opMULUX: Cardinal;
begin
  var a: Integer;
  var b: Integer;
  var res: UInt64;
  F12DecodeOperands(231, 2, 232, 3);
  if (m_flag2 <> 0) then
  begin
    a := m_reg[Cardinal((Cardinal(m_op2) and Cardinal($1F)))];
  end
  else
  begin
    a := Read32(m_op2);
  end;
  res := mulu_32x32(a, m_op1);
  b := Integer((UInt64((res shr 32)) and UInt64($ffffffff)));
  a := Integer((UInt64(res) and UInt64($ffffffff)));
  m_flags.S := Ord((Cardinal(Cardinal((Cardinal(b) and Cardinal($80000000)))) <> Cardinal(0)));
  m_flags.Z := Ord(((a = 0) and (b = 0)));
  if (m_flag2 <> 0) then
  begin
    m_reg[Cardinal((Cardinal(m_op2) and Cardinal($1F)))] := a;
    m_reg[Cardinal((Cardinal(Cardinal((Cardinal(m_op2) and Cardinal($1F)))) + Cardinal(1)))] := b;
  end
  else
    Write64(m_op2, res);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(2))));
  ;
end;

procedure TV60.F2DecodeFirstOperand(DecodeOp1: Integer; dim1: Byte);
begin
  m_moddim := dim1;
  m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($40)));
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
  m_amlength1 := Dispatch(DecodeOp1, 0);
  m_op1 := m_amout;
  m_flag1 := m_amflag;
end;

procedure TV60.F2DecodeSecondOperand(DecodeOp2: Integer; dim2: Byte);
begin
  m_moddim := dim2;
  m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($20)));
  m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1));
  m_amlength2 := Dispatch(DecodeOp2, 0);
  m_op2 := m_amout;
  m_flag2 := m_amflag;
end;

procedure TV60.F2WriteSecondOperand(dim2: Byte);
begin
  m_moddim := dim2;
  m_modm := Cardinal((Cardinal(m_instflags) and Cardinal($20)));
  m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1));
  m_amlength2 := WriteAM();
end;

function TV60.opCVTWS: Cardinal;
begin
  var val: Single;
  F2DecodeFirstOperand(231, 2);
  val := Single(Integer(m_op1));
  m_modwritevalw := f2u(val);
  m_flags.OV := 0;
  m_flags.CY := Ord((val < 0.0));
  m_flags.S := Ord((Cardinal(Cardinal((m_modwritevalw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((val = 0.0));
  F2WriteSecondOperand(2);
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
  ;
end;

function TV60.opCVTSW: Cardinal;
begin
  var val: Single;
  F2DecodeFirstOperand(231, 2);
  val := u2f(m_op1);
  case Cardinal((Cardinal(m_reg[44]) and Cardinal(7))) of
    0:
      begin
        val := roundf(val);
      end;
    1:
      begin
        val := floorf(val);
      end;
    2:
      begin
        val := ceilf(val);
      end;
  else
    begin
      val := truncf(val);
    end;
  end;
  m_modwritevalw := Cardinal(Int64(Trunc(val)));
  m_flags.S := Ord((Cardinal(Cardinal((m_modwritevalw and $80000000))) <> Cardinal(0)));
  m_flags.OV := Ord((((m_flags.S <> 0) and (val >= 0.0)) or ((not (m_flags.S <> 0)) and (val <= (-1.0)))));
  m_flags.Z := Ord((Cardinal(m_modwritevalw) = Cardinal(0)));
  F2WriteSecondOperand(2);
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
  ;
end;

function TV60.opMOVFS: Cardinal;
begin
  F2DecodeFirstOperand(231, 2);
  m_modwritevalw := m_op1;
  F2WriteSecondOperand(2);
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
  ;
end;

function TV60.opNEGFS: Cardinal;
begin
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(232, 2);
  appf := (-u2f(m_op1));
  m_flags.OV := 0;
  m_flags.CY := Ord((appf < 0.0));
  m_flags.S := Ord((Cardinal(Cardinal((f2u(appf) and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((appf = 0.0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opABSFS: Cardinal;
begin
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(232, 2);
  appf := u2f(m_op1);
  if (appf < 0) then
    appf := (-appf);
  m_flags.OV := 0;
  m_flags.CY := 0;
  m_flags.S := Ord((Cardinal(Cardinal((f2u(appf) and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((appf = 0.0));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opADDFS: Cardinal;
begin
  var appw: Cardinal;
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(232, 2);
  if (m_flag2 <> 0) then
    appf := u2f(m_reg[m_op2])
  else
    appf := u2f(Read32(m_op2));
  ;
  appf := (appf + u2f(m_op1));
  appw := f2u(appf);
  m_flags.CY := 0;
  m_flags.OV := m_flags.CY;
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opSUBFS: Cardinal;
begin
  var appw: Cardinal;
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(232, 2);
  if (m_flag2 <> 0) then
    appf := u2f(m_reg[m_op2])
  else
    appf := u2f(Read32(m_op2));
  ;
  appf := (appf - u2f(m_op1));
  appw := f2u(appf);
  m_flags.CY := 0;
  m_flags.OV := m_flags.CY;
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opMULFS: Cardinal;
begin
  var appw: Cardinal;
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(232, 2);
  if (m_flag2 <> 0) then
    appf := u2f(m_reg[m_op2])
  else
    appf := u2f(Read32(m_op2));
  ;
  appf := (appf * u2f(m_op1));
  appw := f2u(appf);
  m_flags.CY := 0;
  m_flags.OV := m_flags.CY;
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opDIVFS: Cardinal;
begin
  var appw: Cardinal;
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(232, 2);
  if (m_flag2 <> 0) then
    appf := u2f(m_reg[m_op2])
  else
    appf := u2f(Read32(m_op2));
  ;
  appf := (appf / u2f(m_op1));
  appw := f2u(appf);
  m_flags.CY := 0;
  m_flags.OV := m_flags.CY;
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opSCLFS: Cardinal;
begin
  var appw: Cardinal;
  var appf: Single;
  F2DecodeFirstOperand(231, 1);
  F2DecodeSecondOperand(232, 2);
  if (m_flag2 <> 0) then
    appf := u2f(m_reg[m_op2])
  else
    appf := u2f(Read32(m_op2));
  ;
  if (SmallInt(m_op1) < 0) then
    appf := (appf / Integer((1 shl (-SmallInt(m_op1)))))
  else
    appf := (appf * Integer((1 shl m_op1)));
  appw := f2u(appf);
  m_flags.CY := 0;
  m_flags.OV := m_flags.CY;
  m_flags.S := Ord((Cardinal(Cardinal((appw and $80000000))) <> Cardinal(0)));
  m_flags.Z := Ord((Cardinal(appw) = Cardinal(0)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := f2u(appf)
  else
    Write32(m_op2, f2u(appf));
  ;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
end;

function TV60.opCMPF: Cardinal;
begin
  var appf: Single;
  F2DecodeFirstOperand(231, 2);
  F2DecodeSecondOperand(231, 2);
  appf := (u2f(m_op2) - u2f(m_op1));
  m_flags.Z := Ord((appf = 0));
  m_flags.S := Ord((appf < 0));
  m_flags.OV := 0;
  m_flags.CY := 0;
  Exit(Cardinal((Cardinal((Cardinal(2) + Cardinal(m_amlength1))) + m_amlength2)));
  ;
end;

function TV60.op5FUNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op5CUNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op5F: Cardinal;
begin
  m_instflags := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_Op5FTable[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))], 0));
end;

function TV60.op5C: Cardinal;
begin
  m_instflags := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_Op5CTable[Cardinal((Cardinal(m_instflags) and Cardinal($1F)))], 0));
end;

function TV60.opINCB: Cardinal;
begin
  var appb: Byte;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    appb := Byte(m_reg[m_amout])
  else
    appb := Read8(m_amout);
  begin
    var res: Cardinal := Integer((Integer((appb + 1)) + 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(res) xor Cardinal(1))) and Cardinal((Cardinal(res) xor Cardinal(appb)))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    appb := Byte(res);
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[m_amout] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_amout]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_amout, appb);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opINCH: Cardinal;
begin
  var apph: Word;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 1;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    apph := Word(m_reg[m_amout])
  else
    apph := Read16(m_amout);
  begin
    var res: Cardinal := Integer((Integer((apph + 1)) + 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal((Cardinal(res) xor Cardinal(1))) and Cardinal((Cardinal(res) xor Cardinal(apph)))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    apph := Word(res);
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[m_amout] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_amout]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_amout, apph);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opINCW: Cardinal;
begin
  var appw: Cardinal;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    appw := m_reg[m_amout]
  else
    appw := Read32(m_amout);
  begin
    var res: UInt64 := (UInt64((UInt64(appw) + UInt64(1))) + UInt64(0));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64(((UInt64(res) xor UInt64(1)) and (UInt64(res) xor UInt64(appw)))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    appw := Cardinal(res);
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[m_amout] := appw
  else
    Write32(m_amout, appw);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opDECB: Cardinal;
begin
  var appb: Byte;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    appb := Byte(m_reg[m_amout])
  else
    appb := Read8(m_amout);
  begin
    var res: Cardinal := Integer((Integer((appb - 1)) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((appb xor 1))) and Cardinal(Cardinal((Cardinal(appb) xor Cardinal(res))))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
    appb := Byte(res);
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[m_amout] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_amout]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_amout, appb);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opDECH: Cardinal;
begin
  var apph: Word;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 1;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    apph := Word(m_reg[m_amout])
  else
    apph := Read16(m_amout);
  begin
    var res: Cardinal := Integer((Integer((apph - 1)) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($10000))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((apph xor 1))) and Cardinal(Cardinal((Cardinal(apph) xor Cardinal(res))))))) and Cardinal($8000))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Word(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($8000))) <> 0), 1, 0);
    end;
    ;
    apph := Word(res);
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[m_amout] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_amout]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_amout, apph);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opDECW: Cardinal;
begin
  var appw: Cardinal;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    appw := m_reg[m_amout]
  else
    appw := Read32(m_amout);
  begin
    var res: UInt64 := (UInt64((UInt64(UInt64(appw)) - UInt64(Int64(1)))) - UInt64(0));
    begin
      m_flags.CY := SelectValue(((res and (UInt64(1) shl 32)) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue(((UInt64((UInt64(Cardinal((Cardinal(appw) xor Cardinal(1)))) and UInt64((UInt64(appw) xor UInt64(res))))) and UInt64($80000000)) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Cardinal(Cardinal(res)) = Cardinal(0)));
      m_flags.S := SelectValue(((UInt64(res) and UInt64($80000000)) <> 0), 1, 0);
    end;
    ;
    appw := Cardinal(res);
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[m_amout] := appw
  else
    Write32(m_amout, appw);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opJMP: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  ReadAMAddress();
  Assert((Cardinal(m_amflag) = Cardinal(0)));
  m_reg[32] := m_amout;
  Exit(0);
end;

function TV60.opJSR: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  m_amlength1 := ReadAMAddress();
  Assert((Cardinal(m_amflag) = Cardinal(0)));
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(Cardinal((m_reg[32] + m_amlength1))) + Cardinal(1))));
  m_reg[32] := m_amout;
  Exit(0);
end;

function TV60.opPREPARE: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], m_reg[30]);
  m_reg[30] := m_reg[31];
  m_reg[31] := Cardinal((m_reg[31] - m_amout));
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opRET: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  ReadAM();
  m_reg[32] := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  m_reg[29] := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  m_reg[31] := Cardinal((m_reg[31] + m_amout));
  Exit(0);
end;

function TV60.opTRAP: Cardinal;
begin
  var oldPSW: Cardinal;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  m_amlength1 := ReadAM();
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  case Cardinal((Cardinal(Cardinal((m_amout shr 4))) and Cardinal($F))) of
    0:
      begin
        if (not (m_flags.OV <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    1:
      begin
        if (m_flags.OV <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    2:
      begin
        if (not (m_flags.CY <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    3:
      begin
        if (m_flags.CY <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    4:
      begin
        if (not (m_flags.Z <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    5:
      begin
        if (m_flags.Z <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    6:
      begin
        if (not (Integer((m_flags.CY or m_flags.Z)) <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    7:
      begin
        if (Integer((m_flags.CY or m_flags.Z)) <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    8:
      begin
        if (not (m_flags.S <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    9:
      begin
        if (m_flags.S <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    10:
      begin
      end;
    11:
      begin
        Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
      end;
    12:
      begin
        if (not (Integer((m_flags.S xor m_flags.OV)) <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    13:
      begin
        if (Integer((m_flags.S xor m_flags.OV)) <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    14:
      begin
        if (not (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0)) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
    15:
      begin
        if (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0) then
          Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))))
        else
          ;
      end;
  end;
  oldPSW := v60_update_psw_for_exception(0, 0);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(Cardinal((Cardinal((Cardinal($3000) + Cardinal(Cardinal((Cardinal($100) * Cardinal(Cardinal((Cardinal(m_amout) and Cardinal($F))))))))) shl 16))) or Cardinal(4))));
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], oldPSW);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(Cardinal((m_reg[32] + m_amlength1))) + Cardinal(1))));
  m_reg[32] := Read32(Cardinal((Cardinal((Cardinal(m_reg[41]) and Cardinal((not $fff)))) + Cardinal((Cardinal(Cardinal((Cardinal(48) + Cardinal(Cardinal((Cardinal(m_amout) and Cardinal($F))))))) * Cardinal(4))))));
  Exit(0);
end;

function TV60.opRETIU: Cardinal;
begin
  var newPSW: Cardinal;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 1;
  ReadAM();
  var StringFrame := m_reg[31];
  m_reg[32] := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  newPSW := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  m_reg[31] := Cardinal((m_reg[31] + m_amout));
  v60WritePSW(newPSW);
  RestoreString(StringFrame, newPSW);
  Exit(0);
end;

function TV60.opRETIS: Cardinal;
begin
  var newPSW: Cardinal;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 1;
  ReadAM();
  var StringFrame := m_reg[31];
  m_reg[32] := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  newPSW := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  m_reg[31] := Cardinal((m_reg[31] + m_amout));
  v60WritePSW(newPSW);
  RestoreString(StringFrame, newPSW);
  Exit(0);
end;

function TV60.opSTTASK: Cardinal;
begin
  var i: Integer;
  var adr: Cardinal;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  adr := m_reg[42];
  v60WritePSW(Cardinal((Cardinal(v60ReadPSW()) or Cardinal($10000000))));
  v60SaveStack();
  Write32(adr, m_reg[44]);
  adr := Cardinal((Cardinal(adr) + Cardinal(4)));
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($100))) <> 0) then
  begin
    Write32(adr, m_reg[37]);
    adr := Cardinal((Cardinal(adr) + Cardinal(4)));
  end;
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($200))) <> 0) then
  begin
    Write32(adr, m_reg[38]);
    adr := Cardinal((Cardinal(adr) + Cardinal(4)));
  end;
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($400))) <> 0) then
  begin
    Write32(adr, m_reg[39]);
    adr := Cardinal((Cardinal(adr) + Cardinal(4)));
  end;
  if (Cardinal((Cardinal(m_reg[43]) and Cardinal($800))) <> 0) then
  begin
    Write32(adr, m_reg[40]);
    adr := Cardinal((Cardinal(adr) + Cardinal(4)));
  end;
  i := 0;
  while (i < 31) do
  begin
    if (Cardinal((Cardinal(m_amout) and Cardinal(Integer((1 shl i))))) <> 0) then
    begin
      Write32(adr, m_reg[i]);
      adr := Cardinal((Cardinal(adr) + Cardinal(4)));
    end;
    Inc(i);
  end;
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opGETPSW: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_modwritevalw := v60ReadPSW();
  m_amlength1 := WriteAM();
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opTASI: Cardinal;
begin
  var appb: Byte;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  m_amlength1 := ReadAMAddress();
  if (m_amflag <> 0) then
    appb := Byte(m_reg[Cardinal((Cardinal(m_amout) and Cardinal($1f)))])
  else
    appb := Read8(m_amout);
  begin
    var res: Cardinal := Integer((Integer((appb - $ff)) - 0));
    begin
      m_flags.CY := SelectValue((Cardinal((Cardinal(res) and Cardinal($100))) <> 0), 1, 0);
    end;
    ;
    m_flags.OV := SelectValue((Cardinal((Cardinal(Cardinal((Cardinal(Integer((appb xor $ff))) and Cardinal(Cardinal((Cardinal(appb) xor Cardinal(res))))))) and Cardinal($80))) <> 0), 1, 0);
    begin
      m_flags.Z := Ord((Byte(res) = 0));
      m_flags.S := SelectValue((Cardinal((Cardinal(res) and Cardinal($80))) <> 0), 1, 0);
    end;
    ;
  end;
  ;
  if (m_amflag <> 0) then
    m_reg[Cardinal((Cardinal(m_amout) and Cardinal($1f)))] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[Cardinal((Cardinal(m_amout) and Cardinal($1f)))]) and Cardinal((not $ff))))) or Cardinal(Integer(($ff and $ff)))))
  else
    Write8(m_amout, $ff);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opCLRTLB: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opPOPM: Cardinal;
begin
  var i: Integer;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  i := 0;
  while (i < 31) do
  begin
    if (Cardinal((Cardinal(m_amout) and Cardinal(Integer((1 shl i))))) <> 0) then
    begin
      m_reg[i] := Read32(m_reg[31]);
      m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
    end;
    Inc(i);
  end;
  if (Cardinal((Cardinal(m_amout) and Cardinal(Integer((1 shl 31))))) <> 0) then
  begin
    v60WritePSW(Cardinal((Cardinal(Cardinal((v60ReadPSW() and $ffff0000))) or Cardinal(Read16(m_reg[31])))));
    m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  end;
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opPUSHM: Cardinal;
begin
  var i: Integer;
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  if (Cardinal((Cardinal(m_amout) and Cardinal(Integer((1 shl 31))))) <> 0) then
  begin
    m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
    Write32(m_reg[31], v60ReadPSW());
  end;
  i := 0;
  while (i < 31) do
  begin
    if (Cardinal((Cardinal(m_amout) and Cardinal(Integer((1 shl Integer((30 - i))))))) <> 0) then
    begin
      m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
      Write32(m_reg[31], m_reg[Integer((30 - i))]);
    end;
    Inc(i);
  end;
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opTESTB: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 0;
  m_amlength1 := ReadAM();
  m_flags.Z := Ord((Cardinal(m_amout) = Cardinal(0)));
  m_flags.S := Ord((Cardinal(Cardinal((Cardinal(m_amout) and Cardinal($80)))) <> Cardinal(0)));
  m_flags.CY := 0;
  m_flags.OV := 0;
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opTESTH: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 1;
  m_amlength1 := ReadAM();
  m_flags.Z := Ord((Cardinal(m_amout) = Cardinal(0)));
  m_flags.S := Ord((Cardinal(Cardinal((Cardinal(m_amout) and Cardinal($8000)))) <> Cardinal(0)));
  m_flags.CY := 0;
  m_flags.OV := 0;
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opTESTW: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  m_flags.Z := Ord((Cardinal(m_amout) = Cardinal(0)));
  m_flags.S := Ord((Cardinal(Cardinal((m_amout and $80000000))) <> Cardinal(0)));
  m_flags.CY := 0;
  m_flags.OV := 0;
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opPUSH: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_amlength1 := ReadAM();
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], m_amout);
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opPOP: Cardinal;
begin
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(1)));
  m_moddim := 2;
  m_modwritevalw := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  m_amlength1 := WriteAM();
  Exit(Cardinal((Cardinal(m_amlength1) + Cardinal(1))));
end;

function TV60.opINCB_0: Cardinal;
begin
  m_modm := 0;
  Exit(opINCB());
end;

function TV60.opINCB_1: Cardinal;
begin
  m_modm := 1;
  Exit(opINCB());
end;

function TV60.opINCH_0: Cardinal;
begin
  m_modm := 0;
  Exit(opINCH());
end;

function TV60.opINCH_1: Cardinal;
begin
  m_modm := 1;
  Exit(opINCH());
end;

function TV60.opINCW_0: Cardinal;
begin
  m_modm := 0;
  Exit(opINCW());
end;

function TV60.opINCW_1: Cardinal;
begin
  m_modm := 1;
  Exit(opINCW());
end;

function TV60.opDECB_0: Cardinal;
begin
  m_modm := 0;
  Exit(opDECB());
end;

function TV60.opDECB_1: Cardinal;
begin
  m_modm := 1;
  Exit(opDECB());
end;

function TV60.opDECH_0: Cardinal;
begin
  m_modm := 0;
  Exit(opDECH());
end;

function TV60.opDECH_1: Cardinal;
begin
  m_modm := 1;
  Exit(opDECH());
end;

function TV60.opDECW_0: Cardinal;
begin
  m_modm := 0;
  Exit(opDECW());
end;

function TV60.opDECW_1: Cardinal;
begin
  m_modm := 1;
  Exit(opDECW());
end;

function TV60.opJMP_0: Cardinal;
begin
  m_modm := 0;
  Exit(opJMP());
end;

function TV60.opJMP_1: Cardinal;
begin
  m_modm := 1;
  Exit(opJMP());
end;

function TV60.opJSR_0: Cardinal;
begin
  m_modm := 0;
  Exit(opJSR());
end;

function TV60.opJSR_1: Cardinal;
begin
  m_modm := 1;
  Exit(opJSR());
end;

function TV60.opPREPARE_0: Cardinal;
begin
  m_modm := 0;
  Exit(opPREPARE());
end;

function TV60.opPREPARE_1: Cardinal;
begin
  m_modm := 1;
  Exit(opPREPARE());
end;

function TV60.opRET_0: Cardinal;
begin
  m_modm := 0;
  Exit(opRET());
end;

function TV60.opRET_1: Cardinal;
begin
  m_modm := 1;
  Exit(opRET());
end;

function TV60.opTRAP_0: Cardinal;
begin
  m_modm := 0;
  Exit(opTRAP());
end;

function TV60.opTRAP_1: Cardinal;
begin
  m_modm := 1;
  Exit(opTRAP());
end;

function TV60.opRETIU_0: Cardinal;
begin
  m_modm := 0;
  Exit(opRETIU());
end;

function TV60.opRETIU_1: Cardinal;
begin
  m_modm := 1;
  Exit(opRETIU());
end;

function TV60.opRETIS_0: Cardinal;
begin
  m_modm := 0;
  Exit(opRETIS());
end;

function TV60.opRETIS_1: Cardinal;
begin
  m_modm := 1;
  Exit(opRETIS());
end;

function TV60.opGETPSW_0: Cardinal;
begin
  m_modm := 0;
  Exit(opGETPSW());
end;

function TV60.opGETPSW_1: Cardinal;
begin
  m_modm := 1;
  Exit(opGETPSW());
end;

function TV60.opTASI_0: Cardinal;
begin
  m_modm := 0;
  Exit(opTASI());
end;

function TV60.opTASI_1: Cardinal;
begin
  m_modm := 1;
  Exit(opTASI());
end;

function TV60.opCLRTLB_0: Cardinal;
begin
  m_modm := 0;
  Exit(opCLRTLB());
end;

function TV60.opCLRTLB_1: Cardinal;
begin
  m_modm := 1;
  Exit(opCLRTLB());
end;

function TV60.opPOPM_0: Cardinal;
begin
  m_modm := 0;
  Exit(opPOPM());
end;

function TV60.opPOPM_1: Cardinal;
begin
  m_modm := 1;
  Exit(opPOPM());
end;

function TV60.opPUSHM_0: Cardinal;
begin
  m_modm := 0;
  Exit(opPUSHM());
end;

function TV60.opPUSHM_1: Cardinal;
begin
  m_modm := 1;
  Exit(opPUSHM());
end;

function TV60.opTESTB_0: Cardinal;
begin
  m_modm := 0;
  Exit(opTESTB());
end;

function TV60.opTESTB_1: Cardinal;
begin
  m_modm := 1;
  Exit(opTESTB());
end;

function TV60.opTESTH_0: Cardinal;
begin
  m_modm := 0;
  Exit(opTESTH());
end;

function TV60.opTESTH_1: Cardinal;
begin
  m_modm := 1;
  Exit(opTESTH());
end;

function TV60.opTESTW_0: Cardinal;
begin
  m_modm := 0;
  Exit(opTESTW());
end;

function TV60.opTESTW_1: Cardinal;
begin
  m_modm := 1;
  Exit(opTESTW());
end;

function TV60.opPUSH_0: Cardinal;
begin
  m_modm := 0;
  Exit(opPUSH());
end;

function TV60.opPUSH_1: Cardinal;
begin
  m_modm := 1;
  Exit(opPUSH());
end;

function TV60.opPOP_0: Cardinal;
begin
  m_modm := 0;
  Exit(opPOP());
end;

function TV60.opPOP_1: Cardinal;
begin
  m_modm := 1;
  Exit(opPOP());
end;

function TV60.opSTTASK_0: Cardinal;
begin
  m_modm := 0;
  Exit(opSTTASK());
end;

function TV60.opSTTASK_1: Cardinal;
begin
  m_modm := 1;
  Exit(opSTTASK());
end;

function TV60.opBGT8: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (not (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBGT16: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (not (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBGE8: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (not (Integer((m_flags.S xor m_flags.OV)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBGE16: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (not (Integer((m_flags.S xor m_flags.OV)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBLT8: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (Integer((m_flags.S xor m_flags.OV)) <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBLT16: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (Integer((m_flags.S xor m_flags.OV)) <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBLE8: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBLE16: Cardinal;
begin
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBH8: Cardinal;
begin
  if (not (Integer((m_flags.CY or m_flags.Z)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBH16: Cardinal;
begin
  if (not (Integer((m_flags.CY or m_flags.Z)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBNH8: Cardinal;
begin
  if (Integer((m_flags.CY or m_flags.Z)) <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBNH16: Cardinal;
begin
  if (Integer((m_flags.CY or m_flags.Z)) <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBNL8: Cardinal;
begin
  if (not (m_flags.CY <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBNL16: Cardinal;
begin
  if (not (m_flags.CY <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBL8: Cardinal;
begin
  if (m_flags.CY <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBL16: Cardinal;
begin
  if (m_flags.CY <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBNE8: Cardinal;
begin
  if (not (m_flags.Z <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBNE16: Cardinal;
begin
  if (not (m_flags.Z <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBE8: Cardinal;
begin
  if (m_flags.Z <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBE16: Cardinal;
begin
  if (m_flags.Z <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBNV8: Cardinal;
begin
  if (not (m_flags.OV <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBNV16: Cardinal;
begin
  if (not (m_flags.OV <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBV8: Cardinal;
begin
  if (m_flags.OV <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBV16: Cardinal;
begin
  if (m_flags.OV <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBP8: Cardinal;
begin
  if (not (m_flags.S <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBP16: Cardinal;
begin
  if (not (m_flags.S <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBN8: Cardinal;
begin
  if (m_flags.S <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(2);
end;

function TV60.opBN16: Cardinal;
begin
  if (m_flags.S <> 0) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
    Exit(0);
  end;
  Exit(3);
end;

function TV60.opBR8: Cardinal;
begin
  m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(ShortInt(Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
  Exit(0);
end;

function TV60.opBR16: Cardinal;
begin
  m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
  Exit(0);
end;

function TV60.opBSR: Cardinal;
begin
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(m_reg[32]) + Cardinal(3))));
  m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))))))));
  Exit(0);
end;

function TV60.opBRK: Cardinal;
begin
  Illegal();
  Exit(1);
end;

function TV60.opBRKV: Cardinal;
begin
  var oldPSW: Cardinal := v60_update_psw_for_exception(0, 0);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], m_reg[32]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Integer((Integer(($1501 shl 16)) or 4)));
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], oldPSW);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) - Cardinal(4)));
  Write32(m_reg[31], Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  m_reg[32] := Read32(Cardinal((Cardinal(Cardinal((Cardinal(m_reg[41]) and Cardinal((not $fff))))) + Cardinal(Integer((21 * 4))))));
  Exit(0);
end;

function TV60.opCLRTLBA: Cardinal;
begin
  Illegal();
  Exit(1);
end;

function TV60.opDISPOSE: Cardinal;
begin
  m_reg[31] := m_reg[30];
  m_reg[30] := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  Exit(1);
end;

function TV60.opHALT: Cardinal;
begin
  FHalted := True;
  Result := 1;
end;

function TV60.opNOP: Cardinal;
begin
  Exit(1);
end;

function TV60.opRSR: Cardinal;
begin
  m_reg[32] := Read32(m_reg[31]);
  m_reg[31] := Cardinal((Cardinal(m_reg[31]) + Cardinal(4)));
  Exit(0);
end;

function TV60.opTRAPFL: Cardinal;
begin
  if (Cardinal((Cardinal((Cardinal(m_reg[44]) and Cardinal($1F0))) and Cardinal((Cardinal((Cardinal(v60ReadPSW()) and Cardinal($1F00))) shr 4)))) <> 0) then
  begin
    Illegal();
  end;
  Exit(1);
end;

function TV60.opTB(reg: Integer): Cardinal;
begin
  if (Cardinal(m_reg[reg]) = Cardinal(0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBGT(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBLE(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (Integer((Integer((m_flags.S xor m_flags.OV)) or m_flags.Z)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBGE(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (Integer((m_flags.S xor m_flags.OV)) <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBLT(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  begin
    m_flags.S := SelectValue((m_flags.S <> 0), 1, 0);
    m_flags.OV := SelectValue((m_flags.OV <> 0), 1, 0);
    m_flags.Z := SelectValue((m_flags.Z <> 0), 1, 0);
    m_flags.CY := SelectValue((m_flags.CY <> 0), 1, 0);
  end;
  ;
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (Integer((m_flags.S xor m_flags.OV)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBH(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (Integer((m_flags.CY or m_flags.Z)) <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBNH(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (Integer((m_flags.CY or m_flags.Z)) <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBL(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (m_flags.CY <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBNL(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (m_flags.CY <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBE(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (m_flags.Z <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBNE(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (m_flags.Z <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBV(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (m_flags.OV <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBNV(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (m_flags.OV <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBN(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (m_flags.S <> 0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBP(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if ((Cardinal(m_reg[reg]) <> Cardinal(0)) and (not (m_flags.S <> 0))) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opDBR(reg: Integer): Cardinal;
begin
  Dec(m_reg[reg]);
  if (Cardinal(m_reg[reg]) <> Cardinal(0)) then
  begin
    m_reg[32] := Cardinal((Cardinal(m_reg[32]) + Cardinal(SmallInt(Fetch16(Cardinal((Cardinal(m_reg[32]) + Cardinal(2))))))));
    Exit(0);
  end;
  Exit(4);
end;

function TV60.opC6: Cardinal;
begin
  var appb: Byte := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_OpC6Table[Integer((appb shr 5))], Integer((appb and $1f))));
end;

function TV60.opC7: Cardinal;
begin
  var appb: Byte := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_OpC7Table[Integer((appb shr 5))], Integer((appb and $1f))));
end;

procedure TV60.F7aDecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
begin
  var appb: Byte;
  m_moddim := dim1;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($40)));
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
  m_amlength1 := Dispatch(DecodeOp1, 0);
  m_flag1 := m_amflag;
  m_op1 := m_amout;
  appb := Fetch8(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1)));
  if (Integer((appb and $80)) <> 0) then
    m_lenop1 := m_reg[Integer((appb and $1F))]
  else
    m_lenop1 := appb;
  m_moddim := dim2;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($20)));
  m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(3))) + m_amlength1));
  m_amlength2 := Dispatch(DecodeOp2, 0);
  m_flag2 := m_amflag;
  m_op2 := m_amout;
  appb := Fetch8(Cardinal((Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(3))) + m_amlength1)) + m_amlength2)));
  if (Integer((appb and $80)) <> 0) then
    m_lenop2 := m_reg[Integer((appb and $1F))]
  else
    m_lenop2 := appb;
end;

procedure TV60.F7bDecodeFirstOperand(DecodeOp1: Integer; dim1: Byte);
begin
  var appb: Byte;
  m_moddim := dim1;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($40)));
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
  m_amlength1 := Dispatch(DecodeOp1, 0);
  m_flag1 := m_amflag;
  m_op1 := m_amout;
  appb := Fetch8(Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1)));
  if (Integer((appb and $80)) <> 0) then
    m_lenop1 := m_reg[Integer((appb and $1F))]
  else
    m_lenop1 := appb;
end;

procedure TV60.F7bWriteSecondOperand(dim2: Byte);
begin
  m_moddim := dim2;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($20)));
  m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(3))) + m_amlength1));
  m_amlength2 := WriteAM();
end;

procedure TV60.F7bDecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
begin
  F7bDecodeFirstOperand(DecodeOp1, dim1);
  m_bamoffset1 := m_bamoffset;
  m_moddim := dim2;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($20)));
  m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(3))) + m_amlength1));
  m_amlength2 := Dispatch(DecodeOp2, 0);
  m_flag2 := m_amflag;
  m_op2 := m_amout;
  m_bamoffset2 := m_bamoffset;
end;

procedure TV60.F7cDecodeOperands(DecodeOp1: Integer; dim1: Byte; DecodeOp2: Integer; dim2: Byte);
begin
  var appb: Byte;
  m_moddim := dim1;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($40)));
  m_modadd := Cardinal((Cardinal(m_reg[32]) + Cardinal(2)));
  m_amlength1 := Dispatch(DecodeOp1, 0);
  m_flag1 := m_amflag;
  m_op1 := m_amout;
  m_moddim := dim2;
  m_modm := Cardinal((Cardinal(m_subop) and Cardinal($20)));
  m_modadd := Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1));
  m_amlength2 := Dispatch(DecodeOp2, 0);
  m_flag2 := m_amflag;
  m_op2 := m_amout;
  appb := Fetch8(Cardinal((Cardinal((Cardinal((Cardinal(m_reg[32]) + Cardinal(2))) + m_amlength1)) + m_amlength2)));
  if (Integer((appb and $80)) <> 0) then
    m_lenop1 := m_reg[Integer((appb and $1F))]
  else
    m_lenop1 := appb;
end;

function TV60.opCMPSTRB(bFill: Byte; bStop: Byte): Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7aDecodeOperands(232, 0, 232, 0);
    StartString(2, 0, 2 * Ord(bFill <> 0) + 4 * Ord(bStop <> 0));
    Exit(0);
  end;
  var i: Cardinal;
  var dest: Cardinal;
  var c1: Byte;
  var c2: Byte;
  F7aDecodeOperands(232, 0, 232, 0);
  if (bFill <> 0) then
  begin
    if (m_lenop1 < m_lenop2) then
    begin
      i := m_lenop1;
      while (i < m_lenop2) do
      begin
        Write8(Cardinal((m_op1 + i)), Byte(m_reg[26]));
        Inc(i);
      end;
    end
    else if (m_lenop2 < m_lenop1) then
    begin
      i := m_lenop2;
      while (i < m_lenop1) do
      begin
        Write8(Cardinal((m_op2 + i)), Byte(m_reg[26]));
        Inc(i);
      end;
    end;
  end;
  dest := SelectValue((m_lenop1 < m_lenop2), m_lenop1, m_lenop2);
  m_flags.Z := 0;
  m_flags.S := 0;
  if (bStop <> 0) then
    m_flags.CY := 1;
  i := 0;
  while (i < dest) do
  begin
    begin
      c1 := Read8(Cardinal((m_op1 + i)));
      c2 := Read8(Cardinal((m_op2 + i)));
      if (c1 > c2) then
      begin
        m_flags.S := 1;
        Break;
      end
      else if (c2 > c1) then
      begin
        m_flags.S := 0;
        Break;
      end;
      if (bStop <> 0) then
        if ((c1 = Byte(m_reg[26])) or (c2 = Byte(m_reg[26]))) then
        begin
          m_flags.CY := 0;
          Break;
        end;
    end;
    Inc(i);
  end;
  m_reg[28] := Cardinal((m_lenop1 + i));
  m_reg[27] := Cardinal((m_lenop2 + i));
  if (i = dest) then
  begin
    if (m_lenop1 > m_lenop2) then
      m_flags.S := 1
    else if (m_lenop2 > m_lenop1) then
      m_flags.S := 0
    else
      m_flags.Z := 1;
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(4))));
  ;
end;

function TV60.opCMPSTRH(bFill: Byte; bStop: Byte): Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7aDecodeOperands(232, 1, 232, 1);
    StartString(2, 1, 2 * Ord(bFill <> 0) + 4 * Ord(bStop <> 0));
    Exit(0);
  end;
  var i: Cardinal;
  var dest: Cardinal;
  var c1: Word;
  var c2: Word;
  F7aDecodeOperands(232, 0, 232, 0);
  if (bFill <> 0) then
  begin
    if (m_lenop1 < m_lenop2) then
    begin
      i := m_lenop1;
      while (i < m_lenop2) do
      begin
        Write16(Cardinal((m_op1 + Cardinal((Cardinal(i) * Cardinal(2))))), Word(m_reg[26]));
        Inc(i);
      end;
    end
    else if (m_lenop2 < m_lenop1) then
    begin
      i := m_lenop2;
      while (i < m_lenop1) do
      begin
        Write16(Cardinal((m_op2 + Cardinal((Cardinal(i) * Cardinal(2))))), Word(m_reg[26]));
        Inc(i);
      end;
    end;
  end;
  dest := SelectValue((m_lenop1 < m_lenop2), m_lenop1, m_lenop2);
  m_flags.Z := 0;
  m_flags.S := 0;
  if (bStop <> 0) then
    m_flags.CY := 1;
  i := 0;
  while (i < dest) do
  begin
    begin
      c1 := Read16(Cardinal((m_op1 + Cardinal((Cardinal(i) * Cardinal(2))))));
      c2 := Read16(Cardinal((m_op2 + Cardinal((Cardinal(i) * Cardinal(2))))));
      if (c1 > c2) then
      begin
        m_flags.S := 1;
        Break;
      end
      else if (c2 > c1) then
      begin
        m_flags.S := 0;
        Break;
      end;
      if (bStop <> 0) then
        if ((c1 = Word(m_reg[26])) or (c2 = Word(m_reg[26]))) then
        begin
          m_flags.CY := 0;
          Break;
        end;
    end;
    Inc(i);
  end;
  m_reg[28] := Cardinal((m_lenop1 + Cardinal((Cardinal(i) * Cardinal(2)))));
  m_reg[27] := Cardinal((m_lenop2 + Cardinal((Cardinal(i) * Cardinal(2)))));
  if (i = dest) then
  begin
    if (m_lenop1 > m_lenop2) then
      m_flags.S := 1
    else if (m_lenop2 > m_lenop1) then
      m_flags.S := 0
    else
      m_flags.Z := 1;
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(4))));
  ;
end;

function TV60.opMOVSTRUB(bFill: Byte; bStop: Byte): Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7aDecodeOperands(232, 0, 232, 0);
    StartString(1, 0, 0 + 2 * Ord(bFill <> 0) + 4 * Ord(bStop <> 0));
    Exit(0);
  end;
  var i: Cardinal;
  var dest: Cardinal;
  var c1: Byte;
  F7aDecodeOperands(232, 0, 232, 0);
  dest := SelectValue((m_lenop1 < m_lenop2), m_lenop1, m_lenop2);
  i := 0;
  while (i < dest) do
  begin
    begin
      c1 := Read8(Cardinal((m_op1 + i)));
      Write8(Cardinal((m_op2 + i)), c1);
      if ((bStop <> 0) and (c1 = Byte(m_reg[26]))) then
        Break;
    end;
    Inc(i);
  end;
  m_reg[28] := Cardinal((m_op1 + i));
  m_reg[27] := Cardinal((m_op2 + i));
  if ((bFill <> 0) and (m_lenop1 < m_lenop2)) then
  begin
    while (i < m_lenop2) do
    begin
      Write8(Cardinal((m_op2 + i)), Byte(m_reg[26]));
      Inc(i);
    end;
    m_reg[27] := Cardinal((m_op2 + i));
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(4))));
  ;
end;

function TV60.opMOVSTRDB(bFill: Byte; bStop: Byte): Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7aDecodeOperands(232, 0, 232, 0);
    StartString(1, 0, 1 + 2 * Ord(bFill <> 0) + 4 * Ord(bStop <> 0));
    Exit(0);
  end;
  var i: Cardinal;
  var dest: Cardinal;
  var c1: Byte;
  F7aDecodeOperands(232, 0, 232, 0);
  dest := SelectValue((m_lenop1 < m_lenop2), m_lenop1, m_lenop2);
  i := 0;
  while (i < dest) do
  begin
    begin
      c1 := Read8(Cardinal((m_op1 + Cardinal((Cardinal(Cardinal((dest - i))) - Cardinal(1))))));
      Write8(Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((dest - i))) - Cardinal(1))))), c1);
      if ((bStop <> 0) and (c1 = Byte(m_reg[26]))) then
        Break;
    end;
    Inc(i);
  end;
  m_reg[28] := Cardinal((m_op1 + Cardinal((Cardinal(Cardinal((m_lenop1 - i))) - Cardinal(1)))));
  m_reg[27] := Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((m_lenop2 - i))) - Cardinal(1)))));
  if ((bFill <> 0) and (m_lenop1 < m_lenop2)) then
  begin
    while (i < m_lenop2) do
    begin
      Write8(Cardinal((Cardinal((m_op2 + dest)) + Cardinal((Cardinal(Cardinal((m_lenop2 - i))) - Cardinal(1))))), Byte(m_reg[26]));
      Inc(i);
    end;
    m_reg[27] := Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((m_lenop2 - i))) - Cardinal(1)))));
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(4))));
  ;
end;

function TV60.opMOVSTRUH(bFill: Byte; bStop: Byte): Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7aDecodeOperands(232, 1, 232, 1);
    StartString(1, 1, 0 + 2 * Ord(bFill <> 0) + 4 * Ord(bStop <> 0));
    Exit(0);
  end;
  var i: Cardinal;
  var dest: Cardinal;
  var c1: Word;
  F7aDecodeOperands(232, 1, 232, 1);
  dest := SelectValue((m_lenop1 < m_lenop2), m_lenop1, m_lenop2);
  i := 0;
  while (i < dest) do
  begin
    begin
      c1 := Read16(Cardinal((m_op1 + Cardinal((Cardinal(i) * Cardinal(2))))));
      Write16(Cardinal((m_op2 + Cardinal((Cardinal(i) * Cardinal(2))))), c1);
      if ((bStop <> 0) and (c1 = Word(m_reg[26]))) then
        Break;
    end;
    Inc(i);
  end;
  m_reg[28] := Cardinal((m_op1 + Cardinal((Cardinal(i) * Cardinal(2)))));
  m_reg[27] := Cardinal((m_op2 + Cardinal((Cardinal(i) * Cardinal(2)))));
  if ((bFill <> 0) and (m_lenop1 < m_lenop2)) then
  begin
    while (i < m_lenop2) do
    begin
      Write16(Cardinal((m_op2 + Cardinal((Cardinal(i) * Cardinal(2))))), Word(m_reg[26]));
      Inc(i);
    end;
    m_reg[27] := Cardinal((m_op2 + Cardinal((Cardinal(i) * Cardinal(2)))));
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(4))));
  ;
end;

function TV60.opMOVSTRDH(bFill: Byte; bStop: Byte): Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7aDecodeOperands(232, 1, 232, 1);
    StartString(1, 1, 1 + 2 * Ord(bFill <> 0) + 4 * Ord(bStop <> 0));
    Exit(0);
  end;
  var i: Cardinal;
  var dest: Cardinal;
  var c1: Word;
  F7aDecodeOperands(232, 1, 232, 1);
  dest := SelectValue((m_lenop1 < m_lenop2), m_lenop1, m_lenop2);
  i := 0;
  while (i < dest) do
  begin
    begin
      c1 := Read16(Cardinal((m_op1 + Cardinal((Cardinal(Cardinal((Cardinal(Cardinal((dest - i))) - Cardinal(1)))) * Cardinal(2))))));
      Write16(Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((Cardinal(Cardinal((dest - i))) - Cardinal(1)))) * Cardinal(2))))), c1);
      if ((bStop <> 0) and (c1 = Word(m_reg[26]))) then
        Break;
    end;
    Inc(i);
  end;
  m_reg[28] := Cardinal((m_op1 + Cardinal((Cardinal(Cardinal((Cardinal(Cardinal((m_lenop1 - i))) - Cardinal(1)))) * Cardinal(2)))));
  m_reg[27] := Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((Cardinal(Cardinal((m_lenop2 - i))) - Cardinal(1)))) * Cardinal(2)))));
  if ((bFill <> 0) and (m_lenop1 < m_lenop2)) then
  begin
    while (i < m_lenop2) do
    begin
      Write16(Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((Cardinal(Cardinal((m_lenop2 - i))) - Cardinal(1)))) * Cardinal(2))))), Word(m_reg[26]));
      Inc(i);
    end;
    m_reg[27] := Cardinal((m_op2 + Cardinal((Cardinal(Cardinal((Cardinal(Cardinal((m_lenop2 - i))) - Cardinal(1)))) * Cardinal(2)))));
  end;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(4))));
  ;
end;

function TV60.opSEARCHUB(bSearch: Byte): Cardinal;
begin
  Result := SearchCharacters(0, bSearch <> 0, False);
end;

function TV60.opSEARCHUH(bSearch: Byte): Cardinal;
begin
  Result := SearchCharacters(1, bSearch <> 0, False);
end;

function TV60.opSEARCHDB(bSearch: Byte): Cardinal;
begin
  Result := SearchCharacters(0, bSearch <> 0, True);
end;

function TV60.opSEARCHDH(bSearch: Byte): Cardinal;
begin
  Result := SearchCharacters(1, bSearch <> 0, True);
end;

function TV60.opSCHCUB: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHUB(1));
end;

function TV60.opSCHCUH: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHUH(1));
end;

function TV60.opSCHCDB: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHDB(1));
end;

function TV60.opSCHCDH: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHDH(1));
end;

function TV60.opSKPCUB: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHUB(0));
end;

function TV60.opSKPCUH: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHUH(0));
end;

function TV60.opSKPCDB: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHDB(0));
end;

function TV60.opSKPCDH: Cardinal;
begin
  FStringBus := True;
  Exit(opSEARCHDH(0));
end;

function TV60.opCMPCB: Cardinal;
begin
  FStringBus := True;
  Exit(opCMPSTRB(0, 0));
end;

function TV60.opCMPCH: Cardinal;
begin
  FStringBus := True;
  Exit(opCMPSTRH(0, 0));
end;

function TV60.opCMPCFB: Cardinal;
begin
  FStringBus := True;
  Exit(opCMPSTRB(1, 0));
end;

function TV60.opCMPCFH: Cardinal;
begin
  FStringBus := True;
  Exit(opCMPSTRH(1, 0));
end;

function TV60.opCMPCSB: Cardinal;
begin
  FStringBus := True;
  Exit(opCMPSTRB(0, 1));
end;

function TV60.opCMPCSH: Cardinal;
begin
  FStringBus := True;
  Exit(opCMPSTRH(0, 1));
end;

function TV60.opMOVCUB: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRUB(0, 0));
end;

function TV60.opMOVCUH: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRUH(0, 0));
end;

function TV60.opMOVCFUB: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRUB(1, 0));
end;

function TV60.opMOVCFUH: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRUH(1, 0));
end;

function TV60.opMOVCSUB: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRUB(0, 1));
end;

function TV60.opMOVCSUH: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRUH(0, 1));
end;

function TV60.opMOVCDB: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRDB(0, 0));
end;

function TV60.opMOVCDH: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRDH(0, 0));
end;

function TV60.opMOVCFDB: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRDB(1, 0));
end;

function TV60.opMOVCFDH: Cardinal;
begin
  FStringBus := True;
  Exit(opMOVSTRDH(1, 0));
end;

function TV60.opEXTBFZ: Cardinal;
begin
  F7bDecodeFirstOperand(262, 11);
  m_lenop1 := Integer((Integer((1 shl m_lenop1)) - 1));
  m_modwritevalw := Cardinal((Cardinal((m_op1 shr m_bamoffset)) and m_lenop1));
  F7bWriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opEXTBFS: Cardinal;
begin
  F7bDecodeFirstOperand(262, 11);
  m_lenop1 := Integer((Integer((1 shl m_lenop1)) - 1));
  m_modwritevalw := Cardinal((Cardinal((m_op1 shr m_bamoffset)) and m_lenop1));
  if (Cardinal((m_modwritevalw and Cardinal((Cardinal((Cardinal(m_lenop1) + Cardinal(1))) shr 1)))) <> 0) then
    m_modwritevalw := Cardinal((m_modwritevalw or (not m_lenop1)));
  F7bWriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opEXTBFL: Cardinal;
begin
  var appw: Cardinal;
  F7bDecodeFirstOperand(262, 11);
  appw := m_lenop1;
  m_lenop1 := Integer((Integer((1 shl m_lenop1)) - 1));
  m_modwritevalw := Cardinal((Cardinal((m_op1 shr m_bamoffset)) and m_lenop1));
  m_modwritevalw := Cardinal((m_modwritevalw shl Cardinal((Cardinal(32) - Cardinal(appw)))));
  F7bWriteSecondOperand(2);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opSCHBS(bSearch1: Cardinal): Cardinal;
begin
  Result := SearchBits(bSearch1 <> 0, False);
end;

function TV60.opSCH0BSU: Cardinal;
begin
  Exit(opSCHBS(0));
end;

function TV60.opSCH1BSU: Cardinal;
begin
  Exit(opSCHBS(1));
end;

function TV60.opINSBFR: Cardinal;
begin
  var appw: Cardinal;
  F7cDecodeOperands(231, 2, 263, 11);
  m_lenop1 := Integer((Integer((1 shl m_lenop1)) - 1));
  m_op2 := Cardinal((m_op2 + (Cardinal(m_bamoffset) div Cardinal(8))));
  appw := Read32(m_op2);
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  appw := Cardinal((appw and (not Cardinal((m_lenop1 shl m_bamoffset)))));
  appw := Cardinal((appw or Cardinal((Cardinal((m_lenop1 and m_op1)) shl m_bamoffset))));
  Write32(m_op2, appw);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opINSBFL: Cardinal;
begin
  var appw: Cardinal;
  F7cDecodeOperands(231, 2, 263, 11);
  m_op1 := Cardinal((m_op1 shr Cardinal((Cardinal(32) - Cardinal(m_lenop1)))));
  m_lenop1 := Integer((Integer((1 shl m_lenop1)) - 1));
  m_op2 := Cardinal((m_op2 + (Cardinal(m_bamoffset) div Cardinal(8))));
  appw := Read32(m_op2);
  m_bamoffset := Cardinal((Cardinal(m_bamoffset) and Cardinal(7)));
  appw := Cardinal((appw and (not Cardinal((m_lenop1 shl m_bamoffset)))));
  appw := Cardinal((appw or Cardinal((Cardinal((m_lenop1 and m_op1)) shl m_bamoffset))));
  Write32(m_op2, appw);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opMOVBSD: Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7bDecodeOperands(263, 10, 263, 10);
    StartString(5, 0, 1);
    Exit(0);
  end;
  var i: Cardinal;
  var srcdata: Byte;
  var dstdata: Byte;
  F7bDecodeOperands(263, 10, 263, 10);
  m_bamoffset1 := Cardinal((m_bamoffset1 + Cardinal((Cardinal(m_lenop1) - Cardinal(1)))));
  m_bamoffset2 := Cardinal((m_bamoffset2 + Cardinal((Cardinal(m_lenop1) - Cardinal(1)))));
  m_op1 := Cardinal((m_op1 + (Cardinal(m_bamoffset1) div Cardinal(8))));
  m_op2 := Cardinal((m_op2 + (Cardinal(m_bamoffset2) div Cardinal(8))));
  m_bamoffset1 := Cardinal((Cardinal(m_bamoffset1) and Cardinal(7)));
  m_bamoffset2 := Cardinal((Cardinal(m_bamoffset2) and Cardinal(7)));
  srcdata := Read8(m_op1);
  dstdata := Read8(m_op2);
  i := 0;
  while (i < m_lenop1) do
  begin
    begin
      m_reg[28] := m_op1;
      m_reg[27] := m_op2;
      dstdata := Integer((dstdata and (not Integer((1 shl m_bamoffset2)))));
      dstdata := Integer((dstdata or Integer((Integer((Integer((srcdata shr m_bamoffset1)) and 1)) shl m_bamoffset2))));
      if (Cardinal(m_bamoffset1) = Cardinal(0)) then
      begin
        m_bamoffset1 := 8;
        Dec(m_op1);
        srcdata := Read8(m_op1);
      end;
      if (Cardinal(m_bamoffset2) = Cardinal(0)) then
      begin
        Write8(m_op2, dstdata);
        m_bamoffset2 := 8;
        Dec(m_op2);
        dstdata := Read8(m_op2);
      end;
      Dec(m_bamoffset1);
      Dec(m_bamoffset2);
    end;
    Inc(i);
  end;
  if (Cardinal(m_bamoffset2) <> Cardinal(7)) then
    Write8(m_op2, dstdata);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opMOVBSU: Cardinal;
begin
  if FCycleModel = vcmBusConstraints then
  begin
    F7bDecodeOperands(263, 10, 263, 10);
    StartString(5, 0, 0);
    Exit(0);
  end;
  var i: Cardinal;
  var srcdata: Byte;
  var dstdata: Byte;
  F7bDecodeOperands(263, 10, 263, 10);
  m_op1 := Cardinal((m_op1 + (Cardinal(m_bamoffset1) div Cardinal(8))));
  m_op2 := Cardinal((m_op2 + (Cardinal(m_bamoffset2) div Cardinal(8))));
  m_bamoffset1 := Cardinal((Cardinal(m_bamoffset1) and Cardinal(7)));
  m_bamoffset2 := Cardinal((Cardinal(m_bamoffset2) and Cardinal(7)));
  srcdata := Read8(m_op1);
  dstdata := Read8(m_op2);
  i := 0;
  while (i < m_lenop1) do
  begin
    begin
      m_reg[28] := m_op1;
      m_reg[27] := m_op2;
      dstdata := Integer((dstdata and (not Integer((1 shl m_bamoffset2)))));
      dstdata := Integer((dstdata or Integer((Integer((Integer((srcdata shr m_bamoffset1)) and 1)) shl m_bamoffset2))));
      Inc(m_bamoffset1);
      Inc(m_bamoffset2);
      if (Cardinal(m_bamoffset1) = Cardinal(8)) then
      begin
        m_bamoffset1 := 0;
        Inc(m_op1);
        srcdata := Read8(m_op1);
      end;
      if (Cardinal(m_bamoffset2) = Cardinal(8)) then
      begin
        Write8(m_op2, dstdata);
        m_bamoffset2 := 0;
        Inc(m_op2);
        dstdata := Read8(m_op2);
      end;
    end;
    Inc(i);
  end;
  if (Cardinal(m_bamoffset2) <> Cardinal(0)) then
    Write8(m_op2, dstdata);
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opADDDC: Cardinal;
begin
  var appb: Byte;
  var src: Byte;
  var dst: Byte;
  F7cDecodeOperands(231, 0, 232, 0);
  if (Cardinal(m_lenop1) <> Cardinal(0)) then
  begin
    Illegal();
  end;
  if (m_flag2 <> 0) then
    appb := Byte(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal($FF))))
  else
    appb := Read8(m_op2);
  ;
  src := Integer((Integer((Byte(Cardinal((m_op1 shr 4))) * 10)) + Byte(Cardinal((Cardinal(m_op1) and Cardinal($F))))));
  dst := Integer((Integer((Integer((appb shr 4)) * 10)) + Integer((appb and $F))));
  appb := Cardinal((Cardinal(Integer((src + dst))) + Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
  if (appb >= 100) then
  begin
    appb := Integer((appb - 100));
    m_flags.CY := 1;
  end
  else
    m_flags.CY := 0;
  if ((appb <> 0) or (m_flags.CY <> 0)) then
    m_flags.Z := 0;
  appb := Integer((Integer(((appb div 10) shl 4)) or (appb mod 10)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opSUBDC: Cardinal;
begin
  var appb: ShortInt;
  var src: Cardinal;
  var dst: Cardinal;
  F7cDecodeOperands(231, 0, 232, 0);
  if (Cardinal(m_lenop1) <> Cardinal(0)) then
  begin
    Illegal();
  end;
  if (m_flag2 <> 0) then
    appb := Byte(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal($FF))))
  else
    appb := Read8(m_op2);
  ;
  src := Cardinal((Cardinal((Cardinal(Cardinal(Cardinal((m_op1 shr 4)))) * Cardinal(10))) + Cardinal(Cardinal((Cardinal(m_op1) and Cardinal($F))))));
  dst := Integer((Integer((ArithmeticShift(Integer((appb and $F0)), 4) * 10)) + Integer((appb and $F))));
  appb := Cardinal((Cardinal(Integer((Integer(dst) - Integer(src)))) - Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
  if (appb < 0) then
  begin
    appb := Integer((appb + 100));
    m_flags.CY := 1;
  end
  else
    m_flags.CY := 0;
  if ((appb <> 0) or (m_flags.CY <> 0)) then
    m_flags.Z := 0;
  appb := Integer((Integer(((appb div 10) shl 4)) or (appb mod 10)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opSUBRDC: Cardinal;
begin
  var appb: ShortInt;
  var src: Cardinal;
  var dst: Cardinal;
  F7cDecodeOperands(231, 0, 232, 0);
  if (Cardinal(m_lenop1) <> Cardinal(0)) then
  begin
    Illegal();
  end;
  if (m_flag2 <> 0) then
    appb := Byte(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal($FF))))
  else
    appb := Read8(m_op2);
  ;
  src := Cardinal((Cardinal((Cardinal(Cardinal(Cardinal((m_op1 shr 4)))) * Cardinal(10))) + Cardinal(Cardinal((Cardinal(m_op1) and Cardinal($F))))));
  dst := Integer((Integer((ArithmeticShift(Integer((appb and $F0)), 4) * 10)) + Integer((appb and $F))));
  appb := Cardinal((Cardinal(Integer((Integer(src) - Integer(dst)))) - Cardinal(SelectValue((m_flags.CY <> 0), 1, 0))));
  if (appb < 0) then
  begin
    appb := Integer((appb + 100));
    m_flags.CY := 1;
  end
  else
    m_flags.CY := 0;
  if ((appb <> 0) or (m_flags.CY <> 0)) then
    m_flags.Z := 0;
  appb := Integer((Integer(((appb div 10) shl 4)) or (appb mod 10)));
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opCVTDPZ: Cardinal;
begin
  var apph: Word;
  F7cDecodeOperands(231, 0, 232, 1);
  apph := Word(Cardinal((Cardinal((Cardinal(Cardinal((m_op1 shr 4))) and Cardinal($F))) or Cardinal((Cardinal((Cardinal(m_op1) and Cardinal($F))) shl 8)))));
  apph := Cardinal((Cardinal(apph) or Cardinal(m_lenop1)));
  apph := Cardinal((Cardinal(apph) or Cardinal(Cardinal((m_lenop1 shl 8)))));
  if (Cardinal(m_op1) <> Cardinal(0)) then
    m_flags.Z := 0;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ffff))))) or Cardinal(Integer((apph and $ffff)))))
  else
    Write16(m_op2, apph);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.opCVTDZP: Cardinal;
begin
  var appb: Byte;
  F7cDecodeOperands(231, 1, 232, 0);
  if ((Cardinal((Cardinal(m_op1) and Cardinal($F0))) <> Cardinal((Cardinal(m_lenop1) and Cardinal($F0)))) or (Cardinal((Cardinal(Cardinal((m_op1 shr 8))) and Cardinal($F0))) <> Cardinal((Cardinal(m_lenop1) and Cardinal($F0))))) then
  begin
    Illegal();
  end;
  if ((Cardinal(Cardinal((Cardinal(m_op1) and Cardinal($F)))) > Cardinal(9)) or (Cardinal(Cardinal((Cardinal(Cardinal((m_op1 shr 8))) and Cardinal($F)))) > Cardinal(9))) then
  begin
    Illegal();
  end;
  appb := Byte(Cardinal((Cardinal((Cardinal(Cardinal((m_op1 shr 8))) and Cardinal($F))) or Cardinal((Cardinal((Cardinal(m_op1) and Cardinal($F))) shl 4)))));
  if (appb <> 0) then
    m_flags.Z := 0;
  if (m_flag2 <> 0) then
    m_reg[m_op2] := Cardinal((Cardinal(Cardinal((Cardinal(m_reg[m_op2]) and Cardinal((not $ff))))) or Cardinal(Integer((appb and $ff)))))
  else
    Write8(m_op2, appb);
  ;
  Exit(Cardinal((Cardinal(Cardinal((m_amlength1 + m_amlength2))) + Cardinal(3))));
  ;
end;

function TV60.op58UNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op5AUNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op5BUNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op5DUNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op59UNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.op58: Cardinal;
begin
  m_subop := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_Op58Table[Cardinal((Cardinal(m_subop) and Cardinal($1F)))], 0));
end;

function TV60.op5A: Cardinal;
begin
  m_subop := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_Op5ATable[Cardinal((Cardinal(m_subop) and Cardinal($1F)))], 0));
end;

function TV60.op5B: Cardinal;
begin
  m_subop := Fetch8(m_reg[32] + 1);
  if (m_subop and $1F) in [1, 3] then
    Exit(SearchBits(m_subop and 2 <> 0, True));
  if (m_subop and $1F) in [$0A, $0B, $10..$1B] then
  begin
    F7bDecodeOperands(263, 10, 263, 10);
    StartString(5, 0, m_subop and 1);
    if m_subop and $1E = $0A then
      FStringState.Logic := 1
    else
      FStringState.Logic := 2 + ((m_subop and $1E) - $10) div 2;
    Exit(0);
  end;
  Result := Dispatch(s_Op5BTable[m_subop and $1F], 0);
end;

function TV60.op5D: Cardinal;
begin
  m_subop := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_Op5DTable[Cardinal((Cardinal(m_subop) and Cardinal($1F)))], 0));
end;

function TV60.op59: Cardinal;
begin
  m_subop := Fetch8(Cardinal((Cardinal(m_reg[32]) + Cardinal(1))));
  Exit(Dispatch(s_Op59Table[Cardinal((Cardinal(m_subop) and Cardinal($1F)))], 0));
end;

function TV60.opUNHANDLED: Cardinal;
begin
  Illegal();
  Result := 0;
end;

function TV60.Dispatch(Index, Reg: Integer): Cardinal;
begin
  case Index of
    0:
      Result := am1PCDisplacementIndexed8;
    1:
      Result := am1PCDisplacementIndexed16;
    2:
      Result := am1PCDisplacementIndexed32;
    3:
      Result := am1DirectAddressIndexed;
    4:
      Result := am1Error5;
    5:
      Result := am1PCDisplacementIndirectIndexed8;
    6:
      Result := am1PCDisplacementIndirectIndexed16;
    7:
      Result := am1PCDisplacementIndirectIndexed32;
    8:
      Result := am1DirectAddressDeferredIndexed;
    9:
      Result := bam1PCDisplacementIndexed8;
    10:
      Result := bam1PCDisplacementIndexed16;
    11:
      Result := bam1PCDisplacementIndexed32;
    12:
      Result := bam1DirectAddressIndexed;
    13:
      Result := bam1Error5;
    14:
      Result := bam1PCDisplacementIndirectIndexed8;
    15:
      Result := bam1PCDisplacementIndirectIndexed16;
    16:
      Result := bam1PCDisplacementIndirectIndexed32;
    17:
      Result := bam1DirectAddressDeferredIndexed;
    18:
      Result := am1ImmediateQuick;
    19:
      Result := am1PCDisplacement8;
    20:
      Result := am1PCDisplacement16;
    21:
      Result := am1PCDisplacement32;
    22:
      Result := am1DirectAddress;
    23:
      Result := am1Immediate;
    24:
      Result := am1Error2;
    25:
      Result := am1PCDisplacementIndirect8;
    26:
      Result := am1PCDisplacementIndirect16;
    27:
      Result := am1PCDisplacementIndirect32;
    28:
      Result := am1DirectAddressDeferred;
    29:
      Result := am1PCDoubleDisplacement8;
    30:
      Result := am1PCDoubleDisplacement16;
    31:
      Result := am1PCDoubleDisplacement32;
    32:
      Result := bam1Error6;
    33:
      Result := bam1PCDisplacement8;
    34:
      Result := bam1PCDisplacement16;
    35:
      Result := bam1PCDisplacement32;
    36:
      Result := bam1DirectAddress;
    37:
      Result := bam1Error2;
    38:
      Result := bam1PCDisplacementIndirect8;
    39:
      Result := bam1PCDisplacementIndirect16;
    40:
      Result := bam1PCDisplacementIndirect32;
    41:
      Result := bam1DirectAddressDeferred;
    42:
      Result := bam1PCDoubleDisplacement8;
    43:
      Result := bam1PCDoubleDisplacement16;
    44:
      Result := bam1PCDoubleDisplacement32;
    45:
      Result := am1DisplacementIndexed8;
    46:
      Result := am1DisplacementIndexed16;
    47:
      Result := am1DisplacementIndexed32;
    48:
      Result := am1RegisterIndirectIndexed;
    49:
      Result := am1DisplacementIndirectIndexed8;
    50:
      Result := am1DisplacementIndirectIndexed16;
    51:
      Result := am1DisplacementIndirectIndexed32;
    52:
      Result := am1Group7a;
    53:
      Result := bam1DisplacementIndexed8;
    54:
      Result := bam1DisplacementIndexed16;
    55:
      Result := bam1DisplacementIndexed32;
    56:
      Result := bam1RegisterIndirectIndexed;
    57:
      Result := bam1DisplacementIndirectIndexed8;
    58:
      Result := bam1DisplacementIndirectIndexed16;
    59:
      Result := bam1DisplacementIndirectIndexed32;
    60:
      Result := bam1Group7a;
    61:
      Result := am1Displacement8;
    62:
      Result := am1Displacement16;
    63:
      Result := am1Displacement32;
    64:
      Result := am1RegisterIndirect;
    65:
      Result := am1DisplacementIndirect8;
    66:
      Result := am1DisplacementIndirect16;
    67:
      Result := am1DisplacementIndirect32;
    68:
      Result := am1Group7;
    69:
      Result := am1DoubleDisplacement8;
    70:
      Result := am1DoubleDisplacement16;
    71:
      Result := am1DoubleDisplacement32;
    72:
      Result := am1Register;
    73:
      Result := am1Autoincrement;
    74:
      Result := am1Autodecrement;
    75:
      Result := am1Group6;
    76:
      Result := am1Error1;
    77:
      Result := bam1Displacement8;
    78:
      Result := bam1Displacement16;
    79:
      Result := bam1Displacement32;
    80:
      Result := bam1RegisterIndirect;
    81:
      Result := bam1DisplacementIndirect8;
    82:
      Result := bam1DisplacementIndirect16;
    83:
      Result := bam1DisplacementIndirect32;
    84:
      Result := bam1Group7;
    85:
      Result := bam1DoubleDisplacement8;
    86:
      Result := bam1DoubleDisplacement16;
    87:
      Result := bam1DoubleDisplacement32;
    88:
      Result := bam1Autoincrement;
    89:
      Result := bam1Autodecrement;
    90:
      Result := bam1Group6;
    91:
      Result := bam1Error1;
    92:
      Result := am2PCDisplacementIndexed8;
    93:
      Result := am2PCDisplacementIndexed16;
    94:
      Result := am2PCDisplacementIndexed32;
    95:
      Result := am2DirectAddressIndexed;
    96:
      Result := am2Error5;
    97:
      Result := am2PCDisplacementIndirectIndexed8;
    98:
      Result := am2PCDisplacementIndirectIndexed16;
    99:
      Result := am2PCDisplacementIndirectIndexed32;
    100:
      Result := am2DirectAddressDeferredIndexed;
    101:
      Result := bam2PCDisplacementIndexed8;
    102:
      Result := bam2PCDisplacementIndexed16;
    103:
      Result := bam2PCDisplacementIndexed32;
    104:
      Result := bam2DirectAddressIndexed;
    105:
      Result := bam2Error5;
    106:
      Result := bam2PCDisplacementIndirectIndexed8;
    107:
      Result := bam2PCDisplacementIndirectIndexed16;
    108:
      Result := bam2PCDisplacementIndirectIndexed32;
    109:
      Result := bam2DirectAddressDeferredIndexed;
    110:
      Result := am2ImmediateQuick;
    111:
      Result := am2PCDisplacement8;
    112:
      Result := am2PCDisplacement16;
    113:
      Result := am2PCDisplacement32;
    114:
      Result := am2DirectAddress;
    115:
      Result := am2Immediate;
    116:
      Result := am2Error2;
    117:
      Result := am2PCDisplacementIndirect8;
    118:
      Result := am2PCDisplacementIndirect16;
    119:
      Result := am2PCDisplacementIndirect32;
    120:
      Result := am2DirectAddressDeferred;
    121:
      Result := am2PCDoubleDisplacement8;
    122:
      Result := am2PCDoubleDisplacement16;
    123:
      Result := am2PCDoubleDisplacement32;
    124:
      Result := bam2Error6;
    125:
      Result := bam2PCDisplacement8;
    126:
      Result := bam2PCDisplacement16;
    127:
      Result := bam2PCDisplacement32;
    128:
      Result := bam2DirectAddress;
    129:
      Result := bam2Error2;
    130:
      Result := bam2PCDisplacementIndirect8;
    131:
      Result := bam2PCDisplacementIndirect16;
    132:
      Result := bam2PCDisplacementIndirect32;
    133:
      Result := bam2DirectAddressDeferred;
    134:
      Result := bam2PCDoubleDisplacement8;
    135:
      Result := bam2PCDoubleDisplacement16;
    136:
      Result := bam2PCDoubleDisplacement32;
    137:
      Result := am2DisplacementIndexed8;
    138:
      Result := am2DisplacementIndexed16;
    139:
      Result := am2DisplacementIndexed32;
    140:
      Result := am2RegisterIndirectIndexed;
    141:
      Result := am2DisplacementIndirectIndexed8;
    142:
      Result := am2DisplacementIndirectIndexed16;
    143:
      Result := am2DisplacementIndirectIndexed32;
    144:
      Result := am2Group7a;
    145:
      Result := bam2DisplacementIndexed8;
    146:
      Result := bam2DisplacementIndexed16;
    147:
      Result := bam2DisplacementIndexed32;
    148:
      Result := bam2RegisterIndirectIndexed;
    149:
      Result := bam2DisplacementIndirectIndexed8;
    150:
      Result := bam2DisplacementIndirectIndexed16;
    151:
      Result := bam2DisplacementIndirectIndexed32;
    152:
      Result := bam2Group7a;
    153:
      Result := am2Displacement8;
    154:
      Result := am2Displacement16;
    155:
      Result := am2Displacement32;
    156:
      Result := am2RegisterIndirect;
    157:
      Result := am2DisplacementIndirect8;
    158:
      Result := am2DisplacementIndirect16;
    159:
      Result := am2DisplacementIndirect32;
    160:
      Result := am2Group7;
    161:
      Result := am2DoubleDisplacement8;
    162:
      Result := am2DoubleDisplacement16;
    163:
      Result := am2DoubleDisplacement32;
    164:
      Result := am2Register;
    165:
      Result := am2Autoincrement;
    166:
      Result := am2Autodecrement;
    167:
      Result := am2Group6;
    168:
      Result := am2Error1;
    169:
      Result := bam2Displacement8;
    170:
      Result := bam2Displacement16;
    171:
      Result := bam2Displacement32;
    172:
      Result := bam2RegisterIndirect;
    173:
      Result := bam2DisplacementIndirect8;
    174:
      Result := bam2DisplacementIndirect16;
    175:
      Result := bam2DisplacementIndirect32;
    176:
      Result := bam2Group7;
    177:
      Result := bam2DoubleDisplacement8;
    178:
      Result := bam2DoubleDisplacement16;
    179:
      Result := bam2DoubleDisplacement32;
    180:
      Result := bam2Autoincrement;
    181:
      Result := bam2Autodecrement;
    182:
      Result := bam2Group6;
    183:
      Result := bam2Error1;
    184:
      Result := am3PCDisplacementIndexed8;
    185:
      Result := am3PCDisplacementIndexed16;
    186:
      Result := am3PCDisplacementIndexed32;
    187:
      Result := am3DirectAddressIndexed;
    188:
      Result := am3Error5;
    189:
      Result := am3PCDisplacementIndirectIndexed8;
    190:
      Result := am3PCDisplacementIndirectIndexed16;
    191:
      Result := am3PCDisplacementIndirectIndexed32;
    192:
      Result := am3DirectAddressDeferredIndexed;
    193:
      Result := am3ImmediateQuick;
    194:
      Result := am3PCDisplacement8;
    195:
      Result := am3PCDisplacement16;
    196:
      Result := am3PCDisplacement32;
    197:
      Result := am3DirectAddress;
    198:
      Result := am3Immediate;
    199:
      Result := am3Error2;
    200:
      Result := am3PCDisplacementIndirect8;
    201:
      Result := am3PCDisplacementIndirect16;
    202:
      Result := am3PCDisplacementIndirect32;
    203:
      Result := am3DirectAddressDeferred;
    204:
      Result := am3PCDoubleDisplacement8;
    205:
      Result := am3PCDoubleDisplacement16;
    206:
      Result := am3PCDoubleDisplacement32;
    207:
      Result := am3DisplacementIndexed8;
    208:
      Result := am3DisplacementIndexed16;
    209:
      Result := am3DisplacementIndexed32;
    210:
      Result := am3RegisterIndirectIndexed;
    211:
      Result := am3DisplacementIndirectIndexed8;
    212:
      Result := am3DisplacementIndirectIndexed16;
    213:
      Result := am3DisplacementIndirectIndexed32;
    214:
      Result := am3Group7a;
    215:
      Result := am3Displacement8;
    216:
      Result := am3Displacement16;
    217:
      Result := am3Displacement32;
    218:
      Result := am3RegisterIndirect;
    219:
      Result := am3DisplacementIndirect8;
    220:
      Result := am3DisplacementIndirect16;
    221:
      Result := am3DisplacementIndirect32;
    222:
      Result := am3Group7;
    223:
      Result := am3DoubleDisplacement8;
    224:
      Result := am3DoubleDisplacement16;
    225:
      Result := am3DoubleDisplacement32;
    226:
      Result := am3Register;
    227:
      Result := am3Autoincrement;
    228:
      Result := am3Autodecrement;
    229:
      Result := am3Group6;
    230:
      Result := am3Error1;
    231:
      Result := ReadAM;
    232:
      Result := ReadAMAddress;
    233:
      Result := opCVTWS;
    234:
      Result := opCVTSW;
    235:
      Result := op5FUNHANDLED;
    236:
      Result := opCMPF;
    237:
      Result := op5CUNHANDLED;
    238:
      Result := opMOVFS;
    239:
      Result := opNEGFS;
    240:
      Result := opABSFS;
    241:
      Result := opSCLFS;
    242:
      Result := opADDFS;
    243:
      Result := opSUBFS;
    244:
      Result := opMULFS;
    245:
      Result := opDIVFS;
    246:
      Result := opDBV(Reg);
    247:
      Result := opDBL(Reg);
    248:
      Result := opDBE(Reg);
    249:
      Result := opDBNH(Reg);
    250:
      Result := opDBN(Reg);
    251:
      Result := opDBR(Reg);
    252:
      Result := opDBLT(Reg);
    253:
      Result := opDBLE(Reg);
    254:
      Result := opDBNV(Reg);
    255:
      Result := opDBNL(Reg);
    256:
      Result := opDBNE(Reg);
    257:
      Result := opDBH(Reg);
    258:
      Result := opDBP(Reg);
    259:
      Result := opTB(Reg);
    260:
      Result := opDBGE(Reg);
    261:
      Result := opDBGT(Reg);
    262:
      Result := BitReadAM;
    263:
      Result := BitReadAMAddress;
    264:
      Result := opADDDC;
    265:
      Result := opSUBDC;
    266:
      Result := opSUBRDC;
    267:
      Result := op59UNHANDLED;
    268:
      Result := opCVTDPZ;
    269:
      Result := opCVTDZP;
    270:
      Result := opSCH0BSU;
    271:
      Result := op5BUNHANDLED;
    272:
      Result := opSCH1BSU;
    273:
      Result := opMOVBSU;
    274:
      Result := opMOVBSD;
    275:
      Result := op5DUNHANDLED;
    276:
      Result := opEXTBFS;
    277:
      Result := opEXTBFZ;
    278:
      Result := opEXTBFL;
    279:
      Result := opINSBFR;
    280:
      Result := opINSBFL;
    281:
      Result := opCMPCB;
    282:
      Result := opCMPCFB;
    283:
      Result := opCMPCSB;
    284:
      Result := op58UNHANDLED;
    285:
      Result := opMOVCUB;
    286:
      Result := opMOVCDB;
    287:
      Result := opMOVCFUB;
    288:
      Result := opMOVCFDB;
    289:
      Result := opMOVCSUB;
    290:
      Result := opSCHCUB;
    291:
      Result := opSCHCDB;
    292:
      Result := opSKPCUB;
    293:
      Result := opSKPCDB;
    294:
      Result := opCMPCH;
    295:
      Result := opCMPCFH;
    296:
      Result := opCMPCSH;
    297:
      Result := op5AUNHANDLED;
    298:
      Result := opMOVCUH;
    299:
      Result := opMOVCDH;
    300:
      Result := opMOVCFUH;
    301:
      Result := opMOVCFDH;
    302:
      Result := opMOVCSUH;
    303:
      Result := opSCHCUH;
    304:
      Result := opSCHCDH;
    305:
      Result := opSKPCUH;
    306:
      Result := opSKPCDH;
    307:
      Result := opHALT;
    308:
      Result := opLDTASK;
    309:
      Result := opSTPR;
    310:
      Result := opUNHANDLED;
    311:
      Result := opRVBIT;
    312:
      Result := opMOVB;
    313:
      Result := opMOVSBH;
    314:
      Result := opMOVZBH;
    315:
      Result := opMOVSBW;
    316:
      Result := opMOVZBW;
    317:
      Result := opCLRTLBA;
    318:
      Result := opLDPR;
    319:
      Result := opUPDPSWW;
    320:
      Result := opMOVTHB;
    321:
      Result := opMOVH;
    322:
      Result := opMOVSHW;
    323:
      Result := opMOVZHW;
    324:
      Result := opINB;
    325:
      Result := opOUTB;
    326:
      Result := opINH;
    327:
      Result := opOUTH;
    328:
      Result := opINW;
    329:
      Result := opOUTW;
    330:
      Result := opMOVTWB;
    331:
      Result := opMOVTWH;
    332:
      Result := opRVBYT;
    333:
      Result := opMOVW;
    334:
      Result := opNOTB;
    335:
      Result := opNEGB;
    336:
      Result := opNOTH;
    337:
      Result := opNEGH;
    338:
      Result := opNOTW;
    339:
      Result := opNEGW;
    340:
      Result := opMOVD;
    341:
      Result := opMOVEAB;
    342:
      Result := opXCHB;
    343:
      Result := opMOVEAH;
    344:
      Result := opXCHH;
    345:
      Result := opMOVEAW;
    346:
      Result := opXCHW;
    347:
      Result := opSETF;
    348:
      Result := opBSR;
    349:
      Result := opCALL;
    350:
      Result := opUPDPSWH;
    351:
      Result := opCHLVL;
    352:
      Result := opCHKAR;
    353:
      Result := opCHKAW;
    354:
      Result := opCHKAE;
    355:
      Result := opREMB;
    356:
      Result := opREMUB;
    357:
      Result := opREMH;
    358:
      Result := opREMUH;
    359:
      Result := opREMW;
    360:
      Result := opREMUW;
    361:
      Result := op58;
    362:
      Result := op59;
    363:
      Result := op5A;
    364:
      Result := op5B;
    365:
      Result := op5C;
    366:
      Result := op5D;
    367:
      Result := op5F;
    368:
      Result := opBV8;
    369:
      Result := opBNV8;
    370:
      Result := opBL8;
    371:
      Result := opBNL8;
    372:
      Result := opBE8;
    373:
      Result := opBNE8;
    374:
      Result := opBNH8;
    375:
      Result := opBH8;
    376:
      Result := opBN8;
    377:
      Result := opBP8;
    378:
      Result := opBR8;
    379:
      Result := opBLT8;
    380:
      Result := opBGE8;
    381:
      Result := opBLE8;
    382:
      Result := opBGT8;
    383:
      Result := opBV16;
    384:
      Result := opBNV16;
    385:
      Result := opBL16;
    386:
      Result := opBNL16;
    387:
      Result := opBE16;
    388:
      Result := opBNE16;
    389:
      Result := opBNH16;
    390:
      Result := opBH16;
    391:
      Result := opBN16;
    392:
      Result := opBP16;
    393:
      Result := opBR16;
    394:
      Result := opBLT16;
    395:
      Result := opBGE16;
    396:
      Result := opBLE16;
    397:
      Result := opBGT16;
    398:
      Result := opADDB;
    399:
      Result := opMULB;
    400:
      Result := opADDH;
    401:
      Result := opMULH;
    402:
      Result := opADDW;
    403:
      Result := opMULW;
    404:
      Result := opMULX;
    405:
      Result := opTEST1;
    406:
      Result := opORB;
    407:
      Result := opROTB;
    408:
      Result := opORH;
    409:
      Result := opROTH;
    410:
      Result := opORW;
    411:
      Result := opROTW;
    412:
      Result := opADDCB;
    413:
      Result := opMULUB;
    414:
      Result := opADDCH;
    415:
      Result := opMULUH;
    416:
      Result := opADDCW;
    417:
      Result := opMULUW;
    418:
      Result := opMULUX;
    419:
      Result := opSET1;
    420:
      Result := opSUBCB;
    421:
      Result := opROTCB;
    422:
      Result := opSUBCH;
    423:
      Result := opROTCH;
    424:
      Result := opSUBCW;
    425:
      Result := opROTCW;
    426:
      Result := opANDB;
    427:
      Result := opDIVB;
    428:
      Result := opANDH;
    429:
      Result := opDIVH;
    430:
      Result := opANDW;
    431:
      Result := opDIVW;
    432:
      Result := opDIVX;
    433:
      Result := opCLR1;
    434:
      Result := opSUBB;
    435:
      Result := opSHLB;
    436:
      Result := opSUBH;
    437:
      Result := opSHLH;
    438:
      Result := opSUBW;
    439:
      Result := opSHLW;
    440:
      Result := opXORB;
    441:
      Result := opDIVUB;
    442:
      Result := opXORH;
    443:
      Result := opDIVUH;
    444:
      Result := opXORW;
    445:
      Result := opDIVUW;
    446:
      Result := opDIVUX;
    447:
      Result := opNOT1;
    448:
      Result := opCMPB;
    449:
      Result := opSHAB;
    450:
      Result := opCMPH;
    451:
      Result := opSHAH;
    452:
      Result := opCMPW;
    453:
      Result := opSHAW;
    454:
      Result := opC6;
    455:
      Result := opC7;
    456:
      Result := opBRK;
    457:
      Result := opBRKV;
    458:
      Result := opRSR;
    459:
      Result := opTRAPFL;
    460:
      Result := opDISPOSE;
    461:
      Result := opNOP;
    462:
      Result := opDECB_0;
    463:
      Result := opDECB_1;
    464:
      Result := opDECH_0;
    465:
      Result := opDECH_1;
    466:
      Result := opDECW_0;
    467:
      Result := opDECW_1;
    468:
      Result := opJMP_0;
    469:
      Result := opJMP_1;
    470:
      Result := opINCB_0;
    471:
      Result := opINCB_1;
    472:
      Result := opINCH_0;
    473:
      Result := opINCH_1;
    474:
      Result := opINCW_0;
    475:
      Result := opINCW_1;
    476:
      Result := opPREPARE_0;
    477:
      Result := opPREPARE_1;
    478:
      Result := opTASI_0;
    479:
      Result := opTASI_1;
    480:
      Result := opRET_0;
    481:
      Result := opRET_1;
    482:
      Result := opPOPM_0;
    483:
      Result := opPOPM_1;
    484:
      Result := opPOP_0;
    485:
      Result := opPOP_1;
    486:
      Result := opJSR_0;
    487:
      Result := opJSR_1;
    488:
      Result := opRETIU_0;
    489:
      Result := opRETIU_1;
    490:
      Result := opPUSHM_0;
    491:
      Result := opPUSHM_1;
    492:
      Result := opPUSH_0;
    493:
      Result := opPUSH_1;
    494:
      Result := opTESTB_0;
    495:
      Result := opTESTB_1;
    496:
      Result := opTESTH_0;
    497:
      Result := opTESTH_1;
    498:
      Result := opTESTW_0;
    499:
      Result := opTESTW_1;
    500:
      Result := opGETPSW_0;
    501:
      Result := opGETPSW_1;
    502:
      Result := opTRAP_0;
    503:
      Result := opTRAP_1;
    504:
      Result := opRETIS_0;
    505:
      Result := opRETIS_1;
    506:
      Result := opSTTASK_0;
    507:
      Result := opSTTASK_1;
    508:
      Result := opCLRTLB_0;
    509:
      Result := opCLRTLB_1;
  else
    Illegal;
    Result := 0;
  end;
end;

constructor TV60.Create(Read: TV60Read; Write: TV60Write; IRQ: TV60IRQ);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FIRQ := IRQ;
  Reset;
end;

procedure TV60.Reset;
begin
  FillChar(m_reg, SizeOf(m_reg), 0);
  FillChar(m_flags, SizeOf(m_flags), 0);
  m_reg[32] := $FFFFFFF0;
  m_reg[33] := $10000000;
  m_reg[43] := $70;
  m_reg[44] := $E000;
  m_reg[45] := $6000;
  m_reg[51] := $F002;
  FIRQLine := False;
  FHalted := False;
  FCycleDebt := 0;
  FLastInstructionCycles := 0;
  FCountingBus := False;
  ResetPrefetch(m_reg[32]);
  FStringState := Default(TV60StringState);
  FStringFrames := nil;
  m_stall_io := 0;
end;

function TV60.Read8(Address: Cardinal): Byte;
begin
  AccountBus(Address, 1, False);
  Result := FRead(Address and $FFFFFF);
end;

function TV60.Read16(Address: Cardinal): Word;
begin
  if Address and 1 <> 0 then
  begin
    var L := Read8(Address);
    var H := Read8(Address + 1);
    Exit(Word(L) or (Word(H) shl 8));
  end;
  AccountBus(Address, 2, False);
  if Assigned(FReadWord) then
    Exit(FReadWord(Address and $FFFFFF));
  var L := FRead(Address and $FFFFFF);
  var H := FRead((Address + 1) and $FFFFFF);
  Result := Word(L) or (Word(H) shl 8);
end;

function TV60.Read32(Address: Cardinal): Cardinal;
begin
  if Address and 1 <> 0 then
  begin
    var L := Read8(Address);
    var M := Read16(Address + 1);
    var H := Read8(Address + 3);
    Exit(Cardinal(L) or (Cardinal(M) shl 8) or (Cardinal(H) shl 24));
  end;
  var L := Read16(Address);
  var H := Read16(Address + 2);
  Result := Cardinal(L) or (Cardinal(H) shl 16);
end;

procedure TV60.Write8(Address: Cardinal; Value: Byte);
begin
  AccountBus(Address, 1, True);
  FWrite(Address and $FFFFFF, Value);
end;

procedure TV60.Write16(Address: Cardinal; Value: Word);
begin
  if Address and 1 <> 0 then
  begin
    Write8(Address, Byte(Value));
    Write8(Address + 1, Byte(Value shr 8));
    Exit;
  end;
  AccountBus(Address, 2, True);
  if Assigned(FWriteWord) then
    FWriteWord(Address and $FFFFFF, Value)
  else
  begin
    FWrite(Address and $FFFFFF, Byte(Value));
    FWrite((Address + 1) and $FFFFFF, Byte(Value shr 8));
  end;
end;

procedure TV60.Write32(Address: Cardinal; Value: Cardinal);
begin
  if Address and 1 <> 0 then
  begin
    Write8(Address, Byte(Value));
    Write16(Address + 1, Word(Value shr 8));
    Write8(Address + 3, Byte(Value shr 24));
  end
  else
  begin
    Write16(Address, Word(Value));
    Write16(Address + 2, Word(Value shr 16));
  end;
end;

function TV60.Read64(Address: Cardinal): UInt64;
begin
  var L := Read32(Address);
  var H := Read32(Address + 4);
  Result := UInt64(L) or (UInt64(H) shl 32);
end;

procedure TV60.Write64(Address: Cardinal; Value: UInt64);
begin
  Write32(Address, Cardinal(Value));
  Write32(Address + 4, Cardinal(Value shr 32));
end;

function TV60.IORead8(Address: Cardinal): Byte;
begin
  AccountBus(Address, 1, False);
  Result := $FF;
  if Assigned(FIORead) then
    Result := FIORead(Address and $FFFFFF);
end;

function TV60.IORead16(Address: Cardinal): Word;
begin
  if Address and 1 <> 0 then
  begin
    var L := IORead8(Address);
    var H := IORead8(Address + 1);
    Exit(Word(L) or (Word(H) shl 8));
  end;
  AccountBus(Address, 2, False);
  Result := $FFFF;
  if Assigned(FIORead) then
  begin
    var L := FIORead(Address and $FFFFFF);
    var H := FIORead((Address + 1) and $FFFFFF);
    Result := Word(L) or (Word(H) shl 8);
  end;
end;

function TV60.IORead32(Address: Cardinal): Cardinal;
begin
  if Address and 1 <> 0 then
  begin
    var L := IORead8(Address);
    var M := IORead16(Address + 1);
    var H := IORead8(Address + 3);
    Exit(Cardinal(L) or (Cardinal(M) shl 8) or (Cardinal(H) shl 24));
  end;
  var L := IORead16(Address);
  var H := IORead16(Address + 2);
  Result := Cardinal(L) or (Cardinal(H) shl 16);
end;

procedure TV60.IOWrite8(Address: Cardinal; Value: Byte);
begin
  AccountBus(Address, 1, True);
  if Assigned(FIOWrite) then
    FIOWrite(Address and $FFFFFF, Value);
end;

procedure TV60.IOWrite16(Address: Cardinal; Value: Word);
begin
  if Address and 1 <> 0 then
  begin
    IOWrite8(Address, Byte(Value));
    IOWrite8(Address + 1, Byte(Value shr 8));
    Exit;
  end;
  AccountBus(Address, 2, True);
  if Assigned(FIOWrite) then
  begin
    FIOWrite(Address and $FFFFFF, Byte(Value));
    FIOWrite((Address + 1) and $FFFFFF, Byte(Value shr 8));
  end;
end;

procedure TV60.IOWrite32(Address: Cardinal; Value: Cardinal);
begin
  if Address and 1 <> 0 then
  begin
    IOWrite8(Address, Byte(Value));
    IOWrite16(Address + 1, Word(Value shr 8));
    IOWrite8(Address + 3, Byte(Value shr 24));
  end
  else
  begin
    IOWrite16(Address, Word(Value));
    IOWrite16(Address + 2, Word(Value shr 16));
  end;
end;

procedure TV60.Illegal;
begin
  raise EInvalidOpException.CreateFmt('V60 unsupported instruction/addressing at %.8x (opcode %.2x)', [m_reg[32], Read8(m_reg[32])]);
end;

// Integer division and arithmetic frames: NEC uPD70616 Programmer's
// Reference Manual, DIV/DIVU/DIVX/DIVUX and sections 8-3, 8-17.
procedure TV60.IntegerException(Code: Word; InstructionLength: Cardinal);
begin
  var CurrentPC := m_reg[32];
  var OldPSW := v60_update_psw_for_exception(0, 0);
  Dec(m_reg[31], 4);
  Write32(m_reg[31], CurrentPC);
  Dec(m_reg[31], 4);
  Write32(m_reg[31], (Cardinal(Code) shl 16) or 8);
  Dec(m_reg[31], 4);
  Write32(m_reg[31], OldPSW);
  Dec(m_reg[31], 4);
  Write32(m_reg[31], CurrentPC + InstructionLength);
  m_reg[32] := Read32((m_reg[41] and $FFFFF000) + 21 * 4);
end;

function TV60.DivideInteger(Size: Integer; Unsigned, Extended: Boolean): Cardinal;
begin
  var DestinationSize := Size;
  if Extended then
    DestinationSize := 3;
  F12DecodeOperands(231, Byte(Size), 232, Byte(DestinationSize));
  Result := m_amlength1 + m_amlength2 + 2;
  if m_op1 = 0 then
  begin
    IntegerException($1500, Result);
    Exit(0);
  end;
  var Dividend: UInt64;
  if m_flag2 <> 0 then
  begin
    Dividend := m_reg[m_op2];
    if Extended then
      Dividend := Dividend or (UInt64(m_reg[(m_op2 and 31) + 1]) shl 32);
  end
  else if Extended then
    Dividend := Read64(m_op2)
  else
    case Size of
      0:
        Dividend := Read8(m_op2);
      1:
        Dividend := Read16(m_op2);
    else
      Dividend := Read32(m_op2);
    end;
  var Quotient: UInt64;
  var Remainder: UInt64;
  if Unsigned then
  begin
    if not Extended then
      case Size of
        0:
          Dividend := Byte(Dividend);
        1:
          Dividend := Word(Dividend);
      else
        Dividend := Cardinal(Dividend);
      end;
    Quotient := Dividend div UInt64(m_op1);
    Remainder := Dividend mod UInt64(m_op1);
    if Extended and (Quotient > High(Cardinal)) then
    begin
      m_flags.OV := 1;
      Exit;
    end;
  end
  else
  begin
    var SignedDividend: Int64;
    var Divisor: Int64;
    if Extended then
      SignedDividend := Int64(Dividend)
    else
      case Size of
        0:
          SignedDividend := ShortInt(Dividend);
        1:
          SignedDividend := SmallInt(Dividend);
      else
        SignedDividend := Integer(Dividend);
      end;
    case Size of
      0:
        Divisor := ShortInt(m_op1);
      1:
        Divisor := SmallInt(m_op1);
    else
      Divisor := Integer(m_op1);
    end;
    if (SignedDividend = Low(Int64)) and (Divisor = -1) then
    begin
      m_flags.OV := 1;
      Exit;
    end;
    var Q := SignedDividend div Divisor;
    var MinValue := Int64(Low(Integer));
    var MaxValue := Int64(High(Integer));
    if not Extended then
      case Size of
        0:
          begin
            MinValue := -128;
            MaxValue := 127;
          end;
        1:
          begin
            MinValue := -32768;
            MaxValue := 32767;
          end;
      end;
    if (Q < MinValue) or (Q > MaxValue) then
    begin
      m_flags.OV := 1;
      Exit;
    end;
    Quotient := UInt64(Q);
    Remainder := UInt64(SignedDividend mod Divisor);
  end;
  m_flags.OV := 0;
  case Size of
    0:
      begin
        m_flags.Z := Ord(Byte(Quotient) = 0);
        m_flags.S := Ord(Quotient and $80 <> 0);
      end;
    1:
      begin
        m_flags.Z := Ord(Word(Quotient) = 0);
        m_flags.S := Ord(Quotient and $8000 <> 0);
      end;
    2:
      begin
        m_flags.Z := Ord(Cardinal(Quotient) = 0);
        m_flags.S := Ord(Quotient and $80000000 <> 0);
      end;
  end;
  if m_flag2 <> 0 then
  begin
    if Extended then
    begin
      m_reg[m_op2] := Cardinal(Quotient);
      m_reg[(m_op2 and 31) + 1] := Cardinal(Remainder);
    end
    else
      case Size of
        0:
          m_reg[m_op2] := (m_reg[m_op2] and $FFFFFF00) or Byte(Quotient);
        1:
          m_reg[m_op2] := (m_reg[m_op2] and $FFFF0000) or Word(Quotient);
        2:
          m_reg[m_op2] := Cardinal(Quotient);
      end;
  end
  else if Extended then
  begin
    Write32(m_op2, Cardinal(Quotient));
    Write32(m_op2 + 4, Cardinal(Remainder));
  end
  else
    case Size of
      0:
        Write8(m_op2, Byte(Quotient));
      1:
        Write16(m_op2, Word(Quotient));
      2:
        Write32(m_op2, Cardinal(Quotient));
    end;
end;

// NEC V60 Programmer's Reference, SHA/SHL/ROT/ROTC (7-91..7-101).
// Work one bit at a time so signed-byte counts, especially -128 and counts
// beyond the operand width, never inherit the host compiler's shift masks.
// Kind: 0 arithmetic shift, 1 logical shift, 2 rotate, 3 rotate through CY.
function TV60.ShiftRotateInteger(Size, Kind: Integer): Cardinal;
begin
  F12DecodeOperands(231, 0, 232, Size);
  var Bits := 8 shl Size;
  var Mask := Cardinal(UInt64($FFFFFFFF) shr (32 - Bits));
  var Sign := Cardinal(1) shl (Bits - 1);
  var Original: Cardinal;
  if m_flag2 <> 0 then
    Original := m_reg[m_op2]
  else
    case Size of
      0:
        Original := Read8(m_op2);
      1:
        Original := Read16(m_op2);
    else
      Original := Read32(m_op2);
    end;
  var Value := Original and Mask;
  var Count := Integer(ShortInt(Byte(m_op1)));
  var Carry := Ord(m_flags.CY <> 0);
  var Overflow := False;
  for var i := 1 to Abs(Count) do
  begin
    var OldSign := Value and Sign;
    var OldCarry := Carry;
    if Count > 0 then
    begin
      Carry := Ord(OldSign <> 0);
      Value := (Value shl 1) and Mask;
      case Kind of
        0:
          Overflow := Overflow or (Value and Sign <> OldSign);
        2:
          Value := Value or Cardinal(Carry);
        3:
          Value := Value or Cardinal(OldCarry);
      end;
    end
    else
    begin
      Carry := Value and 1;
      Value := Value shr 1;
      case Kind of
        0:
          Value := Value or OldSign;
        2:
          if Carry <> 0 then
            Value := Value or Sign;
        3:
          if OldCarry <> 0 then
            Value := Value or Sign;
      end;
    end;
  end;
  if Count = 0 then
    Carry := 0;
  m_flags.CY := Carry;
  m_flags.OV := Ord(Overflow);
  m_flags.S := Ord(Value and Sign <> 0);
  m_flags.Z := Ord(Value = 0);
  if m_flag2 <> 0 then
    m_reg[m_op2] := (Original and not Mask) or Value
  else
    case Size of
      0:
        Write8(m_op2, Byte(Value));
      1:
        Write16(m_op2, Word(Value));
    else
      Write32(m_op2, Value);
    end;
  Result := 2 + m_amlength1 + m_amlength2;
end;

// NEC V60 MUL: OV means the double-width signed product cannot be
// represented in the signed destination width. A nonzero high half is
// not an overflow test: fitting negative products have sign extension.
function TV60.MultiplySignedInteger(Size: Integer): Cardinal;
begin
  F12DecodeOperands(231, Size, 232, Size);
  var Bits := 8 shl Size;
  var Mask := Cardinal(UInt64($FFFFFFFF) shr (32 - Bits));
  var Sign := Int64(1) shl (Bits - 1);
  var Original: Cardinal;
  if m_flag2 <> 0 then
    Original := m_reg[m_op2]
  else
    case Size of
      0:
        Original := Read8(m_op2);
      1:
        Original := Read16(m_op2);
    else
      Original := Read32(m_op2);
    end;
  var A := Int64(m_op1 and Mask);
  var B := Int64(Original and Mask);
  if A >= Sign then
    Dec(A, Int64(Mask) + 1);
  if B >= Sign then
    Dec(B, Int64(Mask) + 1);
  var Product := A * B;
  var Value := Cardinal(UInt64(Product) and Mask);
  m_flags.OV := Ord((Product < -Sign) or (Product >= Sign));
  m_flags.S := Ord(Value and Cardinal(Sign) <> 0);
  m_flags.Z := Ord(Value = 0);
  // CY is unchanged. Narrow destinations retain their other bits/bytes.
  if m_flag2 <> 0 then
    m_reg[m_op2] := (Original and not Mask) or Value
  else
    case Size of
      0:
        Write8(m_op2, Byte(Value));
      1:
        Write16(m_op2, Word(Value));
    else
      Write32(m_op2, Value);
    end;
  Result := 2 + m_amlength1 + m_amlength2;
end;

// Native resumable string execution. NEC V60 Programmer's Reference:
// PSW.IP (3-5), interrupt frames (8-3), MOVC/CMPC/SCHC and bit strings.
// One external transfer per step; aligned halfwords use one 16-bit cycle.
// EXU microprogram latency remains provisional, as in V60.Timing.inc.
const
  skMove = 1;
  skCompare = 2;
  skSearch = 3;
  skBitSearch = 4;
  skBitMove = 5;
  smDown = 1;
  smFill = 2;
  smStop = 4;
  smOne = 8;

function TV60.GetStringPending: Boolean;
begin
  Result := FStringState.Kind <> 0;
end;

procedure TV60.StartString(AKind, ASize, AMode: Byte);
begin
  FStringState := Default(TV60StringState);
  with FStringState do
  begin
    Kind := AKind;
    Size := ASize;
    Mode := AMode;
    PC := m_reg[32];
    Task := m_reg[42];
    Source := m_op1;
    Destination := m_op2;
    Len1 := m_lenop1;
    Len2 := m_lenop2;
    InstructionLength := m_amlength1 + m_amlength2 + 3;
    if Kind in [skMove, skCompare] then
      Inc(InstructionLength);
    Limit := Len1;
    if Kind in [skMove, skCompare] then
      Limit := Min(Len1, Len2);
    if (Kind = skCompare) and (Mode and smFill <> 0) then
      Limit := Max(Len1, Len2);
    Index := 0;
    if Mode and smDown <> 0 then
      Index := Int64(Len1) - 1;
    SrcBit := Integer(m_bamoffset1);
    DstBit := Integer(m_bamoffset2);
    if Kind = skBitSearch then
      SrcBit := Integer(m_bamoffset);
    DestinationRegister := m_flag2;
    if Kind = skCompare then
    begin
      m_flags.Z := 0;
      m_flags.S := 0;
      if Mode and smStop <> 0 then
        m_flags.CY := 1;
    end;
    if (Kind = skMove) and (Mode and smStop <> 0) then
      m_flags.CY := 1;
  end;
  if AKind in [skMove, skCompare, skSearch] then
    StringPointers;
  if (AKind in [skBitSearch, skBitMove]) and (FStringState.Len1 <> 0) then
  begin
    var P := FStringState.SrcBit + FStringState.Index;
    m_reg[28] := Cardinal(Int64(FStringState.Source) + (P - (P and 7)) div 8);
    if AKind = skBitMove then
    begin
      P := FStringState.DstBit + FStringState.Index;
      m_reg[27] := Cardinal(Int64(FStringState.Destination) + (P - (P and 7)) div 8);
    end;
  end;
  m_reg[33] := m_reg[33] or $04000000;
end;

procedure TV60.StringTransfer(Address: Cardinal; Width: Byte; WriteAccess: Boolean; Value: Cardinal; NextPhase: Byte);
begin
  with FStringState do
  begin
    BusAddress := Address;
    BusWidth := Width;
    BusIndex := 0;
    BusWrite := Ord(WriteAccess);
    BusValue := Value;
    BusNextPhase := NextPhase;
    if not WriteAccess then
      BusValue := 0;
  end;
end;

procedure TV60.StringPointers;
begin
  with FStringState do
  begin
    if Kind in [skMove, skCompare] then
    begin
      var SrcProgress := Min(Progress, Limit);
      if Kind = skCompare then
        SrcProgress := Min(Progress, Len1);
      var DstProgress := Progress;
      if Kind = skCompare then
        DstProgress := Min(Progress, Len2);
      var A := Int64(SrcProgress);
      var B := Int64(DstProgress);
      if Mode and smDown <> 0 then
      begin
        A := Int64(Len1) - A - 1;
        B := Int64(Len2) - B - 1;
      end;
      m_reg[28] := Cardinal(Int64(Source) + A * (1 shl Size));
      m_reg[27] := Cardinal(Int64(Destination) + B * (1 shl Size));
    end
    else if Kind = skSearch then
    begin
      m_reg[28] := Cardinal(Int64(Source) + Index * (1 shl Size));
      m_reg[27] := Cardinal(Index);
    end;
  end;
end;

function TV60.StringStep(AllowBus: Boolean): Int64;

  function BitAddress(Base: Cardinal; Position: Int64): Cardinal;
  begin
    Result := Cardinal(Int64(Base) + (Position - (Position and 7)) div 8);
  end;

  procedure NextElement;
  begin
    Inc(FStringState.Progress);
    if FStringState.Mode and smDown <> 0 then
      Dec(FStringState.Index)
    else
      Inc(FStringState.Index);
    FStringState.Phase := 0;
  end;

begin
  Result := 0;
  // Reestablish the interrupted instruction's packed-byte timing state.
  FCountingBus := True;
  FStringBus := FStringState.Kind in [skMove, skCompare, skSearch];
  FDataClocks := 0;
  FLastReadByte := FStringState.LastRead;
  FLastWriteByte := FStringState.LastWrite;
  FLastReadValid := FStringState.ReadValid <> 0;
  FLastWriteValid := FStringState.WriteValid <> 0;
  while FStringState.Kind <> 0 do
  begin
    if FStringState.BusWidth <> 0 then
    begin
      // The second byte of an already charged packed word belongs to the
      // same boundary. Resolve it even at the end of the host's slice.
      var PackedByte := False;
      if FStringBus and (FStringState.BusWidth - FStringState.BusIndex = 1) then
      begin
        var Address := FStringState.BusAddress + FStringState.BusIndex;
        if FStringState.BusWrite <> 0 then
          PackedByte := FLastWriteValid and ((FLastWriteByte xor Address) = 1)
        else
          PackedByte := FLastReadValid and ((FLastReadByte xor Address) = 1);
      end;
      if not AllowBus and not PackedByte then
      begin
        FCountingBus := False;
        Exit(0);
      end;
      with FStringState do
      begin
        if (BusWidth - BusIndex >= 2) and ((BusAddress + BusIndex) and 1 = 0) then
        begin
          if BusWrite <> 0 then
            Write16(BusAddress + BusIndex, Word(BusValue shr (BusIndex * 8)))
          else
            BusValue := BusValue or (Cardinal(Read16(BusAddress + BusIndex)) shl (BusIndex * 8));
          Inc(BusIndex, 2);
        end
        else
        begin
          if BusWrite <> 0 then
            Write8(BusAddress + BusIndex, Byte(BusValue shr (BusIndex * 8)))
          else
            BusValue := BusValue or (Cardinal(Read8(BusAddress + BusIndex)) shl (BusIndex * 8));
          Inc(BusIndex);
        end;
        if BusIndex = BusWidth then
        begin
          BusWidth := 0;
          Phase := BusNextPhase;
        end;
        Inc(DataClocks, FDataClocks);
        LastRead := FLastReadByte;
        LastWrite := FLastWriteByte;
        ReadValid := Ord(FLastReadValid);
        WriteValid := Ord(FLastWriteValid);
      end;
      if AllowBus then
      begin
        FCountingBus := False;
        Exit(FDataClocks);
      end;
      Continue;
    end;
    with FStringState do
      case Kind of
        skMove:
          case Phase of
            0:
              begin
                StringPointers;
                if Progress < Limit then
                  StringTransfer(m_reg[28], 1 shl Size, False, 0, 1)
                else if (Mode and smFill <> 0) and (Progress < Len2) then
                  StringTransfer(m_reg[27], 1 shl Size, True, m_reg[26], 3)
                else
                  Break;
              end;
            1:
              begin
                SrcValue := BusValue;
                StringTransfer(m_reg[27], 1 shl Size, True, SrcValue, 2);
              end;
            2:
              begin
                Inc(Progress);
                StringPointers;
                var Mask := Cardinal($FF);
                if Size <> 0 then
                  Mask := $FFFF;
                if (Mode and smStop <> 0) and ((SrcValue and Mask) = (m_reg[26] and Mask)) then
                begin
                  m_flags.CY := 0;
                  Break;
                end;
                Phase := 0;
              end;
            3:
              begin
                Inc(Progress);
                Phase := 0;
              end;
          end;
        skCompare:
          case Phase of
            0:
              begin
                StringPointers;
                if Progress = Limit then
                begin
                  m_flags.S := Ord(Len1 > Len2);
                  m_flags.Z := Ord(Len1 = Len2);
                  Break;
                end;
                if Progress < Len1 then
                  StringTransfer(m_reg[28], 1 shl Size, False, 0, 1)
                else
                begin
                  SrcValue := m_reg[26];
                  Phase := 2;
                end;
              end;
            1:
              begin
                SrcValue := BusValue;
                Phase := 2;
              end;
            2:
              if Progress < Len2 then
                StringTransfer(m_reg[27], 1 shl Size, False, 0, 3)
              else
              begin
                BusValue := m_reg[26];
                Phase := 3;
              end;
            3:
              begin
                var Mask := Cardinal($FF);
                if Size <> 0 then
                  Mask := $FFFF;
                SrcValue := SrcValue and Mask;
                var Other := BusValue and Mask;
                var Stopped := (Mode and smStop <> 0) and ((SrcValue = (m_reg[26] and Mask)) or (Other = (m_reg[26] and Mask)));
                if Stopped then
                  m_flags.CY := 0;
                if SrcValue <> Other then
                begin
                  m_flags.S := Ord(SrcValue > Other);
                  m_flags.Z := 0;
                  Break;
                end;
                if Stopped then
                begin
                  m_flags.S := 0;
                  m_flags.Z := 1;
                  Break;
                end;
                Inc(Progress);
                Phase := 0;
              end;
          end;
        skSearch:
          case Phase of
            0:
              begin
                StringPointers;
                if Progress = Len1 then
                begin
                  m_flags.Z := 1;
                  Break;
                end;
                StringTransfer(m_reg[28], 1 shl Size, False, 0, 1);
              end;
            1:
              begin
                var Mask := Cardinal($FF);
                if Size <> 0 then
                  Mask := $FFFF;
                if ((BusValue and Mask) = (Destination and Mask)) = (Mode and smOne <> 0) then
                begin
                  m_flags.Z := 0;
                  Break;
                end;
                NextElement;
              end;
          end;
        skBitSearch:
          case Phase of
            0:
              begin
                if Progress = Len1 then
                begin
                  m_flags.Z := 1;
                  Phase := 3;
                  Continue;
                end;
                var Address := BitAddress(Source, SrcBit + Index);
                m_reg[28] := Address;
                if (SrcValid = 0) or (SrcAddress <> Address) then
                  StringTransfer(Address, 1, False, 0, 1)
                else
                  Phase := 2;
              end;
            1:
              begin
                SrcAddress := m_reg[28];
                SrcByte := Byte(BusValue);
                SrcValid := 1;
                Phase := 2;
              end;
            2:
              begin
                if (SrcByte and (1 shl Integer((SrcBit + Index) and 7)) <> 0) = (Mode and smOne <> 0) then
                begin
                  m_flags.Z := 0;
                  Phase := 3;
                  Continue;
                end;
                NextElement;
              end;
            3:
              if DestinationRegister <> 0 then
              begin
                m_reg[Destination] := Cardinal(Index);
                Phase := 4;
              end
              else
                StringTransfer(Destination, 4, True, Cardinal(Index), 4);
            4:
              Break;
          end;
        skBitMove:
          case Phase of
            0:
              begin
                if Progress = Len1 then
                  Break;
                var A := BitAddress(Source, SrcBit + Index);
                var B := BitAddress(Destination, DstBit + Index);
                m_reg[28] := A;
                m_reg[27] := B;
                if (SrcValid = 0) or (SrcAddress <> A) then
                  StringTransfer(A, 1, False, 0, 1)
                else
                  Phase := 2;
              end;
            1:
              begin
                SrcAddress := m_reg[28];
                SrcByte := Byte(BusValue);
                SrcValid := 1;
                Phase := 2;
              end;
            2:
              if (DstValid = 0) or (DstAddress <> m_reg[27]) then
                StringTransfer(m_reg[27], 1, False, 0, 3)
              else
                Phase := 4;
            3:
              begin
                DstAddress := m_reg[27];
                DstByte := Byte(BusValue);
                DstValid := 1;
                Phase := 4;
              end;
            4:
              begin
                var Bit := Integer((DstBit + Index) and 7);
                var A := (SrcByte shr Integer((SrcBit + Index) and 7)) and 1;
                var B := (DstByte shr Bit) and 1;
                case Logic of
                  1:
                    A := A xor 1;
                  2:
                    A := A and B;
                  3:
                    A := (A xor 1) and B;
                  4:
                    A := A or B;
                  5:
                    A := (A xor 1) or B;
                  6:
                    A := A xor B;
                  7:
                    A := (A xor 1) xor B;
                end;
                DstByte := (DstByte and not (1 shl Bit)) or (A shl Bit);
                NextElement;
                if (Progress = Len1) or (BitAddress(Destination, DstBit + Index) <> DstAddress) then
                  StringTransfer(DstAddress, 1, True, DstByte, 5);
              end;
            5:
              begin
                DstValid := 0;
                Phase := 0;
              end;
          end;
      end;
  end;
  // Complete without charging code/data transfers twice. The unused part
  // of the provisional eight-clock EXU floor can refill sequential PFU.
  var Saved := FStringState;
  var Idle := Max(Int64(0), Int64(8) - Saved.CodeClocks - Saved.DataClocks);
  Inc(Result, Idle);
  BackgroundPrefetch(Idle);
  FLastInstructionCycles := Max(Int64(8), Saved.CodeClocks + Saved.DataClocks);
  m_reg[32] := Saved.PC + Saved.InstructionLength;
  m_reg[33] := m_reg[33] and not Cardinal($04000000);
  FStringState := Default(TV60StringState);
  FCountingBus := False;
end;

procedure TV60.SuspendString(Frame: Cardinal);
begin
  if FStringState.Kind = 0 then
    Exit;
  var N := Length(FStringFrames);
  SetLength(FStringFrames, N + 1);
  FStringFrames[N].Frame := Frame;
  FStringFrames[N].State := FStringState;
  FStringState := Default(TV60StringState);
end;

procedure TV60.RestoreString(Frame, NewPSW: Cardinal);
begin
  for var i := High(FStringFrames) downto 0 do
    if (FStringFrames[i].Frame = Frame) and (FStringFrames[i].State.Task = m_reg[42]) then
    begin
      if (NewPSW and $04000000 <> 0) and (m_reg[32] = FStringFrames[i].State.PC) then
        FStringState := FStringFrames[i].State;
      for var J := i to High(FStringFrames) - 1 do
        FStringFrames[J] := FStringFrames[J + 1];
      SetLength(FStringFrames, Length(FStringFrames) - 1);
      Exit;
    end;
end;

procedure TV60.RestoreTaskString;
begin
  if GetStringPending or (m_reg[33] and $04000000 = 0) then
    Exit;
  // A kernel may restore the pending PC/PSW through another saved task
  // context instead of returning through the original interrupt frame.
  for var i := High(FStringFrames) downto 0 do
    if (FStringFrames[i].State.Task = m_reg[42]) and (FStringFrames[i].State.PC = m_reg[32]) then
    begin
      FStringState := FStringFrames[i].State;
      for var J := i to High(FStringFrames) - 1 do
        FStringFrames[J] := FStringFrames[J + 1];
      SetLength(FStringFrames, Length(FStringFrames) - 1);
      Exit;
    end;
end;

procedure TV60.SerializeStrings(State: TStateArchive);

  procedure Validate(const S: TV60StringState);
  begin
    if (S.Kind > skBitMove) or (S.Size > 1) or (S.Phase > 5) or (S.Mode > 15) or (S.Logic > 7) or
      not (S.BusWidth in [0, 1, 2, 4]) or ((S.BusIndex > S.BusWidth) and (S.BusWidth <> 0)) or
      (S.BusWrite > 1) or (S.BusNextPhase > 5) or (S.ReadValid > 1) or (S.WriteValid > 1) or
      (S.SrcValid > 1) or (S.DstValid > 1) or (S.DataClocks < 0) or (S.CodeClocks < 0) or
      (S.DataClocks > Int64(1) shl 48) or (S.CodeClocks > Int64(1) shl 40) then
      raise EReadError.Create('Invalid V60 string state');
    if ((S.Kind in [skSearch, skBitSearch, skBitMove]) and (S.Progress > S.Len1)) or
      ((S.Kind = skMove) and (S.Progress > Max(S.Len1, S.Len2))) or
      ((S.Kind = skCompare) and (S.Progress > S.Limit)) or
      (S.Index < -1) or (S.Index > Int64(High(Cardinal))) then
      raise EReadError.Create('Invalid V60 string progress');
  end;

begin
  State.Field(FStringState, SizeOf(FStringState));
  Validate(FStringState);
  var N: Cardinal := Length(FStringFrames);
  State.Field(N, SizeOf(N));
  if N > 4096 then
    raise EReadError.Create('Invalid V60 string frame count');
  if State.Loading then
    SetLength(FStringFrames, N);
  for var i := 0 to Integer(N) - 1 do
  begin
    State.Field(FStringFrames[i], SizeOf(FStringFrames[i]));
    Validate(FStringFrames[i].State);
  end;
end;
// NEC uPD70616 Programmer's Reference, SCH0BS/SCH1BS (7-94..95),
// SCHC (7-96), SKPC (7-102). Native bounded scans; no reference code copied.
// Bus-constraint mode uses the resumable engine; reference8 preserves the
// old atomic behavior solely for controlled reference/semantic comparisons.

function TV60.SearchCharacters(Size: Integer; Search, Downward: Boolean): Cardinal;
begin
  F7bDecodeOperands(232, Size, 231, Size);
  if FCycleModel = vcmBusConstraints then
  begin
    StartString(3, Size, Ord(Downward) + 8 * Ord(Search));
    Exit(0);
  end;
  var Index: Int64 := 0;
  if Downward then
    Index := Int64(m_lenop1) - 1;
  var Found := False;
  var Examined: Cardinal := 0;
  while Examined < m_lenop1 do
  begin
    var Address := Cardinal(Int64(m_op1) + Index * (1 shl Size));
    var Equal: Boolean;
    if Size = 0 then
      Equal := Read8(Address) = Byte(m_op2)
    else
      Equal := Read16(Address) = Word(m_op2);
    Found := Equal = Search;
    if Found then
      Break;
    Inc(Examined);
    if Downward then
      Dec(Index)
    else
      Inc(Index);
  end;
  m_reg[28] := Cardinal(Int64(m_op1) + Index * (1 shl Size));
  // Preserve the reference's head-relative index for downward searches.
  // NEC's wording does not resolve head-relative vs scan-relative R27.
  m_reg[27] := Cardinal(Index);
  // The preliminary manual says Z=found, while MAME explicitly reports
  // the opposite. Retain established upward-search polarity pending a PCB
  // test, but use actual exhaustion (not index==length) in both directions.
  m_flags.Z := Ord(not Found);
  Result := m_amlength1 + m_amlength2 + 3;
end;

function TV60.SearchBits(SearchOne, Downward: Boolean): Cardinal;
begin
  F7bDecodeFirstOperand(263, 10);
  if FCycleModel = vcmBusConstraints then
  begin
    var Offset := m_bamoffset;
    m_moddim := 2;
    m_modm := m_subop and $20;
    m_modadd := m_reg[32] + 3 + m_amlength1;
    m_amlength2 := ReadAMAddress;
    m_op2 := m_amout;
    m_flag2 := m_amflag;
    m_bamoffset := Offset;
    StartString(4, 0, Ord(Downward) + 8 * Ord(SearchOne));
    Exit(0);
  end;
  // Bit displacements are signed. Floor division is required below zero;
  // unsigned division silently moves a -1 displacement 512 MiB forward.
  var StartBit := Int64(Integer(m_bamoffset));
  var Index: Int64 := 0;
  if Downward then
    Index := Int64(m_lenop1) - 1;
  var Examined: Cardinal := 0;
  var Found := False;
  var HaveByte := False;
  var LastAddress: Cardinal := 0;
  var Data: Byte := 0;
  while Examined < m_lenop1 do
  begin
    var Position := StartBit + Index;
    var Bit := Integer(Position and 7);
    var Address := Cardinal(Int64(m_op1) + (Position - Bit) div 8);
    if not HaveByte or (Address <> LastAddress) then
    begin
      Data := Read8(Address);
      LastAddress := Address;
      HaveByte := True;
    end;
    m_reg[28] := Address;
    Found := (Data and (1 shl Bit) <> 0) = SearchOne;
    if Found then
      Break;
    Inc(Examined);
    if Downward then
      Dec(Index)
    else
      Inc(Index);
  end;
  // R28 remains at the detected/final byte, never at an unexamined byte.
  // Empty-string R28 is unspecified by NEC; preserve it without data reads.
  m_flags.Z := Ord(not Found);
  m_modwritevalw := Cardinal(Index);
  F7bWriteSecondOperand(2);
  Result := m_amlength1 + m_amlength2 + 3;
end;
// Timing constraints from Kaneko et al., FJCC 1986, pp.1000-1007.
// This is a partial timing model, not a measured instruction-cycle table.
// The 16-byte PFU occupancy and external 16-bit transfers constrain issue.
// Functional fetches are not cached: speculative bus side effects and
// self-modifying-code visibility still need a complete PFU/BCU simulation.

procedure TV60.ResetPrefetch(Address: Cardinal);
begin
  FPrefetchAddress := Address;
  FPrefetchCount := 0;
  FPrefetchCredit := 0;
  FPrefetchCost := 0;
end;

function TV60.DataBusClocks(Address: Cardinal; IsWrite: Boolean): Integer;
begin
  // Normal four-clock V60 bus cycle. Board-specific READY delays can be
  // supplied separately; System 32's programmable delay values are not
  // calibrated and must not be guessed from their numeric encoding.
  Result := 4;
  if Assigned(FBusClocks) then
    Result := FBusClocks(Address and $FFFFFF, IsWrite);
  if (Result < 1) or (Result > 4096) then
    raise EArgumentException.Create('Invalid V60 bus cycle duration');
end;

function TV60.PrefetchBusClocks: Integer;
begin
  if FPrefetchCost = 0 then
    FPrefetchCost := DataBusClocks((FPrefetchAddress + Cardinal(FPrefetchCount)) and $FFFFFE, False);
  Result := FPrefetchCost;
end;

procedure TV60.ConsumeCode(Address: Cardinal);
begin
  if FCycleModel = vcmReference8 then
    Exit;
  var Distance := Integer(Address - FPrefetchAddress);
  // Decoder helpers may reread fields already decoded in this instruction.
  if Distance < 0 then
    Exit;
  var Need := Distance + 1;
  while Need > 0 do
  begin
    if FPrefetchCount = 0 then
    begin
      Inc(FCodeStalls, PrefetchBusClocks - FPrefetchCredit);
      FPrefetchCredit := 0;
      FPrefetchCost := 0;
      // The physical first word also contains a discarded byte at odd PC.
      FPrefetchCount := 2 - Integer(FPrefetchAddress and 1);
    end;
    var Take := Min(Need, FPrefetchCount);
    Inc(FPrefetchAddress, Take);
    Dec(FPrefetchCount, Take);
    Dec(Need, Take);
  end;
end;

procedure TV60.BackgroundPrefetch(Clocks: Int64);
begin
  // Issue only while at least four bytes are free, as described for PFU.
  // Transfers arrive as external 16-bit words. A partial word keeps its
  // remaining bus clocks across instructions and snapshot/host slices.
  while (Clocks > 0) and (FPrefetchCount <= 12) do
  begin
    var Cost := PrefetchBusClocks;
    var Spend := Integer(Min(Clocks, Int64(Cost - FPrefetchCredit)));
    Inc(FPrefetchCredit, Spend);
    Dec(Clocks, Spend);
    if FPrefetchCredit = Cost then
    begin
      FPrefetchCredit := 0;
      FPrefetchCost := 0;
      Inc(FPrefetchCount, 2 - Integer((FPrefetchAddress + Cardinal(FPrefetchCount)) and 1));
    end;
  end;
end;

procedure TV60.AccountBus(Address: Cardinal; Width: Integer; IsWrite: Boolean);
begin
  if not FCountingBus or (FCycleModel = vcmReference8) then
    Exit;
  var PackedByte := False;
  if FStringBus and (Width = 1) then
  begin
    // Character transfers can pack neighbouring bytes into a word cycle
    // (FJCC section 2.4, Burst String Read). Count a lower bound rather
    // than charging a whole physical word for every interpreter byte.
    if IsWrite then
    begin
      PackedByte := FLastWriteValid and ((FLastWriteByte xor Address) = 1);
      FLastWriteByte := Address;
      FLastWriteValid := not PackedByte;
    end
    else
    begin
      PackedByte := FLastReadValid and ((FLastReadByte xor Address) = 1);
      FLastReadByte := Address;
      FLastReadValid := not PackedByte;
    end;
  end
  else
  begin
    if IsWrite then
      FLastWriteValid := False
    else
      FLastReadValid := False;
  end;
  if not PackedByte then
    Inc(FDataClocks, DataBusClocks(Address, IsWrite));
end;

function TV60.Fetch8(Address: Cardinal): Byte;
begin
  if FCountingBus then
    ConsumeCode(Address);
  Result := FRead(Address and $FFFFFF);
end;

function TV60.Fetch16(Address: Cardinal): Word;
begin
  var L := Fetch8(Address);
  var H := Fetch8(Address + 1);
  Result := Word(L) or (Word(H) shl 8);
end;

function TV60.Fetch32(Address: Cardinal): Cardinal;
begin
  var L := Fetch16(Address);
  var H := Fetch16(Address + 2);
  Result := Cardinal(L) or (Cardinal(H) shl 16);
end;

procedure TV60.BeginTiming;
begin
  FInstructionPC := m_reg[32];
  FCodeStalls := 0;
  FDataClocks := 0;
  FCountingBus := True;
  FStringBus := False;
  FLastReadValid := False;
  FLastWriteValid := False;
  if FPrefetchAddress <> FInstructionPC then
    ResetPrefetch(FInstructionPC);
end;

function TV60.FinishTiming(Opcode, Step: Cardinal): Int64;
begin
  if FCycleModel = vcmReference8 then
  begin
    FCountingBus := False;
    Exit(8);
  end;
  // The reference eight clocks estimate a WHOLE instruction, not EXU time.
  // Keep it as a total fallback instead of adding every code miss to it.
  // Unknown execution-unit microprograms still lack measured V60 counts.
  // Do not misrepresent V70's published counts as measured V60 timings.
  var CoreMinimum: Int64 := 0;
  var FallbackTotal: Int64 := 8;
  if Opcode = $CD then
  begin
    CoreMinimum := 2;
    FallbackTotal := 0;
  end; // best-case issue interval, FJCC Fig.9
  if Opcode in [$85, $86, $95, $96] then
  begin
    CoreMinimum := 16;
    FallbackTotal := 0;
  end; // 32-bit Booth multiplier
  if (Step <> 0) and (m_reg[32] = FInstructionPC + Step) then
    ConsumeCode(m_reg[32] - 1);
  FCountingBus := False;
  var Execution := Max(CoreMinimum, FDataClocks);
  Result := Max(FallbackTotal, FCodeStalls + Execution);
  if (Step = 0) or (m_reg[32] <> FInstructionPC + Step) then
  begin
    ResetPrefetch(m_reg[32]);
    // IDU redirects BCU before EXU terminates a branch (FJCC section 2.4).
    // Free bus clocks may fetch the target, never the discarded fall-through.
    // Exact redirect/decode latency remains outside this lower-bound model.
    if (Opcode in [$60..$7F, $C6, $C7]) then
      BackgroundPrefetch(Max(Int64(0), Result - FCodeStalls - FDataClocks));
  end
  else
    BackgroundPrefetch(Max(Int64(0), Result - FCodeStalls - FDataClocks));
end;

function TV60.Run(Cycles: Integer): Integer;

  procedure Elapse;
  begin
    repeat
      if FCycleDebt < 0 then
      begin
        var N := Integer(Min(Int64(Cycles), -FCycleDebt));
        Inc(FCycleDebt, N);
        Dec(Cycles, N);
        Inc(Result, N);
        if Assigned(FClockCallback) then
          FClockCallback(N);
      end;
      // Resolve completed transfers at the exact end of a host slice,
      // without issuing the next external bus transaction early.
      if (FCycleDebt = 0) and GetStringPending then
        FCycleDebt := -StringStep(False);
    until (Cycles = 0) or (FCycleDebt = 0);
  end;

begin
  if Cycles <= 0 then
    Exit(0);
  Result := 0;
  // Architectural effects still commit at issue. The remaining cost,
  // including bus/prefetch stalls, is retained across every host slice.
  if FCycleDebt < 0 then
    Elapse;
  while Cycles > 0 do
  begin
    RestoreTaskString;
    if FIRQLine and (m_reg[33] and $40000 <> 0) then
    begin
      BeginTiming;
      FHalted := False;
      var Vector: Cardinal := 0;
      if Assigned(FIRQ) then
        Vector := FIRQ;
      var OldPSW := v60_update_psw_for_exception(1, 0);
      Dec(m_reg[31], 4);
      Write32(m_reg[31], OldPSW);
      Dec(m_reg[31], 4);
      Write32(m_reg[31], m_reg[32]);
      m_reg[32] := Read32((m_reg[41] and $FFFFF000) + (Vector + $40) * 4);
      SuspendString(m_reg[31]);
      FCountingBus := False;
      ResetPrefetch(m_reg[32]);
      if FCycleModel = vcmBusConstraints then
      begin
        // Only the unavoidable external transfers are known here. The
        // undocumented V60 interrupt microprogram latency is still absent.
        FCycleDebt := -Max(Int64(1), FDataClocks);
        Elapse;
        Continue;
      end;
    end;
    if GetStringPending then
    begin
      FCycleDebt := -StringStep;
      if FCycleDebt < 0 then
        Elapse;
      Continue;
    end;
    if FHalted then
    begin
      if FCycleModel = vcmReference8 then
        FCycleDebt := -8
      else
        FCycleDebt := -1;
    end
    else
    begin
      BeginTiming;
      var Opcode := Fetch8(m_reg[32]);
      var Step := Dispatch(s_OpCodeTable[Opcode]);
      if GetStringPending and (Opcode in [$58, $5A, $5B]) then
      begin
        FStringState.DataClocks := FDataClocks;
        FStringState.CodeClocks := FCodeStalls;
        FStringState.LastRead := FLastReadByte;
        FStringState.LastWrite := FLastWriteByte;
        FStringState.ReadValid := Ord(FLastReadValid);
        FStringState.WriteValid := Ord(FLastWriteValid);
        FCountingBus := False;
        FCycleDebt := -(FCodeStalls + FDataClocks);
        FLastInstructionCycles := 0;
      end
      else
      begin
        Inc(m_reg[32], Step);
        FCycleDebt := -FinishTiming(Opcode, Step);
        FLastInstructionCycles := -FCycleDebt;
      end;
    end;
    if FCycleDebt < 0 then
      Elapse;
  end;
end;

procedure TV60.SerializeState(State: TStateArchive);
begin
  State.Field(m_reg, SizeOf(m_reg));
  State.Field(m_flags, SizeOf(m_flags));
  State.Field(FCycleDebt, SizeOf(FCycleDebt));
  State.Field(FIRQLine, SizeOf(FIRQLine));
  State.Field(FHalted, SizeOf(FHalted));
  State.Field(FCycleModel, SizeOf(FCycleModel));
  State.Field(FPrefetchAddress, SizeOf(FPrefetchAddress));
  State.Field(FPrefetchCount, SizeOf(FPrefetchCount));
  State.Field(FPrefetchCredit, SizeOf(FPrefetchCredit));
  State.Field(FPrefetchCost, SizeOf(FPrefetchCost));
  SerializeStrings(State);
  if (Ord(FCycleModel) > Ord(High(TV60CycleModel))) or
    (FPrefetchCount < 0) or (FPrefetchCount > 16) or (FPrefetchCredit < 0) or
    (FPrefetchCost < 0) or (FPrefetchCost > 4096) or
    ((FPrefetchCost = 0) and (FPrefetchCredit <> 0)) or
    ((FPrefetchCost <> 0) and (FPrefetchCredit >= FPrefetchCost)) then
    raise EReadError.Create('Invalid V60 prefetch state');
  if (FCycleDebt < -(Int64(1) shl 40)) or (FCycleDebt > 0) or
    ((FCycleModel = vcmReference8) and (FCycleDebt < -7)) then
    raise EReadError.Create('Invalid V60 cycle state');
end;

function TV60.GetRegister(Index: Integer): Cardinal;
begin
  if (Index < 0) or (Index > 67) then
    raise EArgumentOutOfRangeException.Create('V60 register');
  if Index = 33 then
    Exit(v60ReadPSW);
  Result := m_reg[Index];
end;

procedure TV60.SetRegister(Index: Integer; Value: Cardinal);
begin
  if (Index < 0) or (Index > 67) then
    raise EArgumentOutOfRangeException.Create('V60 register');
  if Index = 33 then
    v60WritePSW(Value)
  else
    m_reg[Index] := Value;
  if Index = 32 then
  begin
    ResetPrefetch(Value);
    if GetStringPending and (Value <> FStringState.PC) then
    begin
      FStringState := Default(TV60StringState);
      m_reg[33] := m_reg[33] and not Cardinal($04000000);
    end;
  end;
end;

end.

