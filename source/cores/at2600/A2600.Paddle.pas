unit A2600.Paddle;

interface

uses
  Core.Snapshots;

type
  // Four independent RC inputs. Resistance -1 means an open controller pin.
  TA2600PaddleCircuit = class
  private
    FClock: UInt64;
    FUpdated: array[0..3] of UInt64;
    FVoltage: array[0..3] of Double;
    FResistance: array[0..3] of Integer;
    FDump: Boolean;
    FFrequency: Double;
    procedure Update(Index: Integer);
  public
    constructor Create(ColorClock: Double);
    procedure Reset;
    procedure Clock;
    procedure SetResistance(Index, Ohms: Integer);
    procedure SetDump(Value: Boolean);
    function Read(Index: Integer): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

const
  SeriesResistance = 1800.0;
  Capacitance = 68.0e-9;
  DumpResistance = 50.0;
  // Normalized comparator voltage. Nominal 1.5 V with a 5 V supply.
  Threshold = 0.3;

constructor TA2600PaddleCircuit.Create(ColorClock: Double);
begin
  inherited Create;
  FFrequency := ColorClock;
  Reset;
end;

procedure TA2600PaddleCircuit.Reset;
begin
  FClock := 0;
  FDump := False;
  for var Index := 0 to 3 do
  begin
    FUpdated[Index] := 0;
    FVoltage[Index] := 0;
    FResistance[Index] := -1;
  end;
end;

procedure TA2600PaddleCircuit.Clock;
begin
  Inc(FClock);
end;

procedure TA2600PaddleCircuit.Update(Index: Integer);
begin
  var Elapsed := (FClock - FUpdated[Index]) / FFrequency;
  if FDump then
    FVoltage[Index] := FVoltage[Index] * Exp(-Elapsed / (DumpResistance * Capacitance))
  else if FResistance[Index] >= 0 then
    FVoltage[Index] := 1 - (1 - FVoltage[Index]) *
      Exp(-Elapsed / ((FResistance[Index] + SeriesResistance) * Capacitance));
  FUpdated[Index] := FClock;
end;

procedure TA2600PaddleCircuit.SetResistance(Index, Ohms: Integer);
begin
  Ohms := EnsureRange(Ohms, -1, 1000000);
  if FResistance[Index] = Ohms then
    Exit;
  Update(Index);
  FResistance[Index] := Ohms;
end;

procedure TA2600PaddleCircuit.SetDump(Value: Boolean);
begin
  if FDump = Value then
    Exit;
  for var Index := 0 to 3 do
    Update(Index);
  FDump := Value;
end;

function TA2600PaddleCircuit.Read(Index: Integer): Boolean;
begin
  Update(Index);
  Result := not FDump and (FVoltage[Index] >= Threshold);
end;

procedure TA2600PaddleCircuit.SerializeState(State: TStateArchive);
begin
  State.Field(FClock, SizeOf(FClock));
  State.Field(FUpdated, SizeOf(FUpdated));
  State.Field(FVoltage, SizeOf(FVoltage));
  State.Field(FResistance, SizeOf(FResistance));
  State.Field(FDump, SizeOf(FDump));
  if State.Loading then
    for var Index := 0 to 3 do
      if (FUpdated[Index] > FClock) or IsNan(FVoltage[Index]) or IsInfinite(FVoltage[Index]) or
        (FVoltage[Index] < 0) or (FVoltage[Index] > 1) or
        (FResistance[Index] < -1) or (FResistance[Index] > 1000000) then
        raise EReadError.Create('Invalid Atari 2600 paddle circuit state');
end;

end.

