unit NES.Mapper.Mmc5;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, NES.APU;

type
  TMapperMmc5 = class(TMapperBanked)
  private
    FPrgRegisters: array[0..4] of Byte;
    FRamBankOffsets: array[0..15] of Integer;
    FPrgOffsets: array[0..4] of Integer;
    FPrgIsRam: array[0..4] of Boolean;
    FChrRegisters: array[0..11] of Integer;
    FCiram: array[0..$7FF] of Byte;
    FExRam: array[0..$3FF] of Byte;
    FPrgMode, FChrMode, FProtect1, FProtect2, FExMode, FNameMap, FFillTile, FFillColor, FChrUpper: Byte;
    FMultiplyA, FMultiplyB, FIrqTarget, FSplitControl, FSplitScroll, FSplitBank: Byte;
    FIrqEnabled, FPending, FInFrame, FSpriteFetch, FLargeSprites, FLastChrB: Boolean;
    FPixelX, FPixelY, FExTile: Integer;
    FPcmControl, FPcmOutput: Byte;
    FLastPpuBusRead: Word;
    FRepeatedReads, FScanlineCounter, FPpuIdleCycles: Byte;
    FPpuMaskRendering: Boolean;
    FPcmTrip, FWriteOnlyPcm: Boolean;
    FPulses: array[0..1] of TPulseChannel;
    FAudioDivider, FHardwareTimerCount: Word;
    FHardwareTimerRunning, FHardwareTimerIrq: Boolean;
    FControlPinMode, FControlPinData: Byte;
    FPulseOutput: Double;
    FSaveRamSize: Integer;
    FExRamBattery: Boolean;
    procedure ResetScanlineCounter;
    procedure DetectScanline;
    procedure UpdatePrgOffsets;
    procedure UpdatePulseOutput;
    procedure WritePulse(Address: Word; Value: Byte);
    procedure WritePcm(Value: Byte); inline;
    function PcmIrq: Boolean; inline;
    function ReadPrg(Address: UInt16): UInt8; inline;
    function SpriteFetch: Boolean;
    function CpuBank(Address: UInt16; out IsRam: Boolean): Integer;
    function PatternOffset(Address: UInt16): Integer;
    function SplitActive: Boolean;
    function NameSource(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Battery: Boolean = False);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure ClockCpu; override;
    procedure ConfigurePrgRam(VolatileSize, SaveSize: UInt64);
    procedure ConfigureSaveRam(Size: Integer);
    procedure ConfigureWriteOnlyPcm;
    function ExRamSaveSize: Integer;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function ExpansionAudio: Double; override;
    procedure ObservePpuBusRead(Address: UInt16); override;
    procedure CpuIoRead(Address: UInt16; Value: UInt8); override;
    procedure CpuIoWrite(Address: UInt16; Value: UInt8); override;
    procedure RestoreLegacyScanline(Line: Integer; Mask: Byte);
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); override;
    procedure SetPpuControl(Value: UInt8); override;
    function ControlPins(Address: UInt16; WriteAccess, M2High: Boolean): Byte;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

type
  PPulseChannel = ^TPulseChannel;

const
  // The MMC5 has its own M2 divider, independent of the APU frame sequencer.
  MMC5_AUDIO_DIVIDER = 7424;
  MMC5_CL3 = $40;
  MMC5_SL3 = $80;
  MMC5_CONTROL_PIN_MASK = MMC5_CL3 or MMC5_SL3;

var
  PulseDac: array[0..30] of Double;

procedure TMapperMmc5.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRegisters, SizeOf(FPrgRegisters));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FCiram, SizeOf(FCiram));
  State.Field(FExRam, SizeOf(FExRam));
  State.Field(FPrgMode, SizeOf(FPrgMode));
  State.Field(FChrMode, SizeOf(FChrMode));
  State.Field(FProtect1, SizeOf(FProtect1));
  State.Field(FProtect2, SizeOf(FProtect2));
  State.Field(FExMode, SizeOf(FExMode));
  State.Field(FNameMap, SizeOf(FNameMap));
  State.Field(FFillTile, SizeOf(FFillTile));
  State.Field(FFillColor, SizeOf(FFillColor));
  State.Field(FChrUpper, SizeOf(FChrUpper));
  State.Field(FMultiplyA, SizeOf(FMultiplyA));
  State.Field(FMultiplyB, SizeOf(FMultiplyB));
  State.Field(FIrqTarget, SizeOf(FIrqTarget));
  State.Field(FSplitControl, SizeOf(FSplitControl));
  State.Field(FSplitScroll, SizeOf(FSplitScroll));
  State.Field(FSplitBank, SizeOf(FSplitBank));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FInFrame, SizeOf(FInFrame));
  State.Field(FSpriteFetch, SizeOf(FSpriteFetch));
  State.Field(FLargeSprites, SizeOf(FLargeSprites));
  State.Field(FLastChrB, SizeOf(FLastChrB));
  State.Field(FPixelX, SizeOf(FPixelX));
  State.Field(FPixelY, SizeOf(FPixelY));
  State.Field(FExTile, SizeOf(FExTile));
  if State.Version >= 21 then
  begin
    State.Field(FPcmControl, SizeOf(FPcmControl));
    State.Field(FPcmOutput, SizeOf(FPcmOutput));
  end
  else if State.Loading then
  begin
    FPcmControl := 0;
    FPcmOutput := 0;
  end;
  if State.Version >= MMC5_AUDIO_STATE_VERSION then
  begin
    State.Field(FPulses, SizeOf(FPulses));
    State.Field(FAudioDivider, SizeOf(FAudioDivider));
    State.Field(FPcmTrip, SizeOf(FPcmTrip));
  end
  else if State.Loading then
  begin
    FillChar(FPulses, SizeOf(FPulses), 0);
    FAudioDivider := 0;
    FPcmTrip := False;
  end;
  if State.Version >= MMC5_SCANLINE_STATE_VERSION then
  begin
    State.Field(FLastPpuBusRead, SizeOf(FLastPpuBusRead));
    State.Field(FRepeatedReads, SizeOf(FRepeatedReads));
    State.Field(FScanlineCounter, SizeOf(FScanlineCounter));
    State.Field(FPpuIdleCycles, SizeOf(FPpuIdleCycles));
    State.Field(FPpuMaskRendering, SizeOf(FPpuMaskRendering));
  end
  else if State.Loading then
    RestoreLegacyScanline(0, 0);

  if State.Version >= MMC5_TIMER_STATE_VERSION then
  begin
    State.Field(FHardwareTimerCount, SizeOf(FHardwareTimerCount));
    State.Field(FHardwareTimerRunning, SizeOf(FHardwareTimerRunning));
    State.Field(FHardwareTimerIrq, SizeOf(FHardwareTimerIrq));
    if State.Loading and (FHardwareTimerCount = 0) then
      FHardwareTimerRunning := False;
  end
  else if State.Loading then
  begin
    FHardwareTimerCount := 0;
    FHardwareTimerRunning := False;
    FHardwareTimerIrq := False;
  end;

  if State.Version >= MMC5_CONTROL_PINS_STATE_VERSION then
  begin
    State.Field(FControlPinMode, SizeOf(FControlPinMode));
    State.Field(FControlPinData, SizeOf(FControlPinData));
  end
  else if State.Loading then
  begin
    FControlPinMode := MMC5_CONTROL_PIN_MASK;
    FControlPinData := 0;
  end;

  if State.Loading then
  begin
    UpdatePulseOutput;
    UpdatePrgOffsets;
  end;
end;

constructor TMapperMmc5.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Battery: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FExRamBattery := Battery;
  // Old iNES headers often lack reliable RAM sizes. Keep their compatible layout.
  ConfigurePrgRam(0, $10000);
  PowerOn;
end;

procedure TMapperMmc5.PowerOn;
begin
  if not FExRamBattery then
    FillChar(FExRam, SizeOf(FExRam), 0);
  FillChar(FPulses, SizeOf(FPulses), 0);
  FAudioDivider := 0;
  FPulseOutput := 0;
  FPcmOutput := 0;
  FIrqTarget := 0;
  FPpuIdleCycles := 3;
  FPpuMaskRendering := False;
  ResetScanlineCounter;
  Reset;
end;

procedure TMapperMmc5.Reset;
begin
  inherited;
  FillChar(FPrgRegisters, SizeOf(FPrgRegisters), 0);
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  FPrgRegisters[4] := $FF;
  FPrgMode := 3;
  FChrMode := 0;
  FProtect1 := 0;
  FProtect2 := 0;
  FExMode := 0;
  FNameMap := 0;
  FFillTile := 0;
  FFillColor := 0;
  FChrUpper := 0;
  FMultiplyA := $FF;
  FMultiplyB := $FF;
  FSplitControl := 0;
  FSplitScroll := 0;
  FSplitBank := 0;
  // Reset detection gates the IRQ pin. It leaves the compare and pending
  // latches intact until an acknowledgment or a new detected frame.
  FIrqEnabled := False;
  FSpriteFetch := False;
  FLargeSprites := False;
  FLastChrB := False;
  FPixelX := 0;
  FPixelY := 0;
  FExTile := 0;
  FPcmControl := 0;
  FPcmTrip := False;
  FHardwareTimerCount := 0;
  FHardwareTimerRunning := False;
  FHardwareTimerIrq := False;
  FControlPinMode := MMC5_CONTROL_PIN_MASK;
  FControlPinData := 0;
  UpdatePrgOffsets;
end;

function TMapperMmc5.CpuBank(Address: UInt16; out IsRam: Boolean): Integer;
begin
  if Address < $8000 then
  begin
    IsRam := True;
    Exit(FPrgRegisters[0] and $0F);
  end;

  var Slot := (Address - $8000) shr 13;
  var RegisterIndex := Slot + 1;
  var Span := 1;
  case FPrgMode of
    0:
      begin
        RegisterIndex := 4;
        Span := 4;
      end;
    1:
      begin
        RegisterIndex := 2 + (Slot shr 1) * 2;
        Span := 2;
      end;
    2:
      if Slot < 2 then
      begin
        RegisterIndex := 2;
        Span := 2;
      end;
  end;
  var Value := FPrgRegisters[RegisterIndex];
  IsRam := (RegisterIndex <> 4) and ((Value and $80) = 0);
  Result := ((Value and $7F) and not (Span - 1)) + (Slot and (Span - 1));
end;

procedure TMapperMmc5.UpdatePrgOffsets;
begin
  for var Slot := 0 to High(FPrgOffsets) do
  begin
    var Bank := CpuBank($6000 + Slot * $2000, FPrgIsRam[Slot]);
    if FPrgIsRam[Slot] then
      FPrgOffsets[Slot] := FRamBankOffsets[Bank and $0F]
    else
      FPrgOffsets[Slot] := (Bank shl 13) mod Length(FPrgRom);
  end;
end;

function TMapperMmc5.ReadPrg(Address: UInt16): UInt8;
begin
  var Slot := (Address shr 13) - 3;
  var Base := FPrgOffsets[Slot];
  if FPrgIsRam[Slot] then
  begin
    if Base < 0 then
      Exit(FCpuOpenBus);
    Result := FPrgRam[Base + (Address and $1FFF)];
  end
  else
    Result := FPrgRom[Base + (Address and $1FFF)];
end;

function TMapperMmc5.ControlPins(Address: UInt16; WriteAccess, M2High: Boolean): Byte;
begin
  // Use the measured pull-up level when no external circuit drives either input.
  var StrobePins: Byte := (FControlPinMode and 3) shl 6;
  Result := ((FControlPinMode or FControlPinData) and MMC5_CONTROL_PIN_MASK) or StrobePins;
  if M2High and ((Address and $FC00) = $5800) then
    if WriteAccess then
      Result := Result and not (StrobePins and MMC5_SL3)
    else
      Result := Result and not (StrobePins and MMC5_CL3);
end;

function TMapperMmc5.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $6000 then
  begin
    Value := ReadPrg(Address);
    Exit;
  end;

  if (Address >= $5C00) and (Address <= $5FFF) then
  begin
    if FExMode < 2 then
      Exit(False);
    Value := FExRam[Address and $3FF];
    Exit;
  end;

  case Address of
    $5010:
      Value := (Ord(PcmIrq) shl 7) or 1; // MMC5A revision bit
      $5015:
      Value := Ord(FPulses[0].LengthCounter <> 0) or (Ord(FPulses[1].LengthCounter <> 0) shl 1);
    $5204:
      Value := (Ord(FPending) shl 7) or (Ord(FInFrame) shl 6);
    $5205:
      Value := (Integer(FMultiplyA) * FMultiplyB) and $FF;
    $5206:
      Value := (Integer(FMultiplyA) * FMultiplyB) shr 8;
    $5208:
      Value := ControlPins(Address, False, True);
    $5209:
      Value := Ord(FHardwareTimerIrq) shl 7;
  else
    Result := False;
  end;
end;

function TMapperMmc5.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $6000 then
  begin
    Value := ReadPrg(Address);
    if (Address and $FFFE) = $FFFA then
      ResetScanlineCounter
    else if ((FPcmControl and 1) <> 0) and not FWriteOnlyPcm and
      ((Address and $C000) = $8000) then
      WritePcm(Value);
    Exit(True);
  end;

  Result := CpuPeek(Address, Value);
  case Address of
    $5010:
      FPcmTrip := False;
    $5204:
      FPending := False;
    $5209:
      FHardwareTimerIrq := False;
  end;
end;

function TMapperMmc5.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $6000 then
  begin
    var Slot := (Address - $6000) shr 13;
    if FPrgIsRam[Slot] and (FPrgOffsets[Slot] >= 0) and (FProtect1 = 2) and (FProtect2 = 1) then
      FPrgRam[FPrgOffsets[Slot] + (Address and $1FFF)] := Value;
    Exit;
  end;

  if (Address >= $5C00) and (Address <= $5FFF) then
  begin
    if FExMode = 2 then
      FExRam[Address and $3FF] := Value
    else if FExMode < 2 then
      if FInFrame then
        FExRam[Address and $3FF] := Value
      else
        FExRam[Address and $3FF] := 0;
    Exit;
  end;

  case Address of
    $5000..$5007:
      WritePulse(Address, Value);
    $5010:
      if FWriteOnlyPcm then
        FPcmControl := Value and 1
      else
        FPcmControl := Value and $81;
    $5011:
      if (FPcmControl and 1) = 0 then
        WritePcm(Value);
    $5015:
      begin
        for var Index := 0 to High(FPulses) do
        begin
          FPulses[Index].Enabled := (Value and (1 shl Index)) <> 0;
          if not FPulses[Index].Enabled then
            FPulses[Index].LengthCounter := 0;
        end;
        UpdatePulseOutput;
      end;
    $5008..$500F, $5012..$5014:
      ;
    $5100:
      begin
        FPrgMode := Value and 3;
        UpdatePrgOffsets;
      end;
    $5101:
      FChrMode := Value and 3;
    $5102:
      FProtect1 := Value and 3;
    $5103:
      FProtect2 := Value and 3;
    $5104:
      FExMode := Value and 3;
    $5105:
      FNameMap := Value;
    $5106:
      FFillTile := Value;
    $5107:
      FFillColor := Value and 3;
    $5113:
      begin
        FPrgRegisters[0] := Value;
        FPrgOffsets[0] := FRamBankOffsets[Value and $0F];
      end;
    $5114..$5117:
      begin
        FPrgRegisters[Address - $5113] := Value;
        UpdatePrgOffsets;
      end;
    $5120..$512B:
      begin
        FChrRegisters[Address - $5120] := Value or (Integer(FChrUpper) shl 8);
        FLastChrB := Address >= $5128;
      end;
    $5130:
      FChrUpper := Value and 3;
    $5200:
      FSplitControl := Value;
    $5201:
      FSplitScroll := Value;
    $5202:
      FSplitBank := Value;
    $5203:
      FIrqTarget := Value;
    $5204:
      FIrqEnabled := (Value and $80) <> 0;
    $5205:
      FMultiplyA := Value;
    $5206:
      FMultiplyB := Value;
    $5207:
      FControlPinMode := Value and (MMC5_CONTROL_PIN_MASK or 3);
    $5208:
      FControlPinData := Value and MMC5_CONTROL_PIN_MASK;
    $5209:
      begin
        // Each byte goes straight into the counter. Only a low-byte write
        // can start a stopped timer. Neither write acknowledges the IRQ.
        FHardwareTimerCount := (FHardwareTimerCount and $FF00) or Value;
        FHardwareTimerRunning := FHardwareTimerCount <> 0;
      end;
    $520A:
      begin
        FHardwareTimerCount := (FHardwareTimerCount and $00FF) or (Word(Value) shl 8);
        FHardwareTimerRunning := FHardwareTimerRunning and (FHardwareTimerCount <> 0);
      end;
  else
    Result := False;
  end;
end;

function TMapperMmc5.SplitActive: Boolean;
begin
  Result := False;
  if SpriteFetch or not FInFrame or (FExMode > 1) or ((FSplitControl and $80) = 0) then
    Exit;

  var Right := (FPixelX div 8) >= (FSplitControl and $1F);
  Result := Right = ((FSplitControl and $40) <> 0);
end;

function TMapperMmc5.PatternOffset(Address: UInt16): Integer;
begin
  if SplitActive then
    Exit(((Integer(FSplitBank) shl 12) + ((Address and $0FF8) or ((FPixelY + FSplitScroll) mod 240 and 7))) mod Length(FChrMemory));

  if (FExMode = 1) and FInFrame and not SpriteFetch then
    Exit(((((FExRam[FExTile] and $3F) or (Integer(FChrUpper) shl 6)) shl 12) + (Address and $0FFF)) mod Length(FChrMemory));

  var UseB := FLargeSprites and ((FInFrame and not SpriteFetch) or (not FInFrame and FLastChrB));
  var Slot := Address shr 10;
  var Span := 1 shl (3 - FChrMode);
  var Index := (Slot div Span) * Span + Span - 1;
  if UseB then
    Index := 8 + (Index and 3);
  Result := (FChrRegisters[Index] * Span * $400 + (Address and (Span * $400 - 1))) mod Length(FChrMemory);
end;

function TMapperMmc5.NameSource(Address: UInt16): Integer;
begin
  Result := (FNameMap shr (((Address and $0FFF) shr 10) * 2)) and 3;
end;

function TMapperMmc5.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;

  if Address < $2000 then
  begin
    Value := FChrMemory[PatternOffset(Address)];
    Exit;
  end;

  var Offset := Address and $3FF;
  if SplitActive then
  begin
    var Row := (FPixelY + FSplitScroll) mod 240;
    var Column := (FPixelX div 8) and $1F;
    if Offset < $3C0 then
      Value := FExRam[(Row div 8) * 32 + Column]
    else
      Value := ((FExRam[$3C0 + (Row div 32) * 8 + Column div 4] shr (((Row div 8) and 2) * 2 + (Column and 2))) and 3) * $55;
    Exit;
  end;

  if (FExMode = 1) and FInFrame and not SpriteFetch then
    if Offset < $3C0 then
      FExTile := Offset
    else
    begin
      Value := (FExRam[FExTile] shr 6) * $55;
      Exit;
    end;

  case NameSource(Address) of
    0, 1:
      Value := FCiram[NameSource(Address) * $400 + Offset];
    2:
      if FExMode <= 1 then
        Value := FExRam[Offset]
      else
        Value := 0;
    3:
      if Offset < $3C0 then
        Value := FFillTile
      else
        Value := FFillColor * $55;
  end;
end;

function TMapperMmc5.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;

  if Address < $2000 then
  begin
    if FHasChrRam then
      FChrMemory[PatternOffset(Address)] := Value;
    Exit;
  end;

  var Offset := Address and $3FF;
  case NameSource(Address) of
    0, 1:
      FCiram[NameSource(Address) * $400 + Offset] := Value;
    2:
      if FExMode <= 1 then
        FExRam[Offset] := Value;
  end;
end;

procedure TMapperMmc5.ResetScanlineCounter;
begin
  FInFrame := False;
  FPending := False;
  FScanlineCounter := 0;
  FRepeatedReads := 0;
  FLastPpuBusRead := 0;
end;

procedure TMapperMmc5.RestoreLegacyScanline(Line: Integer; Mask: Byte);
begin
  FLastPpuBusRead := 0;
  FRepeatedReads := 0;
  FPpuIdleCycles := 0;
  FPpuMaskRendering := (Mask and $18) <> 0;
  FInFrame := FInFrame and (Line >= 0) and (Line < 240);
  FScanlineCounter := 0;
  if FInFrame then
    FScanlineCounter := Line;
end;

procedure TMapperMmc5.CpuIoRead(Address: UInt16; Value: UInt8);
begin
  if (Address = $2002) and ((Value and $80) <> 0) then
    ResetScanlineCounter;
end;

procedure TMapperMmc5.CpuIoWrite(Address: UInt16; Value: UInt8);
begin
  if Address = $4014 then
    ResetScanlineCounter;
  if Address <> $2001 then
    Exit;
  var Rendering := (Value and $18) <> 0;
  if Rendering and not FPpuMaskRendering then
    ResetScanlineCounter;
  FPpuMaskRendering := Rendering;
end;

procedure TMapperMmc5.DetectScanline;
begin
  if not FInFrame then
  begin
    FScanlineCounter := 0;
    FPending := False;
    FInFrame := True;
    Exit;
  end;

  Inc(FScanlineCounter);
  if FScanlineCounter = 240 then
    ResetScanlineCounter
  else if FScanlineCounter = FIrqTarget then
    FPending := True;
end;

procedure TMapperMmc5.ObservePpuBusRead(Address: UInt16);
begin
  FPpuIdleCycles := 0;
  // The read after the three matching nametable fetches clocks the counter.
  // Keeping that address on the bus leaves the detector armed.
  if FRepeatedReads = 3 then
    DetectScanline;

  if (Address and $3000) <> $2000 then
    FRepeatedReads := 0
  else if (Address <> FLastPpuBusRead) or (FRepeatedReads = 0) then
    FRepeatedReads := 1
  else if FRepeatedReads < 3 then
    Inc(FRepeatedReads);
  FLastPpuBusRead := Address;
end;

procedure TMapperMmc5.SetPpuFetchKind(Sprite: Boolean; X, Y: Integer);
begin
  FSpriteFetch := Sprite;
  FPixelX := X;
  FPixelY := Y;
end;

procedure TMapperMmc5.SetPpuControl(Value: UInt8);
begin
  FLargeSprites := (Value and $20) <> 0;
end;

function TMapperMmc5.IrqPending: Boolean;
begin
  Result := (FPending and FIrqEnabled) or PcmIrq or FHardwareTimerIrq;
end;

function TMapperMmc5.SpriteFetch: Boolean;
begin
  // The live PPU pipeline supplies the kind for each individual memory read.
  // SetPpuFetchKind remains available for direct mapper/debug rendering calls.
  if FPpuRenderingRead then
    Result := FPpuSpriteFetch
  else
    Result := FSpriteFetch;
end;

procedure TMapperMmc5.ConfigurePrgRam(VolatileSize, SaveSize: UInt64);
begin
  if (VolatileSize > $20000) or (SaveSize > $20000) then
    raise ENesException.Create('Unsupported MMC5 RAM layout');

  var Size := Integer(VolatileSize + SaveSize);
  if (Size > $10000) and (Size <> $20000) then
    raise ENesException.Create('Unsupported MMC5 RAM layout');

  // Preserve the snapshot layout for previously supported cartridge sizes.
  if Size = $20000 then
    SetLength(FPrgRam, $20000)
  else
    SetLength(FPrgRam, $10000);

  var SecondChip := $8000;
  if SaveSize = $4000 then
    SecondChip := $2000;

  // Undocumented sizes keep the legacy 64 KiB bank decoding.
  for var Bank := 0 to High(FRamBankOffsets) do
  begin
    var ChipBank := Bank and 7;
    var Offset: Integer := ChipBank shl 13;
    case Size of
      0:
        Offset := -1;  // ELROM has no PRG RAM.
        $2000:           // EKROM has one 8 KiB chip.
        if ChipBank < 4 then
          Offset := 0
        else
          Offset := -1;
      $4000:           // ETROM has two 8 KiB chips. The first chip can retain saves.
        if ChipBank < 4 then
          Offset := 0
        else
          Offset := SecondChip;
      $8000:           // EWROM has one 32 KiB chip.
        if ChipBank >= 4 then
          Offset := -1;
      $A000:           // ETROM sockets can also mix 8 KiB and 32 KiB chips.
        if ChipBank < 4 then
        begin
          if SaveSize = $2000 then
            Offset := 0;
        end
        else if VolatileSize = $2000 then
          Offset := $8000;
      $20000:
        Offset := Bank shl 13;
    end;
    FRamBankOffsets[Bank] := Offset;
  end;
  ConfigureSaveRam(Integer(SaveSize));
  UpdatePrgOffsets;
end;

procedure TMapperMmc5.ConfigureSaveRam(Size: Integer);
begin
  if (Size < 0) or (Size > Length(FPrgRam)) then
    raise ENesException.Create('Unsupported MMC5 save RAM size');

  FSaveRamSize := Size;
end;

procedure TMapperMmc5.ConfigureWriteOnlyPcm;
begin
  // Immutable ROM compatibility setting, like the configured battery size.
  // This translation uses read mode to stop its write-only PCM introduction.
  FWriteOnlyPcm := True;
end;

function TMapperMmc5.ExRamSaveSize: Integer;
begin
  Result := Ord(FExRamBattery) * SizeOf(FExRam);
end;

function TMapperMmc5.GetSaveMemory: TByteArray;
begin
  // Keep the PRG NVRAM at the start of the file, followed by internal ExRAM.
  SetLength(Result, FSaveRamSize + ExRamSaveSize);
  if FSaveRamSize <> 0 then
    Move(FPrgRam[0], Result[0], FSaveRamSize);
  if FExRamBattery then
    Move(FExRam[0], Result[FSaveRamSize], SizeOf(FExRam));
end;

procedure TMapperMmc5.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> FSaveRamSize + ExRamSaveSize then
    raise ENesException.Create('Invalid cartridge save size');

  if FSaveRamSize <> 0 then
    Move(Data[0], FPrgRam[0], FSaveRamSize);
  if FExRamBattery then
    Move(Data[FSaveRamSize], FExRam[0], SizeOf(FExRam));
end;

procedure TMapperMmc5.WritePulse(Address: Word; Value: Byte);
begin
  var Pulse: PPulseChannel := @FPulses[(Address shr 2) and 1];
  case Address and 3 of
    0:
      Pulse.Reg0 := Value;
    2:
      Pulse.TimerReload := (Pulse.TimerReload and $700) or Value;
    3:
      begin
        Pulse.TimerReload := (Integer(Value and 7) shl 8) or (Pulse.TimerReload and $FF);
        Pulse.SequenceStep := 0;
        Pulse.EnvelopeStart := True;
        if Pulse.Enabled then
          Pulse.LengthCounter := APU_LENGTH_TABLE[Value shr 3];
      end;
  else
    Exit; // the sweep register is not implemented on the chip
  end;
  UpdatePulseOutput;
end;

procedure TMapperMmc5.ClockCpu;
begin
  if FHardwareTimerRunning then
  begin
    Dec(FHardwareTimerCount);
    if FHardwareTimerCount = 0 then
    begin
      FHardwareTimerRunning := False;
      FHardwareTimerIrq := True;
    end;
  end;

  if FPpuIdleCycles < 3 then
  begin
    Inc(FPpuIdleCycles);
    if FPpuIdleCycles = 3 then
    begin
      FInFrame := False;
      FRepeatedReads := 0;
    end;
  end;

  Inc(FAudioDivider);
  var OutputChanged := False;
  if (FAudioDivider and 1) = 0 then
    for var Index := 0 to High(FPulses) do
    begin
      var Pulse: PPulseChannel := @FPulses[Index];
      if Pulse.Timer > 0 then
        Dec(Pulse.Timer)
      else
      begin
        Pulse.Timer := Pulse.TimerReload;
        Pulse.SequenceStep := (Pulse.SequenceStep + 1) and 7;
        if Pulse.LengthCounter <> 0 then
          OutputChanged := True;
      end;
    end;
  if FAudioDivider = MMC5_AUDIO_DIVIDER then
  begin
    FAudioDivider := 0;
    for var Index := 0 to High(FPulses) do
    begin
      var Pulse: PPulseChannel := @FPulses[Index];
      ClockApuPulseEnvelope(Pulse^);
      if Pulse.LengthCounter > 0 then
      begin
        if (Pulse.Reg0 and $20) = 0 then
          Dec(Pulse.LengthCounter);
        OutputChanged := True;
      end;
    end;
  end;
  if OutputChanged then
    UpdatePulseOutput;
end;

procedure TMapperMmc5.UpdatePulseOutput;
begin
  var Level := 0;
  for var Index := 0 to High(FPulses) do
  begin
    var Pulse: PPulseChannel := @FPulses[Index];
    if (Pulse.LengthCounter <> 0) and (APU_DUTY_TABLE[Pulse.Reg0 shr 6, Pulse.SequenceStep and 7] <> 0) then
      Inc(Level, ApuPulseVolume(Pulse^));
  end;
  FPulseOutput := -PulseDac[Level];
end;

function TMapperMmc5.PcmIrq: Boolean;
begin
  Result := FPcmTrip and ((FPcmControl and $80) <> 0);
end;

procedure TMapperMmc5.WritePcm(Value: Byte);
begin
  FPcmTrip := Value = 0;
  if not FPcmTrip then
    FPcmOutput := Value;
end;

function TMapperMmc5.ExpansionAudio: Double;
begin
  Result := FPulseOutput;
  if not FWriteOnlyPcm or ((FPcmControl and 1) = 0) then
    // PCM and pulse output have opposite polarity to the native APU.
    Result := Result - FPcmOutput * (14.0 / 5000.0);
end;

procedure InitializePulseDac;
begin
  for var Level := 1 to High(PulseDac) do
    PulseDac[Level] := 95.88 / (8128.0 / Level + 100.0);
end;

initialization
  InitializePulseDac;

end.

