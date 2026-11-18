unit SWF.VP6.Entropy;

interface

uses
  System.SysUtils;

type
  TVP6BoolReader = record
  private
    FData: TBytes;
    FPosition, FLimit, FBits: Integer;
    FValue, FRange: Cardinal;
  public
    procedure Init(const Data: TBytes; Offset, Size: Integer);
    function ReadBit(Probability: Byte = 128): Boolean;
    function ReadBits(Count: Integer): Integer;
    function ReadProbability: Byte;
  end;

  TVP6BitReader = record
  private
    FData: TBytes;
    FPosition, FLimit: Integer;
  public
    procedure Init(const Data: TBytes; Offset, Size: Integer);
    function ReadBits(Count: Integer): Integer;
  end;

  TVP6HuffTree = record
  private
    type
      TNode = record
        Weight, Symbol, Zero, One: Integer;
      end;
  private
    FNodes: array[0..22] of TNode;
    FRoot: Integer;
    procedure Build(const Weights: array of Byte);
  public
    procedure BuildTokens(const Probabilities: array of Byte);
    procedure BuildRuns(const Probabilities: array of Byte);
    function Read(var Bits: TVP6BitReader): Integer;
  end;

implementation

uses
  System.Math, SWF.Reader;

procedure CheckPartition(const Data: TBytes; Offset, Size: Integer);
begin
  if (Offset < 0) or (Offset > Length(Data)) or (Size < 0) or (Size > Length(Data) - Offset) or
    (Length(Data) > 64 * 1024 * 1024) then
    raise ESWFError.Create('Invalid VP6 partition');
end;

procedure TVP6BoolReader.Init(const Data: TBytes; Offset, Size: Integer);
var
  I: Integer;
begin
  CheckPartition(Data, Offset, Size);
  if Size < 4 then
    raise ESWFError.Create('Truncated VP6 range partition');
  FData := Data;
  FValue := 0;
  for I := 0 to 3 do
    FValue := (FValue shl 8) or Data[Offset + I];
  FRange := 255;
  FBits := 8;
  FPosition := Offset + 4;
  FLimit := Offset + Size;
end;

function TVP6BoolReader.ReadBit(Probability: Byte): Boolean;
var
  Shift: Integer;
  Split, Threshold: Cardinal;
begin
  Shift := 0;
  while FRange < 128 do
  begin
    FRange := FRange shl 1;
    Inc(Shift);
  end;
  FValue := FValue shl Shift;
  Dec(FBits, Shift);
  if FBits <= 0 then
  begin
    if FPosition < FLimit then
      FValue := FValue or (Cardinal(FData[FPosition]) shl (-FBits))
    else if FPosition - FLimit >= 4 then
      raise ESWFError.Create('Truncated VP6 range code');
    Inc(FPosition);
    Inc(FBits, 8);
  end;
  Split := 1 + ((FRange - 1) * Probability shr 8);
  Threshold := Split shl 24;
  Result := FValue >= Threshold;
  if Result then
  begin
    Dec(FRange, Split);
    Dec(FValue, Threshold);
  end
  else
    FRange := Split;
end;

function TVP6BoolReader.ReadBits(Count: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Count do
    Result := (Result shl 1) or Ord(ReadBit);
end;

function TVP6BoolReader.ReadProbability: Byte;
begin
  Result := Byte(ReadBits(7) shl 1);
  if Result = 0 then
    Result := 1;
end;

procedure TVP6BitReader.Init(const Data: TBytes; Offset, Size: Integer);
begin
  CheckPartition(Data, Offset, Size);
  FData := Data;
  FPosition := Offset * 8;
  FLimit := (Offset + Size) * 8;
end;

function TVP6BitReader.ReadBits(Count: Integer): Integer;
var
  I: Integer;
begin
  if Count > FLimit - FPosition then
    raise ESWFError.Create('Truncated VP6 Huffman code');
  Result := 0;
  for I := 1 to Count do
  begin
    Result := (Result shl 1) or ((FData[FPosition shr 3] shr (7 - (FPosition and 7))) and 1);
    Inc(FPosition);
  end;
end;

procedure TVP6HuffTree.Build(const Weights: array of Byte);
var
  Length, Low, I, Position, J: Integer;
  Node: TNode;
begin
  Length := 0;
  for I := High(Weights) downto 0 do
  begin
    Position := Length;
    while (Position > 0) and (FNodes[Position - 1].Weight > Weights[I]) do
    begin
      FNodes[Position] := FNodes[Position - 1];
      Dec(Position);
    end;
    FNodes[Position].Weight := Weights[I];
    FNodes[Position].Symbol := I;
    Inc(Length);
  end;
  Low := 0;
  for I := 1 to High(Weights) do
  begin
    Node.Weight := FNodes[Low].Weight + FNodes[Low + 1].Weight;
    Node.Symbol := -1;
    Node.Zero := Low;
    Node.One := Low + 1;
    Inc(Low, 2);
    Position := Low;
    while (Position < Length) and (FNodes[Position].Weight < Node.Weight) do
      Inc(Position);
    for J := Length downto Position + 1 do
      FNodes[J] := FNodes[J - 1];
    FNodes[Position] := Node;
    Inc(Length);
  end;
  FRoot := Length - 1;
end;

function Weight(A, B: Integer): Byte;
begin
  Result := Max(1, A * B shr 8);
end;

procedure TVP6HuffTree.BuildTokens(const Probabilities: array of Byte);
var
  Limits: array[0..11] of Byte;
  NonZero, Two, Large, ThreeOrFour, FirstPair, Rest, NextPair, LastPair: Byte;
begin
  Limits[11] := Weight(Probabilities[0], Probabilities[1]);
  Limits[0] := Weight(Probabilities[0], 255 - Probabilities[1]);
  Limits[1] := Weight(255 - Probabilities[0], Probabilities[2]);
  NonZero := Weight(255 - Probabilities[0], 255 - Probabilities[2]);
  Two := Weight(NonZero, Probabilities[3]);
  Large := Weight(NonZero, 255 - Probabilities[3]);
  Limits[2] := Weight(Two, Probabilities[4]);
  ThreeOrFour := Weight(Two, 255 - Probabilities[4]);
  Limits[3] := Weight(ThreeOrFour, Probabilities[5]);
  Limits[4] := Weight(ThreeOrFour, 255 - Probabilities[5]);
  FirstPair := Weight(Large, Probabilities[6]);
  Rest := Weight(Large, 255 - Probabilities[6]);
  Limits[5] := Weight(FirstPair, Probabilities[7]);
  Limits[6] := Weight(FirstPair, 255 - Probabilities[7]);
  NextPair := Weight(Rest, Probabilities[8]);
  LastPair := Weight(Rest, 255 - Probabilities[8]);
  Limits[7] := Weight(NextPair, Probabilities[9]);
  Limits[8] := Weight(NextPair, 255 - Probabilities[9]);
  Limits[9] := Weight(LastPair, Probabilities[10]);
  Limits[10] := Weight(LastPair, 255 - Probabilities[10]);
  Build(Limits);
end;

procedure TVP6HuffTree.BuildRuns(const Probabilities: array of Byte);
var
  Limits: array[0..8] of Byte;
  Root, Pair: Byte;
begin
  Root := Weight(Probabilities[0], Probabilities[1]);
  Limits[0] := Weight(Root, Probabilities[2]);
  Limits[1] := Weight(Root, 255 - Probabilities[2]);
  Root := Weight(Probabilities[0], 255 - Probabilities[1]);
  Limits[2] := Weight(Root, Probabilities[3]);
  Limits[3] := Weight(Root, 255 - Probabilities[3]);
  Root := Weight(255 - Probabilities[0], Probabilities[4]);
  Limits[8] := Weight(255 - Probabilities[0], 255 - Probabilities[4]);
  Pair := Weight(Root, Probabilities[5]);
  Limits[4] := Weight(Pair, Probabilities[6]);
  Limits[5] := Weight(Pair, 255 - Probabilities[6]);
  Pair := Weight(Root, 255 - Probabilities[5]);
  Limits[6] := Weight(Pair, Probabilities[7]);
  Limits[7] := Weight(Pair, 255 - Probabilities[7]);
  Build(Limits);
end;

function TVP6HuffTree.Read(var Bits: TVP6BitReader): Integer;
var
  Index: Integer;
begin
  Index := FRoot;
  while FNodes[Index].Symbol < 0 do
    if Bits.ReadBits(1) = 0 then
      Index := FNodes[Index].Zero
    else
      Index := FNodes[Index].One;
  Result := FNodes[Index].Symbol;
end;

end.

