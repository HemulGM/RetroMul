unit MD.VDP;

interface

uses
  System.SysUtils, System.Math, MD.Arithmetic;

{$Q+}
{$R+}

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
  VDP_DMA_MODE_MEMORY_TO_VRAM = 0;
  VDP_DMA_MODE_FILL = VDP_DMA_MODE_MEMORY_TO_VRAM + 1;
  VDP_DMA_MODE_COPY = VDP_DMA_MODE_FILL + 1;
  VDP_HSCROLL_MODE_FULL = 0;
  VDP_HSCROLL_MODE_INVALID = VDP_HSCROLL_MODE_FULL + 1;
  VDP_HSCROLL_MODE_1_CELL = VDP_HSCROLL_MODE_INVALID + 1;
  VDP_HSCROLL_MODE_1_LINE = VDP_HSCROLL_MODE_1_CELL + 1;
  VDP_VSCROLL_MODE_FULL = 0;
  VDP_VSCROLL_MODE_2_CELL = VDP_VSCROLL_MODE_FULL + 1;
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
  SPRITE_PADDING = 31;
  // 320 + 12 * 16 pixels, plus the fixed scanline padding.
  MAX_WIDESCREEN_TILES = 12;

var
  BlitLookup: TBlitLookupTables;

function GetWidescreenTiles(const Vdp: TVDP): Cardinal; inline;
begin
  Result := Min(Vdp.Configuration.WidescreenTiles, MAX_WIDESCREEN_TILES);
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
  var Temp31: Integer;

  var DecodedAddress: Cardinal := DecodeVRAMAddress(Vdp.State, Address);
  var SpriteTableIndex: Cardinal := Sub32(Address, GetSpriteTableAddress(Vdp.State));
  if Vdp.State.H40Enabled <> 0 then
    Temp31 := 20
  else
    Temp31 := 16;
  if (SpriteTableIndex < Mul32(Mul32(Mul32(Add32(Temp31, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)), 2), 2), 8)) and ((SpriteTableIndex and 4) = 0) then
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
        WriteVRAM(Vdp, (Vdp.State.Access.AddressRegister xor 0), (Value and $FF));
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
      begin
        ;
      end;
  else
    begin
      Assert(0 <> 0);
      ;
    end;
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
        Value := ReadVRAM(State, (Mul32(WordAddress, 2) xor 0)) or (ReadVRAM(State, (Mul32(WordAddress, 2) xor 1)) shl 8);
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
      begin
        ;
      end;
  else
    begin
      Assert(0 <> 0);
      ;
    end;
  end;
  IncrementAccessAddressRegister(State);
  Exit(Value);
end;

procedure ConstantInitialise;
begin
  var PaletteLineIndexMask: Cardinal;
  var ColourIndexMask: Cardinal;
  var PriorityMask: Cardinal;
  var NotShadowedMask: Cardinal;
  var OldPaletteLineIndex: Cardinal;
  var OldColourIndex: Cardinal;
  var OldPriority: Byte;
  var OldNotShadowed: Byte;
  var NewPaletteLineIndex: Cardinal;
  var NewColourIndex: Cardinal;
  var NewPriority: Byte;
  var NewNotShadowed: Byte;
  var DrawNewPixel: Byte;
  var Temp53: Integer;
  var Temp54: Integer;
  var Temp55: Integer;
  var Output: Cardinal;
  var Temp56: Cardinal;
  var Temp57: Cardinal;
  var Temp66: Integer;
  var Temp67: Integer;
  var Temp69: Integer;
  for var NewPixelItem := 0 to High(BlitLookup.Normal.Lower) do
  begin
    for var OldPixelItem := 0 to High(BlitLookup.Normal.Lower[0].Pixels) do
    begin
      PaletteLineIndexMask := $F;
      ColourIndexMask := $3F;
      PriorityMask := $40;
      NotShadowedMask := $80;
      OldPaletteLineIndex := Cardinal(OldPixelItem and PaletteLineIndexMask);
      OldColourIndex := Cardinal(OldPixelItem and ColourIndexMask);
      OldPriority := Ord(Cardinal(OldPixelItem and PriorityMask) <> 0);
      OldNotShadowed := Ord(Cardinal(OldPixelItem and NotShadowedMask) <> 0);
      NewPaletteLineIndex := Cardinal(NewPixelItem and PaletteLineIndexMask);
      NewColourIndex := Cardinal(NewPixelItem and ColourIndexMask);
      NewPriority := Ord(Cardinal(NewPixelItem and PriorityMask) <> 0);
      NewNotShadowed := NewPriority;
      Temp53 := Ord(NewPaletteLineIndex <> 0);
      if Temp53 <> 0 then
      begin
        Temp55 := Ord((OldPaletteLineIndex = 0) or ((OldPriority = 0)));
        Temp54 := Ord((Temp55 <> 0) or (NewPriority <> 0));
        Temp53 := Ord(Temp54 <> 0);
      end;
      DrawNewPixel := Byte(Temp53);
      if DrawNewPixel <> 0 then
        Temp56 := NewPixelItem
      else
        Temp56 := OldPixelItem;
      Output := Temp56;
      if (OldNotShadowed <> 0) or (NewNotShadowed <> 0) then
        Temp57 := NotShadowedMask
      else
        Temp57 := 0;
      Output := Output or Temp57;
      BlitLookup.Normal.Lower[NewPixelItem].Pixels[OldPixelItem] := Byte(Output);
      if DrawNewPixel <> 0 then
      begin
        case NewColourIndex of
          $0E, $1E, $2E:
            begin
              Output := NewColourIndex or Cardinal(SHADOW_HIGHLIGHT_NORMAL);
            end;
          $3E:
            begin
              if OldNotShadowed <> 0 then
                Temp66 := SHADOW_HIGHLIGHT_HIGHLIGHT
              else
                Temp66 := SHADOW_HIGHLIGHT_NORMAL;
              Output := OldColourIndex or Cardinal(Temp66);
            end;
          $3F:
            begin
              Output := OldColourIndex or Cardinal(SHADOW_HIGHLIGHT_SHADOW);
            end;
        else
          begin
            if (NewNotShadowed <> 0) or (OldNotShadowed <> 0) then
              Temp67 := SHADOW_HIGHLIGHT_NORMAL
            else
              Temp67 := SHADOW_HIGHLIGHT_SHADOW;
            Output := NewColourIndex or Cardinal(Temp67);
          end;
        end;
      end
      else
      begin
        if OldNotShadowed <> 0 then
          Temp69 := SHADOW_HIGHLIGHT_NORMAL
        else
          Temp69 := SHADOW_HIGHLIGHT_SHADOW;
        Output := OldColourIndex or Cardinal(Temp69);
      end;
      BlitLookup.ShadowHighlight.Lower[NewPixelItem].Pixels[OldPixelItem] := Byte(Output);
      BlitLookup.ForcedLayer.Lower[NewPixelItem].Pixels[OldPixelItem] := Byte(OldPixelItem and (NewColourIndex or not ColourIndexMask));
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
      begin
        Exit(Cardinal(Vdp.State.VsramCache[PlaneIndex]));
      end;
    VDP_VSCROLL_MODE_2_CELL:
      begin
        Exit(Cardinal(Vdp.State.Vsram[(Add32(PlaneIndex, Mul32(Sub32(TilePair, (GetWidescreenTiles(Vdp) + (2 - 1)) div 2), 2) mod Cardinal(Length(Vdp.State.Vsram))))]));
      end;
  else
    begin
      Assert(0 <> 0);
      Exit(Cardinal(Vdp.State.VsramCache[PlaneIndex]));
    end;
  end;
end;

procedure RenderTilePair(var Vdp: TVDP; PixelYInPlane: Cardinal; VramAddress: Cardinal; BaseTileVramAddress: Cardinal; var Metapixels: array of Byte; var PixelIndex: Integer; const BlitLookupList: TBlitLookup);
begin
  var WordVramAddress: Cardinal;
  var WordValue: Cardinal;
  var XFlip: Cardinal;
  var YFlip: Cardinal;
  var PixelYInTile: Cardinal;
  var TileRowVramAddress: Cardinal;
  var ByteIndexXor: Cardinal;
  var NybbleShift2: Cardinal;
  var NybbleShift1: Cardinal;
  var ByteValue: Cardinal;

  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;
  var TileHeightMask: Cardinal := Cardinal((1 shl TileHeightShift) - 1);
  var PixelYInTileUnflipped: Cardinal := PixelYInPlane and TileHeightMask;
  for var ItemIndex := 0 to 2 - 1 do
  begin
    WordVramAddress := Add32(VramAddress, Mul32(ItemIndex, 2));
    WordValue := ReadVRAM(Vdp.State, (WordVramAddress xor 0)) or (ReadVRAM(Vdp.State, (WordVramAddress xor 1)) shl 8);
    XFlip := Sub32(0, Ord((WordValue and $800) <> 0));
    YFlip := Sub32(0, Ord((WordValue and $1000) <> 0));
    PixelYInTile := PixelYInTileUnflipped xor (TileHeightMask and YFlip);
    TileRowVramAddress := Add32(BaseTileVramAddress, (Add32((WordValue and $7FF) shl TileHeightShift, PixelYInTile)) shl 2);
    ByteIndexXor := 1 xor (3 and XFlip);
    NybbleShift2 := 4 and XFlip;
    NybbleShift1 := 4 xor NybbleShift2;
    var LookupIndex := (WordValue shr 9) and $70;
    for var JIndex := 0 to Integer(8 div 2) - 1 do
    begin
      ByteValue := ReadVRAM(Vdp.State, (Add32(TileRowVramAddress, JIndex) xor ByteIndexXor));
      Metapixels[PixelIndex] := Byte(BlitLookupList.Lower[LookupIndex + ((ByteValue shr NybbleShift1) and $F)].Pixels[Metapixels[PixelIndex]]);
      Inc(PixelIndex);
      Metapixels[PixelIndex] := Byte(BlitLookupList.Lower[LookupIndex + ((ByteValue shr NybbleShift2) and $F)].Pixels[Metapixels[PixelIndex]]);
      Inc(PixelIndex);
    end;
  end;
end;

procedure RenderScrollingPlane(var Vdp: TVDP; Start: Cardinal; EndColumn: Cardinal; Scanline: Cardinal; PlaneIndex: Cardinal; PlaneXOffset: Cardinal; PixelOffset: Integer; var Metapixels: array of Byte; const BlitLookupList: TBlitLookup);
begin
  var Temp79: Integer;
  var Temp80: Byte;
  var Temp81: Cardinal;
  var Temp84: Integer;
  var Temp85: Integer;
  var Temp86: Integer;
  var Temp87: Integer;
  var Vscroll: Cardinal;
  var PixelYInPlane: Cardinal;
  var ClampedI: Cardinal;
  var Temp88: Cardinal;
  var TileX: Cardinal;
  var TileY: Cardinal;
  var VramAddress: Cardinal;

  if PlaneIndex = 0 then
    Temp80 := Vdp.State.PlaneATileIndexRebase
  else
    Temp80 := Vdp.State.PlaneBTileIndexRebase;
  if Temp80 <> 0 then
    Temp79 := $10000
  else
    Temp79 := 0;
  var BaseTileVramAddress: Cardinal := Temp79;
  var PlanePitchShift: Cardinal := Vdp.State.PlaneWidthShift;
  var PlaneWidthBitmask: Cardinal := Cardinal((1 shl PlanePitchShift) - 1);
  var PlaneHeightBitmask: Cardinal := Cardinal(Vdp.State.PlaneHeightBitmask);
  if PlaneIndex = 0 then
    Temp81 := Vdp.State.PlaneAAddress
  else
    Temp81 := Vdp.State.PlaneBAddress;
  var PlaneAddress: Cardinal := Temp81;
  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;
  var PixelIndex := PixelOffset + Integer(Start) * 16;
  var i: Cardinal := Start;
  while True do
  begin
    Temp84 := Ord(i <= EndColumn);
    if Temp84 <> 0 then
    begin
      if 20 > 16 then
        Temp85 := 20
      else
        Temp85 := 16;
      if 20 > 16 then
        Temp86 := 20
      else
        Temp86 := 16;
      if 20 > 16 then
        Temp87 := 20
      else
        Temp87 := 16;
      Temp84 := Ord(i < Cardinal(((((32 - Temp85) div 2) + Temp86) + ((32 - Temp87) div 2)) + 1));
    end;
    if Temp84 = 0 then
      Break;
    Vscroll := GetVScrollValue(Vdp, PlaneIndex, (Sub32(i, 1)));
    PixelYInPlane := Add32(Vscroll, Scanline);
    if Start > Sub32(i, 1) then
      Temp88 := Start
    else
      Temp88 := Sub32(i, 1);
    ClampedI := Temp88;
    TileX := Mul32(Add32(PlaneXOffset, ClampedI), 2) and PlaneWidthBitmask;
    TileY := (PixelYInPlane shr TileHeightShift) and PlaneHeightBitmask;
    VramAddress := Add32(PlaneAddress, Mul32(Add32(TileY shl PlanePitchShift, TileX), 2));
    RenderTilePair(Vdp, PixelYInPlane, VramAddress, BaseTileVramAddress, Metapixels, PixelIndex, BlitLookupList);
    Inc(i);
  end;
end;

procedure RenderWindowPlane(var Vdp: TVDP; Start: Cardinal; EndColumn: Cardinal; Scanline: Cardinal; var Metapixels: array of Byte; const BlitLookupList: TBlitLookup);
begin
  var Temp89: Integer;
  var Temp92: Integer;
  var Temp93: Integer;
  var Temp94: Integer;
  var Temp95: Integer;

  if Vdp.State.PlaneATileIndexRebase <> 0 then
    Temp89 := $10000
  else
    Temp89 := 0;
  var BaseTileVramAddress: Cardinal := Temp89;
  var TileY: Cardinal := Scanline shr (3 + Vdp.State.DoubleResolutionEnabled);
  var PlanePitchShift: Cardinal := 5 + Vdp.State.H40Enabled;
  var PlaneWidthBitmask: Cardinal := Cardinal((1 shl PlanePitchShift) - 1);
  var VramAddressBase: Cardinal := Add32(GetWindowPlaneTableAddress(Vdp.State), Mul32(TileY shl PlanePitchShift, 2));
  var TileXBase: Cardinal := Cardinal(0 - (((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2)) and PlaneWidthBitmask;
  var PixelIndex := PLANE_PADDING + Integer(Start) * 16;
  var i: Cardinal := Start;
  while True do
  begin
    Temp92 := Ord(i < EndColumn);
    if Temp92 <> 0 then
    begin
      if 20 > 16 then
        Temp93 := 20
      else
        Temp93 := 16;
      if 20 > 16 then
        Temp94 := 20
      else
        Temp94 := 16;
      if 20 > 16 then
        Temp95 := 20
      else
        Temp95 := 16;
      Temp92 := Ord(i < Cardinal((((32 - Temp93) div 2) + Temp94) + ((32 - Temp95) div 2)));
    end;
    if Temp92 = 0 then
      Break;
    RenderTilePair(Vdp, Scanline, (Add32(VramAddressBase, Mul32(Add32(TileXBase, Mul32(i, 2)) and PlaneWidthBitmask, 2))), BaseTileVramAddress, Metapixels, PixelIndex, BlitLookupList);
    Inc(i);
  end;
end;

procedure UpdateSpriteCache(var Vdp: TVDP);
begin
  var Temp96: Integer;
  var CachedSprite: TVDPCachedSprite;
  var BlankLines: Cardinal;
  var Temp103: Cardinal;
  var Temp104: Cardinal;
  var Temp105: Integer;
  var Temp106: Integer;
  var Temp108: Integer;
  var Temp110: Byte;
  var Temp111: Integer;

  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;
  if Vdp.State.H40Enabled <> 0 then
    Temp96 := 20
  else
    Temp96 := 16;
  var MaxSprites: Cardinal := Mul32(Mul32(Add32(Temp96, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)), 2), 2);
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
    if BlankLines > CachedSprite.Y then
      Temp103 := BlankLines
    else
      Temp103 := CachedSprite.Y;
    var i: Cardinal := Temp103;
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

      if Vdp.State.H40Enabled <> 0 then
        Temp108 := 20
      else
        Temp108 := 16;
      if Cardinal(Vdp.State.SpriteRowCache.Rows[(Sub32(i, BlankLines))].Total) <> Add32(Temp108, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)) then
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
  var Temp112: Integer;
  var Temp113: Integer;
  var SpriteIndex: Cardinal;
  var Width: Cardinal;
  var RawX: Cardinal;
  var X: Cardinal;
  var Temp116: Integer;
  var Temp117: Integer;
  var Temp118: Integer;
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
  var Temp120: Cardinal;
  var PixelYInTile: Cardinal;
  var NybbleShift: array[0..1] of Cardinal;
  var XInSprite: Cardinal;
  var Temp124: Cardinal;
  var TileIndex: Cardinal;
  var TileRowVramAddress: Cardinal;
  var ByteValue: Cardinal;
  var PaletteLineIndex: Cardinal;

  if Vdp.State.SpriteTileIndexRebase <> 0 then
    Temp112 := $10000
  else
    Temp112 := 0;
  var BaseTileVramAddress: Cardinal := Temp112;
  var TileHeightShift: Cardinal := 3 + Vdp.State.DoubleResolutionEnabled;
  var TileHeightMask: Cardinal := Cardinal((1 shl (3 + Vdp.State.DoubleResolutionEnabled)) - 1);
  if Vdp.State.H40Enabled <> 0 then
    Temp113 := 20
  else
    Temp113 := 16;
  var SpriteLimit: Cardinal := Add32(Temp113, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2));
  var PixelLimit: Cardinal := Mul32(SpriteLimit, 16);
  var Masked: Byte := 0;
  for var ItemIndex := 0 to Vdp.State.SpriteRowCache.Rows[Scanline].Total - 1 do
  begin

    SpriteIndex := Add32(GetSpriteTableAddress(Vdp.State), Vdp.State.SpriteRowCache.Rows[Scanline].Sprites[ItemIndex].TableIndex * 8);
    Width := Cardinal(Vdp.State.SpriteRowCache.Rows[Scanline].Sprites[ItemIndex].Width);
    RawX := (ReadVRAM(Vdp.State, (Add32(SpriteIndex, 6) xor 0)) or (ReadVRAM(Vdp.State, (Add32(SpriteIndex, 6) xor 1)) shl 8)) and $1FF;
    X := Add32(RawX, (((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2) * 8);
    if RawX = 0 then
      Masked := Vdp.State.AllowSpriteMasking
    else
      Vdp.State.AllowSpriteMasking := 1;
    Temp117 := Ord((Masked <> 0) or (Add32(X, Mul32(Width, 8)) <= $80));
    Temp116 := Ord(Temp117 <> 0);
    if Temp116 = 0 then
    begin
      if Vdp.State.H40Enabled <> 0 then
        Temp118 := 20
      else
        Temp118 := 16;
      Temp116 := Ord(X >= Add32($80, Mul32(Mul32(Add32(Temp118, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2)), 2), 8)));
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
      WordValue := ReadVRAM(Vdp.State, (Add32(SpriteIndex, 4) xor 0)) or (ReadVRAM(Vdp.State, (Add32(SpriteIndex, 4) xor 1)) shl 8);
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
        Temp120 := Sub32(Sub32(Height shl TileHeightShift, YInSpriteNonFlipped), 1)
      else
        Temp120 := YInSpriteNonFlipped;
      YInSprite := Temp120;
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
          Temp124 := Sub32(Sub32(Width, JIndex), 1)
        else
          Temp124 := JIndex;
        XInSprite := Temp124;
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

  if not (Vdp.Configuration.PlanesDisabled[PlaneIndex] <> 0) then
  begin
    HscrollVramAddress := Add32(Add32(Vdp.State.HscrollAddress, Mul32(PlaneIndex, 2)), GetHScrollTableOffset(Vdp.State, Scanline));
    Hscroll := Add32(ReadVRAM(Vdp.State, (HscrollVramAddress xor 0)) or (ReadVRAM(Vdp.State, (HscrollVramAddress xor 1)) shl 8), (((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2) * 8);
    ScrollOffset := Sub32(8 * 2, Hscroll mod Cardinal(8 * 2));
    PlaneXOffset := Sub32(0, Hscroll div (8 * 2));
    RenderScrollingPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneIndex, PlaneXOffset, PLANE_PADDING - Integer(ScrollOffset), PlaneMetapixels, BlitLookupList);
  end;
end;

procedure RenderForegroundPlane(var Vdp: TVDP; LeftBoundary: Cardinal; RightBoundary: Cardinal; Scanline: Cardinal; var PlaneMetapixels: array of Byte; const BlitLookupList: TBlitLookup; WindowPlane: Byte);
begin
  var Temp129: Integer := Ord(WindowPlane <> 0);
  if Temp129 <> 0 then
    Temp129 := Ord((Vdp.Configuration.WindowDisabled = 0));
  if Temp129 <> 0 then
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
  var Temp132: Integer;
  var Temp133: Integer;
  var Temp134: Cardinal;
  var Temp135: Cardinal;
  var Temp136: Cardinal;
  var Temp137: Integer;
  var Temp138: Cardinal;
  var Temp139: Integer;
  var Temp144: Integer;
  var Temp145: Integer;
  var Temp146: Cardinal;
  var Temp147: Cardinal;
  var Temp148: Cardinal;
  var Temp149: Cardinal;
  var Temp150: Cardinal;
  var Temp151: Cardinal;

  var FullWindowPlaneLine: Byte := Ord(Integer(Ord(Scanline < Cardinal(Vdp.State.Window.VerticalBoundary))) <> Vdp.State.Window.AlignedBottom);
  if Vdp.State.Window.HorizontalBoundary = 0 then
    Temp132 := 0
  else
    Temp132 := ((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) + Vdp.State.Window.HorizontalBoundary;
  var WindowHorizontalBoundary: Cardinal := Temp132;
  if FullWindowPlaneLine <> 0 then
    Temp133 := 0
  else
  begin
    if Vdp.State.Window.AlignedRight = WindowPlane then
      Temp134 := WindowHorizontalBoundary
    else
      Temp134 := 0;
    Temp133 := Temp134;
  end;
  var LeftBoundary: Cardinal := Temp133;
  if FullWindowPlaneLine <> 0 then
  begin
    if WindowPlane <> 0 then
    begin
      if Vdp.State.H40Enabled <> 0 then
        Temp137 := 20
      else
        Temp137 := 16;
      Temp136 := Add32(Temp137, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2));
    end
    else
      Temp136 := 0;
    Temp135 := Temp136;
  end
  else
  begin
    if Vdp.State.Window.AlignedRight = WindowPlane then
    begin
      if Vdp.State.H40Enabled <> 0 then
        Temp139 := 20
      else
        Temp139 := 16;
      Temp138 := Add32(Temp139, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2));
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
        begin
          RenderSpritePlane(PlaneMetapixels, SpriteMetapixels, BlitLookup.ForcedLayer, $FF, LeftBoundaryPixels, RightBoundaryPixels);
        end;
      2:
        begin
          RenderScrollPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookup.ForcedLayer, 0);
        end;
      3:
        begin
          RenderScrollPlane(Vdp, LeftBoundary, RightBoundary, Scanline, PlaneMetapixels, BlitLookup.ForcedLayer, 1);
        end;
    end;
  end;
  var InputExtraTiles: Cardinal := Cardinal((((GetWidescreenTiles(Vdp) + (2 - 1)) div 2) * 2) * 2);
  var InputExtraTilesInPixels: Cardinal := Mul32(InputExtraTiles, 8);
  var OutputExtraTiles: Cardinal := GetWidescreenTiles(Vdp) * 2;
  var OutputExtraTilesInPixels: Cardinal := Mul32(OutputExtraTiles, 8);
  var XOffset: Cardinal := Cardinal(Sub32(InputExtraTilesInPixels, OutputExtraTilesInPixels) div 2);
  if Vdp.State.H40Enabled <> 0 then
    Temp144 := 20
  else
    Temp144 := 16;
  var OutputWidth: Cardinal := Add32((Temp144 * 2) * 8, OutputExtraTilesInPixels);
  if Vdp.State.V30Enabled <> 0 then
    Temp145 := 30
  else
    Temp145 := 28;
  var OutputHeight: Cardinal := Cardinal(Temp145 shl (3 + Vdp.State.DoubleResolutionEnabled));
  if Add32(XOffset, OutputWidth) < LeftBoundaryPixels then
    Temp147 := Add32(XOffset, OutputWidth)
  else
    Temp147 := LeftBoundaryPixels;
  if XOffset > Temp147 then
    Temp146 := XOffset
  else
  begin
    if Add32(XOffset, OutputWidth) < LeftBoundaryPixels then
      Temp148 := Add32(XOffset, OutputWidth)
    else
      Temp148 := LeftBoundaryPixels;
    Temp146 := Temp148;
  end;
  var ClampedLeftBoundaryPixels: Cardinal := Sub32(Temp146, XOffset);
  if Add32(XOffset, OutputWidth) < RightBoundaryPixels then
    Temp150 := Add32(XOffset, OutputWidth)
  else
    Temp150 := RightBoundaryPixels;
  if XOffset > Temp150 then
    Temp149 := XOffset
  else
  begin
    if Add32(XOffset, OutputWidth) < RightBoundaryPixels then
      Temp151 := Add32(XOffset, OutputWidth)
    else
      Temp151 := RightBoundaryPixels;
    Temp149 := Temp151;
  end;
  var ClampedRightBoundaryPixels: Cardinal := Sub32(Temp149, XOffset);
  ScanlineRenderedCallback(ScanlineRenderedCallbackUserData, Scanline, PlaneMetapixels, PLANE_PADDING + Integer(XOffset), ClampedLeftBoundaryPixels, ClampedRightBoundaryPixels, OutputWidth, OutputHeight);
end;

procedure VDPBeginScanline(var Vdp: TVDP);
begin

  for var ItemIndex := 0 to High(Vdp.State.VsramCache) do
  begin
    Vdp.State.VsramCache[ItemIndex] := Vdp.State.Vsram[ItemIndex];
  end;
end;

procedure VDPEndScanline(var Vdp: TVDP; Scanline: Cardinal; ScanlineRenderedCallback: TVDPScanlineRenderedCallback; ScanlineRenderedCallbackUserData: Pointer);
begin
  var PlaneMetapixelsBuffer: array[0..543] of Byte;
  var SpriteMetapixelsBuffer: array[0..573] of Byte;
  var Temp156: Integer;
  var Temp157: Integer;
  var Temp158: Byte;
  var Temp159: Integer;
  var Temp160: Integer;
  var Temp161: Integer;
  var Temp163: Integer;

  if 30 > 28 then
    Temp156 := 30
  else
    Temp156 := 28;
  if 8 > 16 then
    Temp157 := 8
  else
    Temp157 := 16;
  Assert(Scanline < Cardinal(Temp156 * Temp157));
  UpdateSpriteCache(Vdp);
  FillChar(SpriteMetapixelsBuffer, SizeOf(SpriteMetapixelsBuffer), 0);
  if Vdp.Configuration.SpritesDisabled = 0 then
    RenderSprites(Vdp, SpriteMetapixelsBuffer, Scanline);
  if Vdp.State.Debug.ForcedLayer = 0 then
    Temp158 := Vdp.State.BackgroundColour
  else
    Temp158 := $3F;
  if 20 > 16 then
    Temp159 := 20
  else
    Temp159 := 16;
  if 20 > 16 then
    Temp160 := 20
  else
    Temp160 := 16;
  if 20 > 16 then
    Temp161 := 20
  else
    Temp161 := 16;
  FillChar(PlaneMetapixelsBuffer[PLANE_PADDING], (((((32 - Temp159) div 2) + Temp160) + ((32 - Temp161) div 2)) * (8 * 2)), Temp158);
  var Temp162: Integer := Ord(Vdp.State.DisplayEnabled <> 0);
  if Temp162 <> 0 then
    Temp162 := Ord((Vdp.State.Debug.HideLayers = 0));
  if Temp162 <> 0 then
  begin
    if Vdp.State.H40Enabled <> 0 then
      Temp163 := 20
    else
      Temp163 := 16;
    RenderScrollPlane(Vdp, 0, (Add32(Temp163, Mul32(Add32(Cardinal(GetWidescreenTiles(Vdp)), 2 - 1) div 2, 2))), Scanline, PlaneMetapixelsBuffer, BlitLookup.Normal, 1);
  end;
  RenderForegroundAndSpritePlanes(Vdp, Scanline, PlaneMetapixelsBuffer, SpriteMetapixelsBuffer, 1, ScanlineRenderedCallback, ScanlineRenderedCallbackUserData);
  RenderForegroundAndSpritePlanes(Vdp, Scanline, PlaneMetapixelsBuffer, SpriteMetapixelsBuffer, 0, ScanlineRenderedCallback, ScanlineRenderedCallbackUserData);
end;

function VDPReadData(var Vdp: TVDP): Cardinal;
begin

  var Value: Cardinal := 0;
  Vdp.State.Access.WritePending := 0;
  if not (IsInReadMode(Vdp.State) <> 0) then
  begin
    ;
  end
  else
    Value := ReadAndIncrement(Vdp.State);
  Exit(Value);
end;

function VDPReadControl(var Vdp: TVDP): Cardinal;
begin

  var FifoEmpty: Byte := 1;
  Vdp.State.Access.WritePending := 0;
  Exit(Cardinal((($3400 or (FifoEmpty shl 9)) or (Vdp.State.CurrentlyInVblank shl 7)) or (Vdp.State.CurrentlyInVblank shl 3)));
end;

procedure UpdateFakeFIFO(var State: TVDPState; Value: Cardinal);
begin
  var Last: Cardinal := Cardinal(Length(State.PreviousDataWrites) - 1);
  for var ItemIndex := 0 to Integer(Last) - 1 do
  begin
    State.PreviousDataWrites[ItemIndex] := State.PreviousDataWrites[(Add32(ItemIndex, 1))];
  end;
  State.PreviousDataWrites[Last] := Word(Value);
end;

procedure VDPWriteData(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer);
begin

  Vdp.State.Access.WritePending := 0;
  UpdateFakeFIFO(Vdp.State, Value);
  if IsInReadMode(Vdp.State) <> 0 then
  begin
    ;
    IncrementAccessAddressRegister(Vdp.State);
  end
  else
  begin
    WriteAndIncrement(Vdp, Value, ColourUpdatedCallback, ColourUpdatedCallbackUserData);
    if IsDMAPending(Vdp.State) <> 0 then
    begin
      ClearDMAPending(Vdp.State);
      while True do
      begin
        if Vdp.State.Access.SelectedBuffer = Integer(VDP_ACCESS_VRAM) then
        begin
          WriteVRAM(Vdp, Vdp.State.Access.AddressRegister, (Value shr 8));
          IncrementAccessAddressRegister(Vdp.State);
        end
        else
          WriteAndIncrement(Vdp, Vdp.State.PreviousDataWrites[0], ColourUpdatedCallback, ColourUpdatedCallbackUserData);
        Vdp.State.Dma.SourceAddressLow := (Vdp.State.Dma.SourceAddressLow + 1) and $FFFF;
        Vdp.State.Dma.Length := (Vdp.State.Dma.Length + $FFFF) and $FFFF;
        if not (Vdp.State.Dma.Length <> 0) then
          Break;
      end;
    end;
  end;
end;

procedure VDPWriteControl(var Vdp: TVDP; Value: Cardinal; ColourUpdatedCallback: TVDPColourUpdatedCallback; ColourUpdatedCallbackUserData: Pointer; DmaTransferBeginCallback: TVDPDMATransferBeginCallback; ReadCallback: TVDPReadCallback; ReadCallbackUserData: Pointer; KdebugCallback: TVDPKDebugCallback; KdebugCallbackUserData: Pointer; TargetCycle: Cardinal);
begin
  var CodeBitmask: Cardinal;
  var Temp170: Integer;
  var Reg: Cardinal;
  var Data: Cardinal;
  var Temp206: Integer;
  var Temp212: Integer;
  var Temp218: Integer;
  var Temp219: Integer;
  var Temp220: Integer;
  var Temp221: Integer;
  var Temp222: Integer;
  var Temp223: Integer;
  var Temp224: Integer;
  var Temp225: Integer;
  var Character: Byte;
  var Temp227: Word;
  var TotalReads: Cardinal;
  var Temp230: Integer;
  var Temp231: Integer;
  var ValueScope168: Cardinal;

  var Temp169: Integer := Ord(Vdp.State.Access.WritePending <> 0);
  if Temp169 = 0 then
    Temp169 := Ord((Value and $C000) <> $8000);
  if Temp169 <> 0 then
  begin
    if Vdp.State.Access.WritePending <> 0 then
    begin
      if Vdp.State.Dma.Enabled <> 0 then
        Temp170 := $3C
      else
        Temp170 := $1C;
      CodeBitmask := Cardinal(Temp170);
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
        begin
          Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VRAM;
        end;
      4, 1:
        begin
          Vdp.State.Access.SelectedBuffer := VDP_ACCESS_CRAM;
        end;
      2:
        begin
          Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VSRAM;
        end;
      6:
        begin
          Vdp.State.Access.SelectedBuffer := VDP_ACCESS_VRAM_8_BIT;
        end;
    else
      begin
        Vdp.State.Access.SelectedBuffer := VDP_ACCESS_INVALID;
      end;
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
          begin
            if (Data and Cardinal(1 shl 5)) <> 0 then
            begin
              ;
            end;
            Vdp.State.HIntEnabled := Ord((Data and Cardinal(1 shl 4)) <> 0);
            if (Data and Cardinal(1 shl 1)) <> 0 then
            begin
              ;
            end;
          end;
        1:
          begin
            Vdp.State.ExtendedVramEnabled := Ord((Data and Cardinal(1 shl 7)) <> 0);
            Vdp.State.DisplayEnabled := Ord((Data and Cardinal(1 shl 6)) <> 0);
            Vdp.State.VIntEnabled := Ord((Data and Cardinal(1 shl 5)) <> 0);
            Vdp.State.Dma.Enabled := Ord((Data and Cardinal(1 shl 4)) <> 0);
            Vdp.State.V30Enabled := Ord((Data and Cardinal(1 shl 3)) <> 0);
            Vdp.State.MegaDriveModeEnabled := Ord((Data and Cardinal(1 shl 2)) <> 0);
          end;
        2:
          begin
            Vdp.State.PlaneAAddress := (Data and $78) shl 10;
          end;
        3:
          begin
            Vdp.State.WindowAddress := (Data and $7E) shl 10;
          end;
        4:
          begin
            Vdp.State.PlaneBAddress := (Data and $F) shl 13;
          end;
        5:
          begin
            Vdp.State.SpriteTableAddress := Data shl 9;
          end;
        6:
          begin
            Vdp.State.SpriteTileIndexRebase := Ord((Data and Cardinal(1 shl 5)) <> 0);
          end;
        7:
          begin
            Vdp.State.BackgroundColour := Byte(Data and $3F);
          end;
        8, 9:
          begin
          end;
        10:
          begin
            Vdp.State.HIntInterval := Byte(Data);
          end;
        11:
          begin
            if (Data and Cardinal(1 shl 3)) <> 0 then
            begin
              ;
            end;
            if (Data and 4) <> 0 then
              Temp206 := VDP_VSCROLL_MODE_2_CELL
            else
              Temp206 := VDP_VSCROLL_MODE_FULL;
            Vdp.State.VscrollMode := Temp206;
            SetHScrollMode(Vdp.State, Integer(Data and 3));
          end;
        12:
          begin
            Vdp.State.H40Enabled := Ord((Data and Cardinal((1 shl 7) or (1))) <> 0);
            Vdp.State.ShadowHighlightEnabled := Ord((Data and Cardinal(1 shl 3)) <> 0);
            case ((Data shr 1) and 3) of
              0, 1:
                begin
                  Vdp.State.DoubleResolutionEnabled := 0;
                end;
              2:
                begin
                  Vdp.State.DoubleResolutionEnabled := 0;
                  ;
                end;
              3:
                begin
                  Vdp.State.DoubleResolutionEnabled := 1;
                end;
            end;
          end;
        13:
          begin
            Vdp.State.HscrollAddress := (Data and $7F) shl 10;
          end;
        14:
          begin
            Vdp.State.PlaneATileIndexRebase := Ord((Data and 1) <> 0);
            Temp212 := Ord(((Data and Cardinal(1 shl 4)) <> 0) and (Vdp.State.PlaneATileIndexRebase <> 0));
            Vdp.State.PlaneBTileIndexRebase := Byte(Temp212);
          end;
        15:
          begin
            Vdp.State.Access.Increment := Byte(Data);
          end;
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
                  Vdp.State.PlaneHeightBitmask := Byte(Vdp.State.PlaneHeightBitmask and 0);
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
            if 20 > 16 then
              Temp219 := 20
            else
              Temp219 := 16;
            if 20 > 16 then
              Temp220 := 20
            else
              Temp220 := 16;
            if 20 > 16 then
              Temp221 := 20
            else
              Temp221 := 16;
            if Cardinal((((32 - Temp219) div 2) + Temp220) + ((32 - Temp221) div 2)) < (Data and $1F) then
            begin
              if 20 > 16 then
                Temp222 := 20
              else
                Temp222 := 16;
              if 20 > 16 then
                Temp223 := 20
              else
                Temp223 := 16;
              if 20 > 16 then
                Temp224 := 20
              else
                Temp224 := 16;
              Temp218 := (((32 - Temp222) div 2) + Temp223) + ((32 - Temp224) div 2);
            end
            else
              Temp218 := Data and $1F;
            Vdp.State.Window.HorizontalBoundary := Word(Temp218);
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
                Temp225 := VDP_DMA_MODE_COPY
              else
                Temp225 := VDP_DMA_MODE_FILL;
              Vdp.State.Dma.Mode := Temp225;
            end
            else
            begin
              Vdp.State.Dma.SourceAddressHigh := Byte(Data and $7F);
              Vdp.State.Dma.Mode := VDP_DMA_MODE_MEMORY_TO_VRAM;
            end;
          end;
        30:
          begin
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
      else
        begin
          ;
        end;
      end;
    end;
  end;
  var Temp229: Integer := Ord(IsDMAPending(Vdp.State) <> 0);
  if Temp229 <> 0 then
    Temp229 := Ord(Vdp.State.Dma.Mode <> Integer(VDP_DMA_MODE_FILL));
  if Temp229 <> 0 then
  begin
    ClearDMAPending(Vdp.State);
    if Vdp.State.Dma.Mode = Integer(VDP_DMA_MODE_MEMORY_TO_VRAM) then
    begin
      if Vdp.State.Dma.Length = 0 then
        Temp230 := $10000
      else
        Temp230 := Vdp.State.Dma.Length;
      TotalReads := Cardinal(Temp230);
      Temp231 := Ord((Vdp.State.Access.SelectedBuffer = Integer(VDP_ACCESS_VRAM)) and ((Vdp.State.ExtendedVramEnabled = 0)));
      DmaTransferBeginCallback(ReadCallbackUserData, (TotalReads shl Temp231), TargetCycle);
    end;
    while True do
    begin
      if Vdp.State.Dma.Mode = Integer(VDP_DMA_MODE_MEMORY_TO_VRAM) then
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
      if not (Vdp.State.Dma.Length <> 0) then
        Break;
    end;
  end;
end;

procedure VDPWriteDebugData(var Vdp: TVDP; Value: Cardinal);
begin
  case Vdp.State.Debug.SelectedRegister of
    0:
      begin
        Vdp.State.Debug.HideLayers := Ord((Value and Cardinal(1 shl 6)) <> 0);
        Vdp.State.Debug.ForcedLayer := Byte((Value shr 7) and 3);
      end;
  end;
end;

procedure VDPWriteDebugControl(var Vdp: TVDP; Value: Cardinal);
begin
  Vdp.State.Debug.SelectedRegister := Byte((Value shr 8) and $F);
end;

function VDPReadVRAMWord(const State: TVDPState; Address: Cardinal): Cardinal;
begin
  Exit(ReadVRAM(State, (Address xor 0)) or (ReadVRAM(State, (Address xor 1)) shl 8));
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

