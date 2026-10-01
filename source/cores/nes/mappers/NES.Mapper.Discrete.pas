unit NES.Mapper.Discrete;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperDiscrete = class(TMapperBanked)
  private
    FBoard: Integer;
    FSubmapper: Integer;
    FRegisters: array[0..15] of Byte;
    FSelect, FOuter: Byte;
    FIrqCounter: Integer;
    FIrqEnabled, FIrqPending, FChrWritable, FLegacyChrWrites: Boolean;
    procedure UpdateIndexedBanks;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean = False; Submapper: Integer = 0);
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
  end;

implementation

procedure TMapperDiscrete.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FOuter, SizeOf(FOuter));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  State.Field(FChrWritable, SizeOf(FChrWritable));
  State.Field(FLegacyChrWrites, SizeOf(FLegacyChrWrites));
end;

constructor TMapperDiscrete.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  if (Board = 108) and (Submapper = 0) then
  begin
    if HasChrRam then
    begin
      if MirrorMode = TMirrorMode.Horizontal then
        FSubmapper := 1
      else
        FSubmapper := 3;
    end
    else if Length(Chr) > $4000 then
      FSubmapper := 2
    else
      FSubmapper := 4;
  end;
  if Board = 31 then
    FRegisters[7] := $FF;
  // Legacy mapper-15 game hacks require writable CHR in all modes (NESdev).
  FLegacyChrWrites := (Board = 15) and LegacyHeader;
  if Board = 13 then
  begin
    SetLength(FChrMemory, $4000);
    FHasChrRam := True;
  end;
  Reset;
end;

procedure TMapperDiscrete.Reset;
begin
  // Mapper 31's latches have power-on defaults but survive the reset button.
  if FBoard = 31 then
  begin
    FRamEnabled := False;
    Exit;
  end;
  inherited;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FSelect := 0;
  FOuter := 0;
  FIrqCounter := 0;
  FIrqEnabled := False;
  FIrqPending := False;
  FChrWritable := True;
  case FBoard of
    8, 13, 34, 41, 58, 61, 79, 87, 99, 101, 113, 133, 140, 144, 145, 148, 184, 212, 228, 240, 242:
      Prg32(0);
    180:
      Prg16(1, 0);
    200:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
      end;
    108:
      begin
        Prg32(-1);
        if FSubmapper = 4 then
          FRegisters[0] := (Length(FPrgRom) div $2000) - 1;
      end;
    42:
      Prg32(-1);
    32, 88, 112, 154, 206:
      begin
        Prg8(0, 0);
        Prg8(1, 1);
      end;
    232:
      Prg16(1, 3);
  end;
  if FBoard in [13, 41, 242] then
    Mirror(0);
  if FBoard = 78 then
  begin
    if (FSubmapper = 3) or ((FSubmapper = 0) and (FInitialMirror = TMirrorMode.FourScreen)) then
      Mirror(1)
    else
      Mirror(2);
  end;
  if FBoard = 184 then
    Chr4(1, 4);
  if FBoard = 75 then
  begin
    Prg8(2, 0);
    Chr4(1, 0);
  end;
  if FBoard = 15 then
    CpuWrite($8000, 0);
  if FBoard in [88, 154, 206, 112] then
    UpdateIndexedBanks;
  FRamEnabled := FBoard in [8, 15, 32, 34, 73, 112, 242];
end;

procedure TMapperDiscrete.UpdateIndexedBanks;
begin
  if FBoard = 112 then
  begin
    Prg8(0, FRegisters[0]);
    Prg8(1, FRegisters[1]);
    Chr2(0, FRegisters[2] shr 1);
    Chr2(1, FRegisters[3] shr 1);
    for var i := 4 to 7 do
      Chr1(i, FRegisters[i] or (((FOuter shr i) and 1) shl 8));
  end
  else
  begin
    Prg8(0, FRegisters[6] and $3F);
    Prg8(1, FRegisters[7] and $3F);
    var Mask := $FF;
    if FBoard in [88, 154] then
      Mask := $3F;
    Chr2(0, (FRegisters[0] and Mask) shr 1);
    Chr2(1, (FRegisters[1] and Mask) shr 1);
    for var i := 4 to 7 do
      if FBoard in [88, 154] then
        Chr1(i, (FRegisters[i - 2] and $3F) or $40)
      else
        Chr1(i, FRegisters[i - 2]);
  end;
end;

function TMapperDiscrete.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = 42) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(Integer(FRegisters[0]) * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;
  if (FBoard = 108) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(Integer(FRegisters[0]) * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;
  if (FBoard = 212) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := 0;
    if (Address and $10) = 0 then
      Value := $80;
    Exit(True);
  end;
  if (FBoard = 31) and (Address >= $8000) then
  begin
    Value := FPrgRom[(Integer(FRegisters[(Address - $8000) shr 12]) * $1000 +
      (Address and $0FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;
  Result := inherited;
end;

function TMapperDiscrete.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := inherited CpuWrite(Address, Value);
  var Bank: Integer;
  case FBoard of
    18:
      if Address >= $8000 then
      begin
        var RegisterAddress := Address and $F003;
        if ((RegisterAddress >= $8000) and (RegisterAddress <= $8003)) or
           ((RegisterAddress >= $9000) and (RegisterAddress <= $9001)) then
        begin
          var Index := ((RegisterAddress shr 12) - 8) * 2 + ((RegisterAddress and 2) shr 1);
          if (RegisterAddress and 1) = 0 then
            FRegisters[Index] := (FRegisters[Index] and $F0) or (Value and $0F)
          else
            FRegisters[Index] := (FRegisters[Index] and $0F) or ((Value and 3) shl 4);
          Prg8(Index, FRegisters[Index]);
        end
        else if RegisterAddress = $9002 then
        begin
          FRamEnabled := (Value and 1) <> 0;
          FRamWritable := (Value and 2) <> 0;
        end
        else if (RegisterAddress >= $A000) and (RegisterAddress <= $D003) then
        begin
          var Index := 3 + (((RegisterAddress shr 12) - $A) * 2) + ((RegisterAddress and 2) shr 1);
          if (RegisterAddress and 1) = 0 then
            FRegisters[Index] := (FRegisters[Index] and $F0) or (Value and $0F)
          else
            FRegisters[Index] := (FRegisters[Index] and $0F) or ((Value and $0F) shl 4);
          Chr1(Index - 3, FRegisters[Index]);
        end
        else if (RegisterAddress >= $E000) and (RegisterAddress <= $E003) then
          FRegisters[11 + (RegisterAddress and 3)] := Value and $0F
        else
          case RegisterAddress of
            $F000:
              begin
                FIrqCounter := FRegisters[11] or (Integer(FRegisters[12]) shl 4) or
                  (Integer(FRegisters[13]) shl 8) or (Integer(FRegisters[14]) shl 12);
                FIrqPending := False;
              end;
            $F001:
              begin
                FRegisters[15] := Value and $0F;
                FIrqEnabled := (Value and 1) <> 0;
                FIrqPending := False;
              end;
            $F002:
              begin
                Bank := Value and 3;
                if Bank < 2 then
                  Bank := 1 - Bank;
                Mirror(Bank);
              end;
          end;
        Result := True;
      end;
    73:
      if Address >= $8000 then
      begin
        case Address and $F000 of
          $8000..$B000:
            FRegisters[(Address shr 12) - 8] := Value and $0F;
          $C000:
            begin
              FRegisters[4] := Value and 7;
              FIrqEnabled := (Value and 2) <> 0;
              FIrqPending := False;
              if FIrqEnabled then
                FIrqCounter := FRegisters[0] or (Integer(FRegisters[1]) shl 4) or
                  (Integer(FRegisters[2]) shl 8) or (Integer(FRegisters[3]) shl 12);
            end;
          $D000:
            begin
              FIrqPending := False;
              FIrqEnabled := (FRegisters[4] and 1) <> 0;
            end;
          $F000:
            Prg16(0, Value and 7);
        end;
        Result := True;
      end;
    42:
      if Address >= $8000 then
      begin
        case Address and $E003 of
          $8000:
            if not FHasChrRam then
              Chr8(Value and $0F);
          $E000:
            FRegisters[0] := Value and $0F;
          $E001:
            Mirror((Value shr 3) and 1);
          $E002:
            begin
              FIrqEnabled := (Value and 2) <> 0;
              if not FIrqEnabled then
              begin
                FIrqCounter := 0;
                FIrqPending := False;
              end;
            end;
        end;
        Result := True;
      end;
    41:
      begin
        if (Address >= $6000) and (Address <= $67FF) then
        begin
          FOuter := Address and $FF;
          Prg32(FOuter and 7);
          Chr8((((FOuter shr 3) and 3) shl 2) or FSelect);
          Mirror((FOuter shr 5) and 1);
          Result := True;
        end
        else if (Address >= $8000) and ((FOuter and 4) <> 0) then
        begin
          FSelect := Value and FPrgRom[PrgOffset(Address)] and 3;
          Chr8((((FOuter shr 3) and 3) shl 2) or FSelect);
          Result := True;
        end;
      end;
    58:
      if Address >= $8000 then
      begin
        Bank := Address and 7;
        if (Address and $40) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Chr8((Address shr 3) and 7);
        Mirror((Address shr 7) and 1);
        Result := True;
      end;
    61:
      if Address >= $8000 then
      begin
        Bank := (Address and $0F) * 2;
        if (Address and $10) <> 0 then
        begin
          Bank := Bank or ((Address shr 5) and 1);
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Address and $0F);
        if not FHasChrRam then
        begin
          Bank := (Address shr 8) and $0F;
          if FSubmapper = 1 then
            Bank := (Bank shl 1) or ((Address shr 6) and 1);
          Chr8(Bank);
        end;
        Mirror((Address shr 7) and 1);
        Result := True;
      end;
    78:
      if Address >= $8000 then
      begin
        Value := Value and FPrgRom[PrgOffset(Address)];
        Prg16(0, Value and 7);
        Chr8(Value shr 4);
        if (FSubmapper = 3) or ((FSubmapper = 0) and (FInitialMirror = TMirrorMode.FourScreen)) then
          Mirror(1 - ((Value shr 3) and 1))
        else
          Mirror(2 + ((Value shr 3) and 1));
        Result := True;
      end;
    81:
      if Address >= $8000 then
      begin
        Prg16(0, (Address shr 2) and 3);
        Chr8(Address and 3);
        Result := True;
      end;
    93:
      if Address >= $8000 then
      begin
        Value := Value and FPrgRom[PrgOffset(Address)];
        Prg16(0, (Value shr 4) and 7);
        FChrWritable := (Value and 1) <> 0;
        Result := True;
      end;
    94:
      if Address >= $8000 then
      begin
        Value := Value and FPrgRom[PrgOffset(Address)];
        Prg16(0, (Value shr 2) and 7);
        Result := True;
      end;
    108:
      if Address >= $8000 then
      begin
        case FSubmapper of
          1:
            if Address >= $F000 then
              FRegisters[0] := Value;
          2:
            if Address >= $E000 then
            begin
              FRegisters[0] := Value;
              Chr8(Value);
            end;
          3:
            FRegisters[0] := Value;
          4:
            Chr8(Value);
        end;
        Result := True;
      end;
    148:
      if Address >= $8000 then
      begin
        Value := Value and FPrgRom[PrgOffset(Address)];
        Prg32((Value shr 3) and 7);
        Chr8((Value and 7) or ((Value shr 3) and 8));
        Result := True;
      end;
    200:
      if Address >= $8000 then
      begin
        Bank := Address and $0F;
        Prg16(0, Bank);
        Prg16(1, Bank);
        Chr8(Bank);
        Mirror((Address shr 3) and 1);
        Result := True;
      end;
    212:
      if Address >= $8000 then
      begin
        Bank := Address and 7;
        Chr8(Bank);
        if (Address and $4000) = 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Mirror((Address shr 3) and 1);
        Result := True;
      end;
    33:
      if (Address >= $8000) and (Address < $C000) then
      begin
        case Address and $A003 of
          $8000:
            begin
              Prg8(0, Value and $3F);
              Mirror((Value shr 6) and 1);
            end;
          $8001: Prg8(1, Value and $3F);
          $8002: Chr2(0, Value);
          $8003: Chr2(1, Value);
          $A000..$A003: Chr1(4 + (Address and 3), Value);
        end;
        Result := True;
      end;
    75:
      if Address >= $8000 then
      begin
        case Address and $F000 of
          $8000: Prg8(0, Value and $0F);
          $A000: Prg8(1, Value and $0F);
          $C000: Prg8(2, Value and $0F);
          $9000:
            begin
              if FInitialMirror <> TMirrorMode.FourScreen then
                Mirror(Value and 1);
              FOuter := Value;
            end;
          $E000: FRegisters[0] := Value and $0F;
          $F000: FRegisters[1] := Value and $0F;
        end;
        Chr4(0, FRegisters[0] or ((FOuter and 2) shl 3));
        Chr4(1, FRegisters[1] or ((FOuter and 4) shl 2));
        Result := True;
      end;
    31:
      if (Address and $F000) = $5000 then
      begin
        FRegisters[Address and 7] := Value;
        Result := True;
      end;
    184:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Chr4(0, Value and 7);
        Chr4(1, ((Value shr 4) and 3) or 4);
        Result := True;
      end;
    101:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Chr8(Value);
        Result := True;
      end;
    133, 145:
      if (Address and $E100) = $4100 then
      begin
        if FBoard = 133 then
        begin
          // SA-72008 (72-pin): the 60-pin analog feedback board is not modeled.
          Prg32((Value shr 2) and 1);
          Chr8(Value and 3);
        end
        else
          Chr8(Value shr 7);
        Result := True;
      end;
    8:
      begin
        case Address of
          $42FE:
            Mirror(2 + ((Value shr 4) and 1));
          $42FF:
            Mirror((Value shr 4) and 1);
          $4501:
            begin
              FIrqEnabled := False;
              FIrqPending := False;
            end;
          $4502:
            begin
              FIrqCounter := (FIrqCounter and $FF00) or Value;
              FIrqPending := False;
            end;
          $4503:
            begin
              FIrqCounter := (FIrqCounter and $FF) or (Integer(Value) shl 8);
              FIrqEnabled := True;
              FIrqPending := False;
            end;
        end;
        if Address >= $8000 then
        begin
          Prg16(0, Value shr 3);
          Chr8(Value and 7);
        end;
        Result := Result or (Address >= $8000) or ((Address >= $42FE) and (Address <= $4503));
      end;
    13:
      if Address >= $8000 then
      begin
        Chr4(1, Value and 3);
        Result := True;
      end;
    15:
      if Address >= $8000 then
      begin
        FChrWritable := FLegacyChrWrites or ((Address and 3) in [1, 2]);
        Mirror((Value shr 6) and 1);
        Bank := (Value and $7F) * 2;
        var SubBank := Value shr 7;
        case Address and 3 of
          0:
            for var i := 0 to 3 do
              Prg8(i, (Bank + i) xor SubBank);
          1, 3:
            begin
              Bank := Bank or SubBank;
              Prg8(0, Bank);
              Prg8(1, Bank + 1);
              if (Address and 3) = 1 then
                Bank := Bank or $0E;
              Prg8(2, Bank);
              Prg8(3, Bank + 1);
            end;
          2:
            for var i := 0 to 3 do
              Prg8(i, Bank or SubBank);
        end;
        Result := True;
      end;
    32:
      if Address >= $8000 then
      begin
        case Address and $F000 of
          $8000:
            FRegisters[0] := Value and $1F;
          $9000:
            begin
              FSelect := Value and 2;
              Mirror(Value and 1);
            end;
          $A000:
            FRegisters[1] := Value and $1F;
          $B000:
            Chr1(Address and 7, Value);
        end;
        Prg8(1, FRegisters[1]);
        Prg8(0, -2);
        Prg8(2, -2);
        Prg8(FSelect, FRegisters[0]);
        Result := True;
      end;
    34:
      if FHasChrRam then
      begin
        if Address >= $8000 then
        begin
          Prg32(Value and FPrgRom[PrgOffset(Address)]);
          Result := True;
        end;
      end
      else
        case Address of
          $7FFD:
            Prg32(Value and 1);
          $7FFE:
            Chr4(0, Value and $0F);
          $7FFF:
            Chr4(1, Value and $0F);
        end;
    70, 152:
      if Address >= $8000 then
      begin
        Value := Value and FPrgRom[PrgOffset(Address)];
        Prg16(0, (Value shr 4) and 7);
        Chr8(Value and $0F);
        if FBoard = 152 then
          Mirror(2 + (Value shr 7));
        Result := True;
      end;
    71:
      if Address >= $8000 then
      begin
        if (Address and $F000) = $9000 then
          Mirror(2 + ((Value shr 4) and 1))
        else if Address >= $C000 then
          Prg16(0, Value and $0F);
        Result := True;
      end;
    79, 113:
      if (Address and $E100) = $4100 then
      begin
        if FBoard = 79 then
        begin
          Prg32((Value shr 3) and 1);
          Chr8(Value and 7);
        end
        else
        begin
          Prg32((Value shr 3) and 7);
          Chr8((Value and 7) or ((Value shr 3) and 8));
          Mirror(1 - (Value shr 7));
        end;
        Result := True;
      end;
    87:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Chr8(((Value and 1) shl 1) or ((Value and 2) shr 1));
        Result := True;
      end;
    88, 154, 206:
      if Address >= $8000 then
      begin
        if FBoard = 154 then
          Mirror(2 + ((Value shr 6) and 1));
        if (Address and 1) = 0 then
          FSelect := Value and 7
        else
          FRegisters[FSelect] := Value;
        UpdateIndexedBanks;
        Result := True;
      end;
    99:
      if Address = $4016 then
      begin
        Chr8((Value shr 2) and 1);
        if Length(FPrgRom) > $8000 then
          Prg8(0, Value and 4);
        Result := True;
      end;
    112:
      if Address >= $8000 then
      begin
        case Address and $E001 of
          $8000:
            FSelect := Value and 7;
          $A000:
            FRegisters[FSelect] := Value;
          $C000:
            FOuter := Value;
          $E000:
            Mirror(Value and 1);
        end;
        UpdateIndexedBanks;
        Result := True;
      end;
    // Independently implemented from NESdev's JF-11/JF-14 register description.
    140:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Prg32((Value shr 4) and 3);
        Chr8(Value and $0F);
        Result := True;
      end;
    // Inverted UxROM: bank zero stays at $8000, upper window is switchable.
    180:
      if Address >= $8000 then
      begin
        Value := Value and FPrgRom[PrgOffset(Address)];
        Prg16(1, Value);
        Result := True;
      end;
    144:
      if Address >= $8000 then
      begin
        var RomValue := FPrgRom[PrgOffset(Address)];
        Value := (Value and RomValue) or (RomValue and 1);
        Prg32(Value and $0F);
        Chr8(Value shr 4);
        Result := True;
      end;
    228:
      if Address >= $8000 then
      begin
        var Chip := (Address shr 11) and 3;
        if Chip = 3 then
          Chip := 2;
        Bank := ((Address shr 6) and $1F) or (Chip shl 5);
        if (Address and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Chr8(((Address and $0F) shl 2) or (Value and 3));
        Mirror((Address shr 13) and 1);
        Result := True;
      end;
    232:
      if Address >= $8000 then
      begin
        if Address < $C000 then
          FOuter := (Value shr 3) and 3
        else
          FSelect := Value and 3;
        Prg16(0, (FOuter shl 2) or FSelect);
        Prg16(1, (FOuter shl 2) or 3);
        Result := True;
      end;
    240:
      if (Address >= $4020) and (Address < $6000) then
      begin
        Prg32(Value shr 4);
        Chr8(Value and $0F);
        Result := True;
      end;
    242:
      if Address >= $8000 then
      begin
        Prg32((Address shr 3) and $0F);
        Mirror((Address shr 1) and 1);
        Result := True;
      end;
  end;
end;

function TMapperDiscrete.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = 93) and (Address < $2000) and not FChrWritable then
    Exit(False);
  Result := inherited;
end;

function TMapperDiscrete.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if not FChrWritable then
    Exit(False);
  Result := inherited;
end;

procedure TMapperDiscrete.ClockCpu;
begin
  if FBoard = 73 then
  begin
    if FIrqEnabled then
    begin
      var Latch := FRegisters[0] or (Integer(FRegisters[1]) shl 4) or
        (Integer(FRegisters[2]) shl 8) or (Integer(FRegisters[3]) shl 12);
      if (FRegisters[4] and 4) <> 0 then
      begin
        if (FIrqCounter and $FF) = $FF then
        begin
          FIrqPending := True;
          FIrqCounter := (FIrqCounter and $FF00) or (Latch and $FF);
        end
        else
          FIrqCounter := (FIrqCounter and $FF00) or ((FIrqCounter + 1) and $FF);
      end
      else if FIrqCounter = $FFFF then
      begin
        FIrqPending := True;
        FIrqCounter := Latch;
      end
      else
        FIrqCounter := (FIrqCounter + 1) and $FFFF;
    end;
    Exit;
  end;
  if FBoard = 18 then
  begin
    if FIrqEnabled then
    begin
      var Mask := $FFFF;
      if (FRegisters[15] and 8) <> 0 then
        Mask := $000F
      else if (FRegisters[15] and 4) <> 0 then
        Mask := $00FF
      else if (FRegisters[15] and 2) <> 0 then
        Mask := $0FFF;
      if (FIrqCounter and Mask) = 0 then
        FIrqPending := True;
      FIrqCounter := (FIrqCounter and not Mask) or ((FIrqCounter - 1) and Mask);
    end;
    Exit;
  end;
  if FBoard = 42 then
  begin
    if FIrqEnabled then
    begin
      FIrqCounter := (FIrqCounter + 1) and $7FFF;
      FIrqPending := FIrqCounter >= $6000;
    end;
    Exit;
  end;
  if FIrqEnabled then
  begin
    FIrqCounter := (FIrqCounter + 1) and $FFFF;
    if FIrqCounter = 0 then
    begin
      FIrqPending := True;
      FIrqEnabled := False;
    end;
  end;
end;

function TMapperDiscrete.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

end.

