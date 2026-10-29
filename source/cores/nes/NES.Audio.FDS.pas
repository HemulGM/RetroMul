unit NES.Audio.FDS;

interface

uses
  NES.State;

type
  TFdsEnvelope = record
    Control, Gain, Timer: Integer;
  end;

  // FDS wavetable oscillator, envelopes and modulation, clocked at CPU rate.
  TFdsAudio = class
  private
    FWave, FModTable: array[0..63] of Byte;
    FVolume, FModVolume: TFdsEnvelope;
    FWaveFrequency, FModFrequency, FWavePhase, FModPhase: Integer;
    FWavePosition, FModPosition, FModCounter, FModOutput: Integer;
    FMasterVolume, FEnvelopeSpeed: Integer;
    FEnabled, FWriteWave, FHaltWave, FHaltMod, FHaltEnvelopes: Boolean;
    FAudioCycle, FClockDivider, FVolumeLatch: Integer;
    FForceModCarry: Boolean;
    FOutput, FRawOutput, FCpuRate, FFilterCoefficient: Double;
    FWaveSampleLatch: Byte;
    procedure ResetEnvelope(var Envelope: TFdsEnvelope);
    procedure WriteEnvelope(var Envelope: TFdsEnvelope; Value: Byte);
    procedure TickEnvelope(var Envelope: TFdsEnvelope);
    procedure UpdateModulation;
    procedure SetModCounter(Value: Integer);
    procedure FilterOutput;
  public
    constructor Create;
    procedure Reset;
    procedure SetClockRate(Value: Double);
    procedure Write(Address: Word; Value: Byte);
    function Read(Address: Word): Byte;
    procedure Clock;
    procedure SerializeState(State: TNesStateArchive);
    property Output: Double read FOutput;
    property DacOutput: Double read FRawOutput;
  end;

implementation

uses
  System.Math, System.Classes;

const
  // plgDavid's measured FDS DC response, normalized by Persune. Generated
  // measurement tables are MIT-0: https://gist.github.com/Gumball2415/28740c733a8cb7ef6a33747b14038926
  // Each master-volume row includes its measured attenuation.
  FdsDacLevels: array[0..3, 0..63] of Double = (
    (
    0.0, 0.011244038119912148, 0.02329244464635849, 0.03689166530966759,
    0.047064099460840225, 0.06144484132528305, 0.07443736493587494, 0.09127242118120193,
    0.09417109191417694, 0.11028067022562027, 0.12313485145568848, 0.14219805598258972,
    0.14938560128211975, 0.16868329048156738, 0.18354518711566925, 0.2068835198879242,
    0.18913626670837402, 0.20848724246025085, 0.2214938998222351, 0.2444956749677658,
    0.24725057184696198, 0.2701167166233063, 0.2853243052959442, 0.31316277384757996,
    0.29997509717941284, 0.32447120547294617, 0.33932965993881226, 0.3687431514263153,
    0.369509756565094, 0.3987109363079071, 0.41724449396133423, 0.45292046666145325,
    0.3818801939487457, 0.4082365036010742, 0.4212421178817749, 0.4525822103023529,
    0.4472583532333374, 0.4779548943042755, 0.4942852854728699, 0.5316809415817261,
    0.5007689595222473, 0.5322492122650146, 0.5475159287452698, 0.5858386158943176,
    0.579023540019989, 0.6160796880722046, 0.6360890865325928, 0.6816084384918213,
    0.6108525395393372, 0.6457463502883911, 0.6611738204956055, 0.7038924694061279,
    0.6922631859779358, 0.7332408428192139, 0.7534694075584412, 0.8035991191864014,
    0.756732165813446, 0.7988883852958679, 0.8184196352958679, 0.8701565265655518,
    0.8588585257530212, 0.9090140461921692, 0.9361159205436707, 1.0
  ),
    (
    0.0, 0.00751760508865118, 0.015601513907313347, 0.024745550006628036,
    0.031475771218538284, 0.04084152728319168, 0.0495813824236393, 0.061112891882658005,
    0.06309922784566879, 0.0739707350730896, 0.08266077190637589, 0.09520182013511658,
    0.09986435621976852, 0.11285379528999329, 0.12293221801519394, 0.13853029906749725,
    0.12667885422706604, 0.1396949738264084, 0.1482250690460205, 0.1633184850215912,
    0.16536860167980194, 0.18076641857624054, 0.1908012330532074, 0.2093292474746704,
    0.2005590796470642, 0.21670058369636536, 0.22626268863677979, 0.24572360515594482,
    0.24641752243041992, 0.265634149312973, 0.27789610624313354, 0.3014887273311615,
    0.2530110478401184, 0.27007654309272766, 0.2787778079509735, 0.2997715473175049,
    0.29595616459846497, 0.316366583108902, 0.32699066400527954, 0.3514823317527771,
    0.33034396171569824, 0.3513011634349823, 0.36147013306617737, 0.38665664196014404,
    0.381884902715683, 0.4061277210712433, 0.41876769065856934, 0.4483022689819336,
    0.40083572268486023, 0.42379626631736755, 0.4334810972213745, 0.4612535238265991,
    0.45318350195884705, 0.4795135259628296, 0.49193114042282104, 0.5242449641227722,
    0.49301135540008545, 0.5197716355323792, 0.5318145751953125, 0.5646808743476868,
    0.5557768940925598, 0.5869699120521545, 0.6029122471809387, 0.6419234871864319
  ),
    (
    0.0, 0.0055845919996500015, 0.011548739857971668, 0.018075991421937943,
    0.023292403668165207, 0.030559711158275604, 0.03711474686861038, 0.04573500528931618,
    0.04746655747294426, 0.0554223395884037, 0.061647236347198486, 0.07107464224100113,
    0.07488829642534256, 0.0846238061785698, 0.09217053651809692, 0.10388299822807312,
    0.09497179836034775, 0.1043887585401535, 0.11071209609508514, 0.12230295687913895,
    0.12374399602413177, 0.13535629212856293, 0.14299383759498596, 0.15668439865112305,
    0.1498510241508484, 0.16189949214458466, 0.1694662719964981, 0.1839539259672165,
    0.1844450831413269, 0.19882842898368835, 0.20781278610229492, 0.22509591281414032,
    0.18871892988681793, 0.2017892599105835, 0.208144873380661, 0.223714679479599,
    0.2210078090429306, 0.23595409095287323, 0.243573397397995, 0.26173460483551025,
    0.24635763466358185, 0.2617483139038086, 0.26920220255851746, 0.28784066438674927,
    0.28415247797966003, 0.3018605411052704, 0.3112235963344574, 0.33329325914382935,
    0.29784920811653137, 0.31488272547721863, 0.32196101546287537, 0.3423989713191986,
    0.3359692096710205, 0.35563334822654724, 0.36503279209136963, 0.3890612721443176,
    0.36551934480667114, 0.3855453431606293, 0.394037127494812, 0.4179627001285553,
    0.41125553846359253, 0.4345150291919708, 0.44601085782051086, 0.4746212661266327
  ),
    (
    0.0, 0.004381353501230478, 0.008918197825551033, 0.014247528277337551,
    0.01851591467857361, 0.024328410625457764, 0.029657334089279175, 0.03648122027516365,
    0.037894997745752335, 0.04409882798790932, 0.04910155385732651, 0.0566924586892128,
    0.059866614639759064, 0.06757217645645142, 0.07364130020141602, 0.08297587186098099,
    0.07571925967931747, 0.0833752229809761, 0.08860436826944351, 0.09774365276098251,
    0.0989546924829483, 0.10831043869256973, 0.11431360244750977, 0.12500041723251343,
    0.11974164843559265, 0.1294924020767212, 0.13535229861736298, 0.1469336748123169,
    0.1473645567893982, 0.15887905657291412, 0.16580817103385925, 0.1796664148569107,
    0.15059460699558258, 0.16096872091293335, 0.16610799729824066, 0.17853708565235138,
    0.17629046738147736, 0.18798133730888367, 0.19414560496807098, 0.2087274193763733,
    0.1963418573141098, 0.20865996181964874, 0.21467578411102295, 0.22946085035800934,
    0.22612421214580536, 0.24043625593185425, 0.24789848923683167, 0.2653835117816925,
    0.23718172311782837, 0.25068289041519165, 0.2562868893146515, 0.27222713828086853,
    0.26721659302711487, 0.28279784321784973, 0.29016512632369995, 0.30915653705596924,
    0.29052892327308655, 0.30624648928642273, 0.3126847743988037, 0.33181509375572205,
    0.3265245258808136, 0.34493425488471985, 0.35404476523399353, 0.3768875300884247
  )
  );
  FDS_DAC_PEAK = 2.4 * 95.88 / (8128.0 / 15.0 + 100.0);

constructor TFdsAudio.Create;
begin
  inherited;
  SetClockRate(1789773);
  Reset;
end;

procedure TFdsAudio.Reset;
begin
  FillChar(FWave, SizeOf(FWave), 0);
  FillChar(FModTable, SizeOf(FModTable), 0);
  FVolume := Default(TFdsEnvelope);
  FModVolume := Default(TFdsEnvelope);
  FEnvelopeSpeed := $E8;
  ResetEnvelope(FVolume);
  ResetEnvelope(FModVolume);
  FWaveFrequency := 0;
  FModFrequency := 0;
  FWavePhase := 0;
  FModPhase := 0;
  FWavePosition := 0;
  FModPosition := 0;
  FModCounter := 0;
  FModOutput := 0;
  FMasterVolume := 0;
  FEnabled := True;
  FWriteWave := False;
  FHaltWave := True;
  FHaltMod := True;
  FHaltEnvelopes := False;
  FAudioCycle := 0;
  FClockDivider := 0;
  FVolumeLatch := 0;
  FForceModCarry := False;
  FRawOutput := 0;
  FWaveSampleLatch := 0;
  FOutput := 0;
end;

procedure TFdsAudio.SetClockRate(Value: Double);
begin
  FCpuRate := Value;
  // The adapter's own analog low-pass precedes the Famicom/APU mixer.
  // Computing it in the CPU clock domain makes it independent of host rate.
  FFilterCoefficient := 1 - Exp(-2 * Pi * 2000 / FCpuRate);
end;

procedure TFdsAudio.FilterOutput;
begin
  FOutput := FOutput + FFilterCoefficient * (FRawOutput - FOutput);
  if Abs(FOutput) < 1E-30 then
    FOutput := 0;
end;

procedure TFdsAudio.ResetEnvelope(var Envelope: TFdsEnvelope);
begin
  Envelope.Timer := 8 * ((Envelope.Control and $3F) + 1) * (FEnvelopeSpeed + 1);
end;

procedure TFdsAudio.WriteEnvelope(var Envelope: TFdsEnvelope; Value: Byte);
begin
  Envelope.Control := Value;
  if (Value and $80) <> 0 then
    Envelope.Gain := Value and $3F;
  ResetEnvelope(Envelope);
end;

procedure TFdsAudio.TickEnvelope(var Envelope: TFdsEnvelope);
begin
  if ((Envelope.Control and $80) <> 0) or (FEnvelopeSpeed = 0) then
    Exit;
  Dec(Envelope.Timer);
  if Envelope.Timer <= 0 then
  begin
    ResetEnvelope(Envelope);
    if (Envelope.Control and $40) <> 0 then
    begin
      if Envelope.Gain < 32 then
        Inc(Envelope.Gain);
    end
    else if Envelope.Gain > 0 then
      Dec(Envelope.Gain);
  end;
end;

procedure TFdsAudio.SetModCounter(Value: Integer);
begin
  FModCounter := ((Value + 64) and $7F) - 64;
end;

procedure TFdsAudio.UpdateModulation;
var
  Product: Integer;
begin
  Product := FModCounter * FModVolume.Gain;
  // Loopy's hardware measurements: preserve all 20 product bits. The
  // previous rounded frequency offset lost low pitches and detuned notes.
  if ((Product and $0F) <> 0) and ((Product and $800) = 0) then
    Inc(Product, $20);
  Product := ((Product + $400) shr 4) and $FF;
  FModOutput := FWaveFrequency * Product;
end;

procedure TFdsAudio.Write(Address: Word; Value: Byte);
begin
  if Address = $4023 then
  begin
    FEnabled := (Value and 2) <> 0;
    if not FEnabled then
    begin
      FVolume.Gain := 0;
      FVolumeLatch := 0;
      FWavePhase := 0;
      FWavePosition := 0;
      FModCounter := 0;
      FRawOutput := 0;
    end;
    Exit;
  end;
  if (Address >= $4040) and (Address <= $407F) then
  begin
    if FWriteWave then
      FWave[Address and $3F] := Value and $3F;
    Exit;
  end;
  case Address of
    $4080:
      if FEnabled then
      begin
        WriteEnvelope(FVolume, Value);
        if FVolume.Gain = 0 then
        begin
          FVolumeLatch := 0;
          FRawOutput := 0;
        end;
      end;
    $4082:
      FWaveFrequency := (FWaveFrequency and $F00) or Value;
    $4083:
      begin
        FWaveFrequency := (FWaveFrequency and $FF) or ((Value and $0F) shl 8);
        FHaltWave := (Value and $80) <> 0;
        FHaltEnvelopes := (Value and $40) <> 0;
        if FHaltWave then
        begin
          FWavePosition := 0;
          FWavePhase := 0;
          FClockDivider := 0;
        end;
        if FHaltEnvelopes then
        begin
          ResetEnvelope(FVolume);
          ResetEnvelope(FModVolume);
        end;
      end;
    $4084:
      WriteEnvelope(FModVolume, Value);
    $4085:
      SetModCounter(Value and $7F);
    $4086:
      FModFrequency := (FModFrequency and $F00) or Value;
    $4087:
      begin
        FModFrequency := (FModFrequency and $FF) or ((Value and $0F) shl 8);
        FHaltMod := (Value and $80) <> 0;
        FForceModCarry := (Value and $40) <> 0;
        if FHaltMod then
        begin
          FModPhase := 0;
          FModPosition := FModPosition and $3E;
        end;
      end;
    $4088:
      if FHaltMod and FEnabled then
      begin
        FModTable[FModPosition] := Value and 7;
        FModTable[(FModPosition + 1) and 63] := Value and 7;
        FModPosition := (FModPosition + 2) and 63;
      end;
    $4089:
      begin
        FMasterVolume := Value and 3;
        FWriteWave := (Value and $80) <> 0;
      end;
    $408A:
      FEnvelopeSpeed := Value;
  end;
  UpdateModulation;
end;

function TFdsAudio.Read(Address: Word): Byte;
const
  Increments: array[0..7] of Byte = (0, 1, 2, 4, $C, $C, $E, $F);
begin
  Result := 0;
  if (Address >= $4040) and (Address <= $407F) then
    if FWriteWave then
      Result := FWave[Address and 63]
    else
      Result := FWave[FWavePosition];
  case Address of
    $4090:
      Result := $40 or FVolume.Gain;
    $4091:
      Result := ((FWavePosition shl 6) or (FWavePhase shr 12)) and $FF;
    $4092:
      Result := $40 or FModVolume.Gain;
    $4093:
      Result := (FModPhase shr 5) and $7F;
    $4094:
      // Settled multiplier result; intermediate serial-multiplier phases
      // are not yet modelled.
      Result := Floor(FModCounter * FModVolume.Gain / 16) and $FF;
    $4095:
      Result := Increments[FModTable[FModPosition]];
    $4096:
      if (FAudioCycle and $1F) < FVolumeLatch then
        Result := FWaveSampleLatch;
    $4097:
      Result := FModCounter and $7F;
  end;
end;

procedure TFdsAudio.Clock;
const
  ModSteps: array[0..7] of Integer = (0, 1, 2, 4, 0, -4, -2, -1);
var
  Step, EnvelopeClocks: Integer;
begin
  FAudioCycle := (FAudioCycle + 1) and $1F;
  FClockDivider := (FClockDivider + 1) and $0F;
  if not FEnabled then
  begin
    FVolume.Gain := 0;
    FVolumeLatch := 0;
    FWavePosition := 0;
    FWavePhase := 0;
    FModCounter := 0;
    FRawOutput := 0;
    FilterOutput;
    Exit;
  end;
  if not FHaltEnvelopes then
  begin
    // $4083.7 speeds envelopes up fourfold, while stopping the accumulators.
    if FHaltWave then
      EnvelopeClocks := 4
    else
      EnvelopeClocks := 1;
    for var I := 1 to EnvelopeClocks do
    begin
      TickEnvelope(FVolume);
      TickEnvelope(FModVolume);
    end;
  end;
  if FHaltWave then
    FClockDivider := 0
  else if FClockDivider = 0 then
  begin
    // Both accumulators tick every 16 CPU clocks, not continuously.
    if not FHaltMod then
    begin
      Inc(FModPhase, FModFrequency);
      if (FModPhase >= $1000) or FForceModCarry then
      begin
        FModPhase := FModPhase and $FFF;
        Step := FModTable[FModPosition];
        if Step = 4 then
          FModCounter := 0
        else
          SetModCounter(FModCounter + ModSteps[Step]);
        FModPosition := (FModPosition + 1) and 63;
      end;
    end;
    UpdateModulation;
    Inc(FWavePhase, FModOutput);
    FWavePosition := (FWavePosition + (FWavePhase shr 18)) and 63;
    FWavePhase := FWavePhase and $3FFFF;
  end;
  if FWavePosition = 0 then
    FVolumeLatch := Min(FVolume.Gain, 32);
  // $4089.7 holds the wave DAC sample, not the independent volume gates.
  // Run the actual 32-cycle volume PWM into the analog filter. Averaging
  // its duty before filtering would discard the DAC's ultrasonic ripple.
  if not FWriteWave then
    FWaveSampleLatch := FWave[FWavePosition];
  if FAudioCycle < FVolumeLatch then
    FRawOutput := FdsDacLevels[FMasterVolume, FWaveSampleLatch] * FDS_DAC_PEAK
  else
    FRawOutput := 0;
  FilterOutput;
end;

procedure TFdsAudio.SerializeState(State: TNesStateArchive);
begin
  State.Field(FWave, SizeOf(FWave));
  State.Field(FModTable, SizeOf(FModTable));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FModVolume, SizeOf(FModVolume));
  State.Field(FWaveFrequency, SizeOf(FWaveFrequency));
  State.Field(FModFrequency, SizeOf(FModFrequency));
  State.Field(FWavePhase, SizeOf(FWavePhase));
  State.Field(FModPhase, SizeOf(FModPhase));
  State.Field(FWavePosition, SizeOf(FWavePosition));
  State.Field(FModPosition, SizeOf(FModPosition));
  State.Field(FModCounter, SizeOf(FModCounter));
  State.Field(FModOutput, SizeOf(FModOutput));
  State.Field(FMasterVolume, SizeOf(FMasterVolume));
  State.Field(FEnvelopeSpeed, SizeOf(FEnvelopeSpeed));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FWriteWave, SizeOf(FWriteWave));
  State.Field(FHaltWave, SizeOf(FHaltWave));
  State.Field(FHaltMod, SizeOf(FHaltMod));
  State.Field(FHaltEnvelopes, SizeOf(FHaltEnvelopes));
  State.Field(FOutput, SizeOf(FOutput));
  if State.Version >= 23 then
  begin
    State.Field(FAudioCycle, SizeOf(FAudioCycle));
    State.Field(FClockDivider, SizeOf(FClockDivider));
    State.Field(FVolumeLatch, SizeOf(FVolumeLatch));
    State.Field(FForceModCarry, SizeOf(FForceModCarry));
  end
  else if State.Loading then
  begin
    FAudioCycle := 0;
    FClockDivider := 0;
    FVolumeLatch := Min(FVolume.Gain, 32);
    FForceModCarry := False;
    // v22 used CPU-rate 16-bit fractions instead of the hardware dividers.
    FWavePhase := FWavePhase shl 2;
    FModPhase := FModPhase shr 4;
    UpdateModulation;
  end;
  if State.Version >= 24 then
  begin
    State.Field(FRawOutput, SizeOf(FRawOutput));
    State.Field(FWaveSampleLatch, SizeOf(FWaveSampleLatch));
    State.Field(FCpuRate, SizeOf(FCpuRate));
  end
  else if State.Loading then
  begin
    FRawOutput := FOutput;
    FWaveSampleLatch := FWave[FWavePosition and 63];
  end;
  if State.Loading then
  begin
    if IsNan(FCpuRate) or IsInfinite(FCpuRate) or
      (FCpuRate < 1000000) or (FCpuRate > 3000000) or
      IsNan(FOutput) or IsInfinite(FOutput) or
      IsNan(FRawOutput) or IsInfinite(FRawOutput) or
      (FOutput < 0) or (FOutput > 1) or
      (FRawOutput < 0) or (FRawOutput > 1) or (FWaveSampleLatch > 63) then
      raise EReadError.Create('Invalid FDS audio snapshot');
    SetClockRate(FCpuRate);
    for var Value in FWave do
      if Value > 63 then
        raise EReadError.Create('Invalid FDS audio snapshot');
    for var Value in FModTable do
      if Value > 7 then
        raise EReadError.Create('Invalid FDS audio snapshot');
    if (FVolume.Control < 0) or (FVolume.Control > 255) or
      (FModVolume.Control < 0) or (FModVolume.Control > 255) or
      (FVolume.Gain < 0) or (FVolume.Gain > 63) or
      (FModVolume.Gain < 0) or (FModVolume.Gain > 63) or
      (FVolume.Timer < 0) or (FVolume.Timer > 131072) or
      (FModVolume.Timer < 0) or (FModVolume.Timer > 131072) or
      (FModCounter < -64) or (FModCounter > 63) or
      (FModOutput < 0) or (FModOutput > $FFFFF) then
      raise EReadError.Create('Invalid FDS audio snapshot');
  end;
  if State.Loading then
    if (FAudioCycle < 0) or (FAudioCycle > $1F) or
      (FClockDivider < 0) or (FClockDivider > $0F) or
      (FVolumeLatch < 0) or (FVolumeLatch > 32) or
      (FWavePhase < 0) or (FWavePhase > $3FFFF) or
      (FModPhase < 0) or (FModPhase > $FFF) or (FWavePosition < 0) or (FWavePosition > 63) or
      (FModPosition < 0) or (FModPosition > 63) or
      (FMasterVolume < 0) or (FMasterVolume > 3) or
      (FWaveFrequency < 0) or (FWaveFrequency > $FFF) or
      (FModFrequency < 0) or (FModFrequency > $FFF) or
      (FEnvelopeSpeed < 0) or (FEnvelopeSpeed > 255) then
      raise EReadError.Create('Invalid FDS audio snapshot');
end;

end.

