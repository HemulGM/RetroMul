unit NES.Mapper.Axrom;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperAxrom = class(TMapper)
  private
    FPrgRom, FChrMemory: TByteArray;
    FHasChrRam: Boolean;
    FBankRegister: UInt8;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
  end;

implementation

procedure TMapperAxrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FBankRegister, SizeOf(FBankRegister));
end;

constructor TMapperAxrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  Reset;
end;

function TMapperAxrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := FPrgRom[((FBankRegister and 7) * $8000 + Address - $8000) mod Length(FPrgRom)];
end;

function TMapperAxrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  // iNES mapper 7 defaults to ANROM/AOROM without bus conflicts.
  if Result then
    FBankRegister := Value;
end;

function TMapperAxrom.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[Address];
end;

function TMapperAxrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[Address] := Value;
end;

function TMapperAxrom.GetMirrorMode: TMirrorMode;
begin
  if (FBankRegister and $10) = 0 then
    Result := TMirrorMode.Single0
  else
    Result := TMirrorMode.Single1;
end;

procedure TMapperAxrom.Reset;
begin
  FBankRegister := 0;
end;

end.

