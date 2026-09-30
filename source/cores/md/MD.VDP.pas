unit MD.VDP;

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

type
  TVDPConfiguration = record
    SpritesDisabled: Byte;
    WindowDisabled: Byte;
    PlanesDisabled: array[0..1] of Byte;
    WidescreenTiles: Byte;
  end;

  TVDPTileMetadata = record
    TileIndex: Cardinal;
    PaletteLine: Cardinal;
    XFlip: Byte;
    YFlip: Byte;
    Priority: Byte;
  end;

  TVDPCachedSprite = record
    Y: Cardinal;
    Link: Cardinal;
    Width: Cardinal;
    Height: Cardinal;
  end;

  TVDPSpriteRowCacheEntry = record
    TableIndex: Byte;
    YInSprite: Byte;
    Width: Byte;
    Height: Byte;
  end;

  TVDPSpriteRowCacheRow = record
    Total: Byte;
    Sprites: array[0..31] of TVDPSpriteRowCacheEntry;
  end;

  TVDPAccessState = record
    WritePending: Byte;
    AddressRegister: Cardinal;
    CodeRegister: Word;
    Increment: Byte;
    SelectedBuffer: Integer;
  end;

  TVDPDMAState = record
    Enabled: Byte;
    Mode: Integer;
    SourceAddressHigh: Byte;
    SourceAddressLow: Word;
    Length: Word;
  end;

  TVDPWindowState = record
    AlignedRight: Byte;
    AlignedBottom: Byte;
    HorizontalBoundary: Word;
    VerticalBoundary: Word;
  end;

  TVDPDebugState = record
    SelectedRegister: Byte;
    HideLayers: Byte;
    ForcedLayer: Byte;
  end;

  TVDPSpriteRowCache = record
    NeedsUpdating: Byte;
    Rows: array[0..479] of TVDPSpriteRowCacheRow;
  end;

  TVDPState = record
    Access: TVDPAccessState;
    Dma: TVDPDMAState;
    PlaneAAddress: Cardinal;
    PlaneBAddress: Cardinal;
    WindowAddress: Cardinal;
    SpriteTableAddress: Cardinal;
    HscrollAddress: Cardinal;
    Window: TVDPWindowState;
    PlaneWidthShift: Byte;
    PlaneHeightBitmask: Byte;
    ExtendedVramEnabled: Byte;
    DisplayEnabled: Byte;
    VIntEnabled: Byte;
    HIntEnabled: Byte;
    H40Enabled: Byte;
    V30Enabled: Byte;
    MegaDriveModeEnabled: Byte;
    ShadowHighlightEnabled: Byte;
    DoubleResolutionEnabled: Byte;
    SpriteTileIndexRebase: Byte;
    PlaneATileIndexRebase: Byte;
    PlaneBTileIndexRebase: Byte;
    BackgroundColour: Byte;
    HIntInterval: Byte;
    CurrentlyInVblank: Byte;
    AllowSpriteMasking: Byte;
    HscrollMask: Byte;
    VscrollMode: Integer;
    Debug: TVDPDebugState;
    Vram: array[0..65535] of Byte;
    Cram: array[0..63] of Word;
    Vsram: array[0..63] of Word;
    VsramCache: array[0..1] of Word;
    SpriteTableCache: array[0..127] of array[0..3] of Byte;
    SpriteRowCache: TVDPSpriteRowCache;
    PreviousDataWrites: array[0..3] of Word;
    KdebugBufferIndex: Word;
    KdebugBuffer: array[0..255] of Byte;
  end;

  TVDP = record
    Configuration: TVDPConfiguration;
    State: TVDPState;
  end;

  TVDPScanlineRenderedCallback = procedure(UserData: Pointer; Scanline: Cardinal; const Pixels: array of Byte; PixelOffset: Integer; LeftBoundary: Cardinal; RightBoundary: Cardinal; ScreenWidth: Cardinal; ScreenHeight: Cardinal);

  TVDPColourUpdatedCallback = procedure(UserData: Pointer; Index: Cardinal; Colour: Cardinal);

  TVDPDMATransferBeginCallback = procedure(UserData: Pointer; TotalReads: Cardinal; TargetCycle: Cardinal);

  TVDPReadCallback = function(UserData: Pointer; Address: Cardinal; TargetCycle: Cardinal): Cardinal;

  TVDPKDebugCallback = procedure(UserData: Pointer; const Text: array of Byte);

  TBlitLookupLower = record
    Pixels: array[0..255] of Byte;
  end;

  TBlitLookup = record
    Lower: array[0..127] of TBlitLookupLower;
  end;

  TBlitLookupTables = record
    Normal: TBlitLookup;
    ShadowHighlight: TBlitLookup;
    ForcedLayer: TBlitLookup;
  end;

const
  VDP_ACCESS_VRAM = 0;
  VDP_ACCESS_CRAM = VDP_ACCESS_VRAM + 1;
  VDP_ACCESS_VSRAM = VDP_ACCESS_CRAM + 1;
  VDP_ACCESS_VRAM_8_BIT = VDP_ACCESS_VSRAM + 1;
  VDP_ACCESS_INVALID = VDP_ACCESS_VRAM_8_BIT + 1;

const
  VDP_DMA_MODE_MEMORY_TO_VRAM = 0;
  VDP_DMA_MODE_FILL = VDP_DMA_MODE_MEMORY_TO_VRAM + 1;
  VDP_DMA_MODE_COPY = VDP_DMA_MODE_FILL + 1;

const
  VDP_HSCROLL_MODE_FULL = 0;
  VDP_HSCROLL_MODE_INVALID = VDP_HSCROLL_MODE_FULL + 1;
  VDP_HSCROLL_MODE_1_CELL = VDP_HSCROLL_MODE_INVALID + 1;
  VDP_HSCROLL_MODE_1_LINE = VDP_HSCROLL_MODE_1_CELL + 1;

const
  VDP_VSCROLL_MODE_FULL = 0;
  VDP_VSCROLL_MODE_2_CELL = VDP_VSCROLL_MODE_FULL + 1;

const
  SHADOW_HIGHLIGHT_NORMAL = ( 0 shl 6);
  SHADOW_HIGHLIGHT_SHADOW = ( 1 shl 6);
  SHADOW_HIGHLIGHT_HIGHLIGHT = ( 2 shl 6);

function IsDMAPending(const State: TVDPState): Byte;

procedure ClearDMAPending(var State: TVDPState);

function IsInReadMode(const State: TVDPState): Byte;

procedure SetHScrollMode(var State: TVDPState; Mode: Integer);

function GetSpriteTableAddress(const State: TVDPState): Cardinal;

function GetWindowPlaneTableAddress(const State: TVDPState): Cardinal;

function DecodeVRAMAddress(const State: TVDPState; Address: Cardinal): Cardinal;

function ReadVRAM(const State: TVDPState; Address: Cardinal): Cardinal;

procedure WriteVRAM(var Vdp: TVDP; Address: Cardinal; Value: Cardinal);

procedure IncrementAccessAddressRegister(var State: TVDPState);

procedure WriteAndIncrement(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer);

function ReadAndIncrement(var State: TVDPState): Cardinal;

procedure ConstantInitialise;

procedure VDPInitialise(var Vdp: TVDP);

function GetHScrollTableOffset(const State: TVDPState; Scanline: Cardinal): Cardinal;

function GetVScrollValue(var Vdp: TVDP; PlaneIndex: Cardinal; TilePair: Cardinal): Cardinal;

procedure RenderTilePair(var Vdp: TVDP; PixelYInPlane: Cardinal; VramAddress: Cardinal; BaseTileVramAddress: Cardinal; var Metapixels: array of Byte; var PixelIndex: Integer; const BlitLookupList: TBlitLookup);

procedure RenderScrollingPlane(var Vdp: TVDP; Start: Cardinal; EndColumn: Cardinal; Scanline: Cardinal; PlaneIndex: Cardinal; PlaneXOffset: Cardinal; PixelOffset: Integer; var Metapixels: array of Byte; const BlitLookupList: TBlitLookup);

procedure RenderWindowPlane(var Vdp: TVDP; Start: Cardinal; EndColumn: Cardinal; Scanline: Cardinal; var Metapixels: array of Byte; const BlitLookupList: TBlitLookup);

procedure UpdateSpriteCache(var Vdp: TVDP);

procedure RenderSprites(var Vdp: TVDP; var SpriteMetapixels: array of Byte; Scanline: Cardinal);

procedure RenderScrollPlane(var Vdp: TVDP; LeftBoundary: Cardinal; RightBoundary: Cardinal; Scanline: Cardinal; var PlaneMetapixels: array of Byte; const BlitLookupList: TBlitLookup; PlaneIndex: Cardinal);

procedure RenderForegroundPlane(var Vdp: TVDP; LeftBoundary: Cardinal; RightBoundary: Cardinal; Scanline: Cardinal; var PlaneMetapixels: array of Byte; const BlitLookupList: TBlitLookup; WindowPlane: Byte);

procedure RenderSpritePlane(var PlaneMetapixels: array of Byte; var SpriteMetapixels: array of Byte; const BlitLookupList: TBlitLookup; Mask: Cardinal; LeftBoundaryPixels: Cardinal; RightBoundaryPixels: Cardinal);

procedure RenderForegroundAndSpritePlanes(var Vdp: TVDP; Scanline: Cardinal; var PlaneMetapixels: array of Byte; var SpriteMetapixels: array of Byte; WindowPlane: Byte; ScanlineRenderedCallback: TVDPScanlineRenderedCallback; ScanlineRenderedCallbackUserData: Pointer);

procedure VDPBeginScanline(var Vdp: TVDP);

procedure VDPEndScanline(var Vdp: TVDP; Scanline: Cardinal; ScanlineRenderedCallback: TVDPScanlineRenderedCallback; ScanlineRenderedCallbackUserData: Pointer);

function VDPReadData(var Vdp: TVDP): Cardinal;

function VDPReadControl(var Vdp: TVDP): Cardinal;

procedure UpdateFakeFIFO(var State: TVDPState; Value: Cardinal);

procedure VDPWriteData(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer);

procedure VDPWriteControl(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer; DmaTransferBeginCallback: TVDPDMATransferBeginCallback; ReadCallback: TVDPReadCallback; ReadCallbackUserData: Pointer; KdebugCallback: TVDPKDebugCallback; KdebugCallbackUserData: Pointer; TargetCycle: Cardinal);

procedure VDPWriteDebugData(var Vdp: TVDP; Value: Cardinal);

procedure VDPWriteDebugControl(var Vdp: TVDP; Value: Cardinal);

function VDPReadVRAMWord(const State: TVDPState; Address: Cardinal): Cardinal;

function VDPDecomposeTileMetadata(PackedTileMetadata: Cardinal): TVDPTileMetadata;

function VDPGetCachedSprite(const State: TVDPState; SpriteIndex: Cardinal): TVDPCachedSprite;

implementation

const
  PLANE_PADDING = 16;
  MAX_PLANE_COLUMNS = 32;
  PIXELS_PER_TILE_PAIR = 16;
  MAX_PLANE_PIXELS = MAX_PLANE_COLUMNS * PIXELS_PER_TILE_PAIR;
  SPRITE_PADDING = 31;
  // 320 + 12 * 16 pixels, plus the fixed scanline padding.
  MAX_WIDESCREEN_TILES = 12;

var
  BlitLookup: TBlitLookupTables;

function GetWidescreenTiles(const Vdp: TVDP): Cardinal; inline;
begin
  Result := Min(Vdp.Configuration.WidescreenTiles, MAX_WIDESCREEN_TILES);
end;

function GetVisibleTilePairs(const Vdp: TVDP): Cardinal; inline;
begin
  if Vdp.State.H40Enabled <> 0 then
    Result := 20
  else
    Result := 16;
end;

function IsDMAPending(const State: TVDPState): Byte;
begin
  Exit(Ord((State.Access.CodeRegister and $20) <> 0));
end;

procedure ClearDMAPending(var State: TVDPState);
begin
  State.Access.CodeRegister := Word(State.Access.CodeRegister and (not $20));
end;

function IsInReadMode(const State: TVDPState): Byte;
begin
  Exit(Ord((State.Access.CodeRegister and 1) = 0));
end;

procedure SetHScrollMode(var State: TVDPState; Mode: Integer);
const
  MASKS: array[0..3] of Byte = ($00, $07, $F8, $FF);
begin
  State.HscrollMask := Byte(MASKS[Cardinal(Mode)]);
end;

function GetSpriteTableAddress(const State: TVDPState): Cardinal;
begin
  Exit(State.SpriteTableAddress and ((not Cardinal($1FF)) shl State.H40Enabled));
end;

function GetWindowPlaneTableAddress(const State: TVDPState): Cardinal;
begin
  Exit(State.WindowAddress and ((not Cardinal($7FF)) shl State.H40Enabled));
end;

function DecodeVRAMAddress(const State: TVDPState; Address: Cardinal): Cardinal;
begin
  if State.ExtendedVramEnabled <> 0 then
    Address := ((((Address and $1F802) shr 1) or ((Address and $400) shr 9)) or (Address and $3FC)) or ((Address and 1) shl 16)
  else
    Address := Address and $FFFF;
  Exit(Address xor 1);
end;

function ReadVRAM(const State: TVDPState; Address: Cardinal): Cardinal;
begin
  Exit(Cardinal(State.Vram[(DecodeVRAMAddress(State, Address) mod Cardinal(Length(State.Vram)))]));
end;

procedure WriteVRAM(var Vdp: TVDP; Address: Cardinal; Value: Cardinal);
begin
  var DecodedAddress: Cardinal := DecodeVRAMAddress(Vdp.State, Address);
  var SpriteTableIndex: Cardinal := Sub32(Address, GetSpriteTableAddress(Vdp.State));

  if (SpriteTableIndex < Mul32(Mul32(Mul32(Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)), 2), 2), 8)) and ((SpriteTableIndex and 4) = 0) then
  begin
    Vdp.State.SpriteTableCache[SpriteTableIndex div 8][SpriteTableIndex and 3] := Byte(Value);
    Vdp.State.SpriteRowCache.NeedsUpdating := 1;
  end;
  if DecodedAddress < Cardinal(Length(Vdp.State.Vram)) then
    Vdp.State.Vram[DecodedAddress] := Byte(Value);
end;

procedure IncrementAccessAddressRegister(var State: TVDPState);
begin
  State.Access.AddressRegister := Add32(State.Access.AddressRegister, State.Access.Increment);
  State.Access.AddressRegister := State.Access.AddressRegister and $1FFFF;
end;

procedure WriteAndIncrement(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer);
begin
  case Vdp.State.Access.SelectedBuffer of
    VDP_ACCESS_VRAM:
      begin
        WriteVRAM(Vdp, (Vdp.State.Access.AddressRegister), (Value and $FF));
        WriteVRAM(Vdp, (Vdp.State.Access.AddressRegister xor 1), (Value shr 8));
      end;
    VDP_ACCESS_CRAM:
      begin
        var Colour := Value and $EEE;
        var IndexWrapped := Cardinal(Cardinal(Vdp.State.Access.AddressRegister div 2) mod Cardinal(Length(Vdp.State.Cram)));
        Vdp.State.Cram[IndexWrapped] := Word(Colour);
        ColourUpdatedCallback(ColourUpdatedCallbackUserData, (Add32(SHADOW_HIGHLIGHT_NORMAL, IndexWrapped)), (Colour or ((Colour and $888) shr 3)));
        ColourUpdatedCallback(ColourUpdatedCallbackUserData, (Add32(SHADOW_HIGHLIGHT_SHADOW, IndexWrapped)), (Colour shr 1));
        ColourUpdatedCallback(ColourUpdatedCallbackUserData, (Add32(SHADOW_HIGHLIGHT_HIGHLIGHT, IndexWrapped)), (Add32($888, Colour shr 1)));
      end;
    VDP_ACCESS_VSRAM:
      begin
        var Limit: Cardinal := 40;
        var IndexWrappedScope32 := Cardinal(Cardinal(Vdp.State.Access.AddressRegister div 2) mod Cardinal(Length(Vdp.State.Vsram)));
        if IndexWrappedScope32 < Limit then
        begin
          var Vscroll := Word(Value and $7FF);
          if IndexWrappedScope32 < 2 then
          begin
            var i: Cardinal := Add32(Limit, IndexWrappedScope32);
            while (i < Cardinal(Length(Vdp.State.Vsram))) do
            begin
              Vdp.State.Vsram[i] := Vscroll;
              i := Add32(i, 2);
            end;
          end;
          Vdp.State.Vsram[IndexWrappedScope32] := Vscroll;
        end;
      end;
    VDP_ACCESS_INVALID, VDP_ACCESS_VRAM_8_BIT:
      ;
  else
    Assert(False);
  end;
  IncrementAccessAddressRegister(Vdp.State);
end;

function ReadAndIncrement(var State: TVDPState): Cardinal;
begin
  var WordAddress: Cardinal := Cardinal(State.Access.AddressRegister div 2);
  var Value: Cardinal := State.PreviousDataWrites[0];
  case State.Access.SelectedBuffer of
    VDP_ACCESS_VRAM:
      begin
        Value := ReadVRAM(State, Mul32(WordAddress, 2)) or (ReadVRAM(State, (Mul32(WordAddress, 2) xor 1)) shl 8);
      end;
    VDP_ACCESS_CRAM:
      begin
        Value := Value and Cardinal(not $EEE);
        Value := Value or Cardinal(State.Cram[(WordAddress mod Cardinal(Length(State.Cram)))]);
      end;
    VDP_ACCESS_VSRAM:
      begin
        Value := Value and Cardinal(not $7FF);
        Value := Value or Cardinal(State.Vsram[(WordAddress mod Cardinal(Length(State.Vsram)))]);
      end;
    VDP_ACCESS_VRAM_8_BIT:
      begin
        Value := Value and Cardinal(not $FF);
        Value := Value or ReadVRAM(State, State.Access.AddressRegister);
      end;
    VDP_ACCESS_INVALID:
      ;
  else
    Assert(False);
  end;
  IncrementAccessAddressRegister(State);
  Exit(Value);
end;

procedure ConstantInitialise;
const
  PALETTE_LINE_INDEX_MASK = $0F;
  COLOUR_INDEX_MASK = $3F;
  PRIORITY_MASK = $40;
  NOT_SHADOWED_MASK = $80;
begin
  for var NewPixel := 0 to High(BlitLookup.Normal.Lower) do
  begin
    var NewPaletteLineIndex := NewPixel and PALETTE_LINE_INDEX_MASK;
    var NewColourIndex := NewPixel and COLOUR_INDEX_MASK;
    var NewPriority := (NewPixel and PRIORITY_MASK) <> 0;
    var NewNotShadowed := NewPriority;

    for var OldPixel := 0 to High(BlitLookup.Normal.Lower[0].Pixels) do
    begin
      var OldPaletteLineIndex := OldPixel and PALETTE_LINE_INDEX_MASK;
      var OldColourIndex := OldPixel and COLOUR_INDEX_MASK;
      var OldPriority := (OldPixel and PRIORITY_MASK) <> 0;
      var OldNotShadowed := (OldPixel and NOT_SHADOWED_MASK) <> 0;
      var DrawNewPixel := (NewPaletteLineIndex <> 0) and ((OldPaletteLineIndex = 0) or not OldPriority or NewPriority);

      var Output: Cardinal;
      if DrawNewPixel then
        Output := NewPixel
      else
        Output := OldPixel;

      if OldNotShadowed or NewNotShadowed then
        Output := Output or NOT_SHADOWED_MASK;

      BlitLookup.Normal.Lower[NewPixel].Pixels[OldPixel] := Byte(Output);

      if DrawNewPixel then
        case NewColourIndex of
          $0E, $1E, $2E:
            Output := NewColourIndex or SHADOW_HIGHLIGHT_NORMAL;
          $3E:
            if OldNotShadowed then
              Output := OldColourIndex or SHADOW_HIGHLIGHT_HIGHLIGHT
            else
              Output := OldColourIndex or SHADOW_HIGHLIGHT_NORMAL;
          $3F:
            Output := OldColourIndex or SHADOW_HIGHLIGHT_SHADOW;
        else
          if NewNotShadowed or OldNotShadowed then
            Output := NewColourIndex or SHADOW_HIGHLIGHT_NORMAL
          else
            Output := NewColourIndex or SHADOW_HIGHLIGHT_SHADOW;
        end
      else
      begin
        if OldNotShadowed then
          Output := OldColourIndex or SHADOW_HIGHLIGHT_NORMAL
        else
          Output := OldColourIndex or SHADOW_HIGHLIGHT_SHADOW;
      end;

      BlitLookup.ShadowHighlight.Lower[NewPixel].Pixels[OldPixel] := Byte(Output);
      BlitLookup.ForcedLayer.Lower[NewPixel].Pixels[OldPixel] := Byte(OldPixel and (NewColourIndex or not COLOUR_INDEX_MASK));
    end;
  end;
end;

procedure VDPInitialise(var Vdp: TVDP);
begin
  Vdp.State.Access.WritePending := 0;
  Vdp.State.Access.AddressRegister := 0;
  Vdp.State.Access.CodeRegister := 0;
  Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VRAM;
  Vdp.State.Access.Increment := 0;
  Vdp.State.Dma.Enabled := 0;
  Vdp.State.Dma.Mode := VDP_DMA_MODE_MEMORY_TO_VRAM;
  Vdp.State.Dma.SourceAddressHigh := 0;
  Vdp.State.Dma.SourceAddressLow := 0;
  Vdp.State.Dma.Length := 0;
  Vdp.State.PlaneAAddress := 0;
  Vdp.State.PlaneBAddress := 0;
  Vdp.State.WindowAddress := 0;
  Vdp.State.SpriteTableAddress := 0;
  Vdp.State.HscrollAddress := 0;
  Vdp.State.Window.AlignedRight := 0;
  Vdp.State.Window.AlignedBottom := 0;
  Vdp.State.Window.HorizontalBoundary := 0;
  Vdp.State.Window.VerticalBoundary := 0;
  Vdp.State.PlaneWidthShift := 5;
  Vdp.State.PlaneHeightBitmask := $1F;
  Vdp.State.ExtendedVramEnabled := 0;
  Vdp.State.DisplayEnabled := 0;
  Vdp.State.VIntEnabled := 0;
  Vdp.State.HIntEnabled := 0;
  Vdp.State.H40Enabled := 0;
  Vdp.State.V30Enabled := 0;
  Vdp.State.MegaDriveModeEnabled := 0;
  Vdp.State.ShadowHighlightEnabled := 0;
  Vdp.State.DoubleResolutionEnabled := 0;
  Vdp.State.SpriteTileIndexRebase := 0;
  Vdp.State.PlaneATileIndexRebase := 0;
  Vdp.State.PlaneBTileIndexRebase := 0;
  Vdp.State.BackgroundColour := 0;
  Vdp.State.HIntInterval := 0;
  Vdp.State.CurrentlyInVblank := 1;
  Vdp.State.AllowSpriteMasking := 0;
  SetHScrollMode(Vdp.State, VDP_HSCROLL_MODE_FULL);
  Vdp.State.VscrollMode := VDP_VSCROLL_MODE_FULL;
  Vdp.State.Debug.SelectedRegister := 0;
  Vdp.State.Debug.HideLayers := 0;
  Vdp.State.Debug.ForcedLayer := 0;
  FillChar(Vdp.State.Vram, SizeOf(Vdp.State.Vram), 0);
  FillChar(Vdp.State.Cram, SizeOf(Vdp.State.Cram), 0);
  FillChar(Vdp.State.Vsram, SizeOf(Vdp.State.Vsram), 0);
  FillChar(Vdp.State.SpriteTableCache, SizeOf(Vdp.State.SpriteTableCache), 0);
  Vdp.State.SpriteRowCache.NeedsUpdating := 1;
  FillChar(Vdp.State.SpriteRowCache.Rows, SizeOf(Vdp.State.SpriteRowCache.Rows), 0);
  FillChar(Vdp.State.PreviousDataWrites, SizeOf(Vdp.State.PreviousDataWrites), 0);
  Vdp.State.KdebugBufferIndex := 0;
  Vdp.State.KdebugBuffer[(Length(Vdp.State.KdebugBuffer) - 1)] := 0;
end;

function GetHScrollTableOffset(const State: TVDPState; Scanline: Cardinal): Cardinal;
begin
  Exit(Mul32((Scanline shr State.DoubleResolutionEnabled) and Cardinal(State.HscrollMask), 4));
end;

function GetVScrollValue(var Vdp: TVDP; PlaneIndex: Cardinal; TilePair: Cardinal): Cardinal;
begin
  case Vdp.State.VscrollMode of
    VDP_VSCROLL_MODE_FULL:
      Exit(Cardinal(Vdp.State.VsramCache[PlaneIndex]));
    VDP_VSCROLL_MODE_2_CELL:
      Exit(Cardinal(Vdp.State.Vsram[(Add32(PlaneIndex, Mul32(Sub32(TilePair, (GetWidescreenTiles(Vdp) + (2 - 1)) div 2), 2) mod Cardinal(Length(Vdp.State.Vsram))))]));
  else
    Assert(0 <> 0);
    Exit(Cardinal(Vdp.State.VsramCache[PlaneIndex]));
  end;
end;

procedure RenderTilePair(var Vdp: TVDP; PixelYInPlane: Cardinal; VramAddress: Cardinal; BaseTileVramAddress: Cardinal; var Metapixels: array of Byte; var PixelIndex: Integer; const BlitLookupList: TBlitLookup);
begin
  var TileHeightShift := 3 + Vdp.State.DoubleResolutionEnabled;
  var TileHeightMask := Cardinal((1 shl TileHeightShift) - 1);
  var PixelYInTileUnflipped := PixelYInPlane and TileHeightMask;

  for var i := 0 to 1 do
  begin
    var WordVramAddress := VramAddress + Cardinal(i * 2);
    var WordValue := ReadVRAM(Vdp.State, WordVramAddress) or (ReadVRAM(Vdp.State, WordVramAddress xor 1) shl 8);
    var XFlip := (WordValue and $0800) <> 0;
    var YFlip := (WordValue and $1000) <> 0;
    var PixelYInTile := PixelYInTileUnflipped;

    if YFlip then
      PixelYInTile := PixelYInTile xor TileHeightMask;

    var TileRowVramAddress := BaseTileVramAddress + (((WordValue and $07FF) shl TileHeightShift) + PixelYInTile) shl 2;
    var LookupIndex := (WordValue shr 9) and $70;

    for var JIndex := 0 to 3 do
    begin
      var ByteAddress := TileRowVramAddress + Cardinal(JIndex);
      if XFlip then
        ByteAddress := ByteAddress xor 2
      else
        ByteAddress := ByteAddress xor 1;

      var ByteValue := ReadVRAM(Vdp.State, ByteAddress);
      if XFlip then
      begin
        Metapixels[PixelIndex] := BlitLookupList.Lower[LookupIndex + (ByteValue and $0F)].Pixels[Metapixels[PixelIndex]];
        Inc(PixelIndex);

        Metapixels[PixelIndex] := BlitLookupList.Lower[LookupIndex + ((ByteValue shr 4) and $0F)].Pixels[Metapixels[PixelIndex]];
        Inc(PixelIndex);
      end
      else
      begin
        Metapixels[PixelIndex] := BlitLookupList.Lower[LookupIndex + ((ByteValue shr 4) and $0F)].Pixels[Metapixels[PixelIndex]];
        Inc(PixelIndex);

        Metapixels[PixelIndex] := BlitLookupList.Lower[LookupIndex + (ByteValue and $0F)].Pixels[Metapixels[PixelIndex]];
        Inc(PixelIndex);
      end;
    end;
  end;
end;

procedure RenderScrollingPlane(var Vdp: TVDP; Start: Cardinal; EndColumn: Cardinal; Scanline: Cardinal; PlaneIndex: Cardinal; PlaneXOffset: Cardinal; PixelOffset: Integer; var Metapixels: array of Byte; const BlitLookupList: TBlitLookup);
begin
  var PlaneATileIndex: Byte;
  var Vscroll: Cardinal;
  var PixelYInPlane: Cardinal;
  var ClampedColumn: Cardinal;
  var TileX: Cardinal;
  var TileY: Cardinal;
  var VramAddress: Cardinal;

  if PlaneIndex = 0 then
    PlaneATileIndex := Vdp.State.PlaneATileIndexRebase
  else
    PlaneATileIndex := Vdp.State.PlaneBTileIndexRebase;

  var BaseTileVramAddress: Cardinal;
  if PlaneATileIndex <> 0 then
    BaseTileVramAddress := $10000
  else
    BaseTileVramAddress := 0;
  var PlanePitchShift: Cardinal := Vdp.State.PlaneWidthShift;
  var PlaneWidthBitmask: Cardinal := Cardinal((1 shl PlanePitchShift) - 1);
  var PlaneHeightBitmask: Cardinal := Cardinal(Vdp.State.PlaneHeightBitmask);
  var PlaneAddress: Cardinal;
  if PlaneIndex = 0 then
    PlaneAddress := Vdp.State.PlaneAAddress
  else
    PlaneAddress := Vdp.State.PlaneBAddress;
  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;
  var PixelIndex := PixelOffset + Integer(Start) * 16;
  var Column: Cardinal := Start;
  while (Column <= EndColumn) and (Column <= MAX_PLANE_COLUMNS) do
  begin
    Vscroll := GetVScrollValue(Vdp, PlaneIndex, (Sub32(Column, 1)));
    PixelYInPlane := Add32(Vscroll, Scanline);
    if Start > Sub32(Column, 1) then
      ClampedColumn := Start
    else
      ClampedColumn := Sub32(Column, 1);
    TileX := Mul32(Add32(PlaneXOffset, ClampedColumn), 2) and PlaneWidthBitmask;
    TileY := (PixelYInPlane shr TileHeightShift) and PlaneHeightBitmask;
    VramAddress := Add32(PlaneAddress, Mul32(Add32(TileY shl PlanePitchShift, TileX), 2));
    RenderTilePair(Vdp, PixelYInPlane, VramAddress, BaseTileVramAddress, Metapixels, PixelIndex, BlitLookupList);
    Inc(Column);
  end;
end;

procedure RenderWindowPlane(var Vdp: TVDP; Start: Cardinal; EndColumn: Cardinal; Scanline: Cardinal; var Metapixels: array of Byte; const BlitLookupList: TBlitLookup);
begin
  var BaseTileVramAddress: Cardinal;
  if Vdp.State.PlaneATileIndexRebase <> 0 then
    BaseTileVramAddress := $10000
  else
    BaseTileVramAddress := 0;
  var TileY: Cardinal := Scanline shr (3 + Vdp.State.DoubleResolutionEnabled);
  var PlanePitchShift: Cardinal := 5 + Vdp.State.H40Enabled;
  var PlaneWidthBitmask: Cardinal := Cardinal((1 shl PlanePitchShift) - 1);
  var VramAddressBase: Cardinal := Add32(GetWindowPlaneTableAddress(Vdp.State), Mul32(TileY shl PlanePitchShift, 2));
  var TileXBase: Cardinal := Cardinal(0 - (((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2)) and PlaneWidthBitmask;
  var PixelIndex := PLANE_PADDING + Integer(Start) * 16;
  var Column: Cardinal := Start;
  while (Column < EndColumn) and (Column < MAX_PLANE_COLUMNS) do
  begin
    RenderTilePair(Vdp, Scanline, (Add32(VramAddressBase, Mul32(Add32(TileXBase, Mul32(Column, 2)) and PlaneWidthBitmask, 2))), BaseTileVramAddress, Metapixels, PixelIndex, BlitLookupList);
    Inc(Column);
  end;
end;

procedure UpdateSpriteCache(var Vdp: TVDP);
begin
  var CachedSprite: TVDPCachedSprite;
  var BlankLines: Cardinal;
  var Temp104: Cardinal;
  var Temp105: Integer;
  var Temp106: Integer;
  var Temp110: Byte;
  var Temp111: Integer;

  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;

  var MaxSprites: Cardinal := Mul32(Mul32(Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)), 2), 2);
  var SpritesRemaining: Cardinal := MaxSprites;
  if Vdp.State.SpriteRowCache.NeedsUpdating = 0 then
    Exit;
  Vdp.State.SpriteRowCache.NeedsUpdating := 0;
  for var ItemIndex := 0 to High(Vdp.State.SpriteRowCache.Rows) do
  begin
    Vdp.State.SpriteRowCache.Rows[ItemIndex].Total := 0;
  end;
  var SpriteIndex: Cardinal := 0;
  while True do
  begin
    CachedSprite := VDPGetCachedSprite(Vdp.State, SpriteIndex);
    BlankLines := Cardinal(128 shl Vdp.State.DoubleResolutionEnabled);
    var i: Cardinal;
    if BlankLines > CachedSprite.Y then
      i := BlankLines
    else
      i := CachedSprite.Y;
    while True do
    begin
      if Vdp.State.V30Enabled <> 0 then
        Temp105 := 30
      else
        Temp105 := 28;
      if Add32(BlankLines, Temp105 shl TileHeightShift) < Add32(CachedSprite.Y, CachedSprite.Height shl TileHeightShift) then
      begin
        if Vdp.State.V30Enabled <> 0 then
          Temp106 := 30
        else
          Temp106 := 28;
        Temp104 := Add32(BlankLines, Temp106 shl TileHeightShift);
      end
      else
        Temp104 := Add32(CachedSprite.Y, CachedSprite.Height shl TileHeightShift);
      if not (i < Temp104) then
        Break;

      if Cardinal(Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Total) <> Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)) then
      begin
        Temp110 := Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Total;
        Inc(Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Total);

        Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Sprites[Temp110].TableIndex := Byte(SpriteIndex);
        Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Sprites[Temp110].Width := CachedSprite.Width;
        Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Sprites[Temp110].Height := CachedSprite.Height;
        Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Sprites[Temp110].YInSprite := Byte(Sub32(i, CachedSprite.Y));
      end;
      Inc(i);
    end;
    if CachedSprite.Link >= MaxSprites then
      Break;
    SpriteIndex := CachedSprite.Link;
    Temp111 := Ord(SpriteIndex <> 0);
    if Temp111 <> 0 then
    begin
      Dec(SpritesRemaining);
      Temp111 := Ord(SpritesRemaining <> 0);
    end;
    if Temp111 = 0 then
      Break;
  end;
end;

procedure RenderSprites(var Vdp: TVDP; var SpriteMetapixels: array of Byte; Scanline: Cardinal);
begin
  var SpriteIndex: Cardinal;
  var Width: Cardinal;
  var RawX: Cardinal;
  var X: Cardinal;
  var Temp116: Integer;
  var Temp117: Integer;
  var Height: Cardinal;
  var WordValue: Cardinal;
  var SpriteTileIndex: Cardinal;
  var XFlip: Byte;
  var YFlip: Byte;
  var MetapixelHighBits: Cardinal;
  var ByteIndexXor: Cardinal;
  var Temp119: Integer;
  var YInSpriteNonFlipped: Cardinal;
  var YInSprite: Cardinal;
  var PixelYInTile: Cardinal;
  var NybbleShift: array[0..1] of Cardinal;
  var XInSprite: Cardinal;
  var TileIndex: Cardinal;
  var TileRowVramAddress: Cardinal;
  var ByteValue: Cardinal;
  var PaletteLineIndex: Cardinal;

  var BaseTileVramAddress: Cardinal;
  if Vdp.State.SpriteTileIndexRebase <> 0 then
    BaseTileVramAddress := $10000
  else
    BaseTileVramAddress := 0;
  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;
  var TileHeightMask: Cardinal := Cardinal((1 shl (3 + Vdp.State.DoubleResolutionEnabled)) - 1);

  var SpriteLimit: Cardinal := Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2));
  var PixelLimit: Cardinal := Mul32(SpriteLimit, 16);
  var Masked: Byte := 0;
  for var ItemIndex := 0 to Vdp.State.SpriteRowCache.Rows[Scanline].Total - 1 do
  begin
    SpriteIndex := Add32(GetSpriteTableAddress(Vdp.State), Vdp.State.SpriteRowCache.Rows[Scanline].Sprites[ItemIndex].TableIndex * 8);
    Width := Cardinal(Vdp.State.SpriteRowCache.Rows[Scanline].Sprites[ItemIndex].Width);
    RawX := (ReadVRAM(Vdp.State, Add32(SpriteIndex, 6)) or (ReadVRAM(Vdp.State, (Add32(SpriteIndex, 6) xor 1)) shl 8)) and $1FF;
    X := Add32(RawX, (((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2) * 8);
    if RawX = 0 then
      Masked := Vdp.State.AllowSpriteMasking
    else
      Vdp.State.AllowSpriteMasking := 1;
    Temp117 := Ord((Masked <> 0) or (Add32(X, Mul32(Width, 8)) <= $80));
    Temp116 := Ord(Temp117 <> 0);
    if Temp116 = 0 then
    begin
      Temp116 := Ord(X >= Add32($80, Mul32(Mul32(Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)), 2), 8)));
    end;
    if Temp116 <> 0 then
    begin
      if PixelLimit <= Mul32(Width, 8) then
        Exit;
      PixelLimit := Sub32(PixelLimit, Mul32(Width, 8));
    end
    else
    begin
      Height := Cardinal(Vdp.State.SpriteRowCache.Rows[Scanline].Sprites[ItemIndex].Height);
      WordValue := ReadVRAM(Vdp.State, Add32(SpriteIndex, 4)) or (ReadVRAM(Vdp.State, (Add32(SpriteIndex, 4) xor 1)) shl 8);
      SpriteTileIndex := WordValue and $7FF;
      XFlip := Ord((WordValue and $800) <> 0);
      YFlip := Ord((WordValue and $1000) <> 0);
      MetapixelHighBits := (WordValue shr 9) and $70;
      if XFlip <> 0 then
        Temp119 := 3
      else
        Temp119 := 0;
      ByteIndexXor := Cardinal(1 xor Temp119);
      YInSpriteNonFlipped := Cardinal(Vdp.State.SpriteRowCache.Rows[Scanline].Sprites[ItemIndex].YInSprite);
      if YFlip <> 0 then
        YInSprite := Sub32(Sub32(Height shl TileHeightShift, YInSpriteNonFlipped), 1)
      else
        YInSprite := YInSpriteNonFlipped;
      PixelYInTile := YInSprite and TileHeightMask;
      var PixelIndex := SPRITE_PADDING + Integer(X) - $80;
      if XFlip <> 0 then
      begin
        NybbleShift[0] := 0;
        NybbleShift[1] := 4;
      end
      else
      begin
        NybbleShift[0] := 4;
        NybbleShift[1] := 0;
      end;
      for var JIndex := 0 to Integer(Width) - 1 do
      begin
        if XFlip <> 0 then
          XInSprite := Sub32(Sub32(Width, JIndex), 1)
        else
          XInSprite := JIndex;
        TileIndex := Add32(Add32(SpriteTileIndex, YInSprite shr TileHeightShift), Mul32(XInSprite, Height));
        TileRowVramAddress := Add32(BaseTileVramAddress, (Add32(TileIndex shl (3 + Vdp.State.DoubleResolutionEnabled), PixelYInTile)) shl 2);
        for var KIndex := 0 to Integer(8 div 2) - 1 do
        begin
          ByteValue := ReadVRAM(Vdp.State, (Add32(TileRowVramAddress, KIndex) xor ByteIndexXor));
          for var LIndex := 0 to High(NybbleShift) do
          begin
            if Integer(SpriteMetapixels[PixelIndex] and $F) = 0 then
            begin
              PaletteLineIndex := (ByteValue shr NybbleShift[LIndex]) and $F;
              SpriteMetapixels[PixelIndex] := Byte(MetapixelHighBits or PaletteLineIndex);
            end;
            Inc(PixelIndex);
            Dec(PixelLimit);
            if PixelLimit = 0 then
              Exit;
          end;
        end;
      end;
    end;
    Dec(SpriteLimit);
    if SpriteLimit = 0 then
      Break;
  end;
  Vdp.State.AllowSpriteMasking := 0;
end;

procedure RenderScrollPlane(var Vdp: TVDP; LeftBoundary: Cardinal; RightBoundary: Cardinal; Scanline: Cardinal; var PlaneMetapixels: array of Byte; const BlitLookupList: TBlitLookup; PlaneIndex: Cardinal);
begin
  var HscrollVramAddress: Cardinal;
  var Hscroll: Cardinal;
  var ScrollOffset: Cardinal;
  var PlaneXOffset: Cardinal;

  if Vdp.Configuration.PlanesDisabled[PlaneIndex] = 0 then
  begin
    HscrollVramAddress := Add32(Add32(Vdp.State.HscrollAddress, Mul32(PlaneIndex, 2)), GetHScrollTableOffset(Vdp.State, Scanline));
    Hscroll := Add32(ReadVRAM(Vdp.State, (HscrollVramAddress)) or (ReadVRAM(Vdp.State, (HscrollVramAddress xor 1)) shl 8), (((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2) * 8);
    ScrollOffset := Sub32(8 * 2, Hscroll mod Cardinal(8 * 2));
    PlaneXOffset := Sub32(0, Hscroll div (8 * 2));
    RenderScrollingPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneIndex, PlaneXOffset, PLANE_PADDING - Integer(ScrollOffset), PlaneMetapixels, BlitLookupList);
  end;
end;

procedure RenderForegroundPlane(var Vdp: TVDP; LeftBoundary: Cardinal; RightBoundary: Cardinal; Scanline: Cardinal; var PlaneMetapixels: array of Byte; const BlitLookupList: TBlitLookup; WindowPlane: Byte);
begin
  if (WindowPlane <> 0) and ((Vdp.Configuration.WindowDisabled = 0)) then
    RenderWindowPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookupList)
  else
    RenderScrollPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookupList, 0);
end;

procedure RenderSpritePlane(var PlaneMetapixels: array of Byte; var SpriteMetapixels: array of Byte; const BlitLookupList: TBlitLookup; Mask: Cardinal; LeftBoundaryPixels: Cardinal; RightBoundaryPixels: Cardinal);
begin
  for var PixelIndex := Integer(LeftBoundaryPixels) to Integer(RightBoundaryPixels) - 1 do
  begin
    var PlaneIndex := PLANE_PADDING + PixelIndex;
    var SpritePixel := SpriteMetapixels[SPRITE_PADDING + PixelIndex];
    var PlanePixel := PlaneMetapixels[PlaneIndex];
    PlaneMetapixels[PlaneIndex] := BlitLookupList.Lower[SpritePixel].Pixels[PlanePixel] and Mask;
  end;
end;

procedure RenderForegroundAndSpritePlanes(var Vdp: TVDP; Scanline: Cardinal; var PlaneMetapixels: array of Byte; var SpriteMetapixels: array of Byte; WindowPlane: Byte; ScanlineRenderedCallback: TVDPScanlineRenderedCallback; ScanlineRenderedCallbackUserData: Pointer);
begin
  var Temp133: Integer;
  var Temp135: Cardinal;
  var Temp136: Cardinal;
  var Temp138: Cardinal;
  var VisibleTileRows: Integer;

  var FullWindowPlaneLine: Byte := Ord(Integer(Ord(Scanline < Cardinal(Vdp.State.Window.VerticalBoundary))) <> Vdp.State.Window.AlignedBottom);
  var WindowHorizontalBoundary: Cardinal;
  if Vdp.State.Window.HorizontalBoundary = 0 then
    WindowHorizontalBoundary := 0
  else
    WindowHorizontalBoundary := ((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) + Vdp.State.Window.HorizontalBoundary;
  if FullWindowPlaneLine <> 0 then
    Temp133 := 0
  else
  begin
    if Vdp.State.Window.AlignedRight = WindowPlane then
      Temp133 := WindowHorizontalBoundary
    else
      Temp133 := 0;
  end;
  var LeftBoundary: Cardinal := Temp133;
  if FullWindowPlaneLine <> 0 then
  begin
    if WindowPlane <> 0 then
    begin
      Temp136 := Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2));
    end
    else
      Temp136 := 0;
    Temp135 := Temp136;
  end
  else
  begin
    if Vdp.State.Window.AlignedRight = WindowPlane then
    begin
      Temp138 := Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2));
    end
    else
      Temp138 := WindowHorizontalBoundary;
    Temp135 := Temp138;
  end;
  var RightBoundary: Cardinal := Temp135;
  var LeftBoundaryPixels: Cardinal := Mul32(LeftBoundary, 8 * 2);
  var RightBoundaryPixels: Cardinal := Mul32(RightBoundary, 8 * 2);
  if LeftBoundary = RightBoundary then
    Exit;
  if Vdp.State.DisplayEnabled <> 0 then
  begin
    if Vdp.State.Debug.HideLayers = 0 then
    begin
      RenderForegroundPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookup.Normal, WindowPlane);
      if Vdp.State.ShadowHighlightEnabled <> 0 then
        RenderSpritePlane(PlaneMetapixels, SpriteMetapixels, BlitLookup.ShadowHighlight, $FF, LeftBoundaryPixels, RightBoundaryPixels)
      else
        RenderSpritePlane(PlaneMetapixels, SpriteMetapixels, BlitLookup.Normal, $3F, LeftBoundaryPixels, RightBoundaryPixels);
    end;
    case Vdp.State.Debug.ForcedLayer of
      1:
        RenderSpritePlane(PlaneMetapixels, SpriteMetapixels, BlitLookup.ForcedLayer, $FF, LeftBoundaryPixels, RightBoundaryPixels);
      2:
        RenderScrollPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookup.ForcedLayer, 0);
      3:
        RenderScrollPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookup.ForcedLayer, 1);
    end;
  end;
  var InputExtraTiles: Cardinal := Cardinal((((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2) * 2);
  var InputExtraTilesInPixels: Cardinal := Mul32(InputExtraTiles, 8);
  var OutputExtraTiles: Cardinal := GetWidescreenTiles(Vdp) * 2;
  var OutputExtraTilesInPixels: Cardinal := Mul32(OutputExtraTiles, 8);
  var XOffset: Cardinal := Cardinal(Sub32(InputExtraTilesInPixels, OutputExtraTilesInPixels) div 2);

  var OutputWidth: Cardinal := Add32((GetVisibleTilePairs(Vdp) * 2) * 8, OutputExtraTilesInPixels);
  if Vdp.State.V30Enabled <> 0 then
    VisibleTileRows := 30
  else
    VisibleTileRows := 28;
  var OutputHeight: Cardinal := Cardinal(VisibleTileRows shl (3 + Vdp.State.DoubleResolutionEnabled));
  var ClampedLeftBoundaryPixels := Sub32(
    Max(XOffset, Min(Add32(XOffset, OutputWidth), LeftBoundaryPixels)), XOffset);
  var ClampedRightBoundaryPixels := Sub32(
    Max(XOffset, Min(Add32(XOffset, OutputWidth), RightBoundaryPixels)), XOffset);
  ScanlineRenderedCallback(ScanlineRenderedCallbackUserData, Scanline, PlaneMetapixels, PLANE_PADDING + Integer(XOffset), ClampedLeftBoundaryPixels, ClampedRightBoundaryPixels, OutputWidth, OutputHeight);
end;

procedure VDPBeginScanline(var Vdp: TVDP);
begin
  for var i := 0 to High(Vdp.State.VsramCache) do
    Vdp.State.VsramCache[i] := Vdp.State.Vsram[i];
end;

procedure VDPEndScanline(var Vdp: TVDP; Scanline: Cardinal; ScanlineRenderedCallback: TVDPScanlineRenderedCallback; ScanlineRenderedCallbackUserData: Pointer);
begin
  var PlaneMetapixelsBuffer: array[0..MAX_PLANE_PIXELS + 2 * PLANE_PADDING - 1] of Byte;
  var SpriteMetapixelsBuffer: array[0..MAX_PLANE_PIXELS + 2 * SPRITE_PADDING - 1] of Byte;
  var BackgroundPixel: Byte;

  Assert(Scanline < Cardinal(Length(Vdp.State.SpriteRowCache.Rows)));
  UpdateSpriteCache(Vdp);
  for var PixelIndex := Low(SpriteMetapixelsBuffer) to High(SpriteMetapixelsBuffer) do
    SpriteMetapixelsBuffer[PixelIndex] := 0;
  if Vdp.Configuration.SpritesDisabled = 0 then
    RenderSprites(Vdp, SpriteMetapixelsBuffer, Scanline);
  if Vdp.State.Debug.ForcedLayer = 0 then
    BackgroundPixel := Vdp.State.BackgroundColour
  else
    BackgroundPixel := $3F;
  for var PixelIndex := PLANE_PADDING to PLANE_PADDING + MAX_PLANE_PIXELS - 1 do
    PlaneMetapixelsBuffer[PixelIndex] := BackgroundPixel;
  if (Vdp.State.DisplayEnabled <> 0) and (Vdp.State.Debug.HideLayers = 0) then
  begin
    RenderScrollPlane(Vdp, 0, (Add32(GetVisibleTilePairs(Vdp), Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2))), Scanline, PlaneMetapixelsBuffer, BlitLookup.Normal, 1);
  end;
  RenderForegroundAndSpritePlanes(Vdp, Scanline, PlaneMetapixelsBuffer, SpriteMetapixelsBuffer, 1, ScanlineRenderedCallback, ScanlineRenderedCallbackUserData);
  RenderForegroundAndSpritePlanes(Vdp, Scanline, PlaneMetapixelsBuffer, SpriteMetapixelsBuffer, 0, ScanlineRenderedCallback, ScanlineRenderedCallbackUserData);
end;

function VDPReadData(var Vdp: TVDP): Cardinal;
begin
  var Value: Cardinal := 0;
  Vdp.State.Access.WritePending := 0;
  if IsInReadMode(Vdp.State) <> 0 then
    Value := ReadAndIncrement(Vdp.State);
  Exit(Value);
end;

function VDPReadControl(var Vdp: TVDP): Cardinal;
begin
  Vdp.State.Access.WritePending := 0;
  Exit(Cardinal((($3600) or (Vdp.State.CurrentlyInVblank shl 7)) or (Vdp.State.CurrentlyInVblank shl 3)));
end;

procedure UpdateFakeFIFO(var State: TVDPState; Value: Cardinal);
begin
  var Last: Cardinal := Cardinal(Length(State.PreviousDataWrites) - 1);
  for var i := 0 to Integer(Last) - 1 do
    State.PreviousDataWrites[i] := State.PreviousDataWrites[(Add32(i, 1))];
  State.PreviousDataWrites[Last] := Word(Value);
end;

procedure VDPWriteData(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer);
begin
  Vdp.State.Access.WritePending := 0;
  UpdateFakeFIFO(Vdp.State, Value);
  if IsInReadMode(Vdp.State) <> 0 then
    IncrementAccessAddressRegister(Vdp.State)
  else
  begin
    WriteAndIncrement(Vdp, Value, ColourUpdatedCallback, ColourUpdatedCallbackUserData);
    if IsDMAPending(Vdp.State) <> 0 then
    begin
      ClearDMAPending(Vdp.State);
      while True do
      begin
        if Vdp.State.Access.SelectedBuffer = VDP_ACCESS_VRAM then
        begin
          WriteVRAM(Vdp, Vdp.State.Access.AddressRegister, (Value shr 8));
          IncrementAccessAddressRegister(Vdp.State);
        end
        else
          WriteAndIncrement(Vdp, Vdp.State.PreviousDataWrites[0], ColourUpdatedCallback, ColourUpdatedCallbackUserData);
        Vdp.State.Dma.SourceAddressLow := (Vdp.State.Dma.SourceAddressLow + 1) and $FFFF;
        Vdp.State.Dma.Length := (Vdp.State.Dma.Length + $FFFF) and $FFFF;
        if Vdp.State.Dma.Length = 0 then
          Break;
      end;
    end;
  end;
end;

procedure VDPWriteControl(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer; DmaTransferBeginCallback: TVDPDMATransferBeginCallback; ReadCallback: TVDPReadCallback; ReadCallbackUserData: Pointer; KdebugCallback: TVDPKDebugCallback; KdebugCallbackUserData: Pointer; TargetCycle: Cardinal);
begin
  var CodeBitmask: Cardinal;
  var Reg: Cardinal;
  var Data: Cardinal;
  var Character: Byte;
  var Temp227: Word;
  var TotalReads: Cardinal;
  var Temp231: Integer;
  var ValueScope168: Cardinal;

  if (Vdp.State.Access.WritePending <> 0) or ((Value and $C000) <> $8000) then
  begin
    if Vdp.State.Access.WritePending <> 0 then
    begin
      if Vdp.State.Dma.Enabled <> 0 then
        CodeBitmask := Cardinal($3C)
      else
        CodeBitmask := Cardinal($1C);
      Vdp.State.Access.WritePending := 0;
      Vdp.State.Access.AddressRegister := (Vdp.State.Access.AddressRegister and $3FFF) or ((Value and 7) shl 14);
      Vdp.State.Access.CodeRegister := Word((Cardinal(Vdp.State.Access.CodeRegister) and not CodeBitmask) or ((Value shr 2) and CodeBitmask));
    end
    else
    begin
      Vdp.State.Access.WritePending := 1;
      Vdp.State.Access.AddressRegister := (Value and $3FFF) or (Vdp.State.Access.AddressRegister and Cardinal(3 shl 14));
      Vdp.State.Access.CodeRegister := Word(((Value shr 14) and 3) or Cardinal(Vdp.State.Access.CodeRegister and $3C));
    end;
    case (ArithmeticShiftRight(Vdp.State.Access.CodeRegister, 1) and 7) of
      0:
        Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VRAM;
      4, 1:
        Vdp.State.Access.SelectedBuffer := VDP_ACCESS_CRAM;
      2:
        Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VSRAM;
      6:
        Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VRAM_8_BIT;
    else
      Vdp.State.Access.SelectedBuffer := VDP_ACCESS_INVALID;
    end;
  end
  else
  begin
    Reg := (Value shr 8) and $1F;
    Data := Value and $FF;
    Vdp.State.Access.SelectedBuffer := VDP_ACCESS_INVALID;
    if (Reg <= 10) or (Vdp.State.MegaDriveModeEnabled <> 0) then
    begin
      case Reg of
        0:
          Vdp.State.HIntEnabled := Ord((Data and $10) <> 0);
        1:
          begin
            Vdp.State.ExtendedVramEnabled := Ord((Data and $80) <> 0);
            Vdp.State.DisplayEnabled := Ord((Data and $40) <> 0);
            Vdp.State.VIntEnabled := Ord((Data and $20) <> 0);
            Vdp.State.Dma.Enabled := Ord((Data and $10) <> 0);
            Vdp.State.V30Enabled := Ord((Data and $8) <> 0);
            Vdp.State.MegaDriveModeEnabled := Ord((Data and $4) <> 0);
          end;
        2:
          Vdp.State.PlaneAAddress := (Data and $78) shl 10;
        3:
          Vdp.State.WindowAddress := (Data and $7E) shl 10;
        4:
          Vdp.State.PlaneBAddress := (Data and $F) shl 13;
        5:
          Vdp.State.SpriteTableAddress := Data shl 9;
        6:
          Vdp.State.SpriteTileIndexRebase := Ord((Data and $20) <> 0);
        7:
          Vdp.State.BackgroundColour := Byte(Data and $3F);
        10:
          Vdp.State.HIntInterval := Byte(Data);
        11:
          begin
            if (Data and 4) <> 0 then
              Vdp.State.VscrollMode := VDP_VSCROLL_MODE_2_CELL
            else
              Vdp.State.VscrollMode := VDP_VSCROLL_MODE_FULL;
            SetHScrollMode(Vdp.State, Integer(Data and 3));
          end;
        12:
          begin
            Vdp.State.H40Enabled := Ord((Data and Cardinal((1 shl 7) or (1))) <> 0);
            Vdp.State.ShadowHighlightEnabled := Ord((Data and $8) <> 0);
            case ((Data shr 1) and 3) of
              0, 1:
                Vdp.State.DoubleResolutionEnabled := 0;
              2:
                Vdp.State.DoubleResolutionEnabled := 0;
              3:
                Vdp.State.DoubleResolutionEnabled := 1;
            end;
          end;
        13:
          Vdp.State.HscrollAddress := (Data and $7F) shl 10;
        14:
          begin
            Vdp.State.PlaneATileIndexRebase := Ord((Data and 1) <> 0);
            Vdp.State.PlaneBTileIndexRebase := Byte(Ord(((Data and $10) <> 0) and (Vdp.State.PlaneATileIndexRebase <> 0)));
          end;
        15:
          Vdp.State.Access.Increment := Byte(Data);
        16:
          begin
            Vdp.State.PlaneHeightBitmask := Byte((Data shl 1) or $1F);
            case (Data and 3) of
              0:
                begin
                  Vdp.State.PlaneWidthShift := 5;
                  Vdp.State.PlaneHeightBitmask := Byte(Vdp.State.PlaneHeightBitmask and $7F);
                end;
              1:
                begin
                  Vdp.State.PlaneWidthShift := 6;
                  Vdp.State.PlaneHeightBitmask := Byte(Vdp.State.PlaneHeightBitmask and $3F);
                end;
              2:
                begin
                  Vdp.State.PlaneWidthShift := 5;
                  Vdp.State.PlaneHeightBitmask := 0;
                end;
              3:
                begin
                  Vdp.State.PlaneWidthShift := 7;
                  Vdp.State.PlaneHeightBitmask := Byte(Vdp.State.PlaneHeightBitmask and $1F);
                end;
            end;
          end;
        17:
          begin
            Vdp.State.Window.AlignedRight := Ord((Data and $80) <> 0);
            Vdp.State.Window.HorizontalBoundary := Data and $1F;
          end;
        18:
          begin
            Vdp.State.Window.AlignedBottom := Ord((Data and $80) <> 0);
            Vdp.State.Window.VerticalBoundary := Word((Data and $1F) shl (3 + Vdp.State.DoubleResolutionEnabled));
          end;
        19:
          begin
            Vdp.State.Dma.Length := Word(Vdp.State.Dma.Length and (not ($FF)));
            Vdp.State.Dma.Length := Word(Vdp.State.Dma.Length or (Data));
          end;
        20:
          begin
            Vdp.State.Dma.Length := Word(Vdp.State.Dma.Length and (not ($FF shl 8)));
            Vdp.State.Dma.Length := Word(Vdp.State.Dma.Length or (Data shl 8));
          end;
        21:
          begin
            Vdp.State.Dma.SourceAddressLow := Word(Vdp.State.Dma.SourceAddressLow and (not ($FF)));
            Vdp.State.Dma.SourceAddressLow := Word(Vdp.State.Dma.SourceAddressLow or (Data));
          end;
        22:
          begin
            Vdp.State.Dma.SourceAddressLow := Word(Vdp.State.Dma.SourceAddressLow and (not ($FF shl 8)));
            Vdp.State.Dma.SourceAddressLow := Word(Vdp.State.Dma.SourceAddressLow or (Data shl 8));
          end;
        23:
          begin
            if (Data and $80) <> 0 then
            begin
              Vdp.State.Dma.SourceAddressHigh := Byte(Data and $3F);
              if (Data and $40) <> 0 then
                Vdp.State.Dma.Mode := VDP_DMA_MODE_COPY
              else
                Vdp.State.Dma.Mode := VDP_DMA_MODE_FILL;
            end
            else
            begin
              Vdp.State.Dma.SourceAddressHigh := Byte(Data and $7F);
              Vdp.State.Dma.Mode := VDP_DMA_MODE_MEMORY_TO_VRAM;
            end;
          end;
        30:
          repeat
            Character := Byte((Integer(Data) and ((1 shl 7) - 1)) - (Integer(Data) and (1 shl 7)));
            if (Character < $20) and (Character <> 0) then
              Break;
            Temp227 := Vdp.State.KdebugBufferIndex;
            Inc(Vdp.State.KdebugBufferIndex);
            Vdp.State.KdebugBuffer[Temp227] := Character;
            if (Character = 0) or (Vdp.State.KdebugBufferIndex = Integer(Length(Vdp.State.KdebugBuffer) - 1)) then
            begin
              Vdp.State.KdebugBufferIndex := 0;
              KdebugCallback(KdebugCallbackUserData, Vdp.State.KdebugBuffer);
            end;
          until True;
      end;
    end;
  end;
  if (IsDMAPending(Vdp.State) <> 0) and (Vdp.State.Dma.Mode <> VDP_DMA_MODE_FILL) then
  begin
    ClearDMAPending(Vdp.State);
    if Vdp.State.Dma.Mode = VDP_DMA_MODE_MEMORY_TO_VRAM then
    begin
      if Vdp.State.Dma.Length = 0 then
        TotalReads := Cardinal($10000)
      else
        TotalReads := Cardinal(Vdp.State.Dma.Length);
      Temp231 := Ord((Vdp.State.Access.SelectedBuffer = VDP_ACCESS_VRAM) and ((Vdp.State.ExtendedVramEnabled = 0)));
      DmaTransferBeginCallback(ReadCallbackUserData, (TotalReads shl Temp231), TargetCycle);
    end;
    while True do
    begin
      if Vdp.State.Dma.Mode = VDP_DMA_MODE_MEMORY_TO_VRAM then
      begin
        ValueScope168 := Cardinal(ReadCallback(ReadCallbackUserData, ((Cardinal(Vdp.State.Dma.SourceAddressHigh) shl 17) or (Cardinal(Vdp.State.Dma.SourceAddressLow) shl 1)), TargetCycle));
        UpdateFakeFIFO(Vdp.State, ValueScope168);
        WriteAndIncrement(Vdp, ValueScope168, ColourUpdatedCallback, ColourUpdatedCallbackUserData);
      end
      else
      begin
        WriteVRAM(Vdp, Vdp.State.Access.AddressRegister, ReadVRAM(Vdp.State, Vdp.State.Dma.SourceAddressLow));
        IncrementAccessAddressRegister(Vdp.State);
      end;
      Vdp.State.Dma.SourceAddressLow := (Vdp.State.Dma.SourceAddressLow + 1) and $FFFF;
      Vdp.State.Dma.Length := (Vdp.State.Dma.Length + $FFFF) and $FFFF;
      if Vdp.State.Dma.Length = 0 then
        Break;
    end;
  end;
end;

procedure VDPWriteDebugData(var Vdp: TVDP; Value: Cardinal);
begin
  if Vdp.State.Debug.SelectedRegister = 0 then
  begin
    Vdp.State.Debug.HideLayers := Ord((Value and $40) <> 0);
    Vdp.State.Debug.ForcedLayer := Byte((Value shr 7) and 3);
  end;
end;

procedure VDPWriteDebugControl(var Vdp: TVDP; Value: Cardinal);
begin
  Vdp.State.Debug.SelectedRegister := Byte((Value shr 8) and $F);
end;

function VDPReadVRAMWord(const State: TVDPState; Address: Cardinal): Cardinal;
begin
  Exit(ReadVRAM(State, (Address)) or (ReadVRAM(State, (Address xor 1)) shl 8));
end;

function VDPDecomposeTileMetadata(PackedTileMetadata: Cardinal): TVDPTileMetadata;
begin
  var TileMetadata: TVDPTileMetadata;
  TileMetadata.TileIndex := PackedTileMetadata and $7FF;
  TileMetadata.PaletteLine := (PackedTileMetadata shr 13) and 3;
  TileMetadata.XFlip := Ord((PackedTileMetadata and $800) <> 0);
  TileMetadata.YFlip := Ord((PackedTileMetadata and $1000) <> 0);
  TileMetadata.Priority := Ord((PackedTileMetadata and $8000) <> 0);
  Exit(TileMetadata);
end;

function VDPGetCachedSprite(const State: TVDPState; SpriteIndex: Cardinal): TVDPCachedSprite;
begin
  var CachedSprite: TVDPCachedSprite;
  var SpriteBytes := State.SpriteTableCache[SpriteIndex];
  CachedSprite.Y := Cardinal((SpriteBytes[0] or ((SpriteBytes[1] and 3) shl 8)) and ArithmeticShiftRight($3FF, Ord((State.DoubleResolutionEnabled = 0))));
  CachedSprite.Link := Cardinal(SpriteBytes[2] and $7F);
  CachedSprite.Width := Cardinal((ArithmeticShiftRight(Integer(SpriteBytes[3]), 2) and 3) + 1);
  CachedSprite.Height := Cardinal((SpriteBytes[3] and 3) + 1);
  Exit(CachedSprite);
end;

end.

