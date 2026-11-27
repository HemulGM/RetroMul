unit INTV.STIC;

interface

uses
  System.UITypes, Core.Snapshots;

const
  IntvScreenWidth = 160;
  IntvScreenHeight = 192;

type
  TIntvSTIC = class
  private
    type
      TPixelMask = array[0..IntvScreenWidth * IntvScreenHeight - 1] of Byte;

      TBacktab = array[0..239] of Word;
  private
    FRegisters: array[0..$32] of Word;
    FBacktab: TBacktab;
    FForeground, FBackgroundColors: TPixelMask;
    FOccupancy: TPixelMask;
    FPixels: TArray<TAlphaColor>;
    FDisplayStrobe, FActive, FForegroundBackground: Boolean;
    FLeft, FRight, FTop, FDelayX, FDelayY: Integer;
    FSTIC1A: Boolean;
    procedure DrawBackground(const GROM, GRAM: array of Byte);
    procedure DrawObjects(const GROM, GRAM: array of Byte);
    function InDisplay(X, Y: Integer): Boolean;
  public
    constructor Create(STIC1A: Boolean = False);
    procedure Reset;
    procedure BeginFrame;
    procedure LatchDisplay;
    procedure FetchRow(Row: Integer; const SystemRAM: array of Word);
    procedure Draw(const GROM, GRAM: array of Byte);
    function ReadRegister(Address: Word): Word;
    procedure WriteRegister(Address, Value: Word);
    function VerticalDelay: Integer;
    procedure SerializeState(State: TStateArchive);
    property Active: Boolean read FActive;
    property DisplayStrobe: Boolean read FDisplayStrobe;
    property Pixels: TArray<TAlphaColor> read FPixels;
  end;

implementation

const
  Colors: array[0..15] of TAlphaColor = (
    $FF000000, $FF002DFF, $FFFF3D10, $FFC9CFAB,
    $FF386B3F, $FF00A756, $FFFAEA50, $FFFFFFFF,
    $FFBCBCBC, $FF5AD5FF, $FFFFA600, $FF3C5800,
    $FFFF3276, $FFBD95FF, $FF6CCD30, $FFC81A7D
  );

constructor TIntvSTIC.Create(STIC1A: Boolean);
begin
  inherited Create;
  FSTIC1A := STIC1A;
  FRight := IntvScreenWidth - 1 + Ord(STIC1A);
  SetLength(FPixels, IntvScreenWidth * IntvScreenHeight);
  Reset;
end;

procedure TIntvSTIC.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FBacktab, SizeOf(FBacktab), 0);
  FActive := False;
  FDisplayStrobe := False;
  FForegroundBackground := False;
  for var Index := 0 to High(FPixels) do
    FPixels[Index] := Colors[0];
end;

procedure TIntvSTIC.BeginFrame;
begin
  FDisplayStrobe := False;
end;

procedure TIntvSTIC.LatchDisplay;
begin
  FActive := FDisplayStrobe;
end;

procedure TIntvSTIC.FetchRow(Row: Integer; const SystemRAM: array of Word);
begin
  Move(SystemRAM[Row * 20], FBacktab[Row * 20], 20 * SizeOf(Word));
end;

function TIntvSTIC.ReadRegister(Address: Word): Word;
begin
  case Address of
    $00..$07:
      Result := FRegisters[Address] or $3800;
    $08..$0F:
      Result := FRegisters[Address] or $3000;
    $10..$17:
      Result := FRegisters[Address];
    $18..$1F:
      Result := FRegisters[Address] or $3C00;
    $21:
      begin
        FForegroundBackground := False;
        Result := $3FFF;
      end;
    $22:
      if FSTIC1A then
        Result := $3FF7
      else
        Result := $3FFF;
    $28..$2C:
      Result := FRegisters[Address] or $3FF0;
    $30..$31:
      Result := FRegisters[Address] or $3FF8;
    $32:
      Result := FRegisters[Address] or $3FFC;
  else
    Result := $3FFF;
  end;
end;

procedure TIntvSTIC.WriteRegister(Address, Value: Word);
begin
  case Address of
    $00..$07:
      FRegisters[Address] := Value and $07FF;
    $08..$0F:
      FRegisters[Address] := Value and $0FFF;
    $10..$17:
      FRegisters[Address] := Value and $3FFF;
    $18..$1F:
      FRegisters[Address] := Value and $03FF and not (1 shl (Address - $18));
    $20:
      FDisplayStrobe := True;
    $21:
      FForegroundBackground := True;
    $28..$2C:
      FRegisters[Address] := Value and 15;
    $30..$31:
      FRegisters[Address] := Value and 7;
    $32:
      FRegisters[Address] := Value and 3;
  end;
end;

function TIntvSTIC.VerticalDelay: Integer;
begin
  Result := FRegisters[$31];
end;

function TIntvSTIC.InDisplay(X, Y: Integer): Boolean;
begin
  Result := (X >= FLeft) and (X < FRight) and
    (Y >= FTop) and (Y < IntvScreenHeight);
end;

procedure TIntvSTIC.DrawBackground(const GROM, GRAM: array of Byte);
begin
  var StackIndex := 0;
  for var Tile := 0 to High(FBacktab) do
  begin
    var Card := FBacktab[Tile];
    var FromGRAM := Card and $800 <> 0;
    var Squares := not FForegroundBackground and (Card and $1800 = $1000);
    var Pattern := Card and $7F8;
    if FForegroundBackground or (FromGRAM and not FSTIC1A) then
      Pattern := Pattern and $1F8;
    var Ink := Card and 7;
    var Paper: Integer;
    if FForegroundBackground then
      Paper := ((Card shr 9) and 3) or ((Card shr 11) and 4) or ((Card shr 9) and 8)
    else
    begin
      if (not Squares) and (Card and $2000 <> 0) then
        StackIndex := (StackIndex + 1) and 3;
      Paper := FRegisters[$28 + StackIndex];
      if FromGRAM then
        Ink := Ink or ((Card shr 9) and 8);
    end;

    var OriginX := (Tile mod 20) * 8 + FDelayX;
    var OriginY := (Tile div 20) * 16 + FDelayY;
    for var Row := 0 to 7 do
    begin
      var Bits: Byte := 0;
      if not Squares then
        if FromGRAM then
          Bits := GRAM[Pattern + Row]
        else
          Bits := GROM[Pattern + Row];
      for var Column := 0 to 7 do
      begin
        var X := OriginX + Column;
        var Y := OriginY + Row * 2;
        if not InDisplay(X, Y) then
          Continue;
        var Color: Integer;
        var Solid: Boolean;
        if Squares then
        begin
          var Quadrant := (Row div 4) * 2 + Column div 4;
          if Quadrant = 3 then
            Color := ((Card shr 9) and 3) or ((Card shr 11) and 4)
          else
            Color := (Card shr (Quadrant * 3)) and 7;
          Solid := Color <> 7;
          if not Solid then
            Color := Paper;
        end
        else
        begin
          Solid := Bits and ($80 shr Column) <> 0;
          Color := Paper;
          if Solid then
            Color := Ink;
        end;
        var Index := Y * IntvScreenWidth + X;
        FPixels[Index] := Colors[Color];
        FPixels[Index + IntvScreenWidth] := Colors[Color];
        FBackgroundColors[Index] := Color;
        FBackgroundColors[Index + IntvScreenWidth] := Color;
        FForeground[Index] := Ord(Solid);
        FForeground[Index + IntvScreenWidth] := Ord(Solid);
      end;
    end;
  end;
end;

procedure TIntvSTIC.DrawObjects(const GROM, GRAM: array of Byte);
begin
  for var Sprite := 7 downto 0 do
  begin
    var RegX := FRegisters[Sprite];
    var RegY := FRegisters[8 + Sprite];
    var Attr := FRegisters[16 + Sprite];
    var Visible := RegX and $200 <> 0;
    var Interacts := RegX and $100 <> 0;
    if (RegX and $FF = 0) or not (Visible or Interacts) then
      Continue;
    var OriginX := Integer(RegX and $FF) - 8 + FDelayX;
    var OriginY := (Integer(RegY and $7F) - 8) * 2 + FDelayY;
    var ScaleX := 1 shl ((RegX shr 10) and 1);
    var ScaleY := 1 shl ((RegY shr 8) and 3);
    var Rows := 8 shl ((RegY shr 7) and 1);
    var FromGRAM := Attr and $800 <> 0;
    var Pattern := Attr and $7F8;
    if not FSTIC1A and (FromGRAM or FForegroundBackground) then
      Pattern := Pattern and $1F8;
    if Rows = 16 then
      Pattern := Pattern and not 8;
    var Color := Colors[(Attr and 7) or ((Attr shr 9) and 8)];
    var Behind := Attr and $2000 <> 0;
    var SpriteBit := 1 shl Sprite;
    for var Row := 0 to Rows * ScaleY - 1 do
    begin
      var BitmapRow := Row div ScaleY;
      if RegY and $800 <> 0 then
        BitmapRow := Rows - 1 - BitmapRow;
      var Bits: Byte;
      if FromGRAM then
        Bits := GRAM[Pattern + BitmapRow]
      else
        Bits := GROM[Pattern + BitmapRow];
      if Bits = 0 then
        Continue;
      for var Column := 0 to 8 * ScaleX - 1 do
      begin
        var Bit := Column div ScaleX;
        if RegY and $400 = 0 then
          Bit := 7 - Bit;
        if Bits and (1 shl Bit) = 0 then
          Continue;
        var X := OriginX + Column;
        var Y := OriginY + Row;
        if not InDisplay(X, Y) then
        begin
          if Interacts and (X >= FLeft - 1) and (X <= FRight) and
            (Y >= FTop - 2) and (Y <= IntvScreenHeight) then
            FRegisters[$18 + Sprite] := FRegisters[$18 + Sprite] or $200;
          Continue;
        end;
        var Index := Y * IntvScreenWidth + X;
        if Interacts then
        begin
          if FForeground[Index] <> 0 then
            FRegisters[$18 + Sprite] := FRegisters[$18 + Sprite] or $100;
          var Overlap := FOccupancy[Index];
          FRegisters[$18 + Sprite] := FRegisters[$18 + Sprite] or Overlap;
          if Overlap <> 0 then
            for var Other := Sprite + 1 to 7 do
              if Overlap and (1 shl Other) <> 0 then
                FRegisters[$18 + Other] := FRegisters[$18 + Other] or SpriteBit;
          FOccupancy[Index] := Overlap or SpriteBit;
        end;
        if Visible then
          if Behind and (FForeground[Index] <> 0) then
            FPixels[Index] := Colors[FBackgroundColors[Index]]
          else
            FPixels[Index] := Color;
      end;
    end;
  end;
end;

procedure TIntvSTIC.Draw(const GROM, GRAM: array of Byte);
begin
  var Border := Colors[FRegisters[$2C]];
  for var Index := 0 to High(FPixels) do
    FPixels[Index] := Border;
  if not FActive then
    Exit;
  FDelayX := FRegisters[$30];
  FDelayY := FRegisters[$31] * 2;
  FLeft := (FRegisters[$32] and 1) * 8;
  FTop := (FRegisters[$32] and 2) * 8;
  FillChar(FForeground, SizeOf(FForeground), 0);
  FillChar(FOccupancy, SizeOf(FOccupancy), 0);
  var Backdrop := Colors[0];
  if not FForegroundBackground then
    Backdrop := Colors[FRegisters[$28]];
  for var Y := FTop to IntvScreenHeight - 1 do
    for var X := FLeft to FRight - 1 do
      FPixels[Y * IntvScreenWidth + X] := Backdrop;
  DrawBackground(GROM, GRAM);
  DrawObjects(GROM, GRAM);
end;

procedure TIntvSTIC.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FBacktab, SizeOf(FBacktab));
  State.Field(FDisplayStrobe, SizeOf(FDisplayStrobe));
  State.Field(FActive, SizeOf(FActive));
  State.Field(FForegroundBackground, SizeOf(FForegroundBackground));
  State.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
end;

end.

