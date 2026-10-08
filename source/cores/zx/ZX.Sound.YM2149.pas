unit ZX.Sound.YM2149;

interface

uses
  System.SysUtils, Core.AudioFilter;

type
  TYM2149StateField = procedure(var Value; Size: Integer) of object;

  TYM2149NativeTick = procedure(Rate: Double) of object;

  TYM2149Levels = array[0..2] of Byte;

  TYM2149PortRead = function(Port: Integer): Byte of object;

  TYM2149PortWrite = procedure(Port: Integer; Value: Byte) of object;
  // Independent of CPU/memory. Clock is the input clock; SEL low divides it by 2.

  TYM2149F = class
  private
    FRegisters: array[0..15] of Byte;
    FAddress: Byte;
    FAYModel: Boolean;
    FDACOverride: array[0..2] of Double;
    FOnNativeTick: TYM2149NativeTick;
    FClock, FSampleRate, FDivider: Integer;
    FToneCounter: array[0..2] of Integer;
    FTone: array[0..2] of Boolean;
    FNoiseCounter, FEnvelopeCounter, FEnvelope, FSegment: Integer;
    FNoise: Cardinal;
    FPan: array[0..2, 0..1] of Double;
    FPhase: Double;
    FFilter: array[0..1] of TPCMLowPass;
    FDC: array[0..1] of TPCMDCBlocker;
    FFiltered: array[0..1] of Double;
    FOnPortRead: TYM2149PortRead;
    FOnPortWrite: TYM2149PortWrite;
    procedure ResetEnvelopeSegment;
    procedure StepEnvelope;
  public
    constructor Create(Clock: Integer = 1773400; SampleRate: Integer = 44100; SelectPinHigh: Boolean = True);
    procedure Reset;
    procedure SetClock(Value: Integer);
    procedure RetriggerTone(Channel: Integer);
    procedure WriteAddress(Value: Byte);
    procedure WriteData(Value: Byte);
    function ReadData: Byte;
    procedure WriteRegister(RegisterID, Value: Byte);
    function ReadRegister(RegisterID: Byte): Byte;
    // Negative amplitude releases the sample DAC override.
    procedure SetDACOverride(Channel: Integer; Amplitude: Double);
    procedure SetPan(Channel: Integer; Left, Right: Double);
    procedure Step(out Levels: TYM2149Levels);
    procedure GenerateNative(out Left, Right: Double);
    procedure Sample(out Left, Right: SmallInt);
    procedure Render(var PCM: array of SmallInt; Frames: Integer);
    procedure SerializeState(const Field: TYM2149StateField);
    property AYModel: Boolean read FAYModel write FAYModel;
    property OnNativeTick: TYM2149NativeTick read FOnNativeTick write FOnNativeTick;
    property Clock: Integer read FClock;
    property SampleRate: Integer read FSampleRate;
    property OnPortRead: TYM2149PortRead read FOnPortRead write FOnPortRead;
    property OnPortWrite: TYM2149PortWrite read FOnPortWrite write FOnPortWrite;
  end;

implementation

uses
  System.Math;

const
  RegisterMasks: array[0..15] of Byte = ($FF, 15, $FF, 15, $FF, 15, 31, $FF, 31, 31, 31, $FF, $FF, 15, $FF, $FF);
  EnvelopeModes: array[0..15, 0..1] of ShortInt =
    ((-1, 0), (-1, 0), (-1, 0), (-1, 0), (1, 0), (1, 0), (1, 0), (1, 0),
    (-1, -1), (-1, 0), (-1, 1), (-1, 2), (1, 1), (1, 2), (1, -1), (1, 0));
  AYDAC: array[0..31] of Double = (0.0, 0.0,
    0.00999465934234, 0.00999465934234,
    0.0144502937362, 0.0144502937362,
    0.0210574502174, 0.0210574502174,
    0.0307011520562, 0.0307011520562,
    0.0455481803616, 0.0455481803616,
    0.0644998855573, 0.0644998855573,
    0.107362478065, 0.107362478065,
    0.126588845655, 0.126588845655,
    0.20498970016, 0.20498970016,
    0.292210269322, 0.292210269322,
    0.372838941024, 0.372838941024,
    0.492530708782, 0.492530708782,
    0.635324635691, 0.635324635691,
    0.805584802014, 0.805584802014,
    1.0, 1.0);
  YMDAC: array[0..31] of Double = (
    0, 0, 0.00465400167849, 0.00772106507973, 0.0109559777218, 0.0139620050355,
    0.0169985503929, 0.0200198367285, 0.024368657969, 0.029694056611,
    0.0350652323186, 0.0403906309606, 0.0485389486534, 0.0583352407111,
    0.0680552376593, 0.0777752346075, 0.0925154497597, 0.111085679408,
    0.129747463188, 0.148485542077, 0.17666895552, 0.211551079576,
    0.246387426566, 0.281101701381, 0.333730067903, 0.400427252613,
    0.467383840696, 0.53443198291, 0.635172045472, 0.75800717174, 0.879926756695, 1);

constructor TYM2149F.Create(Clock, SampleRate: Integer; SelectPinHigh: Boolean);
begin
  inherited Create;
  if (Clock < 100000) or (Clock > 8000000) then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 clock');
  if (SampleRate < 8000) or (SampleRate > 192000) then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 sample rate');
  FClock := Clock;
  FSampleRate := SampleRate;
  FDivider := 8;
  if not SelectPinHigh then
    FDivider := 16;
  SetPan(0, 1, 0);
  SetPan(1, 0.7071067811865475, 0.7071067811865475);
  SetPan(2, 0, 1);
  for var J := 0 to 1 do
  begin
    FFilter[J].Configure(Clock / FDivider, Min(14000, SampleRate * 0.4));
    FDC[J].Configure(SampleRate, 20);
  end;
  Reset;
end;

procedure TYM2149F.SetClock(Value: Integer);
begin
  if (Value < 100000) or (Value > 8000000) then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 clock');
  FClock := Value;
  for var J := 0 to 1 do
    FFilter[J].Configure(FClock / FDivider, Min(14000, FSampleRate * 0.4));
end;

procedure TYM2149F.RetriggerTone(Channel: Integer);
begin
  if (Channel < 0) or (Channel > 2) then
    raise EArgumentOutOfRangeException.Create('YM2149 tone channel');
  // Fast Tracker's phase effect forces the next native tone transition.
  FToneCounter[Channel] := $FFFE;
end;

procedure TYM2149F.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FToneCounter, SizeOf(FToneCounter), 0);
  FillChar(FTone, SizeOf(FTone), 0);
  for var C := 0 to 2 do
    FDACOverride[C] := -1;
  FAddress := 0;
  FNoise := 1;
  FNoiseCounter := 0;
  FEnvelopeCounter := 0;
  FSegment := 0;
  ResetEnvelopeSegment;
  FPhase := 0;
  for var J := 0 to 1 do
  begin
    FFilter[J].Reset;
    FDC[J].Reset;
    FFiltered[J] := 0;
  end;
end;

procedure TYM2149F.WriteAddress(Value: Byte);
begin
  FAddress := Value;
end;

procedure TYM2149F.WriteData(Value: Byte);
begin
  if FAddress < 16 then
    WriteRegister(FAddress, Value);
end;

function TYM2149F.ReadData: Byte;
begin
  if FAddress < 16 then
    Result := ReadRegister(FAddress)
  else
    Result := $FF;
end;

procedure TYM2149F.WriteRegister(RegisterID, Value: Byte);
begin
  if RegisterID > 15 then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 register');
  var Previous := FRegisters[RegisterID];
  FRegisters[RegisterID] := Value and RegisterMasks[RegisterID];
  if RegisterID = 13 then
  begin
    FEnvelopeCounter := 0;
    FSegment := 0;
    ResetEnvelopeSegment;
  end;
  if Assigned(FOnPortWrite) then
    if RegisterID >= 14 then
    begin
      var Port := RegisterID - 14;
      if (FRegisters[7] and (64 shl Port)) <> 0 then
        FOnPortWrite(Port, Value);
    end
    else if RegisterID = 7 then
      for var Port := 0 to 1 do
        if ((Previous and (64 shl Port)) = 0) and ((Value and (64 shl Port)) <> 0) then
          FOnPortWrite(Port, FRegisters[14 + Port]);
end;

function TYM2149F.ReadRegister(RegisterID: Byte): Byte;
begin
  if RegisterID > 15 then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 register');
  if (RegisterID >= 14) and ((FRegisters[7] and (64 shl (RegisterID - 14))) = 0) then
  begin
    if Assigned(FOnPortRead) then
      Result := FOnPortRead(RegisterID - 14)
    else
      Result := $FF;
  end
  else
    Result := FRegisters[RegisterID];
end;

procedure TYM2149F.SetDACOverride(Channel: Integer; Amplitude: Double);
begin
  if (Channel < 0) or (Channel > 2) or IsNan(Amplitude) or IsInfinite(Amplitude) or
    (Amplitude < -1) or (Amplitude > 1) then
    raise EArgumentOutOfRangeException.Create('Invalid AY/YM sample DAC');
  FDACOverride[Channel] := Amplitude;
end;

procedure TYM2149F.SetPan(Channel: Integer; Left, Right: Double);
begin
  if (Channel < 0) or (Channel > 2) or IsNan(Left) or IsNan(Right) or IsInfinite(Left) or IsInfinite(Right) or
    (Left < 0) or (Left > 1) or (Right < 0) or (Right > 1) then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 pan');
  FPan[Channel, 0] := Left;
  FPan[Channel, 1] := Right;
end;

procedure TYM2149F.ResetEnvelopeSegment;
begin
  var Mode := EnvelopeModes[FRegisters[13], FSegment];
  if (Mode = -1) or (Mode = 2) then
    FEnvelope := 31
  else
    FEnvelope := 0;
end;

procedure TYM2149F.StepEnvelope;
begin
  var Mode := EnvelopeModes[FRegisters[13], FSegment];
  if (Mode = -1) or (Mode = 1) then
  begin
    Inc(FEnvelope, Mode);
    if (FEnvelope < 0) or (FEnvelope > 31) then
    begin
      FSegment := FSegment xor 1;
      ResetEnvelopeSegment;
    end;
  end;
end;

procedure TYM2149F.Step(out Levels: TYM2149Levels);
begin
  Inc(FNoiseCounter);
  if FNoiseCounter >= Max(1, Integer(FRegisters[6])) * 2 then
  begin
    FNoiseCounter := 0;
    var Feedback := (FNoise xor (FNoise shr 3)) and 1;
    FNoise := (FNoise shr 1) or (Feedback shl 16);
  end;
  Inc(FEnvelopeCounter);
  var EnvelopePeriod := Max(1, Integer(FRegisters[11]) + Integer(FRegisters[12]) * 256);
  if FEnvelopeCounter >= EnvelopePeriod then
  begin
    FEnvelopeCounter := 0;
    StepEnvelope;
  end;
  for var J := 0 to 2 do
  begin
    Inc(FToneCounter[J]);
    var Period := Max(1, Integer(FRegisters[J * 2]) + Integer(FRegisters[J * 2 + 1]) * 256);
    if FToneCounter[J] >= Period then
    begin
      FToneCounter[J] := 0;
      FTone[J] := not FTone[J];
    end;
    Levels[J] := 0;
    if (FTone[J] or ((FRegisters[7] and (1 shl J)) <> 0)) and
      (((FNoise and 1) <> 0) or ((FRegisters[7] and (8 shl J)) <> 0)) then
      if (FRegisters[8 + J] and 16) <> 0 then
        Levels[J] := FEnvelope
      else
        Levels[J] := (FRegisters[8 + J] and 15) * 2 + 1;
  end;
end;

procedure TYM2149F.GenerateNative(out Left, Right: Double);
begin
  var Levels: TYM2149Levels;
  if Assigned(FOnNativeTick) then
    FOnNativeTick(FClock / Double(FDivider));
  Step(Levels);
  Left := 0;
  Right := 0;
  for var J := 0 to 2 do
  begin
    var Amplitude := YMDAC[Levels[J]];
    if FAYModel then
      Amplitude := AYDAC[Levels[J]];
    if FDACOverride[J] >= 0 then
      Amplitude := FDACOverride[J];
    Left := Left + Amplitude * FPan[J, 0] / 3;
    Right := Right + Amplitude * FPan[J, 1] / 3;
  end;
end;

procedure TYM2149F.Sample(out Left, Right: SmallInt);
begin
  FPhase := FPhase + FClock / (Double(FDivider) * FSampleRate);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    var L, R: Double;
    GenerateNative(L, R);
    FFiltered[0] := FFilter[0].Process(L);
    FFiltered[1] := FFilter[1].Process(R);
  end;
  Left := EnsureRange(Round(FDC[0].Process(FFiltered[0]) * 32767), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(FFiltered[1]) * 32767), -32768, 32767);
end;

procedure TYM2149F.Render(var PCM: array of SmallInt; Frames: Integer);
begin
  if (Frames < 0) or (Frames > Length(PCM) div 2) then
    raise EArgumentOutOfRangeException.Create('Invalid YM2149 buffer');
  for var J := 0 to Frames - 1 do
    Sample(PCM[J * 2], PCM[J * 2 + 1]);
end;

procedure TYM2149F.SerializeState(const Field: TYM2149StateField);
begin
  Field(FRegisters, SizeOf(FRegisters));
  Field(FAddress, SizeOf(FAddress));
  Field(FAYModel, SizeOf(FAYModel));
  Field(FDACOverride, SizeOf(FDACOverride));
  Field(FClock, SizeOf(FClock));
  Field(FSampleRate, SizeOf(FSampleRate));
  Field(FDivider, SizeOf(FDivider));
  Field(FToneCounter, SizeOf(FToneCounter));
  Field(FTone, SizeOf(FTone));
  Field(FNoiseCounter, SizeOf(FNoiseCounter));
  Field(FEnvelopeCounter, SizeOf(FEnvelopeCounter));
  Field(FEnvelope, SizeOf(FEnvelope));
  Field(FSegment, SizeOf(FSegment));
  Field(FNoise, SizeOf(FNoise));
  Field(FPan, SizeOf(FPan));
  Field(FPhase, SizeOf(FPhase));
  Field(FFilter, SizeOf(FFilter));
  Field(FDC, SizeOf(FDC));
  Field(FFiltered, SizeOf(FFiltered));
end;

end.

