unit NES.Mapper;

interface

uses
  NES.State, NES.Types;

{$SCOPEDENUMS ON}

const
  MAPPER_NROM = 0;
  MAPPER_MMC1 = 1;
  MAPPER_UXROM = 2;
  MAPPER_CNROM = 3;
  MAPPER_MMC3 = 4;
  MAPPER_MMC5 = 5;
  MAPPER_AXROM = 7;
  MAPPER_FFE_F3XXX = 8;
  MAPPER_MMC2 = 9;
  MAPPER_MMC4 = 10;
  MAPPER_COLOR_DREAMS = 11;
  MAPPER_MMC3_12 = 12;
  MAPPER_CPROM = 13;
  MAPPER_MULTICART_15 = 15;
  MAPPER_BANDAI_FCG = 16;
  MAPPER_VRC2A = 22;
  MAPPER_VRC2B_VRC4E = 23;
  MAPPER_VRC2C_VRC4B = 25;
  MAPPER_IREM_G101 = 32;
  MAPPER_BNROM_NINA001 = 34;
  MAPPER_RAMBO1 = 64;
  MAPPER_GXROM = 66;
  MAPPER_SUNSOFT4 = 68;
  MAPPER_FME7 = 69;
  MAPPER_BANDAI_70 = 70;
  MAPPER_CAMERICA = 71;
  MAPPER_NINA03 = 79;
  MAPPER_CONY = 83;
  MAPPER_JALECO_87 = 87;
  MAPPER_NAMCO_118 = 88;
  MAPPER_JY_90 = 90;
  MAPPER_MMC3_91 = 91;
  MAPPER_VS_SYSTEM = 99;
  MAPPER_DISCRETE_112 = 112;
  MAPPER_NINA_113 = 113;
  MAPPER_TQROM = 119;
  MAPPER_AGCI = 144;
  MAPPER_BANDAI_152 = 152;
  MAPPER_NAMCO_154 = 154;
  MAPPER_BANDAI_159 = 159;
  MAPPER_SUBOR = 167;
  MAPPER_DXROM = 206;
  MAPPER_JY_209 = 209;
  MAPPER_ACTION52 = 228;
  MAPPER_CAMERICA_QUATTRO = 232;
  MAPPER_DISCRETE_240 = 240;
  MAPPER_WAIXING_242 = 242;
  MAPPER_MMC3_245 = 245;
  MAPPER_MMC3_250 = 250;

type
  TMirrorMode = (Horizontal, Vertical, Single0, Single1, FourScreen);

  TMapper = class
  protected
    class procedure ValidateMemory(const PrgRom, ChrData: TByteArray); static;
  public
    procedure SerializeState(State: TNesStateArchive); virtual;
    // Physical cartridge memory, independent of CPU banking / write protection.
    function GetSaveMemory: TByteArray; virtual;
    procedure SetSaveMemory(const Data: TByteArray); virtual;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; virtual; abstract;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; virtual; abstract;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; virtual;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; virtual; abstract;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; virtual; abstract;
    function GetMirrorMode: TMirrorMode; virtual; abstract;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); virtual;
    procedure ClockCpu; virtual;
    procedure ClockCpuWrite; virtual;
    procedure ClockPpuRead; virtual;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); virtual;
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); virtual;
    procedure SetPpuControl(Value: UInt8); virtual;
    function IrqPending: Boolean; virtual;
    procedure Reset; virtual; abstract;
  end;

implementation

procedure TMapper.SerializeState(State: TNesStateArchive);
begin
end;

function TMapper.GetSaveMemory: TByteArray;
begin
  Result := nil;
end;

procedure TMapper.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> 0 then
    raise ENesException.Create('This mapper has no persistent memory');
end;

procedure TMapper.ClockCpu;
begin
end;

procedure TMapper.ClockCpuWrite;
begin
end;

procedure TMapper.ClockPpuRead;
begin
end;

procedure TMapper.ClockScanline(Line: Integer; Rendering: Boolean);
begin
end;

procedure TMapper.SetPpuFetchKind(Sprite: Boolean; X, Y: Integer);
begin
end;

procedure TMapper.SetPpuControl(Value: UInt8);
begin
end;

class procedure TMapper.ValidateMemory(const PrgRom, ChrData: TByteArray);
begin
  if (Length(PrgRom) = 0) or ((Length(PrgRom) mod $4000) <> 0) then
    raise ENesException.Create('PRG ROM must contain complete 16 KB banks');
  if (Length(ChrData) mod $2000) <> 0 then
    raise ENesException.Create('CHR data must contain complete 8 KB banks');
end;

procedure TMapper.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
end;

function TMapper.IrqPending: Boolean;
begin
  Result := False;
end;

function TMapper.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  Result := CpuWrite(Address, Value);
end;

end.

