unit NES.Mapper.ExtendedIrq;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperExtendedIrq = class(TMapperBanked)
  private
    FBoard, FCounter, FLatch, FControl, FSelect, FWorkBank: Integer;
    FRegs: array[0..15] of Integer;
    FEnabled, FPending, FToggle, FA12: Boolean;
    FLowSince: UInt64;
    FNameRam: array[0..$7FF] of Byte;
    function RamOffset(Address: UInt16): Integer;
    procedure UpdateTaitoChr;
    procedure UpdateYoko;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function ConsumeDacWrite(out Value: UInt8): Boolean; override;
  end;

implementation

constructor TMapperExtendedIrq.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  if (Board = MAPPER_FFE_F4XXX) or (Board = MAPPER_FFE_F8XXX) then
    if HasChrRam then
      SetLength(FChrMemory, $8000);
  if (Board = MAPPER_TAITO_X1017) or (Board = MAPPER_TAITO_X1017_552) then
    SetLength(FPrgRam, $1400);
  if (Board = MAPPER_TAITO_X1005) or (Board = MAPPER_TAITO_X1005_207) then
    SetLength(FPrgRam, $80);
  Reset;
end;

procedure TMapperExtendedIrq.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FWorkBank, SizeOf(FWorkBank));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FToggle, SizeOf(FToggle));
  State.Field(FA12, SizeOf(FA12));
  State.Field(FLowSince, SizeOf(FLowSince));
  State.Field(FNameRam, SizeOf(FNameRam));
end;

procedure TMapperExtendedIrq.Reset;
begin
  inherited;
  FCounter := 0;
  FLatch := 0;
  FControl := 0;
  FSelect := 0;
  FWorkBank := -1;
  FEnabled := False;
  FPending := False;
  FToggle := False;
  FA12 := False;
  FLowSince := 0;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FRamEnabled := (FBoard = MAPPER_FFE_F4XXX) or (FBoard = MAPPER_FFE_F8XXX) or (FBoard = MAPPER_KAISER_KS202_56) or (FBoard = MAPPER_KAISER_KS202_142);
  case FBoard of
    MAPPER_YOKO:
      UpdateYoko;
    MAPPER_CITY_FIGHTER:
      begin
        Prg32(0);
        Prg8(2, 0);
        Mirror(0);
        for var i := 0 to 7 do
          Chr1(i, 0)
      end;
    MAPPER_FFE_F4XXX:
      begin
        Prg16(0, 0);
        Prg16(1, 7);
        FControl := 1
      end;
    MAPPER_FFE_F8XXX:
      Prg32(-1);
    MAPPER_IRQ_106:
      for var i := 0 to 3 do
        Prg8(i, -1);
    MAPPER_IRQ_117:
      Prg32(-1);
    MAPPER_IRQ_222:
      begin
        Prg8(2, -2);
        Prg8(3, -1)
      end;
    MAPPER_KAISER7017:
      begin
        Prg16(0, 0);
        Prg16(1, 2);
        Mirror(0)
      end;
    MAPPER_SMB2J:
      begin
        Prg32(0);
        FRamEnabled := False
      end;
    MAPPER_JY_35, MAPPER_KAISER_KS202_56, MAPPER_KAISER_KS202_142, MAPPER_TAITO_X1005, MAPPER_TAITO_X1017, MAPPER_TAITO_X1005_207, MAPPER_TAITO_X1017_552:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        Prg8(2, 0);
        Prg8(3, -1)
      end;
    MAPPER_SMB2J_40:
      begin
        FWorkBank := 6;
        Prg8(0, 4);
        Prg8(1, 5);
        Prg8(2, 0);
        Prg8(3, 7)
      end;
    MAPPER_SMB2J_43:
      begin
        FWorkBank := 2;
        Prg8(0, 1);
        Prg8(1, 0);
        Prg8(2, 0);
        Prg8(3, 9)
      end;
    MAPPER_SMB2J_50:
      begin
        FWorkBank := 15;
        Prg8(0, 8);
        Prg8(1, 9);
        Prg8(2, 0);
        Prg8(3, 11)
      end;
    MAPPER_IREM_H3001:
      begin
        Prg8(0, 0);
        Prg8(1, 1);
        Prg8(2, $FE);
        Prg8(3, -1)
      end;
  end;
end;

function TMapperExtendedIrq.RamOffset(Address: UInt16): Integer;
begin
  Result := -1;
  if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) then
  begin
    if (Address >= $7F00) and (Address <= $7FFF) and (FRegs[8] = $A3) then
      Result := Address and $7F;
  end
  else if (FBoard = MAPPER_TAITO_X1017) or (FBoard = MAPPER_TAITO_X1017_552) then
  begin
    if (Address >= $6000) and (Address < $6800) and (FRegs[7] = $CA) then
      Result := Address - $6000;
    if (Address >= $6800) and (Address < $7000) and (FRegs[8] = $69) then
      Result := Address - $6000;
    if (Address >= $7000) and (Address < $7400) and (FRegs[9] = $84) then
      Result := Address - $6000;
  end;
end;

function TMapperExtendedIrq.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_YOKO) and (Address >= $5000) and (Address < $6000) then
  begin
    if Address < $5400 then
      Value := FCpuOpenBus and $FC
    else
      Value := FRegs[8 + (Address and 3)];
    Exit(True);
  end;

  if (FBoard = MAPPER_KAISER7017) and (Address = $4030) then
  begin
    Value := Ord(FPending);
    FPending := False;
    Exit(True);
  end;

  if (FBoard = MAPPER_SMB2J) and (Address >= $5000) and (Address < $8000) then
  begin
    Value := FPrgRom[(Length(FPrgRom) - $3000 + Address - $5000) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (FBoard = MAPPER_SMB2J_43) and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FPrgRom[($10000 + (Address and $FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (Address >= $6000) and (Address < $8000) and (FWorkBank >= 0) then
  begin
    Value := FPrgRom[(FWorkBank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) or (FBoard = MAPPER_TAITO_X1017) or (FBoard = MAPPER_TAITO_X1017_552) then
    if Address < $8000 then
    begin
      var Offset := RamOffset(Address);
      Result := Offset >= 0;
      if Result then
        Value := FPrgRam[Offset];
      Exit;
    end;

  Result := inherited CpuRead(Address, Value);
end;

procedure TMapperExtendedIrq.UpdateTaitoChr;
begin
  var Swap := (FRegs[6] and 2) shl 1;
  if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) then
    Swap := 0;
  for var i := 0 to 7 do
  begin
    var Bank: Integer;
    if i < 4 then
      if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) then
        Bank := FRegs[i shr 1] + (i and 1)
      else
        Bank := (FRegs[i shr 1] and $FE) or (i and 1)
    else
      Bank := FRegs[i - 2];
    Chr1(i xor Swap, Bank);
  end;
end;

function TMapperExtendedIrq.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  Map43: array[0..7] of Byte = (4, 3, 5, 3, 6, 3, 7, 3);
var
  Reg, Slot: Integer;
begin
  Result := True;
  case FBoard of
    MAPPER_YOKO:
      if (Address >= $5400) and (Address < $6000) then
        FRegs[8 + (Address and 3)] := Value
      else if Address >= $8000 then
      begin
        case Address and $8C17 of
          $8000:
            FSelect := Value;
          $8400:
            FControl := Value;
          $8800:
            begin
              FCounter := (FCounter and $FF00) or Value;
              FPending := False
            end;
          $8801:
            begin
              FCounter := (FCounter and $FF) or (Value shl 8);
              FEnabled := (FControl and $80) <> 0
            end;
          $8C00..$8C02:
            FRegs[Address and 3] := Value;
          $8C10..$8C13:
            FRegs[3 + (Address and 3)] := Value;
        end;
        UpdateYoko;
      end
      else
        Exit(False);
    MAPPER_CITY_FIGHTER:
      if Address >= $8000 then
      begin
        case Address and $F00C of
          $9000:
            begin
              FSelect := Value and 12;
              Mirror(Value and 3)
            end;
          $9004, $9008, $900C:
            if (Address and $800) <> 0 then
              FRegs[15] := ((Value and 15) shl 3) or $100
            else
              FSelect := Value and 12;
          $C000, $C004, $C008, $C00C:
            FControl := Value and 1;
          $F000:
            FCounter := (FCounter and $1E0) or ((Value and 15) shl 1);
          $F004:
            FCounter := (FCounter and $1E) or ((Value and 15) shl 5);
          $F008:
            begin
              FEnabled := (Value and 2) <> 0;
              FPending := False
            end;
        else
          case Address and $F000 of
            $D000:
              Slot := 0;
            $A000:
              Slot := 2;
            $B000:
              Slot := 4;
            $E000:
              Slot := 6;
          else
            Exit(True);
          end;
          Slot := Slot + ((Address shr 3) and 1);
          var Shift := Address and 4;
          FRegs[Slot] := (FRegs[Slot] and ($FF xor (15 shl Shift))) or ((Value and 15) shl Shift);
          Chr1(Slot, FRegs[Slot]);
        end;
        Prg32(FSelect shr 2);
        if FControl = 0 then
          Prg8(2, FSelect);
      end
      else
        Exit(False);
    MAPPER_IRQ_106:
      if Address >= $8000 then
        case Address and 15 of
          0, 2:
            Chr1(Address and 15, Value and $FE);
          1, 3:
            Chr1(Address and 15, Value or 1);
          4..7:
            Chr1(Address and 15, Value);
          8, 11:
            Prg8((Address and 15) - 8, (Value and 15) or $10);
          9, 10:
            Prg8((Address and 15) - 8, Value and 31);
          13:
            begin
              FEnabled := False;
              FCounter := 0;
              FPending := False
            end;
          14:
            FCounter := (FCounter and $FF00) or Value;
          15:
            begin
              FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
              FEnabled := True
            end;
        end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_IRQ_117:
      case Address of
        $8000..$8003:
          Prg8(Address and 3, Value);
        $A000..$A007:
          Chr1(Address and 7, Value);
        $C001:
          FLatch := Value;
        $C002:
          FPending := False;
        $C003:
          begin
            FCounter := FLatch;
            FControl := 1
          end;
        $D000:
          Mirror(Value and 1);
        $E000:
          begin
            FEnabled := (Value and 1) <> 0;
            FPending := False
          end;
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_IRQ_222:
      case Address and $F003 of
        $8000:
          Prg8(0, Value);
        $9000:
          Mirror(Value and 1);
        $A000:
          Prg8(1, Value);
        $B000, $B002, $C000, $C002, $D000, $D002, $E000, $E002:
          Chr1(((Address shr 12) - 11) * 2 + ((Address shr 1) and 1), Value);
        $F000:
          begin
            FCounter := Value;
            FPending := False
          end;
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_KAISER7017:
      if (Address >= $4020) and (Address < $6000) then
      begin
        if (Address and $FF00) = $4A00 then
          FRegs[0] := ((Address shr 2) and 3) or ((Address shr 4) and 4)
        else if (Address and $FF00) = $5100 then
        begin
          Prg16(0, FRegs[0]);
          Mirror(FRegs[1])
        end
        else
          case Address of
            $4020:
              begin
                FCounter := (FCounter and $FF00) or Value;
                FPending := False
              end;
            $4021:
              begin
                FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
                FEnabled := True;
                FPending := False
              end;
            $4025:
              FRegs[1] := (Value shr 3) and 1;
          end;
      end
      else
        Exit(False);
    MAPPER_SMB2J:
      case Address of
        $4022:
          if Length(FPrgRom) >= $10000 then
          begin
            Prg16(0, Value and 1);
            Prg16(1, (Value and 1) + 1)
          end;
        $4122:
          begin
            FEnabled := (Value and 3) <> 0;
            FCounter := 0;
            FPending := False
          end;
      else
        Exit(False);
      end;
    MAPPER_FFE_F4XXX, MAPPER_FFE_F8XXX:
      begin
        case Address of
          $42FE:
            begin
              FControl := Ord((Value and $80) = 0);
              Mirror(2 + ((Value shr 4) and 1))
            end;
          $42FF:
            Mirror((Value shr 4) and 1);
          $4501:
            begin
              FEnabled := False;
              FPending := False
            end;
          $4502:
            begin
              FCounter := (FCounter and $FF00) or Value;
              FPending := False
            end;
          $4503:
            begin
              FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
              FEnabled := True;
              FPending := False
            end;
        else
          if (FBoard = MAPPER_FFE_F4XXX) and (Address >= $8000) then
          begin
            if FHasChrRam or (FControl <> 0) then
            begin
              Prg16(0, Value shr 2);
              Value := Value and 3
            end;
            Chr8(Value);
          end
          else if (FBoard = MAPPER_FFE_F8XXX) and (Address >= $4504) and (Address <= $4507) then
            Prg8(Address - $4504, Value)
          else if (FBoard = MAPPER_FFE_F8XXX) and (Address >= $4510) and (Address <= $4517) then
            Chr1(Address - $4510, Value)
          else
            Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_JY_35:
      begin
        case Address and $F007 of
          $8000..$8003:
            Prg8(Address and 3, Value);
          $9000..$9007:
            Chr1(Address and 7, Value);
          $C002:
            begin
              FEnabled := False;
              FPending := False
            end;
          $C003:
            FEnabled := True;
          $C005:
            FCounter := Value;
          $D001:
            Mirror(Value and 1);
        else
          Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_SMB2J_40:
      if Address >= $8000 then
        case Address and $E000 of
          $8000:
            begin
              FCounter := 0;
              FPending := False
            end;
          $A000:
            FCounter := 4096;
          $E000:
            Prg8(2, Value);
        end
      else
        Exit(False);
    MAPPER_SMB2J_43:
      begin
        case Address and $F1FF of
          $4022:
            Prg8(2, Map43[Value and 7]);
          $4120:
            begin
              if (Value and 1) <> 0 then
              begin
                FWorkBank := 0;
                Prg8(3, 8)
              end
              else
              begin
                FWorkBank := 2;
                Prg8(3, 9)
              end
            end;
          $4122, $8122:
            begin
              FEnabled := (Value and 1) <> 0;
              FCounter := 0;
              FPending := False
            end;
        else
          Exit(False);
        end;
      end;
    MAPPER_SMB2J_50:
      if (Address >= $4020) and (Address < $6000) then
      begin
        case Address and $4120 of
          $4020:
            Prg8(2, (Value and 8) or ((Value and 1) shl 2) or ((Value and 6) shr 1));
          $4120:
            begin
              FEnabled := (Value and 1) <> 0;
              if not FEnabled then
              begin
                FCounter := 0;
                FPending := False
              end
            end;
        end;
      end
      else
        Exit(False);
    MAPPER_KAISER_KS202_56, MAPPER_KAISER_KS202_142:
      if Address >= $8000 then
      begin
        Reg := Address shr 12;
        case Reg of
          8..11:
            begin
              Slot := (Reg - 8) * 4;
              FLatch := (FLatch and ($FFFF xor ($F shl Slot))) or ((Value and 15) shl Slot)
            end;
          12:
            begin
              FEnabled := (Value and 2) <> 0;
              if FEnabled then
                FCounter := FLatch;
              FPending := False
            end;
          13:
            FPending := False;
          14:
            FSelect := (Value and 7) - 1;
          15:
            begin
              if (FSelect >= 0) and (FSelect <= 3) then
                FRegs[FSelect] := (FRegs[FSelect] and $10) or (Value and 15);
              if FSelect = 4 then
                FControl := Value and 4;
              if FBoard = MAPPER_KAISER_KS202_56 then
                case Address and $FC00 of
                  $F000:
                    FRegs[Address and 3] := (Value and $10) or (FRegs[Address and 3] and 15);
                  $F800:
                    Mirror(1 - (Value and 1));
                  $FC00:
                    Chr1(Address and 7, Value);
                end;
              FWorkBank := -1;
              if FControl <> 0 then
                FWorkBank := FRegs[3];
              for Slot := 0 to 2 do
                Prg8(Slot, FRegs[Slot]);
            end;
        end;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_IREM_H3001:
      begin
        case Address of
          $8000:
            Prg8(0, Value);
          $A000:
            Prg8(1, Value);
          $C000:
            Prg8(2, Value);
          $9001:
            Mirror(Value shr 7);
          $9003:
            begin
              FEnabled := (Value and $80) <> 0;
              FPending := False
            end;
          $9004:
            begin
              FCounter := FLatch;
              FPending := False
            end;
          $9005:
            FLatch := (FLatch and $FF) or (Integer(Value) shl 8);
          $9006:
            FLatch := (FLatch and $FF00) or Value;
          $B000..$B007:
            Chr1(Address and 7, Value);
        else
          Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_SUNSOFT3:
      begin
        case Address and $F800 of
          $8800, $9800, $A800, $B800:
            Chr2((Address shr 12) - 8, Value);
          $C800:
            begin
              if FToggle then
                FCounter := (FCounter and $FF00) or Value
              else
                FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
              FToggle := not FToggle
            end;
          $D800:
            begin
              FEnabled := (Value and $10) <> 0;
              FToggle := False;
              FPending := False
            end;
          $E800:
            Mirror(Value);
          $F800:
            Prg16(0, Value);
        else
          Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_TAITO_X1005, MAPPER_TAITO_X1017, MAPPER_TAITO_X1005_207, MAPPER_TAITO_X1017_552:
      begin
        if (Address >= $7EF0) and (Address <= $7EFF) then
        begin
          Reg := Address and 15;
          if Reg < 6 then
          begin
            FRegs[Reg] := Value;
            UpdateTaitoChr
          end
          else if (FBoard = MAPPER_TAITO_X1017) or (FBoard = MAPPER_TAITO_X1017_552) then
            case Reg of
              6:
                begin
                  FRegs[6] := Value;
                  Mirror(1 - (Value and 1));
                  UpdateTaitoChr
                end;
              7..9:
                FRegs[Reg] := Value;
              10..12:
                begin
                  Slot := Value shr 2;
                  if FBoard = MAPPER_TAITO_X1017_552 then
                  begin
                    Slot := 0;
                    for var i := 0 to 5 do
                      Slot := Slot or (((Value shr i) and 1) shl (5 - i))
                  end;
                  Prg8(Reg - 10, Slot);
                end;
            end
          else
            case Reg of
              6, 7:
                if FBoard = MAPPER_TAITO_X1005 then
                  Mirror(1 - (Value and 1));
              8, 9:
                FRegs[8] := Value;
              10..15:
                Prg8((Reg - 10) shr 1, Value);
            end;
          Exit;
        end;
        Slot := RamOffset(Address);
        Result := Slot >= 0;
        if Result then
          FPrgRam[Slot] := Value;
      end;
  else
    Result := inherited CpuWrite(Address, Value);
  end;
end;

function TMapperExtendedIrq.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_TAITO_X1005_207) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[((FRegs[(Address shr 11) and 1] shr 7) * $400) + (Address and $3FF)];
    Exit(True)
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperExtendedIrq.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_TAITO_X1005_207) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[((FRegs[(Address shr 11) and 1] shr 7) * $400) + (Address and $3FF)] := Value;
    Exit(True)
  end;

  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperExtendedIrq.ClockCpu;
begin
  if FBoard = MAPPER_SMB2J_40 then
  begin
    if FCounter > 0 then
    begin
      Dec(FCounter);
      if FCounter = 0 then
        FPending := True
    end;
    Exit
  end;

  if not FEnabled then
    Exit;

  case FBoard of
    MAPPER_YOKO:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = 0 then
        begin
          FCounter := $FFFF;
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_CITY_FIGHTER:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = 0 then
          FPending := True
      end;
    MAPPER_FFE_F4XXX, MAPPER_FFE_F8XXX, MAPPER_IRQ_106:
      begin
        FCounter := (FCounter + 1) and $FFFF;
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_KAISER7017:
      if FCounter > 0 then
      begin
        Dec(FCounter);
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_SMB2J:
      begin
        FCounter := (FCounter + 1) and $FFF;
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_SMB2J_43, MAPPER_SMB2J_50:
      begin
        Inc(FCounter);
        if FCounter = 4096 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_KAISER_KS202_56, MAPPER_KAISER_KS202_142:
      begin
        FCounter := (FCounter + 1) and $FFFF;
        if FCounter = $FFFF then
        begin
          FCounter := FLatch;
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_IREM_H3001:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_SUNSOFT3:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = $FFFF then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
  end;
end;

procedure TMapperExtendedIrq.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if not (FBoard in [MAPPER_JY_35, MAPPER_IRQ_117, MAPPER_IRQ_222]) then
    Exit;

  if (Address and $1000) = 0 then
  begin
    if FA12 then
      FLowSince := PpuCycle;
    FA12 := False
  end
  else if not FA12 then
  begin
    FA12 := True;
    if PpuCycle >= FLowSince + 8 then
      case FBoard of
        MAPPER_JY_35:
          if FEnabled then
          begin
            FCounter := (FCounter - 1) and $FF;
            if FCounter = 0 then
            begin
              FPending := True;
              FEnabled := False
            end
          end;
        MAPPER_IRQ_117:
          if FEnabled and (FControl <> 0) and (FCounter <> 0) then
          begin
            Dec(FCounter);
            if FCounter = 0 then
            begin
              FPending := True;
              FControl := 0
            end
          end;
        MAPPER_IRQ_222:
          if FCounter <> 0 then
          begin
            Inc(FCounter);
            if FCounter >= 240 then
            begin
              FPending := True;
              FCounter := 0
            end
          end;
      end;
  end;
end;

function TMapperExtendedIrq.IrqPending: Boolean;
begin
  Result := FPending
end;

procedure TMapperExtendedIrq.UpdateYoko;
begin
  Mirror(FControl and 1);
  for var i := 0 to 3 do
    Chr2(i, FRegs[3 + i]);
  if (FControl and $10) <> 0 then
  begin
    var Outer := (FSelect and 8) shl 1;
    for var i := 0 to 2 do
      Prg8(i, Outer or (FRegs[i] and 15));
    Prg8(3, Outer or 15)
  end
  else if (FControl and 8) <> 0 then
    Prg32(FSelect shr 1)
  else
  begin
    Prg16(0, FSelect);
    Prg16(1, -1)
  end;
end;

function TMapperExtendedIrq.ConsumeDacWrite(out Value: UInt8): Boolean;
begin
  Result := (FBoard = MAPPER_CITY_FIGHTER) and ((FRegs[15] and $100) <> 0);
  Value := FRegs[15] and $FF;
  FRegs[15] := 0
end;

end.


