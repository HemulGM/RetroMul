unit HW.Sound.MSM5205;

interface

uses
  Core.Snapshots;

type
  TOkiAdpcmDecoder = record
    Signal, StepIndex: Integer;
    procedure Clock(Nibble: Byte);
    function Sample: Integer;
    procedure ValidateState;
  end;

  TMSM5205 = class
  private
    FDecoder: TOkiAdpcmDecoder;
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
  FDecoder := Default(TOkiAdpcmDecoder);
  FReset := False;
end;

procedure TMSM5205.SetReset(Value: Boolean);
begin
  FReset := Value;
  if Value then
    FDecoder := Default(TOkiAdpcmDecoder);
end;

procedure TMSM5205.Clock(Nibble: Byte);
begin
  if not FReset then
    FDecoder.Clock(Nibble);
end;

procedure TOkiAdpcmDecoder.Clock(Nibble: Byte);
begin
  var Step := Steps[StepIndex];
  var Delta := Step div 8;
  if Nibble and 1 <> 0 then
    Inc(Delta, Step div 4);
  if Nibble and 2 <> 0 then
    Inc(Delta, Step div 2);
  if Nibble and 4 <> 0 then
    Inc(Delta, Step);
  if Nibble and 8 <> 0 then
    Delta := -Delta;
  Signal := EnsureRange(Signal + Delta, -2048, 2047);
  StepIndex := EnsureRange(StepIndex + Adjust[Nibble and 7], 0, 48);
end;

function TOkiAdpcmDecoder.Sample: Integer;
begin
  Result := Signal * 16;
end;

procedure TOkiAdpcmDecoder.ValidateState;
begin
  if (Signal < -2048) or (Signal > 2047) or (StepIndex < 0) or (StepIndex > 48) then
    raise EArgumentException.Create('Invalid OKI ADPCM state');
end;

function TMSM5205.Sample: Integer;
begin
  Result := FDecoder.Sample;
end;

procedure TMSM5205.SerializeState(State: TStateArchive);
begin
  State.Field(FDecoder.Signal, SizeOf(FDecoder.Signal));
  State.Field(FDecoder.StepIndex, SizeOf(FDecoder.StepIndex));
  State.Field(FReset, SizeOf(FReset));
  FDecoder.ValidateState;
end;

end.

