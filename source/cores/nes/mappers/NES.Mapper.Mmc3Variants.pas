unit NES.Mapper.Mmc3Variants;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Mmc3, NES.Mapper.Banked,
  HW.Sound.MSM5205;

type
  TMapperMmc3Variant = class(TMapperMmc3)
  private
    FBoard: Integer;
    FOuterChr: Byte;
    FExtraRam: array[0..$1FFF] of Byte;
    FWaixingF003: Boolean;
    FWaixingPrgOffsets: array[0..1, 0..3] of Integer;
    FWaixingPrgHalf: array[0..3] of Byte;
    procedure UpdateWaixingPrgOffsets;
    procedure RestoreWaixingState;
    function ChrBank(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure LoadLegacyMmc3State(State: TNesStateArchive);
    procedure Reset; override;
    function UsesPpuAddressBus: Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockScanline(Scanline: Integer; RenderingEnabled: Boolean); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperNesticle = class(TMapperMmc3)
  private
    FPrgBanks: array[0..3] of Byte;
    FChrBanks: array[0..7] of Byte;
    FTrainer: NES.Types.TByteArray;
    function PatternOffset(Address: UInt16): Integer;
  public
    procedure InstallTrainer(const Trainer: NES.Types.TByteArray);
    function StartupAddress: Word;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperJncota523 = class(TMapperMmc3)
  private
    FOuter: array[0..3] of Byte;
    FExtra: array[8..11] of Byte;
    FDataLatch, FA12Filter: Byte;
    function ProgramBank(Slot: Integer): Integer;
    function PatternOffset(Address: UInt16): Integer;
  public
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
  end;

  TMapperBatmap = class(TMapperMmc3)
  private
    FMusicBoard: Boolean;
    FPrgRamSize: Integer;
    FPrgBank, FChrBank: array[0..1] of Byte;
    function ChrOffset(Address: UInt16): Integer; inline;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer);
    procedure ConfigurePrgRam(Size: UInt64); reintroduce;
    procedure PowerOn; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperBatmapSrrx = class(TMapperBanked)
  private
    FSpeechRom: TArray<Byte>;
    FSpeechAddress: Cardinal;
    FSpeechAutoIncrement: Boolean;
    FIrqCounter, FIrqLatch, FIrqFilter: Byte;
    FIrqEnabled, FIrqPending: Boolean;
  public
    constructor Create(const Prg, Chr: TByteArray; const SpeechRom: TArray<Byte>; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
  end;

  TMapperMcafeE1 = class(TMapperBanked)
  private
    FA12Samples, FCounter: Byte;
    FA12High, FPending: Boolean;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
  end;

  TMapperRincoTalkman = class(TMapperMmc3)
  private
    FFifo: array[0..1023] of Byte;
    FReadIndex, FWriteIndex, FCount: Integer;
    FRateSelect, FInput, FExtraPrgBank, FBlockSelect: Byte;
    FCpuHz, FPhase: Integer;
    FSecondNibble, FPlaying: Boolean;
    FDecoder: TOkiAdpcmDecoder;
    FLowPassCoefficient, FHighPassCoefficient: Double;
    FFiltered, FDirectCurrent: Double;
    procedure UpdateAudioRates;
    procedure ClockNibble;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
  end;

implementation

uses
  System.Math, NES.Consts;

procedure TMapperNesticle.InstallTrainer(const Trainer: NES.Types.TByteArray);
begin
  if Length(Trainer) > $1000 then
    raise ENesException.Create('Nesticle trainer exceeds the $7000-$7FFF RAM window');
  FTrainer := Copy(Trainer);
  if Length(FTrainer) <> 0 then
    Move(FTrainer[0], FPrgRam[$1000], Length(FTrainer));
end;

function TMapperNesticle.StartupAddress: Word;
begin
  Result := 0;
  if (Length(FTrainer) <> 0) and (FTrainer[0] = $4C) then
    Result := $7000;
end;

procedure TMapperNesticle.Reset;
begin
  inherited;
  FIrqRequiresCounterTransition := True;
  FPrgBanks[0] := 0;
  FPrgBanks[1] := 1;
  FPrgBanks[2] := $FE;
  FPrgBanks[3] := $FF;
  for var Slot := 0 to High(FChrBanks) do
    FChrBanks[Slot] := Slot;
  if Length(FTrainer) <> 0 then
    Move(FTrainer[0], FPrgRam[$1000], Length(FTrainer));
end;

procedure TMapperNesticle.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgBanks, SizeOf(FPrgBanks));
  State.Field(FChrBanks, SizeOf(FChrBanks));
end;

function TMapperNesticle.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuRead(Address, Value));
  var Bank := FPrgBanks[(Address - $8000) shr 13];
  Value := FPrgRom[((Bank shl 13) or (Address and $1FFF)) mod Length(FPrgRom)];
  Result := True;
end;

function TMapperNesticle.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $8000..$9FFF:
      if (Address and 1) = 0 then
        FBankSelect := Value
      else
        case FBankSelect of
          $00, $01, $80, $81:
            begin
              var Slot := ((FBankSelect and 1) shl 1) or ((FBankSelect and $80) shr 5);
              FChrBanks[Slot] := Value and $FE;
              FChrBanks[Slot + 1] := Value or 1;
            end;
          $02..$05:
            FChrBanks[FBankSelect + 2] := Value;
          $82..$85:
            FChrBanks[FBankSelect - $82] := Value;
          $06:
            FPrgBanks[0] := Value;
          $07, $47:
            FPrgBanks[1] := Value;
          $46:
            FPrgBanks[2] := Value;
        end;
    $A000..$BFFF:
      if (Address and 1) = 0 then
        inherited CpuWrite(Address, Value);
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

function TMapperNesticle.PatternOffset(Address: UInt16): Integer;
begin
  Result := ((Integer(FChrBanks[Address shr 10]) shl 10) or (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperNesticle.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[PatternOffset(Address)];
end;

function TMapperNesticle.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := FHasChrRam and (Address < $2000);
  if Result then
    FChrMemory[PatternOffset(Address)] := Value;
end;

procedure TMapperJncota523.Reset;
begin
  inherited;
  FillChar(FOuter, SizeOf(FOuter), 0);
  FExtra[8] := $FE;
  FExtra[9] := $FF;
  FExtra[10] := 1;
  FExtra[11] := 3;
  FDataLatch := 0;
  FA12Filter := 0;
end;

procedure TMapperJncota523.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FOuter, SizeOf(FOuter));
  State.Field(FExtra, SizeOf(FExtra));
  State.Field(FDataLatch, SizeOf(FDataLatch));
  State.Field(FA12Filter, SizeOf(FA12Filter));
end;

function TMapperJncota523.ProgramBank(Slot: Integer): Integer;
begin
  var Outside := (FOuter[1] and $7F) shl 1;
  var Mode := FOuter[0] and 7;
  case Mode of
    3:
      Exit(Outside or (Slot and 1));
    4:
      Exit((Outside and not 3) or Slot);
    5:
      Exit((Outside and not $0F) or ((FDataLatch and 7) shl 1) or
        (Slot and 1) or (14 * Ord((Slot and 2) <> 0)));
    6, 7:
      Exit(0);
  end;

  if ((FBankSelect and $40) <> 0) and not Odd(Slot) then
    Slot := Slot xor 2;
  case Slot of
    0, 1:
      Result := FBankRegisters[6 + Slot];
  else
    if (FOuter[3] and 2) <> 0 then
      Result := FExtra[6 + Slot]
    else
      Result := $FC or Slot;
  end;
  var Mask := $3F shr Mode;
  Result := (Result and Mask) or (Outside and not Mask);
end;

function TMapperJncota523.PatternOffset(Address: UInt16): Integer;
const
  RegisterForPair: array[0..3] of Byte = (0, 1, 2, 4);
begin
  var OuterChr := FOuter[2] shl 3;
  var PairIndex := Address shr 11;
  var Bank: Integer;
  if (FOuter[0] and $40) <> 0 then
    Bank := OuterChr or (PairIndex shl 1)
  else
  begin
    if (FBankSelect and $80) <> 0 then
      PairIndex := PairIndex xor 2;
    Bank := FBankRegisters[RegisterForPair[PairIndex]];
    var Mask := $FF shr Ord((FOuter[0] and $10) <> 0);
    if ((FOuter[3] and 2) = 0) and (PairIndex < 2) then
      Mask := Mask and $FE;
    Bank := (Bank and Mask) or (OuterChr and not ($FF shr Ord((FOuter[0] and $10) <> 0)));
  end;
  // The ASIC's PPU A10 input is grounded. The ROM takes A10 directly from the PPU.
  Result := ((Bank shl 11) or (Address and $7FF)) mod Length(FChrMemory);
end;

function TMapperJncota523.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuRead(Address, Value));
  var Bank := ProgramBank((Address - $8000) shr 13);
  Value := FPrgRom[((Bank shl 13) or (Address and $1FFF)) mod Length(FPrgRom)];
  Result := True;
end;

function TMapperJncota523.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $5000) and (Address < $6000) and ((Address and $10) <> 0) then
  begin
    FOuter[Address and 3] := Value;
    Exit(True);
  end;
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));

  FDataLatch := Value;
  if (FOuter[0] and 7) < 5 then
    case Address of
      $8000..$9FFF:
        case Address and 3 of
          0:
            FBankSelect := Value;
          1:
            begin
              var RegisterIndex := FBankSelect and 7;
              if (FOuter[3] and 2) <> 0 then
                RegisterIndex := FBankSelect and 15;
              if RegisterIndex < 8 then
                FBankRegisters[RegisterIndex] := Value
              else if RegisterIndex <= High(FExtra) then
                FExtra[RegisterIndex] := Value;
            end;
        end;
      $A000..$BFFF:
        if (Address and 1) <> 0 then
          FPrgRamControl := Value and $80;
      $C000..$DFFF:
        if (Address and 1) <> 0 then
          FIrqCounter := 0
        else
          FIrqLatch := Value;
      $E000..$FFFF:
        begin
          FIrqEnabled := (Address and 1) <> 0;
          if not FIrqEnabled then
            FIrqPending := False;
        end;
    end;
  Result := True;
end;

function TMapperJncota523.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[PatternOffset(Address)];
end;

function TMapperJncota523.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := FHasChrRam and (Address < $2000);
  if Result then
    FChrMemory[PatternOffset(Address)] := Value;
end;

procedure TMapperJncota523.ClockCpu;
begin
  if FA12Filter <> 0 then
    Dec(FA12Filter);
end;

procedure TMapperJncota523.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if (Address and $1000) = 0 then
    Exit;
  if FA12Filter = 0 then
  begin
    if FIrqCounter = 0 then
      FIrqCounter := FIrqLatch
    else
      Dec(FIrqCounter);
    if (FIrqCounter = 0) and FIrqEnabled then
      FIrqPending := True;
  end;
  FA12Filter := 5;
end;

constructor TMapperBatmap.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  if (Submapper > 1) or (Length(Chr) <> 0) then
    raise ENesException.Create('Unsupported BATMAP cartridge configuration');
  inherited Create(Prg, Chr, True, MirrorMode);
  FMusicBoard := Submapper = 1;
  FIrqRequiresCounterTransition := True;
  SetLength(FChrMemory, $8000);
  PowerOn;
end;

procedure TMapperBatmap.ConfigurePrgRam(Size: UInt64);
begin
  if FMusicBoard then
    Exit;
  if Size > SizeOf(FPrgRam) then
    raise ENesException.Create('Unsupported BATMAP PRG-RAM size');
  FPrgRamSize := Integer(Size);
end;

procedure TMapperBatmap.PowerOn;
begin
  inherited;
  FPrgBank[0] := 0;
  FPrgBank[1] := 1;
  FChrBank[0] := 0;
  FChrBank[1] := 1;
end;

procedure TMapperBatmap.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgBank, SizeOf(FPrgBank));
  State.Field(FChrBank, SizeOf(FChrBank));
end;

function TMapperBatmap.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
var
  Bank: Integer;
begin
  case Address shr 13 of
    3:
      if FMusicBoard then
        Bank := $FE
      else if FPrgRamSize <> 0 then
      begin
        Value := FPrgRam[(Address and $1FFF) mod FPrgRamSize];
        Exit(True);
      end
      else
        Exit(False);
    4:
      if FMusicBoard then
        Bank := FPrgBank[0] shl 1
      else
        Bank := 0;
    5:
      if FMusicBoard then
        Bank := (FPrgBank[0] shl 1) or 1
      else
        Bank := FPrgBank[0];
    6:
      Bank := FPrgBank[1];
    7:
      Bank := $FF;
  else
    Exit(False);
  end;
  Value := FPrgRom[(Bank mod (Length(FPrgRom) div $2000)) * $2000 + (Address and $1FFF)];
  Result := True;
end;

function TMapperBatmap.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $6000 then
    Exit(False);
  if Address < $8000 then
  begin
    if FMusicBoard or (FPrgRamSize = 0) then
      Exit(False);
    FPrgRam[(Address and $1FFF) mod FPrgRamSize] := Value;
    Exit(True);
  end;

  if (not FMusicBoard and (Address < $A000)) or (FMusicBoard and (Address >= $E000)) then
  begin
    if Odd(Address) then
      FPrgBank[Value shr 7] := Value and $7F
    else
      FChrBank[Value shr 7] := Value and 7;
    Exit(True);
  end;
  if FMusicBoard then
    Inc(Address, $2000);
  Result := inherited CpuWrite(Address, Value);
end;

function TMapperBatmap.ChrOffset(Address: UInt16): Integer;
begin
  Result := (FChrBank[(Address shr 12) and 1] and 7) * $1000 + (Address and $FFF);
end;

function TMapperBatmap.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[ChrOffset(Address)];
end;

function TMapperBatmap.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    FChrMemory[ChrOffset(Address)] := Value;
end;

constructor TMapperBatmapSrrx.Create(const Prg, Chr: TByteArray; const SpeechRom: TArray<Byte>; MirrorMode: TMirrorMode);
begin
  if (Length(Prg) <> $40000) or (Length(Chr) <> $40000) or (Length(SpeechRom) <> $800000) then
    raise ENesException.Create('Unsupported BATMAP-SRR-X ROM configuration');
  inherited Create(Prg, Chr, False, MirrorMode);
  FSpeechRom := SpeechRom;
  SetLength(FPrgRam, 0);
  Reset;
end;

procedure TMapperBatmapSrrx.Reset;
begin
  inherited;
  FRamEnabled := False;
  FRamWritable := False;
  Prg8(0, 0);
  Prg8(1, 0);
  Prg8(2, 0);
  Prg8(3, 4);
  Chr4(1, $FD and $3F);
  FSpeechAddress := 0;
  FSpeechAutoIncrement := False;
  FIrqCounter := 0;
  FIrqLatch := 0;
  FIrqFilter := 0;
  FIrqEnabled := False;
  FIrqPending := False;
end;

procedure TMapperBatmapSrrx.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FSpeechAddress, SizeOf(FSpeechAddress));
  State.Field(FSpeechAutoIncrement, SizeOf(FSpeechAutoIncrement));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqLatch, SizeOf(FIrqLatch));
  State.Field(FIrqFilter, SizeOf(FIrqFilter));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
end;

function TMapperBatmapSrrx.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := ((Address and $F800) = $4800) or ((Address and $F000) = $C000);
  if Result then
    Value := FSpeechRom[FSpeechAddress and $7FFFFF];
end;

function TMapperBatmapSrrx.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if CpuPeek(Address, Value) then
  begin
    if FSpeechAutoIncrement then
      FSpeechAddress := (FSpeechAddress + 1) and $7FFFFF;
    Exit(True);
  end;

  case Address of
    $5000..$5FFF:
      Value := FPrgRom[$1000 or (Address and $0FFF)];
    $6000..$7FFF:
      Value := FPrgRom[FPrgBanks[2] * $2000 + (Address and $1FFF)];
    $D000..$DFFF:
      Value := FPrgRom[$7000 or (Address and $0FFF)];
  else
    Exit(inherited CpuRead(Address, Value));
  end;
  Result := True;
end;

function TMapperBatmapSrrx.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address shr 12 of
    8:
      FIrqLatch := Value;
    9:
      FIrqCounter := 0;
    $A:
      begin
        FIrqEnabled := False;
        FIrqPending := False;
      end;
    $B:
      FIrqEnabled := True;
    $C:
      FSpeechAddress := ((FSpeechAddress shl 1) or (Value shr 7)) and $7FFFFF;
    $D:
      FSpeechAutoIncrement := (Value and 2) <> 0;
    $E, $F:
      case Value shr 6 of
        0:
          Prg8(2, Value and $3F);
        1:
          Prg8(0, Value and $3F);
        2:
          Prg8(1, Value and $3F);
        3:
          Chr4(0, Value and $3F);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure TMapperBatmapSrrx.ClockCpu;
begin
  if FIrqFilter <> 0 then
    Dec(FIrqFilter);
end;

procedure TMapperBatmapSrrx.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if (Address and $1000) = 0 then
    Exit;
  if FIrqFilter = 0 then
  begin
    if FIrqCounter = 0 then
      FIrqCounter := FIrqLatch
    else
      Dec(FIrqCounter);
    if FIrqEnabled and (FIrqCounter = 0) then
      FIrqPending := True;
  end;
  FIrqFilter := 5;
end;

function TMapperBatmapSrrx.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

procedure TMapperMmc3Variant.SerializeState(State: TNesStateArchive);
var
  Banks: array[0..7] of UInt8;
begin
  Move(FBankRegisters, Banks, SizeOf(Banks));
  if (FBoard = MAPPER_MMC3_91) and (State.Version < 6) and not State.Loading then
  begin
    FBankRegisters[0] := (Integer(Banks[0]) * 2) and $FF;
    FBankRegisters[1] := (Integer(Banks[1]) * 2) and $FF;
    FBankRegisters[2] := (Integer(Banks[2]) * 2) and $FF;
    FBankRegisters[3] := (Integer(Banks[2]) * 2 + 1) and $FF;
    FBankRegisters[4] := (Integer(Banks[3]) * 2) and $FF;
    FBankRegisters[5] := (Integer(Banks[3]) * 2 + 1) and $FF;
  end;
  try
    inherited;
    State.Field(FBoard, SizeOf(FBoard));
    State.Field(FOuterChr, SizeOf(FOuterChr));
    State.Field(FExtraRam, SizeOf(FExtraRam));
  finally
    if (FBoard = MAPPER_MMC3_91) and (State.Version < 6) and not State.Loading then
      Move(Banks, FBankRegisters, SizeOf(Banks));
  end;
  if (FBoard = MAPPER_MMC3_91) and (State.Version < 6) and State.Loading then
  begin
    Move(FBankRegisters, Banks, SizeOf(Banks));
    FBankRegisters[0] := Banks[0] shr 1;
    FBankRegisters[1] := Banks[1] shr 1;
    FBankRegisters[2] := Banks[2] shr 1;
    FBankRegisters[3] := Banks[4] shr 1;
  end;
  if State.Loading and (FBoard = MAPPER_MMC3_245) then
    RestoreWaixingState;
end;

procedure TMapperMmc3Variant.LoadLegacyMmc3State(State: TNesStateArchive);
begin
  inherited SerializeState(State);
  FOuterChr := 0;
  RestoreWaixingState;
end;

procedure TMapperMmc3Variant.RestoreWaixingState;
begin
  FOuterChr := FOuterChr and 3;
  if FWaixingF003 then
  begin
    // There are no A12 edges at the chip on this board.
    FIrqPending := False;
    FA12High := False;
  end;
  UpdateWaixingPrgOffsets;
end;

constructor TMapperMmc3Variant.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FWaixingF003 := (FBoard = MAPPER_MMC3_245) and HasChrRam;
  Reset;
end;

procedure TMapperMmc3Variant.Reset;
begin
  inherited;
  FOuterChr := 0;
  if FWaixingF003 then
    FillChar(FBankRegisters[0], 6 * SizeOf(FBankRegisters[0]), 0);
  if FBoard = MAPPER_MMC3_245 then
    UpdateWaixingPrgOffsets;
end;

function TMapperMmc3Variant.UsesPpuAddressBus: Boolean;
begin
  Result := FWaixingF003;
end;

procedure TMapperMmc3Variant.UpdateWaixingPrgOffsets;
begin
  var Count := Length(FPrgRom) div $2000;
  for var Half := 0 to 1 do
  begin
    var LastBank := Count - 1;
    var Outer := Half shl 6;
    if Count >= $40 then
      LastBank := $3F or Outer;
    var Swap := (FBankSelect and $40) shr 5;
    FWaixingPrgOffsets[Half, Swap] := (((FBankRegisters[6] and $3F) or Outer) mod Count) shl 13;
    FWaixingPrgOffsets[Half, 1] := (((FBankRegisters[7] and $3F) or Outer) mod Count) shl 13;
    FWaixingPrgOffsets[Half, 2 xor Swap] := ((LastBank + Count - 1) mod Count) shl 13;
    FWaixingPrgOffsets[Half, 3] := (LastBank mod Count) shl 13;
  end;

  for var Slot := 0 to 3 do
  begin
    var RegisterIndex := 0;
    if FWaixingF003 then
      if (FBankSelect and $80) = 0 then
        RegisterIndex := Slot shr 1
      else
        RegisterIndex := Slot + 2;
    FWaixingPrgHalf[Slot] := (FBankRegisters[RegisterIndex] shr 1) and 1;
  end;
end;

procedure TMapperMmc3Variant.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FBoard = MAPPER_MMC3_91 then
    Exit;

  if FWaixingF003 then
  begin
    // PPU A12 is tied low at the MMC3. CHR A11 drives PRG A19.
    FOuterChr := (Address shr 10) and 3;
    Exit;
  end;

  var WasPending := FIrqPending;
  var CanTrigger := (FIrqCounter <> 0) or FIrqReloadPending;
  inherited;
  // Revision A does not repeatedly assert IRQ when reloading zero automatically.
  if (FBoard = MAPPER_MMC3_12) and not CanTrigger then
    FIrqPending := WasPending;
end;

procedure TMapperMmc3Variant.ClockScanline(Scanline: Integer; RenderingEnabled: Boolean);
begin
  if FBoard <> MAPPER_MMC3_91 then
  begin
    inherited;
    Exit;
  end;

  // JY-016 asserts once after eight rendered scanlines, until acknowledged.
  if RenderingEnabled and (Scanline >= 0) and (Scanline < 240) and FIrqEnabled and (FIrqCounter < 8) then
  begin
    Inc(FIrqCounter);
    if FIrqCounter = 8 then
      FIrqPending := True;
  end;
end;

function TMapperMmc3Variant.ChrBank(Address: UInt16): Integer;
begin
  // Mapper 91 has four full-width 2 KiB registers. Expanding them into
  // byte-sized MMC3 registers loses CHR A18 on 512 KiB cartridges.
  if FBoard = MAPPER_MMC3_91 then
    Exit((Integer(FBankRegisters[Address shr 11]) or ((FOuterChr and 1) shl 8)) * 2 + ((Address shr 10) and 1));

  if (FBoard = MAPPER_MMC3_245) and FHasChrRam then
    Exit(Address shr 10);

  var Original := Address;
  if (FBankSelect and $80) <> 0 then
    Address := Address xor $1000;
  var Slot := Address shr 10;
  if Slot < 4 then
    Result := (FBankRegisters[Slot shr 1] and $FE) or (Slot and 1)
  else
    Result := FBankRegisters[Slot - 2];
  if FBoard = MAPPER_MMC3_12 then
    if ((Original < $1000) and ((FOuterChr and 1) <> 0)) or ((Original >= $1000) and ((FOuterChr and $10) <> 0)) then
      Result := Result or $100;
end;

function TMapperMmc3Variant.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FBoard = MAPPER_MMC3_91 then
  begin
    Result := Address >= $8000;
    if not Result then
      Exit;

    var Bank: Integer;
    case (Address - $8000) shr 13 of
      0:
        Bank := FBankRegisters[6];
      1:
        Bank := FBankRegisters[7];
      2:
        Bank := $0E;
    else
      Bank := $0F;
    end;
    Bank := Bank or ((FOuterChr and 6) shl 3);
    Value := FPrgRom[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit;
  end;

  if (FBoard <> MAPPER_MMC3_245) or (Address < $8000) then
    Exit(inherited CpuRead(Address, Value));

  var Half := FWaixingPrgHalf[FOuterChr];
  var Offset := FWaixingPrgOffsets[Half, (Address shr 13) and 3];
  Value := FPrgRom[Offset + (Address and $1FFF)];
  Result := True;
end;

function TMapperMmc3Variant.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_MMC3_12) and (Address >= $4020) and (Address < $6000) then
  begin
    FOuterChr := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_91 then
  begin
    if (Address >= $8000) and (Address < $A000) then
    begin
      FOuterChr := Address and 7;
      Exit(True);
    end;
    Result := (Address >= $6000) and (Address < $8000);
    if not Result then
      Exit;
    var RegisterAddress := Address and $7003;
    if (Address < $7000) and ((Address and 7) >= 4) then
      Exit;
    case RegisterAddress of
      $6000..$6003:
        FBankRegisters[Address and 3] := Value;
      $7000, $7001:
        FBankRegisters[6 + (Address and 1)] := Value;
      $7002:
        begin
          FIrqEnabled := False;
          FIrqPending := False;
          FIrqCounter := 0;
        end;
      $7003:
        begin
          FIrqEnabled := True;
          FIrqPending := False;
        end;
    end;
    Exit;
  end;

  if (FBoard = MAPPER_MMC3_250) and (Address >= $8000) then
  begin
    Value := Address and $FF;
    Address := (Address and $E000) or ((Address shr 10) and 1);
  end;
  Result := inherited CpuWrite(Address, Value);
  if (FBoard = MAPPER_MMC3_245) and ((Address and $E000) = $8000) then
    UpdateWaixingPrgOffsets;
end;

function TMapperMmc3Variant.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if not Result then
    Exit;

  var Bank := ChrBank(Address);
  if (FBoard = MAPPER_TQROM) and ((Bank and $40) <> 0) then
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
  if (FBoard = MAPPER_TQROM) and ((Bank and $40) <> 0) then
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

constructor TMapperMcafeE1.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  PowerOn;
end;

procedure TMapperMcafeE1.PowerOn;
begin
  inherited Reset;
  Prg8(1, 0);
  Mirror(0);
  FA12Samples := 0;
  FCounter := 0;
  FA12High := False;
  FPending := False;
end;

procedure TMapperMcafeE1.Reset;
begin
  // The console reset signal does not reach the cartridge's CPLD.
end;

procedure TMapperMcafeE1.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FA12Samples, SizeOf(FA12Samples));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FA12High, SizeOf(FA12High));
  State.Field(FPending, SizeOf(FPending));
end;

function TMapperMcafeE1.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address and $F000 of
    $8000:
      Chr4(0, Value and $1F);
    $9000:
      Chr4(1, Value and $1F);
    $A000:
      Prg8(0, Value and $0F);
    $B000:
      Prg8(1, Value and $0F);
    $E000:
      begin
        FCounter := Value;
        FPending := False;
      end;
    $F000:
      Mirror(Value and 1);
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

procedure TMapperMcafeE1.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  FA12High := (Address and $1000) <> 0;
end;

procedure TMapperMcafeE1.ClockCpu;
begin
  // The CPLD qualifies PPU A12 against the previous three rising M2 samples.
  if FA12High and (FA12Samples = 0) and (FCounter <> 0) then
  begin
    Dec(FCounter);
    FPending := FCounter = 0;
  end;
  FA12Samples := ((FA12Samples shl 1) or Ord(FA12High)) and 7;
end;

function TMapperMcafeE1.IrqPending: Boolean;
begin
  Result := FPending;
end;

constructor TMapperRincoTalkman.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  FCpuHz := NES_CPU_HZ;
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
end;

procedure TMapperRincoTalkman.Reset;
begin
  inherited;
  FExtraPrgBank := 0;
  FBlockSelect := 0;
  FReadIndex := 0;
  FWriteIndex := 0;
  FCount := 0;
  FRateSelect := 0;
  FInput := 0;
  FSecondNibble := False;
  FPlaying := False;
  FPhase := 0;
  FDecoder := Default(TOkiAdpcmDecoder);
  FDecoder.Signal := -2;
  FFiltered := 0;
  FDirectCurrent := 0;
  UpdateAudioRates;
end;

procedure TMapperRincoTalkman.SetRegion(Region: TNesRegion);
begin
  var NewFrequency := CpuFrequency(Region);
  FPhase := (Int64(FPhase) * NewFrequency) div FCpuHz;
  FCpuHz := NewFrequency;
  UpdateAudioRates;
end;

procedure TMapperRincoTalkman.UpdateAudioRates;
begin
  // Approximate the reconstruction and AC coupling on the speech output.
  FLowPassCoefficient := 1 - Exp(-2 * Pi * (1600 shl FRateSelect) / FCpuHz);
  FHighPassCoefficient := 1 - Exp(-2 * Pi * 20 / FCpuHz);
end;

procedure TMapperRincoTalkman.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FFifo, SizeOf(FFifo));
  State.Field(FReadIndex, SizeOf(FReadIndex));
  State.Field(FWriteIndex, SizeOf(FWriteIndex));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FRateSelect, SizeOf(FRateSelect));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FExtraPrgBank, SizeOf(FExtraPrgBank));
  State.Field(FBlockSelect, SizeOf(FBlockSelect));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FSecondNibble, SizeOf(FSecondNibble));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FDecoder.Signal, SizeOf(FDecoder.Signal));
  State.Field(FDecoder.StepIndex, SizeOf(FDecoder.StepIndex));
  State.Field(FFiltered, SizeOf(FFiltered));
  State.Field(FDirectCurrent, SizeOf(FDirectCurrent));
  if State.Loading then
  begin
    var FifoSize := Cardinal(Length(FFifo));
    if (Cardinal(FReadIndex) >= FifoSize) or (Cardinal(FWriteIndex) >= FifoSize) or
      (Cardinal(FCount) > FifoSize) or (FRateSelect > 3) or
      (Cardinal(FPhase) >= Cardinal(FCpuHz)) or IsNan(FFiltered) or IsInfinite(FFiltered) or
      IsNan(FDirectCurrent) or IsInfinite(FDirectCurrent) then
      raise ENesException.Create('Invalid Rinco Talkman state');
    FDecoder.ValidateState;
    UpdateAudioRates;
  end;
end;

procedure TMapperRincoTalkman.ClockNibble;
begin
  if not FSecondNibble then
  begin
    FInput := 0;
    if FCount <> 0 then
    begin
      FInput := FFifo[FReadIndex];
      FReadIndex := (FReadIndex + 1) and High(FFifo);
      Dec(FCount);
      FPlaying := True;
    end
    else if not FPlaying then
      Exit;
    FDecoder.Clock(FInput shr 4);
  end
  else
    FDecoder.Clock(FInput and $0F);
  FSecondNibble := not FSecondNibble;
end;

procedure TMapperRincoTalkman.ClockCpu;
begin
  Inc(FPhase, 4000 shl FRateSelect);
  if FPhase >= FCpuHz then
  begin
    Dec(FPhase, FCpuHz);
    ClockNibble;
  end;
  if FPlaying then
  begin
    FFiltered := FFiltered + FLowPassCoefficient * (FDecoder.Sample - FFiltered);
    FDirectCurrent := FDirectCurrent + FHighPassCoefficient * (FFiltered - FDirectCurrent);
  end;
end;

function TMapperRincoTalkman.ExpansionAudio: Double;
begin
  Result := (FFiltered - FDirectCurrent) * (0.18 / 32768.0);
end;

function TMapperRincoTalkman.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address and $F001) = $5001 then
  begin
    Value := Ord(FCount < Length(FFifo) div 2) shl 6;
    Exit(True);
  end;
  if Address < $6000 then
    Exit(False);

  var Bank: Integer;
  if Address < $8000 then
    Bank := FExtraPrgBank
  else
  begin
    var Slot := (Address - $8000) shr 13;
    if ((FBankSelect and $40) <> 0) and ((Slot and 1) = 0) then
      Slot := Slot xor 2;
    if Slot < 2 then
      Bank := FBankRegisters[6 + Slot] and $3F
    else
      Bank := $3C + Slot;
  end;
  if (FBlockSelect and $40) <> 0 then
    Bank := Bank or $C0;
  if (FBlockSelect and $80) <> 0 then
    Bank := (Bank and $7F) or $100;
  Value := FPrgRom[((Bank shl 13) or (Address and $1FFF)) mod Length(FPrgRom)];
  Result := True;
end;

function TMapperRincoTalkman.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address and $F001 of
    $5000:
      if FCount < Length(FFifo) then
      begin
        FFifo[FWriteIndex] := Value;
        FWriteIndex := (FWriteIndex + 1) and High(FFifo);
        Inc(FCount);
      end;
    $5001:
      begin
        FReadIndex := 0;
        FWriteIndex := 0;
        FCount := 0;
        FRateSelect := Value shr 6;
        UpdateAudioRates;
      end;
    $9000:
      FExtraPrgBank := Value;
    $9001:
      begin
        // Software writes $10 here. The board function is undocumented.
      end;
    $B000, $B001:
      FBlockSelect := Value and $C0;
  else
    Exit((Address >= $8000) and inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

function TMapperRincoTalkman.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  var Offset := GetChrOffset(Address);
  case FBlockSelect of
    $00:
      Offset := Offset or ((Address and $1000) shl 6);
    $40:
      Offset := Offset or $80000;
  else
    Offset := Offset or $C0000;
  end;
  Value := FChrMemory[Offset mod Length(FChrMemory)];
  Result := True;
end;

end.

