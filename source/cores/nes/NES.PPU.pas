unit NES.PPU;

interface

uses
  NES.State, NES.Types, NES.Consts, NES.Mapper;

type
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

  TPPU = class
  private
    FRegion: TNesRegion;
    FUseVs2C04DPalette: Boolean;
    FPreRenderLine: Integer;
    FMapper: TMapper;
    FNameTable: array[0..4095] of UInt8;
    FPaletteRam: array[0..31] of UInt8;
    FOam: array[0..255] of UInt8;
    FLineSprites: array[0..63] of UInt8;
    FLineSpriteCount: Integer;
    FFrame: TFrameBuffer;
    FDrawingFrame: TFrameBuffer;
    FZapperMask: TNesZapperMask;
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
    FMapperHasPpuClock: Boolean;
    FCacheBackground: Boolean;
    FBackgroundTileX: Integer;
    FBackgroundLow, FBackgroundHigh, FBackgroundPalette: UInt8;
    FMapperSpriteScanline: Integer;
    FMapperSpriteAddresses: array[0..7] of UInt16;
    FMapperSpriteAddressValid: Boolean;
    procedure ClockMapperAddress;
    procedure RefreshOpenBus(Value, Mask: UInt8);
    procedure ClockOam;
    procedure ClockPixels;
    procedure ClockMemory;
    procedure IncrementX;
    procedure IncrementY;
    procedure IncrementDataAddress;
    procedure CopyX;
    procedure CopyY;
    function MirrorNameTableAddress(Address: UInt16): UInt16;
    function PpuReadMemory(Address: UInt16): UInt8;
    procedure PpuWriteMemory(Address: UInt16; Value: UInt8);
    procedure SetVblank(Value: Boolean);
    procedure UpdateNmiState;
    function VblankStartLine: Integer;
    procedure CaptureSplitState;
    function SampleBackgroundPixel(X, Y: Integer; out PaletteIndex: UInt8): UInt8;
    function SampleSpritePixel(X, Y: Integer; out PaletteIndex: UInt8; out PriorityBehindBg: Boolean; out IsSpriteZero: Boolean): UInt8;
    procedure RenderScanline;
  public
    procedure SerializeState(State: TNesStateArchive);
    constructor Create;
    // Select timing before running; resets PPU state.
    procedure SetRegion(Value: TNesRegion);
    procedure ConnectMapper(AMapper: TMapper);
    property UseVs2C04DPalette: Boolean read FUseVs2C04DPalette write FUseVs2C04DPalette;
    procedure Reset;
    procedure Clock;
    function CpuRead(Address: UInt16): UInt8;
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    procedure WriteOamDma(Index: Integer; Value: UInt8);
    function ConsumeNmi: Boolean;
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
    property Cycle: Integer read FCycle;
    property Scanline: Integer read FScanline;
  end;

implementation

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
end;

constructor TPPU.Create;
begin
  inherited Create;
  SetRegion(TNesRegion.NTSC);
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
  // Cache callback presence once; plain cartridges need no timed mapper fetches.
  FMapperHasPpuClock := (AMapper <> nil) and AMapper.HasPpuClockCallbacks;
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
  FV := (FV and not UInt16($7BE0)) or (FT and $7BE0);
end;

function TPPU.MirrorNameTableAddress(Address: UInt16): UInt16;
begin
  var Index: UInt16 := (Address - $2000) and $0FFF;
  var TableIndex: UInt16 := Index shr 10;
  if FMapper = nil then
    Exit(Index and $07FF);

  case FMapper.GetMirrorMode of
    TMirrorMode.Vertical:
      case TableIndex of
        0, 2:
          Result := Index and $03FF;
      else
        Result := $0400 + (Index and $03FF);
      end;
    TMirrorMode.Horizontal:
      case TableIndex of
        0, 1:
          Result := Index and $03FF;
      else
        Result := $0400 + (Index and $03FF);
      end;
    TMirrorMode.Single0:
      Result := Index and $03FF;
    TMirrorMode.Single1:
      Result := $0400 + (Index and $03FF);
    TMirrorMode.FourScreen:
      Result := Index;
  else
    Result := Index and $07FF;
  end;
end;

function TPPU.PpuReadMemory(Address: UInt16): UInt8;
begin
  var Temp: UInt8;
  Address := Address and $3FFF;
  if (Address < $3F00) and (FMapper <> nil) and FMapper.PpuRead(Address, Temp) then
    Exit(Temp);
  if Address < $2000 then
  begin
    Exit(0);
  end;
  if Address < $3F00 then
    Exit(FNameTable[MirrorNameTableAddress(Address)]);

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

procedure TPPU.PpuWriteMemory(Address: UInt16; Value: UInt8);
begin
  Address := Address and $3FFF;
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
  if not FMapperHasPpuClock then
    Exit;
  if (FMask and $18) = 0 then
  begin
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
      Address := (UInt16(FCtrl and $10) shl 8) or
        (UInt16(FFetchTile) shl 4) or ((FV shr 12) and 7) or ((Phase and 2) shl 2);
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
            Address := (UInt16(Tile and 1) shl 12) or (UInt16(Tile and $FE) shl 4) or
              ((Row and 8) shl 1) or (Row and 7)
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
  FMapper.ClockPpuAddress(Address, FPpuClock);
  if ((FCycle and 1) <> 0) and (FCycle <= 339) then
    FMapper.ClockPpuRead;
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
  var Address: UInt16 := FV and $3FFF;
  if Fetch then
  begin
    Address := $2000 or (FV and $0FFF);
    if Background and (FCycle <= 336) then
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
      if Height = 16 then
        Address := (UInt16(Tile and 1) shl 12) or (UInt16(Tile and $FE) shl 4) or ((Row and 8) shl 1) or (Row and 7)
      else
        Address := (UInt16(FCtrl and 8) shl 9) or (UInt16(Tile) shl 4) or (Row and 7);
      Address := Address or ((Phase and 2) shl 2);
    end;
  end;
  var Ale := AddressRequest or (Fetch and ((FCycle and 1) <> 0));
  var ReadLine := ReadRequest or (Fetch and ((FCycle and 1) = 0));

  // Simultaneous ALE/read feeds data back into the address latch.
  // Preserve the stable digital case; analogue oscillation is not modeled.
  if Ale then
    if ReadLine then
      FPixel.AddressLatch := FPixel.DataBus
    else
      FPixel.AddressLatch := Address and $FF;
  FPixel.AddressBus := (Address and $3F00) or FPixel.AddressLatch;
  if ReadLine then
  begin
    var BusAddress := FPixel.AddressBus;
    // Palette RAM is internal; its read buffer comes from nametable RAM.
    if BusAddress >= $3F00 then
      Dec(BusAddress, $1000);
    FPixel.DataBus := PpuReadMemory(BusAddress);
    if ReadRequest then
      FDataBuffer := FPixel.DataBus;
    if Fetch and ((FCycle and 1) = 0) then
    begin
      if Background then
        case Phase of
          1:
            FFetchTile := FPixel.DataBus;
          3:
            FPixel.Attribute := (FPixel.DataBus shr (((FV shr 4) and 4) or (FV and 2))) and 3;
          5:
            FPixel.NextLow := FPixel.DataBus;
          7:
            FPixel.NextHigh := FPixel.DataBus;
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
    if FCycle <= 1 then
      Dec(LastLine);
    for var Age := 0 to LIGHT_SCANLINES - 1 do
    begin
      var Y := (LastLine - Age + FPreRenderLine + 1) mod (FPreRenderLine + 1);
      if Y >= NES_HEIGHT then
        Continue;

      for var X := 0 to NES_WIDTH - 1 do
      begin
        var Color := FDrawingFrame[X, Y];
        var Luma := (299 * Integer((Color shr 16) and $FF) +
          587 * Integer((Color shr 8) and $FF) + 114 * Integer(Color and $FF)) div 1000;
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
      if (FOamAddress and 3) = 2 then
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

procedure TPPU.ClockPixels;
begin
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
    var Background: UInt8 := 0;
    if ((FMask and $08) <> 0) and ((X >= 8) or ((FMask and 2) <> 0)) then
      Background := ((FPixel.Low shr (15 - FFineX)) and 1) or
        (((FPixel.High shr (15 - FFineX)) and 1) shl 1);
    for var i := 0 to 7 do
    begin
      var OutputSprite := ((FPixel.Counting and (1 shl i)) = 0) or
        ((X = 0) and FPixel.DotSkipped);
      if (FPixel.Counting and (1 shl i)) <> 0 then
      begin
        if FPixel.SpriteX[i] > 0 then
          Dec(FPixel.SpriteX[i]);
        if FPixel.SpriteX[i] = 0 then
          FPixel.Counting := FPixel.Counting and not (1 shl i);
      end;
      if OutputSprite and Rendering then
      begin
        var SpritePixel: UInt8;
        if (FPixel.SpriteAttr[i] and $40) <> 0 then
        begin
          SpritePixel := (FPixel.SpriteLow[i] and 1) or ((FPixel.SpriteHigh[i] and 1) shl 1);
          FPixel.SpriteLow[i] := FPixel.SpriteLow[i] shr 1;
          FPixel.SpriteHigh[i] := FPixel.SpriteHigh[i] shr 1;
        end
        else
        begin
          SpritePixel := ((FPixel.SpriteLow[i] shr 7) and 1) or ((FPixel.SpriteHigh[i] shr 6) and 2);
          FPixel.SpriteLow[i] := (FPixel.SpriteLow[i] shl 1) and $FF;
          FPixel.SpriteHigh[i] := (FPixel.SpriteHigh[i] shl 1) and $FF;
        end;
        if (Background <> 0) and (SpritePixel <> 0) and FPixel.SpriteZero[i] and
          ((FMask and $10) <> 0) and ((X >= 8) or ((FMask and 4) <> 0)) and
          (X <> 255) and ((FStatus and $40) = 0) then
        begin
          FPixel.HitPending := True;
          FSprite0HitX := X;
          FSprite0HitY := FScanline;
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
    if (FCycle and 7) = 0 then
    begin
      FPixel.Low := (FPixel.Low and $FF00) or FPixel.NextLow;
      FPixel.High := (FPixel.High and $FF00) or FPixel.NextHigh;
      FPixel.AttrLow := (FPixel.AttrLow and $FF00) or (Ord((FPixel.Attribute and 1) <> 0) * $FF);
      FPixel.AttrHigh := (FPixel.AttrHigh and $FF00) or (Ord((FPixel.Attribute and 2) <> 0) * $FF);
    end;
  end;
  if (FCycle >= 257) and (FCycle <= 320) then
  begin
    var i := (FCycle - 257) div 8;
    var Phase := (FCycle - 257) and 7;
    if Phase = 0 then
    begin
      FPixel.SpriteZero[i] := (i = 0) and FOamEval.ZeroAdded;
    end;
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

  if FCycle = 1 then
    FZapperMaskValid := False;
  ClockMapperAddress;

  Inc(FPpuClock);
  if RenderingEnabled and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
    ClockOam;
  ClockMemory;
  ClockPixels;

  if (FCycle = 1) and (FMapper <> nil) then
    FMapper.ClockScanline(FScanline, RenderingEnabled);
  if (FScanline < 240) and (FCycle = 1) then
    RenderScanline;

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
      if (((FCycle >= 1) and (FCycle <= 256)) or ((FCycle >= 321) and (FCycle <= 336))) and (((FCycle - 1) mod 8) = 7) then
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
        VramAddress := FV and $3FFF;
        var TimedRead := ((FPixel.Mask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine));
        if VramAddress < $3F00 then
        begin
          Result := FDataBuffer;
          DrivenMask := $FF;
          if not TimedRead then
            FDataBuffer := PpuReadMemory(VramAddress);
        end
        else
        begin
          Result := (PpuReadMemory(VramAddress) and $3F) or (FOpenBus and $C0);
          DrivenMask := $3F;
          if (FMask and 1) <> 0 then
            Result := Result and $F0;
          if not TimedRead then
            FDataBuffer := PpuReadMemory(VramAddress - $1000);
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
        if ((FMask and $18) <> 0) and ((FScanline < 240) or (FScanline = FPreRenderLine)) then
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
        if not FAddrLatch then
        begin
          FT := (FT and $00FF) or (UInt16(Value and $3F) shl 8);
          FAddrLatch := True;
        end
        else
        begin
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

function TPPU.ConsumeNmi: Boolean;
begin
  Result := FNmiPending;
  FNmiPending := False;
end;

function TPPU.SampleBackgroundPixel(X, Y: Integer; out PaletteIndex: UInt8): UInt8;
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
  var ScrollY: Integer := (((Integer(RenderV shr 5)) and $1F) shl 3) or ((RenderV shr 12) and 7);
  // PPUCTRL writes t's nametable bits, but PPUADDR and scrolling can change
  // them independently. Fetches must use the captured VRAM address, including
  // the nametable toggle from the two pre-render tile fetches above.
  var BaseNameTable: Integer := (RenderV shr 10) and 3;

  var WorldX: Integer := (X + ScrollX) mod 512;
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

  if FRenderingLine and FCacheBackground and (FBackgroundTileX = (WorldX shr 3)) then
  begin
    PaletteIndex := FBackgroundPalette;
    var Shift := 7 - (LocalX and 7);
    Exit((((FBackgroundHigh shr Shift) and 1) shl 1) or ((FBackgroundLow shr Shift) and 1));
  end;

  var NameAddress: UInt16 := $2000 + UInt16(Table) * $0400 + UInt16((LocalY div 8) * 32 + (LocalX div 8));
  var TileIndex: UInt8 := PpuReadMemory(NameAddress);
  var AttributeAddress: UInt16 := $23C0 + UInt16(Table) * $0400 + UInt16((LocalY div 32) * 8 + (LocalX div 32));
  var AttributeByte: UInt8 := PpuReadMemory(AttributeAddress);
  if (LocalY and $10) <> 0 then
    AttributeByte := AttributeByte shr 4;
  if (LocalX and $10) <> 0 then
    AttributeByte := AttributeByte shr 2;
  PaletteIndex := AttributeByte and 3;

  var FineY: UInt8 := LocalY and 7;
  var PatternBase: UInt16 := UInt16((RenderCtrl and $10) shr 4) shl 12;
  var Lo: UInt8 := PpuReadMemory(PatternBase + UInt16(TileIndex) * 16 + FineY);
  var Hi: UInt8 := PpuReadMemory(PatternBase + UInt16(TileIndex) * 16 + FineY + 8);
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
    SpriteY := FOam[i * 4 + 0];
    TileIndex := FOam[i * 4 + 1];
    Attributes := FOam[i * 4 + 2];
    SpriteX := FOam[i * 4 + 3];
    SpriteTop := SpriteY + 1;

    if (X < SpriteX) or (X >= SpriteX + 8) then
      Continue;

    Row := Y - SpriteTop;
    Column := X - SpriteX;
    if (Attributes and $80) <> 0 then
      Row := SpriteHeight - 1 - Row;
    if (Attributes and $40) <> 0 then
      Column := 7 - Column;

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
    Lo := PpuReadMemory(Address);
    Hi := PpuReadMemory(Address + 8);
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
  var Y: Integer := FScanline;
  // OAM and control registers cannot change during this synchronous render.
  // Preserve the existing unlimited-sprite behavior (do not impose an 8 limit).
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
      end;
  end;
  try
    for var X := 0 to NES_WIDTH - 1 do
    begin
      BgPixel := SampleBackgroundPixel(X, Y, BgPalette);
      SprPixel := SampleSpritePixel(X, Y, SprPalette, PriorityBehindBg, SpriteZero);
      if (BgPixel = 0) and (SprPixel = 0) then
        FinalPaletteAddress := 0
      else if (BgPixel = 0) and (SprPixel <> 0) then
        FinalPaletteAddress := (SprPalette shl 2) or SprPixel
      else if (BgPixel <> 0) and (SprPixel = 0) then
        FinalPaletteAddress := (BgPalette shl 2) or BgPixel
      else if PriorityBehindBg then
        FinalPaletteAddress := (BgPalette shl 2) or BgPixel
      else
        FinalPaletteAddress := (SprPalette shl 2) or SprPixel;
      var ColorIndex := PpuReadMemory($3F00 + FinalPaletteAddress) and $3F;
      if FUseVs2C04DPalette then
        FDrawingFrame[X, Y] := NES_VS_2C04D_PALETTE[ColorIndex]
      else
        FDrawingFrame[X, Y] := NES_PALETTE[ColorIndex];
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
  Result := PpuReadMemory(Address);
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
  Result := SampleBackgroundPixel(X, Y, P);
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

