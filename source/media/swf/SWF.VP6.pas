unit SWF.VP6;

interface

uses
  System.SysUtils, SWF.VP6.Motion, SWF.VP6.Tables;

type
  TVP6Partition = record
    Offset, Size: Integer;
  end;

  TVP6Packet = record
    Color, Alpha: TVP6Partition;
    CropRight, CropBottom: Integer;
    KeyFrame, Empty: Boolean;
  end;

  TVP6Picture = record
    Width, Height: Integer;
    Y, Cb, Cr, Alpha: TBytes;
  end;

type
  TVP6Header = record
    Columns, Rows, Quantizer, CoefficientOffset, Version, Profile: Integer;
    Interlaced, Huffman, Intra, Golden: Boolean;
    Filter: TVP6MotionFilter;
  end;

  TVP6Probabilities = array[0..10] of Byte;

  TVP6RunProbabilities = array[0..13] of Byte;

  TVP6CoeffModels = record
    DC: array[0..1] of TVP6Probabilities;
    ACToken: array[0..2, 0..1, 0..5] of TVP6Probabilities;
    DCToken: array[0..1, 0..2] of TVP6Probabilities;
    Runs: array[0..1] of TVP6RunProbabilities;
    Order, Scan: TVP6ScanOrder;
  end;

  TVP6PlaneState = record
    Header: TVP6Header;
    CoeffModels: TVP6CoeffModels;
    Motion: TVP6MotionModels;
    Previous, Golden: TVP6Picture;
  end;

  TVP6DecoderState = record
    Color, Alpha: TVP6PlaneState;
  end;

function DecodeVP6Frame(const Data: TBytes; const Packet: TVP6Packet; var State: TVP6DecoderState; var Work: Int64; WorkLimit: Integer): TVP6Picture;

function ReadVP6Packet(const Data: TBytes; HasAlpha, FLV: Boolean): TVP6Packet;

function DecodeVP6KeyFrame(const Data: TBytes; const Packet: TVP6Packet; var Work: Int64; WorkLimit: Integer): TVP6Picture;

implementation

uses
  System.Math, SWF.Reader, SWF.VP6.Entropy;

type
  TVP6Block = array[0..63] of Integer;

  PVP6BoolReader = ^TVP6BoolReader;

  TVP6BlockReader = record
  private
    FModels: TVP6CoeffModels;
    FHeader, FCoefficients: TVP6BoolReader;
    FBool: PVP6BoolReader;
    FHuff: TVP6BitReader;
    FHuffDC: array[0..1] of TVP6HuffTree;
    FHuffAC: array[0..2, 0..1, 0..3] of TVP6HuffTree;
    FHuffRun: array[0..1] of TVP6HuffTree;
    FSkipDC, FSkipAC: array[0..1] of Integer;
    FHeaderInfo: TVP6Header;
    procedure ReadModels;
    procedure ReadRangeBlock(Plane, Context: Integer; out Coefficients: TVP6Block);
    procedure ReadHuffmanBlock(Plane: Integer; out Coefficients: TVP6Block);
  public
    procedure Init(const Data: TBytes; const Partition: TVP6Partition; var State: TVP6PlaneState);
    procedure ReadBlock(Plane, Context: Integer; out Coefficients: TVP6Block);
  end;

const
  VP6EndOfBlock = 42;

function ReadVP6Packet(const Data: TBytes; HasAlpha, FLV: Boolean): TVP6Packet;
var
  Offset, AlphaOffset: Integer;
begin
  Result := Default(TVP6Packet);
  if Length(Data) > 64 * 1024 * 1024 then
    raise ESWFError.Create('VP6 packet limit');
  Offset := Ord(FLV);
  if Length(Data) < Offset then
    raise ESWFError.Create('Truncated FLV VP6 adjustment');
  if FLV then
  begin
    Result.CropRight := Data[0] shr 4;
    Result.CropBottom := Data[0] and 15;
  end;
  Result.Empty := Length(Data) - Offset <= 3 * Ord(HasAlpha);
  if Result.Empty then
    Exit;
  if HasAlpha then
  begin
    AlphaOffset := (Integer(Data[Offset]) shl 16) or (Integer(Data[Offset + 1]) shl 8) or Data[Offset + 2];
    Inc(Offset, 3);
    if (AlphaOffset < 4) or (AlphaOffset > Length(Data) - Offset - 4) then
      raise ESWFError.Create('Invalid VP6 alpha partition offset');
    Result.Alpha.Offset := Offset + AlphaOffset;
    Result.Alpha.Size := Length(Data) - Result.Alpha.Offset;
    Result.Color.Size := AlphaOffset;
  end
  else
    Result.Color.Size := Length(Data) - Offset;
  Result.Color.Offset := Offset;
  Result.KeyFrame := Data[Offset] and $80 = 0;
  if HasAlpha then
    Result.KeyFrame := Result.KeyFrame and (Data[Result.Alpha.Offset] and $80 = 0);
end;

function ReadHeader(const Data: TBytes; const Partition: TVP6Partition; const Previous: TVP6Header; out Reader: TVP6BoolReader): TVP6Header;
var
  Raw, Offset, HeaderSize, MinimumOffset: Integer;
  Separate, UpdateFilter, LoopFilter: Boolean;
begin
  Result := Previous;
  Offset := Partition.Offset;
  if (Offset < 0) or (Offset > Length(Data)) or
    (Partition.Size < 1) or (Partition.Size > Length(Data) - Offset) then
    raise ESWFError.Create('Truncated VP6 picture header');
  Result.Intra := Data[Offset] and $80 = 0;
  Result.Golden := Result.Intra;
  Result.Quantizer := (Data[Offset] shr 1) and 63;
  Result.CoefficientOffset := 0;
  Separate := Data[Offset] and 1 <> 0;
  Raw := 1;
  MinimumOffset := 2;
  if Result.Intra then
  begin
    if Partition.Size < 6 then
      raise ESWFError.Create('Truncated VP6 key picture header');
    Result.Version := Data[Offset + 1] shr 3;
    Result.Profile := (Data[Offset + 1] shr 1) and 3;
    Result.Interlaced := Data[Offset + 1] and 1 <> 0;
    Result.Filter := Default(TVP6MotionFilter);
    if not (Result.Version in [6, 7, 8]) or not (Result.Profile in [0, 3]) then
      raise ESWFError.Create('Unsupported VP6 picture version or profile');
    Raw := 2;
    MinimumOffset := 6;
  end
  else if (Previous.Columns = 0) or (Previous.Rows = 0) then
    raise ESWFError.Create('VP6 predicted picture needs a reference');

  HeaderSize := Partition.Size;
  if Separate or (Result.Profile = 0) then
  begin
    if Partition.Size < Raw + 2 then
      raise ESWFError.Create('Truncated VP6 coefficient offset');
    Result.CoefficientOffset := (Integer(Data[Offset + Raw]) shl 8) or Data[Offset + Raw + 1];
    if (Result.CoefficientOffset <= MinimumOffset) or (Result.CoefficientOffset >= Partition.Size) then
      raise ESWFError.Create('Invalid VP6 coefficient partition offset');
    HeaderSize := Result.CoefficientOffset;
    Inc(Raw, 2);
  end;

  Reader.Init(Data, Offset + Raw, HeaderSize - Raw);
  UpdateFilter := False;
  LoopFilter := False;
  if Result.Intra then
  begin
    Result.Rows := Reader.ReadBits(8);
    Result.Columns := Reader.ReadBits(8);
    if (Result.Columns = 0) or (Result.Rows = 0) or
      (Result.Columns * Result.Rows > 32768) then
      raise ESWFError.Create('VP6 picture size limit');
    Reader.ReadBits(8); // Declared display rows and columns do not rescale Flash video.
    Reader.ReadBits(8);
    Reader.ReadBits(2);
    UpdateFilter := Result.Profile = 3;
  end
  else
  begin
    Result.Golden := Reader.ReadBit;
    if Result.Profile = 3 then
    begin
      LoopFilter := Reader.ReadBit;
      if LoopFilter then
        Reader.ReadBit;
      if Result.Version = 8 then
        UpdateFilter := Reader.ReadBit;
    end;
  end;

  if UpdateFilter then
  begin
    Result.Filter.Adaptive := Reader.ReadBit;
    if Result.Filter.Adaptive then
    begin
      Result.Filter.Bicubic := False;
      Result.Filter.VarianceThreshold := Reader.ReadBits(5);
      if Result.Version <> 8 then
        Result.Filter.VarianceThreshold := Result.Filter.VarianceThreshold shl 5;
      Result.Filter.MotionThreshold := 1 shl (Reader.ReadBits(3) + 1);
    end
    else
    begin
      Result.Filter.Bicubic := Reader.ReadBit;
    end;
    Result.Filter.Alpha := 16;
    if Result.Version = 8 then
      Result.Filter.Alpha := Reader.ReadBits(4);
  end;
  Result.Filter.Strength := 0;
  if LoopFilter then
    Result.Filter.Strength := VP6FilterLimits[Result.Quantizer];
  Result.Huffman := Reader.ReadBit;
  if Result.Huffman and (Result.CoefficientOffset = 0) then
    raise ESWFError.Create('VP6 Huffman stream has no coefficient partition');
end;

procedure TVP6BlockReader.ReadModels;
var
  DefaultProbabilities: TVP6Probabilities;
  Plane, I, Mode, Band, At, Context, Slope, Intercept: Integer;
begin
  FillChar(DefaultProbabilities, SizeOf(DefaultProbabilities), 128);
  for Plane := 0 to 1 do
    for I := 0 to 10 do
      if FHeader.ReadBit(VP6CoeffUpdates[Plane, I]) then
      begin
        DefaultProbabilities[I] := FHeader.ReadProbability;
        FModels.DC[Plane][I] := DefaultProbabilities[I];
      end
      else if FHeaderInfo.Intra then
        FModels.DC[Plane][I] := DefaultProbabilities[I];

  if FHeaderInfo.Intra then
  begin
    if FHeaderInfo.Interlaced then
      FModels.Order := VP6AlternateScan
    else
      FModels.Order := VP6DefaultScan;
    for Plane := 0 to 1 do
      for I := 0 to 13 do
        FModels.Runs[Plane][I] := VP6DefaultRuns[Plane, I];
  end;
  if FHeader.ReadBit then
  begin
    for I := 1 to 63 do
      if FHeader.ReadBit(VP6ScanUpdates[I]) then
        FModels.Order[I] := FHeader.ReadBits(4);
    At := 1;
    FModels.Scan[0] := 0;
    for Band := 0 to 15 do
      for I := 1 to 63 do
        if FModels.Order[I] = Band then
        begin
          FModels.Scan[At] := VP6Zigzag[I];
          Inc(At);
        end;
  end
  else if FHeaderInfo.Intra then
  begin
    if FHeaderInfo.Interlaced then
      FModels.Order := VP6AlternateScan
    else
      FModels.Order := VP6DefaultScan;
    FModels.Scan := VP6Zigzag;
  end;

  for Plane := 0 to 1 do
    for I := 0 to 13 do
      if FHeader.ReadBit(VP6RunUpdates[Plane, I]) then
        FModels.Runs[Plane][I] := FHeader.ReadProbability;
  for Mode := 0 to 2 do
    for Plane := 0 to 1 do
      for Band := 0 to 5 do
        for I := 0 to 10 do
          if FHeader.ReadBit(VP6ACUpdates[Mode, Plane, Band, I]) then
          begin
            DefaultProbabilities[I] := FHeader.ReadProbability;
            FModels.ACToken[Mode, Plane, Band][I] := DefaultProbabilities[I];
          end
          else if FHeaderInfo.Intra then
            FModels.ACToken[Mode, Plane, Band][I] := DefaultProbabilities[I];

  for Plane := 0 to 1 do
    for Context := 0 to 2 do
      for I := 0 to 4 do
      begin
        Slope := VP6DCWeights[I, Context, 0];
        Intercept := VP6DCWeights[I, Context, 1];
        FModels.DCToken[Plane, Context][I] :=
          EnsureRange(((FModels.DC[Plane][I] * Slope + 128) div 256) + Intercept, 1, 255);
      end;
end;

procedure TVP6BlockReader.Init(const Data: TBytes; const Partition: TVP6Partition; var State: TVP6PlaneState);
var
  Plane, Mode, Band, Offset, Size: Integer;
begin
  FillChar(FSkipDC, SizeOf(FSkipDC), 0);
  FillChar(FSkipAC, SizeOf(FSkipAC), 0);
  FHeaderInfo := ReadHeader(Data, Partition, State.Header, FHeader);
  if FHeaderInfo.Intra then
    State.Motion.Reset
  else
    State.Motion.Update(FHeader);
  FModels := State.CoeffModels;
  FBool := @FHeader;
  Offset := Partition.Offset + FHeaderInfo.CoefficientOffset;
  Size := Partition.Size - FHeaderInfo.CoefficientOffset;
  if FHeaderInfo.Huffman then
    FHuff.Init(Data, Offset, Size)
  else if FHeaderInfo.CoefficientOffset <> 0 then
  begin
    FCoefficients.Init(Data, Offset, Size);
    FBool := @FCoefficients;
  end;
  ReadModels;
  State.CoeffModels := FModels;
  State.Header := FHeaderInfo;
  if FHeaderInfo.Huffman then
    for Plane := 0 to 1 do
    begin
      FHuffDC[Plane].BuildTokens(FModels.DC[Plane]);
      FHuffRun[Plane].BuildRuns(FModels.Runs[Plane]);
      for Mode := 0 to 2 do
        for Band := 0 to 3 do
          FHuffAC[Mode, Plane, Band].BuildTokens(FModels.ACToken[Mode, Plane, Band]);
    end;
end;

function ReadToken(var Reader: TVP6BoolReader; const Probs: TVP6Probabilities; Prob34: Byte; DC, HasNonZero: Boolean): Integer;
begin
  if HasNonZero and not Reader.ReadBit(Probs[0]) then
  begin
    if DC or Reader.ReadBit(Probs[1]) then
      Exit(0);
    Exit(VP6EndOfBlock);
  end;
  if not Reader.ReadBit(Probs[2]) then
    Exit(1);
  if Reader.ReadBit(Probs[3]) then
    Exit(5);
  if not Reader.ReadBit(Probs[4]) then
    Exit(2);
  Result := 3 + Ord(Reader.ReadBit(Prob34));
end;

function ExpandToken(var Reader: TVP6BoolReader; const Probs: TVP6Probabilities; Token: Integer): Integer;
var
  Category, I, Extra: Integer;
begin
  if Token = 0 then
    Exit(0);
  Result := Token;
  if Token = 5 then
  begin
    if not Reader.ReadBit(Probs[6]) then
      Category := Ord(Reader.ReadBit(Probs[7]))
    else if not Reader.ReadBit(Probs[8]) then
      Category := 2 + Ord(Reader.ReadBit(Probs[9]))
    else
      Category := 4 + Ord(Reader.ReadBit(Probs[10]));
    Extra := 0;
    for I := 0 to 11 do
    begin
      if VP6ExtraProbabilities[Category, I] = 128 then
        Break;
      Extra := (Extra shl 1) or Ord(Reader.ReadBit(VP6ExtraProbabilities[Category, I]));
    end;
    Result := VP6CoefficientBase[Category] + Extra;
  end;
  if Reader.ReadBit then
    Result := -Result;
end;

function ReadRun(var Reader: TVP6BoolReader; const Probs: TVP6RunProbabilities): Integer;
var
  I: Integer;
begin
  if not Reader.ReadBit(Probs[0]) then
  begin
    if not Reader.ReadBit(Probs[1]) then
      Exit(Ord(Reader.ReadBit(Probs[2])));
    Exit(2 + Ord(Reader.ReadBit(Probs[3])));
  end;
  if not Reader.ReadBit(Probs[4]) then
  begin
    if not Reader.ReadBit(Probs[5]) then
      Exit(4 + Ord(Reader.ReadBit(Probs[6])));
    Exit(6 + Ord(Reader.ReadBit(Probs[7])));
  end;
  Result := 8;
  for I := 0 to 5 do
    Inc(Result, Ord(Reader.ReadBit(Probs[I + 8])) shl I);
end;

function Wrap16(Value: Integer): Integer; inline;
begin
  Result := ((Value + 32768) and 65535) - 32768;
end;

procedure TVP6BlockReader.ReadRangeBlock(Plane, Context: Integer; out Coefficients: TVP6Block);
var
  Token, Level, Mode, Band, Index: Integer;
  Probs: TVP6Probabilities;
begin
  Token := ReadToken(FBool^, FModels.DCToken[Plane, Context], FModels.DC[Plane][5], True, True);
  Level := ExpandToken(FBool^, FModels.DC[Plane], Token);
  Coefficients[0] := Level;
  Index := 1;
  while Index < 64 do
  begin
    Band := VP6ACBands[Index];
    Mode := Min(2, Abs(Level));
    Probs := FModels.ACToken[Mode, Plane, Band];
    Token := ReadToken(FBool^, Probs, Probs[5], False, (Index = 1) or (Level <> 0));
    if Token = VP6EndOfBlock then
      Exit;
    Level := ExpandToken(FBool^, Probs, Token);
    Coefficients[FModels.Scan[Index]] := Wrap16(Level * VP6ACQuant[FHeaderInfo.Quantizer] * 4);
    Inc(Index);
    if Level = 0 then
      Inc(Index, ReadRun(FBool^, FModels.Runs[Ord(Index >= 7)]));
  end;
end;

function ReadHuffToken(var Reader: TVP6BitReader; const Tree: TVP6HuffTree; out Level: Integer): Boolean;
var
  Token, Category: Integer;
begin
  Token := Tree.Read(Reader);
  Result := Token <> 11;
  Level := 0;
  if not Result or (Token = 0) then
    Exit;
  if Token < 5 then
    Level := Token
  else
  begin
    Category := Token - 5;
    Level := VP6CoefficientBase[Category] + Reader.ReadBits(VP6ExtraBits[Category]);
  end;
  if Reader.ReadBits(1) <> 0 then
    Level := -Level;
end;

function ReadHuffSkip(var Reader: TVP6BitReader): Integer;
begin
  Result := Reader.ReadBits(2);
  case Result of
    2:
      Result := 2 + Reader.ReadBits(2);
    3:
      if Reader.ReadBits(1) = 0 then
        Result := 6 + Reader.ReadBits(2)
      else
        Result := 10 + Reader.ReadBits(6);
  end;
end;

procedure TVP6BlockReader.ReadHuffmanBlock(Plane: Integer; out Coefficients: TVP6Block);
var
  Level, Mode, Band, Index, Run: Integer;
begin
  Level := 0;
  if FSkipDC[Plane] = 0 then
  begin
    if not ReadHuffToken(FHuff, FHuffDC[Plane], Level) then
      Exit;
    Coefficients[0] := Level;
    if Level = 0 then
      FSkipDC[Plane] := ReadHuffSkip(FHuff);
  end
  else
    Dec(FSkipDC[Plane]);
  if FSkipAC[Plane] > 0 then
  begin
    Dec(FSkipAC[Plane]);
    Exit;
  end;

  Index := 1;
  while Index < 64 do
  begin
    Band := Min(3, VP6ACBands[Index]);
    Mode := Min(2, Abs(Level));
    if not ReadHuffToken(FHuff, FHuffAC[Mode, Plane, Band], Level) then
    begin
      if Index = 1 then
        FSkipAC[Plane] := ReadHuffSkip(FHuff);
      Exit;
    end;
    Coefficients[FModels.Scan[Index]] := Wrap16(Level * VP6ACQuant[FHeaderInfo.Quantizer] * 4);
    Inc(Index);
    if Level = 0 then
    begin
      Run := FHuffRun[Ord(Index >= 7)].Read(FHuff);
      if Run = 8 then
        Inc(Run, FHuff.ReadBits(6));
      Inc(Index, Run);
    end;
  end;
end;

procedure TVP6BlockReader.ReadBlock(Plane, Context: Integer; out Coefficients: TVP6Block);
begin
  FillChar(Coefficients, SizeOf(Coefficients), 0);
  if FHeaderInfo.Huffman then
    ReadHuffmanBlock(Plane, Coefficients)
  else
    ReadRangeBlock(Plane, Context, Coefficients);
end;

function Multiply16(A, B: Integer): Integer; inline;
var
  Product: Int64;
begin
  Product := Int64(A) * B;
  Result := Integer((Product - (Product and 65535)) div 65536);
end;

procedure IDCTStep(const Source: TVP6Block; SourceIndex, SourceStep: Integer; var Dest: TVP6Block; DestIndex, DestStep, Bias, Divisor: Integer; Narrow: Boolean);
var
  S: array[0..7] of Integer;
  I, T0, T1, T2, T3, A, B, C, D, E, F, G, H, V: Integer;

  procedure Store(Index, Value: Integer);
  begin
    V := (Value - (Value and (Divisor - 1))) div Divisor;
    Dest[DestIndex + Index * DestStep] := V;
  end;

begin
  for I := 0 to 7 do
    S[I] := Source[SourceIndex + I * SourceStep];
  T0 := Multiply16(64277, S[1]) + Multiply16(12785, S[7]);
  T1 := Multiply16(12785, S[1]) - Multiply16(64277, S[7]);
  T2 := Multiply16(54491, S[3]) + Multiply16(36410, S[5]);
  T3 := Multiply16(54491, S[5]) - Multiply16(36410, S[3]);
  A := Multiply16(46341, T0 - T2);
  B := Multiply16(46341, T1 - T3);
  C := T0 + T2;
  D := T1 + T3;
  T0 := S[0] + S[4];
  T1 := S[0] - S[4];
  if Narrow then
  begin
    T0 := Wrap16(T0);
    T1 := Wrap16(T1);
  end;
  E := Multiply16(46341, T0) + Bias;
  F := Multiply16(46341, T1) + Bias;
  G := Multiply16(60547, S[2]) + Multiply16(25080, S[6]);
  H := Multiply16(25080, S[2]) - Multiply16(60547, S[6]);
  Store(0, E + G + C);
  Store(7, E + G - C);
  Store(1, F + A + B + H);
  Store(2, F + A - B - H);
  Store(3, E - G + D);
  Store(4, E - G - D);
  Store(5, F - A + B - H);
  Store(6, F - A - B + H);
end;

procedure StoreBlock(var Plane: TBytes; Width, X, Y, Step: Integer; Intra: Boolean; var Coefficients: TVP6Block);
var
  Temp: TVP6Block;
  I, Row, Col, At, DC, Value: Integer;
  HasAC: Boolean;
begin
  HasAC := False;
  for I := 1 to 63 do
    if Coefficients[I] <> 0 then
    begin
      HasAC := True;
      Break;
    end;
  if HasAC then
  begin
    for I := 0 to 7 do
      IDCTStep(Coefficients, I * 8, 1, Temp, I * 8, 1, 0, 1, True);
    for I := 0 to 7 do
      IDCTStep(Temp, I, 8, Coefficients, I, 8, 8, 16, False);
  end
  else
  begin
    DC := Multiply16(46341, Multiply16(46341, Coefficients[0])) + 8;
    DC := (DC - (DC and 15)) div 16;
    for I := 0 to 63 do
      Coefficients[I] := DC;
  end;
  for Row := 0 to 7 do
  begin
    At := (Y + Row * Step) * Width + X;
    for Col := 0 to 7 do
    begin
      if Intra then
        Value := 128
      else
        Value := Plane[At + Col];
      Plane[At + Col] := EnsureRange(Coefficients[Row * 8 + Col] + Value, 0, 255);
    end;
  end;
end;

function DecodePlaneSet(const Data: TBytes; const Partition: TVP6Partition; Alpha: Boolean; var State: TVP6PlaneState; var Work: Int64; WorkLimit: Integer): TVP6Picture;
var
  Reader: TVP6BlockReader;
  TopDC: array[0..2] of TArray<Integer>;
  TopToken, TopReference: array[0..2] of TBytes;
  LeftDC: array[0..3] of Integer;
  LeftToken, LeftReference: array[0..3] of Byte;
  LastDC: array[0..2, 0..2] of Integer;
  Macroblocks: TArray<TVP6Macroblock>;
  Prediction: TVP6BlockPrediction;
  Reference: TVP6Picture;
  Block: TVP6Block;
  MBX, MBY, I, Plane, Left, Top, X, Y, Step, Cols, Rows, DC, AC, Count, Probability, InitialProbability, RefID, PreviousMode: Integer;
  Interlaced, Intra: Boolean;

  procedure PredictMacroblock;
  var
    J, BlockY, RowStep: Integer;
  begin
    if RefID = 1 then
      Reference := State.Previous
    else
      Reference := State.Golden;
    if (Reference.Width <> Result.Width) or (Reference.Height <> Result.Height) then
      raise ESWFError.Create('Missing VP6 reference picture');
    RowStep := 1 + Ord(Interlaced);
    for J := 0 to 3 do
    begin
      if Interlaced then
        BlockY := MBY * 16 + (J shr 1)
      else
        BlockY := MBY * 16 + (J shr 1) * 8;
      PredictVP6Block(Result.Y, Reference.Y, Result.Width, Result.Height,
        MBX * 16 + (J and 1) * 8, BlockY, RowStep, True, Prediction.Vectors[J], Reader.FHeaderInfo.Filter);
    end;
    if not Alpha then
    begin
      PredictVP6Block(Result.Cb, Reference.Cb, Result.Width div 2, Result.Height div 2,
        MBX * 8, MBY * 8, 1, False, Prediction.Vectors[4], Reader.FHeaderInfo.Filter);
      PredictVP6Block(Result.Cr, Reference.Cr, Result.Width div 2, Result.Height div 2,
        MBX * 8, MBY * 8, 1, False, Prediction.Vectors[4], Reader.FHeaderInfo.Filter);
    end;
  end;

begin
  Reader.Init(Data, Partition, State);
  Cols := Reader.FHeaderInfo.Columns;
  Rows := Reader.FHeaderInfo.Rows;
  Result := Default(TVP6Picture);
  Result.Width := Cols * 16;
  Result.Height := Rows * 16;
  Inc(Work, Int64(Cols) * Rows * (1536 + Ord(not Reader.FHeaderInfo.Intra) * 768) + Partition.Size);
  if Work > WorkLimit then
    raise ESWFError.Create('VP6 decoding work limit');
  SetLength(Result.Y, Result.Width * Result.Height);
  if not Alpha then
  begin
    SetLength(Result.Cb, Length(Result.Y) div 4);
    SetLength(Result.Cr, Length(Result.Cb));
  end;
  for Plane := 0 to 2 do
  begin
    Count := Cols;
    if Plane = 0 then
      Count := Count * 2;
    SetLength(TopDC[Plane], Count);
    SetLength(TopToken[Plane], Count);
    SetLength(TopReference[Plane], Count);
    FillChar(TopReference[Plane][0], Count, $FF);
  end;
  if not Reader.FHeaderInfo.Intra then
    SetLength(Macroblocks, Cols * Rows);
  FillChar(LastDC, SizeOf(LastDC), 0);
  LastDC[0, 1] := 128;
  LastDC[0, 2] := 128;
  InitialProbability := 0;
  if Reader.FHeaderInfo.Interlaced then
    InitialProbability := Reader.FHeader.ReadBits(8);
  Interlaced := False;
  PreviousMode := 0;
  for MBY := 0 to Rows - 1 do
  begin
    FillChar(LeftDC, SizeOf(LeftDC), 0);
    FillChar(LeftToken, SizeOf(LeftToken), 0);
    FillChar(LeftReference, SizeOf(LeftReference), $FF);
    for MBX := 0 to Cols - 1 do
    begin
      if Reader.FHeaderInfo.Interlaced then
      begin
        Probability := InitialProbability;
        if MBX > 0 then
        begin
          if Interlaced then
            Dec(Probability, Probability div 2)
          else
            Inc(Probability, (256 - Probability) div 2);
        end;
        Interlaced := Reader.FHeader.ReadBit(Byte(Probability and 255));
      end;
      RefID := 0;
      if not Reader.FHeaderInfo.Intra then
      begin
        Prediction := State.Motion.ReadMacroblock(Reader.FHeader, PreviousMode, Macroblocks, MBX, MBY, Cols);
        RefID := Prediction.Reference;
        Macroblocks[MBY * Cols + MBX].Reference := RefID;
        Macroblocks[MBY * Cols + MBX].Vector := Prediction.Vectors[3];
        if RefID <> 0 then
          PredictMacroblock;
      end;
      Intra := RefID = 0;
      for I := 0 to 5 do
      begin
        if I < 4 then
        begin
          Plane := 0;
          Left := I shr 1;
          Top := MBX * 2 + (I and 1);
        end
        else
        begin
          Plane := I - 3;
          Left := I - 2;
          Top := MBX;
        end;
        AC := Ord(Plane <> 0);
        try
          Reader.ReadBlock(AC, LeftToken[Left] + TopToken[Plane][Top], Block);
        except
          on E: ESWFError do
            raise ESWFError.CreateFmt('VP6 block %d,%d/%d mode %d: %s', [MBX, MBY, I, PreviousMode, E.Message]);
        end;
        LeftToken[Left] := Ord(Block[0] <> 0);
        TopToken[Plane][Top] := LeftToken[Left];
        Count := 0;
        DC := 0;
        if LeftReference[Left] = RefID then
        begin
          DC := LeftDC[Left];
          Inc(Count);
        end;
        if TopReference[Plane][Top] = RefID then
        begin
          Inc(DC, TopDC[Plane][Top]);
          Inc(Count);
        end;
        if Count = 0 then
          DC := LastDC[RefID, Plane]
        else
          DC := DC div Count;
        DC := Wrap16(Block[0] + DC);
        LeftDC[Left] := DC;
        LeftReference[Left] := RefID;
        TopDC[Plane][Top] := DC;
        TopReference[Plane][Top] := RefID;
        LastDC[RefID, Plane] := DC;
        Block[0] := Wrap16(DC * VP6DCQuant[Reader.FHeaderInfo.Quantizer] * 4);
        X := Top * 8;
        Y := MBY * 8;
        Step := 1;
        if Plane = 0 then
        begin
          if Interlaced then
          begin
            Y := MBY * 16 + (I shr 1);
            Step := 2;
          end
          else
            Y := MBY * 16 + (I shr 1) * 8;
          StoreBlock(Result.Y, Result.Width, X, Y, Step, Intra, Block);
        end
        else if not Alpha then
        begin
          if Plane = 1 then
            StoreBlock(Result.Cb, Result.Width div 2, X, Y, Step, Intra, Block)
          else
            StoreBlock(Result.Cr, Result.Width div 2, X, Y, Step, Intra, Block);
        end;
      end;
    end;
  end;
  State.Previous := Result;
  if Reader.FHeaderInfo.Golden then
    State.Golden := Result;
end;

function DecodeVP6Frame(const Data: TBytes; const Packet: TVP6Packet; var State: TVP6DecoderState; var Work: Int64; WorkLimit: Integer): TVP6Picture;
var
  Alpha: TVP6Picture;
  Next: TVP6DecoderState;
begin
  if Packet.Empty then
    raise ESWFError.Create('Empty VP6 frame has no image data');
  if Packet.KeyFrame then
    Next := Default(TVP6DecoderState)
  else
    Next := State;
  Result := DecodePlaneSet(Data, Packet.Color, False, Next.Color, Work, WorkLimit);
  if Packet.Alpha.Size > 0 then
  begin
    Alpha := DecodePlaneSet(Data, Packet.Alpha, True, Next.Alpha, Work, WorkLimit);
    if (Alpha.Width <> Result.Width) or (Alpha.Height <> Result.Height) then
      raise ESWFError.Create('VP6 alpha picture dimensions differ');
    Result.Alpha := Alpha.Y;
  end;
  State := Next;
end;

function DecodeVP6KeyFrame(const Data: TBytes; const Packet: TVP6Packet; var Work: Int64; WorkLimit: Integer): TVP6Picture;
var
  State: TVP6DecoderState;
begin
  if not Packet.KeyFrame then
    raise ESWFError.Create('VP6 intra picture expected');
  State := Default(TVP6DecoderState);
  Result := DecodeVP6Frame(Data, Packet, State, Work, WorkLimit);
end;

end.

