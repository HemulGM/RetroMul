unit A2600.Sound.TIA;

interface

uses
  System.SysUtils, Core.AudioFilter;

type
  TTIAVoice = record
    Control, Frequency, Volume, Divider, Pulse, Noise: Integer;
    Enabled, NoiseBit, NoiseFeedback, HoldPulse: Boolean;
  end;

  TTIASound = class
  private
    FVoices: array[0..1] of TTIAVoice;
    FPhase, FClock: Double;
    FOutput: array[0..1] of Double;
    FDC: array[0..1] of TPCMDCBlocker;
    procedure Advance;
  public
    constructor Create(Clock: Double = 1193191.666666667);
    procedure Reset;
    procedure WriteRegister(Index, Value: Byte);
    function ReadRegister(Index: Byte): Byte;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

constructor TTIASound.Create(Clock: Double);
begin
  inherited Create;
  if (Clock < 1000000) or (Clock > 1300000) then
    raise EArgumentOutOfRangeException.Create('TIA clock');

  FClock := Clock;
  for var C := 0 to 1 do
    FDC[C].Configure(44100, 20);
  Reset;
end;

procedure TTIASound.Reset;
begin
  FillChar(FVoices, SizeOf(FVoices), 0);
  FPhase := 0;
  for var C := 0 to 1 do
  begin
    FOutput[C] := 0;
    FDC[C].Reset;
  end;
end;

procedure TTIASound.WriteRegister(Index, Value: Byte);
begin
  if (Index < $15) or (Index > $1A) then
    raise EArgumentOutOfRangeException.Create('TIA audio register');

  var C := (Index - $15) mod 2;
  case (Index - $15) div 2 of
    0:
      FVoices[C].Control := Value and 15;
    1:
      FVoices[C].Frequency := Value and 31;
    2:
      FVoices[C].Volume := Value and 15;
  end;
end;

function TTIASound.ReadRegister(Index: Byte): Byte;
begin
  if (Index < $15) or (Index > $1A) then
    raise EArgumentOutOfRangeException.Create('TIA audio register');

  var C := (Index - $15) mod 2;
  case (Index - $15) div 2 of
    0:
      Result := FVoices[C].Control;
    1:
      Result := FVoices[C].Frequency;
  else
    Result := FVoices[C].Volume;
  end;
end;

procedure TTIASound.Advance;
begin
  // The four-bit pulse network and five-bit noise network are coupled.
  // Keep their two clock phases separate, including the divider's enable latch.
  for var C := 0 to 1 do
  begin
    var S := FVoices[C];
    var Mode := S.Control and 3;
    if S.Enabled then
    begin
      S.NoiseBit := S.Noise and 1 <> 0;
      S.HoldPulse := ((Mode = 2) and (S.Noise and 30 <> 2)) or ((Mode = 3) and not S.NoiseBit);
      if Mode = 0 then
        S.NoiseFeedback := ((S.Pulse xor S.Noise) and 1 <> 0) or ((S.Noise = 0) and (S.Pulse = 10)) or (S.Control and 12 = 0)
      else
        S.NoiseFeedback := (((S.Noise shr 2) xor S.Noise) and 1 <> 0) or (S.Noise = 0);
    end;
    S.Enabled := S.Divider = S.Frequency;
    if S.Enabled or (S.Divider = 31) then
      S.Divider := 0
    else
      Inc(S.Divider);
    if S.Enabled then
    begin
      var Feedback := False;
      case S.Control shr 2 of
        0:
          Feedback := (((S.Pulse shr 1) xor S.Pulse) and 1 <> 0) and (S.Pulse <> 10) and (Mode <> 0);
        1:
          Feedback := S.Pulse and 8 = 0;
        2:
          Feedback := not S.NoiseBit;
        3:
          Feedback := (S.Pulse and 2 = 0) and (S.Pulse and 14 <> 0);
      end;
      S.Noise := S.Noise shr 1;
      if S.NoiseFeedback then
        S.Noise := S.Noise or 16;
      if not S.HoldPulse then
      begin
        S.Pulse := (not (S.Pulse shr 1)) and 7;
        if Feedback then
          S.Pulse := S.Pulse or 8;
      end;
    end;
    FVoices[C] := S;
    FOutput[C] := Ord(S.Pulse and 1 <> 0) * S.Volume / 15;
  end;
end;

procedure TTIASound.Sample(out Left, Right: SmallInt);
begin
  FPhase := FPhase + FClock / (38 * 44100);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    Advance;
  end;
  // Hardware has a mono output. Keep both voices in the same electrical mix.
  var V := (FOutput[0] + FOutput[1]) * 0.5;
  Left := EnsureRange(Round(FDC[0].Process(V) * 32767), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(V) * 32767), -32768, 32767);
end;

end.

