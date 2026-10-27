unit MSX.Sound.SCC;

interface

uses
  Core.AudioFilter, Core.Snapshots;

type
  TSCC = class
  private
    FWave: array[0..4, 0..31] of ShortInt;
    FRegisters: array[0..15] of Byte;
    FPosition: array[0..4] of Integer;
    FCounter: array[0..4] of Double;
    FDC: TPCMDCBlocker;
    FDeform: Byte;
    FClockCounters: array[0..4] of Integer;
    FPeriods: array[0..4] of Integer;
    FRotationClock: Int64;
    function Period(Channel: Integer): Integer;
    function WaveReadOnly(Channel: Integer; Extended: Boolean): Boolean;
  public
    constructor Create;
    procedure Reset;
    procedure WriteRegister(Index, Value: Byte; Plus: Boolean = False; Compatible: Boolean = False);
    function ReadRegister(Index: Byte; Plus: Boolean = False; Compatible: Boolean = False): Byte;
    procedure Advance(Cycles: Integer);
    function Sample(Tick: Boolean = True): SmallInt;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math, System.Classes;

procedure TSCC.SerializeState(State: TStateArchive);
begin
  State.Field(FWave, SizeOf(FWave));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FDC, SizeOf(FDC));
  State.Field(FDeform, SizeOf(FDeform));
  State.Field(FClockCounters, SizeOf(FClockCounters));
  State.Field(FRotationClock, SizeOf(FRotationClock));
  State.Field(FPeriods, SizeOf(FPeriods));
  if State.Loading then
  begin
    if FRotationClock < 0 then
      raise EReadError.Create('Invalid SCC clock');
    for var C := 0 to 4 do
      if (FPeriods[C] < 0) or (FPeriods[C] > 4095) or (FPosition[C] < 0) or (FPosition[C] > 31) or
        (FClockCounters[C] < 0) or (FClockCounters[C] > 4095) or IsNan(FCounter[C]) or
        (FCounter[C] < 0) or (FCounter[C] >= 1) then
        raise EReadError.Create('Invalid SCC state');
  end;
end;

constructor TSCC.Create;
begin
  inherited;
  FDC.Configure(44100, 20);
  FillChar(FWave, SizeOf(FWave), $FF);
  for var C := 0 to 4 do
    FRegisters[10 + C] := 15;
  Reset;
end;

procedure TSCC.Reset;
begin
  // RESET disables channels; waveform RAM and frequency/volume latches survive.
  FRegisters[15] := 0;
  FDC.Reset;
  FDeform := 0;
  FRotationClock := 0;
end;

function TSCC.Period(Channel: Integer): Integer;
begin
  Result := FPeriods[Channel];
end;

function TSCC.WaveReadOnly(Channel: Integer; Extended: Boolean): Boolean;
begin
  var D := FDeform;
  if Extended then
    D := D and $7F;
  Result := (D and $40 <> 0) or ((D and $80 <> 0) and (Channel >= 3));
end;

procedure TSCC.WriteRegister(Index, Value: Byte; Plus, Compatible: Boolean);
begin
  var Base := $80;
  if Plus then
    Base := $A0;
  if Index < Base then
  begin
    if Compatible and not Plus and (Index >= $80) then
      Exit;
    var C := Index div 32;
    if WaveReadOnly(C, Plus or Compatible) then
      Exit;
    var V := Integer(Value);
    if V >= 128 then
      Dec(V, 256);
    FWave[C, Index and 31] := V;
    if not Plus and (C = 3) then
      FWave[4, Index and 31] := V;
  end
  else if Index < Base + 32 then
  begin
    var R := (Index - Base) and 15;
    FRegisters[R] := Value;
    if R < 10 then
    begin
      var C := R div 2;
      var P := Integer(FRegisters[C * 2]) or ((Integer(FRegisters[C * 2 + 1]) and 15) shl 8);
      // Deformation frequency selection is sampled by a frequency write.
      if FDeform and 2 <> 0 then
        P := P and 255
      else if FDeform and 1 <> 0 then
        P := P shr 8;
      FPeriods[C] := P;
      FClockCounters[R div 2] := 0;
      FCounter[R div 2] := 0;
      if FDeform and $20 <> 0 then
      begin
        FPosition[R div 2] := 0;
        FRotationClock := 0;
      end;
    end;
  end
  else if ((Plus or Compatible) and (Index in [$C0..$DF])) or
    (not (Plus or Compatible) and (Index >= $E0)) then
  begin
    if FDeform <> Value then
      FRotationClock := 0;
    FDeform := Value;
  end;
end;

function TSCC.ReadRegister(Index: Byte; Plus, Compatible: Boolean): Byte;
begin
  if ((Plus or Compatible) and (Index in [$C0..$DF])) or
    (not (Plus or Compatible) and (Index >= $E0)) then
  begin
    if FDeform <> $FF then
      FRotationClock := 0;
    FDeform := $FF;
  end;
  var Base := $80;
  if Plus then
    Base := $A0;
  Result := $FF;
  var C := -1;
  if Index < Base then
    C := Index div 32;
  if Compatible and not Plus and (Index in [$A0..$BF]) then
    C := 4;
  if C < 0 then
    Exit;
  var P := Integer(Index and 31);
  if WaveReadOnly(C, Plus or Compatible) then
  begin
    var Rotating := not ((not (Plus or Compatible)) and (FDeform and $C0 = $C0) and (C >= 3));
    if Rotating then
    begin
      var ClockChannel := C;
      if (C = 3) and not Plus and (FDeform and $C0 = $40) then
        ClockChannel := 4;
      P := (P + FRotationClock div (Period(ClockChannel) + 1)) and 31;
    end;
  end;
  Result := Integer(FWave[C, P]) and 255;
end;

procedure TSCC.Advance(Cycles: Integer);
begin
  Inc(FRotationClock, Cycles);
  for var C := 0 to 4 do
  begin
    var P := Period(C);
    if P <= 8 then
      Continue;
    var N := Int64(FClockCounters[C]) + Cycles;
    FPosition[C] := (FPosition[C] + N div (P + 1)) and 31;
    FClockCounters[C] := N mod (P + 1);
  end;
end;

function TSCC.Sample(Tick: Boolean): SmallInt;
begin
  var Sum := 0.0;
  for var C := 0 to 4 do
  begin
    var P := Period(C);
    if Tick and (P > 8) then
    begin
      FCounter[C] := FCounter[C] + 3579545.0 / (44100 * (P + 1));
      var Steps := Trunc(FCounter[C]);
      FCounter[C] := Frac(FCounter[C]);
      FPosition[C] := (FPosition[C] + Steps) and 31;
    end;
    if (FRegisters[15] and (1 shl C) <> 0) and (P > 8) then
      Sum := Sum + FWave[C, FPosition[C]] * (FRegisters[10 + C] and 15) * 3;
  end;
  Result := EnsureRange(Round(FDC.Process(Sum)), -32768, 32767);
end;

end.

