unit NES.Mapper.MagicCard;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, NES.Mapper.GameDoctor;

const
  MAGIC_CARD_STATE_VERSION = 43;

type
  TMapperMagicCard = class(TMapperBanked)
  private
    FMapperId, FSubmapper: Integer;
    FInitialMode, FMode, FPrgMode, FControl, FLatch: Byte;
    FPrgRegisters: array[0..3] of Byte;
    FChrRegisters: array[0..11] of Byte;
    FMmc4Latch: array[0..1] of Byte;
    FScratch: array[0..$FFF] of Byte;
    FPrgImage, FChrImage, FTrainer: TByteArray;
    FTrainerAddress, FStartup: UInt16;
    FFirstPrgBank: Integer;
    FImagePrgSize: Integer;
    FLegacyChr: TByteArray;
    FCounter: UInt16;
    FEnabled, FPending, FA12, FDiskIrq: Boolean;
    FDiskControl: Byte;
    FDiskPhase, FMasterClocks: Integer;
    function WorkRamOffset(Address: UInt16): Integer;
    function NameTableChrOffset(Address: UInt16): Integer;
    function Mmc4Mode: Boolean;
    function ReadVram(Address: UInt16; out Value: UInt8): Boolean;
    procedure MapPrg;
    procedure MapChr;
    procedure MapCiram;
    procedure InstallTrainer;
    procedure TickIrq;
    procedure LoadFormerCardState(State: TNesStateArchive);
  public
    constructor Create(MapperId, Submapper: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    procedure ConfigureTrainer(const Data: TByteArray);
    function InstallStartup(WriteBus: TGameDoctorBusWrite): UInt16;
    procedure LoadLegacyState(State: TNesStateArchive; LegacyMapper: Integer);
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure CpuIoWrite(Address: UInt16; Value: UInt8); override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean = False): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure Reset; override;
    procedure PowerOn; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
  end;

implementation

uses
  NES.Mapper.Discrete, NES.Mapper.ExtendedIrq, NES.Mapper.Mmc3,
  NES.Mapper.Mmc3Variants;

type
  TFormerBankedMapper = class(TMapperBanked);

  TFormerMmc3Mapper = class(TMapperMmc3);

constructor TMapperMagicCard.Create(MapperId, Submapper: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  if (Length(Prg) < $4000) or (Length(Prg) > $80000) or ((Length(Prg) and $1FFF) <> 0) then
    raise ENesException.Create('Invalid Magic Card PRG size');
  if (MapperId = MAPPER_FFE_F4XXX) and ((Submapper < 0) or (Submapper > 7)) then
    raise ENesException.Create('Invalid Magic Card banking mode');
  if (MapperId = MAPPER_FFE_F8XXX) and ((Submapper < 0) or (Submapper > 3)) then
    raise ENesException.Create('Invalid Super Magic Card trainer address');

  var MaxChr := $8000;
  if MapperId in [MAPPER_MMC3_12, MAPPER_FFE_F8XXX] then
    MaxChr := $40000;
  if (Length(Chr) > MaxChr) or
    ((MapperId = MAPPER_MMC3_12) and (Length(Chr) > 0) and (Length(Prg) > $40000)) then
    raise ENesException.Create('Invalid Magic Card PRG and CHR layout');

  inherited Create(Prg, Chr, True, MirrorMode);
  FMapperId := MapperId;
  FSubmapper := Submapper;
  FImagePrgSize := Length(Prg);
  FFirstPrgBank := FImagePrgSize div $2000 - 4;
  if FFirstPrgBank < 0 then
    FFirstPrgBank := 0;
  FInitialMode := $23;
  case FMapperId of
    MAPPER_FFE_F4XXX:
      FInitialMode := (Submapper shl 5) or 3;
    MAPPER_FFE_F3XXX:
      FInitialMode := $83;
  end;
  case MirrorMode of
    TMirrorMode.Horizontal:
      FInitialMode := FInitialMode or $10;
    TMirrorMode.Single0:
      FInitialMode := FInitialMode and $EE;
    TMirrorMode.Single1:
      FInitialMode := (FInitialMode and $FE) or $10;
  end;

  if FMapperId = MAPPER_MMC3_12 then
  begin
    // The 4M loader puts pattern data in the upper half of the PRG DRAM.
    FLegacyChr := Copy(Chr);
    SetLength(FPrgRom, $80000);
    if Length(Chr) > 0 then
      Move(Chr[0], FPrgRom[$40000], Length(Chr));
    SetLength(FChrMemory, $8000);
  end
  else
  begin
    FChrImage := Copy(Chr);
    SetLength(FChrMemory, MaxChr);
  end;
  SetLength(FPrgRam, $8000);
  FPrgImage := Copy(FPrgRom);
  FMasterClocks := 12;
  PowerOn;
end;

procedure TMapperMagicCard.ConfigureTrainer(const Data: TByteArray);
begin
  if Length(Data) = 0 then
    Exit;
  if Length(Data) <> $200 then
    raise ENesException.Create('Magic Card trainer must contain 512 bytes');

  FTrainer := Copy(Data);
  FTrainerAddress := $7000;
  FStartup := $5FF0;
  if FMapperId = MAPPER_FFE_F8XXX then
  begin
    if FSubmapper <> 0 then
      FTrainerAddress := $5C00 + FSubmapper * $100;
    FStartup := FTrainerAddress;
  end;
  InstallTrainer;
end;

procedure TMapperMagicCard.InstallTrainer;
begin
  for var I := 0 to High(FTrainer) do
    CpuWrite(FTrainerAddress + I, FTrainer[I]);
  if (FStartup <> 0) and (FMapperId <> MAPPER_FFE_F8XXX) then
  begin
    // JSR $7003, followed by an indirect jump through the game's reset vector.
    FScratch[$FF0] := $20;
    FScratch[$FF1] := $03;
    FScratch[$FF2] := $70;
    FScratch[$FF3] := $6C;
    FScratch[$FF4] := $FC;
    FScratch[$FF5] := $FF;
  end;
end;

function TMapperMagicCard.InstallStartup(WriteBus: TGameDoctorBusWrite): UInt16;
begin
  WriteBus($4017, $40);
  Result := FStartup;
end;

procedure TMapperMagicCard.PowerOn;
begin
  Move(FPrgImage[0], FPrgRom[0], Length(FPrgRom));
  FillChar(FPrgRam[0], Length(FPrgRam), 0);
  FillChar(FChrMemory[0], Length(FChrMemory), 0);
  if Length(FChrImage) > 0 then
    Move(FChrImage[0], FChrMemory[0], Length(FChrImage));
  FillChar(FScratch, SizeOf(FScratch), 0);
  FMode := FInitialMode;
  FPrgMode := 3;
  FControl := $42;
  if FMapperId in [MAPPER_MMC3_12, MAPPER_FFE_F8XXX] then
    FPrgMode := 0;
  if FMapperId = MAPPER_FFE_F8XXX then
    FControl := $47;
  FLatch := 0;
  for var I := 0 to High(FPrgRegisters) do
    FPrgRegisters[I] := FFirstPrgBank + I;
  for var I := 0 to High(FChrRegisters) do
    FChrRegisters[I] := I;
  FillChar(FMmc4Latch, SizeOf(FMmc4Latch), 0);
  MapPrg;
  MapChr;
  MapCiram;
  Reset;
  InstallTrainer;
end;

procedure TMapperMagicCard.Reset;
begin
  FCounter := 0;
  FEnabled := False;
  FPending := False;
  FA12 := False;
  FDiskIrq := False;
  FDiskControl := 0;
  FDiskPhase := 0;
end;

procedure TMapperMagicCard.SetRegion(Region: TNesRegion);
begin
  case Region of
    TNesRegion.NTSC:
      FMasterClocks := 12;
    TNesRegion.PAL:
      FMasterClocks := 16;
    TNesRegion.Dendy:
      FMasterClocks := 15;
  end;
end;

function TMapperMagicCard.WorkRamOffset(Address: UInt16): Integer;
begin
  Result := ((FControl and $30) shl 9) or (Address and $1FFF);
end;

function TMapperMagicCard.NameTableChrOffset(Address: UInt16): Integer;
begin
  var Page := FChrRegisters[8 + ((Address shr 10) and 3)];
  Result := ((Integer(Page) shl 10) or (Address and $3FF)) and (Length(FChrMemory) - 1);
end;

function TMapperMagicCard.Mmc4Mode: Boolean;
begin
  Result := (FControl and 5) = 1;
end;

procedure TMapperMagicCard.MapPrg;
begin
  if (FPrgMode and 1) = 0 then
  begin
    for var Slot := 0 to High(FPrgRegisters) do
      Prg8(Slot, FPrgRegisters[Slot]);
    Exit;
  end;

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
  else
    Prg32(3);
  end;
end;

procedure TMapperMagicCard.MapChr;
begin
  if Mmc4Mode then
  begin
    Chr4(0, FChrRegisters[FMmc4Latch[0] and 2] shr 2);
    Chr4(1, FChrRegisters[4 + (FMmc4Latch[1] and 2)] shr 2);
    Exit;
  end;
  if (FControl and 1) <> 0 then
  begin
    for var Slot := 0 to 7 do
      Chr1(Slot, FChrRegisters[Slot]);
    Exit;
  end;

  var Bank := 0;
  if (FPrgMode and 1) = 0 then
    Bank := FLatch and 3
  else
    case FMode shr 5 of
      1, 4, 5:
        Bank := FLatch and 3;
      3:
        Bank := (FLatch shr 4) and 3;
      6:
        Bank := FLatch and 1;
    end;
  Chr8(Bank);
end;

procedure TMapperMagicCard.MapCiram;
begin
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

function TMapperMagicCard.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address of
    $4500:
      Value := $40 or ((FMode and $F0) shr 2) or (FMode and 3);
    $4501:
      Value := (FLatch and $FC) or FPrgMode;
    $5000..$5FFF:
      Value := FScratch[Address and $FFF];
    $6000..$7FFF:
      Value := FPrgRam[WorkRamOffset(Address)];
  else
    Exit(inherited CpuRead(Address, Value));
  end;
  Result := True;
end;

function TMapperMagicCard.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $4500) and (Address <= $451F) then
    FScratch[Address and $FFF] := Value;
  case Address of
    $4024:
      FDiskIrq := False;
    $4025:
      begin
        if ((Value xor FDiskControl) and $80) <> 0 then
          FDiskPhase := 0;
        FDiskControl := Value;
        FDiskIrq := False;
      end;
    $42FC..$42FF:
      begin
        FMode := (Value and $F0) or (Address and 3);
        MapPrg;
        MapChr;
        MapCiram;
      end;
    $43FC..$43FF:
      begin
        FPrgMode := Address and 3;
        FLatch := (FLatch and $FC) or (Value and 3);
        MapPrg;
        MapChr;
      end;
    $4500:
      begin
        FControl := Value;
        MapChr;
      end;
    $4501:
      begin
        FEnabled := False;
        FPending := False;
      end;
    $4502:
      begin
        FCounter := (FCounter and $FF00) or Value;
        FPending := False;
      end;
    $4503:
      begin
        FCounter := (FCounter and $FF) or (UInt16(Value) shl 8);
        FEnabled := True;
        FPending := False;
      end;
    $4504..$4507:
      begin
        var Slot := Address and 3;
        if FPrgMode = 0 then
          FPrgRegisters[Slot] := Value and $3F
        else
          FPrgRegisters[Slot] := Value shr 2;
        if (FPrgMode and 1) = 0 then
          Prg8(Slot, FPrgRegisters[Slot]);
      end;
    $4510..$451B:
      begin
        var Slot := Address - $4510;
        FChrRegisters[Slot] := Value;
        if (Slot < 8) and ((FControl and 1) <> 0) then
          if Mmc4Mode then
            MapChr
          else
            Chr1(Slot, Value);
      end;
    $5000..$5FFF:
      FScratch[Address and $FFF] := Value;
    $6000..$7FFF:
      FPrgRam[WorkRamOffset(Address)] := Value;
    $8000..$FFFF:
      if (FMode and 2) = 0 then
        FPrgRom[PrgOffset(Address)] := Value
      else
      begin
        var Slot := (Address shr 13) and 3;
        FLatch := Value;
        if FPrgMode <> 0 then
        begin
          FPrgRegisters[Slot] := Value shr 2;
          if FPrgMode = 2 then
            Prg8(Slot, FPrgRegisters[Slot])
          else if (FMode shr 5) < 5 then
            MapPrg;
        end;
        if (FControl and 1) = 0 then
          MapChr;
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure TMapperMagicCard.CpuIoWrite(Address: UInt16; Value: UInt8);
begin
  case Address of
    $2000..$3FFF:
      FScratch[$800 + (Address and 7)] := Value;
    $4000..$4015:
      FScratch[Address and $1F] := Value;
  end;
end;

function TMapperMagicCard.ReadVram(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) and ((FControl and 2) = 0) then
  begin
    Value := FChrMemory[NameTableChrOffset(Address)];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperMagicCard.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := ReadVram(Address, Value);
  if (Address >= $2000) or not Mmc4Mode then
    Exit;
  case Address and $0FF8 of
    $0FD8, $0FE8:
      ;
  else
    Exit;
  end;
  var Half := Address shr 12;
  var Selection := (Address shr 4) and 2;
  if FMmc4Latch[Half] <> Selection then
  begin
    FMmc4Latch[Half] := Selection;
    Chr4(Half, FChrRegisters[4 * Half + Selection] shr 2);
  end;
end;

function TMapperMagicCard.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := ReadVram(Address, Value);
end;

function TMapperMagicCard.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $3F00 then
    Exit(False);
  if Address >= $2000 then
  begin
    Result := (FControl and 2) = 0;
    if Result then
      FChrMemory[NameTableChrOffset(Address)] := Value;
    Exit;
  end;
  if (FMode shr 5) >= 4 then
    Exit(True);
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperMagicCard.TickIrq;
begin
  if FEnabled then
  begin
    FCounter := (Integer(FCounter) + 1) and $FFFF;
    if FCounter = 0 then
      FPending := True;
  end;
end;

procedure TMapperMagicCard.ClockCpu;
begin
  if (FDiskControl and $80) <> 0 then
  begin
    Inc(FDiskPhase, FMasterClocks);
    if FDiskPhase >= 1792 then
    begin
      Dec(FDiskPhase, 1792);
      FDiskIrq := True;
    end;
  end;
  if (FControl and 8) = 0 then
    TickIrq;
end;

procedure TMapperMagicCard.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  var A12 := (Address and $1000) <> 0;
  if ((FControl and 8) <> 0) and A12 and not FA12 then
    TickIrq;
  FA12 := A12;
end;

function TMapperMagicCard.IrqPending: Boolean;
begin
  Result := FPending or FDiskIrq;
end;

function TMapperMagicCard.GetSaveMemory: TByteArray;
begin
  Result := nil;
end;

procedure TMapperMagicCard.SerializeState(State: TNesStateArchive);
begin
  if State.Version < MAGIC_CARD_STATE_VERSION then
  begin
    if not State.Loading then
      raise ENesException.Create('Magic Card requires snapshot version 43 or later');
    LoadFormerCardState(State);
    Exit;
  end;
  inherited;
  State.Field(FPrgRom[0], Length(FPrgRom));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FPrgMode, SizeOf(FPrgMode));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FPrgRegisters, SizeOf(FPrgRegisters));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FMmc4Latch, SizeOf(FMmc4Latch));
  State.Field(FScratch, SizeOf(FScratch));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FA12, SizeOf(FA12));
  State.Field(FDiskIrq, SizeOf(FDiskIrq));
  State.Field(FDiskControl, SizeOf(FDiskControl));
  State.Field(FDiskPhase, SizeOf(FDiskPhase));
  if State.Loading then
  begin
    MapPrg;
    MapChr;
    MapCiram;
  end;
end;

procedure TMapperMagicCard.LoadFormerCardState(State: TNesStateArchive);
begin
  // Restore the mapped windows from snapshots made with the generic mapper.
  // Their layouts never stored the Magic Card mode and write-control registers.
  PowerOn;
  var Previous: TMapper;
  var OldPrg := Copy(FPrgImage, 0, FImagePrgSize);
  var OldChr := FChrImage;
  case FMapperId of
    MAPPER_FFE_F3XXX:
      Previous := TMapperDiscrete.Create(FMapperId, OldPrg, OldChr, Length(OldChr) = 0, FInitialMirror, True);
    MAPPER_MMC3_12:
      begin
        OldChr := FLegacyChr;
        Previous := TMapperMmc3Variant.Create(FMapperId, OldPrg, OldChr, Length(OldChr) = 0, FInitialMirror);
      end;
  else
    Previous := TMapperExtendedIrq.Create(FMapperId, OldPrg, OldChr, Length(OldChr) = 0, FInitialMirror, FSubmapper);
  end;

  try
    Previous.SerializeState(State);
    var Counter: Integer := 0;
    var WorkRam := Previous.GetSaveMemory;
    Move(WorkRam[0], FPrgRam[0], Length(WorkRam));
    case Previous.GetMirrorMode of
      TMirrorMode.Single0:
        FMode := FMode and $EE;
      TMirrorMode.Single1:
        FMode := (FMode and $EE) or $10;
      TMirrorMode.Vertical:
        FMode := (FMode and $EE) or 1;
      TMirrorMode.Horizontal:
        FMode := FMode or $11;
    end;
    if Previous is TMapperBanked then
    begin
      var Banked := TFormerBankedMapper(Previous);
      Move(Banked.FChrMemory[0], FChrMemory[0], Length(Banked.FChrMemory));
      for var Slot := 0 to 3 do
        FPrgRegisters[Slot] := Banked.FPrgBanks[Slot];
      for var Slot := 0 to 7 do
        FChrRegisters[Slot] := Banked.FChrBanks[Slot] mod (Length(Banked.FChrMemory) div $400);
      if Previous is TMapperExtendedIrq then
        TMapperExtendedIrq(Previous).ReadFormerIrq(Counter, FEnabled, FPending)
      else
        TMapperDiscrete(Previous).ReadFormerIrq(Counter, FEnabled, FPending);
    end
    else
    begin
      var Mmc3 := TFormerMmc3Mapper(Previous);
      if Length(OldChr) = 0 then
        Move(Mmc3.FChrMemory[0], FChrMemory[0], Length(Mmc3.FChrMemory));
      for var Slot := 0 to 3 do
        FPrgRegisters[Slot] := Mmc3.PrgRegisterBank(Slot) mod (FImagePrgSize div $2000);
      for var Slot := 0 to 7 do
        FChrRegisters[Slot] := Mmc3.GetChrOffset(Slot * $400) shr 10;
      FPending := Previous.IrqPending;
    end;
    FCounter := Counter and $FFFF;
    case FMode shr 5 of
      0, 2:
        FLatch := FPrgRegisters[0] shr 1;
      1:
        FLatch := ((FPrgRegisters[0] shr 1) shl 2) or (FChrRegisters[0] shr 3);
      3:
        FLatch := (FPrgRegisters[2] shr 1) or ((FChrRegisters[0] shr 3) shl 4);
      4:
        FLatch := ((FPrgRegisters[0] shr 2) shl 4) or (FChrRegisters[0] shr 3);
      5, 6:
        FLatch := FChrRegisters[0] shr 3;
    end;
    MapPrg;
    for var Slot := 0 to 3 do
      if FPrgBanks[Slot] <> FPrgRegisters[Slot] then
      begin
        FPrgMode := 0;
        MapPrg;
        Break;
      end;
    MapChr;
    for var Slot := 0 to 7 do
      if FChrBanks[Slot] <> FChrRegisters[Slot] then
      begin
        FControl := FControl or 5;
        MapChr;
        Break;
      end;
    MapCiram;
  finally
    Previous.Free;
  end;
end;

procedure TMapperMagicCard.LoadLegacyState(State: TNesStateArchive; LegacyMapper: Integer);
begin
  var Bank: Byte;
  var ChrRam: Boolean;
  var FormerMirror: TMirrorMode;
  // Old CNROM and UxROM snapshots have fixed-size state layouts here.
  PowerOn;
  if LegacyMapper = MAPPER_CNROM then
  begin
    State.Field(FChrMemory[0], Length(FChrImage));
    State.Field(ChrRam, SizeOf(ChrRam));
    State.Field(FormerMirror, SizeOf(FormerMirror));
    State.Field(Bank, SizeOf(Bank));
    if State.Version >= 6 then
      State.Field(FPrgRam[0], $2000);
    FLatch := Bank and 1;
  end
  else
  begin
    if Length(FChrImage) = 0 then
      State.Field(FChrMemory[0], $2000);
    State.Field(FPrgRam[0], $2000);
    State.Field(ChrRam, SizeOf(ChrRam));
    State.Field(FormerMirror, SizeOf(FormerMirror));
    State.Field(Bank, SizeOf(Bank));
    FLatch := Bank and $0F;
  end;
  MapPrg;
  MapChr;
end;

end.

