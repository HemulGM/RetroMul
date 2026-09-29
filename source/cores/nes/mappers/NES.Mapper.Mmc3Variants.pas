unit NES.Mapper.Mmc3Variants;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Mmc3;

type
  TMapperMmc3Variant = class(TMapperMmc3)
  private
    FBoard: Integer;
    FOuterChr: Byte;
    FExtraRam: array[0..$1FFF] of Byte;
    function ChrBank(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperMmc3Variant.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FOuterChr, SizeOf(FOuterChr));
  State.Field(FExtraRam, SizeOf(FExtraRam));
end;

constructor TMapperMmc3Variant.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  Reset;
end;

procedure TMapperMmc3Variant.Reset;
begin
  inherited;
  FOuterChr := 0;
end;

procedure TMapperMmc3Variant.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  var WasPending := FIrqPending;
  var CanTrigger := (FIrqCounter <> 0) or FIrqReloadPending;
  inherited;
  // Revision A does not repeatedly assert IRQ when reloading zero automatically.
  if (FBoard = 12) and not CanTrigger then
    FIrqPending := WasPending;
end;

function TMapperMmc3Variant.ChrBank(Address: UInt16): Integer;
begin
  var Original := Address;
  if (FBankSelect and $80) <> 0 then
    Address := Address xor $1000;
  var Slot := Address shr 10;
  if Slot < 4 then
    Result := (FBankRegisters[Slot shr 1] and $FE) or (Slot and 1)
  else
    Result := FBankRegisters[Slot - 2];
  if FBoard = 12 then
    if ((Original < $1000) and ((FOuterChr and 1) <> 0)) or
      ((Original >= $1000) and ((FOuterChr and $10) <> 0)) then
      Result := Result or $100;
  if (FBoard = 245) and FHasChrRam then
    Result := Address shr 10;
end;

function TMapperMmc3Variant.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = 91) and (Address < $8000) then
    Exit(False);
  if (FBoard <> 245) or (Address < $8000) then
    Exit(inherited CpuRead(Address, Value));
  var Outer := (FBankRegisters[0] and 2) shl 5;
  var Count := Length(FPrgRom) div $2000;
  var LastBank := Count - 1;
  if Count >= $40 then
    LastBank := $3F or Outer;
  var Slot := (Address - $8000) shr 13;
  if (FBankSelect and $40) <> 0 then
    if Slot = 0 then
      Slot := 2
    else if Slot = 2 then
      Slot := 0;
  var Bank: Integer;
  case Slot of
    0:
      Bank := (FBankRegisters[6] and $3F) or Outer;
    1:
      Bank := (FBankRegisters[7] and $3F) or Outer;
    2:
      Bank := LastBank - 1;
  else
    Bank := LastBank;
  end;
  Value := FPrgRom[(Bank mod Count) * $2000 + (Address and $1FFF)];
  Result := True;
end;

function TMapperMmc3Variant.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = 12) and (Address >= $4020) and (Address < $6000) then
  begin
    FOuterChr := Value;
    Exit(True);
  end;
  if FBoard = 91 then
  begin
    Result := (Address >= $6000) and (Address < $8000);
    if not Result then
      Exit;
    case Address and $7003 of
      $6000, $6001:
        FBankRegisters[Address and 1] := (Integer(Value) * 2) and $FF;
      $6002, $6003:
        begin
          var Slot := 2 + (Address and 1) * 2;
          FBankRegisters[Slot] := (Integer(Value) * 2) and $FF;
          FBankRegisters[Slot + 1] := (Integer(Value) * 2 + 1) and $FF;
        end;
      $7000, $7001:
        FBankRegisters[6 + (Address and 1)] := Value and $0F;
      $7002:
        inherited CpuWrite($E000, 0);
      $7003:
        begin
          inherited CpuWrite($C000, 7);
          inherited CpuWrite($C001, 0);
          inherited CpuWrite($E001, 0);
        end;
    end;
    Exit;
  end;
  if (FBoard = 250) and (Address >= $8000) then
  begin
    Value := Address and $FF;
    Address := (Address and $E000) or ((Address shr 10) and 1);
  end;
  Result := inherited CpuWrite(Address, Value);
end;

function TMapperMmc3Variant.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if not Result then
    Exit;
  var Bank := ChrBank(Address);
  if (FBoard = 119) and ((Bank and $40) <> 0) then
    Value := FExtraRam[(Bank and 7) * $400 + (Address and $3FF)]
  else
    Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)];
end;

function TMapperMmc3Variant.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := False;
  if Address >= $2000 then
    Exit;
  var Bank := ChrBank(Address);
  if (FBoard = 119) and ((Bank and $40) <> 0) then
  begin
    FExtraRam[(Bank and 7) * $400 + (Address and $3FF)] := Value;
    Exit(True);
  end;
  if FHasChrRam then
  begin
    FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value;
    Result := True;
  end;
end;

end.

