unit NES.Mapper.Uxrom;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMapperUxrom = class(TMapper)
  private
    FPrgRom: TByteArray;
    FChrMemory: TByteArray;
    FPrgRam: array[0..$1FFF] of UInt8;
    FHasChrRam: Boolean;
    FBusConflicts: Boolean;
    FMirrorMode: TMirrorMode;
    FPrgBankSelect: UInt8;
    FPrgBankCount, FLastPrgOffset, FSelectedPrgOffset: Integer;
    FPrgRamSize: Integer;
    procedure SelectPrgBank(Value: UInt8);
  public
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ConfigurePrgRam(Size: UInt64);
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; BusConflicts: Boolean = False);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
  end;

implementation

procedure TMapperUxrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FPrgBankSelect, SizeOf(FPrgBankSelect));
  if State.Loading then
    SelectPrgBank(FPrgBankSelect);
end;

procedure TMapperUxrom.ConfigurePrgRam(Size: UInt64);
begin
  if Size > SizeOf(FPrgRam) then
    Size := SizeOf(FPrgRam);
  FPrgRamSize := Integer(Size);
end;

function TMapperUxrom.GetSaveMemory: TByteArray;
begin
  SetLength(Result, SizeOf(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperUxrom.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> SizeOf(FPrgRam) then
    raise ENesException.Create('Invalid cartridge save size');

  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperUxrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; BusConflicts: Boolean);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  // Immutable board wiring comes from the ROM header, not save states.
  FBusConflicts := BusConflicts;
  FMirrorMode := AMirrorMode;
  FPrgBankCount := Length(FPrgRom) div $4000;
  FLastPrgOffset := (FPrgBankCount - 1) * $4000;
  ConfigurePrgRam(SizeOf(FPrgRam));
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  Reset;
end;

procedure TMapperUxrom.SelectPrgBank(Value: UInt8);
begin
  FPrgBankSelect := Value;
  FSelectedPrgOffset := (Integer(Value) mod FPrgBankCount) * $4000;
end;

function TMapperUxrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $8000 then
  begin
    var BankOffset := FSelectedPrgOffset;
    if Address >= $C000 then
      BankOffset := FLastPrgOffset;
    Value := FPrgRom[BankOffset + (Address and $3FFF)];
    Exit(True);
  end;

  Result := (Address >= $6000) and (FPrgRamSize <> 0);
  if Result then
    Value := FPrgRam[(Address and $1FFF) mod FPrgRamSize];
end;

function TMapperUxrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $8000 then
  begin
    var RomValue: UInt8;
    if FBusConflicts and CpuRead(Address, RomValue) then
      Value := Value and RomValue;
    SelectPrgBank(Value);
    Exit(True);
  end;

  Result := (Address >= $6000) and (FPrgRamSize <> 0);
  if Result then
    FPrgRam[(Address and $1FFF) mod FPrgRamSize] := Value;
end;

function TMapperUxrom.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[Address and $1FFF];
end;

function TMapperUxrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[Address and $1FFF] := Value;
end;

function TMapperUxrom.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

procedure TMapperUxrom.Reset;
begin
  SelectPrgBank(0);
end;

end.

