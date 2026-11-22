unit NES.Mapper.Rambo;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperRambo = class(TMapperBanked)
  private
    FRegisters: array[0..15] of Byte;
    FSelect: Byte;
    FCounter, FLatch: Integer;
    FCpuReloadDelay, FCpuExpiry: Integer;
    FEnabled, FPending, FReload, FCycleMode, FScanlineIrqWaiting, FA12High: Boolean;
    FA12LowFalls: Byte;
    FNametableBoard: Boolean;
    FNameBanks: array[0..3] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    procedure UpdatePrgBanks;
    procedure UpdateChrBanks;
    procedure ReloadIrq(Value: Byte);
    procedure ClockScanlineCounter;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; NametableBoard: Boolean = False);
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function NameTableOffset(Address: UInt16): UInt16; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure ClockCpuBus(Address: UInt16); override;
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
  if State.Version >= 42 then
  begin
    State.Field(FCpuReloadDelay, SizeOf(FCpuReloadDelay));
    State.Field(FCpuExpiry, SizeOf(FCpuExpiry));
    State.Field(FEnabled, SizeOf(FEnabled));
    State.Field(FPending, SizeOf(FPending));
    State.Field(FReload, SizeOf(FReload));
    State.Field(FCycleMode, SizeOf(FCycleMode));
    State.Field(FScanlineIrqWaiting, SizeOf(FScanlineIrqWaiting));
    State.Field(FA12High, SizeOf(FA12High));
    State.Field(FA12LowFalls, SizeOf(FA12LowFalls));
  end
  else
  begin
    var Divider: Integer := (-FCpuExpiry) and 3;
    var Delay: Integer := Ord(FScanlineIrqWaiting);
    var ForceClock: Boolean := False;
    var LowSince: UInt64 := 0;
    State.Field(Divider, SizeOf(Divider));
    State.Field(Delay, SizeOf(Delay));
    State.Field(FEnabled, SizeOf(FEnabled));
    State.Field(FPending, SizeOf(FPending));
    State.Field(FReload, SizeOf(FReload));
    State.Field(FCycleMode, SizeOf(FCycleMode));
    State.Field(ForceClock, SizeOf(ForceClock));
    State.Field(FA12High, SizeOf(FA12High));
    State.Field(LowSince, SizeOf(LowSince));
    if State.Loading then
    begin
      // Earlier states stored a PPU timestamp and a free-running divider.
      // Preserve the counter and pending line, then resume on a full M2 cycle.
      FA12LowFalls := 0;
      FScanlineIrqWaiting := (Delay > 0) and not FCycleMode;
      FCpuExpiry := 4 * (FCounter and $FF) + 4 - (Divider and 3);
      FCpuReloadDelay := 0;
      if FCycleMode and FReload then
        FCpuReloadDelay := 5
      else if FCycleMode and (Delay > 0) then
        FCpuExpiry := Delay;
    end;
  end;
  if FNametableBoard then
  begin
    State.Field(FNameBanks, SizeOf(FNameBanks));
    State.Field(FNameRam, SizeOf(FNameRam));
  end;
  if State.Loading then
  begin
    UpdatePrgBanks;
    UpdateChrBanks;
    FRamEnabled := False;
  end;
end;

constructor TMapperRambo.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; NametableBoard: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FNametableBoard := NametableBoard;
  PowerOn;
end;

procedure TMapperRambo.PowerOn;
begin
  inherited Reset;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FRegisters[6] := $1F;
  FRegisters[7] := $1F;
  FRegisters[15] := $1F;
  FSelect := $20;
  FCounter := 0;
  FLatch := $FF;
  FCpuReloadDelay := 0;
  FCpuExpiry := 1018;
  FEnabled := False;
  FPending := True;
  FReload := True;
  FCycleMode := True;
  FScanlineIrqWaiting := False;
  FA12High := False;
  FA12LowFalls := 4;
  FRamEnabled := False;
  Mirror(0);
  UpdatePrgBanks;
  UpdateChrBanks;
end;

procedure TMapperRambo.Reset;
begin
  // The console reset line does not reach the RAMBO-1.
end;

procedure TMapperRambo.UpdatePrgBanks;
begin
  var Swap := (FSelect and $40) shr 5;
  Prg8(Swap, FRegisters[6] and $1F);
  Prg8(1, FRegisters[7] and $1F);
  Prg8(2 xor Swap, FRegisters[15] and $1F);
  Prg8(3, $1F);
end;

procedure TMapperRambo.UpdateChrBanks;
const
  LowRegisters: array[0..3] of Byte = (0, 8, 1, 9);
begin
  var Flip := (FSelect and $80) shr 5;
  for var Slot := 0 to 7 do
  begin
    var Source := Slot xor Flip;
    var Bank: Byte;
    if Source >= 4 then
      Bank := FRegisters[Source - 2]
    else if (FSelect and $20) <> 0 then
      Bank := FRegisters[LowRegisters[Source]]
    else
      Bank := (FRegisters[Source shr 1] and $FE) or (Slot and 1);
    Chr1(Slot, Bank);
    if FNametableBoard and (Slot < 4) then
      FNameBanks[Slot] := Bank shr 7;
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
        var Changed := FSelect xor Value;
        FSelect := Value;
        if (Changed and $40) <> 0 then
          UpdatePrgBanks;
        if (Changed and $A0) <> 0 then
          UpdateChrBanks;
      end;
    $8001:
      begin
        var Index := FSelect and $0F;
        case Index of
          6, 7, 15:
            begin
              FRegisters[Index] := Value and $1F;
              UpdatePrgBanks;
            end;
          0..5, 8, 9:
            begin
              FRegisters[Index] := Value;
              UpdateChrBanks;
            end;
        end;
      end;
    $A000:
      if not FNametableBoard then
        Mirror(Value and 1);
    $C000:
      FLatch := Value;
    $C001:
      ReloadIrq(Value);
    $E000:
      begin
        FEnabled := False;
        FPending := False;
      end;
    $E001:
      FEnabled := True;
  end;
end;

procedure TMapperRambo.ReloadIrq(Value: Byte);
begin
  FScanlineIrqWaiting := False;
  if (Value and 1) <> 0 then
  begin
    FCpuReloadDelay := 6;
    if not FCycleMode and (FA12LowFalls < 16) then
      FCpuReloadDelay := 2;
    FCycleMode := True;
    Exit;
  end;
  FCycleMode := False;
  FReload := True;
  if FA12LowFalls = 16 then
    FA12LowFalls := 17;
end;

procedure TMapperRambo.ClockScanlineCounter;
begin
  if FReload then
  begin
    FReload := False;
    FCounter := FLatch;
  end
  else if FCounter = 0 then
  begin
    FCounter := FLatch;
    Exit;
  end
  else
    Dec(FCounter);
  FScanlineIrqWaiting := FCounter = 0;
end;

procedure TMapperRambo.ClockCpuBus(Address: UInt16);
begin
  // Sample M2 after the CPU write. An A12 expiry drives /IRQ on the next fall.
  if FScanlineIrqWaiting then
  begin
    FScanlineIrqWaiting := False;
    FPending := FPending or FEnabled;
  end;
  if FA12High then
  begin
    if (FA12LowFalls = 16) and not FCycleMode then
      ClockScanlineCounter;
    FA12LowFalls := 0;
  end
  else if FA12LowFalls < 16 then
    Inc(FA12LowFalls);

  if not FCycleMode then
    Exit;
  if FCpuReloadDelay > 0 then
  begin
    Dec(FCpuReloadDelay);
    if FCpuReloadDelay = 0 then
      FCpuExpiry := 4 * FLatch + 1;
  end
  else
  begin
    Dec(FCpuExpiry);
    if FCpuExpiry = 0 then
    begin
      FPending := FPending or FEnabled;
      FCpuExpiry := 4 * (FLatch + 1);
    end;
  end;
end;

procedure TMapperRambo.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  FA12High := (Address and $1000) <> 0;
end;

function TMapperRambo.IrqPending: Boolean;
begin
  Result := FPending;
end;

function TMapperRambo.NameTableOffset(Address: UInt16): UInt16;
begin
  if FNametableBoard then
    Exit((FNameBanks[(Address shr 10) and 3] shl 10) or (Address and $3FF));
  Result := inherited;
end;

function TMapperRambo.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FNametableBoard and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[NameTableOffset(Address)];
    Exit(True);
  end;
  Result := inherited;
end;

function TMapperRambo.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FNametableBoard and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[NameTableOffset(Address)] := Value;
    Exit(True);
  end;
  Result := inherited;
end;

end.
