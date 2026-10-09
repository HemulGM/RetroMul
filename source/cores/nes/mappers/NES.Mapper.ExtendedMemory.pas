unit NES.Mapper.ExtendedMemory;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  T93C66Phase = (Start, Command, ReadData, WriteData, Done);

  TMapperExtendedMemory = class(TMapperBanked)
  private
    FBoard, FSelect, FMode, FCounter: Integer;
    FRegs: array[0..15] of Integer;
    FPending, FLocked: Boolean;
    FNameRam: array[0..$7FF] of Byte;
    FHasEeprom, FEepromClock, FEepromOutput, FEepromWriteEnabled: Boolean;
    FEeprom: array[0..511] of Byte;
    FEepromPhase: T93C66Phase;
    FEepromBits, FEepromShift, FEepromAddress, FEepromOpcode: Integer;
    procedure ResetEepromBus;
    procedure WriteEeprom(Value: Byte);
    procedure UpdateOuter;
    function SmallPrgRead(Address: UInt16; out Value: Byte): Boolean;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Eeprom: Boolean = False);
    procedure Configure93C66(PrgRamSize: Integer);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    function IrqPending: Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

constructor TMapperExtendedMemory.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Eeprom: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  if Eeprom then
    Configure93C66($2000);
  if Board = MAPPER_FDS_CONVERSION_103 then
    SetLength(FPrgRam, $4000);
  if Board = MAPPER_RACERMATE then
  begin
    SetLength(FChrMemory, $10000);
    FHasChrRam := True
  end;
  Reset;
end;

procedure TMapperExtendedMemory.Configure93C66(PrgRamSize: Integer);
begin
  if (FBoard <> MAPPER_WAIXING164) or (PrgRamSize < 0) or (PrgRamSize > $2000) then
    raise ENesException.Create('Unsupported mapper 164 RAM layout');

  FHasEeprom := True;
  SetLength(FPrgRam, PrgRamSize);
  FillChar(FEeprom, SizeOf(FEeprom), $FF);
  FEepromWriteEnabled := False;
  ResetEepromBus;
end;

procedure TMapperExtendedMemory.ResetEepromBus;
begin
  FEepromPhase := T93C66Phase.Start;
  FEepromClock := False;
  FEepromOutput := True;
  FEepromBits := 0;
  FEepromShift := 0;
  FEepromAddress := 0;
  FEepromOpcode := 0;
end;

procedure TMapperExtendedMemory.WriteEeprom(Value: Byte);
begin
  // 93C66, ORG=0: start bit, two opcode bits, nine address bits,
  // then eight data bits, all MSB first. $5200 drives CS/CLK/DI.
  var Clock := (Value and $04) <> 0;
  if (Value and $10) = 0 then
    ResetEepromBus
  else if Clock and not FEepromClock then
    case FEepromPhase of
      T93C66Phase.Start:
        if (Value and 1) <> 0 then
        begin
          FEepromPhase := T93C66Phase.Command;
          FEepromBits := 0;
          FEepromShift := 0;
        end;
      T93C66Phase.Command:
        begin
          FEepromShift := (FEepromShift shl 1) or (Value and 1);
          Inc(FEepromBits);
          if FEepromBits = 11 then
          begin
            FEepromOpcode := FEepromShift shr 9;
            FEepromAddress := FEepromShift and $1FF;
            FEepromBits := 0;
            FEepromShift := 0;
            FEepromPhase := T93C66Phase.Done;
            case FEepromOpcode of
              0:
                case FEepromAddress shr 7 of
                  0:
                    FEepromWriteEnabled := False; // EWDS
                    1:
                    FEepromPhase := T93C66Phase.WriteData; // WRAL
                    2:
                    if FEepromWriteEnabled then
                      FillChar(FEeprom, SizeOf(FEeprom), $FF); // ERAL
                      3:
                    FEepromWriteEnabled := True; // EWEN
                end;
              1:
                FEepromPhase := T93C66Phase.WriteData;
              2:
                begin
                  FEepromPhase := T93C66Phase.ReadData;
                  FEepromOutput := False; // Dummy zero precedes the first byte.
                end;
              3:
                if FEepromWriteEnabled then
                  FEeprom[FEepromAddress] := $FF;
            end;
          end;
        end;
      T93C66Phase.ReadData:
        begin
          FEepromOutput := (FEeprom[FEepromAddress] and ($80 shr FEepromBits)) <> 0;
          Inc(FEepromBits);
          if FEepromBits = 8 then
          begin
            FEepromBits := 0;
            FEepromAddress := (FEepromAddress + 1) and $1FF;
          end;
        end;
      T93C66Phase.WriteData:
        begin
          FEepromShift := (FEepromShift shl 1) or (Value and 1);
          Inc(FEepromBits);
          if FEepromBits = 8 then
          begin
            if FEepromWriteEnabled then
              if FEepromOpcode = 0 then
                FillChar(FEeprom, SizeOf(FEeprom), Byte(FEepromShift))
              else
                FEeprom[FEepromAddress] := Byte(FEepromShift);
            // Programming completes immediately; DO reports ready. A new
            // instruction requires CS to fall before its start bit.
            FEepromOutput := True;
            FEepromPhase := T93C66Phase.Done;
          end;
        end;
    end;
  FEepromClock := Clock;
end;

procedure TMapperExtendedMemory.Reset;
begin
  inherited;
  if FHasEeprom then
    ResetEepromBus;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FSelect := 0;
  FMode := 0;
  FCounter := 0;
  FPending := False;
  FLocked := False;
  case FBoard of
    MAPPER_ACTION53:
      SetLength(FChrMemory, $8000);
    MAPPER_WAIXING162:
      begin
        FRegs[0] := 3;
        FRegs[3] := 7;
        UpdateOuter
      end;
    MAPPER_NANJING:
      begin
        FLocked := True;
        Prg32(0);
        Chr4(0, 0);
        Chr4(1, 0)
      end;
    MAPPER_WAIXING164:
      begin
        FRegs[0] := 15;
        Prg32(15)
      end;
    MAPPER_FDS_CONVERSION_103:
      Prg32(-1);
    MAPPER_RACERMATE:
      begin
        Chr4(0, 0);
        Chr4(1, 0)
      end;
    MAPPER_KAISER7022, MAPPER_MAGIC_KID_GOO_GOO:
      begin
        Prg16(0, 0);
        Prg16(1, 0)
      end;
    MAPPER_BANDAI_KARAOKE:
      Prg16(1, 7);
    MAPPER_MAGIC_FLOOR218:
      Prg32(0);
    MAPPER_DANCE2000:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
        Mirror(0)
      end;
    MAPPER_T262:
      begin
        Prg16(0, 0);
        Prg16(1, 7)
      end;
    MAPPER_KAISER7057, MAPPER_KAISER7031, MAPPER_KAISER7037, MAPPER_LH10, MAPPER_AX5705:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        Prg8(2, -2);
        Prg8(3, -1)
      end;
  end;
  if FBoard = MAPPER_MAGIC_KID_GOO_GOO then
    Mirror(0);
  if FBoard = MAPPER_KAISER7031 then
    Mirror(0);
  if FBoard = MAPPER_AX5705 then
    for var i := 0 to 7 do
      Chr1(i, 0);
  if FBoard = MAPPER_SPECIAL_174 then
    CpuWrite($8000, 0);
end;

procedure TMapperExtendedMemory.UpdateOuter;
var
  Bank, Mask, Mode, FixedSlot: Integer;
begin
  if FBoard = MAPPER_ACTION53 then
  begin
    Mode := FRegs[2] and 3;
    if Mode < 2 then
      Mirror(FMode + 2)
    else
      Mirror(Mode - 2);
    Chr8(FRegs[0] and 3);
    Mask := (2 shl ((FRegs[2] shr 4) and 3)) - 1;
    Bank := (FRegs[3] shl 1) and (511 xor Mask);
    if (FRegs[2] and 8) <> 0 then
    begin
      FixedSlot := (FRegs[2] shr 2) and 1;
      Prg16(1 - FixedSlot, Bank or (FRegs[1] and Mask));
      Prg16(FixedSlot, (FRegs[3] shl 1) or FixedSlot);
    end
    else
    begin
      Prg16(0, Bank or ((FRegs[1] shl 1) and Mask));
      Prg16(1, Bank or (((FRegs[1] shl 1) or 1) and Mask))
    end;
  end
  else if FBoard = MAPPER_WAIXING162 then
  begin
    Bank := (FRegs[2] and 15) shl 4;
    case FRegs[3] and 5 of
      0:
        Bank := Bank or (FRegs[0] and 12) or (FRegs[1] and 2);
      1:
        Bank := Bank or (FRegs[0] and 12);
      4:
        Bank := Bank or (FRegs[0] and 14) or ((FRegs[1] shr 1) and 1);
      5:
        Bank := Bank or (FRegs[0] and 15);
    end;
    Prg32(Bank);
  end
  else if FBoard = MAPPER_NANJING then
    Prg32((FRegs[0] and 15) or ((FRegs[2] and 15) shl 4));
end;

procedure TMapperExtendedMemory.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FLocked, SizeOf(FLocked));
  State.Field(FNameRam, SizeOf(FNameRam));
  if FBoard = MAPPER_WAIXING164 then
    if State.Version >= 18 then
    begin
      var HasEeprom := FHasEeprom;
      State.Field(HasEeprom, SizeOf(HasEeprom));
      if HasEeprom <> FHasEeprom then
        raise ENesException.Create('Snapshot belongs to a different mapper 164 memory layout');

      if FHasEeprom then
      begin
        State.Field(FEeprom, SizeOf(FEeprom));
        State.Field(FEepromClock, SizeOf(FEepromClock));
        State.Field(FEepromOutput, SizeOf(FEepromOutput));
        State.Field(FEepromWriteEnabled, SizeOf(FEepromWriteEnabled));
        State.Field(FEepromPhase, SizeOf(FEepromPhase));
        State.Field(FEepromBits, SizeOf(FEepromBits));
        State.Field(FEepromShift, SizeOf(FEepromShift));
        State.Field(FEepromAddress, SizeOf(FEepromAddress));
        State.Field(FEepromOpcode, SizeOf(FEepromOpcode));
      end;
    end
    else if FHasEeprom then
      raise ENesException.Create('Snapshot predates mapper 164 EEPROM support');
end;

function TMapperExtendedMemory.SmallPrgRead(Address: UInt16; out Value: Byte): Boolean;
var
  Bank, Offset: Integer;
begin
  Result := False;
  Offset := 0;
  case FBoard of
    MAPPER_KAISER7057:
      if Address >= $6000 then
      begin
        if Address < $8000 then
          Bank := FRegs[4 + ((Address - $6000) shr 11)]
        else if Address < $A000 then
          Bank := FRegs[(Address - $8000) shr 11]
        else
          Bank := $34 + ((Address - $A000) shr 11);
        Offset := Bank * $800 + (Address and $7FF);
        Result := True;
      end;
    MAPPER_KAISER7031:
      if Address >= $6000 then
      begin
        if Address < $8000 then
          Bank := FRegs[(Address - $6000) shr 11]
        else
          Bank := 15 - ((Address - $8000) shr 11);
        Offset := Bank * $800 + (Address and $7FF);
        Result := True;
      end;
    MAPPER_KAISER7037:
      case Address shr 12 of
        6:
          begin
            Value := FPrgRam[Address and $FFF];
            Exit(True)
          end;
        7:
          begin
            Offset := 15 * $1000 + (Address and $FFF);
            Result := True
          end;
        10:
          begin
            Offset := Length(FPrgRom) - $4000 + (Address and $FFF);
            Result := True
          end;
        11:
          begin
            Value := FPrgRam[$1000 + (Address and $FFF)];
            Exit(True)
          end;
      end;
    MAPPER_LH10:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Offset := Length(FPrgRom) - $4000 + (Address and $1FFF);
        Result := True
      end
      else if (Address >= $C000) and (Address < $E000) then
      begin
        Value := FPrgRam[Address and $1FFF];
        Exit(True)
      end;
  end;
  if Result then
    Value := FPrgRom[Offset mod Length(FPrgRom)];
end;

function TMapperExtendedMemory.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FHasEeprom then
  begin
    if (Address and $FC00) = $5400 then
    begin
      Value := Ord(not FEepromOutput) shl 2; // Inverted DO at $5400-$57FF.
      Exit(True);
    end;

    if (Address >= $6000) and (Address < $8000) then
    begin
      if Length(FPrgRam) = 0 then
        Exit(False);
      Value := FPrgRam[(Address - $6000) mod Length(FPrgRam)];
      Exit(True);
    end;
  end;
  if (FBoard = MAPPER_NANJING) and (Address >= $5000) and (Address < $6000) then
  begin
    case Address and $7700 of
      $5100:
        Value := Byte(FRegs[3] or FRegs[1] or FRegs[0] or (FRegs[2] xor $FF));
      $5500:
        if FLocked then
          Value := Byte(FRegs[3] or FRegs[0])
        else
          Value := 0;
    else
      Value := 4
    end;
    Exit(True);
  end;

  if SmallPrgRead(Address, Value) then
    Exit(True);

  if (FBoard = MAPPER_KAISER7022) and (Address = $FFFC) then
  begin
    Prg16(0, FRegs[0]);
    Prg16(1, FRegs[0]);
    Chr8(FRegs[0])
  end;
  if FBoard = MAPPER_FDS_CONVERSION_103 then
  begin
    if (Address >= $6000) and (Address < $8000) then
    begin
      if FMode = 0 then
        Value := FPrgRam[Address - $6000]
      else
        Value := FPrgRom[(FRegs[0] * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
      Exit(True);
    end;
    if (Address >= $B800) and (Address < $D800) and (FMode = 0) then
    begin
      Value := FPrgRam[$2000 + Address - $B800];
      Exit(True)
    end;
  end;

  if (FBoard = MAPPER_BANDAI_KARAOKE) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FCpuOpenBus and $F8;
    Exit(True)
  end;

  if (FBoard = MAPPER_BANDAI_KARAOKE) and (Address >= $8000) and (Address < $C000) and (FMode <> 0) then
    Exit(False);

  if (FBoard = MAPPER_DANCE2000) and (Address >= $8000) and ((FRegs[0] and $40) <> 0) then
    Exit(False);

  Result := inherited CpuRead(Address, Value);
end;

function TMapperExtendedMemory.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
var
  Slot, Shift, Bank: Integer;
  Bus: Byte;
begin
  if FHasEeprom then
  begin
    if (Address and $FF00) = $5200 then
    begin
      WriteEeprom(Value);
      Exit(True);
    end;

    if (Address >= $6000) and (Address < $8000) then
    begin
      if Length(FPrgRam) = 0 then
        Exit(False);
      FPrgRam[(Address - $6000) mod Length(FPrgRam)] := Value;
      Exit(True);
    end;
  end;
  Result := True;
  case FBoard of
    MAPPER_ACTION53:
      if (Address >= $5000) and (Address < $6000) then
        FSelect := ((Value and $80) shr 6) or (Value and 1)
      else if Address >= $8000 then
      begin
        if FSelect < 2 then
          FMode := (Value shr 4) and 1
        else if FSelect = 2 then
          FMode := Value and 1;
        FRegs[FSelect] := Value;
        UpdateOuter;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_WAIXING162, MAPPER_NANJING, MAPPER_WAIXING164:
      if (Address >= $5000) and (Address < $6000) then
      begin
        if FBoard = MAPPER_WAIXING164 then
        begin
          case Address and $7300 of
            $5000:
              FRegs[0] := (FRegs[0] and $F0) or (Value and 15);
            $5100:
              FRegs[0] := (FRegs[0] and 15) or ((Value and 15) shl 4);
          end;
          Prg32(FRegs[0]);
        end
        else if (FBoard = MAPPER_NANJING) and (Address = $5101) then
        begin
          if (FRegs[4] <> 0) and (Value = 0) then
            FLocked := not FLocked;
          FRegs[4] := Value
        end
        else if (FBoard = MAPPER_NANJING) and ((Address and $7300) = $5100) and (Value = 6) then
          Prg32(3)
        else
        begin
          FRegs[(Address shr 8) and 3] := Value;
          if (FBoard = MAPPER_NANJING) and ((Address and $7300) = $5000) and ((Value and $80) = 0) and (FCounter < 128) then
          begin
            Chr4(0, 0);
            Chr4(1, 1)
          end;
          UpdateOuter;
        end;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_FDS_CONVERSION_103:
      if (Address >= $6000) and (Address < $8000) then
        FPrgRam[Address - $6000] := Value
      else if (Address >= $B800) and (Address < $D800) then
        FPrgRam[$2000 + Address - $B800] := Value
      else
        case Address and $F000 of
          $8000:
            FRegs[0] := Value and 15;
          $E000:
            Mirror(Ord((Value and 8) <> 0));
          $F000:
            FMode := Value and $10;
        else
          Exit(False)
        end;
    MAPPER_RACERMATE:
      if Address >= $8000 then
        if Address < $C000 then
        begin
          Prg16(0, (Value shr 6) and 3);
          Chr4(1, Value and 15)
        end
        else
        begin
          FCounter := 1024;
          FPending := False
        end
      else
        Exit(False);
    MAPPER_SPECIAL_174:
      if Address >= $8000 then
      begin
        Bank := (Address shr 4) and 7;
        if (Address and $80) <> 0 then
        begin
          Prg16(0, Bank and $FE);
          Prg16(1, Bank or 1)
        end
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end;
        Chr8((Address shr 1) and 7);
        Mirror(Address and 1);
      end
      else
        Exit(False);
    MAPPER_KAISER7022:
      case Address and $F000 of
        $8000:
          Mirror(Ord((Value and 4) <> 0));
        $A000:
          FRegs[0] := Value and 15;
      else
        Exit(False)
      end;
    MAPPER_BANDAI_KARAOKE:
      if Address >= $8000 then
      begin
        if inherited CpuRead(Address, Bus) then
          Value := Value and Bus;
        Bank := Value and 7;
        FMode := 0;
        if (Value and $10) = 0 then
          if Length(FPrgRom) >= $40000 then
            Bank := Bank or 8
          else
            FMode := 1;
        Prg16(0, Bank);
        Mirror(Ord((Value and $20) <> 0));
      end
      else
        Exit(False);
    MAPPER_MAGIC_KID_GOO_GOO:
      if Address >= $8000 then
        if (Address and $A000) = $A000 then
          Chr2(Address and 3, Value)
        else if Address < $A000 then
          Prg16(0, Value and 7)
        else
          Prg16(0, (Value and 7) or 8)
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_T262:
      if Address >= $8000 then
      begin
        if not FLocked then
        begin
          FRegs[0] := ((Address and $60) shr 2) or ((Address and $100) shr 3);
          FMode := Address and $80;
          FLocked := (Address and $2000) <> 0;
          Mirror((Address shr 1) and 1);
        end;
        Prg16(0, FRegs[0] or (Value and 7));
        if FMode <> 0 then
          Prg16(1, FRegs[0] or (Value and 7))
        else
          Prg16(1, FRegs[0] or 7);
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_KAISER7057:
      if (Address >= $B000) and (Address < $F000) then
      begin
        Slot := ((Address shr 12) - 11) * 2 + ((Address shr 1) and 1);
        Shift := (Address and 1) * 4;
        FRegs[Slot] := (FRegs[Slot] and ($FF xor ($F shl Shift))) or ((Value and 15) shl Shift);
      end
      else if (Address >= $8000) and (Address < $A000) then
        Mirror(1 - (Value and 1))
      else
        Exit(False);
    MAPPER_KAISER7031:
      if Address >= $8000 then
        FRegs[(Address shr 11) and 3] := Value
      else
        Exit(False);
    MAPPER_KAISER7037, MAPPER_LH10:
      if ((FBoard = MAPPER_KAISER7037) and (((Address >= $6000) and (Address < $7000)) or ((Address >= $B000) and (Address < $C000)))) then
        FPrgRam[(Ord(Address >= $B000) * $1000) + (Address and $FFF)] := Value
      else if (FBoard = MAPPER_LH10) and (Address >= $C000) and (Address < $E000) then
        FPrgRam[Address and $1FFF] := Value
      else if (Address >= $8000) and ((FBoard = MAPPER_LH10) or (Address < $A000) or (Address >= $C000)) then
      begin
        if (Address and 1) = 0 then
          FSelect := Value and 7
        else
        begin
          FRegs[FSelect] := Value;
          if FSelect >= 6 then
            Prg8((FSelect - 6) * Ord(FBoard = MAPPER_KAISER7037) + FSelect - 6, Value)
        end;
      end
      else
        Exit(False);
    MAPPER_DANCE2000:
      if (Address = $5000) or (Address = $5200) then
      begin
        if Address = $5000 then
          FRegs[0] := Value
        else
          FMode := Value;
        if (Address = $5200) and ((FMode and 4) = 0) then
          Exit(True);
        Mirror(FMode and 1);
        if (FMode and 4) <> 0 then
          Prg32(FRegs[0] and 7)
        else
        begin
          Prg16(0, FRegs[0] and 15);
          Prg16(1, 0)
        end;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_AX5705:
      case Address and $F00F of
        $8000:
          Prg8(0, ((Value and 2) shl 2) or ((Value and 8) shr 2) or (Value and 5));
        $A000:
          Prg8(1, ((Value and 2) shl 2) or ((Value and 8) shr 2) or (Value and 5));
        $8008:
          Mirror(Value and 1);
      else
        case Address and $F00E of
          $A008:
            Slot := 0;
          $A00A:
            Slot := 1;
          $C000:
            Slot := 2;
          $C002:
            Slot := 3;
          $C008:
            Slot := 4;
          $C00A:
            Slot := 5;
          $E000:
            Slot := 6;
          $E002:
            Slot := 7;
        else
          Exit(False)
        end;
        Shift := (Address and 1) * 4;
        if Shift <> 0 then
          Value := (Value and 9) or ((Value and 2) shl 1) or ((Value and 4) shr 1);
        FRegs[Slot] := (FRegs[Slot] and ($FF xor ($F shl Shift))) or ((Value and 15) shl Shift);
        Chr1(Slot, FRegs[Slot]);
      end;
  else
    Exit(inherited CpuWrite(Address, Value))
  end;
end;

function TMapperExtendedMemory.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
var
  Slot, Bank: Integer;
begin
  if (FBoard = MAPPER_MAGIC_FLOOR218) and (Address < $3F00) then
  begin
    Slot := $800;
    if FMirror = TMirrorMode.Vertical then
      Slot := $400;
    if FMirror = TMirrorMode.Single0 then
      Slot := $1000;
    if FMirror = TMirrorMode.Single1 then
      Slot := $2000;
    Value := FNameRam[Ord((Address and Slot) <> 0) * $400 + (Address and $3FF)];
    Exit(True);
  end;

  if (FBoard = MAPPER_KAISER7037) and (Address >= $2000) and (Address < $3F00) then
  begin
    Slot := (Address shr 10) and 3;
    case Slot of
      0:
        Bank := FRegs[2];
      1:
        Bank := FRegs[4];
      2:
        Bank := FRegs[3];
    else
      Bank := FRegs[5]
    end;
    Value := FNameRam[(Bank and 1) * $400 + (Address and $3FF)];
    Exit(True);
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperExtendedMemory.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
var
  Slot, Bank: Integer;
begin
  if (FBoard = MAPPER_MAGIC_FLOOR218) and (Address < $3F00) then
  begin
    Slot := $800;
    if FMirror = TMirrorMode.Vertical then
      Slot := $400;
    if FMirror = TMirrorMode.Single0 then
      Slot := $1000;
    if FMirror = TMirrorMode.Single1 then
      Slot := $2000;
    FNameRam[Ord((Address and Slot) <> 0) * $400 + (Address and $3FF)] := Value;
    Exit(True);
  end;

  if (FBoard = MAPPER_KAISER7037) and (Address >= $2000) and (Address < $3F00) then
  begin
    Slot := (Address shr 10) and 3;
    case Slot of
      0:
        Bank := FRegs[2];
      1:
        Bank := FRegs[4];
      2:
        Bank := FRegs[3];
    else
      Bank := FRegs[5]
    end;
    FNameRam[(Bank and 1) * $400 + (Address and $3FF)] := Value;
    Exit(True);
  end;

  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperExtendedMemory.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if (FBoard = MAPPER_DANCE2000) and (Address >= $2000) and (Address < $3000) and ((FMode and 2) <> 0) then
    Chr4(0, (Address shr 11) and 1);
  if (FBoard = MAPPER_DANCE2000) and ((FMode and 2) = 0) then
    Chr4(0, 0);
end;

procedure TMapperExtendedMemory.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  if FBoard = MAPPER_NANJING then
    FCounter := Line;
  if (FBoard = MAPPER_NANJING) and ((FRegs[0] and $80) <> 0) then
    if Line = 128 then
    begin
      Chr4(0, 1);
      Chr4(1, 1)
    end
    else if Line = 240 then
    begin
      Chr4(0, 0);
      Chr4(1, 0)
    end;
end;

procedure TMapperExtendedMemory.ClockCpu;
begin
  if FBoard = MAPPER_RACERMATE then
  begin
    FCounter := (FCounter - 1) and $FFFF;
    if FCounter = 0 then
    begin
      FCounter := 1024;
      FPending := True
    end
  end;
end;

function TMapperExtendedMemory.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperExtendedMemory.GetSaveMemory: TByteArray;
begin
  if FHasEeprom then
  begin
    SetLength(Result, SizeOf(FEeprom));
    Move(FEeprom[0], Result[0], Length(Result));
  end
  else if FBoard = MAPPER_RACERMATE then
    Result := Copy(FChrMemory, $8000, $8000)
  else
    Result := inherited GetSaveMemory;
end;

procedure TMapperExtendedMemory.SetSaveMemory(const Data: TByteArray);
begin
  if FHasEeprom then
  begin
    if Length(Data) <> SizeOf(FEeprom) then
      raise ENesException.Create('Invalid mapper 164 EEPROM save size');

    Move(Data[0], FEeprom[0], SizeOf(FEeprom));
  end
  else if FBoard = MAPPER_RACERMATE then
  begin
    if Length(Data) <> $8000 then
      raise ENesException.Create('Invalid Racermate save size');

    Move(Data[0], FChrMemory[$8000], $8000);
  end
  else
    inherited;
end;

end.

