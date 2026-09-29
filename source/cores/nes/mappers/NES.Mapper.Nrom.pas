unit NES.Mapper.Nrom;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperNrom = class(TMapper)
  private
    FPrgRom: TByteArray;
    FChrMemory: TByteArray;
    FPrgRam: array[0..$1FFF] of UInt8;
    FHasChrRam: Boolean;
    FMirrorMode: TMirrorMode;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
  end;

implementation

procedure TMapperNrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
end;

function TMapperNrom.GetSaveMemory: TByteArray;
begin
  SetLength(Result, SizeOf(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperNrom.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> SizeOf(FPrgRam) then
    raise ENesException.Create('Invalid cartridge save size');
  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperNrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  FMirrorMode := AMirrorMode;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  Reset;
end;

function TMapperNrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  var Offset: UInt16 := Address - $8000;
  if Length(FPrgRom) = $4000 then
    Offset := Offset and $3FFF
  else
    Offset := Offset and $7FFF;
  Value := FPrgRom[Offset];
end;

function TMapperNrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;
  Result := Address >= $8000;
end;

function TMapperNrom.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[Address and $1FFF];
end;

function TMapperNrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[Address and $1FFF] := Value;
end;

function TMapperNrom.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

procedure TMapperNrom.Reset;
begin
end;

end.

