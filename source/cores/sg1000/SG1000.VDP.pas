unit SG1000.VDP;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Snapshots;

type
  // TMS9918A: 16 KiB VRAM, buffered reads and a two-byte control latch.
  TSGVDP = class
  protected
    FShowBackground, FShowSprites, FRemoveSpriteLimit: Boolean;
    FVRAM: array[0..$3FFF] of Byte;
    FRegisters: array[0..7] of Byte;
    FAddress: Integer;
    FReadBuffer, FStatus, FSpriteIndex: Byte;
    FControlPending: Boolean;
    FPixels: TArray<TAlphaColor>;
    function VRAM(Address: Integer): Byte; inline;
    function Color(Index: Integer): TAlphaColor; virtual;
    procedure RenderSprites(Y: Integer);
  public
    constructor Create;
    procedure Reset; virtual;
    procedure ConfigureDisplay(Background, Sprites, RemoveLimit: Boolean);
    function ReadData: Byte; virtual;
    function ReadStatus: Byte; virtual;
    procedure WriteData(Value: Byte); virtual;
    procedure WriteControl(Value: Byte); virtual;
    function Interrupt: Boolean; virtual;
    procedure RenderLine(Y: Integer); virtual;
    procedure VBlank; virtual;
    procedure EndLine(Line, TotalLines: Integer); virtual;
    function ScreenHeight: Integer; virtual;
    procedure SerializeState(State: TStateArchive); virtual;
    property Pixels: TArray<TAlphaColor> read FPixels;
  end;

implementation

procedure TSGVDP.EndLine(Line, TotalLines: Integer);
begin
end;

function TSGVDP.ScreenHeight: Integer;
begin
  Result := 192;
end;

constructor TSGVDP.Create;
begin
  inherited;
  FShowBackground := True;
  FShowSprites := True;
  SetLength(FPixels, 256 * 192);
  Reset;
end;

procedure TSGVDP.ConfigureDisplay(Background, Sprites, RemoveLimit: Boolean);
begin
  FShowBackground := Background;
  FShowSprites := Sprites;
  FRemoveSpriteLimit := RemoveLimit;
end;

procedure TSGVDP.Reset;
begin
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FAddress := 0;
  FReadBuffer := 0;
  FStatus := $1F;
  FSpriteIndex := $1F;
  FControlPending := False;
  for var i := 0 to High(FPixels) do
    FPixels[i] := $FF000000;
end;

function TSGVDP.VRAM(Address: Integer): Byte;
begin
  Result := FVRAM[Address and $3FFF];
end;

function TSGVDP.Color(Index: Integer): TAlphaColor;
const
  Palette: array[0..15] of TAlphaColor = (
    $FF000000, $FF000000, $FF21C842, $FF5EDC78,
    $FF5455ED, $FF7D76FC, $FFD4524D, $FF42EBF5,
    $FFFC5554, $FFFF7978, $FFD4C154, $FFE6CE80,
    $FF21B03B, $FFC95BBA, $FFCCCCCC, $FFFFFFFF);
begin
  Index := Index and 15;
  if Index = 0 then
    Index := FRegisters[7] and 15;
  Result := Palette[Index];
end;

function TSGVDP.ReadData: Byte;
begin
  FControlPending := False;
  Result := FReadBuffer;
  FReadBuffer := FVRAM[FAddress];
  FAddress := (FAddress + 1) and $3FFF;
end;

function TSGVDP.ReadStatus: Byte;
begin
  Result := FStatus;
  FStatus := FSpriteIndex;
  FControlPending := False;
end;

procedure TSGVDP.WriteData(Value: Byte);
begin
  FControlPending := False;
  FVRAM[FAddress] := Value;
  FReadBuffer := Value;
  FAddress := (FAddress + 1) and $3FFF;
end;

procedure TSGVDP.WriteControl(Value: Byte);
const
  Masks: array[0..7] of Byte = ($03, $FB, $0F, $FF, $07, $7F, $07, $FF);
begin
  if not FControlPending then
  begin
    FAddress := (FAddress and $3F00) or Value;
    FControlPending := True;
    Exit;
  end;

  FAddress := ((Integer(Value) shl 8) or (FAddress and $FF)) and $3FFF;
  FControlPending := False;
  if Value and $80 <> 0 then
    FRegisters[Value and 7] := (FAddress and $FF) and Masks[Value and 7]
  else if Value and $40 = 0 then
  begin
    FReadBuffer := FVRAM[FAddress];
    FAddress := (FAddress + 1) and $3FFF;
  end;
end;

function TSGVDP.Interrupt: Boolean;
begin
  Result := (FStatus and $80 <> 0) and (FRegisters[1] and $20 <> 0);
end;

procedure TSGVDP.VBlank;
begin
  FStatus := FStatus or $80;
end;

procedure TSGVDP.RenderLine(Y: Integer);
var
  Code, Pattern, Colors, Base, PatternBase, ColorBase, Mode: Integer;
  PatternMask, ColorMask, Width, Left, Column: Integer;
begin
  if (Y < 0) or (Y >= 192) then
    Exit;

  var Backdrop := Color(0);
  for var X := 0 to 255 do
    FPixels[Y * 256 + X] := Backdrop;

  if FRegisters[1] and $40 = 0 then
    Exit;

  Mode := (FRegisters[0] and 2) or ((FRegisters[1] shr 4) and 1) or
    ((FRegisters[1] and 8) shr 1);
  Base := FRegisters[2] * 1024;
  PatternBase := FRegisters[4] * 2048;
  ColorBase := FRegisters[3] * 64;
  ColorMask := ((FRegisters[3] and $7F) shl 3) or 7;
  PatternMask := ((FRegisters[4] and 3) shl 8) or $FF;
  if Mode and 2 <> 0 then
  begin
    PatternBase := (FRegisters[4] and 4) * 2048;
    ColorBase := (FRegisters[3] and $80) * 64;
  end;
  Width := 8;
  Left := 0;
  Column := 32;
  if Mode and 1 <> 0 then
  begin
    Width := 6;
    Left := 6;
    Column := 40;
  end;
  if FShowBackground then
    for var Tile := 0 to Column - 1 do
    begin
      Code := VRAM(Base + (Y div 8) * Column + Tile);
      Colors := FRegisters[7];
      case Mode of
        0:
          begin
            Pattern := VRAM(PatternBase + Code * 8 + (Y and 7));
            Colors := VRAM(ColorBase + Code div 8);
          end;
        1:
          Pattern := VRAM(PatternBase + Code * 8 + (Y and 7));
        2, 3:
          begin
            Code := Code + (Y div 64) * 256;
            Pattern := VRAM(PatternBase + (Code and PatternMask) * 8 + (Y and 7));
            if Mode = 2 then
              Colors := VRAM(ColorBase + (Code and ColorMask) * 8 + (Y and 7));
          end;
        4, 6:
          begin
            if Mode = 6 then
              Colors := VRAM(PatternBase + ((Code + (Y div 64) * 256 + ((Y div 4) and 7)) and PatternMask) * 8)
            else
              Colors := VRAM(PatternBase + Code * 8 + ((Y div 4) and 7));
            Pattern := $F0;
          end;
      else
        Pattern := $F0;
      end;
      var Foreground := Color(Colors shr 4);
      var Background := Color(Colors and 15);
      for var Bit := 0 to Width - 1 do
        if Pattern and ($80 shr Bit) <> 0 then
          FPixels[Y * 256 + Left + Tile * Width + Bit] := Foreground
        else
          FPixels[Y * 256 + Left + Tile * Width + Bit] := Background;
    end;
  if Mode and 1 = 0 then
    RenderSprites(Y);
end;

procedure TSGVDP.RenderSprites(Y: Integer);
var
  Occupied, Drawn: array[0..255] of Boolean;
  Count, Size, Zoom, Table, Patterns, SY, SX, Row, Code, Attr, X, Bits: Integer;
begin
  FillChar(Occupied, SizeOf(Occupied), 0);
  FillChar(Drawn, SizeOf(Drawn), 0);
  FSpriteIndex := 31;
  Count := 0;
  Size := 8;
  if FRegisters[1] and 2 <> 0 then
    Size := 16;
  Zoom := 1;
  if FRegisters[1] and 1 <> 0 then
    Zoom := 2;
  Table := FRegisters[5] * 128;
  Patterns := FRegisters[6] * 2048;
  for var i := 0 to 31 do
  begin
    if Count <= 4 then
      FSpriteIndex := i;
    SY := VRAM(Table + i * 4);
    if SY = $D0 then
      Break;

    if SY > $E0 then
      Dec(SY, 256);
    Inc(SY);
    if (Y < SY) or (Y >= SY + Size * Zoom) then
      Continue;

    Inc(Count);
    if Count = 5 then
    begin
      if FStatus and $40 = 0 then
        FStatus := (FStatus and $A0) or $40 or i;
      if not FRemoveSpriteLimit then
        Break;
    end;

    SX := VRAM(Table + i * 4 + 1);
    Code := VRAM(Table + i * 4 + 2);
    Attr := VRAM(Table + i * 4 + 3);
    if Attr and $80 <> 0 then
      Dec(SX, 32);
    if Size = 16 then
      Code := Code and $FC;
    Row := (Y - SY) div Zoom;
    var SpriteColor := Color(Attr and 15);
    var BitsLeft := VRAM(Patterns + Code * 8 + Row);
    var BitsRight := 0;
    if Size = 16 then
      BitsRight := VRAM(Patterns + Code * 8 + Row + 16);
    for var Pixel := 0 to Size - 1 do
    begin
      Bits := BitsLeft;
      if Pixel >= 8 then
        Bits := BitsRight;
      if Bits and ($80 shr (Pixel and 7)) = 0 then
        Continue;

      for var RepeatPixel := 0 to Zoom - 1 do
      begin
        X := SX + Pixel * Zoom + RepeatPixel;
        if (X < 0) or (X > 255) then
          Continue;

        // Color-zero sprites collide but do not obscure lower priority pixels.
        if Count <= 4 then
        begin
          if Occupied[X] then
            FStatus := FStatus or $20;
          Occupied[X] := True;
        end;
        if FShowSprites and (Attr and 15 <> 0) and not Drawn[X] then
        begin
          FPixels[Y * 256 + X] := SpriteColor;
          Drawn[X] := True;
        end;
      end;
    end;
  end;
  if FStatus and $40 = 0 then
    FStatus := (FStatus and $E0) or FSpriteIndex;
end;

procedure TSGVDP.SerializeState(State: TStateArchive);
begin
  State.Field(FVRAM, SizeOf(FVRAM));
  State.Field(FRegisters, SizeOf(FRegisters));
  if State.Loading then
    SetLength(FPixels, ScreenHeight * 256);
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FReadBuffer, SizeOf(FReadBuffer));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FSpriteIndex, SizeOf(FSpriteIndex));
  State.Field(FControlPending, SizeOf(FControlPending));
  State.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));

  if State.Loading and ((FAddress < 0) or (FAddress > $3FFF) or (FSpriteIndex > 31)) then
    raise EReadError.Create('Invalid TMS9918A snapshot address');
end;

end.

