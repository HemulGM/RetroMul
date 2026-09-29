unit GB.GPU;

interface

uses
  GB.InterruptManager;

{$SCOPEDENUMS ON}

type
  TGPUMode = (HBlank, VBlank, OAMAccess, VRAMAccess);

type
  TScreenArray = array[0..23039] of Integer;

  TDrawCallback = reference to procedure(const Value: TScreenArray);

  TScanlineRow = array[0..159] of Integer;

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
  end;

type
  TGBSprites = array[0..39] of TSprite;

type
  TGBGPU = class
  private
    FDrawCallback: TDrawCallback;
    FCurrentMode: TGPUMode;
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
    function GetSpriteHeight: Integer;

    procedure RenderScanLine;
    procedure RenderWindow(var ScanlineRow: TScanlineRow);
    procedure RenderBackground(var ScanlineRow: TScanlineRow);
    procedure RenderSprites(const ScanlineRow: TScanlineRow);

  public
    ModeClock: Integer;
    Width, Height: Integer;
    Line, LYC: Integer;
    ScrollX, ScrollY: Integer;
    WindowX, WindowY: Integer;
    VRAM: array[0..$2000 - 1] of Integer;
    TileSet: array[0..383, 0..15, 0..7] of Integer;
    Screen: TScreenArray;
    BackgroundPalette: array[0..3] of Integer;
    SpritePalette: array[0..1, 0..3] of Integer;
    Palette: array[0..3] of Integer;

    SpriteList: TGBSprites;

    procedure Step(Cycle: Integer);

    function GetLCDStatus: Integer;
    procedure SetLCDStatus(Value: Integer);
    procedure ProcessLCDStatus;

    procedure SetLCDControl(Value: Integer);
    function GetLCDControl: Integer;

    procedure UpdateTile(Address: Integer);
    procedure BuildSprite(Address, Value: Integer);

    constructor Create(Callback: TDrawCallback); reintroduce;
  end;

implementation

{ TGBGPU }

procedure TGBGPU.BuildSprite(Address, Value: Integer);
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
      end;
  end;
end;

constructor TGBGPU.Create(Callback: TDrawCallback);
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
    end;
end;

function TGBGPU.GetLCDControl: Integer;
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

function TGBGPU.GetSpriteHeight: Integer;
begin
  if FTallSprites then
    Result := 16
  else
    Result := 8;
end;

procedure TGBGPU.SetLCDControl(Value: Integer);
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

function TGBGPU.GetLCDStatus: Integer;
begin
  // Bit 7 is unused and always reads as 1.
  Result := $80 or
    (Ord(FLYCInterruptEnabled) shl 6) or
    (Ord(FOAMInterruptEnabled) shl 5) or
    (Ord(FVBlankInterruptEnabled) shl 4) or
    (Ord(FHBlankInterruptEnabled) shl 3) or
    (Ord(Line = LYC) shl 2) or Ord(FCurrentMode);
end;

procedure TGBGPU.ProcessLCDStatus;
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
      TGBInterruptManager.Instance.RaiseInterruptByIndex(3); // LCDC_STATUS
    end;
  end
  else
    FSTATLineActive := False;
end;

procedure TGBGPU.SetLCDStatus(Value: Integer);
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

procedure TGBGPU.RenderBackground(var ScanlineRow: TScanlineRow);
begin
  var MapOffset: Integer;
  var SignedTileData: Boolean := not FUnsignedTileData;
  if FBackgroundTileMapHigh then
    MapOffset := $1c00
  else
    MapOffset := $1800;
  MapOffset := MapOffset + ((((Line + ScrollY) and $FF) shr 3) shl 5);
  var LineOffset: Integer := ScrollX shr 3;
  var X: Integer := ScrollX and 7;
  var Y: Integer := (Line + ScrollY) and 7;
  var CanvasOffset: Integer := Line * 160;
  var Tile: Integer := VRAM[MapOffset + LineOffset];
  if SignedTileData and (Tile < 128) then
    Tile := Tile + 256;
  for var I := 0 to 159 do
  begin
    var ColorIndex := TileSet[Tile][Y][X];
    Screen[CanvasOffset] := BackgroundPalette[ColorIndex];

    CanvasOffset := CanvasOffset + 1;
    ScanlineRow[I] := ColorIndex;
    X := X + 1;
    if X = 8 then
    begin
      X := 0;
      LineOffset := (LineOffset + 1) and 31;
      Tile := VRAM[MapOffset + LineOffset];
      if SignedTileData and (Tile < 128) then
        Tile := Tile + 256;
    end;
  end;
end;

procedure TGBGPU.RenderWindow(var ScanlineRow: TScanlineRow);
begin
  if not (FWindowEnabled and FWindowTriggered) or (WindowX > 166) then
    Exit;

  var MapBase: Integer;
  if FWindowTileMapHigh then
    MapBase := $1C00
  else
    MapBase := $1800;
  Inc(MapBase, (FWindowLine shr 3) * 32);
  var StartX: Integer := WindowX - 7;
  if StartX < 0 then
    StartX := 0;
  for var X := StartX to 159 do
  begin
    var WindowPixel: Integer := X - (WindowX - 7);
    var Tile: Integer := VRAM[MapBase + (WindowPixel shr 3)];
    if (not FUnsignedTileData) and (Tile < 128) then
      Inc(Tile, 256);
    var ColorIndex: Integer := TileSet[Tile][FWindowLine and 7][WindowPixel and 7];
    ScanlineRow[X] := ColorIndex;
    Screen[Line * 160 + X] := BackgroundPalette[ColorIndex];
  end;
  Inc(FWindowLine);
end;

procedure TGBGPU.RenderScanLine;
begin
  if Line = WindowY then
    FWindowTriggered := True;
  var ScanlineRow: TScanlineRow;
  FillChar(ScanlineRow, SizeOf(ScanlineRow), 0);
  for var X := 0 to 159 do
    Screen[Line * 160 + X] := Palette[0];
  if FBackgroundEnabled then
  begin
    RenderBackground(ScanlineRow);
    RenderWindow(ScanlineRow);
  end;
  if FSpritesEnabled then
    RenderSprites(ScanlineRow);
end;

procedure TGBGPU.RenderSprites(const ScanlineRow: TScanlineRow);
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
  // DMG pixel priority: lower X first, then lower OAM index.
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
    var PaletteIndex := Ord(Sprite.IsPalette1);
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
      var ColorIndex := TileSet[Tile][Row][SourceX];
      if ColorIndex = 0 then
        Continue;
      Claimed[X] := True;
      if (not Sprite.BelowBackground) or (ScanlineRow[X] = 0) then
        Screen[Line * 160 + X] := SpritePalette[PaletteIndex][ColorIndex];
    end;
  end;
end;

procedure TGBGPU.Step(Cycle: Integer);
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
        Duration := 172;
      TGPUMode.HBlank:
        Duration := 204;
    else
      Duration := 456;
    end;
    if ModeClock < Duration then
      Break;
    Dec(ModeClock, Duration);
    case FCurrentMode of
      TGPUMode.OAMAccess:
        FCurrentMode := TGPUMode.VRAMAccess;
      TGPUMode.VRAMAccess:
        begin
          FCurrentMode := TGPUMode.HBlank;
          RenderScanLine;
        end;
      TGPUMode.HBlank:
        begin
          Inc(Line);
          if Line = 144 then
          begin
            FCurrentMode := TGPUMode.VBlank;
            TGBInterruptManager.Instance.RaiseInterruptByIndex(4);
            ProcessLCDStatus;
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

procedure TGBGPU.UpdateTile(Address: Integer);
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
    if (VRAM[Address] and Sx) <> 0 then
      Tmp1 := 1
    else
      Tmp1 := 0;
    if (VRAM[Address + 1] and Sx) <> 0 then
      Tmp2 := 2
    else
      Tmp2 := 0;
    var Value := Tmp1 or Tmp2;
    TileSet[Tile][Y][I] := Value;
  end;
end;

end.

