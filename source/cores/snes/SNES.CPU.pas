unit SNES.CPU;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TSnesRead = function(Address: Cardinal): Byte of object;

  TSnesWrite = procedure(Address: Cardinal; Value: Byte) of object;

  TSnesClock = procedure(Clocks: Integer) of object;

  TSnesVector = function(Vector: Word): Word of object;

  TSnesControlIdle = procedure(PC: Word; Jump: Boolean) of object;

  TSnesCPUState = packed record
    A, X, Y, SP, D, PC: Word;
    P, K, DB: Byte;
    E, Waiting, Stopped, NMI, IRQ: Boolean;
    Cycles: UInt64;
  end;

  TSnesCPU = class
  private
    FRead: TSnesRead;
    FWrite: TSnesWrite;
    FClock: TSnesClock;
    FVector: TSnesVector;
    FControlIdle: TSnesControlIdle;
    Operand, AddressMask: Cardinal;
    Immediate: Boolean;
    function ReadBus(Address: Cardinal): Byte;
    procedure WriteBus(Address: Cardinal; Value: Byte);
    function Fetch: Byte;
    function FetchWord: Word;
    function FetchLong: Cardinal;
    function ReadWord(Address: Cardinal; Mask: Cardinal = $FFFFFF): Word;
    function Direct(Offset: Integer; Wrap: Boolean = True): Word;
    function DirectWord(Offset: Integer; BugWrap: Boolean = False): Word;
    function DirectLong(Offset: Integer): Cardinal;
    procedure Idle;
    procedure SetP(Value: Byte);
    procedure SetSP(Value: Word; Wrap: Boolean = True);
    procedure Push(Value: Byte; Wrap: Boolean = True);
    procedure PushWord(Value: Word; Wrap: Boolean = True);
    function Pop(Wrap: Boolean = True): Byte;
    function PopWord(Wrap: Boolean = True): Word;
    procedure NZ(Value: Integer; Eight: Boolean);
    procedure LoadReg(var Reg: Word; Value: Integer; Eight: Boolean);
    function Value(Eight: Boolean): Integer;
    procedure Store(V: Integer; Eight: Boolean; RMW: Boolean = False);
    procedure Flag(Mask: Byte; Enabled: Boolean);
    procedure Branch(Taken: Boolean);
    procedure Add(V: Integer; Eight, Subtract: Boolean);
    procedure Interrupt(Vector: Word; Hardware: Boolean);
  public
    State: TSnesCPUState;
    constructor Create(Read: TSnesRead; Write: TSnesWrite; Clock: TSnesClock; Vector: TSnesVector = nil; ControlIdle: TSnesControlIdle = nil);
    procedure Reset;
    procedure Step;
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  C = $01;
  Z = $02;
  I = $04;
  DFlag = $08;
  XFlag = $10;
  M = $20;
  VFlag = $40;
  N = $80;

type
  TSnesOp = (opADC, opAND, opASL, opASL_Acc, opBCC, opBCS, opBEQ, opBIT, opBMI, opBNE, opBPL, opBRA, opBRK, opBRL, opBVC, opBVS, opCLC, opCLD, opCLI, opCLV, opCMP, opCOP, opCPX, opCPY, opDEC, opDEC_Acc, opDEX, opDEY, opEOR, opINC, opINC_Acc, opINX, opINY, opJML, opJMP, opJMP_AbsIdxXInd, opJSL, opJSR, opJSR_AbsIdxXInd, opLDA, opLDX, opLDY, opLSR, opLSR_Acc, opMVN, opMVP, opNOP, opORA, opPEA, opPEI, opPER, opPHA, opPHB, opPHD, opPHK, opPHP, opPHX, opPHY, opPLA, opPLB, opPLD, opPLP, opPLX, opPLY, opREP, opROL, opROL_Acc, opROR, opROR_Acc, opRTI, opRTL, opRTS, opSBC, opSEC, opSED, opSEI, opSEP, opSTA, opSTP, opSTX, opSTY, opSTZ, opTAX, opTAY, opTCD, opTCS, opTDC, opTRB, opTSB, opTSC, opTSX, opTXA, opTXS, opTXY, opTYA, opTYX, opWAI, opWDM, opXBA, opXCE);

  TSnesMode = (amAbs, amAbsIdxX, amAbsIdxY, amAbsInd, amAbsIndLng, amAbsJmp, amAbsLng, amAbsLngIdxX, amAbsLngJmp, amAcc, amBlkMov, amDir, amDirIdxIndX, amDirIdxX, amDirIdxY, amDirInd, amDirIndIdxY, amDirIndLng, amDirIndLngIdxY, amImm16, amImm8, amImmM, amImmX, amImp, amNone, amRel, amRelLng, amStkRel, amStkRelIndIdxY);

  TSnesInstruction = record
    Op: TSnesOp;
    Mode: TSnesMode;
    Bit: Integer;
  end;

const
  Opcodes: array[0..255] of TSnesInstruction = (
    (Op: opBRK; Mode: amImm8; Bit: 0),
    (Op: opORA; Mode: amDirIdxIndX; Bit: 0),
    (Op: opCOP; Mode: amImm8; Bit: 0),
    (Op: opORA; Mode: amStkRel; Bit: 0),
    (Op: opTSB; Mode: amDir; Bit: 0),
    (Op: opORA; Mode: amDir; Bit: 0),
    (Op: opASL; Mode: amDir; Bit: 0),
    (Op: opORA; Mode: amDirIndLng; Bit: 0),
    (Op: opPHP; Mode: amNone; Bit: 0),
    (Op: opORA; Mode: amImmM; Bit: 0),
    (Op: opASL_Acc; Mode: amAcc; Bit: 0),
    (Op: opPHD; Mode: amNone; Bit: 0),
    (Op: opTSB; Mode: amAbs; Bit: 0),
    (Op: opORA; Mode: amAbs; Bit: 0),
    (Op: opASL; Mode: amAbs; Bit: 0),
    (Op: opORA; Mode: amAbsLng; Bit: 0),
    (Op: opBPL; Mode: amRel; Bit: 0),
    (Op: opORA; Mode: amDirIndIdxY; Bit: 0),
    (Op: opORA; Mode: amDirInd; Bit: 0),
    (Op: opORA; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opTRB; Mode: amDir; Bit: 0),
    (Op: opORA; Mode: amDirIdxX; Bit: 0),
    (Op: opASL; Mode: amDirIdxX; Bit: 0),
    (Op: opORA; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opCLC; Mode: amImp; Bit: 0),
    (Op: opORA; Mode: amAbsIdxY; Bit: 0),
    (Op: opINC_Acc; Mode: amAcc; Bit: 0),
    (Op: opTCS; Mode: amImp; Bit: 0),
    (Op: opTRB; Mode: amAbs; Bit: 0),
    (Op: opORA; Mode: amAbsIdxX; Bit: 0),
    (Op: opASL; Mode: amAbsIdxX; Bit: 0),
    (Op: opORA; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opJSR; Mode: amAbsJmp; Bit: 0),
    (Op: opAND; Mode: amDirIdxIndX; Bit: 0),
    (Op: opJSL; Mode: amNone; Bit: 0),
    (Op: opAND; Mode: amStkRel; Bit: 0),
    (Op: opBIT; Mode: amDir; Bit: 0),
    (Op: opAND; Mode: amDir; Bit: 0),
    (Op: opROL; Mode: amDir; Bit: 0),
    (Op: opAND; Mode: amDirIndLng; Bit: 0),
    (Op: opPLP; Mode: amNone; Bit: 0),
    (Op: opAND; Mode: amImmM; Bit: 0),
    (Op: opROL_Acc; Mode: amAcc; Bit: 0),
    (Op: opPLD; Mode: amNone; Bit: 0),
    (Op: opBIT; Mode: amAbs; Bit: 0),
    (Op: opAND; Mode: amAbs; Bit: 0),
    (Op: opROL; Mode: amAbs; Bit: 0),
    (Op: opAND; Mode: amAbsLng; Bit: 0),
    (Op: opBMI; Mode: amRel; Bit: 0),
    (Op: opAND; Mode: amDirIndIdxY; Bit: 0),
    (Op: opAND; Mode: amDirInd; Bit: 0),
    (Op: opAND; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opBIT; Mode: amDirIdxX; Bit: 0),
    (Op: opAND; Mode: amDirIdxX; Bit: 0),
    (Op: opROL; Mode: amDirIdxX; Bit: 0),
    (Op: opAND; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opSEC; Mode: amImp; Bit: 0),
    (Op: opAND; Mode: amAbsIdxY; Bit: 0),
    (Op: opDEC_Acc; Mode: amAcc; Bit: 0),
    (Op: opTSC; Mode: amImp; Bit: 0),
    (Op: opBIT; Mode: amAbsIdxX; Bit: 0),
    (Op: opAND; Mode: amAbsIdxX; Bit: 0),
    (Op: opROL; Mode: amAbsIdxX; Bit: 0),
    (Op: opAND; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opRTI; Mode: amNone; Bit: 0),
    (Op: opEOR; Mode: amDirIdxIndX; Bit: 0),
    (Op: opWDM; Mode: amImm8; Bit: 0),
    (Op: opEOR; Mode: amStkRel; Bit: 0),
    (Op: opMVP; Mode: amBlkMov; Bit: 0),
    (Op: opEOR; Mode: amDir; Bit: 0),
    (Op: opLSR; Mode: amDir; Bit: 0),
    (Op: opEOR; Mode: amDirIndLng; Bit: 0),
    (Op: opPHA; Mode: amNone; Bit: 0),
    (Op: opEOR; Mode: amImmM; Bit: 0),
    (Op: opLSR_Acc; Mode: amAcc; Bit: 0),
    (Op: opPHK; Mode: amNone; Bit: 0),
    (Op: opJMP; Mode: amAbsJmp; Bit: 0),
    (Op: opEOR; Mode: amAbs; Bit: 0),
    (Op: opLSR; Mode: amAbs; Bit: 0),
    (Op: opEOR; Mode: amAbsLng; Bit: 0),
    (Op: opBVC; Mode: amRel; Bit: 0),
    (Op: opEOR; Mode: amDirIndIdxY; Bit: 0),
    (Op: opEOR; Mode: amDirInd; Bit: 0),
    (Op: opEOR; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opMVN; Mode: amBlkMov; Bit: 0),
    (Op: opEOR; Mode: amDirIdxX; Bit: 0),
    (Op: opLSR; Mode: amDirIdxX; Bit: 0),
    (Op: opEOR; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opCLI; Mode: amImp; Bit: 0),
    (Op: opEOR; Mode: amAbsIdxY; Bit: 0),
    (Op: opPHY; Mode: amNone; Bit: 0),
    (Op: opTCD; Mode: amImp; Bit: 0),
    (Op: opJML; Mode: amAbsLngJmp; Bit: 0),
    (Op: opEOR; Mode: amAbsIdxX; Bit: 0),
    (Op: opLSR; Mode: amAbsIdxX; Bit: 0),
    (Op: opEOR; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opRTS; Mode: amNone; Bit: 0),
    (Op: opADC; Mode: amDirIdxIndX; Bit: 0),
    (Op: opPER; Mode: amRelLng; Bit: 0),
    (Op: opADC; Mode: amStkRel; Bit: 0),
    (Op: opSTZ; Mode: amDir; Bit: 0),
    (Op: opADC; Mode: amDir; Bit: 0),
    (Op: opROR; Mode: amDir; Bit: 0),
    (Op: opADC; Mode: amDirIndLng; Bit: 0),
    (Op: opPLA; Mode: amNone; Bit: 0),
    (Op: opADC; Mode: amImmM; Bit: 0),
    (Op: opROR_Acc; Mode: amAcc; Bit: 0),
    (Op: opRTL; Mode: amNone; Bit: 0),
    (Op: opJMP; Mode: amAbsInd; Bit: 0),
    (Op: opADC; Mode: amAbs; Bit: 0),
    (Op: opROR; Mode: amAbs; Bit: 0),
    (Op: opADC; Mode: amAbsLng; Bit: 0),
    (Op: opBVS; Mode: amRel; Bit: 0),
    (Op: opADC; Mode: amDirIndIdxY; Bit: 0),
    (Op: opADC; Mode: amDirInd; Bit: 0),
    (Op: opADC; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opSTZ; Mode: amDirIdxX; Bit: 0),
    (Op: opADC; Mode: amDirIdxX; Bit: 0),
    (Op: opROR; Mode: amDirIdxX; Bit: 0),
    (Op: opADC; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opSEI; Mode: amImp; Bit: 0),
    (Op: opADC; Mode: amAbsIdxY; Bit: 0),
    (Op: opPLY; Mode: amNone; Bit: 0),
    (Op: opTDC; Mode: amImp; Bit: 0),
    (Op: opJMP_AbsIdxXInd; Mode: amNone; Bit: 0),
    (Op: opADC; Mode: amAbsIdxX; Bit: 0),
    (Op: opROR; Mode: amAbsIdxX; Bit: 0),
    (Op: opADC; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opBRA; Mode: amRel; Bit: 0),
    (Op: opSTA; Mode: amDirIdxIndX; Bit: 0),
    (Op: opBRL; Mode: amRelLng; Bit: 0),
    (Op: opSTA; Mode: amStkRel; Bit: 0),
    (Op: opSTY; Mode: amDir; Bit: 0),
    (Op: opSTA; Mode: amDir; Bit: 0),
    (Op: opSTX; Mode: amDir; Bit: 0),
    (Op: opSTA; Mode: amDirIndLng; Bit: 0),
    (Op: opDEY; Mode: amImp; Bit: 0),
    (Op: opBIT; Mode: amImmM; Bit: 0),
    (Op: opTXA; Mode: amImp; Bit: 0),
    (Op: opPHB; Mode: amNone; Bit: 0),
    (Op: opSTY; Mode: amAbs; Bit: 0),
    (Op: opSTA; Mode: amAbs; Bit: 0),
    (Op: opSTX; Mode: amAbs; Bit: 0),
    (Op: opSTA; Mode: amAbsLng; Bit: 0),
    (Op: opBCC; Mode: amRel; Bit: 0),
    (Op: opSTA; Mode: amDirIndIdxY; Bit: 0),
    (Op: opSTA; Mode: amDirInd; Bit: 0),
    (Op: opSTA; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opSTY; Mode: amDirIdxX; Bit: 0),
    (Op: opSTA; Mode: amDirIdxX; Bit: 0),
    (Op: opSTX; Mode: amDirIdxY; Bit: 0),
    (Op: opSTA; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opTYA; Mode: amImp; Bit: 0),
    (Op: opSTA; Mode: amAbsIdxY; Bit: 0),
    (Op: opTXS; Mode: amImp; Bit: 0),
    (Op: opTXY; Mode: amImp; Bit: 0),
    (Op: opSTZ; Mode: amAbs; Bit: 0),
    (Op: opSTA; Mode: amAbsIdxX; Bit: 0),
    (Op: opSTZ; Mode: amAbsIdxX; Bit: 0),
    (Op: opSTA; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opLDY; Mode: amImmX; Bit: 0),
    (Op: opLDA; Mode: amDirIdxIndX; Bit: 0),
    (Op: opLDX; Mode: amImmX; Bit: 0),
    (Op: opLDA; Mode: amStkRel; Bit: 0),
    (Op: opLDY; Mode: amDir; Bit: 0),
    (Op: opLDA; Mode: amDir; Bit: 0),
    (Op: opLDX; Mode: amDir; Bit: 0),
    (Op: opLDA; Mode: amDirIndLng; Bit: 0),
    (Op: opTAY; Mode: amImp; Bit: 0),
    (Op: opLDA; Mode: amImmM; Bit: 0),
    (Op: opTAX; Mode: amImp; Bit: 0),
    (Op: opPLB; Mode: amNone; Bit: 0),
    (Op: opLDY; Mode: amAbs; Bit: 0),
    (Op: opLDA; Mode: amAbs; Bit: 0),
    (Op: opLDX; Mode: amAbs; Bit: 0),
    (Op: opLDA; Mode: amAbsLng; Bit: 0),
    (Op: opBCS; Mode: amRel; Bit: 0),
    (Op: opLDA; Mode: amDirIndIdxY; Bit: 0),
    (Op: opLDA; Mode: amDirInd; Bit: 0),
    (Op: opLDA; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opLDY; Mode: amDirIdxX; Bit: 0),
    (Op: opLDA; Mode: amDirIdxX; Bit: 0),
    (Op: opLDX; Mode: amDirIdxY; Bit: 0),
    (Op: opLDA; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opCLV; Mode: amImp; Bit: 0),
    (Op: opLDA; Mode: amAbsIdxY; Bit: 0),
    (Op: opTSX; Mode: amImp; Bit: 0),
    (Op: opTYX; Mode: amImp; Bit: 0),
    (Op: opLDY; Mode: amAbsIdxX; Bit: 0),
    (Op: opLDA; Mode: amAbsIdxX; Bit: 0),
    (Op: opLDX; Mode: amAbsIdxY; Bit: 0),
    (Op: opLDA; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opCPY; Mode: amImmX; Bit: 0),
    (Op: opCMP; Mode: amDirIdxIndX; Bit: 0),
    (Op: opREP; Mode: amImm8; Bit: 0),
    (Op: opCMP; Mode: amStkRel; Bit: 0),
    (Op: opCPY; Mode: amDir; Bit: 0),
    (Op: opCMP; Mode: amDir; Bit: 0),
    (Op: opDEC; Mode: amDir; Bit: 0),
    (Op: opCMP; Mode: amDirIndLng; Bit: 0),
    (Op: opINY; Mode: amImp; Bit: 0),
    (Op: opCMP; Mode: amImmM; Bit: 0),
    (Op: opDEX; Mode: amImp; Bit: 0),
    (Op: opWAI; Mode: amNone; Bit: 0),
    (Op: opCPY; Mode: amAbs; Bit: 0),
    (Op: opCMP; Mode: amAbs; Bit: 0),
    (Op: opDEC; Mode: amAbs; Bit: 0),
    (Op: opCMP; Mode: amAbsLng; Bit: 0),
    (Op: opBNE; Mode: amRel; Bit: 0),
    (Op: opCMP; Mode: amDirIndIdxY; Bit: 0),
    (Op: opCMP; Mode: amDirInd; Bit: 0),
    (Op: opCMP; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opPEI; Mode: amDir; Bit: 0),
    (Op: opCMP; Mode: amDirIdxX; Bit: 0),
    (Op: opDEC; Mode: amDirIdxX; Bit: 0),
    (Op: opCMP; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opCLD; Mode: amImp; Bit: 0),
    (Op: opCMP; Mode: amAbsIdxY; Bit: 0),
    (Op: opPHX; Mode: amNone; Bit: 0),
    (Op: opSTP; Mode: amImp; Bit: 0),
    (Op: opJML; Mode: amAbsIndLng; Bit: 0),
    (Op: opCMP; Mode: amAbsIdxX; Bit: 0),
    (Op: opDEC; Mode: amAbsIdxX; Bit: 0),
    (Op: opCMP; Mode: amAbsLngIdxX; Bit: 0),
    (Op: opCPX; Mode: amImmX; Bit: 0),
    (Op: opSBC; Mode: amDirIdxIndX; Bit: 0),
    (Op: opSEP; Mode: amImm8; Bit: 0),
    (Op: opSBC; Mode: amStkRel; Bit: 0),
    (Op: opCPX; Mode: amDir; Bit: 0),
    (Op: opSBC; Mode: amDir; Bit: 0),
    (Op: opINC; Mode: amDir; Bit: 0),
    (Op: opSBC; Mode: amDirIndLng; Bit: 0),
    (Op: opINX; Mode: amImp; Bit: 0),
    (Op: opSBC; Mode: amImmM; Bit: 0),
    (Op: opNOP; Mode: amImp; Bit: 0),
    (Op: opXBA; Mode: amImp; Bit: 0),
    (Op: opCPX; Mode: amAbs; Bit: 0),
    (Op: opSBC; Mode: amAbs; Bit: 0),
    (Op: opINC; Mode: amAbs; Bit: 0),
    (Op: opSBC; Mode: amAbsLng; Bit: 0),
    (Op: opBEQ; Mode: amRel; Bit: 0),
    (Op: opSBC; Mode: amDirIndIdxY; Bit: 0),
    (Op: opSBC; Mode: amDirInd; Bit: 0),
    (Op: opSBC; Mode: amStkRelIndIdxY; Bit: 0),
    (Op: opPEA; Mode: amImm16; Bit: 0),
    (Op: opSBC; Mode: amDirIdxX; Bit: 0),
    (Op: opINC; Mode: amDirIdxX; Bit: 0),
    (Op: opSBC; Mode: amDirIndLngIdxY; Bit: 0),
    (Op: opSED; Mode: amImp; Bit: 0),
    (Op: opSBC; Mode: amAbsIdxY; Bit: 0),
    (Op: opPLX; Mode: amNone; Bit: 0),
    (Op: opXCE; Mode: amImp; Bit: 0),
    (Op: opJSR_AbsIdxXInd; Mode: amNone; Bit: 0),
    (Op: opSBC; Mode: amAbsIdxX; Bit: 0),
    (Op: opINC; Mode: amAbsIdxX; Bit: 0),
    (Op: opSBC; Mode: amAbsLngIdxX; Bit: 0)
  );

constructor TSnesCPU.Create(Read: TSnesRead; Write: TSnesWrite; Clock: TSnesClock; Vector: TSnesVector; ControlIdle: TSnesControlIdle);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FClock := Clock;
  FVector := Vector;
  FControlIdle := ControlIdle;
end;

procedure TSnesCPU.Reset;
begin
  State := Default(TSnesCPUState);
  State.SP := $1FF;
  State.P := I or M or XFlag;
  State.E := True;
  if Assigned(FVector) then
    State.PC := FVector($FFFC)
  else
    State.PC := ReadWord($FFFC);
end;

procedure TSnesCPU.Idle;
begin
  if State.Cycles = High(UInt64) then
    State.Cycles := 0
  else
    Inc(State.Cycles);
  FClock(6);
end;

function TSnesCPU.ReadBus(Address: Cardinal): Byte;
begin
  if State.Cycles = High(UInt64) then
    State.Cycles := 0
  else
    Inc(State.Cycles);
  Result := FRead(Address);
end;

procedure TSnesCPU.WriteBus(Address: Cardinal; Value: Byte);
begin
  if State.Cycles = High(UInt64) then
    State.Cycles := 0
  else
    Inc(State.Cycles);
  FWrite(Address, Value);
end;

function TSnesCPU.Fetch: Byte;
begin
  Result := ReadBus((Cardinal(State.K) shl 16) or State.PC);
  State.PC := (Integer(State.PC) + 1) and $FFFF;
end;

function TSnesCPU.FetchWord: Word;
begin
  Result := Fetch;
  Result := Result or (Word(Fetch) shl 8);
end;

function TSnesCPU.FetchLong: Cardinal;
begin
  Result := FetchWord;
  Result := Result or (Cardinal(Fetch) shl 16);
end;

function TSnesCPU.ReadWord(Address, Mask: Cardinal): Word;
begin
  Result := ReadBus(Address and Mask);
  Result := Result or (Word(ReadBus((Address + 1) and Mask)) shl 8);
end;

function TSnesCPU.Direct(Offset: Integer; Wrap: Boolean): Word;
begin
  if Wrap and State.E and ((State.D and $FF) = 0) then
    Result := (State.D and $FF00) or (Offset and $FF)
  else
    Result := Word(State.D + Offset);
end;

function TSnesCPU.DirectWord(Offset: Integer; BugWrap: Boolean): Word;
begin
  Result := ReadBus(Direct(Offset));
  var Hi := Direct(Offset + 1);
  if BugWrap and State.E and ((State.D and $FF) <> 0) and ((Hi and $FF) = 0) then
    Hi := Word(Hi - $100);
  Result := Result or (Word(ReadBus(Hi)) shl 8);
end;

function TSnesCPU.DirectLong(Offset: Integer): Cardinal;
begin
  Result := ReadBus(Direct(Offset, False));
  Result := Result or (Cardinal(ReadBus(Direct(Offset + 1, False))) shl 8);
  Result := Result or (Cardinal(ReadBus(Direct(Offset + 2, False))) shl 16);
end;

procedure TSnesCPU.SetP(Value: Byte);
begin
  State.P := Value;
  if State.E then
    State.P := State.P or M or XFlag;
  if (State.P and XFlag) <> 0 then
  begin
    State.X := State.X and $FF;
    State.Y := State.Y and $FF;
  end;
end;

procedure TSnesCPU.SetSP(Value: Word; Wrap: Boolean);
begin
  State.SP := Value;
  if State.E and Wrap then
    State.SP := $100 or (Value and $FF);
end;

procedure TSnesCPU.Push(Value: Byte; Wrap: Boolean);
begin
  WriteBus(State.SP, Value);
  SetSP(Word(State.SP - 1), Wrap);
end;

procedure TSnesCPU.PushWord(Value: Word; Wrap: Boolean);
begin
  Push(Value shr 8, Wrap);
  Push(Byte(Value), Wrap);
end;

function TSnesCPU.Pop(Wrap: Boolean): Byte;
begin
  SetSP(Word(State.SP + 1), Wrap);
  Result := ReadBus(State.SP);
end;

function TSnesCPU.PopWord(Wrap: Boolean): Word;
begin
  Result := Pop(Wrap);
  Result := Result or (Word(Pop(Wrap)) shl 8);
end;

procedure TSnesCPU.Flag(Mask: Byte; Enabled: Boolean);
begin
  if Enabled then
    State.P := State.P or Mask
  else
    State.P := State.P and not Mask;
end;

procedure TSnesCPU.NZ(Value: Integer; Eight: Boolean);
begin
  if Eight then
  begin
    Flag(Z, (Value and $FF) = 0);
    Flag(N, (Value and $80) <> 0);
  end
  else
  begin
    Flag(Z, (Value and $FFFF) = 0);
    Flag(N, (Value and $8000) <> 0);
  end;
end;

procedure TSnesCPU.LoadReg(var Reg: Word; Value: Integer; Eight: Boolean);
begin
  NZ(Value, Eight);
  if Eight then
    Reg := (Reg and $FF00) or (Value and $FF)
  else
    Reg := Word(Value);
end;

function TSnesCPU.Value(Eight: Boolean): Integer;
begin
  if Immediate then
    Result := Operand
  else if Eight then
    Result := ReadBus(Operand and AddressMask)
  else
    Result := ReadWord(Operand, AddressMask);
end;

procedure TSnesCPU.Store(V: Integer; Eight, RMW: Boolean);
begin
  if not Eight and RMW then
    WriteBus((Operand + 1) and AddressMask, Byte(V shr 8));
  WriteBus(Operand and AddressMask, Byte(V));
  if not Eight and not RMW then
    WriteBus((Operand + 1) and AddressMask, Byte(V shr 8));
end;

procedure TSnesCPU.Branch(Taken: Boolean);
begin
  if not Taken then
    Exit;
  Idle;
  var Target := Word(State.PC + ShortInt(Operand));
  if State.E and ((Target and $FF00) <> (State.PC and $FF00)) then
    Idle;
  State.PC := Target;
  if Assigned(FControlIdle) then
    FControlIdle(State.PC, False);
end;

procedure TSnesCPU.Add(V: Integer; Eight, Subtract: Boolean);
begin
  var Mask := $FFFF;
  var Sign := $8000;
  var DecimalLimit := $9FFF;
  if Eight then
  begin
    Mask := $FF;
    Sign := $80;
    DecimalLimit := $9F;
  end;
  if Subtract then
    V := V xor Mask;
  var A: Integer := State.A and Mask;
  var Carry: Integer := State.P and C;
  var R: Integer := A + V + Carry;
  if (State.P and DFlag) <> 0 then
  begin
    R := (A and $F) + (V and $F) + Carry;
    if Subtract then
    begin
      if R <= $F then
        Dec(R, 6);
    end
    else if R > 9 then
      Inc(R, 6);
    R := (A and $F0) + (V and $F0) + Ord(R > $F) * $10 + (R and $F);
    if not Eight then
    begin
      if Subtract then
      begin
        if R <= $FF then
          Dec(R, $60);
      end
      else if R > $9F then
        Inc(R, $60);
      R := (A and $F00) + (V and $F00) + Ord(R > $FF) * $100 + (R and $FF);
      if Subtract then
      begin
        if R <= $FFF then
          Dec(R, $600);
      end
      else if R > $9FF then
        Inc(R, $600);
      R := (A and $F000) + (V and $F000) + Ord(R > $FFF) * $1000 + (R and $FFF);
    end;
  end;
  Flag(VFlag, ((not (A xor V)) and (A xor R) and Sign) <> 0);
  if (State.P and DFlag) <> 0 then
    if Subtract then
    begin
      if R <= Mask then
        Dec(R, (Mask + 1) div 16 * 6);
    end
    else if R > DecimalLimit then
      Inc(R, (Mask + 1) div 16 * 6);
  Flag(C, R > Mask);
  LoadReg(State.A, R, Eight);
end;

procedure TSnesCPU.Interrupt(Vector: Word; Hardware: Boolean);
begin
  if Hardware then
  begin
    ReadBus((Cardinal(State.K) shl 16) or State.PC);
    Idle;
  end;
  if not State.E then
    Push(State.K);
  PushWord(State.PC);
  var PS := State.P;
  if State.E and Hardware then
    PS := PS and not XFlag;
  Push(PS);
  State.P := (State.P or I) and not DFlag;
  State.K := 0;
  if Assigned(FVector) then
    State.PC := FVector(Vector)
  else
    State.PC := ReadWord(Vector);
  State.Waiting := False;
end;

procedure TSnesCPU.Step;
var
  O: TSnesOp;
  Mode: TSnesMode;
  Addr, Base: Cardinal;
  V, Mask, Sign, R, OldCarry, Offset: Integer;
  Eight, Index8, Acc, Writing: Boolean;
begin
  if State.Stopped then
  begin
    Idle;
    Exit;
  end;
  if State.NMI then
  begin
    State.NMI := False;
    if State.E then
      Interrupt($FFFA, True)
    else
      Interrupt($FFEA, True);
    Exit;
  end;
  if State.IRQ then
  begin
    State.Waiting := False;
    if (State.P and I) = 0 then
    begin
      if State.E then
        Interrupt($FFFE, True)
      else
        Interrupt($FFEE, True);
      Exit;
    end;
  end;
  if State.Waiting then
  begin
    Idle;
    Exit;
  end;
  var Code := Fetch;
  O := Opcodes[Code].Op;
  Mode := Opcodes[Code].Mode;
  Eight := (State.P and M) <> 0;
  Index8 := (State.P and XFlag) <> 0;
  Immediate := False;
  AddressMask := $FFFFFF;
  Operand := 0;
  Writing := O in [opSTA, opSTX, opSTY, opSTZ, opASL, opROL, opLSR, opROR, opINC, opDEC];
  case Mode of
    amImp, amAcc:
      Idle;
    amImm8:
      begin
        Immediate := True;
        Operand := Fetch;
      end;
    amImm16:
      begin
        Immediate := True;
        Operand := FetchWord;
      end;
    amImmM:
      begin
        Immediate := True;
        if Eight then
          Operand := Fetch
        else
          Operand := FetchWord;
      end;
    amImmX:
      begin
        Immediate := True;
        if Index8 then
          Operand := Fetch
        else
          Operand := FetchWord;
      end;
    amRel:
      Operand := Fetch;
    amRelLng:
      begin
        Operand := FetchWord;
        Idle;
      end;
    amAbs:
      Operand := (Cardinal(State.DB) shl 16) or FetchWord;
    amAbsIdxX, amAbsIdxY:
      begin
        Base := FetchWord;
        if Mode = amAbsIdxX then
          Offset := State.X
        else
          Offset := State.Y;
        Operand := ((Cardinal(State.DB) shl 16) + Base + Cardinal(Offset)) and $FFFFFF;
        if Writing or not Index8 or ((Base and $FF00) <> ((Base + Cardinal(Offset)) and $FF00)) then
          Idle;
      end;
    amAbsLng:
      Operand := FetchLong;
    amAbsLngIdxX:
      Operand := (FetchLong + State.X) and $FFFFFF;
    amAbsJmp:
      Operand := FetchWord;
    amAbsLngJmp:
      Operand := FetchLong;
    amAbsInd:
      begin
        Addr := FetchWord;
        Operand := ReadWord(Addr, $FFFF);
      end;
    amAbsIndLng:
      begin
        Addr := FetchWord;
        Operand := ReadWord(Addr, $FFFF);
        Operand := Operand or (Cardinal(ReadBus(Word(Addr + 2))) shl 16);
      end;
    amBlkMov:
      Operand := FetchWord;
    amStkRel:
      begin
        Operand := Word(State.SP + Fetch);
        Idle;
      end;
    amStkRelIndIdxY:
      begin
        Addr := Word(State.SP + Fetch);
        Idle;
        Operand := ((Cardinal(State.DB) shl 16) + ReadWord(Addr, $FFFF) + State.Y) and $FFFFFF;
        Idle;
      end;
    amDir, amDirIdxX, amDirIdxY, amDirInd, amDirIdxIndX, amDirIndIdxY, amDirIndLng, amDirIndLngIdxY:
      begin
        Offset := Fetch;
        if (State.D and $FF) <> 0 then
          Idle;
        case Mode of
          amDir:
            begin
              Operand := Word(State.D + Offset);
              AddressMask := $FFFF;
            end;
          amDirIdxX:
            begin
              Operand := Direct(Offset + State.X);
              AddressMask := $FFFF;
              Idle;
            end;
          amDirIdxY:
            begin
              Operand := Direct(Offset + State.Y);
              AddressMask := $FFFF;
              Idle;
            end;
          amDirInd:
            Operand := (Cardinal(State.DB) shl 16) or DirectWord(Offset);
          amDirIdxIndX:
            begin
              Idle;
              Operand := (Cardinal(State.DB) shl 16) or DirectWord(Offset + State.X, True);
            end;
          amDirIndIdxY:
            begin
              Base := DirectWord(Offset);
              Operand := ((Cardinal(State.DB) shl 16) + Base + State.Y) and $FFFFFF;
              if Writing or not Index8 or ((Base and $FF00) <> ((Base + State.Y) and $FF00)) then
                Idle;
            end;
          amDirIndLng:
            Operand := DirectLong(Offset);
          amDirIndLngIdxY:
            Operand := (DirectLong(Offset) + State.Y) and $FFFFFF;
        end;
      end;
  end;
  Mask := $FFFF;
  Sign := $8000;
  if Eight then
  begin
    Mask := $FF;
    Sign := $80;
  end;
  Acc := Mode = amAcc;
  case O of
    opORA, opAND, opEOR:
      begin
        V := Value(Eight);
        R := State.A;
        case O of
          opORA:
            R := R or V;
          opAND:
            R := R and V;
          opEOR:
            R := R xor V;
        end;
        LoadReg(State.A, R, Eight);
      end;
    opADC:
      Add(Value(Eight), Eight, False);
    opSBC:
      Add(Value(Eight), Eight, True);
    opLDA:
      LoadReg(State.A, Value(Eight), Eight);
    opLDX:
      LoadReg(State.X, Value(Index8), Index8);
    opLDY:
      LoadReg(State.Y, Value(Index8), Index8);
    opSTA:
      Store(State.A, Eight);
    opSTX:
      Store(State.X, Index8);
    opSTY:
      Store(State.Y, Index8);
    opSTZ:
      Store(0, Eight);
    opCMP, opCPX, opCPY:
      begin
        if O = opCMP then
          R := State.A and Mask
        else
        begin
          Eight := Index8;
          if Eight then
            Mask := $FF
          else
            Mask := $FFFF;
          if O = opCPX then
            R := State.X and Mask
          else
            R := State.Y and Mask;
        end;
        V := Value(Eight);
        Flag(C, R >= V);
        NZ(R - V, Eight);
      end;
    opBIT, opTRB, opTSB:
      begin
        V := Value(Eight);
        Flag(Z, (State.A and V and Mask) = 0);
        if O = opBIT then
        begin
          if not Immediate then
          begin
            Flag(N, (V and Sign) <> 0);
            Flag(VFlag, (V and (Sign shr 1)) <> 0);
          end;
        end
        else
        begin
          if Eight and State.E then
            WriteBus(Operand, Byte(V))
          else
            Idle;
          if O = opTRB then
            V := V and not State.A
          else
            V := V or State.A;
          Store(V, Eight, True);
        end;
      end;
    opASL, opLSR, opROL, opROR, opINC, opDEC, opASL_Acc, opLSR_Acc, opROL_Acc, opROR_Acc, opINC_Acc, opDEC_Acc:
      begin
        if Acc then
          V := State.A and Mask
        else
          V := Value(Eight);
        OldCarry := State.P and C;
        R := V;
        case O of
          opASL, opASL_Acc:
            begin
              Flag(C, (V and Sign) <> 0);
              R := V shl 1;
            end;
          opLSR, opLSR_Acc:
            begin
              Flag(C, (V and 1) <> 0);
              R := V shr 1;
            end;
          opROL, opROL_Acc:
            begin
              Flag(C, (V and Sign) <> 0);
              R := (V shl 1) or OldCarry;
            end;
          opROR, opROR_Acc:
            begin
              Flag(C, (V and 1) <> 0);
              R := (V shr 1) or (OldCarry * Sign);
            end;
          opINC, opINC_Acc:
            R := V + 1;
          opDEC, opDEC_Acc:
            R := V - 1;
        end;
        if Acc then
          LoadReg(State.A, R, Eight)
        else
        begin
          if Eight and State.E then
            WriteBus(Operand, Byte(V))
          else
            Idle;
          NZ(R, Eight);
          Store(R, Eight, True);
        end;
      end;
    opINX:
      LoadReg(State.X, State.X + 1, Index8);
    opINY:
      LoadReg(State.Y, State.Y + 1, Index8);
    opDEX:
      LoadReg(State.X, State.X - 1, Index8);
    opDEY:
      LoadReg(State.Y, State.Y - 1, Index8);
    opBCC:
      Branch((State.P and C) = 0);
    opBCS:
      Branch((State.P and C) <> 0);
    opBEQ:
      Branch((State.P and Z) <> 0);
    opBNE:
      Branch((State.P and Z) = 0);
    opBMI:
      Branch((State.P and N) <> 0);
    opBPL:
      Branch((State.P and N) = 0);
    opBVC:
      Branch((State.P and VFlag) = 0);
    opBVS:
      Branch((State.P and VFlag) <> 0);
    opBRA:
      Branch(True);
    opBRL:
      begin
        State.PC := Word(State.PC + SmallInt(Operand));
        if Assigned(FControlIdle) then
          FControlIdle(State.PC, False);
      end;
    opCLC:
      Flag(C, False);
    opSEC:
      Flag(C, True);
    opCLI:
      Flag(I, False);
    opSEI:
      Flag(I, True);
    opCLD:
      Flag(DFlag, False);
    opSED:
      Flag(DFlag, True);
    opCLV:
      Flag(VFlag, False);
    opREP:
      begin
        Idle;
        SetP(State.P and not Byte(Operand));
      end;
    opSEP:
      begin
        Idle;
        SetP(State.P or Byte(Operand));
      end;
    opTAX:
      LoadReg(State.X, State.A, Index8);
    opTAY:
      LoadReg(State.Y, State.A, Index8);
    opTXA:
      LoadReg(State.A, State.X, Eight);
    opTYA:
      LoadReg(State.A, State.Y, Eight);
    opTXY:
      LoadReg(State.Y, State.X, Index8);
    opTYX:
      LoadReg(State.X, State.Y, Index8);
    opTSX:
      LoadReg(State.X, State.SP, Index8);
    opTXS:
      SetSP(State.X);
    opTCS:
      SetSP(State.A);
    opTSC:
      LoadReg(State.A, State.SP, False);
    opTCD:
      LoadReg(State.D, State.A, False);
    opTDC:
      LoadReg(State.A, State.D, False);
    opXBA:
      begin
        State.A := ((State.A and $FF) shl 8) or (State.A shr 8);
        NZ(State.A, True);
        Idle;
      end;
    opXCE:
      begin
        var WasE := State.E;
        State.E := (State.P and C) <> 0;
        Flag(C, WasE);
        SetP(State.P);
        SetSP(State.SP);
      end;
    opPHP:
      begin
        Idle;
        Push(State.P);
      end;
    opPHK:
      begin
        Idle;
        Push(State.K);
      end;
    opPHB:
      begin
        Idle;
        Push(State.DB);
      end;
    opPHD:
      begin
        Idle;
        PushWord(State.D, False);
        SetSP(State.SP);
      end;
    opPHA:
      begin
        Idle;
        if Eight then
          Push(Byte(State.A))
        else
          PushWord(State.A);
      end;
    opPHX:
      begin
        Idle;
        if Index8 then
          Push(Byte(State.X))
        else
          PushWord(State.X);
      end;
    opPHY:
      begin
        Idle;
        if Index8 then
          Push(Byte(State.Y))
        else
          PushWord(State.Y);
      end;
    opPLP:
      begin
        Idle;
        Idle;
        SetP(Pop);
      end;
    opPLB:
      begin
        Idle;
        Idle;
        State.DB := Pop(False);
        NZ(State.DB, True);
        SetSP(State.SP);
      end;
    opPLD:
      begin
        Idle;
        Idle;
        LoadReg(State.D, PopWord(False), False);
        SetSP(State.SP);
      end;
    opPLA:
      begin
        Idle;
        Idle;
        if Eight then
          V := Pop
        else
          V := PopWord;
        LoadReg(State.A, V, Eight);
      end;
    opPLX:
      begin
        Idle;
        Idle;
        if Index8 then
          V := Pop
        else
          V := PopWord;
        LoadReg(State.X, V, Index8);
      end;
    opPLY:
      begin
        Idle;
        Idle;
        if Index8 then
          V := Pop
        else
          V := PopWord;
        LoadReg(State.Y, V, Index8);
      end;
    opPEA:
      begin
        PushWord(Word(Operand), False);
        SetSP(State.SP);
      end;
    opPEI:
      begin
        PushWord(ReadWord(Operand, $FFFF), False);
        SetSP(State.SP);
      end;
    opPER:
      begin
        PushWord(Word(State.PC + SmallInt(Operand)), False);
        SetSP(State.SP);
      end;
    opJMP:
      State.PC := Word(Operand);
    opJML:
      begin
        State.PC := Word(Operand);
        State.K := Operand shr 16;
      end;
    opJSR:
      begin
        Idle;
        PushWord(Word(State.PC - 1));
        State.PC := Word(Operand);
      end;
    opJSL:
      begin
        Addr := FetchWord;
        Push(State.K, False);
        Idle;
        Base := Fetch;
        PushWord(Word(State.PC - 1), False);
        SetSP(State.SP);
        State.K := Base;
        State.PC := Word(Addr);
      end;
    opJMP_AbsIdxXInd, opJSR_AbsIdxXInd:
      begin
        Addr := FetchWord;
        Idle;
        if O = opJSR_AbsIdxXInd then
          PushWord(Word(State.PC - 1), False);
        Base := Cardinal(State.K) shl 16;
        State.PC := ReadBus(Base or Word(Addr + State.X));
        State.PC := State.PC or (Word(ReadBus(Base or Word(Addr + State.X + 1))) shl 8);
        SetSP(State.SP);
      end;
    opRTS:
      begin
        Idle;
        Idle;
        State.PC := Word(PopWord + 1);
        Idle;
      end;
    opRTL:
      begin
        Idle;
        Idle;
        State.PC := Word(PopWord(False) + 1);
        State.K := Pop(False);
        SetSP(State.SP);
      end;
    opRTI:
      begin
        Idle;
        Idle;
        SetP(Pop);
        State.PC := PopWord;
        if not State.E then
          State.K := Pop;
      end;
    opBRK:
      if State.E then
        Interrupt($FFFE, False)
      else
        Interrupt($FFE6, False);
    opCOP:
      if State.E then
        Interrupt($FFF4, False)
      else
        Interrupt($FFE4, False);
    opMVN, opMVP:
      begin
        State.DB := Byte(Operand);
        V := ReadBus(((Operand shl 8) and $FF0000) or State.X);
        WriteBus((Cardinal(State.DB) shl 16) or State.Y, Byte(V));
        Idle;
        Idle;
        if O = opMVN then
        begin
          State.X := (Integer(State.X) + 1) and $FFFF;
          State.Y := (Integer(State.Y) + 1) and $FFFF;
        end
        else
        begin
          State.X := (Integer(State.X) - 1) and $FFFF;
          State.Y := (Integer(State.Y) - 1) and $FFFF;
        end;
        if Index8 then
        begin
          State.X := State.X and $FF;
          State.Y := State.Y and $FF;
        end;
        State.A := (Integer(State.A) - 1) and $FFFF;
        if State.A <> $FFFF then
          State.PC := (Integer(State.PC) - 3) and $FFFF;
      end;
    opWAI:
      begin
        Idle;
        Idle;
        State.Waiting := True;
      end;
    opSTP:
      State.Stopped := True;
    opNOP, opWDM:
      ;
  end;
  if Assigned(FControlIdle) and (O in [opJMP, opJML, opJSR, opJSL, opJMP_AbsIdxXInd, opJSR_AbsIdxXInd, opRTS, opRTL, opRTI]) then
    FControlIdle(State.PC, True);
end;

procedure TSnesCPU.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
end;

end.

