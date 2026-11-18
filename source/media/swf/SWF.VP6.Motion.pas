unit SWF.VP6.Motion;

interface

uses
  System.SysUtils, SWF.VP6.Entropy;

type
  TVP6MotionVector = record
    X, Y: Integer;
  end;

  TVP6Macroblock = record
    Reference: Integer;
    Vector: TVP6MotionVector;
  end;

  TVP6BlockPrediction = record
    Reference: Integer;
    Vectors: array[0..4] of TVP6MotionVector;
  end;

  TVP6MotionFilter = record
    Adaptive, Bicubic: Boolean;
    VarianceThreshold, MotionThreshold, Alpha, Strength: Integer;
  end;

  TVP6MotionModels = record
  private
    type
      TVectorModel = record
        NonZero, Sign: Byte;
        Raw: array[0..7] of Byte;
        Tree: array[0..6] of Byte;
      end;
  private
    FTransmitted: array[0..2, 0..19] of Byte;
    FProbabilities: array[0..2, 0..9, 0..9] of Byte;
    FVectorModels: array[0..1] of TVectorModel;
    function ReadMode(var Bits: TVP6BoolReader; Context, Previous: Integer): Integer;
    function ReadComponent(var Bits: TVP6BoolReader; Axis: Integer): Integer;
    function ReadVector(var Bits: TVP6BoolReader; const Base: TVP6MotionVector): TVP6MotionVector;
  public
    procedure Reset;
    procedure Update(var Bits: TVP6BoolReader);
    function ReadMacroblock(var Bits: TVP6BoolReader; var PreviousMode: Integer; const Macroblocks: TArray<TVP6Macroblock>; MBX, MBY, Columns: Integer): TVP6BlockPrediction;
  end;

procedure PredictVP6Block(var Dest: TBytes; const Reference: TBytes; Width, Height, X, Y, RowStep: Integer; Luma: Boolean; const Vector: TVP6MotionVector; const Filter: TVP6MotionFilter);

implementation

uses
  System.Math, SWF.Reader, SWF.VP6.Tables;

const
  VP6IntraMode = 1;
  VP6FourVectorMode = 7;
  ModeReferences: array[0..9] of Byte = (1, 0, 1, 1, 1, 2, 2, 1, 2, 2);
  FourVectorModes: array[0..3] of Byte = (0, 2, 3, 4);
  CandidateOffsets: array[0..11, 0..1] of ShortInt = (
    (0, -1), (-1, 0), (-1, -1), (1, -1), (0, -2), (-2, 0),
    (-2, -1), (-1, -2), (1, -2), (2, -1), (-2, -2), (2, -2));

type
  TVP6VectorCandidates = record
    Count: Integer;
    Nearest, near, Base: TVP6MotionVector;
  end;

function FloorDivide(Value, Divisor: Integer): Integer; inline;
begin
  Result := (Value - (Value and (Divisor - 1))) div Divisor;
end;

function FindCandidates(const Macroblocks: TArray<TVP6Macroblock>; MBX, MBY, Columns, Reference: Integer): TVP6VectorCandidates;
var
  I, X, Y: Integer;
  Candidate: TVP6Macroblock;
begin
  Result := Default(TVP6VectorCandidates);
  for I := 0 to High(CandidateOffsets) do
  begin
    X := MBX + CandidateOffsets[I, 0];
    Y := MBY + CandidateOffsets[I, 1];
    if (X < 0) or (X >= Columns) or (Y < 0) then
      Continue;
    Candidate := Macroblocks[Y * Columns + X];
    if (Candidate.Reference <> Reference) or ((Candidate.Vector.X = 0) and (Candidate.Vector.Y = 0)) then
      Continue;
    if Result.Count = 0 then
    begin
      Result.Nearest := Candidate.Vector;
      if I < 2 then
        Result.Base := Candidate.Vector;
      Result.Count := 1;
    end
    else if (Result.Nearest.X <> Candidate.Vector.X) or (Result.Nearest.Y <> Candidate.Vector.Y) then
    begin
      Result.near := Candidate.Vector;
      Result.Count := 2;
      Break;
    end;
  end;
end;

procedure TVP6MotionModels.Reset;
var
  I, J: Integer;
begin
  Move(VP6DefaultModes, FTransmitted, SizeOf(FTransmitted));
  for I := 0 to 1 do
  begin
    FVectorModels[I].NonZero := VP6VectorNonZero[I];
    FVectorModels[I].Sign := 128;
    for J := 0 to 7 do
      FVectorModels[I].Raw[J] := VP6VectorRaw[I, J];
    for J := 0 to 6 do
      FVectorModels[I].Tree[J] := VP6VectorTree[I, J];
  end;
end;

function ReadModeDelta(var Bits: TVP6BoolReader): Integer;
var
  Negative: Boolean;
begin
  Negative := Bits.ReadBit;
  if not Bits.ReadBit(171) then
    Result := 2 - Ord(Bits.ReadBit(83))
  else if Bits.ReadBit(199) then
    Result := Bits.ReadBits(7)
  else if Bits.ReadBit(140) then
    Result := 3
  else if Bits.ReadBit(125) then
    Result := 4
  else
    Result := 6 - Ord(Bits.ReadBit(104));
  Result := Result * 4;
  if Negative then
    Result := -Result;
end;

function ModeRatio(Count, Total: Integer): Integer; inline;
begin
  Result := 255 * Count div (1 + Total);
end;

procedure TVP6MotionModels.Update(var Bits: TVP6BoolReader);
var
  Context, I, J, Delta, Value, Total, Sum, Mode, Inter, near, Gold, GoldNear, Mixed: Integer;
  Counts: array[0..9] of Integer;
begin
  for Context := 0 to 2 do
  begin
    if Bits.ReadBit(174) then
    begin
      I := Bits.ReadBits(4);
      for J := 0 to 19 do
        FTransmitted[Context, J xor 1] := VP6ModeVQ[Context, I, J];
    end;
    if Bits.ReadBit(254) then
      for J := 0 to 19 do
        if Bits.ReadBit(205) then
        begin
          Delta := ReadModeDelta(Bits);
          Value := FTransmitted[Context, J xor 1] + Delta;
          if (Abs(Delta) >= 256) or (Value < 0) or (Value > 255) then
            raise ESWFError.Create('Invalid VP6 mode probability');
          FTransmitted[Context, J xor 1] := Value;
        end;
    for Mode := 0 to 9 do
    begin
      Total := 0;
      for I := 0 to 9 do
      begin
        Counts[I] := 0;
        if I <> Mode then
          Counts[I] := 100 * FTransmitted[Context, I * 2];
        Inc(Total, Counts[I]);
      end;
      Sum := FTransmitted[Context, Mode * 2] + FTransmitted[Context, Mode * 2 + 1];
      Inter := Counts[0] + Counts[2];
      near := Counts[3] + Counts[4];
      Gold := Counts[5] + Counts[6];
      GoldNear := Counts[8] + Counts[9];
      Mixed := Counts[1] + Counts[7];
      FProbabilities[Context, Mode, 0] := 1 + ModeRatio(Inter + near, Total);
      FProbabilities[Context, Mode, 1] := 1 + ModeRatio(Inter, Inter + near);
      FProbabilities[Context, Mode, 2] := 1 + ModeRatio(Mixed, Mixed + Gold + GoldNear);
      FProbabilities[Context, Mode, 3] := 1 + ModeRatio(Counts[0], Inter);
      FProbabilities[Context, Mode, 4] := 1 + ModeRatio(Counts[3], near);
      FProbabilities[Context, Mode, 5] := 1 + ModeRatio(Counts[1], Mixed);
      FProbabilities[Context, Mode, 6] := 1 + ModeRatio(Gold, Gold + GoldNear);
      FProbabilities[Context, Mode, 7] := 1 + ModeRatio(Counts[5], Gold);
      FProbabilities[Context, Mode, 8] := 1 + ModeRatio(Counts[8], GoldNear);
      FProbabilities[Context, Mode, 9] := 255 - ModeRatio(FTransmitted[Context, Mode * 2 + 1], Sum);
    end;
  end;

  for I := 0 to 1 do
  begin
    if Bits.ReadBit(VP6VectorNonZeroUpdate[I]) then
      FVectorModels[I].NonZero := Bits.ReadProbability;
    if Bits.ReadBit(VP6VectorSignUpdate[I]) then
      FVectorModels[I].Sign := Bits.ReadProbability;
  end;
  for I := 0 to 1 do
    for J := 0 to 6 do
      if Bits.ReadBit(VP6VectorTreeUpdate[I, J]) then
        FVectorModels[I].Tree[J] := Bits.ReadProbability;
  for I := 0 to 1 do
    for J := 0 to 7 do
      if Bits.ReadBit(VP6VectorRawUpdate[I, J]) then
        FVectorModels[I].Raw[J] := Bits.ReadProbability;
end;

function TVP6MotionModels.ReadMode(var Bits: TVP6BoolReader; Context, Previous: Integer): Integer;
begin
  if Bits.ReadBit(FProbabilities[Context, Previous, 9]) then
    Exit(Previous);
  if not Bits.ReadBit(FProbabilities[Context, Previous, 0]) then
  begin
    if not Bits.ReadBit(FProbabilities[Context, Previous, 1]) then
      Exit(2 * Ord(Bits.ReadBit(FProbabilities[Context, Previous, 3])));
    Exit(3 + Ord(Bits.ReadBit(FProbabilities[Context, Previous, 4])));
  end;
  if not Bits.ReadBit(FProbabilities[Context, Previous, 2]) then
  begin
    if Bits.ReadBit(FProbabilities[Context, Previous, 5]) then
      Exit(VP6FourVectorMode);
    Exit(VP6IntraMode);
  end;
  if not Bits.ReadBit(FProbabilities[Context, Previous, 6]) then
    Exit(5 + Ord(Bits.ReadBit(FProbabilities[Context, Previous, 7])));
  Result := 8 + Ord(Bits.ReadBit(FProbabilities[Context, Previous, 8]));
end;

function TVP6MotionModels.ReadComponent(var Bits: TVP6BoolReader; Axis: Integer): Integer;
var
  Model: TVectorModel;
  Group, Pair, Order: Integer;
begin
  Model := FVectorModels[Axis];
  Result := 0;
  if not Bits.ReadBit(Model.NonZero) then
  begin
    Group := Ord(Bits.ReadBit(Model.Tree[0]));
    Pair := Ord(Bits.ReadBit(Model.Tree[1 + 3 * Group]));
    Result := 4 * Group + 2 * Pair + Ord(Bits.ReadBit(Model.Tree[2 + 3 * Group + Pair]));
  end
  else
  begin
    for Order in VP6VectorOrder do
      Result := Result or (Ord(Bits.ReadBit(Model.Raw[Order])) shl Order);
    if Result and $F0 = 0 then
      Result := Result or 8
    else
      Result := Result or (Ord(Bits.ReadBit(Model.Raw[3])) shl 3);
  end;
  if (Result <> 0) and Bits.ReadBit(Model.Sign) then
    Result := -Result;
end;

function TVP6MotionModels.ReadVector(var Bits: TVP6BoolReader; const Base: TVP6MotionVector): TVP6MotionVector;
begin
  Result.X := Base.X + ReadComponent(Bits, 0);
  Result.Y := Base.Y + ReadComponent(Bits, 1);
end;

function TVP6MotionModels.ReadMacroblock(var Bits: TVP6BoolReader; var PreviousMode: Integer; const Macroblocks: TArray<TVP6Macroblock>; MBX, MBY, Columns: Integer): TVP6BlockPrediction;
var
  Candidates: TVP6VectorCandidates;
  SubModes: array[0..3] of Integer;
  Mode, I, SumX, SumY: Integer;

  function VectorFor(Mode: Integer): TVP6MotionVector;
  begin
    case Mode of
      2, 6:
        Result := ReadVector(Bits, Candidates.Base);
      3, 8:
        Result := Candidates.Nearest;
      4, 9:
        Result := Candidates.near;
    else
      Result := Default(TVP6MotionVector);
    end;
  end;

begin
  Result := Default(TVP6BlockPrediction);
  Candidates := FindCandidates(Macroblocks, MBX, MBY, Columns, 1);
  Mode := ReadMode(Bits, (Candidates.Count + 1) mod 3, PreviousMode);
  PreviousMode := Mode;
  Result.Reference := ModeReferences[Mode];
  if Result.Reference = 0 then
    Exit;
  if Result.Reference = 2 then
    Candidates := FindCandidates(Macroblocks, MBX, MBY, Columns, 2);
  if Mode = VP6FourVectorMode then
  begin
    for I := 0 to 3 do
      SubModes[I] := FourVectorModes[Bits.ReadBits(2)];
    SumX := 0;
    SumY := 0;
    for I := 0 to 3 do
    begin
      Result.Vectors[I] := VectorFor(SubModes[I]);
      Inc(SumX, Result.Vectors[I].X);
      Inc(SumY, Result.Vectors[I].Y);
    end;
    Result.Vectors[4].X := (SumX + 2 - 4 * Ord(SumX < 0)) div 4;
    Result.Vectors[4].Y := (SumY + 2 - 4 * Ord(SumY < 0)) div 4;
  end
  else
  begin
    Result.Vectors[0] := VectorFor(Mode);
    for I := 1 to 4 do
      Result.Vectors[I] := Result.Vectors[0];
  end;
end;

type
  TVP6Samples = array[0..143] of Byte;

procedure FilterEdge(var Samples: TVP6Samples; Offset, Step, Stride, Strength: Integer);
var
  I, A, B, C, D, Delta: Integer;
begin
  for I := 0 to 11 do
  begin
    A := Samples[Offset - 2 * Step];
    B := Samples[Offset - Step];
    C := Samples[Offset];
    D := Samples[Offset + Step];
    Delta := FloorDivide(A - D + 3 * (C - B) + 4, 8);
    if Abs(Delta) >= 2 * Strength then
      Delta := 0
    else if Delta >= Strength then
      Delta := 2 * Strength - Delta
    else if Delta <= -Strength then
      Delta := -Delta - 2 * Strength;
    Samples[Offset - Step] := EnsureRange(B + Delta, 0, 255);
    Samples[Offset] := EnsureRange(C - Delta, 0, 255);
    Inc(Offset, Stride);
  end;
end;

function LocalVariance(const Samples: TVP6Samples; Offset: Integer): Integer;
var
  X, Y, Value, Sum, SquareSum: Integer;
begin
  Sum := 0;
  SquareSum := 0;
  for Y := 0 to 3 do
    for X := 0 to 3 do
    begin
      Value := Samples[Offset + 24 * Y + 2 * X];
      Inc(Sum, Value);
      Inc(SquareSum, Value * Value);
    end;
  Result := (16 * SquareSum - Sum * Sum) shr 8;
end;

function Interpolate(const Samples: TVP6Samples; Offset, Step, Fraction, Alpha: Integer; Bicubic: Boolean): Integer;
begin
  if Fraction = 0 then
    Exit(Samples[Offset]);
  if not Bicubic then
    Exit((Samples[Offset] * (8 - Fraction) + Samples[Offset + Step] * Fraction + 4) div 8);
  Result := EnsureRange(FloorDivide(Samples[Offset - Step] * VP6Bicubic[Alpha, Fraction, 0] +
      Samples[Offset] * VP6Bicubic[Alpha, Fraction, 1] +
      Samples[Offset + Step] * VP6Bicubic[Alpha, Fraction, 2] +
      Samples[Offset + 2 * Step] * VP6Bicubic[Alpha, Fraction, 3] + 64, 128), 0, 255);
end;

procedure PredictVP6Block(var Dest: TBytes; const Reference: TBytes; Width, Height, X, Y, RowStep: Integer; Luma: Boolean; const Vector: TVP6MotionVector; const Filter: TVP6MotionFilter);
var
  Samples, Horizontal: TVP6Samples;
  Shift, DX, DY, MX, MY, I, J, Source, OutAt, Offset, Strength, FieldY, Parity: Integer;
  Bicubic: Boolean;
begin
  if (Vector.X = 0) and (Vector.Y = 0) then
  begin
    for J := 0 to 7 do
    begin
      Offset := (Y + J * RowStep) * Width + X;
      Move(Reference[Offset], Dest[Offset], 8);
    end;
    Exit;
  end;

  Shift := 8;
  if Luma then
    Shift := 4;
  DX := FloorDivide(Vector.X, Shift);
  DY := FloorDivide(Vector.Y, Shift);
  MX := (Vector.X and (Shift - 1)) * (8 div Shift);
  MY := (Vector.Y and (Shift - 1)) * (8 div Shift);
  for J := 0 to 11 do
  begin
    FieldY := EnsureRange(Y div RowStep + DY + J - 2, 0, Height div RowStep - 1);
    Parity := Y mod RowStep;
    Source := (FieldY * RowStep + Parity) * Width;
    for I := 0 to 11 do
      Samples[J * 12 + I] := Reference[Source + EnsureRange(X + DX + I - 2, 0, Width - 1)];
  end;

  Strength := Filter.Strength;
  if Strength > 0 then
  begin
    if (Vector.X div Shift) and 7 <> 0 then
      FilterEdge(Samples, 10 - (DX and 7), 1, 12, Strength);
    if (Vector.Y div Shift) and 7 <> 0 then
      FilterEdge(Samples, (10 - (DY and 7)) * 12, 12, 1, Strength);
  end;
  Bicubic := Luma and Filter.Bicubic;
  if Luma and Filter.Adaptive and (Max(Abs(Vector.X), Abs(Vector.Y)) <= Filter.MotionThreshold) then
  begin
    Offset := 26 + Ord(Vector.X < 0) + 12 * Ord(Vector.Y < 0);
    Bicubic := LocalVariance(Samples, Offset) >= Filter.VarianceThreshold;
  end;
  for J := 0 to 11 do
    for I := 2 to 9 do
      Horizontal[J * 12 + I] := Interpolate(Samples, J * 12 + I, 1, MX, Filter.Alpha, Bicubic);
  for J := 0 to 7 do
  begin
    OutAt := (Y + J * RowStep) * Width + X;
    for I := 0 to 7 do
      Dest[OutAt + I] := Interpolate(Horizontal, (J + 2) * 12 + I + 2, 12, MY, Filter.Alpha, Bicubic);
  end;
end;

end.

