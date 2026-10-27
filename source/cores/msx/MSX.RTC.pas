unit MSX.RTC;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  // Ricoh RP5C01, 32.768 kHz divider driven by emulated CPU time. No host
  // clock adjustments are made during replay or while loading battery RAM.
  TMSXRTC = class
  private
    FRegisters: array[0..3, 0..12] of Byte;
    FAddress, FMode, FReset: Byte;
    FPhase: Integer;
    FCarryHeld, FAlarm: Boolean;
    procedure Second;
    procedure Minute;
    procedure Day;
    procedure UpdateAlarm;
  public
    constructor Create;
    procedure ResetBus;
    procedure Select(Value: Byte);
    function ReadData: Byte;
    procedure WriteData(Value: Byte);
    procedure Advance(Cycles: Integer);
    procedure ElapseSeconds(Seconds: Int64);
    procedure SerializeState(State: TStateArchive);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    function AlarmPin: Boolean;
  end;

implementation

const
  Masks: array[0..1, 0..12] of Byte = (
    (15, 7, 15, 7, 15, 3, 7, 15, 3, 15, 1, 15, 15),
    (0, 0, 15, 7, 15, 3, 7, 15, 3, 0, 1, 3, 0));

constructor TMSXRTC.Create;
begin
  inherited;
  // Deterministic fresh battery: 1980-01-01, 24h, leap-year counter zero.
  FRegisters[0, 7] := 1;
  FRegisters[0, 9] := 1;
  FRegisters[0, 6] := 2;
  FRegisters[1, 10] := 1;
  FMode := 8;
  FReset := $0C;
  ResetBus;
end;

procedure TMSXRTC.ResetBus;
begin
  FAddress := 0;
end;

procedure TMSXRTC.Select(Value: Byte);
begin
  FAddress := Value and 15;
end;

function TMSXRTC.ReadData: Byte;
begin
  Result := $FF;
  if FAddress = 13 then
    Exit($F0 or FMode);
  if FAddress < 13 then
    Result := $F0 or FRegisters[FMode and 3, FAddress];
end;

procedure TMSXRTC.UpdateAlarm;
begin
  if FReset and 1 <> 0 then
  begin
    FAlarm := False;
    Exit;
  end;
  // Alarm compares minute, hour, weekday and day digits. The reset controller
  // clears the alarm latch; the physical ALARM pin is not wired to the MSX IRQ.
  var Match := True;
  for var I := 2 to 8 do
    Match := Match and (FRegisters[0, I] = FRegisters[1, I]);
  if Match then
    FAlarm := True;
end;

procedure TMSXRTC.WriteData(Value: Byte);
begin
  Value := Value and 15;
  if FAddress < 13 then
  begin
    var Bank := FMode and 3;
    if Bank < 2 then
      Value := Value and Masks[Bank, FAddress];
    FRegisters[Bank, FAddress] := Value;
    UpdateAlarm;
  end
  else if FAddress = 13 then
  begin
    var WasRunning := FMode and 8 <> 0;
    FMode := Value;
    if not WasRunning and (Value and 8 <> 0) and FCarryHeld then
    begin
      FCarryHeld := False;
      Second;
    end;
  end
  else if FAddress = 15 then
  begin
    FReset := Value;
    if Value and 1 <> 0 then
    begin
      for var I := 2 to 8 do
        FRegisters[1, I] := 0;
      FAlarm := False;
    end;
    if Value and 2 <> 0 then
    begin
      FPhase := 0;
      FCarryHeld := False;
    end;
  end;
  // TEST register is an oscillator test input, not ordinary battery RAM.
end;

procedure TMSXRTC.Day;
const
  MonthDays: array[1..12] of Integer = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  FRegisters[0, 6] := (FRegisters[0, 6] + 1) mod 7;
  var D := FRegisters[0, 7] + 10 * FRegisters[0, 8] + 1;
  var M := FRegisters[0, 9] + 10 * FRegisters[0, 10];
  var Limit := 31;
  if (M >= 1) and (M <= 12) then
    Limit := MonthDays[M];
  if (M = 2) and (FRegisters[1, 11] = 0) then
    Limit := 29;
  if D > Limit then
  begin
    D := 1;
    Inc(M);
    if M > 12 then
    begin
      M := 1;
      var Y := (FRegisters[0, 11] + 10 * FRegisters[0, 12] + 1) mod 100;
      FRegisters[0, 11] := Y mod 10;
      FRegisters[0, 12] := Y div 10;
      FRegisters[1, 11] := (FRegisters[1, 11] + 1) and 3;
    end;
    FRegisters[0, 9] := M mod 10;
    FRegisters[0, 10] := M div 10;
  end;
  FRegisters[0, 7] := D mod 10;
  FRegisters[0, 8] := D div 10;
end;

procedure TMSXRTC.Minute;
begin
  var M := FRegisters[0, 2] + 10 * FRegisters[0, 3] + 1;
  FRegisters[0, 2] := M mod 60 mod 10;
  FRegisters[0, 3] := M mod 60 div 10;
  if M < 60 then
    Exit;
  var H := FRegisters[0, 4] + 10 * (FRegisters[0, 5] and 1);
  if FRegisters[1, 10] <> 0 then
  begin
    H := FRegisters[0, 4] + 10 * FRegisters[0, 5] + 1;
    if H >= 24 then
    begin
      H := 0;
      Day;
    end;
    FRegisters[0, 4] := H mod 10;
    FRegisters[0, 5] := H div 10;
  end
  else
  begin
    var PM := FRegisters[0, 5] and 2;
    Inc(H);
    if H = 12 then
    begin
      PM := PM xor 2;
      if PM = 0 then
        Day;
    end
    else if H > 12 then
      H := 1;
    FRegisters[0, 4] := H mod 10;
    FRegisters[0, 5] := (H div 10) or PM;
  end;
end;

procedure TMSXRTC.Second;
begin
  var S := FRegisters[0, 0] + 10 * FRegisters[0, 1] + 1;
  FRegisters[0, 0] := S mod 60 mod 10;
  FRegisters[0, 1] := S mod 60 div 10;
  if S >= 60 then
    Minute;
  UpdateAlarm;
end;

procedure TMSXRTC.Advance(Cycles: Integer);
begin
  if Cycles < 0 then
    raise EArgumentOutOfRangeException.Create('RTC clocks');
  if FReset and 2 <> 0 then
    Exit;
  var Ticks := Int64(FPhase) + Cycles;
  while Ticks >= 3579545 do
  begin
    Dec(Ticks, 3579545);
    if FMode and 8 <> 0 then
      Second
    else
      FCarryHeld := True;
  end;
  FPhase := Integer(Ticks);
end;

procedure TMSXRTC.ElapseSeconds(Seconds: Int64);
begin
  if (Seconds <= 0) or (FMode and 8 = 0) or (FReset and 2 <> 0) then
    Exit;
  // Used only once when loading battery-backed hardware, before emulation.
  // A complete 700-year cycle repeats year/leap/weekday; skip huge intervals.
  Seconds := Seconds mod (Int64(36525) * 7 * 86400);
  var H := FRegisters[0, 4] + 10 * FRegisters[0, 5];
  if FRegisters[1, 10] = 0 then
  begin
    H := (FRegisters[0, 4] + 10 * (FRegisters[0, 5] and 1)) mod 12;
    if FRegisters[0, 5] and 2 <> 0 then
      Inc(H, 12);
  end;
  var Total := Seconds + H * 3600 + (FRegisters[0, 2] + 10 * FRegisters[0, 3]) * 60 +
    FRegisters[0, 0] + 10 * FRegisters[0, 1];
  var Days := Total div 86400;
  for var I := Int64(1) to Days do
    Day;
  H := Total mod 86400 div 3600;
  var M := Total mod 3600 div 60;
  var S := Total mod 60;
  FRegisters[0, 0] := S mod 10;
  FRegisters[0, 1] := S div 10;
  FRegisters[0, 2] := M mod 10;
  FRegisters[0, 3] := M div 10;
  if FRegisters[1, 10] <> 0 then
  begin
    FRegisters[0, 4] := H mod 10;
    FRegisters[0, 5] := H div 10;
  end
  else
  begin
    var PM := Ord(H >= 12) * 2;
    H := H mod 12;
    if H = 0 then
      H := 12;
    FRegisters[0, 4] := H mod 10;
    FRegisters[0, 5] := (H div 10) or PM;
  end;
  UpdateAlarm;
end;

function TMSXRTC.AlarmPin: Boolean;
begin
  // Open-drain output: False when any enabled source pulls the pin low.
  Result := not ((FMode and 4 <> 0) and FAlarm and (FReset and 1 = 0));
  if FReset and 8 = 0 then
    Result := Result and (FPhase < 3579545 div 2);
  if FReset and 4 = 0 then
    Result := Result and (((Int64(FPhase) * 32) div 3579545) and 1 = 0);
end;

function TMSXRTC.Battery: TBytes;
begin
  SetLength(Result, SizeOf(FRegisters) + 2);
  Move(FRegisters, Result[0], SizeOf(FRegisters));
  Result[SizeOf(FRegisters)] := FMode;
  Result[SizeOf(FRegisters) + 1] := FReset;
end;

procedure TMSXRTC.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FRegisters) + 2 then
    raise EReadError.Create('Invalid MSX RTC battery data');
  for var V in Data do
    if V > 15 then
      raise EReadError.Create('Invalid MSX RTC battery nibble');
  Move(Data[0], FRegisters, SizeOf(FRegisters));
  for var Bank := 0 to 1 do
    for var I := 0 to 12 do
      FRegisters[Bank, I] := FRegisters[Bank, I] and Masks[Bank, I];
  FMode := Data[SizeOf(FRegisters)];
  FReset := Data[SizeOf(FRegisters) + 1];
  FPhase := 0;
  FCarryHeld := False;
  FAlarm := False;
end;

procedure TMSXRTC.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FReset, SizeOf(FReset));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FCarryHeld, SizeOf(FCarryHeld));
  State.Field(FAlarm, SizeOf(FAlarm));
  if State.Loading then
  begin
    if (FAddress > 15) or (FMode > 15) or (FReset > 15) or (FPhase < 0) or (FPhase >= 3579545) then
      raise EReadError.Create('Invalid MSX RTC state');
    for var Bank := 0 to 3 do
      for var V in FRegisters[Bank] do
        if V > 15 then
          raise EReadError.Create('Invalid MSX RTC register state');
  end;
end;

end.

