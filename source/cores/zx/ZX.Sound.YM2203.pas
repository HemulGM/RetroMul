unit ZX.Sound.YM2203;

interface

uses
  System.SysUtils, MD.Sound, ZX.Sound.YM2149, Core.AudioFilter;

type
  // OPN FM operators are shared with the existing OPN2 core. YM2203 runs
  // its three FM voices at master/72 and its SSG at master/4.
  TYM2203 = class
  private
    FFM: TFM;
    FSSG: TYM2149F;
    FClock, FSampleRate, FPrescaler, FDivider: Integer;
    FPhase: Double;
    FFiltered: Double;
    FFilter: TPCMLowPass;
    FDC: TPCMDCBlocker;
    FRegisters: array[0..255] of Byte;
    procedure SelectPrescaler;
    function GenerateFM: Integer;
  public
    constructor Create(Clock: Integer = 3500000; SampleRate: Integer = 44100);
    destructor Destroy; override;
    procedure Reset;
    procedure WriteRegister(Index, Value: Byte);
    function ReadRegister(Index: Byte): Byte;
    function Sample: SmallInt;
  end;

implementation

uses
  System.Math;

constructor TYM2203.Create(Clock, SampleRate: Integer);
begin
  inherited Create;
  if (Clock < 1000000) or (Clock > 8000000) or
    (SampleRate < 8000) or (SampleRate > 192000) then
    raise EArgumentOutOfRangeException.Create('YM2203 clock/sample rate');
  FClock := Clock;
  FSampleRate := SampleRate;
  FSSG := TYM2149F.Create(Clock div 4, SampleRate);
  for var C := 0 to 2 do
    FSSG.SetPan(C, 1, 1);
  FFilter.Configure(Clock / 72.0, Min(14000, SampleRate * 0.4));
  FDC.Configure(SampleRate, 20);
  Reset;
end;

destructor TYM2203.Destroy;
begin
  FSSG.Free;
  inherited;
end;

procedure TYM2203.Reset;
begin
  FPrescaler := 2;
  SelectPrescaler;
  FFM := Default(TFM);
  FMInitialise(FFM);
  FFM.Configuration.LadderEffectDisabled := 1;
  FFM.Configuration.DacChannelDisabled := 1;
  for var C := 0 to 5 do
  begin
    FFM.Configuration.FMChannelsDisabled[C] := Ord(C >= 3);
    FFM.State.Channels[C].PanLeft := 1;
    FFM.State.Channels[C].PanRight := 1;
  end;
  FSSG.Reset;
  FSSG.WriteRegister(7, $3F);
  for var C := 8 to 10 do
    FSSG.WriteRegister(C, 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FPhase := 0;
  FFiltered := 0;
  FFilter.Reset;
  FDC.Reset;
end;

procedure TYM2203.SelectPrescaler;
const
  FMClockDividers: array[0..3] of Integer = (24, 24, 72, 36);
  SSGClockDividers: array[0..3] of Integer = (1, 1, 4, 2);
begin
  FDivider := FMClockDividers[FPrescaler];
  FSSG.SetClock(FClock div SSGClockDividers[FPrescaler]);
  FFilter.Configure(FClock / FDivider, Min(14000, FSampleRate * 0.4));
end;

procedure TYM2203.WriteRegister(Index, Value: Byte);
begin
  FRegisters[Index] := Value;
  if Index in [$2D, $2E, $2F] then
  begin
    case Index of
      $2D:
        FPrescaler := FPrescaler or 2;
      $2E:
        FPrescaler := FPrescaler or 1;
      $2F:
        FPrescaler := 0;
    end;
    SelectPrescaler;
    Exit;
  end;
  if Index < 16 then
    FSSG.WriteRegister(Index, Value)
  else if ((Index >= $24) and (Index <= $28)) or
    ((Index >= $30) and (Index <= $B2)) then
  begin
    // A compiled TFM dump may use the OPN2 channel bit in chip 2 keys.
    // Each YM2203 itself has channels 0..2 only.
    if Index = $28 then
      Value := Value and $F3;
    FMDoAddress(FFM, 0, Index);
    FMDoData(FFM, Value);
  end;
end;

function TYM2203.ReadRegister(Index: Byte): Byte;
begin
  Result := FRegisters[Index];
end;

function TYM2203.GenerateFM: Integer;
const
  // Bit masks select earlier operators for modulation, and audible carriers.
  Routing: array[0..7, 1..3] of Byte =
    ((1, 2, 4), (0, 3, 4), (0, 2, 5), (1, 0, 6), (1, 0, 4), (1, 1, 1), (1, 0, 0), (0, 0, 0));
  Carriers: array[0..7] of Byte = (8, 8, 8, 8, 10, 14, 14, 15);
var
  Values: array[0..3] of Integer;

  function Signed14(Value: Cardinal): Integer;
  begin
    Result := Integer(Value and $1FFF) - Integer(Value and $2000);
  end;

  function Bits(Value: Integer): Cardinal;
  begin
    Result := Cardinal((Int64(Value) + 4294967296) and $FFFFFFFF);
  end;

begin
  Result := 0;
  for var C := 0 to 2 do
  begin
    var Feedback := 0;
    var Divisor := FFM.State.Channels[C].State.FeedbackDivisor;
    if Divisor <> ComputeFeedbackDivisor(0) then
    begin
      Feedback := Signed14(FFM.State.Channels[C].State.Operator1PreviousSamples[0]) +
        Signed14(FFM.State.Channels[C].State.Operator1PreviousSamples[1]);
      Feedback := Floor(Feedback / Double(Integer(1) shl Divisor));
    end;
    Values[0] := Signed14(FMOperatorProcess(FFM.State.Channels[C].State.Operators[0], 0, 0, Bits(Feedback)));
    var Algorithm := FFM.State.Channels[C].State.Algorithm;
    for var Op := 1 to 3 do
    begin
      var Modulation := 0;
      for var Source := 0 to Op - 1 do
        if (Routing[Algorithm, Op] and (1 shl Source)) <> 0 then
          Inc(Modulation, Values[Source]);
      Values[Op] := Signed14(FMOperatorProcess(FFM.State.Channels[C].State.Operators[Op], 0, 0, Bits(Modulation)));
    end;
    FFM.State.Channels[C].State.Operator1PreviousSamples[1] := FFM.State.Channels[C].State.Operator1PreviousSamples[0];
    FFM.State.Channels[C].State.Operator1PreviousSamples[0] := Word(Bits(Values[0]) and $FFFF);
    for var Op := 0 to 3 do
      if (Carriers[Algorithm] and (1 shl Op)) <> 0 then
        Inc(Result, Values[Op]);
  end;
  for var Timer := 0 to 1 do
    if (FRegisters[$27] and (1 shl Timer)) <> 0 then
    begin
      Dec(FFM.State.Timers[Timer].Counter);
      if FFM.State.Timers[Timer].Counter = 0 then
      begin
        FFM.State.Timers[Timer].Counter := FFM.State.Timers[Timer].Value;
        if FFM.State.Timers[Timer].Enabled <> 0 then
          FFM.State.Status := FFM.State.Status or (1 shl Timer);
        if (Timer = 0) and (FFM.State.Channel3Metadata.CsmModeEnabled <> 0) then
          for var Op := 0 to 3 do
          begin
            FMOperatorSetKeyOn(FFM.State.Channels[2].State.Operators[Op], 1);
            FMOperatorSetKeyOn(FFM.State.Channels[2].State.Operators[Op], 0);
          end;
      end;
    end;
  // YM2203 has no YM2612 9-bit DAC quantization or per-channel clipping.
  Result := Result div 2;
end;

function TYM2203.Sample: SmallInt;
var
  L, R: SmallInt;
begin
  FPhase := FPhase + FClock / (Double(FDivider) * FSampleRate);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    FFiltered := FFilter.Process(GenerateFM / 32768.0);
  end;
  FSSG.Sample(L, R);
  Result := EnsureRange(Round(FDC.Process(FFiltered) * 32767) + Integer(L), -32768, 32767);
end;

end.

