unit GBA.Video;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, Core.Snapshots;

const
  GBA_WIDTH = 240;
  GBA_HEIGHT = 160;

type
  TGBATileFetch = record
    Entry: Word;
    Address, NextCycle, Remaining, Column, Row, SampleX, SampleY: Integer;
    X, Y, Mosaic: Integer;
  end;

  PGBATileFetch = ^TGBATileFetch;

  TGBAObjectPixel = record
    Color, Key: Integer;
    Semi, Window, Mosaic: Boolean;
  end;

  PGBAObjectPixel = ^TGBAObjectPixel;

  TGBAObjectFetch = record
    Index, Stage, Delay, Pixel, Width, Height, DrawWidth, DrawHeight: Integer;
    TargetY, X, Y, WorkBuffer: Integer;
    A, B, C: Word;
    Matrix: array[0..3] of Integer;
  end;

  PGBAObjectFetch = ^TGBAObjectFetch;

  TGBAVideo = class
  private
    FFrame: TArray<TAlphaColor>;
    FRefX, FRefY, FPixelX, FPixelY: array[0..1] of Integer;
    FAffineReload, FAffineOverride: array[0..1, 0..1] of Boolean;
    FAffineActive: array[0..1] of Boolean;
    FRenderPosition: Integer;
    FWindowX, FWindowY: array[0..1] of Boolean;
    FWindowMap: array[0..255] of Byte;
    FWindowCursor, FWindowScanline: Integer;
    FClocked: Boolean;
    FClockLine, FClockCycle: Integer;
    FMemoryPorts: Byte;
    FDisplayLatch: array[0..2] of Word;
    FFetch: array[0..3] of TGBATileFetch;
    FObjectFetch: TGBAObjectFetch;
    FObjectDraw: TGBAObjectFetch;
    FObjectDrawing, FObjectDrawStarted: Boolean;
    FObjectRow: Integer;
    FMosaicBGCount, FMosaicOBJCount, FMosaicOBJLine: Integer;
    FMosaicX, FMosaicY: array[0..1] of Integer;
    FMergeTop, FMergeBottom, FMergeTopLayer, FMergeBottomLayer, FMergeMask: Integer;
    FMergeSemi: Boolean;
    FMergeMainColor, FMergeSubColor: Integer;
    FObjectMosaic: TGBAObjectPixel;
  public
    // Frequently read ports follow the small timing state, before large rows.
    IO: array[0..$3FF] of Byte;
    Palette: array[0..$3FF] of Byte;
    OAM: array[0..$3FF] of Byte;
  private
    FBackgroundRow: array[0..3, 0..247] of Integer;
    FBackgroundFIFO: array[0..3, 0..7] of Integer;
    FObjectRows: array[0..1, 0..239] of TGBAObjectPixel;
    procedure ResetTiming;
    procedure ClockTextBackground(BG, Cycle: Integer);
    procedure ClockAffineBackground(BG, Cycle, Display: Integer);
    procedure ClockAffine;
    procedure LatchAffineReferences;
    procedure ClockObject(Cycle: Integer);
    procedure FetchObjectPixel;
    procedure MergeLayers(X: Integer);
    function EffectColor(Top, Bottom, TopLayer, BottomLayer, Mask: Integer; Semi: Boolean): Integer;
    procedure AdvanceWindows(Last: Integer);
    procedure AdvanceAffine(Count: Integer);
    function VR16(Address: Integer): Word; inline;
    function PAL16(Index: Integer): Word; inline;
    function Background(BG, X, Y, Mode: Integer): Integer;
    procedure Sprites(Y: Integer; var Colors, Priorities: array of Integer; var Semi, ObjWindow: array of Boolean);
    function WindowMask(X, Y: Integer; ObjWindow: Boolean): Integer;
  public
    VRAM: array[0..$17FFF] of Byte;
    constructor Create;
    procedure Reset;
    function Reg16(Offset: Integer): Word; inline;
    procedure SetReg16(Offset: Integer; Value: Word);
    procedure ReloadAffine(Offset: Integer);
    procedure BeginFrame;
    procedure BeginScanline(Y: Integer);
    procedure RenderLine(Y: Integer; First: Integer = 0; Last: Integer = 239);
    procedure EndLine;
    procedure SerializeState(State: TStateArchive);
    procedure RunCycles(Line, FirstCycle, LastCycle: Integer);
    function MemoryBusy(Address: Cardinal): Boolean; inline;
    property Clocked: Boolean read FClocked write FClocked;
    property Pixels: TArray<TAlphaColor> read FFrame;
  end;

function GBAColor(Value: Integer): TAlphaColor;

implementation

type
  // Rows have four-byte alignment; a packed view permits paired stores.
  TGBAPixelPair = packed record
    case Byte of
      0:
        (Value: UInt64);
      1:
        (First, Second: Integer);
  end;

  PGBAPixelPair = ^TGBAPixelPair;

var
  // Palette indices, not colors: palette RAM is still read on its own clock.
  GBATextPairs: array[0..31, 0..255] of TGBAPixelPair;
  GBAColors: array[0..32767] of TAlphaColor;

function LookupColor(Value: Integer): TAlphaColor; inline;
begin
  Result := GBAColors[Value and $7FFF];
end;

function GBAColor(Value: Integer): TAlphaColor;
begin
  Result := LookupColor(Value);
end;

function FloorFixed8(Value: Integer): Integer; inline;
begin
  // Delphi shr is logical. Retain floor (rather than truncation) for negative
  // affine coordinates, including MinInt, without floating-point conversion.
  if Value < 0 then
    Result := -1 - ((-1 - Value) shr 8)
  else
    Result := Value shr 8;
end;

function Signed16(V: Word): Integer; inline;
begin
  Result := V;
  if V and $8000 <> 0 then
    Dec(Result, $10000);
end;

constructor TGBAVideo.Create;
begin
  inherited;
  SetLength(FFrame, GBA_WIDTH * GBA_HEIGHT);
  Reset;
end;

procedure TGBAVideo.Reset;
begin
  FillChar(IO, SizeOf(IO), 0);
  FillChar(VRAM, SizeOf(VRAM), 0);
  FillChar(Palette, SizeOf(Palette), 0);
  FillChar(OAM, SizeOf(OAM), 0);
  FillChar(FRefX, SizeOf(FRefX), 0);
  FillChar(FRefY, SizeOf(FRefY), 0);
  FillChar(FPixelX, SizeOf(FPixelX), 0);
  FillChar(FPixelY, SizeOf(FPixelY), 0);
  FRenderPosition := 0;
  FillChar(FWindowX, SizeOf(FWindowX), 0);
  FillChar(FWindowY, SizeOf(FWindowY), 0);
  FillChar(FWindowMap, SizeOf(FWindowMap), 0);
  FWindowCursor := 0;
  FWindowScanline := -1;
  ResetTiming;
  for var i := 0 to High(FFrame) do
    FFrame[i] := $FF000000;
  SetReg16(0, $80);
end;

function TGBAVideo.Reg16(Offset: Integer): Word;
begin
  Result := IO[Offset] or (Word(IO[Offset + 1]) shl 8);
end;

procedure TGBAVideo.SetReg16(Offset: Integer; Value: Word);
begin
  IO[Offset] := Byte(Value and 255);
  IO[Offset + 1] := Byte(Value shr 8);
end;

function TGBAVideo.VR16(Address: Integer): Word;
begin
  Address := Address and $1FFFF;
  if Address >= $18000 then
    Dec(Address, $8000);
  Result := VRAM[Address] or (Word(VRAM[(Address + 1) mod $18000]) shl 8);
end;

function TGBAVideo.PAL16(Index: Integer): Word;
begin
  Index := (Index and 511) * 2;
  Result := Palette[Index] or (Word(Palette[Index + 1]) shl 8);
end;

procedure TGBAVideo.ReloadAffine(Offset: Integer);
begin
  for var i := 0 to 1 do
  begin
    var Base := $28 + i * 16;
    if (Offset >= Base) and (Offset < Base + 8) then
    begin
      var Axis := (Offset - Base) div 4;
      var V := Integer(Cardinal(Reg16(Base + Axis * 4)) or (Cardinal(Reg16(Base + Axis * 4 + 2)) shl 16)) and $FFFFFFF;
      if V and $8000000 <> 0 then
        Dec(V, $10000000);

      if FClocked then
      begin
        FAffineReload[i, Axis] := True;
        Continue;
      end;

      if Axis = 0 then
      begin
        FRefX[i] := V;
        FPixelX[i] := V;
        FFetch[i + 2].X := V;
      end
      else
      begin
        FRefY[i] := V;
        FPixelY[i] := V;
        FFetch[i + 2].Y := V;
      end;
    end;
  end;
end;

procedure TGBAVideo.BeginFrame;
begin
  if FClocked then
    FillChar(FAffineActive, SizeOf(FAffineActive), 0);
  ReloadAffine($28);
  ReloadAffine($2C);
  ReloadAffine($38);
  ReloadAffine($3C);
  FRenderPosition := 0;
end;

procedure TGBAVideo.EndLine;
begin
  AdvanceWindows(255);
  if FClocked then
    Exit;

  for var i := 0 to 1 do
  begin
    FRefX[i] := Integer((Int64(FRefX[i]) + Signed16(Reg16($22 + i * 16)) + $10000000) and $FFFFFFF);
    if FRefX[i] and $8000000 <> 0 then
      Dec(FRefX[i], $10000000);
    FRefY[i] := Integer((Int64(FRefY[i]) + Signed16(Reg16($26 + i * 16)) + $10000000) and $FFFFFFF);
    if FRefY[i] and $8000000 <> 0 then
      Dec(FRefY[i], $10000000);
    FPixelX[i] := FRefX[i];
    FPixelY[i] := FRefY[i];
  end;
  FRenderPosition := 0;
end;

procedure TGBAVideo.BeginScanline(Y: Integer);
begin
  if FWindowScanline = Y then
    Exit;

  AdvanceWindows(255);
  FWindowScanline := Y;
  FWindowCursor := 0;
  if FClocked then
  begin
    FClockLine := Y;
    FClockCycle := 0;
    FillChar(FBackgroundRow, SizeOf(FBackgroundRow), $FF);
    for var BG := 0 to 3 do
      Move(FBackgroundFIFO[BG], FBackgroundRow[BG], SizeOf(FBackgroundFIFO[BG]));
    FillChar(FFetch, SizeOf(FFetch), 0);
    for var i := 0 to 3 do
      FFetch[i].NextCycle := -1;
    if Y = 0 then
      FMosaicBGCount := 0
    else if FMosaicBGCount = (IO[$4C] shr 4) then
      FMosaicBGCount := 0
    else
      FMosaicBGCount := (FMosaicBGCount + 1) and 15;
    if FMosaicBGCount = 0 then
    begin
      Move(FRefX, FMosaicX, SizeOf(FMosaicX));
      Move(FRefY, FMosaicY, SizeOf(FMosaicY));
    end;
    for var i := 0 to 1 do
    begin
      FFetch[i + 2].X := FRefX[i];
      FFetch[i + 2].Y := FRefY[i];
    end;
    FObjectRow := FObjectFetch.WorkBuffer;
    FillChar(FObjectMosaic, SizeOf(FObjectMosaic), 0);
    FObjectMosaic.Color := -1;
  end;

  for var i := 0 to 1 do
  begin
    // Vertical bounds drive comparators, rather than a fresh range test
    // at each pixel. Changing a bound after it passed retains the latch.
    if Y = IO[$45 + i * 2] then
      FWindowY[i] := True;
    if Y = IO[$44 + i * 2] then
      FWindowY[i] := False;
  end;
end;

procedure TGBAVideo.AdvanceWindows(Last: Integer);
begin
  Last := Min(Last, 255);
  var C := Reg16(0);
  if C and $6000 = 0 then
  begin
    FWindowX[0] := False;
    FWindowX[1] := False;
    if Last = FWindowCursor then
      FWindowMap[Last] := 0
    else if Last > FWindowCursor then
      FillChar(FWindowMap[FWindowCursor], Last - FWindowCursor + 1, 0);
    FWindowCursor := Max(FWindowCursor, Last + 1);
    Exit;
  end;

  while FWindowCursor <= Last do
  begin
    var X := FWindowCursor;
    var Mask: Byte := 0;
    for var i := 0 to 1 do
    begin
      if X = IO[$41 + i * 2] then
        FWindowX[i] := C and ($2000 shl i) <> 0;
      if X = IO[$40 + i * 2] then
        FWindowX[i] := False;
      if FWindowX[i] and FWindowY[i] then
        Mask := Mask or (1 shl i);
    end;
    FWindowMap[X] := Mask;
    Inc(FWindowCursor);
  end;
end;

procedure TGBAVideo.AdvanceAffine(Count: Integer);
begin
  for var i := 0 to 1 do
  begin
    FPixelX[i] := Integer((Int64(FPixelX[i]) + Int64(Count) * Signed16(Reg16($20 + i * 16)) + $10000000) and $FFFFFFF);
    FPixelY[i] := Integer((Int64(FPixelY[i]) + Int64(Count) * Signed16(Reg16($24 + i * 16)) + $10000000) and $FFFFFFF);
    if FPixelX[i] and $8000000 <> 0 then
      Dec(FPixelX[i], $10000000);
    if FPixelY[i] and $8000000 <> 0 then
      Dec(FPixelY[i], $10000000);
  end;
  Inc(FRenderPosition, Count);
end;

function TGBAVideo.Background(BG, X, Y, Mode: Integer): Integer;
begin
  Result := -1;
  var C := Reg16(8 + BG * 2);
  var Mosaic := C and $40 <> 0;
  if Mosaic then
  begin
    X := X - X mod ((Reg16($4C) and 15) + 1);
    Y := Y - Y mod (((Reg16($4C) shr 4) and 15) + 1);
  end;
  if (Mode = 0) or ((Mode = 1) and (BG < 2)) then
  begin
    var Size := C shr 14;
    var Width := 256;
    var Height := 256;
    if Size and 1 <> 0 then
      Width := 512;
    if Size and 2 <> 0 then
      Height := 512;
    X := (X + Reg16($10 + BG * 4)) and (Width - 1);
    Y := (Y + Reg16($12 + BG * 4)) and (Height - 1);
    var Map := ((C shr 8) and 31) * $800;
    var Block := (Y div 256) * (Width div 256) + (X div 256);
    var Entry := VR16((Map + Block * $800 + (((Y and 255) div 8) * 32 + (X and 255) div 8) * 2) and $FFFF);
    var TX := X and 7;
    var TY := Y and 7;
    if Entry and $400 <> 0 then
      TX := 7 - TX;
    if Entry and $800 <> 0 then
      TY := 7 - TY;
    var Base := ((C shr 2) and 3) * $4000;
    var Index: Integer;
    if C and $80 <> 0 then
      Index := VRAM[(Base + (Entry and $3FF) * 64 + TY * 8 + TX) and $FFFF]
    else
    begin
      Index := VRAM[(Base + (Entry and $3FF) * 32 + TY * 4 + TX div 2) and $FFFF];
      if TX and 1 = 0 then
        Index := Index and 15
      else
        Index := Index shr 4;
      if Index <> 0 then
        Inc(Index, (Entry shr 12) * 16);
    end;
    if Index <> 0 then
      Result := PAL16(Index);
    Exit;
  end;

  if BG < 2 then
    Exit;

  var i := BG - 2;
  var Matrix := $20 + i * 16;
  var AX := FPixelX[i];
  var AY := FPixelY[i];
  if Mosaic then
  begin
    var DX := FRenderPosition - X;
    Dec(AX, DX * Signed16(Reg16(Matrix)));
    Dec(AY, DX * Signed16(Reg16(Matrix + 4)));
    var DY := Reg16(6) - Y;
    Dec(AX, DY * Signed16(Reg16(Matrix + 2)));
    Dec(AY, DY * Signed16(Reg16(Matrix + 6)));
  end;
  var TX: Integer;
  var TY: Integer;

  // Delphi shr is logical for signed integers; arithmetic fixed-point division.
  TX := FloorFixed8(AX);
  TY := FloorFixed8(AY);

  if Mode >= 3 then
  begin
    if BG <> 2 then
      Exit;

    var W := 240;
    var H := 160;
    if Mode = 5 then
    begin
      W := 160;
      H := 128;
    end;
    if (TX < 0) or (TX >= W) or (TY < 0) or (TY >= H) then
      Exit;

    var Page := 0;
    if (Mode <> 3) and (Reg16(0) and $10 <> 0) then
      Page := $A000;
    if Mode = 4 then
      Result := PAL16(VRAM[Page + TY * W + TX])
    else
      Result := VR16(Page + (TY * W + TX) * 2);
    Exit;
  end;

  var Size := 128 shl (C shr 14);
  if C and $2000 <> 0 then
  begin
    TX := TX and (Size - 1);
    TY := TY and (Size - 1);
  end
  else if (TX < 0) or (TY < 0) or (TX >= Size) or (TY >= Size) then
    Exit;

  var Tile := VRAM[((((C shr 8) and 31) * $800) + (TY div 8) * (Size div 8) + TX div 8) and $FFFF];
  var Index := VRAM[((((C shr 2) and 3) * $4000) + Tile * 64 + (TY and 7) * 8 + (TX and 7)) and $FFFF];
  if Index <> 0 then
    Result := PAL16(Index);
end;

procedure TGBAVideo.Sprites(Y: Integer; var Colors, Priorities: array of Integer; var Semi, ObjWindow: array of Boolean);
const
  Widths: array[0..2, 0..3] of Integer = ((8, 16, 32, 64), (16, 32, 32, 64), (8, 8, 16, 32));
  Heights: array[0..2, 0..3] of Integer = ((8, 16, 32, 64), (8, 8, 16, 32), (16, 32, 32, 64));

  function OW(A: Integer): Word;
  begin
    Result := OAM[A] or (Word(OAM[A + 1]) shl 8);
  end;

begin
  for var X := 0 to 239 do
  begin
    Colors[X] := -1;
    Priorities[X] := 4;
    Semi[X] := False;
    ObjWindow[X] := False;
  end;

  if Reg16(0) and $1000 = 0 then
    Exit;

  var Budget := 1210;
  if Reg16(0) and $20 <> 0 then
    Budget := 954;
  for var i := 0 to 127 do
  begin
    if Budget <= 0 then
      Break;

    var A := OW(i * 8);
    var B := OW(i * 8 + 2);
    var C := OW(i * 8 + 4);
    var Affine := A and $100 <> 0;
    if not Affine and (A and $200 <> 0) then
      Continue;

    var Shape := A shr 14;
    if Shape = 3 then
      Continue;

    var Kind := (A shr 10) and 3;
    if Kind = 3 then
      Continue;

    var W := Widths[Shape, B shr 14];
    var H := Heights[Shape, B shr 14];
    var DW := W;
    var DH := H;
    if Affine and (A and $200 <> 0) then
    begin
      DW := W * 2;
      DH := H * 2;
    end;
    var SY := (Y - (A and 255) + 256) and 255;

    // Wrapped OBJ ranges end in the upper part of the screen. In particular
    // a 128-pixel double-size area must not appear again at its unsigned Y.
    if (SY >= DH) or (Y >= ((Integer(A and 255) + DH) and 255)) then
      Continue;

    var SX := Integer(B and 511);
    if SX >= 256 then
      Dec(SX, 512);
    var Pri := (C shr 10) and 3;
    var Cost := 1;
    if Affine then
    begin
      Dec(Budget, 10);
      Cost := 2;
    end;
    var DrawPixels := Min(DW, Max(0, Budget) div Cost);
    Dec(Budget, DW * Cost);
    for var X := Max(0, SX) to Min(239, SX + DrawPixels - 1) do
    begin
      var LX := X - SX;
      var LY := SY;
      if A and $1000 <> 0 then
      begin
        LX := LX - LX mod (((Reg16($4C) shr 8) and 15) + 1);
        LY := LY - LY mod (((Reg16($4C) shr 12) and 15) + 1);
      end;
      var TX := LX;
      var TY := LY;
      if Affine then
      begin
        var M := ((B shr 9) and 31) * 32;
        TX := FloorFixed8(Signed16(OW(M + 6)) * (LX - DW div 2) + Signed16(OW(M + 14)) * (LY - DH div 2)) + W div 2;
        TY := FloorFixed8(Signed16(OW(M + 22)) * (LX - DW div 2) + Signed16(OW(M + 30)) * (LY - DH div 2)) + H div 2;
      end
      else
      begin
        if B and $1000 <> 0 then
          TX := W - 1 - TX;
        if B and $2000 <> 0 then
          TY := H - 1 - TY;
      end;

      if (TX < 0) or (TX >= W) or (TY < 0) or (TY >= H) then
        Continue;

      var Color8 := A and $2000 <> 0;
      var Step := 1;
      if Color8 then
        Step := 2;
      var Stride := 32;
      if Reg16(0) and $40 <> 0 then
        Stride := (W div 8) * Step;
      var Tile := Integer(C and $3FF);
      if Color8 then
        Tile := Tile and not 1;
      Inc(Tile, (TY div 8) * Stride + (TX div 8) * Step);
      var Address := $10000 + (Tile * 32 and $7FFF);
      if (Reg16(0) and 7 >= 3) and (Address < $14000) then
        Continue;

      var Index: Integer;
      if Color8 then
        Index := VRAM[$10000 + ((Address - $10000 + (TY and 7) * 8 + (TX and 7)) and $7FFF)]
      else
      begin
        Index := VRAM[$10000 + ((Address - $10000 + (TY and 7) * 4 + (TX and 7) div 2) and $7FFF)];
        if TX and 1 = 0 then
          Index := Index and 15
        else
          Index := Index shr 4;
        if Index <> 0 then
          Inc(Index, (C shr 12) * 16);
      end;
      if Index = 0 then
        Continue;

      if Kind = 2 then
      begin
        ObjWindow[X] := True;
        Continue;
      end;

      if Pri >= Priorities[X] then
        Continue;

      Priorities[X] := Pri;
      Colors[X] := PAL16(256 + Index);
      Semi[X] := Kind = 1;
    end;
  end;
end;

function TGBAVideo.WindowMask(X, Y: Integer; ObjWindow: Boolean): Integer;
begin
  var C := Reg16(0);
  if C and $E000 = 0 then
    Exit($3F);

  AdvanceWindows(X);
  if (C and $2000 <> 0) and (FWindowMap[X] and 1 <> 0) then
    Exit(IO[$48] and $3F);

  if (C and $4000 <> 0) and (FWindowMap[X] and 2 <> 0) then
    Exit(IO[$49] and $3F);

  if (C and $8000 <> 0) and ObjWindow then
    Exit(IO[$4B] and $3F);

  Result := IO[$4A] and $3F;
end;

procedure TGBAVideo.RenderLine(Y, First, Last: Integer);
var
  Obj, Priority: array[0..239] of Integer;
  Semi, ObjWindow: array[0..239] of Boolean;
begin
  if (First > Last) or (Y < 0) or (Y >= 160) then
    Exit;

  First := EnsureRange(First, 0, 239);
  Last := EnsureRange(Last, 0, 239);
  BeginScanline(Y);
  AdvanceWindows(Last);
  if First = 0 then
  begin
    FRenderPosition := 0;
    FPixelX := FRefX;
    FPixelY := FRefY;
  end;
  if First > FRenderPosition then
    AdvanceAffine(First - FRenderPosition);
  var C := Reg16(0);
  var Mode := C and 7;
  if C and $80 <> 0 then
  begin
    for var X := First to Last do
      FFrame[Y * 240 + X] := $FFFFFFFF;
    AdvanceAffine(Last - First + 1);
    Exit;
  end;

  Sprites(Y, Obj, Priority, Semi, ObjWindow);
  for var X := First to Last do
  begin
    var Mask := WindowMask(X, Y, ObjWindow[X]);
    var Top := PAL16(0);
    var Bottom := Top;
    var TopLayer := 5;
    var BottomLayer := 5;
    var TopKey := 100;
    var BottomKey := 100;
    for var BG := 0 to 3 do
    begin
      if (C and (1 shl (8 + BG)) = 0) or (Mask and (1 shl BG) = 0) then
        Continue;

      if ((Mode = 1) and (BG = 3)) or ((Mode = 2) and (BG < 2)) or ((Mode >= 3) and (BG <> 2)) or (Mode > 5) then
        Continue;

      var V := Background(BG, X, Y, Mode);
      if V < 0 then
        Continue;

      var Key := (Reg16(8 + BG * 2) and 3) * 8 + BG + 1;
      if Key < TopKey then
      begin
        Bottom := Top;
        BottomLayer := TopLayer;
        BottomKey := TopKey;
        Top := V;
        TopLayer := BG;
        TopKey := Key;
      end
      else if Key < BottomKey then
      begin
        Bottom := V;
        BottomLayer := BG;
        BottomKey := Key;
      end;
    end;
    if (Obj[X] >= 0) and (Mask and $10 <> 0) then
    begin
      var Key := Priority[X] * 8;
      if Key < TopKey then
      begin
        Bottom := Top;
        BottomLayer := TopLayer;
        Top := Obj[X];
        TopLayer := 4;
      end
      else if Key < BottomKey then
      begin
        Bottom := Obj[X];
        BottomLayer := 4;
      end;
    end;
    var Blend := Reg16($50);
    var Effect := (Blend shr 6) and 3;
    var IsSemi := (TopLayer = 4) and Semi[X];
    if Mask and $20 <> 0 then
    begin
      if ((Effect = 1) or IsSemi) and (Blend and (1 shl (8 + BottomLayer)) <> 0) and (IsSemi or (Blend and (1 shl TopLayer) <> 0)) then
      begin
        var A := Min(16, Reg16($52) and 31);
        var B := Min(16, (Reg16($52) shr 8) and 31);
        var V := 0;
        for var Channel := 0 to 2 do
        begin
          var Shift := Channel * 5;
          var Level := Min(31, (((Top shr Shift) and 31) * A + ((Bottom shr Shift) and 31) * B) div 16);
          V := V or (Level shl Shift);
        end;
        Top := V;
      end
      else if (Blend and (1 shl TopLayer) <> 0) and (Effect in [2, 3]) then
      begin
        var Amount := Min(16, Reg16($54) and 31);
        var V := 0;
        for var Channel := 0 to 2 do
        begin
          var Shift := Channel * 5;
          var Level := (Top shr Shift) and 31;
          if Effect = 2 then
            Inc(Level, (31 - Level) * Amount div 16)
          else
            Dec(Level, Level * Amount div 16);
          V := V or (Level shl Shift);
        end;
        Top := V;
      end;
    end;
    FFrame[Y * 240 + X] := LookupColor(Top);
    AdvanceAffine(1);
  end;
end;

procedure TGBAVideo.SerializeState(State: TStateArchive);
begin
  State.Field(IO, SizeOf(IO));
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(Palette, SizeOf(Palette));
  State.Field(OAM, SizeOf(OAM));
  State.Field(FRefX, SizeOf(FRefX));
  State.Field(FRefY, SizeOf(FRefY));
  State.Field(FAffineReload, SizeOf(FAffineReload));
  State.Field(FAffineOverride, SizeOf(FAffineOverride));
  State.Field(FAffineActive, SizeOf(FAffineActive));
  State.Field(FPixelX, SizeOf(FPixelX));
  State.Field(FPixelY, SizeOf(FPixelY));
  State.Field(FRenderPosition, SizeOf(FRenderPosition));
  State.Field(FWindowX, SizeOf(FWindowX));
  State.Field(FWindowY, SizeOf(FWindowY));
  State.Field(FWindowMap, SizeOf(FWindowMap));
  State.Field(FWindowCursor, SizeOf(FWindowCursor));
  State.Field(FWindowScanline, SizeOf(FWindowScanline));
  State.Field(FClocked, SizeOf(FClocked));
  State.Field(FClockLine, SizeOf(FClockLine));
  State.Field(FClockCycle, SizeOf(FClockCycle));
  State.Field(FMemoryPorts, SizeOf(FMemoryPorts));
  State.Field(FDisplayLatch, SizeOf(FDisplayLatch));
  State.Field(FFetch, SizeOf(FFetch));
  State.Field(FBackgroundRow, SizeOf(FBackgroundRow));
  State.Field(FBackgroundFIFO, SizeOf(FBackgroundFIFO));
  State.Field(FObjectRows, SizeOf(FObjectRows));
  State.Field(FObjectFetch, SizeOf(FObjectFetch));
  State.Field(FObjectDraw, SizeOf(FObjectDraw));
  State.Field(FObjectDrawing, SizeOf(FObjectDrawing));
  State.Field(FObjectDrawStarted, SizeOf(FObjectDrawStarted));
  State.Field(FObjectRow, SizeOf(FObjectRow));
  State.Field(FMosaicBGCount, SizeOf(FMosaicBGCount));
  State.Field(FMosaicOBJCount, SizeOf(FMosaicOBJCount));
  State.Field(FMosaicOBJLine, SizeOf(FMosaicOBJLine));
  State.Field(FMosaicX, SizeOf(FMosaicX));
  State.Field(FMosaicY, SizeOf(FMosaicY));
  State.Field(FMergeTop, SizeOf(FMergeTop));
  State.Field(FMergeBottom, SizeOf(FMergeBottom));
  State.Field(FMergeTopLayer, SizeOf(FMergeTopLayer));
  State.Field(FMergeBottomLayer, SizeOf(FMergeBottomLayer));
  State.Field(FMergeMask, SizeOf(FMergeMask));
  State.Field(FMergeSemi, SizeOf(FMergeSemi));
  State.Field(FMergeMainColor, SizeOf(FMergeMainColor));
  State.Field(FMergeSubColor, SizeOf(FMergeSubColor));
  State.Field(FObjectMosaic, SizeOf(FObjectMosaic));

  if State.Loading and ((FRenderPosition < 0) or (FRenderPosition > 240)) then
    raise EReadError.Create('Invalid GBA affine state');

  if State.Loading then
  begin
    if (FClockLine < -1) or (FClockLine > 227) or (FClockCycle < 0) or (FClockCycle > 1232) or
      (FMemoryPorts > 15) or (FObjectRow < 0) or (FObjectRow > 1) or
      (FObjectFetch.WorkBuffer < 0) or (FObjectFetch.WorkBuffer > 1) or
      (FObjectFetch.Stage < 0) or (FObjectFetch.Stage > 3) or
      (FObjectFetch.Index < 0) or (FObjectFetch.Index > 128) or
      (FObjectFetch.Pixel < 0) or (FObjectFetch.Pixel > 128) or
      ((FObjectFetch.Stage = 2) and (FObjectFetch.Pixel > 3)) or
      (FObjectDraw.WorkBuffer < 0) or (FObjectDraw.WorkBuffer > 1) or
      (FObjectDraw.Pixel < 0) or (FObjectDraw.Pixel > 128) or
      (FObjectDraw.DrawWidth < 0) or (FObjectDraw.DrawWidth > 128) or
      (FObjectDraw.DrawHeight < 0) or (FObjectDraw.DrawHeight > 128) or
      (FMergeTopLayer < 0) or (FMergeTopLayer > 5) or
      (FMergeBottomLayer < 0) or (FMergeBottomLayer > 5) or
      (FMosaicBGCount < 0) or (FMosaicBGCount > 15) or
      (FMosaicOBJCount < 0) or (FMosaicOBJCount > 15) then
      raise EReadError.Create('Invalid GBA PPU fetch state');

    if (FWindowCursor < 0) or (FWindowCursor > 256) or
      (FWindowScanline < -1) or (FWindowScanline > 227) then
      raise EReadError.Create('Invalid GBA window state');

    for var X := 0 to 255 do
      if FWindowMap[X] > 3 then
        raise EReadError.Create('Invalid GBA window mask');
  end;

  State.Field(FFrame[0], Length(FFrame) * SizeOf(TAlphaColor));
end;

// Independent clocked implementation. The four memory-port flags describe
// real PPU transactions, so CPU/DMA arbitration and rendering share one clock.
// Timing references: GBATEK and the BSD-licensed NBA hardware test ROMs.
procedure TGBAVideo.ResetTiming;
begin
  FClockLine := -1;
  FClockCycle := 0;
  FMemoryPorts := 0;
  FillChar(FAffineReload, SizeOf(FAffineReload), 0);
  FillChar(FAffineOverride, SizeOf(FAffineOverride), 0);
  FillChar(FAffineActive, SizeOf(FAffineActive), 0);
  FillChar(FDisplayLatch, SizeOf(FDisplayLatch), 0);
  FillChar(FFetch, SizeOf(FFetch), 0);
  FillChar(FBackgroundRow, SizeOf(FBackgroundRow), $FF);
  FillChar(FBackgroundFIFO, SizeOf(FBackgroundFIFO), $FF);
  FillChar(FObjectRows, SizeOf(FObjectRows), 0);
  for var Row := 0 to 1 do
    for var X := 0 to 239 do
    begin
      FObjectRows[Row, X].Color := -1;
      FObjectRows[Row, X].Key := 100;
    end;
  FillChar(FObjectFetch, SizeOf(FObjectFetch), 0);
  FillChar(FObjectDraw, SizeOf(FObjectDraw), 0);
  FObjectDrawing := False;
  FObjectDrawStarted := False;
  FObjectFetch.Index := 128;
  FObjectRow := 0;
  FMosaicBGCount := 0;
  FMosaicOBJCount := 0;
  FMosaicOBJLine := 0;
  FillChar(FMosaicX, SizeOf(FMosaicX), 0);
  FillChar(FMosaicY, SizeOf(FMosaicY), 0);
  FMergeTop := 0;
  FMergeBottom := 0;
  FMergeTopLayer := 5;
  FMergeBottomLayer := 5;
  FMergeMask := 0;
  FMergeSemi := False;
  FMergeMainColor := 0;
  FMergeSubColor := 0;
  FillChar(FObjectMosaic, SizeOf(FObjectMosaic), 0);
  FObjectMosaic.Color := -1;
end;

procedure TGBAVideo.LatchAffineReferences;
begin
  for var i := 0 to 1 do
    for var Axis := 0 to 1 do
    begin
      FAffineOverride[i, Axis] := FAffineReload[i, Axis];
      if not FAffineReload[i, Axis] then
        Continue;

      var Base := $28 + i * 16 + Axis * 4;
      var Value := Integer((Cardinal(Reg16(Base)) or (Cardinal(Reg16(Base + 2)) shl 16)) and $FFFFFFF);
      if Value and $8000000 <> 0 then
        Dec(Value, $10000000);
      if Axis = 0 then
      begin
        FRefX[i] := Value;
        FFetch[i + 2].X := Value;
      end
      else
      begin
        FRefY[i] := Value;
        FFetch[i + 2].Y := Value;
      end;
      FAffineReload[i, Axis] := False;
    end;
end;

procedure TGBAVideo.ClockAffine;
begin
  var D := Reg16(0);
  var Mode := D and 7;
  for var i := 0 to 1 do
  begin
    var Enabled :=
      (D and FDisplayLatch[1] and (1 shl (10 + i)) <> 0) and
      (((i = 0) and (Mode in [1..5])) or ((i = 1) and (Mode = 2)));
    if Enabled then
    begin
      for var Axis := 0 to 1 do
      begin
        var Value := FRefX[i];
        if Axis = 1 then
          Value := FRefY[i];
        if not FAffineOverride[i, Axis] then
        begin
          if FAffineActive[i] then
            Value := Integer((Int64(Value) + Signed16(Reg16($22 + i * 16 + Axis * 4)) + $10000000) and $FFFFFFF)
          else
          begin
            var Base := $28 + i * 16 + Axis * 4;
            Value := Integer((Cardinal(Reg16(Base)) or (Cardinal(Reg16(Base + 2)) shl 16)) and $FFFFFFF);
          end;
          if Value and $8000000 <> 0 then
            Dec(Value, $10000000);
        end;
        if Axis = 0 then
          FRefX[i] := Value
        else
          FRefY[i] := Value;
      end;
      FFetch[i + 2].X := FRefX[i];
      FFetch[i + 2].Y := FRefY[i];
      if FMosaicBGCount = 0 then
      begin
        FMosaicX[i] := FRefX[i];
        FMosaicY[i] := FRefY[i];
      end;
    end;
    FAffineActive[i] := Enabled;
  end;
end;

function TGBAVideo.MemoryBusy(Address: Cardinal): Boolean;
begin
  var Port := 0;
  case Address shr 24 of
    5:
      Port := 1;
    6:
      if Address and $10000 = 0 then
        Port := 2
      else
        Port := 4;
    7:
      Port := 8;
  end;
  Result := FClocked and (FMemoryPorts and Port <> 0);
end;

procedure TGBAVideo.ClockTextBackground(BG, Cycle: Integer);
begin
  var C := Reg16(8 + BG * 2);
  var S: PGBATileFetch := @FFetch[BG];
  var local := Cycle - 4 - BG;
  if (local < 0) or (local and 3 <> 0) then
    Exit;

  var Pixel := local div 4 - 7;
  var Scroll := Reg16($10 + BG * 4);
  if ((Pixel + Scroll) and 7 = 0) and (Pixel < 240) then
  begin
    var X := (Pixel + Scroll) and $1FF;
    var Y := FClockLine;
    if C and $40 <> 0 then
      Dec(Y, FMosaicBGCount);
    Y := (Y + Reg16($12 + BG * 4)) and $1FF;
    var Wide := (C shr 14) and 1;
    var Map := ((C shr 8) and 31) * $800;
    if (Wide <> 0) and (X >= 256) then
      Inc(Map, $800);
    if (C and $8000 <> 0) and (Y >= 256) then
      Inc(Map, $800 shl Wide);
    S.Entry := PWord(@VRAM[(Map + (Y and 255) div 8 * 64 + (X and 255) div 8 * 2) and $FFFE])^;
    S.Row := Y and 7;
    if S.Entry and $800 <> 0 then
      S.Row := 7 - S.Row;
    S.Column := 0;
    S.Remaining := 2 + 2 * Ord(C and $80 <> 0);
    S.Address := ((C shr 2) and 3) * $4000 + (S.Entry and $3FF) * (32 shl Ord(C and $80 <> 0)) +
      S.Row * (4 shl Ord(C and $80 <> 0));
    S.NextCycle := local + 4;
    FMemoryPorts := FMemoryPorts or 2;
  end
  else if (S.Remaining > 0) and (local = S.NextCycle) then
  begin
    var BPP8 := C and $80 <> 0;
    var Count := 4 shr Ord(BPP8);
    var Column := S.Column;
    if S.Entry and $400 <> 0 then
      Column := (4 shl Ord(BPP8)) - 2 - Column;
    var WordData := PWord(@VRAM[(S.Address + Column) and $FFFE])^;
    FMemoryPorts := FMemoryPorts or 2;
    var FirstX := (local - 4) div 4 - 7;
    if (C and $C0 = 0) and (FirstX >= 0) and (FirstX <= 244) then
    begin
      // One completed 4bpp fetch supplies four pixels. Keep the same VRAM
      // read/port reservation and preserve the last raw mosaic sample.
      var Bank := S.Entry shr 12;
      var Pair0, Pair1: PGBAPixelPair;
      if S.Entry and $400 = 0 then
      begin
        Pair0 := @GBATextPairs[Bank, WordData and 255];
        Pair1 := @GBATextPairs[Bank, WordData shr 8];
        S.Mosaic := WordData shr 12;
      end
      else
      begin
        Pair0 := @GBATextPairs[Bank + 16, WordData shr 8];
        Pair1 := @GBATextPairs[Bank + 16, WordData and 255];
        S.Mosaic := WordData and 15;
      end;
      PGBAPixelPair(@FBackgroundRow[BG, FirstX]).Value := Pair0.Value;
      PGBAPixelPair(@FBackgroundRow[BG, FirstX + 2]).Value := Pair1.Value;
      // The FIFO wraps independently of the linear row (including scroll 1..7).
      FBackgroundFIFO[BG, FirstX and 7] := Pair0.First;
      FBackgroundFIFO[BG, (FirstX + 1) and 7] := Pair0.Second;
      FBackgroundFIFO[BG, (FirstX + 2) and 7] := Pair1.First;
      FBackgroundFIFO[BG, (FirstX + 3) and 7] := Pair1.Second;
    end
    else
      for var i := 0 to Count - 1 do
      begin
        var DataX := FirstX + i;
        if (DataX < 0) or (DataX > 247) then
          Continue;

        var Shift := i * (4 shl Ord(BPP8));
        if S.Entry and $400 <> 0 then
          Shift := (Count - 1 - i) * (4 shl Ord(BPP8));
        var Index := (WordData shr Shift) and (15 + 240 * Ord(BPP8));
        if (C and $40 = 0) or (DataX mod ((IO[$4C] and 15) + 1) = 0) then
          S.Mosaic := Index
        else
          Index := S.Mosaic;
        var Color := -1;
        if Index <> 0 then
        begin
          if not BPP8 then
            Inc(Index, (S.Entry shr 12) * 16);
          Color := Index;
        end;
        FBackgroundRow[BG, DataX] := Color;
        FBackgroundFIFO[BG, DataX and 7] := Color;
      end;
    Inc(S.Column, 2);
    Dec(S.Remaining);
    Inc(S.NextCycle, 16 shr Ord(BPP8));
  end;
end;

procedure TGBAVideo.ClockAffineBackground(BG, Cycle, Display: Integer);
begin
  var D := Display;
  var Mode := D and 7;
  var C := Reg16(8 + BG * 2);
  var S: PGBATileFetch := @FFetch[BG];
  var Gap := 38 - BG * 2;
  if Mode >= 3 then
    Gap := 35;
  var local := Cycle - Gap;
  if local < 0 then
    Exit;

  var X := local div 4;
  if local and 3 = 0 then
  begin
    var AX := S.X;
    var AY := S.Y;
    if C and $40 <> 0 then
    begin
      AX := FMosaicX[BG - 2] + X * Signed16(Reg16($20 + (BG - 2) * 16));
      AY := FMosaicY[BG - 2] + X * Signed16(Reg16($24 + (BG - 2) * 16));
    end;
    if (C and $40 = 0) or (X mod ((IO[$4C] and 15) + 1) = 0) then
    begin
      S.SampleX := FloorFixed8(AX);
      S.SampleY := FloorFixed8(AY);
    end;
    Inc(S.X, Signed16(Reg16($20 + (BG - 2) * 16)));
    Inc(S.Y, Signed16(Reg16($24 + (BG - 2) * 16)));
    FMemoryPorts := FMemoryPorts or 2;
    if Mode >= 3 then
    begin
      if X >= 240 then
        Exit;

      var Width := 240;
      var Height := 160;
      if Mode = 5 then
      begin
        Width := 160;
        Height := 128;
      end;
      if (S.SampleX < 0) or (S.SampleX >= Width) or (S.SampleY < 0) or (S.SampleY >= Height) then
        Exit;

      var Base := 0;
      if (Mode <> 3) and (D and $10 <> 0) then
        Base := $A000;
      var Address := S.SampleY * Width + S.SampleX;
      if Mode = 4 then
      begin
        var Index := VRAM[Base + Address];
        if Index <> 0 then
          FBackgroundRow[BG, X] := Index
        else
          FBackgroundRow[BG, X] := -1;
      end
      else
        FBackgroundRow[BG, X] := VR16(Base + Address * 2) or $8000;
    end
    else
    begin
      var Size := 128 shl (C shr 14);
      var TX := S.SampleX;
      var TY := S.SampleY;
      if C and $2000 <> 0 then
      begin
        TX := TX and (Size - 1);
        TY := TY and (Size - 1);
      end;
      S.Address := -1;
      if (TX >= 0) and (TX < Size) and (TY >= 0) and (TY < Size) then
      begin
        var Tile := VRAM[((((C shr 8) and 31) * $800) + (TY shr 3) * (Size shr 3) + (TX shr 3)) and $FFFF];
        S.Address := ((((C shr 2) and 3) * $4000) + Tile * 64 + (TY and 7) * 8 + (TX and 7)) and $FFFF;
      end;
    end;
  end
  else if (Mode < 3) and (local and 3 = 1) then
  begin
    FMemoryPorts := FMemoryPorts or 2;
    if S.Address >= 0 then
    begin
      var Index := VRAM[S.Address];
      if (Index <> 0) and (X < 240) then
        FBackgroundRow[BG, X] := Index;
    end;
  end;
end;

procedure TGBAVideo.FetchObjectPixel;
begin
  var S: PGBAObjectFetch := @FObjectDraw;
  var D := Reg16(0);
  FMemoryPorts := FMemoryPorts or 4;
  var TX := S.Pixel;
  var TY := S.Y;
  if S.A and $1000 <> 0 then
  begin
    TY := (FMosaicOBJLine - (S.A and 255) + 256) and 255;
    if TY >= S.DrawHeight then
      TY := 0;
  end;
  if S.A and $100 <> 0 then
  begin
    TX := FloorFixed8(S.Matrix[0] * (S.Pixel - S.DrawWidth div 2) + S.Matrix[1] * (TY - S.DrawHeight div 2)) + S.Width div 2;
    TY := FloorFixed8(S.Matrix[2] * (S.Pixel - S.DrawWidth div 2) + S.Matrix[3] * (TY - S.DrawHeight div 2)) + S.Height div 2;
  end
  else
  begin
    if S.B and $1000 <> 0 then
      TX := S.Width - 1 - TX;
    if S.B and $2000 <> 0 then
      TY := S.Height - 1 - TY;
  end;
  var X := S.X + S.Pixel;
  if (TX >= 0) and (TX < S.Width) and (TY >= 0) and (TY < S.Height) then
  begin
    var BPP8 := S.A and $2000 <> 0;
    var Scale := 1 shl Ord(BPP8);
    var Stride := 32;
    if D and $40 <> 0 then
      Stride := S.Width div 8 * Scale;
    var Tile := S.C and $3FF;
    if BPP8 then
      Tile := Tile and not 1;
    Inc(Tile, TY div 8 * Stride + TX div 8 * Scale);
    var Address := $10000 + ((Tile * 32 + (TY and 7) * (4 * Scale) + (TX and 7) div (2 shr Ord(BPP8))) and $7FFF);
    if (D and 7 < 3) or (Address >= $14000) then
    begin
      var Index := Integer(VRAM[Address]);
      if not BPP8 then
      begin
        if TX and 1 = 0 then
          Index := Index and 15
        else
          Index := Index shr 4;
        if Index <> 0 then
          Inc(Index, (S.C shr 12) * 16);
      end;
      if (Index <> 0) and (X >= 0) and (X < 240) then
      begin
        var P: PGBAObjectPixel := @FObjectRows[S.WorkBuffer, X];
        if S.A and $C00 = $800 then
          P.Window := True
        else if (S.C shr 10 and 3) * 8 < P.Key then
        begin
          P.Color := Index + 256;
          P.Key := (S.C shr 10 and 3) * 8;
          P.Semi := S.A and $C00 = $400;
          P.Mosaic := S.A and $1000 <> 0;
        end;
      end;
    end;
  end;
  Inc(S.Pixel);
end;

procedure TGBAVideo.ClockObject(Cycle: Integer);
const
  Widths: array[0..2, 0..3] of Integer = ((8, 16, 32, 64), (16, 32, 32, 64), (8, 8, 16, 32));
  Heights: array[0..2, 0..3] of Integer = ((8, 16, 32, 64), (8, 8, 16, 32), (16, 32, 32, 64));
begin
  var S: PGBAObjectFetch := @FObjectFetch;
  var D := Reg16(0);
  if Cycle = 40 then
  begin
    FObjectDrawing := False;
    FObjectDrawStarted := False;

    if not ((FClockLine < 159) or (FClockLine = 227)) then
    begin
      S.Index := 128;
      Exit;
    end;

    S.WorkBuffer := FObjectRow xor 1;
    FillChar(FObjectRows[S.WorkBuffer], SizeOf(FObjectRows[S.WorkBuffer]), 0);
    for var X := 0 to 239 do
    begin
      FObjectRows[S.WorkBuffer, X].Color := -1;
      FObjectRows[S.WorkBuffer, X].Key := 100;
    end;
    S.TargetY := (FClockLine + 1) mod 228;
    if S.TargetY = 0 then
    begin
      FMosaicOBJCount := 0;
      FMosaicOBJLine := 0;
    end
    else if FMosaicOBJCount = IO[$4D] shr 4 then
    begin
      FMosaicOBJCount := 0;
      FMosaicOBJLine := S.TargetY;
    end
    else
      FMosaicOBJCount := (FMosaicOBJCount + 1) and 15;
    S.Index := 0;
    S.Stage := 0;
    S.Delay := 0;
  end;

  // OAM and OBJ VRAM each have an independent, two-cycle pipeline stage.
  if (Cycle and 1 <> 0) or ((D and $20 <> 0) and ((Cycle >= 1000) or (Cycle < 40))) or (D and $1000 = 0) or (D and $80 <> 0) then
    Exit;

  var PairWidth := 2;
  if FObjectDraw.A and $100 <> 0 then
    PairWidth := 1;

  var AllowOAM := not FObjectDrawing or not FObjectDrawStarted or (FObjectDraw.Pixel >= FObjectDraw.DrawWidth - PairWidth);
  if (S.Index < 128) and AllowOAM then
    case S.Stage of
      0:
        begin
          var Address := S.Index * 8;
          S.A := OAM[Address] or (Word(OAM[Address + 1]) shl 8);
          S.B := OAM[Address + 2] or (Word(OAM[Address + 3]) shl 8);
          FMemoryPorts := FMemoryPorts or 8;
          var Shape := S.A shr 14;
          if (Shape = 3) or (S.A and $300 = $200) or (S.A and $C00 = $C00) then
          begin
            Inc(S.Index);
          end
          else
          begin
            S.Width := Widths[Shape, S.B shr 14];
            S.Height := Heights[Shape, S.B shr 14];
            S.DrawWidth := S.Width;
            S.DrawHeight := S.Height;
            if S.A and $300 = $300 then
            begin
              S.DrawWidth := S.Width * 2;
              S.DrawHeight := S.Height * 2;
            end;
            S.Y := (S.TargetY - (S.A and 255) + 256) and 255;
            if (S.Y >= S.DrawHeight) or (S.TargetY >= ((Integer(S.A and 255) + S.DrawHeight) and 255)) then
              Inc(S.Index)
            else
              S.Stage := 1;
          end;
        end;
      1:
        begin
          var Address := S.Index * 8 + 4;
          S.C := OAM[Address] or (Word(OAM[Address + 1]) shl 8);
          FMemoryPorts := FMemoryPorts or 8;
          S.X := S.B and 511;
          if S.X >= 256 then
            Dec(S.X, 512);
          S.Pixel := 0;
          if S.A and $100 <> 0 then
            S.Stage := 2
          else
            S.Stage := 3;
        end;
      2:
        begin
          var Address := ((S.B shr 9) and 31) * 32 + 6 + S.Pixel * 8;
          S.Matrix[S.Pixel] := Signed16(OAM[Address] or (Word(OAM[Address + 1]) shl 8));
          FMemoryPorts := FMemoryPorts or 8;
          Inc(S.Pixel);
          if S.Pixel = 4 then
          begin
            S.Pixel := 0;
            S.Stage := 3;
          end;
        end;
    end;

  if FObjectDrawing then
  begin
    FObjectDrawStarted := True;
    if FObjectDraw.Delay > 0 then
      Dec(FObjectDraw.Delay)
    else
    begin
      for var i := 1 to PairWidth do
        FetchObjectPixel;
      if FObjectDraw.Pixel >= FObjectDraw.DrawWidth then
        FObjectDrawing := False;
    end;
  end;

  if not FObjectDrawing and (S.Stage = 3) then
  begin
    FObjectDraw := S^;
    FObjectDraw.Delay := Ord(S.A and $100 <> 0);
    FObjectDrawing := True;
    FObjectDrawStarted := False;
    Inc(S.Index);
    S.Stage := 0;
  end;
end;

procedure TGBAVideo.MergeLayers(X: Integer);
begin
  var Obj := FObjectRows[FObjectRow, X];
  var ObjectWindow := Obj.Window;
  if not Obj.Mosaic or not FObjectMosaic.Mosaic or (X mod ((IO[$4D] and 15) + 1) = 0) then
    FObjectMosaic := Obj;
  if Obj.Mosaic then
    Obj := FObjectMosaic;
  var D := Reg16(0);
  FMergeMask := WindowMask(X, FClockLine, ObjectWindow);
  FMergeTop := 0;
  FMergeBottom := 0;
  FMergeTopLayer := 5;
  FMergeBottomLayer := 5;
  var TopKey := 100;
  var BottomKey := 100;

  for var BG := 0 to 3 do
  begin
    if (D and FDisplayLatch[2] and (1 shl (8 + BG)) = 0) or (FMergeMask and (1 shl BG) = 0) then
      Continue;

    var Value := FBackgroundRow[BG, X];
    if Value < 0 then
      Continue;

    var Key := (Reg16(8 + BG * 2) and 3) * 8 + BG + 1;
    if Key < TopKey then
    begin
      FMergeBottom := FMergeTop;
      FMergeBottomLayer := FMergeTopLayer;
      BottomKey := TopKey;
      FMergeTop := Value;
      FMergeTopLayer := BG;
      TopKey := Key;
    end
    else if Key < BottomKey then
    begin
      FMergeBottom := Value;
      FMergeBottomLayer := BG;
      BottomKey := Key;
    end;
  end;

  FMergeSemi := False;
  if (D and $1000 <> 0) and (Obj.Color >= 0) and (FMergeMask and $10 <> 0) then
  begin
    if Obj.Key < TopKey then
    begin
      FMergeBottom := FMergeTop;
      FMergeBottomLayer := FMergeTopLayer;
      FMergeTop := Obj.Color;
      FMergeTopLayer := 4;
      FMergeSemi := Obj.Semi;
    end
    else if Obj.Key < BottomKey then
    begin
      FMergeBottom := Obj.Color;
      FMergeBottomLayer := 4;
    end;
  end;
end;

function TGBAVideo.EffectColor(Top, Bottom, TopLayer, BottomLayer, Mask: Integer; Semi: Boolean): Integer;
begin
  Result := Top;
  if Mask and $20 = 0 then
    Exit;

  var Blend := Reg16($50);
  var Effect := Blend shr 6 and 3;
  var Alpha := ((Effect = 1) or Semi) and (Blend and (1 shl (8 + BottomLayer)) <> 0) and (Semi or (Blend and (1 shl TopLayer) <> 0));

  if not Alpha and ((Blend and (1 shl TopLayer) = 0) or not (Effect in [2, 3])) then
    Exit;

  Result := 0;
  for var Channel := 0 to 2 do
  begin
    var Shift := Channel * 5;
    var Level := Top shr Shift and 31;
    if Alpha then
      Level := Min(31, (Level * Min(16, IO[$52] and 31) + (Bottom shr Shift and 31) * Min(16, IO[$53] and 31)) div 16)
    else if Effect = 2 then
      Inc(Level, (31 - Level) * Min(16, IO[$54] and 31) div 16)
    else
      Dec(Level, Level * Min(16, IO[$54] and 31) div 16);
    Result := Result or (Level shl Shift);
  end;
end;

procedure TGBAVideo.RunCycles(Line, FirstCycle, LastCycle: Integer);
begin
  if not FClocked then
    Exit;

  if FWindowScanline <> Line then
    BeginScanline(Line);

  // Registers cannot change inside this bus slice. Dispatch only the fetch
  // phases that can transact on this clock, retaining every port reservation.
  var D := Reg16(0);
  var Mode := D and 7;
  var Enable := FDisplayLatch[2];
  if FirstCycle < 40 then
    Enable := FDisplayLatch[1];
  Enable := Enable and D;

  // VBlank lines 160..226 have no BG/merger or OBJ evaluation. The
  // affine reload and display latch still have their original event clocks.
  if (Line >= 160) and (Line < 227) then
  begin
    if (FirstCycle <= 1) and (LastCycle >= 1) then
      LatchAffineReferences;
    if (FirstCycle <= 40) and (LastCycle >= 40) then
    begin
      FDisplayLatch[2] := FDisplayLatch[1];
      FDisplayLatch[1] := FDisplayLatch[0];
      FDisplayLatch[0] := D;
      ClockObject(40);
    end;
    FClockCycle := LastCycle;
    FMemoryPorts := 0;
    AdvanceWindows(Min(255, LastCycle div 4));
    Exit;
  end;

  // Beyond the last merger clock, only unfinished OBJ evaluation can use
  // a video port. Advance an idle HBlank without visiting each clock.
  if (FirstCycle >= 1007) and
    ((D and $1080 <> $1000) or ((FObjectFetch.Index >= 128) and not FObjectDrawing)) then
  begin
    FClockCycle := LastCycle;
    FMemoryPorts := 0;
    var WindowEnd := Min(255, LastCycle div 4);
    if (WindowEnd >= FWindowCursor) or ((D and $6000 = 0) and (FWindowX[0] or FWindowX[1])) then
      AdvanceWindows(WindowEnd);
    Exit;
  end;

  // Text map reads have a fixed eight-pixel phase while registers remain
  // unchanged in this slice. Other text clocks can only fetch pending data.
  // Avoid entering the full fetch routine on clocks with no transaction.
  var TextMapPhases := ((7 - (IO[$10] and 7)) and 7) or
    (((7 - (IO[$14] and 7)) and 7) shl 3) or
    (((7 - (IO[$18] and 7)) and 7) shl 6) or
    (((7 - (IO[$1C] and 7)) and 7) shl 9);

  var GroupEnd := Min(LastCycle - 3, 1000);
  var Cycle := FirstCycle;
  while Cycle <= LastCycle do
  begin
    // Registers remain fixed throughout this slice. Complete mode-0 groups
    // have the same OBJ/BG/palette/merger order, with constant phase indices.
    // Prefixes, tails, forced blank and every other mode use the scalar path.
    if (Line < 160) and (Mode = 0) and (Cycle >= 48) and
      (Cycle <= GroupEnd) and (Cycle and 3 = 0) and
      ((D or FDisplayLatch[2]) and $80 = 0) then
    begin
      while Cycle <= GroupEnd do
      begin
        var local := Cycle - 4;
        FClockCycle := Cycle;
        FMemoryPorts := 0;
        if (D and $1080 = $1000) and ((FObjectFetch.Index < 128) or FObjectDrawing) then
          ClockObject(Cycle);
        if Enable and $100 <> 0 then
          if ((local < 988) and ((local shr 2 and 7) = (TextMapPhases and 7))) or
            ((FFetch[0].Remaining > 0) and (local = FFetch[0].NextCycle)) then
            ClockTextBackground(0, Cycle);
        FClockCycle := Cycle + 1;
        FMemoryPorts := 0;
        if Enable and $200 <> 0 then
          if ((local < 988) and ((local shr 2 and 7) = (TextMapPhases shr 3 and 7))) or
            ((FFetch[1].Remaining > 0) and (local = FFetch[1].NextCycle)) then
            ClockTextBackground(1, Cycle + 1);
        FMergeSubColor := FMergeBottom and $7FFF;
        var Blend := Reg16($50);
        var Alpha := ((Blend shr 6 and 3 = 1) or FMergeSemi) and (FMergeMask and $20 <> 0) and
          (Blend and (1 shl (8 + FMergeBottomLayer)) <> 0) and
          (FMergeSemi or (Blend and (1 shl FMergeTopLayer) <> 0));
        if Alpha and (FMergeBottom and $8000 = 0) then
        begin
          FMemoryPorts := FMemoryPorts or 1;
          FMergeSubColor := PAL16(FMergeBottom);
        end;
        FClockCycle := Cycle + 2;
        FMemoryPorts := 0;
        if (D and $1080 = $1000) and ((FObjectFetch.Index < 128) or FObjectDrawing) then
          ClockObject(Cycle + 2);
        if Enable and $400 <> 0 then
          if ((local < 988) and ((local shr 2 and 7) = (TextMapPhases shr 6 and 7))) or
            ((FFetch[2].Remaining > 0) and (local = FFetch[2].NextCycle)) then
            ClockTextBackground(2, Cycle + 2);
        // Complete groups cover X=1..239: publish X-1, then merge X.
        var X := (Cycle - 44) shr 2;
        var Position := Line * 240 + X - 1;
        FFrame[Position] := LookupColor(EffectColor(FMergeMainColor, FMergeSubColor,
              FMergeTopLayer, FMergeBottomLayer, FMergeMask, FMergeSemi));
        if (X and 1 = 0) and (IO[2] and 1 <> 0) then
        begin
          var A := FFrame[Position - 1];
          var B := FFrame[Position];
          FFrame[Position - 1] := (A and $FFFF00FF) or (B and $FF00);
          FFrame[Position] := (B and $FFFF00FF) or (A and $FF00);
        end;
        if FWindowCursor <= (Cycle + 2) div 4 then
          AdvanceWindows((Cycle + 2) div 4);
        MergeLayers(X);
        FClockCycle := Cycle + 3;
        FMemoryPorts := 0;
        if Enable and $800 <> 0 then
          if ((local < 988) and ((local shr 2 and 7) = (TextMapPhases shr 9 and 7))) or
            ((FFetch[3].Remaining > 0) and (local = FFetch[3].NextCycle)) then
            ClockTextBackground(3, Cycle + 3);
        FMergeMainColor := FMergeTop and $7FFF;
        if FMergeTop and $8000 = 0 then
        begin
          FMemoryPorts := FMemoryPorts or 1;
          FMergeMainColor := PAL16(FMergeTop);
        end;
        Inc(Cycle, 4);
      end;
      Continue;
    end;

    FClockCycle := Cycle;
    FMemoryPorts := 0;

    if Cycle = 1 then
      LatchAffineReferences;

    if Cycle = 40 then
    begin
      FDisplayLatch[2] := FDisplayLatch[1];
      FDisplayLatch[1] := FDisplayLatch[0];
      FDisplayLatch[0] := Reg16(0);
      Enable := FDisplayLatch[2] and D;
    end;

    if (Cycle = 40) or ((Cycle and 1 = 0) and (D and $1080 = $1000) and ((FObjectFetch.Index < 128) or FObjectDrawing)) then
      ClockObject(Cycle);

    if Line >= 160 then
    begin
      Inc(Cycle);
      Continue;
    end;

    if Cycle = 6 then
      ClockAffine;

    if (D or FDisplayLatch[2]) and $80 <> 0 then
    begin
      if (Cycle >= 50) and (Cycle < 1010) and ((Cycle - 50) and 3 = 0) then
        FFrame[Line * 240 + (Cycle - 50) div 4] := $FFFFFFFF;
      Inc(Cycle);
      Continue;
    end;

    var BG := Cycle and 3;
    if Cycle <= 1006 then
      case Mode of
        0, 1:
          if (Mode = 0) or (BG < 2) then
          begin
            if Enable and (1 shl (8 + BG)) <> 0 then
            begin
              var local := Cycle - 4 - BG;
              var Fetch: PGBATileFetch := @FFetch[BG];
              if (local >= 0) and
                (((local < 988) and ((local shr 2 and 7) = (TextMapPhases shr (BG * 3) and 7))) or
                ((Fetch.Remaining > 0) and (local = Fetch.NextCycle))) then
                ClockTextBackground(BG, Cycle);
            end;
          end
          else if Enable and $400 <> 0 then
            ClockAffineBackground(2, Cycle, D);
        2:
          begin
            BG := 3 - BG div 2;
            if Enable and (1 shl (8 + BG)) <> 0 then
              ClockAffineBackground(BG, Cycle, D);
          end;
        3..5:
          if (BG = 3) and (Enable and $400 <> 0) then
            ClockAffineBackground(2, Cycle, D);
      end;
    if (Cycle >= 46) and (Cycle <= 1006) then
      case Cycle and 3 of
        3:
          begin
            FMergeMainColor := FMergeTop and $7FFF;
            if FMergeTop and $8000 = 0 then
            begin
              FMemoryPorts := FMemoryPorts or 1;
              FMergeMainColor := PAL16(FMergeTop);
            end;
          end;
        1:
          begin
            FMergeSubColor := FMergeBottom and $7FFF;
            var Blend := Reg16($50);
            var Alpha := ((Blend shr 6 and 3 = 1) or FMergeSemi) and (FMergeMask and $20 <> 0) and
              (Blend and (1 shl (8 + FMergeBottomLayer)) <> 0) and
              (FMergeSemi or (Blend and (1 shl FMergeTopLayer) <> 0));
            if Alpha and (FMergeBottom and $8000 = 0) then
            begin
              FMemoryPorts := FMemoryPorts or 1;
              FMergeSubColor := PAL16(FMergeBottom);
            end;
          end;
        2:
          begin
            var X := (Cycle - 46) shr 2;
            if X > 0 then
            begin
              var Position := Line * 240 + X - 1;
              FFrame[Position] := LookupColor(EffectColor(FMergeMainColor, FMergeSubColor,
                    FMergeTopLayer, FMergeBottomLayer, FMergeMask, FMergeSemi));
              if (X and 1 = 0) and (IO[2] and 1 <> 0) then
              begin
                var A := FFrame[Position - 1];
                var B := FFrame[Position];
                FFrame[Position - 1] := (A and $FFFF00FF) or (B and $FF00);
                FFrame[Position] := (B and $FFFF00FF) or (A and $FF00);
              end;
            end;
            if X < 240 then
            begin
              if FWindowCursor <= Cycle div 4 then
                AdvanceWindows(Cycle div 4);
              MergeLayers(X);
            end;
          end;
      end;
    Inc(Cycle);
  end;

  // Preserve comparator history before the next CPU/DMA register write.
  var WindowEnd := Min(255, LastCycle div 4);
  if (WindowEnd >= FWindowCursor) or ((D and $6000 = 0) and (FWindowX[0] or FWindowX[1])) then
    AdvanceWindows(WindowEnd);
end;

initialization
  for var Bank := 0 to 15 do
    for var Data := 0 to 255 do
    begin
      var First: Integer := Data and 15;
      var Second: Integer := Data shr 4;
      if First = 0 then
        First := -1
      else
        Inc(First, Bank * 16);
      if Second = 0 then
        Second := -1
      else
        Inc(Second, Bank * 16);
      GBATextPairs[Bank, Data].First := First;
      GBATextPairs[Bank, Data].Second := Second;
      GBATextPairs[Bank + 16, Data].First := Second;
      GBATextPairs[Bank + 16, Data].Second := First;
    end;
  for var Value := 0 to High(GBAColors) do
  begin
    var R := Value and 31;
    var G := (Value shr 5) and 31;
    var B := (Value shr 10) and 31;
    GBAColors[Value] :=
      $FF000000 or
      (Cardinal((R shl 3) or (R shr 2)) shl 16) or
      (Cardinal((G shl 3) or (G shr 2)) shl 8) or
      (Cardinal((B shl 3) or (B shr 2)));
  end;

end.

