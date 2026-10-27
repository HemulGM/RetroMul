unit ZX.GeneralSound;

interface

uses
  System.SysUtils, MD.Z80, Core.Snapshots;

type
  // Classic 12 MHz GS, not NeoGS. Commands are executed by its guest ROM.
  TZXGeneralSound = class
  protected
    FCPU: TZ80State;
    FCallbacks: TZ80ReadAndWriteCallbacks;
    FROM, FRAM: TBytes;
    FRAMKB, FPhase, FDebt, FIRQPhase: Integer;
    FClocks: UInt64;
    FPage, FCommand, FStatus, FToGS, FToHost: Byte;
    FSample, FVolume: array[0..7] of Byte;
    function RAMOffset(Address: Word): Integer;
    procedure Clock(Kind: TZ80BusCycle; Count: Cardinal); virtual;
    function ExecuteInstruction: Cardinal; virtual;
    function ClockHz: Integer; virtual;
    constructor CreateBoard(RAMKB: Integer; const Resource: string; ROMSize: Integer);
  public
    constructor Create(RAMKB: Integer);
    procedure Reset; virtual;
    procedure Tick(HostClock: Integer); virtual;
    function HostRead(Address: Word; out Value: Byte): Boolean; virtual;
    procedure HostWrite(Address: Word; Value: Byte); virtual;
    function ReadMemory(Address: Word): Byte; virtual;
    procedure WriteMemory(Address: Word; Value: Byte); virtual;
    function ReadPort(Address: Word): Byte; virtual;
    procedure WritePort(Address: Word; Value: Byte); virtual;
    procedure Levels(out Left, Right: Double); virtual;
    procedure SerializeState(State: TStateArchive); virtual;
    property CPU: TZ80State read FCPU;
    property Clocks: UInt64 read FClocks;
    property RAMKB: Integer read FRAMKB;
  end;

implementation

uses
  System.Classes;

function GSRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXGeneralSound(Context).ReadMemory(Word(Address and $FFFF));
end;

procedure GSWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TZXGeneralSound(Context).WriteMemory(Word(Address and $FFFF), Byte(Value and 255));
end;

function GSIn(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXGeneralSound(Context).ReadPort(Word(Address and $FFFF));
end;

procedure GSOut(Context: Pointer; Address, Value: Cardinal);
begin
  TZXGeneralSound(Context).WritePort(Word(Address and $FFFF), Byte(Value and 255));
end;

procedure GSClock(Context: Pointer; Kind: TZ80BusCycle; Address, Count: Cardinal);
begin
  TZXGeneralSound(Context).Clock(Kind, Count);
end;

constructor TZXGeneralSound.Create(RAMKB: Integer);
begin
  if (RAMKB <> 128) and (RAMKB <> 512) then
    raise EArgumentException.Create('Unsupported General Sound RAM size');
  CreateBoard(RAMKB, 'ZX_GS105B', 32768);
  Reset;
end;

constructor TZXGeneralSound.CreateBoard(RAMKB: Integer; const Resource: string; ROMSize: Integer);
begin
  inherited Create;
  FRAMKB := RAMKB;
  SetLength(FRAM, RAMKB * 1024);
  var Stream := TResourceStream.Create(HInstance, Resource, PChar(10));
  try
    if Stream.Size <> ROMSize then
      raise EReadError.Create('Invalid General Sound ROM');
    SetLength(FROM, ROMSize);
    Stream.ReadBuffer(FROM[0], Length(FROM));
  finally
    Stream.Free;
  end;
  FCallbacks := Default(TZ80ReadAndWriteCallbacks);
  FCallbacks.UserData := Self;
  FCallbacks.ReadCallback := GSRead;
  FCallbacks.WriteCallback := GSWrite;
  FCallbacks.PortReadCallback := GSIn;
  FCallbacks.PortWriteCallback := GSOut;
  FCallbacks.CycleCallback := GSClock;
end;

procedure TZXGeneralSound.Reset;
begin
  FCPU := Default(TZ80State);
  Z80Reset(FCPU);
  FillChar(FRAM[0], Length(FRAM), 0);
  FillChar(FSample, SizeOf(FSample), $80);
  FillChar(FVolume, SizeOf(FVolume), 0);
  FPage := 0;
  FStatus := 0;
  FCommand := 0;
  FToGS := 0;
  FToHost := 0;
  FPhase := 0;
  FDebt := 0;
  FIRQPhase := 0;
  FClocks := 0;
end;

function TZXGeneralSound.RAMOffset(Address: Word): Integer;
begin
  Result := -1;
  if (Address >= $4000) and (Address < $8000) then
    Exit(Integer(Address)); // upper half of RAM page 1
  if (Address < $8000) or (FPage = 0) then
    Exit;
  // Base board has pages 1..4. Classic GS512 decodes pages 1..15;
  // its documented missing 32 KiB is not replaced with fictitious RAM.
  var Pages := 4;
  if FRAMKB = 512 then
    Pages := 15;
  if FPage <= Pages then
    Result := (Integer(FPage) - 1) * $8000 + (Address and $7FFF);
end;

function TZXGeneralSound.ReadMemory(Address: Word): Byte;
begin
  if Address < $4000 then
    Result := FROM[Address]
  else if (Address >= $8000) and (FPage = 0) then
    Result := FROM[Address and $7FFF]
  else
  begin
    var Offset := RAMOffset(Address);
    if Offset < 0 then
      Result := $FF
    else
      Result := FRAM[Offset];
  end;
  // M1 instruction fetches use this same bus path, unlike refresh cycles.
  if (Address and $E000) = $6000 then
    FSample[(Address shr 8) and 3] := Result;
end;

procedure TZXGeneralSound.WriteMemory(Address: Word; Value: Byte);
begin
  var Offset := RAMOffset(Address);
  if Offset >= 0 then
    FRAM[Offset] := Value;
end;

function TZXGeneralSound.HostRead(Address: Word; out Value: Byte): Boolean;
begin
  Value := $FF;
  Result := True;
  // Original diode decoder: A7/A5/A4=1, A6/A2=0, A1/A0=1.
  // A3 selects data/command; high address byte is not decoded.
  case Address and $FF of
    $B3:
      begin
        Value := FToHost;
        FStatus := FStatus and $7F;
      end;
    $BB:
      Value := FStatus or $7E;
  else
    Result := False;
  end;
end;

procedure TZXGeneralSound.HostWrite(Address: Word; Value: Byte);
begin
  case Address and $FF of
    $B3:
      begin
        FToGS := Value;
        FStatus := FStatus or $80;
      end;
    $BB:
      begin
        FCommand := Value;
        FStatus := FStatus or 1;
      end;
  end;
end;

function TZXGeneralSound.ReadPort(Address: Word): Byte;
begin
  Result := $FF;
  // Only A0..A3 feed DD10/DD11. All upper bits are aliases.
  case Address and 15 of
    1:
      Result := FCommand;
    2:
      begin
        Result := FToGS;
        FStatus := FStatus and $7F;
      end;
    3:
      begin
        FToHost := $FF;
        FStatus := FStatus or $80;
      end;
    4:
      Result := FStatus;
    5:
      FStatus := FStatus and $FE;
    10:
      FStatus := (FStatus and $7F) or ((1 - (FPage and 1)) shl 7);
    11:
      FStatus := (FStatus and $FE) or (FVolume[0] shr 5);
    // Write-only latches see the pulled-up internal data bus on IN.
      0, 6..9:
      WritePort(Address, $FF);
  end;
end;

procedure TZXGeneralSound.WritePort(Address: Word; Value: Byte);
begin
  case Address and 15 of
    0:
      FPage := Value and 15;
    2:
      FStatus := FStatus and $7F;
    3:
      begin
        FToHost := Value;
        FStatus := FStatus or $80;
      end;
    5:
      FStatus := FStatus and $FE;
    6..9:
      FVolume[(Address and 15) - 6] := Value and $3F;
    10:
      FStatus := (FStatus and $7F) or ((1 - (FPage and 1)) shl 7);
    11:
      FStatus := (FStatus and $FE) or (FVolume[0] shr 5);
  end;
end;

procedure TZXGeneralSound.Clock(Kind: TZ80BusCycle; Count: Cardinal);
begin
  Inc(FClocks, Count);
  FIRQPhase := (FIRQPhase + Integer(Count)) mod 320;
  // DD18 /5, DD19.2 /4, DD19.1 /16: a 37.5 kHz square wave.
  Z80Interrupt(FCPU, Ord(FIRQPhase < 160));
end;

function TZXGeneralSound.ClockHz: Integer;
begin
  Result := 12000000;
end;

function TZXGeneralSound.ExecuteInstruction: Cardinal;
begin
  Result := Z80DoInstruction(FCPU, FCallbacks);
end;

procedure TZXGeneralSound.Tick(HostClock: Integer);
begin
  if (HostClock < 1000000) or (HostClock > 30000000) then
    raise EArgumentException.Create('Invalid General Sound host clock');
  Inc(FPhase, ClockHz);
  Inc(FDebt, FPhase div HostClock);
  FPhase := FPhase mod HostClock;
  // Integer clock conversion keeps both oscillators independent. The shared
  // Z80 finishes its current instruction; the overshoot is repaid next tick.
  while FDebt > 0 do
    Dec(FDebt, Integer(ExecuteInstruction));
end;

procedure TZXGeneralSound.Levels(out Left, Right: Double);
begin
  Left := ((Integer(FSample[0]) - 128) * FVolume[0] +
    (Integer(FSample[1]) - 128) * FVolume[1]) / (128.0 * 63 * 2) * 0.25;
  Right := ((Integer(FSample[2]) - 128) * FVolume[2] +
    (Integer(FSample[3]) - 128) * FVolume[3]) / (128.0 * 63 * 2) * 0.25;
end;

procedure TZXGeneralSound.SerializeState(State: TStateArchive);
begin
  var Size := FRAMKB;
  State.Field(Size, SizeOf(Size));
  if Size <> FRAMKB then
    raise EReadError.Create('Mismatched General Sound RAM');
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM[0], Length(FRAM));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FDebt, SizeOf(FDebt));
  State.Field(FIRQPhase, SizeOf(FIRQPhase));
  State.Field(FClocks, SizeOf(FClocks));
  State.Field(FPage, SizeOf(FPage));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FToGS, SizeOf(FToGS));
  State.Field(FToHost, SizeOf(FToHost));
  State.Field(FSample, SizeOf(FSample));
  State.Field(FVolume, SizeOf(FVolume));
  if (FPage > 15) or ((FStatus and $7E) <> 0) or (FPhase < 0) or
    (FPhase >= 30000000) or (FDebt > 0) or (FDebt < -65536) or
    (FIRQPhase < 0) or (FIRQPhase >= 320) or (FCPU.InterruptMode > 2) or
    (FCPU.EIDelay > 2) then
    raise EReadError.Create('Invalid General Sound state');
  for var C := 0 to 7 do
    if FVolume[C] > 63 then
      raise EReadError.Create('Invalid General Sound volume');
end;

end.

