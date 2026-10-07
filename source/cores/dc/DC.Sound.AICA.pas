unit DC.Sound.AICA;

interface

uses
  System.SysUtils, Core.AudioFilter, DC.Sound.AICA.DSP;

type
  TAICAWrite = procedure(Address: Cardinal; Value: Byte) of object;

  TAICARead = function(Address: Cardinal): Byte of object;

  TAICAVoice = record
    Active, LoopEnded: Boolean;
    Phase, ADPosition, ADSignal, ADStep, LoopSignal, LoopStep: Integer;
    EGVolume, EGState, FilterState, FilterVolume: Integer;
    Rates: array[0..3] of Integer;
    LFOPhase: Double;
    ADCurrent, ADNext: Integer;
    Filter1, Filter2: Double;
  end;

  TAICA = class
  private
    class var
      FAttack, FDecay: array[0..63] of Integer;
    class var
      FEnvelope: array[0..1023] of Double;
  private
    FRead: TAICARead;
    FDSP: TAICADSP;
    FRegisters: array[0..$7FFF] of Byte;
    FVoices: array[0..63] of TAICAVoice;
    FTimers: array[0..2] of Integer;
    FIRQ: Integer;
    FNoise: Cardinal;
    FDC: array[0..1] of TPCMDCBlocker;
    function WordAt(Address: Integer): Integer;
    procedure PutWord(Address, Value: Integer);
    procedure KeyOn(Channel: Integer);
    procedure Envelope(Channel: Integer);
    function Voice(Channel: Integer): Double;
    function PCM(Address, Kind, Position: Integer): Integer;
    procedure DecodeADPCM(Channel, Position: Integer);
    function Gain(Level, Pan, Side: Integer): Double;
    procedure Timers;
  public
    class constructor Create;
    constructor Create(Read: TAICARead; Write: TAICAWrite);
    destructor Destroy; override;
    procedure Reset;
    function ReadRegister(Address: Integer): Byte;
    procedure WriteRegister(Address: Integer; Value: Byte);
    procedure Sample(out Left, Right: SmallInt);
    function FIQ: Boolean;
  end;

implementation

uses
  System.Math;

const
  AttackTimes: array[0..63] of Double = (100000, 100000, 8100.0, 6900.0, 6000.0, 4800.0, 4000.0, 3400.0, 3000.0, 2400.0, 2000.0, 1700.0, 1500.0,
    1200.0, 1000.0, 860.0, 760.0, 600.0, 500.0, 430.0, 380.0, 300.0, 250.0, 220.0, 190.0, 150.0, 130.0, 110.0, 95.0,
    76.0, 63.0, 55.0, 47.0, 38.0, 31.0, 27.0, 24.0, 19.0, 15.0, 13.0, 12.0, 9.4, 7.9, 6.8, 6.0, 4.7, 3.8, 3.4, 3.0, 2.4,
    2.0, 1.8, 1.6, 1.3, 1.1, 0.93, 0.85, 0.65, 0.53, 0.44, 0.40, 0.35, 0.0, 0.0);
  DecayTimes: array[0..63] of Double = (100000, 100000, 118200.0, 101300.0, 88600.0, 70900.0, 59100.0, 50700.0, 44300.0, 35500.0, 29600.0, 25300.0, 22200.0, 17700.0,
    14800.0, 12700.0, 11100.0, 8900.0, 7400.0, 6300.0, 5500.0, 4400.0, 3700.0, 3200.0, 2800.0, 2200.0, 1800.0, 1600.0, 1400.0, 1100.0,
    920.0, 790.0, 690.0, 550.0, 460.0, 390.0, 340.0, 270.0, 230.0, 200.0, 170.0, 140.0, 110.0, 98.0, 85.0, 68.0, 57.0, 49.0, 43.0, 34.0,
    28.0, 25.0, 22.0, 18.0, 14.0, 12.0, 11.0, 8.5, 7.1, 6.1, 5.4, 4.3, 3.6, 3.1);
  LFOFrequency: array[0..31] of Double = (0.17, 0.19, 0.23, 0.27, 0.34, 0.39, 0.45, 0.55, 0.68, 0.78, 0.92, 1.10, 1.39, 1.60, 1.87, 2.27,
    2.87, 3.31, 3.92, 4.79, 6.15, 7.18, 8.60, 10.8, 14.4, 17.2, 21.5, 28.7, 43.1, 57.4, 86.1, 172.3);
  PitchDepth: array[0..7] of Double = (0, 7, 13.5, 27, 55, 112, 230, 494);
  AmpDepth: array[0..7] of Double = (0, 0.4, 0.8, 1.5, 3, 6, 12, 24);
  Att: array[0..7] of Double = (0.4, 0.8, 1.5, 3, 6, 12, 24, 48);
  ADScale: array[0..7] of Integer = ($E6, $E6, $E6, $E6, $133, $199, $200, $266);

class constructor TAICA.Create;
begin
  for var I := 0 to 1023 do
    FEnvelope[I] := Power(10, 3 * (I - 1023) / (32.0 * 20));
  for var I := 2 to 63 do
  begin
    if AttackTimes[I] = 0 then
      FAttack[I] := 1024 * 65536
    else
      FAttack[I] := Trunc((1023 * 1000.0 * 65536) / (44100 * AttackTimes[I]));
    FDecay[I] := Trunc((1023 * 1000.0 * 65536) / (44100 * DecayTimes[I]));
  end;
end;

constructor TAICA.Create(Read: TAICARead; Write: TAICAWrite);
begin
  inherited Create;
  FRead := Read;
  FDSP := TAICADSP.Create(Read, Write);
  for var I := 0 to 1 do
    FDC[I].Configure(44100, 20);
  Reset;
end;

destructor TAICA.Destroy;
begin
  FDSP.Free;
  inherited;
end;

procedure TAICA.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
  FillChar(FTimers, SizeOf(FTimers), 0);
  FNoise := 1;
  FIRQ := 0;
  FDSP.Reset;
  PutWord($289C, $40);
  PutWord($28A8, $18);
  PutWord($28AC, $50);
  PutWord($28B0, 8);
  for var I := 0 to 63 do
  begin
    FVoices[I].EGState := 3;
    FVoices[I].LoopEnded := True;
  end;
  for var I := 0 to 1 do
    FDC[I].Reset;
end;

function TAICA.WordAt(Address: Integer): Integer;
begin
  Address := Address and $7FFE;
  Result := Integer(FRegisters[Address]) + Integer(FRegisters[Address + 1]) * 256;
end;

procedure TAICA.PutWord(Address, Value: Integer);
begin
  Address := Address and $7FFE;
  FRegisters[Address] := Value and 255;
  FRegisters[Address + 1] := (Value shr 8) and 255;
end;

function TAICA.ReadRegister(Address: Integer): Byte;
begin
  Address := Address and $7FFF;
  if Address >= $4000 then
    Exit(FDSP.ReadRegister(Address));
  var Base := Address and $7FFE;
  var Value := WordAt(Base);
  var Selected := (WordAt($280C) shr 8) and 63;
  case Base of
    $2800:
      Value := $10;
    $2808:
      Value := $900;
    $2810:
      begin
        Value := ((1023 - (FVoices[Selected].EGVolume shr 16)) shr 1) or (FVoices[Selected].EGState shl 13);
        if FVoices[Selected].LoopEnded then
          Value := Value or $8000;
        if Address and 1 <> 0 then
          FVoices[Selected].LoopEnded := False;
      end;
    $2814:
      Value := FVoices[Selected].Phase shr 12;
    $2D00:
      Value := FIRQ;
  end;
  Result := (Value shr ((Address and 1) * 8)) and 255;
end;

procedure TAICA.WriteRegister(Address: Integer; Value: Byte);
begin
  Address := Address and $7FFF;
  FRegisters[Address] := Value;
  if Address >= $3000 then
    FDSP.WriteRegister(Address, Value);
  if Address < $2000 then
  begin
    var C := Address div 128;
    var Offset := Address and 127;
    if Offset = 1 then
      if WordAt(C * 128) and $8000 <> 0 then
      begin
        for var I := 0 to 63 do
          if WordAt(I * 128) and $4000 <> 0 then
          begin
            if not FVoices[I].Active or (FVoices[I].EGState = 3) then
              KeyOn(I);
          end
          else
            FVoices[I].EGState := 3;
        PutWord(C * 128, WordAt(C * 128) and $7FFF);
      end;
    if Offset in [$14, $15] then
      FVoices[C].Rates[3] := FDecay[EnsureRange((WordAt(C * 128 + $14) and 31) * 2, 0, 63)];
  end
  else
    case Address and $7FFC of
      $2804:
        begin
          FDSP.RingBase := WordAt($2804) and $FFF;
          FDSP.RingLength := 8192 shl ((WordAt($2804) shr 13) and 3);
        end;
      $2890, $2894, $2898:
        FTimers[(Address - $2890) div 4] := (WordAt(Address and $7FFC) and 255) * 256;
      $28A4:
        begin
          PutWord($28A0, WordAt($28A0) and not WordAt($28A4));
          PutWord($28A4, 0);
        end;
      $28A0:
        PutWord($28A0, WordAt($28A0) or (WordAt($28A0) and $20));
      $2D04:
        if Value and 1 <> 0 then
          FIRQ := 0;
    end;
end;

procedure TAICA.KeyOn(Channel: Integer);
begin
  var Base := Channel * 128;
  var V := Default(TAICAVoice);
  V.Active := True;
  V.ADStep := $7F;
  V.LoopStep := $7F;
  V.EGVolume := $17F * 65536;
  V.FilterVolume := WordAt(Base + $2C) and $1FFF;
  var Pitch := WordAt(Base + $18);
  var Oct := ((Pitch shr 11) and 15) xor 8;
  Dec(Oct, 8);
  var KRS := (WordAt(Base + $14) shr 10) and 15;
  var Rate := 0;
  if KRS <> 15 then
    Rate := Oct + 2 * KRS + ((Pitch shr 9) and 1);
  var Rates: array[0..3] of Integer;
  var E1 := WordAt(Base + $10);
  Rates[0] := E1 and 31;
  Rates[1] := (E1 shr 6) and 31;
  Rates[2] := (E1 shr 11) and 31;
  Rates[3] := WordAt(Base + $14) and 31;
  for var I := 0 to 3 do
  begin
    var R := EnsureRange(Rate + Rates[I] * 2, 0, 63);
    if I = 0 then
      V.Rates[I] := FAttack[R]
    else
      V.Rates[I] := FDecay[R];
  end;
  FVoices[Channel] := V;
end;

procedure TAICA.Envelope(Channel: Integer);
begin
  var V := FVoices[Channel];
  var Base := Channel * 128;
  if V.EGState = 0 then
  begin
    V.EGVolume := Min(1023 * 65536, V.EGVolume + V.Rates[0]);
    if V.EGVolume >= 1023 * 65536 then
      if (WordAt(Base + $14) and $4000 = 0) and (V.Rates[1] <> 0) then
        V.EGState := 1;
  end
  else
  begin
    V.EGVolume := Max(0, V.EGVolume - V.Rates[V.EGState]);
    if (V.EGState = 1) and (V.EGVolume shr 21 <= 31 - ((WordAt(Base + $14) shr 5) and 31)) then
      V.EGState := 2;
    if (V.EGState = 3) and (V.EGVolume = 0) then
    begin
      V.Active := False;
      V.LoopEnded := True;
    end;
  end;
  var FRate: Integer;
  var E := WordAt(Base + $40);
  var E2 := WordAt(Base + $44);
  case V.FilterState of
    0:
      FRate := (E shr 8) and 31;
    1:
      FRate := E and 31;
    2:
      FRate := (E2 shr 8) and 31;
  else
    FRate := E2 and 31;
  end;
  var Target := WordAt(Base + $30 + V.FilterState * 4) and $1FFF;
  var Delta := Max(0, FDecay[Min(63, FRate * 2)] shr 16);
  if V.FilterVolume < Target then
    V.FilterVolume := Min(Target, V.FilterVolume + Delta)
  else if V.FilterVolume > Target then
    V.FilterVolume := Max(Target, V.FilterVolume - Delta)
  else if V.FilterState < 3 then
    Inc(V.FilterState);
  FVoices[Channel] := V;
end;

function TAICA.PCM(Address, Kind, Position: Integer): Integer;
begin
  if Kind = 0 then
  begin
    var Offset := (Address + Position * 2) and $7FFFFF;
    Result := Integer(FRead(Offset)) + Integer(FRead((Offset + 1) and $7FFFFF)) * 256;
    if Result >= 32768 then
      Dec(Result, 65536);
  end
  else
  begin
    Result := FRead((Address + Position) and $7FFFFF);
    if Result >= 128 then
      Dec(Result, 256);
    Result := Result * 256;
  end;
end;

procedure TAICA.DecodeADPCM(Channel, Position: Integer);
begin
  var Base := Channel * 128;
  var Start := ((WordAt(Base) and 127) shl 16) or WordAt(Base + 4);
  var LoopStart := WordAt(Base + 8);
  while FVoices[Channel].ADPosition < Position do
  begin
    var Index := FVoices[Channel].ADPosition;
    var N := (FRead((Start + Index div 2) and $7FFFFF) shr ((Index and 1) * 4)) and 15;
    FVoices[Channel].ADCurrent := FVoices[Channel].ADSignal;
    var Diff := Min(32767, FVoices[Channel].ADStep * ((N and 7) * 2 + 1) div 8);
    if N and 8 <> 0 then
      Diff := -Diff;
    FVoices[Channel].ADSignal := EnsureRange(FVoices[Channel].ADSignal + Diff, -32768, 32767);
    FVoices[Channel].ADStep := EnsureRange(FVoices[Channel].ADStep * ADScale[N and 7] div 256, $7F, $6000);
    Inc(FVoices[Channel].ADPosition);
    if FVoices[Channel].ADPosition = LoopStart then
    begin
      FVoices[Channel].LoopSignal := FVoices[Channel].ADSignal;
      FVoices[Channel].LoopStep := FVoices[Channel].ADStep;
    end;
  end;
  FVoices[Channel].ADNext := FVoices[Channel].ADSignal;
end;

function TAICA.Voice(Channel: Integer): Double;
begin
  var Base := Channel * 128;
  var Control := WordAt(Base);
  var Kind := (Control shr 7) and 3;
  var Start := ((Control and 127) shl 16) or WordAt(Base + 4);
  var Pos := FVoices[Channel].Phase shr 12;
  var Fraction := (FVoices[Channel].Phase and 4095) / 4096.0;
  var LE := WordAt(Base + $C);
  var LS := WordAt(Base + 8);
  if Kind = 3 then
    LE := (LE + 3) and $FFFC;
  LE := Max(1, LE);
  var Next := Pos + 1;
  if (Next >= LE) and (Control and $200 <> 0) then
    Next := LS;
  if Kind < 2 then
    Result := PCM(Start, Kind, Pos) * (1 - Fraction) + PCM(Start, Kind, Next) * Fraction
  else
  begin
    DecodeADPCM(Channel, Pos + 1);
    Result := FVoices[Channel].ADCurrent * (1 - Fraction) + FVoices[Channel].ADNext * Fraction;
  end;
  var LFO := WordAt(Base + $1C);
  var LF := FVoices[Channel].LFOPhase;
  var Wave: array[0..3] of Double;
  FNoise := Cardinal((UInt64(FNoise) * 1664525 + 1013904223) and $FFFFFFFF);
  Wave[0] := LF * 2 - 1;
  Wave[1] := 1;
  if LF >= 0.5 then
    Wave[1] := -1;
  Wave[2] := 1 - 4 * Abs(LF - 0.5);
  Wave[3] := (FNoise shr 16) / 32767.5 - 1;
  FVoices[Channel].LFOPhase := Frac(LF + LFOFrequency[(LFO shr 10) and 31] / 44100);
  var Pitch := WordAt(Base + $18);
  var Oct := ((Pitch shr 11) and 15) xor 8;
  Dec(Oct, 8);
  var Step: Double := (1024 + (Pitch and 1023)) * 4 * Power(2, Oct);
  if (LFO shr 5) and 7 <> 0 then
    Step := Step * Power(2, Wave[(LFO shr 8) and 3] * PitchDepth[(LFO shr 5) and 7] / 1200);
  FVoices[Channel].Phase := FVoices[Channel].Phase + Max(0, Trunc(Step));
  if (FVoices[Channel].Phase shr 12 >= LS) and (WordAt(Base + $14) and $4000 <> 0) and (FVoices[Channel].EGState = 0) then
    FVoices[Channel].EGState := 1;
  if FVoices[Channel].Phase shr 12 >= LE then
  begin
    FVoices[Channel].LoopEnded := True;
    if (Control and $200 <> 0) and (LS < LE) then
    begin
      FVoices[Channel].Phase := LS * 4096 + (FVoices[Channel].Phase - LE * 4096) mod ((LE - LS) * 4096);
      if Kind >= 2 then
      begin
        FVoices[Channel].ADPosition := LS;
        if Kind = 2 then
        begin
          FVoices[Channel].ADSignal := FVoices[Channel].LoopSignal;
          FVoices[Channel].ADStep := FVoices[Channel].LoopStep;
        end;
      end;
    end
    else
      FVoices[Channel].Active := False;
  end;
  var Attack := FVoices[Channel].EGState = 0;
  Envelope(Channel);
  if Attack then
    Result := Result * (FVoices[Channel].EGVolume / (1023.0 * 65536))
  else
    Result := Result * FEnvelope[EnsureRange(FVoices[Channel].EGVolume shr 16, 0, 1023)];
  if LFO and 7 <> 0 then
    Result := Result * Power(10, -((Wave[(LFO shr 3) and 3] + 1) / 2) * AmpDepth[LFO and 7] / 20);
  var Filter := WordAt(Base + $28);
  if Filter and $20 = 0 then
  begin
    var Cut := Min(0.95, Power(2, (FVoices[Channel].FilterVolume - 8191) / 256.0));
    FVoices[Channel].Filter1 := FVoices[Channel].Filter1 + Cut * (Result - FVoices[Channel].Filter1);
    FVoices[Channel].Filter2 := FVoices[Channel].Filter2 + Cut * (FVoices[Channel].Filter1 - FVoices[Channel].Filter2);
    Result := FVoices[Channel].Filter2;
  end;
  var TL := Filter shr 8;
  var DB := 0.0;
  for var I := 0 to 7 do
    if TL and (1 shl I) <> 0 then
      DB := DB + Att[I];
  Result := Result * Power(10, -DB / 20);
end;

function TAICA.Gain(Level, Pan, Side: Integer): Double;
begin
  Result := 0;
  if Level = 0 then
    Exit;
  Result := Power(10, (Level - 15) * 3 / 20.0);
  if ((Side = 0) and (Pan < 16)) or ((Side = 1) and (Pan >= 16)) then
  begin
    if Pan and 15 = 15 then
      Result := 0
    else
      Result := Result * Power(10, -(Pan and 15) * 3 / 20.0);
  end;
end;

procedure TAICA.Timers;
begin
  var Pending := WordAt($28A0);
  for var I := 0 to 2 do
  begin
    var Base := $2890 + I * 4;
    var Prescale := (WordAt(Base) shr 8) and 7;
    Inc(FTimers[I], 256 shr Prescale);
    if FTimers[I] >= 65536 then
    begin
      FTimers[I] := FTimers[I] and $FFFF;
      Pending := Pending or (1 shl (6 + I));
    end;
    PutWord(Base, (WordAt(Base) and $FF00) or (FTimers[I] shr 8));
  end;
  PutWord($28A0, Pending);
  Pending := Pending and WordAt($289C);
  if FIRQ = 0 then
    for var I := 10 downto 0 do
      if Pending and (1 shl I) <> 0 then
      begin
        var Bit := 1 shl Min(7, I);
        FIRQ := Ord(WordAt($28A8) and Bit <> 0) + 2 * Ord(WordAt($28AC) and Bit <> 0) + 4 * Ord(WordAt($28B0) and Bit <> 0);
        Break;
      end;
end;

function TAICA.FIQ: Boolean;
begin
  Result := FIRQ <> 0;
end;

procedure TAICA.Sample(out Left, Right: SmallInt);
begin
  Timers;
  var L := 0.0;
  var R := 0.0;
  for var C := 0 to 63 do
    if FVoices[C].Active then
    begin
      var V := Voice(C);
      var Send := WordAt(C * 128 + $20);
      FDSP.Mix(Send and 15, EnsureRange(Round(V * Gain((Send shr 4) and 15, 0, 0) * 4), -$80000, $7FFFF));
      var Pan := WordAt(C * 128 + $24);
      var Level := (Pan shr 8) and 15;
      var Position := Pan and 31;
      if WordAt($2800) and $8000 <> 0 then
        Position := 0;
      L := L + V * Gain(Level, Position, 0);
      R := R + V * Gain(Level, Position, 1);
    end;
  FDSP.Step;
  for var E := 0 to 15 do
  begin
    var Pan := WordAt($2000 + E * 4);
    L := L + FDSP.Effect(E) * Gain((Pan shr 8) and 15, Pan and 31, 0);
    R := R + FDSP.Effect(E) * Gain((Pan shr 8) and 15, Pan and 31, 1);
  end;
  var Master := Gain(WordAt($2800) and 15, 0, 0);
  Left := EnsureRange(Round(FDC[0].Process(L * Master / 2)), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(R * Master / 2)), -32768, 32767);
end;

end.

