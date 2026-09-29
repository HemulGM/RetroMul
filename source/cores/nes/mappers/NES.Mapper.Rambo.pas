unit NES.Mapper.Rambo;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperRambo = class(TMapperBanked)
  private
    FRegisters: array[0..15] of Byte;
    FSelect: Byte;
    FCounter, FLatch, FCpuDivider, FDelay: Integer;
    FEnabled, FPending, FReload, FCycleMode, FForceClock, FA12High: Boolean;
    FA12LowSince: UInt64;
    procedure UpdateBanks;
    procedure TickIrq(Delay: Integer);
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperRambo.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FCpuDivider, SizeOf(FCpuDivider));
  State.Field(FDelay, SizeOf(FDelay));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FReload, SizeOf(FReload));
  State.Field(FCycleMode, SizeOf(FCycleMode));
  State.Field(FForceClock, SizeOf(FForceClock));
  State.Field(FA12High, SizeOf(FA12High));
  State.Field(FA12LowSince, SizeOf(FA12LowSince));
end;

constructor TMapperRambo.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited;
  Reset;
end;

procedure TMapperRambo.Reset;
begin
  inherited;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FSelect := 0;
  FCounter := 0;
  FLatch := 0;
  FCpuDivider := 0;
  FDelay := 0;
  FEnabled := False;
  FPending := False;
  FReload := False;
  FCycleMode := False;
  FForceClock := False;
  FA12High := False;
  FA12LowSince := 0;
  FRamEnabled := False;
  UpdateBanks;
end;

procedure TMapperRambo.UpdateBanks;
begin
  if (FSelect and $40) = 0 then
  begin
    Prg8(0, FRegisters[6]);
    Prg8(1, FRegisters[7]);
    Prg8(2, FRegisters[15]);
  end
  else
  begin
    Prg8(0, FRegisters[15]);
    Prg8(1, FRegisters[6]);
    Prg8(2, FRegisters[7]);
  end;
  var Flip := (FSelect shr 5) and 4;
  Chr1(0 xor Flip, FRegisters[0]);
  Chr1(2 xor Flip, FRegisters[1]);
  for var i := 4 to 7 do
    Chr1(i xor Flip, FRegisters[i - 2]);
  if (FSelect and $20) <> 0 then
  begin
    Chr1(1 xor Flip, FRegisters[8]);
    Chr1(3 xor Flip, FRegisters[9]);
  end
  else
  begin
    Chr1(1 xor Flip, FRegisters[0] + 1);
    Chr1(3 xor Flip, FRegisters[1] + 1);
  end;
end;

function TMapperRambo.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if not Result then
    Exit;
  case Address and $E001 of
    $8000:
      begin
        FSelect := Value;
        UpdateBanks;
      end;
    $8001:
      begin
        FRegisters[FSelect and $0F] := Value;
        UpdateBanks;
      end;
    $A000:
      Mirror(Value and 1);
    $C000:
      FLatch := Value;
    $C001:
      begin
        FForceClock := FCycleMode and ((Value and 1) = 0);
        FCycleMode := (Value and 1) <> 0;
        FReload := True;
        if FCycleMode then
          FCpuDivider := 0;
      end;
    $E000:
      begin
        FEnabled := False;
        FPending := False;
        FDelay := 0;
      end;
    $E001:
      FEnabled := True;
  end;
end;

procedure TMapperRambo.TickIrq(Delay: Integer);
begin
  if FReload then
  begin
    FCounter := (FLatch + 1 + Ord(FLatch > 1)) and $FF;
    FReload := False;
  end
  else if FCounter = 0 then
    FCounter := (FLatch + 1) and $FF;
  FCounter := (FCounter - 1) and $FF;
  if (FCounter = 0) and FEnabled then
    FDelay := Delay;
end;

procedure TMapperRambo.ClockCpu;
begin
  if FDelay > 0 then
  begin
    Dec(FDelay);
    if FDelay = 0 then
      FPending := True;
  end;
  if FCycleMode or FForceClock then
  begin
    FCpuDivider := (FCpuDivider + 1) and 3;
    if FCpuDivider = 0 then
    begin
      TickIrq(1);
      FForceClock := False;
    end;
  end;
end;

procedure TMapperRambo.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  var High := (Address and $1000) <> 0;
  if not High and FA12High then
    FA12LowSince := PpuCycle;
  if High and not FA12High and not FCycleMode and (PpuCycle >= FA12LowSince) and
    (PpuCycle - FA12LowSince >= 30) then
    TickIrq(2);
  FA12High := High;
end;

function TMapperRambo.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

