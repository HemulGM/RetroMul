unit NES.Mapper.Gxrom;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperGxrom = class(TMapper)
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

procedure TMapperGxrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FBankRegister, SizeOf(FBankRegister));
end;

constructor TMapperGxrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
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

function TMapperGxrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := FPrgRom[(((FBankRegister shr 4) and 3) * $8000 + Address - $8000) mod Length(FPrgRom)];
end;

function TMapperGxrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  var RomValue: UInt8;
  Result := CpuRead(Address, RomValue);
  if Result then
    FBankRegister := Value and RomValue;
end;

function TMapperGxrom.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[((FBankRegister and 3) * $2000 + Address) mod Length(FChrMemory)];
end;

function TMapperGxrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[((FBankRegister and 3) * $2000 + Address) mod Length(FChrMemory)] := Value;
end;

function TMapperGxrom.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

procedure TMapperGxrom.Reset;
begin
  FBankRegister := 0;
end;

end.

