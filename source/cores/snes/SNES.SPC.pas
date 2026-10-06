unit SNES.SPC;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TSpcVoice = packed record
    Address, LoopAddress: Word;
    Block: array[0..15] of SmallInt;
    History: array[0..3] of SmallInt;
    Position, Fraction, Prev1, Prev2, Envelope, EnvelopeMode, Counter: Integer;
    PreviousEnvelope: Integer;
    Active, Release: Boolean;
    Header: Byte;
    BRROffset, KeyOnDelay: Integer;
    ENVX: Byte;
  end;

  PSpcVoice = ^TSpcVoice;

  TSpcBusCycle = procedure(Address, Value: Integer; Writing: Boolean) of object;

  TSpcDSPPipeline = packed record
    EveryOtherSample: Boolean;
    NewKON, KON, KOFF, PMON, NON, EON, DIR, SRCN, ADSR: Byte;
    BRRHeader, BRRByte, ENDX, ENVX, OUTX, ESA, EchoFlags: Byte;
    DirectoryAddress, NextAddress, EchoAddress: Word;
    Pitch, Output, Looped, EchoLength: Integer;
    MainOutput, EchoOutput, EchoInput: array[0..1] of Integer;
  end;

  PSpcDSPPipeline = ^TSpcDSPPipeline;

  TSpcState = packed record
    RAM: array[0..65535] of Byte;
    DSP: array[0..127] of Byte;
    PortsIn, PortsOut: array[0..3] of Byte;
    RAMRegisters: array[0..1] of Byte;
    TimerTarget: array[0..2] of Byte;
    A, X, Y, SP, P, Control, DSPAddress: Byte;
    PC: Word;
    Cycles: Int64;
    TimerPrescale, TimerStage, TimerOutput: array[0..2] of Integer;
    SampleClock: Integer;
    Halted: Boolean;
    Voices: array[0..7] of TSpcVoice;
    Noise: Word;
    NoiseCounter, EchoPosition, EchoHistoryPosition: Integer;
    DSPCounter: Integer;
    EchoHistory: array[0..7, 0..1] of SmallInt;
    DSPPipeline: TSpcDSPPipeline;
  end;

  TSnesSPC = class
  private
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
    FOnBusCycle: TSpcBusCycle;
    function BusRead(Address: Word): Byte;
    procedure BusWrite(Address: Word; V: Byte);
    procedure Idle;
    function Fetch: Byte;
    function FetchWord: Word;
    function Direct(Offset: Integer): Word;
    function DirectWord(Offset: Integer): Word;
    procedure Push(V: Byte);
    function Pop: Byte;
    procedure NZ(V: Integer; Wide: Boolean = False);
    procedure Flag(Mask: Byte; Value: Boolean);
    procedure Branch(Taken: Boolean; Offset: Integer; var Cycles: Integer);
    function ALU(Op, A, B: Integer): Byte;
    procedure DecodeBRR(var Voice: TSpcVoice);
    function CheckCounter(Rate: Integer): Boolean;
    procedure ProcessEnvelope(var Voice: TSpcVoice; Base: Integer);
    procedure VoicePhase(Index, Phase: Integer);
    procedure EchoPhase(Phase: Integer);
    procedure DSPTick;
    procedure Clock(Cycles: Integer);
  public
    State: TSpcState;
    constructor Create;
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; V: Byte);
    procedure Step;
    procedure RunUntil(Target: Int64);
    procedure BeginFrame;
    procedure SerializeState(Archive: TStateArchive);
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
    property OnBusCycle: TSpcBusCycle read FOnBusCycle write FOnBusCycle;
  end;

implementation

uses
  System.Math;

const
  C = 1;
  Z = 2;
  I = 4;
  H = 8;
  BFlag = 16;
  PFlag = 32;
  VFlag = 64;
  N = 128;
  IPL: array[0..63] of Byte = ($CD, $EF, $BD, $E8, $00, $C6, $1D, $D0, $FC, $8F, $AA, $F4, $8F, $BB, $F5, $78,
    $CC, $F4, $D0, $FB, $2F, $19, $EB, $F4, $D0, $FC, $7E, $F4, $D0, $0B, $E4, $F5, $CB, $F4, $D7, $00,
    $FC, $D0, $F3, $AB, $01, $10, $EF, $7E, $F4, $10, $EB, $BA, $F6, $DA, $00, $BA, $F4, $C4, $F4, $DD, $5D,
    $D0, $DB, $1F, $00, $00, $C0, $FF);
  InstructionCycles: array[0..255] of Byte = (
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 4, 6, 8,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 6, 5, 2, 2, 4, 6,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 4, 5, 4,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 6, 5, 2, 2, 3, 8,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 4, 6, 6,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 4, 5, 2, 2, 4, 3,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 4, 5, 5,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 3, 6,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 2, 4, 5,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 12, 5,
    3, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 2, 4, 4,
    2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 3, 4,
    3, 8, 4, 5, 4, 5, 4, 7, 2, 5, 6, 4, 5, 2, 4, 9,
    2, 8, 4, 5, 5, 6, 6, 7, 4, 5, 5, 5, 2, 2, 6, 3,
    2, 8, 4, 5, 3, 4, 3, 6, 2, 4, 5, 3, 4, 3, 4, 3,
    2, 8, 4, 5, 4, 5, 5, 6, 3, 4, 5, 4, 2, 2, 4, 3);

type
  TSpcOp = (opADC, opADC_Acc, opADC_Imm, opADDW, opAND, opAND_Acc, opAND_Imm, opAND1,
    opASL, opASL_Acc, opBBC, opBBS, opBCC, opBCS, opBEQ, opBMI, opBNE, opBPL, opBRA,
    opBRK, opBVC, opBVS, opCBNE, opCLR1, opCLRC, opCLRP, opCLRV, opCMP, opCMP_Acc,
    opCMP_Imm, opCMPW, opCPX, opCPX_Imm, opCPY, opCPY_Imm, opDAA, opDAS, opDBNZ,
    opDBNZ_Y, opDEC, opDEC_Acc, opDECW, opDEX, opDEY, opDI, opDIV, opEI, opEOR,
    opEOR_Acc, opEOR_Imm, opEOR1, opINC, opINC_Acc, opINCW, opINX, opINY, opJMP,
    opJSR, opLDA, opLDA_AutoIncX, opLDA_Imm, opLDC, opLDW, opLDX, opLDX_Imm, opLDY,
    opLDY_Imm, opLSR, opLSR_Acc, opMOV, opMOV_Imm, opMUL, opNAND1, opNOP, opNOR1,
    opNOT1, opNOTC, opOR, opOR_Acc, opOR_Imm, opOR1, opPCALL, opPHA, opPHP, opPHX,
    opPHY, opPLA, opPLP, opPLX, opPLY, opROL, opROL_Acc, opROR, opROR_Acc, opRTI,
    opRTS, opSBC, opSBC_Acc, opSBC_Imm, opSET1, opSETC, opSETP, opSTA, opSTA_AutoIncX,
    opSTC, opSTOP, opSTW, opSTX, opSTY, opSUBW, opTAX, opTAY, opTCALL, opTCLR1, opTSET1,
    opTSX, opTXA, opTXS, opTYA, opXCN);

  TSpcMode = (amAbs, amAbsBit, amAbsIdxX, amAbsIdxXInd, amAbsIdxY, amDir, amDirIdxX,
    amDirIdxXInd, amDirIdxY, amDirImm, amDirIndIdxY, amDirToDir, amImm, amIndX, amIndXToIndY, amNone, amRel);

  TSpcInstruction = record
    Op: TSpcOp;
    Mode: TSpcMode;
    Bit: Integer;
  end;

const
  Opcodes: array[0..255] of TSpcInstruction = (
    (Op: opNOP; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 0),
    (Op: opSET1; Mode: amDir; Bit: 0),
    (Op: opBBS; Mode: amDir; Bit: 0),
    (Op: opOR_Acc; Mode: amDir; Bit: 0),
    (Op: opOR_Acc; Mode: amAbs; Bit: 0),
    (Op: opOR_Acc; Mode: amIndX; Bit: 0),
    (Op: opOR_Acc; Mode: amDirIdxXInd; Bit: 0),
    (Op: opOR_Imm; Mode: amImm; Bit: 0),
    (Op: opOR; Mode: amDirToDir; Bit: 0),
    (Op: opOR1; Mode: amAbsBit; Bit: 0),
    (Op: opASL; Mode: amDir; Bit: 0),
    (Op: opASL; Mode: amAbs; Bit: 0),
    (Op: opPHP; Mode: amNone; Bit: 0),
    (Op: opTSET1; Mode: amAbs; Bit: 0),
    (Op: opBRK; Mode: amNone; Bit: 0),
    (Op: opBPL; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 1),
    (Op: opCLR1; Mode: amDir; Bit: 0),
    (Op: opBBC; Mode: amDir; Bit: 0),
    (Op: opOR_Acc; Mode: amDirIdxX; Bit: 0),
    (Op: opOR_Acc; Mode: amAbsIdxX; Bit: 0),
    (Op: opOR_Acc; Mode: amAbsIdxY; Bit: 0),
    (Op: opOR_Acc; Mode: amDirIndIdxY; Bit: 0),
    (Op: opOR; Mode: amDirImm; Bit: 0),
    (Op: opOR; Mode: amIndXToIndY; Bit: 0),
    (Op: opDECW; Mode: amDir; Bit: 0),
    (Op: opASL; Mode: amDirIdxX; Bit: 0),
    (Op: opASL_Acc; Mode: amNone; Bit: 0),
    (Op: opDEX; Mode: amNone; Bit: 0),
    (Op: opCPX; Mode: amAbs; Bit: 0),
    (Op: opJMP; Mode: amAbsIdxXInd; Bit: 0),
    (Op: opCLRP; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 2),
    (Op: opSET1; Mode: amDir; Bit: 1),
    (Op: opBBS; Mode: amDir; Bit: 1),
    (Op: opAND_Acc; Mode: amDir; Bit: 0),
    (Op: opAND_Acc; Mode: amAbs; Bit: 0),
    (Op: opAND_Acc; Mode: amIndX; Bit: 0),
    (Op: opAND_Acc; Mode: amDirIdxXInd; Bit: 0),
    (Op: opAND_Imm; Mode: amImm; Bit: 0),
    (Op: opAND; Mode: amDirToDir; Bit: 0),
    (Op: opNOR1; Mode: amAbsBit; Bit: 0),
    (Op: opROL; Mode: amDir; Bit: 0),
    (Op: opROL; Mode: amAbs; Bit: 0),
    (Op: opPHA; Mode: amNone; Bit: 0),
    (Op: opCBNE; Mode: amDir; Bit: 0),
    (Op: opBRA; Mode: amRel; Bit: 0),
    (Op: opBMI; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 3),
    (Op: opCLR1; Mode: amDir; Bit: 1),
    (Op: opBBC; Mode: amDir; Bit: 1),
    (Op: opAND_Acc; Mode: amDirIdxX; Bit: 0),
    (Op: opAND_Acc; Mode: amAbsIdxX; Bit: 0),
    (Op: opAND_Acc; Mode: amAbsIdxY; Bit: 0),
    (Op: opAND_Acc; Mode: amDirIndIdxY; Bit: 0),
    (Op: opAND; Mode: amDirImm; Bit: 0),
    (Op: opAND; Mode: amIndXToIndY; Bit: 0),
    (Op: opINCW; Mode: amDir; Bit: 0),
    (Op: opROL; Mode: amDirIdxX; Bit: 0),
    (Op: opROL_Acc; Mode: amNone; Bit: 0),
    (Op: opINX; Mode: amNone; Bit: 0),
    (Op: opCPX; Mode: amDir; Bit: 0),
    (Op: opJSR; Mode: amAbs; Bit: 0),
    (Op: opSETP; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 4),
    (Op: opSET1; Mode: amDir; Bit: 2),
    (Op: opBBS; Mode: amDir; Bit: 2),
    (Op: opEOR_Acc; Mode: amDir; Bit: 0),
    (Op: opEOR_Acc; Mode: amAbs; Bit: 0),
    (Op: opEOR_Acc; Mode: amIndX; Bit: 0),
    (Op: opEOR_Acc; Mode: amDirIdxXInd; Bit: 0),
    (Op: opEOR_Imm; Mode: amImm; Bit: 0),
    (Op: opEOR; Mode: amDirToDir; Bit: 0),
    (Op: opAND1; Mode: amAbsBit; Bit: 0),
    (Op: opLSR; Mode: amDir; Bit: 0),
    (Op: opLSR; Mode: amAbs; Bit: 0),
    (Op: opPHX; Mode: amNone; Bit: 0),
    (Op: opTCLR1; Mode: amAbs; Bit: 0),
    (Op: opPCALL; Mode: amNone; Bit: 0),
    (Op: opBVC; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 5),
    (Op: opCLR1; Mode: amDir; Bit: 2),
    (Op: opBBC; Mode: amDir; Bit: 2),
    (Op: opEOR_Acc; Mode: amDirIdxX; Bit: 0),
    (Op: opEOR_Acc; Mode: amAbsIdxX; Bit: 0),
    (Op: opEOR_Acc; Mode: amAbsIdxY; Bit: 0),
    (Op: opEOR_Acc; Mode: amDirIndIdxY; Bit: 0),
    (Op: opEOR; Mode: amDirImm; Bit: 0),
    (Op: opEOR; Mode: amIndXToIndY; Bit: 0),
    (Op: opCMPW; Mode: amDir; Bit: 0),
    (Op: opLSR; Mode: amDirIdxX; Bit: 0),
    (Op: opLSR_Acc; Mode: amNone; Bit: 0),
    (Op: opTAX; Mode: amNone; Bit: 0),
    (Op: opCPY; Mode: amAbs; Bit: 0),
    (Op: opJMP; Mode: amAbs; Bit: 0),
    (Op: opCLRC; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 6),
    (Op: opSET1; Mode: amDir; Bit: 3),
    (Op: opBBS; Mode: amDir; Bit: 3),
    (Op: opCMP_Acc; Mode: amDir; Bit: 0),
    (Op: opCMP_Acc; Mode: amAbs; Bit: 0),
    (Op: opCMP_Acc; Mode: amIndX; Bit: 0),
    (Op: opCMP_Acc; Mode: amDirIdxXInd; Bit: 0),
    (Op: opCMP_Imm; Mode: amImm; Bit: 0),
    (Op: opCMP; Mode: amDirToDir; Bit: 0),
    (Op: opNAND1; Mode: amAbsBit; Bit: 0),
    (Op: opROR; Mode: amDir; Bit: 0),
    (Op: opROR; Mode: amAbs; Bit: 0),
    (Op: opPHY; Mode: amNone; Bit: 0),
    (Op: opDBNZ; Mode: amDir; Bit: 0),
    (Op: opRTS; Mode: amNone; Bit: 0),
    (Op: opBVS; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 7),
    (Op: opCLR1; Mode: amDir; Bit: 3),
    (Op: opBBC; Mode: amDir; Bit: 3),
    (Op: opCMP_Acc; Mode: amDirIdxX; Bit: 0),
    (Op: opCMP_Acc; Mode: amAbsIdxX; Bit: 0),
    (Op: opCMP_Acc; Mode: amAbsIdxY; Bit: 0),
    (Op: opCMP_Acc; Mode: amDirIndIdxY; Bit: 0),
    (Op: opCMP; Mode: amDirImm; Bit: 0),
    (Op: opCMP; Mode: amIndXToIndY; Bit: 0),
    (Op: opADDW; Mode: amDir; Bit: 0),
    (Op: opROR; Mode: amDirIdxX; Bit: 0),
    (Op: opROR_Acc; Mode: amNone; Bit: 0),
    (Op: opTXA; Mode: amNone; Bit: 0),
    (Op: opCPY; Mode: amDir; Bit: 0),
    (Op: opRTI; Mode: amNone; Bit: 0),
    (Op: opSETC; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 8),
    (Op: opSET1; Mode: amDir; Bit: 4),
    (Op: opBBS; Mode: amDir; Bit: 4),
    (Op: opADC_Acc; Mode: amDir; Bit: 0),
    (Op: opADC_Acc; Mode: amAbs; Bit: 0),
    (Op: opADC_Acc; Mode: amIndX; Bit: 0),
    (Op: opADC_Acc; Mode: amDirIdxXInd; Bit: 0),
    (Op: opADC_Imm; Mode: amImm; Bit: 0),
    (Op: opADC; Mode: amDirToDir; Bit: 0),
    (Op: opEOR1; Mode: amAbsBit; Bit: 0),
    (Op: opDEC; Mode: amDir; Bit: 0),
    (Op: opDEC; Mode: amAbs; Bit: 0),
    (Op: opLDY_Imm; Mode: amImm; Bit: 0),
    (Op: opPLP; Mode: amNone; Bit: 0),
    (Op: opMOV_Imm; Mode: amDirImm; Bit: 0),
    (Op: opBCC; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 9),
    (Op: opCLR1; Mode: amDir; Bit: 4),
    (Op: opBBC; Mode: amDir; Bit: 4),
    (Op: opADC_Acc; Mode: amDirIdxX; Bit: 0),
    (Op: opADC_Acc; Mode: amAbsIdxX; Bit: 0),
    (Op: opADC_Acc; Mode: amAbsIdxY; Bit: 0),
    (Op: opADC_Acc; Mode: amDirIndIdxY; Bit: 0),
    (Op: opADC; Mode: amDirImm; Bit: 0),
    (Op: opADC; Mode: amIndXToIndY; Bit: 0),
    (Op: opSUBW; Mode: amDir; Bit: 0),
    (Op: opDEC; Mode: amDirIdxX; Bit: 0),
    (Op: opDEC_Acc; Mode: amNone; Bit: 0),
    (Op: opTSX; Mode: amNone; Bit: 0),
    (Op: opDIV; Mode: amNone; Bit: 0),
    (Op: opXCN; Mode: amNone; Bit: 0),
    (Op: opEI; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 10),
    (Op: opSET1; Mode: amDir; Bit: 5),
    (Op: opBBS; Mode: amDir; Bit: 5),
    (Op: opSBC_Acc; Mode: amDir; Bit: 0),
    (Op: opSBC_Acc; Mode: amAbs; Bit: 0),
    (Op: opSBC_Acc; Mode: amIndX; Bit: 0),
    (Op: opSBC_Acc; Mode: amDirIdxXInd; Bit: 0),
    (Op: opSBC_Imm; Mode: amImm; Bit: 0),
    (Op: opSBC; Mode: amDirToDir; Bit: 0),
    (Op: opLDC; Mode: amAbsBit; Bit: 0),
    (Op: opINC; Mode: amDir; Bit: 0),
    (Op: opINC; Mode: amAbs; Bit: 0),
    (Op: opCPY_Imm; Mode: amImm; Bit: 0),
    (Op: opPLA; Mode: amNone; Bit: 0),
    (Op: opSTA_AutoIncX; Mode: amIndX; Bit: 0),
    (Op: opBCS; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 11),
    (Op: opCLR1; Mode: amDir; Bit: 5),
    (Op: opBBC; Mode: amDir; Bit: 5),
    (Op: opSBC_Acc; Mode: amDirIdxX; Bit: 0),
    (Op: opSBC_Acc; Mode: amAbsIdxX; Bit: 0),
    (Op: opSBC_Acc; Mode: amAbsIdxY; Bit: 0),
    (Op: opSBC_Acc; Mode: amDirIndIdxY; Bit: 0),
    (Op: opSBC; Mode: amDirImm; Bit: 0),
    (Op: opSBC; Mode: amIndXToIndY; Bit: 0),
    (Op: opLDW; Mode: amDir; Bit: 0),
    (Op: opINC; Mode: amDirIdxX; Bit: 0),
    (Op: opINC_Acc; Mode: amNone; Bit: 0),
    (Op: opTXS; Mode: amNone; Bit: 0),
    (Op: opDAS; Mode: amNone; Bit: 0),
    (Op: opLDA_AutoIncX; Mode: amIndX; Bit: 0),
    (Op: opDI; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 12),
    (Op: opSET1; Mode: amDir; Bit: 6),
    (Op: opBBS; Mode: amDir; Bit: 6),
    (Op: opSTA; Mode: amDir; Bit: 0),
    (Op: opSTA; Mode: amAbs; Bit: 0),
    (Op: opSTA; Mode: amIndX; Bit: 0),
    (Op: opSTA; Mode: amDirIdxXInd; Bit: 0),
    (Op: opCPX_Imm; Mode: amImm; Bit: 0),
    (Op: opSTX; Mode: amAbs; Bit: 0),
    (Op: opSTC; Mode: amAbsBit; Bit: 0),
    (Op: opSTY; Mode: amDir; Bit: 0),
    (Op: opSTY; Mode: amAbs; Bit: 0),
    (Op: opLDX_Imm; Mode: amImm; Bit: 0),
    (Op: opPLX; Mode: amNone; Bit: 0),
    (Op: opMUL; Mode: amNone; Bit: 0),
    (Op: opBNE; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 13),
    (Op: opCLR1; Mode: amDir; Bit: 6),
    (Op: opBBC; Mode: amDir; Bit: 6),
    (Op: opSTA; Mode: amDirIdxX; Bit: 0),
    (Op: opSTA; Mode: amAbsIdxX; Bit: 0),
    (Op: opSTA; Mode: amAbsIdxY; Bit: 0),
    (Op: opSTA; Mode: amDirIndIdxY; Bit: 0),
    (Op: opSTX; Mode: amDir; Bit: 0),
    (Op: opSTX; Mode: amDirIdxY; Bit: 0),
    (Op: opSTW; Mode: amDir; Bit: 0),
    (Op: opSTY; Mode: amDirIdxX; Bit: 0),
    (Op: opDEY; Mode: amNone; Bit: 0),
    (Op: opTYA; Mode: amNone; Bit: 0),
    (Op: opCBNE; Mode: amDirIdxX; Bit: 0),
    (Op: opDAA; Mode: amNone; Bit: 0),
    (Op: opCLRV; Mode: amNone; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 14),
    (Op: opSET1; Mode: amDir; Bit: 7),
    (Op: opBBS; Mode: amDir; Bit: 7),
    (Op: opLDA; Mode: amDir; Bit: 0),
    (Op: opLDA; Mode: amAbs; Bit: 0),
    (Op: opLDA; Mode: amIndX; Bit: 0),
    (Op: opLDA; Mode: amDirIdxXInd; Bit: 0),
    (Op: opLDA_Imm; Mode: amImm; Bit: 0),
    (Op: opLDX; Mode: amAbs; Bit: 0),
    (Op: opNOT1; Mode: amAbsBit; Bit: 0),
    (Op: opLDY; Mode: amDir; Bit: 0),
    (Op: opLDY; Mode: amAbs; Bit: 0),
    (Op: opNOTC; Mode: amNone; Bit: 0),
    (Op: opPLY; Mode: amNone; Bit: 0),
    (Op: opSTOP; Mode: amNone; Bit: 0),
    (Op: opBEQ; Mode: amRel; Bit: 0),
    (Op: opTCALL; Mode: amNone; Bit: 15),
    (Op: opCLR1; Mode: amDir; Bit: 7),
    (Op: opBBC; Mode: amDir; Bit: 7),
    (Op: opLDA; Mode: amDirIdxX; Bit: 0),
    (Op: opLDA; Mode: amAbsIdxX; Bit: 0),
    (Op: opLDA; Mode: amAbsIdxY; Bit: 0),
    (Op: opLDA; Mode: amDirIndIdxY; Bit: 0),
    (Op: opLDX; Mode: amDir; Bit: 0),
    (Op: opLDX; Mode: amDirIdxY; Bit: 0),
    (Op: opMOV; Mode: amDirToDir; Bit: 0),
    (Op: opLDY; Mode: amDirIdxX; Bit: 0),
    (Op: opINY; Mode: amNone; Bit: 0),
    (Op: opTAY; Mode: amNone; Bit: 0),
    (Op: opDBNZ_Y; Mode: amNone; Bit: 0),
    (Op: opSTOP; Mode: amNone; Bit: 0)
  );

const
  Gaussian: array[0..511] of SmallInt = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5,
    6, 6, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10,
    11, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 15, 16, 16, 17, 17,
    18, 19, 19, 20, 20, 21, 21, 22, 23, 23, 24, 24, 25, 26, 27, 27,
    28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 36, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
    58, 59, 60, 61, 62, 64, 65, 66, 67, 69, 70, 71, 73, 74, 76, 77,
    78, 80, 81, 83, 84, 86, 87, 89, 90, 92, 94, 95, 97, 99, 100, 102,
    104, 106, 107, 109, 111, 113, 115, 117, 118, 120, 122, 124, 126, 128, 130, 132,
    134, 137, 139, 141, 143, 145, 147, 150, 152, 154, 156, 159, 161, 163, 166, 168,
    171, 173, 175, 178, 180, 183, 186, 188, 191, 193, 196, 199, 201, 204, 207, 210,
    212, 215, 218, 221, 224, 227, 230, 233, 236, 239, 242, 245, 248, 251, 254, 257,
    260, 263, 267, 270, 273, 276, 280, 283, 286, 290, 293, 297, 300, 304, 307, 311,
    314, 318, 321, 325, 328, 332, 336, 339, 343, 347, 351, 354, 358, 362, 366, 370,
    374, 378, 381, 385, 389, 393, 397, 401, 405, 410, 414, 418, 422, 426, 430, 434,
    439, 443, 447, 451, 456, 460, 464, 469, 473, 477, 482, 486, 491, 495, 499, 504,
    508, 513, 517, 522, 527, 531, 536, 540, 545, 550, 554, 559, 563, 568, 573, 577,
    582, 587, 592, 596, 601, 606, 611, 615, 620, 625, 630, 635, 640, 644, 649, 654,
    659, 664, 669, 674, 678, 683, 688, 693, 698, 703, 708, 713, 718, 723, 728, 732,
    737, 742, 747, 752, 757, 762, 767, 772, 777, 782, 787, 792, 797, 802, 806, 811,
    816, 821, 826, 831, 836, 841, 846, 851, 855, 860, 865, 870, 875, 880, 884, 889,
    894, 899, 904, 908, 913, 918, 923, 927, 932, 937, 941, 946, 951, 955, 960, 965,
    969, 974, 978, 983, 988, 992, 997, 1001, 1005, 1010, 1014, 1019, 1023, 1027, 1032, 1036,
    1040, 1045, 1049, 1053, 1057, 1061, 1066, 1070, 1074, 1078, 1082, 1086, 1090, 1094, 1098, 1102,
    1106, 1109, 1113, 1117, 1121, 1125, 1128, 1132, 1136, 1139, 1143, 1146, 1150, 1153, 1157, 1160,
    1164, 1167, 1170, 1174, 1177, 1180, 1183, 1186, 1190, 1193, 1196, 1199, 1202, 1205, 1207, 1210,
    1213, 1216, 1219, 1221, 1224, 1227, 1229, 1232, 1234, 1237, 1239, 1241, 1244, 1246, 1248, 1251,
    1253, 1255, 1257, 1259, 1261, 1263, 1265, 1267, 1269, 1270, 1272, 1274, 1275, 1277, 1279, 1280,
    1282, 1283, 1284, 1286, 1287, 1288, 1290, 1291, 1292, 1293, 1294, 1295, 1296, 1297, 1297, 1298,
    1299, 1300, 1300, 1301, 1302, 1302, 1303, 1303, 1303, 1304, 1304, 1304, 1304, 1304, 1305, 1305);

function SAR(V, Bits: Integer): Integer;
begin
  if V >= 0 then
    Result := V shr Bits
  else
    Result := not ((not V) shr Bits);
end;

constructor TSnesSPC.Create;
begin
  inherited Create;
  SetLength(FSamples, 4096);
  Reset;
end;

procedure TSnesSPC.Reset;
begin
  State := Default(TSpcState);
  State.PC := $FFC0;
  State.SP := $EF;
  State.P := Z;
  State.Control := $80;
  State.DSP[$6C] := $E0;
  State.Noise := $4000;
  State.DSPPipeline.EveryOtherSample := True;
  for var J := 0 to 7 do
  begin
    State.Voices[J].BRROffset := 1;
    State.Voices[J].Release := True;
  end;
  FSampleFrames := 0;
end;

procedure TSnesSPC.BeginFrame;
begin
  FSampleFrames := 0;
end;

function TSnesSPC.Read(Address: Word): Byte;
begin
  if (Address >= $FFC0) and ((State.Control and $80) <> 0) then
    Exit(IPL[Address - $FFC0]);

  case Address of
    $F0, $F1, $FA..$FC:
      Result := 0;
    $F2:
      Result := State.DSPAddress;
    $F3:
      Result := State.DSP[State.DSPAddress and $7F];
    $F4..$F7:
      Result := State.PortsIn[Address - $F4];
    $F8, $F9:
      Result := State.RAMRegisters[Address - $F8];
    $FD..$FF:
      begin
        Result := State.TimerOutput[Address - $FD] and 15;
        State.TimerOutput[Address - $FD] := 0;
      end;
  else
    Result := State.RAM[Address];
  end;
end;

procedure TSnesSPC.Write(Address: Word; V: Byte);
begin
  State.RAM[Address] := V;
  case Address of
    $F1:
      begin
        for var T := 0 to 2 do
          if ((State.Control and (1 shl T)) = 0) and ((V and (1 shl T)) <> 0) then
          begin
            State.TimerStage[T] := 0;
            State.TimerOutput[T] := 0;
          end;
        if (V and $10) <> 0 then
        begin
          State.PortsIn[0] := 0;
          State.PortsIn[1] := 0;
        end;
        if (V and $20) <> 0 then
        begin
          State.PortsIn[2] := 0;
          State.PortsIn[3] := 0;
        end;
        State.Control := V;
      end;
    $F2:
      State.DSPAddress := V;
    $F3:
      if State.DSPAddress < $80 then
      begin
        var R := State.DSPAddress;
        if R = $7C then
          State.DSP[R] := 0
        else
          State.DSP[R] := V;
        case R and 15 of
          8:
            State.DSPPipeline.ENVX := V;
          9:
            State.DSPPipeline.OUTX := V;
          12:
            case R of
              $4C:
                State.DSPPipeline.NewKON := V;
              $7C:
                State.DSPPipeline.ENDX := 0;
            end;
        end;
      end;
    $F4..$F7:
      State.PortsOut[Address - $F4] := V;
    $F8, $F9:
      State.RAMRegisters[Address - $F8] := V;
    $FA..$FC:
      State.TimerTarget[Address - $FA] := V;
  end;
end;

function TSnesSPC.BusRead(Address: Word): Byte;
begin
  Clock(1);
  Result := Read(Address);
  if Assigned(FOnBusCycle) then
    FOnBusCycle(Address, Result, False);
end;

procedure TSnesSPC.BusWrite(Address: Word; V: Byte);
begin
  Clock(1);
  Write(Address, V);
  if Assigned(FOnBusCycle) then
    FOnBusCycle(Address, V, True);
end;

procedure TSnesSPC.Idle;
begin
  Clock(1);
  if Assigned(FOnBusCycle) then
    FOnBusCycle(-1, -1, False);
end;

function TSnesSPC.Fetch: Byte;
begin
  Result := BusRead(State.PC);
  State.PC := (Integer(State.PC) + 1) and $FFFF;
end;

function TSnesSPC.FetchWord: Word;
begin
  Result := Fetch;
  Result := Result or (Word(Fetch) shl 8);
end;

function TSnesSPC.Direct(Offset: Integer): Word;
begin
  Result := (Word(State.P and PFlag) shl 3) or (Offset and $FF);
end;

function TSnesSPC.DirectWord(Offset: Integer): Word;
begin
  Result := BusRead(Direct(Offset));
  Result := Result or (Word(BusRead(Direct(Offset + 1))) shl 8);
end;

procedure TSnesSPC.Push(V: Byte);
begin
  BusWrite($100 or State.SP, V);
  State.SP := (Integer(State.SP) - 1) and $FF;
end;

function TSnesSPC.Pop: Byte;
begin
  State.SP := (Integer(State.SP) + 1) and $FF;
  Result := BusRead($100 or State.SP);
end;

procedure TSnesSPC.Flag(Mask: Byte; Value: Boolean);
begin
  if Value then
    State.P := State.P or Mask
  else
    State.P := State.P and not Mask;
end;

procedure TSnesSPC.NZ(V: Integer; Wide: Boolean);
begin
  if Wide then
  begin
    Flag(Z, (V and $FFFF) = 0);
    Flag(N, (V and $8000) <> 0);
  end
  else
  begin
    Flag(Z, (V and $FF) = 0);
    Flag(N, (V and $80) <> 0);
  end;
end;

procedure TSnesSPC.Branch(Taken: Boolean; Offset: Integer; var Cycles: Integer);
begin
  if Taken then
  begin
    State.PC := Word(State.PC + ShortInt(Offset));
    Inc(Cycles, 2);
  end;
end;

function TSnesSPC.ALU(Op, A, B: Integer): Byte;
begin
  var R := 0;
  var Carry := State.P and C;
  case Op of
    0:
      R := A or B;
    1:
      R := A and B;
    2:
      R := A xor B;
    3:
      begin
        R := A - B;
        Flag(C, A >= B);
      end;
    4, 5:
      begin
        if Op = 5 then
          B := B xor $FF;
        R := A + B + Carry;
        Flag(C, R > $FF);
        Flag(H, (A and 15) + (B and 15) + Carry > 15);
        Flag(VFlag, ((not (A xor B)) and (A xor R) and $80) <> 0);
      end;
  end;
  NZ(R);
  Result := Byte(R);
end;

procedure TSnesSPC.Step;
var
  Addr, AddrB, Tmp: Word;
  Offset, V, R, Bit, Cycles: Integer;
  Immediate, Acc, Taken: Boolean;
  O: TSpcOp;
  Mode: TSpcMode;
begin
  if State.Halted then
  begin
    BusRead(State.PC);
    Idle;
    Exit;
  end;

  var StartCycle := State.Cycles;
  var Code := Fetch;
  O := Opcodes[Code].Op;
  Mode := Opcodes[Code].Mode;
  Bit := Opcodes[Code].Bit;
  Cycles := InstructionCycles[Code];
  Addr := 0;
  AddrB := 0;
  V := 0;
  Offset := 0;
  Immediate := False;
  case Mode of
    amDir:
      begin
        Offset := Fetch;
        Addr := Direct(Offset);
      end;
    amDirIdxX:
      begin
        Offset := Fetch;
        Idle;
        Addr := Direct(Offset + State.X);
      end;
    amDirIdxY:
      begin
        Offset := Fetch;
        Idle;
        Addr := Direct(Offset + State.Y);
      end;
    amAbs:
      Addr := FetchWord;
    amAbsIdxX:
      begin
        Addr := Word(FetchWord + State.X);
        Idle;
      end;
    amAbsIdxY:
      begin
        Addr := Word(FetchWord + State.Y);
        Idle;
      end;
    amIndX:
      begin
        BusRead(State.PC);
        Addr := Direct(State.X);
      end;
    amDirIdxXInd:
      begin
        Offset := Fetch;
        Idle;
        Addr := DirectWord(Offset + State.X);
      end;
    amDirIndIdxY:
      begin
        Offset := Fetch;
        if O <> opSTA then
          Idle;
        Addr := Word(DirectWord(Offset) + State.Y);
        if O = opSTA then
          Idle;
      end;
    amAbsIdxXInd:
      begin
        Tmp := Word(FetchWord + State.X);
        Idle;
        Addr := BusRead(Tmp);
        Addr := Addr or (Word(BusRead(Word(Tmp + 1))) shl 8);
      end;
    amImm:
      begin
        V := Fetch;
        Immediate := True;
      end;
    amRel:
      Offset := Fetch;
    amAbsBit:
      begin
        Tmp := FetchWord;
        Addr := Tmp and $1FFF;
        Bit := Tmp shr 13;
      end;
    amDirToDir:
      begin
        AddrB := Direct(Fetch);
        V := BusRead(AddrB);
        Addr := Direct(Fetch);
      end;
    amDirImm:
      begin
        V := Fetch;
        Addr := Direct(Fetch);
        Immediate := True;
      end;
    amIndXToIndY:
      begin
        BusRead(State.PC);
        Addr := Direct(State.X);
        AddrB := Direct(State.Y);
      end;
  end;
  if (Mode = amNone) and (O <> opPCALL) then
    BusRead(State.PC);
  case O of
    opOR, opAND, opEOR, opCMP, opADC, opSBC,   //
    opOR_Acc, opAND_Acc, opEOR_Acc, opCMP_Acc, //
    opADC_Acc, opSBC_Acc, opOR_Imm, opAND_Imm, //
    opEOR_Imm, opCMP_Imm, opADC_Imm, opSBC_Imm:
      begin
        Acc := O in [opOR_Acc, opAND_Acc, opEOR_Acc, opCMP_Acc, //
          opADC_Acc, opSBC_Acc, opOR_Imm, opAND_Imm, opEOR_Imm, //
          opCMP_Imm, opADC_Imm, opSBC_Imm];
        if Acc then
        begin
          if not Immediate then
            V := BusRead(Addr);
          R := State.A;
        end
        else
        begin
          if Mode = amIndXToIndY then
            V := BusRead(AddrB);
          R := BusRead(Addr);
        end;
        R := ALU(Code shr 5, R, V);
        if (Code shr 5) <> 3 then
          if Acc then
            State.A := R
          else
            BusWrite(Addr, Byte(R));
      end;
    opLDA, opLDA_Imm, opLDA_AutoIncX:
      begin
        if not Immediate then
          V := BusRead(Addr);
        State.A := V;
        NZ(V);
        if O = opLDA_AutoIncX then
          State.X := (Integer(State.X) + 1) and $FF;
      end;
    opLDX, opLDX_Imm:
      begin
        if not Immediate then
          V := BusRead(Addr);
        State.X := V;
        NZ(V);
      end;
    opLDY, opLDY_Imm:
      begin
        if not Immediate then
          V := BusRead(Addr);
        State.Y := V;
        NZ(V);
      end;
    opSTA, opSTA_AutoIncX:
      begin
        if O = opSTA_AutoIncX then
          Idle
        else
          BusRead(Addr);
        BusWrite(Addr, State.A);
        if O = opSTA_AutoIncX then
          State.X := (Integer(State.X) + 1) and $FF;
      end;
    opSTX:
      begin
        BusRead(Addr);
        BusWrite(Addr, State.X);
      end;
    opSTY:
      begin
        BusRead(Addr);
        BusWrite(Addr, State.Y);
      end;
    opMOV:
      BusWrite(Addr, Byte(V));
    opMOV_Imm:
      begin
        BusRead(Addr);
        BusWrite(Addr, Byte(V));
      end;
    opLDW:
      begin
        Tmp := BusRead(Addr);
        Idle;
        Tmp := Tmp or (Word(BusRead(Direct(Offset + 1))) shl 8);
        State.A := Byte(Tmp);
        State.Y := Tmp shr 8;
        NZ(Tmp, True);
      end;
    opSTW:
      begin
        BusRead(Addr);
        BusWrite(Addr, State.A);
        BusWrite(Direct(Offset + 1), State.Y);
      end;
    opADDW, opSUBW, opCMPW:
      begin
        V := BusRead(Addr);
        if O <> opCMPW then
          Idle;
        V := V or (Word(BusRead(Direct(Offset + 1))) shl 8);
        R := State.A or (Word(State.Y) shl 8);
        var Old := R;
        if O = opADDW then
          R := R + V
        else
          R := R - V;
        if O = opADDW then
          Flag(C, R > $FFFF)
        else
          Flag(C, R >= 0);
        if O <> opCMPW then
        begin
          if O = opADDW then
          begin
            Flag(H, (Old and $FFF) + (V and $FFF) > $FFF);
            Flag(VFlag, ((not (Old xor V)) and (Old xor R) and $8000) <> 0);
          end
          else
          begin
            Flag(H, (Old and $FFF) >= (V and $FFF));
            Flag(VFlag, ((Old xor V) and (Old xor R) and $8000) <> 0);
          end;
          State.A := Byte(R);
          State.Y := Byte(R shr 8);
        end;
        NZ(R, True);
      end;
    opCPX, opCPX_Imm, opCPY, opCPY_Imm:
      begin
        if not Immediate then
          V := BusRead(Addr);
        if O in [opCPX, opCPX_Imm] then
          R := State.X
        else
          R := State.Y;
        ALU(3, R, V);
      end;
    opASL, opROL, opLSR, opROR, opINC, opDEC, opASL_Acc, opROL_Acc, opLSR_Acc, opROR_Acc, opINC_Acc, opDEC_Acc:
      begin
        Acc := O in [opASL_Acc, opROL_Acc, opLSR_Acc, opROR_Acc, opINC_Acc, opDEC_Acc];
        if Acc then
          V := State.A
        else
          V := BusRead(Addr);
        R := V;
        var Carry := State.P and C;
        case O of
          opASL, opASL_Acc:
            begin
              Flag(C, (V and $80) <> 0);
              R := V shl 1;
            end;
          opROL, opROL_Acc:
            begin
              Flag(C, (V and $80) <> 0);
              R := (V shl 1) or Carry;
            end;
          opLSR, opLSR_Acc:
            begin
              Flag(C, (V and 1) <> 0);
              R := V shr 1;
            end;
          opROR, opROR_Acc:
            begin
              Flag(C, (V and 1) <> 0);
              R := (V shr 1) or (Carry shl 7);
            end;
          opINC, opINC_Acc:
            R := V + 1;
          opDEC, opDEC_Acc:
            R := V - 1;
        end;
        NZ(R);
        if Acc then
          State.A := Byte(R)
        else
          BusWrite(Addr, Byte(R));
      end;
    opINCW, opDECW:
      begin
        V := BusRead(Addr);
        if O = opINCW then
          Inc(V)
        else
          Dec(V);
        BusWrite(Addr, Byte(V));
        Inc(V, Integer(BusRead(Direct(Offset + 1))) shl 8);
        BusWrite(Direct(Offset + 1), Byte(V shr 8));
        NZ(V, True);
      end;
    opINX:
      begin
        State.X := (Integer(State.X) + 1) and $FF;
        NZ(State.X);
      end;
    opINY:
      begin
        State.Y := (Integer(State.Y) + 1) and $FF;
        NZ(State.Y);
      end;
    opDEX:
      begin
        State.X := (Integer(State.X) - 1) and $FF;
        NZ(State.X);
      end;
    opDEY:
      begin
        State.Y := (Integer(State.Y) - 1) and $FF;
        NZ(State.Y);
      end;
    opSET1:
      BusWrite(Addr, BusRead(Addr) or (1 shl Bit));
    opCLR1:
      BusWrite(Addr, BusRead(Addr) and not (1 shl Bit));
    opBBS, opBBC:
      begin
        Taken := (BusRead(Addr) and (1 shl Bit)) <> 0;
        Idle;
        Offset := Fetch;
        Branch(Taken = (O = opBBS), Offset, Cycles);
      end;
    opCBNE:
      begin
        V := BusRead(Addr);
        Idle;
        Offset := Fetch;
        Branch(V <> State.A, Offset, Cycles);
      end;
    opDBNZ:
      begin
        V := Byte(BusRead(Addr) - 1);
        BusWrite(Addr, Byte(V));
        Offset := Fetch;
        Branch(V <> 0, Offset, Cycles);
      end;
    opDBNZ_Y:
      begin
        Idle;
        Offset := Fetch;
        State.Y := (Integer(State.Y) - 1) and $FF;
        Branch(State.Y <> 0, Offset, Cycles);
      end;
    opBPL:
      Branch((State.P and N) = 0, Offset, Cycles);
    opBMI:
      Branch((State.P and N) <> 0, Offset, Cycles);
    opBVC:
      Branch((State.P and VFlag) = 0, Offset, Cycles);
    opBVS:
      Branch((State.P and VFlag) <> 0, Offset, Cycles);
    opBCC:
      Branch((State.P and C) = 0, Offset, Cycles);
    opBCS:
      Branch((State.P and C) <> 0, Offset, Cycles);
    opBEQ:
      Branch((State.P and Z) <> 0, Offset, Cycles);
    opBNE:
      Branch((State.P and Z) = 0, Offset, Cycles);
    opBRA:
      State.PC := Word(State.PC + ShortInt(Offset));
    opTSET1, opTCLR1:
      begin
        V := BusRead(Addr);
        NZ(State.A - V);
        BusRead(Addr);
        if O = opTSET1 then
          BusWrite(Addr, V or State.A)
        else
          BusWrite(Addr, V and not State.A);
      end;
    opOR1, opNOR1, opAND1, opNAND1, opEOR1, opLDC, opSTC, opNOT1:
      begin
        V := BusRead(Addr);
        Taken := (V and (1 shl Bit)) <> 0;
        case O of
          opOR1:
            Flag(C, ((State.P and C) <> 0) or Taken);
          opNOR1:
            Flag(C, ((State.P and C) <> 0) or not Taken);
          opAND1:
            Flag(C, ((State.P and C) <> 0) and Taken);
          opNAND1:
            Flag(C, ((State.P and C) <> 0) and not Taken);
          opEOR1:
            Flag(C, ((State.P and C) <> 0) xor Taken);
          opLDC:
            Flag(C, Taken);
          opSTC:
            begin
              Idle;
              if (State.P and C) <> 0 then
                V := V or (1 shl Bit)
              else
                V := V and not (1 shl Bit);
              BusWrite(Addr, Byte(V));
            end;
          opNOT1:
            BusWrite(Addr, V xor (1 shl Bit));
        end;
      end;
    opTAX:
      begin
        State.X := State.A;
        NZ(State.X);
      end;
    opTAY:
      begin
        State.Y := State.A;
        NZ(State.Y);
      end;
    opTXA:
      begin
        State.A := State.X;
        NZ(State.A);
      end;
    opTYA:
      begin
        State.A := State.Y;
        NZ(State.A);
      end;
    opTSX:
      begin
        State.X := State.SP;
        NZ(State.X);
      end;
    opTXS:
      State.SP := State.X;
    opPHP:
      Push(State.P);
    opPHA:
      Push(State.A);
    opPHX:
      Push(State.X);
    opPHY:
      Push(State.Y);
    opPLP:
      begin
        Idle;
        State.P := Pop;
      end;
    opPLA:
      begin
        Idle;
        State.A := Pop;
      end;
    opPLX:
      begin
        Idle;
        State.X := Pop;
      end;
    opPLY:
      begin
        Idle;
        State.Y := Pop;
      end;
    opCLRP:
      Flag(PFlag, False);
    opSETP:
      Flag(PFlag, True);
    opCLRC:
      Flag(C, False);
    opSETC:
      Flag(C, True);
    opNOTC:
      State.P := State.P xor C;
    opCLRV:
      State.P := State.P and not (VFlag or H);
    opEI:
      Flag(I, True);
    opDI:
      Flag(I, False);
    opJMP:
      State.PC := Addr;
    opJSR, opPCALL, opTCALL:
      begin
        if O = opPCALL then
          Addr := $FF00 or Fetch;
        Idle;
        Push(State.PC shr 8);
        Push(Byte(State.PC));
        if O = opTCALL then
        begin
          Idle;
          Tmp := $FFDE - Bit * 2;
          Addr := BusRead(Tmp);
          Addr := Addr or (Word(BusRead(Tmp + 1)) shl 8);
        end;
        State.PC := Addr;
      end;
    opRTS, opRTI:
      begin
        Idle;
        if O = opRTI then
          State.P := Pop;
        State.PC := Pop;
        State.PC := State.PC or (Word(Pop) shl 8);
      end;
    opBRK:
      begin
        Push(State.PC shr 8);
        Push(Byte(State.PC));
        Push(State.P);
        State.P := (State.P or BFlag) and not I;
        Idle;
        State.PC := BusRead($FFDE);
        State.PC := State.PC or (Word(BusRead($FFDF)) shl 8);
      end;
    opMUL:
      begin
        Tmp := State.A * State.Y;
        State.A := Byte(Tmp);
        State.Y := Tmp shr 8;
        NZ(State.Y);
      end;
    opDIV:
      begin
        V := State.A or (Word(State.Y) shl 8);
        Flag(H, (State.Y and 15) >= (State.X and 15));
        Flag(VFlag, State.Y >= State.X);
        if State.Y < State.X * 2 then
        begin
          R := V div State.X;
          State.Y := V mod State.X;
        end
        else
        begin
          R := 255 - (V - State.X * 512) div (256 - State.X);
          State.Y := State.X + (V - State.X * 512) mod (256 - State.X);
        end;
        State.A := Byte(R);
        NZ(State.A);
      end;
    opXCN:
      begin
        State.A := ((State.A and $F) shl 4) or (State.A shr 4);
        NZ(State.A);
      end;
    opDAA:
      begin
        V := State.A;
        if ((State.P and C) <> 0) or (V > $99) then
        begin
          Inc(V, $60);
          Flag(C, True);
        end;
        if ((State.P and H) <> 0) or ((V and 15) > 9) then
          Inc(V, 6);
        State.A := Byte(V);
        NZ(V);
      end;
    opDAS:
      begin
        V := State.A;
        if ((State.P and C) = 0) or (V > $99) then
        begin
          Dec(V, $60);
          Flag(C, False);
        end;
        if ((State.P and H) = 0) or ((V and 15) > 9) then
          Dec(V, 6);
        State.A := Byte(V);
        NZ(V);
      end;
    opSTOP:
      State.Halted := True;
    opNOP:
      ;
  end;
  // Arithmetic is instruction based; every peripheral access above has its
  // own bus clock, including reads preceding writes and internal idle clocks.
  while State.Cycles - StartCycle < Cycles do
    Idle;
end;

procedure TSnesSPC.Clock(Cycles: Integer);
begin
  Inc(State.Cycles, Cycles);
  for var T := 0 to 2 do
  begin
    var Rate := 128;
    if T = 2 then
      Rate := 16;
    Inc(State.TimerPrescale[T], Cycles);
    while State.TimerPrescale[T] >= Rate do
    begin
      Dec(State.TimerPrescale[T], Rate);
      if (State.Control and (1 shl T)) = 0 then
        Continue;

      State.TimerStage[T] := (State.TimerStage[T] + 1) and $FF;
      var Target := Integer(State.TimerTarget[T]);
      if Target = 0 then
        Target := 256;
      if State.TimerStage[T] = (Target and $FF) then
      begin
        State.TimerStage[T] := 0;
        State.TimerOutput[T] := (State.TimerOutput[T] + 1) and 15;
      end;
    end;
  end;
  for var J := 1 to Cycles do
  begin
    DSPTick;
    State.SampleClock := (State.SampleClock + 1) and 31;
  end;
end;

procedure TSnesSPC.RunUntil(Target: Int64);
begin
  while State.Cycles < Target do
    Step;
end;

procedure TSnesSPC.DecodeBRR(var Voice: TSpcVoice);
begin
  Voice.Header := State.DSPPipeline.BRRHeader;
  var Shift := Voice.Header shr 4;
  var Data := (Integer(State.DSPPipeline.BRRByte) shl 8) or
    State.RAM[Word(Voice.Address + Voice.BRROffset + 1)];
  for var J := 0 to 3 do
  begin
    var S: Integer := (Data shr (12 - J * 4)) and 15;
    if S >= 8 then
      Dec(S, 16);
    if Shift <= 12 then
      S := SAR(S shl Shift, 1)
    else if S < 0 then
      S := -2048
    else
      S := 0;
    var P1 := Integer(Voice.Block[(Voice.Position + 11) mod 12]);
    var P2 := SAR(Voice.Block[(Voice.Position + 10) mod 12], 1);
    case Voice.Header and 12 of
      4:
        Inc(S, SAR(P1, 1) + SAR(-P1, 5));
      8:
        Inc(S, P1 + SAR(-3 * P1, 6) - P2 + SAR(P2, 4));
      12:
        Inc(S, P1 + SAR(-13 * P1, 7) - P2 + SAR(3 * P2, 4));
    end;
    S := SmallInt(EnsureRange(S, -32768, 32767) * 2);
    Voice.Block[Voice.Position] := S;
    Voice.Position := (Voice.Position + 1) mod 12;
    Voice.Prev2 := Voice.Prev1;
    Voice.Prev1 := S;
  end;
end;

function TSnesSPC.CheckCounter(Rate: Integer): Boolean;
const
  Rates: array[0..31] of Integer = (
    65535, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192,
    160, 128, 96, 80, 64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4,
    3, 2, 1);
  Offsets: array[0..31] of Integer = (
    1, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0,
    1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040,
    536, 0, 1040, 0, 0);
begin
  Result := ((State.DSPCounter + Offsets[Rate]) mod Rates[Rate]) = 0;
end;

procedure TSnesSPC.ProcessEnvelope(var Voice: TSpcVoice; Base: Integer);
begin
  if Voice.Release then
  begin
    Voice.Envelope := Max(0, Voice.Envelope - 8);
    Exit;
  end;

  var Env := Voice.Envelope;
  var Rate := 31;
  var Sustain := State.DSP[Base + 6];
  var ADSR := State.DSPPipeline.ADSR;
  var Gain := State.DSP[Base + 7];
  if (ADSR and $80) <> 0 then
    case Voice.EnvelopeMode of
      0:
        begin
          Rate := (ADSR and 15) * 2 + 1;
          if Rate = 31 then
            Inc(Env, 1024)
          else
            Inc(Env, 32);
        end;
      1:
        begin
          Dec(Env, SAR(Env - 1, 8) + 1);
          Rate := ((ADSR shr 3) and 14) or 16;
        end;
    else
      Dec(Env, SAR(Env - 1, 8) + 1);
      Rate := Sustain and 31;
    end
  else
  begin
    Sustain := Gain;
    if (Gain and $80) = 0 then
      Env := Gain * 16
    else
    begin
      Rate := Gain and 31;
      case (Gain shr 5) and 3 of
        0:
          Dec(Env, 32);
        1:
          Dec(Env, SAR(Env - 1, 8) + 1);
        2:
          Inc(Env, 32);
        3:
          if Word(Voice.PreviousEnvelope) < $600 then
            Inc(Env, 32)
          else
            Inc(Env, 8);
      end;
    end;
  end;
  if (Voice.EnvelopeMode = 1) and (SAR(Env, 8) = (Sustain shr 5)) then
    Voice.EnvelopeMode := 2;
  Voice.PreviousEnvelope := Env;
  if (Env < 0) or (Env > $7FF) then
  begin
    Env := EnsureRange(Env, 0, $7FF);
    if Voice.EnvelopeMode = 0 then
      Voice.EnvelopeMode := 1;
  end;
  if CheckCounter(Rate) then
    Voice.Envelope := Env;
end;

// S-DSP phases follow the documented voice/echo schedule, also used by the
// ISC-licensed ares SFC DSP. All latches reside in serialized TSpcState.
procedure TSnesSPC.VoicePhase(Index, Phase: Integer);
begin
  var V: PSpcVoice := @State.Voices[Index];
  var D: PSpcDSPPipeline := @State.DSPPipeline;
  var Base := Index * 16;
  var Mask := 1 shl Index;
  case Phase of
    1:
      begin
        D.DirectoryAddress := Word(Integer(D.DIR) * 256 + Integer(D.SRCN) * 4);
        D.SRCN := State.DSP[Base + 4];
      end;
    2:
      begin
        var Address := D.DirectoryAddress;
        if V.KeyOnDelay = 0 then
          Address := Word(Address + 2);
        D.NextAddress := State.RAM[Address] or (Word(State.RAM[Word(Address + 1)]) shl 8);
        D.ADSR := State.DSP[Base + 5];
        D.Pitch := State.DSP[Base + 2];
      end;
    3:
      begin
        VoicePhase(Index, 10);
        VoicePhase(Index, 11);
        VoicePhase(Index, 12);
      end;
    10:
      D.Pitch := D.Pitch or ((State.DSP[Base + 3] and $3F) shl 8);
    11:
      begin
        D.BRRByte := State.RAM[Word(V.Address + V.BRROffset)];
        D.BRRHeader := State.RAM[V.Address];
      end;
    12:
      begin
        if (D.PMON and Mask) <> 0 then
          Inc(D.Pitch, SAR(SAR(D.Output, 5) * D.Pitch, 10));
        if V.KeyOnDelay > 0 then
        begin
          if V.KeyOnDelay = 5 then
          begin
            V.Address := D.NextAddress;
            V.BRROffset := 1;
            V.Position := 0;
            D.BRRHeader := 0;
          end;
          V.Envelope := 0;
          V.PreviousEnvelope := 0;
          V.Fraction := 0;
          Dec(V.KeyOnDelay);
          if (V.KeyOnDelay and 3) <> 0 then
            V.Fraction := $4000;
          D.Pitch := 0;
        end;
        var Position := (V.Position + (V.Fraction shr 12)) mod 12;
        for var J := 0 to 3 do
          V.History[J] := V.Block[(Position + J) mod 12];
        var Offset := (V.Fraction shr 4) and $FF;
        var Sample := Integer(SmallInt(
            SAR(Gaussian[255 - Offset] * V.History[0], 11) +
            SAR(Gaussian[511 - Offset] * V.History[1], 11) +
            SAR(Gaussian[256 + Offset] * V.History[2], 11)));
        Sample := EnsureRange(Sample + SAR(Gaussian[Offset] * V.History[3], 11), -32768, 32767) and not 1;
        if (D.NON and Mask) <> 0 then
          Sample := SmallInt(State.Noise shl 1);
        D.Output := SAR(Sample * V.Envelope, 11) and not 1;
        V.ENVX := V.Envelope shr 4;
        if ((State.DSP[$6C] and $80) <> 0) or ((D.BRRHeader and 3) = 1) then
        begin
          V.Envelope := 0;
          V.Release := True;
        end;
        if D.EveryOtherSample then
        begin
          if (D.KOFF and Mask) <> 0 then
            V.Release := True;
          if (D.KON and Mask) <> 0 then
          begin
            V.KeyOnDelay := 5;
            V.EnvelopeMode := 0;
            V.Release := False;
            V.Active := True;
          end;
        end;
        if V.KeyOnDelay = 0 then
          ProcessEnvelope(V^, Base);
      end;
    4:
      begin
        D.Looped := 0;
        if V.Fraction >= $4000 then
        begin
          DecodeBRR(V^);
          Inc(V.BRROffset, 2);
          if V.BRROffset >= 9 then
          begin
            V.Address := Word(V.Address + 9);
            if (D.BRRHeader and 1) <> 0 then
            begin
              V.Address := D.NextAddress;
              D.Looped := Mask;
            end;
            V.BRROffset := 1;
          end;
        end;
        V.Fraction := Min((V.Fraction and $3FFF) + D.Pitch, $7FFF);
        var Amp := SAR(D.Output * ShortInt(State.DSP[Base]), 7);
        D.MainOutput[0] := EnsureRange(D.MainOutput[0] + Amp, -32768, 32767);
        if (D.EON and Mask) <> 0 then
          D.EchoOutput[0] := EnsureRange(D.EchoOutput[0] + Amp, -32768, 32767);
      end;
    5:
      begin
        var Amp := SAR(D.Output * ShortInt(State.DSP[Base + 1]), 7);
        D.MainOutput[1] := EnsureRange(D.MainOutput[1] + Amp, -32768, 32767);
        if (D.EON and Mask) <> 0 then
          D.EchoOutput[1] := EnsureRange(D.EchoOutput[1] + Amp, -32768, 32767);
        D.ENDX := State.DSP[$7C] or D.Looped;
        if V.KeyOnDelay = 5 then
          D.ENDX := D.ENDX and not Mask;
      end;
    6:
      D.OUTX := Byte(SAR(D.Output, 8));
    7:
      begin
        State.DSP[$7C] := D.ENDX;
        D.ENVX := V.ENVX;
      end;
    8:
      State.DSP[Base + 9] := D.OUTX;
    9:
      State.DSP[Base + 8] := D.ENVX;
  end;
end;

procedure TSnesSPC.EchoPhase(Phase: Integer);

  function FIR(Tap, Channel: Integer): Integer;
  begin
    var Position := (State.EchoHistoryPosition + Tap + 1) and 7;
    Result := SAR(State.EchoHistory[Position, Channel] * ShortInt(State.DSP[$0F + Tap * 16]), 6);
  end;

  function Output(Channel: Integer): Integer;
  begin
    var D: PSpcDSPPipeline := @State.DSPPipeline;
    Result := EnsureRange(Integer(SmallInt(SAR(D.MainOutput[Channel] * ShortInt(State.DSP[$0C + Channel * 16]), 7))) +
      Integer(SmallInt(SAR(D.EchoInput[Channel] * ShortInt(State.DSP[$2C + Channel * 16]), 7))), -32768, 32767);
  end;

  procedure WriteEcho(Channel: Integer);
  begin
    var D: PSpcDSPPipeline := @State.DSPPipeline;
    if (D.EchoFlags and $20) = 0 then
    begin
      var Address := Word(D.EchoAddress + Channel * 2);
      State.RAM[Address] := Byte(D.EchoOutput[Channel]);
      State.RAM[Word(Address + 1)] := Byte(SAR(D.EchoOutput[Channel], 8));
    end;
    D.EchoOutput[Channel] := 0;
  end;

begin
  var D: PSpcDSPPipeline := @State.DSPPipeline;
  case Phase of
    22:
      begin
        State.EchoHistoryPosition := (State.EchoHistoryPosition + 1) and 7;
        D.EchoAddress := Word(Integer(D.ESA) * 256 + State.EchoPosition);
        State.EchoHistory[State.EchoHistoryPosition, 0] := SAR(SmallInt(State.RAM[D.EchoAddress] or
              (Word(State.RAM[Word(D.EchoAddress + 1)]) shl 8)), 1);
        for var Ch := 0 to 1 do
          D.EchoInput[Ch] := FIR(0, Ch);
      end;
    23:
      begin
        for var Ch := 0 to 1 do
          Inc(D.EchoInput[Ch], FIR(1, Ch) + FIR(2, Ch));
        State.EchoHistory[State.EchoHistoryPosition, 1] := SAR(SmallInt(State.RAM[Word(D.EchoAddress + 2)] or
              (Word(State.RAM[Word(D.EchoAddress + 3)]) shl 8)), 1);
      end;
    24:
      for var Ch := 0 to 1 do
        Inc(D.EchoInput[Ch], FIR(3, Ch) + FIR(4, Ch) + FIR(5, Ch));
    25:
      for var Ch := 0 to 1 do
        D.EchoInput[Ch] := EnsureRange(Integer(SmallInt(D.EchoInput[Ch] + FIR(6, Ch))) +
            Integer(SmallInt(FIR(7, Ch))), -32768, 32767) and not 1;
    26:
      begin
        D.MainOutput[0] := Output(0);
        for var Ch := 0 to 1 do
          D.EchoOutput[Ch] := EnsureRange(D.EchoOutput[Ch] +
              Integer(SmallInt(SAR(D.EchoInput[Ch] * ShortInt(State.DSP[$0D]), 7))), -32768, 32767) and not 1;
      end;
    27:
      begin
        var Left := D.MainOutput[0];
        var Right := Output(1);
        D.MainOutput[0] := 0;
        D.MainOutput[1] := 0;
        if (State.DSP[$6C] and $40) <> 0 then
        begin
          Left := 0;
          Right := 0;
        end;
        if FSampleFrames * 2 + 1 < Length(FSamples) then
        begin
          FSamples[FSampleFrames * 2] := Left;
          FSamples[FSampleFrames * 2 + 1] := Right;
          Inc(FSampleFrames);
        end;
      end;
    28:
      D.EchoFlags := State.DSP[$6C];
    29:
      begin
        D.ESA := State.DSP[$6D];
        if State.EchoPosition = 0 then
          D.EchoLength := (State.DSP[$7D] and 15) * $800;
        Inc(State.EchoPosition, 4);
        if State.EchoPosition >= D.EchoLength then
          State.EchoPosition := 0;
        WriteEcho(0);
        D.EchoFlags := State.DSP[$6C];
      end;
    30:
      WriteEcho(1);
  end;
end;

procedure TSnesSPC.DSPTick;
begin
  var Phase := State.SampleClock;
  // Three staggered voice operations run concurrently on most phases.
  if Phase in [2, 5, 8, 11, 14] then
  begin
    var V := (Phase - 2) div 3;
    VoicePhase(V, 7);
    VoicePhase(V + 3, 1);
    VoicePhase(V + 1, 4);
  end
  else if Phase in [3, 6, 9, 12, 15, 18] then
  begin
    var V := (Phase - 3) div 3;
    VoicePhase(V, 8);
    VoicePhase(V + 1, 5);
    VoicePhase(V + 2, 2);
  end
  else if Phase in [4, 7, 10, 13, 16, 19] then
  begin
    var V := (Phase - 4) div 3;
    VoicePhase(V, 9);
    VoicePhase(V + 1, 6);
    VoicePhase(V + 2, 3);
  end
  else
    case Phase of
      0:
        begin
          VoicePhase(0, 5);
          VoicePhase(1, 2);
        end;
      1:
        begin
          VoicePhase(0, 6);
          VoicePhase(1, 3);
        end;
      17:
        begin
          VoicePhase(0, 1);
          VoicePhase(5, 7);
          VoicePhase(6, 4);
        end;
      20:
        begin
          VoicePhase(1, 1);
          VoicePhase(6, 7);
          VoicePhase(7, 4);
        end;
      21:
        begin
          VoicePhase(6, 8);
          VoicePhase(7, 5);
          VoicePhase(0, 2);
        end;
      22:
        begin
          VoicePhase(0, 10);
          VoicePhase(6, 9);
          VoicePhase(7, 6);
        end;
      23:
        VoicePhase(7, 7);
      24:
        VoicePhase(7, 8);
      25:
        begin
          VoicePhase(0, 11);
          VoicePhase(7, 9);
        end;
      27:
        State.DSPPipeline.PMON := State.DSP[$2D] and $FE;
      28:
        begin
          State.DSPPipeline.NON := State.DSP[$3D];
          State.DSPPipeline.EON := State.DSP[$4D];
          State.DSPPipeline.DIR := State.DSP[$5D];
        end;
      29:
        begin
          State.DSPPipeline.EveryOtherSample := not State.DSPPipeline.EveryOtherSample;
          if State.DSPPipeline.EveryOtherSample then
            State.DSPPipeline.NewKON := State.DSPPipeline.NewKON and not State.DSPPipeline.KON;
        end;
      30:
        begin
          if State.DSPPipeline.EveryOtherSample then
          begin
            State.DSPPipeline.KON := State.DSPPipeline.NewKON;
            State.DSPPipeline.KOFF := State.DSP[$5C];
          end;
          if State.DSPCounter = 0 then
            State.DSPCounter := $77FF
          else
            Dec(State.DSPCounter);
          if CheckCounter(State.DSP[$6C] and 31) then
            State.Noise := (State.Noise shr 1) or (((State.Noise xor (State.Noise shr 1)) and 1) shl 14);
          VoicePhase(0, 12);
        end;
      31:
        begin
          VoicePhase(0, 4);
          VoicePhase(2, 1);
        end;
    end;
  if Phase in [22..30] then
    EchoPhase(Phase);
end;

procedure TSnesSPC.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  if Archive.Loading then
  begin
    if (State.SampleClock < 0) or (State.SampleClock > 31) or
      (State.EchoHistoryPosition < 0) or (State.EchoHistoryPosition > 7) or
      (State.DSPCounter < 0) or (State.DSPCounter > $77FF) then
      raise EReadError.Create('Invalid SNES DSP phase snapshot');
    for var J := 0 to 7 do
      if (State.Voices[J].Position < 0) or (State.Voices[J].Position > 11) or
        (State.Voices[J].Fraction < 0) or (State.Voices[J].Fraction > $7FFF) or
        (State.Voices[J].KeyOnDelay < 0) or (State.Voices[J].KeyOnDelay > 5) or
        (State.Voices[J].BRROffset < 0) or (State.Voices[J].BRROffset > 8) then
        raise EReadError.Create('Invalid SNES DSP voice snapshot');
    FSampleFrames := 0;
  end;
end;

end.

