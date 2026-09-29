unit NES.Mapper.Vrc;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperVrc = class(TMapperBanked)
  private
    FBoard, FPrescaler, FCounter, FLatch: Integer;
    FChrRegisters: array[0..7] of Integer;
    FPrg0, FPrg1, FSwap, FControl, FRamLatch: Byte;
    FPending: Boolean;
    procedure TickIrq;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
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
end;

constructor TMapperVrc.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
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
  Prg8(0, 0);
  Prg8(1, 1);
end;

function TMapperVrc.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = 22) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FRamLatch;
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperVrc.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
  begin
    if (FBoard = 22) and (Address >= $6000) then
    begin
      FRamLatch := Value and 1;
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;
  var LowBits: Integer;
  if FBoard = 22 then
    LowBits := ((Address shr 1) and 1) or ((Address and 1) shl 1)
  else if FBoard = 25 then
    LowBits := (((Address shr 1) or (Address shr 3)) and 1) or (((Address or (Address shr 2)) and 1) shl 1)
  else
    LowBits := ((Address or (Address shr 2)) and 1) or ((((Address shr 1) or (Address shr 3)) and 1) shl 1);
  var Page := Address shr 12;
  case Page of
    8:
      FPrg0 := Value and $1F;
    9:
      if (FBoard = 22) or (LowBits < 2) then
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
        if FBoard = 22 then
          Chr1(Slot, FChrRegisters[Slot] shr 1)
        else
          Chr1(Slot, FChrRegisters[Slot]);
      end;
    $F:
      if FBoard <> 22 then
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
    FCounter := FLatch;
    FPending := True;
  end
  else
    Inc(FCounter);
end;

procedure TMapperVrc.ClockCpu;
begin
  if (FControl and 2) = 0 then
    Exit;
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

