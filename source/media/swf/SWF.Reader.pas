unit SWF.Reader;

interface

uses
  System.SysUtils, System.Classes, Media.Image.PixelBuffer;

type
  ESWFError = class(Exception);

  TSWFRect = record
    Left, Right, Top, Bottom: Integer;
  end;

  TSWFColorTransform = record
    Mult: array[0..3] of Double;
    Add: array[0..3] of Integer;
    class function Identity: TSWFColorTransform; static;
    function ThenBy(const Parent: TSWFColorTransform): TSWFColorTransform;
    function Apply(Color: Cardinal): Cardinal;
  end;

  TSWFMatrix = record
    A, B, C, D, TX, TY: Double;
    class function Identity: TSWFMatrix; static;
    function ThenBy(const Parent: TSWFMatrix): TSWFMatrix;
  end;

  TSWFFilterKind = (sfDropShadow, sfBlur, sfGlow, sfBevel, sfGradientGlow,
    sfConvolution, sfColorMatrix, sfGradientBevel, sfDisplacementMap);

  TSWFDisplacementMode = (dmWrap, dmClamp, dmIgnore, dmColor);

  TSWFGradientStop = record
    Ratio: Byte;
    Color: Cardinal;
  end;

  TSWFFilter = record
    Kind: TSWFFilterKind;
    Color, HighlightColor: Cardinal;
    BlurX, BlurY, Angle, Distance, Strength: Double;
    Passes: Byte;
    Inner, Knockout, CompositeSource, OnTop: Boolean;
    Matrix: array[0..19] of Single;
    MatrixX, MatrixY: Byte;
    Kernel: TArray<Single>;
    Divisor, Bias: Single;
    PreserveAlpha, ClampEdges: Boolean;
    GradientCount: Byte;
    GradientStops: TArray<TSWFGradientStop>;
    MapBitmap: IImagePixelBuffer;
    MapX, MapY, ComponentX, ComponentY: Integer;
    MapScaleX, MapScaleY: Single;
    MapMode: TSWFDisplacementMode;
  end;

  TSWFFilters = TArray<TSWFFilter>;

  TSWFReader = class
  private
    FData: TBytes;
    FPosition, FBit: Integer;
    FVersion: Byte;
  public
    constructor Create(const Data: TBytes; Version: Byte = 6);
    procedure Need(Count: Integer);
    procedure Align;
    function U8: Byte;
    function U16: Word;
    function S16: SmallInt;
    function U32: Cardinal;
    function EncodedU32: Cardinal;
    function Bits(Count: Integer): Cardinal;
    function SignedBits(Count: Integer): Integer;
    function Bytes(Count: Integer): TBytes;
    function Str: string;
    function TextBytes(Count: Integer): string;
    function Rect: TSWFRect;
    function Matrix: TSWFMatrix;
    function FilterList: TSWFFilters;
    procedure SkipColorTransform(WithAlpha: Boolean);
    function ColorTransform(WithAlpha: Boolean): TSWFColorTransform;
    property Position: Integer read FPosition;
    function Remaining: Integer;
  end;

function DecodeSWF(const Data: TBytes): TBytes;

function SWFFloat32(Value: Double): Double;

function SWFTwipsFromPixels(Value: Double): Integer;

function SWFRoundCoordinate(Value: Double): Integer;

function SWFMatrixProduct(A, B, C, D: Double): Double;
// Caller must mask floating-point exceptions for the complete calculation.

function SWFMatrixProductMasked(A, B, C, D: Double): Double;

function SWFAddCoordinate(A, B: Integer): Integer;

implementation

uses
  System.ZLib, System.Math, Z7.Archive.Lzma;

function SWFFloat32(Value: Double): Double;
var
  Number: Single;
  Bits: UInt64;
begin
  Move(Value, Bits, 8);
  if (Bits and $7FF0000000000000) = $7FF0000000000000 then
  begin
    if (Bits and $FFFFFFFFFFFFF) <> 0 then
      Exit(NaN);
    Exit(Value);
  end;
  if Value >= 3.4028235677973366e38 then
    Exit(Infinity);
  if Value <= -3.4028235677973366e38 then
    Exit(NegInfinity);
  Number := Value;
  Result := Number;
end;

function TruncatePixelTwips(Value: Double): Integer;
begin
  Result := Trunc(Value);
end;

function SWFTwipsFromPixels(Value: Double): Integer;
begin
  if IsNan(Value) then
    Exit(0);
  if Value >= 107374182.35 then
    Exit(High(Integer));
  if Value <= -107374182.4 then
    Exit(Low(Integer));
  { Passing the product as Double forces binary64 rounding before truncation,
    including on Win32 where x87 otherwise keeps an 80-bit intermediate. }
  Result := TruncatePixelTwips(Value * 20);
end;

function SWFRoundCoordinate(Value: Double): Integer;
begin
  if IsNan(Value) or IsInfinite(Value) then
    Exit(0);
  if Value >= 2147483648.0 then
    Exit(Low(Integer));
  if Value <= -2147483648.0 then
    Exit(Low(Integer));
  Result := Round(Value);
end;

function SWFMatrixProductMasked(A, B, C, D: Double): Double;
var
  Left, Right: Double;
begin
  Left := SWFFloat32(SWFFloat32(A) * SWFFloat32(B));
  Right := SWFFloat32(SWFFloat32(C) * SWFFloat32(D));
  Result := SWFFloat32(Left + Right);
end;

function SWFMatrixProduct(A, B, C, D: Double): Double;
var
  Mask: TArithmeticExceptionMask;
begin
  Mask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Result := SWFMatrixProductMasked(A, B, C, D);
  finally
    ClearExceptions;
    SetExceptionMask(Mask);
  end;
end;

function SWFAddCoordinate(A, B: Integer): Integer;
var
  Bits: Cardinal;
begin
  Bits := Cardinal((Int64(A) + B) and $FFFFFFFF);
  Move(Bits, Result, 4);
end;

class function TSWFColorTransform.Identity: TSWFColorTransform;
begin
  Result := Default(TSWFColorTransform);
  for var I := 0 to 3 do
    Result.Mult[I] := 1;
end;

function TSWFColorTransform.ThenBy(const Parent: TSWFColorTransform): TSWFColorTransform;
var
  I, Bits, ParentBits: Integer;
  ProductValue: Int64;

  function Wrap16(Value: Int64): Integer;
  begin
    Result := Value and $FFFF;
    if Result > 32767 then
      Dec(Result, 65536);
  end;

  function Shift8(Value: Int64): Int64;
  begin
    if Value < 0 then
      Result := -((-Value + 255) div 256)
    else
      Result := Value div 256;
  end;

begin
  { signed 8.8 products and offsets wrap. }
  for I := 0 to 3 do
  begin
    Bits := Trunc(Mult[I] * 256);
    ParentBits := Trunc(Parent.Mult[I] * 256);
    ProductValue := Int64(Bits) * ParentBits;
    Result.Mult[I] := Wrap16(Shift8(ProductValue)) / 256.0;
    Result.Add[I] := Wrap16(Parent.Add[I] + Wrap16(Shift8(Int64(ParentBits) * Add[I])));
  end;
end;

function TSWFColorTransform.Apply(Color: Cardinal): Cardinal;
var
  I, Shift, Channel, Bits: Integer;
  ProductValue: Int64;
begin
  { Preserve fully transparent source pixels }
  if Color shr 24 = 0 then
    Exit(Color);
  Result := 0;
  for I := 0 to 3 do
  begin
    if I = 3 then
      Shift := 24
    else
      Shift := (2 - I) * 8;
    Bits := Trunc(Mult[I] * 256);
    ProductValue := ((Color shr Shift) and 255) * Int64(Bits);
    if ProductValue < 0 then
      ProductValue := -((-ProductValue + 255) div 256)
    else
      ProductValue := ProductValue div 256;
    Channel := EnsureRange(ProductValue + Add[I], Int64(0), Int64(255));
    Result := Result or (Cardinal(Channel) shl Shift);
  end;
end;

class function TSWFMatrix.Identity: TSWFMatrix;
begin
  Result := Default(TSWFMatrix);
  Result.A := 1;
  Result.D := 1;
end;

function TSWFMatrix.ThenBy(const Parent: TSWFMatrix): TSWFMatrix;
var
  X, Y: Double;
  Mask: TArithmeticExceptionMask;
  TranslationsMasked: Boolean;
begin
  Mask := GetExceptionMask;
  TranslationsMasked := Mask = [exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision];
  X := 0;
  Y := 0;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Result.A := SWFMatrixProductMasked(Parent.A, A, Parent.C, B);
    Result.B := SWFMatrixProductMasked(Parent.B, A, Parent.D, B);
    Result.C := SWFMatrixProductMasked(Parent.A, C, Parent.C, D);
    Result.D := SWFMatrixProductMasked(Parent.B, C, Parent.D, D);
    if TranslationsMasked then
    begin
      X := SWFMatrixProductMasked(Parent.A, TX, Parent.C, TY);
      Y := SWFMatrixProductMasked(Parent.B, TX, Parent.D, TY);
    end;
  finally
    ClearExceptions;
    SetExceptionMask(Mask);
  end;
  // Keep the original argument conversion under the caller's FP mask.
  if not TranslationsMasked then
    X := SWFMatrixProduct(Parent.A, SWFFloat32(TX), Parent.C, SWFFloat32(TY));
  Result.TX := SWFAddCoordinate(SWFRoundCoordinate(X), Trunc(Parent.TX));
  if not TranslationsMasked then
    Y := SWFMatrixProduct(Parent.B, SWFFloat32(TX), Parent.D, SWFFloat32(TY));
  Result.TY := SWFAddCoordinate(SWFRoundCoordinate(Y), Trunc(Parent.TY));
end;

constructor TSWFReader.Create(const Data: TBytes; Version: Byte);
begin
  inherited Create;
  FData := Data;
  FVersion := Version;
end;

procedure TSWFReader.Need(Count: Integer);
begin
  if (Count < 0) or (Count > Length(FData) - FPosition) then
    raise ESWFError.Create('Truncated SWF data');
end;

procedure TSWFReader.Align;
begin
  if FBit <> 0 then
  begin
    Inc(FPosition);
    FBit := 0;
  end;
end;

function TSWFReader.U8: Byte;
begin
  Align;
  Need(1);
  Result := FData[FPosition];
  Inc(FPosition);
end;

function TSWFReader.U16: Word;
begin
  Result := U8;
  Result := Result or (Word(U8) shl 8);
end;

function TSWFReader.S16: SmallInt;
var
  V: Word;
begin
  V := U16;
  Move(V, Result, 2);
end;

function TSWFReader.U32: Cardinal;
begin
  Result := U16;
  Result := Result or (Cardinal(U16) shl 16);
end;

function TSWFReader.EncodedU32: Cardinal;
var
  Shift: Integer;
  Part: Byte;
begin
  Result := 0;
  Shift := 0;
  repeat
    Part := U8;
    if (Shift = 28) and (Part > $0F) then
      raise ESWFError.Create('Invalid SWF encoded U32');
    Result := Result or (Cardinal(Part and $7F) shl Shift);
    Inc(Shift, 7);
  until Part < $80;
end;

function TSWFReader.Bits(Count: Integer): Cardinal;
begin
  if (Count < 0) or (Count > 32) then
    raise ESWFError.Create('Invalid SWF bit count');
  Result := 0;
  for var I := 1 to Count do
  begin
    Need(1);
    Result := (Result shl 1) or ((FData[FPosition] shr (7 - FBit)) and 1);
    Inc(FBit);
    if FBit = 8 then
    begin
      FBit := 0;
      Inc(FPosition);
    end;
  end;
end;

function TSWFReader.SignedBits(Count: Integer): Integer;
var
  V: Cardinal;
begin
  V := Bits(Count);
  if (Count > 0) and (Count < 32) and ((V and (Cardinal(1) shl (Count - 1))) <> 0) then
    V := V or (High(Cardinal) shl Count);
  Move(V, Result, 4);
end;

function TSWFReader.Bytes(Count: Integer): TBytes;
begin
  Align;
  Need(Count);
  Result := Copy(FData, FPosition, Count);
  Inc(FPosition, Count);
end;

{ SwfStr permits invalid bytes. UTF-8 with maximal-subpart replacement from SWF6; WINDOWS-1252 before it. }
function DecodeSWFText(const Data: TBytes; Offset, Count: Integer; Version: Byte): string;
const
  Legacy: array[$80..$9F] of Word = (
    $20AC, $0081, $201A, $0192, $201E, $2026, $2020, $2021,
    $02C6, $2030, $0160, $2039, $0152, $008D, $017D, $008F,
    $0090, $2018, $2019, $201C, $201D, $2022, $2013, $2014,
    $02DC, $2122, $0161, $203A, $0153, $009D, $017E, $0178);
var
  I, Last, Used, Remaining, CodePoint, Value, Lower, Upper: Integer;

  procedure Emit(Value: Integer);
  begin
    Inc(Used);
    Result[Used] := Char(Value);
  end;

begin
  SetLength(Result, Count);
  Used := 0;
  I := Offset;
  Last := Offset + Count;
  while I < Last do
  begin
    Value := Data[I];
    Inc(I);
    if Version < 6 then
    begin
      if (Value >= $80) and (Value <= $9F) then
        Emit(Legacy[Value])
      else
        Emit(Value);
      Continue;
    end;
    if Value < $80 then
    begin
      Emit(Value);
      Continue;
    end;
    Lower := $80;
    Upper := $BF;
    if (Value >= $C2) and (Value <= $DF) then
    begin
      Remaining := 1;
      CodePoint := Value and $1F;
    end
    else if (Value >= $E0) and (Value <= $EF) then
    begin
      Remaining := 2;
      CodePoint := Value and $0F;
      if Value = $E0 then
        Lower := $A0
      else if Value = $ED then
        Upper := $9F;
    end
    else if (Value >= $F0) and (Value <= $F4) then
    begin
      Remaining := 3;
      CodePoint := Value and 7;
      if Value = $F0 then
        Lower := $90
      else if Value = $F4 then
        Upper := $8F;
    end
    else
    begin
      Emit($FFFD);
      Continue;
    end;
    while (Remaining > 0) and (I < Last) do
    begin
      Value := Data[I];
      if (Value < Lower) or (Value > Upper) then
        Break;
      Inc(I);
      CodePoint := (CodePoint shl 6) or (Value and $3F);
      Dec(Remaining);
      Lower := $80;
      Upper := $BF;
    end;
    if Remaining > 0 then
      Emit($FFFD)
    else if CodePoint <= $FFFF then
      Emit(CodePoint)
    else
    begin
      Dec(CodePoint, $10000);
      Emit($D800 or (CodePoint shr 10));
      Emit($DC00 or (CodePoint and $3FF));
    end;
  end;
  SetLength(Result, Used);
end;

function TSWFReader.TextBytes(Count: Integer): string;
begin
  Align;
  Need(Count);
  if Count > 1024 * 1024 then
    raise ESWFError.Create('SWF string limit');
  Result := DecodeSWFText(FData, FPosition, Count, FVersion);
  Inc(FPosition, Count);
end;

function TSWFReader.Str: string;
var
  Start: Integer;
begin
  Align;
  Start := FPosition;
  while U8 <> 0 do
    ;
  if FPosition - Start - 1 > 1024 * 1024 then
    raise ESWFError.Create('SWF string limit');
  Result := DecodeSWFText(FData, Start, FPosition - Start - 1, FVersion);
end;

function TSWFReader.Rect: TSWFRect;
var
  N: Integer;
begin
  Align;
  N := Bits(5);
  Result.Left := SignedBits(N);
  Result.Right := SignedBits(N);
  Result.Top := SignedBits(N);
  Result.Bottom := SignedBits(N);
  Align;
end;

function TSWFReader.Matrix: TSWFMatrix;
var
  N: Integer;
begin
  Align;
  Result := TSWFMatrix.Identity;
  if Bits(1) <> 0 then
  begin
    N := Bits(5);
    Result.A := SignedBits(N) / 65536;
    Result.D := SignedBits(N) / 65536;
  end;
  if Bits(1) <> 0 then
  begin
    N := Bits(5);
    Result.B := SignedBits(N) / 65536;
    Result.C := SignedBits(N) / 65536;
  end;
  N := Bits(5);
  Result.TX := SignedBits(N);
  Result.TY := SignedBits(N);
  Align;
end;

procedure TSWFReader.SkipColorTransform(WithAlpha: Boolean);
begin
  ColorTransform(WithAlpha);
end;

function TSWFReader.ColorTransform(WithAlpha: Boolean): TSWFColorTransform;
var
  Add, Mult: Boolean;
  N, Channels: Integer;
begin
  Result := TSWFColorTransform.Identity;
  Align;
  Add := Bits(1) <> 0;
  Mult := Bits(1) <> 0;
  N := Bits(4);
  Channels := 3 + Ord(WithAlpha);
  if Mult then
    for var I := 0 to Channels - 1 do
      Result.Mult[I] := SignedBits(N) / 256;
  if Add then
    for var I := 0 to Channels - 1 do
      Result.Add[I] := SignedBits(N);
  Align;
end;

function TSWFReader.FilterList: TSWFFilters;
var
  I, J, Code, Flags, Count: Integer;
  Bits32: Cardinal;
  Filter: TSWFFilter;

  function Fixed16: Double;
  begin
    Result := Integer(U32) / 65536.0;
  end;

  function RGBA: Cardinal;
  var
    Red, Green, Blue, Alpha: Cardinal;
  begin
    Red := U8;
    Green := U8;
    Blue := U8;
    Alpha := U8;
    Result := (Alpha shl 24) or (Red shl 16) or (Green shl 8) or Blue;
  end;

  procedure ReadFloat(out Value: Single);
  var
    Bits: Cardinal;
  begin
    Bits := U32;
    if (Bits and $7F800000 = $7F800000) and (Bits and $007FFFFF <> 0) then
      Bits := $7FC00000;
    Move(Bits, Value, SizeOf(Value));
  end;

begin
  SetLength(Result, U8);
  for I := 0 to High(Result) do
  begin
    Code := U8;
    if Code > Ord(sfGradientBevel) then
      raise ESWFError.Create('Invalid SWF filter type');
    Filter := Default(TSWFFilter);
    Filter.Kind := TSWFFilterKind(Code);
    case Filter.Kind of
      sfDropShadow, sfGlow, sfBevel:
        begin
          if Filter.Kind = sfBevel then
            Filter.HighlightColor := RGBA;
          Filter.Color := RGBA;
          Filter.BlurX := Fixed16;
          Filter.BlurY := Fixed16;
          if Filter.Kind <> sfGlow then
          begin
            Filter.Angle := Fixed16;
            Filter.Distance := Fixed16;
          end;
          Filter.Strength := S16 / 256.0;
          Flags := U8;
          Filter.Inner := Flags and $80 <> 0;
          Filter.Knockout := Flags and $40 <> 0;
          Filter.CompositeSource := Flags and $20 <> 0;
          if Filter.Kind = sfBevel then
          begin
            Filter.OnTop := Flags and $10 <> 0;
            Filter.Passes := Flags and $0F;
          end
          else
            Filter.Passes := Flags and $1F;
        end;
      sfBlur:
        begin
          Filter.BlurX := Fixed16;
          Filter.BlurY := Fixed16;
          Filter.Passes := U8 shr 3;
        end;
      sfColorMatrix:
        for J := 0 to High(Filter.Matrix) do
        begin
          Bits32 := U32;
          if Bits32 and $7F800000 <> $7F800000 then
            Move(Bits32, Filter.Matrix[J], SizeOf(Single));
        end;
      sfGradientGlow, sfGradientBevel:
        begin
          Filter.GradientCount := U8;
          Need(5 * Integer(Filter.GradientCount) + 19);
          SetLength(Filter.GradientStops, Filter.GradientCount);
          for J := 0 to High(Filter.GradientStops) do
            Filter.GradientStops[J].Color := RGBA;
          for J := 0 to High(Filter.GradientStops) do
            Filter.GradientStops[J].Ratio := U8;
          Filter.BlurX := Fixed16;
          Filter.BlurY := Fixed16;
          Filter.Angle := Fixed16;
          Filter.Distance := Fixed16;
          Filter.Strength := S16 / 256.0;
          Flags := U8;
          Filter.Inner := Flags and $80 <> 0;
          Filter.Knockout := Flags and $40 <> 0;
          Filter.CompositeSource := Flags and $20 <> 0;
          Filter.OnTop := Flags and $10 <> 0;
          Filter.Passes := Flags and $0F;
        end;
      sfConvolution:
        begin
          Filter.MatrixX := U8;
          Filter.MatrixY := U8;
          Count := Integer(Filter.MatrixX) * Filter.MatrixY;
          Need(13 + 4 * Count);
          ReadFloat(Filter.Divisor);
          ReadFloat(Filter.Bias);
          SetLength(Filter.Kernel, Count);
          for J := 0 to Count - 1 do
            ReadFloat(Filter.Kernel[J]);
          Filter.Color := RGBA;
          Flags := U8;
          Filter.PreserveAlpha := Flags and 1 <> 0;
          Filter.ClampEdges := Flags and 2 <> 0;
        end;
    end;
    Result[I] := Filter;
  end;
end;

function TSWFReader.Remaining: Integer;
begin
  Result := Length(FData) - FPosition;
end;

function DecodeSWFLzma(const Data: TBytes; Size: Cardinal): TBytes;
const
  SWFHeaderSize = 8;
  LzmaPropertiesOffset = 12;
  LzmaPropertiesSize = 5;
  PayloadOffset = LzmaPropertiesOffset + LzmaPropertiesSize;
var
  PackedSize: Cardinal;
  Source, Destination: TBytesStream;
begin
  if Length(Data) < PayloadOffset + 5 then
    raise ESWFError.Create('Truncated LZMA SWF header or range stream');
  PackedSize := Cardinal(Data[8]) or (Cardinal(Data[9]) shl 8) or
    (Cardinal(Data[10]) shl 16) or (Cardinal(Data[11]) shl 24);
  if PackedSize <> Cardinal(Length(Data) - PayloadOffset) then
    raise ESWFError.Create('LZMA SWF compressed length mismatch');

  SetLength(Result, Size);
  Move(Data[0], Result[0], SWFHeaderSize);
  Source := TBytesStream.Create(Data);
  try
    Destination := TBytesStream.Create(Result);
    try
      Source.Position := PayloadOffset;
      Destination.Position := SWFHeaderSize;
      try
        DecodeLzma(Source, Destination, PackedSize, Size - SWFHeaderSize,
          Copy(Data, LzmaPropertiesOffset, LzmaPropertiesSize), False, nil);
      except
        on E: ESevenZip do
          raise ESWFError.Create('Invalid LZMA SWF stream: ' + E.Message);
      end;
    finally
      Destination.Free;
    end;
  finally
    Source.Free;
  end;
end;

function DecodeSWF(const Data: TBytes): TBytes;
var
  Size: Cardinal;
  Z: z_stream;
  Status: Integer;
begin
  if (Length(Data) < 8) or (Data[1] <> Ord('W')) or (Data[2] <> Ord('S')) then
    raise ESWFError.Create('Invalid SWF signature');
  Move(Data[4], Size, 4);
  if (Size < 12) or (Size > 64 * 1024 * 1024) then
    raise ESWFError.Create('SWF exceeds 64 MiB or has an invalid size');
  case Data[0] of
    Ord('F'):
      begin
        if Cardinal(Length(Data)) <> Size then
          raise ESWFError.Create('SWF file length mismatch');
        Result := Copy(Data);
      end;
    Ord('C'):
      begin
        SetLength(Result, Size);
        Move(Data[0], Result[0], 8);
        FillChar(Z, SizeOf(Z), 0);
        if inflateInit(Z) <> Z_OK then
          raise ESWFError.Create('Cannot initialize SWF inflater');
        try
          Z.next_in := @Data[8];
          Z.avail_in := Length(Data) - 8;
          Z.next_out := @Result[8];
          Z.avail_out := Size - 8;
          Status := inflate(Z, Z_FINISH);
          if (Status <> Z_STREAM_END) or (Z.total_out <> Size - 8) or (Z.avail_in <> 0) then
            raise ESWFError.Create('Invalid compressed SWF stream');
        finally
          inflateEnd(Z);
        end;
      end;
    Ord('Z'):
      Result := DecodeSWFLzma(Data, Size);
  else
    raise ESWFError.Create('Invalid SWF compression');
  end;
end;

end.

