unit ZX.Sound.DAC;

interface

uses
  System.SysUtils, Core.AudioFilter;

type
  TZXDACSample = record
    PCM: TArray<SmallInt>;
    Loop: Integer;
  end;

  TZXDACVoice = record
    Sample: Integer;
    Position, Rate, Gain: Double;
    Enabled: Boolean;
  end;

  TZXSampleDAC = class
  private
    FSamples: TArray<TZXDACSample>;
    FChannels: Integer;
    FDC: array[0..1] of TPCMDCBlocker;
  public
    Voices: array[0..3] of TZXDACVoice;
    constructor Create(const Samples: TArray<TZXDACSample>; Channels: Integer);
    procedure Reset;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math;

constructor TZXSampleDAC.Create(const Samples: TArray<TZXDACSample>; Channels: Integer);
begin
  inherited Create;
  if (Channels < 1) or (Channels > 4) then
    raise EArgumentOutOfRangeException.Create('DAC channels');
  FSamples := Copy(Samples);
  FChannels := Channels;
  for var I := 0 to 1 do
    FDC[I].Configure(44100, 20);
  Reset;
end;

procedure TZXSampleDAC.Reset;
begin
  for var C := 0 to 3 do
  begin
    Voices[C] := Default(TZXDACVoice);
    Voices[C].Gain := 1;
  end;
  for var I := 0 to 1 do
    FDC[I].Reset;
end;

procedure TZXSampleDAC.Sample(out Left, Right: SmallInt);
var
  L, R, V: Double;
begin
  L := 0;
  R := 0;
  for var C := 0 to FChannels - 1 do
    if Voices[C].Enabled then
    begin
      var S := Voices[C].Sample;
      if (S < 0) or (S >= Length(FSamples)) then
        Continue;
      var Size := Length(FSamples[S].PCM);
      if Size = 0 then
        Continue;
      var Loop := EnsureRange(FSamples[S].Loop, 0, Size);
      if Voices[C].Position >= Size then
      begin
        if Loop = Size then
        begin
          Voices[C].Enabled := False;
          Continue;
        end;
        Voices[C].Position := Loop + Frac((Voices[C].Position - Loop) / (Size - Loop)) * (Size - Loop);
      end;
      var At := Trunc(Voices[C].Position);
      var Next := At + 1;
      if Next = Size then
        Next := Loop;
      var A := Integer(FSamples[S].PCM[At]);
      var B := 0;
      if Next < Size then
        B := FSamples[S].PCM[Next];
      V := (A + (B - A) * Frac(Voices[C].Position)) * Voices[C].Gain;
      if C = 0 then
        L := L + V
      else if C = FChannels - 1 then
        R := R + V
      else
      begin
        L := L + V * 0.7071067811865475;
        R := R + V * 0.7071067811865475;
      end;
      Voices[C].Position := Voices[C].Position + EnsureRange(Voices[C].Rate, 0.0, 100000.0) / 44100;
    end;
  Left := EnsureRange(Round(FDC[0].Process(L / FChannels)), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(R / FChannels)), -32768, 32767);
end;

end.

