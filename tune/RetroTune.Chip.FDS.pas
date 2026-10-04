unit RetroTune.Chip.FDS;

interface

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
    FOutput: Double;
    procedure ResetEnvelope(var Envelope: TFdsEnvelope);
    procedure WriteEnvelope(var Envelope: TFdsEnvelope; Value: Byte);
    procedure TickEnvelope(var Envelope: TFdsEnvelope);
    procedure UpdateModulation;
    procedure SetModCounter(Value: Integer);
  public
    constructor Create;
    procedure Reset;
    procedure Write(Address: Word; Value: Byte);
    function Read(Address: Word): Byte;
    procedure Clock;
    property Output: Double read FOutput;
  end;

implementation

uses
  System.Math;

constructor TFdsAudio.Create;
begin
  inherited;
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
  Product, Value, Remainder: Integer;
begin
  Product := FModCounter * FModVolume.Gain;
  // Signed shifts with the FDS's asymmetric rounding and 8-bit wrap.
  Value := Floor(Product / 16);
  if ((Product and 15) <> 0) and ((Value and $80) = 0) then
    if FModCounter < 0 then
      Dec(Value)
    else
      Inc(Value, 2);
  if Value >= 192 then
    Dec(Value, 256)
  else if Value < -64 then
    Inc(Value, 256);
  Product := FWaveFrequency * Value;
  Remainder := Product and 63;
  FModOutput := Floor(Product / 64);
  if Remainder >= 32 then
    Inc(FModOutput);
end;

procedure TFdsAudio.Write(Address: Word; Value: Byte);
begin
  if Address = $4023 then
  begin
    FEnabled := (Value and 2) <> 0;
    Exit;
  end;
  if not FEnabled then
    Exit;
  if (Address >= $4040) and (Address <= $407F) then
  begin
    if FWriteWave then
      FWave[Address and $3F] := Value and $3F;
    Exit;
  end;
  case Address of
    $4080:
      WriteEnvelope(FVolume, Value);
    $4082:
      FWaveFrequency := (FWaveFrequency and $F00) or Value;
    $4083:
      begin
        FWaveFrequency := (FWaveFrequency and $FF) or ((Value and $0F) shl 8);
        FHaltWave := (Value and $80) <> 0;
        FHaltEnvelopes := (Value and $40) <> 0;
        if FHaltWave then
          FWavePosition := 0;
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
        if FHaltMod then
          FModPhase := 0;
      end;
    $4088:
      if FHaltMod then
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
begin
  Result := 0;
  if not FEnabled then
    Exit;
  if (Address >= $4040) and (Address <= $407F) then
    if FWriteWave then
      Result := FWave[Address and 63]
    else
      Result := FWave[FWavePosition];
  case Address of
    $4090:
      Result := $40 or FVolume.Gain;
    $4092:
      Result := $40 or FModVolume.Gain;
  end;
end;

procedure TFdsAudio.Clock;
const
  ModSteps: array[0..7] of Integer = (0, 1, 2, 4, 0, -4, -2, -1);
  MasterLevels: array[0..3] of Double = (1.0, 2 / 3, 17 / 36, 14 / 36);
var
  Step, Frequency: Integer;
begin
  if not FEnabled then
  begin
    FOutput := 0;
    Exit;
  end;
  if not FHaltWave and not FHaltEnvelopes then
  begin
    TickEnvelope(FVolume);
    TickEnvelope(FModVolume);
  end;
  if not FHaltMod then
  begin
    Inc(FModPhase, FModFrequency);
    if FModPhase >= $10000 then
    begin
      FModPhase := FModPhase and $FFFF;
      Step := FModTable[FModPosition];
      if Step = 4 then
        FModCounter := 0
      else
        SetModCounter(FModCounter + ModSteps[Step]);
      FModPosition := (FModPosition + 1) and 63;
    end;
  end;
  UpdateModulation;
  if not FWriteWave then
    FOutput := FWave[FWavePosition] * Min(FVolume.Gain, 32) *
      MasterLevels[FMasterVolume] / (63 * 32) * 0.30;
  Frequency := FWaveFrequency + FModOutput;
  if not FHaltWave and (Frequency > 0) then
  begin
    Inc(FWavePhase, Frequency);
    while FWavePhase >= $10000 do
    begin
      Dec(FWavePhase, $10000);
      FWavePosition := (FWavePosition + 1) and 63;
    end;
  end;
end;

end.

