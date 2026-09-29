unit NES.Mapper.Sunsoft;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperSunsoft = class(TMapperBanked)
  private
    FBoard, FCounter: Integer;
    FSelect, FWorkBank: Byte;
    FNametableBanks: array[0..1] of Byte;
    FUseChrNametables, FCountEnabled, FIrqEnabled, FPending: Boolean;
    function NameOffset(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperSunsoft.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FWorkBank, SizeOf(FWorkBank));
  State.Field(FNametableBanks, SizeOf(FNametableBanks));
  State.Field(FUseChrNametables, SizeOf(FUseChrNametables));
  State.Field(FCountEnabled, SizeOf(FCountEnabled));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FPending, SizeOf(FPending));
end;

constructor TMapperSunsoft.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  SetLength(FPrgRam, $8000);
  Reset;
end;

procedure TMapperSunsoft.Reset;
begin
  inherited;
  FSelect := 0;
  FWorkBank := 0;
  FCounter := 0;
  FCountEnabled := False;
  FIrqEnabled := False;
  FPending := False;
  FUseChrNametables := False;
  FillChar(FNametableBanks, SizeOf(FNametableBanks), 0);
  if FBoard = 69 then
  begin
    Prg8(0, 0);
    Prg8(1, 1);
    Prg8(2, 2);
  end
  else
  begin
    Prg16(1, 7);
    FRamEnabled := False;
  end;
end;

function TMapperSunsoft.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = 69) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FWorkBank and $40) = 0 then
      Value := FPrgRom[((FWorkBank and $3F) * $2000 + (Address and $1FFF)) mod Length(FPrgRom)]
    else if (FWorkBank and $80) <> 0 then
      Value := FPrgRam[(FWorkBank and 3) * $2000 + (Address and $1FFF)]
    else
      Exit(False);
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperSunsoft.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
  begin
    if (FBoard = 69) and (Address >= $6000) then
    begin
      if (FWorkBank and $C0) = $C0 then
        FPrgRam[(FWorkBank and 3) * $2000 + (Address and $1FFF)] := Value;
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
  if FBoard = 68 then
    case Address shr 12 of
      8..$B:
        Chr2((Address shr 12) - 8, Value);
      $C, $D:
        FNametableBanks[(Address shr 12) - $C] := Value or $80;
      $E:
        begin
          Mirror(Value and 3);
          FUseChrNametables := (Value and $10) <> 0;
        end;
      $F:
        begin
          Prg16(0, Value and 7);
          FRamEnabled := (Value and $10) <> 0;
        end;
    end
  else
    case Address and $E000 of
      $8000:
        FSelect := Value and $0F;
      $A000:
        case FSelect of
          0..7:
            Chr1(FSelect, Value);
          8:
            FWorkBank := Value;
          9..11:
            Prg8(FSelect - 9, Value and $3F);
          12:
            Mirror(Value and 3);
          13:
            begin
              FIrqEnabled := (Value and 1) <> 0;
              FCountEnabled := (Value and $80) <> 0;
              FPending := False;
            end;
          14:
            FCounter := (FCounter and $FF00) or Value;
          15:
            FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
        end;
    end;
end;

function TMapperSunsoft.NameOffset(Address: UInt16): Integer;
begin
  var Slot := ((Address - $2000) shr 10) and 3;
  case FMirror of
    TMirrorMode.Vertical:
      Slot := Slot and 1;
    TMirrorMode.Horizontal:
      Slot := Slot shr 1;
    TMirrorMode.Single0:
      Slot := 0;
    TMirrorMode.Single1:
      Slot := 1;
  else
    Slot := Slot and 1;
  end;
  Result := (FNametableBanks[Slot] * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperSunsoft.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FUseChrNametables and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FChrMemory[NameOffset(Address)];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperSunsoft.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FUseChrNametables and (Address >= $2000) and (Address < $3F00) then
  begin
    if FHasChrRam then
      FChrMemory[NameOffset(Address)] := Value;
    Exit(True);
  end;
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperSunsoft.ClockCpu;
begin
  if FCountEnabled then
  begin
    FCounter := (FCounter - 1) and $FFFF;
    if (FCounter = $FFFF) and FIrqEnabled then
      FPending := True;
  end;
end;

function TMapperSunsoft.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

