unit NeoGeo.Video;

interface

uses
  System.SysUtils, System.UITypes, NeoGeo.Cartridge, Core.Snapshots;

const
  NG_WIDTH = 320;
  NG_HEIGHT = 224;
  NG_LINES = 264;
  NG_LINE_CLOCKS = 1536;
  NG_FRAME_CLOCKS = NG_LINES * NG_LINE_CLOCKS;
  NG_FPS = 24000000.0 / NG_FRAME_CLOCKS;

type
  TNeoGeoVideo = class
  private
    FCart: TNeoGeoCartridge;
    FSpriteMask: Integer;
    FAddress, FModulo: Word;
    FAnimation, FAnimationDelay, FAnimationSpeed: Byte;
    FAnimationDisabled: Boolean;
    function Color(Index: Integer): TAlphaColor;
    function SpritePixel(Code, Y, X: Integer): Byte;
  public
    VRAM: array[0..$87FF] of Word;
    Palette: array[0..$1FFF] of Word;
    PaletteBank: Integer;
    CartFixed, Shadow: Boolean;
    Pixels: array[0..NG_WIDTH * NG_HEIGHT - 1] of TAlphaColor;
    constructor Create(Cart: TNeoGeoCartridge);
    procedure Reset;
    procedure ClearFrame;
    function StartupVideoReady: Boolean;
    procedure SetAddress(Value: Word);
    procedure WriteData(Value: Word);
    function ReadRegister(Index, Line: Integer): Word;
    procedure Control(Value: Word);
    procedure RenderLine(Line: Integer);
    procedure NextFrame;
    procedure SerializeState(State: TStateArchive);
    property Modulo: Word read FModulo write FModulo;
  end;

implementation

// Hardware behavior cross-checked with NeoGeo Development Wiki and MAME's
// BSD-3-Clause neogeo_spr.cpp (Bryan McPhail, Ernesto Corvi, Andrew Prime,
// Zsolt Vasvari). All graphics access below uses checked array indices.

constructor TNeoGeoVideo.Create(Cart: TNeoGeoCartridge);
begin
  inherited Create;
  FCart := Cart;
  var Tiles := Length(Cart.SpriteROM) div 128;
  var Size := 1;
  while Size < Tiles do
    Size := Size * 2;
  FSpriteMask := Size - 1;
  Reset;
end;

procedure TNeoGeoVideo.Reset;
begin
  FillChar(VRAM, SizeOf(VRAM), 0);
  FillChar(Palette, SizeOf(Palette), 0);
  FAddress := 0;
  FModulo := 0;
  FAnimation := 0;
  FAnimationDelay := 0;
  FAnimationSpeed := 0;
  FAnimationDisabled := False;
  PaletteBank := 0;
  CartFixed := False;
  Shadow := False;
  ClearFrame;
end;

procedure TNeoGeoVideo.ClearFrame;
begin
  for var I := Low(Pixels) to High(Pixels) do
    Pixels[I] := $FF000000;
end;

function TNeoGeoVideo.StartupVideoReady: Boolean;
begin
  // Cartridge graphics, including the animated BIOS logo, are ready to show.
  if CartFixed then
    Exit(True);
  // The system FIX map is cleared to ASCII spaces before the BIOS displays
  // menus or errors. Reject the AA/55/address patterns left by its RAM tests.
  // Checking every visible entry also rejects a partially cleared test map.
  Result := False;
  for var Column := 0 to 39 do
    for var Row := 2 to 29 do
    begin
      var Code := VRAM[$7000 + Column * 32 + Row] and $FFF;
      if Code >= $100 then
        Exit(False);
      if Code = $20 then
        Result := True;
    end;
end;

procedure TNeoGeoVideo.SetAddress(Value: Word);
begin
  FAddress := Value;
  if (Value and $8000) <> 0 then
    FAddress := Value and $87FF;
end;

procedure TNeoGeoVideo.WriteData(Value: Word);
begin
  VRAM[FAddress] := Value;
  SetAddress(Word((FAddress and $8000) or ((Integer(FAddress) + FModulo) and $7FFF)));
end;

function TNeoGeoVideo.ReadRegister(Index, Line: Integer): Word;
begin
  case Index and 3 of
    0, 1:
      Result := VRAM[FAddress];
    2:
      Result := FModulo;
  else
    var Counter := Line + $100;
    if Counter >= $200 then
      Dec(Counter, NG_LINES);
    Result := Word(((Counter shl 7) or (FAnimation and 7)) and $FFFF);
  end;
end;

procedure TNeoGeoVideo.Control(Value: Word);
begin
  FAnimationSpeed := Value shr 8;
  FAnimationDisabled := (Value and 8) <> 0;
end;

procedure TNeoGeoVideo.NextFrame;
begin
  if FAnimationDelay = 0 then
  begin
    FAnimationDelay := FAnimationSpeed;
    FAnimation := Byte((Integer(FAnimation) + 1) and $FF);
  end
  else
    Dec(FAnimationDelay);
end;

function TNeoGeoVideo.Color(Index: Integer): TAlphaColor;
begin
  var Value := Palette[PaletteBank * $1000 + (Index and $FFF)];
  var R := ((Value shr 14) and 1) or ((Value shr 7) and $1E);
  var G := ((Value shr 13) and 1) or ((Value shr 3) and $1E);
  var B := ((Value shr 12) and 1) or ((Value shl 1) and $1E);
  R := R * 255 div 31;
  G := G * 255 div 31;
  B := B * 255 div 31;
  if (Value and $8000) <> 0 then
  begin
    R := R * 8 div 9;
    G := G * 8 div 9;
    B := B * 8 div 9;
  end;
  if Shadow then
  begin
    R := R div 2;
    G := G div 2;
    B := B div 2;
  end;
  Result := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

function TNeoGeoVideo.SpritePixel(Code, Y, X: Integer): Byte;
begin
  // Unwired tile address lines mirror the ROM; holes in partial regions stay blank.
  var Base := (Code and FSpriteMask) * 128 + ((X and 8) xor 8) * 8 + Y * 4;
  Result := 0;
  if Base + 3 >= Length(FCart.SpriteROM) then
    Exit;
  var Bit := X and 7;
  Result := ((FCart.SpriteROM[Base] shr Bit) and 1) or
    (((FCart.SpriteROM[Base + 2] shr Bit) and 1) shl 1) or
    (((FCart.SpriteROM[Base + 1] shr Bit) and 1) shl 2) or
    (((FCart.SpriteROM[Base + 3] shr Bit) and 1) shl 3);
end;

procedure TNeoGeoVideo.RenderLine(Line: Integer);
const
  ZoomX: array[0..15] of Word = ($0080, $0880, $0888, $2888, $288A,
    $2A8A, $2AAA, $AAAA, $AAEA, $BAEA, $BAEB, $BBEB, $BBEF, $FBEF, $FBFF, $FFFF);
  FixOffsets: array[0..3] of Integer = ($10, $18, 0, 8);
begin
  if (Line < 0) or (Line >= NG_LINES) then
    Exit;
  var Visible := (Line >= 16) and (Line < 240);
  var Row := (Line - 16) * NG_WIDTH;
  if Visible then
    for var X := 0 to NG_WIDTH - 1 do
      Pixels[Row + X] := Color($FFF);
  var X := 0;
  var Y := 0;
  var Rows := 0;
  var ZX := 0;
  var ZY := 0;
  var Active := 0;
  var List := $8600 + (Line and 1) * $80;
  // Neo Pong's background consumes the physical line limit before its UI.
  // Render these releases permissively while keeping the hardware sprite list bounded.
  var Permissive := (FCart.SetName = 'neopong') or (FCart.SetName = 'neopong10');
  for var Sprite := 0 to 380 do
  begin
    var Control := VRAM[$8200 + Sprite];
    var Zoom := VRAM[$8000 + Sprite];
    if (Control and $40) <> 0 then
    begin
      X := (X + ZX + 1) and $1FF;
      ZX := (Zoom shr 8) and 15;
    end
    else
    begin
      Y := $200 - (Control shr 7);
      X := VRAM[$8400 + Sprite] shr 7;
      Rows := Control and $3F;
      ZX := (Zoom shr 8) and 15;
      ZY := Zoom and $FF;
    end;
    var SpriteLine := (Line + $200 - Y) and $1FF;
    if (Rows = 0) or ((Rows < 32) and (SpriteLine >= Rows * 16)) then
      Continue;
    if Active < 96 then
    begin
      VRAM[List + Active] := Sprite;
      Inc(Active);
    end;
    if Visible then
    begin
      var ZoomLine := SpriteLine and $FF;
      var Invert := (SpriteLine and $100) <> 0;
      if Invert then
        ZoomLine := ZoomLine xor $FF;
      if Rows > 32 then
      begin
        ZoomLine := ZoomLine mod ((ZY + 1) * 2);
        if ZoomLine > ZY then
        begin
          ZoomLine := (ZY + 1) * 2 - 1 - ZoomLine;
          Invert := not Invert;
        end;
      end;
      var Encoded := FCart.ZoomROM[ZY * 256 + ZoomLine];
      var Tile := Encoded shr 4;
      var TY := Encoded and 15;
      if Invert then
      begin
        Tile := Tile xor 31;
        TY := TY xor 15;
      end;
      var Offset := Sprite * 64 + Tile * 2;
      var Attr := VRAM[Offset + 1];
      var Code := Integer(VRAM[Offset]) or ((Attr and $F0) shl 12);
      if not FAnimationDisabled then
      begin
        if (Attr and 8) <> 0 then
          Code := (Code and $FFFF8) or (FAnimation and 7)
        else if (Attr and 4) <> 0 then
          Code := (Code and $FFFFC) or (FAnimation and 3);
      end;
      if (Attr and 2) <> 0 then
        TY := TY xor 15;
      var DX := X;
      for var SX := 0 to 15 do
        if (ZoomX[ZX] and (1 shl (15 - SX))) <> 0 then
        begin
          var TX := SX;
          if (Attr and 1) <> 0 then
            TX := 15 - TX;
          var Pen := SpritePixel(Code, TY, TX);
          var ScreenX := DX;
          if X > $1F0 then
            ScreenX := DX - $200;
          if (Pen <> 0) and (ScreenX >= 0) and (ScreenX < NG_WIDTH) then
            Pixels[Row + ScreenX] := Color((Attr shr 8) * 16 + Pen);
          Inc(DX);
        end;
    end;
    if (Active = 96) and not Permissive then
      Break;
  end;
  for var I := Active to 96 do
    VRAM[List + I] := 0;
  if not Visible then
    Exit;
  var FixedData := FCart.FixedBIOS;
  if CartFixed then
    FixedData := FCart.FixedROM;
  var FixedBank := 0;
  if CartFixed and (Length(FixedData) > $20000) and (FCart.FixedBankType = 1) then
  begin
    var Banks: array[0..33] of Integer;
    var K := 0;
    var BankRow := 0;
    var Bank := 0;
    while BankRow < 32 do
    begin
      if (VRAM[$7500 + K] = $0200) and ((VRAM[$7580 + K] and $FF00) = $FF00) then
      begin
        Bank := VRAM[$7580 + K] and 3;
        Banks[BankRow] := Bank;
        Inc(BankRow);
      end;
      Banks[BankRow] := Bank;
      Inc(BankRow);
      Inc(K, 2);
    end;
    FixedBank := $1000 * (Banks[((Line shr 3) - 2) and 31] xor 3);
  end;
  for var Column := 0 to 39 do
  begin
    var Entry := VRAM[$7000 + Column * 32 + (Line shr 3)];
    var Code := Entry and $FFF;
    Inc(Code, FixedBank);
    if CartFixed and (Length(FixedData) > $20000) and (FCart.FixedBankType = 2) then
      Inc(Code, $1000 * (((VRAM[$7500 + (((Line shr 3) - 1) and 31) +
          32 * (Column div 6)] shr ((5 - (Column mod 6)) * 2)) and 3) xor 3));
    var Base := Code * 32 + (Line and 7);
    for var Pair := 0 to 3 do
    begin
      var Address := Base + FixOffsets[Pair];
      Address := Address mod Length(FixedData);
      var ByteValue := FixedData[Address];
      for var Nibble := 0 to 1 do
      begin
        var Pen := (ByteValue shr (Nibble * 4)) and 15;
        if Pen <> 0 then
          Pixels[Row + Column * 8 + Pair * 2 + Nibble] := Color((Entry shr 12) * 16 + Pen);
      end;
    end;
  end;
end;

procedure TNeoGeoVideo.SerializeState(State: TStateArchive);
begin
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(Palette, SizeOf(Palette));
  State.Field(PaletteBank, SizeOf(PaletteBank));
  State.Field(CartFixed, SizeOf(CartFixed));
  State.Field(Shadow, SizeOf(Shadow));
  State.Field(Pixels, SizeOf(Pixels));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FModulo, SizeOf(FModulo));
  State.Field(FAnimation, SizeOf(FAnimation));
  State.Field(FAnimationDelay, SizeOf(FAnimationDelay));
  State.Field(FAnimationSpeed, SizeOf(FAnimationSpeed));
  State.Field(FAnimationDisabled, SizeOf(FAnimationDisabled));
end;

end.

