unit PCE.Sound.HuC6280;

interface

uses
  Core.AudioFilter;

type
  TPCESoundVoice = record
    Wave: array[0..31] of Byte;
    Position, Period, Control, Balance, Noise, DAC: Integer;
    Counter, NoiseCounter: Double;
    LFSR: Cardinal;
  end;

  THuC6280PSG = class
  private
    FVoices: array[0..5] of TPCESoundVoice;
    FLatch, FBalance, FLFOFrequency, FLFOControl: Integer;
    FDC: array[0..1] of TPCMDCBlocker;
  public
    constructor Create;
    procedure Reset;
    procedure WriteRegister(Index, Value: Byte);
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

constructor THuC6280PSG.Create;
begin
  inherited;
  for var I := 0 to 1 do
    FDC[I].Configure(44100, 20);
  Reset;
end;

procedure THuC6280PSG.Reset;
begin
  FillChar(FVoices, SizeOf(FVoices), 0);
  FLatch := 0;
  FBalance := $FF;
  FLFOFrequency := 0;
  FLFOControl := 0;
  for var I := 0 to 5 do
  begin
    FVoices[I].Control := $40;
    FVoices[I].Balance := $FF;
    FVoices[I].LFSR := $200C3;
  end;
  for var I := 0 to 1 do
    FDC[I].Reset;
end;

procedure THuC6280PSG.WriteRegister(Index, Value: Byte);
begin
  case Index of
    0:
      FLatch := Value and 7;
    1:
      FBalance := Value;
    8:
      FLFOFrequency := Value;
    9:
      begin
        FLFOControl := Value;
        if Value and $80 <> 0 then
        begin
          FVoices[1].Position := 0;
          FVoices[1].Counter := 0;
        end;
      end;
  end;
  if FLatch >= 6 then
    Exit;
  case Index of
    2:
      FVoices[FLatch].Period := (FVoices[FLatch].Period and $F00) or Value;
    3:
      FVoices[FLatch].Period := (FVoices[FLatch].Period and 255) or ((Value and 15) shl 8);
    4:
      begin
        if (FVoices[FLatch].Control and $40 <> 0) and (Value and $40 = 0) then
          FVoices[FLatch].Position := 0;
        FVoices[FLatch].Control := Value;
      end;
    5:
      FVoices[FLatch].Balance := Value;
    6:
      begin
        if FVoices[FLatch].Control and $40 = 0 then
        begin
          FVoices[FLatch].Wave[FVoices[FLatch].Position] := Value and 31;
          FVoices[FLatch].Position := (FVoices[FLatch].Position + 1) and 31;
        end
        else if FVoices[FLatch].Control and $80 <> 0 then
          FVoices[FLatch].DAC := Value and 31;
      end;
    7:
      FVoices[FLatch].Noise := Value;
  end;
end;

procedure THuC6280PSG.Sample(out Left, Right: SmallInt);
const
  Depth: array[0..3] of Integer = (0, 1, 16, 256);
begin
  var SumL := 0.0;
  var SumR := 0.0;
  var LFO := (FLFOControl and 3 <> 0) and (FLFOControl and $80 = 0);
  for var C := 5 downto 0 do
  begin
    var Period := FVoices[C].Period;
    if (C = 0) and LFO then
      Period := (Period + (Integer(FVoices[1].Wave[FVoices[1].Position]) - 16) * Depth[FLFOControl and 3]) and $FFF;
    if Period = 0 then
      Period := 4096;
    if (C = 1) and LFO then
      Period := Period * Max(1, FLFOFrequency);
    if FVoices[C].Control and $40 = 0 then
    begin
      FVoices[C].Counter := FVoices[C].Counter + 3579545.0 / (44100 * Period);
      FVoices[C].Position := (FVoices[C].Position + Trunc(FVoices[C].Counter)) and 31;
      FVoices[C].Counter := Frac(FVoices[C].Counter);
    end;
    var Value := Integer(FVoices[C].Wave[FVoices[C].Position]);
    if FVoices[C].Control and $40 <> 0 then
      Value := FVoices[C].DAC;
    if (C >= 4) and (FVoices[C].Noise and $80 <> 0) then
    begin
      var NP := ((FVoices[C].Noise xor 255) and 31) * 64;
      if NP = 0 then
        NP := 32;
      FVoices[C].NoiseCounter := FVoices[C].NoiseCounter + 3579545.0 / (44100 * NP);
      while FVoices[C].NoiseCounter >= 1 do
      begin
        FVoices[C].NoiseCounter := FVoices[C].NoiseCounter - 1;
        FVoices[C].LFSR := (FVoices[C].LFSR shr 1) xor ($30061 * (FVoices[C].LFSR and 1));
      end;
      Value := Integer(FVoices[C].LFSR and 1) * 31;
    end;
    if (FVoices[C].Control and $80 = 0) or ((C = 1) and LFO) then
      Continue;
    var V := FVoices[C].Control and 31;
    var VL := Max(0, V + ((FVoices[C].Balance shr 4) and 15) * 2 + ((FBalance shr 4) and 15) * 2 - 60);
    var VR := Max(0, V + (FVoices[C].Balance and 15) * 2 + (FBalance and 15) * 2 - 60);
    if VL > 0 then
      SumL := SumL + (Value - 16) * Power(2, (VL - 31) / 4.0) * 320;
    if VR > 0 then
      SumR := SumR + (Value - 16) * Power(2, (VR - 31) / 4.0) * 320;
  end;
  Left := EnsureRange(Round(FDC[0].Process(SumL)), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(SumR)), -32768, 32767);
end;

end.

