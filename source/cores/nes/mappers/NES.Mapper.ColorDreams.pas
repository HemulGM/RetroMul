unit NES.Mapper.ColorDreams;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperColorDreams = class(TMapper)
  private
    FPrgRom, FChrMemory: TByteArray;
    FHasChrRam: Boolean;
    FMirrorMode: TMirrorMode;
    FBankRegister: UInt8;
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

procedure TMapperColorDreams.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FBankRegister, SizeOf(FBankRegister));
end;

constructor TMapperColorDreams.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
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

function TMapperColorDreams.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := FPrgRom[((FBankRegister and 3) * $8000 + Address - $8000) mod Length(FPrgRom)];
end;

function TMapperColorDreams.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  var RomValue: UInt8;
  Result := CpuRead(Address, RomValue);
  if Result then
    FBankRegister := Value and RomValue;
end;

function TMapperColorDreams.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[((FBankRegister shr 4) * $2000 + Address) mod Length(FChrMemory)];
end;

function TMapperColorDreams.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[((FBankRegister shr 4) * $2000 + Address) mod Length(FChrMemory)] := Value;
end;

function TMapperColorDreams.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

procedure TMapperColorDreams.Reset;
begin
  FBankRegister := 0;
end;

end.

