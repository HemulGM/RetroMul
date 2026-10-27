unit ZX.SID;

interface

uses
  System.SysUtils, C64.Sound.SID, Core.Snapshots;

type
  // One MOS SID through either eLeMeNt ZX / MB03+ or HardSID / ZX-TSid xxCF.
  TZXSID = class
  private
    FChip: TSID;
    FAddress, FParameters: Byte;
    FInterface, FFixedClock: Integer;
    FClock, FChipClock, FChipPhase, FSamplePhase: Integer;
    FLevel: SmallInt;
    procedure SetParameters(Value: Byte);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset(Clock, Model: Integer; NTSC: Boolean; InterfaceType: Integer = 0; OneMHz: Boolean = False);
    procedure SetMotherboardClock(Clock: Integer);
    class function Decodes(Address: Word; InterfaceType: Integer = 0): Boolean; static;
    function HandlesPort(Address: Word): Boolean;
    procedure WritePort(Address: Word; Value: Byte);
    function ReadPort(Address: Word): Byte;
    procedure Tick;
    function Level: Double;
    procedure SerializeState(State: TStateArchive);
    property Chip: TSID read FChip;
    property InterfaceType: Integer read FInterface;
    property FixedClock: Integer read FFixedClock;
    property MotherboardClock: Integer read FClock;
  end;

implementation

uses
  System.Classes;

constructor TZXSID.Create;
begin
  inherited;
  FChip := TSID.Create;
  Reset(3500000, 0, False);
end;

destructor TZXSID.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TZXSID.SetParameters(Value: Byte);
begin
  FParameters := Value and 3;
  FChipClock := 985248;
  if (FParameters and 2) <> 0 then
    FChipClock := 1022730; // eZX/MB Programmer's Reference, SID register 1F.
  if FFixedClock <> 0 then
    FChipClock := FFixedClock;
  FChip.Configure(TSIDModel(FParameters and 1), FChipClock);
end;

procedure TZXSID.Reset(Clock, Model: Integer; NTSC: Boolean; InterfaceType: Integer; OneMHz: Boolean);
begin
  if (Clock < 1000000) or (Clock > 8000000) or (Model < 0) or (Model > 1) then
    raise EArgumentOutOfRangeException.Create('Invalid SID configuration');
  if (InterfaceType < 0) or (InterfaceType > 1) or
    (OneMHz and ((InterfaceType <> 1) or NTSC)) then
    raise EArgumentOutOfRangeException.Create('Invalid SID interface/clock');
  FInterface := InterfaceType;
  FFixedClock := 0;
  if OneMHz then
    FFixedClock := 1000000;
  FClock := Clock;
  FAddress := 0;
  FChipPhase := 0;
  FSamplePhase := 0;
  FLevel := 0;
  SetParameters(Model or (Ord(NTSC) shl 1));
  FChip.Reset;
end;

procedure TZXSID.SetMotherboardClock(Clock: Integer);
begin
  if (Clock < 1000000) or (Clock > 8000000) then
    raise EArgumentOutOfRangeException.Create('Invalid SID motherboard clock');
  if FClock = Clock then
    Exit;
  // Snapshot metadata can select another motherboard after device reset.
  // Preserve fractional progress and the chip itself when changing the base.
  FChipPhase := (Int64(FChipPhase) * Clock) div FClock;
  FSamplePhase := (Int64(FSamplePhase) * Clock) div FClock;
  FClock := Clock;
end;

class function TZXSID.Decodes(Address: Word; InterfaceType: Integer): Boolean;
begin
  case InterfaceType of
    0: Result := (Address = $6C3B) or (Address = $6D3B);
    1: Result := (Address and $FF) = $CF;
  else
    Result := False;
  end;
end;

function TZXSID.HandlesPort(Address: Word): Boolean;
begin
  Result := Decodes(Address, FInterface);
end;

procedure TZXSID.WritePort(Address: Word; Value: Byte);
begin
  if not HandlesPort(Address) then
    Exit;
  if FInterface = 1 then
  begin
    // ZX-TSid CPLD rev.D: low byte CF selects the chip; A12..A8
    // drive its five register pins. A15..A13 therefore create eight mirrors.
    // The MOS reserved registers keep their bus behavior, not eZX setup.
    FChip.WriteRegister((Address shr 8) and $1F, Value);
    Exit;
  end;
  case Address of
    $6C3B:
      FAddress := Value;
    $6D3B:
      case FAddress of
        $00..$1C:
          FChip.WriteRegister(FAddress, Value);
        $1F:
          SetParameters(Value);
        // 20 is reserved for optional multiple SIDs. This profile has one chip.
      end;
  end;
end;

function TZXSID.ReadPort(Address: Word): Byte;
begin
  Result := $FF;
  if not HandlesPort(Address) then
    Exit;
  if FInterface = 1 then
    Exit(FChip.ReadRegister((Address shr 8) and $1F));
  if Address <> $6D3B then
    Exit;
  case FAddress of
    $00..$1C:
      Result := FChip.ReadRegister(FAddress);
    $1F:
      Result := FParameters;
    $20:
      Result := 0;
  end;
end;

procedure TZXSID.Tick;
begin
  Inc(FChipPhase, FChipClock);
  while FChipPhase >= FClock do
  begin
    Dec(FChipPhase, FClock);
    FChip.Clock;
  end;
  Inc(FSamplePhase, 44100);
  if FSamplePhase >= FClock then
  begin
    Dec(FSamplePhase, FClock);
    FLevel := FChip.Sample;
  end;
end;

function TZXSID.Level: Double;
begin
  Result := FLevel / 32768;
end;

procedure TZXSID.SerializeState(State: TStateArchive);
begin
  State.Field(FInterface, SizeOf(FInterface));
  State.Field(FFixedClock, SizeOf(FFixedClock));
  if (FInterface < 0) or (FInterface > 1) or
    ((FFixedClock <> 0) and ((FFixedClock <> 1000000) or (FInterface <> 1))) then
    raise EReadError.Create('Invalid SID interface state');
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FParameters, SizeOf(FParameters));
  State.Field(FClock, SizeOf(FClock));
  State.Field(FChipClock, SizeOf(FChipClock));
  State.Field(FChipPhase, SizeOf(FChipPhase));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FLevel, SizeOf(FLevel));
  FChip.SerializeState(State.Field, State.Loading);
  if (FParameters > 3) or (FClock < 1000000) or (FClock > 8000000) or
    (FChipPhase < 0) or (FChipPhase >= FClock) or
    (FSamplePhase < 0) or (FSamplePhase >= FClock) or
    (Ord(FChip.Model) <> Integer(FParameters and 1)) or (FChip.ChipClock <> FChipClock) or
    (FChip.SampleRate <> 44100) then
    raise EReadError.Create('Invalid SID state');
  var ExpectedClock := 985248;
  if (FParameters and 2) <> 0 then
    ExpectedClock := 1022730;
  if FFixedClock <> 0 then
  begin
    if (FParameters and 2) <> 0 then
      raise EReadError.Create('Invalid fixed SID clock state');
    ExpectedClock := FFixedClock;
  end;
  if FChipClock <> ExpectedClock then
    raise EReadError.Create('Mismatched SID clock');
end;

end.

