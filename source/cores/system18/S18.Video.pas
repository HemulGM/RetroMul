unit S18.Video;

interface

uses
  System.SysUtils, System.UITypes, S16.Video, MD.VDP, Core.Snapshots;

type
  TS18Video = class(TS16Video)
  private
    FVDP: TVDP;
    FOverlay: array[0..S16_WIDTH * S16_HEIGHT - 1] of Word;
    FLineMix: array[0..S16_HEIGHT - 1] of Byte;
    FTileBanks: array[0..7] of Byte;
    FTileBankCount, FSpriteBankCount: Integer;
    FOverlayBehindBackground: Boolean;
  protected
    procedure DrawBackground; override;
    procedure MixLayer(Layer: Integer); override;
    procedure ResetBanks; override;
    function DecodeTile(Code: Integer): Integer; override;
    function PixelColor(Offset: Integer): TAlphaColor; override;
    procedure ShadePixel(Offset: Integer); override;
  public
    OverlayEnabled, Grayscale: Boolean;
    Mixing: Byte;
    constructor Create(const Tiles, Sprites: TBytes);
    procedure ResetVDP;
    procedure BeginScanline(Line: Integer);
    procedure EndScanline(Line: Integer);
    procedure SetTileBank(Index, Bank: Integer; Wrap: Boolean = False);
    procedure SetSpritePair(Index, Bank: Integer);
    function ReadVDP(Offset: Cardinal; Time: Int64): Word;
    procedure WriteVDP(Offset: Cardinal; Value: Word; Time: Int64; ReadBus: TVDPReadCallback; UserData: Pointer);
    procedure SerializeVDP(State: TStateArchive);
  end;

implementation

const
  VisiblePixel = $8000;
  OverlayIndex = $1000;
  ShadowIndex = $800;

procedure ColourChanged(UserData: Pointer; Index, Colour: Cardinal);
begin
  // CRAM is sampled directly when rendering each scanline.
end;

procedure DebugOutput(UserData: Pointer; const Text: array of Byte);
begin
end;

procedure CopyScanline(UserData: Pointer; Scanline: Cardinal; const Pixels: array of Byte; PixelOffset: Integer; LeftBoundary, RightBoundary, ScreenWidth, ScreenHeight: Cardinal);
begin
  var Video := TS18Video(UserData);
  for var X := Integer(LeftBoundary) to Integer(RightBoundary) - 1 do
  begin
    var Pixel := Pixels[PixelOffset + X] and $3F;
    if Pixel and $F <> 0 then
      Video.FOverlay[Integer(Scanline) * S16_WIDTH + X] := VisiblePixel or Video.FVDP.State.Cram[Pixel];
  end;
end;

constructor TS18Video.Create(const Tiles, Sprites: TBytes);
begin
  inherited Create(Tiles, Sprites, False);
  FTileBankCount := Length(Tiles) div (3 * 8 * $400);
  FSpriteBankCount := Length(Sprites) div $40000;
  ResetVDP;
end;

procedure TS18Video.ResetVDP;
begin
  FVDP := Default(TVDP);
  VDPInitialise(FVDP);
  OverlayEnabled := False;
  Grayscale := True;
  Mixing := 0;
  FillChar(FOverlay, SizeOf(FOverlay), 0);
  FillChar(FLineMix, SizeOf(FLineMix), $FF);
end;

procedure TS18Video.ResetBanks;
begin
  inherited;
  for var I := 0 to High(FTileBanks) do
    FTileBanks[I] := I;
  for var I := 0 to High(FSpriteBanks) do
    FSpriteBanks[I] := I;
end;

procedure TS18Video.SetTileBank(Index, Bank: Integer; Wrap: Boolean);
begin
  if Wrap and (FTileBankCount > 0) then
    Bank := Bank mod FTileBankCount;
  FTileBanks[Index] := Byte(Bank);
end;

procedure TS18Video.SetSpritePair(Index, Bank: Integer);
begin
  if Bank < FSpriteBankCount then
  begin
    FSpriteBanks[Index * 2] := Byte(Bank * 2);
    FSpriteBanks[Index * 2 + 1] := Byte(Bank * 2 + 1);
  end
  else
  begin
    FSpriteBanks[Index * 2] := $FF;
    FSpriteBanks[Index * 2 + 1] := $FF;
  end;
end;

function TS18Video.DecodeTile(Code: Integer): Integer;
begin
  Result := FTileBanks[Code shr 10] * $400 + (Code and $3FF);
end;

procedure TS18Video.BeginScanline(Line: Integer);
begin
  if Line = 0 then
    FOverlayBehindBackground := False;
  FVDP.State.CurrentlyInVblank := Ord(Line >= S16_HEIGHT);
  VDPBeginScanline(FVDP);
end;

procedure TS18Video.EndScanline(Line: Integer);
begin
  if Line >= S16_HEIGHT then
    Exit;
  FLineMix[Line] := $FF;
  if not OverlayEnabled or (FVDP.State.DisplayEnabled = 0) then
    Exit;
  FLineMix[Line] := Mixing and 7;
  if FLineMix[Line] < 2 then
    FOverlayBehindBackground := True;
  // Mode 5 uses palette index zero as the transparent input to the external mixer.
  FillChar(FOverlay[Line * S16_WIDTH], S16_WIDTH * SizeOf(Word), 0);
  var Background := FVDP.State.BackgroundColour;
  FVDP.State.BackgroundColour := 0;
  try
    VDPEndScanline(FVDP, Line, CopyScanline, Self);
  finally
    FVDP.State.BackgroundColour := Background;
  end;
end;

procedure TS18Video.DrawBackground;
begin
  DrawLayer(1);
  if FOverlayBehindBackground then
  begin
    MixLayer(0);
    DrawLayer(1, False);
  end;
end;

procedure TS18Video.MixLayer(Layer: Integer);
begin
  for var Y := 0 to S16_HEIGHT - 1 do
  begin
    var Setting := FLineMix[Y];
    if (Setting = $FF) or (Setting shr 1 <> Layer) then
      Continue;
    var Priority := (Setting and 1) shl Layer;
    for var X := 0 to S16_WIDTH - 1 do
    begin
      var Source := Y * S16_WIDTH + X;
      if FOverlay[Source] and VisiblePixel = 0 then
        Continue;
      var Dest := Source;
      if Flip then
        Dest := High(FIndex) - Source;
      FIndex[Dest] := OverlayIndex;
      FPriority[Dest] := FPriority[Dest] or Priority;
    end;
  end;
end;

procedure TS18Video.ShadePixel(Offset: Integer);
begin
  FIndex[Offset] := FIndex[Offset] or ShadowIndex;
end;

function TS18Video.PixelColor(Offset: Integer): TAlphaColor;
begin
  var Index := FIndex[Offset];
  if Index and OverlayIndex <> 0 then
  begin
    var RGB := FOverlay[Offset];
    var R := ((RGB shr 1) and 7) * 255 div 7;
    var G := ((RGB shr 5) and 7) * 255 div 7;
    var B := ((RGB shr 9) and 7) * 255 div 7;
    if Index and ShadowIndex <> 0 then
    begin
      R := R * 4 div 5;
      G := G * 4 div 5;
      B := B * 4 div 5;
    end;
    Exit($FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B));
  end;
  Result := inherited PixelColor(Offset);
  if Grayscale then
  begin
    var Gray := (Integer(Result shr 16 and $FF) * 30 + Integer(Result shr 8 and $FF) * 59 +
      Integer(Result and $FF) * 11) div 100;
    Result := $FF000000 or Cardinal(Gray * $010101);
  end;
end;

function TS18Video.ReadVDP(Offset: Cardinal; Time: Int64): Word;
begin
  FVDP.State.MasterTime := Time;
  case Offset and $E of
    0, 2:
      Result := Word(VDPReadData(FVDP));
    4, 6:
      Result := Word(VDPReadControl(FVDP));
    8, 10, 12, 14:
      Result := VDPReadHV(FVDP);
  else
    Result := $FFFF;
  end;
end;

procedure TS18Video.WriteVDP(Offset: Cardinal; Value: Word; Time: Int64; ReadBus: TVDPReadCallback; UserData: Pointer);
begin
  FVDP.State.MasterTime := Time;
  case Offset and $E of
    0, 2:
      VDPWriteData(FVDP, Value, ColourChanged, nil);
    4, 6:
      VDPWriteControl(FVDP, Value, ColourChanged, nil, nil, ReadBus, UserData, DebugOutput, nil, 0);
  end;
end;

procedure TS18Video.SerializeVDP(State: TStateArchive);
begin
  State.Field(FVDP.State, SizeOf(FVDP.State));
  State.Field(FTileBanks, SizeOf(FTileBanks));
  State.Field(FSpriteBanks, SizeOf(FSpriteBanks));
  State.Field(OverlayEnabled, SizeOf(OverlayEnabled));
  State.Field(Grayscale, SizeOf(Grayscale));
  State.Field(Mixing, SizeOf(Mixing));
  // Snapshots are taken between frames, before the next set of scanlines.
end;

end.

