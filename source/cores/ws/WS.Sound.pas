unit WS.Sound;

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, WS.Types;

type
  TWSSound = class
  private
    FRAM: PWSRAM;
    FIO: PWSIO;
    FPeriod, FPosition: array[0..3] of Integer;
    FNoise: Word;
    FNoiseOut: Integer;
    FSweepClock, FSweepCounter, FSamplePhase: Integer;
    FHyperLeft, FHyperRight: Byte;
    FHyperChannel, FHyperDirtyLeft, FHyperDirtyRight: Boolean;
    FHyperClock, FHyperRate: Integer;
    FHyperOutLeft, FHyperOutRight: SmallInt;
    function HyperScale(Value: Byte): SmallInt;
  private
    FFilterInL, FFilterInR, FFilterOutL, FFilterOutR: Double;
    FSampleFrames: Integer;
    FSamples: TArray<SmallInt>;
    procedure Output;
  public
    constructor Create(RAM: PWSRAM; IO: PWSIO);
    procedure Reset;
    procedure Tick(Cycles: Integer);
    procedure BeginFrame;
    procedure WritePort(Port, Value: Byte);
    procedure HyperDMA(Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
  end;

implementation

{$Q-}{$R-}

constructor TWSSound.Create(RAM: PWSRAM; IO: PWSIO);
begin
  inherited Create;
  FRAM := RAM;
  FIO := IO;
  SetLength(FSamples, 4096);
  Reset;
end;

procedure TWSSound.Reset;
begin
  FillChar(FPeriod, SizeOf(FPeriod), 0);
  FillChar(FPosition, SizeOf(FPosition), 0);
  FNoise := 0;
  FNoiseOut := 0;
  FSweepClock := 0;
  FSweepCounter := 0;
  FSamplePhase := 0;
  FSampleFrames := 0;
  FHyperLeft := 0;
  FHyperRight := 0;
  FHyperChannel := False;
  FHyperDirtyLeft := False;
  FHyperDirtyRight := False;
  FHyperClock := 0;
  FHyperRate := 0;
  FHyperOutLeft := 0;
  FHyperOutRight := 0;
  FFilterInL := 0;
  FFilterInR := 0;
  FFilterOutL := 0;
  FFilterOutR := 0;
end;

procedure TWSSound.BeginFrame;
begin
  FSampleFrames := 0;
end;

procedure TWSSound.WritePort(Port, Value: Byte);
begin
  if (Port = $8E) and (Value and 8 <> 0) then
    FNoise := 0;
  if Port = $8D then
  begin
    FSweepCounter := Value and $1F;
    FSweepClock := 0;
  end;
  if Port = $89 then
    FIO[Port] := Value;
  if (Port = $6B) and (Value and $10 <> 0) then
    FHyperChannel := False;
  if Port = $64 then
    FHyperOutLeft := SmallInt((Word(FHyperOutLeft) and $FF00) or Value);
  if Port = $65 then
    FHyperOutLeft := SmallInt((Word(FHyperOutLeft) and $FF) or (Word(Value) shl 8));
  if Port = $66 then
    FHyperOutRight := SmallInt((Word(FHyperOutRight) and $FF00) or Value);
  if Port = $67 then
    FHyperOutRight := SmallInt((Word(FHyperOutRight) and $FF) or (Word(Value) shl 8));
  if Port = $69 then
  begin
    if FHyperChannel then
    begin
      FHyperRight := Value;
      FHyperDirtyRight := True;
    end
    else
    begin
      FHyperLeft := Value;
      FHyperDirtyLeft := True;
    end;
    FHyperChannel := not FHyperChannel;
  end;
end;

procedure TWSSound.HyperDMA(Value: Byte);
begin
  case (FIO[$6B] shr 5) and 3 of
    0:
      begin
        if FHyperChannel then
        begin
          FHyperRight := Value;
          FHyperDirtyRight := True;
        end
        else
        begin
          FHyperLeft := Value;
          FHyperDirtyLeft := True;
        end;
        FHyperChannel := not FHyperChannel;
      end;
    1:
      begin
        FHyperLeft := Value;
        FHyperDirtyLeft := True;
      end;
    2:
      begin
        FHyperRight := Value;
        FHyperDirtyRight := True;
      end;
    3:
      begin
        FHyperLeft := Value;
        FHyperRight := Value;
        FHyperDirtyLeft := True;
        FHyperDirtyRight := True;
      end;
  end;
end;

procedure TWSSound.Tick(Cycles: Integer);
const
  Taps: array[0..7] of Integer = (14, 10, 13, 4, 8, 6, 9, 11);
  HyperDivisors: array[0..7] of Integer = (1, 2, 3, 4, 5, 6, 8, 12);
begin
  for var T := 1 to Cycles do
  begin
    for var C := 0 to 3 do
      if FIO[$90] and (1 shl C) <> 0 then
      begin
        Dec(FPeriod[C]);
        if FPeriod[C] <= 0 then
        begin
          var Pitch := (FIO[$80 + C * 2] or (FIO[$81 + C * 2] shl 8)) and $7FF;
          FPeriod[C] := 2048 - Pitch;
          FPosition[C] := (FPosition[C] + 1) and 31;
          if (C = 3) and (FIO[$8E] and $10 <> 0) then
          begin
            FNoiseOut := (1 xor (FNoise shr 7) xor (FNoise shr Taps[FIO[$8E] and 7])) and 1;
            FNoise := ((FNoise shl 1) or FNoiseOut) and $7FFF;
          end;
        end;
      end;
    if FIO[$90] and $44 = $44 then
    begin
      Inc(FSweepClock);
      if (FSweepClock >= 8192) or (FIO[$95] and 2 <> 0) then
      begin
        FSweepClock := 0;
        if FSweepCounter = 0 then
        begin
          FSweepCounter := FIO[$8D] and $1F;
          var Pitch := ((FIO[$84] or (FIO[$85] shl 8)) + ShortInt(FIO[$8C])) and $7FF;
          FIO[$84] := Byte(Pitch);
          FIO[$85] := Pitch shr 8;
        end
        else
          Dec(FSweepCounter);
      end;
    end;
    Inc(FHyperClock);
    if FHyperClock = 128 then
    begin
      FHyperClock := 0;
      if FIO[$6A] and $80 <> 0 then
      begin
        Inc(FHyperRate);
        if FHyperRate >= HyperDivisors[(FIO[$6A] shr 4) and 7] then
        begin
          FHyperRate := 0;
          if FHyperDirtyLeft then
            FHyperOutLeft := HyperScale(FHyperLeft);
          if FHyperDirtyRight then
            FHyperOutRight := HyperScale(FHyperRight);
          FHyperDirtyLeft := False;
          FHyperDirtyRight := False;
        end;
      end;
    end;
    Inc(FSamplePhase, 44100);
    if FSamplePhase >= WS_CLOCK then
    begin
      Dec(FSamplePhase, WS_CLOCK);
      Output;
    end;
  end;
  FIO[$92] := Byte(FNoise);
  FIO[$93] := FNoise shr 8;
end;

function TWSSound.HyperScale(Value: Byte): SmallInt;
begin
  var V := FIO[$6A] and 3;
  if V = 0 then
    Exit(ShortInt(Value) * 256);
  case (FIO[$6A] shr 2) and 3 of
    0:
      Result := Integer(Value) shl (8 - V);
    1:
      Result := (Integer(Value) shl (8 - V)) - ($10000 shr V);
    2:
      Result := ShortInt(Value) * (1 shl (8 - V));
  else
    Result := ShortInt(Value) * 256;
  end;
end;

procedure TWSSound.Output;
var
  L, R, Sample, Volume, Shift: Integer;
  Filter: Double;
begin
  L := 0;
  R := 0;
  for var C := 0 to 3 do
  begin
    Volume := FIO[$88 + C];
    if (C = 1) and (FIO[$90] and $20 <> 0) then
    begin
      if FIO[$94] and 1 <> 0 then
        Inc(R, Volume)
      else if FIO[$94] and 2 <> 0 then
        Inc(R, Volume div 2);
      if FIO[$94] and 4 <> 0 then
        Inc(L, Volume)
      else if FIO[$94] and 8 <> 0 then
        Inc(L, Volume div 2);
      Continue;
    end;
    if FIO[$90] and (1 shl C) = 0 then
      Continue;
    if (C = 3) and (FIO[$90] and $80 <> 0) then
      Sample := FNoiseOut * 15
    else
    begin
      Sample := FRAM[Word((FIO[$8F] shl 6) + C * 16 + FPosition[C] div 2)];
      Sample := (Sample shr ((FPosition[C] and 1) * 4)) and 15;
    end;
    Inc(L, Sample * (Volume shr 4));
    Inc(R, Sample * (Volume and 15));
  end;
  FIO[$96] := Byte(R);
  FIO[$97] := R shr 8;
  FIO[$98] := Byte(L);
  FIO[$99] := L shr 8;
  FIO[$9A] := Byte(L + R);
  FIO[$9B] := (L + R) shr 8;
  if FIO[$91] and $80 <> 0 then
  begin
    L := L * 32;
    R := R * 32;
    if FIO[$6A] and $80 <> 0 then
    begin
      Inc(L, FHyperOutLeft);
      Inc(R, FHyperOutRight);
    end;
    if FIO[$91] and 8 = 0 then
    begin
      L := 0;
      R := 0;
    end;
  end
  else if FIO[$91] and 1 <> 0 then
  begin
    Shift := (FIO[$91] shr 1) and 3;
    L := (((L + R) shr Shift) and $FF) * 128;
    L := L * (FIO[$9E] and 3) div 3;
    R := L;
  end
  else
  begin
    L := 0;
    R := 0;
  end;
  if FSampleFrames * 2 + 2 > Length(FSamples) then
    SetLength(FSamples, Length(FSamples) * 2);
  Filter := 0.9977 * (FFilterOutL + L - FFilterInL);
  FFilterInL := L;
  FFilterOutL := Filter;
  FSamples[FSampleFrames * 2] := EnsureRange(Round(Filter), -32768, 32767);
  Filter := 0.9977 * (FFilterOutR + R - FFilterInR);
  FFilterInR := R;
  FFilterOutR := Filter;
  FSamples[FSampleFrames * 2 + 1] := EnsureRange(Round(Filter), -32768, 32767);
  Inc(FSampleFrames);
end;

procedure TWSSound.SerializeState(State: TStateArchive);
begin
  State.Field(FPeriod, SizeOf(FPeriod));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FNoiseOut, SizeOf(FNoiseOut));
  State.Field(FSweepClock, SizeOf(FSweepClock));
  State.Field(FSweepCounter, SizeOf(FSweepCounter));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FHyperLeft, SizeOf(FHyperLeft));
  State.Field(FHyperClock, SizeOf(FHyperClock));
  State.Field(FHyperRate, SizeOf(FHyperRate));
  State.Field(FHyperDirtyLeft, SizeOf(FHyperDirtyLeft));
  State.Field(FHyperDirtyRight, SizeOf(FHyperDirtyRight));
  State.Field(FHyperOutLeft, SizeOf(FHyperOutLeft));
  State.Field(FHyperOutRight, SizeOf(FHyperOutRight));
  State.Field(FHyperRight, SizeOf(FHyperRight));
  State.Field(FHyperChannel, SizeOf(FHyperChannel));
  State.Field(FFilterInL, SizeOf(FFilterInL));
  State.Field(FFilterInR, SizeOf(FFilterInR));
  State.Field(FFilterOutL, SizeOf(FFilterOutL));
  State.Field(FFilterOutR, SizeOf(FFilterOutR));
  if State.Loading then
    FSampleFrames := 0;
end;

end.

