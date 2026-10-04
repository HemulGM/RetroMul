unit RetroTune.Spectrum;

interface

const
  TuneFFTSize = 1024;
  TuneSpectrumBands = 64;

type
  TTunePCMWindow = array[0..TuneFFTSize - 1] of Single;

  TTuneSpectrum = array[0..TuneSpectrumBands - 1] of Single;

// Hann-windowed FFT, logarithmic frequency bands, normalized -72..0 dBFS.
// This module has no UI/decoder dependencies and accepts any PCM sample rate.
procedure AnalyzeSpectrum(const Samples: TTunePCMWindow; SampleRate: Integer; out Bands: TTuneSpectrum);

implementation

uses
  System.Math;

procedure AnalyzeSpectrum(const Samples: TTunePCMWindow; SampleRate: Integer; out Bands: TTuneSpectrum);
var
  Re, Im: array[0..TuneFFTSize - 1] of Double;
  I, J, Bit, Len, Half, Base, K, FirstBin, LastBin, Band: Integer;
  Temp, Angle, Wr, Wi, Tr, Ti, StepR, StepI, Power, LowHz, HighHz, MaxHz: Double;
begin
  Bands := Default(TTuneSpectrum);
  if SampleRate <= 0 then
    Exit;
  FillChar(Im, SizeOf(Im), 0);
  for I := 0 to TuneFFTSize - 1 do
    Re[I] := Samples[I] * (0.5 - 0.5 * Cos(2 * Pi * I / (TuneFFTSize - 1)));
  J := 0;
  for I := 1 to TuneFFTSize - 1 do
  begin
    Bit := TuneFFTSize shr 1;
    while (J and Bit) <> 0 do
    begin
      J := J xor Bit;
      Bit := Bit shr 1;
    end;
    J := J xor Bit;
    if I < J then
    begin
      Temp := Re[I];
      Re[I] := Re[J];
      Re[J] := Temp;
    end;
  end;
  Len := 2;
  while Len <= TuneFFTSize do
  begin
    Half := Len div 2;
    Angle := -2 * Pi / Len;
    StepR := Cos(Angle);
    StepI := Sin(Angle);
    Base := 0;
    while Base < TuneFFTSize do
    begin
      Wr := 1;
      Wi := 0;
      for K := 0 to Half - 1 do
      begin
        I := Base + K;
        J := I + Half;
        Tr := Wr * Re[J] - Wi * Im[J];
        Ti := Wr * Im[J] + Wi * Re[J];
        Re[J] := Re[I] - Tr;
        Im[J] := Im[I] - Ti;
        Re[I] := Re[I] + Tr;
        Im[I] := Im[I] + Ti;
        Temp := Wr * StepR - Wi * StepI;
        Wi := Wr * StepI + Wi * StepR;
        Wr := Temp;
      end;
      Inc(Base, Len);
    end;
    Len := Len * 2;
  end;
  MaxHz := Min(20000.0, SampleRate / 2.0);
  LowHz := Min(30.0, MaxHz / 2);
  for Band := 0 to TuneSpectrumBands - 1 do
  begin
    HighHz := Min(30.0, MaxHz / 2) * System.Math.Power(MaxHz / Min(30.0, MaxHz / 2),
        (Band + 1) / TuneSpectrumBands);
    FirstBin := EnsureRange(Floor(LowHz * TuneFFTSize / SampleRate), 1, TuneFFTSize div 2);
    LastBin := EnsureRange(Ceil(HighHz * TuneFFTSize / SampleRate), FirstBin, TuneFFTSize div 2);
    Power := 0;
    for I := FirstBin to LastBin do
      Power := Max(Power, Sqr(Re[I]) + Sqr(Im[I]));
    // Hann coherent gain is ~0.5, so sine peak amplitude = magnitude * 4/N.
    Power := Sqrt(Power) * 4 / TuneFFTSize;
    Bands[Band] := EnsureRange((20 * Log10(Max(Power, 0.000001)) + 72) / 72, 0.0, 1.0);
    LowHz := HighHz;
  end;
end;

end.

