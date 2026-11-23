unit Flash.Filters;

interface

uses
  SWF.Reader, Media.Image.PixelBuffer;

const
  FlashRenderWorkLimit = 20000000;

type
  TFlashChargeWork = procedure(Count: Integer) of object;

function HasFlashFilters(const Filters: TSWFFilters): Boolean;

function HasFlashDisplacement(const Filters: TSWFFilters): Boolean;

procedure FlashFilterPadding(const Filters: TSWFFilters; out X, Y: Integer; IncludeConvolutionSamples: Boolean = False);

procedure ApplyFlashFilters(var Pixels: TArray<Cardinal>; Width, Height: Integer; const Content: TSWFRect; const Filters: TSWFFilters; var Work: Int64; FilterTransparent: Boolean = False);

function FlashBitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect;

procedure ApplyFlashBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter; Charge: TFlashChargeWork);

implementation

uses
  System.Math;

const
  GradientEffects =[ sfGradientGlow,  sfGradientBevel];
  BevelEffects =[ sfBevel,  sfGradientBevel];
  OffsetEffects =[ sfDropShadow,  sfBevel,  sfGradientGlow,  sfGradientBevel];
  BlurredEffects =[ sfBlur,  sfGlow,  sfDropShadow,  sfBevel,  sfGradientGlow,  sfGradientBevel];

type
  TGradientRamp = array[0..255] of Cardinal;

function FilterEnabled(const Filter: TSWFFilter): Boolean;
const
  Identity: array[0..19] of Single = (1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0);
var
  I: Integer;
begin
  case Filter.Kind of
    sfBlur:
      Result := (Filter.Passes > 0) and ((Filter.BlurX > 1) or (Filter.BlurY > 1));
    sfGlow, sfDropShadow, sfBevel:
      Result := True;
    sfGradientGlow, sfGradientBevel:
      Result := (Filter.GradientCount <> 0) and (Filter.Strength > 0);
    sfConvolution:
      Result := (Filter.MatrixX <> 0) and (Filter.MatrixY <> 0);
    sfDisplacementMap:
      Result := (Filter.MapBitmap <> nil) and not Filter.MapBitmap.Disposed and
        ((Filter.MapScaleX <> 0) or (Filter.MapScaleY <> 0));
    sfColorMatrix:
      begin
        for I := 0 to High(Identity) do
          if IsNan(Filter.Matrix[I]) or (Filter.Matrix[I] <> Identity[I]) then
            Exit(True);
        Result := False;
      end;
  else
    Result := False;
  end;
end;

function HasFlashFilters(const Filters: TSWFFilters): Boolean;
var
  Filter: TSWFFilter;
begin
  for Filter in Filters do
    if FilterEnabled(Filter) then
      Exit(True);
  Result := False;
end;

function HasFlashDisplacement(const Filters: TSWFFilters): Boolean;
var
  Filter: TSWFFilter;
begin
  for Filter in Filters do
    if (Filter.Kind = sfDisplacementMap) and FilterEnabled(Filter) then
      Exit(True);
  Result := False;
end;

function BlurRadius(Blur: Double): Double;
begin
  Result := Max(0.0, (Min(255.0, Blur) - 1) / 2);
end;

procedure FlashFilterPadding(const Filters: TSWFFilters; out X, Y: Integer; IncludeConvolutionSamples: Boolean);
var
  Filter: TSWFFilter;
  PadX, PadY: Int64;
begin
  PadX := 0;
  PadY := 0;
  for Filter in Filters do
    if (Filter.Kind in BlurredEffects) and FilterEnabled(Filter) then
    begin
      Inc(PadX, Ceil(BlurRadius(Filter.BlurX)) * Integer(Filter.Passes));
      Inc(PadY, Ceil(BlurRadius(Filter.BlurY)) * Integer(Filter.Passes));
      if Filter.Kind in OffsetEffects then
      begin
        Inc(PadX, Ceil(Abs(Filter.Distance * Cos(Filter.Angle))));
        Inc(PadY, Ceil(Abs(Filter.Distance * Sin(Filter.Angle))));
      end;
    end
    else if IncludeConvolutionSamples and (Filter.Kind = sfConvolution) and FilterEnabled(Filter) then
    begin
      Inc(PadX, Filter.MatrixX div 2);
      Inc(PadY, Filter.MatrixY div 2);
    end;
  X := Min(Int64(FlashRenderWorkLimit), PadX);
  Y := Min(Int64(FlashRenderWorkLimit), PadY);
end;

procedure ChargeFilterWork(var Work: Int64; Count: Int64);
begin
  Inc(Work, Count);
  if Work > FlashRenderWorkLimit then
    raise ESWFError.Create('Flash frame rendering work limit');
end;

procedure BlurAxis(const Input: TArray<Cardinal>; var Output: TArray<Cardinal>; Lines, Length, LineStride, PixelStride: Integer; Kernel: Double);
const
  ChannelShifts: array[0..3] of Integer = (0, 8, 16, 24);
var
  Sum: array[0..3] of Integer;
  Radius: Double;
  Inner, Weight, Line, Start, Position, I, J, Channel: Integer;
  Divide, Weighted: Int64;
  Left, Right, Old, Added, Color: Cardinal;

  function ReadPixel(At: Integer): Cardinal;
  begin
    if (At < 0) or (At >= Length) then
      Exit(0);
    Result := Input[Start + At * PixelStride];
  end;

begin
  Kernel := Min(Kernel, 255.0);
  Radius := BlurRadius(Kernel);
  Inner := Ceil(Radius) - 1;
  Weight := Floor((Radius - Inner) * 255);
  Divide := Round(Kernel * 65536) * 255;
  for Line := 0 to Lines - 1 do
  begin
    Start := Line * LineStride;
    FillChar(Sum, SizeOf(Sum), 0);
    for I := 0 to Min(Inner, Length - 1) do
    begin
      Color := ReadPixel(I);
      for J := 0 to 3 do
        Inc(Sum[J], (Color shr ChannelShifts[J]) and 255);
    end;
    for Position := 0 to Length - 1 do
    begin
      Left := ReadPixel(Position - Inner - 1);
      Right := ReadPixel(Position + Inner + 1);
      Old := ReadPixel(Position - Inner);
      Added := Right;
      Color := 0;
      for J := 0 to 3 do
      begin
        Weighted := Int64(Sum[J]) * 255 + Integer(((Left shr ChannelShifts[J]) and 255) +
            ((Right shr ChannelShifts[J]) and 255)) * Weight;
        Channel := (Weighted * 65536) div Divide;
        Color := Color or (Cardinal(Channel) shl ChannelShifts[J]);
        Inc(Sum[J], Integer((Added shr ChannelShifts[J]) and 255) -
          Integer((Old shr ChannelShifts[J]) and 255));
      end;
      Output[Start + Position * PixelStride] := Color;
    end;
  end;
end;

function BlurredPixels(const Pixels: TArray<Cardinal>; Width, Height: Integer; const Filter: TSWFFilter; var Work: Int64): TArray<Cardinal>;
var
  Pass, Axis, WorkIndex: Integer;
  Horizontal, Vertical: Boolean;
  Buffers: array[0..1] of TArray<Cardinal>;
begin
  Result := Pixels;
  Horizontal := Filter.BlurX > 1;
  Vertical := Filter.BlurY > 1;
  if (Filter.Passes = 0) or not (Horizontal or Vertical) then
    Exit;
  ChargeFilterWork(Work, Int64(Width) * Height * Filter.Passes * (Ord(Horizontal) + Ord(Vertical)));
  SetLength(Buffers[0], System.Length(Pixels));
  if (Filter.Passes > 1) or (Horizontal and Vertical) then
    SetLength(Buffers[1], System.Length(Pixels));
  WorkIndex := 0;
  for Pass := 1 to Filter.Passes do
    for Axis := 0 to 1 do
    begin
      if Axis = 0 then
      begin
        if not Horizontal then
          Continue;
        BlurAxis(Result, Buffers[WorkIndex], Height, Width, Width, 1, Filter.BlurX);
      end
      else
      begin
        if not Vertical then
          Continue;
        BlurAxis(Result, Buffers[WorkIndex], Width, Height, 1, Width, Filter.BlurY);
      end;
      Result := Buffers[WorkIndex];
      WorkIndex := 1 - WorkIndex;
    end;
end;

function Saturate(Value: Double): Double;
begin
  Result := EnsureRange(Value, 0.0, 1.0);
end;

function ScaleEffect(Base, Color: Cardinal; BaseWeight, EffectAlpha: Double): Cardinal;
var
  Shift, Channel: Integer;
begin
  Result := Cardinal(Round((Base shr 24) * BaseWeight + EffectAlpha * 255)) shl 24;
  for Shift in [0, 8, 16] do
  begin
    Channel := Round(((Base shr Shift) and 255) * BaseWeight + ((Color shr Shift) and 255) * EffectAlpha);
    Result := Result or (Cardinal(Min(Channel, 255)) shl Shift);
  end;
end;

procedure BuildGradientRamp(const Filter: TSWFFilter; out Ramp: TGradientRamp);
var
  Stops: TArray<TSWFGradientStop>;
  Stop, Lower, Upper: TSWFGradientStop;
  I, J, Ratio, Shift, A, B: Integer;
  Fraction: Double;
begin
  Stops := Copy(Filter.GradientStops, 0, Filter.GradientCount);
  // Keep equal ratios in their original order so they make a sharp transition.
  for I := 1 to High(Stops) do
  begin
    Stop := Stops[I];
    J := I;
    while (J > 0) and (Stops[J - 1].Ratio > Stop.Ratio) do
    begin
      Stops[J] := Stops[J - 1];
      Dec(J);
    end;
    Stops[J] := Stop;
  end;
  I := 0;
  for Ratio := Low(Ramp) to High(Ramp) do
  begin
    while (I < High(Stops)) and (Stops[I + 1].Ratio <= Ratio) do
      Inc(I);
    Lower := Stops[I];
    Ramp[Ratio] := Lower.Color;
    if (Ratio <= Lower.Ratio) or (I = High(Stops)) then
      Continue;
    Upper := Stops[I + 1];
    Fraction := (Ratio - Lower.Ratio) / (Upper.Ratio - Lower.Ratio);
    Ramp[Ratio] := 0;
    for Shift in [0, 8, 16, 24] do
    begin
      A := (Lower.Color shr Shift) and 255;
      B := (Upper.Color shr Shift) and 255;
      Ramp[Ratio] := Ramp[Ratio] or (Cardinal(Round(A + (B - A) * Fraction)) shl Shift);
    end;
  end;
end;

procedure ApplyAlphaEffect(var Pixels: TArray<Cardinal>; Width, Height: Integer; const Content: TSWFRect; const Filter: TSWFFilter; var Work: Int64);
var
  Blurred, Output: TArray<Cardinal>;
  Area: TSWFRect;
  Ramp: TGradientRamp;
  Gradient, Bevel, KeepSource: Boolean;
  X, Y, I, Ratio, LeftDX, LeftDY, RightDX, RightDY: Integer;
  OffsetX, OffsetY, A, BlurAlpha, Intensity, EffectAlpha, BaseWeight, EffectWeight: Double;
  Base, Color: Cardinal;

  function SampleAlpha(SX, SY: Integer): Double;
  begin
    if (SX < 0) or (SY < 0) or (SX >= Width) or (SY >= Height) then
      Exit(0);
    Result := (Blurred[SY * Width + SX] shr 24) / 255.0;
  end;

begin
  Gradient := Filter.Kind in GradientEffects;
  Bevel := Filter.Kind in BevelEffects;
  KeepSource := Filter.CompositeSource and not Filter.Knockout;
  Area.Left := 0;
  Area.Top := 0;
  Area.Right := Width;
  Area.Bottom := Height;
  if Gradient then
  begin
    Area := FlashBitmapFilterRect(Content, Filter);
    Area.Left := Max(0, Area.Left);
    Area.Top := Max(0, Area.Top);
    Area.Right := Min(Width, Area.Right);
    Area.Bottom := Min(Height, Area.Bottom);
    if (Area.Right <= Area.Left) or (Area.Bottom <= Area.Top) then
      Exit;
    ChargeFilterWork(Work, Length(Ramp) + Integer(Filter.GradientCount) * Filter.GradientCount div 2);
    BuildGradientRamp(Filter, Ramp);
  end;
  Blurred := BlurredPixels(Pixels, Width, Height, Filter, Work);
  ChargeFilterWork(Work, Int64(Width) * Height);
  if Gradient then
    Output := Copy(Pixels)
  else
    SetLength(Output, System.Length(Pixels));
  OffsetX := Filter.Distance * Cos(Filter.Angle);
  OffsetY := Filter.Distance * Sin(Filter.Angle);
  LeftDX := Floor(0.5 + OffsetX);
  LeftDY := Floor(0.5 + OffsetY);
  RightDX := Floor(0.5 - OffsetX);
  RightDY := Floor(0.5 - OffsetY);
  for Y := Area.Top to Area.Bottom - 1 do
  begin
    I := Y * Width + Area.Left;
    for X := Area.Left to Area.Right - 1 do
    begin
      Base := Pixels[I];
      A := (Base shr 24) / 255.0;
      BlurAlpha := SampleAlpha(X + RightDX, Y + RightDY);
      Color := Filter.Color;
      if Gradient or Bevel then
      begin
        if Gradient then
        begin
          if Bevel then
          begin
            Intensity := EnsureRange((SampleAlpha(X + LeftDX, Y + LeftDY) - BlurAlpha) * Filter.Strength,
              -1.0, 1.0);
            // Highlight, unlit fill and shadow correspond to 0, 128 and 255.
            if Intensity >= 0 then
              Ratio := 128 - Round(128 * Intensity)
            else
              Ratio := 128 - Round(127 * Intensity);
          end
          else
          begin
            if Filter.Inner and not Filter.OnTop then
              BlurAlpha := 1 - BlurAlpha;
            Ratio := Round(255 * Saturate(BlurAlpha * Filter.Strength));
          end;
          Color := Ramp[Ratio];
          EffectAlpha := (Color shr 24) / 255.0;
        end
        else
        begin
          Intensity := (SampleAlpha(X + LeftDX, Y + LeftDY) - BlurAlpha) * Filter.Strength;
          if Intensity >= 0 then
            Color := Filter.HighlightColor;
          EffectAlpha := Saturate(Abs(Intensity)) * (Color shr 24) / 255.0;
        end;
        if Filter.OnTop then
        begin
          EffectWeight := 1;
          BaseWeight := 1 - EffectAlpha;
        end
        else if Filter.Inner then
        begin
          EffectWeight := A;
          BaseWeight := 1 - EffectAlpha;
        end
        else
        begin
          EffectWeight := 1 - A;
          BaseWeight := 1;
        end;
        if Filter.Knockout or (Gradient and not Filter.CompositeSource) then
          BaseWeight := 0;
      end
      else if Filter.Inner then
      begin
        EffectAlpha := Saturate((1 - BlurAlpha) * Filter.Strength) * (Color shr 24) / 255.0;
        EffectWeight := A;
        BaseWeight := 0;
        if KeepSource then
          BaseWeight := 1 - EffectAlpha;
      end
      else
      begin
        EffectAlpha := Saturate(BlurAlpha * Filter.Strength) * (Color shr 24) / 255.0;
        BaseWeight := 0;
        EffectWeight := 1;
        if Filter.Knockout or Filter.CompositeSource then
          EffectWeight := 1 - A;
        if KeepSource then
          BaseWeight := 1;
      end;
      Output[I] := ScaleEffect(Base, Color, BaseWeight, EffectAlpha * EffectWeight);
      Inc(I);
    end;
  end;
  Pixels := Output;
end;

procedure ApplyColorMatrix(var Pixels: TArray<Cardinal>; const Filter: TSWFFilter; var Work: Int64; FilterTransparent: Boolean);
var
  I, J, Row, Offset, Alpha: Integer;
  Color: Cardinal;
  Input, Output: array[0..3] of Double;
  Value: Double;
  SafeFilter: TSWFFilter;
begin
  ChargeFilterWork(Work, System.Length(Pixels));
  SafeFilter := Filter;
  // Preserve non-finite entries in AVM1 getters and handle them at pixel evaluation.
  for Row := 0 to 3 do
    for J := Row * 5 to Row * 5 + 4 do
      if IsNan(SafeFilter.Matrix[J]) or IsInfinite(SafeFilter.Matrix[J]) then
      begin
        FillChar(SafeFilter.Matrix[Row * 5], 5 * SizeOf(Single), 0);
        Break;
      end;
  for I := 0 to High(Pixels) do
  begin
    Color := Pixels[I];
    Alpha := Color shr 24;
    if Alpha = 0 then
    begin
      if not FilterTransparent then
        Continue;
      Input[0] := 0;
      Input[1] := 0;
      Input[2] := 0;
    end
    else
    begin
      Input[0] := ((Color shr 16) and 255) * 255.0 / Alpha;
      Input[1] := ((Color shr 8) and 255) * 255.0 / Alpha;
      Input[2] := (Color and 255) * 255.0 / Alpha;
    end;
    Input[3] := Alpha;
    for Row := 0 to 3 do
    begin
      Offset := Row * 5;
      Value := SafeFilter.Matrix[Offset + 4];
      for J := 0 to 3 do
        Value := Value + SafeFilter.Matrix[Offset + J] * Input[J];
      Output[Row] := EnsureRange(Value, 0.0, 255.0);
    end;
    Value := Output[3] / 255.0;
    Pixels[I] := (Cardinal(Round(Output[3])) shl 24) or
      (Cardinal(Round(Output[0] * Value)) shl 16) or
      (Cardinal(Round(Output[1] * Value)) shl 8) or Cardinal(Round(Output[2] * Value));
  end;
end;

procedure ApplyConvolution(var Pixels: TArray<Cardinal>; Width: Integer; const InputRect, OutputRect: TSWFRect; const Filter: TSWFFilter; var Work: Int64);
type
  TKernelTap = record
    X, Y: Integer;
    Weight: Double;
  end;
var
  Input: TArray<Cardinal>;
  Taps: TArray<TKernelTap>;
  Divisor, Bias, Weight: Double;
  Sums: array[0..3] of Double;
  X, Y, SX, SY, I, J, Index, Count, Alpha: Integer;
  Color: Cardinal;

  function FiniteOrZero(Value: Double): Double;
  begin
    if IsNan(Value) or IsInfinite(Value) then
      Exit(0);
    Result := Value;
  end;

  function Channel(Value: Double): Cardinal;
  begin
    Result := Round(EnsureRange(Value + Bias, 0.0, 255.0));
  end;

begin
  if (OutputRect.Right <= OutputRect.Left) or (OutputRect.Bottom <= OutputRect.Top) then
    Exit;
  Divisor := FiniteOrZero(Filter.Divisor);
  if Divisor = 0 then
    Divisor := 1;
  Bias := FiniteOrZero(Filter.Bias);
  Count := Min(Length(Filter.Kernel), Integer(Filter.MatrixX) * Filter.MatrixY);
  ChargeFilterWork(Work, Count + Int64(Length(Pixels)));
  SetLength(Taps, Count);
  J := 0;
  for I := 0 to Count - 1 do
  begin
    Weight := FiniteOrZero(Filter.Kernel[I]);
    if Weight = 0 then
      Continue;
    Taps[J].X := I mod Filter.MatrixX - Filter.MatrixX div 2;
    Taps[J].Y := I div Filter.MatrixX - Filter.MatrixY div 2;
    Taps[J].Weight := Weight / Divisor;
    Inc(J);
  end;
  Count := J;
  ChargeFilterWork(Work, Int64(OutputRect.Right - OutputRect.Left) *
    (OutputRect.Bottom - OutputRect.Top) * (Count + 1));
  Input := Copy(Pixels);
  for Y := InputRect.Top to InputRect.Bottom - 1 do
    for X := InputRect.Left to InputRect.Right - 1 do
    begin
      Index := Y * Width + X;
      Input[Index] := UnpremultiplyBitmapColor(Input[Index]);
    end;
  for Y := OutputRect.Top to OutputRect.Bottom - 1 do
    for X := OutputRect.Left to OutputRect.Right - 1 do
    begin
      FillChar(Sums, SizeOf(Sums), 0);
      for I := 0 to Count - 1 do
      begin
        SX := X + Taps[I].X;
        SY := Y + Taps[I].Y;
        if Filter.ClampEdges then
        begin
          SX := EnsureRange(SX, InputRect.Left, InputRect.Right - 1);
          SY := EnsureRange(SY, InputRect.Top, InputRect.Bottom - 1);
        end;
        if (SX >= InputRect.Left) and (SX < InputRect.Right) and
          (SY >= InputRect.Top) and (SY < InputRect.Bottom) then
          Color := Input[SY * Width + SX]
        else
          Color := Filter.Color;
        for J := 0 to 3 do
          Sums[J] := Sums[J] + ((Color shr (J * 8)) and 255) * Taps[I].Weight;
      end;
      Index := Y * Width + X;
      if Filter.PreserveAlpha then
        Alpha := Pixels[Index] shr 24
      else
        Alpha := Channel(Sums[3]);
      Color := (Cardinal(Alpha) shl 24) or (Channel(Sums[2]) shl 16) or
        (Channel(Sums[1]) shl 8) or Channel(Sums[0]);
      Pixels[Index] := PremultiplyBitmapColor(Color, True);
    end;
end;

function DisplacedPixels(const Pixels: TArray<Cardinal>; Stride: Integer; const InputRect, OutputRect: TSWFRect; const Filter: TSWFFilter; var Work: Int64): TArray<Cardinal>;
var
  InputWidth, InputHeight, MapWidth, MapHeight, X, Y, Index: Integer;
  MapX, MapY: Int64;
  SourceX, SourceY, U, V: Double;
  MapColor, EdgeColor: Cardinal;
  Wrap: Boolean;

  function Component(Color: Cardinal; Channel: Integer): Integer;
  begin
    case Channel of
      1:
        Result := (Color shr 16) and 255;
      2:
        Result := (Color shr 8) and 255;
      4:
        Result := Color and 255;
      8:
        Result := Color shr 24;
    else
      Result := 128;
    end;
  end;

  function Coordinate(Value: Double; Extent: Integer): Double;
  begin
    if Wrap then
      Result := Value - Floor(Value / Extent) * Extent
    else
      Result := EnsureRange(Value, 0.0, Extent - 1.0);
  end;

  function NextIndex(Start, Extent: Integer): Integer;
  begin
    Result := Start + 1;
    if Result < Extent then
      Exit;
    if Wrap then
      Result := 0
    else
      Result := Start;
  end;

  function Sample(SX, SY: Double): Cardinal;
  var
    IX, IY, NextX, NextY, Shift: Integer;
    FX, FY, A, B, C, D: Double;
    TL, TR, BL, BR: Cardinal;
  begin
    SX := Coordinate(SX, InputWidth);
    SY := Coordinate(SY, InputHeight);
    IX := Floor(SX);
    IY := Floor(SY);
    FX := SX - IX;
    FY := SY - IY;
    NextX := NextIndex(IX, InputWidth);
    NextY := NextIndex(IY, InputHeight);
    Inc(IX, InputRect.Left);
    Inc(IY, InputRect.Top);
    Inc(NextX, InputRect.Left);
    Inc(NextY, InputRect.Top);
    TL := Pixels[IY * Stride + IX];
    if (FX = 0) and (FY = 0) then
      Exit(TL);
    TR := Pixels[IY * Stride + NextX];
    BL := Pixels[NextY * Stride + IX];
    BR := Pixels[NextY * Stride + NextX];
    Result := 0;
    for Shift in [0, 8, 16, 24] do
    begin
      A := (TL shr Shift) and 255;
      B := (TR shr Shift) and 255;
      C := (BL shr Shift) and 255;
      D := (BR shr Shift) and 255;
      Result := Result or (Cardinal(Round(
          (A + (B - A) * FX) * (1 - FY) + (C + (D - C) * FX) * FY)) shl Shift);
    end;
  end;

begin
  InputWidth := InputRect.Right - InputRect.Left;
  InputHeight := InputRect.Bottom - InputRect.Top;
  MapWidth := Filter.MapBitmap.Width;
  MapHeight := Filter.MapBitmap.Height;
  Wrap := Filter.MapMode = dmWrap;
  EdgeColor := PremultiplyBitmapColor(Filter.Color, True);
  ChargeFilterWork(Work, 2 * Int64(OutputRect.Right - OutputRect.Left) * (OutputRect.Bottom - OutputRect.Top));
  SetLength(Result, (OutputRect.Right - OutputRect.Left) * (OutputRect.Bottom - OutputRect.Top));
  Index := 0;
  for Y := OutputRect.Top to OutputRect.Bottom - 1 do
  begin
    SourceY := Y - InputRect.Top;
    MapY := Int64(Y) - InputRect.Top - Filter.MapY;
    for X := OutputRect.Left to OutputRect.Right - 1 do
    begin
      SourceX := X - InputRect.Left;
      MapX := Int64(X) - InputRect.Left - Filter.MapX;
      if (MapX < 0) or (MapX >= MapWidth) or (MapY < 0) or (MapY >= MapHeight) then
        Result[Index] := Pixels[Y * Stride + X]
      else
      begin
        MapColor := Filter.MapBitmap.PixelPremultiplied(Integer(MapX), Integer(MapY));
        U := SourceX + (Component(MapColor, Filter.ComponentX) - 128) * Filter.MapScaleX / 256.0;
        V := SourceY + (Component(MapColor, Filter.ComponentY) - 128) * Filter.MapScaleY / 256.0;
        // The bounds test is on pixel centers, before interpolation.
        if (Filter.MapMode in [dmColor, dmIgnore]) and
          ((U < -0.5) or (U > InputWidth - 0.5) or (V < -0.5) or (V > InputHeight - 0.5)) then
        begin
          if Filter.MapMode = dmColor then
            Result[Index] := EdgeColor
          else
            Result[Index] := Pixels[Y * Stride + X];
        end
        else
          Result[Index] := Sample(U, V);
      end;
      Inc(Index);
    end;
  end;
end;

procedure ApplyFlashFilters(var Pixels: TArray<Cardinal>; Width, Height: Integer; const Content: TSWFRect; const Filters: TSWFFilters; var Work: Int64; FilterTransparent: Boolean);
var
  Filter: TSWFFilter;
  Bounds, Clipped: TSWFRect;
  Output: TArray<Cardinal>;
  Row, RowWidth: Integer;
begin
  Bounds := Content;
  for Filter in Filters do
    if FilterEnabled(Filter) then
    begin
      case Filter.Kind of
        sfBlur:
          Pixels := BlurredPixels(Pixels, Width, Height, Filter, Work);
        sfDropShadow, sfGlow, sfBevel, sfGradientGlow, sfGradientBevel:
          ApplyAlphaEffect(Pixels, Width, Height, Bounds, Filter, Work);
        sfColorMatrix:
          ApplyColorMatrix(Pixels, Filter, Work, FilterTransparent);
        sfConvolution, sfDisplacementMap:
          begin
            Clipped.Left := Max(0, Bounds.Left);
            Clipped.Top := Max(0, Bounds.Top);
            Clipped.Right := Min(Width, Bounds.Right);
            Clipped.Bottom := Min(Height, Bounds.Bottom);
            if Filter.Kind = sfConvolution then
              ApplyConvolution(Pixels, Width, Clipped, Clipped, Filter, Work)
            else if (Clipped.Right > Clipped.Left) and (Clipped.Bottom > Clipped.Top) then
            begin
              Output := DisplacedPixels(Pixels, Width, Clipped, Clipped, Filter, Work);
              RowWidth := Clipped.Right - Clipped.Left;
              for Row := Clipped.Top to Clipped.Bottom - 1 do
                Move(Output[(Row - Clipped.Top) * RowWidth], Pixels[Row * Width + Clipped.Left],
                  RowWidth * SizeOf(Cardinal));
            end;
          end;
      end;
      Bounds := FlashBitmapFilterRect(Bounds, Filter);
    end;
end;

function FlashBitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect;
var
  PadX, PadY, DX, DY: Integer;
begin
  Result := Rect;
  if (Rect.Right <= Rect.Left) or (Rect.Bottom <= Rect.Top) then
    Exit;
  if not (Filter.Kind in BlurredEffects) then
    Exit;
  if (Filter.Kind in GradientEffects) and not FilterEnabled(Filter) then
    Exit;
  if Filter.Inner and not Filter.OnTop then
    Exit;
  PadX := Ceil(BlurRadius(Filter.BlurX)) * Integer(Filter.Passes);
  PadY := Ceil(BlurRadius(Filter.BlurY)) * Integer(Filter.Passes);
  DX := 0;
  DY := 0;
  if Filter.Kind in OffsetEffects then
  begin
    DX := -Floor(0.5 - Filter.Distance * Cos(Filter.Angle));
    DY := -Floor(0.5 - Filter.Distance * Sin(Filter.Angle));
    if Filter.Kind in BevelEffects then
    begin
      Inc(PadX, Ceil(Abs(Filter.Distance * Cos(Filter.Angle))));
      Inc(PadY, Ceil(Abs(Filter.Distance * Sin(Filter.Angle))));
      DX := 0;
      DY := 0;
    end;
  end;
  Result.Left := Max(Int64(Low(Integer)), Int64(Rect.Left) + Min(0, DX - PadX));
  Result.Top := Max(Int64(Low(Integer)), Int64(Rect.Top) + Min(0, DY - PadY));
  Result.Right := Min(Int64(High(Integer)), Int64(Rect.Right) + Max(0, DX + PadX));
  Result.Bottom := Min(Int64(High(Integer)), Int64(Rect.Bottom) + Max(0, DY + PadY));
end;

procedure ApplyFlashBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter; Charge: TFlashChargeWork);
var
  SourceArea, Output, InputRaster, OutputRaster: TSWFRect;
  Filters: TSWFFilters;
  Pixels: TArray<Cardinal>;
  DeltaX, DeltaY, Left, Top, Right, Bottom, Count, Work: Int64;
  PadX, PadY, SourceX, SourceY, Width, Height, Row, Column, Index: Integer;
begin
  SourceArea.Left := Max(0, Rect.Left);
  SourceArea.Top := Max(0, Rect.Top);
  SourceArea.Right := Min(Source.Width, Rect.Right);
  SourceArea.Bottom := Min(Source.Height, Rect.Bottom);
  if (SourceArea.Right <= SourceArea.Left) or (SourceArea.Bottom <= SourceArea.Top) then
    Exit;
  Output := FlashBitmapFilterRect(SourceArea, Filter);
  DeltaX := Int64(X) - Rect.Left;
  DeltaY := Int64(Y) - Rect.Top;
  Left := Max(Int64(0), Int64(Output.Left) + DeltaX);
  Top := Max(Int64(0), Int64(Output.Top) + DeltaY);
  Right := Min(Int64(Dest.Width), Int64(Output.Right) + DeltaX);
  Bottom := Min(Int64(Dest.Height), Int64(Output.Bottom) + DeltaY);
  if (Right <= Left) or (Bottom <= Top) then
    Exit;
  Work := 0;
  if (Filter.Kind = sfDisplacementMap) and FilterEnabled(Filter) then
  begin
    InputRaster.Left := 0;
    InputRaster.Top := 0;
    InputRaster.Right := Source.Width;
    InputRaster.Bottom := Source.Height;
    OutputRaster.Left := Left - DeltaX;
    OutputRaster.Top := Top - DeltaY;
    OutputRaster.Right := Right - DeltaX;
    OutputRaster.Bottom := Bottom - DeltaY;
    Pixels := DisplacedPixels(Source.SnapshotPremultiplied, Source.Width, InputRaster, OutputRaster, Filter, Work);
    Width := OutputRaster.Right - OutputRaster.Left;
    PadX := 0;
    PadY := 0;
  end
  else
  begin
    Filters := [Filter];
    FlashFilterPadding(Filters, PadX, PadY, True);
    Width := Right - Left + 2 * PadX;
    Height := Bottom - Top + 2 * PadY;
    Count := Int64(Width) * Height;
    ChargeFilterWork(Work, Count);
    SetLength(Pixels, Count);
    SourceX := Left - DeltaX - PadX;
    SourceY := Top - DeltaY - PadY;
    Index := 0;
    for Row := 0 to Height - 1 do
      for Column := 0 to Width - 1 do
      begin
        Pixels[Index] := Source.PixelPremultiplied(SourceX + Column, SourceY + Row);
        Inc(Index);
      end;
    OutputRaster.Left := PadX;
    OutputRaster.Top := PadY;
    OutputRaster.Right := Width - PadX;
    OutputRaster.Bottom := Height - PadY;
    if (Filter.Kind = sfConvolution) and FilterEnabled(Filter) then
    begin
      InputRaster.Left := Max(0, -SourceX);
      InputRaster.Top := Max(0, -SourceY);
      InputRaster.Right := Min(Width, Source.Width - SourceX);
      InputRaster.Bottom := Min(Height, Source.Height - SourceY);
      ApplyConvolution(Pixels, Width, InputRaster, OutputRaster, Filter, Work);
    end
    else
    begin
      InputRaster.Left := SourceArea.Left - SourceX;
      InputRaster.Top := SourceArea.Top - SourceY;
      InputRaster.Right := SourceArea.Right - SourceX;
      InputRaster.Bottom := SourceArea.Bottom - SourceY;
      ApplyFlashFilters(Pixels, Width, Height, InputRaster, Filters, Work, True);
    end;
  end;
  if Assigned(Charge) then
    Charge(1 + Integer((Work - 1) div 32));
  // The working raster is complete before writing, including overlapping self-copies.
  for Row := 0 to Integer(Bottom - Top) - 1 do
  begin
    Index := (Row + PadY) * Width + PadX;
    for Column := 0 to Integer(Right - Left) - 1 do
      Dest.SetPixelPremultiplied(Integer(Left) + Column, Integer(Top) + Row, Pixels[Index + Column]);
  end;
end;

end.

