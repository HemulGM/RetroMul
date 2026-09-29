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
    FMirrorMode: TMirrorMode;
    FPrgBankSelect: UInt8;
    function GetPrgBankCount: Integer;
    function NormalizeBank(Bank: Integer): Integer;
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

procedure TMapperUxrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FPrgBankSelect, SizeOf(FPrgBankSelect));
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

constructor TMapperUxrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
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

function TMapperUxrom.GetPrgBankCount: Integer;
begin
  Result := Length(FPrgRom) div $4000;
  if Result <= 0 then
    Result := 1;
end;

function TMapperUxrom.NormalizeBank(Bank: Integer): Integer;
begin
  Result := Bank mod GetPrgBankCount;
  if Result < 0 then
    Inc(Result, GetPrgBankCount);
end;

function TMapperUxrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  var Bank: Integer;
  if (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  if Address < $C000 then
    Bank := NormalizeBank(FPrgBankSelect)
  else
    Bank := GetPrgBankCount - 1;

  var Offset: Integer := Bank * $4000 + (Address and $3FFF);
  Value := FPrgRom[Offset mod Length(FPrgRom)];
end;

function TMapperUxrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;

  Result := Address >= $8000;
  if Result then
    FPrgBankSelect := Value and $0F;
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
  FPrgBankSelect := 0;
end;

end.

