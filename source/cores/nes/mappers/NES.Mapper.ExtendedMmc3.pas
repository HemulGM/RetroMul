unit NES.Mapper.ExtendedMmc3;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Mmc3;

type
  TMapperExtendedMmc3 = class(TMapperMmc3)
  private
    FBoard: Integer;
    FResetBank: Integer;
    FStarted: Boolean;
    FRegs: array[0..63] of Integer;
    FChrExtra: TByteArray;
    FPrgExtra: array[0..$7FFF] of Byte;
    FSubmapper: Integer;
    FChrRam: array[0..$1FFF] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    FNameBanks: array[0..3] of Byte;
    procedure UpdateProtection121;
    function PrgBank(Slot: Integer): Integer;
    function ChrBank(Address: UInt16): Integer;
    function ChrRamOffset(Bank: Integer): Integer;
    function PermuteChr(Bank: Integer): Integer;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    procedure CpuRamWrite(Address: UInt16; Value: UInt8); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

constructor TMapperExtendedMmc3.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FStarted := False;
  if Board = MAPPER_SACHEN_9602 then
  begin
    SetLength(FChrMemory, $8000);
    FHasChrRam := True
  end;
  if Board = MAPPER_MMC3_COOLBOY then
  begin
    SetLength(FChrMemory, $40000);
    FHasChrRam := True
  end;
  if Board = MAPPER_FK23C then
  begin
    SetLength(FChrExtra, $40000);
    if HasChrRam then
      SetLength(FChrMemory, $40000)
  end;
  Reset;
end;

procedure TMapperExtendedMmc3.Reset;
begin
  inherited;
  if FStarted and (FBoard = MAPPER_RESET_TXROM) then
    FResetBank := (FResetBank + 1) and 3;
  if FStarted and (FBoard = MAPPER_MMC3_STREET_HEROES) then
    FResetBank := FResetBank xor $FF;
  FStarted := True;
  FillChar(FRegs, SizeOf(FRegs), 0);
  if FBoard = MAPPER_MMC3_45 then
    FRegs[2] := 15;
  if FBoard = MAPPER_MMC3_121 then
    FRegs[3] := $80;
  if FBoard = MAPPER_MMC3_208 then
    FRegs[5] := 3;
  if FBoard = MAPPER_MMC3_215 then
    FRegs[1] := 3;
  if FBoard = MAPPER_MMC3_198 then
  begin
    FRegs[1] := 1;
    FRegs[2] := (Length(FPrgRom) div $2000) - 2;
    FRegs[3] := FRegs[2] + 1
  end;
  if FBoard = MAPPER_MMC3_199 then
  begin
    FRegs[0] := $FE;
    FRegs[1] := $FF;
    FRegs[2] := 1;
    FRegs[3] := 3
  end;
  if FBoard = MAPPER_MMC3_219 then
    for var i := 0 to 3 do
      FRegs[8 + i] := (Length(FPrgRom) div $2000) - 4 + i;
  if FBoard = MAPPER_TAITO_TC0690 then
  begin
    FRegs[0] := 0;
    FRegs[1] := 0
  end;
  if FBoard = MAPPER_MULTIMAPPER_116 then
  begin
    for var i := 0 to 3 do
      FRegs[8 + i] := $FF;
    for var i := 4 to 7 do
      FRegs[8 + i] := i;
    FRegs[2] := 1;
    FRegs[16] := 12;
    FBankRegisters[6] := $FC;
    FBankRegisters[7] := $FD;
  end;
  if FBoard = MAPPER_FK23C then
  begin
    FRegs[8] := $FE;
    FRegs[9] := $FF;
    FRegs[10] := $FF;
    FRegs[11] := $FF;
    if (Length(FPrgRom) = $100000) and (Length(FChrMemory) = $100000) then
      FRegs[4] := $20;
  end;
  FillChar(FNameBanks, SizeOf(FNameBanks), 0);
end;

procedure TMapperExtendedMmc3.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FChrRam, SizeOf(FChrRam));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FNameBanks, SizeOf(FNameBanks));
  State.Field(FResetBank, SizeOf(FResetBank));
  State.Field(FStarted, SizeOf(FStarted));
  if Length(FChrExtra) > 0 then
    State.Field(FChrExtra[0], Length(FChrExtra));
  if FBoard = MAPPER_FK23C then
    State.Field(FPrgExtra, SizeOf(FPrgExtra));
end;

function TMapperExtendedMmc3.PermuteChr(Bank: Integer): Integer;
begin
  Result :=
    (Bank and 3) or
    ((Bank shr 1) and 4) or
    ((Bank shr 4) and 8) or
    ((Bank shr 2) and $10) or
    ((Bank shl 3) and $20) or
    ((Bank shl 2) and $C0);
end;

function TMapperExtendedMmc3.PrgBank(Slot: Integer): Integer;
begin
  var OriginalSlot := Slot;
  if (FBankSelect and $40) <> 0 then
    if (Slot = 0) or (Slot = 2) then
      Slot := Slot xor 2;
  case Slot of
    0:
      Result := FBankRegisters[6];
    1:
      Result := FBankRegisters[7];
    2:
      Result := $FFFE;
  else
    Result := $FFFF;
  end;
  case FBoard of
    MAPPER_DRAGON_FIGHTER:
      if OriginalSlot = 0 then
        Result := FRegs[0] and 31;
    MAPPER_TAITO_TC0690:
      case OriginalSlot of
        0, 1:
          Result := FRegs[OriginalSlot];
        2:
          Result := $FFFE;
        3:
          Result := $FFFF
      end;
    MAPPER_MULTIMAPPER_116:
      case FRegs[0] and 3 of
        0:
          case OriginalSlot of
            0, 1:
              Result := FRegs[1 + OriginalSlot];
            2:
              Result := $FFFE;
            3:
              Result := $FFFF
          end;
        1:
          if Slot >= 2 then
            Result := $FE + Slot - 2;
        2, 3:
          begin
            var Bank := FRegs[19] and 15;
            if (FRegs[16] and 8) = 0 then
              Result := ((Bank and $FE) shl 1) + OriginalSlot
            else if (FRegs[16] and 4) <> 0 then
              if OriginalSlot < 2 then
                Result := (Bank shl 1) + OriginalSlot
              else
                Result := 30 + (OriginalSlot and 1)
            else if OriginalSlot < 2 then
              Result := OriginalSlot
            else
              Result := (Bank shl 1) + (OriginalSlot and 1);
          end;
      end;
    MAPPER_FK23C:
      begin
        var Mode := FRegs[0] and 7;
        if Mode = 3 then
          Result := (FRegs[4] shl 1) + (OriginalSlot and 1)
        else if Mode = 4 then
          Result := ((FRegs[4] and $FFE) shl 1) + OriginalSlot
        else if Mode <= 2 then
          if (FRegs[3] and 2) <> 0 then
          begin
            if Slot >= 2 then
              Result := FRegs[6 + Slot];
            Result := Result or (FRegs[4] shl 1)
          end
          else
          begin
            var Mask := $3F shr Mode;
            Result := (Result and Mask) or ((FRegs[4] shl 1) and not Mask)
          end;
      end;
    MAPPER_MMC3_COOLBOY:
      begin
        var Mask := (($3F or (FRegs[1] and $40) or ((FRegs[1] and $20) shl 2)) xor ((FRegs[0] and $40) shr 2)) xor ((FRegs[1] and $80) shr 2);
        var Outer := (FRegs[0] and 7) or ((FRegs[1] and $10) shr 1) or ((FRegs[1] and 12) shl 2) or ((FRegs[0] and $30) shl 2);
        if ((FRegs[3] and $40) <> 0) and (Result >= $FE) and ((FBankSelect and $40) <> 0) and (OriginalSlot in [1, 3]) then
          Result := 0;
        if (FRegs[3] and $10) = 0 then
          Result := ((Outer shl 4) and not Mask) or (Result and Mask)
        else
        begin
          Mask := Mask and $F0;
          var Extra := FRegs[3] and 14;
          if (FRegs[1] and 2) <> 0 then
            Extra := (FRegs[3] and 12) or ((OriginalSlot and 2));
          Result := ((Outer shl 4) and not Mask) or (Result and Mask) or Extra or (OriginalSlot and 1);
        end;
      end;
    MAPPER_MMC3_14:
      if (FRegs[0] and 2) = 0 then
        case OriginalSlot of
          0, 1:
            Result := FRegs[9 + OriginalSlot];
          2:
            Result := $FFFE;
          3:
            Result := $FFFF
        end;
    MAPPER_MMC3_121:
      begin
        if ((FRegs[5] and $3F) <> 0) and (OriginalSlot > 0) then
          Result := FRegs[3 - OriginalSlot];
        Result := (Result and 31) or ((FRegs[3] and $80) shr 2);
      end;
    MAPPER_MMC3_126:
      begin
        if (FRegs[3] and 3) <> 0 then
          Result := FBankRegisters[6] + (OriginalSlot and 1) + (Ord((FRegs[3] and 3) = 3) * (OriginalSlot shr 1) * 2);
        Result := (Result and (((not FRegs[0] shr 2) and $10) or 15)) or
          ((FRegs[0] and (6 or ((FRegs[0] and $40) shr 6))) shl 4) or ((FRegs[0] and $10) shl 3);
      end;
    MAPPER_MMC3_198:
      Result := FRegs[OriginalSlot];
    MAPPER_MMC3_199:
      if OriginalSlot >= 2 then
        Result := FRegs[OriginalSlot - 2];
    MAPPER_MMC3_208:
      Result := FRegs[5] * 4 + OriginalSlot;
    MAPPER_MMC3_215:
      begin
        var Mask := 31;
        var Extra := 0;
        if (FRegs[0] and $40) <> 0 then
        begin
          Mask := 15;
          Extra := FRegs[1] and $10
        end;
        if (FRegs[0] and $80) <> 0 then
        begin
          Result := ((FRegs[1] and 3) shl 4) or (FRegs[0] and (Mask shr 1)) or (Extra shr 1);
          Result := (Result shl 1) + (OriginalSlot and 1) + Ord((FRegs[0] and $20) <> 0) * (OriginalSlot shr 1) * 2;
        end
        else
          Result := ((FRegs[1] and 3) shl 5) or (Result and Mask) or Extra;
      end;
    MAPPER_MMC3_219:
      Result := FRegs[8 + OriginalSlot];
    MAPPER_MMC3_45:
      Result := (Result and ($3F xor (FRegs[3] and $3F))) or FRegs[1];
    MAPPER_MMC3_114:
      if (FRegs[0] and $80) <> 0 then
        Result := ((FRegs[0] and 15) shl 1) + (OriginalSlot and 1);
    MAPPER_MMC3_187:
      if (FRegs[0] and $80) = 0 then
        Result := Result and $3F
      else if (FRegs[0] and $20) = 0 then
        Result := ((FRegs[0] and 31) shl 1) + (OriginalSlot and 1)
      else if (FRegs[0] and $40) <> 0 then
        Result := (FRegs[0] and $1C) + OriginalSlot
      else
        Result := ((FRegs[0] and $1E) shl 1) + OriginalSlot;
    MAPPER_MMC3_224:
      begin
        if (FBankSelect and $40) <> 0 then
          case OriginalSlot of
            0:
              Result := $3E;
            1:
              Result := FBankRegisters[6] and $3F;
            2:
              Result := FBankRegisters[7] and $3F
          end;
        Result := (Result and $3F) or (FRegs[0] shl 6);
      end;
    MAPPER_UNL158_B:
      if (FRegs[0] and $80) = 0 then
        Result := Result and 15
      else if (FRegs[0] and $20) <> 0 then
        Result := ((FRegs[0] and 6) shl 1) + OriginalSlot
      else
        Result := ((FRegs[0] and 7) shl 1) + (OriginalSlot and 1);
    MAPPER_MMC3_BMC_F15:
      begin
        var Mode := (FRegs[0] shr 3) and 1;
        Result := ((FRegs[0] and (15 xor Mode)) shl 1) + ((OriginalSlot shr 1) * Mode * 2) + (OriginalSlot and 1)
      end;
    MAPPER_BMC_HPXX:
      if (FRegs[0] and 4) <> 0 then
        if (FRegs[0] and 15) = 4 then
          Result := ((FRegs[1] and 31) shl 1) + (OriginalSlot and 1)
        else
          Result := ((FRegs[1] and $1E) shl 1) + OriginalSlot
      else if (FRegs[0] and 2) <> 0 then
        Result := (Result and 15) or ((FRegs[1] and $18) shl 1)
      else
        Result := (Result and 31) or ((FRegs[1] and $10) shl 1);
    MAPPER_MMC3_BMC411120_C:
      if (FRegs[0] and 8) <> 0 then
        Result := ((((FRegs[0] shr 4) and 3) or 12) shl 2) + OriginalSlot
      else
        Result := (Result and 15) or ((FRegs[0] and 3) shl 4);
    MAPPER_RESET_TXROM:
      Result := (Result and 15) or (FResetBank shl 4);
    MAPPER_MMC3_MALI_SB:
      Result := (Result and 3) or ((Result and 8) shr 1) or ((Result and 4) shl 1);
    MAPPER_BMC8IN1:
      if (FRegs[0] and $10) <> 0 then
        Result := (Result and 15) or ((FRegs[0] and 12) shl 2)
      else
        Result := ((FRegs[0] and 15) shl 2) + OriginalSlot;
    MAPPER_BMC830118_C:
      begin
        if ((FRegs[0] and 12) = 12) and (OriginalSlot >= 2) then
          if (FBankSelect and $40) = 0 then
            Result := FBankRegisters[6 + (OriginalSlot and 1)]
          else if OriginalSlot = 2 then
            Result := $FFFE
          else
            Result := FBankRegisters[7];
        if ((FRegs[0] and 12) = 12) and (OriginalSlot >= 2) then
          Result := $32 or (Result and 15)
        else
          Result := ((FRegs[0] and 12) shl 2) or (Result and 15);
      end;
    MAPPER_BMC_GN45:
      Result := (Result and 15) or FRegs[0];
    MAPPER_SACHEN_9602:
      if Slot < 2 then
        Result := (Result and $3F) or (FRegs[1] shl 6)
      else
        Result := Result and $3F;
    MAPPER_MMC3_37:
      case FRegs[0] of
        0..2:
          Result := Result and 7;
        3:
          Result := (Result and 7) or 8;
        4..6:
          Result := (Result and 15) or $10;
        7:
          Result := (Result and 7) or $20;
      end;
    MAPPER_MMC3_44:
      if FRegs[0] < 6 then
        Result := (Result and 15) or (FRegs[0] shl 4)
      else
        Result := (Result and 31) or (FRegs[0] shl 4);
    MAPPER_MMC3_47:
      Result := (Result and 15) or ((FRegs[0] and 1) shl 4);
    MAPPER_MMC3_49:
      if (FRegs[0] and 1) <> 0 then
        Result := (Result and 15) or ((FRegs[0] and $C0) shr 2)
      else
        Result := ((FRegs[0] shr 4) and 3) * 4 + OriginalSlot;
    MAPPER_MMC3_52:
      if (FRegs[0] and 8) <> 0 then
        Result := (Result and 15) or ((FRegs[0] and 7) shl 4)
      else
        Result := (Result and 31) or ((FRegs[0] and 6) shl 4);
    MAPPER_MMC3_115:
      if (FRegs[0] and $80) <> 0 then
        if (FRegs[0] and $20) <> 0 then
          Result := ((FRegs[0] and $E) shl 1) + OriginalSlot
        else
          Result := ((FRegs[0] and 15) shl 1) + (OriginalSlot and 1);
    MAPPER_MMC3_123:
      if (FRegs[0] and $40) <> 0 then
      begin
        var Bank := (FRegs[0] and 5) or ((FRegs[0] and 8) shr 2) or ((FRegs[0] and $20) shr 2);
        if (FRegs[0] and 2) <> 0 then
          Result := ((Bank and $FE) shl 1) + OriginalSlot
        else
          Result := (Bank shl 1) + (OriginalSlot and 1);
      end;
    MAPPER_MMC3_134:
      Result := (Result and 31) or ((FRegs[0] and 2) shl 4);
    MAPPER_MMC3_189:
      Result := ((FRegs[0] or (FRegs[0] shr 4)) and 7) * 4 + OriginalSlot;
    MAPPER_MMC3_196:
      if FRegs[0] <> 0 then
        Result := FRegs[1] * 4 + OriginalSlot;
    MAPPER_MMC3_205:
      if FRegs[0] < 2 then
        Result := (Result and 31) or (FRegs[0] shl 4)
      else
        Result := (Result and 15) or (FRegs[0] shl 4);
    MAPPER_MMC3_249:
      if (FRegs[0] and 2) <> 0 then
      begin
        if Result < $20 then
          Result := (Result and 1) or ((Result shr 3) and 2) or ((Result shr 1) and 4) or ((Result shl 2) and $18)
        else
          Result := PermuteChr((Result - $20) and $FF);
      end;
  end;
  // Standard MMC3 registers ignore PRG bits 6-7, but outer-bank boards apply
  // their own masks before the physical address is wrapped.
  case FBoard of
    MAPPER_MMC3_CHR_RAM_74, MAPPER_TXSROM, MAPPER_MMC3_182, MAPPER_MMC3_CHR_RAM_191, MAPPER_MMC3_CHR_RAM_192, MAPPER_MMC3_CHR_RAM_194, MAPPER_MMC3_CHR_RAM_195, MAPPER_MMC3_197, MAPPER_MMC3_238, MAPPER_MMC3_254, MAPPER_MMC3_STREET_HEROES, MAPPER_MMC3_KOF97:
      if Slot < 2 then
        Result := Result and $3F;
  end;
  if Result = $FFFE then
    Result := (Length(FPrgRom) div $2000) - 2;
  if Result = $FFFF then
    Result := (Length(FPrgRom) div $2000) - 1;
  Result := Result mod (Length(FPrgRom) div $2000);
end;

function TMapperExtendedMmc3.ChrBank(Address: UInt16): Integer;
begin
  var Slot := Address shr 10;
  if FBoard = MAPPER_TAITO_TC0690 then
  begin
    if Slot < 4 then
      Exit(FRegs[2 + (Slot shr 1)] * 2 + (Slot and 1))
    else
      Exit(FRegs[Slot])
  end;
  if FBoard = MAPPER_MULTIMAPPER_116 then
    case FRegs[0] and 3 of
      0:
        Exit(FRegs[8 + Slot] or ((FRegs[0] and 4) shl 6));
      2, 3:
        if (FRegs[16] and $10) <> 0 then
          Exit(FRegs[17 + (Slot shr 2)] * 4 + (Slot and 3))
        else
          Exit((FRegs[17] and $FE) * 4 + Slot);
    end;

  if (FBoard = MAPPER_MMC3_14) and ((FRegs[0] and 2) = 0) then
    Exit(FRegs[1 + Slot]);

  if FBoard = MAPPER_MMC3_165 then
  begin
    var R := FRegs[12 + (Address shr 12)];
    if Address < $1000 then
      R := R
    else
      R := 2 + R * 2;
    Result := FBankRegisters[R];
    if Result = 0 then
      Exit(-1);
    Exit((Result and $FC) + (Slot and 3));
  end;

  if FBoard = MAPPER_MMC3_219 then
    Exit(FRegs[12 + Slot]);

  if FBoard = MAPPER_MMC3_197 then
  begin
    if (FBankSelect and $80) = 0 then
      if Slot < 4 then
        Exit(Integer(FBankRegisters[0]) * 2 + Slot)
      else
        Exit(Integer(FBankRegisters[2 + ((Slot - 4) shr 1)]) * 2 + (Slot and 1))
    else if Slot < 4 then
      Exit(Integer(FBankRegisters[2]) * 2 + Slot)
    else
      Exit(Integer(FBankRegisters[0]) * 2 + (Slot and 1));
  end;

  if (FBankSelect and $80) <> 0 then
    Slot := Slot xor 4;
  if Slot < 4 then
    Result := (FBankRegisters[Slot shr 1] and $FE) or (Slot and 1)
  else
    Result := FBankRegisters[Slot - 2];
  case FBoard of
    MAPPER_DRAGON_FIGHTER:
      if (Address shr 10) < 2 then
        Result := (((Result shr 1) xor FRegs[1]) shl 1) + ((Address shr 10) and 1)
      else if (Address shr 10) < 4 then
        Result := (((Result shr 1) or ((FRegs[2] and $40) shl 1)) shl 1) + ((Address shr 10) and 1)
      else
        Result := (FRegs[2] and $3F) * 4 + ((Address shr 10) - 4);
    MAPPER_MULTIMAPPER_116:
      Result := Result or ((FRegs[0] and 4) shl 6);
    MAPPER_FK23C:
      if (FRegs[0] and $40) <> 0 then
      begin
        var Mask := 0;
        if (FRegs[3] and $44) <> 0 then
          if (FRegs[0] and $10) <> 0 then
            Mask := 1
          else
            Mask := 3;
        Result := ((FRegs[2] or (FRegs[5] and Mask)) shl 3) + (Address shr 10);
      end
      else if (FRegs[3] and 2) <> 0 then
      begin
        case Slot of
          0:
            Result := FBankRegisters[0];
          1:
            Result := FRegs[10];
          2:
            Result := FBankRegisters[1];
          3:
            Result := FRegs[11]
        end;
        Result := Result or (FRegs[2] shl 3);
      end
      else
      begin
        var Mask := $FF;
        if (FRegs[0] and $10) <> 0 then
          Mask := $7F;
        Result := (Result and Mask) or ((FRegs[2] shl 3) and not Mask)
      end;
    MAPPER_MMC3_COOLBOY:
      begin
        var Mask := $FF xor (FRegs[0] and $80);
        if (FRegs[3] and $40) <> 0 then
          case Slot of
            0:
              Result := FBankRegisters[0];
            2:
              Result := FBankRegisters[1];
            1, 3:
              Result := 0
          end;
        if (FRegs[3] and $10) <> 0 then
          Result := (Result and $80 and Mask) or (((FRegs[0] and 8) shl 4) and not Mask) or ((FRegs[2] and 15) shl 3) or (Address shr 10)
        else
          Result := (Result and Mask) or (((FRegs[0] and 8) shl 4) and not Mask);
      end;
    MAPPER_MMC3_14:
      if Slot < 4 then
        Result := Result or ((FRegs[0] and 8) shl 5)
      else if Slot < 6 then
        Result := Result or ((FRegs[0] and $20) shl 3)
      else
        Result := Result or ((FRegs[0] and $80) shl 1);
    MAPPER_MMC3_121:
      if Length(FPrgRom) = Length(FChrMemory) then
        Result := Result or ((FRegs[3] and $80) shl 1)
      else if (Address shr 10) >= 4 then
        Result := Result or $100;
    MAPPER_MMC3_126:
      begin
        var Outer := ((not FRegs[0]) and $80 and FRegs[2]) or ((FRegs[0] shl 4) and $80 and FRegs[0]) or
          ((FRegs[0] shl 3) and $100) or ((FRegs[0] shl 5) and $200);
        if (FRegs[3] and $10) <> 0 then
          Result := Outer or ((FRegs[2] and 15) shl 3) or (Address shr 10)
        else
          Result := Outer or (Result and ((FRegs[0] and $80) - 1));
      end;
    MAPPER_MMC3_198:
      if FHasChrRam and (FBankRegisters[0] or FBankRegisters[1] or FBankRegisters[2] or FBankRegisters[3] or FBankRegisters[4] or FBankRegisters[5] = 0) then
        Result := Address shr 10;
    MAPPER_MMC3_199:
      case Address shr 10 of
        0:
          Result := FBankRegisters[0];
        1:
          Result := FRegs[2];
        2:
          Result := FBankRegisters[1];
        3:
          Result := FRegs[3]
      end;
    MAPPER_MMC3_215:
      if (FRegs[0] and $40) <> 0 then
        Result := ((FRegs[1] and 12) shl 6) or (Result and $7F) or ((FRegs[1] and $20) shl 2)
      else
        Result := ((FRegs[1] and 12) shl 6) or Result;
    MAPPER_MMC3_45:
      if not FHasChrRam then
        Result := (Result and ($FF shr (15 - (FRegs[2] and 15)))) or FRegs[0] or ((FRegs[2] and $F0) shl 4);
    MAPPER_MMC3_187:
      if (Address shr 10) >= 4 then
        Result := Result or $100;
    MAPPER_BMC_HPXX:
      if (FRegs[0] and 4) <> 0 then
      begin
        var Bank := FRegs[2] and $3F;
        case FRegs[0] and 3 of
          2:
            Bank := (Bank and $3E) or (FRegs[4] and 1);
          3:
            Bank := (Bank and $3C) or (FRegs[4] and 3);
        end;
        Result := (Bank shl 3) + (Address shr 10);
      end
      else if (FRegs[0] and 1) <> 0 then
        Result := (Result and $7F) or ((FRegs[2] and $30) shl 3)
      else
        Result := Result or ((FRegs[2] and $20) shl 3);
    MAPPER_MMC3_STREET_HEROES:
      begin
        var Bit := 0;
        case Address shr 11 of
          0:
            Bit := 3;
          1:
            Bit := 2;
          2:
            Bit := 0;
          3:
            Bit := 1
        end;
        Result := Result or (((FRegs[0] shr Bit) and 1) shl 8);
      end;
    MAPPER_MMC3_BMC411120_C:
      Result := Result or ((FRegs[0] and 3) shl 7);
    MAPPER_RESET_TXROM:
      Result := (Result and $7F) or (FResetBank shl 7);
    MAPPER_MMC3_MALI_SB:
      Result := (Result and $DD) or ((Result and $20) shr 4) or ((Result and 2) shl 4);
    MAPPER_BMC8IN1, MAPPER_BMC830118_C:
      Result := ((FRegs[0] and 12) shl 5) or (Result and $7F);
    MAPPER_BMC_GN45:
      Result := (Result and $7F) or (FRegs[0] shl 3);
    MAPPER_MMC3_37:
      if FRegs[0] >= 4 then
        Result := Result or $80;
    MAPPER_MMC3_44:
      if FRegs[0] < 6 then
        Result := (Result and $7F) or (FRegs[0] shl 7)
      else
        Result := Result or (FRegs[0] shl 7);
    MAPPER_MMC3_47:
      Result := (Result and $7F) or ((FRegs[0] and 1) shl 7);
    MAPPER_MMC3_49:
      Result := (Result and $7F) or ((FRegs[0] and $C0) shl 1);
    MAPPER_MMC3_52:
      if (FRegs[0] and $40) <> 0 then
        Result := (Result and $7F) or (((FRegs[0] and 4) or ((FRegs[0] shr 4) and 3)) shl 7)
      else
        Result := Result or (((FRegs[0] and 4) or ((FRegs[0] shr 4) and 2)) shl 7);
    MAPPER_MMC3_115:
      Result := Result or (FRegs[1] shl 8);
    MAPPER_MMC3_134:
      Result := Result or ((FRegs[0] and $20) shl 3);
    MAPPER_MMC3_205:
      begin
        if FRegs[0] >= 2 then
          Result := (Result and $7F) or $100;
        if (FRegs[0] and 1) <> 0 then
          Result := Result or $80;
      end;
    MAPPER_MMC3_249:
      if (FRegs[0] and 2) <> 0 then
        Result := PermuteChr(Result);
  end;
end;

function TMapperExtendedMmc3.ChrRamOffset(Bank: Integer): Integer;
begin
  Result := -1;
  case FBoard of
    MAPPER_MMC3_199:
      if Bank < 8 then
        Result := Bank * $400;
    MAPPER_MMC3_STREET_HEROES:
      if (FRegs[0] and $40) <> 0 then
        Result := (Bank and 7) * $400;
    MAPPER_MMC3_CHR_RAM_74:
      if (Bank >= 8) and (Bank <= 9) then
        Result := (Bank - 8) * $400;
    MAPPER_MMC3_CHR_RAM_191:
      if Bank >= $80 then
        Result := ((Bank - $80) and 1) * $400;
    MAPPER_MMC3_CHR_RAM_192:
      if (Bank >= 8) and (Bank <= 11) then
        Result := (Bank - 8) * $400;
    MAPPER_MMC3_CHR_RAM_194:
      if Bank < 2 then
        Result := Bank * $400;
    MAPPER_MMC3_CHR_RAM_195:
      if Bank < 4 then
        Result := Bank * $400;
  end;
end;

function TMapperExtendedMmc3.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
const
  Protect187: array[0..3] of Byte = ($83, $83, $42, 0);
  Protect258: array[0..7] of Byte = (0, 0, 0, 1, 2, 4, 15, 0);
begin
  if (FBoard = MAPPER_DRAGON_FIGHTER) and (Address >= $6000) and (Address < $7000) then
  begin
    if (Address and 1) = 0 then
      if (FRegs[0] and $E0) = $C0 then
        FRegs[1] := FRegs[62]
      else
        FRegs[2] := FRegs[63];
    Value := 0;
    Exit(True);
  end;

  if (FBoard = MAPPER_FK23C) and (Address >= $4000) and (Address < $8000) then
  begin
    if (FRegs[6] and $20) <> 0 then
    begin
      var Bank := FRegs[6] and 3;
      if Address < $6000 then
        Bank := (Bank + 1) and 3;
      Value := FPrgExtra[Bank * $2000 + (Address and $1FFF)];
      Exit(True)
    end;
    if Address < $6000 then
      Exit(False);
    if (FRegs[6] and $80) = 0 then
      Exit(False);
    Value := FPrgExtra[Address and $1FFF];
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_198) and (Address >= $5000) and (Address < $8000) then
  begin
    Value := FPrgRam[Address and $FFF];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_121) and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FRegs[4];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_208) and (Address >= $5800) and (Address < $6000) then
  begin
    Value := FRegs[Address and 3];
    Exit(True)
  end;

  if (Address >= $5000) and (Address < $6000) then
    case FBoard of
      MAPPER_MMC3_187:
        begin
          Value := Protect187[FRegs[1] and 3];
          Exit(True)
        end;
      MAPPER_UNL158_B:
        begin
          Value := FCpuOpenBus or Protect258[Address and 7];
          Exit(True)
        end;
      MAPPER_BMC_HPXX:
        begin
          Value := 0;
          Exit(True)
        end;
    end;

  if (FBoard = MAPPER_MMC3_STREET_HEROES) and (Address = $4100) then
  begin
    Value := FResetBank;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_115) and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FRegs[2];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_238) and (Address >= $4020) and (Address < $8000) then
  begin
    Value := FRegs[0];
    Exit(True)
  end;

  if Address >= $8000 then
  begin
    Value := FPrgRom[PrgBank((Address - $8000) shr 13) * $2000 + (Address and $1FFF)];
    Exit(True)
  end;

  Result := inherited CpuRead(Address, Value);
  if Result and (FBoard = MAPPER_MMC3_254) and (FRegs[0] = 0) then
    Value := Value xor FRegs[1];
end;

function TMapperExtendedMmc3.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  Security: array[0..7] of Byte = (0, 3, 1, 5, 6, 7, 2, 4);
  Protection: array[0..3] of Byte = (0, 2, 2, 3);
  Reg215: array[0..4, 0..7] of Byte = ((0, 1, 2, 3, 4, 5, 6, 7), (0, 2, 6, 1, 7, 3, 4, 5), (0, 5, 4, 1, 7, 2, 6, 3), (0, 6, 3, 7, 5, 2, 4, 1), (0, 2, 5, 3, 6, 1, 7, 4));
  Addr215: array[0..4, 0..7] of Byte = ((0, 1, 2, 3, 4, 5, 6, 7), (3, 2, 0, 4, 1, 5, 6, 7), (0, 1, 2, 3, 4, 5, 6, 7), (5, 0, 1, 2, 3, 7, 6, 4), (3, 1, 0, 5, 2, 4, 6, 7));
begin
  if (FBoard = MAPPER_DRAGON_FIGHTER) and (Address >= $6000) and (Address < $8000) then
  begin
    if (Address and 1) = 0 then
      FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_TAITO_TC0690) and (Address >= $8000) then
  begin
    case Address and $E003 of
      $8000, $8001:
        FRegs[Address and 1] := Value and $3F;
      $8002, $8003:
        FRegs[Address and 3] := Value;
      $A000..$A003:
        FRegs[4 + (Address and 3)] := Value;
      $C000:
        begin
          FIrqPending := False;
          FIrqLatch := (Value xor $FF) + Ord(FSubmapper = 1)
        end;
      $C001:
        begin
          FIrqPending := False;
          FIrqCounter := 0;
          FIrqReloadPending := True
        end;
      $C002:
        FIrqEnabled := True;
      $C003:
        begin
          FIrqEnabled := False;
          FIrqPending := False
        end;
      $E000:
        begin
          FMirrorMode := TMirrorMode.Vertical;
          if (Value and $40) <> 0 then
            FMirrorMode := TMirrorMode.Horizontal
        end;
    end;
    Exit(True);
  end;

  if FBoard = MAPPER_MULTIMAPPER_116 then
  begin
    if (Address >= $4100) and (Address < $8000) then
    begin
      if (Address and $4100) = $4100 then
      begin
        FRegs[0] := Value;
        if (Address and 1) <> 0 then
        begin
          FRegs[16] := 12;
          FRegs[19] := 0;
          FRegs[20] := 0;
          FRegs[21] := 0
        end
      end;
    end
    else if Address >= $8000 then
      case FRegs[0] and 3 of
        0:
          begin
            if (Address >= $B000) and (Address <= $E003) then
            begin
              var R := 8 + (((((Address and 2) or (Address shr 10)) shr 1) + 2) and 7);
              var Shift := (Address and 1) * 4;
              FRegs[R] := (FRegs[R] and ($F0 shr Shift)) or ((Value and 15) shl Shift)
            end
            else
              case Address and $F000 of
                $8000:
                  FRegs[1] := Value;
                $A000:
                  FRegs[2] := Value;
                $9000:
                  FRegs[3] := Value
              end;
            FMirrorMode := TMirrorMode.Vertical;
            if (FRegs[3] and 1) <> 0 then
              FMirrorMode := TMirrorMode.Horizontal;
          end;
        1:
          begin
            inherited CpuWrite(Address, Value);
            Exit(True)
          end;
        2, 3:
          begin
            if (Value and $80) <> 0 then
            begin
              FRegs[16] := FRegs[16] or 12;
              FRegs[20] := 0;
              FRegs[21] := 0
            end
            else
            begin
              FRegs[20] := FRegs[20] or ((Value and 1) shl FRegs[21]);
              Inc(FRegs[21]);
              if FRegs[21] = 5 then
              begin
                FRegs[16 + ((Address shr 13) - 4)] := FRegs[20];
                FRegs[20] := 0;
                FRegs[21] := 0
              end;
            end;
            case FRegs[16] and 3 of
              0:
                FMirrorMode := TMirrorMode.Single0;
              1:
                FMirrorMode := TMirrorMode.Single1;
              2:
                FMirrorMode := TMirrorMode.Vertical;
              3:
                FMirrorMode := TMirrorMode.Horizontal
            end;
          end;
      end;
    Exit(True);
  end;

  if FBoard = MAPPER_FK23C then
  begin
    if Address < $8000 then
    begin
      if ((FRegs[6] and $40) <> 0) or ((FRegs[6] and $20) = 0) then
      begin
        if (Address and $5010) = $5010 then
        begin
          FRegs[Address and 3] := Value;
          case Address and 3 of
            0:
              FRegs[4] := (FRegs[4] and not $180) or ((Value and $80) shl 1) or ((Value and 8) shl 4);
            1:
              FRegs[4] := (FRegs[4] and not $7F) or (Value and $7F);
            2:
              begin
                FRegs[4] := (FRegs[4] and not $200) or ((Value and $40) shl 3);
                FRegs[5] := 0
              end;
          end;
        end
        else if Address >= $6000 then
        begin
          if (FRegs[6] and $C0) = $80 then
            FPrgExtra[Address and $1FFF] := Value
        end;
      end
      else if Address >= $4000 then
      begin
        var Bank := FRegs[6] and 3;
        if Address < $6000 then
          Bank := (Bank + 1) and 3;
        FPrgExtra[Bank * $2000 + (Address and $1FFF)] := Value
      end;
      Exit(True);
    end;
    if (FRegs[3] and $44) <> 0 then
      if (Address < $A000) or (Address >= $C000) then
        FRegs[5] := Value and 3;
    case Address and $E001 of
      $8000:
        begin
          if (Length(FPrgRom) = $1000000) and (Value in [$46, $47]) then
            Value := Value xor 1;
          FBankSelect := Value;
          Exit(True)
        end;
      $8001:
        begin
          var R := FBankSelect and 7;
          if (FRegs[3] and 2) <> 0 then
            R := FBankSelect and 15;
          if R < 8 then
            FBankRegisters[R] := Value
          else if R < 12 then
            FRegs[R] := Value;
          Exit(True);
        end;
      $A000:
        begin
          FRegs[7] := Value and 3;
          var R := Value and 1;
          if (FRegs[6] and 8) <> 0 then
            R := Value and 3;
          case R of
            0:
              FMirrorMode := TMirrorMode.Vertical;
            1:
              FMirrorMode := TMirrorMode.Horizontal;
            2:
              FMirrorMode := TMirrorMode.Single0;
            3:
              FMirrorMode := TMirrorMode.Single1
          end;
          Exit(True);
        end;
      $A001:
        begin
          if (Value and $20) = 0 then
            Value := Value and $C0;
          FRegs[6] := Value
        end;
    end;
  end;

  if (FBoard = MAPPER_MMC3_COOLBOY) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FPrgRamControl and $80) <> 0 then
      inherited CpuWrite(Address, Value);
    if (FRegs[3] and $90) <> $80 then
      FRegs[Address and 3] := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_14 then
  begin
    if Address = $A131 then
      FRegs[0] := Value;
    if (FRegs[0] and 2) = 0 then
    begin
      if (Address >= $B000) and (Address < $F000) then
      begin
        var R := 1 + ((Address shr 12) - 11) * 2 + ((Address shr 1) and 1);
        var Shift := (Address and 1) * 4;
        FRegs[R] := (FRegs[R] and ($FF xor (15 shl Shift))) or ((Value and 15) shl Shift);
      end
      else
        case Address and $F003 of
          $8000:
            FRegs[9] := Value;
          $9000:
            FRegs[11] := Value;
          $A000:
            FRegs[10] := Value
        end;
      FMirrorMode := TMirrorMode.Vertical;
      if (FRegs[11] and 1) <> 0 then
        FMirrorMode := TMirrorMode.Horizontal;
      Exit(True);
    end;
  end;

  if FBoard = MAPPER_MMC3_121 then
  begin
    if (Address >= $5000) and (Address < $6000) then
    begin
      case Value and 3 of
        0, 1:
          FRegs[4] := $83;
        2:
          FRegs[4] := $42;
        3:
          FRegs[4] := 0
      end;
      if (Address and $5180) = $5180 then
        FRegs[3] := Value;
      Exit(True);
    end;
    if (Address >= $8000) and (Address < $A000) then
      if (Address and 3) = 3 then
      begin
        FRegs[5] := Value;
        UpdateProtection121;
        Address := $8000
      end
      else if (Address and 1) <> 0 then
      begin
        FRegs[6] := 0;
        for var i := 0 to 5 do
          FRegs[6] := FRegs[6] or (((Value shr i) and 1) shl (5 - i));
        if FRegs[7] = 0 then
          UpdateProtection121;
        Address := $8001;
      end
      else
        Address := $8000;
  end;

  if (FBoard = MAPPER_MMC3_126) and (Address >= $6000) and (Address < $8000) then
  begin
    var R := Address and 3;
    if (R = 1) or (R = 2) or ((FRegs[3] and $80) = 0) then
      FRegs[R] := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_198 then
  begin
    if (Address >= $5000) and (Address < $8000) then
    begin
      FPrgRam[Address and $FFF] := Value;
      Exit(True)
    end;
    if (Address = $8001) and ((FBankSelect and 7) >= 6) then
      if Value >= $40 then
        FRegs[(FBankSelect and 7) - 6] := Value and $4F
      else
        FRegs[(FBankSelect and 7) - 6] := Value and $3F;
  end;

  if FBoard = MAPPER_MMC3_199 then
  begin
    if (Address = $8001) and ((FBankSelect and 8) <> 0) then
    begin
      FRegs[FBankSelect and 3] := Value;
      Exit(True)
    end;
    if (Address and $E001) = $A000 then
    begin
      case Value and 3 of
        0:
          FMirrorMode := TMirrorMode.Vertical;
        1:
          FMirrorMode := TMirrorMode.Horizontal;
        2:
          FMirrorMode := TMirrorMode.Single0;
        3:
          FMirrorMode := TMirrorMode.Single1
      end;
      Exit(True)
    end;
  end;

  if FBoard = MAPPER_MMC3_208 then
  begin
    if (Address >= $5000) and (Address < $6000) then
    begin
      if Address < $5800 then
        FRegs[4] := Value
      else
      begin
        var Key := FRegs[4];
        var Lut := 0;
        if (Key and $40) = 0 then
        begin
          Lut := $59;
          if (Key and 8) <> 0 then
            Lut := Lut xor ((Key and 1) shl 4) xor ((Key and 2) shl 5) xor ((Key and $10) shr 1) xor (Key shr 7);
        end
        else if (Key and 8) = 0 then
          Lut := ((Key and 1) shl 4) or ((Key and 2) shl 5) or ((Key and $10) shr 1) or (Key shr 7);
        FRegs[Address and 3] := Value xor Lut;
      end;
      Exit(True);
    end;
    if ((Address >= $4800) and (Address < $5000)) or ((Address >= $6800) and (Address < $7000)) then
    begin
      FRegs[5] := (Value and 1) or ((Value shr 3) and 2);
      Exit(True)
    end;
  end;

  if FBoard = MAPPER_MMC3_215 then
  begin
    if (Address >= $5000) and (Address < $8000) then
    begin
      case Address of
        $5000:
          FRegs[0] := Value;
        $5001:
          FRegs[1] := Value;
        $5007:
          FRegs[2] := Value and 7
      end;
      Exit(True)
    end;
    if Address >= $8000 then
    begin
      var R := FRegs[2];
      if R > 4 then
        R := 0;
      var Decoded := Addr215[R, ((Address shr 12) and 6) or (Address and 1)];
      Address := $8000 or ((Decoded and 6) shl 12) or (Decoded and 1);
      if Decoded = 0 then
        Value := (Value and $C0) or Reg215[R, Value and 7];
    end;
  end;

  if (FBoard = MAPPER_MMC3_219) and (Address >= $8000) and (Address < $A000) then
  begin
    case Address and 3 of
      0:
        begin
          FRegs[0] := 0;
          FRegs[1] := Value
        end;
      2:
        begin
          FRegs[0] := Value;
          FRegs[1] := 0
        end;
      1:
        begin
          if (FRegs[0] >= $23) and (FRegs[0] <= $26) then
            FRegs[8 + $26 - FRegs[0]] := ((Value and $20) shr 5) or ((Value and $10) shr 3) or ((Value and 8) shr 1) or ((Value and 4) shl 1);
          case FRegs[1] of
            8, 10, 14, 18, 22, 26, 30:
              FRegs[2] := (Value shl 4) and $FF;
            9, 11, 12, 13, 15, 16, 17, 20, 21, 24, 25, 28, 29:
              begin
                var Slot: Integer;
                var Bank := Value shr 1;
                case FRegs[1] of
                  9:
                    begin
                      Slot := 0;
                      Bank := Bank and 14
                    end;
                  11:
                    begin
                      Slot := 1;
                      Bank := Bank or 1
                    end;
                  12, 13:
                    begin
                      Slot := 2;
                      Bank := Bank and 14
                    end;
                  15:
                    begin
                      Slot := 3;
                      Bank := Bank or 1
                    end;
                  16, 17:
                    begin
                      Slot := 4;
                      Bank := Bank and 15
                    end;
                  20, 21:
                    begin
                      Slot := 5;
                      Bank := Bank and 15
                    end;
                  24, 25:
                    begin
                      Slot := 6;
                      Bank := Bank and 15
                    end;
                else
                  begin
                    Slot := 7;
                    Bank := Bank and 15
                  end
                end;
                FRegs[12 + Slot] := FRegs[2] or Bank;
              end;
          end;
        end;
    end;
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_45) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FRegs[3] and $40) <> 0 then
      Exit(inherited CpuWrite(Address, Value));
    FRegs[FRegs[4]] := Value;
    FRegs[4] := (FRegs[4] + 1) and 3;
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_114) and (Address >= $5000) then
  begin
    if Address < $8000 then
    begin
      FRegs[0] := Value;
      Exit(True)
    end;
    case Address and $E001 of
      $8001:
        Exit(inherited CpuWrite($A000, Value));
      $A000:
        begin
          FRegs[1] := 1;
          Exit(inherited CpuWrite($8000, (Value and $C0) or Security[Value and 7]))
        end;
      $A001:
        begin
          FIrqLatch := Value;
          Exit(True)
        end;
      $C000:
        begin
          if FRegs[1] <> 0 then
          begin
            FRegs[1] := 0;
            inherited CpuWrite($8001, Value)
          end;
          Exit(True)
        end;
      $C001:
        begin
          FIrqReloadPending := True;
          Exit(True)
        end;
      $E000, $E001:
        ;
    else
      Exit(True);
    end;
  end;

  if FBoard = MAPPER_MMC3_187 then
  begin
    if (Address >= $5000) and (Address < $7000) then
    begin
      if (Address = $5000) or (Address = $6000) then
        FRegs[0] := Value;
      Exit(True)
    end;
    if Address = $8000 then
      FRegs[1] := 1;
    if (Address = $8001) and (FRegs[1] <> 1) then
      Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_224) and (Address >= $5000) and (Address <= $5003) then
  begin
    if Address = $5000 then
      FRegs[0] := (Value shr 2) and 1;
    Exit(True)
  end;

  if (FBoard = MAPPER_UNL158_B) and (Address >= $5000) and (Address < $6000) then
  begin
    if (Address and 7) = 0 then
      FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_BMC_F15) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FPrgRamControl and $80) <> 0 then
      FRegs[0] := Value and 15;
    Exit(True)
  end;

  if FBoard = MAPPER_BMC_HPXX then
  begin
    if (Address >= $5000) and (Address < $6000) then
    begin
      if FRegs[5] = 0 then
      begin
        FRegs[Address and 3] := Value;
        FRegs[5] := Value and $80
      end;
      Exit(True)
    end;
    if (Address >= $8000) and ((FRegs[0] and 4) <> 0) then
    begin
      FRegs[4] := Value;
      FMirrorMode := TMirrorMode.Horizontal;
      if (Value and 4) <> 0 then
        FMirrorMode := TMirrorMode.Vertical;
      Exit(True)
    end;
  end;

  if (FBoard = MAPPER_MMC3_STREET_HEROES) and (Address = $4100) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_KOF97) and (Address >= $8000) then
  begin
    Value := (Value and $D8) or ((Value and $20) shr 4) or ((Value and 4) shl 3) or ((Value and 2) shr 1) or ((Value and 1) shl 2);
    case Address of
      $9000:
        Address := $8001;
      $D000:
        Address := $C001;
      $F000:
        Address := $E001
    end;
  end;

  if (FBoard = MAPPER_MMC3_BMC411120_C) and (Address >= $6000) and (Address < $8000) then
  begin
    FRegs[0] := Address and $FF;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_MALI_SB) and (Address >= $8000) then
  begin
    var Bit := (Address shr 3) and 1;
    if Address >= $C000 then
      Bit := Bit or ((Address shr 2) and 1);
    Address := (Address and $FFFE) or Bit
  end;

  if (FBoard = MAPPER_BMC8IN1) and (Address >= $8000) and ((Address and $1000) <> 0) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_BMC830118_C) and (Address >= $6800) and (Address <= $68FF) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_BMC_GN45) and (Address >= $6000) and (Address < $8000) then
  begin
    if FRegs[1] <> 0 then
      Exit(inherited CpuWrite(Address, Value));
    if Address < $7000 then
    begin
      FRegs[0] := Address and $30;
      FRegs[1] := Address and $80
    end
    else
      FRegs[0] := Value and $30;
    Exit(True);
  end;

  if (FBoard = MAPPER_SACHEN_9602) and (Address >= $8000) then
  begin
    if (Address and $E001) = $8000 then
      FRegs[0] := Value;
    if ((Address and $E001) = $8001) and ((FRegs[0] and 7) < 6) then
    begin
      FRegs[1] := Value shr 6;
      Value := Value and 31
    end;
  end;
  if (Address >= $6000) and (Address < $8000) and (FBoard in [MAPPER_MMC3_37,
      MAPPER_MMC3_47,
      MAPPER_MMC3_49,
      MAPPER_MMC3_52,
      MAPPER_MMC3_205]) then
  begin
    if (FBoard = MAPPER_MMC3_205) or ((FPrgRamControl and $C0) = $80) then
    begin
      case FBoard of
        MAPPER_MMC3_37:
          FRegs[0] := Value and 7;
        MAPPER_MMC3_47:
          FRegs[0] := Value and 1;
        MAPPER_MMC3_49:
          FRegs[0] := Value;
        MAPPER_MMC3_52:
          if (FRegs[0] and $80) = 0 then
            FRegs[0] := Value
          else
            Exit(inherited CpuWrite(Address, Value));
        MAPPER_MMC3_205:
          FRegs[0] := Value and 3;
      end;
    end;
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_44) and ((Address and $E001) = $A001) then
  begin
    FRegs[0] := Value and 7;
    if FRegs[0] = 7 then
      FRegs[0] := 6
  end;
  if (FBoard = MAPPER_MMC3_115) and (Address >= $4100) and (Address < $8000) then
  begin
    if Address = $5080 then
      FRegs[2] := Value
    else if (Address and 1) <> 0 then
      FRegs[1] := Value and 1
    else
      FRegs[0] := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_123 then
  begin
    if (Address >= $5001) and (Address < $8000) and ((Address and $800) <> 0) then
    begin
      FRegs[Address and 1] := Value;
      Exit(True)
    end;
    if (Address >= $8000) and (Address < $A000) and ((Address and 1) = 0) then
      Value := (Value and $C0) or Security[Value and 7];
  end;

  if (FBoard = MAPPER_MMC3_134) and (Address = $6001) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_189) and (Address >= $4120) and (Address < $8000) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if FBoard = MAPPER_MMC3_196 then
  begin
    if (Address >= $6000) and (Address < $7000) then
    begin
      FRegs[0] := 1;
      FRegs[1] := (Value and 15) or (Value shr 4);
      Exit(True)
    end;
    if Address >= $8000 then
    begin
      var Low := ((Address shr 2) or (Address shr 3)) and 1;
      if Address < $C000 then
        Low := Low or ((Address shr 1) and 1);
      Address := (Address and $FFFE) or Low;
    end;
  end;

  if FBoard = MAPPER_MMC3_182 then
  begin
    if Address < $8000 then
      Exit(inherited CpuWrite(Address, Value));
    case Address and $E001 of
      $8001:
        Address := $A000;
      $A000:
        begin
          Address := $8000;
          Value := (Value and $F8) or Security[Value and 7]
        end;
      $C000:
        Address := $8001;
      $C001:
        begin
          inherited CpuWrite($C000, Value);
          Address := $C001
        end;
      $E000, $E001:
        ;
    else
      Exit(True);
    end;
  end;

  if (FBoard = MAPPER_MMC3_238) and (Address >= $4020) and (Address < $8000) then
  begin
    FRegs[0] := Protection[Value and 3];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_249) and (Address = $5000) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if FBoard = MAPPER_MMC3_254 then
    case Address of
      $8000:
        FRegs[0] := $FF;
      $A001:
        FRegs[1] := Value
    end;

  if FBoard = MAPPER_TXSROM then
  begin
    if (Address >= $8000) and ((Address and $E001) = $A000) then
      Exit(True);
    if (Address >= $8000) and ((Address and $E001) = $8001) then
    begin
      var Reg := FBankSelect and 7;
      if (FBankSelect and $80) = 0 then
      begin
        if Reg < 2 then
        begin
          FNameBanks[Reg * 2] := Value shr 7;
          FNameBanks[Reg * 2 + 1] := Value shr 7
        end
      end
      else if (Reg >= 2) and (Reg <= 5) then
        FNameBanks[Reg - 2] := Value shr 7;
    end;
  end;

  Result := inherited CpuWrite(Address, Value);
end;

function TMapperExtendedMmc3.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_TXSROM) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[FNameBanks[(Address shr 10) and 3] * $400 + (Address and $3FF)];
    Exit(True)
  end;

  Result := Address < $2000;
  if not Result then
    Exit;

  var Bank := ChrBank(Address);
  if (FBoard = MAPPER_FK23C) and (((FRegs[0] and $20) <> 0) or (((FRegs[6] and $24) = $24) and (Bank <= 7))) then
  begin
    Value := FChrExtra[(Bank * $400 + (Address and $3FF)) mod Length(FChrExtra)];
    Exit(True)
  end;

  if Bank < 0 then
  begin
    Value := FChrRam[Address and $FFF];
    Exit(True)
  end;

  var Ram := ChrRamOffset(Bank);
  if (FBoard = MAPPER_MMC3_STREET_HEROES) and ((FRegs[0] and $40) <> 0) then
    Ram := (Address shr 10) * $400;
  if Ram >= 0 then
    Value := FChrRam[Ram + (Address and $3FF)]
  else
    Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)];
end;

function TMapperExtendedMmc3.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_TXSROM) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[FNameBanks[(Address shr 10) and 3] * $400 + (Address and $3FF)] := Value;
    Exit(True)
  end;

  if Address >= $2000 then
    Exit(False);

  var Bank := ChrBank(Address);
  if (FBoard = MAPPER_FK23C) and (((FRegs[0] and $20) <> 0) or (((FRegs[6] and $24) = $24) and (Bank <= 7))) then
  begin
    FChrExtra[(Bank * $400 + (Address and $3FF)) mod Length(FChrExtra)] := Value;
    Exit(True)
  end;

  if Bank < 0 then
  begin
    FChrRam[Address and $FFF] := Value;
    Exit(True)
  end;

  var Ram := ChrRamOffset(Bank);
  if (FBoard = MAPPER_MMC3_STREET_HEROES) and ((FRegs[0] and $40) <> 0) then
    Ram := (Address shr 10) * $400;
  if Ram >= 0 then
  begin
    FChrRam[Ram + (Address and $3FF)] := Value;
    Exit(True)
  end;

  Result := FHasChrRam;
  if Result then
    FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value;
end;

procedure TMapperExtendedMmc3.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if (FBoard = MAPPER_MULTIMAPPER_116) and ((FRegs[0] and 3) <> 1) then
    Exit;

  if FBoard = MAPPER_MMC3_165 then
  begin
    FRegs[12] := FRegs[14];
    FRegs[13] := FRegs[15];
    case Address and $2FF8 of
      $FD0:
        FRegs[14 + (Address shr 12 and 1)] := 0;
      $FE8:
        FRegs[14 + (Address shr 12 and 1)] := 1
    end;
    Exit;
  end;

  var Pending := FIrqPending;
  var Active := (FIrqCounter <> 0) or FIrqReloadPending;
  inherited;
  if (FBoard = MAPPER_TAITO_TC0690) or (FBoard = MAPPER_FK23C) then
    if FIrqPending and not Pending then
    begin
      FIrqPending := False;
      if FBoard = MAPPER_FK23C then
        FRegs[60] := 2
      else if FSubmapper = 1 then
        FRegs[60] := 6
      else
        FRegs[60] := 22;
    end;
  if (FBoard = MAPPER_MMC3_114) and not Active then
    FIrqPending := Pending;
end;

procedure TMapperExtendedMmc3.ClockCpu;
begin
  if FRegs[60] > 0 then
  begin
    Dec(FRegs[60]);
    if FRegs[60] = 0 then
      FIrqPending := True
  end;
end;

procedure TMapperExtendedMmc3.CpuRamWrite(Address: UInt16; Value: UInt8);
begin
  if FBoard = MAPPER_DRAGON_FIGHTER then
    case Address of
      $6A:
        FRegs[62] := Value;
      $FF:
        FRegs[63] := Value
    end;
end;

function TMapperExtendedMmc3.GetSaveMemory: TByteArray;
begin
  if FBoard = MAPPER_SACHEN_9602 then
    Result := Copy(FChrMemory)
  else if FBoard = MAPPER_FK23C then
  begin
    SetLength(Result, SizeOf(FPrgExtra));
    Move(FPrgExtra[0], Result[0], Length(Result))
  end
  else
    Result := inherited;
end;

procedure TMapperExtendedMmc3.SetSaveMemory(const Data: TByteArray);
begin
  if FBoard = MAPPER_SACHEN_9602 then
  begin
    if Length(Data) <> Length(FChrMemory) then
      raise ENesException.Create('Invalid Sachen CHR save size');

    Move(Data[0], FChrMemory[0], Length(Data))
  end
  else if FBoard = MAPPER_FK23C then
  begin
    if Length(Data) <> SizeOf(FPrgExtra) then
      raise ENesException.Create('Invalid FK23C save size');

    Move(Data[0], FPrgExtra[0], Length(Data))
  end
  else
    inherited;
end;

procedure TMapperExtendedMmc3.UpdateProtection121;
begin
  case FRegs[5] and $3F of
    $20, $29, $2B, $3C, $3F:
      begin
        FRegs[7] := 1;
        FRegs[0] := FRegs[6]
      end;
    $26:
      begin
        FRegs[7] := 0;
        FRegs[0] := FRegs[6]
      end;
    $2C:
      begin
        FRegs[7] := 1;
        if FRegs[6] <> 0 then
          FRegs[0] := FRegs[6]
      end;
    $28:
      begin
        FRegs[7] := 0;
        FRegs[1] := FRegs[6]
      end;
    $2A:
      begin
        FRegs[7] := 0;
        FRegs[2] := FRegs[6]
      end;
    $2F:
      ;
  else
    FRegs[5] := 0
  end;
end;

end.

