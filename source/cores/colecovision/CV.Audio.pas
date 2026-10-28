unit CV.Audio;

interface

uses
  Core.Snapshots;

type
  // Native polyphase windowed-sinc reconstruction of timestamped PSG steps.
  // 32 output taps, 64 fractional phases; 16-sample fixed group delay.
  TCVAudio = class
  private
    FImpulse: array[0..31] of Double;
    FHead: Integer;
    FLastLevel: Integer;
    FLevel, FDCInput, FDCOutput: Double;
  public
    procedure Reset;
    procedure SetLevel(Value, Phase: Integer);
    function Sample: Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

const
  ClockRate = 3579545;
  SampleRate = 44100;
  Phases = 64;
  Taps = 32;

var
  Kernel: array[0..Phases - 1, 0..Taps - 1] of Double;
  DCCoefficient: Double;

procedure PrepareKernel;
begin
  // Blackman window; source edges are filtered before 44.1 kHz sampling.
  // Keep every phase's DC gain exactly one.
  for var Phase := 0 to Phases - 1 do
  begin
    var Sum := 0.0;
    for var I := 0 to Taps - 1 do
    begin
      var X := I - (Taps div 2 - 1) - Phase / Phases;
      var Sinc := 0.84;
      if Abs(X) > 1E-12 then
        Sinc := Sin(Pi * 0.84 * X) / (Pi * X);
      var W := 0.42 - 0.5 * Cos(2 * Pi * I / (Taps - 1)) +
        0.08 * Cos(4 * Pi * I / (Taps - 1));
      Kernel[Phase, I] := Sinc * W;
      Sum := Sum + Kernel[Phase, I];
    end;
    for var I := 0 to Taps - 1 do
      Kernel[Phase, I] := Kernel[Phase, I] / Sum;
  end;
  DCCoefficient := Exp(-2 * Pi * 15 / SampleRate);
end;

procedure TCVAudio.Reset;
begin
  FillChar(FImpulse, SizeOf(FImpulse), 0);
  FHead := 0;
  FLastLevel := 0;
  FLevel := 0;
  FDCInput := 0;
  FDCOutput := 0;
end;

procedure TCVAudio.SetLevel(Value, Phase: Integer);
begin
  var Delta := Value - FLastLevel;
  if Delta = 0 then
    Exit;
  var P := EnsureRange(Int64(Phase) * Phases div ClockRate, Int64(0), Int64(Phases - 1));
  for var I := 0 to Taps - 1 do
  begin
    var Index := (FHead + I) and (Taps - 1);
    FImpulse[Index] := FImpulse[Index] + Delta * Kernel[P, I];
  end;
  FLastLevel := Value;
end;

function TCVAudio.Sample: Integer;
begin
  FLevel := FLevel + FImpulse[FHead];
  FImpulse[FHead] := 0;
  FHead := (FHead + 1) and (Taps - 1);
  FDCOutput := DCCoefficient * (FDCOutput + FLevel - FDCInput);
  FDCInput := FLevel;
  Result := Round(FDCOutput);
end;

procedure TCVAudio.SerializeState(State: TStateArchive);
begin
  State.Field(FImpulse, SizeOf(FImpulse));
  State.Field(FHead, SizeOf(FHead));
  State.Field(FLastLevel, SizeOf(FLastLevel));
  State.Field(FLevel, SizeOf(FLevel));
  State.Field(FDCInput, SizeOf(FDCInput));
  State.Field(FDCOutput, SizeOf(FDCOutput));
  if State.Loading then
  begin
    if (FHead < 0) or (FHead >= Taps) or (Abs(Int64(FLastLevel)) > 16384) then
      raise EReadError.Create('Invalid ColecoVision audio state');
    for var Value in FImpulse do
      if IsNan(Value) or IsInfinite(Value) or (Abs(Value) > 1E7) then
        raise EReadError.Create('Invalid ColecoVision audio impulse');
    if IsNan(FLevel) or IsInfinite(FLevel) or (Abs(FLevel) > 1E7) or
      IsNan(FDCInput) or IsInfinite(FDCInput) or (Abs(FDCInput) > 1E7) or
      IsNan(FDCOutput) or IsInfinite(FDCOutput) or (Abs(FDCOutput) > 1E7) then
      raise EReadError.Create('Invalid ColecoVision audio filter');
  end;
end;

initialization
  PrepareKernel;

end.

