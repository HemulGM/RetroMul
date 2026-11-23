unit NES.Mapper.Flash;

interface

uses
  System.Classes, System.SysUtils, Audio.Types, Core.Storage, NES.State,
  NES.Types, NES.Mapper, NES.Mapper.Banked, NES.Mapper.Mmc3;

type
  TMapperFlash = class(TMapperBanked)
  private
    FBoard, FSubmapper, FBank, FFlashStep, FFlashMode, FRegister: Integer;
    FBattery, FSoftwareId: Boolean;
    FNameRam: array[0..$3FFF] of Byte;
    procedure Update(Value: Byte);
    procedure WriteFlash(Offset: Integer; Value: Byte);
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer; Battery: Boolean);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperRainbow512 = class(TMapperFlash)
  private
    FEspFlags: Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Battery: Boolean);
    procedure ConfigureChrRam(Size: UInt64);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperImpactFlash = class(TMapperMmc3)
  private
    FSubmapper, FFlashStep, FFlashMode: Integer;
    FSoftwareId: Boolean;
    function FlashOffset(Address: UInt16): Integer; inline;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperHaratyler = class(TMapperMmc3)
  private
    FBank: Byte;
    FFrequency: Cardinal;
    FFlashStep, FEraseMask: Byte;
    FFlashId, FToggle, FProgramError, FEraseSuspended, FChipErase: Boolean;
    FProgramTicks, FProgramOffset, FEraseTicks, FEraseSelectTicks: Integer;
    FProgramData: Byte;
    function FlashOffset(Address: UInt16): Integer;
    function ReadFlash(Offset: Integer): Byte;
    procedure WriteFlash(Offset: Integer; Value: Byte);
    function FlashTicks(Microseconds: Integer): Integer;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperHaratylerMp = class(TMapperHaratyler)
  private
    const
      BitCycles = 1000;
      PcmBlockFrames = 1024;
  private
    FStorage: IStorage;
    FAudioFolder: string;
    FBitTicks: Word;
    FSlot, FCommand, FVolume, FEq, FFolder: Byte;
    FSource: IAudioSource;
    FFormat: TAudioFormat;
    FTrack, FTrackFolder: Byte;
    FPcm: array[0..PcmBlockFrames * 2 - 1] of SmallInt;
    FPcmOffset, FPcmCount: Integer;
    FNextFrame, FPcmStart: Int64;
    FPhase: Cardinal;
    FLow, FHighCut, FSample, FLowAlpha, FHighAlpha, FGain: Double;
    procedure ExecuteCommand;
    procedure ResetPlayer;
    procedure UpdateGain;
    procedure StopTrack;
    function OpenTrack(Folder, Track: Byte): Boolean;
    procedure AdvanceSample;
    function QueryByte: Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; const AudioFolder: string; const Storage: IStorage);
    procedure Reset; override;
    procedure ClockCpu; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function ExpansionAudio: Double; override;
  end;

procedure WriteNorFlash(var Image: TByteArray; Offset, SectorSize: Integer; Value: Byte; var Step, Mode: Integer; var SoftwareId: Boolean; AddressMask: Integer = $7FFF);

implementation

uses
  System.IOUtils, System.Math, Audio.MP3.Source, NES.Consts;

constructor TMapperFlash.Create(Board: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer; Battery: Boolean);
begin
  inherited Create(Prg, Chr, True, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FBattery := Battery;
  if (Board = MAPPER_GTROM) or (Board = MAPPER_4MROM512) then
    SetLength(FChrMemory, $4000)
  else
    SetLength(FChrMemory, $8000);
  Reset;
end;

procedure TMapperFlash.Reset;
begin
  inherited;
  FRamEnabled := FBoard = MAPPER_4MROM512;
  FFlashStep := 0;
  FFlashMode := 0;
  FSoftwareId := False;
  Update(0);
end;

procedure TMapperFlash.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBank, SizeOf(FBank));
  State.Field(FFlashStep, SizeOf(FFlashStep));
  State.Field(FFlashMode, SizeOf(FFlashMode));
  State.Field(FRegister, SizeOf(FRegister));
  State.Field(FSoftwareId, SizeOf(FSoftwareId));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FPrgRom[0], Length(FPrgRom));
end;

procedure TMapperFlash.Update(Value: Byte);
begin
  FRegister := Value;
  if FBoard = MAPPER_4MROM512 then
  begin
    FBank := Value and 31;
    Prg16(0, FBank);
    Prg16(1, -1);
    Chr8(0);
    FMirror := TMirrorMode.FourScreen;
  end
  else if FBoard = MAPPER_GTROM then
  begin
    FBank := Value and 15;
    Prg32(FBank);
    Chr8((Value shr 4) and 1)
  end
  else
  begin
    FBank := Value and 31;
    Prg16(0, FBank);
    Prg16(1, -1);
    Chr8((Value shr 5) and 3);
    if FSubmapper = 3 then
      Mirror(1 - ((Value shr 7) and 1))
    else if (FInitialMirror = TMirrorMode.Single0) or (FInitialMirror = TMirrorMode.Single1) then
      Mirror(2 + (Value shr 7));
  end;
end;

procedure WriteNorFlash(var Image: TByteArray; Offset, SectorSize: Integer; Value: Byte; var Step, Mode: Integer; var SoftwareId: Boolean; AddressMask: Integer);
var
  Command, Unlock1, Unlock2: Integer;
begin
  Command := Offset and AddressMask;
  Unlock1 := $5555 and AddressMask;
  Unlock2 := $2AAA and AddressMask;
  if Mode = 1 then
  begin
    Image[Offset mod Length(Image)] := Image[Offset mod Length(Image)] and Value;
    Mode := 0;
    Step := 0;
    Exit
  end;

  if Step = 0 then
  begin
    if (Command = Unlock1) and (Value = $AA) then
      Step := 1
    else if Value = $F0 then
    begin
      SoftwareId := False;
      Mode := 0
    end;
  end
  else if Step = 1 then
    if (Command = Unlock2) and (Value = $55) then
      Step := 2
    else
      Step := 0
  else if Step = 2 then
  begin
    Step := 0;
    if Command = Unlock1 then
      case Value of
        $80:
          begin
            Mode := 2;
            Step := 3
          end;
        $90:
          SoftwareId := True;
        $A0:
          Mode := 1;
        $F0:
          SoftwareId := False;
      end;
  end
  else if Step = 3 then
    if (Command = Unlock1) and (Value = $AA) then
      Step := 4
    else
    begin
      Step := 0;
      Mode := 0
    end
  else if Step = 4 then
    if (Command = Unlock2) and (Value = $55) then
      Step := 5
    else
    begin
      Step := 0;
      Mode := 0
    end
  else
  begin
    if (Command = Unlock1) and (Value = $10) then
      FillChar(Image[0], Length(Image), $FF)
    else if Value = $30 then
    begin
      var Base := (Offset and ($80000 - SectorSize)) mod Length(Image);
      if Base + SectorSize <= Length(Image) then
        FillChar(Image[Base], SectorSize, $FF)
    end;
    Step := 0;
    Mode := 0;
  end;
end;

procedure TMapperFlash.WriteFlash(Offset: Integer; Value: Byte);
begin
  WriteNorFlash(FPrgRom, Offset, $1000, Value, FFlashStep, FFlashMode, FSoftwareId);
end;

function TMapperFlash.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_GTROM) and (((Address >= $5000) and (Address < $6000)) or ((Address >= $7000) and (Address < $8000))) then
  begin
    Update(FCpuOpenBus);
    Value := FCpuOpenBus;
    Exit(True)
  end;

  if (Address >= $8000) and FSoftwareId and
    ((FBoard <> MAPPER_4MROM512) or (Address < $C000)) then
  begin
    case Address and $1FF of
      0:
        Value := $BF;
      1:
        Value := $B7;
    else
      Value := $FF
    end;
    Exit(True)
  end;

  Result := inherited;
end;

function TMapperFlash.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
var
  Bus: Byte;
begin
  if FBoard = MAPPER_GTROM then
  begin
    if ((Address >= $5000) and (Address < $6000)) or ((Address >= $7000) and (Address < $8000)) then
    begin
      Update(Value);
      Exit(True)
    end;

    if Address >= $8000 then
    begin
      WriteFlash(FBank * $8000 + (Address and $7FFF), Value);
      Exit(True)
    end;
  end
  else if FBoard = MAPPER_4MROM512 then
  begin
    if Address < $8000 then
      Exit(inherited CpuWrite(Address, Value));
    if Address < $C000 then
      WriteFlash(FBank * $4000 + (Address and $3FFF), Value)
    else
      Update((FRegister shr 1) or ((Value and 1) shl 4));
    Exit(True);
  end
  else if Address >= $8000 then
  begin
    if (FSubmapper = 4) and (Address < $C000) then
      Exit(True);

    if FBattery and (Address < $C000) then
      WriteFlash(FBank * $4000 + (Address and $3FFF), Value)
    else
    begin
      if (FSubmapper = 2) or ((FSubmapper = 0) and not FBattery) then
        if inherited CpuRead(Address, Bus) then
          Value := Value and Bus;
      Update(Value);
    end;
    Exit(True);
  end;
  Result := False;
end;

function TMapperFlash.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
    if FBoard = MAPPER_GTROM then
    begin
      Value := FNameRam[((FRegister and $20) shl 8) + (Address and $1FFF)];
      Exit(True)
    end
    else if FBoard = MAPPER_4MROM512 then
    begin
      Value := FChrMemory[Address];
      Exit(True);
    end
    else if FMirror = TMirrorMode.FourScreen then
    begin
      Value := FChrMemory[$6000 + (Address and $1FFF)];
      Exit(True)
    end;

  Result := inherited;
end;

function TMapperFlash.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
    if FBoard = MAPPER_GTROM then
    begin
      FNameRam[((FRegister and $20) shl 8) + (Address and $1FFF)] := Value;
      Exit(True)
    end
    else if FBoard = MAPPER_4MROM512 then
    begin
      FChrMemory[Address] := Value;
      Exit(True);
    end
    else if FMirror = TMirrorMode.FourScreen then
    begin
      FChrMemory[$6000 + (Address and $1FFF)] := Value;
      Exit(True)
    end;

  Result := inherited;
end;

function TMapperFlash.GetSaveMemory: TByteArray;
begin
  Result := Copy(FPrgRom)
end;

procedure TMapperFlash.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRom) then
    raise ENesException.Create('Invalid flash save size');

  FPrgRom := Copy(Data);
end;

constructor TMapperRainbow512.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Battery: Boolean);
begin
  inherited Create(MAPPER_RAINBOW512, Prg, Chr, MirrorMode, 0, Battery);
  ConfigureChrRam($2000);
end;

procedure TMapperRainbow512.ConfigureChrRam(Size: UInt64);
begin
  if FMirror = TMirrorMode.FourScreen then
    Size := $8000;
  case Size of
    $0000, $2000:
      SetLength(FChrMemory, $2000);
    $4000, $8000:
      SetLength(FChrMemory, Integer(Size));
  else
    raise ENesException.Create('Unsupported Rainbow-512 CHR RAM size');
  end;
  Update(0);
end;

procedure TMapperRainbow512.Reset;
begin
  inherited;
  FEspFlags := $41;
end;

procedure TMapperRainbow512.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FEspFlags, SizeOf(FEspFlags));
end;

function TMapperRainbow512.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  // No receive bytes are pending while the optional network device is disconnected.
  case Address of
    $5000:
      Value := 0;
    $5001:
      Value := FEspFlags;
    $5C03:
      Value := $20;
  else
    Exit(inherited CpuRead(Address, Value));
  end;
  Result := True;
end;

function TMapperRainbow512.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $5000:
      Exit(True);
    $5001:
      FEspFlags := Value and $41;
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

constructor TMapperImpactFlash.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  if (Submapper > 1) or (Length(Prg) <> $80000) or (Length(Chr) = 0) then
    raise ENesException.Create('Unsupported Impact Soft cartridge configuration');
  inherited Create(Prg, Chr, False, MirrorMode);
  FSubmapper := Submapper;
  FIrqRequiresCounterTransition := True;
end;

procedure TMapperImpactFlash.Reset;
begin
  inherited;
  FFlashStep := 0;
  FFlashMode := 0;
  FSoftwareId := False;
end;

procedure TMapperImpactFlash.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FFlashStep, SizeOf(FFlashStep));
  State.Field(FFlashMode, SizeOf(FFlashMode));
  State.Field(FSoftwareId, SizeOf(FSoftwareId));
  State.Field(FPrgRom[0], Length(FPrgRom));
end;

function TMapperImpactFlash.FlashOffset(Address: UInt16): Integer;
begin
  Result := ((PrgRegisterBank((Address shr 13) and 3) and $3F) shl 13) or (Address and $1FFF);
end;

function TMapperImpactFlash.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);
  if not FSoftwareId then
    Value := FPrgRom[FlashOffset(Address)]
  else if Odd(Address) then
    Value := $A4
  else if FSubmapper = 0 then
    Value := $C2
  else
    Value := $01;
  Result := True;
end;

function TMapperImpactFlash.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);

  // Flash and the AX5202P both see the write. Flash uses the pre-write PRG mapping.
  WriteNorFlash(FPrgRom, FlashOffset(Address), $10000, Value, FFlashStep, FFlashMode, FSoftwareId);
  if FSubmapper = 0 then
    Address := (Address and $FFFE) or ((Address shr 1) and 1)
  else if (Address < $A000) or (Address >= $E000) then
    Address := Address xor $6000;
  Result := inherited CpuWrite(Address, Value);
end;

function TMapperImpactFlash.GetSaveMemory: TByteArray;
begin
  Result := Copy(FPrgRom);
end;

procedure TMapperImpactFlash.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRom) then
    raise ENesException.Create('Invalid Impact Soft flash save size');
  Move(Data[0], FPrgRom[0], Length(FPrgRom));
end;

constructor TMapperHaratyler.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  if (Length(Prg) <> $80000) or (Length(Chr) <> 0) then
    raise ENesException.Create('Haratyler requires 512 KiB of flash and CHR RAM');
  inherited Create(Prg, Chr, True, MirrorMode);
  SetLength(FChrMemory, $4000);
  SetRegion(TNesRegion.NTSC);
end;

procedure TMapperHaratyler.Reset;
begin
  inherited;
  FBank := 0;
  FFlashStep := 0;
  FFlashId := False;
  FProgramError := False;
end;

procedure TMapperHaratyler.SetRegion(Region: TNesRegion);
begin
  FFrequency := CpuFrequency(Region);
end;

function TMapperHaratyler.FlashTicks(Microseconds: Integer): Integer;
begin
  Result := (Int64(FFrequency) * Microseconds + 999999) div 1000000;
end;

function TMapperHaratyler.FlashOffset(Address: UInt16): Integer;
begin
  var Bank := ((Address shr 13) and 3) shl 4;
  if Bank in [$10, $20] then
    Inc(Bank, (FBank and 1) or ((FBank and 2) shl 2));
  Result := (Bank shl 13) or (Address and $1FFF);
end;

function TMapperHaratyler.ReadFlash(Offset: Integer): Byte;
begin
  if (FProgramTicks > 0) or FProgramError then
    Exit(((FProgramData xor $80) and $80) or (Ord(FToggle) shl 6) or
      (Ord(FProgramError) shl 5));
  if FEraseTicks > 0 then
  begin
    var Selected := (FEraseMask and (1 shl (Offset shr 16))) <> 0;
    if not FEraseSuspended then
      Exit((Ord(FToggle) shl 6) or (Ord(Selected and FToggle) shl 2) or
        (Ord(FEraseSelectTicks = 0) shl 3));
    if Selected then
      Exit($80 or (Ord(FToggle) shl 2));
  end;
  if FFlashId then
    case Offset and $FF of
      0:
        Exit($37);
      1:
        Exit($86);
      2:
        Exit(0);       // Uniform sectors have no protection straps on the cartridge.
        3:
        Exit($7F);
    else
      Exit($FF);
    end;
  Result := FPrgRom[Offset];
end;

procedure TMapperHaratyler.WriteFlash(Offset: Integer; Value: Byte);
begin
  if FProgramTicks > 0 then
    Exit;
  if FEraseTicks > 0 then
  begin
    if not FEraseSuspended then
    begin
      if not FChipErase then
      begin
        if Value = $B0 then
        begin
          FEraseSuspended := True;
          FEraseSelectTicks := 0;
        end
        else if FEraseSelectTicks > 0 then
        begin
          if Value = $30 then
          begin
            FEraseMask := FEraseMask or (1 shl (Offset shr 16));
            FEraseSelectTicks := FlashTicks(50);
          end
          else
          begin
            FEraseMask := 0;
            FEraseTicks := 0;
            FEraseSelectTicks := 0;
          end;
        end;
      end;
      Exit;
    end;
    if (FFlashStep = 0) and (Value = $30) then
    begin
      FEraseSuspended := False;
      Exit;
    end;
  end;

  var CommandAddress := Offset and $7FF;
  if (Value = $F0) and (FFlashStep <> 6) then
  begin
    FFlashStep := 0;
    FFlashId := False;
    FProgramError := False;
    Exit;
  end;
  if FProgramError then
    Exit;

  // Unlock addresses are decoded on A10..A0, separately from the cartridge's bank latch.
  case FFlashStep of
    0, 3:
      if (CommandAddress = $555) and (Value = $AA) then
        Inc(FFlashStep)
      else
        FFlashStep := 0;
    1, 4:
      if (CommandAddress = $2AA) and (Value = $55) then
        Inc(FFlashStep)
      else
        FFlashStep := 0;
    2:
      begin
        FFlashStep := 0;
        if CommandAddress = $555 then
          case Value of
            $80:
              if FEraseTicks = 0 then
                FFlashStep := 3;
            $90:
              FFlashId := True;
            $A0:
              FFlashStep := 6;
          end;
      end;
    5:
      begin
        FFlashStep := 0;
        FChipErase := (Value = $10) and (CommandAddress = $555);
        if FChipErase then
        begin
          FEraseMask := $FF;
          FEraseTicks := FlashTicks(16000000);
        end
        else if Value = $30 then
        begin
          FEraseMask := 1 shl (Offset shr 16);
          FEraseSelectTicks := FlashTicks(50);
          FEraseTicks := FlashTicks(2000000);
        end;
        FToggle := False;
      end;
    6:
      begin
        FFlashStep := 0;
        if (FEraseMask and (1 shl (Offset shr 16))) = 0 then
        begin
          FProgramOffset := Offset;
          FProgramData := Value;
          FProgramTicks := FlashTicks(35);
          FToggle := False;
        end;
      end;
  end;
end;

procedure TMapperHaratyler.ClockCpu;
begin
  if FProgramTicks > 0 then
  begin
    Dec(FProgramTicks);
    if FProgramTicks = 0 then
    begin
      FProgramError := (FProgramData and not FPrgRom[FProgramOffset]) <> 0;
      FPrgRom[FProgramOffset] := FPrgRom[FProgramOffset] and FProgramData;
    end;
  end;
  if (FEraseTicks > 0) and not FEraseSuspended then
    if FEraseSelectTicks > 0 then
      Dec(FEraseSelectTicks)
    else
    begin
      Dec(FEraseTicks);
      if FEraseTicks = 0 then
      begin
        for var Sector := 0 to 7 do
          if (FEraseMask and (1 shl Sector)) <> 0 then
            FillChar(FPrgRom[Sector shl 16], $10000, $FF);
        FEraseMask := 0;
        FChipErase := False;
      end;
    end;
end;

function TMapperHaratyler.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := ReadFlash(FlashOffset(Address));
end;

function TMapperHaratyler.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := CpuPeek(Address, Value);
  if Result and ((FProgramTicks > 0) or FProgramError or (FEraseTicks > 0)) then
    FToggle := not FToggle;
end;

function TMapperHaratyler.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);
  WriteFlash(FlashOffset(Address), Value);
  case Address and $E000 of
    $A000:
      inherited CpuWrite($A000, Address and 1);
    $C000:
      begin
        var Count := Address and $FF;
        inherited CpuWrite($C000, (Count - 1) and $FF);
        inherited CpuWrite($C001, 0);
        inherited CpuWrite($E000 + Ord(Count <> $FF), 0);
      end;
    $E000:
      FBank := Address and 3;
  end;
  Result := True;
end;

function TMapperHaratyler.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[((FBank and 1) shl 13) or Address];
end;

function TMapperHaratyler.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    FChrMemory[((FBank and 1) shl 13) or Address] := Value;
end;

function TMapperHaratyler.GetSaveMemory: TByteArray;
begin
  Result := Copy(FPrgRom);
end;

procedure TMapperHaratyler.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRom) then
    raise ENesException.Create('Invalid Haratyler flash save size');
  Move(Data[0], FPrgRom[0], Length(FPrgRom));
end;

procedure TMapperHaratyler.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRom[0], Length(FPrgRom));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FFlashStep, SizeOf(FFlashStep));
  State.Field(FFlashId, SizeOf(FFlashId));
  State.Field(FToggle, SizeOf(FToggle));
  State.Field(FProgramOffset, SizeOf(FProgramOffset));
  State.Field(FProgramData, SizeOf(FProgramData));
  State.Field(FProgramTicks, SizeOf(FProgramTicks));
  State.Field(FProgramError, SizeOf(FProgramError));
  State.Field(FEraseMask, SizeOf(FEraseMask));
  State.Field(FEraseTicks, SizeOf(FEraseTicks));
  State.Field(FEraseSelectTicks, SizeOf(FEraseSelectTicks));
  State.Field(FEraseSuspended, SizeOf(FEraseSuspended));
  State.Field(FChipErase, SizeOf(FChipErase));
  if State.Loading and ((FBank > 3) or (FFlashStep > 6) or
    (FProgramOffset < 0) or (FProgramOffset >= Length(FPrgRom)) or
    (FProgramTicks < 0) or (FProgramTicks > FlashTicks(35)) or
    (FEraseTicks < 0) or (FEraseTicks > FlashTicks(16000000)) or
    (FEraseSelectTicks < 0) or (FEraseSelectTicks > FlashTicks(50)) or
    ((FEraseTicks > 0) <> (FEraseMask <> 0))) then
    raise ENesException.Create('Invalid Haratyler flash snapshot');
end;

constructor TMapperHaratylerMp.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; const AudioFolder: string; const Storage: IStorage);
begin
  inherited Create(Prg, Chr, MirrorMode);
  FAudioFolder := AudioFolder;
  FStorage := Storage;
end;

procedure TMapperHaratylerMp.Reset;
begin
  inherited;
  ResetPlayer;
end;

procedure TMapperHaratylerMp.ResetPlayer;
begin
  FBitTicks := 0;
  FSlot := 0;
  FCommand := $FF;
  FVolume := 25;
  FEq := 0;
  FFolder := 0;
  StopTrack;
  UpdateGain;
end;

procedure TMapperHaratylerMp.UpdateGain;
begin
  // Leave headroom for the internal 2A03 mix.
  FGain := FVolume * (0.35 / 30);
end;

procedure TMapperHaratylerMp.StopTrack;
begin
  FSource := nil;
  FTrack := 0;
  FTrackFolder := 0;
  FNextFrame := 0;
  FPcmCount := 0;
  FPhase := 0;
  FSample := 0;
  FLow := 0;
  FHighCut := 0;
end;

function TMapperHaratylerMp.OpenTrack(Folder, Track: Byte): Boolean;
const
  MaxTrackBytes = 32 * 1024 * 1024;
begin
  StopTrack;
  if (FAudioFolder = '') or (FStorage = nil) then
    Exit(False);

  var Path := TPath.Combine(TPath.Combine(FAudioFolder, Format('%.2d', [Folder + 1])),
    Format('%.3d.mp3', [Track]));
  if not FStorage.Exists(Path) then
    Exit(False);

  try
    var Input := FStorage.OpenRead(Path);
    try
      if (Input.Size <= 0) or (Input.Size > MaxTrackBytes) then
        Exit(False);
      var Data: TBytes;
      SetLength(Data, Integer(Input.Size));
      Input.ReadBuffer(Data[0], Length(Data));
      FSource := OpenMP3(Data);
    finally
      Input.Free;
    end;
  except
    on E: EStreamError do
      Exit(False);
    on E: EInOutError do
      Exit(False);
    on E: EArgumentException do
      Exit(False);
  end;

  FFormat := FSource.GetFormat;
  FTrack := Track;
  FTrackFolder := Folder;
  FLowAlpha := 1 - Exp(-2 * Pi * 240 / FFormat.SampleRate);
  FHighAlpha := 1 - Exp(-2 * Pi * 3200 / FFormat.SampleRate);
  Result := True;
end;

procedure TMapperHaratylerMp.AdvanceSample;
const
  // Broad bass/treble approximations for Normal, Pop, Rock, Jazz, Classic, Bass.
  Bass: array[0..5] of Double = (0, -0.15, 0.55, 0.30, 0.15, 0.85);
  Treble: array[0..5] of Double = (0, 0.15, 0.50, 0.30, 0.45, -0.15);
begin
  if FPcmOffset >= FPcmCount then
  begin
    FPcmCount := FSource.Render(FPcm, PcmBlockFrames);
    if FPcmCount = 0 then
    begin
      StopTrack;
      Exit;
    end;
    FPcmOffset := 0;
    FPcmStart := FNextFrame;
  end;

  var Index := FPcmOffset * FFormat.Channels;
  var Sample: Double := FPcm[Index] / 32768;
  if FFormat.Channels = 2 then
    Sample := (Integer(FPcm[Index]) + FPcm[Index + 1]) / 65536;
  Inc(FPcmOffset);
  Inc(FNextFrame);
  FLow := FLow + FLowAlpha * (Sample - FLow);
  FHighCut := FHighCut + FHighAlpha * (Sample - FHighCut);
  FSample := EnsureRange(Sample + Bass[FEq] * FLow + Treble[FEq] * (Sample - FHighCut), -1.0, 1.0);
end;

procedure TMapperHaratylerMp.ExecuteCommand;
begin
  case FCommand of
    $01..$BF:
      if OpenTrack(FFolder, FCommand) then
        AdvanceSample;
    $C0..$DE:
      begin
        FVolume := FCommand - $C0;
        UpdateGain;
      end;
    $E0..$E5:
      FEq := FCommand - $E0;
    $F0..$FC:
      FFolder := FCommand - $F0;
    $FF:
      StopTrack;
  end;
end;

function TMapperHaratylerMp.QueryByte: Byte;
begin
  case FSlot of
    2:
      Result := $A0;
    3:
      Result := $20;
    4:
      Result := FEq shl 4;
    5:
      Result := (FVolume and $F) shl 4;
    6:
      Result := FVolume and $F0;
    7:
      Result := FFolder shl 4;
  else
    Result := $FF;
  end;
end;

function TMapperHaratylerMp.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address <> $6003 then
    Exit(inherited CpuPeek(Address, Value));
  Value := QueryByte;
  Result := True;
end;

function TMapperHaratylerMp.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address <> $6003 then
    Exit(inherited CpuRead(Address, Value));
  Value := QueryByte;
  case FSlot of
    0:
      if FBitTicks = 0 then
      begin
        FCommand := $FF;
        FBitTicks := BitCycles;
      end;
    1..8:
      FCommand := FCommand and not (1 shl (8 - FSlot));
    9:
      begin
        FSlot := 0;
        ExecuteCommand;
      end;
  end;
  Result := True;
end;

procedure TMapperHaratylerMp.ClockCpu;
begin
  inherited;
  if FBitTicks <> 0 then
  begin
    Dec(FBitTicks);
    if FBitTicks = 0 then
    begin
      Inc(FSlot);
      if FSlot < 9 then
        FBitTicks := BitCycles;
    end;
  end;

  if FSource <> nil then
  begin
    Inc(FPhase, FFormat.SampleRate);
    if FPhase >= FFrequency then
    begin
      Dec(FPhase, FFrequency);
      AdvanceSample;
    end;
  end;
end;

function TMapperHaratylerMp.ExpansionAudio: Double;
begin
  Result := FSample * FGain;
end;

procedure TMapperHaratylerMp.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version < 27 then
  begin
    if State.Loading then
      ResetPlayer;
    Exit;
  end;

  State.Field(FBitTicks, SizeOf(FBitTicks));
  State.Field(FSlot, SizeOf(FSlot));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FEq, SizeOf(FEq));
  State.Field(FFolder, SizeOf(FFolder));
  var Track := FTrack;
  var TrackFolder := FTrackFolder;
  var NextFrame := FNextFrame;
  var Phase := FPhase;
  var Sample := FSample;
  var Low := FLow;
  var HighCut := FHighCut;
  State.Field(Track, SizeOf(Track));
  State.Field(TrackFolder, SizeOf(TrackFolder));
  State.Field(NextFrame, SizeOf(NextFrame));
  State.Field(Phase, SizeOf(Phase));
  State.Field(Sample, SizeOf(Sample));
  State.Field(Low, SizeOf(Low));
  State.Field(HighCut, SizeOf(HighCut));
  if not State.Loading then
    Exit;

  if (FSlot > 9) or (FBitTicks > BitCycles) or ((FSlot in [1..8]) and (FBitTicks = 0)) or
    ((FSlot = 9) and (FBitTicks <> 0)) or (FVolume > 30) or (FEq > 5) or (FFolder > 12) or
    (Track > $BF) or (TrackFolder > 12) or (NextFrame < 0) or (Phase >= FFrequency) or
    IsNan(Sample) or IsNan(Low) or IsNan(HighCut) or (Abs(Sample) > 1) or (Abs(Low) > 1) or
    (Abs(HighCut) > 1) then
    raise ENesException.Create('Invalid Haratyler MP snapshot');
  UpdateGain;
  if Track = 0 then
  begin
    StopTrack;
    Exit;
  end;

  if (FSource <> nil) and (FTrack = Track) and (FTrackFolder = TrackFolder) and
    (NextFrame >= FPcmStart) and (NextFrame <= FPcmStart + FPcmCount) then
    FPcmOffset := Integer(NextFrame - FPcmStart)
  else
  begin
    if not OpenTrack(TrackFolder, Track) then
      Exit;
    var Seek := FSource as IAudioSeekSource;
    if Seek.SeekFrame(NextFrame, nil) <> NextFrame then
    begin
      StopTrack;
      Exit;
    end;
    FPcmOffset := 0;
  end;
  FNextFrame := NextFrame;
  FPhase := Phase;
  FSample := Sample;
  FLow := Low;
  FHighCut := HighCut;
end;

end.

