unit S16.I8751;

// Intel 8051/8751 interpreter. One returned cycle is twelve oscillator clocks.
// ISA and timer modes follow Intel MCS-51 User's Manual (272383-002).
interface

uses
  System.SysUtils, Core.Snapshots;

type
  TMCURead = function(Address: Word): Byte of object;

  TMCUWrite = procedure(Address: Word; Value: Byte) of object;

  TMCUPortRead = function(Port: Byte): Byte of object;

  TMCUPortWrite = procedure(Port, Value: Byte) of object;

  TS16I8751 = class
  private
    FCode: TBytes;
    FData: array[0..255] of Byte;
    FPC: Word;
    FIRQ: array[0..1] of Boolean;
    FPriority: Integer;
    FPreviousPriority: array[0..1] of Integer;
    FDepth, FIRQBlock: Integer;
    FCycles: Int64;
    function Fetch: Byte;
    function Code(Address: Word): Byte;
    function ReadData(Address: Byte; Latch: Boolean = False): Byte;
    procedure WriteData(Address, Value: Byte);
    function ReadIndirect(Address: Byte): Byte;
    procedure WriteIndirect(Address, Value: Byte);
    function GetBit(Address: Byte; Latch: Boolean = False): Boolean;
    procedure PutBit(Address: Byte; Value: Boolean);
    procedure Carry(Value: Boolean);
    function Reg(Index: Byte): Byte;
    procedure SetReg(Index, Value: Byte);
    procedure Push(Value: Byte);
    function Pop: Byte;
    procedure PushPC;
    procedure ReturnPC;
    procedure Branch(Condition: Boolean);
    procedure Add(Value: Byte; WithCarry, Subtract: Boolean);
    procedure Tick(Cycles: Integer);
    function Interrupt: Boolean;
  public
    ReadExternal: TMCURead;
    WriteExternal: TMCUWrite;
    ReadPort: TMCUPortRead;
    WritePort: TMCUPortWrite;
    constructor Create(const Firmware: TBytes);
    procedure Reset;
    procedure SetIRQ(Line: Integer; Asserted: Boolean);
    function Step: Integer;
    procedure SerializeState(State: TStateArchive);
    property PC: Word read FPC;
    property Cycles: Int64 read FCycles;
  end;

implementation

constructor TS16I8751.Create(const Firmware: TBytes);
begin
  inherited Create;
  if Length(Firmware) <> $1000 then
    raise EArgumentException.Create('8751 requires a 4 KiB firmware ROM');
  FCode := Copy(Firmware);
  Reset;
end;

procedure TS16I8751.Reset;
begin
  FillChar(FData, SizeOf(FData), 0);
  FData[$81] := 7;
  for var P := 0 to 3 do
    FData[$80 + P * 16] := $FF;
  FPC := 0;
  FCycles := 0;
  FPriority := -1;
  FDepth := 0;
  FIRQBlock := 0;
  FillChar(FPreviousPriority, SizeOf(FPreviousPriority), 0);
  FillChar(FIRQ, SizeOf(FIRQ), 0);
end;

function TS16I8751.Code(Address: Word): Byte;
begin
  Result := $FF;
  if Address < Length(FCode) then
    Result := FCode[Address];
end;

function TS16I8751.Fetch: Byte;
begin
  Result := Code(FPC);
  FPC := Word((Cardinal(FPC) + 1) and $FFFF);
end;

function TS16I8751.ReadData(Address: Byte; Latch: Boolean): Byte;
begin
  Result := FData[Address];
  if not Latch and (Address in [$80, $90, $A0, $B0]) and Assigned(ReadPort) then
    Result := Result and ReadPort((Address - $80) shr 4);
  if not Latch and (Address = $B0) then
  begin
    if FIRQ[0] then
      Result := Result and $FB;
    if FIRQ[1] then
      Result := Result and $F7;
  end;
end;

procedure TS16I8751.WriteData(Address, Value: Byte);
begin
  FData[Address] := Value;
  if (Address in [$80, $90, $A0, $B0]) and Assigned(WritePort) then
    WritePort((Address - $80) shr 4, Value);
  if Address in [$A8, $B8] then
    FIRQBlock := 1;
end;

function TS16I8751.ReadIndirect(Address: Byte): Byte;
begin
  Result := $FF;
  if Address < $80 then
    Result := FData[Address];
end;

procedure TS16I8751.WriteIndirect(Address, Value: Byte);
begin
  if Address < $80 then
    FData[Address] := Value;
end;

function TS16I8751.GetBit(Address: Byte; Latch: Boolean): Boolean;
var
  B: Byte;
begin
  if Address < $80 then
    B := $20 + (Address shr 3)
  else
    B := Address and $F8;
  Result := ReadData(B, Latch) and (1 shl (Address and 7)) <> 0;
end;

procedure TS16I8751.PutBit(Address: Byte; Value: Boolean);
var
  B, V: Byte;
begin
  if Address < $80 then
    B := $20 + (Address shr 3)
  else
    B := Address and $F8;
  V := ReadData(B, True) and not (1 shl (Address and 7));
  if Value then
    V := V or (1 shl (Address and 7));
  WriteData(B, V);
end;

procedure TS16I8751.Carry(Value: Boolean);
begin
  PutBit($D7, Value);
end;

function TS16I8751.Reg(Index: Byte): Byte;
begin
  Result := FData[(FData[$D0] and $18) or (Index and 7)];
end;

procedure TS16I8751.SetReg(Index, Value: Byte);
begin
  FData[(FData[$D0] and $18) or (Index and 7)] := Value;
end;

procedure TS16I8751.Push(Value: Byte);
begin
  FData[$81] := Byte((Integer(FData[$81]) + 1) and $FF);
  WriteIndirect(FData[$81], Value);
end;

function TS16I8751.Pop: Byte;
begin
  Result := ReadIndirect(FData[$81]);
  FData[$81] := Byte((Integer(FData[$81]) - 1) and $FF);
end;

procedure TS16I8751.PushPC;
begin
  Push(Byte(FPC and $FF));
  Push(Byte(FPC shr 8));
end;

procedure TS16I8751.ReturnPC;
begin
  var H := Pop;
  FPC := (Word(H) shl 8) or Pop;
end;

procedure TS16I8751.Branch(Condition: Boolean);
begin
  var R := Fetch;
  if Condition then
    FPC := Word((Integer(FPC) + ShortInt(R)) and $FFFF);
end;

procedure TS16I8751.Add(Value: Byte; WithCarry, Subtract: Boolean);
var
  A, C, R: Integer;
begin
  A := FData[$E0];
  C := 0;
  if WithCarry and GetBit($D7) then
    C := 1;
  if Subtract then
    R := A - Value - C
  else
    R := A + Value + C;
  Carry((R < 0) or (R > 255));
  if Subtract then
  begin
    PutBit($D6, (A and 15) < (Value and 15) + C);
    PutBit($D2, ((A xor Value) and (A xor R) and $80) <> 0);
  end
  else
  begin
    PutBit($D6, (A and 15) + (Value and 15) + C > 15);
    PutBit($D2, ((not (A xor Value)) and (A xor R) and $80) <> 0);
  end;
  FData[$E0] := Byte(R and $FF);
end;

procedure TS16I8751.SetIRQ(Line: Integer; Asserted: Boolean);
begin
  if not (Line in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('8751 IRQ line');
  var Mask := 1 shl (Line * 2 + 1);
  if FData[$88] and (Mask shr 1) = 0 then
  begin
    if Asserted then
      FData[$88] := FData[$88] or Mask
    else
      FData[$88] := FData[$88] and not Mask;
  end
  else if Asserted and not FIRQ[Line] then
    FData[$88] := FData[$88] or Mask;
  FIRQ[Line] := Asserted;
end;

procedure TS16I8751.Tick(Cycles: Integer);
var
  Mode, N, Count, LowReg, HighReg, Flag: Integer;
begin
  for var Cycle := 1 to Cycles do
  begin
    // External interrupts are sampled even when the selected mode changes.
    for var Line := 0 to 1 do
      if FData[$88] and (1 shl (Line * 2)) = 0 then
      begin
        if FIRQ[Line] then
          FData[$88] := FData[$88] or (2 shl (Line * 2))
        else
          FData[$88] := FData[$88] and not (2 shl (Line * 2));
      end;
    for N := 0 to 1 do
    begin
      Mode := (FData[$89] shr (N * 4)) and 15;
      if FData[$88] and ($10 shl (N * 2)) = 0 then
        Continue;
      if ((Mode and 8) <> 0) and FIRQ[N] then
        Continue;
      if Mode and 4 <> 0 then
        Continue; // T0/T1 have no external clock on these boards.
      LowReg := $8A + N;
      HighReg := $8C + N;
      Flag := $20 shl (N * 2);
      if (N = 1) and (FData[$89] and 3 = 3) then
        Continue;
      case Mode and 3 of
        0:
          Count := (FData[HighReg] shl 5) or (FData[LowReg] and 31);
        1:
          Count := (FData[HighReg] shl 8) or FData[LowReg];
      else
        Count := FData[LowReg];
      end;
      Inc(Count);
      case Mode and 3 of
        0:
          begin
            if Count > $1FFF then
              FData[$88] := FData[$88] or Flag;
            FData[LowReg] := (FData[LowReg] and $E0) or (Count and 31);
            FData[HighReg] := Byte((Count shr 5) and $FF);
          end;
        1:
          begin
            if Count > $FFFF then
              FData[$88] := FData[$88] or Flag;
            FData[LowReg] := Byte(Count and $FF);
            FData[HighReg] := Byte((Count shr 8) and $FF);
          end;
        2:
          begin
            if Count > 255 then
            begin
              Count := FData[HighReg];
              FData[$88] := FData[$88] or Flag;
            end;
            FData[LowReg] := Byte(Count);
          end;
        3:
          if N = 0 then
          begin
            if Count > 255 then
              FData[$88] := FData[$88] or Flag;
            FData[LowReg] := Byte(Count and $FF);
          end;
      end;
    end;
    // Split timer zero: TH0 is controlled by TR1, with overflow on TF1.
    if (FData[$89] and 3 = 3) and (FData[$88] and $40 <> 0) then
    begin
      Count := Integer(FData[$8C]) + 1;
      if Count > 255 then
        FData[$88] := FData[$88] or $80;
      FData[$8C] := Byte(Count and $FF);
    end;
  end;
  Inc(FCycles, Cycles);
end;

function TS16I8751.Interrupt: Boolean;
const
  Vectors: array[0..4] of Word = (3, $B, $13, $1B, $23);
var
  Pending: Integer;
begin
  Result := False;
  if (FData[$A8] and $80 = 0) or (FIRQBlock > 0) then
    Exit;
  Pending := 0;
  if FData[$88] and 2 <> 0 then
    Pending := Pending or 1;
  if FData[$88] and $20 <> 0 then
    Pending := Pending or 2;
  if FData[$88] and 8 <> 0 then
    Pending := Pending or 4;
  if FData[$88] and $80 <> 0 then
    Pending := Pending or 8;
  if FData[$98] and 3 <> 0 then
    Pending := Pending or 16;
  Pending := Pending and FData[$A8];
  for var Level := 1 downto 0 do
    if Level > FPriority then
      for var I := 0 to 4 do
        if ((Pending and (1 shl I)) <> 0) and
          (Ord(FData[$B8] and (1 shl I) <> 0) = Level) then
        begin
          FPreviousPriority[FDepth] := FPriority;
          Inc(FDepth);
          FPriority := Level;
          if I in [1, 3] then
            FData[$88] := FData[$88] and not (1 shl (I + 4));
          if (I = 0) and (FData[$88] and 1 <> 0) then
            FData[$88] := FData[$88] and not 2;
          if (I = 2) and (FData[$88] and 4 <> 0) then
            FData[$88] := FData[$88] and not 8;
          FData[$87] := FData[$87] and not 1;
          PushPC;
          FPC := Vectors[I];
          Tick(2);
          Exit(True);
        end;
end;

function TS16I8751.Step: Integer;
const
  Cycles: array[0..255] of Byte = (
    1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 1, 2, 4, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 1, 1, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1);
var
  Op, V, D, A, B, R: Byte;
  W: Word;
  T, Extra: Integer;
begin
  Extra := 0;
  if Interrupt then
    Extra := 2;
  if FIRQBlock > 0 then
    Dec(FIRQBlock);
  if FData[$87] and 3 <> 0 then
  begin
    Tick(1);
    Exit(1 + Extra);
  end;
  Op := Fetch;
  Result := Cycles[Op];
  A := FData[$E0];
  R := Op and 7;
  // The regular register/indirect/immediate arithmetic groups share addressing.
  if ((Op and $F0) in [$20, $30, $40, $50, $60, $90]) and (Op and 15 >= 4) then
  begin
    case Op and 15 of
      4:
        V := Fetch;
      5:
        V := ReadData(Fetch);
      6, 7:
        V := ReadIndirect(Reg(Op and 1));
    else
      V := Reg(R);
    end;
    case Op and $F0 of
      $20:
        Add(V, False, False);
      $30:
        Add(V, True, False);
      $40:
        FData[$E0] := A or V;
      $50:
        FData[$E0] := A and V;
      $60:
        FData[$E0] := A xor V;
      $90:
        Add(V, True, True);
    end;
  end
  else if Op and $1F in [1, $11] then
  begin
    V := Fetch;
    if Op and $10 <> 0 then
      PushPC;
    FPC := (FPC and $F800) or (Word(Op and $E0) shl 3) or V;
  end
  else
    case Op of
      $00:
        ;
      $02, $12:
        begin
          V := Fetch;
          W := (Word(V) shl 8) or Fetch;
          if Op = $12 then
            PushPC;
          FPC := W;
        end;
      $03:
        FData[$E0] := Byte(((A shr 1) or (A shl 7)) and $FF);
      $04:
        FData[$E0] := Byte((Integer(A) + 1) and $FF);
      $05:
        begin
          D := Fetch;
          WriteData(D, Byte((Integer(ReadData(D, True)) + 1) and $FF));
        end;
      $06, $07:
        begin
          D := Reg(Op and 1);
          WriteIndirect(D, Byte((Integer(ReadIndirect(D)) + 1) and $FF));
        end;
      $08..$0F:
        SetReg(R, Byte((Integer(Reg(R)) + 1) and $FF));
      $10:
        begin
          D := Fetch;
          B := Ord(GetBit(D, True));
          Branch(B <> 0);
          if B <> 0 then
            PutBit(D, False);
        end;
      $13:
        begin
          FData[$E0] := (A shr 1) or (Ord(GetBit($D7)) shl 7);
          Carry(A and 1 <> 0);
        end;
      $14:
        FData[$E0] := Byte((Integer(A) - 1) and $FF);
      $15:
        begin
          D := Fetch;
          WriteData(D, Byte((Integer(ReadData(D, True)) - 1) and $FF));
        end;
      $16, $17:
        begin
          D := Reg(Op and 1);
          WriteIndirect(D, Byte((Integer(ReadIndirect(D)) - 1) and $FF));
        end;
      $18..$1F:
        SetReg(R, Byte((Integer(Reg(R)) - 1) and $FF));
      $20:
        begin
          D := Fetch;
          Branch(GetBit(D));
        end;
      $22, $32:
        begin
          ReturnPC;
          if Op = $32 then
          begin
            if FDepth > 0 then
            begin
              Dec(FDepth);
              FPriority := FPreviousPriority[FDepth];
            end;
            FIRQBlock := 1;
          end;
        end;
      $23:
        FData[$E0] := Byte(((A shl 1) or (A shr 7)) and $FF);
      $30:
        begin
          D := Fetch;
          Branch(not GetBit(D));
        end;
      $33:
        begin
          FData[$E0] := Byte(((A shl 1) or Ord(GetBit($D7))) and $FF);
          Carry(A and $80 <> 0);
        end;
      $40:
        Branch(GetBit($D7));
      $42, $52, $62:
        begin
          D := Fetch;
          V := ReadData(D, True);
          case Op of
            $42:
              V := V or A;
            $52:
              V := V and A;
            $62:
              V := V xor A;
          end;
          WriteData(D, V);
        end;
      $43, $53, $63:
        begin
          D := Fetch;
          V := Fetch;
          B := ReadData(D, True);
          case Op of
            $43:
              V := B or V;
            $53:
              V := B and V;
            $63:
              V := B xor V;
          end;
          WriteData(D, V);
        end;
      $50:
        Branch(not GetBit($D7));
      $60:
        Branch(A = 0);
      $70:
        Branch(A <> 0);
      $72:
        begin
          D := Fetch;
          Carry(GetBit($D7) or GetBit(D));
        end;
      $73:
        FPC := Word(((FData[$83] shl 8) + FData[$82] + A) and $FFFF);
      $74:
        FData[$E0] := Fetch;
      $75:
        begin
          D := Fetch;
          WriteData(D, Fetch);
        end;
      $76, $77:
        begin
          V := Fetch;
          WriteIndirect(Reg(Op and 1), V);
        end;
      $78..$7F:
        SetReg(R, Fetch);
      $80:
        Branch(True);
      $82:
        begin
          D := Fetch;
          Carry(GetBit($D7) and GetBit(D));
        end;
      $83:
        FData[$E0] := Code(Word((Cardinal(FPC) + A) and $FFFF));
      $84:
        begin
          B := FData[$F0];
          Carry(False);
          PutBit($D2, B = 0);
          if B <> 0 then
          begin
            FData[$E0] := A div B;
            FData[$F0] := A mod B;
          end;
        end;
      $85:
        begin
          V := ReadData(Fetch);
          D := Fetch;
          WriteData(D, V);
        end;
      $86, $87:
        begin
          D := Fetch;
          WriteData(D, ReadIndirect(Reg(Op and 1)));
        end;
      $88..$8F:
        begin
          D := Fetch;
          WriteData(D, Reg(R));
        end;
      $90:
        begin
          FData[$83] := Fetch;
          FData[$82] := Fetch;
        end;
      $92:
        begin
          D := Fetch;
          PutBit(D, GetBit($D7));
        end;
      $93:
        FData[$E0] := Code(Word(((FData[$83] shl 8) + FData[$82] + A) and $FFFF));
      $A0:
        begin
          D := Fetch;
          Carry(GetBit($D7) or not GetBit(D));
        end;
      $A2:
        Carry(GetBit(Fetch));
      $A3:
        begin
          T := (FData[$83] shl 8) + FData[$82] + 1;
          FData[$82] := Byte(T and $FF);
          FData[$83] := Byte((T shr 8) and $FF);
        end;
      $A4:
        begin
          T := A * FData[$F0];
          FData[$E0] := Byte(T and $FF);
          FData[$F0] := Byte(T shr 8);
          Carry(False);
          PutBit($D2, T > 255);
        end;
      $A5:
        raise EInvalidOpException.CreateFmt('Reserved 8751 opcode A5 at %.4x', [(Integer(FPC) - 1) and $FFFF]);
      $A6, $A7:
        begin
          V := ReadData(Fetch);
          WriteIndirect(Reg(Op and 1), V);
        end;
      $A8..$AF:
        SetReg(R, ReadData(Fetch));
      $B0:
        begin
          D := Fetch;
          Carry(GetBit($D7) and not GetBit(D));
        end;
      $B2:
        begin
          D := Fetch;
          PutBit(D, not GetBit(D, True));
        end;
      $B3:
        Carry(not GetBit($D7));
      $B4..$BF:
        begin
          case Op of
            $B4:
              begin
                B := A;
                V := Fetch;
              end;
            $B5:
              begin
                B := A;
                V := ReadData(Fetch);
              end;
            $B6, $B7:
              begin
                B := ReadIndirect(Reg(Op and 1));
                V := Fetch;
              end;
          else
            B := Reg(R);
            V := Fetch;
          end;
          Carry(B < V);
          Branch(B <> V);
        end;
      $C0:
        begin
          V := ReadData(Fetch);
          Push(V);
        end;
      $C2:
        PutBit(Fetch, False);
      $C3:
        Carry(False);
      $C4:
        FData[$E0] := Byte(((A shr 4) or (A shl 4)) and $FF);
      $C5:
        begin
          D := Fetch;
          FData[$E0] := ReadData(D);
          WriteData(D, A);
        end;
      $C6, $C7:
        begin
          D := Reg(Op and 1);
          FData[$E0] := ReadIndirect(D);
          WriteIndirect(D, A);
        end;
      $C8..$CF:
        begin
          FData[$E0] := Reg(R);
          SetReg(R, A);
        end;
      $D0:
        begin
          D := Fetch;
          WriteData(D, Pop);
        end;
      $D2:
        PutBit(Fetch, True);
      $D3:
        Carry(True);
      $D4:
        begin
          T := A;
          if ((T and 15) > 9) or GetBit($D6) then
            Inc(T, 6);
          if (T > $9F) or GetBit($D7) then
            Inc(T, $60);
          if T > 255 then
            Carry(True);
          FData[$E0] := Byte(T and $FF);
        end;
      $D5:
        begin
          D := Fetch;
          V := Byte((Integer(ReadData(D, True)) - 1) and $FF);
          WriteData(D, V);
          Branch(V <> 0);
        end;
      $D6, $D7:
        begin
          D := Reg(Op and 1);
          V := ReadIndirect(D);
          FData[$E0] := (A and $F0) or (V and 15);
          WriteIndirect(D, (V and $F0) or (A and 15));
        end;
      $D8..$DF:
        begin
          V := Byte((Integer(Reg(R)) - 1) and $FF);
          SetReg(R, V);
          Branch(V <> 0);
        end;
      $E0, $E2, $E3:
        begin
          if Op = $E0 then
            W := (Word(FData[$83]) shl 8) or FData[$82]
          else
            W := (Word(FData[$A0]) shl 8) or Reg(Op and 1);
          FData[$E0] := $FF;
          if Assigned(ReadExternal) then
            FData[$E0] := ReadExternal(W);
        end;
      $E4:
        FData[$E0] := 0;
      $E5:
        FData[$E0] := ReadData(Fetch);
      $E6, $E7:
        FData[$E0] := ReadIndirect(Reg(Op and 1));
      $E8..$EF:
        FData[$E0] := Reg(R);
      $F0, $F2, $F3:
        begin
          if Op = $F0 then
            W := (Word(FData[$83]) shl 8) or FData[$82]
          else
            W := (Word(FData[$A0]) shl 8) or Reg(Op and 1);
          if Assigned(WriteExternal) then
            WriteExternal(W, A);
        end;
      $F4:
        FData[$E0] := not A;
      $F5:
        WriteData(Fetch, A);
      $F6, $F7:
        WriteIndirect(Reg(Op and 1), A);
      $F8..$FF:
        SetReg(R, A);
    end;
  V := FData[$E0];
  V := V xor (V shr 4);
  V := V xor (V shr 2);
  V := V xor (V shr 1);
  FData[$D0] := (FData[$D0] and $FE) or (V and 1);
  Tick(Result);
  Inc(Result, Extra);
end;

procedure TS16I8751.SerializeState(State: TStateArchive);
begin
  State.Field(FData, SizeOf(FData));
  State.Field(FPC, SizeOf(FPC));
  State.Field(FIRQ, SizeOf(FIRQ));
  State.Field(FPriority, SizeOf(FPriority));
  State.Field(FPreviousPriority, SizeOf(FPreviousPriority));
  State.Field(FDepth, SizeOf(FDepth));
  State.Field(FIRQBlock, SizeOf(FIRQBlock));
  State.Field(FCycles, SizeOf(FCycles));
  if (FDepth < 0) or (FDepth > 2) or (FPriority < -1) or (FPriority > 1) or
    (FIRQBlock < 0) or (FIRQBlock > 1) or (FCycles < 0) then
    raise EArgumentException.Create('Invalid 8751 state');
end;

end.

