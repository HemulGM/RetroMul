unit NES.APU;

interface

uses
  NES.State, System.Math, NES.Types, NES.Consts, Core.AudioFilter;

type
  TApuRegisterWriteEvent = procedure(Cycle: UInt32; Address: UInt16; Value: UInt8) of object;

  TPulseChannel = record
    Reg0: UInt8;
    Reg1: UInt8;
    Reg2: UInt8;
    Reg3: UInt8;
    Enabled: Boolean;
    LengthCounter: Integer;
    TimerReload: Integer;
    Timer: Integer;
    SequenceStep: Integer;
    EnvelopeStart: Boolean;
    EnvelopeDivider: Integer;
    EnvelopeDecay: Integer;
    SweepReload: Boolean;
    SweepDivider: Integer;
  end;

  TTriangleChannel = record
    Reg0: UInt8;
    Reg2: UInt8;
    Reg3: UInt8;
    Enabled: Boolean;
    LengthCounter: Integer;
    TimerReload: Integer;
    Timer: Integer;
    SequenceStep: Integer;
    LinearCounter: Integer;
    LinearReloadFlag: Boolean;
  end;

  TNoiseChannel = record
    Reg0: UInt8;
    Reg2: UInt8;
    Reg3: UInt8;
    Enabled: Boolean;
    LengthCounter: Integer;
    TimerReload: Integer;
    Timer: Integer;
    Shift: UInt16;
    EnvelopeStart: Boolean;
    EnvelopeDivider: Integer;
    EnvelopeDecay: Integer;
  end;

  TDmcChannel = record
    Control: UInt8;
    SampleAddress: UInt16;
    SampleLength: Integer;
    CurrentAddress: UInt16;
    BytesRemaining: Integer;
    TimerReload, Timer: Integer;
    OutputLevel, Shift, SampleBuffer: UInt8;
    BitsRemaining: Integer;
    BufferEmpty, Silence, IrqFlag: Boolean;
  end;

  TApu = class
  private
    FRegion: TNesRegion;
    FOnRegisterWrite: TApuRegisterWriteEvent;
    FPulse1: TPulseChannel;
    FPulse2: TPulseChannel;
    FTriangle: TTriangleChannel;
    FNoise: TNoiseChannel;
    FDmc: TDmcChannel;
    FDmcDmaDelay: Integer;
    FDmcDisableDelay: Integer;
    FDmcAbortRequested: Boolean;
    FCycle: UInt32;
    FFrameCounter: UInt32;
    FFrameMode5: Boolean;
    FFrameIrqInhibit: Boolean;
    FPendingFrameMode5: Boolean;
    FPendingFrameIrqInhibit: Boolean;
    FFrameResetDelay: Integer;
    FFrameIrqFlag: Boolean;
    FFrameIrqClearPending: Boolean;
    FSampleRate: Integer;
    FSampleTimer: Double;
    FSampleStep: Double;
    FBuffer: array of SmallInt;
    FWritePos: Integer;
    FReadPos: Integer;
    FCount: Integer;
    FWriteCounts: array[$4000..$4017] of UInt64;
    FHp90Output: Double;
    FHp90Input: Double;
    FHp440Output: Double;
    FHp440Input: Double;
    FLp14Output: Double;
    FAntiAlias: TPCMLowPass;
    FMixKey: Integer;
    FMixValue: Double;
    FMixValid: Boolean;
    FHp90Coefficient: Double;
    FHp440Coefficient: Double;
    FLp14Coefficient: Double;
    function LengthFromIndex(Index: UInt8): Integer;
    function PulseSweepTarget(const Channel: TPulseChannel; NegateExtra: Integer): Integer;
    function PulseVolume(const Channel: TPulseChannel): Integer;
    function NoiseVolume: Integer;
    function PulseRawOutput(const Channel: TPulseChannel; NegateExtra: Integer): Integer;
    function TriangleRawOutput: Integer;
    function NoiseRawOutput: Integer;
    procedure ClockPulseEnvelope(var Channel: TPulseChannel);
    procedure ClockNoiseEnvelope;
    procedure ClockLinearCounter;
    procedure ClockLengthCounters;
    procedure ClockSweep(var Channel: TPulseChannel; NegateExtra: Integer);
    procedure QuarterFrame;
    procedure HalfFrame;
    procedure ClockDmc;
    procedure RestartDmc;
    function ReadStatus: UInt8;
    procedure PushSample(Value: SmallInt);
    function MixSample: Double;
    function FilterSample(Value: Double): Double;
  public
    procedure SerializeState(State: TNesStateArchive);
    procedure SerializeDmaState(State: TNesStateArchive);
    constructor Create;
    // Select timing before running; resets channels and buffered PCM.
    procedure SetRegion(Value: TNesRegion);
    procedure Reset;
    procedure SetSampleRate(Value: Integer);
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    function CpuReadStatus: UInt8;
    function IrqPending: Boolean;
    procedure Clock;
    function DmcDmaRequested: Boolean;
    function ConsumeDmcAbort: Boolean;
    function DmcDmaAddress: UInt16;
    procedure CompleteDmcDma(Value: UInt8);
    function PopSamples(var Samples: array of SmallInt): Integer;
    function DebugStatus: UInt8;
    function DebugPulse1Reg0: UInt8;
    function DebugPulse1Length: Integer;
    function DebugPulse2Length: Integer;
    function DebugTriangleLength: Integer;
    function DebugNoiseLength: Integer;
    function DebugWriteCount(Address: UInt16): UInt64;
    function DebugCycle: UInt32;
    function DebugFrameCounter: UInt32;
    function DebugFrameIrqFlag: Boolean;
    property DebugPulse1: TPulseChannel read FPulse1;
    property DebugPulse2: TPulseChannel read FPulse2;
    property DebugTriangle: TTriangleChannel read FTriangle;
    property DebugNoise: TNoiseChannel read FNoise;
    property DebugDmc: TDmcChannel read FDmc;
    property OnRegisterWrite: TApuRegisterWriteEvent read FOnRegisterWrite write FOnRegisterWrite;
  end;

implementation

procedure TApu.SerializeDmaState(State: TNesStateArchive);
begin
  if State.Version >= 8 then
    State.Field(FDmcDmaDelay, SizeOf(FDmcDmaDelay))
  else if State.Loading then
    FDmcDmaDelay := 0;
  if State.Version >= 10 then
  begin
    State.Field(FDmcDisableDelay, SizeOf(FDmcDisableDelay));
    State.Field(FDmcAbortRequested, SizeOf(FDmcAbortRequested));
  end
  else if State.Loading then
  begin
    FDmcDisableDelay := 0;
    FDmcAbortRequested := False;
  end;
end;

procedure TApu.SerializeState(State: TNesStateArchive);
begin
  // The mixer cache is derived from channel state and never stored in snapshots.
  FMixValid := False;
  State.Field(FRegion, SizeOf(FRegion));
  State.Field(FPulse1, SizeOf(FPulse1));
  State.Field(FPulse2, SizeOf(FPulse2));
  State.Field(FTriangle, SizeOf(FTriangle));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FDmc, SizeOf(FDmc));
  State.Field(FCycle, SizeOf(FCycle));
  State.Field(FFrameCounter, SizeOf(FFrameCounter));
  State.Field(FFrameMode5, SizeOf(FFrameMode5));
  State.Field(FFrameIrqInhibit, SizeOf(FFrameIrqInhibit));
  State.Field(FPendingFrameMode5, SizeOf(FPendingFrameMode5));
  State.Field(FPendingFrameIrqInhibit, SizeOf(FPendingFrameIrqInhibit));
  State.Field(FFrameResetDelay, SizeOf(FFrameResetDelay));
  State.Field(FFrameIrqFlag, SizeOf(FFrameIrqFlag));
  if State.Version >= 9 then
    State.Field(FFrameIrqClearPending, SizeOf(FFrameIrqClearPending))
  else if State.Loading then
    FFrameIrqClearPending := False;
  State.Field(FSampleRate, SizeOf(FSampleRate));
  State.Field(FSampleTimer, SizeOf(FSampleTimer));
  State.Field(FSampleStep, SizeOf(FSampleStep));
  if Length(FBuffer) > 0 then
    State.Field(FBuffer[0], Length(FBuffer) * SizeOf(FBuffer[0]));
  State.Field(FWritePos, SizeOf(FWritePos));
  State.Field(FReadPos, SizeOf(FReadPos));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FWriteCounts, SizeOf(FWriteCounts));
  State.Field(FHp90Output, SizeOf(FHp90Output));
  State.Field(FHp90Input, SizeOf(FHp90Input));
  State.Field(FHp440Output, SizeOf(FHp440Output));
  State.Field(FHp440Input, SizeOf(FHp440Input));
  State.Field(FLp14Output, SizeOf(FLp14Output));
  State.Field(FHp90Coefficient, SizeOf(FHp90Coefficient));
  State.Field(FHp440Coefficient, SizeOf(FHp440Coefficient));
  State.Field(FLp14Coefficient, SizeOf(FLp14Coefficient));
  if State.Version >= 3 then
    State.Field(FAntiAlias, SizeOf(FAntiAlias))
  else if State.Loading then
    FAntiAlias.Reset;
  // Rebuild derived coefficients, including when loading older snapshots.
  SetSampleRate(FSampleRate);
end;

const
  LENGTH_TABLE: array[0..31] of Integer = (
    10, 254, 20, 2, 40, 4, 80, 6,
    160, 8, 60, 10, 14, 12, 26, 14,
    12, 16, 24, 18, 48, 20, 96, 22,
    192, 24, 72, 26, 16, 28, 32, 30
  );
  DUTY_TABLE: array[0..3, 0..7] of Integer = (
    (0, 1, 0, 0, 0, 0, 0, 0),
    (0, 1, 1, 0, 0, 0, 0, 0),
    (0, 1, 1, 1, 1, 0, 0, 0),
    (1, 0, 0, 1, 1, 1, 1, 1)
  );
  TRI_TABLE: array[0..31] of Integer = (
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
  );
  NOISE_PERIOD_TABLE: array[TNesRegion, 0..15] of Integer = (
    (4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068),
    (4, 8, 14, 30, 60, 88, 118, 148, 188, 236, 354, 472, 708, 944, 1890, 3778),
    (4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068));
  DMC_PERIOD_TABLE: array[TNesRegion, 0..15] of Integer = (
    (428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54),
    (398, 354, 316, 298, 276, 236, 210, 198, 176, 148, 132, 118, 98, 78, 66, 50),
    (428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54));
  // CPU-cycle positions of the quarter/half-frame sequencer events.
  FRAME_STEPS: array[TNesRegion, 0..4] of UInt32 = (
    (7457, 14913, 22371, 29829, 37281),
    (8313, 16627, 24939, 33253, 41565),
    (7457, 14913, 22371, 29829, 37281));

constructor TApu.Create;
begin
  inherited Create;
  SetSampleRate(44100);
  SetLength(FBuffer, 16384);
  Reset;
end;

procedure TApu.SetRegion(Value: TNesRegion);
begin
  FRegion := Value;
  SetSampleRate(FSampleRate);
  Reset;
end;

procedure TApu.Reset;
begin
  FillChar(FPulse1, SizeOf(FPulse1), 0);
  FillChar(FPulse2, SizeOf(FPulse2), 0);
  FillChar(FTriangle, SizeOf(FTriangle), 0);
  FillChar(FNoise, SizeOf(FNoise), 0);
  FNoise.Shift := 1;
  FNoise.TimerReload := NOISE_PERIOD_TABLE[FRegion, 0];
  FillChar(FDmc, SizeOf(FDmc), 0);
  FDmc.SampleAddress := $C000;
  FDmc.SampleLength := 1;
  FDmc.TimerReload := DMC_PERIOD_TABLE[FRegion, 0];
  FDmc.Timer := FDmc.TimerReload - 1;
  FDmc.BitsRemaining := 8;
  FDmc.BufferEmpty := True;
  FDmc.Silence := True;
  FDmcDmaDelay := 0;
  FDmcDisableDelay := 0;
  FDmcAbortRequested := False;
  FCycle := 0;
  FFrameCounter := 0;
  FFrameMode5 := False;
  FFrameIrqInhibit := False;
  FPendingFrameMode5 := False;
  FPendingFrameIrqInhibit := False;
  FFrameResetDelay := 0;
  FFrameIrqFlag := False;
  FFrameIrqClearPending := False;
  FSampleTimer := 0;
  FWritePos := 0;
  FReadPos := 0;
  FCount := 0;
  FillChar(FWriteCounts, SizeOf(FWriteCounts), 0);
  FHp90Output := 0;
  FHp90Input := 0;
  FHp440Output := 0;
  FHp440Input := 0;
  FLp14Output := 0;
  FAntiAlias.Reset;
end;

procedure TApu.SetSampleRate(Value: Integer);
begin
  if Value <= 0 then
    Value := 44100;
  FSampleRate := Value;
  FSampleStep := CpuFrequency(FRegion) / FSampleRate;
  FAntiAlias.Configure(CpuFrequency(FRegion), Min(12000.0, FSampleRate * 0.27));
  var Dt: Double := 1.0 / FSampleRate;
  var Rc: Double := 1.0 / (2.0 * Pi * 90.0);
  FHp90Coefficient := Rc / (Rc + Dt);
  Rc := 1.0 / (2.0 * Pi * 440.0);
  FHp440Coefficient := Rc / (Rc + Dt);
  // Filter the CPU-rate mixer BEFORE decimation. At lower output rates,
  // lower the cutoff as well so ultrasonic content cannot freely alias.
  Dt := 1.0 / CpuFrequency(FRegion);
  Rc := 1.0 / (2.0 * Pi * Min(14000.0, FSampleRate * 0.3));
  FLp14Coefficient := Dt / (Rc + Dt);
end;

function TApu.LengthFromIndex(Index: UInt8): Integer;
begin
  Result := LENGTH_TABLE[Index and 31];
end;

function TApu.PulseSweepTarget(const Channel: TPulseChannel; NegateExtra: Integer): Integer;
begin
  var Change: Integer := Channel.TimerReload shr (Channel.Reg1 and 7);
  if (Channel.Reg1 and $08) <> 0 then
    Result := Channel.TimerReload - Change - NegateExtra
  else
    Result := Channel.TimerReload + Change;
end;

function TApu.PulseVolume(const Channel: TPulseChannel): Integer;
begin
  if (Channel.Reg0 and $10) <> 0 then
    Result := Channel.Reg0 and $0F
  else
    Result := Channel.EnvelopeDecay;
end;

function TApu.NoiseVolume: Integer;
begin
  if (FNoise.Reg0 and $10) <> 0 then
    Result := FNoise.Reg0 and $0F
  else
    Result := FNoise.EnvelopeDecay;
end;

function TApu.PulseRawOutput(const Channel: TPulseChannel; NegateExtra: Integer): Integer;
begin
  Result := 0;
  if not Channel.Enabled or (Channel.LengthCounter = 0) then
    Exit;
  if Channel.TimerReload < 8 then
    Exit;
  var SweepTarget: Integer := PulseSweepTarget(Channel, NegateExtra);
  if SweepTarget > $7FF then
    Exit;
  var Duty: Integer := (Channel.Reg0 shr 6) and 3;
  if DUTY_TABLE[Duty, Channel.SequenceStep and 7] = 0 then
    Exit;
  Result := PulseVolume(Channel);
end;

function TApu.TriangleRawOutput: Integer;
begin
  // Stopping the sequencer holds its DAC level; it does not output zero.
  Result := TRI_TABLE[FTriangle.SequenceStep and 31];
end;

function TApu.NoiseRawOutput: Integer;
begin
  Result := 0;
  if not FNoise.Enabled or (FNoise.LengthCounter = 0) then
    Exit;
  if (FNoise.Shift and 1) <> 0 then
    Exit;
  Result := NoiseVolume;
end;

procedure TApu.ClockPulseEnvelope(var Channel: TPulseChannel);
begin
  if Channel.EnvelopeStart then
  begin
    Channel.EnvelopeStart := False;
    Channel.EnvelopeDecay := 15;
    Channel.EnvelopeDivider := Channel.Reg0 and $0F;
  end
  else if Channel.EnvelopeDivider > 0 then
    Dec(Channel.EnvelopeDivider)
  else
  begin
    Channel.EnvelopeDivider := Channel.Reg0 and $0F;
    if Channel.EnvelopeDecay > 0 then
      Dec(Channel.EnvelopeDecay)
    else if (Channel.Reg0 and $20) <> 0 then
      Channel.EnvelopeDecay := 15;
  end;
end;

procedure TApu.ClockNoiseEnvelope;
begin
  if FNoise.EnvelopeStart then
  begin
    FNoise.EnvelopeStart := False;
    FNoise.EnvelopeDecay := 15;
    FNoise.EnvelopeDivider := FNoise.Reg0 and $0F;
  end
  else if FNoise.EnvelopeDivider > 0 then
    Dec(FNoise.EnvelopeDivider)
  else
  begin
    FNoise.EnvelopeDivider := FNoise.Reg0 and $0F;
    if FNoise.EnvelopeDecay > 0 then
      Dec(FNoise.EnvelopeDecay)
    else if (FNoise.Reg0 and $20) <> 0 then
      FNoise.EnvelopeDecay := 15;
  end;
end;

procedure TApu.ClockLinearCounter;
begin
  if FTriangle.LinearReloadFlag then
    FTriangle.LinearCounter := FTriangle.Reg0 and $7F
  else if FTriangle.LinearCounter > 0 then
    Dec(FTriangle.LinearCounter);

  if (FTriangle.Reg0 and $80) = 0 then
    FTriangle.LinearReloadFlag := False;
end;

procedure TApu.ClockLengthCounters;
begin
  if FPulse1.Enabled and (FPulse1.LengthCounter > 0) and ((FPulse1.Reg0 and $20) = 0) then
    Dec(FPulse1.LengthCounter);
  if FPulse2.Enabled and (FPulse2.LengthCounter > 0) and ((FPulse2.Reg0 and $20) = 0) then
    Dec(FPulse2.LengthCounter);
  if FTriangle.Enabled and (FTriangle.LengthCounter > 0) and ((FTriangle.Reg0 and $80) = 0) then
    Dec(FTriangle.LengthCounter);
  if FNoise.Enabled and (FNoise.LengthCounter > 0) and ((FNoise.Reg0 and $20) = 0) then
    Dec(FNoise.LengthCounter);
end;

procedure TApu.ClockSweep(var Channel: TPulseChannel; NegateExtra: Integer);
begin
  var NewPeriod: Integer;
  var DividerPeriod: Integer := (Channel.Reg1 shr 4) and 7;
  if (Channel.SweepDivider = 0) and ((Channel.Reg1 and $80) <> 0) and ((Channel.Reg1 and 7) <> 0) then
  begin
    NewPeriod := PulseSweepTarget(Channel, NegateExtra);
    if (Channel.TimerReload >= 8) and (NewPeriod <= $7FF) and (NewPeriod >= 0) then
      Channel.TimerReload := NewPeriod;
  end;
  if (Channel.SweepDivider = 0) or Channel.SweepReload then
  begin
    Channel.SweepReload := False;
    Channel.SweepDivider := DividerPeriod;
  end
  else
    Dec(Channel.SweepDivider);
end;

procedure TApu.QuarterFrame;
begin
  ClockPulseEnvelope(FPulse1);
  ClockPulseEnvelope(FPulse2);
  ClockNoiseEnvelope;
  ClockLinearCounter;
end;

procedure TApu.HalfFrame;
begin
  ClockLengthCounters;
  ClockSweep(FPulse1, 1);
  ClockSweep(FPulse2, 0);
end;

procedure TApu.CpuWrite(Address: UInt16; Value: UInt8);
begin
  if Assigned(FOnRegisterWrite) then
    FOnRegisterWrite(FCycle, Address, Value);
  if (Address >= $4000) and (Address <= $4017) then
    Inc(FWriteCounts[Address]);

  case Address of
    $4000:
      begin
        FPulse1.Reg0 := Value;
      end;
    $4001:
      begin
        FPulse1.Reg1 := Value;
        FPulse1.SweepReload := True;
      end;
    $4002:
      begin
        FPulse1.Reg2 := Value;
        FPulse1.TimerReload := (FPulse1.TimerReload and $700) or Value;
      end;
    $4003:
      begin
        FPulse1.Reg3 := Value;
        FPulse1.TimerReload := ((Value and 7) shl 8) or (FPulse1.TimerReload and $FF);
        if FPulse1.Enabled then
          FPulse1.LengthCounter := LengthFromIndex(Value shr 3);
        FPulse1.SequenceStep := 0;
        FPulse1.EnvelopeStart := True;
      end;
    $4004:
      begin
        FPulse2.Reg0 := Value;
      end;
    $4005:
      begin
        FPulse2.Reg1 := Value;
        FPulse2.SweepReload := True;
      end;
    $4006:
      begin
        FPulse2.Reg2 := Value;
        FPulse2.TimerReload := (FPulse2.TimerReload and $700) or Value;
      end;
    $4007:
      begin
        FPulse2.Reg3 := Value;
        FPulse2.TimerReload := ((Value and 7) shl 8) or (FPulse2.TimerReload and $FF);
        if FPulse2.Enabled then
          FPulse2.LengthCounter := LengthFromIndex(Value shr 3);
        FPulse2.SequenceStep := 0;
        FPulse2.EnvelopeStart := True;
      end;
    $4008:
      FTriangle.Reg0 := Value;
    $400A:
      begin
        FTriangle.Reg2 := Value;
        FTriangle.TimerReload := ((FTriangle.Reg3 and 7) shl 8) or FTriangle.Reg2;
      end;
    $400B:
      begin
        FTriangle.Reg3 := Value;
        FTriangle.TimerReload := ((FTriangle.Reg3 and 7) shl 8) or FTriangle.Reg2;
        if FTriangle.Enabled then
          FTriangle.LengthCounter := LengthFromIndex(Value shr 3);
        FTriangle.LinearReloadFlag := True;
      end;
    $400C:
      begin
        FNoise.Reg0 := Value;
      end;
    $400E:
      begin
        FNoise.Reg2 := Value;
        FNoise.TimerReload := NOISE_PERIOD_TABLE[FRegion, Value and $0F];
      end;
    $400F:
      begin
        FNoise.Reg3 := Value;
        if FNoise.Enabled then
          FNoise.LengthCounter := LengthFromIndex(Value shr 3);
        FNoise.EnvelopeStart := True;
      end;
    $4010:
      begin
        FDmc.Control := Value;
        FDmc.TimerReload := DMC_PERIOD_TABLE[FRegion, Value and $0F];
        if (Value and $80) = 0 then
          FDmc.IrqFlag := False;
      end;
    $4011:
      FDmc.OutputLevel := Value and $7F;
    $4012:
      FDmc.SampleAddress := $C000 or (UInt16(Value) shl 6);
    $4013:
      FDmc.SampleLength := Integer(Value) * 16 + 1;
    $4015:
      begin
        FPulse1.Enabled := (Value and $01) <> 0;
        if not FPulse1.Enabled then
          FPulse1.LengthCounter := 0;
        FPulse2.Enabled := (Value and $02) <> 0;
        if not FPulse2.Enabled then
          FPulse2.LengthCounter := 0;
        FTriangle.Enabled := (Value and $04) <> 0;
        if not FTriangle.Enabled then
          FTriangle.LengthCounter := 0;
        FNoise.Enabled := (Value and $08) <> 0;
        if not FNoise.Enabled then
          FNoise.LengthCounter := 0;
        FDmc.IrqFlag := False;
        if (Value and $10) = 0 then
        begin
          if FDmcDisableDelay = 0 then
            FDmcDisableDelay := 3 + Ord((FCycle and 1) = 0);
        end
        else if FDmc.BytesRemaining = 0 then
        begin
          RestartDmc;
          // Load DMA halts on the get phase of the second following APU cycle.
          // Enable propagation also gates a reload if the output buffer
          // empties immediately after this write.
          FDmcDmaDelay := 3 + Ord((FCycle and 1) = 0);
        end;
      end;
    $4017:
      begin
        FPendingFrameMode5 := (Value and $80) <> 0;
        FPendingFrameIrqInhibit := (Value and $40) <> 0;
        FFrameIrqInhibit := FPendingFrameIrqInhibit;
        if FPendingFrameIrqInhibit then
        begin
          FFrameIrqInhibit := True;
          FFrameIrqFlag := False;
        end;
        // Clock runs before the CPU access: odd FCycle is the PUT phase.
        if (FCycle and 1) <> 0 then
          FFrameResetDelay := 3
        else
          FFrameResetDelay := 4;
      end;
  end;
end;

function TApu.ReadStatus: UInt8;
begin
  Result := 0;
  if FPulse1.LengthCounter > 0 then
    Result := Result or $01;
  if FPulse2.LengthCounter > 0 then
    Result := Result or $02;
  if FTriangle.LengthCounter > 0 then
    Result := Result or $04;
  if FNoise.LengthCounter > 0 then
    Result := Result or $08;
  if FDmc.BytesRemaining > 0 then
    Result := Result or $10;
  if FFrameIrqFlag then
    Result := Result or $40;
  if FDmc.IrqFlag then
    Result := Result or $80;
end;

function TApu.CpuReadStatus: UInt8;
begin
  Result := ReadStatus;
  // The status read requests a clear on the next GET phase. Two adjacent
  // reads starting on GET therefore both see the old frame IRQ flag.
  FFrameIrqClearPending := True;
end;

function TApu.IrqPending: Boolean;
begin
  Result := (FFrameIrqFlag and not FFrameIrqInhibit) or FDmc.IrqFlag;
end;

function TApu.FilterSample(Value: Double): Double;
begin
  FHp90Output := FHp90Coefficient * (FHp90Output + Value - FHp90Input);
  FHp90Input := Value;
  FHp440Output := FHp440Coefficient * (FHp440Output + FHp90Output - FHp440Input);
  FHp440Input := FHp90Output;
  Result := FHp440Output;
end;

function TApu.MixSample: Double;
begin
  var PulseMix: Double;
  var TndMix: Double;
  var PulseDenom: Double;
  var TndInput: Double;
  var TndDenom: Double;
  var P1: Integer := PulseRawOutput(FPulse1, 1);
  var P2: Integer := PulseRawOutput(FPulse2, 0);
  var Tri: Integer := TriangleRawOutput;
  var Noi: Integer := NoiseRawOutput;
  var Key := (P1 + P2) or (Tri shl 5) or (Noi shl 9) or (Integer(FDmc.OutputLevel) shl 13);
  if FMixValid and (FMixKey = Key) then
    Exit(FMixValue);

  if (P1 + P2) = 0 then
    PulseMix := 0
  else
  begin
    PulseDenom := (8128.0 / (P1 + P2)) + 100.0;
    if PulseDenom <= 0 then
      PulseMix := 0
    else
      PulseMix := 95.88 / PulseDenom;
  end;

  if (Tri = 0) and (Noi = 0) and (FDmc.OutputLevel = 0) then
    TndMix := 0
  else
  begin
    TndInput := (Tri / 8227.0) + (Noi / 12241.0) + (FDmc.OutputLevel / 22638.0);
    if TndInput <= 0 then
      TndMix := 0
    else
    begin
      TndDenom := (1.0 / TndInput) + 100.0;
      if TndDenom <= 0 then
        TndMix := 0
      else
        TndMix := 159.79 / TndDenom;
    end;
  end;

  Result := PulseMix + TndMix;
  if IsNan(Result) or IsInfinite(Result) then
    Result := 0;
  if Result < 0 then
    Result := 0;
  if Result > 1 then
    Result := 1;
  FMixKey := Key;
  FMixValue := Result;
  FMixValid := True;
end;

procedure TApu.PushSample(Value: SmallInt);
begin
  if FCount >= Length(FBuffer) then
  begin
    FReadPos := (FReadPos + 1) mod Length(FBuffer);
    Dec(FCount);
  end;
  FBuffer[FWritePos] := Value;
  FWritePos := (FWritePos + 1) mod Length(FBuffer);
  Inc(FCount);
end;

procedure TApu.RestartDmc;
begin
  FDmc.CurrentAddress := FDmc.SampleAddress;
  FDmc.BytesRemaining := FDmc.SampleLength;
end;

function TApu.ConsumeDmcAbort: Boolean;
begin
  Result := FDmcAbortRequested;
  FDmcAbortRequested := False;
end;

function TApu.DmcDmaRequested: Boolean;
begin
  Result := FDmc.BufferEmpty and (FDmc.BytesRemaining > 0) and (FDmcDmaDelay = 0);
end;

function TApu.DmcDmaAddress: UInt16;
begin
  Result := FDmc.CurrentAddress;
end;

procedure TApu.CompleteDmcDma(Value: UInt8);
begin
  if not DmcDmaRequested then
    Exit;
  FDmc.SampleBuffer := Value;
  FDmc.BufferEmpty := False;
  if FDmc.CurrentAddress = $FFFF then
    FDmc.CurrentAddress := $8000
  else
    Inc(FDmc.CurrentAddress);
  Dec(FDmc.BytesRemaining);
  if FDmc.BytesRemaining = 0 then
  begin
    if (FDmc.Control and $40) <> 0 then
      RestartDmc
    else if (FDmc.Control and $80) <> 0 then
      FDmc.IrqFlag := True;
  end;
  // A one-byte fetch ending just before the output shifter reload produces
  // a spurious reload request, then the length gate cancels it one cycle later.
  if (FDmc.SampleLength = 1) and ((FDmc.Control and $40) = 0) and
    (FDmc.BitsRemaining = 1) and (FDmc.Timer < 2) then
  begin
    FDmc.Shift := FDmc.SampleBuffer;
    RestartDmc;
    FDmcDisableDelay := 4;
  end;
end;

procedure TApu.ClockDmc;
begin
  if FDmc.Timer > 0 then
  begin
    Dec(FDmc.Timer);
    Exit;
  end;
  FDmc.Timer := FDmc.TimerReload - 1;
  if not FDmc.Silence then
  begin
    if (FDmc.Shift and 1) <> 0 then
    begin
      if FDmc.OutputLevel <= 125 then
        Inc(FDmc.OutputLevel, 2);
    end
    else if FDmc.OutputLevel >= 2 then
      Dec(FDmc.OutputLevel, 2);
  end;
  FDmc.Shift := FDmc.Shift shr 1;
  Dec(FDmc.BitsRemaining);
  if FDmc.BitsRemaining = 0 then
  begin
    FDmc.BitsRemaining := 8;
    FDmc.Silence := FDmc.BufferEmpty;
    if not FDmc.BufferEmpty then
    begin
      FDmc.Shift := FDmc.SampleBuffer;
      FDmc.BufferEmpty := True;
      // The output unit empties on get; reload DMA first tries to halt on put.
      if FDmcDmaDelay < 1 then
        FDmcDmaDelay := 1;
    end;
  end;
end;

procedure TApu.Clock;
begin
  var Feedback: UInt16;
  var Sample: Double;
  FCycle := (UInt64(FCycle) + 1) and $FFFFFFFF;
  if FFrameIrqClearPending and ((FCycle and 1) = 0) then
  begin
    FFrameIrqFlag := False;
    FFrameIrqClearPending := False;
  end;
  if FDmcDmaDelay > 0 then
    Dec(FDmcDmaDelay);
  if FDmcDisableDelay > 0 then
  begin
    Dec(FDmcDisableDelay);
    if FDmcDisableDelay = 0 then
    begin
      FDmc.BytesRemaining := 0;
      FDmcAbortRequested := True;
    end;
  end;

  var FrameReset: Boolean := False;
  if FFrameResetDelay > 0 then
  begin
    Dec(FFrameResetDelay);
    if FFrameResetDelay = 0 then
    begin
      FFrameMode5 := FPendingFrameMode5;
      FFrameIrqInhibit := FPendingFrameIrqInhibit;
      FFrameCounter := 0;
      FrameReset := True;
      if FFrameMode5 then
      begin
        QuarterFrame;
        HalfFrame;
      end;
    end;
  end;

  if not FrameReset then
    Inc(FFrameCounter);

  if (FFrameCounter = FRAME_STEPS[FRegion, 0]) or (FFrameCounter = FRAME_STEPS[FRegion, 2]) then
    QuarterFrame;
  if FFrameCounter = FRAME_STEPS[FRegion, 1] then
  begin
    QuarterFrame;
    HalfFrame;
  end;
  if not FFrameMode5 then
  begin
    if FFrameCounter = FRAME_STEPS[FRegion, 3] then
    begin
      QuarterFrame;
      HalfFrame;
    end;
    if (FFrameCounter >= FRAME_STEPS[FRegion, 3] - 1) and (FFrameCounter <= FRAME_STEPS[FRegion, 3] + 1) then
    begin
      // Inhibit masks the IRQ pin, but the status latch still pulses during
      // the first two terminal clocks. The third clock applies inhibit.
      FFrameIrqFlag := not FFrameIrqInhibit or
        (FFrameCounter < FRAME_STEPS[FRegion, 3] + 1);
      if FFrameCounter = FRAME_STEPS[FRegion, 3] + 1 then
        FFrameCounter := 0;
    end;
  end
  else
  begin
    if FFrameCounter = FRAME_STEPS[FRegion, 4] then
    begin
      QuarterFrame;
      HalfFrame;
    end;
    if FFrameCounter = FRAME_STEPS[FRegion, 4] + 1 then
      FFrameCounter := 0;
  end;

  if (FCycle and 1) = 0 then
  begin
    if FPulse1.Timer <= 0 then
    begin
      FPulse1.Timer := FPulse1.TimerReload;
      FPulse1.SequenceStep := (FPulse1.SequenceStep + 1) and 7;
    end
    else
      Dec(FPulse1.Timer);

    if FPulse2.Timer <= 0 then
    begin
      FPulse2.Timer := FPulse2.TimerReload;
      FPulse2.SequenceStep := (FPulse2.SequenceStep + 1) and 7;
    end
    else
      Dec(FPulse2.Timer);
  end;

  // The table is in CPU cycles, not the half-rate pulse timer clocks.
  if FNoise.Timer <= 0 then
  begin
    FNoise.Timer := FNoise.TimerReload - 1;
    if (FNoise.Reg2 and $80) <> 0 then
      Feedback := ((FNoise.Shift and 1) xor ((FNoise.Shift shr 6) and 1))
    else
      Feedback := ((FNoise.Shift and 1) xor ((FNoise.Shift shr 1) and 1));
    FNoise.Shift := (FNoise.Shift shr 1) or (Feedback shl 14);
  end
  else
    Dec(FNoise.Timer);

  ClockDmc;

  if FTriangle.Timer <= 0 then
  begin
    FTriangle.Timer := FTriangle.TimerReload;
    if (FTriangle.LengthCounter > 0) and (FTriangle.LinearCounter > 0) then
      FTriangle.SequenceStep := (FTriangle.SequenceStep + 1) and 31;
  end
  else
    Dec(FTriangle.Timer);

  // An output-rate low-pass cannot remove frequencies that have already
  // folded into the audible band. Keep its history at the APU clock rate.
  FLp14Output := FLp14Output + FLp14Coefficient * (FAntiAlias.Process(MixSample) - FLp14Output);
  FSampleTimer := FSampleTimer + 1.0;
  while FSampleTimer >= FSampleStep do
  begin
    FSampleTimer := FSampleTimer - FSampleStep;
    Sample := FilterSample(FLp14Output);
    if IsNan(Sample) or IsInfinite(Sample) then
      Sample := 0;
    if Sample > 1 then
      Sample := 1
    else if Sample < -1 then
      Sample := -1;
    PushSample(Round(Sample * 32767));
  end;
end;

function TApu.PopSamples(var Samples: array of SmallInt): Integer;
begin
  Result := Min(Length(Samples), FCount);
  for var i := 0 to Result - 1 do
  begin
    Samples[i] := FBuffer[FReadPos];
    FReadPos := (FReadPos + 1) mod Length(FBuffer);
  end;
  Dec(FCount, Result);
end;

function TApu.DebugStatus: UInt8;
begin
  Result := ReadStatus;
end;

function TApu.DebugPulse1Reg0: UInt8;
begin
  Result := FPulse1.Reg0;
end;

function TApu.DebugPulse1Length: Integer;
begin
  Result := FPulse1.LengthCounter;
end;

function TApu.DebugPulse2Length: Integer;
begin
  Result := FPulse2.LengthCounter;
end;

function TApu.DebugTriangleLength: Integer;
begin
  Result := FTriangle.LengthCounter;
end;

function TApu.DebugNoiseLength: Integer;
begin
  Result := FNoise.LengthCounter;
end;

function TApu.DebugWriteCount(Address: UInt16): UInt64;
begin
  if (Address >= $4000) and (Address <= $4017) then
    Result := FWriteCounts[Address]
  else
    Result := 0;
end;

function TApu.DebugCycle: UInt32;
begin
  Result := FCycle;
end;

function TApu.DebugFrameCounter: UInt32;
begin
  Result := FFrameCounter;
end;

function TApu.DebugFrameIrqFlag: Boolean;
begin
  Result := FFrameIrqFlag;
end;

end.

