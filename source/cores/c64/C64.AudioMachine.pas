unit C64.AudioMachine;

interface

uses
  System.SysUtils, C64.CPU, C64.Sound.SID;

type
  TC64AudioMachine = class
  private
    FCPU: TCPU6510;
    FChips: array[0..2] of TSID;
    FBases: array[0..2] of Word;
    FChipCount, FClock, FPeriod, FUntilPlay, FCycle, FBudget: Integer;
    FPlay: Word;
    FCIA, FActive, FIRQCall, FKernelIRQ, FInitializing: Boolean;
    FPhase: Double;
    FIO: array[0..4095] of Byte;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function PortValue: Byte;
    function IOEnabled: Boolean;
    procedure StartCall(Address: Word; IRQ: Boolean);
    procedure Tick;
  public
    RAM: array[0..65535] of Byte;
    constructor Create(Clock: Integer; const Bases: array of Word; const Models: array of TSIDModel);
    destructor Destroy; override;
    procedure Start(Init, Play: Word; Track: Byte; CIA: Boolean);
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

constructor TC64AudioMachine.Create(Clock: Integer; const Bases: array of Word; const Models: array of TSIDModel);
begin
  inherited Create;
  if (Clock < 500000) or (Clock > 2000000) or (Length(Bases) < 1) or (Length(Bases) > 3) or (Length(Bases) <> Length(Models)) then
    raise EArgumentException.Create('Invalid C64 audio configuration');
  FClock := Clock;
  FChipCount := Length(Bases);
  FCPU := TCPU6510.Create;
  FCPU.Connect(ReadMemory, WriteMemory);
  for var I := 0 to FChipCount - 1 do
  begin
    FBases[I] := Bases[I];
    FChips[I] := TSID.Create(Models[I], Clock);
  end;
end;

destructor TC64AudioMachine.Destroy;
begin
  for var I := 0 to 2 do
    FChips[I].Free;
  FCPU.Free;
  inherited;
end;

function TC64AudioMachine.PortValue: Byte;
begin
  Result := (RAM[1] and RAM[0]) or (RAM[0] xor 255);
end;

function TC64AudioMachine.IOEnabled: Boolean;
begin
  var Port := PortValue;
  Result := ((Port and 3) <> 0) and ((Port and 4) <> 0);
end;

function TC64AudioMachine.ReadMemory(Address: Word): Byte;
const
  Epilogue: array[0..5] of Byte = ($68, $A8, $68, $AA, $68, $40);
begin
  if Address = 1 then
    Exit(PortValue);

  if (PortValue and 2) <> 0 then
  begin
    if (Address >= $EA31) and (Address <= $EA36) then
      Exit(Epilogue[Address - $EA31]);
    if Address = $EA81 then
      Exit($40);
  end;

  if IOEnabled and (Address >= $D000) and (Address <= $DFFF) then
  begin
    for var I := FChipCount - 1 downto 1 do
      if (Address >= FBases[I]) and (Integer(Address) < Integer(FBases[I]) + 32) then
        Exit(FChips[I].ReadRegister(Address - FBases[I]));

    if (Address >= $D400) and (Address < $D800) then
      Exit(FChips[0].ReadRegister(Address and 31));

    if Address = $D012 then
    begin
      if FClock = 985248 then
        Exit((FCycle div 63) and 255)
      else
        Exit((FCycle div 65) and 255);
    end;

    if Address = $DC0D then
    begin
      Result := FIO[$C0D];
      FIO[$C0D] := 0;
      Exit;
    end;

    Exit(FIO[Address and $FFF]);
  end;
  Result := RAM[Address];
end;

procedure TC64AudioMachine.WriteMemory(Address: Word; Value: Byte);
begin
  if IOEnabled and (Address >= $D000) and (Address <= $DFFF) then
  begin
    for var I := FChipCount - 1 downto 1 do
      if (Address >= FBases[I]) and (Integer(Address) < Integer(FBases[I]) + 32) then
      begin
        FChips[I].WriteRegister(Address - FBases[I], Value);
        Exit;
      end;

    if (Address >= $D400) and (Address < $D800) then
    begin
      FChips[0].WriteRegister(Address and 31, Value);
      Exit;
    end;

    FIO[Address and $FFF] := Value;
    if FCIA and ((Address = $DC05) or (Address = $DC0E)) then
    begin
      var Timer := Integer(FIO[$C04]) + Integer(FIO[$C05]) * 256;
      if Timer = 0 then
        Timer := 65536;
      FPeriod := Timer;
    end;
    if Address = $D019 then
      FIO[$019] := 0;
  end
  else
    RAM[Address] := Value;
end;

procedure TC64AudioMachine.StartCall(Address: Word; IRQ: Boolean);
begin
  FCPU.Sp := $FD;
  FCPU.Pc := Address;
  FCPU.P := (FCPU.P or $24) and $EF;
  // RTS returns to the sentinel; IRQ players use the conventional KERNAL epilogue.
  RAM[$1FE] := $FE;
  RAM[$1FF] := $FF;
  if IRQ then
  begin
    RAM[$1FF] := $FF;
    RAM[$1FE] := $FF;
    RAM[$1FD] := FCPU.P;
    FCPU.Sp := $FC;
    if FKernelIRQ then
    begin
      RAM[$1FC] := FCPU.A;
      RAM[$1FB] := FCPU.X;
      RAM[$1FA] := FCPU.Y;
      FCPU.Sp := $F9;
    end;
  end;
  FActive := True;
  FBudget := FClock * 2;
end;

procedure TC64AudioMachine.Start(Init, Play: Word; Track: Byte; CIA: Boolean);
begin
  FillChar(FIO, SizeOf(FIO), 0);
  RAM[0] := $2F;
  RAM[1] := $37;
  FCIA := CIA;
  FPlay := Play;
  FIRQCall := Play = 0;
  FInitializing := True;
  if CIA then
    FPeriod := FClock div 60
  else if FClock = 985248 then
    FPeriod := 312 * 63
  else
    FPeriod := 263 * 65;
  FIO[$C04] := FPeriod and 255;
  FIO[$C05] := FPeriod shr 8;
  FCycle := 0;
  FPhase := 0;
  FUntilPlay := FPeriod;
  for var I := 0 to FChipCount - 1 do
    FChips[I].Reset;
  FCPU.Reset;
  while FCPU.CyclesRemaining > 0 do
    FCPU.Clock;
  FCPU.A := Track;
  FCPU.X := Ord(FClock <> 985248);
  FCPU.Y := 0;
  StartCall(Init, False);
  while FActive do
    Tick;
  if FPlay = 0 then
  begin
    FPlay := Integer(RAM[$314]) + Integer(RAM[$315]) * 256;
    FKernelIRQ := FPlay <> 0;
    if FPlay = 0 then
      FPlay := Integer(RAM[$FFFE]) + Integer(RAM[$FFFF]) * 256;
    if FPlay = 0 then
      raise ENotSupportedException.Create('SID IRQ player has no interrupt vector');
  end;
  for var I := 0 to FChipCount - 1 do
    FChips[I].Sample;
  FUntilPlay := FPeriod;
  FInitializing := False;
end;

procedure TC64AudioMachine.Tick;
begin
  if FActive then
  begin
    if FCPU.Jammed then
      raise EArgumentException.Create('SID player halted the CPU');

    Dec(FBudget);
    if FBudget <= 0 then
      raise ENotSupportedException.Create('SID routine exceeded the execution budget (ROM-dependent player?)');

    FCPU.Clock;
    if (FCPU.Pc = $FFFF) and (FCPU.CyclesRemaining = 0) then
      FActive := False;
  end;
  for var I := 0 to FChipCount - 1 do
    FChips[I].Clock;
  Inc(FCycle);
  if FClock = 985248 then
    FCycle := FCycle mod (312 * 63)
  else
    FCycle := FCycle mod (263 * 65);
  if not FInitializing then
  begin
    Dec(FUntilPlay);
    if FUntilPlay <= 0 then
    begin
      Inc(FUntilPlay, FPeriod);
      if FActive then
        raise ENotSupportedException.Create('SID play routine did not finish before the next frame');

      FIO[$019] := $81;
      FIO[$C0D] := $81;
      if FIRQCall then
      begin
        var Vector := Integer(RAM[$314]) + Integer(RAM[$315]) * 256;
        FKernelIRQ := Vector <> 0;
        if FKernelIRQ then
          FPlay := Vector
        else
          FPlay := Integer(RAM[$FFFE]) + Integer(RAM[$FFFF]) * 256;
      end;
      StartCall(FPlay, FIRQCall);
    end;
  end;
end;

procedure TC64AudioMachine.Sample(out Left, Right: SmallInt);
begin
  FPhase := FPhase + FClock / 44100.0;
  var Count := Trunc(FPhase);
  FPhase := FPhase - Count;
  for var I := 1 to Count do
    Tick;
  var L, R: Integer;
  L := FChips[0].Sample;
  R := L;
  if FChipCount > 1 then
    R := FChips[1].Sample;
  if FChipCount > 2 then
  begin
    var Center := FChips[2].Sample;
    L := (L + Center) div 2;
    R := (R + Center) div 2;
  end;
  Left := L;
  Right := R;
end;

end.

