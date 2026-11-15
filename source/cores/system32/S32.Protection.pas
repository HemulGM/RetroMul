unit S32.Protection;

interface

uses
  System.SysUtils, HW.V30MZ, Core.Snapshots;

type
  // The dumped GA2/Arabian Fight firmware uses the shared native 8086/V30
  // instruction engine. V25 internal peripheral timers are not modeled here.
  TS32V25Protection = class
  private
    FCPU: TV30MZ;
    FROM: TBytes;
    FDecode: array[0..255] of Byte;
    FRAM: array[0..255] of Byte;
    FTime: Int64;
    function ReadMemory(Address: Cardinal): Byte;
    procedure WriteMemory(Address: Cardinal; Value: Byte);
    function ReadPort(Address: Cardinal): Byte;
    procedure WritePort(Address: Cardinal; Value: Byte);
    function DecodeOpcode(Value: Byte): Byte;
    function BusInfo(Address: Cardinal): Integer;
  public
    Shared: array[0..$7FF] of Byte;
    constructor Create(const ROM: TBytes; ArabianFight: Boolean);
    destructor Destroy; override;
    procedure Reset;
    procedure RunUntil(Target: Int64);
    procedure SerializeState(State: TStateArchive);
    function ProgramCounter: Cardinal;
  end;

implementation

uses
  System.Classes;

const
  GA2_OPCODES: array[0..255] of Byte = (
    0, 0, $EA, 0, 0, $8B, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $FA,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $3B, 0, $49, 0, 0, 0,
    0, 0, 0, 0, 0, $E8, 0, 0, $75, 0, 0, 0, 0, $3A, 0, 0,
    0, 0, 0, 0, $8D, 0, 0, 0, 0, 0, 0, 0, $BF, 0, $88, 0,
    0, 0, 0, $81, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    $02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $BC,
    0, 0, 0, $8A, 0, 0, 0, 0, 0, 0, $83, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $B8, $26, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $B5, 0, $EB,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $B2, 0, 0, 0, 0,
    0, 0, 0, $C3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, $B9, $BB, 0, $43, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, $8E, 0, 0, 0, 0, 0, 0, 0, 0, $BE, 0, $80, 0, 0);
  ARF_OPCODES: array[0..255] of Byte = (
    0, 0, $43, 0, 0, 0, $83, 0, 0, 0, $EA, 0, 0, $BC, $73, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    $3A, 0, 0, $BE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $80, 0,
    0, $B5, 0, 0, 0, 0, 0, $26, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $E8, $8D, 0, $8B, 0,
    0, 0, 0, $FA, 0, $8A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, $BA, $88, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, $BB, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $75, 0, $BF,
    0, 0, 0, 0, 0, 0, 0, 0, $03, $3B, $8E, $74, 0, 0, $81, 0,
    0, 0, 0, $C3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, $B9, $B2, 0, 0, 0, 0, $49, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, $EB, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $02, $B8);

constructor TS32V25Protection.Create(const ROM: TBytes; ArabianFight: Boolean);
const
  AddressBits: array[0..15] of Integer = (14, 11, 15, 12, 13, 4, 3, 7, 5, 10, 2, 8, 9, 6, 1, 0);
begin
  inherited Create;
  if Length(ROM) <> $10000 then
    raise EReadError.Create('System 32 V25 requires a 64 KiB protection ROM');
  SetLength(FROM, $10000);
  for var I := 0 to $FFFF do
  begin
    var Source := 0;
    for var BitIndex := 0 to 15 do
      Source := Source or (((I shr AddressBits[BitIndex]) and 1) shl (15 - BitIndex));
    FROM[I] := ROM[Source];
  end;
  if ArabianFight then
    Move(ARF_OPCODES, FDecode, SizeOf(FDecode))
  else
    Move(GA2_OPCODES, FDecode, SizeOf(FDecode));
  FCPU := TV30MZ.Create(ReadMemory, WriteMemory, ReadPort, WritePort);
  FCPU.OpcodeDecoder := DecodeOpcode;
  FCPU.BusInfo := BusInfo;
  Reset;
end;

destructor TS32V25Protection.Destroy;
begin
  FCPU.Free;
  inherited;
end;

procedure TS32V25Protection.Reset;
begin
  FCPU.Reset;
  FCPU.State := Default(TV30State);
  FCPU.State.S[1] := $FFFF;
  FCPU.State.Flags := $8002;
  FillChar(Shared, SizeOf(Shared), 0);
  FillChar(FRAM, SizeOf(FRAM), 0);
  FTime := 0;
end;

function TS32V25Protection.BusInfo(Address: Cardinal): Integer;
begin
  Result := 0;
end; // V25 external data bus is eight bits wide.

function TS32V25Protection.DecodeOpcode(Value: Byte): Byte;
begin
  Result := FDecode[Value];
  if Result = 0 then
    raise EInvalidOpException.CreateFmt('System 32 V25 unknown encrypted opcode %.2x at %.5x', [Value, FCPU.ProgramCounter]);
end;

function TS32V25Protection.ReadMemory(Address: Cardinal): Byte;
begin
  Result := $FF;
  Address := Address and $FFFFF;
  if (Address and $F0000 = 0) or (Address and $F0000 = $F0000) then
    Result := FROM[Address and $FFFF];
  if Address and $F0000 = $10000 then
    Result := Shared[Address and $7FF];
  if Address and $FFF00 = $FFE00 then
    Result := FRAM[Address and $FF];
end;

procedure TS32V25Protection.WriteMemory(Address: Cardinal; Value: Byte);
begin
  if Address and $F0000 = $10000 then
    Shared[Address and $7FF] := Value;
  if Address and $FFF00 = $FFE00 then
    FRAM[Address and $FF] := Value;
end;

function TS32V25Protection.ReadPort(Address: Cardinal): Byte;
begin
  Result := $FF;
end;

procedure TS32V25Protection.WritePort(Address: Cardinal; Value: Byte);
begin
end;

procedure TS32V25Protection.RunUntil(Target: Int64);
begin
  while FTime < Target do
  begin
    var Cycles := FCPU.Step;
    if (Cycles <= 0) or (FCPU.State.InvalidCount <> 0) then
      raise EInvalidOpException.CreateFmt('System 32 V25 unsupported instruction at %.5x', [FCPU.ProgramCounter]);
    Inc(FTime, Cycles);
  end;
end;

function TS32V25Protection.ProgramCounter: Cardinal;
begin
  Result := FCPU.ProgramCounter;
end;

procedure TS32V25Protection.SerializeState(State: TStateArchive);
begin
  // The WonderSwan loader normalizes V30MZ reserved flag bits. Keep the V25
  // flags exactly as saved, while validating the shared instruction/prefetch state.
  State.Field(FCPU.State, SizeOf(FCPU.State));
  if (FCPU.State.QueueCount > 16) or (FCPU.State.QueueHead > 15) or
    (FCPU.State.RepeatSeg < -1) or (FCPU.State.RepeatSeg > 3) or (FCPU.State.IRQShadow > 1) then
    raise EReadError.Create('Invalid System 32 V25 processor state');
  State.Field(Shared, SizeOf(Shared));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FTime, SizeOf(FTime));
  if FTime < 0 then
    raise EReadError.Create('Invalid System 32 V25 clock state');
end;

end.

