unit C64.Sound.SID;

interface

uses
  System.SysUtils, Core.AudioFilter;

type
  TSIDModel = (MOS6581, MOS8580);

  TSIDVoice = record
    Phase, Noise: Cardinal;
    Envelope, State, RateCounter, ExpCounter, ExpPeriod: Integer;
    Gate, HoldZero: Boolean;
  end;

  TSID = class
  private
    FRegisters: array[0..31] of Byte;
    FVoices: array[0..2] of TSIDVoice;
    FModel: TSIDModel;
    FClock, FSampleRate: Integer;
    FLow, FBand: Double;
    FBus: Byte;
    FDirectSum, FRoutedSum, FVolumeSum, FDACSum: Double;
    FCount: Integer;
    FDC: TPCMDCBlocker;
    function Wave(Voice: Integer): Integer;
    procedure EnvelopeClock(Voice: Integer);
  public
    constructor Create(Model: TSIDModel = MOS6581; Clock: Integer = 985248; SampleRate: Integer = 44100);
    procedure Reset;
    procedure WriteRegister(RegisterID, Value: Byte);
    function ReadRegister(RegisterID: Byte): Byte;
    procedure Clock;
    function Sample: SmallInt;
    property Model: TSIDModel read FModel;
  end;

implementation

uses
  System.Math;

const
  Rates: array[0..15] of Integer = (9, 32, 63, 95, 149, 220, 267, 313, 392, 977, 1954, 3126, 3907, 11720, 19532, 31251);

constructor TSID.Create(Model: TSIDModel; Clock, SampleRate: Integer);
begin
  inherited Create;
  if (Clock < 500000) or (Clock > 2000000) or (SampleRate < 8000) or (SampleRate > 192000) then
    raise EArgumentOutOfRangeException.Create('Invalid SID clock/sample rate');
  FModel := Model;
  FClock := Clock;
  FSampleRate := SampleRate;
  FDC.Configure(SampleRate, 20);
  Reset;
end;

procedure TSID.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
  for var V := 0 to 2 do
  begin
    FVoices[V].Noise := $7FFFF8;
    FVoices[V].ExpPeriod := 1;
    FVoices[V].State := 2;
    FVoices[V].HoldZero := True;
  end;
  FLow := 0;
  FBand := 0;
  FBus := 0;
  FDirectSum := 0;
  FRoutedSum := 0;
  FVolumeSum := 0;
  FDACSum := 0;
  FCount := 0;
  FDC.Reset;
end;

procedure TSID.WriteRegister(RegisterID, Value: Byte);
begin
  RegisterID := RegisterID and 31;
  FBus := Value;
  if RegisterID > 24 then
    Exit;
  var Old := FRegisters[RegisterID];
  FRegisters[RegisterID] := Value;
  if (RegisterID < 21) and (RegisterID mod 7 = 4) then
  begin
    var V := RegisterID div 7;
    var Gate := (Value and 1) <> 0;
    if Gate <> FVoices[V].Gate then
    begin
      FVoices[V].Gate := Gate;
      if Gate then
      begin
        FVoices[V].State := 0;
        FVoices[V].HoldZero := False;
      end
      else
        FVoices[V].State := 2;
    end;
    if ((Value and 8) <> 0) and ((Old and 8) = 0) then
    begin
      FVoices[V].Phase := 0;
      FVoices[V].Noise := $7FFFF8;
    end;
  end;
end;

function TSID.ReadRegister(RegisterID: Byte): Byte;
begin
  case RegisterID and 31 of
    25, 26:
      Result := $FF;
    27:
      Result := Wave(2) shr 4;
    28:
      Result := FVoices[2].Envelope;
  else
    Result := FBus;
  end;
end;

procedure TSID.EnvelopeClock(Voice: Integer);
begin
  var V := FVoices[Voice];
  var Base := Voice * 7;
  var Rate: Integer;
  case V.State of
    0:
      Rate := FRegisters[Base + 5] shr 4;
    1:
      Rate := FRegisters[Base + 5] and 15;
  else
    Rate := FRegisters[Base + 6] and 15;
  end;
  V.RateCounter := (V.RateCounter + 1) and $7FFF;
  if V.RateCounter = 0 then
    V.RateCounter := 1;
  if V.RateCounter = Rates[Rate] then
  begin
    V.RateCounter := 0;
    if V.State = 0 then
    begin
      V.ExpCounter := 0;
      V.Envelope := (V.Envelope + 1) and 255;
      if V.Envelope = 255 then
        V.State := 1;
    end
    else
    begin
      Inc(V.ExpCounter);
      if V.ExpCounter >= V.ExpPeriod then
      begin
        V.ExpCounter := 0;
        if not V.HoldZero and ((V.State = 2) or (V.Envelope <> (FRegisters[Base + 6] shr 4) * 17)) then
          V.Envelope := (V.Envelope + 255) and 255;
      end;
    end;
    case V.Envelope of
      255:
        V.ExpPeriod := 1;
      93:
        V.ExpPeriod := 2;
      54:
        V.ExpPeriod := 4;
      26:
        V.ExpPeriod := 8;
      14:
        V.ExpPeriod := 16;
      6:
        V.ExpPeriod := 30;
      0:
        begin
          V.ExpPeriod := 1;
          V.HoldZero := True;
        end;
    end;
  end;
  FVoices[Voice] := V;
end;

procedure TSID.Clock;
var
  Rising: array[0..2] of Boolean;
begin
  for var V := 0 to 2 do
  begin
    var Old := FVoices[V].Phase;
    if (FRegisters[V * 7 + 4] and 8) = 0 then
      FVoices[V].Phase := (UInt64(Old) + Cardinal(FRegisters[V * 7]) + Cardinal(FRegisters[V * 7 + 1]) * 256) and $FFFFFF;
    Rising[V] := ((Old and $800000) = 0) and ((FVoices[V].Phase and $800000) <> 0);
    if ((Old and $080000) = 0) and ((FVoices[V].Phase and $080000) <> 0) then
      FVoices[V].Noise := ((FVoices[V].Noise shl 1) or (((FVoices[V].Noise shr 22) xor (FVoices[V].Noise shr 17)) and 1)) and $7FFFFF;
    EnvelopeClock(V);
  end;
  for var V := 0 to 2 do
  begin
    var Source := (V + 2) mod 3;
    if Rising[Source] and ((FRegisters[V * 7 + 4] and 2) <> 0) and
      not (Rising[(Source + 2) mod 3] and ((FRegisters[Source * 7 + 4] and 2) <> 0)) then
      FVoices[V].Phase := 0;
  end;
  // Integrate at the chip clock before resampling, including volume DAC writes.
  var Volume := (FRegisters[24] and 15) / 15.0;
  var Offset: Double := 0.02;
  if FModel = MOS8580 then
    Offset := 0.002;
  FVolumeSum := FVolumeSum + Volume;
  FDACSum := FDACSum + Volume * Offset;
  for var V := 0 to 2 do
  begin
    var Value := (Wave(V) - 2048) / 2048.0 * (FVoices[V].Envelope / 255.0) / 3;
    if (FRegisters[23] and (1 shl V)) <> 0 then
      FRoutedSum := FRoutedSum + Value
    else if (V <> 2) or ((FRegisters[24] and $80) = 0) then
      FDirectSum := FDirectSum + Value;
  end;
  Inc(FCount);
  // Keep the standalone kernel bounded even if a caller forgets to consume PCM.
  if FCount = 2000000 then
  begin
    FDirectSum := FDirectSum / FCount;
    FRoutedSum := FRoutedSum / FCount;
    FVolumeSum := FVolumeSum / FCount;
    FDACSum := FDACSum / FCount;
    FCount := 1;
  end;
end;

function TSID.Wave(Voice: Integer): Integer;
begin
  var Base := Voice * 7;
  var Control := FRegisters[Base + 4];
  var Phase := FVoices[Voice].Phase;
  Result := $FFF;
  if (Control and $F0) = 0 then
    Exit(0);
  if (Control and $10) <> 0 then
  begin
    var Invert := (Phase and $800000) <> 0;
    if (Control and 4) <> 0 then
      Invert := Invert xor ((FVoices[(Voice + 2) mod 3].Phase and $800000) <> 0);
    var Triangle := (Phase shr 11) and $FFF;
    if Invert then
      Triangle := Triangle xor $FFF;
    Result := Result and (Triangle and $FFE);
  end;
  if (Control and $20) <> 0 then
    Result := Result and (Phase shr 12);
  if (Control and $40) <> 0 then
    if ((Control and 8) = 0) and (Integer(Phase shr 12) < (Integer(FRegisters[Base + 2]) + (Integer(FRegisters[Base + 3] and 15) shl 8))) then
      Result := 0;
  if (Control and $80) <> 0 then
  begin
    var N := FVoices[Voice].Noise;
    var Noise := ((N shr 11) and $800) or ((N shr 10) and $400) or ((N shr 7) and $200) or
      ((N shr 5) and $100) or ((N shr 4) and $80) or ((N shr 1) and $40) or ((N shl 1) and $20) or ((N shl 2) and $10);
    Result := Result and Noise;
  end;
end;

function TSID.Sample: SmallInt;
begin
  if FCount = 0 then
    Clock;
  var Direct := FDirectSum / FCount;
  var Routed := FRoutedSum / FCount;
  var Volume := FVolumeSum / FCount;
  var DAC := FDACSum / FCount;
  FDirectSum := 0;
  FRoutedSum := 0;
  FVolumeSum := 0;
  FDACSum := 0;
  FCount := 0;
  var Cutoff := (Integer(FRegisters[21] and 7) + Integer(FRegisters[22]) * 8) / 2047.0;
  if FModel = MOS6581 then
    Cutoff := 30 + 12000 * Sqr(Cutoff)
  else
    Cutoff := 30 + 12500 * Cutoff;
  var Coefficient := 2 * Sin(Pi * Min(Cutoff, FSampleRate * 0.4) / (FSampleRate * 2));
  var Damping := 1.45 - (FRegisters[23] shr 4) * 0.055;
  // Stable state-variable approximation; model-specific analog calibration is future work.
  var High: Double;
  for var Step := 1 to 2 do
  begin
    High := Routed - FLow - Damping * FBand;
    FBand := FBand + Coefficient * High;
    FLow := FLow + Coefficient * FBand;
  end;
  var Filtered: Double := 0;
  if (FRegisters[24] and $10) <> 0 then
    Filtered := Filtered + FLow;
  if (FRegisters[24] and $20) <> 0 then
    Filtered := Filtered + FBand;
  if (FRegisters[24] and $40) <> 0 then
    Filtered := Filtered + High;
  Result := EnsureRange(Round(FDC.Process((Direct + Filtered) * Volume + DAC) * 26000), -32768, 32767);
end;

end.

