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
    FHasChrRam, FHasPrgRam: Boolean;
    FPrgMask: UInt16;
    FMirrorMode: TMirrorMode;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; AHasPrgRam: Boolean = True);
    procedure LoadLegacyState(State: TNesStateArchive; LegacyMapper: Integer);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
    function AllowsPpuReadCaching: Boolean; override;
    function AllowsDirectPpuRead: Boolean; override;
  end;

implementation

uses
  NES.Mapper.Factory;

function TMapperNrom.AllowsDirectPpuRead: Boolean;
begin
  // Derived boards retain the contextual path unless they explicitly opt in.
  Result := ClassType = TMapperNrom;
end;

function TMapperNrom.AllowsPpuReadCaching: Boolean;
begin
  // A derived board must explicitly opt in if it adds read/fetch behavior.
  Result := ClassType = TMapperNrom;
end;

procedure TMapperNrom.SerializeState(State: TNesStateArchive);
begin
  var BoardMirror := FMirrorMode;
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  if State.Loading and not FHasPrgRam then
    FMirrorMode := BoardMirror;
end;

procedure TMapperNrom.LoadLegacyState(State: TNesStateArchive; LegacyMapper: Integer);
begin
  // The former mapper's latches and work RAM were absent on the real board.
  var FormerBoard := CreateMapper(LegacyMapper, FPrgRom, FChrMemory, FHasChrRam, FMirrorMode, True);
  try
    FormerBoard.SerializeState(State);
  finally
    FormerBoard.Free;
  end;
end;

function TMapperNrom.GetSaveMemory: TByteArray;
begin
  if not FHasPrgRam then
    Exit(nil);
  SetLength(Result, SizeOf(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperNrom.SetSaveMemory(const Data: TByteArray);
begin
  if not FHasPrgRam and (Length(Data) = 0) then
    Exit;
  if not FHasPrgRam or (Length(Data) <> SizeOf(FPrgRam)) then
    raise ENesException.Create('Invalid cartridge save size');

  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperNrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; AHasPrgRam: Boolean);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FPrgMask := $7FFF;
  if Length(FPrgRom) = $4000 then
    FPrgMask := $3FFF;
  FHasPrgRam := AHasPrgRam;
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
    if FHasPrgRam then
      Value := FPrgRam[Address and $1FFF];
    Exit(FHasPrgRam);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  Value := FPrgRom[Address and FPrgMask];
end;

function TMapperNrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    if FHasPrgRam then
      FPrgRam[Address and $1FFF] := Value;
    Exit(FHasPrgRam);
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

