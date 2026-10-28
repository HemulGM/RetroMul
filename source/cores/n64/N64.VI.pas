unit N64.VI;
// Runs without range and overflow checks (every index is masked and all
// guest arithmetic wraps explicitly); N64_CHECKED builds them in, for the
// tests.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, N64.Types,
  Core.Snapshots;

type
  TN64VIPixel = record
    R, G, B, Coverage: Integer;
  end;

  // The active analogue raster is independent of the RDRAM framebuffer stride.
  // All colour filtering and 10-bit source addressing use integer arithmetic.
  TN64VI = class
  private
    const
      Slots = 8;
  private
    FBus: TN64Bus;
    FRandom: Cardinal;
    // Triple-buffered weave: FBuffers[FFront] is the persistent raster (the
    // snapshot state) and the frame most recently returned by Render. The
    // next field is composed in the oldest buffer, the one after it, which
    // then becomes the front: with VI fields in two slots the console still
    // holds the frame before the front (CompleteVISlot), and a buffer held
    // would be copied (SetLength), a memory manager call for each field.
    FBuffers: array[0..2] of TArray<TAlphaColor>;
    FFront: Integer;
    FWidth, FHeight: Integer;
    FLastField: Integer;
    // Per-render fetch state; not part of the snapshot.
    FOrigin, FStride, FPixelType, FAAMode, FStatus, FFetchState: Integer;
    // Whole filtered (and, with divot, divot-filtered) source rows per slot,
    // keyed by row and fetch state. Linear indices may cross rows, so a row is
    // located by floor division; consecutive rows never share a slot.
    FSlotRow, FSlotState: array[0..Slots - 1] of Integer;
    FSlotFiltered, FSlotDivot: array[0..Slots - 1] of Boolean;
    FFilteredRows, FDivotRows: array[0..Slots - 1] of TArray<TN64VIPixel>;
    // Raw pixels of the rows around one being filtered (see FilteredSlot).
    FWindow: TArray<TN64VIPixel>;
    FColumnR, FColumnG, FColumnB: TArray<Integer>;
    function Random: Cardinal;
    function Raw(Index: Integer): TN64VIPixel;
    procedure DecodeWindow(First, Count: Integer);
    function FilteredSlot(Row: Integer): Integer;
    function DivotSlot(Row: Integer): Integer;
    function RowPixels(Row: Integer): TArray<TN64VIPixel>;
    procedure ComposeRow(const Weave: TArray<TAlphaColor>; const ColumnR, ColumnG, ColumnB: TArray<Integer>; OutputIndex, Width, FirstSample, LastSample, XStart, XStep, FirstColumn: Integer; Progressive: Boolean);
  public
    constructor Create(Bus: TN64Bus);
    procedure Reset;
    // Pixels stays unchanged for the next two Renders. A consumer that still
    // holds it then gets a private copy (SetLength copy-on-write).
    procedure Render(const Registers: array of Cardinal; out Width, Height: Integer; out Pixels: TArray<TAlphaColor>);
    // The RDRAM bytes Render(Registers) may read (more, not fewer): Count
    // from Address, within RDRAM. False: it reads none.
    class function SourceSpan(const Registers: array of Cardinal; out Address, Count: Cardinal): Boolean; static;
    // The bus Render reads RDRAM from.
    property Source: TN64Bus read FBus write FBus;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

function FloorShift(Value: Integer; Count: Integer): Integer; inline;
begin
  // Floor division by 2^Count (Count <= 24); the logical shift only sees
  // non-negative values. The filters' values are small: the bias keeps them
  // non-negative without a branch on their sign.
  if Value >= -$1000000 then
    Result := ((Value + $1000000) shr Count) - ($1000000 shr Count)
  else
    Result := not ((not Value) shr Count);
end;

function IntegerSqrt(Value: Cardinal): Cardinal;
begin
  Result := 0;
  var Bit: Cardinal := 1 shl 30;
  while Bit > Value do
    Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Value >= Result + Bit then
    begin
      Dec(Value, Result + Bit);
      Inc(Result, Bit * 2);
    end;
    Result := Result shr 1;
    Bit := Bit shr 2;
  end;
end;

var
  // Gamma: GammaTable[V] = IntegerSqrt(V) * 2 for V = channel * 64 + dither.
  GammaTable: array[0..16383] of Byte;

function Median(A, B, C: Integer): Integer; inline;
begin
  Result := Max(Min(A, B), Min(Max(A, B), C));
end;

function FloorDivide(Value, Divisor: Integer): Integer; inline;
begin
  // Divisor > 0. Row of a linear framebuffer index, rounding towards minus infinity.
  Result := Value div Divisor;
  if (Value < 0) and (Result * Divisor <> Value) then
    Dec(Result);
end;

constructor TN64VI.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  Reset;
end;

procedure TN64VI.Reset;
begin
  FRandom := 3;
  FBuffers[0] := nil;
  FBuffers[1] := nil;
  FBuffers[2] := nil;
  FFront := 0;
  FWidth := 0;
  FHeight := 0;
  FLastField := -1;
end;

function TN64VI.Random: Cardinal;
begin
  FRandom := Cardinal((UInt64(FRandom) * $343FD + $269EC3) and $FFFFFFFF);
  Result := (FRandom shr 16) and $7FFF;
end;

function TN64VI.Raw(Index: Integer): TN64VIPixel;
begin
  Result := Default(TN64VIPixel);
  var Bytes := 2;
  if FPixelType = 3 then
    Bytes := 4;
  // Origin <= $FFFFFF and |Index| < 2^23: the address fits an Integer.
  var Address := FOrigin + Index * Bytes;
  if (Address < 0) or (Address + Bytes > $800000) then
    Exit;
  var A := Cardinal(Address);
  // Plain RDRAM under the TN64Bus contract: identical to the bus readers.
  if A + Cardinal(Bytes) <= FBus.RAMSize then
  begin
    if FPixelType = 3 then
    begin
      var V := FBus.ReadRAM32(A);
      Result.R := (V shr 24) and $FF;
      Result.G := (V shr 16) and $FF;
      Result.B := (V shr 8) and $FF;
      Result.Coverage := (V shr 5) and 7;
    end
    else
    begin
      var V := FBus.ReadRAM16(A);
      Result.R := Integer((V shr 8) and $F8);
      Result.G := Integer((V shr 3) and $F8);
      Result.B := Integer((V shl 2) and $F8);
      Result.Coverage := Integer((V and 1) shl 2) or FBus.ReadHiddenRAM(A);
    end;
    Exit;
  end;
  if FPixelType = 3 then
  begin
    var V := FBus.Read32(A);
    Result.R := (V shr 24) and $FF;
    Result.G := (V shr 16) and $FF;
    Result.B := (V shr 8) and $FF;
    Result.Coverage := (V shr 5) and 7;
  end
  else
  begin
    var V := (Cardinal(FBus.Read8(A)) shl 8) or FBus.Read8(A + 1);
    // VI fetch keeps the low three colour bits clear; restoration/gamma follows.
    Result.R := Integer((V shr 8) and $F8);
    Result.G := Integer((V shr 3) and $F8);
    Result.B := Integer((V shl 2) and $F8);
    Result.Coverage := Integer((V and 1) shl 2) or FBus.ReadHidden(A);
  end;
end;

// The row helpers take every array as a const parameter and declare no
// managed locals: a managed local adds an implicit try/finally, and Delphi
// then keeps all of the routine's variables in memory instead of registers.

procedure DecodeRow16(Bus: TN64Bus; const Values: TArray<TN64VIPixel>; Address: Cardinal; Count: Integer);
begin
  // Raw 16-bit pixels with the coverage forced to 7 (filters off).
  for var Column := 0 to Count - 1 do
  begin
    var V := Bus.ReadRAM16(Address);
    Values[Column].R := Integer((V shr 8) and $F8);
    Values[Column].G := Integer((V shr 3) and $F8);
    Values[Column].B := Integer((V shl 2) and $F8);
    Values[Column].Coverage := 7;
    Inc(Address, 2);
  end;
end;

procedure DivotRow(const Here, Above, Below, Target: TArray<TN64VIPixel>; Count: Integer);
begin
  // Horizontal median of three where any of them is not fully covered. The
  // row ends read the last pixel of the row above and the first one below.
  var Last := Count - 1;
  for var Column := 0 to Last do
  begin
    var Middle := Here[Column];
    var Left, Right: TN64VIPixel;
    if Column > 0 then
      Left := Here[Column - 1]
    else
      Left := Above[Last];
    if Column < Last then
      Right := Here[Column + 1]
    else
      Right := Below[0];
    if (Middle.Coverage and Left.Coverage and Right.Coverage) <> 7 then
    begin
      Middle.R := Median(Middle.R, Left.R, Right.R);
      Middle.G := Median(Middle.G, Left.G, Right.G);
      Middle.B := Median(Middle.B, Left.B, Right.B);
    end;
    Target[Column] := Middle;
  end;
end;

procedure InterpolateColumns(const Top, Bottom: TArray<TN64VIPixel>; First: Integer; const R, G, B: TArray<Integer>; Output, Count, YFraction: Integer; Resample: Boolean);
begin
  // Vertical step of the bilinear tap, once per source column (1/32 steps),
  // from Top[First..] and Bottom[First..] to R/G/B[Output..]. A zero
  // fraction adds FloorShift(16, 5) = 0: the top row as it is.
  if Resample and (YFraction <> 0) then
    for var K := 0 to Count - 1 do
    begin
      var I := First + K;
      R[Output + K] := Top[I].R + FloorShift((Bottom[I].R - Top[I].R) * YFraction + 16, 5);
      G[Output + K] := Top[I].G + FloorShift((Bottom[I].G - Top[I].G) * YFraction + 16, 5);
      B[Output + K] := Top[I].B + FloorShift((Bottom[I].B - Top[I].B) * YFraction + 16, 5);
    end
  else
    for var K := 0 to Count - 1 do
    begin
      var I := First + K;
      R[Output + K] := Top[I].R;
      G[Output + K] := Top[I].G;
      B[Output + K] := Top[I].B;
    end;
end;

procedure TN64VI.DecodeWindow(First, Count: Integer);
begin
  // FWindow[K] = Raw(First + K).
  if Length(FWindow) < Count then
    SetLength(FWindow, Count);
  var Bytes := 2;
  if FPixelType = 3 then
    Bytes := 4;
  var Address := FOrigin + First * Bytes;
  if (Address < 0) or (Int64(Address) + Int64(Count) * Bytes > FBus.RAMSize) then
  begin
    for var K := 0 to Count - 1 do
      FWindow[K] := Raw(First + K);
    Exit;
  end;
  // All in plain RDRAM: the same reads as Raw.
  var A := Cardinal(Address);
  {$IF Defined(CPU64BITS)}
  // The queued RDP work on the window's bytes waited for once, then each
  // word read without (ReadRAM16/32 and ReadHiddenRAM wait for their own).
  FBus.SyncRDPRead(A, Cardinal(Count * Bytes));
  if FPixelType = 3 then
    for var K := 0 to Count - 1 do
    begin
      var V := FBus.RDPRead32(A);
      FWindow[K].R := (V shr 24) and $FF;
      FWindow[K].G := (V shr 16) and $FF;
      FWindow[K].B := (V shr 8) and $FF;
      FWindow[K].Coverage := (V shr 5) and 7;
      Inc(A, 4);
    end
  else
    for var K := 0 to Count - 1 do
    begin
      var V := FBus.RDPRead16(A);
      FWindow[K].R := Integer((V shr 8) and $F8);
      FWindow[K].G := Integer((V shr 3) and $F8);
      FWindow[K].B := Integer((V shl 2) and $F8);
      FWindow[K].Coverage := Integer((V and 1) shl 2) or FBus.RDPReadHidden(A);
      Inc(A, 2);
    end;
  {$ELSE}
  if FPixelType = 3 then
    for var K := 0 to Count - 1 do
    begin
      var V := FBus.ReadRAM32(A);
      FWindow[K].R := (V shr 24) and $FF;
      FWindow[K].G := (V shr 16) and $FF;
      FWindow[K].B := (V shr 8) and $FF;
      FWindow[K].Coverage := (V shr 5) and 7;
      Inc(A, 4);
    end
  else
    for var K := 0 to Count - 1 do
    begin
      var V := FBus.ReadRAM16(A);
      FWindow[K].R := Integer((V shr 8) and $F8);
      FWindow[K].G := Integer((V shr 3) and $F8);
      FWindow[K].B := Integer((V shl 2) and $F8);
      FWindow[K].Coverage := Integer((V and 1) shl 2) or FBus.ReadHiddenRAM(A);
      Inc(A, 2);
    end;
  {$ENDIF}
end;

function Toward(const Neighbour: TN64VIPixel; R, G, B: Integer): Cardinal; inline;
begin
  // The dither filter's step of each channel towards Neighbour (5-bit
  // values against the centre's R, G, B): -1, 0 or +1, plus one, in bytes
  // 0, 1 and 2.
  Result := Cardinal(1 + Ord((Neighbour.R shr 3) > R) - Ord((Neighbour.R shr 3) < R)) or
    (Cardinal(1 + Ord((Neighbour.G shr 3) > G) - Ord((Neighbour.G shr 3) < G)) shl 8) or
    (Cardinal(1 + Ord((Neighbour.B shr 3) > B) - Ord((Neighbour.B shr 3) < B)) shl 16);
end;

procedure FilterRow(const Window, Target: TArray<TN64VIPixel>; Stride, AAMode: Integer; Dither: Boolean; FetchState: Integer);
var
  Colours: array[0..6] of TN64VIPixel;
  Values: array[0..6] of Integer;
begin
  // Target[C] is pixel Base + C filtered, where Window[W] is
  // Raw(Base - Stride - 2 + W): index Base + C + D is Window[Stride + 2 + C + D].
  for var C := 0 to Stride - 1 do
  begin
    var W := Stride + 2 + C;
    var Pixel := Window[W];
    if AAMode >= 2 then
      Pixel.Coverage := 7;
    if Pixel.Coverage = 7 then
    begin
      if Dither then
      begin
        // Dither filter: the 3x3 neighbourhood, or this row twice when the
        // next field line is fetched from the same row.
        var Below := W + Stride;
        if FetchState = 1 then
          Below := W;
        var Above := W - Stride;
        var R := Pixel.R shr 3;
        var G := Pixel.G shr 3;
        var B := Pixel.B shr 3;
        // Each neighbour moves each channel by one towards it: the sums of
        // the steps, each byte 0..16 with a bias of 8.
        var Sum := Toward(Window[Above - 1], R, G, B) + Toward(Window[Above], R, G, B) +
          Toward(Window[Above + 1], R, G, B) + Toward(Window[Below - 1], R, G, B) +
          Toward(Window[Below], R, G, B) + Toward(Window[Below + 1], R, G, B) +
          Toward(Window[W - 1], R, G, B) + Toward(Window[W + 1], R, G, B);
        Pixel.R := Pixel.R + Integer(Sum and $FF) - 8;
        Pixel.G := Pixel.G + Integer((Sum shr 8) and $FF) - 8;
        Pixel.B := Pixel.B + Integer((Sum shr 16) and $FF) - 8;
      end;
      Target[C] := Pixel;
      Continue;
    end;
    // Anti-alias reconstruction from the fully covered neighbours.
    Colours[0] := Pixel;
    var Count := 1;
    for var I := 0 to 5 do
    begin
      var N: Integer;
      case I of
        0:
          N := W - Stride - 1;
        1:
          N := W - Stride + 1;
        2:
          N := W - 2;
        3:
          N := W + 2;
        4:
          if FetchState = 1 then
            N := W - 2
          else
            N := W + Stride - 1;
      else
        if FetchState = 1 then
          N := W + 2
        else
          N := W + Stride + 1;
      end;
      if Window[N].Coverage = 7 then
      begin
        Colours[Count] := Window[N];
        Inc(Count);
      end;
    end;
    for var Channel := 0 to 2 do
    begin
      for var I := 0 to Count - 1 do
        case Channel of
          0:
            Values[I] := Colours[I].R;
          1:
            Values[I] := Colours[I].G;
        else
          Values[I] := Colours[I].B;
        end;
      // Retain the centre while rejecting an isolated neighbour extremum.
      var PosMax := 0;
      var PosMin := 0;
      var Low := Values[0];
      var High := Values[0];
      for var I := 1 to Count - 1 do
        if Values[I] > Values[PosMax] then
        begin
          High := Values[PosMax];
          PosMax := I
        end
        else if Values[I] < Values[PosMin] then
        begin
          Low := Values[PosMin];
          PosMin := I
        end;
      if High <> Values[PosMax] then
        for var I := PosMax + 1 to Count - 1 do
          High := Max(High, Values[I]);
      if Low <> Values[PosMin] then
        for var I := PosMin + 1 to Count - 1 do
          Low := Min(Low, Values[I]);
      var Center := Values[0];
      var Value := (Center + FloorShift((Low + High - Center * 2) * (7 - Pixel.Coverage) + 4, 3)) and $FF;
      case Channel of
        0:
          Pixel.R := Value;
        1:
          Pixel.G := Value;
      else
        Pixel.B := Value;
      end;
    end;
    Target[C] := Pixel;
  end;
end;

function TN64VI.FilteredSlot(Row: Integer): Integer;
begin
  // The filtered pixels (dither filter or anti-alias reconstruction) of the
  // whole row, current fetch state.
  Result := Row and (Slots - 1);
  if FSlotFiltered[Result] and (FSlotRow[Result] = Row) and (FSlotState[Result] = FFetchState) then
    Exit;
  var Stride := FStride;
  var Base := Row * Stride;
  if (FAAMode >= 2) and ((FStatus and $10000) = 0) and (FPixelType = 2) and FBus.DirectMemory and
    (FOrigin + Base * 2 >= 0) and (FOrigin + (Base + Stride) * 2 <= $800000) then
    // Filters off and the row inside RDRAM: Filtered = Raw with full coverage.
    DecodeRow16(FBus, FFilteredRows[Result], Cardinal(FOrigin + Base * 2), Stride)
  else
  begin
    // Filtered reads the rows above and below, and two pixels to either
    // side: decode that window once, then filter the row from it.
    DecodeWindow(Base - Stride - 2, 3 * Stride + 4);
    FilterRow(FWindow, FFilteredRows[Result], Stride, FAAMode, (FStatus and $10000) <> 0, FFetchState);
  end;
  FSlotRow[Result] := Row;
  FSlotState[Result] := FFetchState;
  FSlotFiltered[Result] := True;
  FSlotDivot[Result] := False;
end;

function TN64VI.DivotSlot(Row: Integer): Integer;
begin
  // Divot for the whole row. Its ends read the neighbouring rows (linear
  // indices Base - 1 and Base + Stride); rows Row - 1..Row + 1 occupy three
  // different slots.
  var Above := FilteredSlot(Row - 1);
  var Below := FilteredSlot(Row + 1);
  Result := FilteredSlot(Row);
  if FSlotDivot[Result] then
    Exit;
  DivotRow(FFilteredRows[Result], FFilteredRows[Above], FFilteredRows[Below], FDivotRows[Result], FStride);
  FSlotDivot[Result] := True;
end;

function TN64VI.RowPixels(Row: Integer): TArray<TN64VIPixel>;
begin
  // The divot/filtered pixels of source row Row.
  if (FStatus and $10) <> 0 then
    Result := FDivotRows[DivotSlot(Row)]
  else
    Result := FFilteredRows[FilteredSlot(Row)];
end;

procedure TN64VI.ComposeRow(const Weave: TArray<TAlphaColor>; const ColumnR, ColumnG, ColumnB: TArray<Integer>; OutputIndex, Width, FirstSample, LastSample, XStart, XStep, FirstColumn: Integer; Progressive: Boolean);
begin
  var Resample := FAAMode <> 3;
  var Noisy := (FStatus and 4) <> 0;
  var Gamma := (FStatus and 8) <> 0;
  for var X := FirstSample to LastSample - 1 do
  begin
    var SX := XStart + X * XStep;
    var K := (SX shr 10) - FirstColumn;
    var R := ColumnR[K];
    var G := ColumnG[K];
    var B := ColumnB[K];
    // Horizontal step between this and the next column, 1/32 steps (none
    // for a zero fraction, as in InterpolateColumns).
    var XFraction := (SX shr 5) and 31;
    if Resample and (XFraction <> 0) then
    begin
      R := R + FloorShift((ColumnR[K + 1] - R) * XFraction + 16, 5);
      G := G + FloorShift((ColumnG[K + 1] - G) * XFraction + 16, 5);
      B := B + FloorShift((ColumnB[K + 1] - B) * XFraction + 16, 5);
    end;
    var Noise: Cardinal := 0;
    if Noisy then
      Noise := Random;
    if R < 0 then
      R := 0
    else if R > 255 then
      R := 255;
    if G < 0 then
      G := 0
    else if G > 255 then
      G := 255;
    if B < 0 then
      B := 0
    else if B > 255 then
      B := 255;
    if Gamma then
    begin
      var RD := 0;
      var GD := 0;
      var BD := 0;
      if Noisy then
      begin
        RD := Noise and 63;
        GD := (Noise shr 6) and 63;
        BD := ((Noise shr 9) and 56) or (Noise and 7)
      end;
      R := GammaTable[R * 64 + RD];
      G := GammaTable[G * 64 + GD];
      B := GammaTable[B * 64 + BD];
    end
    else if Noisy then
    begin
      R := Min(255, R + Integer(Noise and 1));
      G := Min(255, G + Integer((Noise shr 1) and 1));
      B := Min(255, B + Integer((Noise shr 2) and 1));
    end;
    var Colour: TAlphaColor := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
    Weave[OutputIndex] := Colour;
    if Progressive then
      Weave[OutputIndex + Width] := Colour;
    Inc(OutputIndex);
  end;
end;

procedure TN64VI.Render(const Registers: array of Cardinal; out Width, Height: Integer; out Pixels: TArray<TAlphaColor>);
begin
  if Length(Registers) < 14 then
    raise EArgumentException.Create('VI requires fourteen registers');
  var Status := Integer(Registers[0] and $1FFFF);
  var Stride := Integer(Registers[2] and $FFF);
  var PixelType := Status and 3;
  var XStart := Integer((Registers[12] shr 16) and $FFF);
  var YStart := Integer((Registers[13] shr 16) and $FFF);
  var XStep := Integer(Registers[12] and $FFF);
  var YStep := Integer(Registers[13] and $FFF);
  var HStart := Integer((Registers[9] shr 16) and $3FF);
  var HEnd := Integer(Registers[9] and $3FF);
  var VStart := Integer((Registers[10] shr 16) and $3FF);
  var VEnd := Integer(Registers[10] and $3FF);
  var ActiveWidth := HEnd - HStart;
  var FieldRows := (VEnd - VStart) div 2;
  var Interlaced := (Status and $40) <> 0;
  var PAL := (Registers[6] and $3FF) > 550;
  // The signal includes its blank borders. A progressive field has 1:2 pixel
  // aspect; repeat each filtered scanline for IEmulationCore square pixels.
  Width := 640;
  Height := 480;
  if PAL then
    Height := 576;
  if (ActiveWidth < 1) or (ActiveWidth > 1024) or (FieldRows < 1) or (FieldRows > 512) or
    (Stride < 1) or (XStep = 0) or (YStep = 0) then
  begin
    SetLength(Pixels, Width * Height);
    for var I := 0 to High(Pixels) do
      Pixels[I] := $FF000000;
    Exit;
  end;
  var LeftBlank := 108;
  var TopBlank := 34;
  if PAL then
  begin
    LeftBlank := 128;
    TopBlank := 44
  end;
  var ActiveLeft := HStart - LeftBlank;
  var ActiveTop := (VStart - TopBlank) div 2;
  var LeftClipped := ActiveLeft < 0;
  if LeftClipped then
  begin
    Inc(XStart, -ActiveLeft * XStep);
    Inc(ActiveWidth, ActiveLeft);
    ActiveLeft := 0;
  end;
  if ActiveTop < 0 then
  begin
    Inc(YStart, -ActiveTop * YStep);
    ActiveTop := 0
  end;
  var RightClipped := ActiveLeft + ActiveWidth > Width;
  if RightClipped then
    ActiveWidth := Width - ActiveLeft;
  // These samples belong to the VI analog blanking interval. Retain the
  // border in the output instead of masking it in an oracle comparison.
  var FirstSample := 8;
  var LastSample := ActiveWidth - 7;
  if LeftClipped then
    FirstSample := 0;
  if RightClipped then
    LastSample := ActiveWidth;
  FieldRows := Min(FieldRows, Height div 2 - ActiveTop);
  var Field := Integer(Registers[4] and 1);
  // CURRENT identifies the physical field belonging to this ORIGIN/scale
  // packet. Its visible canvas row parity is inverted, as in the references.
  // At wrap Console passes the saved completed physical field; its guest
  // MMIO CURRENT may already name the next field.
  if Interlaced then
    Field := Field xor 1;
  var Size := Width * Height;
  if (FWidth <> Width) or (FHeight <> Height) then
  begin
    FWidth := Width;
    FHeight := Height;
    SetLength(FBuffers[FFront], Size);
    for var I := 0 to Size - 1 do
      FBuffers[FFront][I] := $FF000000;
  end;
  // Compose in the oldest buffer; SetLength also makes it private if a frame
  // returned three fields ago is still referenced by a consumer.
  var Back := (FFront + 1) mod Length(FBuffers);
  SetLength(FBuffers[Back], Size);
  var Weave := FBuffers[Back];
  if not (PixelType in [2, 3]) then
  begin
    for var I := 0 to Size - 1 do
      Weave[I] := $FF000000;
    FFront := Back;
    Pixels := Weave;
    Exit;
  end;
  // This field's rows start opaque black; with interlace the other field's
  // rows keep the previous raster. (No row of black allocated for it: the VI
  // thread calls no memory manager, which sleeps 10 ms on a lock held.)
  for var Y := 0 to Height - 1 do
    if not Interlaced or ((Y and 1) = Field) then
    begin
      for var X := Y * Width to Y * Width + Width - 1 do
        Weave[X] := $FF000000;
    end
    else
      Move(FBuffers[FFront][Y * Width], Weave[Y * Width], Width * SizeOf(TAlphaColor));
  FStatus := Status;
  FOrigin := Integer(Registers[1] and $FFFFFF);
  FStride := Stride;
  FPixelType := PixelType;
  FAAMode := (Status shr 8) and 3;
  FFetchState := 0;
  for var Slot := 0 to Slots - 1 do
  begin
    FSlotFiltered[Slot] := False;
    FSlotDivot[Slot] := False;
    if Length(FFilteredRows[Slot]) <> Stride then
      SetLength(FFilteredRows[Slot], Stride);
    if ((Status and $10) <> 0) and (Length(FDivotRows[Slot]) <> Stride) then
      SetLength(FDivotRows[Slot], Stride);
  end;
  // Source columns of this field: SX = XStart + X * XStep grows with X.
  var FirstColumn := 0;
  var Columns := 0;
  if LastSample > FirstSample then
  begin
    FirstColumn := (XStart + FirstSample * XStep) shr 10;
    Columns := ((XStart + (LastSample - 1) * XStep) shr 10) - FirstColumn + 2;
    if Length(FColumnR) < Columns then
    begin
      SetLength(FColumnR, Columns);
      SetLength(FColumnG, Columns);
      SetLength(FColumnB, Columns);
    end;
  end;
  for var Y := 0 to FieldRows - 1 do
  begin
    var SY := YStart + Y * YStep;
    var SourceRow := SY shr 10;
    if SourceRow = (SY + YStep) shr 10 then
      FFetchState := 2
    else
      FFetchState := FFetchState shr 1;
    if Columns = 0 then
      Continue;
    var OutputY := (ActiveTop + Y) * 2;
    if Interlaced then
      Inc(OutputY, Field);
    // The two source rows of the bilinear tap, as linear framebuffer spans.
    // The columns are linear framebuffer indices, so they may run on into
    // the next rows: one row's part at a time, from the slots themselves.
    // The bottom row's filtering (a few rows on) leaves the top row's
    // slot alone.
    var First := SourceRow * Stride + FirstColumn;
    var Row := FloorDivide(First, Stride);
    var Column := First - Row * Stride;
    var Done := 0;
    while Done < Columns do
    begin
      var Take := Min(Columns - Done, Stride - Column);
      var Top := RowPixels(Row);
      var Bottom := Top;
      if FAAMode <> 3 then
        Bottom := RowPixels(Row + 1);
      InterpolateColumns(Top, Bottom, Column, FColumnR, FColumnG, FColumnB, Done, Take, (SY shr 5) and 31,
        FAAMode <> 3);
      Inc(Done, Take);
      Inc(Row);
      Column := 0;
    end;
    ComposeRow(Weave, FColumnR, FColumnG, FColumnB, OutputY * Width + ActiveLeft + FirstSample, Width,
      FirstSample, LastSample, XStart, XStep, FirstColumn, not Interlaced);
  end;
  FLastField := Field;
  FFront := Back;
  Pixels := Weave;
end;

class function TN64VI.SourceSpan(const Registers: array of Cardinal; out Address, Count: Cardinal): Boolean;
begin
  // Render's geometry up to its source rows and columns, then every row it
  // can reach from them: a row's filter window takes the rows around it and
  // two pixels to either side, divot the rows around those, the bilinear tap
  // the next row, and the columns of a field row may run into later rows.
  Result := False;
  Address := 0;
  Count := 0;
  if Length(Registers) < 14 then
    Exit;
  var Status := Integer(Registers[0] and $1FFFF);
  var Stride := Integer(Registers[2] and $FFF);
  var PixelType := Status and 3;
  var XStart := Integer((Registers[12] shr 16) and $FFF);
  var YStart := Integer((Registers[13] shr 16) and $FFF);
  var XStep := Integer(Registers[12] and $FFF);
  var YStep := Integer(Registers[13] and $FFF);
  var HStart := Integer((Registers[9] shr 16) and $3FF);
  var HEnd := Integer(Registers[9] and $3FF);
  var VStart := Integer((Registers[10] shr 16) and $3FF);
  var VEnd := Integer(Registers[10] and $3FF);
  var ActiveWidth := HEnd - HStart;
  var FieldRows := (VEnd - VStart) div 2;
  var PAL := (Registers[6] and $3FF) > 550;
  var Width := 640;
  var Height := 480;
  if PAL then
    Height := 576;
  if (ActiveWidth < 1) or (ActiveWidth > 1024) or (FieldRows < 1) or (FieldRows > 512) or
    (Stride < 1) or (XStep = 0) or (YStep = 0) or not (PixelType in [2, 3]) then
    Exit;
  var LeftBlank := 108;
  var TopBlank := 34;
  if PAL then
  begin
    LeftBlank := 128;
    TopBlank := 44
  end;
  var ActiveLeft := HStart - LeftBlank;
  var ActiveTop := (VStart - TopBlank) div 2;
  var LeftClipped := ActiveLeft < 0;
  if LeftClipped then
  begin
    Inc(XStart, -ActiveLeft * XStep);
    Inc(ActiveWidth, ActiveLeft);
    ActiveLeft := 0;
  end;
  if ActiveTop < 0 then
  begin
    Inc(YStart, -ActiveTop * YStep);
    ActiveTop := 0
  end;
  var RightClipped := ActiveLeft + ActiveWidth > Width;
  if RightClipped then
    ActiveWidth := Width - ActiveLeft;
  var FirstSample := 8;
  var LastSample := ActiveWidth - 7;
  if LeftClipped then
    FirstSample := 0;
  if RightClipped then
    LastSample := ActiveWidth;
  FieldRows := Min(FieldRows, Height div 2 - ActiveTop);
  if (LastSample <= FirstSample) or (FieldRows < 1) then
    Exit;
  var FirstColumn := Int64((XStart + FirstSample * XStep) shr 10);
  var Columns := Int64(((XStart + (LastSample - 1) * XStep) shr 10)) - FirstColumn + 2;
  var FirstRow := Int64(YStart shr 10);
  var LastRow := Int64((YStart + (FieldRows - 1) * YStep) shr 10);
  var Lo := (FirstRow - 4) * Stride + FirstColumn - 4;
  var Hi := (LastRow + 6) * Stride + FirstColumn + Columns + 4;
  var Bytes := 2;
  if PixelType = 3 then
    Bytes := 4;
  var First := Int64(Registers[1] and $FFFFFF) + Lo * Bytes;
  var Last := Int64(Registers[1] and $FFFFFF) + Hi * Bytes;
  if First < 0 then
    First := 0;
  if Last > $800000 then
    Last := $800000;
  if Last <= First then
    Exit;
  Address := Cardinal(First);
  Count := Cardinal(Last - First);
  Result := True;
end;

procedure TN64VI.SerializeState(State: TStateArchive);
begin
  State.Field(FRandom, 4);
  State.Field(FWidth, 4);
  State.Field(FHeight, 4);
  State.Field(FLastField, 4);
  if State.Loading then
  begin
    if (FWidth < 0) or (FWidth > 1024) or (FHeight < 0) or (FHeight > 1024) or
      (FLastField < -1) or (FLastField > 1) then
      raise EReadError.Create('Invalid VI raster snapshot');
    FFront := 0;
    FBuffers[2] := nil;
    FBuffers[1] := nil;
    FBuffers[0] := nil;
    SetLength(FBuffers[0], FWidth * FHeight);
  end;
  if Length(FBuffers[FFront]) > 0 then
    State.Field(FBuffers[FFront][0], Length(FBuffers[FFront]) * SizeOf(Cardinal))
  else
  begin
    var Empty: Byte := 0;
    State.Field(Empty, 0)
  end;
end;

initialization
  for var V := 0 to High(GammaTable) do
    GammaTable[V] := Byte(IntegerSqrt(Cardinal(V)) * 2);

end.

