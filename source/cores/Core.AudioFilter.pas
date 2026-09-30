unit Core.AudioFilter;

interface

type
  // Two-pole Butterworth low-pass. Run at the SOURCE rate before decimation.
  TPCMLowPass = record
  private
    FB0, FB1, FB2, FA1, FA2: Double;
    FZ1, FZ2: Double;
  public
    procedure Configure(SampleRate, Cutoff: Double);
    procedure Reset;
    function Process(Value: Double): Double;
  end;

  TPCMDCBlocker = record
  private
    FCoefficient, FInput, FOutput: Double;
  public
    procedure Configure(SampleRate, Cutoff: Double);
    procedure Reset;
    function Process(Value: Double): Double;
  end;

implementation

uses
  System.Math;

procedure TPCMLowPass.Configure(SampleRate, Cutoff: Double);
begin
  var K := Tan(Pi * Min(Cutoff, SampleRate * 0.45) / SampleRate);
  var Scale := 1 / (1 + Sqrt(2) * K + K * K);
  FB0 := K * K * Scale;
  FB1 := 2 * FB0;
  FB2 := FB0;
  FA1 := 2 * (K * K - 1) * Scale;
  FA2 := (1 - Sqrt(2) * K + K * K) * Scale;
end;

procedure TPCMLowPass.Reset;
begin
  FZ1 := 0;
  FZ2 := 0;
end;

function TPCMLowPass.Process(Value: Double): Double;
begin
  Result := FB0 * Value + FZ1;
  FZ1 := FB1 * Value - FA1 * Result + FZ2;
  FZ2 := FB2 * Value - FA2 * Result;
end;

procedure TPCMDCBlocker.Configure(SampleRate, Cutoff: Double);
begin
  FCoefficient := Exp(-2 * Pi * Cutoff / SampleRate);
end;

procedure TPCMDCBlocker.Reset;
begin
  FInput := 0;
  FOutput := 0;
end;

function TPCMDCBlocker.Process(Value: Double): Double;
begin
  FOutput := FCoefficient * (FOutput + Value - FInput);
  FInput := Value;
  Result := FOutput;
end;

end.

