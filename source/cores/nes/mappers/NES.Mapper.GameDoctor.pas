unit NES.Mapper.GameDoctor;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

const
  TURBO_GAME_DOCTOR_BIOS_FILE = 'turbo-game-doctor-4800.bin';

type
  TGameDoctorBusWrite = procedure(Address: UInt16; Value: UInt8) of object;

  TMapperGameDoctor = class(TMapperBanked)
  private
    FTurbo: Boolean;
    FInitialMode, FMode, FExpandedMode, FTurboMode, FLatch, FChrBank: Byte;
    FPrgRegisters: array[0..3] of Byte;
    FChrRegisters: array[0..7] of Byte;
    FLastChrSlot: Integer;
    FChrLocked: Boolean;
    FDiskControl: Byte;
    FDiskPhase, FIrqCounter, FIrqTarget: Integer;
    FCounterEnabled, FIrq, FDiskIrq: Boolean;
    FPrgImage, FChrImage, FTrainer, FBios: TByteArray;
    FTrainerAddress, FTrainerEntry, FBootstrap: UInt16;
    function ExpandedPrg: Boolean;
    function FullPrg: Boolean;
    procedure MapBanks;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer; Turbo: Boolean; const TrainerData: TArray<Byte>);
    procedure ConfigureMedia(ChrRamSize: UInt64; const StandardTrainer, Bios: TByteArray);
    function InstallStartup(WriteBus: TGameDoctorBusWrite): UInt16;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
  end;

implementation

constructor TMapperGameDoctor.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer; Turbo: Boolean; const TrainerData: TArray<Byte>);
begin
  if (Submapper < 0) or (Submapper > 7) or (Length(Prg) > $80000) or
    (Length(Chr) > $40000) or (not Turbo and (Length(Chr) > $8000)) then
    raise ENesException.Create('Invalid Game Doctor memory layout');

  inherited Create(Prg, Chr, True, MirrorMode);
  FTurbo := Turbo;
  FInitialMode := (Submapper shl 5) or 3;
  if MirrorMode <> TMirrorMode.Vertical then
    FInitialMode := FInitialMode or $10;
  if FTurbo then
    FInitialMode := FInitialMode or 4;

  // G026 copies bank 0 into bank 15 from its initialization routine.
  if not FTurbo and (Submapper = 3) and (Length(FPrgRom) < $40000) then
    SetLength(FPrgRom, $40000);
  FPrgImage := Copy(FPrgRom);
  FChrImage := Copy(Chr);

  if Length(TrainerData) <> 0 then
  begin
    if Length(TrainerData) < 4 then
      raise ENesException.Create('Invalid Game Doctor trainer header');
    FTrainerAddress := TrainerData[0] or (UInt16(TrainerData[1]) shl 8);
    FTrainerEntry := TrainerData[2] or (UInt16(TrainerData[3]) shl 8);
    SetLength(FTrainer, Length(TrainerData) - 4);
    if Length(FTrainer) <> 0 then
      Move(TrainerData[4], FTrainer[0], Length(FTrainer));
    var LastAddress := Integer(FTrainerAddress) + Length(FTrainer);
    if (LastAddress > $10000) or
      ((Length(FTrainer) <> 0) and (FTrainerAddress < $6000) and (LastAddress > $2000)) then
      raise ENesException.Create('Game Doctor trainer must fit in CPU RAM');
    if FTrainerEntry <> 0 then
    begin
      // Keep the JSR stub and its instruction operands outside trainer data,
      // accounting for the four mirrors of the CPU's internal RAM.
      for var Page := 7 downto 2 do
      begin
        var Address := Page shl 8;
        var Overlaps := False;
        if (Length(FTrainer) <> 0) and (FTrainerAddress < $2000) then
          for var MirrorBase := 0 to 3 do
            if (Address + MirrorBase * $800 < LastAddress) and
              (Address + MirrorBase * $800 + 6 > FTrainerAddress) then
              Overlaps := True;
        if not Overlaps then
        begin
          FBootstrap := Address;
          Break;
        end;
      end;
      if FBootstrap = 0 then
        raise ENesException.Create('Game Doctor trainer leaves no room for the startup routine');
    end;
  end;
  ConfigureMedia(0, nil, nil);
  PowerOn;
end;

procedure TMapperGameDoctor.ConfigureMedia(ChrRamSize: UInt64; const StandardTrainer, Bios: TByteArray);
begin
  if FTurbo and (ChrRamSize > $40000) then
    raise ENesException.Create('Invalid Turbo Game Doctor CHR RAM size');
  if FTurbo and (ChrRamSize > $8000) then
    SetLength(FChrMemory, $40000)
  else if Length(FChrImage) > $8000 then
    SetLength(FChrMemory, $40000)
  else
    SetLength(FChrMemory, $8000);
  if Length(FChrImage) > 0 then
    Move(FChrImage[0], FChrMemory[0], Length(FChrImage));
  if Length(StandardTrainer) <> 0 then
  begin
    FTrainer := Copy(StandardTrainer);
    FTrainerAddress := $7000;
  end;
  FBios := Bios;
end;

function TMapperGameDoctor.InstallStartup(WriteBus: TGameDoctorBusWrite): UInt16;
begin
  // The copier BIOS starts the game with the APU frame IRQ inhibited.
  WriteBus($4017, $40);
  for var i := 0 to High(FTrainer) do
  begin
    var Address := FTrainerAddress + i;
    if Address >= $8000 then
      FPrgRom[PrgOffset(Address)] := FTrainer[i]
    else
      WriteBus(Address, FTrainer[i]);
  end;

  Result := FBootstrap;
  if Result = 0 then
    Exit;
  // JSR trainer entry; JMP ($FFFC) using the mapping left by the trainer.
  WriteBus(Result, $20);
  WriteBus(Result + 1, Lo(FTrainerEntry));
  WriteBus(Result + 2, Hi(FTrainerEntry));
  WriteBus(Result + 3, $6C);
  WriteBus(Result + 4, $FC);
  WriteBus(Result + 5, $FF);
end;

procedure TMapperGameDoctor.PowerOn;
begin
  Move(FPrgImage[0], FPrgRom[0], Length(FPrgRom));
  FillChar(FChrMemory[0], Length(FChrMemory), 0);
  if Length(FChrImage) <> 0 then
    Move(FChrImage[0], FChrMemory[0], Length(FChrImage));
  FMode := FInitialMode;
  FExpandedMode := 3;
  FTurboMode := 3;
  FLatch := 0;
  FChrBank := 0;
  FLastChrSlot := 0;
  FChrLocked := False;
  for var i := 0 to High(FPrgRegisters) do
    FPrgRegisters[i] := $1C + i;
  for var i := 0 to High(FChrRegisters) do
    FChrRegisters[i] := i;
  MapBanks;
  Reset;
end;

procedure TMapperGameDoctor.Reset;
begin
  FDiskControl := 0;
  FDiskPhase := 0;
  FDiskIrq := False;
  FIrqCounter := 0;
  if FTurbo then
    FIrqCounter := $8000;
  FIrqTarget := 0;
  FCounterEnabled := False;
  FIrq := False;
end;

procedure TMapperGameDoctor.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRom[0], Length(FPrgRom));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FExpandedMode, SizeOf(FExpandedMode));
  State.Field(FTurboMode, SizeOf(FTurboMode));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FChrBank, SizeOf(FChrBank));
  State.Field(FPrgRegisters, SizeOf(FPrgRegisters));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FLastChrSlot, SizeOf(FLastChrSlot));
  State.Field(FChrLocked, SizeOf(FChrLocked));
  State.Field(FDiskControl, SizeOf(FDiskControl));
  State.Field(FDiskPhase, SizeOf(FDiskPhase));
  State.Field(FDiskIrq, SizeOf(FDiskIrq));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqTarget, SizeOf(FIrqTarget));
  State.Field(FCounterEnabled, SizeOf(FCounterEnabled));
  State.Field(FIrq, SizeOf(FIrq));
end;

function TMapperGameDoctor.ExpandedPrg: Boolean;
begin
  Result := (FExpandedMode and 1) = 0;
end;

function TMapperGameDoctor.FullPrg: Boolean;
begin
  if FTurbo then
    Result := (FTurboMode and $80) <> 0
  else
    Result := ExpandedPrg;
end;

procedure TMapperGameDoctor.MapBanks;
begin
  if FullPrg then
    for var Slot := 0 to High(FPrgRegisters) do
      Prg8(Slot, FPrgRegisters[Slot])
  else if ExpandedPrg then
  begin
    var HighBank := (FExpandedMode and $40) shr 2;
    Prg8(0, (FPrgRegisters[0] and $0F) or HighBank);
    Prg8(1, (FPrgRegisters[1] and $0F) or HighBank);
    Prg8(2, FPrgRegisters[2] and $0F);
    Prg8(3, FPrgRegisters[3] and $0F);
  end
  else
    case FMode shr 5 of
      0:
        begin
          Prg16(0, FLatch and 7);
          Prg16(1, 7);
        end;
      1:
        begin
          Prg16(0, (FLatch shr 2) and $0F);
          Prg16(1, 7);
        end;
      2:
        begin
          Prg16(0, FLatch and $0F);
          Prg16(1, 15);
        end;
      3:
        begin
          Prg16(0, 15);
          Prg16(1, FLatch and $0F);
        end;
      4:
        Prg32((FLatch shr 4) and 3);
      5:
        Prg32(3);
      6:
        begin
          Prg8(0, FLatch and $0F);
          Prg8(1, FLatch shr 4);
          Prg16(1, 7);
        end;
      7:
        begin
          Prg8(0, FLatch and $0E);
          Prg8(1, (FLatch shr 4) or 1);
          Prg16(1, 7);
        end;
    end;

  if FTurbo and ((FTurboMode and $40) <> 0) then
    for var Slot := 0 to High(FChrRegisters) do
      Chr1(Slot, FChrRegisters[Slot])
  else
    Chr8(FChrBank);

  case FMode and $11 of
    $00:
      Mirror(2);
    $01:
      Mirror(0);
    $10:
      Mirror(3);
    $11:
      Mirror(1);
  end;
end;

function TMapperGameDoctor.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FTurbo then
  begin
    case Address of
      $4400..$4407:
        Value := FChrRegisters[Address and 7];
      $4408..$440B:
        Value := (FPrgRegisters[Address and 3] shl 2) or (FLatch and 3);
      $440C:
        Value := FIrqCounter shr 8;
      $440D:
        Value := FIrqCounter and $FF;
      $4411:
        Value := FTurboMode;
      $4415:
        Value := FMode;
      $4420:
        Value := FChrRegisters[FLastChrSlot];
      $4800..$4FFF:
        begin
          if Length(FBios) = 0 then
            Exit(False);
          Value := FBios[Address and $7FF];
        end;
    else
      Exit(inherited CpuRead(Address, Value));
    end;
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperGameDoctor.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $4024:
      FDiskIrq := False;
    $4025:
      begin
        FDiskIrq := False;
        FDiskControl := Value;
        if (Value and $42) <> 0 then
          FDiskPhase := 0;
      end;
    $42FC..$42FF:
      begin
        FMode := (Value and $F0) or (Address and 3);
        if (FMode shr 5) >= 4 then
          FChrLocked := False;
        MapBanks;
      end;
    $43FC..$43FF:
      begin
        FExpandedMode := (Value and $40) or (Address and 1);
        FChrBank := Value and 3;
        MapBanks;
      end;
    $8000..$FFFF:
      if (FMode and 2) = 0 then
        FPrgRom[PrgOffset(Address)] := Value
      else
      begin
        FLatch := Value;
        FPrgRegisters[(Address shr 13) and 3] := Value shr 2;
        if FullPrg or ExpandedPrg then
          FChrBank := Value and 3
        else
          case FMode shr 5 of
            1, 4, 5:
              FChrBank := Value and 3;
            3:
              FChrBank := (Value shr 4) and 3;
          end;
        MapBanks;
      end;
  else
    if FTurbo then
      case Address of
        $4400..$4407:
          begin
            FChrRegisters[Address and 7] := Value;
            MapBanks;
          end;
        $440C:
          begin
            FIrq := False;
            FIrqTarget := (FIrqTarget and $FF) or (Integer(Value) shl 8);
            FCounterEnabled := (Value and $80) <> 0;
            if not FCounterEnabled then
              FIrqCounter := $8000;
          end;
        $440D:
          begin
            FIrq := False;
            FIrqTarget := (FIrqTarget and $FF00) or Value;
          end;
        $4411:
          begin
            FTurboMode := Value;
            MapBanks;
          end;
      else
        Exit(inherited CpuWrite(Address, Value));
      end
    else
      case Address of
        $4100:
          FIrqCounter := (FIrqCounter and $FF00) or Value;
        $4101:
          begin
            FIrqCounter := (FIrqCounter and $FF) or (Integer(Value) shl 8);
            FCounterEnabled := Value <> 0;
            if not FCounterEnabled then
              FIrq := False;
          end;
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
  end;
  Result := True;
end;

function TMapperGameDoctor.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  var Mode := FMode shr 5;
  if FTurbo and (Mode >= 5) and ((FMode and 1) = 0) then
    FChrLocked := (FMode and $10) <> 0;
  if (Mode >= 4) or FChrLocked then
    Exit(True);
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperGameDoctor.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if (Address < $2000) and FTurbo then
    FLastChrSlot := Address shr 10;
end;

procedure TMapperGameDoctor.ClockCpu;
begin
  // 1792 NTSC master clocks correspond to 149 1/3 CPU clocks.
  Inc(FDiskPhase, 3);
  if FDiskPhase >= 448 then
  begin
    Dec(FDiskPhase, 448);
    if (FDiskControl and $80) <> 0 then
      FDiskIrq := True;
  end;

  if not FCounterEnabled then
    Exit;
  if FTurbo then
  begin
    if FIrqCounter < $FFFF then
    begin
      Inc(FIrqCounter);
      if FIrqCounter = FIrqTarget then
        FIrq := True;
    end;
  end
  else
  begin
    FIrqCounter := (FIrqCounter + 1) and $FFFF;
    if FIrqCounter = 0 then
      FIrq := True;
  end;
end;

function TMapperGameDoctor.IrqPending: Boolean;
begin
  Result := FIrq or FDiskIrq;
end;

end.

