unit CV.Controller;

interface

uses
  Core.Snapshots;

type
  // One independent optical encoder. Host motion supplies relative counts or
  // stick velocity; the console sees finite quadrature pulses and level IRQ.
  TCVSpinner = class
  private
    FPending, FTimer, FMousePeriod, FVelocityPeriod, FVelocity: Integer;
    FPulse, FIRQ, FDirection: Integer;
    function Period: Integer;
    function Active: Boolean;
  public
    procedure Reset;
    procedure Move(Delta, FrameClocks: Integer);
    procedure SetVelocity(Value: Integer);
    procedure Advance(Clocks: Integer);
    function ClocksUntilEvent: Integer;
    function IRQ: Boolean;
    function PortValue(Value: Byte; Joystick: Boolean): Byte;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

const
  ClockRate = 3579545;
  PulseClocks = 1790; // 500 us monostable; physical RC tolerance is not modelled.
  IRQClocks = 40;     // Approximately 11 us; see Coleco controller circuitry.

procedure TCVSpinner.Reset;
begin
  FPending := 0;
  FTimer := 0;
  FMousePeriod := 0;
  FVelocityPeriod := 0;
  FVelocity := 0;
  FPulse := 0;
  FIRQ := 0;
  FDirection := 0;
end;

function TCVSpinner.Active: Boolean;
begin
  Result := (FPending <> 0) or (FVelocity <> 0);
end;

function TCVSpinner.Period: Integer;
begin
  if FPending <> 0 then
    Result := FMousePeriod
  else
    Result := FVelocityPeriod;
  Result := Max(PulseClocks + 1, Result);
end;

procedure TCVSpinner.Move(Delta, FrameClocks: Integer);
begin
  Delta := EnsureRange(Delta, -4096, 4096);
  if Delta = 0 then
    Exit;
  FPending := EnsureRange(FPending + Delta, -4096, 4096);
  FMousePeriod := Max(PulseClocks + 1, FrameClocks div Abs(Delta));
  if FTimer = 0 then
    FTimer := Period
  else
    FTimer := Min(FTimer, Period);
end;

procedure TCVSpinner.SetVelocity(Value: Integer);
begin
  Value := EnsureRange(Value, -32767, 32767);
  var Rate := Max(0, Abs(Value) - 4096) * 1600 div (32767 - 4096);
  FVelocity := 0;
  FVelocityPeriod := 0;
  if Rate > 0 then
  begin
    FVelocity := Sign(Value);
    FVelocityPeriod := ClockRate div Rate;
  end;
  if not Active then
    FTimer := 0
  else if FTimer = 0 then
    FTimer := Period
  else
    FTimer := Min(FTimer, Period);
end;

function TCVSpinner.ClocksUntilEvent: Integer;
begin
  Result := MaxInt;
  if FTimer > 0 then
    Result := Min(Result, FTimer);
  if FPulse > 0 then
    Result := Min(Result, FPulse);
  if FIRQ > 0 then
    Result := Min(Result, FIRQ);
end;

procedure TCVSpinner.Advance(Clocks: Integer);
begin
  while Clocks > 0 do
  begin
    var Part := Min(Clocks, ClocksUntilEvent);
    Dec(Clocks, Part);
    FPulse := Max(0, FPulse - Part);
    FIRQ := Max(0, FIRQ - Part);
    if FTimer > 0 then
    begin
      Dec(FTimer, Part);
      if FTimer = 0 then
      begin
        if FPending <> 0 then
        begin
          FDirection := Sign(FPending);
          Dec(FPending, FDirection);
        end
        else
          FDirection := FVelocity;
        FPulse := PulseClocks;
        FIRQ := IRQClocks;
        if Active then
          FTimer := Period;
      end;
    end;
  end;
end;

function TCVSpinner.IRQ: Boolean;
begin
  Result := FIRQ > 0;
end;

function TCVSpinner.PortValue(Value: Byte; Joystick: Boolean): Byte;
begin
  Result := Value;
  if FPulse = 0 then
    Exit;
  Result := Result or $80;
  if Joystick then
    if FDirection < 0 then
      Result := Result xor $30
    else
      Result := Result xor $10;
end;

procedure TCVSpinner.SerializeState(State: TStateArchive);
begin
  State.Field(FPending, SizeOf(FPending));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FMousePeriod, SizeOf(FMousePeriod));
  State.Field(FVelocityPeriod, SizeOf(FVelocityPeriod));
  State.Field(FVelocity, SizeOf(FVelocity));
  State.Field(FPulse, SizeOf(FPulse));
  State.Field(FIRQ, SizeOf(FIRQ));
  State.Field(FDirection, SizeOf(FDirection));
  if State.Loading and ((Abs(Int64(FPending)) > 4096) or
    (FTimer < 0) or (FTimer > ClockRate) or
    (FMousePeriod < 0) or (FMousePeriod > 228 * 313) or
    (FVelocityPeriod < 0) or (FVelocityPeriod > ClockRate) or
    (Abs(Int64(FVelocity)) > 1) or (Abs(Int64(FDirection)) > 1) or
    (FPulse < 0) or (FPulse > PulseClocks) or (FIRQ < 0) or (FIRQ > IRQClocks)) then
    raise EReadError.Create('Invalid ColecoVision encoder state');
end;

end.

