unit HW.V30MZ;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

const
  V30_CF = $0001;
  V30_PF = $0004;
  V30_AF = $0010;
  V30_ZF = $0040;
  V30_SF = $0080;
  V30_TF = $0100;
  V30_IF = $0200;
  V30_DF = $0400;
  V30_OF = $0800;

type
  TV30Read = function(Address: Cardinal): Byte of object;

  TV30Clock = procedure(Clocks: Integer) of object;

  TV30BusInfo = function(Address: Cardinal): Integer of object; // low byte: waits, bit 8: word bus

  TV30Write = procedure(Address: Cardinal; Value: Byte) of object;

  TV30PortRead = function(Address: Cardinal; WordAccess: Boolean): Byte of object;

  TV30PortWrite = procedure(Address: Cardinal; Value: Byte; WordAccess: Boolean) of object;

  TV30State = record
    R: array[0..7] of Word; // AX CX DX BX SP BP SI DI
    S: array[0..3] of Word; // ES CS SS DS
    IP, Flags: Word;
    Halted: Boolean;
    IRQShadow: Byte;
    Cycles: UInt64;
    InvalidCount: Cardinal;
    MulOverflow: Boolean;
    Prefetch: array[0..15] of Byte;
    FetchCS, FetchIP, ReadIP: Word;
    QueueHead, QueueCount, FetchWait: Byte;
    RepeatActive: Boolean;
    RepeatIP, RepeatCS, RepeatNextIP: Word;
    RepeatOp, RepeatType: Byte;
    RepeatSeg: ShortInt;
  end;

  // Native V30MZ interpreter. REP executes one iteration per Step, allowing
  // scanline, DMA and interrupt scheduling between iterations.
  TV30MZ = class
  private
    FRead, FIn: TV30Read;
    FWrite, FOut: TV30Write;
    FSeg, FRep, FCost: Integer;
    FStartIP: Word;
    FSpent: Integer;
    function Bus(Address: Cardinal): Integer;
    procedure TickClocks(Clocks: Integer);
    procedure PrefetchCycle;
    procedure Idle(Clocks: Integer);
    procedure MemoryCycles(Address: Cardinal; Wide: Boolean);
    procedure FlushPrefetch;
    function PortIn(Port: Word; Wide: Boolean): Word;
    procedure PortOut(Port, Value: Word; Wide: Boolean);
  private
    FMod, FReg, FRM: Integer;
    FOffset, FSegment: Word;
    function Fetch8: Byte;
    function Fetch16: Word;
    function Mem(Seg, Offset: Word; Wide: Boolean): Word;
    procedure PutMem(Seg, Offset, Value: Word; Wide: Boolean);
    function RegValue(Index: Integer; Wide: Boolean): Word;
    procedure PutReg(Index: Integer; Value: Word; Wide: Boolean);
    procedure Decode;
    procedure MemoryRegisterEA;
    function Operand(Wide: Boolean): Word;
    procedure PutOperand(Value: Word; Wide: Boolean);
    function DataSeg: Word;
    procedure Push(Value: Word);
    function Pop: Word;
    procedure SetFlag(Mask: Word; Value: Boolean);
    procedure LoadFlags(Value: Word);
    procedure SZP(Value: Word; Wide: Boolean);
    function ALU(Op: Integer; A, B: Word; Wide: Boolean): Word;
    function Shift(Op: Integer; A: Word; Count: Integer; Wide: Boolean): Word;
    function Condition(Code: Integer): Boolean;
    procedure SoftwareInterrupt(Vector: Byte);
    procedure StringOp(Op: Byte);
    procedure Group3(Wide: Boolean);
  public
    State: TV30State;
    HardwareColor: Boolean;
    BusInfo: TV30BusInfo;
    ClockEvent: TV30Clock;
    PortBusInfo: TV30BusInfo;
    PortReadEvent: TV30PortRead;
    PortWriteEvent: TV30PortWrite;
    constructor Create(ReadMemory: TV30Read; WriteMemory: TV30Write; ReadPort: TV30Read; WritePort: TV30Write);
    procedure Reset;
    function Step: Integer;
    function Interrupt(Vector: Byte): Boolean;
    procedure SerializeState(Archive: TStateArchive);
    function ProgramCounter: Cardinal;
  end;

implementation

{$Q-}{$R-}

constructor TV30MZ.Create(ReadMemory: TV30Read; WriteMemory: TV30Write; ReadPort: TV30Read; WritePort: TV30Write);
begin
  inherited Create;
  HardwareColor := True;
  FRead := ReadMemory;
  FWrite := WriteMemory;
  FIn := ReadPort;
  FOut := WritePort;
  Reset;
end;

procedure TV30MZ.Reset;
begin
  State := Default(TV30State);
  State.S[1] := $FFFF;
  State.R[3] := $1C00;
  State.R[1] := 4;
  State.R[4] := $2000;
  State.R[7] := $6FFF;
  State.Flags := $F002;
  FlushPrefetch;
end;

function TV30MZ.ProgramCounter: Cardinal;
begin
  Result := ((Cardinal(State.S[1]) shl 4) + State.IP) and $FFFFF;
end;

function TV30MZ.Bus(Address: Cardinal): Integer;
begin
  if Assigned(BusInfo) then
    Result := BusInfo(Address and $FFFFF)
  else
    Result := $101;
end;

procedure TV30MZ.FlushPrefetch;
begin
  State.FetchCS := State.S[1];
  State.FetchIP := State.IP;
  State.ReadIP := State.IP;
  State.QueueCount := 0;
  State.QueueHead := 0;
  State.FetchWait := 0;
end;

procedure TV30MZ.TickClocks(Clocks: Integer);
begin
  Inc(FSpent, Clocks);
  if Assigned(ClockEvent) then
    ClockEvent(Clocks);
end;

procedure TV30MZ.PrefetchCycle;
begin
  TickClocks(1);
  if (State.FetchCS <> State.S[1]) or ((State.ReadIP <> State.IP) and not State.RepeatActive) then
    FlushPrefetch;
  Inc(State.FetchWait);
  if State.QueueCount >= 16 then
    Exit;
  var Info := Bus((Cardinal(State.FetchCS) shl 4) + State.FetchIP);
  if State.FetchWait < (Info and $FF) then
    Exit;
  State.FetchWait := 0;
  var Count := 1;
  if (Info and $100 <> 0) and not Odd(State.FetchIP) then
    Count := 2;
  for var I := 1 to Count do
  begin
    if State.QueueCount = 16 then
      Break;
    State.Prefetch[(State.QueueHead + State.QueueCount) and 15] :=
      FRead(((Cardinal(State.FetchCS) shl 4) + State.FetchIP) and $FFFFF);
    Inc(State.FetchIP);
    Inc(State.QueueCount);
  end;
end;

procedure TV30MZ.Idle(Clocks: Integer);
begin
  for var I := 1 to Clocks do
    PrefetchCycle;
end;

procedure TV30MZ.MemoryCycles(Address: Cardinal; Wide: Boolean);
begin
  var Info := Bus(Address);
  TickClocks(Info and $FF);
  if Wide and (Odd(Address) or (Info and $100 = 0)) then
    TickClocks(Bus(Address + 1) and $FF);
end;

function TV30MZ.Fetch8: Byte;
begin
  if (State.FetchCS <> State.S[1]) or (State.ReadIP <> State.IP) then
    FlushPrefetch;
  while State.QueueCount < 2 do
    PrefetchCycle;
  Result := State.Prefetch[State.QueueHead];
  State.QueueHead := (State.QueueHead + 1) and 15;
  Dec(State.QueueCount);
  Inc(State.IP);
  State.ReadIP := State.IP;
end;

function TV30MZ.Fetch16: Word;
begin
  if (State.FetchCS <> State.S[1]) or (State.ReadIP <> State.IP) then
    FlushPrefetch;
  while State.QueueCount < 2 do
    PrefetchCycle;
  Result := State.Prefetch[State.QueueHead];
  State.QueueHead := (State.QueueHead + 1) and 15;
  Result := Result or (Word(State.Prefetch[State.QueueHead]) shl 8);
  State.QueueHead := (State.QueueHead + 1) and 15;
  Dec(State.QueueCount, 2);
  Inc(State.IP, 2);
  State.ReadIP := State.IP;
end;

function TV30MZ.PortIn(Port: Word; Wide: Boolean): Word;

  function ReadCycle(Address: Word; WordAccess: Boolean; ClockBus: Boolean): Byte;
  begin
    if ClockBus then
      if Assigned(PortBusInfo) then
        TickClocks(PortBusInfo(Address) and $FF)
      else
        TickClocks(1);
    if Assigned(PortReadEvent) then
      Result := PortReadEvent(Address, WordAccess)
    else
      Result := FIn(Address);
  end;

begin
  var WordBus := Port < $C0;
  if Assigned(PortBusInfo) then
    WordBus := PortBusInfo(Port) and $100 <> 0;
  var Combined := Wide and not Odd(Port) and WordBus;
  Result := ReadCycle(Port, Combined, True);
  if Wide then
    Result := Result or (Word(ReadCycle(Word(Port + 1), Combined, not Combined)) shl 8);
end;

procedure TV30MZ.PortOut(Port, Value: Word; Wide: Boolean);

  procedure WriteCycle(Address: Word; Data: Byte; WordAccess, ClockBus: Boolean);
  begin
    if ClockBus then
      if Assigned(PortBusInfo) then
        TickClocks(PortBusInfo(Address) and $FF)
      else
        TickClocks(1);
    if Assigned(PortWriteEvent) then
      PortWriteEvent(Address, Data, WordAccess)
    else
      FOut(Address, Data);
  end;

begin
  var WordBus := Port < $C0;
  if Assigned(PortBusInfo) then
    WordBus := PortBusInfo(Port) and $100 <> 0;
  var Combined := Wide and not Odd(Port) and WordBus;
  WriteCycle(Port, Byte(Value), Combined, True);
  if Wide then
    WriteCycle(Word(Port + 1), Value shr 8, Combined, not Combined);
end;

function TV30MZ.Mem(Seg, Offset: Word; Wide: Boolean): Word;
begin
  MemoryCycles((Cardinal(Seg) shl 4) + Offset, Wide);
  Result := FRead(((Cardinal(Seg) shl 4) + Offset) and $FFFFF);
  if Wide then
    Result := Result or (Word(FRead(((Cardinal(Seg) shl 4) + Word(Offset + 1)) and $FFFFF)) shl 8);
end;

procedure TV30MZ.PutMem(Seg, Offset, Value: Word; Wide: Boolean);
begin
  MemoryCycles((Cardinal(Seg) shl 4) + Offset, Wide);
  FWrite(((Cardinal(Seg) shl 4) + Offset) and $FFFFF, Byte(Value));
  if Wide then
    FWrite(((Cardinal(Seg) shl 4) + Word(Offset + 1)) and $FFFFF, Value shr 8);
end;

function TV30MZ.RegValue(Index: Integer; Wide: Boolean): Word;
begin
  if Wide then
    Exit(State.R[Index and 7]);
  Result := (State.R[Index and 3] shr ((Index shr 2) * 8)) and $FF;
end;

procedure TV30MZ.PutReg(Index: Integer; Value: Word; Wide: Boolean);
begin
  if Wide then
    State.R[Index and 7] := Value
  else if Index < 4 then
    State.R[Index] := (State.R[Index] and $FF00) or (Value and $FF)
  else
    State.R[Index and 3] := (State.R[Index and 3] and $FF) or (Value shl 8);
end;

function TV30MZ.DataSeg: Word;
begin
  if FSeg >= 0 then
    Result := State.S[FSeg]
  else
    Result := State.S[3];
end;

procedure TV30MZ.Decode;
var
  B: Byte;
  Base: Word;
  Seg: Integer;
begin
  B := Fetch8;
  FMod := B shr 6;
  FReg := (B shr 3) and 7;
  FRM := B and 7;
  FOffset := 0;
  FSegment := 0;
  if FMod = 3 then
    Exit;
  Seg := 3;
  case FRM of
    0:
      Base := State.R[3] + State.R[6];
    1:
      Base := State.R[3] + State.R[7];
    2:
      begin
        Base := State.R[5] + State.R[6];
        Seg := 2;
      end;
    3:
      begin
        Base := State.R[5] + State.R[7];
        Seg := 2;
      end;
    4:
      Base := State.R[6];
    5:
      Base := State.R[7];
    6:
      if FMod = 0 then
        Base := Fetch16
      else
      begin
        Base := State.R[5];
        Seg := 2;
      end;
  else
    Base := State.R[3];
  end;
  if FMod = 1 then
    Base := Base + ShortInt(Fetch8);
  if FMod = 2 then
    Base := Base + Fetch16;
  if FSeg >= 0 then
    Seg := FSeg;
  FOffset := Base;
  FSegment := State.S[Seg];
  if (FRM < 4) then
    Inc(FCost, 1);
end;

procedure TV30MZ.MemoryRegisterEA;
var
  Seg: Integer;
begin
  if FMod <> 3 then
    Exit;
  FMod := 0;
  Seg := 3;
  case FRM of
    0:
      FOffset := State.R[3] + State.R[0];
    1:
      FOffset := State.R[3] + State.R[1];
    2:
      begin
        FOffset := State.R[5] + State.R[2];
        Seg := 2;
      end;
    3:
      begin
        FOffset := State.R[5] + State.R[3];
        Seg := 2;
      end;
    4:
      FOffset := State.R[4] + State.R[6];
    5:
      FOffset := State.R[5] + State.R[7];
    6:
      begin
        FOffset := State.R[5] + State.R[6];
        Seg := 2;
      end;
    7:
      FOffset := State.R[3] + State.R[7];
  end;
  if FSeg >= 0 then
    Seg := FSeg;
  FSegment := State.S[Seg];
end;

function TV30MZ.Operand(Wide: Boolean): Word;
begin
  if FMod = 3 then
    Result := RegValue(FRM, Wide)
  else
    Result := Mem(FSegment, FOffset, Wide);
end;

procedure TV30MZ.PutOperand(Value: Word; Wide: Boolean);
begin
  if FMod = 3 then
    PutReg(FRM, Value, Wide)
  else
    PutMem(FSegment, FOffset, Value, Wide);
end;

procedure TV30MZ.Push(Value: Word);
begin
  Dec(State.R[4], 2);
  PutMem(State.S[2], State.R[4], Value, True);
end;

function TV30MZ.Pop: Word;
begin
  Result := Mem(State.S[2], State.R[4], True);
  Inc(State.R[4], 2);
end;

procedure TV30MZ.SetFlag(Mask: Word; Value: Boolean);
begin
  if Value then
    State.Flags := State.Flags or Mask
  else
    State.Flags := State.Flags and not Mask;
end;

procedure TV30MZ.LoadFlags(Value: Word);
begin
  if (State.Flags and V30_IF = 0) and (Value and V30_IF <> 0) then
    State.IRQShadow := 1;
  State.Flags := (Value and $8FD5) or $7002;
end;

procedure TV30MZ.SZP(Value: Word; Wide: Boolean);
var
  V: Byte;
begin
  if not Wide then
    Value := Value and $FF;
  SetFlag(V30_ZF, Value = 0);
  if Wide then
    SetFlag(V30_SF, Value and $8000 <> 0)
  else
    SetFlag(V30_SF, Value and $80 <> 0);
  V := Byte(Value);
  V := V xor (V shr 4);
  V := V xor (V shr 2);
  V := V xor (V shr 1);
  SetFlag(V30_PF, V and 1 = 0);
end;

function TV30MZ.ALU(Op: Integer; A, B: Word; Wide: Boolean): Word;
var
  Mask, Sign, C: Cardinal;
  N: Int64;
begin
  if Wide then
  begin
    Mask := $FFFF;
    Sign := $8000;
  end
  else
  begin
    Mask := $FF;
    Sign := $80;
  end;
  A := A and Mask;
  B := B and Mask;
  C := Ord(State.Flags and V30_CF <> 0);
  case Op of
    0, 2:
      begin
        if Op = 0 then
          C := 0;
        N := Cardinal(A) + Cardinal(B) + C;
        Result := N and Mask;
        SetFlag(V30_CF, N > Mask);
        SetFlag(V30_OF, (not (A xor B) and (A xor Result) and Sign) <> 0);
        SetFlag(V30_AF, (A xor B xor Result) and $10 <> 0);
      end;
    3, 5, 7:
      begin
        if Op <> 3 then
          C := 0;
        N := Int64(A) - B - C;
        Result := N and Mask;
        SetFlag(V30_CF, N < 0);
        SetFlag(V30_OF, ((A xor B) and (A xor Result) and Sign) <> 0);
        SetFlag(V30_AF, (A xor B xor Result) and $10 <> 0);
      end;
  else
    case Op of
      1:
        Result := A or B;
      4:
        Result := A and B;
    else
      Result := A xor B;
    end;
    State.Flags := State.Flags and not (V30_CF or V30_OF or V30_AF);
  end;
  SZP(Result, Wide);
end;

function TV30MZ.Shift(Op: Integer; A: Word; Count: Integer; Wide: Boolean): Word;
var
  Mask, Sign: Word;
  Carry: Boolean;
begin
  if Wide then
  begin
    Mask := $FFFF;
    Sign := $8000;
  end
  else
  begin
    Mask := $FF;
    Sign := $80;
  end;
  Result := A and Mask;
  Count := Count and 31;

  if Op = 6 then
    Exit(0);
  for var I := 1 to Count do
  begin
    Carry := State.Flags and V30_CF <> 0;
    case Op of
      0:
        begin
          SetFlag(V30_CF, Result and Sign <> 0);
          Result := ((Result shl 1) or Ord(Result and Sign <> 0)) and Mask;
        end;
      1:
        begin
          SetFlag(V30_CF, Odd(Result));
          Result := (Result shr 1) or (Ord(Odd(Result)) * Sign);
        end;
      2:
        begin
          SetFlag(V30_CF, Result and Sign <> 0);
          Result := ((Result shl 1) or Ord(Carry)) and Mask;
        end;
      3:
        begin
          SetFlag(V30_CF, Odd(Result));
          Result := (Result shr 1) or (Ord(Carry) * Sign);
        end;
      4, 6:
        begin
          SetFlag(V30_CF, Result and Sign <> 0);
          Result := (Result shl 1) and Mask;
        end;
      5:
        begin
          SetFlag(V30_CF, Odd(Result));
          Result := Result shr 1;
        end;
      7:
        begin
          SetFlag(V30_CF, Odd(Result));
          Result := (Result shr 1) or (Result and Sign);
        end;
    end;
  end;
  if Op >= 4 then
  begin
    SZP(Result, Wide);
    SetFlag(V30_AF, False);
  end;
  case Op of
    0, 2, 4, 6:
      SetFlag(V30_OF, (Result and Sign <> 0) xor (State.Flags and V30_CF <> 0));
    1, 3:
      SetFlag(V30_OF, (Result and Sign <> 0) xor (Result and (Sign shr 1) <> 0));
    5, 7:
      SetFlag(V30_OF, (Result and Sign <> 0) xor (Result and (Sign shr 1) <> 0));
  end;
end;

function TV30MZ.Condition(Code: Integer): Boolean;
var
  C, Z, S, O, P: Boolean;
begin
  C := State.Flags and V30_CF <> 0;
  Z := State.Flags and V30_ZF <> 0;
  S := State.Flags and V30_SF <> 0;
  O := State.Flags and V30_OF <> 0;
  P := State.Flags and V30_PF <> 0;
  case Code shr 1 of
    0:
      Result := O;
    1:
      Result := C;
    2:
      Result := Z;
    3:
      Result := C or Z;
    4:
      Result := S;
    5:
      Result := P;
    6:
      Result := S xor O;
  else
    Result := Z or (S xor O);
  end;
  if Odd(Code) then
    Result := not Result;
end;

procedure TV30MZ.SoftwareInterrupt(Vector: Byte);
var
  NewIP, NewCS: Word;
begin
  State.RepeatActive := False;
  Push(State.Flags or $F002);
  State.Flags := (State.Flags and not (V30_IF or V30_TF)) or $8000;
  Push(State.S[1]);
  Push(State.IP);
  NewIP := Mem(0, Vector * 4, True);
  NewCS := Mem(0, Vector * 4 + 2, True);
  State.S[1] := NewCS;
  State.IP := NewIP;
  State.Halted := False;
  Inc(FCost, 25);
  FlushPrefetch;
end;

function TV30MZ.Interrupt(Vector: Byte): Boolean;
begin
  State.Halted := False;
  Result := (State.Flags and V30_IF <> 0) and (State.IRQShadow = 0);
  if not Result then
    Exit;
  FCost := 0;
  FSpent := 0;
  SoftwareInterrupt(Vector);
  Idle(FCost);
  Inc(State.Cycles, Cardinal(FSpent));
end;

procedure TV30MZ.StringOp(Op: Byte);
var
  Wide: Boolean;
  A, B, Port: Word;
  Delta: Integer;
  Again: Boolean;
begin
  State.RepeatActive := False;
  if (FRep <> 0) and (State.R[1] = 0) then
    Exit;
  Wide := Odd(Op);
  Delta := 1 + Ord(Wide);
  if State.Flags and V30_DF <> 0 then
    Delta := -Delta;
  case Op and $FE of
    $6C:
      begin
        Port := State.R[2];
        A := PortIn(Port, Wide);
        PutMem(State.S[0], State.R[7], A, Wide);
        Inc(State.R[7], Delta);
      end;
    $6E:
      begin
        A := Mem(DataSeg, State.R[6], Wide);
        Port := State.R[2];
        PortOut(Port, A, Wide);
        Inc(State.R[6], Delta);
      end;
    $A4:
      begin
        A := Mem(DataSeg, State.R[6], Wide);
        PutMem(State.S[0], State.R[7], A, Wide);
        Inc(State.R[6], Delta);
        Inc(State.R[7], Delta);
      end;
    $A6:
      begin
        A := Mem(DataSeg, State.R[6], Wide);
        B := Mem(State.S[0], State.R[7], Wide);
        ALU(7, A, B, Wide);
        Inc(State.R[6], Delta);
        Inc(State.R[7], Delta);
      end;
    $AA:
      begin
        PutMem(State.S[0], State.R[7], RegValue(0, Wide), Wide);
        Inc(State.R[7], Delta);
      end;
    $AC:
      begin
        PutReg(0, Mem(DataSeg, State.R[6], Wide), Wide);
        Inc(State.R[6], Delta);
      end;
    $AE:
      begin
        ALU(7, RegValue(0, Wide), Mem(State.S[0], State.R[7], Wide), Wide);
        Inc(State.R[7], Delta);
      end;
  end;
  Inc(FCost, 3);
  if FRep <> 0 then
  begin
    Dec(State.R[1]);
    Again := State.R[1] <> 0;
    if (Op and $FE = $A6) or (Op and $FE = $AE) then
      Again := Again and ((State.Flags and V30_ZF <> 0) = (FRep = $F3));
    if Again then
    begin
      State.RepeatActive := True;
      State.RepeatIP := FStartIP;
      State.RepeatCS := State.S[1];
      State.RepeatNextIP := State.IP;
      State.RepeatOp := Op;
      State.RepeatType := FRep;
      State.RepeatSeg := FSeg;
      State.IP := FStartIP;
    end;
  end;
end;

procedure TV30MZ.Group3(Wide: Boolean);
var
  A, B, V: Word;
  U, Q, Remain: UInt64;
  N, D, SQ, SR: Int64;

  function UnsignedErrorZero: Boolean;
  var
    NegDiv, Hi, AH, Part, Sum: Cardinal;
  begin
    NegDiv := Word(-A);
    Hi := State.R[2];
    AH := State.R[0] shr 8;
    if not Wide then
    begin
      if A = 0 then
        Exit(State.R[0] and $3FC0 = 0);
      NegDiv := (Byte(-A) shl 8) shr 2;
      Hi := Word((State.R[0] and $FFC0) + NegDiv);
      Result := (Hi = 0) or (Word(Hi + NegDiv * 2) = 0);
      Exit;
    end;
    if NegDiv = 0 then
      Exit((Hi and $3FFF = 0) and (AH and $C0 = 0));
    AH := AH and $C0;
    Part := Byte(NegDiv shl 6);
    NegDiv := NegDiv shr 2;
    Sum := AH + Part;
    AH := Byte(Sum);
    Hi := Word(Hi + NegDiv + (Sum shr 8));
    if (Hi or AH) = 0 then
      Exit(True);
    Sum := AH + Part;
    AH := Byte(Sum);
    Hi := Word(Hi + NegDiv + (Sum shr 8));
    Sum := AH + Part;
    AH := Byte(Sum);
    Result := (AH = 0) and (Word(Hi + NegDiv + (Sum shr 8)) = 0);
  end;

begin
  Decode;
  A := Operand(Wide);
  case FReg of
    0:
      begin
        if Wide then
          B := Fetch16
        else
          B := Fetch8;
        ALU(4, A, B, Wide);
      end;
    1:
      ;
    2:
      PutOperand(not A, Wide);
    3:
      PutOperand(ALU(5, 0, A, Wide), Wide);
    4, 5:
      begin
        if FReg = 4 then
          if Wide then
            N := Cardinal(State.R[0]) * UInt64(A)
          else
            N := Byte(State.R[0]) * Cardinal(A)
        else if Wide then
          N := SmallInt(State.R[0]) * Int64(SmallInt(A))
        else
          N := ShortInt(State.R[0]) * Int64(ShortInt(A));
        if Wide then
        begin
          State.R[0] := Word(N);
          State.R[2] := Word(N shr 16);
          if FReg = 4 then
            V := Ord(State.R[2] <> 0)
          else
            V := Ord((N < -32768) or (N > 32767));
        end
        else
        begin
          State.R[0] := Word(N);
          if FReg = 4 then
            V := Ord(N > 255)
          else
            V := Ord((N < -128) or (N > 127));
        end;
        SetFlag(V30_CF, V <> 0);
        SetFlag(V30_OF, V <> 0);
        State.MulOverflow := V <> 0;
        State.Flags := State.Flags and not (V30_AF or V30_PF or V30_SF);
        SetFlag(V30_ZF, (FReg = 5) or HardwareColor);
        Inc(FCost, 3);
      end;
    6, 7:
      begin
        State.Flags := State.Flags and not (V30_AF or V30_PF or V30_SF or V30_CF or V30_OF);
        if not Wide then
        begin
          SetFlag(V30_CF, State.MulOverflow);
          SetFlag(V30_OF, State.MulOverflow);
        end;
        if (FReg = 7) and (A = 0) then
        begin
          if Wide and (State.R[2] = $8000) and (State.R[0] = 0) then
          begin
            State.R[0] := $8001;
            State.R[2] := 0;
            SetFlag(V30_ZF, True);
            Exit;
          end;
          if not Wide and (State.R[0] = $8000) then
          begin
            State.R[0] := $81;
            SZP($81, False);
            SetFlag(V30_CF, False);
            SetFlag(V30_OF, False);
            Exit;
          end;
        end;
        if A = 0 then
        begin
          if FReg = 6 then
            SetFlag(V30_ZF, UnsignedErrorZero);
          SoftwareInterrupt(0);
          Exit;
        end;
        if FReg = 6 then
        begin
          if Wide then
            U := (Cardinal(State.R[2]) shl 16) or State.R[0]
          else
            U := State.R[0];
          Q := U div A;
          Remain := U mod A;
          if (Wide and (Q > $FFFF)) or (not Wide and (Q > $FF)) then
          begin
            SetFlag(V30_ZF, UnsignedErrorZero);
            SoftwareInterrupt(0);
            Exit;
          end;
          if Wide then
          begin
            State.R[0] := Q;
            State.R[2] := Remain;
          end
          else
            State.R[0] := Word(Q or (Remain shl 8));
          SetFlag(V30_ZF, (Remain = 0) and Odd(Q));
        end
        else
        begin
          if Wide then
          begin
            N := Integer((Cardinal(State.R[2]) shl 16) or State.R[0]);
            D := SmallInt(A);
          end
          else
          begin
            N := SmallInt(State.R[0]);
            D := ShortInt(A);
          end;
          SQ := N div D;
          SR := N mod D;
          if (Wide and ((SQ < -32767) or (SQ > 32767))) or
            (not Wide and ((SQ < -127) or (SQ > 127))) then
          begin
            SoftwareInterrupt(0);
            Exit;
          end;
          if Wide then
          begin
            State.R[0] := Word(SQ);
            State.R[2] := Word(SR);
            SetFlag(V30_ZF, (SR = 0) and Odd(SQ));
          end
          else
          begin
            State.R[0] := Byte(SQ) or (Word(Byte(SR)) shl 8);
            SZP(Byte(SQ), False);
            SetFlag(V30_CF, False);
            SetFlag(V30_OF, False);
          end;
        end;
        Inc(FCost, 22);
      end;
  end;
end;

function TV30MZ.Step: Integer;
var
  Op: Byte;
  A, B, V, Temp, Port, CF, NewIP, NewCS: Word;
  Wide, Trap, Taken: Boolean;
  Kind, Count, Delta: Integer;
  SignedProduct: Int64;
begin
  FSpent := 0;
  if State.Halted then
  begin
    Idle(1);
    Inc(State.Cycles);
    Exit(1);
  end;
  Trap := State.Flags and V30_TF <> 0;
  if State.IRQShadow > 0 then
    Dec(State.IRQShadow);
  FCost := 1;
  FSeg := -1;
  FRep := 0;
  FStartIP := State.IP;
  Count := 0;
  if State.RepeatActive and (State.RepeatIP = State.IP) and (State.RepeatCS = State.S[1]) then
  begin
    Op := State.RepeatOp;
    FSeg := State.RepeatSeg;
    FRep := State.RepeatType;
    State.IP := State.RepeatNextIP;
  end
  else
  begin
    State.RepeatActive := False;
    repeat
      Op := Fetch8;
      Inc(Count);
      case Op of
        $26:
          FSeg := 0;
        $2E:
          FSeg := 1;
        $36:
          FSeg := 2;
        $3E:
          FSeg := 3;
        $F2, $F3:
          FRep := Op;
        $F0:
          ;
      else
        Break;
      end;
      Inc(FCost);
    until Count >= 16;
  end;
  Wide := Odd(Op);
  if (Op <= $3D) and (Op and 7 <= 5) then
  begin
    Kind := Op shr 3;
    if Op and 7 >= 4 then
    begin
      A := RegValue(0, Wide);
      if Wide then
        B := Fetch16
      else
        B := Fetch8;
      V := ALU(Kind, A, B, Wide);
      if Kind <> 7 then
        PutReg(0, V, Wide);
    end
    else
    begin
      Decode;
      if Op and 2 = 0 then
      begin
        A := Operand(Wide);
        B := RegValue(FReg, Wide);
      end
      else
      begin
        A := RegValue(FReg, Wide);
        B := Operand(Wide);
      end;
      V := ALU(Kind, A, B, Wide);
      if Kind <> 7 then
        if Op and 2 = 0 then
          PutOperand(V, Wide)
        else
          PutReg(FReg, V, Wide);
    end;
  end
  else
    case Op of
      $06, $0E, $16, $1E:
        begin
          Push(State.S[Op shr 3]);
          Inc(FCost);
        end;
      $07, $17, $1F:
        begin
          State.S[Op shr 3] := Pop;
          if Op = $17 then
            State.IRQShadow := 1;
          Inc(FCost, 2);
        end;
      $27, $2F:
        begin
          A := Byte(State.R[0]);
          B := A;
          CF := State.Flags and V30_CF;
          Taken := False;
          if ((A and 15) > 9) or (State.Flags and V30_AF <> 0) then
          begin
            V := A;
            if Op = $27 then
              A := Byte(A + 6)
            else
              A := Byte(A - 6);
            if Op = $27 then
              Temp := A
            else
              Temp := V;
            Taken := ((A xor V) and (Temp xor 6) and $80) <> 0;
            SetFlag(V30_AF, True);
          end
          else
            SetFlag(V30_AF, False);
          if (B > $99) or (CF <> 0) then
          begin
            V := A;
            if Op = $27 then
              A := Byte(A + $60)
            else
              A := Byte(A - $60);
            if Op = $27 then
              Temp := A
            else
              Temp := V;
            Taken := Taken or (((A xor V) and (Temp xor $60) and $80) <> 0);
            SetFlag(V30_CF, True);
          end
          else
            SetFlag(V30_CF, False);
          SetFlag(V30_OF, Taken);
          PutReg(0, A, False);
          SZP(A, False);
          Inc(FCost, 9);
        end;
      $37, $3F:
        begin
          A := Byte(State.R[0]);
          B := State.R[0] shr 8;
          Taken := ((A and 15) > 9) or (State.Flags and V30_AF <> 0);
          if Taken then
            if Op = $37 then
            begin
              A := Byte(A + 6);
              B := Byte(B + 1);
            end
            else
            begin
              A := Byte(A - 6);
              B := Byte(B - 1);
            end;
          State.R[0] := (B shl 8) or (A and 15);
          SetFlag(V30_AF, Taken);
          SetFlag(V30_CF, Taken);
          SetFlag(V30_ZF, Taken);
          SetFlag(V30_SF, not Taken);
          SetFlag(V30_PF, True);
          SetFlag(V30_OF, False);
          Inc(FCost, 8);
        end;
      $40..$4F:
        begin
          CF := State.Flags and V30_CF;
          if Op < $48 then
            V := ALU(0, State.R[Op and 7], 1, True)
          else
            V := ALU(5, State.R[Op and 7], 1, True);
          State.R[Op and 7] := V;
          SetFlag(V30_CF, CF <> 0);
        end;
      $50..$57:
        begin
          FCost := 0;
          V := State.R[Op and 7];
          if Op = $54 then
            Dec(V, 2);
          Push(V);
        end;
      $58..$5F:
        begin
          FCost := 0;
          State.R[Op and 7] := Pop;
        end;
      $60:
        begin
          Temp := State.R[4];
          for var I := 0 to 7 do
            if I = 4 then
              Push(Temp)
            else
              Push(State.R[I]);
          Inc(FCost, 8);
        end;
      $61:
        begin
          for var I := 7 downto 0 do
          begin
            V := Pop;
            if I <> 4 then
              State.R[I] := V;
          end;
          Inc(FCost, 7);
        end;
      $62:
        begin
          Decode;
          A := Mem(FSegment, FOffset, True);
          B := Mem(FSegment, FOffset + 2, True);
          V := State.R[FReg];
          if (SmallInt(V) < SmallInt(A)) or (SmallInt(V) > SmallInt(B)) then
          begin
            SoftwareInterrupt(5);
          end;
          Inc(FCost, 12);
        end;
      $68:
        begin
          Push(Fetch16);
        end;
      $6A:
        begin
          V := Word(SmallInt(ShortInt(Fetch8)));
          Push(V);
        end;
      $69, $6B:
        begin
          Decode;
          A := Operand(True);
          if Op = $69 then
            B := Fetch16
          else
            B := Word(SmallInt(ShortInt(Fetch8)));
          SignedProduct := Int64(SmallInt(A)) * SmallInt(B);
          State.R[FReg] := Word(SignedProduct);
          Taken := (SignedProduct < -32768) or (SignedProduct > 32767);
          SetFlag(V30_CF, Taken);
          SetFlag(V30_OF, Taken);
          State.MulOverflow := Taken;
          State.Flags := State.Flags and not (V30_AF or V30_PF or V30_SF);
          SetFlag(V30_ZF, True);
          Inc(FCost, 3);
        end;
      $6C..$6F, $A4..$A7, $AA..$AF:
        StringOp(Op);
      $70..$7F:
        begin
          Delta := ShortInt(Fetch8);
          if Condition(Op and 15) then
          begin
            Inc(State.IP, Delta);
            Inc(FCost, 2);
          end;
        end;
      $80..$83:
        begin
          Wide := Op and 1 <> 0;
          Decode;
          A := Operand(Wide);
          if Op = $81 then
            B := Fetch16
          else if Op = $83 then
            B := Word(SmallInt(ShortInt(Fetch8)))
          else
            B := Fetch8;
          V := ALU(FReg, A, B, Wide);
          if FReg <> 7 then
            PutOperand(V, Wide);
        end;
      $84, $85:
        begin
          Decode;
          ALU(4, Operand(Wide), RegValue(FReg, Wide), Wide);
        end;
      $86, $87:
        begin
          Decode;
          A := Operand(Wide);
          B := RegValue(FReg, Wide);
          PutOperand(B, Wide);
          PutReg(FReg, A, Wide);
          Inc(FCost, 2);
        end;
      $88..$8B:
        begin
          Decode;
          if Op and 2 = 0 then
            PutOperand(RegValue(FReg, Wide), Wide)
          else
            PutReg(FReg, Operand(Wide), Wide);
        end;
      $8C:
        begin
          Decode;
          PutOperand(State.S[FReg and 3], True);
        end;
      $8D:
        begin
          Decode;
          MemoryRegisterEA;
          State.R[FReg] := FOffset;
        end;
      $8E:
        begin
          Decode;
          State.S[FReg and 3] := Operand(True);
          if FReg and 3 = 2 then
            State.IRQShadow := 1;
        end;
      $8F:
        begin
          Decode;
          V := Pop;
          PutOperand(V, True);
        end;
      $90..$97:
        begin
          V := State.R[0];
          State.R[0] := State.R[Op and 7];
          State.R[Op and 7] := V;
        end;
      $98:
        State.R[0] := Word(SmallInt(ShortInt(State.R[0])));
      $99:
        if State.R[0] and $8000 <> 0 then
          State.R[2] := $FFFF
        else
          State.R[2] := 0;
      $9A:
        begin
          NewIP := Fetch16;
          NewCS := Fetch16;
          Push(State.S[1]);
          Push(State.IP);
          State.IP := NewIP;
          State.S[1] := NewCS;
          Inc(FCost, 6);
        end;
      $9B:
        Inc(FCost, 8);
      $9C:
        Push(State.Flags or $F002);
      $9D:
        LoadFlags(Pop);
      $9E:
        State.Flags := (State.Flags and $FF00) or (RegValue(4, False) and $D5) or 2;
      $9F:
        PutReg(4, (State.Flags and $D5) or 2, False);
      $A0..$A3:
        begin
          V := Fetch16;
          if Op and 2 = 0 then
            PutReg(0, Mem(DataSeg, V, Wide), Wide)
          else
            PutMem(DataSeg, V, RegValue(0, Wide), Wide);
        end;
      $A8, $A9:
        begin
          if Wide then
            V := Fetch16
          else
            V := Fetch8;
          ALU(4, RegValue(0, Wide), V, Wide);
        end;
      $B0..$BF:
        begin
          Wide := Op >= $B8;
          if Wide then
            V := Fetch16
          else
            V := Fetch8;
          PutReg(Op and 7, V, Wide);
        end;
      $C0, $C1, $D0..$D3:
        begin
          Decode;
          A := Operand(Wide);
          case Op and $FE of
            $C0:
              Count := Fetch8;
            $D0:
              Count := 1;
          else
            Count := Byte(State.R[1]);
          end;
          PutOperand(Shift(FReg, A, Count, Wide), Wide);
        end;
      $C2, $C3:
        begin
          V := 0;
          if Op = $C2 then
            V := Fetch16;
          State.IP := Pop;
          Inc(State.R[4], V);
          Inc(FCost, 3);
        end;
      $C4, $C5:
        begin
          Decode;
          MemoryRegisterEA;
          A := Mem(FSegment, FOffset, True);
          if Op = $C4 then
            Kind := 0
          else
            Kind := 3;
          B := Mem(FSegment, FOffset + 2, True);
          State.R[FReg] := A;
          State.S[Kind] := B;
          Inc(FCost, 3);
        end;
      $C6, $C7:
        begin
          Decode;
          if Wide then
            V := Fetch16
          else
            V := Fetch8;
          PutOperand(V, Wide);
        end;
      $C8:
        begin
          V := Fetch16;
          Count := Fetch8 and 31;
          Push(State.R[5]);
          Temp := State.R[4];
          if Count > 0 then
          begin
            for var I := 1 to Count - 1 do
              Push(Mem(State.S[2], State.R[5] - I * 2, True));
            Push(Temp);
          end;
          State.R[5] := Temp;
          Dec(State.R[4], V);
          Inc(FCost, 6 + Count * 2);
        end;
      $C9:
        begin
          State.R[4] := State.R[5];
          State.R[5] := Pop;
          Inc(FCost);
        end;
      $CA, $CB:
        begin
          V := 0;
          if Op = $CA then
            V := Fetch16;
          State.IP := Pop;
          State.S[1] := Pop;
          Inc(State.R[4], V);
          Inc(FCost, 5);
        end;
      $CC:
        SoftwareInterrupt(3);
      $CD:
        begin
          V := Fetch8;
          SoftwareInterrupt(V);
        end;
      $CE:
        if State.Flags and V30_OF <> 0 then
          SoftwareInterrupt(4);
      $CF:
        begin
          State.IP := Pop;
          State.S[1] := Pop;
          LoadFlags(Pop);
          Inc(FCost, 5);
        end;
      $D4:
        begin
          V := Fetch8;
          A := Byte(State.R[0]);
          State.Flags := State.Flags and not (V30_AF or V30_PF or V30_SF or V30_CF or V30_OF);
          if V = 0 then
          begin
            SetFlag(V30_ZF, A and $C0 = 0);
            SetFlag(V30_CF, State.MulOverflow);
            SetFlag(V30_OF, State.MulOverflow);
            SoftwareInterrupt(0);
          end
          else
          begin
            State.R[0] := ((A div V) shl 8) or (A mod V);
            SZP(Byte(State.R[0]), False);
          end;
          Inc(FCost, 15);
        end;
      $D5:
        begin
          V := Fetch8;
          A := Byte((State.R[0] shr 8) * V);
          B := Byte(State.R[0]);
          State.R[0] := ALU(0, A, B, False);
          Inc(FCost, 5);
        end;
      $D6:
        if State.Flags and V30_CF <> 0 then
          PutReg(0, $FF, False)
        else
          PutReg(0, 0, False);
      $D7:
        PutReg(0, Mem(DataSeg, State.R[3] + Byte(State.R[0]), False), False);
      $D8..$DF:
        begin
          Fetch8;
        end;
      $E0..$E3:
        begin
          Delta := ShortInt(Fetch8);
          if Op = $E3 then
            Taken := State.R[1] = 0
          else
          begin
            Dec(State.R[1]);
            Taken := State.R[1] <> 0;
            if Op = $E0 then
              Taken := Taken and (State.Flags and V30_ZF = 0);
            if Op = $E1 then
              Taken := Taken and (State.Flags and V30_ZF <> 0);
          end;
          if Taken then
          begin
            Inc(State.IP, Delta);
            Inc(FCost, 3);
          end;
        end;
      $E4..$E7, $EC..$EF:
        begin
          if Op < $E8 then
            Port := Fetch8
          else
            Port := State.R[2];
          if Op and 2 = 0 then
          begin
            if Op < $E8 then
              Idle(5)
            else
              Idle(4);
            A := PortIn(Port, Wide);
            PutReg(0, A, Wide);
            FCost := 1;
          end
          else
          begin
            if Op < $E8 then
              Idle(6)
            else
              Idle(4);
            PortOut(Port, RegValue(0, Wide), Wide);
            FCost := 0;
          end;
        end;
      $E8:
        begin
          V := Fetch16;
          Push(State.IP);
          Inc(State.IP, SmallInt(V));
          Inc(FCost, 2);
        end;
      $E9:
        begin
          V := Fetch16;
          Inc(State.IP, SmallInt(V));
          Inc(FCost, 2);
        end;
      $EA:
        begin
          NewIP := Fetch16;
          NewCS := Fetch16;
          State.IP := NewIP;
          State.S[1] := NewCS;
          Inc(FCost, 5);
        end;
      $EB:
        begin
          Delta := ShortInt(Fetch8);
          Inc(State.IP, Delta);
          Inc(FCost, 2);
        end;
      $F1:
        Inc(State.InvalidCount);
      $F4:
        State.Halted := True;
      $F5:
        State.Flags := State.Flags xor V30_CF;
      $F6, $F7:
        Group3(Wide);
      $F8:
        SetFlag(V30_CF, False);
      $F9:
        SetFlag(V30_CF, True);
      $FA:
        SetFlag(V30_IF, False);
      $FB:
        if State.Flags and V30_IF = 0 then
        begin
          SetFlag(V30_IF, True);
          State.IRQShadow := 1;
        end;
      $FC:
        SetFlag(V30_DF, False);
      $FD:
        SetFlag(V30_DF, True);
      $FE, $FF:
        begin
          Decode;
          A := Operand(Wide);
          case FReg of
            0, 1:
              begin
                CF := State.Flags and V30_CF;
                if FReg = 0 then
                  V := ALU(0, A, 1, Wide)
                else
                  V := ALU(5, A, 1, Wide);
                PutOperand(V, Wide);
                SetFlag(V30_CF, CF <> 0);
              end;
            2:
              begin
                Push(State.IP);
                State.IP := A;
                Inc(FCost, 3);
              end;
            3:
              begin
                Push(State.S[1]);
                Push(State.IP);
                MemoryRegisterEA;
                A := Operand(True);
                B := Mem(FSegment, FOffset + 2, True);
                State.IP := A;
                State.S[1] := B;
                Inc(FCost, 6);
              end;
            4:
              begin
                State.IP := A;
                Inc(FCost, 3);
              end;
            5:
              begin
                MemoryRegisterEA;
                A := Operand(True);
                State.S[1] := Mem(FSegment, FOffset + 2, True);
                State.IP := A;
                Inc(FCost, 6);
              end;
            6:
              Push(Operand(True));
          else
            Inc(State.InvalidCount);
          end;
        end;
    else
      Inc(State.InvalidCount);
    end;
  if Trap and (State.Flags and V30_TF <> 0) and (State.IRQShadow = 0) then
    SoftwareInterrupt(1);
  Idle(FCost);
  Result := FSpent;
  Inc(State.Cycles, Cardinal(Result));
end;

procedure TV30MZ.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  if Archive.Loading then
  begin
    State.Flags := (State.Flags and $8FD5) or $7002;
    if (State.QueueCount > 16) or (State.QueueHead > 15) then
      raise EReadError.Create('Invalid V30MZ prefetch state');
    if (State.RepeatSeg < -1) or (State.RepeatSeg > 3) then
      raise EReadError.Create('Invalid V30MZ repeat segment');
    if State.IRQShadow > 1 then
      raise EReadError.Create('Invalid V30MZ interrupt state');
  end;
end;

end.

