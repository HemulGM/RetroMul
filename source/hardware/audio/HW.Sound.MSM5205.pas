unit HW.Sound.MSM5205;

interface

uses
  Core.Snapshots;

type
  TMSM5205 = class
  private
    FSignal, FStep: Integer;
    FReset: Boolean;
  public
    procedure Reset;
    procedure SetReset(Value: Boolean);
    procedure Clock(Nibble: Byte);
    function Sample: Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math, System.SysUtils;

const
  Adjust: array[0..7] of Integer = (-1, -1, -1, -1, 2, 4, 6, 8);
  Steps: array[0..48] of Integer = (16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552);

procedure TMSM5205.Reset;
begin
  FSignal := 0;
  FStep := 0;
  FReset := False;
end;

procedure TMSM5205.SetReset(Value: Boolean);
begin
  FReset := Value;
  if Value then
  begin
    FSignal := 0;
    FStep := 0;
  end;
end;

procedure TMSM5205.Clock(Nibble: Byte);
begin
  if FReset then
    Exit;

  var Step := Steps[FStep];
  var Delta := Step div 8;
  if Nibble and 1 <> 0 then
    Inc(Delta, Step div 4);
  if Nibble and 2 <> 0 then
    Inc(Delta, Step div 2);
  if Nibble and 4 <> 0 then
    Inc(Delta, Step);
  if Nibble and 8 <> 0 then
    Delta := -Delta;
  FSignal := EnsureRange(FSignal + Delta, -2048, 2047);
  FStep := EnsureRange(FStep + Adjust[Nibble and 7], 0, 48);
end;

function TMSM5205.Sample: Integer;
begin
  Result := FSignal * 16;
end;

procedure TMSM5205.SerializeState(State: TStateArchive);
begin
  State.Field(FSignal, SizeOf(FSignal));
  State.Field(FStep, SizeOf(FStep));
  State.Field(FReset, SizeOf(FReset));
  if (FSignal < -2048) or (FSignal > 2047) or (FStep < 0) or (FStep > 48) then
    raise EArgumentException.Create('Invalid MSM5205 state');
end;

end.

