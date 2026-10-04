unit NES.Mapper.Flash;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

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

implementation

constructor TMapperFlash.Create(Board: Integer; const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer; Battery: Boolean);
begin
  inherited Create(Prg, Chr, True, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FBattery := Battery;
  if Board = MAPPER_GTROM then
    SetLength(FChrMemory, $4000)
  else
    SetLength(FChrMemory, $8000);
  Reset;
end;

procedure TMapperFlash.Reset;
begin
  inherited;
  FRamEnabled := False;
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
  if FBoard = MAPPER_GTROM then
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

procedure TMapperFlash.WriteFlash(Offset: Integer; Value: Byte);
var
  Command: Integer;
begin
  Command := Offset and $7FFF;
  if FFlashMode = 1 then
  begin
    FPrgRom[Offset mod Length(FPrgRom)] := FPrgRom[Offset mod Length(FPrgRom)] and Value;
    FFlashMode := 0;
    FFlashStep := 0;
    Exit
  end;

  if FFlashStep = 0 then
  begin
    if (Command = $5555) and (Value = $AA) then
      FFlashStep := 1
    else if Value = $F0 then
    begin
      FSoftwareId := False;
      FFlashMode := 0
    end;
  end
  else if FFlashStep = 1 then
    if (Command = $2AAA) and (Value = $55) then
      FFlashStep := 2
    else
      FFlashStep := 0
  else if FFlashStep = 2 then
  begin
    FFlashStep := 0;
    if Command = $5555 then
      case Value of
        $80:
          begin
            FFlashMode := 2;
            FFlashStep := 3
          end;
        $90:
          FSoftwareId := True;
        $A0:
          FFlashMode := 1;
        $F0:
          FSoftwareId := False;
      end;
  end
  else if FFlashStep = 3 then
    if (Command = $5555) and (Value = $AA) then
      FFlashStep := 4
    else
    begin
      FFlashStep := 0;
      FFlashMode := 0
    end
  else if FFlashStep = 4 then
    if (Command = $2AAA) and (Value = $55) then
      FFlashStep := 5
    else
    begin
      FFlashStep := 0;
      FFlashMode := 0
    end
  else
  begin
    if (Command = $5555) and (Value = $10) then
      FillChar(FPrgRom[0], Length(FPrgRom), $FF)
    else if Value = $30 then
    begin
      var Base := (Offset and $7F000) mod Length(FPrgRom);
      if Base + $1000 <= Length(FPrgRom) then
        FillChar(FPrgRom[Base], $1000, $FF)
    end;
    FFlashStep := 0;
    FFlashMode := 0;
  end;
end;

function TMapperFlash.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_GTROM) and (((Address >= $5000) and (Address < $6000)) or ((Address >= $7000) and (Address < $8000))) then
  begin
    Update(FCpuOpenBus);
    Value := FCpuOpenBus;
    Exit(True)
  end;

  if (Address >= $8000) and FSoftwareId then
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

end.

