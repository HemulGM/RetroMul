unit GB.Memory;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, GB.ROM, GB.GPU, GB.MBC,
  GB.Timer, GB.InterruptManager, GB.Joypad;

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
  TGBMemory = class
  protected
    FGPU: TGBVideo;
    function ProcessUnusedBits(Address, Value: Integer): Integer;
    function ReadWorkRAM(Offset: Integer): Byte; virtual;
    procedure WriteWorkRAM(Offset: Integer; Value: Byte); virtual;
    function ReadModelRegister(Address: Integer; out Value: Byte): Boolean; virtual;
    function WriteModelRegister(Address: Integer; Value: Byte): Boolean; virtual;
    function GetDoubleSpeed: Boolean; virtual;
    function ReadDMASource(Address: Integer): Byte;
  private
    FTimer: TGBTimer;
    FInterruptManager: TGBInterruptManager;
    FJoypad: TGBJoypad;
    FDMASource, FDMAIndex, FDMAClocks: Integer;
    FDMAActive: Boolean;
    FSerialClocks, FSerialBits: Integer;
    function DMABlocksCPU(Address: Integer): Boolean;
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

    FMBC: TGBMBC;
    UseBIOS: Boolean;
    procedure WriteByte(Address: Integer; Value: Byte);
    procedure WriteWord(Address: Integer; Value: Word);

    function ReadByte(Address: Integer): Byte;
    function ReadWord(Address: Integer): Word;
    function GetROMBank: Integer;
    function IsCGBMode: Boolean; virtual;
    function PerformSpeedSwitch: Boolean; virtual;
    function StopHalts: Boolean; virtual;
    function ConsumeDMACyclePenalty: Integer; virtual;
    procedure StepHardware(Clocks: Integer);
    property DoubleSpeed: Boolean read GetDoubleSpeed;
    property Timer: TGBTimer read FTimer;
    property InterruptManager: TGBInterruptManager read FInterruptManager;
    property Joypad: TGBJoypad read FJoypad;
    procedure InitializeMemory; virtual;
    constructor Create(AMbc: TGBMBC; AGPU: TGBVideo; ATimer: TGBTimer = nil; AInterruptManager: TGBInterruptManager = nil; AJoypad: TGBJoypad = nil); overload;
    procedure SerializeState(State: TStateArchive); virtual;
  end;

implementation

function TGBMemory.ReadWorkRAM(Offset: Integer): Byte;
begin
  Result := WRAM[Offset];
end;

procedure TGBMemory.WriteWorkRAM(Offset: Integer; Value: Byte);
begin
  WRAM[Offset] := Value;
end;

function TGBMemory.ReadModelRegister(Address: Integer; out Value: Byte): Boolean;
begin
  Value := 0;
  Result := False;
end;

function TGBMemory.WriteModelRegister(Address: Integer; Value: Byte): Boolean;
begin
  Result := False;
end;

function TGBMemory.IsCGBMode: Boolean;
begin
  Result := False;
end;

function TGBMemory.GetDoubleSpeed: Boolean;
begin
  Result := False;
end;

function TGBMemory.PerformSpeedSwitch: Boolean;
begin
  Result := False;
end;

function TGBMemory.StopHalts: Boolean;
begin
  Result := False;
end;

function TGBMemory.ConsumeDMACyclePenalty: Integer;
begin
  Result := 0;
end;

function TGBMemory.DMABlocksCPU(Address: Integer): Boolean;
begin
  Result := False;
  if not FDMAActive or ((Address >= $FF80) and (Address <= $FFFE)) or
    (Address = $FF46) then
    Exit;
  if not IsCGBMode then
    Exit(True);
  // CGB separates the cartridge and WRAM buses. OAM remains unavailable.
  Result := ((Address >= $FE00) and (Address < $FEA0)) or
    ((FDMASource < $8000) and ((Address < $8000) or
      ((Address >= $A000) and (Address < $C000)))) or
    (((FDMASource >= $A000) and (FDMASource < $C000)) and
      ((Address < $8000) or ((Address >= $A000) and (Address < $C000)))) or
    ((FDMASource >= $C000) and (Address >= $C000) and (Address < $FE00)) or
    (((FDMASource >= $8000) and (FDMASource < $A000)) and
      (Address >= $8000) and (Address < $A000));
end;

function TGBMemory.ReadDMASource(Address: Integer): Byte;
begin
  // DMA bypasses CPU/PPU access restrictions, using the currently selected banks.
  if Address < $8000 then
    Result := FMBC.MbcRead(Address)
  else if Address < $A000 then
    Result := FGPU.ReadVRAM(Address - $8000)
  else if Address < $C000 then
    Result := FMBC.MbcRead(Address)
  else
    Result := ReadWorkRAM((Address - $C000) and $1FFF);
end;

procedure TGBMemory.StepHardware(Clocks: Integer);
begin
  if not FDMAActive and ((IOPort[$02] and $81) <> $81) then
    Exit;
  for var I := 1 to Clocks do
  begin
    if FDMAActive then
    begin
      Inc(FDMAClocks);
      if FDMAClocks = 4 then
      begin
        FDMAClocks := 0;
        var Value := ReadDMASource(FDMASource + FDMAIndex);
        OAM[FDMAIndex] := Value;
        FGPU.BuildSprite(FDMAIndex, Value);
        Inc(FDMAIndex);
        FDMAActive := FDMAIndex < 160;
      end;
    end;
    if ((IOPort[$02] and $81) = $81) then
    begin
      Inc(FSerialClocks);
      var Period := 512;
      if IsCGBMode and ((IOPort[$02] and 2) <> 0) then
        Period := 16;
      if FSerialClocks >= Period then
      begin
        FSerialClocks := 0;
        IOPort[$01] := ((Integer(IOPort[$01]) shl 1) or 1) and $FF;
        Inc(FSerialBits);
        if FSerialBits = 8 then
        begin
          IOPort[$02] := IOPort[$02] and $7F;
          FInterruptManager.RaiseInterruptByIndex(1);
        end;
      end;
    end;
  end;
end;

{ TGBMemory }

constructor TGBMemory.Create(AMbc: TGBMBC; AGPU: TGBVideo; ATimer: TGBTimer; AInterruptManager: TGBInterruptManager; AJoypad: TGBJoypad);
begin
  FTimer := ATimer;
  if FTimer = nil then
    FTimer := TGBTimer.Instance;
  FInterruptManager := AInterruptManager;
  if FInterruptManager = nil then
    FInterruptManager := TGBInterruptManager.Instance;
  FJoypad := AJoypad;
  if FJoypad = nil then
    FJoypad := TGBJoypad.Instance;
  FGPU := AGPU;
  FMBC := AMbc;
  UseBIOS := True;
  InitializeMemory;
end;

function TGBMemory.GetROMBank: Integer;
begin
  Result := FMBC.ROMBankSelected;
end;

procedure TGBMemory.InitializeMemory;
begin
  FDMAActive := False;
  FDMASource := 0;
  FDMAIndex := 0;
  FDMAClocks := 0;
  FSerialClocks := 0;
  FSerialBits := 0;
  for var i := 0 to High(ROMBank00) do
    ROMBank00[i] := $00;
  for var i := 0 to High(ROMBank01NN) do
    ROMBank01NN[i] := $00;
  for var i := 0 to High(VRAM) do
    VRAM[i] := $00;
  for var i := 0 to High(ExtRAM) do
    ExtRAM[i] := $00;
  for var i := 0 to High(WRAM0) do
    WRAM0[i] := $00;
  for var i := 0 to High(WRAM1) do
    WRAM1[i] := $00;
  for var i := 0 to High(ECHO) do
    ECHO[i] := $00;
  for var i := 0 to High(OAM) do
    OAM[i] := $00;
  for var i := 0 to High(IOPort) do
    IOPort[i] := $00;
  for var i := 0 to High(HRAM) do
    HRAM[i] := $00;
  for var i := 0 to High(WRAM) do
    WRAM[i] := $00;
end;

function TGBMemory.ProcessUnusedBits(Address, Value: Integer): Integer;
begin
  var Ret: Integer;
  case Address of
    $FF02:
      begin
        if IsCGBMode then
          Ret := Value or $7C
        else
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

function TGBMemory.ReadByte(Address: Integer): Byte;
begin
  if DMABlocksCPU(Address) then
    Exit($FF);
  if (Address >= $FF4D) and (Address <= $FF7F) and
    ReadModelRegister(Address, Result) then
    Exit;
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
  else if (Address >= $c000) and (Address <= $dfff) then
    Result := ReadWorkRAM(Address - $c000)
  else if (Address >= $e000) and (Address <= $fdff) then
    Result := ReadWorkRAM(Address - $e000)
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
  else if (Address = $FF00) then
    Result := FJoypad.GetPressedKeys
  else if (Address >= $FF01) and (Address <= $FFFF) then
  begin
    if (Address = $FF01) or (Address = $FF02) or (Address = $FF46) then
      Result := ProcessUnusedBits(Address, IOPort[Address - $FF00])
    else if Address = $FF04 then
      Result := FTimer.GetDivider
    else if Address = $FF05 then
      Result := FTimer.GetCounter
    else if Address = $FF06 then
      Result := FTimer.GetModulo
    else if Address = $FF07 then
      Result := ProcessUnusedBits(Address, FTimer.GetControl)
    else if Address = $FF0F then
      Result := ProcessUnusedBits(Address, FInterruptManager.GetInterruptsRaised)
    else if Address = $FFFF then
      Result := ProcessUnusedBits(Address, FInterruptManager.GetInterruptsEnabled)
    else if (Address >= $FF80) and (Address <= $FFFE) then
      Result := ProcessUnusedBits(Address, HRAM[Address - $FF80])
    else if (Address >= $FF10) and (Address <= $FF3F) then
      Result := ProcessUnusedBits(Address, IOPort[Address - $FF00]) // sound hardware
    else
      Result := ProcessUnusedBits(Address, 0);
  end;
end;

function TGBMemory.ReadWord(Address: Integer): Word;
begin
  var Value: Integer := ReadByte((Address + 1) and $FFFF);
  Value := Value shl 8;
  Value := Value + ReadByte(Address);
  Result := Value;
end;

procedure TGBMemory.WriteByte(Address: Integer; Value: Byte);
begin
  if DMABlocksCPU(Address) then
    Exit;
  if (Address >= $FF4D) and (Address <= $FF7F) and
    WriteModelRegister(Address, Value) then
    Exit;
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

  if (Address >= $C000) and (Address <= $DFFF) then
    WriteWorkRAM(Address - $C000, Value)
  else if (Address >= $E000) and (Address <= $FDFF) then
    WriteWorkRAM(Address - $E000, Value)
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
      $FF02:
        begin
          IOPort[$02] := Value and $83;
          FSerialClocks := 0;
          FSerialBits := 0;
        end;
      $FF26: // Only the APU can set channel status bits.
        if (Value and $80) = 0 then
          IOPort[$26] := 0
        else
          IOPort[$26] := $80 or (IOPort[$26] and $0F);
      $FF1A:
        begin
          IOPort[$1A] := Value;
          if (Value and $80) = 0 then
            IOPort[$26] := IOPort[$26] and $FB;
        end;
      $FF00: // joypad
        begin
          FJoypad.SetSelection(Value);
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
      $FF46:
        begin // OAM DMA
          IOPort[$46] := Value;
          FDMASource := Value shl 8;
          // E000-FFFF mirrors C000-DFFF on the DMA source bus.
          if FDMASource >= $E000 then
            Dec(FDMASource, $2000);
          FDMAIndex := 0;
          FDMAClocks := 0;
          FDMAActive := True;
        end;
      $FF47:
        begin
          IOPort[Address - $FF00] := Value;
          for var i := 0 to 3 do
            FGPU.BackgroundPalette[i] := FGPU.Palette[(Value shr (i * 2)) and 3];
        end;
      $FF48:
        begin
          IOPort[Address - $FF00] := Value;
          for var i := 0 to 3 do
            FGPU.SpritePalette[0][i] := FGPU.Palette[(Value shr (i * 2)) and 3];
        end;
      $FF49:
        begin
          IOPort[Address - $FF00] := Value;
          for var i := 0 to 3 do
            FGPU.SpritePalette[1][i] := FGPU.Palette[(Value shr (i * 2)) and 3];
        end;
      $FF0F:
        begin
          FInterruptManager.RaiseInterruptByReg(Value);
        end;
      $FF04:
        begin
          FTimer.ClearDivider;
        end;
      $FF05:
        begin
          FTimer.SetCounter(Value);
        end;
      $FF06:
        begin
          FTimer.SetModulo(Value);
        end;
      $FF07:
        begin
          FTimer.SetControl(Value);
        end;
    else
      IOPort[Address - $FF00] := Value;
    end;
  end
  else if Address = $FFFF then
  begin
    FInterruptManager.EnableInterruptByReg(Value);
  end;
end;

procedure TGBMemory.WriteWord(Address: Integer; Value: Word);
begin
  var LowVal: Integer := Value and $FF;
  var UpperVal: Integer := (Value and $FF00) shr 8;
  WriteByte(Address, LowVal);
  WriteByte((Address + 1) and $FFFF, UpperVal);
end;

procedure TGBMemory.SerializeState(State: TStateArchive);
begin
  State.Field(ROMBank00, SizeOf(ROMBank00));
  State.Field(ROMBank01NN, SizeOf(ROMBank01NN));
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(ExtRAM, SizeOf(ExtRAM));
  State.Field(WRAM0, SizeOf(WRAM0));
  State.Field(WRAM1, SizeOf(WRAM1));
  State.Field(WRAM, SizeOf(WRAM));
  State.Field(ECHO, SizeOf(ECHO));
  State.Field(OAM, SizeOf(OAM));
  State.Field(IOPort, SizeOf(IOPort));
  State.Field(HRAM, SizeOf(HRAM));
  State.Field(UseBIOS, SizeOf(UseBIOS));
  State.Field(FDMASource, SizeOf(FDMASource));
  State.Field(FDMAIndex, SizeOf(FDMAIndex));
  State.Field(FDMAClocks, SizeOf(FDMAClocks));
  State.Field(FDMAActive, SizeOf(FDMAActive));
  State.Field(FSerialClocks, SizeOf(FSerialClocks));
  State.Field(FSerialBits, SizeOf(FSerialBits));
end;

end.

