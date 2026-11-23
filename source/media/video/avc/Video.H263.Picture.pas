unit Video.H263.Picture;

interface

uses
  System.SysUtils;

type
  TH263PictureFormat = record
    Width, Height, AspectNumerator, AspectDenominator: Integer;
    CustomClock, Slices: Boolean;
  end;

  TH263PictureHeader = record
    Width, Height, Version, PictureType, Quantizer, BodyBit: Integer;
    AspectNumerator, AspectDenominator: Integer;
    Deblock, H263, Slices, NoRounding: Boolean;
  end;

  TH263Picture = record
    Width, Height: Integer;
    Y, Cb, Cr: TBytes;
  end;

function ReadSparkHeader(const Data: TBytes; Offset: Integer; out Header: TH263PictureHeader): Boolean;

function H263IndependentPicture(const Data: TBytes; Offset, Size: Integer): Boolean;

procedure ReadH263Header(const Data: TBytes; const Previous: TH263PictureFormat; out Header: TH263PictureHeader; out Format: TH263PictureFormat);

function DecodeH263Picture(const Data: TBytes; const Header: TH263PictureHeader; const Reference: TH263Picture; var Work: Int64; WorkLimit: Integer): TH263Picture;

implementation

uses
  System.Math, Video.AVC.Types, Video.H263.Tables;

type
  TSparkBits = record
    Data: TBytes;
    Position: Integer;
    function Read(Count: Integer): Integer;
    function Signed(Count: Integer): Integer;
    function VLC(const Table: array of TSparkVLCEntry): Integer;
  end;

  TSparkBlock = array[0..63] of Integer;

  TSparkVector = record
    X, Y: Integer;
  end;

  TSparkVectors = array[0..3] of TSparkVector;

const
  SparkSizes: array[2..6, 0..1] of Word = ((352, 288), (176, 144), (128, 96), (320, 240), (160, 120));
  SparkQuantizerDelta: array[0..3] of ShortInt = (-1, -2, 1, 2);
  SparkZigzag: array[0..63] of Byte = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);

function TSparkBits.Read(Count: Integer): Integer;
var
  ByteIndex, BitIndex, Step: Integer;
begin
  if Count > Length(Data) * 8 - Position then
    raise EPlayerFormat.Create('Truncated H.263/Spark picture');
  Result := 0;
  while Count > 0 do
  begin
    ByteIndex := Position shr 3;
    BitIndex := Position and 7;
    Step := Min(8 - BitIndex, Count);
    Result := (Result shl Step) or ((Data[ByteIndex] shr (8 - BitIndex - Step)) and ((1 shl Step) - 1));
    Inc(Position, Step);
    Dec(Count, Step);
  end;
end;

function TSparkBits.Signed(Count: Integer): Integer;
begin
  Result := Read(Count);
  if Result and (1 shl (Count - 1)) <> 0 then
    Dec(Result, 1 shl Count);
end;

function TSparkBits.VLC(const Table: array of TSparkVLCEntry): Integer;
var
  Node: Integer;
begin
  Node := 0;
  while Table[Node].Zero <> 0 do
    if Read(1) = 0 then
      Node := Table[Node].Zero
    else
      Node := Table[Node].One;
  Result := Table[Node].Value;
  if Result = SparkVLCInvalid then
    raise EPlayerFormat.Create('Invalid H.263/Spark VLC');
end;

function ReadSparkHeader(const Data: TBytes; Offset: Integer; out Header: TH263PictureHeader): Boolean;
var
  Bits: TSparkBits;
  Format, SizeBits: Integer;
begin
  Header := Default(TH263PictureHeader);
  Result := False;
  if (Offset < 0) or (Length(Data) - Offset < 5) or (Length(Data) > 64 * 1024 * 1024) then
    Exit;
  Bits.Data := Data;
  Bits.Position := Offset * 8;
  try
    if Bits.Read(17) <> 1 then
      Exit;
    Header.Version := Bits.Read(5);
    if Header.Version > 1 then
      Exit;
    Bits.Read(8); // Temporal reference within the group of pictures.
    Format := Bits.Read(3);
    case Format of
      0, 1:
        begin
          SizeBits := 8 + 8 * Format;
          Header.Width := Bits.Read(SizeBits);
          Header.Height := Bits.Read(SizeBits);
        end;
      2..6:
        begin
          Header.Width := SparkSizes[Format, 0];
          Header.Height := SparkSizes[Format, 1];
        end;
    else
      Exit;
    end;
    Header.PictureType := Bits.Read(2);
    if Header.PictureType > 2 then
      Exit;
    Header.Deblock := Bits.Read(1) <> 0;
    Header.Quantizer := Bits.Read(5);
    if (Header.Quantizer = 0) or (Header.Width = 0) or (Header.Height = 0) or
      (Header.Width > 4096) or (Header.Height > 4096) or
      (Int64(Header.Width) * Header.Height > 8 * 1024 * 1024) then
      Exit;
    while Bits.Read(1) <> 0 do
      Bits.Read(8);
    Header.BodyBit := Bits.Position;
    Result := True;
  except
    on E: EPlayerFormat do
      Result := False;
  end;
end;

function H263IndependentPicture(const Data: TBytes; Offset, Size: Integer): Boolean;
begin
  Result := False;
  if (Size < 5) or (Offset < 0) or (Offset > Length(Data) - Size) or
    (Data[Offset] <> 0) or (Data[Offset + 1] <> 0) or (Data[Offset + 2] and $FC <> $80) then
    Exit;
  var SourceType := (Data[Offset + 4] shr 2) and 7;
  if SourceType in [1..5] then
    Exit((Data[Offset + 4] and 2) = 0); // Baseline I-picture.
  // PLUSPTYPE I-pictures must carry OPPTYPE, so UFEP must be 001.
  if (SourceType = 7) and (Size >= 8) then
    Result := (Data[Offset + 4] and 3 = 0) and (Data[Offset + 5] and $80 <> 0) and
      (Data[Offset + 7] and $1C = 0);
end;

procedure ReadH263Header(const Data: TBytes; const Previous: TH263PictureFormat; out Header: TH263PictureHeader; out Format: TH263PictureFormat);
const
  Sizes: array[1..5, 0..1] of Word = ((128, 96), (176, 144), (352, 288), (704, 576), (1408, 1152));
  Aspect: array[1..5, 0..1] of Byte = ((1, 1), (12, 11), (10, 11), (16, 11), (40, 33));
  StructuredSlices = 1 shl 4; // OPPTYPE bit 10, within the ten optional mode bits.
var
  Bits: TSparkBits;

  procedure StandardFormat(Index: Integer);
  begin
    if (Index < Low(Sizes)) or (Index > High(Sizes)) then
      raise EPlayerFormat.Create('Invalid H.263 source format');
    Format.Width := Sizes[Index, 0];
    Format.Height := Sizes[Index, 1];
    Format.AspectNumerator := 12;
    Format.AspectDenominator := 11;
  end;

  procedure ReadCustomFormat;
  begin
    var Code := Bits.Read(4);
    Format.Width := (Bits.Read(9) + 1) * 4;
    if Bits.Read(1) <> 1 then
      raise EPlayerFormat.Create('Invalid H.263 custom size marker');
    Format.Height := Bits.Read(9) * 4;
    if (Format.Height = 0) or (Format.Height > 1152) then
      raise EPlayerFormat.Create('Invalid H.263 custom picture height');
    if Code = 15 then
    begin
      Format.AspectNumerator := Bits.Read(8);
      Format.AspectDenominator := Bits.Read(8);
      if (Format.AspectNumerator = 0) or (Format.AspectDenominator = 0) then
        raise EPlayerFormat.Create('Invalid H.263 extended pixel aspect ratio');
    end
    else
    begin
      if (Code < Low(Aspect)) or (Code > High(Aspect)) then
        raise EPlayerFormat.Create('Invalid H.263 pixel aspect ratio code');
      Format.AspectNumerator := Aspect[Code, 0];
      Format.AspectDenominator := Aspect[Code, 1];
    end;
  end;

  procedure ReadPlusType;
  begin
    var Update := Bits.Read(3);
    if Update > 1 then
      raise EPlayerFormat.Create('Invalid H.263 extended update code');
    var SourceFormat := 0;
    if Update = 1 then
    begin
      SourceFormat := Bits.Read(3);
      Format.CustomClock := Bits.Read(1) <> 0;
      var Modes := Bits.Read(10);
      if (Modes and not StructuredSlices) <> 0 then
        raise EPlayerUnsupported.Create('Unsupported H.263+ optional coding mode');
      Format.Slices := (Modes and StructuredSlices) <> 0;
      if Bits.Read(4) <> 8 then
        raise EPlayerFormat.Create('Invalid H.263 optional type marker');
    end
    else
    begin
      if Previous.Width = 0 then
        raise EPlayerFormat.Create('H.263 extended picture has no preceding format');
      Format := Previous;
    end;
    Header.PictureType := Bits.Read(3);
    if Header.PictureType > 1 then
      raise EPlayerUnsupported.Create('Only H.263 I and P pictures are supported');
    if Bits.Read(2) <> 0 then
      raise EPlayerUnsupported.Create('H.263 resolution update is unsupported');
    Header.NoRounding := Bits.Read(1) <> 0;
    if Bits.Read(3) <> 1 then
      raise EPlayerFormat.Create('Invalid H.263 mandatory type marker');
    if (Header.PictureType = 0) and ((Update = 0) or Header.NoRounding) then
      raise EPlayerFormat.Create('Invalid H.263 intra picture type');
    if Bits.Read(1) <> 0 then
      raise EPlayerUnsupported.Create('H.263 continuous presence mode is unsupported');
    if Update = 1 then
    begin
      if SourceFormat = 6 then
        ReadCustomFormat
      else
        StandardFormat(SourceFormat);
      if Format.CustomClock and ((Bits.Read(8) and 127) = 0) then
        raise EPlayerFormat.Create('Zero H.263 custom clock divisor');
    end;
    if Format.CustomClock then
      Bits.Read(2); // Extended temporal reference. Presentation uses container timestamps.
    if (Update = 1) and Format.Slices and (Bits.Read(2) <> 0) then
      raise EPlayerUnsupported.Create('Only ordered H.263 slices in picture scan order are supported');
    Header.Quantizer := Bits.Read(5);
  end;

begin
  Header := Default(TH263PictureHeader);
  Format := Default(TH263PictureFormat);
  if Length(Data) > 16 * 1024 * 1024 then
    raise EPlayerUnsupported.Create('H.263 picture size limit');
  Bits.Data := Data;
  Bits.Position := 0;
  if Bits.Read(22) <> $20 then
    raise EPlayerFormat.Create('Invalid H.263 picture start code');
  Bits.Read(8); // Temporal reference.
  if Bits.Read(2) <> 2 then
    raise EPlayerFormat.Create('Invalid H.263 picture type marker');
  Bits.Read(3); // Split screen, document camera, freeze release.
  var Index := Bits.Read(3);
  if Index = 7 then
    ReadPlusType
  else
  begin
    StandardFormat(Index);
    Header.PictureType := Bits.Read(1);
    if Bits.Read(4) <> 0 then
      raise EPlayerUnsupported.Create('H.263 optional prediction/coding modes are unsupported');
    Header.Quantizer := Bits.Read(5);
    if Bits.Read(1) <> 0 then
      raise EPlayerUnsupported.Create('H.263 continuous presence mode is unsupported');
  end;
  if Header.Quantizer = 0 then
    raise EPlayerFormat.Create('Invalid H.263 picture quantizer');
  while Bits.Read(1) <> 0 do
    Bits.Read(8);
  Header.Width := Format.Width;
  Header.Height := Format.Height;
  Header.AspectNumerator := Format.AspectNumerator;
  Header.AspectDenominator := Format.AspectDenominator;
  Header.Slices := Format.Slices;
  Header.BodyBit := Bits.Position;
  Header.H263 := True;
end;

function ReadSegmentStart(var Bits: TSparkBits): Boolean;
begin
  if Length(Bits.Data) * 8 - Bits.Position < 17 then
    Exit(False);
  var Start := Bits.Position;
  // Stuffing adds at most seven zero bits before the 17-bit start code.
  if Bits.Read(16) = 0 then
    for var Padding := 0 to 7 do
    begin
      if Length(Bits.Data) * 8 - Bits.Position = 0 then
        Break;
      if Bits.Read(1) = 1 then
        Exit(True);
    end;
  Bits.Position := Start;
  Result := False;
end;

function AddressBits(Blocks: Integer): Integer;
begin
  if Blocks <= 48 then
    Exit(6);
  if Blocks <= 99 then
    Exit(7);
  if Blocks <= 396 then
    Exit(9);
  if Blocks <= 1584 then
    Exit(11);
  if Blocks <= 6336 then
    Exit(13);
  Result := 14;
end;

procedure ReadOrderedSlice(var Bits: TSparkBits; MB, Width: Integer; var Quantizer: Integer);
begin
  if Bits.Read(1) <> 1 then
    raise EPlayerFormat.Create('Invalid H.263 slice address marker');
  if Bits.Read(Width) <> MB then
    raise EPlayerFormat.Create('Unexpected H.263 slice address');
  if MB <> 0 then
  begin
    if (Width > 11) and (Bits.Read(1) <> 1) then
      raise EPlayerFormat.Create('Invalid H.263 slice quantizer marker');
    Quantizer := Bits.Read(5);
    if Quantizer = 0 then
      raise EPlayerFormat.Create('Invalid H.263 slice quantizer');
  end;
  if Bits.Read(1) <> 1 then
    raise EPlayerFormat.Create('Invalid H.263 slice end marker');
  if MB <> 0 then
    Bits.Read(2); // Slice frame identifier.
end;

procedure ReadGOB(var Bits: TSparkBits; Group: Integer; var Quantizer: Integer);
begin
  if Bits.Read(5) <> Group then
    raise EPlayerFormat.Create('Unexpected H.263 group number');
  Bits.Read(2); // GOB frame identifier.
  Quantizer := Bits.Read(5);
  if Quantizer = 0 then
    raise EPlayerFormat.Create('Invalid H.263 group quantizer');
end;

function ClipByte(Value: Integer): Byte; inline;
begin
  Result := EnsureRange(Value, 0, 255);
end;

function HalfFloor(Value: Integer): Integer; inline;
begin
  Result := (Value - (Value and 1)) div 2;
end;

function Median(A, B, C: Integer): Integer;
begin
  Result := Max(Min(A, B), Min(Max(A, B), C));
end;

function PredictVector(const Previous: TArray<TSparkVectors>; const Current: TSparkVectors; MB, Columns, Block, FirstMB: Integer): TSparkVector;
var
  A, B, C: TSparkVector;
  Col: Integer;
begin
  Col := MB mod Columns;
  if Odd(Block) then
    A := Current[Block - 1]
  else if (Col > 0) and (MB > FirstMB) then
    A := Previous[MB - 1][Block + 1]
  else
    A := Default(TSparkVector);
  if Block >= 2 then
  begin
    B := Current[0];
    C := Current[1];
  end
  else
  begin
    if MB - Columns < FirstMB then
      B := A
    else
      B := Previous[MB - Columns][Block + 2];
    if Col = Columns - 1 then
      C := Default(TSparkVector)
    else if MB - Columns + 1 < FirstMB then
      C := A
    else
      C := Previous[MB - Columns + 1][2];
  end;
  Result.X := Median(A.X, B.X, C.X);
  Result.Y := Median(A.Y, B.Y, C.Y);
end;

function ChromaComponent(Sum: Integer): Integer;
var
  Fraction: Integer;
begin
  Fraction := Sum and 15;
  Result := (Sum - Fraction) div 8;
  if Fraction >= 14 then
    Inc(Result, 2)
  else if Fraction > 2 then
    Inc(Result);
end;

procedure ReadBlock(var Bits: TSparkBits; const Header: TH263PictureHeader; Quantizer: Integer; Intra, Coded: Boolean; out Coefficients: TSparkBlock; out AC: Boolean);
var
  Position, Code, Run, Level, LevelBits, Value: Integer;
  Last: Boolean;
begin
  FillChar(Coefficients, SizeOf(Coefficients), 0);
  Position := 0;
  AC := False;
  if Intra then
  begin
    Value := Bits.Read(8);
    if (Value = 0) or (Value = 128) then
      raise EPlayerFormat.Create('Invalid H.263/Spark intra DC value');
    if Value = 255 then
      Value := 128;
    Coefficients[0] := Value * 8;
    Position := 1;
  end;
  if not Coded then
    Exit;
  repeat
    Code := Bits.VLC(SparkCoefficients);
    if Code = SparkCoeffEscape then
    begin
      LevelBits := 8;
      if Header.Version = 1 then
      begin
        LevelBits := 7;
        if Bits.Read(1) <> 0 then
          LevelBits := 11;
      end;
      Last := Bits.Read(1) <> 0;
      Run := Bits.Read(6);
      Level := Bits.Signed(LevelBits);
      if (Level = 0) or (Header.H263 and (Level = -128)) then
        raise EPlayerFormat.Create('Invalid H.263/Spark escaped coefficient');
    end
    else
    begin
      Last := (Code and SparkCoeffLast) <> 0;
      Run := (Code shr 5) and 63;
      Level := Code and 31;
      if Bits.Read(1) <> 0 then
        Level := -Level;
    end;
    Inc(Position, Run);
    if Position >= 64 then
      raise EPlayerFormat.Create('H.263/Spark coefficient run exceeds block');
    Value := Quantizer * (2 * Abs(Level) + 1) - Ord(not Odd(Quantizer));
    if Level < 0 then
      Value := -Value;
    Coefficients[SparkZigzag[Position]] := EnsureRange(Value, -2048, 2047);
    AC := AC or (Position <> 0);
    Inc(Position);
  until Last;
end;

procedure InverseDCT(const Coefficients: TSparkBlock; AC: Boolean; out Samples: TSparkBlock);
var
  Temp: TSparkBlock;
  X, Y, I, DC: Integer;
  Sum: Int64;
begin
  if not AC then
  begin
    if Coefficients[0] < 0 then
      DC := -((-Coefficients[0] + 4) div 8)
    else
      DC := (Coefficients[0] + 4) div 8;
    for I := 0 to High(Samples) do
      Samples[I] := DC;
    Exit;
  end;
  for Y := 0 to 7 do
    for X := 0 to 7 do
    begin
      Sum := 0;
      for I := 0 to 7 do
        Inc(Sum, Coefficients[Y * 8 + I] * SparkIDCTBasis[X, I]);
      Temp[Y * 8 + X] := Integer(Sum);
    end;
  for Y := 0 to 7 do
    for X := 0 to 7 do
    begin
      Sum := 0;
      for I := 0 to 7 do
        Inc(Sum, Int64(Temp[I * 8 + X]) * SparkIDCTBasis[Y, I]);
      if Sum < 0 then
        Samples[Y * 8 + X] := -Integer((-Sum + (Int64(1) shl 27)) shr 28)
      else
        Samples[Y * 8 + X] := Integer((Sum + (Int64(1) shl 27)) shr 28);
    end;
end;

procedure ReconstructBlock(var Plane: TBytes; const Reference: TBytes; Width, Height, X, Y: Integer; const Vector: TSparkVector; Intra, NoRounding: Boolean; const Samples: TSparkBlock);
var
  Row, Col, Dest, SrcX, SrcY, DX, DY, X0, X1, Y0, Y1, FractionX, FractionY, Prediction: Integer;
begin
  DX := HalfFloor(Vector.X);
  DY := HalfFloor(Vector.Y);
  FractionX := Vector.X and 1;
  FractionY := Vector.Y and 1;
  var RoundBias := 2;
  if NoRounding then
    RoundBias := Ord((FractionX <> 0) and (FractionY <> 0));
  for Row := 0 to Min(7, Height - Y - 1) do
  begin
    Dest := (Y + Row) * Width + X;
    SrcY := Y + Row + DY;
    Y0 := EnsureRange(SrcY, 0, Height - 1) * Width;
    Y1 := EnsureRange(SrcY + FractionY, 0, Height - 1) * Width;
    for Col := 0 to Min(7, Width - X - 1) do
    begin
      Prediction := 0;
      if not Intra then
      begin
        SrcX := X + Col + DX;
        X0 := EnsureRange(SrcX, 0, Width - 1);
        if (FractionX = 0) and (FractionY = 0) then
          Prediction := Reference[Y0 + X0]
        else
        begin
          X1 := EnsureRange(SrcX + FractionX, 0, Width - 1);
          Prediction := (Integer(Reference[Y0 + X0]) + Reference[Y0 + X1] +
            Reference[Y1 + X0] + Reference[Y1 + X1] + RoundBias) div 4;
        end;
      end;
      Plane[Dest + Col] := ClipByte(Prediction + Samples[Row * 8 + Col]);
    end;
  end;
end;

function DecodeH263Picture(const Data: TBytes; const Header: TH263PictureHeader; const Reference: TH263Picture; var Work: Int64; WorkLimit: Integer): TH263Picture;
var
  Bits: TSparkBits;
  Predictors: TArray<TSparkVectors>;
  Vectors: TSparkVectors;
  Chroma, Prediction: TSparkVector;
  Coefficients, Samples: TSparkBlock;
  Columns, Rows, MB, Entry, Kind, Pattern, Quantizer, I, X, Y, HalfWidth, HalfHeight, GroupSize, FirstMB, SliceAddressBits: Integer;
  Skipped, Intra, AC: Boolean;
begin
  Result.Width := Header.Width;
  Result.Height := Header.Height;
  Columns := (Header.Width + 15) div 16;
  Rows := (Header.Height + 15) div 16;
  if Header.H263 then
  begin
    // H.263 predicts within the coded macroblock raster, including its padding.
    Result.Width := Columns * 16;
    Result.Height := Rows * 16;
  end;
  if (Header.PictureType <> 0) and ((Reference.Width <> Result.Width) or (Reference.Height <> Result.Height)) then
    raise EPlayerFormat.Create('Missing H.263/Spark reference picture');
  HalfWidth := (Result.Width + 1) div 2;
  HalfHeight := (Result.Height + 1) div 2;
  Inc(Work, 4 * Int64(Result.Width) * Result.Height + Length(Data));
  if Work > WorkLimit then
    raise EPlayerFormat.Create('Video picture decoding work limit');
  SetLength(Result.Y, Result.Width * Result.Height);
  SetLength(Result.Cb, HalfWidth * HalfHeight);
  SetLength(Result.Cr, HalfWidth * HalfHeight);
  SetLength(Predictors, Columns * Rows);
  Bits.Data := Data;
  Bits.Position := Header.BodyBit;
  Quantizer := Header.Quantizer;
  FirstMB := 0;
  GroupSize := Columns;
  if Header.Height > 800 then
    GroupSize := Columns * 4
  else if Header.Height > 400 then
    GroupSize := Columns * 2;
  SliceAddressBits := 0;
  if Header.Slices then
  begin
    SliceAddressBits := AddressBits(Columns * Rows);
    ReadOrderedSlice(Bits, 0, SliceAddressBits, Quantizer);
  end;
  for MB := 0 to High(Predictors) do
  begin
    repeat
      if Header.H263 and (MB > 0) and (Header.Slices or (MB mod GroupSize = 0)) and ReadSegmentStart(Bits) then
      begin
        if Header.Slices then
          ReadOrderedSlice(Bits, MB, SliceAddressBits, Quantizer)
        else
          ReadGOB(Bits, MB div GroupSize, Quantizer);
        FirstMB := MB;
      end;
      Skipped := False;
      if Header.PictureType = 0 then
        Entry := Bits.VLC(SparkIntraMB)
      else
      begin
        Skipped := Bits.Read(1) <> 0;
        if Skipped then
          Entry := 0
        else
          Entry := Bits.VLC(SparkInterMB);
      end;
    until Entry <> SparkMBStuffing;
    Kind := Entry shr 2;
    if Header.H263 and (Kind in [SparkInter4V, SparkInter4VQ]) then
      raise EPlayerUnsupported.Create('H.263 four-vector prediction is unsupported');
    Intra := Kind >= SparkIntra;
    Pattern := 0;
    if not Skipped then
    begin
      Pattern := Bits.VLC(SparkLumaPattern);
      if not Intra then
        Pattern := Pattern xor 15;
      Pattern := (Pattern shl 2) or (Entry and 3);
      if Kind in [SparkInterQ, SparkInter4VQ, SparkIntraQ] then
        Quantizer := EnsureRange(Quantizer + SparkQuantizerDelta[Bits.Read(2)], 1, 31);
    end;
    Vectors := Default(TSparkVectors);
    if not (Intra or Skipped) then
    begin
      for I := 0 to 3 do
      begin
        if (I > 0) and not (Kind in [SparkInter4V, SparkInter4VQ]) then
          Vectors[I] := Vectors[0]
        else
        begin
          Prediction := PredictVector(Predictors, Vectors, MB, Columns, I, FirstMB);
          Vectors[I].X := ((Prediction.X + Bits.VLC(SparkMotion) + 32) and 63) - 32;
          Vectors[I].Y := ((Prediction.Y + Bits.VLC(SparkMotion) + 32) and 63) - 32;
        end;
      end;
    end;
    Predictors[MB] := Vectors;
    Chroma.X := ChromaComponent(Vectors[0].X + Vectors[1].X + Vectors[2].X + Vectors[3].X);
    Chroma.Y := ChromaComponent(Vectors[0].Y + Vectors[1].Y + Vectors[2].Y + Vectors[3].Y);
    X := (MB mod Columns) * 16;
    Y := (MB div Columns) * 16;
    for I := 0 to 5 do
    begin
      ReadBlock(Bits, Header, Quantizer, Intra, Pattern and (32 shr I) <> 0, Coefficients, AC);
      if AC then
      begin
        Inc(Work, 128);
        if Work > WorkLimit then
          raise EPlayerFormat.Create('Video picture decoding work limit');
      end;
      InverseDCT(Coefficients, AC, Samples);
      case I of
        0..3:
          ReconstructBlock(Result.Y, Reference.Y, Result.Width, Result.Height,
            X + (I and 1) * 8, Y + (I shr 1) * 8, Vectors[I], Intra, Header.NoRounding, Samples);
        4:
          ReconstructBlock(Result.Cb, Reference.Cb, HalfWidth, HalfHeight, X div 2, Y div 2, Chroma, Intra, Header.NoRounding, Samples);
        5:
          ReconstructBlock(Result.Cr, Reference.Cr, HalfWidth, HalfHeight, X div 2, Y div 2, Chroma, Intra, Header.NoRounding, Samples);
      end;
    end;
  end;
end;

end.

