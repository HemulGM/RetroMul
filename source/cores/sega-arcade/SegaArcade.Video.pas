unit SegaArcade.Video;

// Hardware formats cross-checked against segaic16 / sega16sp
interface

uses
  System.SysUtils, System.UITypes, Core.Snapshots;

const
  SEGA_ARCADE_WIDTH = 320;
  SEGA_ARCADE_HEIGHT = 224;

type
  TSegaArcadeVideo = class
  private
    FTiles, FSprites: TBytes;
    FA: Boolean;
  protected
    FSpriteBanks: array[0..15] of Byte;
    FIndex: array[0..SEGA_ARCADE_WIDTH * SEGA_ARCADE_HEIGHT - 1] of Word;
    FPriority: array[0..SEGA_ARCADE_WIDTH * SEGA_ARCADE_HEIGHT - 1] of Byte;
    FSpritePixels: array[0..SEGA_ARCADE_WIDTH * SEGA_ARCADE_HEIGHT - 1] of Word;
    FPages, FScrollX, FScrollY: array[0..3] of Word;
    function TilePixel(Code, X, Y: Integer): Integer;
    procedure DrawLayer(Which: Integer; Opaque: Boolean = True);
    procedure DrawBackground; virtual;
    procedure MixLayer(Layer: Integer); virtual;
    procedure ResetBanks; virtual;
    procedure DrawText;
    procedure DrawSprites;
    function Color(Index: Integer): TAlphaColor; virtual;
    function DecodeTile(Code: Integer): Integer; virtual;
    function PixelColor(Offset: Integer): TAlphaColor; virtual;
    procedure ShadePixel(Offset: Integer); virtual;
  public
    TileRAM: array[0..$7FFF] of Word;
    TextRAM: array[0..$7FF] of Word;
    SpriteRAM: array[0..$3FF] of Word;
    PaletteRAM: array[0..$7FF] of Word;
    TileBank: array[0..1] of Byte;
    DisplayEnabled, Flip, RowScroll, ColumnScroll: Boolean;
    Pixels: TArray<TAlphaColor>;
    constructor Create(const Tiles, Sprites: TBytes; RevisionA: Boolean; SparseSpriteBanks: Boolean = False);
    procedure Reset;
    procedure Latch;
    procedure Render;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor TSegaArcadeVideo.Create(const Tiles, Sprites: TBytes; RevisionA: Boolean; SparseSpriteBanks: Boolean);
const
  // 171-5358 jumper/address decoding; 255 means an unconnected bank.
  Banks5358: array[0..15] of Byte = (0, 255, 255, 255, 255, 255, 255, 3,
    255, 255, 255, 2, 255, 1, 0, 255);
begin
  inherited Create;
  FTiles := Tiles;
  FSprites := Sprites;
  FA := RevisionA;
  for var i := 0 to High(FSpriteBanks) do
    if SparseSpriteBanks then
      FSpriteBanks[i] := Banks5358[i]
    else
      FSpriteBanks[i] := i;
  SetLength(Pixels, SEGA_ARCADE_WIDTH * SEGA_ARCADE_HEIGHT);
  Reset;
end;

procedure TSegaArcadeVideo.ResetBanks;
begin
  TileBank[0] := 0;
  TileBank[1] := 1;
end;

procedure TSegaArcadeVideo.Reset;
begin
  FillChar(TileRAM, SizeOf(TileRAM), 0);
  FillChar(TextRAM, SizeOf(TextRAM), 0);
  FillChar(SpriteRAM, SizeOf(SpriteRAM), 0);
  FillChar(PaletteRAM, SizeOf(PaletteRAM), 0);
  ResetBanks;
  DisplayEnabled := False;
  Flip := False;
  RowScroll := False;
  ColumnScroll := False;
  Latch;
  Render;
end;

procedure TSegaArcadeVideo.Latch;
begin
  for var i := 0 to 3 do
  begin
    FPages[i] := TextRAM[$E80 div 2 + i];
    FScrollY[i] := TextRAM[$E90 div 2 + i];
    FScrollX[i] := TextRAM[$E98 div 2 + i];
  end;
end;

function TSegaArcadeVideo.TilePixel(Code, X, Y: Integer): Integer;
begin
  var Plane := Length(FTiles) div 3;
  var Offset := Code * 8 + (Y and 7);
  if (Offset < 0) or (Offset >= Plane) then
    Exit(0);
  var Shift := 7 - (X and 7);
  Result := (FTiles[Offset] shr Shift) and 1;
  Result := Result or (((FTiles[Offset + Plane] shr Shift) and 1) shl 1);
  Result := Result or (((FTiles[Offset + Plane * 2] shr Shift) and 1) shl 2);
end;

function TSegaArcadeVideo.DecodeTile(Code: Integer): Integer;
begin
  Result := TileBank[Code div $1000] * $1000 + (Code and $FFF);
end;

procedure TSegaArcadeVideo.DrawLayer(Which: Integer; Opaque: Boolean);
begin
  for var Y := 0 to SEGA_ARCADE_HEIGHT - 1 do
    for var X := 0 to SEGA_ARCADE_WIDTH - 1 do
    begin
      var Pages: Integer;
      var SX, SY, XS, YS: Integer;
      if FA then
      begin
        var PageRegister := $E9E div 2 - Which;
        if Flip then
          PageRegister := $E8E div 2 - Which;
        Pages := TextRAM[PageRegister];
        Pages := ((Pages shr 4) and $0707) or ((Pages shl 4) and $7070);
        XS := TextRAM[$FF8 div 2 + Which] and $1FF;
        YS := TextRAM[$F24 div 2 + Which] and $FF;
        if RowScroll then
          XS := TextRAM[$F80 div 2 + (Y div 8) * 2 + Which] and $1FF;
        if ColumnScroll then
          YS := TextRAM[$F30 div 2 + (X div 16) * 2 + Which] and $FF;
        SX := (X + $C8 - XS) and $3FF;
        SY := (Y + YS) and $1FF;
      end
      else
      begin
        Pages := FPages[Which];
        XS := FScrollX[Which];
        YS := FScrollY[Which];
        var Row := TextRAM[$F80 div 2 + $20 * Which + Y div 8];
        if XS and $8000 <> 0 then
          XS := Row;
        if YS and $8000 <> 0 then
          YS := TextRAM[$F16 div 2 + $20 * Which + (X + 8) div 16];
        if Row and $8000 <> 0 then
        begin
          Pages := FPages[Which + 2];
          XS := FScrollX[Which + 2];
          YS := FScrollY[Which + 2];
        end;
        SX := (X + $C0 - XS) and $3FF;
        SY := (Y + YS) and $1FF;
      end;
      var Quadrant := (SX div 512) + (SY div 256) * 2;
      var Page := (Pages shr (Quadrant * 4)) and $F;
      var Data := TileRAM[Page * $800 + ((SY and $FF) div 8) * 64 + (SX and $1FF) div 8];
      var Code, Palette, Priority: Integer;
      if FA then
      begin
        Code := (Data and $FFF) or ((Data shr 1) and $1000);
        Palette := (Data shr 5) and $7F;
        Priority := (Data shr 12) and 1;
      end
      else
      begin
        Code := Data and $1FFF;
        Code := DecodeTile(Code);
        Palette := (Data shr 6) and $7F;
        Priority := Data shr 15;
      end;
      var Pixel := TilePixel(Code, SX, SY);
      var Offset := Y * SEGA_ARCADE_WIDTH + X;
      if (Pixel <> 0) or ((Which = 1) and Opaque) then
        FIndex[Offset] := Palette * 8 + Pixel;
      if Pixel <> 0 then
        FPriority[Offset] := FPriority[Offset] or (1 shl (Priority + 1 - Which));
    end;
end;

procedure TSegaArcadeVideo.DrawText;
begin
  for var Y := 0 to SEGA_ARCADE_HEIGHT - 1 do
    for var X := 0 to SEGA_ARCADE_WIDTH - 1 do
    begin
      var Data := TextRAM[(Y div 8) * 64 + X div 8 + 24];
      var Code, Palette, Priority: Integer;
      if FA then
      begin
        Code := Data and $FF;
        Palette := (Data shr 8) and 7;
        Priority := (Data shr 11) and 1;
      end
      else
      begin
        Code := DecodeTile(Data and $1FF);
        Palette := (Data shr 9) and 7;
        Priority := Data shr 15;
      end;
      var Pixel := TilePixel(Code, X, Y);
      if Pixel <> 0 then
      begin
        var Offset := Y * SEGA_ARCADE_WIDTH + X;
        FIndex[Offset] := Palette * 8 + Pixel;
        FPriority[Offset] := FPriority[Offset] or (4 shl Priority);
      end;
    end;
end;

procedure TSegaArcadeVideo.DrawSprites;
begin
  FillChar(FSpritePixels, SizeOf(FSpritePixels), $FF);
  var BankBytes := $20000;
  if FA then
    BankBytes := $10000;
  var Banks := Length(FSprites) div BankBytes;
  if Banks = 0 then
    Exit;
  for var i := 0 to $7F do
  begin
    var Base := i * 8;
    var Bottom := Integer(SpriteRAM[Base] shr 8);
    var Top := Integer(SpriteRAM[Base] and $FF);
    var Control := SpriteRAM[Base + 2];
    if (FA and (Bottom > $F0)) or (not FA and (Control and $8000 <> 0)) then
      Break;
    var Address := Integer(SpriteRAM[Base + 3]);
    // The address latch is initialized even for hidden, empty and unmapped sprites.
    SpriteRAM[Base + 7] := Word(Address);
    if (Top >= Bottom) or (not FA and (Control and $4000 <> 0)) then
      Continue;
    var Attr := SpriteRAM[Base + 4];
    var XPos := Integer(SpriteRAM[Base + 1] and $1FF);
    var Pitch, Bank, ColPri, HZoom, VZoom, XOrigin, YOrigin: Integer;
    if FA then
    begin
      Pitch := Integer(Control and $7FFF) - Integer(Control and $8000);
      Bank := (Attr shr 4) and 7;
      ColPri := (((Attr shr 8) and $3F) shl 4) or ((Attr and 3) shl 10);
      HZoom := 0;
      VZoom := 0;
      XOrigin := 189;
      YOrigin := 1;
    end
    else
    begin
      Pitch := Integer(Control and $7F) - Integer(Control and $80);
      Bank := (Attr shr 8) and $F;
      ColPri := (Attr and $FF) shl 4;
      HZoom := SpriteRAM[Base + 5] and $1F;
      VZoom := (SpriteRAM[Base + 5] shr 5) and $1F;
      XOrigin := 184;
      YOrigin := 0;
    end;
    Bank := FSpriteBanks[Bank];
    if Bank = 255 then
      Continue;
    Bank := Bank mod Banks;
    var XDelta := 1;
    if Flip then
    begin
      var OldTop := Top;
      Top := SEGA_ARCADE_HEIGHT - Bottom;
      Bottom := SEGA_ARCADE_HEIGHT - OldTop;
      XPos := SEGA_ARCADE_WIDTH - XPos;
      XOrigin := -XOrigin;
      XDelta := -1;
    end;
    var YAcc := SpriteRAM[Base + 5] and $3FF;
    for var Y := Top to Bottom - 1 do
    begin
      Address := (Address + Pitch) and $FFFF;
      if not FA then
      begin
        YAcc := YAcc + (VZoom shl 10);
        if YAcc and $8000 <> 0 then
        begin
          Address := (Address + Pitch) and $FFFF;
          YAcc := YAcc and $7FFF;
        end;
      end;
      var DestY := Y + YOrigin;
      if (DestY < 0) or (DestY >= SEGA_ARCADE_HEIGHT) then
        Continue;
      var Reverse := Control and $100 <> 0;
      if FA then
        Reverse := Address and $8000 <> 0;
      var Cursor := Address;
      var LastRead: Integer;
      var X := 0;
      var XAcc := 4 * HZoom;
      // A full address-space pass bounds malformed rows with no end marker.
      // Valid rows stop on their fourth-nibble marker or the hardware X counter.
      for var Words := 0 to $FFFF do
      begin
        LastRead := Cursor;
        var WordAddress := Cursor and $FFFF;
        if FA then
          WordAddress := Cursor and $7FFF;
        var ROMOffset := Bank * BankBytes + WordAddress * 2;
        var Data := (Integer(FSprites[ROMOffset]) shl 8) or FSprites[ROMOffset + 1];
        var LastPixel: Integer;
        for var N := 0 to 3 do
        begin
          var Shift := 12 - N * 4;
          if Reverse then
            Shift := N * 4;
          var Pixel := (Data shr Shift) and $F;
          LastPixel := Pixel;
          XAcc := (XAcc and $3F) + HZoom;
          if XAcc >= $40 then
            Continue;
          // The fetch counter wraps, but pixels do not wrap back into the
          // viewport when a sprite extends past the right/left clipping edge.
          var DestX := XPos + XDelta * X - XOrigin;
          if (DestX >= 0) and (DestX < SEGA_ARCADE_WIDTH) and (Pixel <> 0) and (Pixel <> 15) then
            FSpritePixels[DestY * SEGA_ARCADE_WIDTH + DestX] := ColPri or Pixel;
          Inc(X);
        end;
        if Reverse then
          Cursor := (Cursor - 1) and $FFFF
        else
          Cursor := (Cursor + 1) and $FFFF;
        if (LastPixel = 15) or (((-XDelta * X) and $1FF) = 1) then
          Break;
      end;
      SpriteRAM[Base + 7] := Word(LastRead and $FFFF);
    end;
    if not FA then
      SpriteRAM[Base + 5] := Word(YAcc and $7FFF);
  end;
  for var i := 0 to High(FIndex) do
  begin
    var Pixel := FSpritePixels[i];
    if (Pixel <> $FFFF) and ((1 shl ((Pixel shr 10) and 3)) > FPriority[i]) then
      if Pixel and $3F0 = $3F0 then
        ShadePixel(i)
      else
        FIndex[i] := $400 or (Pixel and $3FF);
  end;
end;

function TSegaArcadeVideo.Color(Index: Integer): TAlphaColor;
begin
  var Data := PaletteRAM[Index and $7FF];
  var R := ((Data and $F) shl 1) or ((Data shr 12) and 1);
  var G := ((Data shr 3) and $1E) or ((Data shr 13) and 1);
  var B := ((Data shr 7) and $1E) or ((Data shr 14) and 1);
  R := R * 255 div 31;
  G := G * 255 div 31;
  B := B * 255 div 31;
  if Index and $800 <> 0 then
    if Data and $8000 <> 0 then
    begin
      R := R * 4 div 5 + 51;
      G := G * 4 div 5 + 51;
      B := B * 4 div 5 + 51;
    end
    else
    begin
      R := R * 4 div 5;
      G := G * 4 div 5;
      B := B * 4 div 5;
    end;
  Result := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

procedure TSegaArcadeVideo.DrawBackground;
begin
  DrawLayer(1);
end;

procedure TSegaArcadeVideo.MixLayer(Layer: Integer);
begin
end;

procedure TSegaArcadeVideo.ShadePixel(Offset: Integer);
begin
  FIndex[Offset] := (FIndex[Offset] and $7FF) or $800;
end;

function TSegaArcadeVideo.PixelColor(Offset: Integer): TAlphaColor;
begin
  Result := Color(FIndex[Offset]);
end;

procedure TSegaArcadeVideo.Render;
begin
  if not DisplayEnabled then
  begin
    for var i := 0 to High(Pixels) do
      Pixels[i] := $FF000000;
    Exit;
  end;
  FillChar(FPriority, SizeOf(FPriority), 0);
  DrawBackground;
  MixLayer(1);
  DrawLayer(0);
  MixLayer(2);
  DrawText;
  MixLayer(3);
  if Flip then
    for var i := 0 to High(FIndex) div 2 do
    begin
      var J := High(FIndex) - i;
      var Index := FIndex[i];
      FIndex[i] := FIndex[J];
      FIndex[J] := Index;
      var Priority := FPriority[i];
      FPriority[i] := FPriority[J];
      FPriority[J] := Priority;
    end;
  // Sprites have their own global-flip position/direction circuit. In particular,
  // row fetch order is controlled by pitch, not by rotating the completed image.
  DrawSprites;
  for var i := 0 to High(Pixels) do
    Pixels[i] := PixelColor(i);
end;

procedure TSegaArcadeVideo.SerializeState(State: TStateArchive);
begin
  State.Field(TileRAM, SizeOf(TileRAM));
  State.Field(TextRAM, SizeOf(TextRAM));
  State.Field(SpriteRAM, SizeOf(SpriteRAM));
  State.Field(PaletteRAM, SizeOf(PaletteRAM));
  State.Field(TileBank, SizeOf(TileBank));
  State.Field(DisplayEnabled, SizeOf(DisplayEnabled));
  State.Field(Flip, SizeOf(Flip));
  State.Field(RowScroll, SizeOf(RowScroll));
  State.Field(ColumnScroll, SizeOf(ColumnScroll));
  State.Field(FPages, SizeOf(FPages));
  State.Field(FScrollX, SizeOf(FScrollX));
  State.Field(FScrollY, SizeOf(FScrollY));
  // Retain the exact published frame without running the sprite generator again.
  State.Field(Pixels[0], Length(Pixels) * SizeOf(TAlphaColor));
end;

end.

