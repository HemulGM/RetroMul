unit WS.Video;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Math, Core.Snapshots,
  WS.Types;

type
  TWSVideo = class
  private
    FRAM: PWSRAM;
    FIO: PWSIO;
    FPixels, FNative: TArray<TAlphaColor>;
    FOAM: array[0..127, 0..3] of Byte;
    FSpriteCount: Integer;
    // Indexed rows precede palette lookup by one scanline.
    FRows: array[0..1, 0..WS_WIDTH - 1] of Word;
    FLatched: array[0..$13] of Byte;
    FMode: Byte;
    FLayerRows: array[0..1, 0..WS_WIDTH - 1] of Word;
    FSpriteRow: array[0..WS_WIDTH - 1] of Word;
    FFetchAttr: array[0..1] of Word;
    FSelectedSprites: array[0..31, 0..3] of Byte;
    FSelectedCount: Integer;
    FSpriteData: Cardinal;
    FVertical, FHardwareColor: Boolean;
    FOrientation, FPalette: Integer;
    function RAM16(Address: Word): Word;
    function TileAddress(Tile, Y: Integer): Word;
    function DecodePixel(Data: Cardinal; X: Integer): Integer;
    function FetchData(Address: Word): Cardinal;
    procedure StartFetchLine(Y: Integer);
    procedure FetchBackground(Y, Layer, Cell: Integer; DataPhase: Boolean);
    procedure FetchSprite(Y, Slot: Integer; DataPhase: Boolean);
    procedure FetchCycle(Y, Clock: Integer);
    procedure ComposeLine(Y: Integer);
    function PaletteColor(Palette, Color: Integer): TAlphaColor;
    function Opaque(Palette, Color: Integer): Boolean;
    function Inside(X, Y, Base: Integer): Boolean;
    function GetVertical: Boolean;
  public
    constructor Create(RAM: PWSRAM; IO: PWSIO; HardwareColor, Vertical: Boolean);
    procedure Reset;
    procedure BeginLine(FrameStart: Boolean);
    procedure Tick(Line, FirstClock, Clocks: Integer);
    procedure EndFrame;
    procedure Configure(Orientation, Palette: Integer);
    function FrameWidth: Integer;
    function FrameHeight: Integer;
    procedure SerializeState(State: TStateArchive);
    property Pixels: TArray<TAlphaColor> read FPixels;
    property Vertical: Boolean read GetVertical;
  end;

implementation

{$Q-}{$R-}

constructor TWSVideo.Create(RAM: PWSRAM; IO: PWSIO; HardwareColor, Vertical: Boolean);
begin
  inherited Create;
  FRAM := RAM;
  FIO := IO;
  FHardwareColor := HardwareColor;
  FVertical := Vertical;
  SetLength(FNative, WS_WIDTH * WS_HEIGHT);
  SetLength(FPixels, WS_WIDTH * WS_HEIGHT);
  Reset;
end;

procedure TWSVideo.Reset;
begin
  FillChar(FOAM, SizeOf(FOAM), 0);
  FSpriteCount := 0;
  FMode := 0;
  FillChar(FLayerRows, SizeOf(FLayerRows), 0);
  FillChar(FSpriteRow, SizeOf(FSpriteRow), 0);
  FillChar(FFetchAttr, SizeOf(FFetchAttr), 0);
  FillChar(FSelectedSprites, SizeOf(FSelectedSprites), 0);
  FSelectedCount := 0;
  FSpriteData := 0;
  FillChar(FRows, SizeOf(FRows), 0);
  FillChar(FLatched, SizeOf(FLatched), 0);
  for var I := 0 to High(FNative) do
    FNative[I] := $FFFFFFFF;
  EndFrame;
end;

function TWSVideo.RAM16(Address: Word): Word;
begin
  Result := FRAM[Address] or (Word(FRAM[Word(Address + 1)]) shl 8);
end;

function TWSVideo.GetVertical: Boolean;
begin
  case FOrientation of
    1:
      Result := False;
    2:
      Result := True;
  else
    Result := FVertical;
  end;
end;

procedure TWSVideo.Configure(Orientation, Palette: Integer);
begin
  FOrientation := Orientation;
  FPalette := Palette;
end;

function TWSVideo.FrameWidth: Integer;
begin
  if Vertical then
    Result := WS_HEIGHT
  else
    Result := WS_WIDTH;
end;

function TWSVideo.FrameHeight: Integer;
begin
  if Vertical then
    Result := WS_WIDTH
  else
    Result := WS_HEIGHT;
end;

function TWSVideo.TileAddress(Tile, Y: Integer): Word;
begin
  if FMode and $80 = 0 then
    Tile := Tile and $1FF;
  if FMode and $40 = 0 then
    Result := $2000 + Tile * 16 + (Y and 7) * 2
  else
    Result := $4000 + Tile * 32 + (Y and 7) * 4;
end;

function TWSVideo.FetchData(Address: Word): Cardinal;
begin
  Result := RAM16(Address);
  if FMode and $40 <> 0 then
    Result := Result or (Cardinal(RAM16(Word(Address + 2))) shl 16);
end;

function TWSVideo.DecodePixel(Data: Cardinal; X: Integer): Integer;
begin
  if FMode and $60 = $60 then
    Exit((Data shr ((X div 2) * 8 + (1 - (X and 1)) * 4)) and 15);
  Result := Integer((Data shr (7 - X)) and 1) or Integer((Data shr (15 - X)) and 1) shl 1;
  if FMode and $40 <> 0 then
    Result := Result or (Integer((Data shr (23 - X)) and 1) shl 2) or
      (Integer((Data shr (31 - X)) and 1) shl 3);
end;

procedure TWSVideo.StartFetchLine(Y: Integer);
begin
  FillChar(FLayerRows, SizeOf(FLayerRows), 0);
  FillChar(FSpriteRow, SizeOf(FSpriteRow), 0);
  FSelectedCount := 0;
  if FLatched[0] and 4 = 0 then
    Exit;
  for var I := 0 to FSpriteCount - 1 do
    if Byte(Y - FOAM[I, 2]) < 8 then
    begin
      Move(FOAM[I, 0], FSelectedSprites[FSelectedCount, 0], 4);
      Inc(FSelectedCount);
      if FSelectedCount = 32 then
        Break;
    end;
end;

procedure TWSVideo.FetchBackground(Y, Layer, Cell: Integer; DataPhase: Boolean);
begin
  if FLatched[0] and (1 shl Layer) = 0 then
    Exit;
  var Scroll := Integer(FLatched[$10 + Layer * 2]);
  var SY := (Y + Integer(FLatched[$11 + Layer * 2])) and $FF;
  if not DataPhase then
  begin
    var Base := (FLatched[7] shr (Layer * 4)) and 15;
    if not FHardwareColor then
      Base := Base and 7;
    FFetchAttr[Layer] := RAM16(Base * $800 + (SY shr 3) * 64 +
        (((Scroll shr 3) + Cell) and 31) * 2);
    Exit;
  end;
  var Attr := Integer(FFetchAttr[Layer]);
  var Tile := (Attr and $1FF) or ((Attr shr 4) and $200);
  if Attr and $8000 <> 0 then
    SY := SY xor 7;
  var Data := FetchData(TileAddress(Tile, SY));
  var Palette := (Attr shr 9) and 15;
  for var J := 0 to 7 do
  begin
    var X := Cell * 8 - (Scroll and 7) + J;
    if (X < 0) or (X >= WS_WIDTH) then
      Continue;
    if (Layer = 1) and (FLatched[0] and $20 <> 0) then
      if Inside(X, Y, 8) = (FLatched[0] and $10 <> 0) then
        Continue;
    var Column := J;
    if Attr and $4000 <> 0 then
      Column := Column xor 7;
    var Pixel := DecodePixel(Data, Column);
    if Opaque(Palette, Pixel) then
      FLayerRows[Layer, X] := $100 or (Palette shl 4) or Pixel;
  end;
end;

procedure TWSVideo.FetchSprite(Y, Slot: Integer; DataPhase: Boolean);
begin
  // Hardware fetches selected sprites from last to first. Opaque pixels
  // overwrite earlier fetches, preserving the first OAM entry's priority.
  var I := FSelectedCount - 1 - Slot;
  if I < 0 then
    Exit;
  var Attr := Integer(FSelectedSprites[I, 0]) or (Integer(FSelectedSprites[I, 1]) shl 8);
  if not DataPhase then
  begin
    var Row := Byte(Y - FSelectedSprites[I, 2]);
    if Attr and $8000 <> 0 then
      Row := Row xor 7;
    FSpriteData := FetchData(TileAddress(Attr and $1FF, Row));
    Exit;
  end;
  var Palette := 8 + ((Attr shr 9) and 7);
  for var J := 0 to 7 do
  begin
    var X := Byte(Integer(FSelectedSprites[I, 3]) + J);
    if X >= WS_WIDTH then
      Continue;
    if (FLatched[0] and 8 <> 0) and (Inside(X, Y, 12) = (Attr and $1000 <> 0)) then
      Continue;
    var Column := J;
    if Attr and $4000 <> 0 then
      Column := Column xor 7;
    var Pixel := DecodePixel(FSpriteData, Column);
    if Opaque(Palette, Pixel) then
      FSpriteRow[X] := $100 or ((Attr and $2000) shr 4) or (Palette shl 4) or Pixel;
  end;
end;

procedure TWSVideo.FetchCycle(Y, Clock: Integer);
begin
  // WSdev Frame_timing: 33 screen cells each, then 32 reverse-order
  // sprite slots. Exact mono/4bpp subphases remain undocumented; these
  // modes use the same slot model, fetching their complete row payload.
  if Clock = 0 then
    StartFetchLine(Y);
  if Clock < 66 then
    FetchBackground(Y, 0, Clock shr 1, Odd(Clock))
  else if Clock < 132 then
    FetchBackground(Y, 1, (Clock - 66) shr 1, Odd(Clock))
  else if Clock >= 158 then
  begin
    var Group := (Clock - 158) div 8;
    var Phase := (Clock - 158) mod 8;
    var Slot := Group * 3 + Phase div 2;
    if (Phase < 6) and (Slot < 32) then
      FetchSprite(Y, Slot, Odd(Phase));
  end;
  if Clock = 255 then
    ComposeLine(Y);
end;

function TWSVideo.PaletteColor(Palette, Color: Integer): TAlphaColor;
var
  C, R, G, B: Cardinal;
begin
  if FMode and $80 <> 0 then
  begin
    C := RAM16($FE00 + Palette * 32 + Color * 2);
    R := ((C shr 8) and 15) * 17;
    G := ((C shr 4) and 15) * 17;
    B := (C and 15) * 17;
  end
  else
  begin
    if Palette >= 0 then
      Color := (FIO[$20 + Palette * 2 + (Color and 3) div 2] shr ((Color and 1) * 4)) and 7;
    C := (FIO[$1C + (Color and 7) div 2] shr ((Color and 1) * 4)) and 15;
    C := 15 - C;
    case FPalette of
      1:
        begin
          R := 40 + C * 12;
          G := 48 + C * 12;
          B := 24 + C * 9;
        end;
      2:
        begin
          R := 28 + C * 13;
          G := 36 + C * 13;
          B := 42 + C * 13;
        end;
    else
      R := C * 17;
      G := R;
      B := R;
    end;
  end;
  Result := $FF000000 or (R shl 16) or (G shl 8) or B;
end;

function TWSVideo.Opaque(Palette, Color: Integer): Boolean;
begin
  Result := (Color <> 0) or ((FMode and $40 = 0) and (Palette and 4 = 0));
end;

function TWSVideo.Inside(X, Y, Base: Integer): Boolean;
begin
  Result := (X >= FLatched[Base]) and (Y >= FLatched[Base + 1]) and (X <= FLatched[Base + 2]) and (Y <= FLatched[Base + 3]);
end;

procedure TWSVideo.BeginLine(FrameStart: Boolean);
begin
  Move(FIO[0], FLatched[0], SizeOf(FLatched));
  if FrameStart then
  begin
    FMode := 0;
    if FHardwareColor and (FIO[$60] and $80 <> 0) then
      FMode := FIO[$60] and $E0;
  end;
end;

procedure TWSVideo.Tick(Line, FirstClock, Clocks: Integer);
var
  Color: TAlphaColor;
begin
  for var Clock := FirstClock to FirstClock + Clocks - 1 do
  begin
    if Line < WS_HEIGHT then
      FetchCycle(Line, Clock);
    if Line = 144 then
    begin
      if Clock = 0 then
        FSpriteCount := Min(Integer(FIO[6]), 128);
      var Base := Integer(FIO[4] and $3F) shl 9;
      if not FHardwareColor then
        Base := Base and $3FFF;
      // One word per clock, including entries beyond the displayed count.
      var Offset := Clock * 2;
      for var B := 0 to 1 do
        FOAM[(Offset + B) shr 2, (Offset + B) and 3] :=
          FRAM[Base + ((Integer(FIO[5]) * 4 + Offset + B) and $1FF)];
    end;
    if (Line < 1) or (Line > WS_HEIGHT) or (Clock >= WS_WIDTH) then
      Continue;
    if (FIO[$14] and 1 = 0) or (FIO[$1A] and 1 <> 0) then
      Color := $FFFFFFFF
    else
    begin
      var Indexed := FRows[(Line - 1) and 1, Clock];
      if Indexed and $100 <> 0 then
        Color := PaletteColor((Indexed shr 4) and 15, Indexed and 15)
      else if FMode and $80 <> 0 then
        Color := PaletteColor(FIO[1] shr 4, FIO[1] and 15)
      else
        Color := PaletteColor(-1, FIO[1] and 7);
    end;
    FNative[(Line - 1) * WS_WIDTH + Clock] := Color;
  end;
end;

procedure TWSVideo.ComposeLine(Y: Integer);
begin
  // No VRAM reads here: each stage already captured its data in its slot.
  for var X := 0 to WS_WIDTH - 1 do
  begin
    var Color := FLayerRows[0, X];
    var Front := FLayerRows[1, X];
    if Front <> 0 then
      Color := Front;
    var Sprite := FSpriteRow[X];
    if (Sprite <> 0) and ((Front = 0) or (Sprite and $200 <> 0)) then
      Color := Sprite and $1FF;
    FRows[Y and 1, X] := Color;
  end;
end;

procedure TWSVideo.EndFrame;
begin
  if (FIO[$16] = 255) or (FIO[$1A] and 1 <> 0) then
    for var I := 0 to High(FNative) do
      FNative[I] := $FFFFFFFF
  else if FIO[$16] < 144 then
    for var I := Integer(FIO[$16]) * WS_WIDTH to High(FNative) do
      FNative[I] := $FFFFFFFF;
  if not Vertical then
    Move(FNative[0], FPixels[0], Length(FNative) * SizeOf(TAlphaColor))
  else
    for var Y := 0 to WS_HEIGHT - 1 do
      for var X := 0 to WS_WIDTH - 1 do
        FPixels[(WS_WIDTH - 1 - X) * WS_HEIGHT + Y] := FNative[Y * WS_WIDTH + X];
end;

procedure TWSVideo.SerializeState(State: TStateArchive);
begin
  State.Field(FOAM, SizeOf(FOAM));
  State.Field(FSpriteCount, SizeOf(FSpriteCount));
  State.Field(FRows, SizeOf(FRows));
  State.Field(FLatched, SizeOf(FLatched));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FLayerRows, SizeOf(FLayerRows));
  State.Field(FSpriteRow, SizeOf(FSpriteRow));
  State.Field(FFetchAttr, SizeOf(FFetchAttr));
  State.Field(FSelectedSprites, SizeOf(FSelectedSprites));
  State.Field(FSelectedCount, SizeOf(FSelectedCount));
  State.Field(FSpriteData, SizeOf(FSpriteData));
  State.Field(FNative[0], Length(FNative) * SizeOf(TAlphaColor));
  if State.Loading then
  begin
    if (FSpriteCount < 0) or (FSpriteCount > 128) or
      (FSelectedCount < 0) or (FSelectedCount > 32) then
      raise EReadError.Create('Invalid WonderSwan sprite state');
    EndFrame;
  end;
end;

end.

