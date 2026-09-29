unit GBC.GPU;

interface

uses
  GBC.InterruptManager;

{$SCOPEDENUMS ON}

type
  TGPUMode = (HBlank, VBlank, OAMAccess, VRAMAccess);

type
  TScreenArray = array[0..23039] of Integer;

  TDrawCallback = reference to procedure(const Value: TScreenArray);
  THBlankCallback = procedure of object;

  TScanlineRow = array[0..159] of Integer;
  TScanlinePriorityRow = array[0..159] of Boolean;

  TRGB32 = packed record
    B, G, R, A: Byte;
  end;

  TRGB32Array = packed array[0..MaxInt div SizeOf(TRGB32) - 1] of TRGB32;

  PRGB32Array = ^TRGB32Array;

type
  TSprite = record
    X: Integer;
    Y: Integer;
    TileNumber: Integer;
    BelowBackground: Boolean;
    IsXFlip: Boolean;
    IsYFlip: Boolean;
    IsPalette1: Boolean;
    PaletteIndex: Integer;
    VRAMBank: Integer;
  end;

type
  TGBCSprites = array[0..39] of TSprite;

type
  TGBCGPU = class
  private
    FDrawCallback: TDrawCallback;
    FHBlankCallback: THBlankCallback;
    FCurrentMode: TGPUMode;
    FMode3Cycles: Integer;
    FWindowLine: Integer;
    FWindowTriggered: Boolean;
    FSTATLineActive: Boolean;
    FLYCInterruptEnabled: Boolean;
    FOAMInterruptEnabled: Boolean;
    FVBlankInterruptEnabled: Boolean;
    FHBlankInterruptEnabled: Boolean;
    FLineMatchesLYC: Boolean;

    FLCDEnabled: Boolean;
    FWindowTileMapHigh: Boolean;
    FWindowEnabled: Boolean;
    FUnsignedTileData: Boolean;
    FBackgroundTileMapHigh: Boolean;
    FTallSprites: Boolean;
    FSpritesEnabled: Boolean;
    FBackgroundEnabled: Boolean;
    FCGBMode: Boolean;
    FVBK: Byte;
    FBGPaletteIndex, FOBJPaletteIndex: Byte;
    FBGPaletteRAM, FOBJPaletteRAM: array[0..63] of Byte;
    FColorIndexBuffer, FPaletteIndexBuffer: array[0..23039] of Byte;
    FObjectPixelBuffer: array[0..23039] of Boolean;
    FDisplayVRAM, FDisplayVRAMBank1: array[0..$2000 - 1] of Integer;
    function CGBColor(const PaletteRAM: array of Byte; PaletteIndex, ColorIndex: Integer): Integer;
    function PixelColor(IsObject: Boolean; PaletteIndex, ColorIndex: Integer): Integer;
    function GetSpriteHeight: Integer;
    function GetMode3Cycles: Integer;
    function DisplayTilePixel(Bank, Tile, Y, X: Integer): Integer;
    procedure SnapshotDisplayVRAM;

    procedure RenderScanLine;
    procedure ResolveCGBFrame;
    procedure RenderWindow(var ScanlineRow: TScanlineRow;
      var PriorityRow: TScanlinePriorityRow);
    procedure RenderBackground(var ScanlineRow: TScanlineRow;
      var PriorityRow: TScanlinePriorityRow);
    procedure RenderSprites(const ScanlineRow: TScanlineRow;
      const PriorityRow: TScanlinePriorityRow);

  public
    ModeClock: Integer;
    Width, Height: Integer;
    Line, LYC: Integer;
    ScrollX, ScrollY: Integer;
    WindowX, WindowY: Integer;
    VRAM: array[0..$2000 - 1] of Integer;
    VRAMBank1: array[0..$2000 - 1] of Integer;
    TileSet: array[0..1, 0..383, 0..15, 0..7] of Integer;
    Screen: TScreenArray;
    BackgroundPalette: array[0..3] of Integer;
    SpritePalette: array[0..1, 0..3] of Integer;
    Palette: array[0..3] of Integer;

    SpriteList: TGBCSprites;

    procedure Step(Cycle: Integer);

    function GetLCDStatus: Integer;
    procedure SetLCDStatus(Value: Integer);
    procedure ProcessLCDStatus;

    procedure SetLCDControl(Value: Integer);
    function GetLCDControl: Integer;
    procedure SetCGBMode(Value: Boolean);
    procedure SetHBlankCallback(const Value: THBlankCallback);
    function CanAccessVRAM: Boolean;

    procedure UpdateTile(Address: Integer);
    procedure BuildSprite(Address, Value: Integer);
    function ReadVRAM(Address: Integer): Byte;
    procedure WriteVRAM(Address: Integer; Value: Byte);
    function GetVBK: Byte;
    procedure SetVBK(Value: Byte);
    function ReadCGBPalette(Address: Integer): Byte;
    procedure WriteCGBPalette(Address: Integer; Value: Byte);

    constructor Create(Callback: TDrawCallback); reintroduce;
  end;

implementation

const
  DefaultCGBColors: array[0..3] of Word = ($7FFF, $56B5, $294A, $0000);

function TGBCGPU.CGBColor(const PaletteRAM: array of Byte; PaletteIndex, ColorIndex: Integer): Integer;
var
  Value, R, G, B: Integer;
begin
  // CGB attributes carry only palette[2:0] and color[1:0].  Keep palette
  // RAM addressing inside its eight palettes even if a caller uses a wider
  // intermediate Integer while rendering a newly loaded screen.
  PaletteIndex := PaletteIndex and 7;
  ColorIndex := ColorIndex and 3;
  Value := PaletteRAM[(PaletteIndex * 8) + (ColorIndex * 2)] or
    (PaletteRAM[(PaletteIndex * 8) + (ColorIndex * 2) + 1] shl 8);
  R := (Value and $1F) * 255 div 31;
  G := ((Value shr 5) and $1F) * 255 div 31;
  B := ((Value shr 10) and $1F) * 255 div 31;
  // TScreenArray stores signed Integers.  Do not use $FF000000 here: with
  // range checks enabled Delphi treats that literal as an unsigned value and
  // raises ERangeError before the bit pattern can be assigned.  -$01000000
  // is the identical opaque-alpha ARGB bit pattern in the signed domain.
  Result := -$01000000 or (R shl 16) or (G shl 8) or B;
end;

function TGBCGPU.PixelColor(IsObject: Boolean; PaletteIndex, ColorIndex: Integer): Integer;
const
  DMGR: array[0..3] of Integer = ($E0, $88, $34, $08);
  DMGG: array[0..3] of Integer = ($F8, $C0, $68, $18);
  DMGB: array[0..3] of Integer = ($D0, $70, $56, $20);
var
  Shade: Integer;
begin
  if FCGBMode then
  begin
    if IsObject then
      Result := CGBColor(FOBJPaletteRAM, PaletteIndex, ColorIndex)
    else
      Result := CGBColor(FBGPaletteRAM, PaletteIndex, ColorIndex);
    Exit;
  end;
  if IsObject then
  begin
    if PaletteIndex = 0 then
      Shade := SpritePalette[0][ColorIndex]
    else
      Shade := SpritePalette[1][ColorIndex];
  end
  else
    Shade := BackgroundPalette[ColorIndex];
  Result := -$01000000 or (DMGR[Shade] shl 16) or
    (DMGG[Shade] shl 8) or DMGB[Shade];
end;

procedure TGBCGPU.SetCGBMode(Value: Boolean);
begin
  FCGBMode := Value;
  if Value then
    for var PaletteIndex := 0 to 7 do
      for var ColorIndex := 0 to 3 do
      begin
        FBGPaletteRAM[PaletteIndex * 8 + ColorIndex * 2] := DefaultCGBColors[ColorIndex] and $FF;
        FBGPaletteRAM[PaletteIndex * 8 + ColorIndex * 2 + 1] := DefaultCGBColors[ColorIndex] shr 8;
        FOBJPaletteRAM[PaletteIndex * 8 + ColorIndex * 2] := DefaultCGBColors[ColorIndex] and $FF;
        FOBJPaletteRAM[PaletteIndex * 8 + ColorIndex * 2 + 1] := DefaultCGBColors[ColorIndex] shr 8;
      end;
end;

function TGBCGPU.ReadVRAM(Address: Integer): Byte;
begin
  Address := Address and $1FFF;
  if (FVBK and 1) <> 0 then
    Result := VRAMBank1[Address]
  else
    Result := VRAM[Address];
end;

procedure TGBCGPU.WriteVRAM(Address: Integer; Value: Byte);
begin
  Address := Address and $1FFF;
  if (FVBK and 1) <> 0 then
    VRAMBank1[Address] := Value
  else
    VRAM[Address] := Value;
  // $1800..$1FFF is the tile-map area, not tile data.  UpdateTile has 384
  // decoded tile slots ($0000..$17FF), so map writes must not enter it.
  if Address <= $17FF then
    UpdateTile(Address);
end;

function TGBCGPU.GetVBK: Byte;
begin
  Result := $FE or (FVBK and 1);
end;

procedure TGBCGPU.SetVBK(Value: Byte);
begin
  FVBK := Value and 1;
end;

function TGBCGPU.ReadCGBPalette(Address: Integer): Byte;
begin
  case Address of
    $FF68:
      Result := FBGPaletteIndex;
    $FF69:
      Result := FBGPaletteRAM[FBGPaletteIndex and $3F];
    $FF6A:
      Result := FOBJPaletteIndex;
  else
    Result := FOBJPaletteRAM[FOBJPaletteIndex and $3F];
  end;
end;

procedure TGBCGPU.WriteCGBPalette(Address: Integer; Value: Byte);
begin
  case Address of
    $FF68:
      FBGPaletteIndex := Value and $BF;
    $FF69:
      begin
        FBGPaletteRAM[FBGPaletteIndex and $3F] := Value;
        if (FBGPaletteIndex and $80) <> 0 then
          FBGPaletteIndex := $80 or ((FBGPaletteIndex + 1) and $3F);
      end;
    $FF6A:
      FOBJPaletteIndex := Value and $BF;
    $FF6B:
      begin
        FOBJPaletteRAM[FOBJPaletteIndex and $3F] := Value;
        if (FOBJPaletteIndex and $80) <> 0 then
          FOBJPaletteIndex := $80 or ((FOBJPaletteIndex + 1) and $3F);
      end;
  end;
end;

procedure TGBCGPU.SetHBlankCallback(const Value: THBlankCallback);
begin
  FHBlankCallback := Value;
end;

function TGBCGPU.CanAccessVRAM: Boolean;
begin
  // The CPU cannot use VRAM during pixel transfer (mode 3).  DMA uses
  // WriteVRAM directly and deliberately bypasses this CPU bus restriction.
  Result := (not FLCDEnabled) or (FCurrentMode <> TGPUMode.VRAMAccess);
end;

{ TGBGPU }

procedure TGBCGPU.BuildSprite(Address, Value: Integer);
begin
  var SpriteNumber: Integer := Address shr 2;
  if SpriteNumber >= 40 then
    Exit;

  case Address and $3 of
    0: // Y-coordinate
      SpriteList[SpriteNumber].Y := Value - 16;
    1: // X-coordinate
      SpriteList[SpriteNumber].X := Value - 8;
    2: // Data tile
      SpriteList[SpriteNumber].TileNumber := Value;
    3: // Options
      begin
        SpriteList[SpriteNumber].IsPalette1 := (Value and $10) <> 0;
        SpriteList[SpriteNumber].IsXFlip := (Value and $20) <> 0;
        SpriteList[SpriteNumber].IsYFlip := (Value and $40) <> 0;
        SpriteList[SpriteNumber].BelowBackground := (Value and $80) <> 0;
        SpriteList[SpriteNumber].PaletteIndex := Value and 7;
        SpriteList[SpriteNumber].VRAMBank := (Value shr 3) and 1;
      end;
  end;
end;

constructor TGBCGPU.Create(Callback: TDrawCallback);
begin
  FDrawCallback := Callback;
  Width := 160;
  Height := 144;

  FSTATLineActive := False;
  FLYCInterruptEnabled := False;
  FOAMInterruptEnabled := False;
  FVBlankInterruptEnabled := False;
  FHBlankInterruptEnabled := False;
  FLineMatchesLYC := False;

  FLCDEnabled := True;             //Bit 7 - LCD Display Enable             (0=Off, 1=On)
  FWindowTileMapHigh := False;     //Bit 6 - Window Tile Map Display Select (0=9800-9BFF, 1=9C00-9FFF)
  FWindowEnabled := False;         //Bit 5 - Window Display Enable          (0=Off, 1=On)
  FUnsignedTileData := False;      //Bit 4 - BG & Window Tile Data Select   (0=8800-97FF, 1=8000-8FFF)
  FBackgroundTileMapHigh := False; //Bit 3 - BG Tile Map Display Select     (0=9800-9BFF, 1=9C00-9FFF)
  FTallSprites := False;           //Bit 2 - OBJ (Sprite) Size              (0=8x8, 1=8x16)
  FSpritesEnabled := False;        //Bit 1 - OBJ (Sprite) Display Enable    (0=Off, 1=On)
  FBackgroundEnabled := False;     //Bit 0 - BG/Window Display/Priority     (0=Off, 1=On)
  FCGBMode := False;

  BackgroundPalette[0] := 0;
  BackgroundPalette[1] := 3;
  BackgroundPalette[2] := 3;
  BackgroundPalette[3] := 3;

  SpritePalette[0][0] := 0;
  SpritePalette[0][1] := 3;
  SpritePalette[0][2] := 3;
  SpritePalette[0][3] := 3;
  SpritePalette[1][0] := 0;
  SpritePalette[1][1] := 3;
  SpritePalette[1][2] := 3;
  SpritePalette[1][3] := 3;

  Palette[0] := 0;
  Palette[1] := 1;
  Palette[2] := 2;
  Palette[3] := 3;

  ModeClock := 0;
  FMode3Cycles := 172;
  SnapshotDisplayVRAM;
  FCurrentMode := TGPUMode.OAMAccess;
  SetLCDControl($91);

  for var I := 0 to 39 do
    with SpriteList[I] do
    begin
      Y := -16; // Y-coordinate of top-left corner, (Value stored is Y-coordinate minus 16)
      X := -8;  // X-coordinate of top-left corner, (Value stored is X-coordinate minus 8)
      TileNumber := 0;
      BelowBackground := False; // false = above background, true = below background
      IsYFlip := False;
      IsXFlip := False;
      IsPalette1 := False; // false = palette 0, true = palette 1
      PaletteIndex := 0;
      VRAMBank := 0;
    end;
end;

function TGBCGPU.GetLCDControl: Integer;
begin
  Result :=
    (Ord(FLCDEnabled) shl 7) or
    (Ord(FWindowTileMapHigh) shl 6) or
    (Ord(FWindowEnabled) shl 5) or
    (Ord(FUnsignedTileData) shl 4) or
    (Ord(FBackgroundTileMapHigh) shl 3) or
    (Ord(FTallSprites) shl 2) or
    (Ord(FSpritesEnabled) shl 1) or Ord(FBackgroundEnabled);
end;

function TGBCGPU.GetSpriteHeight: Integer;
begin
  if FTallSprites then
    Result := 16
  else
    Result := 8;
end;

procedure TGBCGPU.SetLCDControl(Value: Integer);
begin
  var NewLCDEnable: Boolean := Value and $80 <> 0;
  var NewWndTileMapDisplaySelect: Boolean := Value and $40 <> 0;
  var NewWndDisplayEnable: Boolean := Value and $20 <> 0;
  var NewBGAndWndTileDataSelect: Boolean := Value and $10 <> 0;
  var NewBGTileMapDisplaySelect: Boolean := Value and $8 <> 0;
  var NewTallSpriteMode: Boolean := Value and $4 <> 0;
  var NewSpriteDisplayEnable: Boolean := Value and $2 <> 0;
  var NewBGWndDisplayPriority: Boolean := Value and $1 <> 0;

  if FLCDEnabled <> NewLCDEnable then
  begin
    Line := 0;
    ModeClock := 0;
    FWindowLine := 0;
    FWindowTriggered := False;
    FSTATLineActive := False;
    if NewLCDEnable then
      FCurrentMode := TGPUMode.OAMAccess
    else
    begin
      FCurrentMode := TGPUMode.HBlank;
      FillChar(Screen, SizeOf(Screen), 0);
    end;
  end;

  FLCDEnabled := NewLCDEnable;
  FWindowTileMapHigh := NewWndTileMapDisplaySelect;
  FWindowEnabled := NewWndDisplayEnable;
  FUnsignedTileData := NewBGAndWndTileDataSelect;
  FBackgroundTileMapHigh := NewBGTileMapDisplaySelect;
  FTallSprites := NewTallSpriteMode;
  FSpritesEnabled := NewSpriteDisplayEnable;
  FBackgroundEnabled := NewBGWndDisplayPriority;
end;

function TGBCGPU.GetLCDStatus: Integer;
begin
  // Bit 7 is unused and always reads as 1.
  Result := $80 or
    (Ord(FLYCInterruptEnabled) shl 6) or
    (Ord(FOAMInterruptEnabled) shl 5) or
    (Ord(FVBlankInterruptEnabled) shl 4) or
    (Ord(FHBlankInterruptEnabled) shl 3) or
    (Ord(Line = LYC) shl 2) or Ord(FCurrentMode);
end;

procedure TGBCGPU.ProcessLCDStatus;
begin
  if not FLCDEnabled then
  begin
    FSTATLineActive := False;
    Exit;
  end;
  FLineMatchesLYC := Line = LYC;
  // from The Cycle Accurate Game Boy Document (TCAGBD.pdf)
  if (FLineMatchesLYC and FLYCInterruptEnabled) or
    ((Ord(FCurrentMode) = 0) and FHBlankInterruptEnabled) or
    ((Ord(FCurrentMode) = 2) and FOAMInterruptEnabled) or
    ((Ord(FCurrentMode) = 1) and (FOAMInterruptEnabled or FVBlankInterruptEnabled)) then
  begin
    if not FSTATLineActive then
    begin
      FSTATLineActive := True;
      TGBCInterruptManager.Instance.RaiseInterruptByIndex(3); // LCDC_STATUS
    end;
  end
  else
    FSTATLineActive := False;
end;

procedure TGBCGPU.SetLCDStatus(Value: Integer);
begin
  // bit 6 is ly==lyc enable
  FLYCInterruptEnabled := (Value and $40) <> 0;
  // bit 5 is mode 2 enable
  FOAMInterruptEnabled := (Value and $20) <> 0;
  // bit 4 is mode 1 enable
  FVBlankInterruptEnabled := (Value and $10) <> 0;
  // bit 3 is mode 0 enable
  FHBlankInterruptEnabled := (Value and $8) <> 0;
end;

procedure TGBCGPU.RenderBackground(var ScanlineRow: TScanlineRow;
  var PriorityRow: TScanlinePriorityRow);
begin
  var MapBase := $1800;
  if FBackgroundTileMapHigh then
    MapBase := $1C00;
  var WorldY := (Line + ScrollY) and $FF;
  for var I := 0 to 159 do
  begin
    var WorldX := (ScrollX + I) and $FF;
    var MapAddress := MapBase + ((WorldY shr 3) shl 5) + (WorldX shr 3);
    var Tile := FDisplayVRAM[MapAddress];
    var Attribute := 0;
    if FCGBMode then
      Attribute := FDisplayVRAMBank1[MapAddress];
    if (not FUnsignedTileData) and (Tile < 128) then
      Inc(Tile, 256);
    var TileX := WorldX and 7;
    var TileY := WorldY and 7;
    if (Attribute and $20) <> 0 then
      TileX := 7 - TileX;
    if (Attribute and $40) <> 0 then
      TileY := 7 - TileY;
    var ColorIndex := DisplayTilePixel((Attribute shr 3) and 1, Tile, TileY, TileX);
    Screen[Line * 160 + I] := PixelColor(False, Attribute and 7, ColorIndex);
    FColorIndexBuffer[Line * 160 + I] := ColorIndex;
    FPaletteIndexBuffer[Line * 160 + I] := Attribute and 7;
    FObjectPixelBuffer[Line * 160 + I] := False;
    ScanlineRow[I] := ColorIndex;
    PriorityRow[I] := FCGBMode and ((Attribute and $80) <> 0);
  end;
end;

function TGBCGPU.GetMode3Cycles: Integer;
begin
  // Fine X scrolling and window startup delay the pixel fetcher.  HBlank is
  // shortened by the same amount so a scanline remains exactly 456 cycles.
  Result := 172 + (ScrollX and 7);
  if FWindowEnabled and (Line >= WindowY) and (WindowX <= 166) then
    Inc(Result, 6);
  if Result > 376 then
    Result := 376;
end;

function TGBCGPU.DisplayTilePixel(Bank, Tile, Y, X: Integer): Integer;
var
  Address, LowByte, HighByte: Integer;
begin
  // Each VRAM bank contains 384 tile slots ($0000..$17FF).  A malformed or
  // transient map value must not address the map area beyond this range.
  Tile := Tile mod 384;
  if Tile < 0 then
    Inc(Tile, 384);
  Y := Y and 7;
  X := X and 7;
  Address := Tile * 16 + Y * 2;
  if Bank = 0 then
  begin
    LowByte := FDisplayVRAM[Address];
    HighByte := FDisplayVRAM[Address + 1];
  end
  else
  begin
    LowByte := FDisplayVRAMBank1[Address];
    HighByte := FDisplayVRAMBank1[Address + 1];
  end;
  Result := ((LowByte shr (7 - X)) and 1) or
    (((HighByte shr (7 - X)) and 1) shl 1);
end;

procedure TGBCGPU.SnapshotDisplayVRAM;
begin
  Move(VRAM, FDisplayVRAM, SizeOf(VRAM));
  Move(VRAMBank1, FDisplayVRAMBank1, SizeOf(VRAMBank1));
end;

procedure TGBCGPU.RenderWindow(var ScanlineRow: TScanlineRow;
  var PriorityRow: TScanlinePriorityRow);
begin
  if not (FWindowEnabled and FWindowTriggered) or (WindowX > 166) then
    Exit;

  var MapBase: Integer;
  if FWindowTileMapHigh then
    MapBase := $1C00
  else
    MapBase := $1800;
  var StartX: Integer := WindowX - 7;
  if StartX < 0 then
    StartX := 0;
  for var X := StartX to 159 do
  begin
    var WindowPixel: Integer := X - (WindowX - 7);
    var MapAddress := MapBase + ((FWindowLine shr 3) * 32) + (WindowPixel shr 3);
    var Tile: Integer := FDisplayVRAM[MapAddress];
    var Attribute := 0;
    if FCGBMode then
      Attribute := FDisplayVRAMBank1[MapAddress];
    if (not FUnsignedTileData) and (Tile < 128) then
      Inc(Tile, 256);
    var TileX := WindowPixel and 7;
    var TileY := FWindowLine and 7;
    if (Attribute and $20) <> 0 then
      TileX := 7 - TileX;
    if (Attribute and $40) <> 0 then
      TileY := 7 - TileY;
    var ColorIndex: Integer := DisplayTilePixel((Attribute shr 3) and 1,
      Tile, TileY, TileX);
    ScanlineRow[X] := ColorIndex;
    PriorityRow[X] := FCGBMode and ((Attribute and $80) <> 0);
    Screen[Line * 160 + X] := PixelColor(False, Attribute and 7, ColorIndex);
    FColorIndexBuffer[Line * 160 + X] := ColorIndex;
    FPaletteIndexBuffer[Line * 160 + X] := Attribute and 7;
    FObjectPixelBuffer[Line * 160 + X] := False;
  end;
  Inc(FWindowLine);
end;

procedure TGBCGPU.RenderScanLine;
begin
  if Line = WindowY then
    FWindowTriggered := True;
  var ScanlineRow: TScanlineRow;
  var PriorityRow: TScanlinePriorityRow;
  FillChar(ScanlineRow, SizeOf(ScanlineRow), 0);
  FillChar(PriorityRow, SizeOf(PriorityRow), 0);
  for var X := 0 to 159 do
  begin
    Screen[Line * 160 + X] := PixelColor(False, 0, 0);
    FColorIndexBuffer[Line * 160 + X] := 0;
    FPaletteIndexBuffer[Line * 160 + X] := 0;
    FObjectPixelBuffer[Line * 160 + X] := False;
  end;
  // In CGB mode LCDC.0 controls BG-to-OBJ priority, not whether the BG and
  // window generators run.  Suppressing them here produced a black screen in
  // titles which clear the priority bit for their sprite layers.
  if FCGBMode or FBackgroundEnabled then
  begin
    RenderBackground(ScanlineRow, PriorityRow);
    RenderWindow(ScanlineRow, PriorityRow);
  end;
  if FSpritesEnabled then
    RenderSprites(ScanlineRow, PriorityRow);
end;

procedure TGBCGPU.RenderSprites(const ScanlineRow: TScanlineRow;
  const PriorityRow: TScanlinePriorityRow);
begin
  var SpriteSize := GetSpriteHeight;
  var Count: Integer := 0;
  // OAM selection is limited to the first ten objects intersecting this line.
  var Selected: array[0..9] of Integer;
  for var I := 0 to 39 do
    if (SpriteList[I].Y <= Line) and (SpriteList[I].Y + SpriteSize > Line) then
    begin
      Selected[Count] := I;
      Inc(Count);
      if Count = 10 then
        Break;
    end;
  // DMG chooses the lowest X coordinate first. CGB preserves OAM order.
  if not FCGBMode then
    for var I := 1 to Count - 1 do
    begin
      var Index := Selected[I];
      var J := I - 1;
      while J >= 0 do
      begin
        if SpriteList[Selected[J]].X <= SpriteList[Index].X then
          Break;
        Selected[J + 1] := Selected[J];
        Dec(J);
      end;
      Selected[J + 1] := Index;
    end;
  var Claimed: array[0..159] of Boolean;
  FillChar(Claimed, SizeOf(Claimed), 0);
  for var I := 0 to Count - 1 do
  begin
    var Sprite := SpriteList[Selected[I]];
    var Row := Line - Sprite.Y;
    if Sprite.IsYFlip then
      Row := SpriteSize - 1 - Row;
    var Tile := Sprite.TileNumber;
    if SpriteSize = 16 then
      Tile := (Tile and $FE) + (Row shr 3);
    Row := Row and 7;
    var PaletteIndex := Sprite.PaletteIndex;
    for var J := 0 to 7 do
    begin
      var X := Sprite.X + J;
      if (X < 0) or (X >= 160) then
        Continue;
      if Claimed[X] then
        Continue;
      var SourceX := J;
      if Sprite.IsXFlip then
        SourceX := 7 - J;
      var ColorIndex := DisplayTilePixel(Sprite.VRAMBank, Tile, Row, SourceX);
      if ColorIndex = 0 then
        Continue;
      Claimed[X] := True;
      // CGB tile attributes can force every non-zero OBJ pixel behind a
      // non-zero background pixel. DMG has no per-tile priority bit.
      var DrawSprite: Boolean;
      if FCGBMode then
        DrawSprite := (not FBackgroundEnabled) or
          ((not PriorityRow[X]) and
           ((not Sprite.BelowBackground) or (ScanlineRow[X] = 0)))
      else
        DrawSprite := (not Sprite.BelowBackground) or (ScanlineRow[X] = 0);
      if DrawSprite then
      begin
        if FCGBMode then
        begin
          Screen[Line * 160 + X] := PixelColor(True, PaletteIndex, ColorIndex);
          FColorIndexBuffer[Line * 160 + X] := ColorIndex;
          FPaletteIndexBuffer[Line * 160 + X] := PaletteIndex;
          FObjectPixelBuffer[Line * 160 + X] := True;
        end
        else if Sprite.IsPalette1 then
          Screen[Line * 160 + X] := PixelColor(True, 1, ColorIndex)
        else
          Screen[Line * 160 + X] := PixelColor(True, 0, ColorIndex);
      end;
    end;
  end;
end;

procedure TGBCGPU.ResolveCGBFrame;
begin
  if not FCGBMode then
    Exit;
  for var I := 0 to High(Screen) do
    Screen[I] := PixelColor(FObjectPixelBuffer[I], FPaletteIndexBuffer[I],
      FColorIndexBuffer[I]);
end;

procedure TGBCGPU.Step(Cycle: Integer);
begin
  if not FLCDEnabled then
    Exit;
  var Duration: Integer;
  Inc(ModeClock, Cycle);
  while True do
  begin
    case FCurrentMode of
      TGPUMode.OAMAccess:
        Duration := 80;
      TGPUMode.VRAMAccess:
        Duration := FMode3Cycles;
      TGPUMode.HBlank:
        Duration := 456 - 80 - FMode3Cycles;
    else
      Duration := 456;
    end;
    if ModeClock < Duration then
      Break;
    Dec(ModeClock, Duration);
    case FCurrentMode of
      TGPUMode.OAMAccess:
        begin
          FMode3Cycles := GetMode3Cycles;
          FCurrentMode := TGPUMode.VRAMAccess;
        end;
      TGPUMode.VRAMAccess:
        begin
          FCurrentMode := TGPUMode.HBlank;
          RenderScanLine;
          if Assigned(FHBlankCallback) then
            FHBlankCallback;
        end;
      TGPUMode.HBlank:
        begin
          Inc(Line);
          if Line = 144 then
          begin
            FCurrentMode := TGPUMode.VBlank;
            TGBCInterruptManager.Instance.RaiseInterruptByIndex(4);
            ProcessLCDStatus;
            ResolveCGBFrame;
            if Assigned(FDrawCallback) then
              FDrawCallback(Screen);
          end
          else
            FCurrentMode := TGPUMode.OAMAccess;
        end;
      TGPUMode.VBlank:
        begin
          Inc(Line);
          if Line > 153 then
          begin
            Line := 0;
            SnapshotDisplayVRAM;
            FWindowLine := 0;
            FWindowTriggered := False;
            FCurrentMode := TGPUMode.OAMAccess;
          end;
        end;
    end;
    ProcessLCDStatus;
    if not FLCDEnabled then
      Exit;
  end;
  ProcessLCDStatus;
end;

procedure TGBCGPU.UpdateTile(Address: Integer);
begin
  // get base address for this tile row
  Address := Address and $1FFE;
  // work out which tile and row was updated
  var Tile: Integer := (Address shr 4) and 511;
  var Y: Integer := (Address shr 1) and 7;
  for var i := 0 to 7 do
  begin
    // find bit index for this pixel
    var Sx: Integer := 1 shl (7 - I);
    var Tmp1, Tmp2: Integer;
    var TileLow, TileHigh: Integer;
    if FVBK and 1 <> 0 then
    begin
      TileLow := VRAMBank1[Address];
      TileHigh := VRAMBank1[Address + 1];
    end
    else
    begin
      TileLow := VRAM[Address];
      TileHigh := VRAM[Address + 1];
    end;
    if (TileLow and Sx) <> 0 then
      Tmp1 := 1
    else
      Tmp1 := 0;
    if (TileHigh and Sx) <> 0 then
      Tmp2 := 2
    else
      Tmp2 := 0;
    var Value := Tmp1 or Tmp2;
    TileSet[FVBK and 1][Tile][Y][I] := Value;
  end;
end;

end.
