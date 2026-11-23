unit Audio.Codec.GSM;

interface

uses
  System.SysUtils;

const
  GSMWavBlockBytes = 65;
  GSMWavBlockFrames = 320;

type
  TGSMWavSamples = array[0..GSMWavBlockFrames - 1] of SmallInt;

  TGSMLar = array[0..7] of Integer;

  // Complete predictive state at a block boundary. Copying it allows seeking
  // without losing the filter history at boundaries between WAV blocks.
  TGSMDecoder = record
  private
    FHistory: array[0..119] of SmallInt;
    FHistoryPosition, FLag, FDeemphasis: Integer;
    FPreviousLAR: TGSMLar;
    FLattice: array[0..8] of Integer;
    procedure DecodeFrame(const Data: TBytes; Offset: Integer; var Bit: Integer; var Output: TGSMWavSamples; OutputOffset: Integer);
  public
    procedure Reset;
    procedure DecodeWavBlock(const Data: TBytes; Offset: Integer; out Output: TGSMWavSamples);
  end;

implementation

uses
  System.Math, Audio.Binary;

function ShiftRight(Value, Bits: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := -1 - ((-1 - Value) shr Bits)
  else
    Result := Value shr Bits;
end;

function Saturate(Value: Integer): Integer; inline;
begin
  Result := EnsureRange(Value, Low(SmallInt), High(SmallInt));
end;

function MultiplyQ15(A, B: Integer): Integer; inline;
begin
  Result := Saturate(ShiftRight(A * B + 16384, 15));
end;

procedure TGSMDecoder.Reset;
begin
  Self := Default(TGSMDecoder);
  FLag := 40;
end;

procedure TGSMDecoder.DecodeWavBlock(const Data: TBytes; Offset: Integer; out Output: TGSMWavSamples);
begin
  RequireBytes(Data, Offset, GSMWavBlockBytes);
  var Bit := 0;
  DecodeFrame(Data, Offset, Bit, Output, 0);
  DecodeFrame(Data, Offset, Bit, Output, GSMWavBlockFrames div 2);
end;

procedure TGSMDecoder.DecodeFrame(const Data: TBytes; Offset: Integer; var Bit: Integer; var Output: TGSMWavSamples; OutputOffset: Integer);
const
  LARBits: array[0..7] of Integer = (6, 6, 5, 5, 4, 4, 3, 3);
  LARMinimum: TGSMLar = (-32, -32, -16, -16, -8, -8, -4, -4);
  LARBias: TGSMLar = (0, 0, 4096, -5120, 188, -3584, -682, -2288);
  LARInverse: TGSMLar = (13107, 13107, 13107, 13107, 19223, 17476, 31454, 29708);
  PulseScale: array[0..7] of Integer = (18431, 20479, 22527, 24575, 26623, 28671, 30719, 32767);
  PitchGain: array[0..3] of Integer = (3277, 11469, 21299, 32767);
  SynthesisEnds: array[0..3] of Integer = (13, 27, 40, 160);
var
  CurrentLAR, Reflection: TGSMLar;
  Residual: array[0..159] of Integer;
  Grid: array[0..39] of Integer;

  function ReadBits(Count: Integer): Integer;
  begin
    // WAV49 places the two 260-bit frames back to back, LSB first.
    var ByteOffset := Offset + (Bit div 8);
    var InByte := Bit and 7;
    Result := Data[ByteOffset];
    if InByte + Count > 8 then
      Result := Result or (Integer(Data[ByteOffset + 1]) shl 8);
    Result := (Result shr InByte) and ((1 shl Count) - 1);
    Inc(Bit, Count);
  end;

begin
  for var I := 0 to High(CurrentLAR) do
  begin
    var Coded := ReadBits(LARBits[I]);
    var Scaled := Saturate((Coded + LARMinimum[I]) * 1024 - LARBias[I]);
    CurrentLAR[I] := Saturate(2 * MultiplyQ15(LARInverse[I], Scaled));
  end;

  for var Subframe := 0 to 3 do
  begin
    var Lag := ReadBits(7);
    var Gain := PitchGain[ReadBits(2)];
    var GridOffset := ReadBits(2);
    var Peak := ReadBits(6);
    if (Lag >= 40) and (Lag <= 120) then
      FLag := Lag;
    var Exponent := 0;
    if Peak > 15 then
      Exponent := (Peak shr 3) - 1;
    var Mantissa := Peak - Exponent * 8;
    if Mantissa = 0 then
    begin
      Exponent := -4;
      Mantissa := 7;
    end
    else
    begin
      while Mantissa < 8 do
      begin
        Mantissa := Mantissa * 2 + 1;
        Dec(Exponent);
      end;
      Dec(Mantissa, 8);
    end;
    var Shift := 6 - Exponent;
    var Rounding := (1 shl Shift) shr 1;
    FillChar(Grid, SizeOf(Grid), 0);
    for var I := 0 to 12 do
    begin
      var Pulse := (ReadBits(3) * 2 - 7) * 4096;
      Grid[GridOffset + 3 * I] := ShiftRight(
          Saturate(MultiplyQ15(PulseScale[Mantissa], Pulse) + Rounding), Shift);
    end;
    for var I := 0 to High(Grid) do
    begin
      var delayed := (FHistoryPosition + Length(FHistory) - FLag) mod Length(FHistory);
      var Sample := Saturate(Grid[I] + MultiplyQ15(Gain, FHistory[delayed]));
      Residual[Subframe * 40 + I] := Sample;
      FHistory[FHistoryPosition] := SmallInt(Sample);
      FHistoryPosition := (FHistoryPosition + 1) mod Length(FHistory);
    end;
  end;

  var Position := 0;
  for var Section := 0 to High(SynthesisEnds) do
  begin
    for var I := 0 to High(Reflection) do
    begin
      var Previous := FPreviousLAR[I];
      var Current := CurrentLAR[I];
      var Ratio: Integer;
      case Section of
        0:
          Ratio := ShiftRight(Previous, 2) + ShiftRight(Current, 2) + ShiftRight(Previous, 1);
        1:
          Ratio := ShiftRight(Previous, 1) + ShiftRight(Current, 1);
        2:
          Ratio := ShiftRight(Previous, 2) + ShiftRight(Current, 2) + ShiftRight(Current, 1);
      else
        Ratio := Current;
      end;
      var Magnitude := Min(Abs(Ratio), High(SmallInt));
      if Magnitude < 11059 then
        Magnitude := Magnitude * 2
      else if Magnitude < 20070 then
        Inc(Magnitude, 11059)
      else
        Magnitude := Saturate((Magnitude shr 2) + 26112);
      if Ratio < 0 then
        Magnitude := -Magnitude;
      Reflection[I] := Magnitude;
    end;
    while Position < SynthesisEnds[Section] do
    begin
      var Sample := Residual[Position];
      for var I := High(Reflection) downto 0 do
      begin
        Sample := Saturate(Sample - MultiplyQ15(Reflection[I], FLattice[I]));
        FLattice[I + 1] := Saturate(FLattice[I] + MultiplyQ15(Reflection[I], Sample));
      end;
      FLattice[0] := Sample;
      FDeemphasis := Saturate(Sample + MultiplyQ15(FDeemphasis, 28180));
      Output[OutputOffset + Position] := SmallInt(Saturate(FDeemphasis * 2) and not 7);
      Inc(Position);
    end;
  end;
  FPreviousLAR := CurrentLAR;
end;

end.

