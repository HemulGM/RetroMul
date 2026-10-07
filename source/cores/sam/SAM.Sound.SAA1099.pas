unit SAM.Sound.SAA1099;

interface

uses
  System.SysUtils, Core.AudioFilter;

type
  TSAA1099 = class
  private
    FRegisters: array[0..31] of Byte;
    FAddress: Byte;
    FClock, FSampleRate: Integer;
    FPhase: Double;
    FToneCounter: array[0..5] of Integer;
    FTone: array[0..5] of Boolean;
    FNoiseCounter: array[0..1] of Integer;
    FNoise: array[0..1] of Cardinal;
    FEnvelope: array[0..1] of Integer;
    FEnvControl, FEnvPending: array[0..1] of Byte;
    FEnvEnded, FEnvHasPending: array[0..1] of Boolean;
    FFilter: array[0..1] of TPCMLowPass;
    FDC: array[0..1] of TPCMDCBlocker;
    FFiltered: array[0..1] of Double;
    function HalfPeriod(Channel: Integer): Integer;
    procedure EnvelopeTick(Group: Integer);
    function EnvelopeLevel(Group: Integer; Right: Boolean): Integer;
    procedure NativeStep;
  public
    constructor Create(Clock: Integer = 8000000; SampleRate: Integer = 44100);
    procedure Reset;
    procedure WriteAddress(Value: Byte);
    procedure WriteData(Value: Byte);
    procedure WriteRegister(Index, Value: Byte);
    function ReadRegister(Index: Byte): Byte;
    procedure GetEnvelopeLevels(Group: Integer; out Left, Right: Integer);
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

constructor TSAA1099.Create(Clock, SampleRate: Integer);
begin
  inherited Create;
  if (Clock < 1000000) or (Clock > 16000000) or (SampleRate < 8000) or (SampleRate > 192000) then
    raise EArgumentOutOfRangeException.Create('SAA1099 clock/rate');
  FClock := Clock;
  FSampleRate := SampleRate;
  for var I := 0 to 1 do
  begin
    FFilter[I].Configure(Clock / 128.0, Min(14000, SampleRate * 0.4));
    FDC[I].Configure(SampleRate, 20);
  end;
  Reset;
end;

procedure TSAA1099.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FToneCounter, SizeOf(FToneCounter), 0);
  FillChar(FTone, SizeOf(FTone), 0);
  FillChar(FNoiseCounter, SizeOf(FNoiseCounter), 0);
  FAddress := 0;
  FPhase := 0;
  for var I := 0 to 1 do
  begin
    FNoise[I] := $3FFFF;
    FEnvelope[I] := 0;
    FEnvControl[I] := 0;
    FEnvPending[I] := 0;
    FEnvEnded[I] := True;
    FEnvHasPending[I] := False;
    FFiltered[I] := 0;
    FFilter[I].Reset;
    FDC[I].Reset;
  end;
end;

function TSAA1099.HalfPeriod(Channel: Integer): Integer;
begin
  var Octave := (FRegisters[$10 + Channel div 2] shr ((Channel mod 2) * 4)) and 7;
  Result := (511 - Integer(FRegisters[8 + Channel])) shl (8 - Octave);
end;

procedure TSAA1099.EnvelopeTick(Group: Integer);
begin
  if (FRegisters[$18 + Group] and $80 = 0) or FEnvEnded[Group] then
    Exit;
  var Step := 1;
  if FEnvControl[Group] and $10 <> 0 then
    Step := 2;
  Inc(FEnvelope[Group], Step);
  var Mode := (FEnvControl[Group] shr 1) and 7;
  var Length := 16;
  if Mode in [4, 5] then
    Length := 32;
  if FEnvelope[Group] >= Length then
  begin
    if Mode in [1, 3, 5, 7] then
      FEnvelope[Group] := FEnvelope[Group] - Length
    else
      FEnvEnded[Group] := True;
    if FEnvHasPending[Group] then
    begin
      FEnvControl[Group] := FEnvPending[Group];
      FEnvHasPending[Group] := False;
      FEnvelope[Group] := 0;
      FEnvEnded[Group] := False;
    end;
  end;
end;

function TSAA1099.EnvelopeLevel(Group: Integer; Right: Boolean): Integer;
begin
  var Control := FEnvControl[Group];
  if FRegisters[$18 + Group] and $80 = 0 then
    Exit(16);
  var Step := FEnvelope[Group];
  var Mode := (Control shr 1) and 7;
  Result := 0;
  case Mode of
    1:
      Result := 15;
    2:
      if Step < 16 then
        Result := 15 - Step;
    3:
      Result := 15 - (Step and 15);
    4:
      if Step < 16 then
        Result := Step
      else if Step < 32 then
        Result := 31 - Step;
    5:
      if Step and 31 < 16 then
        Result := Step and 15
      else
        Result := 15 - (Step and 15);
    6:
      if Step < 16 then
        Result := Step;
    7:
      Result := Step and 15;
  end;
  if Right and (Control and 1 <> 0) then
    Result := 15 - Result;
  if Control and $10 <> 0 then
    Result := Result and 14;
end;

procedure TSAA1099.WriteAddress(Value: Byte);
begin
  FAddress := Value and 31;
  if FAddress in [$18, $19] then
    for var G := 0 to 1 do
      if FEnvControl[G] and $20 <> 0 then
        EnvelopeTick(G);
end;

procedure TSAA1099.WriteData(Value: Byte);
begin
  WriteRegister(FAddress, Value);
end;

procedure TSAA1099.WriteRegister(Index, Value: Byte);
begin
  if Index > 31 then
    raise EArgumentOutOfRangeException.Create('SAA1099 register');
  FRegisters[Index] := Value;
  if Index in [$18, $19] then
  begin
    var G := Index - $18;
    if Value and $80 = 0 then
      FEnvEnded[G] := True
    else
    begin
      var OldResolution := FEnvControl[G] and $10;
      if OldResolution <> (Value and $10) then
        if Value and $10 <> 0 then
          FEnvelope[G] := FEnvelope[G] and (not 1)
        else
          FEnvelope[G] := FEnvelope[G] or 1;
      FEnvControl[G] := (FEnvControl[G] and $EF) or (Value and $10);
      if FEnvEnded[G] then
      begin
        FEnvControl[G] := Value;
        FEnvelope[G] := 0;
        FEnvEnded[G] := False;
        FEnvHasPending[G] := False;
      end
      else
      begin
        FEnvPending[G] := Value;
        FEnvHasPending[G] := True;
      end;
    end;
  end;
  if (Index = $1C) and (Value and 2 <> 0) then
  begin
    FillChar(FToneCounter, SizeOf(FToneCounter), 0);
    FillChar(FTone, SizeOf(FTone), 0);
    FillChar(FNoiseCounter, SizeOf(FNoiseCounter), 0);
    FNoise[0] := $3FFFF;
    FNoise[1] := $3FFFF;
  end;
end;

function TSAA1099.ReadRegister(Index: Byte): Byte;
begin
  if Index > 31 then
    raise EArgumentOutOfRangeException.Create('SAA1099 register');
  Result := FRegisters[Index];
end;

procedure TSAA1099.GetEnvelopeLevels(Group: Integer; out Left, Right: Integer);
begin
  if (Group < 0) or (Group > 1) then
    raise EArgumentOutOfRangeException.Create('SAA1099 envelope group');
  Left := EnvelopeLevel(Group, False);
  Right := EnvelopeLevel(Group, True);
end;

procedure TSAA1099.NativeStep;
var
  L, R: Double;
begin
  L := 0;
  R := 0;
  if FRegisters[$1C] and 2 = 0 then
  begin
    for var C := 0 to 5 do
    begin
      Inc(FToneCounter[C], 128);
      var Period := HalfPeriod(C);
      while FToneCounter[C] >= Period do
      begin
        Dec(FToneCounter[C], Period);
        FTone[C] := not FTone[C];
        if (C mod 3 = 1) and (FEnvControl[C div 3] and $20 = 0) then
          EnvelopeTick(C div 3);
      end;
    end;
    for var G := 0 to 1 do
    begin
      var Mode := (FRegisters[$16] shr (G * 4)) and 3;
      var Period := 256 shl Mode;
      if Mode = 3 then
        Period := HalfPeriod(G * 3);
      Inc(FNoiseCounter[G], 128);
      while FNoiseCounter[G] >= Period do
      begin
        Dec(FNoiseCounter[G], Period);
        var Feedback := ((FNoise[G] shr 17) xor (FNoise[G] shr 10)) and 1;
        FNoise[G] := ((FNoise[G] shl 1) or Feedback) and $3FFFF;
      end;
    end;
    for var C := 0 to 5 do
    begin
      var ToneOn := (FRegisters[$14] and (1 shl C)) <> 0;
      var NoiseOn := (FRegisters[$15] and (1 shl C)) <> 0;
      var Level := 0.0;
      if ToneOn then
      begin
        if FTone[C] then
        begin
          Level := 1;
          if NoiseOn and (FNoise[C div 3] and 1 <> 0) then
            Level := 0.5;
        end;
      end
      else if NoiseOn and (FNoise[C div 3] and 1 <> 0) then
        Level := 1;
      var EL := 16;
      var ER := 16;
      if C mod 3 = 2 then
      begin
        EL := EnvelopeLevel(C div 3, False);
        ER := EnvelopeLevel(C div 3, True);
      end;
      var AL := FRegisters[C] and 15;
      var AR := FRegisters[C] shr 4;
      if (C mod 3 = 2) and (FRegisters[$18 + C div 3] and $80 <> 0) then
      begin
        // Envelope and amplitude pulse-density patterns combine in hardware.
        // The envelope path inverts the tone/noise gate and drops amplitude bit 0.
        L := L + (1 - Level) * (((AL div 2) * EL + 1) div 2) / 4;
        R := R + (1 - Level) * (((AR div 2) * ER + 1) div 2) / 4;
      end
      else
      begin
        L := L + Level * AL;
        R := R + Level * AR;
      end;
    end;
  end;
  if FRegisters[$1C] and 1 = 0 then
  begin
    L := 0;
    R := 0;
  end;
  FFiltered[0] := FFilter[0].Process(L / 90);
  FFiltered[1] := FFilter[1].Process(R / 90);
end;

procedure TSAA1099.Sample(out Left, Right: SmallInt);
begin
  FPhase := FPhase + FClock / (128.0 * FSampleRate);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    NativeStep;
  end;
  Left := EnsureRange(Round(FDC[0].Process(FFiltered[0]) * 32767), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(FFiltered[1]) * 32767), -32768, 32767);
end;

end.

