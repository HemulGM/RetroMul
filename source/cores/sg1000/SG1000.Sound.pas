unit SG1000.Sound;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  // TI SN76489A, clocked directly by Z80 T states (not by host audio playback).
  TSGSound = class
  private
    FPeriod: array[0..2] of Integer;
    FCounter: array[0..3] of Integer;
    FOutput: array[0..3] of Boolean;
    FVolume: array[0..3] of Integer;
    FLatch, FNoise, FLFSR, FDivider: Integer;
    FSega: Boolean;
    FStereo: Byte;
    FChannelVolume: array[0..3] of Integer;
    FAmplitude: array[0..3] of Integer; // Derived from attenuation and host gain.
    procedure UpdateAmplitude(Channel: Integer);
    function ChannelSample(Channel: Integer): Integer; inline;
    procedure Clock;
    function TonePeriod(Channel: Integer): Integer;
  public
    constructor Create(Sega: Boolean = False);
    procedure Reset;
    procedure Write(Value: Byte);
    procedure Advance(Cycles: Integer);
    function ClocksUntilTick: Integer;
    function Sample: SmallInt;
    procedure SampleStereo(out Left, Right: SmallInt);
    procedure SetStereo(Value: Byte);
    procedure SetVolumes(const Values: array of Integer);
    procedure SerializeState(State: TStateArchive; Stereo: Boolean = False);
  end;

implementation

constructor TSGSound.Create(Sega: Boolean);
begin
  inherited Create;
  FSega := Sega;
  for var i := 0 to 3 do
    FChannelVolume[i] := 100;
  Reset;
end;

procedure TSGSound.Reset;
begin
  FillChar(FPeriod, SizeOf(FPeriod), 0);
  FillChar(FCounter, SizeOf(FCounter), 0);
  FillChar(FOutput, SizeOf(FOutput), 0);
  FillChar(FVolume, SizeOf(FVolume), 0);
  FLatch := 0;
  FNoise := 0;
  FLFSR := $10000;
  if FSega then
    FLFSR := $8000;
  FDivider := 0;
  FStereo := $FF;
  for var i := 0 to 3 do
    UpdateAmplitude(i);
end;

function TSGSound.TonePeriod(Channel: Integer): Integer;
begin
  Result := FPeriod[Channel];
  if Result = 0 then
    if FSega then
      Result := 1
    else
      Result := $400;
end;

procedure TSGSound.Write(Value: Byte);
begin
  if Value and $80 <> 0 then
    FLatch := (Value shr 4) and 7;
  var Channel := FLatch div 2;
  if FLatch and 1 <> 0 then
  begin
    FVolume[Channel] := Value and 15;
    UpdateAmplitude(Channel);
  end
  else if Channel < 3 then
  begin
    if Value and $80 <> 0 then
      FPeriod[Channel] := (FPeriod[Channel] and $3F0) or (Value and 15)
    else
      FPeriod[Channel] := (FPeriod[Channel] and 15) or ((Value and 63) shl 4);
  end
  else
  begin
    FNoise := Value and 7;
    FLFSR := $10000;
    if FSega then
      FLFSR := $8000;
    FOutput[3] := False;
  end;
end;

procedure TSGSound.Clock;
begin
  for var Channel := 0 to 2 do
  begin
    Dec(FCounter[Channel]);
    if FCounter[Channel] <= 0 then
    begin
      FCounter[Channel] := TonePeriod(Channel);
      if FSega and (FPeriod[Channel] <= 1) then
        FOutput[Channel] := True
      else
        FOutput[Channel] := not FOutput[Channel];
    end;
  end;
  if FSega then
  begin
    var Tick := False;
    if FNoise and 3 = 3 then
      Tick := (FCounter[2] = TonePeriod(2)) and FOutput[2]
    else
    begin
      Dec(FCounter[3]);
      if FCounter[3] <= 0 then
      begin
        FCounter[3] := 16 shl (FNoise and 3);
        FOutput[3] := not FOutput[3];
        Tick := FOutput[3];
      end;
    end;
    if Tick then
    begin
      var Feedback := FLFSR and 1;
      if FNoise and 4 <> 0 then
        Feedback := Feedback xor ((FLFSR shr 3) and 1);
      FLFSR := (FLFSR shr 1) or (Feedback shl 15);
    end;
    Exit;
  end;

  Dec(FCounter[3]);
  if FCounter[3] <= 0 then
  begin
    if FNoise and 3 = 3 then
      FCounter[3] := TonePeriod(2) * 2
    else
      FCounter[3] := 32 shl (FNoise and 3);
    // The TI 17-bit representation has two output-delay stages. Periodic
    // noise recirculates tap 2, giving the measured 15-shift ring period.
    var Feedback := (FLFSR shr 2) and 1;
    if FNoise and 4 <> 0 then
      Feedback := ((FLFSR shr 2) xor (FLFSR shr 3)) and 1;
    FLFSR := (FLFSR shr 1) or (Feedback shl 16);
    FOutput[3] := FLFSR and 1 <> 0;
  end;
end;

function TSGSound.ClocksUntilTick: Integer;
begin
  Result := 16 - FDivider;
end;

procedure TSGSound.Advance(Cycles: Integer);
begin
  if (Cycles < 0) or (Cycles > 65535) then
    raise EArgumentOutOfRangeException.Create('Invalid PSG clock count');

  Inc(FDivider, Cycles);

  // TI counts at clock / 16; every tone edge occurs after Period ticks.
  while FDivider >= 16 do
  begin
    Dec(FDivider, 16);
    Clock;
  end;
end;

procedure TSGSound.SetVolumes(const Values: array of Integer);
begin
  if Length(Values) <> 4 then
    raise EArgumentException.Create('PSG needs four channel volumes');

  for var i := 0 to 3 do
  begin
    if Values[i] < 0 then
      FChannelVolume[i] := 0
    else if Values[i] > 100 then
      FChannelVolume[i] := 100
    else
      FChannelVolume[i] := Values[i];
    UpdateAmplitude(i);
  end;
end;

procedure TSGSound.UpdateAmplitude(Channel: Integer);
const
  Amplitudes: array[0..15] of Integer = (4096, 3254, 2584, 2053, 1631, 1295, 1029, 817, 649, 516, 410, 326, 259, 206, 164, 0);
begin
  FAmplitude[Channel] := Amplitudes[FVolume[Channel]] * FChannelVolume[Channel] div 100;
end;

function TSGSound.ChannelSample(Channel: Integer): Integer;
begin
  Result := FAmplitude[Channel];
  var High := FOutput[Channel];
  if FSega and (Channel = 3) then
    High := FLFSR and 1 <> 0;
  if not High then
    Result := -Result;
end;

function TSGSound.Sample: SmallInt;
begin
  var Value := 0;
  for var Channel := 0 to 3 do
    Inc(Value, ChannelSample(Channel));
  Result := Value;
end;

procedure TSGSound.SetStereo(Value: Byte);
begin
  FStereo := Value;
end;

procedure TSGSound.SampleStereo(out Left, Right: SmallInt);
begin
  var L := 0;
  var R := 0;
  for var Channel := 0 to 3 do
  begin
    var Value := ChannelSample(Channel);
    if FStereo and (1 shl (Channel + 4)) <> 0 then
      Inc(L, Value);
    if FStereo and (1 shl Channel) <> 0 then
      Inc(R, Value);
  end;
  Left := L;
  Right := R;
end;

procedure TSGSound.SerializeState(State: TStateArchive; Stereo: Boolean);
begin
  if Stereo then
    State.Field(FStereo, SizeOf(FStereo));
  State.Field(FPeriod, SizeOf(FPeriod));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FLFSR, SizeOf(FLFSR));
  State.Field(FDivider, SizeOf(FDivider));

  if State.Loading then
  begin
    if (FLatch < 0) or (FLatch > 7) or (FNoise < 0) or (FNoise > 7) or
      (FLFSR < 0) or (FLFSR > $1FFFF) or (FDivider < 0) or (FDivider > 15) then
      raise EReadError.Create('Invalid PSG snapshot');

    for var Channel := 0 to 3 do
    begin
      if (FVolume[Channel] < 0) or (FVolume[Channel] > 15) or
        (FCounter[Channel] < 0) or (FCounter[Channel] > 2048) then
        raise EReadError.Create('Invalid PSG channel snapshot');

      if (Channel < 3) and ((FPeriod[Channel] < 0) or (FPeriod[Channel] > 1023)) then
        raise EReadError.Create('Invalid PSG tone snapshot');
    end;
    for var Channel := 0 to 3 do
      UpdateAmplitude(Channel);
  end;
end;

end.

