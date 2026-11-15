unit J2ME.Effects;

interface

type
  // Emulated motor duty, independent of any physical actuator or frontend.
  TJ2MEVibrationSample = record
    Area: Double; // percent * milliseconds
    Millis: Int64;
    function Level: Byte;
  end;

  // One owner: the VM executor. Consumers receive accumulated motor duty;
  // platform effects are applied by the existing frontend rumble path.
  TJ2MEDeviceEffects = class
  private
    FBacklight, FPresented, FVibration: Integer;
    FFlashStart, FFlashUntil, FVibrationUntil, FLastNow: Int64;
    FPending: TJ2MEVibrationSample;
    procedure Advance(Now: Int64);
  public
    constructor Create(Now: Int64);
    procedure SetBacklight(Level: Integer; CancelFlash: Boolean = False);
    procedure FlashBacklight(Duration, Now: Int64);
    procedure SetVibration(Strength: Integer; Duration, Now: Int64);
    function TakeVibration(Now: Int64): TJ2MEVibrationSample;
    function Poll(Now: Int64): Boolean;
    procedure ApplyBacklight(var Pixels: TArray<UInt32>);
    procedure Shutdown(Now: Int64);
  end;

implementation

uses
  System.Math, System.SysUtils;

function Deadline(Now, Duration: Int64): Int64;
begin
  if Duration > High(Int64) - Now then
    Result := High(Int64)
  else
    Result := Now + Duration;
end;

function TJ2MEVibrationSample.Level: Byte;
begin
  Result := 0;
  if Millis > 0 then
    Result := Byte(EnsureRange(Round(Area / Millis * 255 / 100), Int64(0), Int64(255)));
end;

constructor TJ2MEDeviceEffects.Create(Now: Int64);
begin
  inherited Create;
  if Now < 0 then
    raise EArgumentOutOfRangeException.Create('Device effect clock');
  FLastNow := Now;
  FBacklight := 100;
  FPresented := 100;
end;

procedure TJ2MEDeviceEffects.Advance(Now: Int64);
begin
  if Now <= FLastNow then
    Exit;
  Inc(FPending.Millis, Now - FLastNow);
  var UntilTime := Now;
  if (FVibrationUntil >= 0) and (FVibrationUntil < UntilTime) then
    UntilTime := FVibrationUntil;
  if UntilTime > FLastNow then
    FPending.Area := FPending.Area + Double(UntilTime - FLastNow) * FVibration;
  if (FVibrationUntil >= 0) and (Now >= FVibrationUntil) then
    FVibration := 0;
  FLastNow := Now;
end;

procedure TJ2MEDeviceEffects.SetBacklight(Level: Integer; CancelFlash: Boolean);
begin
  if (Level < 0) or (Level > 100) then
    raise EArgumentOutOfRangeException.Create('Backlight level');
  FBacklight := Level;
  if CancelFlash then
    FFlashUntil := 0;
end;

procedure TJ2MEDeviceEffects.FlashBacklight(Duration, Now: Int64);
begin
  if (Duration < 0) or (Now < 0) then
    raise EArgumentOutOfRangeException.Create('Backlight duration');
  FFlashUntil := 0;
  if Duration <> 0 then
  begin
    FFlashStart := Now;
    FFlashUntil := Deadline(Now, Duration);
  end;
end;

procedure TJ2MEDeviceEffects.SetVibration(Strength: Integer; Duration, Now: Int64);
begin
  if (Strength < 0) or (Strength > 100) or (Duration < -1) or (Now < 0) then
    raise EArgumentOutOfRangeException.Create('Vibration request');
  Advance(Now);
  FVibration := Strength;
  if Duration = -1 then
    FVibrationUntil := -1
  else
    FVibrationUntil := Deadline(Now, Duration);
  if (Duration = 0) or (Strength = 0) then
  begin
    FVibration := 0;
    FVibrationUntil := 0;
  end;
end;

function TJ2MEDeviceEffects.TakeVibration(Now: Int64): TJ2MEVibrationSample;
begin
  Advance(Now);
  Result := FPending;
  FPending := Default(TJ2MEVibrationSample);
end;

function TJ2MEDeviceEffects.Poll(Now: Int64): Boolean;
begin
  Advance(Now);
  if (FFlashUntil <> 0) and (Now >= FFlashUntil) then
    FFlashUntil := 0;
  var Level := FBacklight;
  if FFlashUntil <> 0 then
  begin
    Level := 0;
    if (((Now - FFlashStart) div 250) and 1) = 0 then
      Level := 100;
  end;
  Result := Level <> FPresented;
  FPresented := Level;
end;

procedure TJ2MEDeviceEffects.ApplyBacklight(var Pixels: TArray<UInt32>);
begin
  if FPresented = 100 then
    Exit;

  // A virtual color-phone backlight: zero retains 20% ambient reflectance.
  var Scale := 20 + FPresented * 80 div 100;
  for var I := 0 to High(Pixels) do
  begin
    var P := Pixels[I];
    var R := (((P shr 16) and 255) * UInt32(Scale) + 50) div 100;
    var G := (((P shr 8) and 255) * UInt32(Scale) + 50) div 100;
    var B := ((P and 255) * UInt32(Scale) + 50) div 100;
    Pixels[I] := (P and $FF000000) or (R shl 16) or (G shl 8) or B;
  end;
end;

procedure TJ2MEDeviceEffects.Shutdown(Now: Int64);
begin
  SetVibration(0, 0, Now);
  FPending := Default(TJ2MEVibrationSample);
  SetBacklight(100, True);
end;

end.

