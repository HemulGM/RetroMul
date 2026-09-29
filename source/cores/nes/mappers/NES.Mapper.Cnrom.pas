unit NES.Mapper.Cnrom;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperCnrom = class(TMapper)
  private
    FPrgRom, FChrMemory: TByteArray;
    FHasChrRam: Boolean;
    FMirrorMode: TMirrorMode;
    FChrBank: UInt8;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
  end;

implementation

procedure TMapperCnrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FChrBank, SizeOf(FChrBank));
end;

constructor TMapperCnrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
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

function TMapperCnrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := FPrgRom[(Address - $8000) mod Length(FPrgRom)];
end;

function TMapperCnrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  var RomValue: UInt8;
  Result := CpuRead(Address, RomValue);
  // Standard CNROM boards AND the CPU data with the still-driven PRG ROM.
  if Result then
    FChrBank := (Value and RomValue) and 3;
end;

function TMapperCnrom.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[(Integer(FChrBank) * $2000 + Address) mod Length(FChrMemory)];
end;

function TMapperCnrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[(Integer(FChrBank) * $2000 + Address) mod Length(FChrMemory)] := Value;
end;

function TMapperCnrom.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

procedure TMapperCnrom.Reset;
begin
  FChrBank := 0;
end;

end.

