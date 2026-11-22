unit NES.PPU;

interface

uses
  NES.State, NES.Types, NES.Consts, NES.Mapper, NES.Mapper.OneBus,
  NES.Mapper.Um6578, NES.Mapper.Mxm1, NES.Mapper.FlameCyclone, NES.Mapper.Mmc3;

type
  // Sprite lanes need not be aligned. A packed word lets the compiler select
  // a fixed-width unaligned access instead of calling the general RTL Move.
  TPpuSpriteWord = packed record
    Value: UInt32;
  end;

  PPpuSpriteWord = ^TPpuSpriteWord;

  TOamEvaluation = record
    Secondary: array[0..31] of UInt8;
    BufferValue, CorruptRow: UInt8;
    WriteIndex, OverflowLeft: Integer;
    InRange, Done: Boolean;
    ZeroAdded, Frozen, CorruptPending: Boolean;
  end;

  TPixelPipeline = record
    Low, High, AttrLow, AttrHigh: UInt16;
    NextLow, NextHigh, Attribute: UInt8;
    SpriteLow, SpriteHigh, SpriteX, SpriteAttr, SpriteY, SpriteTile: array[0..7] of UInt8;
    SpriteZero: array[0..7] of Boolean;
    HitPending, DotSkipped: Boolean;
    Counting: UInt8;
    Mask, MaskDelay: UInt8;
    AddressLatch, DataBus, ReadDelay, AddressDelay: UInt8;
    AddressBus, AddressValue: UInt16;
  end;

  TSpriteLinePixels = array[0..NES_WIDTH - 1] of UInt8;

  TPPU = class
  private
    FRegion: TNesRegion;
    FUseVs2C04DPalette: Boolean;
    FRemoveSpriteLimit: Boolean;
    FCustomPalette: TArray<UInt32>;
    FPreRenderLine: Integer;
    FMapper: TMapper;
    FLineSprites: array[0..63] of UInt8;
    FLineSpriteCount: Integer;
    FZapperMaskValid: Boolean;
    FRenderingLine: Boolean;
    FCycle: Integer;
    FScanline: Integer;
    FFrameReady: Boolean;
    FFrameOdd: Boolean;
    FCtrl: UInt8;
    FMask: UInt8;
    FStatus: UInt8;
    FOamAddress: UInt8;
    FAddrLatch: Boolean;
    FFineX: UInt8;
    FV: UInt16;
    FT: UInt16;
    FDataBuffer: UInt8;
    FOpenBus: UInt8;
    FOpenBusExpiry: array[0..7] of UInt64;
    FOamEval: TOamEvaluation;
    FPixel: TPixelPipeline;
    FNmiOccurred: Boolean;
    FNmiPending: Boolean;
    FNmiDelay: Integer;
    FNmiLine: Boolean;
    FVblSetSuppressed: Boolean;
    FOddFrameSkipEnabled: Boolean;
    FRenderV: UInt16;
    FRenderCtrl: UInt8;
    FRenderMask: UInt8;
    FRenderFineX: UInt8;
    FSplitActive: Boolean;
    FSplitY: Integer;
    FSplitV: UInt16;
    FSplitCtrl: UInt8;
    FSplitFineX: UInt8;
    FSplitMask: UInt8;
    FSprite0HitX: Integer;
    FSprite0HitY: Integer;
    FPpuClock: UInt64;
    FFetchTile: UInt8;
    FMapperHasPpuClock, FMapperHasPpuRead, FMapperUsesPpuAddressBus: Boolean;
    FObservePpuBusRead: TPpuBusReadObserver;
    FMapperHasRenderCallbacks: Boolean;
    FRenderScanlineDot: Integer;
    FMapperAllowsDirectRead: Boolean;
    FCacheBackground: Boolean;
    // Derived row data; valid only inside synchronous RenderScanline.
    FSpriteRowCached: array[0..63] of Boolean;
    FSpriteRowLow, FSpriteRowHigh: array[0..63] of UInt8;
    FBackgroundTileX: Integer;
    FBackgroundLow, FBackgroundHigh, FBackgroundPalette: UInt8;
    FMapperSpriteScanline: Integer;
    FMapperSpriteAddresses: array[0..7] of UInt16;
    FMapperSpriteAddressValid: Boolean;
    // Keep per-dot state within short ARM load/store offsets. Bulk pixel and
    // memory buffers follow it; snapshot field order is defined separately.
    FPaletteRam: array[0..31] of UInt8;
    FOneBus: TMapperOneBus;
    FMmc3Fceux: TMapperMmc3;
    FUm6578: TMapperUm6578;
    FMxm1: TMapperMxm1;
    FFlameCyclone: TMapperFlameCyclone;
    FSuborSb2000: TMapperSuborSb2000;
    FUmControl: Byte;
    FUmAttr2, FUmAttr3: Word;
    FUmPalette: array[0..63] of Byte;
    FOneBusPalette: array[0..255] of Byte;
    FVt369Palette: array[0..1023] of Byte;
    FVt369Colors: array[0..511] of Cardinal;
    FVt369OamHigh: array[0..255] of Byte;
    FVt369OamPage: Byte;
    FVt369SpriteHit: Integer;
    FVt389ExtendedOam, FWideDrawingUsed, FWideFrameReady: Boolean;
    FWideDrawing, FWideFrame: TArray<Cardinal>;
    FVt369LcdNmiArmed, FVt369LcdNmiWait: Boolean;
    FVt369LcdDmaAddress: Word;
    FOneBusColors: array[0..4095] of UInt32;
    FOneBusColorRegion: Integer;
    FOneBusColorRgb444: Boolean;
    FExtraBgLow, FExtraBgHigh: Word;
    FNextExtraBgLow, FNextExtraBgHigh: Byte;
    FExtraSpriteLow, FExtraSpriteHigh: array[0..7] of Byte;
    FOam: array[0..255] of UInt8;
    FNameTable: array[0..4095] of UInt8;
    FFrame: TFrameBuffer;
    FDrawingFrame: TFrameBuffer;
    FZapperMask: TNesZapperMask;
    procedure BuildOneBusColors;
    function OneBusPaletteIndex(Index: Byte): Byte; inline;
    function OneBusPatternPixel(Address: Word; Kind: TOneBusFetch; Eva, Column: Byte; HighPlanesAsPixels: Boolean = False): Byte;
    function ScanlinePaletteIndex(PaletteIndex, Pixel: Byte): Byte; inline;
    procedure ClockMapperAddress;
    procedure RefreshOpenBus(Value, Mask: UInt8);
    procedure ClockOam;
    function AdvanceWaitingSprites(Offset: Integer): Boolean; inline;
    procedure ShiftSpriteGroup(Offset: Integer); inline;
    procedure ClockPixels;
    procedure DrawTimedPixel(X: Integer);
    procedure ClockMemory;
    function ReadMapperDma(Address: Word): Byte;
    procedure IncrementX;
    procedure IncrementY;
    procedure IncrementDataAddress;
    procedure CopyX;
    procedure CopyY;
    function MirrorNameTableAddress(Address: UInt16): UInt16;
    function PpuReadMemory(Address: UInt16; Rendering: Boolean = False; Sprite: Boolean = False; Debug: Boolean = False): UInt8;
    function ReadPpuBus(Address: UInt16; Rendering: Boolean = False; Sprite: Boolean = False): UInt8; inline;
    procedure PpuWriteMemory(Address: UInt16; Value: UInt8);
    procedure SetVblank(Value: Boolean);
    procedure UpdateNmiState;
    function VblankStartLine: Integer; inline;
    procedure CaptureSplitState;
    function SampleBackgroundPixel(X, Y: Integer; out PaletteIndex: UInt8; Debug: Boolean = False): UInt8;
    function SampleSpritePixel(X, Y: Integer; out PaletteIndex: UInt8; out PriorityBehindBg: Boolean; out IsSpriteZero: Boolean): UInt8;
    procedure BuildSpriteLine(out Pixels: TSpriteLinePixels);
    procedure RenderScanline;
    procedure RenderVt369Line;
    procedure RenderVt389Line;
    procedure CopyLowResolutionLineToWide(Line: Integer);
    function Vt369OamByte(Index: Integer): Byte;
    function Vt369NameTableOffset(Address: UInt16): UInt16;
    procedure UpdateVt369Color(Index: Integer); inline;
  public
    procedure SerializeState(State: TNesStateArchive);
    constructor Create;
    // Select timing before running; resets PPU state.
    procedure SetRegion(Value: TNesRegion);
    procedure SetCustomPalette(const Colors: TArray<UInt32>);
    property RemoveSpriteLimit: Boolean read FRemoveSpriteLimit write FRemoveSpriteLimit;
    procedure ConnectMapper(AMapper: TMapper);
    property UseVs2C04DPalette: Boolean read FUseVs2C04DPalette write FUseVs2C04DPalette;
    procedure Reset;
    procedure Clock;
    function CpuRead(Address: UInt16): UInt8;
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    procedure WriteOamDma(Index: Integer; Value: UInt8);
    function UmVramAvailable: Boolean; inline;
    procedure WriteVt369DmaVram(Value: Byte);
    procedure WriteVt369Oam(Index: Integer; Value: Byte);
    procedure SelectVt389Oam;
    procedure WriteVt369Palette(Address: Word; Value: Byte);
    function ReadVt369NameTable(Address: UInt16): Byte;
    procedure WriteVt369NameTable(Address: UInt16; Value: Byte);
    function ConsumeNmi: Boolean; inline;
    procedure RebuildFrame;
    // Borrowed mask, invalidated by Clock, Reset and snapshot loading.
    function GetZapperMask: PNesZapperMask;
    function DebugReadMemory(Address: UInt16): UInt8;
    function DebugMask: UInt8;
    function DebugCtrl: UInt8;
    function DebugStatus: UInt8;
    function DebugV: UInt16;
    function DebugT: UInt16;
    function DebugBackgroundPixel(X, Y: Integer): UInt8;
    function DebugOam(Index: Integer): UInt8;
    function DebugSprite0HitX: Integer;
    function DebugSprite0HitY: Integer;
    function DebugSplitActive: Boolean;
    function DebugSplitY: Integer;

    property FrameReady: Boolean read FFrameReady write FFrameReady;
    property Frame: TFrameBuffer read FFrame;
    property WideFrame: TArray<Cardinal> read FWideFrame;
    property WideFrameReady: Boolean read FWideFrameReady;
    property Cycle: Integer read FCycle;
    property Scanline: Integer read FScanline;
  end;

implementation

uses
  System.SysUtils, NES.Mapper.Namco, NES.Mapper.Mmc5;

function Vt369Rgb555(Value: Integer): Cardinal; inline;
begin
  Result := $FF000000 or (Cardinal(((Value shr 10) and 31) * 255 div 31) shl 16) or
    (Cardinal(((Value shr 5) and 31) * 255 div 31) shl 8) or Cardinal((Value and 31) * 255 div 31);
end;

procedure TPPU.UpdateVt369Color(Index: Integer);
begin
  var Address := Index * 2;
  FVt369Colors[Index] := Vt369Rgb555(FVt369Palette[Address] or
      (Integer(FVt369Palette[Address + 1]) shl 8));
end;

procedure TPPU.SerializeState(State: TNesStateArchive);
begin
  FMapperSpriteAddressValid := False;
  FCacheBackground := False;
  FZapperMaskValid := False;
  State.Field(FRegion, SizeOf(FRegion));
  State.Field(FPreRenderLine, SizeOf(FPreRenderLine));
  State.Field(FNameTable, SizeOf(FNameTable));
  State.Field(FPaletteRam, SizeOf(FPaletteRam));
  State.Field(FOam, SizeOf(FOam));
  State.Field(FLineSprites, SizeOf(FLineSprites));
  State.Field(FLineSpriteCount, SizeOf(FLineSpriteCount));
  State.Field(FFrame, SizeOf(FFrame));
  State.Field(FDrawingFrame, SizeOf(FDrawingFrame));
  State.Field(FRenderingLine, SizeOf(FRenderingLine));
  State.Field(FCycle, SizeOf(FCycle));
  State.Field(FScanline, SizeOf(FScanline));
  State.Field(FFrameReady, SizeOf(FFrameReady));
  State.Field(FFrameOdd, SizeOf(FFrameOdd));
  State.Field(FCtrl, SizeOf(FCtrl));
  State.Field(FMask, SizeOf(FMask));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FOamAddress, SizeOf(FOamAddress));
  State.Field(FAddrLatch, SizeOf(FAddrLatch));
  State.Field(FFineX, SizeOf(FFineX));
  State.Field(FV, SizeOf(FV));
  State.Field(FT, SizeOf(FT));
  State.Field(FDataBuffer, SizeOf(FDataBuffer));
  State.Field(FOpenBus, SizeOf(FOpenBus));
  State.Field(FNmiOccurred, SizeOf(FNmiOccurred));
  State.Field(FNmiPending, SizeOf(FNmiPending));
  State.Field(FNmiDelay, SizeOf(FNmiDelay));
  State.Field(FNmiLine, SizeOf(FNmiLine));
  State.Field(FVblSetSuppressed, SizeOf(FVblSetSuppressed));
  State.Field(FOddFrameSkipEnabled, SizeOf(FOddFrameSkipEnabled));
  State.Field(FRenderV, SizeOf(FRenderV));
  State.Field(FRenderCtrl, SizeOf(FRenderCtrl));
  State.Field(FRenderMask, SizeOf(FRenderMask));
  State.Field(FRenderFineX, SizeOf(FRenderFineX));
  State.Field(FSplitActive, SizeOf(FSplitActive));
  State.Field(FSplitY, SizeOf(FSplitY));
  State.Field(FSplitV, SizeOf(FSplitV));
  State.Field(FSplitCtrl, SizeOf(FSplitCtrl));
  State.Field(FSplitFineX, SizeOf(FSplitFineX));
  State.Field(FSplitMask, SizeOf(FSplitMask));
  State.Field(FSprite0HitX, SizeOf(FSprite0HitX));
  State.Field(FSprite0HitY, SizeOf(FSprite0HitY));
  State.Field(FPpuClock, SizeOf(FPpuClock));
  State.Field(FFetchTile, SizeOf(FFetchTile));
  if State.Version >= 9 then
    State.Field(FOpenBusExpiry, SizeOf(FOpenBusExpiry))
  else if State.Loading then
    RefreshOpenBus(FOpenBus, $FF);
  if State.Version >= 10 then
    State.Field(FOamEval, SizeOf(FOamEval))
  else if State.Loading then
    FOamEval := Default(TOamEvaluation);
  if State.Version >= 10 then
    State.Field(FPixel, SizeOf(FPixel))
  else if State.Loading then
  begin
    FPixel := Default(TPixelPipeline);
    FPixel.Mask := FMask;
  end;
  if FOneBus <> nil then
  begin
    State.Field(FOneBusPalette, SizeOf(FOneBusPalette));
    if FOneBus.HasVt369 then
    begin
      State.Field(FVt369Palette, SizeOf(FVt369Palette));
      if State.Loading then
        for var Index := 0 to High(FVt369Colors) do
          UpdateVt369Color(Index);
      State.Field(FVt369OamHigh, SizeOf(FVt369OamHigh));
      State.Field(FVt369OamPage, SizeOf(FVt369OamPage));
      State.Field(FVt369SpriteHit, SizeOf(FVt369SpriteHit));
      if FOneBus.SupportsWideVideo(State.Version) then
      begin
        State.Field(FVt389ExtendedOam, SizeOf(FVt389ExtendedOam));
        State.Field(FWideDrawingUsed, SizeOf(FWideDrawingUsed));
        State.Field(FWideFrameReady, SizeOf(FWideFrameReady));
        State.Field(FWideDrawing[0], Length(FWideDrawing) * SizeOf(Cardinal));
        State.Field(FWideFrame[0], Length(FWideFrame) * SizeOf(Cardinal));
      end
      else if State.Loading then
      begin
        FVt389ExtendedOam := False;
        FWideDrawingUsed := False;
        FWideFrameReady := False;
      end;
      if FOneBus.HasVt369PhoneLcd then
      begin
        State.Field(FVt369LcdNmiArmed, SizeOf(FVt369LcdNmiArmed));
        State.Field(FVt369LcdNmiWait, SizeOf(FVt369LcdNmiWait));
        State.Field(FVt369LcdDmaAddress, SizeOf(FVt369LcdDmaAddress));
        if State.Loading and (FVt369LcdDmaAddress > $3FFF) then
          raise ENesException.Create('Invalid VT369 LCD DMA address');
      end;
    end;
    State.Field(FExtraBgLow, SizeOf(FExtraBgLow));
    State.Field(FExtraBgHigh, SizeOf(FExtraBgHigh));
    State.Field(FNextExtraBgLow, SizeOf(FNextExtraBgLow));
    State.Field(FNextExtraBgHigh, SizeOf(FNextExtraBgHigh));
    State.Field(FExtraSpriteLow, SizeOf(FExtraSpriteLow));
    State.Field(FExtraSpriteHigh, SizeOf(FExtraSpriteHigh));
    if State.Loading then
      BuildOneBusColors;
  end;
  if (FUm6578 <> nil) or (FSuborSb2000 <> nil) then
  begin
    State.Field(FUmControl, SizeOf(FUmControl));
    State.Field(FUmPalette, SizeOf(FUmPalette));
    State.Field(FUmAttr2, SizeOf(FUmAttr2));
    State.Field(FUmAttr3, SizeOf(FUmAttr3));
    State.Field(FExtraBgLow, SizeOf(FExtraBgLow));
    State.Field(FExtraBgHigh, SizeOf(FExtraBgHigh));
    State.Field(FNextExtraBgLow, SizeOf(FNextExtraBgLow));
    State.Field(FNextExtraBgHigh, SizeOf(FNextExtraBgHigh));
  end;
end;

constructor TPPU.Create;
begin
  inherited Create;
  FOneBusColorRegion := -1;
  FRenderScanlineDot := 1;
  SetRegion(TNesRegion.NTSC);
end;

procedure TPPU.SetCustomPalette(const Colors: TArray<UInt32>);
begin
  if (Length(Colors) <> 0) and (Length(Colors) <> 64) and (Length(Colors) <> 512) then
    raise EArgumentException.Create('NES palette color count');
  FCustomPalette := Copy(Colors);
end;

procedure TPPU.SetRegion(Value: TNesRegion);
begin
  FRegion := Value;
  if Value in [TNesRegion.PAL, TNesRegion.Dendy] then
    FPreRenderLine := 311
  else
    FPreRenderLine := 261;
  Reset;
end;

function TPPU.VblankStartLine: Integer;
begin
  if FRegion = TNesRegion.Dendy then
    Result := 291
  else
    Result := 241;
end;

procedure TPPU.ConnectMapper(AMapper: TMapper);
begin
  FMapper := AMapper;
  FMxm1 := nil;
  if AMapper is TMapperMxm1 then
    FMxm1 := TMapperMxm1(AMapper);
  FFlameCyclone := nil;
  if AMapper is TMapperFlameCyclone then
  begin
    FFlameCyclone := TMapperFlameCyclone(AMapper);
    FFlameCyclone.ConnectPpu(ReadMapperDma, PpuWriteMemory);
  end;
  // Cache callback presence once; plain cartridges need no timed mapper fetches.
  FOneBus := nil;
  FUm6578 := nil;
  FSuborSb2000 := nil;
  if AMapper is TMapperSuborSb2000 then
  begin
    FSuborSb2000 := TMapperSuborSb2000(AMapper);
    if FSuborSb2000.EnhancedVideo then
      FUm6578 := FSuborSb2000;
  end
  else if AMapper is TMapperUm6578 then
    FUm6578 := TMapperUm6578(AMapper);
  if AMapper is TMapperOneBus then
  begin
    FOneBus := TMapperOneBus(AMapper);
    BuildOneBusColors;
  end;
  if (FOneBus <> nil) and FOneBus.SupportsWideVideo then
  begin
    SetLength(FWideFrame, VT389_WIDTH * VT389_HEIGHT);
    SetLength(FWideDrawing, VT389_WIDTH * VT389_HEIGHT);
  end
  else
  begin
    FWideFrame := nil;
    FWideDrawing := nil;
  end;
  FMmc3Fceux := nil;
  if (AMapper is TMapperMmc3) and TMapperMmc3(AMapper).FceuxCompatibility then
    FMmc3Fceux := TMapperMmc3(AMapper);
  FMapperHasPpuRead := False;
  FMapperHasPpuClock := (FOneBus <> nil) or
    ((AMapper <> nil) and (FMmc3Fceux = nil) and AMapper.HasPpuClockCallbacks(FMapperHasPpuRead));
  FMapperHasRenderCallbacks := (AMapper <> nil) and AMapper.HasPpuRenderCallbacks;
  FMapperAllowsDirectRead := (AMapper <> nil) and AMapper.AllowsDirectPpuRead;
  FMapperUsesPpuAddressBus := (AMapper <> nil) and AMapper.UsesPpuAddressBus;
  FObservePpuBusRead := nil;
  if AMapper <> nil then
    FObservePpuBusRead := AMapper.PpuBusReadObserver();
  // The scanline renderer needs MMC5's in-frame flag from the attribute fetch.
  if AMapper is TMapperMmc5 then
    FRenderScanlineDot := 4
  else
    FRenderScanlineDot := 1;
end;

procedure TPPU.Reset;
begin
  FMapperSpriteAddressValid := False;
  FCycle := 0;
  FPpuClock := 0;
  FFetchTile := 0;
  FScanline := FPreRenderLine;
  FFrameReady := False;
  FFrameOdd := False;
  FWideFrameReady := False;
  FWideDrawingUsed := False;
  FVt389ExtendedOam := False;
  if Length(FWideFrame) <> 0 then
  begin
    FillChar(FWideFrame[0], Length(FWideFrame) * SizeOf(Cardinal), 0);
    FillChar(FWideDrawing[0], Length(FWideDrawing) * SizeOf(Cardinal), 0);
  end;
  FCtrl := 0;
  FMask := 0;
  FStatus := 0;
  FOamAddress := 0;
  FAddrLatch := False;
  FFineX := 0;
  FV := 0;
  FT := 0;
  FDataBuffer := 0;
  FOpenBus := 0;
  FillChar(FOpenBusExpiry, SizeOf(FOpenBusExpiry), 0);
  FOamEval := Default(TOamEvaluation);
  FPixel := Default(TPixelPipeline);
  FUmControl := 0;
  FUmAttr2 := 0;
  FUmAttr3 := 0;
  FillChar(FUmPalette, SizeOf(FUmPalette), 0);
  FillChar(FOneBusPalette, SizeOf(FOneBusPalette), 0);
  FillChar(FVt369Palette, SizeOf(FVt369Palette), 0);
  for var Index := 0 to High(FVt369Colors) do
    FVt369Colors[Index] := $FF000000;
  FillChar(FVt369OamHigh, SizeOf(FVt369OamHigh), 0);
  FVt369OamPage := 0;
  FVt369SpriteHit := -1;
  FVt369LcdNmiArmed := False;
  FVt369LcdNmiWait := False;
  FVt369LcdDmaAddress := 0;
  FillChar(FExtraSpriteLow, SizeOf(FExtraSpriteLow), 0);
  FillChar(FExtraSpriteHigh, SizeOf(FExtraSpriteHigh), 0);
  FExtraBgLow := 0;
  FExtraBgHigh := 0;
  FNextExtraBgLow := 0;
  FNextExtraBgHigh := 0;
  FNmiOccurred := False;
  FNmiPending := False;
  FNmiDelay := 0;
  FNmiLine := False;
  FVblSetSuppressed := False;
  FOddFrameSkipEnabled := False;
  FRenderV := 0;
  FRenderCtrl := 0;
  FRenderMask := 0;
  FRenderFineX := 0;
  FSplitActive := False;
  FSplitY := 240;
  FSplitV := 0;
  FSplitCtrl := 0;
  FSplitFineX := 0;
  FSplitMask := 0;
  FSprite0HitX := -1;
  FSprite0HitY := -1;
  FRenderingLine := False;
  FillChar(FFrame, SizeOf(FFrame), 0);
  FillChar(FDrawingFrame, SizeOf(FDrawingFrame), 0);
  FZapperMaskValid := False;
  for var i := Low(FNameTable) to High(FNameTable) do
    FNameTable[i] := 0;
  for var i := Low(FPaletteRam) to High(FPaletteRam) do
    FPaletteRam[i] := 0;
  for var i := Low(FOam) to High(FOam) do
    FOam[i] := 0;
end;

procedure TPPU.IncrementX;
begin
  if (FV and $001F) = 31 then
  begin
    FV := FV and not UInt16($001F);
    FV := FV xor $0400;
  end
  else
    FV := (FV + 1) and $7FFF;
end;

procedure TPPU.IncrementY;
begin
  if FUm6578 <> nil then
  begin
    if (FV and $7000) <> $7000 then
      FV := (Integer(FV) + $1000) and $FFFF
    else
    begin
      FV := FV and $0FFF;
      if (FV and $03E0) = $03E0 then
        FV := FV xor $0BE0
      else
        Inc(FV, $20);
    end;
    Exit;
  end;
  var Y: UInt16;
  if (FV and $7000) <> $7000 then
    FV := (FV + $1000) and $7FFF
  else
  begin
    FV := FV and not UInt16($7000);
    Y := (FV and $03E0) shr 5;
    if Y = 29 then
    begin
      Y := 0;
      FV := FV xor $0800;
    end
    else if Y = 31 then
      Y := 0
    else
      Inc(Y);
    FV := (FV and not UInt16($03E0)) or (Y shl 5);
  end;
end;

procedure TPPU.CopyX;
begin
  FV := (FV and not UInt16($041F)) or (FT and $041F);
end;

procedure TPPU.CopyY;
begin
  if FUm6578 <> nil then
    FV := (FV and $041F) or (FT and $FBE0)
  else
    FV := (FV and not UInt16($7BE0)) or (FT and $7BE0);
end;

function TPPU.MirrorNameTableAddress(Address: UInt16): UInt16;
begin
  if FMapper = nil then
    Exit(Address and $07FF);
  Result := FMapper.NameTableOffset(Address);
end;

function TPPU.ReadPpuBus(Address: UInt16; Rendering, Sprite: Boolean): UInt8;
begin
  if Assigned(FObservePpuBusRead) then
    FObservePpuBusRead(Address);
  Result := PpuReadMemory(Address, Rendering, Sprite);
end;

function TPPU.PpuReadMemory(Address: UInt16; Rendering, Sprite, Debug: Boolean): UInt8;
begin
  var Temp: UInt8;
  if FUm6578 <> nil then
  begin
    FUm6578.PpuRead(Address, Result);
    Exit;
  end;
  if (FOneBus <> nil) and ((Address and $6000) = $4000) then
    Exit(FOneBus.ReadPattern(Address and $1FFF, TOneBusFetch.CpuPort, 0, True));

  Address := Address and $3FFF;
  if (Address < $3F00) and (FMapper <> nil) then
  begin
    if Debug then
    begin
      if FMapper.PpuPeek(Address, Rendering, Temp, Sprite) then
        Exit(Temp);
    end
    else if FMapperAllowsDirectRead then
    begin
      if FMapper.PpuRead(Address, Temp) then
        Exit(Temp);
    end
    else if FMapper.PpuReadContext(Address, Rendering, Temp, Sprite) then
      Exit(Temp);
  end;

  if Address < $2000 then
  begin
    Exit(0);
  end;
  if (FOneBus <> nil) and FOneBus.HasVt369 then
  begin
    if FOneBus.Vt369WidePalette and (Address >= $3C00) then
      Exit(FVt369Palette[Address and $3FF]);
    if Address < $3F00 then
      Exit(ReadVt369NameTable(Address));
    Exit(FOneBusPalette[OneBusPaletteIndex(Address and $FF)]);
  end;
  if Address < $3F00 then
    Exit(FNameTable[MirrorNameTableAddress(Address)]);

  if FOneBus <> nil then
    Exit(FOneBusPalette[OneBusPaletteIndex(Address and $FF)] and $3F);

  var PalAddr: UInt16 := (Address - $3F00) and $1F;
  case PalAddr of
    $10:
      PalAddr := 0;
    $14:
      PalAddr := 4;
    $18:
      PalAddr := 8;
    $1C:
      PalAddr := 12;
  end;
  Result := FPaletteRam[PalAddr] and $3F;
end;

function TPPU.UmVramAvailable: Boolean;
begin
  Result := ((FPixel.Mask and $18) = 0) or ((FScanline >= 240) and (FScanline <> FPreRenderLine));
end;

procedure TPPU.PpuWriteMemory(Address: UInt16; Value: UInt8);
begin
  if FUm6578 <> nil then
  begin
    FUm6578.PpuWrite(Address, Value);
    Exit;
  end;
  if (FOneBus <> nil) and ((Address and $6000) = $4000) then
  begin
    FOneBus.WriteHighPattern(Address and $1FFF, Value);
    Exit;
  end;
  Address := Address and $3FFF;
  if (FOneBus <> nil) and FOneBus.HasVt369 then
  begin
    if FOneBus.Vt369WidePalette and (Address >= $3C00) then
    begin
      WriteVt369Palette(Address, Value);
      Exit;
    end;
    if Address >= $3F00 then
    begin
      FOneBusPalette[OneBusPaletteIndex(Address and $FF)] := Value;
      Exit;
    end;
    if Address >= $2000 then
    begin
      WriteVt369NameTable(Address, Value);
      Exit;
    end;
  end;
  if (FOneBus <> nil) and (Address >= $3F00) then
  begin
    FOneBusPalette[OneBusPaletteIndex(Address and $FF)] := Value and $3F;
    Exit;
  end;
  if (Address < $3F00) and (FMapper <> nil) and FMapper.PpuWrite(Address, Value) then
    Exit;

  if Address < $2000 then
  begin
    Exit;
  end;

  if Address < $3F00 then
  begin
    FNameTable[MirrorNameTableAddress(Address)] := Value;
    Exit;
  end;

  var PalAddr: UInt16 := (Address - $3F00) and $1F;
  case PalAddr of
    $10:
      PalAddr := 0;
    $14:
      PalAddr := 4;
    $18:
      PalAddr := 8;
    $1C:
      PalAddr := 12;
  end;
  FPaletteRam[PalAddr] := Value and $3F;
end;

procedure TPPU.UpdateNmiState;
begin
  var NewLine: Boolean := FNmiOccurred and ((FCtrl and $80) <> 0);
  if NewLine and not FNmiLine then
  begin
    FNmiDelay := 0;
    FNmiPending := True;
  end
  else if not NewLine then
  begin
    // A pulse that falls before the CPU samples the pin is not latched.
    FNmiPending := False;
    FNmiDelay := 0;
  end;
  FNmiLine := NewLine;
end;

procedure TPPU.CaptureSplitState;
begin
  if (FScanline < 0) or (FScanline >= 240) then
    Exit;

  if not FSplitActive then
  begin
    FSplitActive := True;
    FSplitY := FScanline;
  end;
  FSplitV := FT;
  FSplitCtrl := FCtrl;
  FSplitFineX := FFineX;
  FSplitMask := FMask;
end;

procedure TPPU.SetVblank(Value: Boolean);
begin
  if Value then
  begin
    if FVblSetSuppressed then
    begin
      FVblSetSuppressed := False;
      FOddFrameSkipEnabled := False;
      FNmiOccurred := False;
      FNmiPending := False;
      FNmiDelay := 0;
      FNmiLine := False;
      Exit;
    end;

    FStatus := FStatus or $80;
    FNmiOccurred := True;
  end
  else
  begin
    FStatus := FStatus and not $80;
    FNmiOccurred := False;
  end;
  UpdateNmiState;
end;

procedure TPPU.ClockMapperAddress;
begin
  if (FMask and $18) = 0 then
  begin
    if FOneBus <> nil then
      FOneBus.ObserveVideoTimer(FV and $3FFF, False)
    else
      FMapper.ClockPpuAddress(FV and $3FFF, FPpuClock);
    Exit;
  end;

  if (FScanline >= 240) and (FScanline <> FPreRenderLine) then
    Exit;

  // Expose only timed PPU fetches; frame/debug reads must not clock IRQs.
  var Phase: Integer := FCycle and 7;
  var Address: UInt16 := $2000 or (FV and $0FFF);
  if ((FCycle >= 1) and (FCycle < 256)) or ((FCycle >= 320) and (FCycle < 336)) then
  begin
    if Phase >= 4 then
      Address := (UInt16(FCtrl and $10) shl 8) or (UInt16(FFetchTile) shl 4) or ((FV shr 12) and 7) or ((Phase and 2) shl 2);
  end
  else if (FCycle >= 256) and (FCycle < 320) and (Phase >= 4) then
  begin
    // Select the eight sprite rows in one OAM pass. Reuse only calculations;
    // still deliver every timed callback. OAM/control writes invalidate these.
    if not FMapperSpriteAddressValid or (FMapperSpriteScanline <> FScanline) then
    begin
      var NextLine: Integer;
      if FScanline = FPreRenderLine then
        NextLine := 0
      else
        NextLine := FScanline + 1;
      var Height: Integer;
      if (FCtrl and $20) <> 0 then
        Height := 16
      else
        Height := 8;
      if Height = 16 then
        Address := $1FE0
      else
        Address := (UInt16(FCtrl and $08) shl 9) or $0FF0;
      for var Slot := 0 to 7 do
        FMapperSpriteAddresses[Slot] := Address;
      var Count: Integer := 0;
      for var i := 0 to 63 do
        if (NextLine > FOam[i * 4]) and (NextLine <= Integer(FOam[i * 4]) + Height) then
        begin
          var Tile := FOam[i * 4 + 1];
          var Attributes := FOam[i * 4 + 2];
          var Row := NextLine - FOam[i * 4] - 1;
          if (Attributes and $80) <> 0 then
            Row := Height - 1 - Row;
          if Height = 16 then
            Address := (UInt16(Tile and 1) shl 12) or (UInt16(Tile and $FE) shl 4) or ((Row and 8) shl 1) or (Row and 7)
          else
            Address := (UInt16(FCtrl and $08) shl 9) or (UInt16(Tile) shl 4) or (Row and 7);
          FMapperSpriteAddresses[Count] := Address;
          Inc(Count);
          if Count = 8 then
            Break;
        end;
      FMapperSpriteScanline := FScanline;
      FMapperSpriteAddressValid := True;
    end;
    Address := FMapperSpriteAddresses[(FCycle - 256) div 8] or ((Phase and 2) shl 2);
  end;
  if FOneBus <> nil then
    FOneBus.ObserveVideoTimer(Address, True)
  else
  begin
    FMapper.ClockPpuAddress(Address, FPpuClock);
    if FMapperHasPpuRead and ((FCycle and 1) <> 0) and (FCycle <= 339) then
      FMapper.ClockPpuRead;
  end;
end;

function TPPU.ReadMapperDma(Address: Word): Byte;
begin
  Result := PpuReadMemory(Address);
end;

procedure TPPU.ClockMemory;
begin
  // Address and data use separate phases: A0..A7 stay in the external
  // octal latch while A8..A13 remain driven by the current fetch.
  if FPixel.AddressDelay > 0 then
  begin
    Dec(FPixel.AddressDelay);
    if FPixel.AddressDelay = 0 then
      FV := FPixel.AddressValue;
  end;
  var ReadRequest := False;
  var AddressRequest := False;
  if FPixel.ReadDelay > 0 then
  begin
    Dec(FPixel.ReadDelay);
    ReadRequest := FPixel.ReadDelay = 0;
    AddressRequest := FPixel.ReadDelay = 2;
  end;
  var Rendering := ((FPixel.Mask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine));
  var Fetch := Rendering and (FCycle >= 1) and (FCycle <= 340);
  var Background := (FCycle <= 256) or (FCycle >= 321);
  var Phase := (FCycle - 1) and 7;
  var AddressMask: Word := $3F00;
  if FUm6578 <> nil then
    AddressMask := $FF00;
  var Address: UInt16 := FV and (AddressMask or $FF);
  if Fetch then
  begin
    Address := $2000 or (FV and $0FFF);
    if Background and (FCycle <= 336) and (FUm6578 <> nil) then
    begin
      // The adjacent bytes are the tile index and its bank/palette bits.
      if Phase < 4 then
      begin
        Address := ((FV and $0FFF) shl 1) or (Phase shr 1);
        if (FUmControl and 1) <> 0 then
          Address := $2000 or (Address and $07FF);
      end
      else
      begin
        Address := (Word(FPixel.Attribute and $0F) shl 12) or (Word(FFetchTile) shl 4) or
          ((FV shr 12) and 7) or ((Phase and 2) shl 2);
        if (FUmControl and $80) <> 0 then
          Address := Address and $FFEF;
      end;
    end
    else if Background and (FCycle <= 336) then
      case Phase of
        2, 3:
          Address := $23C0 or (FV and $0C00) or ((FV shr 4) and $38) or ((FV shr 2) and 7);
        4..7:
          Address := (UInt16(FCtrl and $10) shl 8) or (UInt16(FFetchTile) shl 4) or
            ((FV shr 12) and 7) or ((Phase and 2) shl 2);
      end
    else if not Background and (Phase >= 4) then
    begin
      var i := (FCycle - 257) div 8;
      var Row := (FScanline - Integer(FPixel.SpriteY[i])) and $FF;
      var Tile := FPixel.SpriteTile[i];
      var Height := 8;
      if (FCtrl and $20) <> 0 then
        Height := 16;
      if (FPixel.SpriteAttr[i] and $80) <> 0 then
        Row := Row xor (Height - 1);
      if FUm6578 <> nil then
        if Height = 16 then
          Address := (Word(FUmControl and 8) shl 10) or (Word(Tile and $FE) shl 4) or
            ((Row and 8) shl 1) or (Row and 7)
        else
          Address := (Word(FUmControl and $0C) shl 10) or (Word(Tile) shl 4) or (Row and 7)
      else if Height = 16 then
        Address := (UInt16(Tile and 1) shl 12) or (UInt16(Tile and $FE) shl 4) or ((Row and 8) shl 1) or (Row and 7)
      else
        Address := (UInt16(FCtrl and 8) shl 9) or (UInt16(Tile) shl 4) or (Row and 7);
      Address := Address or ((Phase and 2) shl 2);
    end;
  end;
  var Ale := AddressRequest or (Fetch and ((FCycle and 1) <> 0));
  // On an odd NTSC frame, line 0 dot 0 completes the second dummy
  // nametable fetch from the pre-render line.
  var OddFrameRead := (FCycle = 0) and FPixel.DotSkipped and Rendering;
  if OddFrameRead then
    Address := $2000 or (FV and $0FFF);
  var ReadLine := ReadRequest or OddFrameRead or (Fetch and ((FCycle and 1) = 0));

  // Simultaneous ALE/read feeds data back into the address latch.
  // Preserve the stable digital case; analogue oscillation is not modeled.
  if Ale then
    if ReadLine then
      FPixel.AddressLatch := FPixel.DataBus
    else
      FPixel.AddressLatch := Address and $FF;
  FPixel.AddressBus := (Address and AddressMask) or FPixel.AddressLatch;
  if FMapperUsesPpuAddressBus then
    FMapper.ClockPpuAddress(FPixel.AddressBus, FPpuClock);
  if ReadLine then
  begin
    var BusAddress := FPixel.AddressBus;
    // Palette RAM is internal; its read buffer comes from nametable RAM.
    if (FUm6578 = nil) and (BusAddress >= $3F00) then
      Dec(BusAddress, $1000);
    if (FOneBus <> nil) and Fetch and not ReadRequest and (BusAddress < $2000) then
    begin
      if Background then
      begin
        FPixel.DataBus := FOneBus.ReadPattern(BusAddress, TOneBusFetch.Background, FPixel.Attribute);
        if FOneBus.Background4Bpp then
        begin
          var Plane := FOneBus.ReadPattern(BusAddress, TOneBusFetch.Background, FPixel.Attribute, True);
          if Phase = 5 then
            FNextExtraBgLow := Plane;
          if Phase = 7 then
            FNextExtraBgHigh := Plane;
        end;
      end
      else
      begin
        var Slot := (FCycle - 257) div 8;
        var Eva := (FPixel.SpriteAttr[Slot] shr 2) and 7;
        FPixel.DataBus := FOneBus.ReadPattern(BusAddress, TOneBusFetch.Sprite, Eva);
        if FOneBus.Sprite4Bpp then
        begin
          var Plane := FOneBus.ReadPattern(BusAddress, TOneBusFetch.Sprite, Eva, True);
          if FOneBus.WideSprites and ((FPixel.SpriteAttr[Slot] and $40) <> 0) then
          begin
            var LeftHalf := FPixel.DataBus;
            FPixel.DataBus := Plane;
            Plane := LeftHalf;
          end;
          if Phase = 5 then
            FExtraSpriteLow[Slot] := Plane;
          if Phase = 7 then
            FExtraSpriteHigh[Slot] := Plane;
        end;
      end;
    end
    else
    begin
      var MxmData: Byte;
      if (FMxm1 <> nil) and Fetch and not ReadRequest and FMxm1.Fetch(BusAddress, FCycle, MxmData) then
        FPixel.DataBus := MxmData
      else
        FPixel.DataBus := ReadPpuBus(BusAddress, (Fetch or OddFrameRead) and not ReadRequest, not Background);
    end;
    if ReadRequest then
      FDataBuffer := FPixel.DataBus;
    if Fetch and ((FCycle and 1) = 0) then
    begin
      if Background then
        case Phase of
          1:
            FFetchTile := FPixel.DataBus;
          3:
            if FUm6578 <> nil then
              FPixel.Attribute := FPixel.DataBus
            else
              FPixel.Attribute := (FPixel.DataBus shr (((FV shr 4) and 4) or (FV and 2))) and 3;
          5:
            begin
              FPixel.NextLow := FPixel.DataBus;
              if (FUm6578 <> nil) and ((FUmControl and $80) <> 0) then
                FNextExtraBgLow := PpuReadMemory(BusAddress or $10);
            end;
          7:
            begin
              FPixel.NextHigh := FPixel.DataBus;
              if (FUm6578 <> nil) and ((FUmControl and $80) <> 0) then
                FNextExtraBgHigh := PpuReadMemory(BusAddress or $10);
            end;
        end
      else
      begin
        var i := (FCycle - 257) div 8;
        if Phase = 5 then
          FPixel.SpriteLow[i] := FPixel.DataBus;
        if Phase = 7 then
          FPixel.SpriteHigh[i] := FPixel.DataBus;
      end;
    end;
  end;
  if ReadRequest then
    IncrementDataAddress;
end;

function TPPU.GetZapperMask: PNesZapperMask;
const
  LIGHT_SCANLINES = 26;
  LIGHT_THRESHOLD = 128;
begin
  if not FZapperMaskValid then
  begin
    FillChar(FZapperMask, SizeOf(FZapperMask), 0);
    // Rendering emits a complete line at dot 1. Include only recently drawn
    // lines, including the previous frame's tail during early scanlines.
    // This approximates persistence; it is not an analog photodiode model.
    var LastLine := FScanline;
    if FCycle <= FRenderScanlineDot then
      Dec(LastLine);
    for var Age := 0 to LIGHT_SCANLINES - 1 do
    begin
      var Y := (LastLine - Age + FPreRenderLine + 1) mod (FPreRenderLine + 1);
      if Y >= NES_HEIGHT then
        Continue;

      for var X := 0 to NES_WIDTH - 1 do
      begin
        var Color := FDrawingFrame[X, Y];
        var Luma := (299 * Integer((Color shr 16) and $FF) + 587 * Integer((Color shr 8) and $FF) + 114 * Integer(Color and $FF)) div 1000;
        FZapperMask[X, Y] := Ord(Luma >= LIGHT_THRESHOLD);
      end;
    end;
    FZapperMaskValid := True;
  end;
  Result := @FZapperMask;
end;

procedure TPPU.ClockOam;
begin
  if (FCycle = 63) or (FCycle = 255) or (FCycle = 339) then
    FOamEval.Frozen := False;
  if (FCycle = 0) or (FCycle = 257) then
    FOamEval.WriteIndex := 0;
  if (FScanline < 240) and (FCycle >= 1) and (FCycle <= 256) then
  begin
    if FCycle <= 64 then
    begin
      FOamEval.BufferValue := $FF;
      FOamEval.Secondary[FOamEval.WriteIndex and 31] := $FF;
      if ((FCycle and 1) = 0) and not FOamEval.Frozen then
      begin
        FOamEval.WriteIndex := (FOamEval.WriteIndex + 1) and 31;
        if FOamEval.WriteIndex = 0 then
          FOamEval.Frozen := True;
      end;
    end
    else if (FCycle and 1) <> 0 then
    begin
      if FCycle = 65 then
      begin
        FOamEval.WriteIndex := 0;
        FOamEval.OverflowLeft := 0;
        FOamEval.InRange := False;
        FOamEval.Done := False;
        FOamEval.ZeroAdded := False;
      end;
      FOamEval.BufferValue := FOam[FOamAddress];
      if (FOneBus = nil) and ((FOamAddress and 3) = 2) then
        FOamEval.BufferValue := FOamEval.BufferValue and $E3;
    end
    else
    begin
      var N := FOamAddress shr 2;
      var M := FOamAddress and 3;
      var Height := 8;
      if (FCtrl and $20) <> 0 then
        Height := 16;
      var YInRange := (FScanline >= FOamEval.BufferValue) and (FScanline < Integer(FOamEval.BufferValue) + Height);
      if FOamEval.Done then
      begin
        N := (N + 1) and 63;
        FOamEval.BufferValue := FOamEval.Secondary[FOamEval.WriteIndex and 31];
      end
      else
      begin
        FOamEval.InRange := FOamEval.InRange or YInRange;
        if FOamEval.WriteIndex < 32 then
        begin
          FOamEval.Secondary[FOamEval.WriteIndex] := FOamEval.BufferValue;
          if FOamEval.InRange then
          begin
            if FCycle = 66 then
              FOamEval.ZeroAdded := True;
            Inc(M);
            Inc(FOamEval.WriteIndex);
            if FOamEval.WriteIndex = 32 then
              FOamEval.Frozen := True;
            if M = 4 then
            begin
              M := 0;
              N := (N + 1) and 63;
            end;
            if (FOamEval.WriteIndex and 3) = 0 then
            begin
              FOamEval.InRange := False;
              if not YInRange then
                M := 0;
            end;
          end
          else
          begin
            N := (N + 1) and 63;
            M := 0;
          end;
          if (N = 0) and (M = 0) then
            FOamEval.Done := True;
        end
        else
        begin
          // Full OAM2 turns writes into reads; n/m advance independently.
          FOamEval.BufferValue := FOamEval.Secondary[FOamEval.WriteIndex and 31];
          if FOamEval.InRange then
          begin
            FStatus := FStatus or $20;
            Inc(M);
            if M = 4 then
            begin
              M := 0;
              N := (N + 1) and 63;
            end;
            if FOamEval.OverflowLeft = 0 then
              FOamEval.OverflowLeft := 3
            else
            begin
              Dec(FOamEval.OverflowLeft);
              if FOamEval.OverflowLeft = 0 then
              begin
                FOamEval.Done := True;
                M := 0;
              end;
            end;
          end
          else
          begin
            N := (N + 1) and 63;
            M := (M + 1) and 3;
            if N = 0 then
              FOamEval.Done := True;
          end;
        end;
      end;
      FOamAddress := (N shl 2) or M;
    end;
  end
  else if (FCycle >= 257) and (FCycle <= 320) then
  begin
    var Phase := (FCycle - 257) and 7;
    if (Phase < 4) and (FCycle <> 257) and not FOamEval.Frozen then
    begin
      FOamEval.WriteIndex := (FOamEval.WriteIndex + 1) and 31;
      if FOamEval.WriteIndex = 0 then
        FOamEval.Frozen := True;
    end;
    FOamEval.BufferValue := FOamEval.Secondary[FOamEval.WriteIndex and 31];
  end
  else if (FCycle >= 321) or (FCycle = 0) then
  begin
    if (FCycle = 321) and not FOamEval.Frozen then
    begin
      FOamEval.WriteIndex := (FOamEval.WriteIndex + 1) and 31;
      if FOamEval.WriteIndex = 0 then
        FOamEval.Frozen := True;
    end;
    FOamEval.BufferValue := FOamEval.Secondary[FOamEval.WriteIndex and 31];
  end;
end;

function TPPU.AdvanceWaitingSprites(Offset: Integer): Boolean;
begin
  var Counters: UInt32;
  Counters := PPpuSpriteWord(@FPixel.SpriteX[Offset]).Value;
  var Bits := Counters and $FEFEFEFE;
  // Each byte must be at least two: no output this dot, no counter expiry,
  // and subtracting one from all four bytes cannot borrow across lanes.
  Result := ((((Bits and $7F7F7F7F) + $7F7F7F7F) or Bits or $7F7F7F7F) and $80808080) = $80808080;
  if Result then
  begin
    Counters := Counters - $01010101;
    PPpuSpriteWord(@FPixel.SpriteX[Offset]).Value := Counters;
  end;
end;

procedure TPPU.ShiftSpriteGroup(Offset: Integer);
begin
  var Attributes, Low, High: UInt32;
  Attributes := PPpuSpriteWord(@FPixel.SpriteAttr[Offset]).Value;
  Low := PPpuSpriteWord(@FPixel.SpriteLow[Offset]).Value;
  High := PPpuSpriteWord(@FPixel.SpriteHigh[Offset]).Value;

  // Expand each horizontal-flip bit to a byte mask. Strip cross-byte carries
  // so all four shifters advance independently, including transparent ones.
  var Reverse := ((Attributes and $40404040) shr 6) * $FF;
  Low := ((Low shl 1) and $FEFEFEFE and not Reverse) or ((Low shr 1) and $7F7F7F7F and Reverse);
  High := ((High shl 1) and $FEFEFEFE and not Reverse) or ((High shr 1) and $7F7F7F7F and Reverse);
  PPpuSpriteWord(@FPixel.SpriteLow[Offset]).Value := Low;
  PPpuSpriteWord(@FPixel.SpriteHigh[Offset]).Value := High;
end;

procedure TPPU.DrawTimedPixel(X: Integer);
var
  Background, PaletteAddress: Byte;
begin
  Background := 0;
  PaletteAddress := 0;
  var Mask := FPixel.Mask;
  if ((Mask and $08) <> 0) and ((X >= 8) or ((Mask and 2) <> 0)) then
  begin
    var Shift := 15 - FFineX;
    Background := ((FPixel.Low shr Shift) and 1) or (((FPixel.High shr Shift) and 1) shl 1);
    if FUm6578 <> nil then
      PaletteAddress := (((FUmAttr2 shr Shift) and 1) shl 4) or (((FUmAttr3 shr Shift) and 1) shl 5);
    if (FUm6578 <> nil) and ((FUmControl and $80) <> 0) then
      Background := Background or (((FExtraBgLow shr Shift) and 1) shl 2) or
        (((FExtraBgHigh shr Shift) and 1) shl 3)
    else
      PaletteAddress := PaletteAddress or (((FPixel.AttrLow shr Shift) and 1) shl 2) or
        (((FPixel.AttrHigh shr Shift) and 1) shl 3);
    PaletteAddress := PaletteAddress or Background;
    if Background = 0 then
      PaletteAddress := 0;
  end;
  if ((Mask and $10) <> 0) and ((X >= 8) or ((Mask and 4) <> 0)) then
    for var Slot := 0 to 7 do
      if ((FPixel.Counting and (1 shl Slot)) = 0) or ((X = 0) and FPixel.DotSkipped) then
      begin
        var Shift := 7;
        if (FPixel.SpriteAttr[Slot] and $40) <> 0 then
          Shift := 0;
        var Pixel := ((FPixel.SpriteLow[Slot] shr Shift) and 1) or
          (((FPixel.SpriteHigh[Slot] shr Shift) and 1) shl 1);
        if Pixel <> 0 then
        begin
          if (Background = 0) or ((FPixel.SpriteAttr[Slot] and $20) = 0) then
            PaletteAddress := $10 or ((FPixel.SpriteAttr[Slot] and 3) shl 2) or Pixel;
          Break;
        end;
      end;
  var Color: Byte;
  if FUm6578 <> nil then
    Color := FUmPalette[PaletteAddress] and $3F
  else
    Color := FPaletteRam[PaletteAddress] and $3F;
  if (Mask and 1) <> 0 then
    Color := Color and $30;
  if Length(FCustomPalette) = 512 then
    FDrawingFrame[X, FScanline] := FCustomPalette[((Mask and $E0) shl 1) or Color]
  else if Length(FCustomPalette) = 64 then
    FDrawingFrame[X, FScanline] := FCustomPalette[Color]
  else
    FDrawingFrame[X, FScanline] := NES_PALETTE[Color];
end;

procedure TPPU.ClockPixels;
begin
  if (FOneBus <> nil) and FOneBus.Vt369WidePalette then
  begin
    if (FScanline < 240) and (FCycle = FVt369SpriteHit) then
      FStatus := FStatus or $40;
    Exit;
  end;
  if FPixel.HitPending then
  begin
    FStatus := FStatus or $40;
    FPixel.HitPending := False;
  end;

  if (FScanline >= 240) and (FScanline <> FPreRenderLine) then
    Exit;

  var Rendering := (FPixel.Mask and $18) <> 0;
  if (FScanline < 240) and (FCycle >= 1) and (FCycle <= 256) then
  begin
    var X := FCycle - 1;
    if (FUm6578 <> nil) or (FMxm1 <> nil) then
      DrawTimedPixel(X);
    var FirstSprite := 0;
    var LastSprite := 7;
    var HitPossible :=
      ((FStatus and $40) = 0) and ((FMask and $18) = $18) and
      ((X >= 8) or ((FMask and 6) = 6)) and (X <> 255);

    // Groups without sprite zero can shift together even while a hit is
    // possible elsewhere. Keep every shifter clock and the scalar hit path.
    if Rendering and (FOneBus = nil) then
    begin
      var ZeroFlags: UInt32;
      if (FPixel.Counting and $0F) = 0 then
      begin
        ZeroFlags := PPpuSpriteWord(@FPixel.SpriteZero[0]).Value;
        if not HitPossible or (ZeroFlags = 0) then
        begin
          ShiftSpriteGroup(0);
          FirstSprite := 4;
        end;
      end;
      if (FPixel.Counting and $F0) = 0 then
      begin
        ZeroFlags := PPpuSpriteWord(@FPixel.SpriteZero[4]).Value;
        if not HitPossible or (ZeroFlags = 0) then
        begin
          ShiftSpriteGroup(4);
          LastSprite := 3;
        end;
      end;
    end;
    // The skipped odd-frame dot makes waiting sprites output at X=0.
    if not ((X = 0) and FPixel.DotSkipped) then
    begin
      if ((FPixel.Counting and $0F) = $0F) and AdvanceWaitingSprites(0) then
        FirstSprite := 4;
      if ((FPixel.Counting and $F0) = $F0) and AdvanceWaitingSprites(4) then
        LastSprite := 3;
    end;

    for var i := FirstSprite to LastSprite do
    begin
      var OutputSprite := ((FPixel.Counting and (1 shl i)) = 0) or ((X = 0) and FPixel.DotSkipped);
      if (FPixel.Counting and (1 shl i)) <> 0 then
      begin
        if FPixel.SpriteX[i] > 0 then
          Dec(FPixel.SpriteX[i]);
        if FPixel.SpriteX[i] = 0 then
          FPixel.Counting := FPixel.Counting and not (1 shl i);
      end;

      var ExtraSprite := (FOneBus <> nil) and FOneBus.Sprite4Bpp;
      if OutputSprite and Rendering and (((FPixel.SpriteLow[i] or FPixel.SpriteHigh[i]) <> 0) or
        (ExtraSprite and ((FExtraSpriteLow[i] or FExtraSpriteHigh[i]) <> 0))) then
      begin
        // All eight shifters still advance on every dot. Their pixel values
        // are needed here only while a sprite-zero hit is still possible.
        if FPixel.SpriteZero[i] and ((FStatus and $40) = 0) and
          ((FMask and $18) = $18) and
          ((X >= 8) or ((FMask and 2) <> 0)) and
          ((X >= 8) or ((FMask and 4) <> 0)) and (X <> 255) then
        begin
          var Background := ((FPixel.Low shr (15 - FFineX)) and 1) or (((FPixel.High shr (15 - FFineX)) and 1) shl 1);
          if ((FOneBus <> nil) and FOneBus.Background4Bpp) or
            ((FUm6578 <> nil) and ((FUmControl and $80) <> 0)) then
            Background := Background or (((FExtraBgLow or FExtraBgHigh) shr (15 - FFineX)) and 1);
          if Background <> 0 then
          begin
            var SpritePixel: UInt8;
            if (FPixel.SpriteAttr[i] and $40) <> 0 then
              SpritePixel := (FPixel.SpriteLow[i] and 1) or ((FPixel.SpriteHigh[i] and 1) shl 1)
            else
              SpritePixel := ((FPixel.SpriteLow[i] shr 7) and 1) or ((FPixel.SpriteHigh[i] shr 6) and 2);
            if ExtraSprite and not FOneBus.WideSprites then
            begin
              var Shift := 7 - 7 * Ord((FPixel.SpriteAttr[i] and $40) <> 0);
              SpritePixel := SpritePixel or (((FExtraSpriteLow[i] or FExtraSpriteHigh[i]) shr Shift) and 1);
            end;
            if SpritePixel <> 0 then
            begin
              FPixel.HitPending := True;
              FSprite0HitX := X;
              FSprite0HitY := FScanline;
            end;
          end;
        end;
        if (FPixel.SpriteAttr[i] and $40) <> 0 then
        begin
          FPixel.SpriteLow[i] := FPixel.SpriteLow[i] shr 1;
          FPixel.SpriteHigh[i] := FPixel.SpriteHigh[i] shr 1;
          if ExtraSprite then
          begin
            if FOneBus.WideSprites then
            begin
              FPixel.SpriteLow[i] := FPixel.SpriteLow[i] or ((FExtraSpriteLow[i] and 1) shl 7);
              FPixel.SpriteHigh[i] := FPixel.SpriteHigh[i] or ((FExtraSpriteHigh[i] and 1) shl 7);
            end;
            FExtraSpriteLow[i] := FExtraSpriteLow[i] shr 1;
            FExtraSpriteHigh[i] := FExtraSpriteHigh[i] shr 1;
          end;
        end
        else
        begin
          FPixel.SpriteLow[i] := (FPixel.SpriteLow[i] shl 1) and $FF;
          FPixel.SpriteHigh[i] := (FPixel.SpriteHigh[i] shl 1) and $FF;
          if ExtraSprite then
          begin
            if FOneBus.WideSprites then
            begin
              FPixel.SpriteLow[i] := FPixel.SpriteLow[i] or (FExtraSpriteLow[i] shr 7);
              FPixel.SpriteHigh[i] := FPixel.SpriteHigh[i] or (FExtraSpriteHigh[i] shr 7);
            end;
            FExtraSpriteLow[i] := (FExtraSpriteLow[i] shl 1) and $FF;
            FExtraSpriteHigh[i] := (FExtraSpriteHigh[i] shl 1) and $FF;
          end;
        end;
      end;
    end;
    FPixel.DotSkipped := False;
  end;

  if not Rendering then
    Exit;

  if FCycle = 339 then
  begin
    FPixel.Counting := 0;
    for var i := 0 to 7 do
      if FPixel.SpriteX[i] <> 0 then
        FPixel.Counting := FPixel.Counting or (1 shl i);
  end;
  if ((FCycle >= 1) and (FCycle <= 256)) or ((FCycle >= 321) and (FCycle <= 336)) then
  begin
    FPixel.Low := (FPixel.Low shl 1) and $FFFF;
    FPixel.High := ((FPixel.High shl 1) or 1) and $FFFF;
    FPixel.AttrLow := (FPixel.AttrLow shl 1) and $FFFF;
    FPixel.AttrHigh := (FPixel.AttrHigh shl 1) and $FFFF;
    if (FOneBus <> nil) or (FUm6578 <> nil) then
    begin
      FExtraBgLow := (FExtraBgLow shl 1) and $FFFF;
      FExtraBgHigh := (FExtraBgHigh shl 1) and $FFFF;
      if (FCycle and 7) = 0 then
      begin
        FExtraBgLow := (FExtraBgLow and $FF00) or FNextExtraBgLow;
        FExtraBgHigh := (FExtraBgHigh and $FF00) or FNextExtraBgHigh;
      end;
    end;
    if FUm6578 <> nil then
    begin
      FUmAttr2 := (FUmAttr2 shl 1) and $FFFF;
      FUmAttr3 := (FUmAttr3 shl 1) and $FFFF;
      if (FCycle and 7) = 0 then
      begin
        FUmAttr2 := (FUmAttr2 and $FF00) or (Ord((FPixel.Attribute and $40) <> 0) * $FF);
        FUmAttr3 := (FUmAttr3 and $FF00) or (Ord((FPixel.Attribute and $80) <> 0) * $FF);
      end;
    end;
    if (FCycle and 7) = 0 then
    begin
      FPixel.Low := (FPixel.Low and $FF00) or FPixel.NextLow;
      FPixel.High := (FPixel.High and $FF00) or FPixel.NextHigh;
      var Attribute := FPixel.Attribute;
      if FUm6578 <> nil then
        Attribute := Attribute shr 4;
      FPixel.AttrLow := (FPixel.AttrLow and $FF00) or (Ord((Attribute and 1) <> 0) * $FF);
      FPixel.AttrHigh := (FPixel.AttrHigh and $FF00) or (Ord((Attribute and 2) <> 0) * $FF);
    end;
  end;

  if (FCycle >= 257) and (FCycle <= 320) then
  begin
    var i := (FCycle - 257) div 8;
    var Phase := (FCycle - 257) and 7;
    if Phase = 0 then
      FPixel.SpriteZero[i] := (i = 0) and FOamEval.ZeroAdded;

    case Phase of
      0:
        FPixel.SpriteY[i] := FOamEval.BufferValue;
      1:
        FPixel.SpriteTile[i] := FOamEval.BufferValue;
      2:
        FPixel.SpriteAttr[i] := FOamEval.BufferValue;
      3:
        FPixel.SpriteX[i] := FOamEval.BufferValue;
    end;
    if (Phase = 4) or (Phase = 6) then
    begin
      var Row := (FScanline - Integer(FPixel.SpriteY[i])) and $FF;
      var Height := 8;
      if (FCtrl and $20) <> 0 then
        Height := 16;
      if (FScanline = FPreRenderLine) and (Row >= Height) then
        FPixel.SpriteZero[i] := False;
    end;
  end;
end;

procedure TPPU.Clock;
begin
  if FSuborSb2000 <> nil then
  begin
    if FSuborSb2000.EnhancedVideo then
      FUm6578 := FSuborSb2000
    else
      FUm6578 := nil;
  end;
  if FPixel.MaskDelay > 0 then
  begin
    Dec(FPixel.MaskDelay);
    if FPixel.MaskDelay = 0 then
    begin
      if ((FPixel.Mask and $18) <> 0) and ((FMask and $18) = 0) and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
      begin
        FOamEval.CorruptRow := FOamEval.WriteIndex and 31;
        if (FCycle >= 65) and (FCycle <= 256) then
          FOamEval.CorruptRow := (FOamEval.CorruptRow + 3) and $1C;
        FOamEval.CorruptPending := True;
      end;
      FPixel.Mask := FMask;
    end;
  end;

  var RenderingEnabled: Boolean := (FPixel.Mask and $18) <> 0;
  if RenderingEnabled and FOamEval.CorruptPending and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
  begin
    FMapperSpriteAddressValid := False;
    for var i := 0 to 7 do
      FOam[Integer(FOamEval.CorruptRow) * 8 + i] := FOam[i];
    FOamEval.Secondary[FOamEval.CorruptRow] := FOamEval.Secondary[0];
    FOamEval.CorruptPending := False;
  end;

  if FCycle = FRenderScanlineDot then
    FZapperMaskValid := False;
  if (FOneBus <> nil) and ((FCycle = 256) or (FCycle = 240)) then
    FOneBus.ClockHsync(FScanline, RenderingEnabled and (FScanline < 240), FCycle);
  if FMapperHasPpuClock and not FMapperUsesPpuAddressBus then
    ClockMapperAddress
  else if (FMmc3Fceux <> nil) and ((FCycle = 255) or (FCycle = 256)) and
    (FScanline >= 0) and (FScanline < 240) then
    FMmc3Fceux.ClockFceuxIrq(FCycle, RenderingEnabled);
  if FFlameCyclone <> nil then
    FFlameCyclone.ClockRaster(FScanline, FCycle, RenderingEnabled);

  Inc(FPpuClock);
  if RenderingEnabled and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
    ClockOam;
  ClockMemory;
  ClockPixels;

  if (FCycle = 1) and (FMapper <> nil) then
    FMapper.ClockScanline(FScanline, RenderingEnabled);
  if FUm6578 <> nil then
  begin
    if FCycle = 330 then
      FUm6578.ClockVideoTimer;
  end
  else if (FMxm1 = nil) and (FScanline < 240) and (FCycle = FRenderScanlineDot) then
  begin
    if (Length(FWideDrawing) <> 0) and FOneBus.WideVideoEnabled then
      RenderVt389Line
    else
    begin
      RenderScanline;
      if FWideDrawingUsed then
        CopyLowResolutionLineToWide(FScanline);
    end;
  end;

  if FVt369LcdNmiArmed and (FScanline = 240) and (FCycle = 120) then
  begin
    if not FVt369LcdNmiWait then
      FNmiPending := True;
    FVt369LcdNmiWait := False;
  end;

  if FNmiDelay > 0 then
  begin
    Dec(FNmiDelay);
    if (FNmiDelay = 0) and FNmiLine then
      FNmiPending := True;
  end;

  if RenderingEnabled then
  begin
    if (((FScanline >= 0) and (FScanline < 240)) or (FScanline = FPreRenderLine)) then
    begin
      if (((FCycle >= 1) and (FCycle <= 256)) or ((FCycle >= 321) and (FCycle <= 336))) and ((FCycle and 7) = 0) then
        IncrementX;
      if FCycle = 256 then
        IncrementY;
      if FCycle = 257 then
        CopyX;

      // Sprite fetches force the primary OAM address back to zero.
      if (FCycle >= 257) and (FCycle <= 320) then
        FOamAddress := 0;
      if (FScanline = FPreRenderLine) and (FCycle = 339) then
        FOddFrameSkipEnabled := RenderingEnabled;
      if (FScanline = FPreRenderLine) and (FCycle >= 280) and (FCycle <= 304) then
        CopyY;
    end;
  end;

  if (FScanline = VblankStartLine) and (FCycle = 1) then
    SetVblank(True);

  if (FScanline = FPreRenderLine) and (FCycle = 1) then
  begin
    FVblSetSuppressed := False;
    FOddFrameSkipEnabled := False;
    SetVblank(False);
    FFrameReady := False;
  end;
  if (FScanline = FPreRenderLine) and (FCycle = 0) then
    FStatus := FStatus and not $60;

  if (FRegion = TNesRegion.NTSC) and FOddFrameSkipEnabled and FFrameOdd and (FScanline = FPreRenderLine) and (FCycle = 339) then
  begin
    FCycle := 340;
    FPixel.DotSkipped := True;
  end;

  Inc(FCycle);

  if FCycle > 340 then
  begin
    FCycle := 0;
    Inc(FScanline);
    if FScanline > FPreRenderLine then
    begin
      FScanline := 0;
      FFrameReady := True;
      FFrame := FDrawingFrame;
      FWideFrameReady := FWideDrawingUsed;
      if FWideDrawingUsed then
      begin
        var Previous := FWideFrame;
        FWideFrame := FWideDrawing;
        FWideDrawing := Previous;
        FWideDrawingUsed := False;
      end;
      if FMapper is TMapperChinaErSan2 then
      begin
        var Colors: array[0..15] of UInt32;
        for var i := 0 to High(Colors) do
        begin
          var ColorIndex := PpuReadMemory($3F00 + i);
          if Length(FCustomPalette) = 512 then
            Colors[i] := FCustomPalette[((FMask and $E0) shl 1) or ColorIndex]
          else if Length(FCustomPalette) = 64 then
            Colors[i] := FCustomPalette[ColorIndex]
          else
            Colors[i] := NES_PALETTE[ColorIndex];
        end;
        TMapperChinaErSan2(FMapper).DrawTextOverlay(FFrame, Colors);
      end;
      FFrameOdd := not FFrameOdd;
      FRenderV := FV;
      FRenderCtrl := FCtrl;
      FRenderMask := FMask;
      FRenderFineX := FFineX;
      FSprite0HitX := -1;
      FSprite0HitY := -1;
    end;
  end;
end;

procedure TPPU.IncrementDataAddress;
begin
  // During rendering PPUDATA clocks both scroll counters, regardless of PPUCTRL.
  if ((FMask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
  begin
    IncrementX;
    IncrementY;
  end
  else if FUm6578 <> nil then
    FV := (Integer(FV) + 1 + 31 * Ord((FCtrl and 4) <> 0)) and $FFFF
  else if (FCtrl and $04) <> 0 then
    FV := (FV + 32) and $7FFF
  else
    FV := (FV + 1) and $7FFF;
  if FMapper <> nil then
    FMapper.ClockPpuAddress(FV and $3FFF, FPpuClock);
end;

procedure TPPU.RefreshOpenBus(Value, Mask: UInt8);
begin
  FOpenBus := (FOpenBus and not Mask) or (Value and Mask);

  // Analogue retention varies with temperature/chip. Use a deterministic
  // ~0.3 second lifetime (20 NTSC frames), independently for each driven bit.
  for var i := 0 to 7 do
    if (Mask and (1 shl i)) <> 0 then
      FOpenBusExpiry[i] := FPpuClock + 1786840;
end;

function TPPU.CpuRead(Address: UInt16): UInt8;
begin
  var VramAddress: UInt16;
  var DrivenMask: UInt8 := 0;
  for var i := 0 to 7 do
    if FPpuClock >= FOpenBusExpiry[i] then
      FOpenBus := FOpenBus and not (1 shl i);

  Result := FOpenBus;
  if (FUm6578 <> nil) and (Address >= $2008) then
  begin
    if Address = $2008 then
      Result := FUmControl
    else if (Address >= $2040) and (Address <= $207F) then
      Result := FUmPalette[Address and $3F];
    Exit;
  end;
  if FOneBus <> nil then
  begin
    if FOneBus.IsVideoRegister(Address) then
    begin
      if FOneBus.HasVt369 and ((Address and $FF) <= $50) then
        Exit(FOneBus.Vt369VideoControl(Address and $FF));
      Exit;
    end;
    if (Address and $3F) = 0 then
      Address := $2002;
  end;
  case Address and 7 of
    2:
      begin
        Result := (FStatus and $E0) or (FOpenBus and $1F);
        DrivenMask := $E0;
        if ((Result and $80) = 0) and (FScanline = 241) and (FCycle = 1) then
        begin
          FVblSetSuppressed := True;
          FNmiPending := False;
        end;
        FStatus := FStatus and not $80;
        if (FScanline = VblankStartLine) and (FCycle <= 3) then
          FNmiPending := False;
        if (Result and $80) = 0 then
          FNmiPending := False
        else if FNmiDelay > 0 then
          FNmiPending := False;
        FNmiOccurred := False;
        FNmiDelay := 0;
        FNmiLine := False;
        FAddrLatch := False;
      end;
    4:
      begin
        if (FOneBus <> nil) and FOneBus.Vt369WidePalette then
        begin
          Result := Vt369OamByte((Integer(FVt369OamPage) shl 8) or FOamAddress);
          RefreshOpenBus(Result, $FF);
          Exit;
        end;
        Result := FOam[FOamAddress];
        DrivenMask := $FF;

        // Attribute bits 2..4 are unimplemented in primary OAM.
        if (FOamAddress and 3) = 2 then
          Result := Result and $E3;
        if ((FMask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
          Result := FOamEval.BufferValue;
      end;
    7:
      begin
        if FUm6578 <> nil then
        begin
          Result := FDataBuffer;
          if UmVramAvailable then
          begin
            FUm6578.PpuRead(FV, FDataBuffer);
            IncrementDataAddress;
          end
          else
            FPixel.ReadDelay := 6;
          RefreshOpenBus(Result, $FF);
          Exit;
        end;
        VramAddress := FV and $3FFF;
        if (FOneBus <> nil) and ((FV and $6000) = $4000) then
        begin
          Result := FDataBuffer;
          FDataBuffer := PpuReadMemory(FV);
          IncrementDataAddress;
          RefreshOpenBus(Result, $FF);
          Exit;
        end;
        var TimedRead := ((FPixel.Mask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine));
        if (FOneBus <> nil) and FOneBus.HasVt369 and
          ((VramAddress >= $3F00) or (FOneBus.Vt369WidePalette and (VramAddress >= $3C00))) then
        begin
          Result := PpuReadMemory(VramAddress);
          DrivenMask := $FF;
          if not TimedRead then
            FDataBuffer := PpuReadMemory(VramAddress - $1000);
        end
        else if VramAddress < $3F00 then
        begin
          Result := FDataBuffer;
          DrivenMask := $FF;
          if not TimedRead then
            FDataBuffer := ReadPpuBus(VramAddress);
        end
        else
        begin
          Result := (PpuReadMemory(VramAddress) and $3F) or (FOpenBus and $C0);
          DrivenMask := $3F;
          if (FMask and 1) <> 0 then
            Result := Result and $F0;
          if not TimedRead then
            FDataBuffer := ReadPpuBus(VramAddress - $1000);
        end;
        if TimedRead then
          FPixel.ReadDelay := 6
        else
          IncrementDataAddress;
      end;
  end;
  RefreshOpenBus(Result, DrivenMask);
end;

procedure TPPU.CpuWrite(Address: UInt16; Value: UInt8);
begin
  FMapperSpriteAddressValid := False;
  RefreshOpenBus(Value, $FF);
  if (FUm6578 <> nil) and (Address >= $2008) then
  begin
    if Address = $2008 then
      FUmControl := Value
    else if (Address >= $2040) and (Address <= $207F) then
      FUmPalette[Address and $3F] := Value;
    Exit;
  end;
  if (FOneBus <> nil) and FOneBus.IsVideoRegister(Address) then
  begin
    FOneBus.WriteVideoRegister(Address, Value);
    if (Address = $2050) and FOneBus.HasVt369PhoneLcd then
    begin
      FVt369LcdNmiArmed := Odd(Value);
      FVt369LcdNmiWait := FVt369LcdNmiArmed;
    end;
    Exit;
  end;
  if (FOneBus <> nil) and FOneBus.HasVt369 and (Address = $2008) then
  begin
    FVt369OamPage := Value and 1;
    Exit;
  end;
  case Address and 7 of
    0:
      begin
        var OldCtrl: UInt8 := FCtrl;
        FCtrl := Value;
        if FMapper <> nil then
          FMapper.SetPpuControl(Value);
        FT := (FT and $F3FF) or (UInt16(Value and 3) shl 10);
        if ((OldCtrl and $80) = 0) and ((FCtrl and $80) <> 0) and FNmiOccurred and not ((FScanline = FPreRenderLine) and (FCycle <= 1)) then
        begin
          FNmiLine := True;
          FNmiDelay := 0;
          FNmiPending := True;
        end
        else
          UpdateNmiState;
        CaptureSplitState;
      end;
    1:
      begin
        FMask := Value;
        FPixel.MaskDelay := 3;
        CaptureSplitState;
      end;
    3:
      FOamAddress := Value;
    4:
      begin
        if (FOneBus <> nil) and FOneBus.Vt369WidePalette then
        begin
          WriteVt369Oam((Integer(FVt369OamPage) shl 8) or FOamAddress, Value);
          FOamAddress := (FOamAddress + 1) and $FF;
          if FOamAddress = 0 then
            FVt369OamPage := FVt369OamPage xor 1;
        end
        else if ((FMask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
          FOamAddress := (FOamAddress + 4) and $FC
        else
        begin
          FOam[FOamAddress] := Value;
          FOamAddress := (FOamAddress + 1) and $FF;
        end;
      end;
    5:
      begin
        if not FAddrLatch then
        begin
          FFineX := Value and 7;
          FT := (FT and $7FE0) or (Value shr 3);
          FAddrLatch := True;
          CaptureSplitState;
        end
        else
        begin
          FT := (FT and $0C1F) or (UInt16(Value and 7) shl 12) or (UInt16(Value and $F8) shl 2);
          FAddrLatch := False;
          CaptureSplitState;
        end;
      end;
    6:
      begin
        if (FOneBus <> nil) and FOneBus.HasVt369PhoneLcd then
          if FAddrLatch then
            FVt369LcdDmaAddress := (FVt369LcdDmaAddress and $3F00) or Value
          else
            FVt369LcdDmaAddress := ((Value and $3F) shl 8) or (FVt369LcdDmaAddress and $FF);
        if not FAddrLatch then
        begin
          var AddressMask := $3F;
          if FUm6578 <> nil then
            AddressMask := $FF
          else if FOneBus <> nil then
            AddressMask := $7F;
          FT := (FT and $00FF) or (UInt16(Value and AddressMask) shl 8);
          FAddrLatch := True;
        end
        else
        begin
          if FUm6578 <> nil then
            FT := (FT and $FF00) or Value
          else
            FT := (FT and $7F00) or Value;
          if ((FPixel.Mask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
          begin
            FPixel.AddressValue := FT;
            FPixel.AddressDelay := 3;
          end
          else
            FV := FT;
          if FMapper <> nil then
            FMapper.ClockPpuAddress(FV and $3FFF, FPpuClock);
          FAddrLatch := False;
        end;
      end;
    7:
      begin
        PpuWriteMemory(FV, Value);
        IncrementDataAddress;
      end;
  end;
end;

procedure TPPU.WriteOamDma(Index: Integer; Value: UInt8);
begin
  FMapperSpriteAddressValid := False;
  RefreshOpenBus(Value, $FF);
  FOam[(FOamAddress + (Index and $FF)) and $FF] := Value;
end;

function TPPU.Vt369NameTableOffset(Address: UInt16): UInt16;
begin
  if (FOneBus.Vt369VideoControl($50) and 1) <> 0 then
    Result := Address and $FFF
  else
    Result := MirrorNameTableAddress($2000 or (Address and $FFF));
end;

function TPPU.ReadVt369NameTable(Address: UInt16): Byte;
begin
  Result := FNameTable[Vt369NameTableOffset(Address)];
end;

procedure TPPU.WriteVt369NameTable(Address: UInt16; Value: Byte);
begin
  FNameTable[Vt369NameTableOffset(Address)] := Value;
end;

function TPPU.Vt369OamByte(Index: Integer): Byte;
begin
  if Index < 256 then
    Result := FOam[Index]
  else
    Result := FVt369OamHigh[Index and $FF];
end;

procedure TPPU.WriteVt369Oam(Index: Integer; Value: Byte);
begin
  if Index < 256 then
    FOam[Index] := Value
  else
    FVt369OamHigh[Index and $FF] := Value;
end;

procedure TPPU.SelectVt389Oam;
begin
  FVt389ExtendedOam := Length(FWideDrawing) <> 0;
end;

procedure TPPU.WriteVt369Palette(Address: Word; Value: Byte);
begin
  if FOneBus.Vt369WidePalette then
  begin
    var Index := Address and $3FF;
    FVt369Palette[Index] := Value;
    UpdateVt369Color(Index shr 1);
  end
  else
    FOneBusPalette[Address and $FF] := Value;
end;

procedure TPPU.WriteVt369DmaVram(Value: Byte);
begin
  if FOneBus.HasVt369PhoneLcd then
  begin
    PpuWriteMemory(FVt369LcdDmaAddress, Value);
    FVt369LcdDmaAddress := (FVt369LcdDmaAddress + 1) and $3FFF;
    Exit;
  end;
  PpuWriteMemory(FV, Value);
  FV := (FV + 1 + 31 * Ord((FCtrl and 4) <> 0)) and $3FFF;
end;

function TPPU.ConsumeNmi: Boolean;
begin
  Result := FNmiPending;
  FNmiPending := False;
end;

function TPPU.SampleBackgroundPixel(X, Y: Integer; out PaletteIndex: UInt8; Debug: Boolean): UInt8;
begin
  if FMapper <> nil then
    FMapper.SetPpuFetchKind(False, X, Y);
  var RenderV: UInt16 := FRenderV;
  var RenderCtrl: UInt8 := FRenderCtrl;
  var RenderMask: UInt8 := FRenderMask;
  var RenderFineX: UInt8 := FRenderFineX;
  if not FRenderingLine and FSplitActive and (Y >= FSplitY) then
  begin
    RenderV := FSplitV;
    RenderCtrl := FSplitCtrl;
    RenderMask := FSplitMask;
    RenderFineX := FSplitFineX;
  end;

  if (RenderMask and $08) = 0 then
  begin
    PaletteIndex := 0;
    Exit(0);
  end;

  if (X < 8) and ((RenderMask and $02) = 0) then
  begin
    PaletteIndex := 0;
    Exit(0);
  end;

  var ScrollX: Integer := ((Integer(RenderV and $001F)) shl 3) or RenderFineX;
  Dec(ScrollX, 16);
  if not FRenderingLine and FSplitActive and (Y >= FSplitY) then
    Inc(ScrollX, 16);
  while ScrollX < 0 do
    Inc(ScrollX, 512);

  var WorldX: Integer := (X + ScrollX) mod 512;
  if FRenderingLine and FCacheBackground and (FBackgroundTileX = (WorldX shr 3)) then
  begin
    PaletteIndex := FBackgroundPalette;
    var Shift := 7 - (WorldX and 7);
    Exit((((FBackgroundHigh shr Shift) and 1) shl 1) or ((FBackgroundLow shr Shift) and 1));
  end;
  var ScrollY: Integer := (((Integer(RenderV shr 5)) and $1F) shl 3) or ((RenderV shr 12) and 7);

  // PPUCTRL writes t's nametable bits, but PPUADDR and scrolling can change
  // them independently. Fetches must use the captured VRAM address, including
  // the nametable toggle from the two pre-render tile fetches above.
  var BaseNameTable: Integer := (RenderV shr 10) and 3;

  var WorldY: Integer;
  if FRenderingLine then
    WorldY := ScrollY mod 480
  else
    WorldY := (Y + ScrollY) mod 480;

  var TableX: Integer := ((BaseNameTable and 1) + (WorldX div 256)) and 1;
  var TableY: Integer := (((BaseNameTable shr 1) and 1) + (WorldY div 240)) and 1;
  var Table: Integer := (TableY shl 1) or TableX;
  var LocalX: Integer := WorldX mod 256;
  var LocalY: Integer := WorldY mod 240;

  var NameAddress: UInt16 := $2000 + UInt16(Table) * $0400 + UInt16((LocalY div 8) * 32 + (LocalX div 8));
  var TileIndex: UInt8 := PpuReadMemory(NameAddress, True, False, Debug);
  var AttributeAddress: UInt16 := $23C0 + UInt16(Table) * $0400 + UInt16((LocalY div 32) * 8 + (LocalX div 32));
  var AttributeByte: UInt8 := PpuReadMemory(AttributeAddress, True, False, Debug);
  if (LocalY and $10) <> 0 then
    AttributeByte := AttributeByte shr 4;
  if (LocalX and $10) <> 0 then
    AttributeByte := AttributeByte shr 2;
  PaletteIndex := AttributeByte and 3;

  var FineY: UInt8 := LocalY and 7;
  var PatternBase: UInt16 := UInt16((RenderCtrl and $10) shr 4) shl 12;
  var PatternAddress := PatternBase + UInt16(TileIndex) * 16 + FineY;
  if FOneBus <> nil then
  begin
    var Eva: Byte := PaletteIndex;
    if FOneBus.BackgroundExtended then
      PaletteIndex := 0;
    Exit(OneBusPatternPixel(PatternAddress, TOneBusFetch.Background, Eva, LocalX and 7));
  end;
  var Lo: UInt8 := PpuReadMemory(PatternAddress, True, False, Debug);
  var Hi: UInt8 := PpuReadMemory(PatternAddress + 8, True, False, Debug);
  if FRenderingLine and FCacheBackground then
  begin
    FBackgroundTileX := WorldX shr 3;
    FBackgroundLow := Lo;
    FBackgroundHigh := Hi;
    FBackgroundPalette := PaletteIndex;
  end;

  var BitPosition: UInt8 := 7 - (LocalX and 7);
  Result := (((Hi shr BitPosition) and 1) shl 1) or ((Lo shr BitPosition) and 1);
end;

function TPPU.SampleSpritePixel(X, Y: Integer; out PaletteIndex: UInt8; out PriorityBehindBg: Boolean; out IsSpriteZero: Boolean): UInt8;
begin
  if FMapper <> nil then
    FMapper.SetPpuFetchKind(True, X, Y);
  var SpriteX: Integer;
  var SpriteY: Integer;
  var SpriteTop: Integer;
  var SpriteHeight: Integer;
  var Row: Integer;
  var Column: Integer;
  var BitPosition: Integer;
  var TileIndex: UInt8;
  var Attributes: UInt8;
  var PatternBase: UInt16;
  var Address: UInt16;
  var Lo: UInt8;
  var Hi: UInt8;
  PaletteIndex := 0;
  PriorityBehindBg := False;
  IsSpriteZero := False;
  Result := 0;

  if (FRenderMask and $10) = 0 then
    Exit;
  if (X < 8) and ((FRenderMask and $04) = 0) then
    Exit;

  if (FRenderCtrl and $20) <> 0 then
    SpriteHeight := 16
  else
    SpriteHeight := 8;

  // RenderScanline selected all sprites intersecting this row in OAM order.
  // Keep pattern reads here: mapper latches/fetch context can change per pixel.
  for var Candidate := 0 to FLineSpriteCount - 1 do
  begin
    var i: Integer := FLineSprites[Candidate];
    if FMapper <> nil then
      FMapper.SetPpuSpriteIndex(i);
    SpriteY := FOam[i * 4 + 0];
    TileIndex := FOam[i * 4 + 1];
    Attributes := FOam[i * 4 + 2];
    SpriteX := FOam[i * 4 + 3];
    SpriteTop := SpriteY + 1;

    var SpriteWidth := 8;
    if (FOneBus <> nil) and FOneBus.WideSprites then
      SpriteWidth := 16;
    if (X < SpriteX) or (X >= SpriteX + SpriteWidth) then
      Continue;

    Row := Y - SpriteTop;
    Column := X - SpriteX;
    if (Attributes and $80) <> 0 then
      Row := SpriteHeight - 1 - Row;
    if (Attributes and $40) <> 0 then
      Column := SpriteWidth - 1 - Column;

    if SpriteHeight = 16 then
    begin
      PatternBase := UInt16(TileIndex and 1) shl 12;
      TileIndex := TileIndex and $FE;
      if Row > 7 then
      begin
        Inc(TileIndex);
        Dec(Row, 8);
      end;
    end
    else
      PatternBase := UInt16((FRenderCtrl and $08) shr 3) shl 12;

    Address := PatternBase + UInt16(TileIndex) * 16 + UInt16(Row and 7);
    if FOneBus <> nil then
    begin
      Result := OneBusPatternPixel(Address, TOneBusFetch.Sprite,
        (Attributes shr 2) and 7, Column and 7, Column >= 8);
      if Result = 0 then
        Continue;
      PaletteIndex := 4 + (Attributes and 3);
      PriorityBehindBg := (Attributes and $20) <> 0;
      IsSpriteZero := i = 0;
      Exit;
    end;
    if FRenderingLine and FCacheBackground and FSpriteRowCached[i] then
    begin
      Lo := FSpriteRowLow[i];
      Hi := FSpriteRowHigh[i];
    end
    else
    begin
      Lo := PpuReadMemory(Address, True, True);
      Hi := PpuReadMemory(Address + 8, True, True);
      if FRenderingLine and FCacheBackground then
      begin
        FSpriteRowCached[i] := True;
        FSpriteRowLow[i] := Lo;
        FSpriteRowHigh[i] := Hi;
      end;
    end;
    BitPosition := 7 - Column;

    Result := (((Hi shr BitPosition) and 1) shl 1) or ((Lo shr BitPosition) and 1);
    if Result <> 0 then
    begin
      PaletteIndex := 4 + (Attributes and 3);
      PriorityBehindBg := (Attributes and $20) <> 0;
      IsSpriteZero := i = 0;
      Exit;
    end;
  end;
end;

procedure TPPU.BuildSpriteLine(out Pixels: TSpriteLinePixels);
begin
  FillChar(Pixels, SizeOf(Pixels), 0);
  // Called only for passive reads with no per-pixel mapper context callbacks.
  // Select the first opaque OAM pixel before applying background priority.
  var Height := 8;
  if (FRenderCtrl and $20) <> 0 then
    Height := 16;
  var LeftClip := 0;
  if (FRenderMask and $04) = 0 then
    LeftClip := 8;

  for var Candidate := 0 to FLineSpriteCount - 1 do
  begin
    var i := Integer(FLineSprites[Candidate]);
    var SpriteX := Integer(FOam[i * 4 + 3]);
    var FirstX := SpriteX;
    if FirstX < LeftClip then
      FirstX := LeftClip;
    var LastX := SpriteX + 7;
    if LastX >= NES_WIDTH then
      LastX := NES_WIDTH - 1;
    if FirstX > LastX then
      Continue;

    var Attributes := FOam[i * 4 + 2];
    var Row := FScanline - Integer(FOam[i * 4]) - 1;
    if (Attributes and $80) <> 0 then
      Row := Height - 1 - Row;
    var Tile := FOam[i * 4 + 1];
    var Address: UInt16;
    if Height = 16 then
      Address := (UInt16(Tile and 1) shl 12) or (UInt16(Tile and $FE) shl 4) or
        ((Row and 8) shl 1) or (Row and 7)
    else
      Address := (UInt16(FRenderCtrl and $08) shl 9) or (UInt16(Tile) shl 4) or (Row and 7);
    var Lo := PpuReadMemory(Address, True, True);
    var Hi := PpuReadMemory(Address + 8, True, True);
    var PaletteAndPriority := ((4 + (Attributes and 3)) shl 2) or (Attributes and $20);
    for var X := FirstX to LastX do
      if Pixels[X] = 0 then
      begin
        var Shift := 7 - (X - SpriteX);
        if (Attributes and $40) <> 0 then
          Shift := 7 - Shift;
        var Pixel := ((Lo shr Shift) and 1) or (((Hi shr Shift) and 1) shl 1);
        if Pixel <> 0 then
          Pixels[X] := PaletteAndPriority or Pixel;
      end;
  end;
end;

function TPPU.OneBusPaletteIndex(Index: Byte): Byte;
begin
  if not FOneBus.HasEnhancedVideo then
    Index := Index and $1F;
  Result := Index;
  if (Index and $63) = 0 then
    Result := Index and $EF;
end;

function TPPU.ScanlinePaletteIndex(PaletteIndex, Pixel: Byte): Byte;
begin
  // VT03 uses CGRAM bits 5 and 6 for the additional pattern planes.
  Result := (PaletteIndex shl 2) or (Pixel and 3) or ((Pixel and $0C) shl 3);
end;

function TPPU.OneBusPatternPixel(Address: Word; Kind: TOneBusFetch; Eva, Column: Byte; HighPlanesAsPixels: Boolean): Byte;
begin
  var Shift := 7 - Column;
  var Lo := FOneBus.ReadPattern(Address, Kind, Eva, HighPlanesAsPixels);
  var Hi := FOneBus.ReadPattern(Address + 8, Kind, Eva, HighPlanesAsPixels);
  Result := ((Lo shr Shift) and 1) or (((Hi shr Shift) and 1) shl 1);
  if ((Kind = TOneBusFetch.Background) and FOneBus.Background4Bpp) or
    ((Kind = TOneBusFetch.Sprite) and FOneBus.Sprite4Bpp and not FOneBus.WideSprites) then
  begin
    Lo := FOneBus.ReadPattern(Address, Kind, Eva, True);
    Hi := FOneBus.ReadPattern(Address + 8, Kind, Eva, True);
    Result := Result or (((Lo shr Shift) and 1) shl 2) or (((Hi shr Shift) and 1) shl 3);
  end;
end;

procedure TPPU.BuildOneBusColors;
const
  InvertedHue: array[0..15] of Byte = (13, 7, 8, 9, 10, 11, 12, 1, 2, 3, 4, 5, 6, 0, 14, 15);

  function Channel(Value: Double): UInt32;
  begin
    Value := (Value - 4.0 / 15.0) * (225.0 / 143.0);
    if FRegion = TNesRegion.NTSC then
      Value := (Value - 0.075) / 0.925;
    if Value <= 0 then
      Exit(0);
    if Value >= 1 then
      Exit(255);
    Result := Round(Value * 255);
  end;

begin
  var Rgb444 := FOneBus.HasVt32;
  if (FOneBusColorRegion = Ord(FRegion)) and (FOneBusColorRgb444 = Rgb444) then
    Exit;
  FOneBusColorRegion := Ord(FRegion);
  FOneBusColorRgb444 := Rgb444;
  if Rgb444 then
  begin
    for var Index := 0 to High(FOneBusColors) do
      FOneBusColors[Index] := $FF000000 or (Cardinal((Index and $00F) * 17) shl 16) or
        (Cardinal(((Index shr 4) and $F) * 17) shl 8) or Cardinal((Index shr 8) * 17);
    Exit;
  end;
  for var Index := 0 to High(FOneBusColors) do
  begin
    var Hue := Index and 15;
    var Luma := (Index shr 4) and 15;
    var Chroma := Index shr 8;
    if (Luma < ((Chroma + 1) shr 1)) or (Luma > 15 - (Chroma shr 1)) then
    begin
      Hue := InvertedHue[Hue];
      Chroma := 16 - Chroma;
      Luma := (Luma - 8) and 15;
    end;
    var Brightness := Luma / 15;
    var Saturation := Chroma / 30;
    var Phase := (Hue - 2) * Pi / 6;
    if FRegion <> TNesRegion.NTSC then
      Phase := Phase - Pi / 18;
    var Y := Brightness;
    var U: Double := 0;
    var V: Double := 0;
    case Hue of
      0:
        Y := Y + Saturation;
      1..12:
        begin
          U := Cos(Phase) * Saturation;
          V := Sin(Phase) * Saturation;
        end;
      13:
        Y := Y - Saturation;
    else
      Y := 0;
    end;
    FOneBusColors[Index] := $FF000000 or (Channel(Y + 1.1400 * V) shl 16) or
      (Channel(Y - 0.5807 * V - 0.3940 * U) shl 8) or Channel(Y + 2.0290 * U);
  end;
end;

procedure TPPU.RenderVt369Line;
begin
  var Bg: array[0..NES_WIDTH - 1] of Byte;
  var PixelIndices: array[0..NES_WIDTH - 1] of Word;
  FillChar(Bg, SizeOf(Bg), 0);
  FillChar(PixelIndices, SizeOf(PixelIndices), 0);
  FVt369SpriteHit := -1;
  var Interleaved := (FOneBus.Vt369VideoControl($50) and 1) <> 0;
  var WideNameRows := FOneBus.HasVt369PhoneLcd and
    (FOneBus.Vt369VideoControl($1C) = $12) and (FOneBus.Vt369VideoControl($1D) = $09) and
    (FOneBus.Vt369VideoControl($1E) = $0F) and ((FOneBus.Vt369VideoControl($20) and $10) <> 0) and
    (FOneBus.Vt369VideoControl($22) = 8);
  if (FMask and 8) <> 0 then
  begin
    var V := FV;
    var FineY := (V shr 12) and 7;
    var MinX := 8 * Ord((FMask and 2) = 0);
    var RightTable := (FCtrl and $10) <> 0;
    var TilePixels: TVt369TileRow;
    for var TileColumn := 0 to (NES_WIDTH - 1 + FFineX) div 8 do
    begin
      var Left := 8 * TileColumn - FFineX;
      if Left + 7 >= MinX then
      begin
        var Tile, Attribute: Byte;
        if WideNameRows then
        begin
          var Row := (((V shr 5) and 31) + 30 * Ord((V and $800) <> 0)) and 31;
          var Index := (Row shl 6) or ((V and 31) shl 1);
          Tile := ReadVt369NameTable(Index);
          Attribute := ReadVt369NameTable(Index + 1);
        end
        else if Interleaved then
        begin
          Tile := ReadVt369NameTable((V shl 1) and $FFF);
          Attribute := ReadVt369NameTable(((V shl 1) or 1) and $FFF);
        end
        else
        begin
          Tile := ReadVt369NameTable(V);
          Attribute := ReadVt369NameTable($3C0 or (V and $C00) or ((V shr 4) and $38) or ((V shr 2) and 7));
          Attribute := (Attribute shr (((V shr 4) and 4) or (V and 2))) and 3;
        end;
        FOneBus.ReadVt369BackgroundRow(Tile, Attribute, FineY, RightTable, TilePixels);
        for var Column := 0 to 7 do
        begin
          var X := Left + Column;
          if (X >= MinX) and (X < NES_WIDTH) then
          begin
            Bg[X] := TilePixels[Column];
            PixelIndices[X] := TilePixels[Column];
          end;
        end;
      end;
      if (V and $1F) = $1F then
        V := (V and not $1F) xor $400
      else
        Inc(V);
    end;
  end;
  if (FMask and $10) <> 0 then
  begin
    var SpriteMode := FOneBus.Vt369VideoControl($1D);
    var Extended := FOneBus.Vt369VideoControl($1E);
    var Encoding := FOneBus.Vt369VideoControl($1C);
    var Height := 8 + 8 * Ord(((SpriteMode and 4) <> 0) or ((FCtrl and $20) <> 0));
    var Width := 8 + 8 * Ord((SpriteMode and 2) <> 0);
    for var i := 63 + 64 * Ord((SpriteMode and 1) <> 0) downto 0 do
    begin
      var X, Y, Tile, Attr: Integer;
      if (Extended and 4) <> 0 then
      begin
        Y := Vt369OamByte(i);
        Tile := Vt369OamByte($80 + i);
        Attr := Vt369OamByte($100 + i);
        X := Vt369OamByte($180 + i);
      end
      else
      begin
        Y := Vt369OamByte(i * 4);
        Tile := Vt369OamByte(i * 4 + 1);
        Attr := Vt369OamByte(i * 4 + 2);
        X := Vt369OamByte(i * 4 + 3);
      end;
      var SignedCoords := (SpriteMode and 8) <> 0;
      if SignedCoords then
      begin
        Dec(X, 256 * Ord((Attr and $40) <> 0));
        Dec(Y, 256 * Ord((Attr and $80) <> 0));
      end;
      var Row := FScanline - Y - 1;
      if (Row < 0) or (Row >= Height) then
        Continue;
      if not SignedCoords and ((Attr and $80) <> 0) then
        Row := Height - 1 - Row;
      if (Encoding and $80) = 0 then
        Tile := Tile or ((Attr shl 6) and $700);
      var RightTable := (FCtrl and 8) <> 0;
      if (FCtrl and $20) <> 0 then
      begin
        RightTable := Odd(Tile);
        Tile := Tile and not 1;
      end;
      var Palette := (Attr and 3) shl 4;
      if SignedCoords then
        Palette := Palette or ((Attr shl 1) and $40);
      for var Column := 0 to Width - 1 do
      begin
        var Dest := X + Column;
        if (Dest < 0) or (Dest >= NES_WIDTH) or ((Dest < 8) and ((FMask and 4) = 0)) then
          Continue;
        var Source := Column;
        if not SignedCoords and ((Attr and $40) <> 0) then
          Source := Width - 1 - Source;
        var Pixel := FOneBus.Vt369SpritePixel(Tile, Row, Source, Palette, RightTable);
        if Pixel = 0 then
          Continue;
        if (i = 0) and (Bg[Dest] <> 0) and (Dest < 255) and (FVt369SpriteHit < 0) then
          FVt369SpriteHit := Dest + 2;
        if SignedCoords or ((Attr and $20) = 0) or (Bg[Dest] = 0) then
          PixelIndices[Dest] := $100 or Pixel
        else
          PixelIndices[Dest] := Bg[Dest];
      end;
    end;
  end;
  for var X := 0 to NES_WIDTH - 1 do
    FDrawingFrame[X, FScanline] := FVt369Colors[PixelIndices[X]];
end;

procedure TPPU.CopyLowResolutionLineToWide(Line: Integer);
begin
  var Offset := 2 * Line * VT389_WIDTH;
  for var X := 0 to NES_WIDTH - 1 do
  begin
    var Pixel := FDrawingFrame[X, Line];
    FWideDrawing[Offset + 2 * X] := Pixel;
    FWideDrawing[Offset + 2 * X + 1] := Pixel;
  end;
  Move(FWideDrawing[Offset], FWideDrawing[Offset + VT389_WIDTH], VT389_WIDTH * SizeOf(Cardinal));
end;

procedure TPPU.RenderVt389Line;
begin
  if not FWideDrawingUsed then
  begin
    for var Line := 0 to FScanline - 1 do
      CopyLowResolutionLineToWide(Line);
    FWideDrawingUsed := True;
  end;

  var Background: array[0..2 * VT389_WIDTH - 1] of Byte;
  var Indices: array[0..2 * VT389_WIDTH - 1] of Word;
  FillChar(Background, SizeOf(Background), 0);
  FillChar(Indices, SizeOf(Indices), 0);
  FVt369SpriteHit := -1;
  if (FMask and 8) <> 0 then
  begin
    // The two preceding nametable fetches advanced horizontal VRAM before dot 1.
    var CoarseX := (((FV shr 5) and $20) or (FV and $1F)) - 2;
    var V := (FV and not $041F) or ((CoarseX and $20) shl 5) or (CoarseX and $1F);
    var Interleaved := Odd(FOneBus.Vt369VideoControl($50));
    var SmallBanks := (FOneBus.Vt369VideoControl($1C) and 8) <> 0;
    var MinX := 16 * Ord((FMask and 2) = 0);
    var TilePixels: TVt389TileRow;
    for var TileColumn := 0 to 32 do
    begin
      var Tile, Attribute: Byte;
      if Interleaved then
      begin
        Tile := ReadVt369NameTable((V shl 1) and $FFF);
        Attribute := ReadVt369NameTable(((V shl 1) or 1) and $FFF);
      end
      else
      begin
        Tile := ReadVt369NameTable(V);
        Attribute := 0;
        if not SmallBanks then
        begin
          Attribute := ReadVt369NameTable($3C0 or (V and $C00) or ((V shr 4) and $38) or ((V shr 2) and 7));
          Attribute := (Attribute shr (((V shr 4) and 4) or (V and 2))) and 3;
        end;
      end;
      FOneBus.ReadVt389BackgroundRow(Tile, Attribute, (V shr 12) and 7, (FCtrl and $10) <> 0, TilePixels);
      for var X := 0 to 15 do
      begin
        var Dest := 16 * TileColumn - 2 * FFineX + X;
        if (Dest >= MinX) and (Dest < VT389_WIDTH) then
        begin
          Background[Dest] := TilePixels[X];
          Background[Dest + VT389_WIDTH] := TilePixels[X + 16];
          Indices[Dest] := TilePixels[X];
          Indices[Dest + VT389_WIDTH] := TilePixels[X + 16];
        end;
      end;
      if (V and $1F) = $1F then
        V := (V and not $1F) xor $400
      else
        Inc(V);
    end;
  end;

  if (FMask and $10) <> 0 then
  begin
    var SpriteMode := FOneBus.Vt369VideoControl($1D);
    var SpriteMax := 63 + 64 * Ord(Odd(SpriteMode) and not FVt389ExtendedOam);
    var SignedCoords := (SpriteMode and 8) <> 0;
    var MinX := 16 * Ord((FMask and 4) = 0);
    for var i := SpriteMax downto 0 do
    begin
      var X, Y, Tile, Attr, Width, Height, Palette: Integer;
      var Packed4, FlipX, FlipY, Behind: Boolean;
      if FVt389ExtendedOam then
      begin
        var Base := 8 * i;
        var Size := Vt369OamByte(Base + 3);
        Y := Vt369OamByte(Base);
        Tile := Vt369OamByte(Base + 1) or (Integer(Vt369OamByte(Base + 2)) shl 8);
        X := Vt369OamByte(Base + 7);
        Attr := Vt369OamByte(Base + 6);
        Width := 8 shl ((Size shr 4) and 3);
        Height := 8 shl ((Size shr 2) and 3);
        Packed4 := (Size and $80) = 0;
        Palette := (Attr and 15) shl 4;
        FlipX := (Attr and $40) <> 0;
        FlipY := (Attr and $80) <> 0;
        Behind := False;
      end
      else
      begin
        if Odd(SpriteMode) then
        begin
          Y := Vt369OamByte(i);
          Tile := Vt369OamByte($80 + i);
          Attr := Vt369OamByte($100 + i);
          X := Vt369OamByte($180 + i);
        end
        else
        begin
          Y := Vt369OamByte(i * 4);
          Tile := Vt369OamByte(i * 4 + 1);
          Attr := Vt369OamByte(i * 4 + 2);
          X := Vt369OamByte(i * 4 + 3);
        end;
        Tile := Tile or ((Attr shl 6) and $700);
        Width := 16;
        Height := 16;
        if ((SpriteMode and 4) <> 0) or ((FCtrl and $20) <> 0) then
        begin
          Height := 32;
          Tile := Tile shr 1;
        end;
        Packed4 := (FOneBus.Vt369VideoControl($1C) and $10) <> 0;
        Palette := (Attr and 3) shl 4;
        if SignedCoords then
        begin
          Dec(X, 256 * Ord((Attr and $40) <> 0));
          Dec(Y, 256 * Ord((Attr and $80) <> 0));
          Palette := Palette or ((Attr shl 1) and $40);
        end;
        FlipX := not SignedCoords and ((Attr and $40) <> 0);
        FlipY := not SignedCoords and ((Attr and $80) <> 0);
        Behind := not SignedCoords and ((Attr and $20) <> 0);
      end;

      var Row := 2 * (FScanline - Y - Ord(Odd(SpriteMode) and not FVt389ExtendedOam));
      if (Row < 0) or (Row >= Height) then
        Continue;
      for var Subline := 0 to 1 do
      begin
        var SourceY := Row + Subline;
        if FlipY then
          SourceY := Height - 1 - SourceY;
        for var Column := 0 to Width - 1 do
        begin
          var Dest := 2 * X + Column;
          if (Dest < MinX) or (Dest >= VT389_WIDTH) then
            Continue;
          var SourceX := Column;
          if FlipX then
            SourceX := Width - 1 - SourceX;
          var Pixel := FOneBus.Vt389SpritePixel(Tile, Width, Height, SourceY, SourceX, Palette, Packed4);
          if Pixel = 0 then
            Continue;
          var Index := Dest + Subline * VT389_WIDTH;
          if (i = 0) and (Background[Index] <> 0) and (Dest < VT389_WIDTH - 2) and
            ((FVt369SpriteHit < 0) or (Dest div 2 + 2 < FVt369SpriteHit)) then
            FVt369SpriteHit := Dest div 2 + 2;
          if not Behind or (Background[Index] = 0) then
            Indices[Index] := $100 or Pixel
          else
            Indices[Index] := Background[Index];
        end;
      end;
    end;
  end;

  var Offset := 2 * FScanline * VT389_WIDTH;
  for var X := 0 to High(Indices) do
    FWideDrawing[Offset + X] := FVt369Colors[Indices[X]];
  for var X := 0 to NES_WIDTH - 1 do
    FDrawingFrame[X, FScanline] := FWideDrawing[Offset + 2 * X];
end;

procedure TPPU.RenderScanline;
begin
  var BgPixel: UInt8;
  var BgPalette: UInt8;
  var SprPixel: UInt8;
  var SprPalette: UInt8;
  var PriorityBehindBg: Boolean;
  var SpriteZero: Boolean;
  var FinalPaletteAddress: UInt8;
  var SavedCtrl: UInt8;
  var SavedFineX: UInt8;
  if (FOneBus <> nil) and FOneBus.Vt369WidePalette then
  begin
    RenderVt369Line;
    Exit;
  end;
  // Preserve mapper banks, mirroring and palette changes made by raster IRQs.
  // Rendering remains scanline-granular, not a pixel-fetch pipeline.
  var SavedV: UInt16 := FRenderV;
  SavedCtrl := FRenderCtrl;
  var SavedMask: UInt8 := FRenderMask;
  SavedFineX := FRenderFineX;
  FRenderV := FV;
  FRenderCtrl := FCtrl;
  FRenderMask := FMask;
  FRenderFineX := FFineX;
  FRenderingLine := True;
  // CPU/register writes cannot interleave with this synchronous scanline.
  // Keep per-pixel reads for boards with mapper latches or fetch-dependent data.
  FCacheBackground := (FMapper <> nil) and FMapper.AllowsPpuReadCaching;
  FBackgroundTileX := -1;
  FillChar(FSpriteRowCached, SizeOf(FSpriteRowCached), 0);
  // Palette reads have no mapper callbacks. Freeze the 32 ARGB entries for
  // this synchronous line, preserving universal-color aliases and grayscale.
  var Colors: array[0..127] of UInt32;
  var ColorMask: UInt8 := $3F;
  if (FRenderMask and 1) <> 0 then
    ColorMask := $30;
  var LastColor := 31;
  if (FOneBus <> nil) and FOneBus.HasEnhancedVideo then
    LastColor := 127;
  for var i := 0 to LastColor do
  begin
    var ColorIndex := PpuReadMemory($3F00 + i) and ColorMask;
    // VS boards keep their board-specific scrambled palette.
    if (FOneBus <> nil) and FOneBus.ExtendedPalette then
    begin
      var Hi := FOneBusPalette[OneBusPaletteIndex(i or $80)] and $3F;
      if FOneBus.HasVt369 then
        Colors[i] := Vt369Rgb555((Integer(FOneBusPalette[OneBusPaletteIndex(i or $80)]) shl 8) or
            PpuReadMemory($3F00 + i))
      else
        Colors[i] := FOneBusColors[(Hi shl 6) or ColorIndex];
    end
    else if FUseVs2C04DPalette then
      Colors[i] := NES_VS_2C04D_PALETTE[ColorIndex]
    else if Length(FCustomPalette) = 512 then
      Colors[i] := FCustomPalette[((FRenderMask and $E0) shl 1) or ColorIndex]
    else if Length(FCustomPalette) = 64 then
      Colors[i] := FCustomPalette[ColorIndex]
    else
      Colors[i] := NES_PALETTE[ColorIndex];
  end;
  var Y: Integer := FScanline;

  // Presentation enhancements do not change OAM evaluation, overflow, sprite
  // zero hits or timed mapper bus fetches in the hardware pipeline.
  FLineSpriteCount := 0;
  if (FRenderMask and $10) <> 0 then
  begin
    var SpriteHeight: Integer := 8;
    if (FRenderCtrl and $20) <> 0 then
      SpriteHeight := 16;
    for var i := 0 to 63 do
      if (Y > FOam[i * 4]) and (Y <= Integer(FOam[i * 4]) + SpriteHeight) then
      begin
        FLineSprites[FLineSpriteCount] := i;
        Inc(FLineSpriteCount);
        if (FLineSpriteCount = 8) and not FRemoveSpriteLimit then
          Break;
      end;
  end;
  var BatchSprites := FCacheBackground and not FMapperHasRenderCallbacks;
  var SpritePixels: TSpriteLinePixels;
  try
    if BatchSprites then
      BuildSpriteLine(SpritePixels);
    var BackgroundPixelsLeft := 0;
    for var X := 0 to NES_WIDTH - 1 do
    begin
      if BackgroundPixelsLeft > 0 then
      begin
        // Only passive boards enter this path. Their fetched pattern and
        // palette remain fixed until the end of this eight-pixel tile.
        var Shift := BackgroundPixelsLeft - 1;
        BgPixel := (((FBackgroundHigh shr Shift) and 1) shl 1) or
          ((FBackgroundLow shr Shift) and 1);
        BgPalette := FBackgroundPalette;
        Dec(BackgroundPixelsLeft);
      end
      else
      begin
        BgPixel := SampleBackgroundPixel(X, Y, BgPalette);
        if FCacheBackground and (FBackgroundTileX >= 0) then
          BackgroundPixelsLeft := 7 - ((X + FRenderFineX) and 7);
      end;
      if BatchSprites then
      begin
        var Sprite := SpritePixels[X];
        SprPixel := Sprite and 3;
        SprPalette := (Sprite shr 2) and 7;
        PriorityBehindBg := (Sprite and $20) <> 0;
      end
      else
        SprPixel := SampleSpritePixel(X, Y, SprPalette, PriorityBehindBg, SpriteZero);
      if (BgPixel = 0) and (SprPixel = 0) then
        FinalPaletteAddress := 0
      else if (BgPixel = 0) and (SprPixel <> 0) then
        FinalPaletteAddress := ScanlinePaletteIndex(SprPalette, SprPixel)
      else if (BgPixel <> 0) and (SprPixel = 0) then
        FinalPaletteAddress := ScanlinePaletteIndex(BgPalette, BgPixel)
      else if PriorityBehindBg then
        FinalPaletteAddress := ScanlinePaletteIndex(BgPalette, BgPixel)
      else
        FinalPaletteAddress := ScanlinePaletteIndex(SprPalette, SprPixel);
      FDrawingFrame[X, Y] := Colors[FinalPaletteAddress];
    end;
  finally
    FCacheBackground := False;
    FRenderingLine := False;
    FRenderV := SavedV;
    FRenderCtrl := SavedCtrl;
    FRenderMask := SavedMask;
    FRenderFineX := SavedFineX;
  end;
end;

procedure TPPU.RebuildFrame;
begin
  // The completed image was published at the frame boundary by Clock.
  FSplitActive := False;
  FSplitY := 240;
end;

function TPPU.DebugReadMemory(Address: UInt16): UInt8;
begin
  Result := PpuReadMemory(Address, False, False, True);
end;

function TPPU.DebugMask: UInt8;
begin
  Result := FMask;
end;

function TPPU.DebugCtrl: UInt8;
begin
  Result := FCtrl;
end;

function TPPU.DebugStatus: UInt8;
begin
  Result := FStatus;
end;

function TPPU.DebugV: UInt16;
begin
  Result := FV;
end;

function TPPU.DebugT: UInt16;
begin
  Result := FT;
end;

function TPPU.DebugBackgroundPixel(X, Y: Integer): UInt8;
begin
  var P: UInt8;
  Result := SampleBackgroundPixel(X, Y, P, True);
end;

function TPPU.DebugOam(Index: Integer): UInt8;
begin
  Result := FOam[Index and $FF];
end;

function TPPU.DebugSprite0HitX: Integer;
begin
  Result := FSprite0HitX;
end;

function TPPU.DebugSprite0HitY: Integer;
begin
  Result := FSprite0HitY;
end;

function TPPU.DebugSplitActive: Boolean;
begin
  Result := FSplitActive;
end;

function TPPU.DebugSplitY: Integer;
begin
  Result := FSplitY;
end;

end.

