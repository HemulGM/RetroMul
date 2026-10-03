unit SNES.SPC;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TSpcVoice = packed record
    Address, LoopAddress: Word;
    Block: array[0..15] of SmallInt;
    History: array[0..3] of SmallInt;
    Position, Fraction, Prev1, Prev2, Envelope, EnvelopeMode, Counter: Integer;
    PreviousEnvelope: Integer;
    Active, Release: Boolean;
    Header: Byte;
  end;

  PSpcVoice = ^TSpcVoice;

  TSpcState = packed record
    RAM: array[0..65535] of Byte;
    DSP: array[0..127] of Byte;
    PortsIn, PortsOut: array[0..3] of Byte;
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
  end;

  TSnesSPC = class
  private
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
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
    procedure DecodeBlock(var Voice: TSpcVoice);
    function CheckCounter(Rate: Integer): Boolean;
    procedure ProcessEnvelope(var Voice: TSpcVoice; Base: Integer);
    procedure Mix;
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
        if R = $4C then
          for var J := 0 to 7 do
            if (V and (1 shl J)) <> 0 then
            begin
              var Dir := (Word(State.DSP[$5D]) shl 8) + State.DSP[J * 16 + 4] * 4;
              var Voice: PSpcVoice := @State.Voices[J];
              Voice^ := Default(TSpcVoice);
              Voice.Address := State.RAM[Word(Dir)] or (Word(State.RAM[Word(Dir + 1)]) shl 8);
              Voice.LoopAddress := State.RAM[Word(Dir + 2)] or (Word(State.RAM[Word(Dir + 3)]) shl 8);
              Voice.Active := True;
              Voice.Position := 0;
              DecodeBlock(Voice^);
              State.DSP[$7C] := State.DSP[$7C] and not (1 shl J);
            end;
        if R = $5C then
          for var J := 0 to 7 do
            if (V and (1 shl J)) <> 0 then
              State.Voices[J].Release := True;
      end;
    $F4..$F7:
      State.PortsOut[Address - $F4] := V;
  end;
end;

function TSnesSPC.Fetch: Byte;
begin
  Result := Read(State.PC);
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
  Result := Read(Direct(Offset));
  Result := Result or (Word(Read(Direct(Offset + 1))) shl 8);
end;

procedure TSnesSPC.Push(V: Byte);
begin
  Write($100 or State.SP, V);
  State.SP := (Integer(State.SP) - 1) and $FF;
end;

function TSnesSPC.Pop: Byte;
begin
  State.SP := (Integer(State.SP) + 1) and $FF;
  Result := Read($100 or State.SP);
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
    Clock(2);
    Exit;
  end;
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
        Addr := Direct(Offset + State.X);
      end;
    amDirIdxY:
      begin
        Offset := Fetch;
        Addr := Direct(Offset + State.Y);
      end;
    amAbs:
      Addr := FetchWord;
    amAbsIdxX:
      Addr := Word(FetchWord + State.X);
    amAbsIdxY:
      Addr := Word(FetchWord + State.Y);
    amIndX:
      Addr := Direct(State.X);
    amDirIdxXInd:
      begin
        Offset := Fetch;
        Addr := DirectWord(Offset + State.X);
      end;
    amDirIndIdxY:
      begin
        Offset := Fetch;
        Addr := Word(DirectWord(Offset) + State.Y);
      end;
    amAbsIdxXInd:
      begin
        Tmp := Word(FetchWord + State.X);
        Addr := Read(Tmp);
        Addr := Addr or (Word(Read(Word(Tmp + 1))) shl 8);
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
        Addr := Direct(State.X);
        AddrB := Direct(State.Y);
      end;
  end;
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
            V := Read(Addr);
          R := State.A;
        end
        else
        begin
          if Mode = amIndXToIndY then
            V := Read(AddrB)
          else if not Immediate then
            V := Read(AddrB);
          R := Read(Addr);
        end;
        R := ALU(Code shr 5, R, V);
        if (Code shr 5) <> 3 then
          if Acc then
            State.A := R
          else
            Write(Addr, Byte(R));
      end;
    opLDA, opLDA_Imm, opLDA_AutoIncX:
      begin
        if not Immediate then
          V := Read(Addr);
        State.A := V;
        NZ(V);
        if O = opLDA_AutoIncX then
          State.X := (Integer(State.X) + 1) and $FF;
      end;
    opLDX, opLDX_Imm:
      begin
        if not Immediate then
          V := Read(Addr);
        State.X := V;
        NZ(V);
      end;
    opLDY, opLDY_Imm:
      begin
        if not Immediate then
          V := Read(Addr);
        State.Y := V;
        NZ(V);
      end;
    opSTA, opSTA_AutoIncX:
      begin
        Write(Addr, State.A);
        if O = opSTA_AutoIncX then
          State.X := (Integer(State.X) + 1) and $FF;
      end;
    opSTX:
      Write(Addr, State.X);
    opSTY:
      Write(Addr, State.Y);
    opMOV:
      Write(Addr, Read(AddrB));
    opMOV_Imm:
      Write(Addr, Byte(V));
    opLDW:
      begin
        Tmp := DirectWord(Offset);
        State.A := Byte(Tmp);
        State.Y := Tmp shr 8;
        NZ(Tmp, True);
      end;
    opSTW:
      begin
        Write(Addr, State.A);
        Write(Direct(Offset + 1), State.Y);
      end;
    opADDW, opSUBW, opCMPW:
      begin
        V := DirectWord(Offset);
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
          V := Read(Addr);
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
          V := Read(Addr);
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
          Write(Addr, Byte(R));
      end;
    opINCW, opDECW:
      begin
        V := DirectWord(Offset);
        if O = opINCW then
          Inc(V)
        else
          Dec(V);
        Write(Addr, Byte(V));
        Write(Direct(Offset + 1), Byte(V shr 8));
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
      Write(Addr, Read(Addr) or (1 shl Bit));
    opCLR1:
      Write(Addr, Read(Addr) and not (1 shl Bit));
    opBBS, opBBC:
      begin
        Taken := (Read(Addr) and (1 shl Bit)) <> 0;
        Offset := Fetch;
        Branch(Taken = (O = opBBS), Offset, Cycles);
      end;
    opCBNE:
      begin
        V := Read(Addr);
        Offset := Fetch;
        Branch(V <> State.A, Offset, Cycles);
      end;
    opDBNZ:
      begin
        V := Byte(Read(Addr) - 1);
        Write(Addr, Byte(V));
        Offset := Fetch;
        Branch(V <> 0, Offset, Cycles);
      end;
    opDBNZ_Y:
      begin
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
        V := Read(Addr);
        NZ(State.A - V);
        if O = opTSET1 then
          Write(Addr, V or State.A)
        else
          Write(Addr, V and not State.A);
      end;
    opOR1, opNOR1, opAND1, opNAND1, opEOR1, opLDC, opSTC, opNOT1:
      begin
        V := Read(Addr);
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
              if (State.P and C) <> 0 then
                V := V or (1 shl Bit)
              else
                V := V and not (1 shl Bit);
              Write(Addr, Byte(V));
            end;
          opNOT1:
            Write(Addr, V xor (1 shl Bit));
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
      State.P := Pop;
    opPLA:
      State.A := Pop;
    opPLX:
      State.X := Pop;
    opPLY:
      State.Y := Pop;
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
        if O = opTCALL then
        begin
          Tmp := $FFDE - Bit * 2;
          Addr := Read(Tmp);
          Addr := Addr or (Word(Read(Tmp + 1)) shl 8);
        end;
        Push(State.PC shr 8);
        Push(Byte(State.PC));
        State.PC := Addr;
      end;
    opRTS, opRTI:
      begin
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
        State.PC := Read($FFDE);
        State.PC := State.PC or (Word(Read($FFDF)) shl 8);
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
  Clock(Cycles);
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
      Inc(State.TimerStage[T]);
      var Target := Integer(State.RAM[$FA + T]);
      if Target = 0 then
        Target := 256;
      if State.TimerStage[T] >= Target then
      begin
        State.TimerStage[T] := 0;
        State.TimerOutput[T] := (State.TimerOutput[T] + 1) and 15;
      end;
    end;
  end;
  Inc(State.SampleClock, Cycles);
  while State.SampleClock >= 32 do
  begin
    Dec(State.SampleClock, 32);
    Mix;
  end;
end;

procedure TSnesSPC.RunUntil(Target: Int64);
begin
  while State.Cycles < Target do
    Step;
end;

procedure TSnesSPC.DecodeBlock(var Voice: TSpcVoice);
begin
  Voice.Header := State.RAM[Voice.Address];
  var Shift := Voice.Header shr 4;
  for var J := 0 to 15 do
  begin
    var Data := State.RAM[Word(Voice.Address + 1 + J div 2)];
    var S: Integer := Data and 15;
    if (J and 1) = 0 then
      S := Data shr 4;
    if S >= 8 then
      Dec(S, 16);
    if Shift <= 12 then
      S := SAR(S shl Shift, 1)
    else if S < 0 then
      S := -2048
    else
      S := 0;
    var P1 := SAR(Voice.Prev1, 1);
    var P2 := SAR(Voice.Prev2, 1);
    case Voice.Header and 12 of
      4:
        Inc(S, P1 + SAR(-P1, 4));
      8:
        Inc(S, 2 * P1 + SAR(-3 * P1, 5) - P2 + SAR(P2, 4));
      12:
        Inc(S, 2 * P1 + SAR(-13 * P1, 6) - P2 + SAR(3 * P2, 4));
    end;
    S := SmallInt(EnsureRange(S, -32768, 32767) * 2);
    Voice.Block[J] := S;
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
  var ADSR := State.DSP[Base + 5];
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

procedure TSnesSPC.Mix;
begin
  if State.DSPCounter = 0 then
    State.DSPCounter := $77FF
  else
    Dec(State.DSPCounter);
  var Left := 0;
  var Right := 0;
  var EchoLeft := 0;
  var EchoRight := 0;
  var PreviousOutput := 0;
  for var J := 0 to 7 do
  begin
    var Voice: PSpcVoice := @State.Voices[J];
    var Base := J * 16;
    if not Voice.Active then
    begin
      State.DSP[Base + 8] := 0;
      State.DSP[Base + 9] := 0;
      PreviousOutput := 0;
      Continue;
    end;
    var Offset := (Voice.Fraction shr 4) and $FF;
    var Sample := Integer(SmallInt(
        SAR(Gaussian[255 - Offset] * Voice.History[0], 11) +
        SAR(Gaussian[511 - Offset] * Voice.History[1], 11) +
        SAR(Gaussian[256 + Offset] * Voice.History[2], 11)));
    Sample := EnsureRange(Sample + SAR(Gaussian[Offset] * Voice.History[3], 11), -32768, 32767) and not 1;
    if (State.DSP[$3D] and (1 shl J)) <> 0 then
      Sample := SmallInt(State.Noise shl 1);
    Sample := SAR(Sample * Voice.Envelope, 11) and not 1;
    State.DSP[Base + 8] := Voice.Envelope shr 4;
    State.DSP[Base + 9] := Byte(SAR(Sample, 8));
    if (State.DSP[$6C] and $80) <> 0 then
    begin
      Voice.Envelope := 0;
      Voice.Release := True;
    end;
    ProcessEnvelope(Voice^, Base);
    var VoiceLeft := SAR(Sample * ShortInt(State.DSP[Base]), 7);
    var VoiceRight := SAR(Sample * ShortInt(State.DSP[Base + 1]), 7);
    Left := EnsureRange(Left + VoiceLeft, -32768, 32767);
    Right := EnsureRange(Right + VoiceRight, -32768, 32767);
    if (State.DSP[$4D] and (1 shl J)) <> 0 then
    begin
      EchoLeft := EnsureRange(EchoLeft + VoiceLeft, -32768, 32767);
      EchoRight := EnsureRange(EchoRight + VoiceRight, -32768, 32767);
    end;
    var Pitch := State.DSP[Base + 2] or ((State.DSP[Base + 3] and $3F) shl 8);
    if (J > 0) and ((State.DSP[$2D] and (1 shl J)) <> 0) then
      Pitch := EnsureRange(Pitch + SAR(SAR(PreviousOutput, 5) * Pitch, 10), 0, $7FFF);
    PreviousOutput := Sample;
    Inc(Voice.Fraction, Pitch);
    while Voice.Fraction >= 4096 do
    begin
      Dec(Voice.Fraction, 4096);
      Voice.History[0] := Voice.History[1];
      Voice.History[1] := Voice.History[2];
      Voice.History[2] := Voice.History[3];
      Voice.History[3] := Voice.Block[Voice.Position];
      Inc(Voice.Position);
      if Voice.Position >= 16 then
      begin
        Voice.Position := 0;
        if (Voice.Header and 1) <> 0 then
        begin
          State.DSP[$7C] := State.DSP[$7C] or (1 shl J);
          if (Voice.Header and 2) <> 0 then
            Voice.Address := Voice.LoopAddress
          else
          begin
            Voice.Active := False;
            Break;
          end;
        end
        else
          Voice.Address := (Integer(Voice.Address) + 9) and $FFFF;
        DecodeBlock(Voice^);
      end;
    end;
  end;
  var NoiseRate := State.DSP[$6C] and 31;
  if CheckCounter(NoiseRate) then
  begin
    State.Noise := (State.Noise shr 1) or (((State.Noise xor (State.Noise shr 1)) and 1) shl 14);
  end;
  var EchoAddress := Word((Word(State.DSP[$6D]) shl 8) + State.EchoPosition);
  State.EchoHistoryPosition := (State.EchoHistoryPosition + 1) and 7;
  State.EchoHistory[State.EchoHistoryPosition, 0] := SAR(SmallInt(State.RAM[EchoAddress] or (Word(State.RAM[Word(EchoAddress + 1)]) shl 8)), 1);
  State.EchoHistory[State.EchoHistoryPosition, 1] := SAR(SmallInt(State.RAM[Word(EchoAddress + 2)] or (Word(State.RAM[Word(EchoAddress + 3)]) shl 8)), 1);
  var FilteredLeft := 0;
  var FilteredRight := 0;
  for var Tap := 0 to 7 do
  begin
    var History := (State.EchoHistoryPosition + Tap + 1) and 7;
    var Coefficient := ShortInt(State.DSP[$0F + Tap * 16]);
    var TapLeft := SAR(State.EchoHistory[History, 0] * Coefficient, 6);
    var TapRight := SAR(State.EchoHistory[History, 1] * Coefficient, 6);
    if Tap = 7 then
    begin
      FilteredLeft := SmallInt(FilteredLeft) + SmallInt(TapLeft);
      FilteredRight := SmallInt(FilteredRight) + SmallInt(TapRight);
    end
    else
    begin
      Inc(FilteredLeft, TapLeft);
      Inc(FilteredRight, TapRight);
    end;
  end;
  FilteredLeft := EnsureRange(FilteredLeft, -32768, 32767) and not 1;
  FilteredRight := EnsureRange(FilteredRight, -32768, 32767) and not 1;
  if (State.DSP[$6C] and $20) = 0 then
  begin
    var Feedback := ShortInt(State.DSP[$0D]);
    var OutLeft := EnsureRange(EchoLeft + SAR(FilteredLeft * Feedback, 7), -32768, 32767) and not 1;
    var OutRight := EnsureRange(EchoRight + SAR(FilteredRight * Feedback, 7), -32768, 32767) and not 1;
    State.RAM[EchoAddress] := Byte(OutLeft);
    State.RAM[Word(EchoAddress + 1)] := Byte(OutLeft shr 8);
    State.RAM[Word(EchoAddress + 2)] := Byte(OutRight);
    State.RAM[Word(EchoAddress + 3)] := Byte(OutRight shr 8);
  end;
  Inc(State.EchoPosition, 4);
  var EchoLength := (State.DSP[$7D] and 15) * $800;
  if EchoLength = 0 then
    EchoLength := 4;
  if State.EchoPosition >= EchoLength then
    State.EchoPosition := 0;
  Left := SAR(EnsureRange(Left, -32768, 32767) * ShortInt(State.DSP[$0C]), 7);
  Right := SAR(EnsureRange(Right, -32768, 32767) * ShortInt(State.DSP[$1C]), 7);
  Inc(Left, SAR(FilteredLeft * ShortInt(State.DSP[$2C]), 7));
  Inc(Right, SAR(FilteredRight * ShortInt(State.DSP[$3C]), 7));
  if (State.DSP[$6C] and $40) <> 0 then
  begin
    Left := 0;
    Right := 0;
  end;
  if FSampleFrames * 2 + 1 < Length(FSamples) then
  begin
    FSamples[FSampleFrames * 2] := EnsureRange(Left, -32768, 32767);
    FSamples[FSampleFrames * 2 + 1] := EnsureRange(Right, -32768, 32767);
    Inc(FSampleFrames);
  end;
end;

procedure TSnesSPC.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  if Archive.Loading then
    FSampleFrames := 0;
end;

end.

