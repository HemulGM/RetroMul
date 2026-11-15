unit S32.Video;

interface

uses
  System.SysUtils, System.UITypes, Core.Snapshots;

const
  S32_WIDTH = 416;
  S32_HEIGHT = 224;
  S32_FPS = 60;

type
  TS32Clip = record
    Left, Top, Right, Bottom: Integer;
    function Contains(X, Y: Integer): Boolean;
  end;

  TS32Video = class
  private
    FTiles, FSprites: TBytes;
    FLayers: array[0..7] of TArray<Word>;
    FSpriteBack: TArray<Word>;
    FLatched: array[0..7] of Byte;
    FWidth, FFrame, FSpriteCountdown: Integer;
    FBuffer: Boolean;
    function V(Address: Integer): Word; inline;
    function S(Address: Integer): Word; inline;
    function TilePixel(Layer, X, Y: Integer): Word;
    function LayerPixel(Layer, X, Y: Integer): Word;
    function ClipPixel(Layer, X, Y: Integer): Boolean;
    function DrawSprite(Entry, XOffset, YOffset: Integer; const ClipIn, ClipOut: TS32Clip): Integer;
    procedure DrawSprites;
    procedure Mix(FirstLine, LastLine: Integer);
  public
    RAM, SpriteRAM: array[0..$1FFFF] of Byte;
    Palette: array[0..$3FFF] of Word;
    Mixer: array[0..$3F] of Word;
    Control: array[0..7] of Byte;
    TileBank: Byte;
    Enabled: Boolean;
    Pixels: TArray<TAlphaColor>;
    constructor Create(const Tiles, Sprites: TBytes);
    procedure Reset;
    procedure BeginFrame;
    procedure RenderLine(Y: Integer);
    procedure UpdateSprites;
    procedure Render(ClockSprites: Boolean = True);
    function ReadControl(Index: Integer): Byte;
    function ReadPalette(Address: Cardinal): Byte;
    procedure WritePalette(Address: Cardinal; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property Width: Integer read FWidth;
  end;

implementation

uses
  System.Math;

function SignExtend(Value, Bits: Integer): Integer; inline;
begin
  Result := Value and ((1 shl Bits) - 1);
  if Result and (1 shl (Bits - 1)) <> 0 then
    Dec(Result, 1 shl Bits);
end;

function RGB5(Value: Integer): Cardinal; inline;
begin
  Result := EnsureRange(Value, 0, 31);
  Result := (Result shl 3) or (Result shr 2);
end;

function TS32Clip.Contains(X, Y: Integer): Boolean;
begin
  Result := (X >= Left) and (X <= Right) and (Y >= Top) and (Y <= Bottom);
end;

constructor TS32Video.Create(const Tiles, Sprites: TBytes);
begin
  inherited Create;
  FTiles := Tiles;
  FSprites := Sprites;
  for var I := 0 to 7 do
    SetLength(FLayers[I], 512 * 256);
  SetLength(FSpriteBack, 512 * 256);
  Reset;
end;

procedure TS32Video.Reset;
begin
  FillChar(RAM, SizeOf(RAM), 0);
  FillChar(SpriteRAM, SizeOf(SpriteRAM), 0);
  FillChar(Palette, SizeOf(Palette), 0);
  FillChar(Mixer, SizeOf(Mixer), 0);
  FillChar(Control, SizeOf(Control), 0);
  FillChar(FLatched, SizeOf(FLatched), 0);
  FillChar(FLayers[6][0], Length(FLayers[6]) * 2, $FF);
  FillChar(FSpriteBack[0], Length(FSpriteBack) * 2, $FF);
  FFrame := 0;
  FSpriteCountdown := 0;
  FWidth := 320;
  FBuffer := False;
  TileBank := 0;
  Enabled := False;
  SetLength(Pixels, FWidth * S32_HEIGHT);
end;

function TS32Video.V(Address: Integer): Word;
begin
  Result := Word(RAM[Address and $1FFFF]) or (Word(RAM[(Address + 1) and $1FFFF]) shl 8);
end;

function TS32Video.S(Address: Integer): Word;
begin
  Result := Word(SpriteRAM[Address and $1FFFF]) or (Word(SpriteRAM[(Address + 1) and $1FFFF]) shl 8);
end;

function TS32Video.ReadControl(Index: Integer): Byte;
begin
  Index := Index and 7;
  case Index of
    0:
      begin
        Result := $FC;
        if FBuffer then
          Inc(Result);
      end;
    1:
      Result := $FD;
    2..5:
      Result := $FC or FLatched[Index];
    6:
      Result := $FC or (FLatched[6] and 1);
  else
    Result := $FC;
  end;
end;

function Alternate(Value: Word): Word;
begin
  Result := (Value and $8000) or ((Value and $001E) shr 1) or ((Value and $03C0) shr 2) or
    ((Value and $7800) shr 3) or ((Value and 1) shl 12) or ((Value and $20) shl 8) or ((Value and $400) shl 4);
end;

function Canonical(Value: Word): Word;
begin
  Result := (Value and $8000) or ((Value and $000F) shl 1) or ((Value and $00F0) shl 2) or
    ((Value and $0F00) shl 3) or ((Value and $1000) shr 12) or ((Value and $2000) shr 8) or ((Value and $4000) shr 4);
end;

function TS32Video.ReadPalette(Address: Cardinal): Byte;
begin
  var Value := Palette[(Address shr 1) and $3FFF];
  if Address and $8000 <> 0 then
    Value := Alternate(Value);
  Result := Byte(Value shr (8 * (Address and 1)));
end;

procedure TS32Video.WritePalette(Address: Cardinal; Value: Byte);
begin
  var Index := Integer((Address shr 1) and $3FFF);
  for var CopyIndex := 0 to 1 do
  begin
    var Data := Palette[Index];
    if Address and $8000 <> 0 then
      Data := Alternate(Data);
    var Shift := 8 * (Address and 1);
    Data := (Data and not (Word($FF) shl Shift)) or (Word(Value) shl Shift);
    if Address and $8000 <> 0 then
      Data := Canonical(Data);
    Palette[Index] := Data;
    if Mixer[$4E div 2] and $0880 = 0 then
      Break;
    Index := Index xor $2000;
  end;
end;

function TS32Video.TilePixel(Layer, X, Y: Integer): Word;
const
  XOrder: array[0..15] of Integer = (0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15);
begin
  X := X and $3FF;
  Y := Y and $1FF;
  var PageIndex := (X shr 9) or ((Y shr 8) shl 1);
  var Page := (V($1FF40 + Layer * 4 + (PageIndex shr 1) * 2) shr (8 * (PageIndex and 1))) and $7F;
  var Tile := V(Page * $400 + ((Y and $FF) shr 4) * 64 + ((X and $1FF) shr 4) * 2);
  var Bank := ((TileBank and 1) shl 1) or ((V($1FF00) shr 10) and 1);
  var Index := (Bank shl 13) or (Tile and $1FFF);
  X := X and 15;
  Y := Y and 15;
  if Tile and $4000 <> 0 then
    X := 15 - X;
  if Tile and $8000 <> 0 then
    Y := 15 - Y;
  var Offset := Index * 128 + Y * 8 + (XOrder[X] shr 1);
  Result := 0;
  if Offset < Length(FTiles) then
  begin
    var Pen := (FTiles[Offset] shr (4 * (1 - (XOrder[X] and 1)))) and 15;
    if Pen <> 0 then
      Result := (((Tile shr 4) and $1FF) shl 4) or Pen;
  end;
end;

function TS32Video.ClipPixel(Layer, X, Y: Integer): Boolean;
begin
  Result := True;
  if Layer = 0 then
    Exit;
  var B := Layer - 1;
  if Layer = 5 then
    B := 4;
  if V($1FF02) and (1 shl (11 + B)) = 0 then
    Exit;
  var Mask := (V($1FF06) shr (4 * B)) and 15;
  if B = 4 then
    Mask := $10;
  var Inside := False;
  for var I := 0 to 4 do
    if Mask and (1 shl I) <> 0 then
    begin
      var R: TS32Clip;
      R.Left := V($1FF60 + I * 8) and $1FF;
      R.Right := V($1FF64 + I * 8) and $1FF;
      R.Top := V($1FF62 + I * 8) and $FF;
      R.Bottom := V($1FF66 + I * 8) and $FF;
      if (I in [2, 3]) and (V($1FF04) and (1 shl (I + 2)) <> 0) then
      begin
        var Line := Y;
        if V($1FF00) and $200 <> 0 then
          Line := 223 - Y;
        var Table := (V($1FF04) shr 10) * $800 + (I - 2) * $200;
        var MinX := V(Table + Line * 2);
        var MaxX := V(Table + $400 + Line * 2);
        if (MinX = $FFFF) or (MaxX = $FFFF) then
          Continue;
        R.Left := MinX and $1FF;
        R.Right := MaxX and $1FF;
      end;
      if V($1FF00) and $200 <> 0 then
      begin
        var T := R.Left;
        R.Left := FWidth - 1 - R.Right;
        R.Right := FWidth - 1 - T;
        T := R.Top;
        R.Top := 223 - R.Bottom;
        R.Bottom := 223 - T;
      end;
      Inside := Inside or R.Contains(X, Y);
    end;
  Result := Inside;
  if V($1FF02) and (1 shl (6 + B)) <> 0 then
    Result := not Result;
end;

function TS32Video.LayerPixel(Layer, X, Y: Integer): Word;
begin
  Result := 0;
  if Layer = 7 then
  begin
    if V($1FF00) and $200 <> 0 then
      Y := 223 - Y;
    Result := V($1FF5E) and $1E00;
    if V($1FF5E) and $8000 <> 0 then
      Inc(Result, (V($1FF5E) + Y) and $1FF);
    Exit;
  end;
  if not ClipPixel(Layer, X, Y) then
    Exit;
  if Layer = 0 then
  begin
    if V($1FF00) and $200 <> 0 then
    begin
      X := FWidth - 1 - X;
      Y := 223 - Y;
    end;
    var Tile := V(((V($1FF5C) shr 4) and $1F) * $1000 + ((Y shr 3) * 64 + (X shr 3)) * 2);
    var Index := ((V($1FF5C) and 7) shl 9) or (Tile and $1FF);
    var Offset := Index * 32 + (Y and 7) * 4 + ((X and 7) shr 1);
    var Pen := (RAM[Offset and $1FFFF] shr (4 * (1 - (X and 1)))) and 15;
    if Pen <> 0 then
      Result := ((Tile shr 9) shl 4) or Pen;
    Exit;
  end;
  if Layer = 5 then
  begin
    var SX := (X + V($1FF88)) and $1FF;
    var SY := (Y + V($1FF8A)) and $1FF;
    var Pen, Color: Integer;
    if V($1FF00) and $800 <> 0 then
    begin
      Pen := RAM[((SY and $FF) * 512 + SX) and $1FFFF];
      Color := (V($1FF8C) shl 4) and $1FF00;
    end
    else
    begin
      Pen := (V(SY * 256 + (SX shr 2) * 2) shr (4 * (SX and 3))) and 15;
      Color := (V($1FF8C) shl 4) and $1FFF0;
    end;
    if Pen <> 0 then
      Result := Color + Pen;
    Exit;
  end;
  var B := Layer - 1;
  var FlipX := ((V($1FF00) shr B) xor (V($1FF00) shr 9)) and 1 <> 0;
  var FlipY := ((V($1FF00) shr B) and Ord(V($1FF00) and $100 = 0)) xor ((V($1FF00) shr 9) and 1) <> 0;
  if FlipX then
    X := FWidth - 1 - X;
  if FlipY then
    Y := 223 - Y;
  var SX, SY: Integer;
  if B < 2 then
  begin
    var ZX := Max($80, V($1FF50 + B * 4) and $FFF);
    var ZY := ZX;
    if V($1FF00) and $4000 <> 0 then
      ZY := Max($80, V($1FF52 + B * 4) and $FFF);
    var CenterXBits := 9 + Ord(ZX <> $200);
    var CenterYBits := 9 + Ord(ZY <> $200);
    var StepX := (Int64($200) shl 20) div ZX;
    var StepY := (Int64($200) shl 20) div ZY;
    SX := (((Int64(V($1FF12 + B * 8) and $3FF) shl 20) + ((V($1FF10 + B * 8) and $FF00) shl 4)) +
      (X - SignExtend(V($1FF30 + B * 4), CenterXBits)) * StepX) shr 20;
    SY := (((Int64(V($1FF16 + B * 8) and $1FF) shl 20) + ((V($1FF14 + B * 8) and $FE00) shl 4)) +
      (Y - SignExtend(V($1FF32 + B * 4), CenterYBits)) * StepY) shr 20;
  end
  else
  begin
    SX := X + (V($1FF12 + B * 8) and $3FF) - (V($1FF30 + B * 4) and $1FF);
    SY := Y + (V($1FF16 + B * 8) and $1FF);
    var Table := (V($1FF04) shr 10) * $800;
    if V($1FF04) and (1 shl (B + 2)) = 0 then
    begin
      if V($1FF04) and (1 shl (B - 2)) <> 0 then
        Inc(SX, V(Table + (B - 2) * $200 + Y * 2) and $3FF);
      if V($1FF04) and (1 shl B) <> 0 then
        SY := (V($1FF16 + B * 8) + V(Table + $400 + (B - 2) * $200 + Y * 2)) and $1FF;
    end;
  end;
  Result := TilePixel(B, SX, SY);
end;

function TS32Video.DrawSprite(Entry, XOffset, YOffset: Integer; const ClipIn, ClipOut: TS32Clip): Integer;
const
  Masks: array[0..3, 0..3] of Word = (($7FFF, $3FFF, $1FFF, $FFF), ($3FFF, $1FFF, $FFF, $7FF), ($3FFF, $1FFF, $FFF, $7FF), ($1FFF, $FFF, $7FF, $3FF));
begin
  var D: array[0..7] of Word;
  for var I := 0 to 7 do
    D[I] := S(Entry * 16 + I * 2);
  var Indirect := D[0] and $2000 <> 0;
  var local := D[0] and $1000 <> 0;
  Result := 2 * Ord(Indirect and local);
  var BPP8 := D[0] and $200 <> 0;
  var SourceWidth := (D[1] shr Ord(not BPP8)) and $3F;
  var SourceHeight := D[1] shr 8;
  var DW := D[3] and $3FF;
  var DH := D[2] and $3FF;
  if (SourceWidth = 0) or (SourceHeight = 0) or (DW = 0) or (DH = 0) then
    Exit;
  var XP := SignExtend(D[5], 12);
  var YP := SignExtend(D[4], 12);
  if D[0] and $10 <> 0 then
    Inc(XP, XOffset);
  if D[0] and $20 <> 0 then
    Inc(YP, YOffset);
  case D[0] and 3 of
    0, 3:
      Dec(XP, (DW - 1) div 2);
    1:
      Dec(XP, DW - 1);
  end;
  case (D[0] shr 2) and 3 of
    0, 3:
      Dec(YP, (DH - 1) div 2);
    1:
      Dec(YP, DH - 1);
  end;
  var FlipX := D[0] and $40 <> 0;
  var FlipY := D[0] and $80 <> 0;
  var FromRAM := D[0] and $400 <> 0;
  var Shadow := (D[0] and $800 <> 0) and (FLatched[5] and 1 <> 0);
  var Bank := ((D[3] and $800) shr 11) or ((D[3] and $4000) shr 13);
  var Banks := Length(FSprites) div $400000;
  if Banks > 0 then
    Bank := Bank mod Banks;
  var Address := Cardinal(D[6]) or (Cardinal(D[2] and $F000) shl 4);
  var PerWord := 8 shr Ord(BPP8);
  var HZoom := (PerWord * SourceWidth shl 16) div DW;
  var VZoom := (SourceHeight shl 16) div DH;
  var Color := D[7] and $7FF0;
  if BPP8 then
    Color := Color and $7F00;
  if Mixer[$4C div 2] and $C = 0 then
    Color := Color or (D[7] and $8000)
  else
    Color := Color or $8000;
  var Transparent := 0;
  if D[0] and $100 = 0 then
    Transparent := (1 shl (4 shl Ord(BPP8))) - 1;
  var Mask := Masks[FLatched[4] and 3, FLatched[5] and 3];
  if BPP8 then
    Mask := Mask and $FFF0;
  var IndTable: array[0..15] of Word;
  if Indirect then
    for var I := 0 to 15 do
    begin
      var Offset := 16 * (D[7] and $1FFF);
      if local then
        Offset := Entry * 16 + 16;
      IndTable[I] := S(Offset + I * 2);
      if BPP8 then
        IndTable[I] := IndTable[I] and $FFF0;
      if FLatched[5] and 1 <> 0 then
        IndTable[I] := IndTable[I] or $8000;
    end;
  for var DY := Max(0, ClipIn.Top - YP) to Min(DH - 1, ClipIn.Bottom - YP) do
  begin
    var SourceY := DY;
    if FlipY then
      SourceY := DH - 1 - DY;
    SourceY := (Int64(SourceY) * VZoom) shr 16;
    var RowAddress := Address + Cardinal(SourceY * SourceWidth);
    var XAcc := 0;
    var DX := 0;
    // End markers are only recognized at the last pixel of each source word.
    for var SourceX := 0 to SourceWidth * PerWord - 1 do
    begin
      var WordAddress := RowAddress + Cardinal(SourceX div PerWord);
      var Data: Cardinal;
      if FromRAM then
      begin
        var Off := Integer(WordAddress and $7FFF) * 4;
        Data := (Cardinal(SpriteRAM[Off]) shl 24) or (Cardinal(SpriteRAM[Off + 1]) shl 16) or
          (Cardinal(SpriteRAM[Off + 2]) shl 8) or SpriteRAM[Off + 3];
      end
      else
      begin
        var Off := Int64(Bank) * $400000 + Int64(WordAddress and $FFFFF) * 4;
        if Off + 3 >= Length(FSprites) then
          Break;
        Data := (Cardinal(FSprites[Off]) shl 24) or (Cardinal(FSprites[Off + 1]) shl 16) or
          (Cardinal(FSprites[Off + 2]) shl 8) or FSprites[Off + 3];
      end;
      var Bits := 4 shl Ord(BPP8);
      var Pen := (Data shr (32 - Bits * ((SourceX mod PerWord) + 1))) and ((1 shl Bits) - 1);
      var Trans := 0;
      if (SourceX mod PerWord = 0) or (SourceX mod PerWord = PerWord - 1) then
        Trans := Transparent;
      while (XAcc < $10000) and (DX < DW) do
      begin
        var X := XP + DX;
        if FlipX then
          X := XP + DW - 1 - DX;
        var Y := YP + DY;
        if ClipIn.Contains(X, Y) and not ClipOut.Contains(X, Y) and (Pen <> Cardinal(Trans)) then
        begin
          var Pixel := Color or Integer(Pen);
          var Draw := Pen <> 0;
          if Indirect then
          begin
            if BPP8 then
              Pixel := IndTable[Pen shr 4] or (Pen and 15)
            else
              Pixel := IndTable[Pen];
            Draw := Pixel and Mask <> Mask;
          end;
          if Draw then
          begin
            if Shadow then
              FSpriteBack[Y * 512 + X] := FSpriteBack[Y * 512 + X] and $7FFF
            else
              FSpriteBack[Y * 512 + X] := Pixel;
          end;
        end;
        Inc(DX);
        Inc(XAcc, HZoom);
      end;
      Dec(XAcc, $10000);
      if (DX >= DW) or ((SourceX mod PerWord = PerWord - 1) and (Transparent <> 0) and (Pen = Cardinal(Transparent))) then
        Break;
    end;
  end;
end;

procedure TS32Video.DrawSprites;
begin
  var CI, CO: TS32Clip;
  CI.Left := 0;
  CI.Top := 0;
  CI.Right := 319 + 96 * Ord(FLatched[6] and 1 <> 0);
  CI.Bottom := 223;
  CO.Left := 0;
  CO.Top := 0;
  CO.Right := -1;
  CO.Bottom := -1;
  var Entry := 0;
  var XO := 0;
  var YO := 0;
  for var Count := 0 to $1FFF do
  begin
    var Base := (Entry and $1FFF) * 16;
    var C := S(Base);
    case C shr 14 of
      0:
        Inc(Entry, 1 + DrawSprite(Entry and $1FFF, XO, YO, CI, CO));
      1:
        begin
          if C and $1000 <> 0 then
          begin
            CI.Left := Max(0, SignExtend(S(Base + 4), 12));
            CI.Right := Min(319 + 96 * Ord(FLatched[6] and 1 <> 0), SignExtend(S(Base + 6), 12));
            CI.Top := Max(0, SignExtend(C, 12));
            CI.Bottom := Min(223, SignExtend(S(Base + 2), 12));
          end;
          if C and $2000 <> 0 then
          begin
            CO.Left := SignExtend(S(Base + 12), 12);
            CO.Right := SignExtend(S(Base + 14), 12);
            CO.Top := SignExtend(S(Base + 8), 12);
            CO.Bottom := SignExtend(S(Base + 10), 12);
          end;
          Inc(Entry);
        end;
      2:
        begin
          if C and $2000 <> 0 then
          begin
            YO := SignExtend(S(Base + 2), 12);
            XO := SignExtend(S(Base + 4), 12);
          end;
          Entry := C and $1FFF;
        end;
      3:
        Break;
    end;
  end;
end;

procedure TS32Video.Mix(FirstLine, LastLine: Integer);
type
  TLayer = record
    Index, Priority, Base, Shift, Offset, Blend, SpriteBlend: Integer;
  end;
var
  Orders: array[0..15, 0..7] of TLayer;
  Counts: array[0..15] of Integer;
  Offsets: array[0..2, 0..2] of Integer;
begin
  for var I := 0 to 1 do
    for var C := 0 to 2 do
      Offsets[I, C] := SignExtend(Mixer[$40 div 2 + I * 3 + C], 6);
  FillChar(Offsets[2], SizeOf(Offsets[2]), 0);
  var GroupMode := Mixer[$4C div 2] and 15;
  var GroupShift := 15 - (GroupMode and 3) - Ord(GroupMode >= 4) - Ord(GroupMode >= 12);
  var GroupMask := (1 shl ((GroupMode and 3) + 1)) - 1;
  var PixelMask := ((1 shl GroupShift) - 1) and $3FFF;
  var ShadowMask := $8000 * Ord(Mixer[$4C div 2] and 4 <> 0);
  var BlendEnabled := Mixer[$4E div 2] and $800 <> 0;
  var BlendFactor := (Mixer[$4E div 2] shr 8) and 7;
  var EnableMask: Integer;
  // VDP layer-disable bits use NBG0..3,text,bitmap order.
  EnableMask := 0;
  for var L := 0 to 5 do
  begin
    var BitIndex := L - 1;
    if L = 0 then
      BitIndex := 4
    else if L = 5 then
      BitIndex := 5;
    if (V($1FF02) and (1 shl BitIndex) = 0) and (V($1FF8E) and (1 shl L) = 0) and
      not ((L in [3, 4]) and (V($1FF00) and (1 shl (L + 9)) <> 0)) then
      EnableMask := EnableMask or (1 shl L);
  end;
  for var G := 0 to GroupMask do
  begin
    var N := 0;
    for var L := 0 to 7 do
    begin
      if L < 6 then
        if (EnableMask and (1 shl L) = 0) or (Mixer[$20 div 2 + L] and 15 = 0) then
          Continue;
      var Item: TLayer;
      Item := Default(TLayer);
      Item.Index := L;
      var M := Mixer[$20 div 2 + L];
      Item.Priority := ((M and 15) shl 3) or (6 - L);
      var Flag := (Mixer[$30 div 2 + L] shr 14) and 1;
      var BitIndex := L;
      if L = 6 then
      begin
        M := Mixer[G];
        Item.Priority := ((M and 15) shl 3) or 7;
        Flag := (Mixer[$4C div 2] shr 15) and 1;
      end;
      if L = 7 then
      begin
        M := Mixer[$2C div 2];
        Item.Priority := 8;
        BitIndex := 8;
        Flag := (Mixer[$3E div 2] shr 14) and 1;
      end;
      Item.Base := (M and $F0) shl 6;
      if (L = 6) and (GroupMode and 3 = 3) then
        Item.Base := (Mixer[$4C div 2] and $F0) shl 6;
      Item.Shift := (M shr 8) and 3;
      var LayerBit := (Mixer[$3E div 2] shr BitIndex) and 1;
      // Color offset selectors follow the mixer truth table.
      case ((Mixer[$3E div 2] and $8000) shr 14) or LayerBit of
        0, 3:
          Item.Offset := 1 - Flag;
        1:
          Item.Offset := 2;
        2:
          if Flag = 0 then
            Item.Offset := 2
          else
            Item.Offset := 0;
      end;
      if (L < 6) and BlendEnabled then
      begin
        Item.Blend := (Mixer[$30 div 2 + L] shr 6) and $FF;
        var Encoding := Mixer[$30 div 2 + L] and $3F;
        var Value := Encoding and 15;
        case Encoding shr 4 of
          0:
            Item.SpriteBlend := 1 shl Value;
          1:
            Item.SpriteBlend := (2 shl Value) - 1;
          2:
            Item.SpriteBlend := not ((1 shl Value) - 1) and $FFFF;
          3:
            Item.SpriteBlend := $FFFF;
        end;
      end;
      Orders[G, N] := Item;
      Inc(N);
    end;
    Counts[G] := N;
    for var A := 0 to N - 1 do
      for var B := A + 1 to N - 1 do
        if Orders[G, B].Priority > Orders[G, A].Priority then
        begin
          var T := Orders[G, A];
          Orders[G, A] := Orders[G, B];
          Orders[G, B] := T;
        end;
  end;
  for var Y := FirstLine to LastLine do
    for var X := 0 to FWidth - 1 do
    begin
      var SX := X;
      var SY := Y;
      if FLatched[2] and 1 <> 0 then
        SX := FWidth - 1 - X;
      if FLatched[2] and 2 <> 0 then
        SY := 223 - Y;
      var Sprite := Integer(FLayers[6][SY * 512 + SX]);
      var G := (Sprite shr GroupShift) and GroupMask;
      var Shadow := False;
      var Found := False;
      var Top: TLayer;
      var R := 0;
      var Green := 0;
      var Blue := 0;
      for var I := 0 to Counts[G] - 1 do
      begin
        var L := Orders[G, I];
        var P: Integer;
        if L.Index = 6 then
        begin
          Shadow := Shadow or ((not Sprite and ShadowMask) <> 0);
          if Sprite and $7FFF = $7FFF then
            Continue;
          P := Sprite and PixelMask;
          if P and $7FFE = ($7FFE and PixelMask) then
          begin
            Shadow := True;
            Continue;
          end;
        end
        else
        begin
          P := FLayers[L.Index][Y * 512 + X] and $1FFF;
          if (P = 0) and (L.Index <> 7) then
            Continue;
        end;
        P := Palette[(L.Base + ((P shr L.Shift) and $FFF0) + (P and 15)) and $3FFF];
        var RR := (P and 31) + Offsets[L.Offset, 0];
        var GG := ((P shr 5) and 31) + Offsets[L.Offset, 1];
        var BB := ((P shr 10) and 31) + Offsets[L.Offset, 2];
        if not Found then
        begin
          R := RR;
          Green := GG;
          Blue := BB;
          Top := L;
          Found := True;
          if Top.Blend = 0 then
            Break;
        end
        else
        begin
          if (Top.Blend and (1 shl L.Index) <> 0) and ((L.Index <> 6) or (Top.SpriteBlend and (1 shl G) <> 0)) then
          begin
            R := (R * (7 - BlendFactor) + RR * (BlendFactor + 1)) div 8;
            Green := (Green * (7 - BlendFactor) + GG * (BlendFactor + 1)) div 8;
            Blue := (Blue * (7 - BlendFactor) + BB * (BlendFactor + 1)) div 8;
          end;
          Break;
        end;
      end;
      if Shadow then
      begin
        R := R div 2;
        Green := Green div 2;
        Blue := Blue div 2;
      end;
      Pixels[Y * FWidth + X] := $FF000000 or (RGB5(R) shl 16) or (RGB5(Green) shl 8) or RGB5(Blue);
    end;
end;

procedure TS32Video.UpdateSprites;
begin
  var Command := Control[0];
  if Control[3] and 2 = 0 then
  begin
    if FSpriteCountdown = 0 then
    begin
      Command := 3;
      FSpriteCountdown := Control[3] and 1;
    end
    else
      Dec(FSpriteCountdown);
  end;
  if Command and 2 <> 0 then
    FillChar(FLayers[6][0], Length(FLayers[6]) * 2, $FF);
  if Command and 1 <> 0 then
  begin
    var T := FLayers[6];
    FLayers[6] := FSpriteBack;
    FSpriteBack := T;
    FBuffer := not FBuffer;
    Move(Control, FLatched, SizeOf(Control));
  end;
  if Command and 1 <> 0 then
    DrawSprites;
  Control[0] := 0;
end;

procedure TS32Video.BeginFrame;
begin
  Inc(FFrame);
  FWidth := 320 + 96 * Ord(V($1FF00) and $8000 <> 0);
  SetLength(Pixels, FWidth * 224);
end;

procedure TS32Video.RenderLine(Y: Integer);
begin
  if (Y < 0) or (Y >= 224) then
    Exit;
  if not Enabled then
  begin
    for var X := 0 to FWidth - 1 do
      Pixels[Y * FWidth + X] := $FF000000;
    Exit;
  end;
  for var L := 0 to 7 do
    if L <> 6 then
      for var X := 0 to FWidth - 1 do
        FLayers[L][Y * 512 + X] := LayerPixel(L, X, Y);
  Mix(Y, Y);
end;

procedure TS32Video.Render(ClockSprites: Boolean);
begin
  BeginFrame;
  if ClockSprites then
    UpdateSprites;
  for var Y := 0 to 223 do
    RenderLine(Y);
end;

procedure TS32Video.SerializeState(State: TStateArchive);
begin
  State.Field(RAM, SizeOf(RAM));
  State.Field(SpriteRAM, SizeOf(SpriteRAM));
  State.Field(Palette, SizeOf(Palette));
  State.Field(Mixer, SizeOf(Mixer));
  State.Field(Control, SizeOf(Control));
  State.Field(FLatched, SizeOf(FLatched));
  State.Field(TileBank, SizeOf(TileBank));
  State.Field(Enabled, SizeOf(Enabled));
  State.Field(FFrame, SizeOf(FFrame));
  State.Field(FBuffer, SizeOf(FBuffer));
  State.Field(FSpriteCountdown, SizeOf(FSpriteCountdown));
  if (FSpriteCountdown < 0) or (FSpriteCountdown > 1) then
    raise EArgumentException.Create('Invalid System 32 sprite timing state');
  State.Field(FLayers[6][0], Length(FLayers[6]) * 2);
  State.Field(FSpriteBack[0], Length(FSpriteBack) * 2);
  State.Field(FWidth, SizeOf(FWidth));
  if (FWidth <> 320) and (FWidth <> 416) then
    raise EArgumentException.Create('Invalid System 32 video width');
  if State.Loading then
    SetLength(Pixels, FWidth * 224);
  State.Field(Pixels[0], Length(Pixels) * SizeOf(TAlphaColor));
end;

end.

