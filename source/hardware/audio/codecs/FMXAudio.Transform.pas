unit FMXAudio.Transform;

{$Q-}{$R-}{$POINTERMATH ON}

interface

uses
  System.SysUtils;

type
  TFloatSamples = TArray<Double>;

  TInverseMDCT = class
  private
    FSize, FFFTSize: Integer;
    FReal, FImag, FCos, FSin, FPreCos, FPreSin, FPostCos, FPostSin: TFloatSamples;
    FReverse: TArray<Integer>;
  public
    constructor Create(Size: Integer);
    procedure Execute(const Coefficients: array of Double; Offset: Integer; out Samples: TFloatSamples);
    procedure forward(const Samples: TFloatSamples; out Coefficients: TFloatSamples);
  end;

function AACWindow(Size: Integer; Kaiser: Boolean): TFloatSamples;

implementation

uses
  System.Math;

constructor TInverseMDCT.Create(Size: Integer);
var
  i, j, Bits, k: Integer;
begin
  inherited Create;
  if (Size < 1) or (Size > 8192) then
    raise EArgumentException.Create('Invalid MDCT size');
  k := Size;
  for j in [2, 3, 5] do
    while k mod j = 0 do
      k := k div j;
  if k <> 1 then
    raise EArgumentException.Create('MDCT size requires factors 2, 3 or 5');
  FSize := Size;
  FFFTSize := Size * 2;
  SetLength(FPreCos, Size);
  SetLength(FPreSin, Size);
  SetLength(FPostCos, Size * 2);
  SetLength(FPostSin, Size * 2);
  for i := 0 to Size - 1 do
  begin
    FPreCos[i] := Cos(Pi * i / (2 * Size));
    FPreSin[i] := -Sin(Pi * i / (2 * Size))
  end;
  for i := 0 to Size * 2 - 1 do
  begin
    FPostCos[i] := Cos(Pi * (Size + 2 * i + 1) / (4 * Size));
    FPostSin[i] := Sin(Pi * (Size + 2 * i + 1) / (4 * Size))
  end;
  SetLength(FReal, FFFTSize);
  SetLength(FImag, FFFTSize);
  SetLength(FReverse, FFFTSize);
  SetLength(FCos, FFFTSize);
  SetLength(FSin, FFFTSize);
  Bits := 0;
  i := FFFTSize;
  while i > 1 do
  begin
    Inc(Bits);
    i := i div 2
  end;
  for i := 0 to FFFTSize - 1 do
  begin
    j := i;
    k := 0;
    for var b := 1 to Bits do
    begin
      k := (k shl 1) or (j and 1);
      j := j shr 1
    end;
    FReverse[i] := k;
  end;
  for i := 0 to FFFTSize - 1 do
  begin
    FCos[i] := Cos(2 * Pi * i / FFFTSize);
    FSin[i] := -Sin(2 * Pi * i / FFFTSize)
  end;
end;

procedure TInverseMDCT.Execute(const Coefficients: array of Double; Offset: Integer; out Samples: TFloatSamples);
var
  i, j, Len, HalfLen, Base, k, Step: Integer;
  R, Im, U, V: Double;

  procedure MixedFFT(Input, Stride, Count, Output: Integer);
  var
    Radix, Block, q, k, j, Index, Twiddle: Integer;
    RealValues, ImagValues: array[0..4] of Double;
    R, Im: Double;
  begin
    if Count = 1 then
    begin
      if Input < FSize then
      begin
        FReal[Output] := Coefficients[Offset + Input] * FPreCos[Input];
        FImag[Output] := Coefficients[Offset + Input] * FPreSin[Input];
      end
      else
      begin
        FReal[Output] := 0;
        FImag[Output] := 0;
      end;
      Exit;
    end;
    Radix := 2;
    while Count mod Radix <> 0 do
      Inc(Radix);
    Block := Count div Radix;
    for q := 0 to Radix - 1 do
      MixedFFT(Input + q * Stride, Stride * Radix, Block, Output + q * Block);
    for k := 0 to Block - 1 do
    begin
      for q := 0 to Radix - 1 do
      begin
        RealValues[q] := FReal[Output + q * Block + k];
        ImagValues[q] := FImag[Output + q * Block + k];
      end;
      for j := 0 to Radix - 1 do
      begin
        Index := k + j * Block;
        R := 0;
        Im := 0;
        for q := 0 to Radix - 1 do
        begin
          Twiddle := (q * Index * (FFFTSize div Count)) mod FFFTSize;
          R := R + RealValues[q] * FCos[Twiddle] - ImagValues[q] * FSin[Twiddle];
          Im := Im + RealValues[q] * FSin[Twiddle] + ImagValues[q] * FCos[Twiddle];
        end;
        FReal[Output + Index] := R;
        FImag[Output + Index] := Im;
      end;
    end;
  end;

begin
  if (Offset < 0) or (Length(Coefficients) - Offset < FSize) then
    raise EArgumentException.Create('Truncated MDCT coefficients');
  if FSize = 1 then
  begin
    SetLength(Samples, 2);
    Samples[0] := 0;
    Samples[1] := -Coefficients[Offset];
    Exit
  end;
  if FSize and (FSize - 1) <> 0 then
  begin
    MixedFFT(0, 1, FFFTSize, 0);
    SetLength(Samples, FSize * 2);
    for i := 0 to High(Samples) do
    begin
      j := (FSize div 2 + i) mod FFFTSize;
      Samples[i] := FReal[j] * FPostCos[i] + FImag[j] * FPostSin[i];
    end;
    Exit;
  end;
  FillChar(FReal[0], FFFTSize * SizeOf(Double), 0);
  FillChar(FImag[0], FFFTSize * SizeOf(Double), 0);
  // Odd-frequency DFT samples via pre-rotation and a 2N complex FFT.
  // Replaces the sparse 8N transform without changing IMDCT normalization.
  for i := 0 to FSize - 1 do
  begin
    j := FReverse[i];
    R := Coefficients[Offset + i];
    FReal[j] := R * FPreCos[i];
    FImag[j] := R * FPreSin[i];
  end;
  Len := 2;
  while Len <= FFFTSize do
  begin
    HalfLen := Len div 2;
    Step := FFFTSize div Len;
    Base := 0;
    while Base < FFFTSize do
    begin
      for j := 0 to HalfLen - 1 do
      begin
        i := Base + j;
        k := j * Step;
        R := FCos[k] * FReal[i + HalfLen] - FSin[k] * FImag[i + HalfLen];
        Im := FSin[k] * FReal[i + HalfLen] + FCos[k] * FImag[i + HalfLen];
        U := FReal[i];
        V := FImag[i];
        FReal[i] := U + R;
        FImag[i] := V + Im;
        FReal[i + HalfLen] := U - R;
        FImag[i + HalfLen] := V - Im;
      end;
      Inc(Base, Len);
    end;
    Len := Len * 2;
  end;
  SetLength(Samples, FSize * 2);
  for i := 0 to High(Samples) do
  begin
    j := (FSize div 2 + i) and (FFFTSize - 1);
    Samples[i] := FReal[j] * FPostCos[i] + FImag[j] * FPostSin[i];
  end;
end;

procedure TInverseMDCT.forward(const Samples: TFloatSamples; out Coefficients: TFloatSamples);
var
  Folded, Transformed: TFloatSamples;
  Half: Integer;
begin
  if Length(Samples) <> FSize * 2 then
    raise EArgumentException.Create('Invalid forward MDCT sample count');
  Half := FSize div 2;
  SetLength(Folded, FSize);
  for var n := 0 to Half - 1 do
  begin
    Folded[n] := -Samples[3 * Half - 1 - n] - Samples[3 * Half + n];
    Folded[Half + n] := Samples[n] - Samples[FSize - 1 - n];
  end;
  Execute(Folded, 0, Transformed);
  SetLength(Coefficients, FSize);
  for var k := 0 to Half - 1 do
  begin
    Coefficients[k] := -Transformed[3 * Half - 1 - k];
    Coefficients[Half + k] := Transformed[k];
  end;
end;

function AACWindow(Size: Integer; Kaiser: Boolean): TFloatSamples;
var
  i, k: Integer;
  Sum, Weight, Term, Z, Alpha: Double;
begin
  SetLength(Result, Size);
  if not Kaiser then
  begin
    for i := 0 to Size - 1 do
      Result[i] := Sin(Pi * (i + 0.5) / (Size * 2));
    Exit;
  end;
  if Size <= 128 then
    Alpha := 6
  else
    Alpha := 4;
  Sum := 0;
  for i := 0 to Size do
  begin
    Z := Pi * Alpha * Sqrt(Max(0.0, 1 - Sqr(2 * i / Size - 1)));
    Weight := 1;
    Term := 1;
    for k := 1 to 60 do
    begin
      Term := Term * Sqr(Z / (2 * k));
      Weight := Weight + Term;
      if Term < Weight * 1E-15 then
        Break;
    end;
    Sum := Sum + Weight;
    if i < Size then
      Result[i] := Sum;
  end;
  for i := 0 to Size - 1 do
    Result[i] := Sqrt(Result[i] / Sum);
end;

end.

