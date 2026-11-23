unit HW.PIC16C5x;

// PIC16C54 and PIC16C57 baseline cores. Instruction encoding, banking, stack and reset
// behavior follow Microchip DS30453E, sections 5, 6, 8, 9 and 10.
interface

uses
  System.SysUtils, Core.Snapshots;

type
  TPICReadPort = function(Port: Integer): Byte of object;

  TPICWritePort = procedure(Port: Integer; Value: Byte) of object;

  TPICStateField = procedure(var Value; Size: Integer) of object;

  TPIC16C57 = class
  private
    FProgramMask: Word;
    FFileMask, FPageBits, FPortCount: Byte;
    FROM: TArray<Word>;
    FRAM: array[0..127] of Byte;
    FStack: array[0..1] of Word;
    FTris: array[0..2] of Byte;
    FW, FOption: Byte;
    FPC: Word;
    FSleep, FPCWritten, FT0: Boolean;
    FPrescaler, FInhibit: Integer;
    FWDT, FWDTPeriod: Int64;
    FWDTEnabled: Boolean;
    FRead: TPICReadPort;
    FWrite: TPICWritePort;
    constructor CreateModel(const ROM: TBytes; Oscillator: Integer; Watchdog: Boolean; ProgramWords, FileRegisters, PortCount: Integer);
    function Address(FileNo: Byte): Integer;
    procedure Drive(Port: Integer);
    procedure Flags(Mask, Value: Byte);
    procedure Advance(Cycles: Integer);
    procedure TimerPulse;
  public
    constructor Create(const ROM: TBytes; Oscillator: Integer = 3750000; Watchdog: Boolean = True);
    procedure Reset(PowerOn: Boolean = True);
    function ReadFile(FileNo: Byte): Byte;
    procedure WriteFile(FileNo, Value: Byte);
    procedure SetT0(Level: Boolean);
    function Step: Integer;
    procedure SerializeState(State: TStateArchive); overload;
    procedure SerializeState(Field: TPICStateField); overload;
    property PC: Word read FPC;
    property W: Byte read FW;
    property OnReadPort: TPICReadPort read FRead write FRead;
    property OnWritePort: TPICWritePort read FWrite write FWrite;
  end;

  TPIC16C54 = class(TPIC16C57)
  public
    constructor Create(const ROM: TBytes; Oscillator: Integer = 1789773; Watchdog: Boolean = False);
  end;

implementation

constructor TPIC16C57.Create(const ROM: TBytes; Oscillator: Integer; Watchdog: Boolean);
begin
  CreateModel(ROM, Oscillator, Watchdog, $800, $80, 3);
end;

constructor TPIC16C54.Create(const ROM: TBytes; Oscillator: Integer; Watchdog: Boolean);
begin
  inherited CreateModel(ROM, Oscillator, Watchdog, $200, $20, 2);
end;

constructor TPIC16C57.CreateModel(const ROM: TBytes; Oscillator: Integer; Watchdog: Boolean; ProgramWords, FileRegisters, PortCount: Integer);
begin
  inherited Create;
  if (Length(ROM) <> ProgramWords * 2) or (Oscillator < 4000) then
    raise EArgumentException.Create('Invalid PIC16C5x ROM/clock');

  FProgramMask := ProgramWords - 1;
  FFileMask := FileRegisters - 1;
  FPortCount := PortCount;
  FPageBits := (FProgramMask shr 4) and $60;
  SetLength(FROM, ProgramWords);
  for var I := 0 to FProgramMask do
    FROM[I] := (Word(ROM[I * 2]) or (Word(ROM[I * 2 + 1]) shl 8)) and $FFF;
  FWDTPeriod := Int64(Oscillator) * 18 div 4000;
  FWDTEnabled := Watchdog;
  Reset;
end;

procedure TPIC16C57.Drive(Port: Integer);
begin
  if Assigned(FWrite) then
  begin
    var Value := FRAM[5 + Port] or FTris[Port];
    if Port = 0 then
      Value := Value and 15;
    FWrite(Port, Value);
  end;
end;

procedure TPIC16C57.Reset(PowerOn: Boolean);
begin
  var Status := FRAM[3] and $F;
  if PowerOn then
  begin
    FillChar(FRAM, SizeOf(FRAM), 0);
    FillChar(FStack, SizeOf(FStack), 0);
    FW := 0;
    Status := $18;
  end
  else
    Status := Status and $EF;
  FRAM[3] := Status;
  FPC := FProgramMask;
  FPCWritten := False;
  FillChar(FTris, SizeOf(FTris), $FF);
  FOption := $FF;
  FPrescaler := 0;
  FInhibit := 0;
  FWDT := 0;
  FSleep := False;
  for var I := 0 to FPortCount - 1 do
    Drive(I);
end;

function TPIC16C57.Address(FileNo: Byte): Integer;
begin
  Result := FileNo and 31;
  if Result = 0 then
    Result := FRAM[4] and FFileMask
  else if (Result >= 16) and (FFileMask > $1F) then
    Result := Result or (FRAM[4] and $60);
  if Result and $10 = 0 then
    Result := Result and 15;
end;

function TPIC16C57.ReadFile(FileNo: Byte): Byte;
begin
  var A := Address(FileNo);
  case A of
    0:
      Exit(0);
    2:
      Exit(Byte(FPC and $FF));
    4:
      Exit(FRAM[4] or ($FF xor FFileMask));
    5..7:
      begin
        if A >= 5 + FPortCount then
          Exit(FRAM[A]);
        var Pins: Byte := $FF;
        if Assigned(FRead) then
          Pins := FRead(A - 5);
        Result := (FRAM[A] and not FTris[A - 5]) or (Pins and FTris[A - 5]);
        if A = 5 then
          Result := Result and $0F;
        Exit;
      end;
  end;
  Result := FRAM[A];
end;

procedure TPIC16C57.WriteFile(FileNo, Value: Byte);
begin
  var A := Address(FileNo);
  case A of
    0:
      Exit;
    1:
      begin
        FInhibit := 3;
        if FOption and 8 = 0 then
          FPrescaler := 0;
      end;
    2:
      begin
        FPC := (Word(FRAM[3] and FPageBits) shl 4) or Value;
        FPCWritten := True;
        Exit;
      end;
    3:
      Value := (Value and (FPageBits or 7)) or (FRAM[3] and $18);
    4:
      Value := Value and FFileMask;
    5:
      Value := Value and $0F;
  end;
  FRAM[A] := Value;
  if (A >= 5) and (A < 5 + FPortCount) then
    Drive(A - 5);
end;

procedure TPIC16C57.Flags(Mask, Value: Byte);
begin
  FRAM[3] := (FRAM[3] and not Mask) or (Value and Mask);
end;

procedure TPIC16C57.TimerPulse;
begin
  if FInhibit <> 0 then
    Exit;

  var Divider := 1;
  if FOption and 8 = 0 then
    Divider := 2 shl (FOption and 7);
  Inc(FPrescaler);
  if FPrescaler >= Divider then
  begin
    FPrescaler := 0;
    FRAM[1] := Byte((Cardinal(FRAM[1]) + 1) and $FF);
  end;
end;

procedure TPIC16C57.SetT0(Level: Boolean);
begin
  if (Level <> FT0) and (FOption and $20 <> 0) and (Level = (FOption and $10 = 0)) then
    TimerPulse;
  FT0 := Level;
end;

procedure TPIC16C57.Advance(Cycles: Integer);
begin
  if not FSleep then
    for var I := 1 to Cycles do
      if FInhibit <> 0 then
        Dec(FInhibit)
      else if FOption and $20 = 0 then
        TimerPulse;
  if FWDTEnabled then
  begin
    Inc(FWDT, Cycles);
    var Limit := FWDTPeriod;
    if FOption and 8 <> 0 then
      Limit := Limit shl (FOption and 7);
    if FWDT >= Limit then
      Reset(False);
  end;
end;

function TPIC16C57.Step: Integer;
begin
  Result := 1;
  if FSleep then
  begin
    Advance(Result);
    Exit;
  end;

  var Op := FROM[FPC];
  FPC := (FPC + 1) and FProgramMask;
  FPCWritten := False;
  var FileNo := Byte(Op and $1F);
  var Value := 0;
  var Mask := 0;
  var FlagValue := 0;
  var Store := False;
  var Skip := False;
  if Op < $20 then
  begin
    case Op of
      0:
        ;
      2:
        FOption := FW;
      3:
        begin
          FSleep := True;
          FWDT := 0;
          Flags($18, $10);
        end;
      4:
        begin
          FWDT := 0;
          Flags($18, $18);
        end;
      5..7:
        begin
          if Op < 5 + FPortCount then
          begin
            FTris[Op - 5] := FW;
            Drive(Op - 5);
          end;
        end;
    else
      raise EInvalidOpException.CreateFmt('Reserved PIC opcode %.3x', [Op]);
    end;
  end
  else if Op and $FE0 = $020 then
    WriteFile(FileNo, FW)
  else if Op and $FC0 = $040 then
  begin
    if Op and $20 <> 0 then
      WriteFile(FileNo, 0)
    else
      FW := 0;
    Flags(4, 4);
  end
  else if Op < $400 then
  begin
    var F := Integer(ReadFile(FileNo));
    var W := Integer(FW);
    Store := True;
    case Op and $FC0 of
      $080:
        begin
          Value := F - W;
          Mask := 7;
          if F >= W then
            FlagValue := FlagValue or 1;
          if (F and 15) >= (W and 15) then
            FlagValue := FlagValue or 2;
        end;
      $0C0:
        begin
          Value := F - 1;
          Mask := 4;
        end;
      $100:
        begin
          Value := F or W;
          Mask := 4;
        end;
      $140:
        begin
          Value := F and W;
          Mask := 4;
        end;
      $180:
        begin
          Value := F xor W;
          Mask := 4;
        end;
      $1C0:
        begin
          Value := F + W;
          Mask := 7;
          if Value > $FF then
            FlagValue := FlagValue or 1;
          if (F and 15) + (W and 15) > 15 then
            FlagValue := FlagValue or 2;
        end;
      $200:
        begin
          Value := F;
          Mask := 4;
        end;
      $240:
        begin
          Value := F xor $FF;
          Mask := 4;
        end;
      $280:
        begin
          Value := F + 1;
          Mask := 4;
        end;
      $2C0:
        begin
          Value := F - 1;
          Skip := Value and $FF = 0;
        end;
      $300:
        begin
          Value := (F shr 1) or ((FRAM[3] and 1) shl 7);
          Mask := 1;
          FlagValue := F and 1;
        end;
      $340:
        begin
          Value := (F shl 1) or (FRAM[3] and 1);
          Mask := 1;
          FlagValue := (F shr 7) and 1;
        end;
      $380:
        Value := (F shr 4) or (F shl 4);
      $3C0:
        begin
          Value := F + 1;
          Skip := Value and $FF = 0;
        end;
    end;
    Value := Value and $FF;
    if (Mask and 4 <> 0) and (Value = 0) then
      FlagValue := FlagValue or 4;
  end
  else if Op < $800 then
  begin
    var F := ReadFile(FileNo);
    var BitValue := 1 shl ((Op shr 5) and 7);
    case Op and $F00 of
      $400:
        WriteFile(FileNo, Byte(F and not BitValue));
      $500:
        WriteFile(FileNo, Byte(F or BitValue));
      $600:
        Skip := F and BitValue = 0;
      $700:
        Skip := F and BitValue <> 0;
    end;
  end
  else
    case Op and $F00 of
      $800:
        begin
          FW := Byte(Op and $FF);
          FPC := FStack[0];
          FStack[0] := FStack[1];
          FPCWritten := True;
        end;
      $900:
        begin
          FStack[1] := FStack[0];
          FStack[0] := FPC;
          FPC := (Word(FRAM[3] and FPageBits) shl 4) or (Op and $FF);
          FPCWritten := True;
        end;
      $A00, $B00:
        begin
          FPC := (Word(FRAM[3] and FPageBits) shl 4) or (Op and $1FF);
          FPCWritten := True;
        end;
      $C00:
        FW := Byte(Op and $FF);
      $D00:
        begin
          FW := FW or Byte(Op and $FF);
          Flags(4, Ord(FW = 0) * 4);
        end;
      $E00:
        begin
          FW := FW and Byte(Op and $FF);
          Flags(4, Ord(FW = 0) * 4);
        end;
      $F00:
        begin
          FW := FW xor Byte(Op and $FF);
          Flags(4, Ord(FW = 0) * 4);
        end;
    end;
  if Store then
  begin
    if Op and $20 <> 0 then
      WriteFile(FileNo, Byte(Value))
    else
      FW := Byte(Value);
    Flags(Byte(Mask), Byte(FlagValue));
  end;
  if Skip then
  begin
    FPC := (FPC + 1) and FProgramMask;
    Result := 2;
  end;
  if FPCWritten then
    Result := 2;
  Advance(Result);
end;

procedure TPIC16C57.SerializeState(State: TStateArchive);
begin
  SerializeState(State.Field);
end;

procedure TPIC16C57.SerializeState(Field: TPICStateField);
begin
  Field(FRAM, SizeOf(FRAM));
  Field(FStack, SizeOf(FStack));
  Field(FTris, SizeOf(FTris));
  Field(FW, SizeOf(FW));
  Field(FOption, SizeOf(FOption));
  Field(FPC, SizeOf(FPC));
  Field(FSleep, SizeOf(FSleep));
  Field(FT0, SizeOf(FT0));
  Field(FPrescaler, SizeOf(FPrescaler));
  Field(FInhibit, SizeOf(FInhibit));
  Field(FWDT, SizeOf(FWDT));
  if (FPC > FProgramMask) or (FStack[0] > FProgramMask) or (FStack[1] > FProgramMask) or
    (FPrescaler < 0) or (FPrescaler > 255) or
    (FInhibit < 0) or (FInhibit > 3) or (FWDT < 0) then
    raise EArgumentException.Create('Invalid PIC16C5x state');
end;

end.

