unit A2600.DPC;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  // Pitfall II display fetchers, oscillator counters and polynomial register.
  TA2600DPC = class
  private
    FDisplay: TBytes;
    FTop, FBottom, FFlags: array[0..7] of Byte;
    FCounters: array[0..7] of Word;
    FMusic: array[0..7] of Boolean;
    FRandom: Byte;
    FPhase: Double;
    procedure UpdateFlag(Index: Integer);
  public
    constructor Create(const Image: TBytes);
    procedure Reset;
    procedure Clock(CPUFrequency: Double);
    procedure Access;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

constructor TA2600DPC.Create(const Image: TBytes);
begin
  inherited Create;
  if Length(Image) < 10240 then
    raise EReadError.Create('Truncated DPC image');
  FDisplay := Copy(Image, 8192, 2048);
  Reset;
end;

procedure TA2600DPC.Reset;
begin
  FillChar(FTop, SizeOf(FTop), 0);
  FillChar(FBottom, SizeOf(FBottom), 0);
  FillChar(FFlags, SizeOf(FFlags), 0);
  FillChar(FCounters, SizeOf(FCounters), 0);
  FillChar(FMusic, SizeOf(FMusic), 0);
  FRandom := 1;
  FPhase := 0;
end;

procedure TA2600DPC.Access;
begin
  var Feedback := 1 xor ((FRandom shr 7) and 1) xor ((FRandom shr 5) and 1) xor
    ((FRandom shr 4) and 1) xor ((FRandom shr 3) and 1);
  FRandom := ((Integer(FRandom) shl 1) or Feedback) and $FF;
end;

procedure TA2600DPC.UpdateFlag(Index: Integer);
begin
  var Low := FCounters[Index] and $FF;
  if Low = FTop[Index] then
    FFlags[Index] := $FF
  else if Low = FBottom[Index] then
    FFlags[Index] := 0;
end;

procedure TA2600DPC.Clock(CPUFrequency: Double);
begin
  FPhase := FPhase + 20000.0 / CPUFrequency;
  if FPhase < 1 then
    Exit;
  FPhase := FPhase - 1;
  for var I := 5 to 7 do
    if FMusic[I] then
    begin
      var Low := Integer(FCounters[I] and $FF) - 1;
      if Low < 0 then
        Low := FTop[I];
      FCounters[I] := (FCounters[I] and $700) or Low;
      UpdateFlag(I);
    end;
end;

function TA2600DPC.Read(Address: Word): Byte;
const
  Weights: array[0..2] of Byte = (4, 5, 6);
begin
  var I := Address and 7;
  UpdateFlag(I);
  Result := 0;
  case (Address shr 3) and 7 of
    0:
      if I < 4 then
        Result := FRandom
      else
        for var Voice := 0 to 2 do
          if FMusic[Voice + 5] and (FFlags[Voice + 5] <> 0) then
            Inc(Result, Weights[Voice]);
    1:
      Result := FDisplay[2047 - FCounters[I]];
    2:
      Result := FDisplay[2047 - FCounters[I]] and FFlags[I];
    7:
      Result := FFlags[I];
  end;
  if (I < 5) or not FMusic[I] then
    FCounters[I] := (Integer(FCounters[I]) - 1) and $7FF;
end;

procedure TA2600DPC.Write(Address: Word; Value: Byte);
begin
  var I := Address and 7;
  case (Address shr 3) and 7 of
    0:
      begin
        FTop[I] := Value;
        FFlags[I] := 0;
      end;
    1:
      FBottom[I] := Value;
    2:
      begin
        if (I >= 5) and FMusic[I] then
          Value := FTop[I];
        FCounters[I] := (FCounters[I] and $700) or Value;
      end;
    3:
      begin
        FCounters[I] := (FCounters[I] and $FF) or (Word(Value and 7) shl 8);
        if I >= 5 then
          FMusic[I] := Value and $10 <> 0;
      end;
    6:
      FRandom := 1;
  end;
end;

procedure TA2600DPC.SerializeState(State: TStateArchive);
begin
  State.Field(FTop, SizeOf(FTop));
  State.Field(FBottom, SizeOf(FBottom));
  State.Field(FFlags, SizeOf(FFlags));
  State.Field(FCounters, SizeOf(FCounters));
  State.Field(FMusic, SizeOf(FMusic));
  State.Field(FRandom, SizeOf(FRandom));
  State.Field(FPhase, SizeOf(FPhase));
  for var Counter in FCounters do
    if Counter > $7FF then
      raise EReadError.Create('Invalid DPC counter');
  if (FPhase < 0) or (FPhase >= 1) then
    raise EReadError.Create('Invalid DPC phase');
end;

end.

