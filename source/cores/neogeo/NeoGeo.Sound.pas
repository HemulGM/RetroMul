unit NeoGeo.Sound;

interface

uses
  System.SysUtils, MD.Sound, ZX.Sound.YM2149, NeoGeo.Cartridge, Core.Snapshots;

const
  NG_SAMPLE_RATE = 44100;

type
  TNGADPCMVoice = record
    Playing: Boolean;
    Position, Ending: Integer;
    Predictor, Step: Integer;
    Output: Integer;
  end;

  TNeoGeoSound = class
  private
    FCart: TNeoGeoCartridge;
    FFM: TFM;
    FSSG: TYM2149F;
    FRegisters: array[0..511] of Byte;
    FAddress: array[0..1] of Byte;
    FVoices: array[0..6] of TNGADPCMVoice;
    FEndFlags, FEndMask: Byte;
    FBusy, FClockRemainder, FSamplePhase: Integer;
    FAFraction, FBFraction: Integer;
    FNativeLeft, FNativeRight: Integer;
    procedure NativeTick;
    procedure GenerateFM;
    procedure ClockADPCMA;
    procedure ClockADPCMB;
    procedure WriteRegister(Bank: Integer; Index, Value: Byte);
    procedure StartVoice(Channel: Integer);
  public
    Samples: TArray<SmallInt>;
    constructor Create(Cart: TNeoGeoCartridge);
    destructor Destroy; override;
    procedure Reset;
    procedure BeginFrame;
    procedure Advance(MasterClocks: Integer);
    procedure WritePort(Port: Integer; Value: Byte);
    function ReadPort(Port: Integer): Byte;
    function IRQ: Boolean;
    function SampleFrames: Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor TNeoGeoSound.Create(Cart: TNeoGeoCartridge);
begin
  inherited Create;
  FCart := Cart;
  FSSG := TYM2149F.Create(2000000, NG_SAMPLE_RATE);
  FSSG.AYModel := True;
  for var I := 0 to 2 do
    FSSG.SetPan(I, 0.33, 0.33);
  Reset;
end;

destructor TNeoGeoSound.Destroy;
begin
  FSSG.Free;
  inherited;
end;

procedure TNeoGeoSound.Reset;
begin
  FFM := Default(TFM);
  FMInitialise(FFM);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FAddress, SizeOf(FAddress), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
  FSSG.Reset;
  FEndFlags := 0;
  FEndMask := $BF;
  FBusy := 0;
  FClockRemainder := 0;
  FSamplePhase := 0;
  FAFraction := 0;
  FBFraction := 0;
  FNativeLeft := 0;
  FNativeRight := 0;
  Samples := nil;
end;

procedure TNeoGeoSound.BeginFrame;
begin
  Samples := nil;
end;

procedure TNeoGeoSound.StartVoice(Channel: Integer);
begin
  var Base := $110 + Channel;
  var Ending := $120 + Channel;
  if Channel = 6 then
  begin
    Base := $12;
    Ending := $14;
  end;
  var Start := Integer(FRegisters[Base]) or (Integer(FRegisters[Base + 8]) shl 8);
  var Finish := Integer(FRegisters[Ending]) or (Integer(FRegisters[Ending + 8]) shl 8);
  if Channel = 6 then
  begin
    Start := Integer(FRegisters[$12]) or (Integer(FRegisters[$13]) shl 8);
    Finish := Integer(FRegisters[$14]) or (Integer(FRegisters[$15]) shl 8);
  end;
  FVoices[Channel] := Default(TNGADPCMVoice);
  FVoices[Channel].Position := Start * 512;
  FVoices[Channel].Ending := (Finish + 1) * 512;
  FVoices[Channel].Playing := True;
  if Channel = 6 then
    FVoices[Channel].Step := 127;
  var Flag := 1 shl Channel;
  if Channel = 6 then
    Flag := $80;
  FEndFlags := Byte(FEndFlags and ($FF xor Flag));
end;

procedure TNeoGeoSound.WriteRegister(Bank: Integer; Index, Value: Byte);
begin
  FRegisters[Bank * 256 + Index] := Value;
  if Bank = 0 then
  begin
    if Index < 16 then
      FSSG.WriteRegister(Index, Value)
    else if Index = $10 then
    begin
      if (Value and 1) <> 0 then
        FVoices[6].Playing := False
      else if (Value and $80) <> 0 then
      begin
        FBFraction := 0;
        StartVoice(6);
      end;
    end
    else if Index = $1C then
    begin
      FEndFlags := Byte(FEndFlags and ($FF xor Value));
      FEndMask := Byte((Value xor $FF) and $BF);
    end
    else if (Index >= $22) and (Index <= $B6) and not (Index in [$2A, $2B, $2C]) then
    begin
      FMDoAddress(FFM, 0, Index);
      FMDoData(FFM, Value);
    end;
  end
  else if Index = 0 then
  begin
    for var I := 0 to 5 do
      if (Value and (1 shl I)) <> 0 then
      begin
        if (Value and $80) <> 0 then
          FVoices[I].Playing := False
        else
          StartVoice(I);
      end;
  end
  else if (Index >= $30) and (Index <= $B6) then
  begin
    FMDoAddress(FFM, 1, Index);
    FMDoData(FFM, Value);
  end;
end;

procedure TNeoGeoSound.WritePort(Port: Integer; Value: Byte);
begin
  var Bank := (Port shr 1) and 1;
  if (Port and 1) = 0 then
    FAddress[Bank] := Value
  else
    WriteRegister(Bank, FAddress[Bank], Value);
  if (Port and 1) = 0 then
    FBusy := 17 * 3
  else
    FBusy := 83 * 3;
end;

function TNeoGeoSound.ReadPort(Port: Integer): Byte;
begin
  Result := 0;
  case Port and 3 of
    0:
      begin
        Result := FFM.State.Status and 3;
        if FBusy > 0 then
          Result := Result or $80;
      end;
    1:
      if FAddress[0] < 16 then
        Result := FRegisters[FAddress[0]];
    2:
      Result := FEndFlags and FEndMask;
  end;
end;

function TNeoGeoSound.IRQ: Boolean;
begin
  Result := ((FFM.State.Status and 1) <> 0) and ((FRegisters[$27] and 4) <> 0) or
    ((FFM.State.Status and 2) <> 0) and ((FRegisters[$27] and 8) <> 0);
end;

procedure TNeoGeoSound.ClockADPCMA;
const
  Steps: array[0..48] of Integer = (16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279,
    307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552);
  Adjust: array[0..7] of Integer = (-1, -1, -1, -1, 2, 5, 7, 9);
begin
  for var I := 0 to 5 do
    if FVoices[I].Playing then
    begin
      var Pos := FVoices[I].Position;
      if (Pos >= FVoices[I].Ending) or (Pos div 2 >= Length(FCart.SamplesA)) then
      begin
        FVoices[I].Playing := False;
        FVoices[I].Output := 0;
        FEndFlags := Byte(FEndFlags or (1 shl I));
        Continue;
      end;
      var N := (FCart.SamplesA[Pos div 2] shr ((1 - (Pos and 1)) * 4)) and 15;
      var Delta := (2 * (N and 7) + 1) * Steps[FVoices[I].Step] div 8;
      if (N and 8) <> 0 then
        Delta := -Delta;
      var Sum := (FVoices[I].Predictor + Delta + $1000) and $FFF;
      FVoices[I].Predictor := (Sum and $7FF) - (Sum and $800);
      FVoices[I].Step := EnsureRange(FVoices[I].Step + Adjust[N and 7], 0, 48);
      var Attenuation := (FRegisters[$101] xor $3F) and $3F;
      Inc(Attenuation, (FRegisters[$108 + I] xor $1F) and $1F);
      if Attenuation >= 63 then
        FVoices[I].Output := 0
      else
      begin
        var Product := FVoices[I].Predictor * 16 * (15 - (Attenuation and 7));
        FVoices[I].Output := Integer(Floor(Product / Double(1 shl (5 + (Attenuation shr 3))))) and (not 3);
      end;
      Inc(FVoices[I].Position);
    end;
end;

procedure TNeoGeoSound.ClockADPCMB;
const
  Adjust: array[0..7] of Integer = (57, 57, 57, 57, 77, 102, 128, 153);
begin
  if not FVoices[6].Playing then
    Exit;
  var Pos := FVoices[6].Position;
  if (Pos >= FVoices[6].Ending) or (Pos div 2 >= Length(FCart.SamplesB)) then
  begin
    if (FRegisters[$10] and $10) <> 0 then
    begin
      StartVoice(6);
      Pos := FVoices[6].Position;
    end
    else
    begin
      FVoices[6].Playing := False;
      FVoices[6].Output := 0;
      FEndFlags := FEndFlags or $80;
      Exit;
    end;
  end;
  if Pos div 2 >= Length(FCart.SamplesB) then
    Exit;
  var N := (FCart.SamplesB[Pos div 2] shr ((1 - (Pos and 1)) * 4)) and 15;
  var Delta := (2 * (N and 7) + 1) * FVoices[6].Step div 8;
  if (N and 8) <> 0 then
    Delta := -Delta;
  FVoices[6].Predictor := EnsureRange(FVoices[6].Predictor + Delta, -32768, 32767);
  FVoices[6].Step := EnsureRange(FVoices[6].Step * Adjust[N and 7] div 64, 127, 24576);
  FVoices[6].Output := FVoices[6].Predictor * FRegisters[$1B] div 256;
  Inc(FVoices[6].Position);
end;

procedure TNeoGeoSound.GenerateFM;
const
  Channels: array[0..3] of Integer = (1, 2, 4, 5);
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
  FNativeLeft := 0;
  FNativeRight := 0;
  for var C in Channels do
  begin
    var Feedback := 0;
    var Divisor := FFM.State.Channels[C].State.FeedbackDivisor;
    if Divisor <> ComputeFeedbackDivisor(0) then
      Feedback := Floor((Signed14(FFM.State.Channels[C].State.Operator1PreviousSamples[0]) +
        Signed14(FFM.State.Channels[C].State.Operator1PreviousSamples[1])) / Double(1 shl Divisor));
    var AM := FFM.State.LFO.AmplitudeModulation;
    var AMShift := FFM.State.Channels[C].State.AmplitudeModulationShift;
    Values[0] := Signed14(FMOperatorProcess(FFM.State.Channels[C].State.Operators[0], AM, AMShift, Bits(Feedback)));
    var Algorithm := FFM.State.Channels[C].State.Algorithm;
    for var Op := 1 to 3 do
    begin
      var Modulation := 0;
      for var Source := 0 to Op - 1 do
        if (Routing[Algorithm, Op] and (1 shl Source)) <> 0 then
          Inc(Modulation, Values[Source]);
      Values[Op] := Signed14(FMOperatorProcess(FFM.State.Channels[C].State.Operators[Op], AM, AMShift, Bits(Modulation)));
    end;
    FFM.State.Channels[C].State.Operator1PreviousSamples[1] := FFM.State.Channels[C].State.Operator1PreviousSamples[0];
    FFM.State.Channels[C].State.Operator1PreviousSamples[0] := Word(Bits(Values[0]) and $FFFF);
    var Sample := 0;
    for var Op := 0 to 3 do
      if (Carriers[Algorithm] and (1 shl Op)) <> 0 then
        Inc(Sample, Values[Op]);
    Sample := Sample div 2;
    if FFM.State.Channels[C].PanLeft <> 0 then
      Inc(FNativeLeft, Sample);
    if FFM.State.Channels[C].PanRight <> 0 then
      Inc(FNativeRight, Sample);
  end;
end;

procedure TNeoGeoSound.NativeTick;
begin
  if FMLFOAdvance(FFM.State.LFO) <> 0 then
    for var C := 0 to 5 do
      FMChannelSetPhaseModulation(FFM.State.Channels[C].State, FFM.State.LFO.PhaseModulation);
  GenerateFM;
  for var I := 0 to 1 do
    if (FRegisters[$27] and (1 shl I)) <> 0 then
    begin
      if FFM.State.Timers[I].Counter > 1 then
        Dec(FFM.State.Timers[I].Counter)
      else
      begin
        FFM.State.Timers[I].Counter := FFM.State.Timers[I].Value;
        if FFM.State.Timers[I].Enabled <> 0 then
          FFM.State.Status := Byte(FFM.State.Status or (1 shl I));
      end;
    end;
  Inc(FAFraction);
  if FAFraction = 3 then
  begin
    FAFraction := 0;
    ClockADPCMA;
  end;
  Inc(FBFraction, Integer(FRegisters[$19]) or (Integer(FRegisters[$1A]) shl 8));
  while FBFraction >= $10000 do
  begin
    Dec(FBFraction, $10000);
    ClockADPCMB;
  end;
  for var I := 0 to 6 do
  begin
    var Pan := FRegisters[$108 + I];
    if I = 6 then
      Pan := FRegisters[$11];
    if (Pan and $80) <> 0 then
      Inc(FNativeLeft, FVoices[I].Output);
    if (Pan and $40) <> 0 then
      Inc(FNativeRight, FVoices[I].Output);
  end;
end;

procedure TNeoGeoSound.Advance(MasterClocks: Integer);
begin
  if (MasterClocks < 0) or (MasterClocks > 4096) then
    raise EArgumentOutOfRangeException.Create('YM2610 clock slice');
  FBusy := Max(0, FBusy - MasterClocks);
  // Both synthesis and host sampling are clocked from the same 24 MHz timeline.
  for var I := 1 to MasterClocks do
  begin
    Inc(FClockRemainder);
    if FClockRemainder = 432 then
    begin
      FClockRemainder := 0;
      NativeTick;
    end;
    Inc(FSamplePhase, NG_SAMPLE_RATE);
    if FSamplePhase >= 24000000 then
    begin
      Dec(FSamplePhase, 24000000);
      var L, R: SmallInt;
      FSSG.Sample(L, R);
      var Index := Length(Samples);
      SetLength(Samples, Index + 2);
      Samples[Index] := EnsureRange(FNativeLeft + Integer(L), -32768, 32767);
      Samples[Index + 1] := EnsureRange(FNativeRight + Integer(R), -32768, 32767);
    end;
  end;
end;

function TNeoGeoSound.SampleFrames: Integer;
begin
  Result := Length(Samples) div 2;
end;

procedure TNeoGeoSound.SerializeState(State: TStateArchive);
begin
  State.Field(FFM, SizeOf(FFM));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FVoices, SizeOf(FVoices));
  State.Field(FEndFlags, SizeOf(FEndFlags));
  State.Field(FEndMask, SizeOf(FEndMask));
  State.Field(FBusy, SizeOf(FBusy));
  State.Field(FClockRemainder, SizeOf(FClockRemainder));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FAFraction, SizeOf(FAFraction));
  State.Field(FBFraction, SizeOf(FBFraction));
  State.Field(FNativeLeft, SizeOf(FNativeLeft));
  State.Field(FNativeRight, SizeOf(FNativeRight));
  FSSG.SerializeState(State.Field);
  if State.Loading then
    Samples := nil;
end;

end.

