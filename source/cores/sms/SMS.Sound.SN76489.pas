unit SMS.Sound.SN76489;

interface

type
  TSN76489 = class
  private
    FPeriod: array[0..2] of Integer;
    FCounter: array[0..3] of Integer;
    FOutput: array[0..3] of Boolean;
    FVolume: array[0..3] of Integer;
    FLatch, FNoise, FLFSR: Integer;
    FPhase: Double;
    procedure Clock;
  public
    constructor Create;
    procedure Reset;
    procedure Write(Value: Byte);
    procedure Sample(Stereo: Byte; out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

constructor TSN76489.Create;
begin
  inherited;
  Reset;
end;

procedure TSN76489.Reset;
begin
  for var C := 0 to 2 do
    FPeriod[C] := 0;
  for var C := 0 to 3 do
  begin
    FCounter[C] := 0;
    FOutput[C] := False;
    FVolume[C] := 15;
  end;
  FLatch := 0;
  FNoise := 0;
  FLFSR := $8000;
  FPhase := 0;
end;

procedure TSN76489.Write(Value: Byte);
begin
  if Value and $80 <> 0 then
    FLatch := (Value shr 4) and 7;
  var C := FLatch div 2;
  if FLatch and 1 <> 0 then
    FVolume[C] := Value and 15
  else if C < 3 then
  begin
    if Value and $80 <> 0 then
      FPeriod[C] := (FPeriod[C] and $3F0) or (Value and 15)
    else
      FPeriod[C] := (FPeriod[C] and 15) or ((Value and 63) shl 4);
  end
  else
  begin
    FNoise := Value and 7;
    FLFSR := $8000;
  end;
end;

procedure TSN76489.Clock;
begin
  for var C := 0 to 2 do
  begin
    Dec(FCounter[C]);
    if FCounter[C] <= 0 then
    begin
      FCounter[C] := Max(1, FPeriod[C]);
      if FPeriod[C] <= 1 then
        FOutput[C] := True
      else
        FOutput[C] := not FOutput[C];
    end;
  end;
  var ShiftNoise := False;
  if FNoise and 3 = 3 then
    ShiftNoise := (FCounter[2] = Max(1, FPeriod[2])) and FOutput[2]
  else
  begin
    Dec(FCounter[3]);
    if FCounter[3] <= 0 then
    begin
      FCounter[3] := 16 shl (FNoise and 3);
      FOutput[3] := not FOutput[3];
      ShiftNoise := FOutput[3];
    end;
  end;
  if ShiftNoise then
  begin
    var Feedback := FLFSR and 1;
    if FNoise and 4 <> 0 then
      Feedback := Feedback xor ((FLFSR shr 3) and 1);
    FLFSR := (FLFSR shr 1) or (Feedback shl 15);
  end;
end;

procedure TSN76489.Sample(Stereo: Byte; out Left, Right: SmallInt);
const
  Volume: array[0..15] of Integer = (4096, 3254, 2584, 2053, 1631, 1295, 1029, 817, 649, 516, 410, 326, 259, 206, 164, 0);
begin
  FPhase := FPhase + 3579545.0 / (16 * 44100);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    Clock;
  end;
  var L := 0;
  var R := 0;
  for var C := 0 to 3 do
  begin
    var High := FOutput[C];
    if C = 3 then
      High := FLFSR and 1 <> 0;
    var V := -Volume[FVolume[C]];
    if High then
      V := -V;
    if Stereo and (1 shl (C + 4)) <> 0 then
      Inc(L, V);
    if Stereo and (1 shl C) <> 0 then
      Inc(R, V);
  end;
  Left := L;
  Right := R;
end;

end.

