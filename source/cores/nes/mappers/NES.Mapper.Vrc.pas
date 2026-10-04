unit NES.Mapper.Vrc;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperVrc = class(TMapperBanked)
  protected
    FBoard, FSubmapper, FPrescaler, FCounter, FLatch: Integer;
    FChrRegisters: array[0..7] of Integer;
    FPrg0, FPrg1, FSwap, FControl, FRamLatch: Byte;
    FPending: Boolean;
    FHybridRam: array[0..$7FF] of Byte;
    FForceRom: Boolean;
    procedure TickIrq;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure Reset; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperVrc.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FPrescaler, SizeOf(FPrescaler));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FPrg0, SizeOf(FPrg0));
  State.Field(FPrg1, SizeOf(FPrg1));
  State.Field(FSwap, SizeOf(FSwap));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FRamLatch, SizeOf(FRamLatch));
  State.Field(FPending, SizeOf(FPending));
  if FBoard = MAPPER_VRC4_253 then
  begin
    State.Field(FHybridRam, SizeOf(FHybridRam));
    State.Field(FForceRom, SizeOf(FForceRom))
  end;
end;

constructor TMapperVrc.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  Reset;
end;

procedure TMapperVrc.Reset;
begin
  inherited;
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  FPrg0 := 0;
  FPrg1 := 1;
  FSwap := 0;
  FControl := 0;
  FRamLatch := 0;
  FPrescaler := 341;
  FCounter := 0;
  FLatch := 0;
  FPending := False;
  FForceRom := False;
  Prg8(0, 0);
  Prg8(1, 1);
end;

function TMapperVrc.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_VRC2_VRC4_183) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(Integer(FRamLatch) * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (FBoard = MAPPER_VRC2A) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FRamLatch;
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperVrc.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_WAIXING_252) or (FBoard = MAPPER_VRC4_253) or (FBoard = MAPPER_TF1201) or (FBoard = MAPPER_T230) then
  begin
    if Address < $8000 then
      Exit(inherited CpuWrite(Address, Value));

    var A := Address;
    if FBoard = MAPPER_T230 then
      A := (Address and $F000) or (Ord((Address and $2A) <> 0) shl 1) or Ord((Address and $15) <> 0);
    if FBoard = MAPPER_TF1201 then
      A := (Address and $F003) or ((Address and 12) shr 2);
    if (A >= $B000) and (A < $F000) then
    begin
      var Slot: Integer;
      var Shift: Integer;
      if FBoard = MAPPER_WAIXING_252 then
      begin
        Slot := (((A - $B000) shr 11) and 6) or ((A shr 3) and 1);
        Shift := A and 4
      end
      else if FBoard = MAPPER_VRC4_253 then
      begin
        Slot := ((((A and 8) or (A shr 8)) shr 3) + 2) and 7;
        Shift := A and 4
      end
      else if FBoard = MAPPER_TF1201 then
      begin
        Slot := (((A shr 11) - 6) or (A and 1)) and 7;
        Shift := (A and 2) * 2
      end
      else
      begin
        Slot := ((A shr 12) - 11) * 2 + ((A shr 1) and 1);
        Shift := (A and 1) * 4
      end;
      var Mask := 15;
      if (FBoard = MAPPER_T230) and (Shift = 4) then
        Mask := 31;
      if (FBoard = MAPPER_T230) and FHasChrRam then
        FRamLatch := (Value and 8) shl 2
      else
      begin
        FChrRegisters[Slot] := (FChrRegisters[Slot] and ($1FF xor (Mask shl Shift))) or ((Value and Mask) shl Shift);
        if (FBoard = MAPPER_VRC4_253) and (Shift = 4) then
          FChrRegisters[Slot] := (FChrRegisters[Slot] and $FF) or ((Value shr 4) shl 8);
        if (FBoard = MAPPER_VRC4_253) and (Slot = 0) then
          if (FChrRegisters[Slot] and $FF) = $C8 then
            FForceRom := False
          else if (FChrRegisters[Slot] and $FF) = $88 then
            FForceRom := True;
        Chr1(Slot, FChrRegisters[Slot]);
      end;
    end
    else if A >= $F000 then
    begin
      var R := A and 3;
      if (FBoard = MAPPER_WAIXING_252) or (FBoard = MAPPER_VRC4_253) then
        R := (A shr 2) and 3;
      if FBoard = MAPPER_TF1201 then
        case R of
          1:
            R := 2;
          2:
            R := 1
        end;
      case R of
        0:
          begin
            FLatch := (FLatch and $F0) or (Value and 15);
            if FBoard = MAPPER_VRC4_253 then
              FPending := False
          end;
        1:
          begin
            FLatch := (FLatch and 15) or ((Value and 15) shl 4);
            if FBoard = MAPPER_VRC4_253 then
              FPending := False
          end;
        2:
          begin
            FControl := Value and 7;
            FPending := False;
            if (FControl and 2) <> 0 then
            begin
              FCounter := FLatch;
              FPrescaler := 341
            end;
            if FBoard = MAPPER_VRC4_253 then
            begin
              FCounter := FLatch;
              FPrescaler := 114;
              FControl := Value and 2
            end
          end;
        3:
          begin
            FPending := False;
            FControl := (FControl and 5) or ((FControl and 1) shl 1)
          end;
      end;
    end
    else if (FBoard = MAPPER_VRC4_253) then
      case A of
        $8010:
          FPrg0 := Value;
        $A010:
          FPrg1 := Value;
        $9400:
          Mirror(Value and 3)
      end
    else if (FBoard = MAPPER_T230) then
      case A and $F002 of
        $9000:
          Mirror(Value and 3);
        $9002:
          FSwap := Value and 2;
        $A000, $A002:
          begin
            FPrg0 := (Value and 31) shl 1;
            FPrg1 := FPrg0 or 1
          end;
      end
    else
      case A and $F000 of
        $8000:
          FPrg0 := Value;
        $A000:
          FPrg1 := Value;
        $9000:
          if (FBoard = MAPPER_TF1201) and ((A and 3) = 1) then
            FSwap := Ord((Value and 3) <> 0) * 2
          else
            Mirror(Value and 1);
      end;
    Prg8(0, -2);
    Prg8(2, -2);
    Prg8(FSwap, FPrg0);
    Prg8(1, FPrg1);
    if FBoard = MAPPER_T230 then
    begin
      Prg8(2 - FSwap, 30 or FRamLatch);
      Prg8(FSwap, FPrg0 or FRamLatch)
    end;
    Exit(True);
  end;

  if Address < $8000 then
  begin
    if (FBoard = MAPPER_VRC2_VRC4_183) and (Address >= $6000) then
    begin
      FRamLatch := Address and 15;
      Exit(True)
    end;
    if (FBoard = MAPPER_VRC2A) and (Address >= $6000) then
    begin
      FRamLatch := Value and 1;
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;

  var LowBits: Integer;
  if FBoard = MAPPER_VRC2A then
    LowBits := ((Address shr 1) and 1) or ((Address and 1) shl 1)
  else if FBoard = MAPPER_VRC4A_VRC4C then
  begin
    if FSubmapper = 1 then
      LowBits := ((Address shr 1) and 1) or (((Address shr 2) and 1) shl 1)
    else if FSubmapper = 2 then
      LowBits := ((Address shr 6) and 1) or (((Address shr 7) and 1) shl 1)
    else
      LowBits := (((Address shr 1) or (Address shr 6)) and 1) or ((((Address shr 2) or (Address shr 7)) and 1) shl 1);
  end
  else if FBoard = MAPPER_VRC2_VRC4_27 then
    LowBits := Address and 3
  else if FBoard = MAPPER_VRC2_VRC4_183 then
    LowBits := (Address shr 2) and 3
  else if FBoard = MAPPER_VRC2C_VRC4B then
    LowBits := (((Address shr 1) or (Address shr 3)) and 1) or (((Address or (Address shr 2)) and 1) shl 1)
  else
    LowBits := ((Address or (Address shr 2)) and 1) or ((((Address shr 1) or (Address shr 3)) and 1) shl 1);
  var Page := Address shr 12;
  case Page of
    8:
      FPrg0 := Value and $1F;
    9:
      if (FBoard = MAPPER_VRC2A) or (LowBits < 2) then
        Mirror(Value and 3)
      else
        FSwap := Value and 2;
    $A:
      FPrg1 := Value and $1F;
    $B..$E:
      begin
        var Slot := (Page - $B) * 2 + (LowBits shr 1);
        if (LowBits and 1) = 0 then
          FChrRegisters[Slot] := (FChrRegisters[Slot] and $1F0) or (Value and $0F)
        else
          FChrRegisters[Slot] := (FChrRegisters[Slot] and $0F) or ((Value and $1F) shl 4);
        if FBoard = MAPPER_VRC2A then
          Chr1(Slot, FChrRegisters[Slot] shr 1)
        else
          Chr1(Slot, FChrRegisters[Slot]);
      end;
    $F:
      if FBoard <> MAPPER_VRC2A then
        case LowBits of
          0:
            FLatch := (FLatch and $F0) or (Value and $0F);
          1:
            FLatch := (FLatch and $0F) or ((Value and $0F) shl 4);
          2:
            begin
              FControl := Value and 7;
              FPending := False;
              if (FControl and 2) <> 0 then
              begin
                FCounter := FLatch;
                FPrescaler := 341;
              end;
            end;
          3:
            begin
              FPending := False;
              FControl := (FControl and 5) or ((FControl and 1) shl 1);
            end;
        end;
  end;
  Prg8(0, -2);
  Prg8(2, -2);
  Prg8(FSwap, FPrg0);
  Prg8(1, FPrg1);
  Result := True;
end;

procedure TMapperVrc.TickIrq;
begin
  if FCounter = $FF then
  begin
    if FBoard = MAPPER_TF1201 then
      FCounter := 0
    else
      FCounter := FLatch;
    FPending := True;
  end
  else
    Inc(FCounter);
end;

function TMapperVrc.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_VRC4_253) and (Address < $2000) and not FForceRom then
  begin
    var Bank := FChrRegisters[Address shr 10] and $FF;
    if (Bank = 4) or (Bank = 5) then
    begin
      Value := FHybridRam[(Bank and 1) * $400 + (Address and $3FF)];
      Exit(True)
    end;
  end;

  Result := inherited;
end;

function TMapperVrc.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_VRC4_253) and (Address < $2000) and not FForceRom then
  begin
    var Bank := FChrRegisters[Address shr 10] and $FF;
    if (Bank = 4) or (Bank = 5) then
    begin
      FHybridRam[(Bank and 1) * $400 + (Address and $3FF)] := Value;
      Exit(True)
    end;
  end;

  if (FBoard = MAPPER_WAIXING_252) and (Address < $2000) then
  begin
    FChrMemory[ChrOffset(Address)] := Value;
    Exit(True)
  end;

  Result := inherited;
end;

procedure TMapperVrc.ClockCpu;
begin
  if (FControl and 2) = 0 then
    Exit;

  if FBoard = MAPPER_VRC4_253 then
  begin
    Dec(FPrescaler);
    if FPrescaler <= 0 then
    begin
      FPrescaler := 114;
      TickIrq
    end;
    Exit
  end;

  if (FControl and 4) <> 0 then
    TickIrq
  else
  begin
    Dec(FPrescaler, 3);
    if FPrescaler <= 0 then
    begin
      Inc(FPrescaler, 341);
      TickIrq;
    end;
  end;
end;

function TMapperVrc.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

