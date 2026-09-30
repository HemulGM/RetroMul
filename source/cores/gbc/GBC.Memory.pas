unit GBC.Memory;

interface

uses
  System.SysUtils, GBC.ROM, GBC.GPU, GBC.MBC, GBC.Timer, GBC.InterruptManager,
  GBC.Joypad;

const
  BootROM: array[0..255] of Integer = (
    $31, $FE, $FF, $AF, $21, $FF, $9F, $32, $CB, $7C, $20, $FB, $21, $26, $FF, $0E,
    $11, $3E, $80, $32, $E2, $0C, $3E, $F3, $E2, $32, $3E, $77, $77, $3E, $FC, $E0,
    $47, $11, $04, $01, $21, $10, $80, $1A, $CD, $95, $00, $CD, $96, $00, $13, $7B,
    $FE, $34, $20, $F3, $11, $D8, $00, $06, $08, $1A, $13, $22, $23, $05, $20, $F9,
    $3E, $19, $EA, $10, $99, $21, $2F, $99, $0E, $0C, $3D, $28, $08, $32, $0D, $20,
    $F9, $2E, $0F, $18, $F3, $67, $3E, $64, $57, $E0, $42, $3E, $91, $E0, $40, $04,
    $1E, $02, $0E, $0C, $F0, $44, $FE, $90, $20, $FA, $0D, $20, $F7, $1D, $20, $F2,
    $0E, $13, $24, $7C, $1E, $83, $FE, $62, $28, $06, $1E, $C1, $FE, $64, $20, $06,
    $7B, $E2, $0C, $3E, $87, $F2, $F0, $42, $90, $E0, $42, $15, $20, $D2, $05, $20,
    $4F, $16, $20, $18, $CB, $4F, $06, $04, $C5, $CB, $11, $17, $C1, $CB, $11, $17,
    $05, $20, $F5, $22, $23, $22, $23, $C9, $CE, $ED, $66, $66, $CC, $0D, $00, $0B,
    $03, $73, $00, $83, $00, $0C, $00, $0D, $00, $08, $11, $1F, $88, $89, $00, $0E,
    $DC, $CC, $6E, $E6, $DD, $DD, $D9, $99, $BB, $BB, $67, $63, $6E, $0E, $EC, $CC,
    $DD, $DC, $99, $9F, $BB, $B9, $33, $3E, $3c, $42, $B9, $A5, $B9, $A5, $42, $3C,
    $21, $04, $01, $11, $A8, $00, $1A, $13, $BE, $20, $FE, $23, $7D, $FE, $34, $20,
    $F5, $06, $19, $78, $86, $23, $05, $20, $FB, $86, $20, $FE, $3E, $01, $E0, $50);

type
  TGBCMemory = class
  private
    FGPU: TGBCGPU;
    FWRAMBank: Byte;
    FPrepareSpeedSwitch: Boolean;
    FDoubleSpeed: Boolean;
    FHDMAActive: Boolean;
    FHDMASource, FHDMADestination, FHDMARemainingBlocks: Integer;
    FDMACyclePenalty: Integer;
    FWRAMBanks: array[1..7, 0..$FFF] of Byte;
    procedure ExecuteGeneralHDMA(Control: Byte);
    procedure ExecuteHDMABlock;
    function ProcessUnusedBits(Address, Value: Integer): Integer;
  public
    // 0000-3FFF   16KB ROM Bank 00     (in cartridge, fixed at bank 00)
    ROMBank00: array[0..16383] of Byte;
    // 4000-7FFF   16KB ROM Bank 01..NN (in cartridge, switchable bank number)
    ROMBank01NN: array[0..16383] of Byte;
    // 8000-9FFF   8KB Video RAM (VRAM) (switchable bank 0-1 in CGB Mode)
    VRAM: array[0..8191] of Byte;
    // A000-BFFF   8KB External RAM     (in cartridge, switchable bank, if any)
    ExtRAM: array[0..8191] of Byte;
    // C000-CFFF   4KB Work RAM Bank 0 (WRAM)
    WRAM0: array[0..4095] of Byte;
    // D000-DFFF   4KB Work RAM Bank 1 (WRAM)  (switchable bank 1-7 in CGB Mode)
    WRAM1: array[0..4095] of Byte;
    WRAM: array[0..8191] of Byte;
    // E000-FDFF   Same as C000-DDFF (ECHO)    (typically not used)
    ECHO: array[0..7679] of Byte;
    // FE00-FE9F   Sprite Attribute Table (OAM)
    OAM: array[0..159] of Byte;
    // FEA0-FEFF   Not Usable
    // ...
    // FF00-FF7F   I/O Ports
    IOPort: array[0..127] of Byte;
    // FF80-FFFE   High RAM (HRAM)
    HRAM: array[0..127] of Byte;

    FMBC: TGBCMBC;
    UseBIOS: Boolean;
    procedure WriteByte(Address: Integer; Value: Byte);
    procedure WriteWord(Address: Integer; Value: Word);

    function ReadByte(Address: Integer): Byte;
    function ReadWord(Address: Integer): Word;
    function GetROMBank: Integer;
    function IsCGBMode: Boolean;
    function PerformSpeedSwitch: Boolean;
    property DoubleSpeed: Boolean read FDoubleSpeed;
    function ConsumeDMACyclePenalty: Integer;
    procedure InitializeMemory;
    constructor Create(AMbc: TGBCMBC; AGPU: TGBCGPU); overload;
  end;

implementation

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
  FHDMADestination := $8000 or ((IOPort[$53] and $1F) shl 8) or
    (IOPort[$54] and $F0);
  FHDMARemainingBlocks := (Control and $7F) + 1;
  // HBlank does not exist with the LCD disabled.  On real CGB hardware a
  // request with bit 7 set in that state is therefore performed immediately
  // as a general transfer.  Leaving it pending makes the transfer overwrite
  // visible tile data after the game enables the LCD.
  FHDMAActive := ((Control and $80) <> 0) and
    ((FGPU.GetLCDControl and $80) <> 0);
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
    FGPU.WriteVRAM((FHDMADestination + I) and $1FFF,
      ReadByte((FHDMASource + I) and $FFFF));
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

constructor TGBCMemory.Create(AMbc: TGBCMBC; AGPU: TGBCGPU);
begin
  FGPU := AGPU;
  FMBC := AMbc;
  FWRAMBank := 1;
  FPrepareSpeedSwitch := False;
  FDoubleSpeed := False;
  FHDMAActive := False;
  FHDMARemainingBlocks := 0;
  FDMACyclePenalty := 0;
  FGPU.SetHBlankCallback(ExecuteHDMABlock);
  UseBIOS := True;
  InitializeMemory;
end;

function TGBCMemory.GetROMBank: Integer;
begin
  Result := FMBC.ROMBankSelected;
end;

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

procedure TGBCMemory.InitializeMemory;
begin
  for var I := 0 to High(ROMBank00) do
    ROMBank00[I] := $00;
  for var I := 0 to High(ROMBank01NN) do
    ROMBank01NN[I] := $00;
  for var I := 0 to High(VRAM) do
    VRAM[I] := $00;
  for var I := 0 to High(ExtRAM) do
    ExtRAM[I] := $00;
  for var I := 0 to High(WRAM0) do
    WRAM0[I] := $00;
  for var I := 0 to High(WRAM1) do
    WRAM1[I] := $00;
  for var I := 0 to High(ECHO) do
    ECHO[I] := $00;
  for var I := 0 to High(OAM) do
    OAM[I] := $00;
  for var I := 0 to High(IOPort) do
    IOPort[I] := $00;
  for var I := 0 to High(HRAM) do
    HRAM[I] := $00;
  for var I := 0 to High(WRAM) do
    WRAM[I] := $00;
end;

function TGBCMemory.ProcessUnusedBits(Address, Value: Integer): Integer;
begin
  var Ret: Integer;
  case Address of
    $FF02:
      begin
        Ret := Value or $7E;
      end;
    $FF07:
      begin
        Ret := Value or $F8;
      end;
    $ff0f:
      begin
        Ret := Value or $E0;
      end;
    $ff41, $FF10:
      begin
        Ret := Value or $80;
      end;
    $FF1A:
      begin
        Ret := Value or $7F;
      end;
    $FF1C:
      begin
        Ret := Value or $9F;
      end;
    $FF20:
      begin
        Ret := Value or $C0;
      end;
    $FF23:
      begin
        Ret := Value or $3F;
      end;
    $FF26:
      begin
        Ret := Value or $70;
      end;
    $ff03, $ff08, $ff09, $ff0a, $ff0b, $ff0c, $ff0d, $ff0e, $ff15, $ff1f, $ff27, $ff28, $ff29:
      begin
        Ret := Value or $FF;
      end;
  else
    Ret := Value;
  end;
  if (Address >= $ff4c) and (Address <= $ff7f) then
    Ret := Value or $FF;
  Result := Ret;
end;

function TGBCMemory.ReadByte(Address: Integer): Byte;
begin
  Result := $00;
  if (Address <= $7fff) then
  begin
    if UseBIOS then
    begin
      if Address < $100 then
      begin
        Result := BootROM[Address];
        Exit;
      end
      else if Address = $100 then
      begin
        UseBIOS := False;
      end;
    end;

    Result := FMBC.MbcRead(Address);
  end
  else if (Address >= $8000) and (Address <= $9fff) then
  begin
    if FGPU.CanAccessVRAM then
      Result := FGPU.ReadVRAM(Address - $8000)
    else
      Result := $FF;
  end
  else if (Address >= $a000) and (Address <= $bfff) then
    Result := FMBC.MbcRead(Address)
  else if (Address >= $c000) and (Address <= $cfff) then
    Result := WRAM[Address - $c000]
  else if (Address >= $d000) and (Address <= $dfff) then
    Result := FWRAMBanks[FWRAMBank][Address - $d000]
  else if (Address >= $e000) and (Address <= $efff) then
    // E000-EFFF mirrors fixed WRAM bank 0.
    Result := WRAM[Address - $e000]
  else if (Address >= $f000) and (Address <= $fdff) then
    // F000-FDFF mirrors the first 3584 bytes of the selected WRAM bank.
    Result := FWRAMBanks[FWRAMBank][Address - $f000]
  else if (Address >= $fe00) and (Address <= $FE9F) then
    Result := OAM[Address - $fe00]
  else if (Address = $ff40) then
    Result := FGPU.GetLCDControl
  else if (Address = $FF41) then
    Result := ProcessUnusedBits(Address, FGPU.GetLCDStatus)
  else if (Address = $FF42) then
    Result := FGPU.ScrollY
  else if (Address = $FF43) then
    Result := FGPU.ScrollX
  else if (Address = $FF44) then
    Result := FGPU.Line
  else if (Address = $FF45) then
    Result := FGPU.LYC
  else if (Address >= $FF47) and (Address <= $FF49) then
    // BGP/OBP0/OBP1 are readable registers.  Games can use their current
    // values as the source for palette fades and other effects.
    Result := IOPort[Address - $FF00]
  else if (Address = $FF4A) then
    Result := FGPU.WindowY
  else if (Address = $FF4B) then
    Result := FGPU.WindowX
  else if Address = $FF4F then
    Result := FGPU.GetVBK
  else if Address = $FF4D then
  begin
    if IsCGBMode then
      Result := $7E or (Ord(FDoubleSpeed) shl 7) or Ord(FPrepareSpeedSwitch)
    else
      Result := $FF;
  end
  else if (Address >= $FF68) and (Address <= $FF6B) then
    Result := FGPU.ReadCGBPalette(Address)
  else if Address = $FF70 then
    Result := $F8 or FWRAMBank
  else if Address = $FF55 then
    Result := IOPort[$55]
  else if (Address = $FF00) then
    Result := TGBCJoypad.Instance.GetPressedKeys
  else if (Address >= $FF01) and (Address <= $FFFF) then
  begin
    if Address = $FF04 then
      Result := TGBCTimer.Instance.GetDivider
    else if Address = $FF05 then
      Result := TGBCTimer.Instance.GetCounter
    else if Address = $FF06 then
      Result := TGBCTimer.Instance.GetModulo
    else if Address = $FF07 then
      Result := ProcessUnusedBits(Address, TGBCTimer.Instance.GetControl)
    else if Address = $FF0F then
      Result := ProcessUnusedBits(Address, TGBCInterruptManager.Instance.GetInterruptsRaised)
    else if Address = $FFFF then
      Result := ProcessUnusedBits(Address, TGBCInterruptManager.Instance.GetInterruptsEnabled)
    else if (Address >= $FF80) and (Address <= $FFFE) then
      Result := ProcessUnusedBits(Address, HRAM[Address - $FF80])
    else if (Address >= $FF10) and (Address <= $FF3F) then
      Result := ProcessUnusedBits(Address, IOPort[Address - $FF00]) // sound hardware
    else
      Result := ProcessUnusedBits(Address, 0);
  end;
end;

function TGBCMemory.ReadWord(Address: Integer): Word;
begin
  var Value: Integer := ReadByte((Address + 1) and $FFFF);
  Value := Value shl 8;
  Value := Value + ReadByte(Address);
  Result := Value;
end;

procedure TGBCMemory.WriteByte(Address: Integer; Value: Byte);
begin
  if (Address >= 0) and (Address <= $7FFF) then
  begin
    FMBC.MbcWrite(Address, Value);
  end
  else if (Address >= $A000) and (Address <= $BFFF) then
  begin
    FMBC.MbcWrite(Address, Value);
  end;

  if (Address >= $8000) and (Address <= $9FFF) then
  begin
    if FGPU.CanAccessVRAM then
      FGPU.WriteVRAM(Address - $8000, Value);
  end;

  if (Address >= $C000) and (Address <= $CFFF) then
    WRAM[Address - $C000] := Value
  else if (Address >= $D000) and (Address <= $DFFF) then
    FWRAMBanks[FWRAMBank][Address - $D000] := Value
  else if (Address >= $E000) and (Address <= $EFFF) then
    WRAM[Address - $E000] := Value
  else if (Address >= $F000) and (Address <= $FDFF) then
    FWRAMBanks[FWRAMBank][Address - $F000] := Value
  else if (Address >= $FE00) and (Address <= $FE9F) then
  begin
    OAM[Address - $FE00] := Value;
    FGPU.BuildSprite(Address - $FE00, Value);
  end
  else if (Address >= $FF80) and (Address <= $FFFE) then
    HRAM[Address - $FF80] := Value
  else if (Address >= $FF00) and (Address <= $FF7F) then
  begin
    case Address of
      $FF00: // joypad
        begin
          TGBCJoypad.Instance.SetSelection(Value);
        end;
      $FF40:
        begin
          FGPU.SetLCDControl(Value);
        end;
      $FF41:
        begin
          FGPU.SetLCDStatus(Value);
        end;
      $FF42:
        begin
          FGPU.ScrollY := Value;
        end;
      $FF43:
        begin
          FGPU.ScrollX := Value;
        end;
      $FF45:
        begin
          FGPU.LYC := Value;
        end;
      $FF4A:
        FGPU.WindowY := Value;
      $FF4B:
        FGPU.WindowX := Value;
      $FF4D:
        FPrepareSpeedSwitch := IsCGBMode and ((Value and 1) <> 0);
      $FF4F:
        FGPU.SetVBK(Value);
      $FF68, $FF69, $FF6A, $FF6B:
        FGPU.WriteCGBPalette(Address, Value);
      $FF70:
        begin
          FWRAMBank := Value and 7;
          if FWRAMBank = 0 then
            FWRAMBank := 1;
        end;
      $FF51, $FF52, $FF53, $FF54:
        IOPort[Address - $FF00] := Value;
      $FF55:
        ExecuteGeneralHDMA(Value);
      $FF46:
        begin // OAM DMA
          for var I := 0 to 159 do
            WriteByte($FE00 + I, ReadByte((Value shl 8) + I));
        end;
      $FF47:
        begin
          IOPort[Address - $FF00] := Value;
          for var I := 0 to 3 do
            FGPU.BackgroundPalette[I] := FGPU.Palette[(Value shr (I * 2)) and 3];
        end;
      $FF48:
        begin
          IOPort[Address - $FF00] := Value;
          for var I := 0 to 3 do
            FGPU.SpritePalette[0][I] := FGPU.Palette[(Value shr (I * 2)) and 3];
        end;
      $FF49:
        begin
          IOPort[Address - $FF00] := Value;
          for var I := 0 to 3 do
            FGPU.SpritePalette[1][I] := FGPU.Palette[(Value shr (I * 2)) and 3];
        end;
      $FF0F:
        begin
          TGBCInterruptManager.Instance.RaiseInterruptByReg(Value);
        end;
      $FF04:
        begin
          TGBCTimer.Instance.ClearDivider;
        end;
      $FF05:
        begin
          TGBCTimer.Instance.SetCounter(Value);
        end;
      $FF06:
        begin
          TGBCTimer.Instance.SetModulo(Value);
        end;
      $FF07:
        begin
          TGBCTimer.Instance.SetControl(Value);
        end;
    else
      IOPort[Address - $FF00] := Value;
    end;
  end
  else if Address = $FFFF then
  begin
    TGBCInterruptManager.Instance.EnableInterruptByReg(Value);
  end;
end;

procedure TGBCMemory.WriteWord(Address: Integer; Value: Word);
begin
  var LowVal: Integer := Value and $FF;
  var UpperVal: Integer := (Value and $FF00) shr 8;
  WriteByte(Address, LowVal);
  WriteByte((Address + 1) and $FFFF, UpperVal);
end;

end.
