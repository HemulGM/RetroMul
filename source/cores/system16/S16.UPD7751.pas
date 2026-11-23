unit S16.UPD7751;

// NEC 7751 (MCS-48) plus the System 16A 8243 ROM-address expander and DAC.
// Instruction semantics checked against Intel MCS-48
interface

uses
  System.SysUtils, Core.Snapshots;

type
  TS16UPD7751 = class
  private
    FROM, FData: TBytes;
    FRAM: array[0..63] of Byte;
    FPC, FBank: Word;
    FA, FPSW, FTimer, FP1, FP2, FDAC, FCommand: Byte;
    FReset, FIRQ, FIRQEnabled, FTimerIRQEnabled, FInIRQ, FF1: Boolean;
    FTimerRunning, FTimerFlag, FTimerPending: Boolean;
    FPrescale: Integer;
    FAddress: Cardinal;
    FBalance: Int64;
    function Fetch: Byte;
    procedure Push;
    procedure Pull(WithPSW: Boolean);
    procedure Add(Value: Byte; Carry: Boolean);
    procedure Branch(Taken: Boolean);
    procedure Expander(Port, Operation: Integer);
    procedure Burn(Cycles: Integer);
    function Step: Integer;
  public
    constructor Create(const ROM, Data: TBytes);
    procedure Reset;
    procedure Control(Value: Byte);
    procedure Command(Value: Byte);
    procedure Advance(ZCycles: Integer);
    function Sample: Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

constructor TS16UPD7751.Create(const ROM, Data: TBytes);
begin
  inherited Create;
  if (Length(ROM) < $400) or (Length(Data) = 0) then
    raise EReadError.Create('Missing System 16A 7751 firmware or sample ROM');
  FROM := ROM;
  FData := Data;
  Reset;
end;

procedure TS16UPD7751.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FPC := 0;
  FBank := 0;
  FA := 0;
  FPSW := 0;
  FTimer := 0;
  FP1 := $FF;
  FP2 := $FF;
  FDAC := $80;
  FReset := True;
  FIRQ := False;
  FIRQEnabled := False;
  FTimerIRQEnabled := False;
  FInIRQ := False;
  FF1 := False;
  FTimerRunning := False;
  FTimerFlag := False;
  FTimerPending := False;
  FPrescale := 0;
  FCommand := 0;
  FAddress := 0;
  FBalance := 0;
end;

procedure TS16UPD7751.Control(Value: Byte);
begin
  var AssertReset := Value and 1 = 0;
  if AssertReset and not FReset then
  begin
    var Address := FAddress;
    var Cmd := FCommand;
    Reset;
    FAddress := Address;
    FCommand := Cmd;
  end;
  FReset := AssertReset;
  FIRQ := Value and 2 = 0;
end;

procedure TS16UPD7751.Command(Value: Byte);
begin
  FAddress := (FAddress and $3FFF) or (Cardinal(Value and 1) shl 14);
  var Banks := Length(FData) div $8000;
  for var I := 0 to 3 do
    if (I < Banks) and (Value and (2 shl I) = 0) then
      FAddress := FAddress or Cardinal(I * $8000);
  FCommand := Value shr 5;
end;

function TS16UPD7751.Fetch: Byte;
begin
  Result := $FF;
  if FPC < Length(FROM) then
    Result := FROM[FPC];
  FPC := ((FPC + 1) and $7FF) or (FPC and $800);
end;

procedure TS16UPD7751.Push;
begin
  var SP := FPSW and 7;
  FRAM[8 + SP * 2] := Byte(FPC and $FF);
  FRAM[9 + SP * 2] := Byte((FPC shr 8) or (FPSW and $F0));
  FPSW := (FPSW and $F0) or ((SP + 1) and 7);
end;

procedure TS16UPD7751.Pull(WithPSW: Boolean);
begin
  var SP := (Integer(FPSW) - 1) and 7;
  var HighByte := FRAM[9 + SP * 2];
  FPC := FRAM[8 + SP * 2] or (Word(HighByte and $F) shl 8);
  FPSW := (FPSW and $F0) or SP;
  if WithPSW then
    FPSW := (HighByte and $F0) or SP;
  if FInIRQ then
    FPC := FPC and $7FF;
end;

procedure TS16UPD7751.Add(Value: Byte; Carry: Boolean);
begin
  var C := 0;
  if Carry then
    C := FPSW shr 7;
  var Sum := Integer(FA) + Value + C;
  var Nibble := (FA and $F) + (Value and $F) + C;
  FPSW := (FPSW and $3F) or ((Sum shr 1) and $80) or ((Nibble shl 2) and $40);
  FA := Byte(Sum and $FF);
end;

procedure TS16UPD7751.Branch(Taken: Boolean);
begin
  // Page comes from the PC before fetching the displacement byte.
  var Page := FPC and $F00;
  var Target := Fetch;
  if Taken then
    FPC := Page or Target;
end;

procedure TS16UPD7751.Expander(Port, Operation: Integer);
begin
  var Shift := Port * 4;
  var Mask := Cardinal($F shl Shift) and $3FFF;
  var Value := Cardinal(FA and $F) shl Shift;
  case Operation of
    0:
      FA := Byte((FAddress shr Shift) and $F);
    1:
      FAddress := (FAddress and not Mask) or (Value and Mask);
    2:
      FAddress := FAddress or (Value and Mask);
    3:
      FAddress := FAddress and (not Mask or Value);
  end;
  FP2 := (FP2 and $F0) or (FA and $F);
end;

procedure TS16UPD7751.Burn(Cycles: Integer);
begin
  if FTimerRunning then
  begin
    Inc(FPrescale, Cycles);
    var Value := Integer(FTimer) + (FPrescale shr 5);
    FPrescale := FPrescale and $1F;
    FTimer := Byte(Value and $FF);
    if Value > $FF then
    begin
      FTimerFlag := True;
      if FTimerIRQEnabled then
        FTimerPending := True;
    end;
  end;
end;

function TS16UPD7751.Step: Integer;
begin
  Result := 1;
  if not FInIRQ and ((FIRQ and FIRQEnabled) or (FTimerPending and FTimerIRQEnabled)) then
  begin
    Push;
    FPC := 3;
    if not (FIRQ and FIRQEnabled) then
    begin
      FPC := 7;
      FTimerPending := False;
    end;
    FInIRQ := True;
    Burn(2);
    Exit(2);
  end;
  var Op := Fetch;
  var RBase := 0;
  if FPSW and $10 <> 0 then
    RBase := 24;
  var Reg := RBase + (Op and 7);
  var Indirect := FRAM[RBase + (Op and 1)] and $3F;
  var Temp: Byte;
  case Op of
    $00, $75:
      ;
    $02:
      Result := 2; // External BUS output is unconnected.
      $03:
      begin
        Add(Fetch, False);
        Result := 2;
      end;
    $13:
      begin
        Add(Fetch, True);
        Result := 2;
      end;
    $04, $24, $44, $64, $84, $A4, $C4, $E4, $14, $34, $54, $74, $94, $B4, $D4, $F4:
      begin
        var Address := Word(Fetch) or (Word(Op and $E0) shl 3);
        if Op and $10 <> 0 then
          Push;
        if not FInIRQ then
          Address := Address or FBank;
        FPC := Address;
        Result := 2;
      end;
    $05:
      FIRQEnabled := True;
    $15:
      FIRQEnabled := False;
    $07:
      FA := Byte((Integer(FA) - 1) and $FF);
    $08:
      begin
        FA := $FF;
        if FAddress < Cardinal(Length(FData)) then
          FA := FData[FAddress];
        Result := 2;
      end;
    $09:
      begin
        FA := FP1;
        Result := 2;
      end;
    $0A:
      begin
        FA := ($80 or (FCommand shl 4) or $F) and FP2;
        Result := 2;
      end;
    $0C..$0F:
      begin
        Expander(Op and 3, 0);
        Result := 2;
      end;
    $10, $11:
      FRAM[Indirect] := Byte((Integer(FRAM[Indirect]) + 1) and $FF);
    $12, $32, $52, $72, $92, $B2, $D2, $F2:
      begin
        Branch(FA and (1 shl (Op shr 5)) <> 0);
        Result := 2;
      end;
    $16:
      begin
        Branch(FTimerFlag);
        FTimerFlag := False;
        Result := 2;
      end;
    $17:
      FA := Byte((Integer(FA) + 1) and $FF);
    $18..$1F:
      FRAM[Reg] := Byte((Integer(FRAM[Reg]) + 1) and $FF);
    $20, $21:
      begin
        Temp := FA;
        FA := FRAM[Indirect];
        FRAM[Indirect] := Temp;
      end;
    $23:
      begin
        FA := Fetch;
        Result := 2;
      end;
    $25:
      FTimerIRQEnabled := True;
    $26, $46:
      begin
        Branch(Op = $26);
        Result := 2;
      end; // T0 is grounded.
      $27:
      FA := 0;
    $28..$2F:
      begin
        Temp := FA;
        FA := FRAM[Reg];
        FRAM[Reg] := Temp;
      end;
    $30, $31:
      begin
        Temp := FRAM[Indirect];
        FRAM[Indirect] := (Temp and $F0) or (FA and $F);
        FA := (FA and $F0) or (Temp and $F);
      end;
    $35:
      begin
        FTimerIRQEnabled := False;
        FTimerPending := False;
      end;
    $36, $56:
      begin
        Branch(Op = $36);
        Result := 2;
      end; // T1 is grounded.
      $37:
      FA := FA xor $FF;
    $39:
      begin
        FP1 := FA;
        FDAC := FA;
        Result := 2;
      end;
    $3A:
      begin
        FP2 := FA;
        Result := 2;
      end;
    $3C..$3F:
      begin
        Expander(Op and 3, 1);
        Result := 2;
      end;
    $40, $41:
      FA := FA or FRAM[Indirect];
    $42:
      FA := FTimer;
    $43:
      begin
        FA := FA or Fetch;
        Result := 2;
      end;
    $45:
      FTimerRunning := False; // Counter mode: board T1 is fixed low.
      $47:
      FA := Byte(((FA shl 4) or (FA shr 4)) and $FF);
    $48..$4F:
      FA := FA or FRAM[Reg];
    $50, $51:
      FA := FA and FRAM[Indirect];
    $53:
      begin
        FA := FA and Fetch;
        Result := 2;
      end;
    $55:
      begin
        FTimerRunning := True;
        FPrescale := 0;
      end;
    $57:
      begin
        if (FA and $F > 9) or (FPSW and $40 <> 0) then
        begin
          if FA > $F9 then
            FPSW := FPSW or $80;
          FA := Byte((Integer(FA) + 6) and $FF);
        end;
        if (FA and $F0 > $90) or (FPSW and $80 <> 0) then
        begin
          FA := Byte((Integer(FA) + $60) and $FF);
          FPSW := FPSW or $80;
        end;
      end;
    $58..$5F:
      FA := FA and FRAM[Reg];
    $60, $61:
      Add(FRAM[Indirect], False);
    $62:
      FTimer := FA;
    $65:
      FTimerRunning := False;
    $67:
      begin
        Temp := (FA shl 7) and $80;
        FA := (FA shr 1) or (FPSW and $80);
        FPSW := (FPSW and $7F) or Temp;
      end;
    $68..$6F:
      Add(FRAM[Reg], False);
    $70, $71:
      Add(FRAM[Indirect], True);
    $76:
      begin
        Branch(FF1);
        Result := 2;
      end;
    $77:
      FA := Byte(((FA shr 1) or (FA shl 7)) and $FF);
    $78..$7F:
      Add(FRAM[Reg], True);
    $80, $81:
      begin
        FA := $FF;
        Result := 2;
      end; // No external data RAM.
      $83:
      begin
        Pull(False);
        Result := 2;
      end;
    $85:
      FPSW := FPSW and $DF;
    $86:
      begin
        Branch(FIRQ);
        Result := 2;
      end;
    $88:
      begin
        Fetch;
        Result := 2;
      end; // External BUS output is unconnected.
      $89:
      begin
        FP1 := FP1 or Fetch;
        FDAC := FP1;
        Result := 2;
      end;
    $8A:
      begin
        FP2 := FP2 or Fetch;
        Result := 2;
      end;
    $8C..$8F:
      begin
        Expander(Op and 3, 2);
        Result := 2;
      end;
    $90, $91:
      Result := 2; // External RAM writes are unconnected.
      $93:
      begin
        FInIRQ := False;
        Pull(True);
        Result := 2;
      end;
    $95:
      FPSW := FPSW xor $20;
    $96:
      begin
        Branch(FA <> 0);
        Result := 2;
      end;
    $97:
      FPSW := FPSW and $7F;
    $98:
      begin
        Fetch;
        Result := 2;
      end;
    $99:
      begin
        FP1 := FP1 and Fetch;
        FDAC := FP1;
        Result := 2;
      end;
    $9A:
      begin
        FP2 := FP2 and Fetch;
        Result := 2;
      end;
    $9C..$9F:
      begin
        Expander(Op and 3, 3);
        Result := 2;
      end;
    $A0, $A1:
      FRAM[Indirect] := FA;
    $A3:
      begin
        FA := FROM[(FPC and $F00) or FA];
        Result := 2;
      end;
    $A5:
      FF1 := False;
    $A7:
      FPSW := FPSW xor $80;
    $A8..$AF:
      FRAM[Reg] := FA;
    $B0, $B1:
      begin
        FRAM[Indirect] := Fetch;
        Result := 2;
      end;
    $B3:
      begin
        FPC := (FPC and $F00) or FROM[(FPC and $F00) or FA];
        Result := 2;
      end;
    $B5:
      FF1 := not FF1;
    $B6:
      begin
        Branch(FPSW and $20 <> 0);
        Result := 2;
      end;
    $B8..$BF:
      begin
        FRAM[Reg] := Fetch;
        Result := 2;
      end;
    $C5:
      FPSW := FPSW and $EF;
    $C6:
      begin
        Branch(FA = 0);
        Result := 2;
      end;
    $C7:
      FA := FPSW or 8;
    $C8..$CF:
      FRAM[Reg] := Byte((Integer(FRAM[Reg]) - 1) and $FF);
    $D0, $D1:
      FA := FA xor FRAM[Indirect];
    $D3:
      begin
        FA := FA xor Fetch;
        Result := 2;
      end;
    $D5:
      FPSW := FPSW or $10;
    $D7:
      FPSW := FA and $F7;
    $D8..$DF:
      FA := FA xor FRAM[Reg];
    $E3:
      begin
        FA := FROM[$300 or FA];
        Result := 2;
      end;
    $E5:
      FBank := 0;
    $E6:
      begin
        Branch(FPSW and $80 = 0);
        Result := 2;
      end;
    $E7:
      FA := Byte(((FA shl 1) or (FA shr 7)) and $FF);
    $E8..$EF:
      begin
        FRAM[Reg] := Byte((Integer(FRAM[Reg]) - 1) and $FF);
        Branch(FRAM[Reg] <> 0);
        Result := 2;
      end;
    $F0, $F1:
      FA := FRAM[Indirect];
    $F5:
      FBank := $800;
    $F6:
      begin
        Branch(FPSW and $80 <> 0);
        Result := 2;
      end;
    $F7:
      begin
        Temp := FA and $80;
        FA := Byte(((FA shl 1) or (FPSW shr 7)) and $FF);
        FPSW := (FPSW and $7F) or Temp;
      end;
    $F8..$FF:
      FA := FRAM[Reg];
  else
    raise EInvalidOpException.CreateFmt('Invalid 7751 opcode %.2x at %.3x', [Op, (FPC - 1) and $FFF]);
  end;
  Burn(Result);
end;

procedure TS16UPD7751.Advance(ZCycles: Integer);
begin
  if FReset then
    Exit;
  Inc(FBalance, Int64(ZCycles) * 6000000);
  while FBalance > 0 do
    Dec(FBalance, Int64(Step) * 15 * 4000000);
end;

function TS16UPD7751.Sample: Integer;
begin
  Result := (Integer(FDAC) - 128) * 128;
end;

procedure TS16UPD7751.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPC, SizeOf(FPC));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FA, SizeOf(FA));
  State.Field(FPSW, SizeOf(FPSW));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FP1, SizeOf(FP1));
  State.Field(FP2, SizeOf(FP2));
  State.Field(FDAC, SizeOf(FDAC));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FReset, SizeOf(FReset));
  State.Field(FIRQ, SizeOf(FIRQ));
  State.Field(FIRQEnabled, SizeOf(FIRQEnabled));
  State.Field(FTimerIRQEnabled, SizeOf(FTimerIRQEnabled));
  State.Field(FInIRQ, SizeOf(FInIRQ));
  State.Field(FF1, SizeOf(FF1));
  State.Field(FTimerRunning, SizeOf(FTimerRunning));
  State.Field(FTimerFlag, SizeOf(FTimerFlag));
  State.Field(FTimerPending, SizeOf(FTimerPending));
  State.Field(FPrescale, SizeOf(FPrescale));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FBalance, SizeOf(FBalance));
  if (FPC >= $1000) or (FPrescale < 0) or (FPrescale > 31) then
    raise EReadError.Create('Invalid 7751 state');
end;

end.

