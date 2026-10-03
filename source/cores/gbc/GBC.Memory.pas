unit GBC.Memory;

interface

uses
  Core.Snapshots, GB.Memory, GBC.GPU, GBC.MBC;

type
  TGBCMemory = class(TGBMemory)
  private
    FColorGPU: TGBCGPU;
    FWRAMBank: Byte;
    FPrepareSpeedSwitch, FDoubleSpeed: Boolean;
    FHDMAActive: Boolean;
    FHDMASource, FHDMADestination, FHDMARemainingBlocks: Integer;
    FDMACyclePenalty: Integer;
    FWRAMBanks: array[1..7, 0..$FFF] of Byte;
    procedure ExecuteGeneralHDMA(Control: Byte);
    procedure ExecuteHDMABlock;
  protected
    function ReadWorkRAM(Offset: Integer): Byte; override;
    procedure WriteWorkRAM(Offset: Integer; Value: Byte); override;
    function ReadModelRegister(Address: Integer; out Value: Byte): Boolean; override;
    function WriteModelRegister(Address: Integer; Value: Byte): Boolean; override;
    function GetDoubleSpeed: Boolean; override;
  public
    constructor Create(AMbc: TGBCMBC; AGPU: TGBCGPU); reintroduce; overload;
    function IsCGBMode: Boolean; override;
    function PerformSpeedSwitch: Boolean; override;
    function StopHalts: Boolean; override;
    function ConsumeDMACyclePenalty: Integer; override;
    procedure InitializeMemory; override;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

uses
  GBC.Timer, GBC.InterruptManager, GBC.Joypad;

constructor TGBCMemory.Create(AMbc: TGBCMBC; AGPU: TGBCGPU);
begin
  FColorGPU := AGPU;
  FWRAMBank := 1;
  inherited Create(AMbc, AGPU, TGBCTimer.Instance, TGBCInterruptManager.Instance, TGBCJoypad.Instance);
  FColorGPU.SetHBlankCallback(ExecuteHDMABlock);
end;

procedure TGBCMemory.InitializeMemory;
begin
  inherited;
  IOPort[$55] := $FF;
end;

function TGBCMemory.GetDoubleSpeed: Boolean;
begin
  Result := FDoubleSpeed;
end;

function TGBCMemory.StopHalts: Boolean;
begin
  Result := not PerformSpeedSwitch;
end;

function TGBCMemory.ReadWorkRAM(Offset: Integer): Byte;
begin
  if Offset < $1000 then
    Result := WRAM[Offset]
  else
    Result := FWRAMBanks[FWRAMBank][Offset - $1000];
end;

procedure TGBCMemory.WriteWorkRAM(Offset: Integer; Value: Byte);
begin
  if Offset < $1000 then
    WRAM[Offset] := Value
  else
    FWRAMBanks[FWRAMBank][Offset - $1000] := Value;
end;

function TGBCMemory.ReadModelRegister(Address: Integer; out Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $FF4F:
      Value := FColorGPU.GetVBK;
    $FF4D:
      if IsCGBMode then
        Value := $7E or (Ord(FDoubleSpeed) shl 7) or Ord(FPrepareSpeedSwitch)
      else
        Value := $FF;
    $FF68..$FF6B:
      Value := FColorGPU.ReadCGBPalette(Address);
    $FF70:
      Value := $F8 or FWRAMBank;
    $FF55:
      Value := IOPort[$55];
  else
    Value := 0;
    Result := False;
  end;
end;

function TGBCMemory.WriteModelRegister(Address: Integer; Value: Byte): Boolean;
begin
  Result := True;
  case Address of
    $FF4D:
      FPrepareSpeedSwitch := IsCGBMode and ((Value and 1) <> 0);
    $FF4F:
      FColorGPU.SetVBK(Value);
    $FF68..$FF6B:
      FColorGPU.WriteCGBPalette(Address, Value);
    $FF70:
      begin
        FWRAMBank := Value and 7;
        if FWRAMBank = 0 then
          FWRAMBank := 1;
      end;
    $FF51..$FF54:
      IOPort[Address - $FF00] := Value;
    $FF55:
      ExecuteGeneralHDMA(Value);
  else
    Result := False;
  end;
end;

procedure TGBCMemory.ExecuteGeneralHDMA(Control: Byte);
begin
  // A write with bit 7 clear cancels an active HBlank transfer. The readback
  // reports the number of untransferred blocks with bit 7 set.
  if FHDMAActive and ((Control and $80) = 0) then
  begin
    FHDMAActive := False;
    IOPort[$55] := $80 or (FHDMARemainingBlocks - 1);
    Exit;
  end;

  FHDMASource := (IOPort[$51] shl 8) or (IOPort[$52] and $F0);
  FHDMADestination := $8000 or ((IOPort[$53] and $1F) shl 8) or (IOPort[$54] and $F0);
  FHDMARemainingBlocks := (Control and $7F) + 1;
  // HBlank does not exist with the LCD disabled.  On real CGB hardware a
  // request with bit 7 set in that state is therefore performed immediately
  // as a general transfer.  Leaving it pending makes the transfer overwrite
  // visible tile data after the game enables the LCD.
  FHDMAActive := ((Control and $80) <> 0) and ((FColorGPU.GetLCDControl and $80) <> 0);
  if FHDMAActive then
    IOPort[$55] := FHDMARemainingBlocks - 1
  else
    while FHDMARemainingBlocks > 0 do
      ExecuteHDMABlock;
end;

procedure TGBCMemory.ExecuteHDMABlock;
begin
  if FHDMARemainingBlocks <= 0 then
    Exit;
  for var I := 0 to $0F do
    FColorGPU.WriteVRAM((FHDMADestination + I) and $1FFF, ReadByte((FHDMASource + I) and $FFFF));
  // A 16-byte CGB DMA block occupies the CPU bus for eight machine cycles
  // (32 normal-speed clock cycles).  Peripheral time still advances while
  // the CPU is paused, so the CPU consumes this after the current operation.
  Inc(FDMACyclePenalty, 32);
  Inc(FHDMASource, $10);
  FHDMADestination := $8000 or ((FHDMADestination + $10) and $1FFF);
  Dec(FHDMARemainingBlocks);
  IOPort[$51] := (FHDMASource shr 8) and $FF;
  IOPort[$52] := FHDMASource and $F0;
  IOPort[$53] := (FHDMADestination shr 8) and $1F;
  IOPort[$54] := FHDMADestination and $F0;
  if FHDMARemainingBlocks = 0 then
  begin
    FHDMAActive := False;
    IOPort[$55] := $FF;
  end
  else
    IOPort[$55] := FHDMARemainingBlocks - 1;
end;

{ TGBMemory }

function TGBCMemory.IsCGBMode: Boolean;
begin
  Result := Assigned(FMBC) and FMBC.IsCGBCartridge;
end;

function TGBCMemory.PerformSpeedSwitch: Boolean;
begin
  Result := IsCGBMode and FPrepareSpeedSwitch;
  if Result then
  begin
    FDoubleSpeed := not FDoubleSpeed;
    FPrepareSpeedSwitch := False;
  end;
end;

function TGBCMemory.ConsumeDMACyclePenalty: Integer;
begin
  Result := FDMACyclePenalty;
  FDMACyclePenalty := 0;
end;

procedure TGBCMemory.SerializeState(State: TStateArchive);
begin
  State.Field(FWRAMBank, SizeOf(FWRAMBank));
  State.Field(FPrepareSpeedSwitch, SizeOf(FPrepareSpeedSwitch));
  State.Field(FDoubleSpeed, SizeOf(FDoubleSpeed));
  State.Field(FHDMAActive, SizeOf(FHDMAActive));
  State.Field(FHDMASource, SizeOf(FHDMASource));
  State.Field(FHDMADestination, SizeOf(FHDMADestination));
  State.Field(FHDMARemainingBlocks, SizeOf(FHDMARemainingBlocks));
  State.Field(FDMACyclePenalty, SizeOf(FDMACyclePenalty));
  State.Field(FWRAMBanks, SizeOf(FWRAMBanks));
  // CGB extension precedes common state in existing snapshots.
  inherited SerializeState(State);
end;

end.

