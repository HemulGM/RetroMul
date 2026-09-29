unit NES.Mapper.Banked;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperBanked = class(TMapper)
  protected
    FPrgRom, FChrMemory, FPrgRam: TByteArray;
    FPrgBanks: array[0..3] of Integer;
    FChrBanks: array[0..7] of Integer;
    FHasChrRam, FRamEnabled, FRamWritable: Boolean;
    FInitialMirror, FMirror: TMirrorMode;
    procedure Prg8(Slot, Bank: Integer);
    procedure Prg16(Slot, Bank: Integer);
    procedure Prg32(Bank: Integer);
    procedure Chr1(Slot, Bank: Integer);
    procedure Chr2(Slot, Bank: Integer);
    procedure Chr4(Slot, Bank: Integer);
    procedure Chr8(Bank: Integer);
    procedure Mirror(Value: Integer);
    function PrgOffset(Address: UInt16): Integer;
    function ChrOffset(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
  end;

implementation

procedure TMapperBanked.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  if Length(FPrgRam) > 0 then
    State.Field(FPrgRam[0], Length(FPrgRam) * SizeOf(FPrgRam[0]));
  State.Field(FPrgBanks, SizeOf(FPrgBanks));
  State.Field(FChrBanks, SizeOf(FChrBanks));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FRamEnabled, SizeOf(FRamEnabled));
  State.Field(FRamWritable, SizeOf(FRamWritable));
  State.Field(FInitialMirror, SizeOf(FInitialMirror));
  State.Field(FMirror, SizeOf(FMirror));
end;

function TMapperBanked.GetSaveMemory: TByteArray;
begin
  SetLength(Result, Length(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperBanked.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRam) then
    raise ENesException.Create('Invalid cartridge save size');
  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperBanked.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create;
  ValidateMemory(Prg, Chr);
  FPrgRom := Copy(Prg);
  FChrMemory := Copy(Chr);
  FHasChrRam := HasChrRam;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  SetLength(FPrgRam, $2000);
  FInitialMirror := MirrorMode;
  FMirror := FInitialMirror;
  FRamEnabled := True;
  FRamWritable := True;
  Prg16(0, 0);
  Prg16(1, -1);
  Chr8(0);
end;

procedure TMapperBanked.Prg8(Slot, Bank: Integer);
begin
  var Count := Length(FPrgRom) div $2000;
  FPrgBanks[Slot] := ((Bank mod Count) + Count) mod Count;
end;

procedure TMapperBanked.Prg16(Slot, Bank: Integer);
begin
  for var i := 0 to 1 do
    Prg8(Slot * 2 + i, Bank * 2 + i);
end;

procedure TMapperBanked.Prg32(Bank: Integer);
begin
  for var i := 0 to 3 do
    Prg8(i, Bank * 4 + i);
end;

procedure TMapperBanked.Chr1(Slot, Bank: Integer);
begin
  FChrBanks[Slot] := Bank;
end;

procedure TMapperBanked.Chr2(Slot, Bank: Integer);
begin
  for var i := 0 to 1 do
    Chr1(Slot * 2 + i, Bank * 2 + i);
end;

procedure TMapperBanked.Chr4(Slot, Bank: Integer);
begin
  for var i := 0 to 3 do
    Chr1(Slot * 4 + i, Bank * 4 + i);
end;

procedure TMapperBanked.Chr8(Bank: Integer);
begin
  for var i := 0 to 7 do
    Chr1(i, Bank * 8 + i);
end;

procedure TMapperBanked.Mirror(Value: Integer);
begin
  case Value and 3 of
    0:
      FMirror := TMirrorMode.Vertical;
    1:
      FMirror := TMirrorMode.Horizontal;
    2:
      FMirror := TMirrorMode.Single0;
    3:
      FMirror := TMirrorMode.Single1;
  end;
end;

function TMapperBanked.PrgOffset(Address: UInt16): Integer;
begin
  Result := FPrgBanks[(Address - $8000) shr 13] * $2000 + (Address and $1FFF);
end;

function TMapperBanked.ChrOffset(Address: UInt16): Integer;
begin
  Result := (FChrBanks[Address shr 10] * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperBanked.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $8000 then
    Value := FPrgRom[PrgOffset(Address)]
  else if (Address >= $6000) and FRamEnabled then
    Value := FPrgRam[Address and $1FFF]
  else
    Result := False;
end;

function TMapperBanked.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address >= $6000) and (Address < $8000) and FRamEnabled;
  if Result and FRamWritable then
    FPrgRam[Address and $1FFF] := Value;
end;

function TMapperBanked.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[ChrOffset(Address)];
end;

function TMapperBanked.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[ChrOffset(Address)] := Value;
end;

function TMapperBanked.GetMirrorMode: TMirrorMode;
begin
  Result := FMirror;
end;

procedure TMapperBanked.Reset;
begin
  FMirror := FInitialMirror;
  FRamEnabled := True;
  FRamWritable := True;
  Prg16(0, 0);
  Prg16(1, -1);
  Chr8(0);
end;

end.

