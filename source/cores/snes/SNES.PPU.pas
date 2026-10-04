unit SNES.PPU;

interface

uses
  System.SysUtils, System.UITypes, Core.Snapshots;

type
  TSnesPPUState = packed record
    VRAM: array[0..65535] of Byte;
    CGRAM: array[0..511] of Byte;
    OAM: array[0..543] of Byte;
    Regs: array[0..$33] of Byte;
    ScrollX, ScrollY: array[0..3] of Word;
    Matrix: array[0..5] of SmallInt;
    M7ScrollX, M7ScrollY: SmallInt;
    VRAMAddress, VRAMBuffer, OAMAddress, OAMReload: Word;
    CGAddress: Word;
    ScrollLatch, HScrollLatch, M7Latch, OAMLatch, CGLatch: Byte;
    FixedColor: Word;
    HLatch, VLatch: Word;
    HToggle, VToggle: Boolean;
    Status: Byte;
    OddField: Boolean;
    PPU1Bus, PPU2Bus: Byte;
    Latched: Boolean;
  end;

  TSnesPPU = class
  private
    FFrame: TArray<TAlphaColor>;
    function VRAMIndex: Integer;
    procedure IncrementVRAM;
    function OAMIndex: Integer;
    function TilePixel(Base, Tile, BPP, X, Y: Integer): Integer;
    function MapEntry(Layer, Column, Row: Integer): Word;
    function OffsetEntry(Column: Integer; Vertical: Boolean): Word;
    function Palette(Index: Integer): Word;
    function Background(Layer, X, Y: Integer; out Priority: Integer): Integer;
    function Window(Layer, X: Integer): Boolean;
    function Color(Value: Word): TAlphaColor;
  public
    State: TSnesPPUState;
    constructor Create;
    procedure Reset;
    procedure Write(Address: Word; Value: Byte; V: Integer = 0);
    function Read(Address: Word; OpenBus: Byte; H, V: Integer; PAL, Odd: Boolean; LatchEnabled: Boolean = True): Byte;
    procedure LatchCounters(H, V: Integer);
    procedure RenderLine(Y: Integer; Odd: Boolean = False);
    function Width: Integer;
    function Height: Integer;
    function OutputHeight: Integer;
    procedure SerializeState(Archive: TStateArchive);
    property Pixels: TArray<TAlphaColor> read FFrame;
  end;

implementation

uses
  System.Math;

constructor TSnesPPU.Create;
begin
  inherited Create;
  SetLength(FFrame, 512 * 478);
  Reset;
end;

procedure TSnesPPU.Reset;
begin
  State := Default(TSnesPPUState);
  State.Regs[0] := $80;
  for var i := 0 to High(FFrame) do
    FFrame[i] := $FF000000;
end;

function TSnesPPU.Width: Integer;
begin
  if (State.Regs[5] and 7 in [5, 6]) or ((State.Regs[$33] and 8) <> 0) then
    Result := 512
  else
    Result := 256;
end;

function TSnesPPU.Height: Integer;
begin
  if (State.Regs[$33] and 4) <> 0 then
    Result := 239
  else
    Result := 224;
end;

function TSnesPPU.OutputHeight: Integer;
begin
  Result := Height;
  if ((State.Regs[$33] and 1) <> 0) and ((State.Regs[5] and 7) in [5, 6]) then
    Result := Result * 2;
end;

function TSnesPPU.VRAMIndex: Integer;
begin
  var A := State.VRAMAddress;
  case (State.Regs[$15] shr 2) and 3 of
    1:
      A := (A and $FF00) or ((A and $1F) shl 3) or ((A shr 5) and 7);
    2:
      A := (A and $FE00) or ((A and $3F) shl 3) or ((A shr 6) and 7);
    3:
      A := (A and $FC00) or ((A and $7F) shl 3) or ((A shr 7) and 7);
  end;
  Result := (A shl 1) and $FFFF;
end;

procedure TSnesPPU.IncrementVRAM;
const
  Increments: array[0..3] of Integer = (1, 32, 128, 128);
begin
  State.VRAMAddress := Word(State.VRAMAddress + Increments[State.Regs[$15] and 3]);
end;

function TSnesPPU.OAMIndex: Integer;
begin
  Result := State.OAMAddress and $3FF;
  if Result >= 512 then
    Result := 512 + (Result and 31);
end;

procedure TSnesPPU.Write(Address: Word; Value: Byte; V: Integer);
begin
  var R := Address and $FF;
  if R > $33 then
    Exit;

  State.Regs[R] := Value;
  case R of
    $02, $03:
      begin
        State.OAMReload := ((Word(State.Regs[3] and 1) shl 8) or State.Regs[2]) shl 1;
        State.OAMAddress := State.OAMReload;
      end;
    $04:
      begin
        var A := OAMIndex;
        if A >= 512 then
          State.OAM[A] := Value
        else if (A and 1) <> 0 then
        begin
          State.OAM[A - 1] := State.OAMLatch;
          State.OAM[A] := Value;
        end
        else
          State.OAMLatch := Value;
        State.OAMAddress := (Integer(State.OAMAddress) + 1) and $FFFF;
      end;
    $0D..$14:
      begin
        var Layer := (R - $0D) div 2;
        if (R and 1) <> 0 then
        begin
          State.ScrollX[Layer] := ((Word(Value) shl 8) or (State.ScrollLatch and $F8) or (State.HScrollLatch and 7)) and $3FF;
          State.HScrollLatch := Value;
        end
        else
          State.ScrollY[Layer] := ((Word(Value) shl 8) or State.ScrollLatch) and $3FF;
        State.ScrollLatch := Value;
        if R <= $0E then
        begin
          if R = $0D then
            State.M7ScrollX := SmallInt((Word(Value) shl 8) or State.M7Latch)
          else
            State.M7ScrollY := SmallInt((Word(Value) shl 8) or State.M7Latch);
          State.M7Latch := Value;
        end;
      end;
    $16, $17:
      begin
        State.VRAMAddress := State.Regs[$16] or (Word(State.Regs[$17]) shl 8);
        var A := VRAMIndex;
        State.VRAMBuffer := State.VRAM[A] or (Word(State.VRAM[(A + 1) and $FFFF]) shl 8);
      end;
    $18, $19:
      begin
        if ((State.Regs[0] and $80) <> 0) or (V >= Height + 1) then
          State.VRAM[(VRAMIndex + R - $18) and $FFFF] := Value;
        if ((R = $19) = ((State.Regs[$15] and $80) <> 0)) then
          IncrementVRAM;
      end;
    $1B..$1E:
      begin
        State.Matrix[R - $1B] := SmallInt((Word(Value) shl 8) or State.M7Latch);
        State.M7Latch := Value;
      end;
    $1F, $20:
      begin
        State.Matrix[R - $1B] := SmallInt((Word(Value) shl 8) or State.M7Latch);
        State.M7Latch := Value;
      end;
    $21:
      State.CGAddress := Word(Value) shl 1;
    $22:
      begin
        if (State.CGAddress and 1) = 0 then
          State.CGLatch := Value
        else
        begin
          State.CGRAM[(State.CGAddress - 1) and $1FF] := State.CGLatch;
          State.CGRAM[State.CGAddress and $1FF] := Value and $7F;
        end;
        State.CGAddress := (State.CGAddress + 1) and $1FF;
      end;
    $32:
      begin
        if (Value and $20) <> 0 then
          State.FixedColor := (State.FixedColor and $7FE0) or (Value and 31);
        if (Value and $40) <> 0 then
          State.FixedColor := (State.FixedColor and $7C1F) or ((Value and 31) shl 5);
        if (Value and $80) <> 0 then
          State.FixedColor := (State.FixedColor and $03FF) or ((Value and 31) shl 10);
      end;
  end;
end;

procedure TSnesPPU.LatchCounters(H, V: Integer);
begin
  State.HLatch := H div 4;
  State.VLatch := V;
  State.Latched := True;
end;

function TSnesPPU.Read(Address: Word; OpenBus: Byte; H, V: Integer; PAL, Odd: Boolean; LatchEnabled: Boolean): Byte;
begin
  Result := OpenBus;
  case Address of
    $2134..$2136:
      Result := Byte((Integer(State.Matrix[0]) * ShortInt(State.Matrix[1] shr 8)) shr ((Address - $2134) * 8));
    $2137:
      if LatchEnabled then
        LatchCounters(H, V);
    $2138:
      begin
        Result := State.OAM[OAMIndex];
        State.OAMAddress := (Integer(State.OAMAddress) + 1) and $FFFF;
      end;
    $2139, $213A:
      begin
        if Address = $2139 then
          Result := Byte(State.VRAMBuffer)
        else
          Result := State.VRAMBuffer shr 8;
        if ((Address = $213A) = ((State.Regs[$15] and $80) <> 0)) then
        begin
          var A := VRAMIndex;
          State.VRAMBuffer := State.VRAM[A] or (Word(State.VRAM[(A + 1) and $FFFF]) shl 8);
          IncrementVRAM;
        end;
      end;
    $213B:
      begin
        Result := State.CGRAM[State.CGAddress and $1FF];
        if (State.CGAddress and 1) <> 0 then
          Result := (Result and $7F) or (State.PPU2Bus and $80);
        State.CGAddress := (State.CGAddress + 1) and $1FF;
      end;
    $213C:
      begin
        if State.HToggle then
          Result := (State.PPU2Bus and $FE) or (State.HLatch shr 8 and 1)
        else
          Result := Byte(State.HLatch);
        State.HToggle := not State.HToggle;
      end;
    $213D:
      begin
        if State.VToggle then
          Result := (State.PPU2Bus and $FE) or (State.VLatch shr 8 and 1)
        else
          Result := Byte(State.VLatch);
        State.VToggle := not State.VToggle;
      end;
    $213E:
      Result := State.Status or (State.PPU1Bus and $10) or 1;
    $213F:
      begin
        Result := 3 or (Ord(PAL) shl 4) or (Ord(Odd) shl 7) or (Ord(State.Latched) shl 6) or (State.PPU2Bus and $20);
        if LatchEnabled then
          State.Latched := False;
        State.HToggle := False;
        State.VToggle := False;
      end;
  else
    var Reg := Address and $210F;
    if ((Reg >= $2104) and (Reg <= $2106)) or ((Reg >= $2108) and (Reg <= $210A)) then
      Result := State.PPU1Bus;
  end;
  if ((Address >= $2134) and (Address <= $2136)) or ((Address >= $2138) and (Address <= $213A)) or (Address = $213E) then
    State.PPU1Bus := Result;
  if (Address >= $213B) and (Address <= $213F) and (Address <> $213E) then
    State.PPU2Bus := Result;
end;

function TSnesPPU.Palette(Index: Integer): Word;
begin
  Index := (Index and $FF) * 2;
  Result := State.CGRAM[Index] or (Word(State.CGRAM[Index + 1]) shl 8);
end;

function TSnesPPU.TilePixel(Base, Tile, BPP, X, Y: Integer): Integer;
begin
  Result := 0;
  Base := Base + Tile * BPP * 8 + Y * 2;
  for var Plane := 0 to BPP - 1 do
    Result := Result or (((State.VRAM[(Base + (Plane div 2) * 16 + (Plane and 1)) and $FFFF] shr (7 - X)) and 1) shl Plane);
end;

function TSnesPPU.MapEntry(Layer, Column, Row: Integer): Word;
begin
  var Map := State.Regs[7 + Layer];
  var Screen := 0;
  if (Map and 1) <> 0 then
    Screen := (Column shr 5) and 1;
  if (Map and 2) <> 0 then
    Inc(Screen, ((Row shr 5) and 1) * (1 + (Map and 1)));
  var A := ((Map and $FC) shl 9) + Screen * $800 + ((Row and 31) * 32 + (Column and 31)) * 2;
  Result := State.VRAM[A and $FFFF] or (Word(State.VRAM[(A + 1) and $FFFF]) shl 8);
end;

function TSnesPPU.OffsetEntry(Column: Integer; Vertical: Boolean): Word;
begin
  var VShift := 3;
  if (State.Regs[5] and $40) <> 0 then
    VShift := 4;
  var HShift := VShift;
  if (State.Regs[5] and 7) = 6 then
    HShift := 3;
  var Row := Integer(State.ScrollY[2]);
  if Vertical then
    Inc(Row, 8);
  Result := MapEntry(2, ((Column shl 3) + (State.ScrollX[2] and $3F8)) shr HShift, Row shr VShift);
end;

function Signed13(Value: Integer): Integer;
begin
  Result := Value and $1FFF;
  if (Result and $1000) <> 0 then
    Dec(Result, $2000);
end;

function Mode7Clip(Value: Integer): Integer;
begin
  if (Value and $2000) <> 0 then
    Result := Value or not $3FF
  else
    Result := Value and $3FF;
end;

function Shift8(Value: Integer): Integer;
begin
  if Value >= 0 then
    Result := Value shr 8
  else
    Result := not ((not Value) shr 8);
end;

function TSnesPPU.Background(Layer, X, Y: Integer; out Priority: Integer): Integer;
const
  Depth: array[0..7, 0..3] of Integer = ((2, 2, 2, 2), (4, 4, 2, 0), (4, 4, 0, 0), (8, 4, 0, 0), (8, 2, 0, 0), (4, 2, 0, 0), (4, 0, 0, 0), (8, 0, 0, 0));
  LowPrio: array[0..7, 0..3] of Integer = ((8, 7, 2, 1), (6, 5, 1, 0), (3, 1, 0, 0), (3, 1, 0, 0), (3, 1, 0, 0), (3, 1, 0, 0), (1, 0, 0, 0), (3, 1, 0, 0));
  HighPrio: array[0..7, 0..3] of Integer = ((11, 10, 5, 4), (9, 8, 3, 0), (7, 5, 0, 0), (7, 5, 0, 0), (7, 5, 0, 0), (7, 5, 0, 0), (5, 0, 0, 0), (2, 0, 0, 0));
begin
  Result := -1;
  Priority := 0;
  var Mode := State.Regs[5] and 7;
  var BPP := Depth[Mode, Layer];
  if (Mode = 7) and (Layer = 1) and ((State.Regs[$33] and $40) <> 0) then
    BPP := 8;
  if BPP = 0 then
    Exit;

  var Mosaic := (State.Regs[6] shr 4) + 1;
  if (State.Regs[6] and (1 shl Layer)) <> 0 then
  begin
    X := X - X mod Mosaic;
    Y := Y - (Y - 1) mod Mosaic;
  end;
  if (Mode in [5, 6]) and ((State.Regs[$33] and 1) <> 0) then
    Y := Y * 2 + Ord(State.OddField);
  if Mode = 7 then
  begin
    if (State.Regs[$1A] and 1) <> 0 then
      X := 255 - X;
    if (State.Regs[$1A] and 2) <> 0 then
      Y := 255 - Y;
    var CenterX := Signed13(State.Matrix[4]);
    var CenterY := Signed13(State.Matrix[5]);
    var DX := Mode7Clip(Signed13(State.M7ScrollX) - CenterX);
    var DY := Mode7Clip(Signed13(State.M7ScrollY) - CenterY);
    // The three products are truncated separately before the pixel step is added.
    var PX := Shift8((Integer(State.Matrix[0]) * DX and not 63) +
      (Integer(State.Matrix[1]) * Y and not 63) + (Integer(State.Matrix[1]) * DY and not 63) +
      CenterX * 256 + Integer(State.Matrix[0]) * X);
    var PY := Shift8((Integer(State.Matrix[2]) * DX and not 63) +
      (Integer(State.Matrix[3]) * Y and not 63) + (Integer(State.Matrix[3]) * DY and not 63) +
      CenterY * 256 + Integer(State.Matrix[2]) * X);
    var Tile := 0;
    if ((PX < 0) or (PX >= 1024) or (PY < 0) or (PY >= 1024)) and ((State.Regs[$1A] and $80) <> 0) then
    begin
      if (State.Regs[$1A] and $40) = 0 then
        Exit;
    end
    else
      Tile := State.VRAM[(((PY and $3FF) div 8 * 128 + (PX and $3FF) div 8) * 2) and $FFFF];
    var Pixel := State.VRAM[(Tile * 128 + (PY and 7) * 16 + (PX and 7) * 2 + 1) and $FFFF];
    Priority := 3;
    if Layer = 1 then
    begin
      Priority := 1;
      if (Pixel and $80) <> 0 then
        Priority := 5;
      Pixel := Pixel and $7F;
    end;
    if Pixel = 0 then
      Exit;

    Result := Palette(Pixel);
    if (Layer = 0) and ((State.Regs[$30] and 1) <> 0) then
      Result := ((Pixel and 7) shl 2) or ((Pixel and $38) shl 4) or ((Pixel and $C0) shl 7);
    Exit;
  end;
  var Size := 8;
  if (State.Regs[5] and (16 shl Layer)) <> 0 then
    Size := 16;
  var Hires := Mode in [5, 6];
  var HScroll := Integer(State.ScrollX[Layer]);
  if Hires then
    HScroll := HScroll * 2;
  var VScroll := Integer(State.ScrollY[Layer]);
  // BG3's offset fetch occurs after the current column's BG1/BG2 fetch.
  var Column := X div 8;
  if Hires then
    Column := X div 16;
  if (Mode in [2, 4, 6]) and (Layer < 2) and (Column > 0) then
  begin
    var Enable := $2000 shl Layer;
    var HO := OffsetEntry(Column - 1, False);
    if Mode = 4 then
    begin
      if (HO and Enable) <> 0 then
        if (HO and $8000) <> 0 then
          VScroll := HO and $3FF
        else
          HScroll := (HScroll and 7) or (HO and $3F8);
    end
    else
    begin
      var VO := OffsetEntry(Column - 1, True);
      if (HO and Enable) <> 0 then
        HScroll := (HScroll and 7) or (HO and $3F8);
      if (VO and Enable) <> 0 then
        VScroll := VO and $3FF;
    end;
  end;
  if Hires then
    X := (X + HScroll) and $7FF
  else
    X := (X + HScroll) and $3FF;
  Y := (Y + VScroll) and $3FF;
  var TY := Y div Size;
  var TileWidth := Size;
  if Hires then
    TileWidth := 16;
  var TX := X div TileWidth;
  var Entry := MapEntry(Layer, TX, TY);
  var PX := X mod TileWidth;
  var PY := Y mod Size;
  if (Entry and $4000) <> 0 then
    PX := TileWidth - 1 - PX;
  if (Entry and $8000) <> 0 then
    PY := Size - 1 - PY;
  var Tile := (Entry and $3FF) + PX div 8 + PY div 8 * 16;
  var Base := ((State.Regs[$0B + Layer div 2] shr ((Layer and 1) * 4)) and $F) shl 13;
  var Pixel := TilePixel(Base, Tile and $3FF, BPP, PX and 7, PY and 7);
  if Pixel = 0 then
    Exit;

  Priority := LowPrio[Mode, Layer];
  if (Entry and $2000) <> 0 then
  begin
    Priority := HighPrio[Mode, Layer];
    if (Mode = 1) and (Layer = 2) and ((State.Regs[5] and 8) <> 0) then
      Priority := 11;
  end;
  var Pal := (Entry shr 10) and 7;
  if (BPP = 8) and ((State.Regs[$30] and 1) <> 0) then
  begin
    Result := ((Pixel and 7) shl 2) or ((Pal and 1) shl 1) or
      ((Pixel and $38) shl 4) or ((Pal and 2) shl 5) or
      ((Pixel and $C0) shl 7) or ((Pal and 4) shl 10);
    Exit;
  end;
  if BPP = 8 then
    Pal := 0;
  var PalBase := 0;
  if Mode = 0 then
    PalBase := Layer * 32;
  Result := Palette(PalBase + (Pal shl BPP) + Pixel);
end;

function TSnesPPU.Window(Layer, X: Integer): Boolean;
begin
  var Settings := State.Regs[$23 + Layer div 2] shr ((Layer and 1) * 4);
  var W1 := (X >= State.Regs[$26]) and (X <= State.Regs[$27]);
  var W2 := (X >= State.Regs[$28]) and (X <= State.Regs[$29]);
  if (Settings and 1) <> 0 then
    W1 := not W1;
  if (Settings and 4) <> 0 then
    W2 := not W2;
  Result := False;

  if (Settings and $A) = 2 then
    Exit(W1);
  if (Settings and $A) = 8 then
    Exit(W2);
  if (Settings and $A) <> $A then
    Exit;

  var Logic := State.Regs[$2A + Layer div 4] shr ((Layer mod 4) * 2) and 3;
  case Logic of
    0:
      Result := W1 or W2;
    1:
      Result := W1 and W2;
    2:
      Result := W1 xor W2;
    3:
      Result := not (W1 xor W2);
  end;
end;

function TSnesPPU.Color(Value: Word): TAlphaColor;
begin
  var Bright := State.Regs[0] and 15;
  var R := (Value and 31) * 255 * Bright div (31 * 15);
  var G := (Value shr 5 and 31) * 255 * Bright div (31 * 15);
  var B := (Value shr 10 and 31) * 255 * Bright div (31 * 15);
  Result := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

procedure TSnesPPU.RenderLine(Y: Integer; Odd: Boolean);
const
  ObjWidths: array[0..15] of Integer = (8, 8, 8, 16, 16, 32, 16, 16, 16, 32, 64, 32, 64, 64, 32, 32);
  ObjHeights: array[0..15] of Integer = (8, 8, 8, 16, 16, 32, 32, 32, 16, 32, 64, 32, 64, 64, 64, 32);
  SpritePrio: array[0..7, 0..3] of Integer = ((3, 6, 9, 12), (2, 4, 7, 10),
    (2, 4, 6, 8), (2, 4, 6, 8), (2, 4, 6, 8), (2, 4, 6, 8), (2, 3, 4, 6), (2, 4, 6, 7));
var
  ObjColor, ObjPriority: array[0..255] of Integer;
  ObjMath: array[0..255] of Boolean;
begin
  if (Y < 0) or (Y >= Height) then
    Exit;

  State.OddField := Odd;
  var OutputY := Y;
  if OutputHeight > Height then
    OutputY := Y * 2 + Ord(Odd);
  FillChar(ObjPriority, SizeOf(ObjPriority), 0);
  var Count := 0;
  var Tiles := 0;
  var First := 0;
  if (State.Regs[3] and $80) <> 0 then
    First := (State.OAMReload div 4) and 127;
  for var J := 0 to 127 do
  begin
    var Obj := (First + J) and 127;
    var A := Obj * 4;
    var High := State.OAM[512 + Obj div 4] shr ((Obj and 3) * 2);
    var SizeIndex := (State.Regs[1] shr 5) or ((High and 2) shl 2);
    var ObjWidth := ObjWidths[SizeIndex];
    var ObjHeight := ObjHeights[SizeIndex];
    var X: Integer := State.OAM[A] or ((High and 1) shl 8);
    if X >= 256 then
      Dec(X, 512);
    if (X <> -256) and ((X + ObjWidth <= 0) or (X > 255)) then
      Continue;

    var Row := (Y - State.OAM[A + 1]) and $FF;
    var VisibleHeight := ObjHeight;
    if (State.Regs[$33] and 2) <> 0 then
      VisibleHeight := VisibleHeight div 2;
    if Row >= VisibleHeight then
      Continue;

    Inc(Count);
    if Count > 32 then
    begin
      State.Status := State.Status or $40;
      Break;
    end;

    if (State.Regs[$33] and 2) <> 0 then
      Row := Row * 2 + Ord(Odd);
    var Flags := State.OAM[A + 3];
    if (Flags and $80) <> 0 then
      if Row < ObjWidth then
        Row := ObjWidth - 1 - Row
      else
        Row := ObjWidth * 3 - 1 - Row;
    var Base := (State.Regs[1] and 7) shl 14;
    if (Flags and 1) <> 0 then
      Inc(Base, (((State.Regs[1] shr 3) and 3) + 1) shl 13);
    for var Col := 0 to ObjWidth - 1 do
    begin
      var SX := X + Col;
      if (SX < 0) or (SX >= 256) then
        Continue;

      if (Col mod 8) = 0 then
        Inc(Tiles);
      if Tiles > 34 then
      begin
        State.Status := State.Status or $80;
        Break;
      end;

      if ObjPriority[SX] <> 0 then
        Continue;

      var PX := Col;
      if (Flags and $40) <> 0 then
        PX := ObjWidth - 1 - Col;
      var Tile := ((State.OAM[A + 2] and $F0) + (Row div 8) * 16) and $F0;
      Tile := Tile or ((State.OAM[A + 2] + PX div 8) and 15);
      var Pixel := TilePixel(Base, Tile, 4, PX and 7, Row and 7);
      if Pixel = 0 then
        Continue;

      ObjColor[SX] := Palette(128 + ((Flags shr 1) and 7) * 16 + Pixel);
      ObjMath[SX] := (Flags and 8) <> 0;
      ObjPriority[SX] := SpritePrio[State.Regs[5] and 7, (Flags shr 4) and 3];
    end;
  end;
  var W := Width;
  for var X := 0 to W - 1 do
  begin
    var ScreenX := X;
    if W = 512 then
      ScreenX := X div 2;
    var BGX := ScreenX;
    var SubX := ScreenX;
    if (State.Regs[5] and 7) in [5, 6] then
    begin
      BGX := ScreenX * 2 + 1;
      SubX := ScreenX * 2;
    end;
    var Main := Integer(Palette(0));
    var Sub := Integer(Palette(0));
    if (W = 256) and ((State.Regs[$30] and 2) = 0) then
      Sub := State.FixedColor;
    var MainPrio := 0;
    var SubPrio := 0;
    var MainLayer := 5;
    var AllowMath := True;
    for var L := 3 downto 0 do
    begin
      // BG fetches use the physical scanline (1..224); OBJ was evaluated on the
      // preceding line and therefore keeps the zero-based output Y above.
      var Priority: Integer;
      var Pixel := Background(L, BGX, Y + 1, Priority);
      if (Pixel >= 0) and ((State.Regs[$2C] and (1 shl L)) <> 0) and (Priority > MainPrio) and
        not (((State.Regs[$2E] and (1 shl L)) <> 0) and Window(L, ScreenX)) then
      begin
        Main := Pixel;
        MainPrio := Priority;
        MainLayer := L;
      end;
      if SubX <> BGX then
        Pixel := Background(L, SubX, Y + 1, Priority);
      if (Pixel >= 0) and ((State.Regs[$2D] and (1 shl L)) <> 0) and (Priority > SubPrio) and
        not (((State.Regs[$2F] and (1 shl L)) <> 0) and Window(L, ScreenX)) then
      begin
        Sub := Pixel;
        SubPrio := Priority;
      end;
    end;
    if ObjPriority[ScreenX] <> 0 then
    begin
      if ((State.Regs[$2C] and 16) <> 0) and (ObjPriority[ScreenX] > MainPrio) and
        not (((State.Regs[$2E] and 16) <> 0) and Window(4, ScreenX)) then
      begin
        Main := ObjColor[ScreenX];
        MainLayer := 4;
        AllowMath := ObjMath[ScreenX];
      end;
      if ((State.Regs[$2D] and 16) <> 0) and (ObjPriority[ScreenX] > SubPrio) and
        not (((State.Regs[$2F] and 16) <> 0) and Window(4, ScreenX)) then
      begin
        Sub := ObjColor[ScreenX];
        SubPrio := ObjPriority[ScreenX];
      end;
    end;
    var InWindow := Window(5, ScreenX);
    var Clip := State.Regs[$30] shr 6;
    var Prevent := State.Regs[$30] shr 4 and 3;
    var Clipped := (Clip = 3) or ((Clip = 1) and not InWindow) or ((Clip = 2) and InWindow);
    var MathPrevented := (Prevent = 3) or ((Prevent = 1) and not InWindow) or ((Prevent = 2) and InWindow);
    if Clipped then
      Main := 0;
    if AllowMath and ((State.Regs[$31] and (1 shl MainLayer)) <> 0) and not MathPrevented then
    begin
      var Operand := Sub;
      if ((State.Regs[$30] and 2) = 0) or (SubPrio = 0) then
        Operand := State.FixedColor;
      var Combined := 0;
      for var Component := 0 to 2 do
      begin
        var V := (Main shr (Component * 5)) and 31;
        var S := (Operand shr (Component * 5)) and 31;
        if (State.Regs[$31] and $80) <> 0 then
          V := V - S
        else
          V := V + S;
        if ((State.Regs[$31] and $40) <> 0) and not Clipped and
          (((State.Regs[$30] and 2) = 0) or (SubPrio > 0)) then
          V := V div 2;
        Combined := Combined or (EnsureRange(V, 0, 31) shl (Component * 5));
      end;
      Main := Combined;
    end;
    if (W = 512) and ((X and 1) = 0) then
      Main := Sub;
    var Output := Color(Word(Main));
    if (State.Regs[0] and $80) <> 0 then
      Output := $FF000000;
    FFrame[OutputY * 512 + X] := Output;
  end;
end;

procedure TSnesPPU.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  Archive.Field(FFrame[0], Length(FFrame) * 4);
end;

end.

