unit NES.Mapper.Multicart;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperMulticart = class(TMapperBanked)
  private
    FBoard, FWorkBank, FResetCount: Integer;
    FRegs: array[0..3] of Integer;
    FStarted, FEpromFirst: Boolean;
    procedure UpdateBanks;
    procedure Latch234(Address: UInt16; Value: Byte);
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

constructor TMapperMulticart.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  if (Board = MAPPER_SUPERVISION) and (Length(Prg) >= $8000) then
  begin
    var Crc: Cardinal := $FFFFFFFF;
    for var i := 0 to $7FFF do
    begin
      Crc := Crc xor Prg[i];
      for var Bit := 0 to 7 do
        if (Crc and 1) <> 0 then
          Crc := (Crc shr 1) xor $EDB88320
        else
          Crc := Crc shr 1;
    end;
    FEpromFirst := (Crc xor $FFFFFFFF) = $63794E25;
  end;
  Reset;
end;

procedure TMapperMulticart.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FWorkBank, SizeOf(FWorkBank));
  State.Field(FResetCount, SizeOf(FResetCount));
  State.Field(FStarted, SizeOf(FStarted));
end;

procedure TMapperMulticart.Reset;
begin
  inherited;
  FRamEnabled := False;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FWorkBank := -1;
  if FStarted then
  begin
    if FBoard = MAPPER_MULTICART_60 then
      FResetCount := (FResetCount + 1) and 3;
    if FBoard = MAPPER_MULTICART_230 then
      FResetCount := FResetCount xor 1;
  end;
  FStarted := True;
  case FBoard of
    MAPPER_BMC51:
      FRegs[1] := 1;
    MAPPER_MULTICART_60:
      begin
        Prg16(0, FResetCount);
        Prg16(1, FResetCount);
        Chr8(FResetCount);
        Exit
      end;
    MAPPER_MULTICART_62, MAPPER_BMC235:
      Prg32(0);
    MAPPER_BMC63, MAPPER_BMC810544_CA1, MAPPER_BMC_NTD03, MAPPER_BMC_G146, MAPPER_EH8813_A:
      CpuWrite($8000, 0);
    MAPPER_MULTICART_230:
      begin
        if FResetCount = 0 then
        begin
          Prg16(0, 0);
          Prg16(1, 7);
          Mirror(0)
        end
        else
        begin
          Prg16(0, 8);
          Prg16(1, 9);
          Mirror(1)
        end;
        Exit;
      end;
    MAPPER_BS5:
      begin
        for var i := 0 to 3 do
        begin
          Prg8(i, -1);
          Chr2(i, (Length(FChrMemory) div $800) - 1)
        end;
        Exit
      end;
    MAPPER_BMC64IN1_NO_REPEAT:
      begin
        FRegs[0] := $80;
        FRegs[1] := $43
      end;
    MAPPER_FARID_UNROM:
      Prg16(1, 7);
  end;
  UpdateBanks;
end;

procedure TMapperMulticart.UpdateBanks;
var
  Bank, Outer, Mode: Integer;
begin
  case FBoard of
    MAPPER_BMC51:
      begin
        Bank := FRegs[0] shl 2;
        Mode := FRegs[1];
        if (Mode and 1) <> 0 then
        begin
          Prg32(FRegs[0]);
          FWorkBank := $23 or Bank
        end
        else
        begin
          Prg16(0, (Bank or Mode) shr 1);
          Prg16(1, (Bank or $E) shr 1);
          FWorkBank := $2F or Bank
        end;
        Mirror(Ord(Mode = 3));
      end;
    MAPPER_SUPERVISION:
      begin
        Outer := (FRegs[0] shl 3) and $78;
        FWorkBank := (Outer shl 1) or 15;
        if FEpromFirst then
          Inc(FWorkBank, 4);
        if (FRegs[0] and $10) <> 0 then
        begin
          Bank := Ord(FEpromFirst) * 2;
          Prg16(0, (Outer or (FRegs[1] and 7)) + Bank);
          Prg16(1, (Outer or 7) + Bank);
        end
        else if FEpromFirst then
        begin
          Prg16(0, 0);
          Prg16(1, 1)
        end
        else
        begin
          Prg16(0, $80);
          Prg16(1, $80)
        end;
        Mirror((FRegs[0] shr 5) and 1);
      end;
    MAPPER_MULTICART_57:
      begin
        Mirror((FRegs[1] shr 3) and 1);
        Chr8(((FRegs[0] and $40) shr 3) or ((FRegs[0] or FRegs[1]) and 7));
        Bank := (FRegs[1] shr 5) and 7;
        if (FRegs[1] and $10) <> 0 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end;
      end;
    MAPPER_MULTICART_221:
      begin
        Outer := (FRegs[0] and $FC) shr 2;
        Bank := Outer or FRegs[1];
        if (FRegs[0] and 2) = 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else if (FRegs[0] and $100) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Outer or 7)
        end
        else
          Prg32((Outer or (FRegs[1] and 6)) shr 1);
        Mirror(FRegs[0] and 1);
      end;
    MAPPER_MULTICART_234:
      begin
        if (FRegs[0] and $40) <> 0 then
        begin
          Prg32((FRegs[0] and $E) or (FRegs[1] and 1));
          Chr8(((FRegs[0] shl 2) and $38) or ((FRegs[1] shr 4) and 7))
        end
        else
        begin
          Prg32(FRegs[0] and 15);
          Chr8(((FRegs[0] shl 2) and $3C) or ((FRegs[1] shr 4) and 3))
        end;
        Mirror((FRegs[0] shr 7) and 1);
      end;
    MAPPER_BMC70IN1:
      begin
        Outer := FRegs[2];
        Bank := Outer or FRegs[0];
        Mode := FRegs[1];
        if Mode = $20 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          if Mode = $30 then
            Prg16(1, Bank)
          else
            Prg16(1, Outer or 7)
        end;
        if not FHasChrRam then
          Chr8(FRegs[3]);
      end;
    MAPPER_BMC80013_B:
      begin
        if (FRegs[2] and 2) <> 0 then
          Bank := (FRegs[0] and 15) or (FRegs[1] and $70)
        else
          Bank := FRegs[0] and 3;
        Prg16(0, Bank);
        Prg16(1, FRegs[1] and $7F);
        Mirror(1 - ((FRegs[0] shr 4) and 1));
      end;
    MAPPER_BMC60311_C:
      begin
        Outer := FRegs[1];
        Bank := Outer;
        if (FRegs[2] and 4) = 0 then
          Bank := Bank or FRegs[0];
        case FRegs[2] and 3 of
          0:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank)
            end;
          1:
            Prg32(Bank shr 1);
          2:
            begin
              Prg16(0, Bank);
              Prg16(1, Outer or 7)
            end;
        end;
        Mirror((FRegs[2] shr 3) and 1);
      end;
    MAPPER_BMC64IN1_NO_REPEAT:
      begin
        Bank := ((FRegs[1] and 31) shl 1) or ((FRegs[1] shr 6) and 1);
        if (FRegs[0] and $80) <> 0 then
          if (FRegs[1] and $80) <> 0 then
            Prg32(FRegs[1] and 31)
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank)
          end
        else
          Prg16(1, Bank);
        Mirror((FRegs[0] shr 5) and 1);
        Chr8((FRegs[2] shl 2) or ((FRegs[0] shr 1) and 3));
      end;
    MAPPER_BMC830425_C4391_T:
      begin
        Outer := FRegs[1] shl 3;
        if FRegs[2] <> 0 then
        begin
          Prg16(0, Outer or (FRegs[0] and 7));
          Prg16(1, Outer or 7)
        end
        else
        begin
          Prg16(0, Outer or FRegs[0]);
          Prg16(1, Outer or 15)
        end;
      end;
    MAPPER_BMC12IN1:
      begin
        Outer := (FRegs[2] and 3) shl 3;
        Chr4(0, (FRegs[0] shr 3) or (Outer shl 2));
        Chr4(1, (FRegs[1] shr 3) or (Outer shl 2));
        if (FRegs[2] and 8) <> 0 then
          Prg32((Outer or (FRegs[0] and 6)) shr 1)
        else
        begin
          Prg16(0, Outer or (FRegs[0] and 7));
          Prg16(1, Outer or 7)
        end;
        Mirror((FRegs[2] shr 2) and 1);
      end;
    MAPPER_MULTICART_487:
      begin
        Bank := FRegs[1] and $1E;
        Outer := ((FRegs[1] and $1E) shl 2) or (FRegs[0] and 3);
        if (FRegs[1] and $40) <> 0 then
        begin
          Bank := Bank or ((FRegs[0] and 8) shr 3);
          Outer := Outer or (FRegs[0] and 4)
        end
        else
        begin
          Bank := Bank or (FRegs[1] and 1);
          Outer := Outer or ((FRegs[1] and 1) shl 2)
        end;
        if (FRegs[1] and $20) <> 0 then
        begin
          Inc(Bank, $10);
          Inc(Outer, $40)
        end;
        Prg32(Bank);
        Chr8(Outer);
        Mirror((FRegs[1] shr 7) and 1);
      end;
  end;
end;

procedure TMapperMulticart.Latch234(Address: UInt16; Value: Byte);
begin
  if Address <= $FF9F then
  begin
    if (FRegs[0] and $3F) = 0 then
      FRegs[0] := Value
  end
  else
    FRegs[1] := Value and $71;
  UpdateBanks;
end;

function TMapperMulticart.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) and (FWorkBank >= 0) then
  begin
    Value := FPrgRom[(FWorkBank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True)
  end;

  if (FBoard = MAPPER_UNL_D1038) and (FRegs[0] <> 0) and (Address >= $8000) then
  begin
    Value := 0;
    Exit(True)
  end;

  if (FBoard = MAPPER_BMC63) and (FRegs[0] <> 0) and (Address >= $8000) and (Address < $C000) then
    Exit(False);

  if (FBoard = MAPPER_BMC235) and (FRegs[0] <> 0) and (Address >= $8000) then
    Exit(False);

  // DIP switches default to zero, matching an unconfigured Mesen board.
  if (Address >= $8000) and (((FBoard = MAPPER_BMC70IN1) and (FRegs[1] = $10)) or ((FBoard = MAPPER_EH8813_A) and (FRegs[0] <> 0))) then
    Address := Address and $FFF0;
  Result := inherited CpuRead(Address, Value);
  if Result and (FBoard = MAPPER_MULTICART_234) and (((Address >= $FF80) and (Address <= $FF9F)) or ((Address >= $FFE8) and (Address <= $FFF8))) then
    Latch234(Address, Value);
end;

function TMapperMulticart.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
var
  Bank, Outer, Mode: Integer;
  Bus: Byte;
begin
  Result := True;
  if (FBoard = MAPPER_BMC51) and (Address >= $6000) then
  begin
    if Address < $8000 then
      FRegs[1] := ((Value shr 3) and 2) or ((Value shr 1) and 1)
    else
    begin
      FRegs[0] := Value and 15;
      if (Address and $E000) = $C000 then
        FRegs[1] := ((Value shr 3) and 2) or (FRegs[1] and 1)
    end;
    UpdateBanks;
    Exit;
  end;

  if (FBoard = MAPPER_SUPERVISION) and (Address >= $6000) then
  begin
    if Address < $8000 then
      FRegs[0] := Value
    else
      FRegs[1] := Value;
    UpdateBanks;
    Exit
  end;

  if (FBoard = MAPPER_BMC60311_C) and (Address >= $6000) and (Address < $8000) then
  begin
    if (Address and 1) = 0 then
      FRegs[2] := Value and 15
    else
      FRegs[1] := Value;
    UpdateBanks;
    Exit
  end;

  if (FBoard = MAPPER_BMC64IN1_NO_REPEAT) and (Address >= $5000) and (Address <= $5003) then
  begin
    FRegs[Address and 3] := Value;
    UpdateBanks;
    Exit
  end;

  if (FBoard = MAPPER_SUPER40IN1_WS) and (Address >= $6000) and (Address <= $6FFF) then
  begin
    if FRegs[0] = 0 then
      if (Address and 1) <> 0 then
        Chr8(Value)
      else
      begin
        FRegs[0] := Value and $20;
        Bank := ((not Value) shr 3) and 1;
        Prg16(0, Value and (not Bank));
        Prg16(1, Value or Bank);
        Mirror((Value shr 4) and 1)
      end;
    Exit;
  end;

  if (FBoard = MAPPER_MULTICART_487) and (Address >= $4100) and (Address < $6000) then
  begin
    if (Address and $100) <> 0 then
      if (Address and $80) <> 0 then
        FRegs[1] := Value
      else if (FRegs[1] and $20) = 0 then
        FRegs[0] := Value and 15;
    UpdateBanks;
    Exit;
  end;

  if Address < $8000 then
    Exit(False);

  case FBoard of
    MAPPER_MULTICART_57:
      begin
        FRegs[(Address shr 11) and 1] := Value;
        UpdateBanks
      end;
    MAPPER_UNL_D1038:
      begin
        Bank := (Address shr 4) and 7;
        if (Address and $80) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Chr8(Address and 7);
        Mirror((Address shr 3) and 1);
        FRegs[0] := Address and $100;
      end;
    MAPPER_MULTICART_60:
      ;
    MAPPER_MULTICART_62:
      begin
        Bank := ((Address and $3F00) shr 8) or (Address and $40);
        if (Address and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Chr8(((Address and 31) shl 2) or (Value and 3));
        Mirror((Address shr 7) and 1);
      end;
    MAPPER_BMC63:
      begin
        FRegs[0] := Ord((Address and $300) = $300);
        Outer := (Address shr 1) and $1FC;
        if (Address and 2) <> 0 then
        begin
          Prg8(0, Outer);
          Prg8(1, Outer or 1);
          Prg8(2, Outer or 2)
        end
        else
        begin
          Bank := Outer or ((Address shr 1) and 2);
          Prg8(0, Bank);
          Prg8(1, Bank or 1);
          Prg8(2, Bank)
        end;
        if (Address and $800) <> 0 then
        begin
          Bank := Address and $7C;
          if (Address and 6) <> 0 then
            Bank := Bank or 3
          else
            Bank := Bank or 1
        end
        else
        begin
          Bank := Outer;
          if (Address and 2) <> 0 then
            Bank := Bank or 3
          else
            Bank := Bank or ((Address shr 1) and 2) or 1
        end;
        Prg8(3, Bank);
        Mirror(Address and 1);
      end;
    MAPPER_MULTICART_221:
      begin
        if Address < $C000 then
          FRegs[0] := Address
        else
          FRegs[1] := Address and 7;
        UpdateBanks
      end;
    MAPPER_MULTICART_230:
      if FResetCount = 0 then
        Prg16(0, Value and 7)
      else
      begin
        Bank := (Value and 31) + 8;
        if (Value and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Mirror(1 - ((Value shr 6) and 1))
      end;
    MAPPER_MULTICART_234:
      if ((Address >= $FF80) and (Address <= $FF9F)) or ((Address >= $FFE8) and (Address <= $FFF8)) then
      begin
        inherited CpuRead(Address, Bus);
        Latch234(Address, Value and Bus)
      end;
    MAPPER_BMC235:
      begin
        Mode := 3;
        case Length(FPrgRom) div $4000 of
          64:
            Mode := 0;
          128:
            Mode := 1;
          256:
            Mode := 2
        end;
        Outer := (Address shr 8) and 3;
        FRegs[0] := 0;
        case Mode of
          0:
            if Outer <> 0 then
              FRegs[0] := 1;
          1:
            if (Outer = 1) or (Outer = 3) then
              FRegs[0] := 1
            else
              Outer := (Outer shr 1);
          2:
            if Outer = 1 then
              FRegs[0] := 1
            else if Outer > 1 then
              Dec(Outer);
        end;
        Bank := (Outer shl 5) or (Address and 31);
        if (Address and $800) <> 0 then
        begin
          Bank := Bank * 2 + ((Address shr 12) and 1);
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank);
        if (Address and $400) <> 0 then
          Mirror(2)
        else
          Mirror((Address shr 13) and 1);
      end;
    MAPPER_BMC70IN1:
      begin
        if (Address and $4000) <> 0 then
        begin
          FRegs[1] := Address and $30;
          FRegs[0] := Address and 7
        end
        else
        begin
          Mirror((Address shr 5) and 1);
          if FHasChrRam then
            FRegs[2] := (Address and 3) shl 3
          else
            FRegs[3] := Address and 7
        end;
        UpdateBanks;
      end;
    MAPPER_BMC255:
      begin
        Bank := ((Address shr 8) and $40) or ((Address shr 6) and $3F);
        Outer := Ord((Address and $1000) = 0);
        Prg16(0, Bank and (not Outer));
        Prg16(1, Bank or Outer);
        Chr8(((Address shr 8) and $40) or (Address and $3F));
        Mirror((Address shr 13) and 1)
      end;
    MAPPER_BMC810544_CA1:
      begin
        Bank := (Address shr 6) and $FFFE;
        if (Address and $40) <> 0 then
          Prg32(Bank shr 1)
        else
        begin
          Bank := Bank or ((Address shr 5) and 1);
          Prg16(0, Bank);
          Prg16(1, Bank)
        end;
        Chr8(Address and 15);
        Mirror((Address shr 4) and 1)
      end;
    MAPPER_BMC80013_B:
      begin
        Mode := (Address shr 13) and 3;
        if Mode = 0 then
          FRegs[0] := Value
        else
        begin
          FRegs[1] := Value;
          FRegs[2] := Mode
        end;
        UpdateBanks
      end;
    MAPPER_BS5:
      case Address and $F000 of
        $8000:
          Chr2((Address shr 10) and 3, Address and 31);
        $A000:
          if (Address and $10) <> 0 then
            Prg8((Address shr 10) and 3, Address and 15);
      end;
    MAPPER_GKCX1:
      begin
        Prg32((Address shr 3) and 3);
        Chr8(Address and 7)
      end;
    MAPPER_BMC60311_C:
      begin
        FRegs[0] := Value and 7;
        UpdateBanks
      end;
    MAPPER_BMC_NTD03:
      begin
        Bank := (Address shr 10) and $1E;
        if (Address and $80) <> 0 then
        begin
          Bank := Bank or ((Address shr 6) and 1);
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Chr8(((Address and $300) shr 5) or (Address and 7));
        Mirror((Address shr 10) and 1)
      end;
    MAPPER_BMC64IN1_NO_REPEAT:
      begin
        FRegs[3] := Value;
        UpdateBanks
      end;
    MAPPER_BMC830425_C4391_T:
      begin
        FRegs[0] := Value and 15;
        if (Address and $FFE0) = $F0E0 then
        begin
          FRegs[1] := Address and 15;
          FRegs[2] := (Address shr 4) and 1
        end;
        UpdateBanks
      end;
    MAPPER_FARID_UNROM:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        if ((FRegs[0] and $88) = 0) and ((Value and $80) <> 0) then
          FRegs[0] := (FRegs[0] and $87) or (Value and $78);
        FRegs[0] := (FRegs[0] and $78) or (Value and $87);
        Outer := (FRegs[0] and $70) shr 1;
        Prg16(0, Outer or (FRegs[0] and 7));
        Prg16(1, Outer or 7);
      end;
    MAPPER_BMC12IN1:
      begin
        case Address and $E000 of
          $A000:
            FRegs[0] := Value;
          $C000:
            FRegs[1] := Value;
          $E000:
            FRegs[2] := Value and 15
        end;
        UpdateBanks
      end;
    MAPPER_BMC_G146:
      begin
        if (Address and $800) <> 0 then
        begin
          Prg16(0, (Address and 31) or (Address and ((Address and $40) shr 6)));
          Prg16(1, (Address and $18) or 7)
        end
        else if (Address and $40) <> 0 then
        begin
          Prg16(0, Address and 31);
          Prg16(1, Address and 31)
        end
        else
          Prg32((Address and $1E) shr 1);
        Mirror((Address shr 7) and 1);
      end;
    MAPPER_MULTICART_487:
      begin
        if (FRegs[1] and $20) <> 0 then
          FRegs[0] := ((Value and 1) shl 3) or ((Value and $70) shr 4);
        UpdateBanks
      end;
    MAPPER_EH8813_A:
      if (Address and $100) = 0 then
      begin
        FRegs[0] := Address and $40;
        Bank := Address and 7;
        if (Address and $80) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Chr8(Value and 15);
      end;
  else
    Result := False;
  end;
end;

end.

