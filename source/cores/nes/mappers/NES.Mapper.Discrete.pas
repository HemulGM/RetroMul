unit NES.Mapper.Discrete;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperDiscrete = class(TMapperBanked)
  private
    FBoard: Integer;
    FRegisters: array[0..15] of Byte;
    FSelect, FOuter: Byte;
    FIrqCounter: Integer;
    FIrqEnabled, FIrqPending, FChrWritable, FLegacyChrWrites: Boolean;
    procedure UpdateIndexedBanks;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean = False);
    procedure Reset; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
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

constructor TMapperDiscrete.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
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
  inherited;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FSelect := 0;
  FOuter := 0;
  FIrqCounter := 0;
  FIrqEnabled := False;
  FIrqPending := False;
  FChrWritable := True;
  case FBoard of
    8, 13, 34, 79, 87, 99, 113, 144, 228, 240, 242:
      Prg32(0);
    32, 88, 112, 154, 206:
      begin
        Prg8(0, 0);
        Prg8(1, 1);
      end;
    232:
      Prg16(1, 3);
  end;
  if FBoard in [13, 242] then
    Mirror(0);
  if FBoard = 15 then
    CpuWrite($8000, 0);
  if FBoard in [88, 154, 206, 112] then
    UpdateIndexedBanks;
  FRamEnabled := FBoard in [8, 15, 32, 34, 112, 242];
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

function TMapperDiscrete.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := inherited CpuWrite(Address, Value);
  var Bank: Integer;
  case FBoard of
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

function TMapperDiscrete.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if not FChrWritable then
    Exit(False);
  Result := inherited;
end;

procedure TMapperDiscrete.ClockCpu;
begin
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

