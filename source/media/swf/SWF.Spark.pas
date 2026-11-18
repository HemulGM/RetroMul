unit SWF.Spark;

interface

uses
  System.SysUtils, Media.Image.PixelBuffer;

type
  TSparkHeader = record
    Width, Height, Version, PictureType, Quantizer, BodyBit: Integer;
    Deblock: Boolean;
  end;

  TSparkFrame = record
    Width, Height: Integer;
    Y, Cb, Cr: TBytes;
  end;

function ReadSparkHeader(const Data: TBytes; Offset: Integer; out Header: TSparkHeader): Boolean;

function DecodeSpark(const Data: TBytes; const Header: TSparkHeader; const Reference: TSparkFrame; var Work: Int64; WorkLimit: Integer): TSparkFrame;

procedure PublishSpark(const Frame: TSparkFrame; Quantizer: Integer; Deblock: Boolean; const Bitmap: IImagePixelBuffer);

implementation

uses
  System.Math, SWF.Reader, SWF.Spark.Tables;

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
  SparkDeblockStrength: array[0..31] of Byte = (
    0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 11, 11, 11, 12, 12, 12);

function TSparkBits.Read(Count: Integer): Integer;
var
  ByteIndex, BitIndex, Step: Integer;
begin
  if Count > Length(Data) * 8 - Position then
    raise ESWFError.Create('Truncated Sorenson Spark picture');
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
    raise ESWFError.Create('Invalid Sorenson Spark VLC');
end;

function ReadSparkHeader(const Data: TBytes; Offset: Integer; out Header: TSparkHeader): Boolean;
var
  Bits: TSparkBits;
  Format, SizeBits: Integer;
begin
  Header := Default(TSparkHeader);
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
    on E: ESWFError do
      Result := False;
  end;
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

function PredictVector(const Previous: TArray<TSparkVectors>; const Current: TSparkVectors; MB, Columns, Block: Integer): TSparkVector;
var
  A, B, C: TSparkVector;
  Col: Integer;
begin
  Col := MB mod Columns;
  if Odd(Block) then
    A := Current[Block - 1]
  else if Col > 0 then
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
    if MB < Columns then
      B := A
    else
      B := Previous[MB - Columns][Block + 2];
    if Col = Columns - 1 then
      C := Default(TSparkVector)
    else if MB < Columns then
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

procedure ReadBlock(var Bits: TSparkBits; const Header: TSparkHeader; Quantizer: Integer; Intra, Coded: Boolean; out Coefficients: TSparkBlock; out AC: Boolean);
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
      raise ESWFError.Create('Invalid Sorenson Spark intra DC value');
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
      if Level = 0 then
        raise ESWFError.Create('Zero Sorenson Spark escaped coefficient');
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
      raise ESWFError.Create('Sorenson Spark coefficient run exceeds block');
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

procedure ReconstructBlock(var Plane: TBytes; const Reference: TBytes; Width, Height, X, Y: Integer; const Vector: TSparkVector; Intra: Boolean; const Samples: TSparkBlock);
var
  Row, Col, Dest, SrcX, SrcY, DX, DY, X0, X1, Y0, Y1, FractionX, FractionY, Prediction: Integer;
begin
  DX := HalfFloor(Vector.X);
  DY := HalfFloor(Vector.Y);
  FractionX := Vector.X and 1;
  FractionY := Vector.Y and 1;
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
            Reference[Y1 + X0] + Reference[Y1 + X1] + 2) div 4;
        end;
      end;
      Plane[Dest + Col] := ClipByte(Prediction + Samples[Row * 8 + Col]);
    end;
  end;
end;

function DecodeSpark(const Data: TBytes; const Header: TSparkHeader; const Reference: TSparkFrame; var Work: Int64; WorkLimit: Integer): TSparkFrame;
var
  Bits: TSparkBits;
  Predictors: TArray<TSparkVectors>;
  Vectors: TSparkVectors;
  Chroma, Prediction: TSparkVector;
  Coefficients, Samples: TSparkBlock;
  Columns, Rows, MB, Entry, Kind, Pattern, Quantizer, I, X, Y, HalfWidth, HalfHeight: Integer;
  Skipped, Intra, AC: Boolean;
begin
  if (Header.PictureType <> 0) and ((Reference.Width <> Header.Width) or (Reference.Height <> Header.Height)) then
    raise ESWFError.Create('Missing Sorenson Spark reference picture');
  Result.Width := Header.Width;
  Result.Height := Header.Height;
  HalfWidth := (Header.Width + 1) div 2;
  HalfHeight := (Header.Height + 1) div 2;
  Columns := (Header.Width + 15) div 16;
  Rows := (Header.Height + 15) div 16;
  Inc(Work, 4 * Int64(Header.Width) * Header.Height + Length(Data));
  if Work > WorkLimit then
    raise ESWFError.Create('Flash video decoding work limit');
  SetLength(Result.Y, Result.Width * Result.Height);
  SetLength(Result.Cb, HalfWidth * HalfHeight);
  SetLength(Result.Cr, HalfWidth * HalfHeight);
  SetLength(Predictors, Columns * Rows);
  Bits.Data := Data;
  Bits.Position := Header.BodyBit;
  Quantizer := Header.Quantizer;
  for MB := 0 to High(Predictors) do
  begin
    repeat
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
          Prediction := PredictVector(Predictors, Vectors, MB, Columns, I);
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
          raise ESWFError.Create('Flash video decoding work limit');
      end;
      InverseDCT(Coefficients, AC, Samples);
      case I of
        0..3:
          ReconstructBlock(Result.Y, Reference.Y, Header.Width, Header.Height,
            X + (I and 1) * 8, Y + (I shr 1) * 8, Vectors[I], Intra, Samples);
        4:
          ReconstructBlock(Result.Cb, Reference.Cb, HalfWidth, HalfHeight, X div 2, Y div 2, Chroma, Intra, Samples);
        5:
          ReconstructBlock(Result.Cr, Reference.Cr, HalfWidth, HalfHeight, X div 2, Y div 2, Chroma, Intra, Samples);
      end;
    end;
  end;
end;

procedure FilterPlane(var Plane: TBytes; Width, Height, Strength: Integer);
var
  X, Y: Integer;

  procedure Filter(First, Step: Integer);
  var
    A, B, C, D, Delta, Ramp, Adjustment: Integer;
  begin
    A := Plane[First];
    B := Plane[First + Step];
    C := Plane[First + 2 * Step];
    D := Plane[First + 3 * Step];
    Delta := (A - 4 * B + 4 * C - D) div 8;
    Ramp := Max(0, Min(Abs(Delta), 2 * Strength - Abs(Delta)));
    if Delta < 0 then
      Ramp := -Ramp;
    Adjustment := EnsureRange((A - D) div 4, -Abs(Ramp div 2), Abs(Ramp div 2));
    Plane[First] := Byte(A - Adjustment);
    Plane[First + Step] := ClipByte(B + Ramp);
    Plane[First + 2 * Step] := ClipByte(C - Ramp);
    Plane[First + 3 * Step] := Byte(D + Adjustment);
  end;

begin
  Y := 8;
  while Y <= Height - 2 do
  begin
    for X := 0 to Width - 1 do
      Filter((Y - 2) * Width + X, Width);
    Inc(Y, 8);
  end;
  X := 8;
  while X <= Width - 2 do
  begin
    for Y := 0 to Height - 1 do
      Filter(Y * Width + X - 2, 1);
    Inc(X, 8);
  end;
end;

procedure PublishSpark(const Frame: TSparkFrame; Quantizer: Integer; Deblock: Boolean; const Bitmap: IImagePixelBuffer);
var
  YPlane, CbPlane, CrPlane: TBytes;
  X, Y, ChromaIndex, Gray, Cb, Cr, R, G, B, HalfWidth, HalfHeight: Integer;
begin
  HalfWidth := (Frame.Width + 1) div 2;
  HalfHeight := (Frame.Height + 1) div 2;
  YPlane := Frame.Y;
  CbPlane := Frame.Cb;
  CrPlane := Frame.Cr;
  if Deblock then
  begin
    YPlane := Copy(YPlane);
    CbPlane := Copy(CbPlane);
    CrPlane := Copy(CrPlane);
    FilterPlane(YPlane, Frame.Width, Frame.Height, SparkDeblockStrength[Quantizer]);
    FilterPlane(CbPlane, HalfWidth, HalfHeight, SparkDeblockStrength[Quantizer]);
    FilterPlane(CrPlane, HalfWidth, HalfHeight, SparkDeblockStrength[Quantizer]);
  end;
  for Y := 0 to Frame.Height - 1 do
    for X := 0 to Frame.Width - 1 do
    begin
      ChromaIndex := (Y div 2) * HalfWidth + (X div 2);
      Gray := (Integer(YPlane[Y * Frame.Width + X]) - 16) * 76309 + 32768;
      Cb := Integer(CbPlane[ChromaIndex]) - 128;
      Cr := Integer(CrPlane[ChromaIndex]) - 128;
      R := ClipByte((Gray + 104597 * Cr) div 65536);
      G := ClipByte((Gray - 53279 * Cr - 25675 * Cb) div 65536);
      B := ClipByte((Gray + 132201 * Cb) div 65536);
      Bitmap.SetPixelPremultiplied(X, Y, $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B));
    end;
end;

end.

