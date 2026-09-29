unit NES.PPU;

interface

uses
  NES.State, NES.Types, NES.Consts, NES.Mapper;

type
  TPpu = class
  private
    FRegion: TNesRegion;
    FPreRenderLine: Integer;
    FMapper: TMapper;
    FNameTable: array[0..4095] of UInt8;
    FPaletteRam: array[0..31] of UInt8;
    FOam: array[0..255] of UInt8;
    FLineSprites: array[0..63] of UInt8;
    FLineSpriteCount: Integer;
    FFrame: TFrameBuffer;
    FDrawingFrame: TFrameBuffer;
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
    procedure ClockMapperAddress;
    procedure IncrementX;
    procedure IncrementY;
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
    procedure Reset;
    procedure Clock;
    function CpuRead(Address: UInt16): UInt8;
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    procedure WriteOamDma(Index: Integer; Value: UInt8);
    function ConsumeNmi: Boolean;
    procedure RebuildFrame;
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

procedure TPpu.SerializeState(State: TNesStateArchive);
begin
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
end;

constructor TPpu.Create;
begin
  inherited Create;
  SetRegion(TNesRegion.NTSC);
end;

procedure TPpu.SetRegion(Value: TNesRegion);
begin
  FRegion := Value;
  if Value in [TNesRegion.PAL, TNesRegion.Dendy] then
    FPreRenderLine := 311
  else
    FPreRenderLine := 261;
  Reset;
end;

function TPpu.VblankStartLine: Integer;
begin
  if FRegion = TNesRegion.Dendy then
    Result := 291
  else
    Result := 241;
end;

procedure TPpu.ConnectMapper(AMapper: TMapper);
begin
  FMapper := AMapper;
end;

procedure TPpu.Reset;
begin
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
  for var i := Low(FNameTable) to High(FNameTable) do
    FNameTable[i] := 0;
  for var i := Low(FPaletteRam) to High(FPaletteRam) do
    FPaletteRam[i] := 0;
  for var i := Low(FOam) to High(FOam) do
    FOam[i] := 0;
end;

procedure TPpu.IncrementX;
begin
  if (FV and $001F) = 31 then
  begin
    FV := FV and not UInt16($001F);
    FV := FV xor $0400;
  end
  else
    FV := (FV + 1) and $7FFF;
end;

procedure TPpu.IncrementY;
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

procedure TPpu.CopyX;
begin
  FV := (FV and not UInt16($041F)) or (FT and $041F);
end;

procedure TPpu.CopyY;
begin
  FV := (FV and not UInt16($7BE0)) or (FT and $7BE0);
end;

function TPpu.MirrorNameTableAddress(Address: UInt16): UInt16;
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

function TPpu.PpuReadMemory(Address: UInt16): UInt8;
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

procedure TPpu.PpuWriteMemory(Address: UInt16; Value: UInt8);
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

procedure TPpu.UpdateNmiState;
begin
  var NewLine: Boolean := FNmiOccurred and ((FCtrl and $80) <> 0);
  if NewLine and not FNmiLine then
    FNmiDelay := 8
  else if not NewLine then
  begin
    if (FNmiDelay > 0) and (FNmiDelay <= 6) then
      FNmiPending := True;
    FNmiDelay := 0;
  end;
  FNmiLine := NewLine;
end;

procedure TPpu.CaptureSplitState;
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

procedure TPpu.SetVblank(Value: Boolean);
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

procedure TPpu.ClockMapperAddress;
begin
  if FMapper = nil then
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
  if ((FCycle >= 1) and (FCycle < 256)) or
    ((FCycle >= 320) and (FCycle < 336)) then
  begin
    if Phase = 1 then
      FFetchTile := PpuReadMemory(Address);
    if Phase >= 4 then
      Address := (UInt16(FCtrl and $10) shl 8) or
        (UInt16(FFetchTile) shl 4) or ((FV shr 12) and 7) or ((Phase and 2) shl 2);
  end
  else if (FCycle >= 256) and (FCycle < 320) and (Phase >= 4) then
  begin
    var Slot: Integer := (FCycle - 256) div 8;
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
    var Count: Integer := 0;
    var Tile: UInt8 := $FF;
    var Attributes: UInt8 := 0;
    var Row: Integer := 0;
    for var i := 0 to 63 do
      if (NextLine > FOam[i * 4]) and (NextLine <= Integer(FOam[i * 4]) + Height) then
      begin
        if Count = Slot then
        begin
          Tile := FOam[i * 4 + 1];
          Attributes := FOam[i * 4 + 2];
          Row := NextLine - FOam[i * 4] - 1;
          Break;
        end;
        Inc(Count);
      end;
    if (Attributes and $80) <> 0 then
      Row := Height - 1 - Row;
    if Height = 16 then
      Address := (UInt16(Tile and 1) shl 12) or (UInt16(Tile and $FE) shl 4) or
        ((Row and 8) shl 1) or (Row and 7)
    else
      Address := (UInt16(FCtrl and $08) shl 9) or (UInt16(Tile) shl 4) or (Row and 7);
    Address := Address or ((Phase and 2) shl 2);
  end;
  FMapper.ClockPpuAddress(Address, FPpuClock);
  if ((FCycle and 1) <> 0) and (FCycle <= 339) then
    FMapper.ClockPpuRead;
end;

procedure TPpu.Clock;
begin
  var RenderingEnabled: Boolean := (FMask and $18) <> 0;
  ClockMapperAddress;
  Inc(FPpuClock);
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

  if (FSprite0HitX >= 0) and (FSprite0HitY >= 0) then
    if (FScanline = FSprite0HitY) and (FCycle = FSprite0HitX + 1) then
      FStatus := FStatus or $40;

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
    FStatus := FStatus and not $40;
    FStatus := FStatus and not $20;
    FFrameReady := False;
  end;

  if (FRegion = TNesRegion.NTSC) and FOddFrameSkipEnabled and FFrameOdd and (FScanline = FPreRenderLine) and (FCycle = 339) then
    FCycle := 340;

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

function TPpu.CpuRead(Address: UInt16): UInt8;
begin
  var VramAddress: UInt16;
  Result := FOpenBus;
  case Address and 7 of
    2:
      begin
        Result := (FStatus and $E0) or (FOpenBus and $1F);
        if ((Result and $80) = 0) and (FScanline = 241) and (FCycle = 1) then
        begin
          FVblSetSuppressed := True;
          FNmiPending := False;
        end;
        FStatus := FStatus and not $80;
        if (Result and $80) = 0 then
          FNmiPending := False
        else if (FNmiDelay > 0) and (FNmiDelay <= 6) then
          FNmiPending := True;
        FNmiOccurred := False;
        FNmiDelay := 0;
        FNmiLine := False;
        FAddrLatch := False;
      end;
    4:
      Result := FOam[FOamAddress];
    7:
      begin
        VramAddress := FV and $3FFF;
        if VramAddress < $3F00 then
        begin
          Result := FDataBuffer;
          FDataBuffer := PpuReadMemory(VramAddress);
        end
        else
        begin
          Result := PpuReadMemory(VramAddress);
          FDataBuffer := PpuReadMemory(VramAddress - $1000);
        end;
        if (FCtrl and $04) <> 0 then
          FV := (FV + 32) and $7FFF
        else
          FV := (FV + 1) and $7FFF;
        if FMapper <> nil then
          FMapper.ClockPpuAddress(FV and $3FFF, FPpuClock);
      end;
  end;
  FOpenBus := Result;
end;

procedure TPpu.CpuWrite(Address: UInt16; Value: UInt8);
begin
  FOpenBus := Value;
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
        CaptureSplitState;
      end;
    3:
      FOamAddress := Value;
    4:
      begin
        FOam[FOamAddress] := Value;
        FOamAddress := (FOamAddress + 1) and $FF;
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
          FV := FT;
          if FMapper <> nil then
            FMapper.ClockPpuAddress(FV and $3FFF, FPpuClock);
          FAddrLatch := False;
        end;
      end;
    7:
      begin
        PpuWriteMemory(FV, Value);
        if (FCtrl and $04) <> 0 then
          FV := (FV + 32) and $7FFF
        else
          FV := (FV + 1) and $7FFF;
        if FMapper <> nil then
          FMapper.ClockPpuAddress(FV and $3FFF, FPpuClock);
      end;
  end;
end;

procedure TPpu.WriteOamDma(Index: Integer; Value: UInt8);
begin
  FOam[(FOamAddress + (Index and $FF)) and $FF] := Value;
end;

function TPpu.ConsumeNmi: Boolean;
begin
  Result := FNmiPending;
  FNmiPending := False;
end;

function TPpu.SampleBackgroundPixel(X, Y: Integer; out PaletteIndex: UInt8): UInt8;
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
  var BitPosition: UInt8 := 7 - (LocalX and 7);
  Result := (((Hi shr BitPosition) and 1) shl 1) or ((Lo shr BitPosition) and 1);
end;

function TPpu.SampleSpritePixel(X, Y: Integer; out PaletteIndex: UInt8; out PriorityBehindBg: Boolean; out IsSpriteZero: Boolean): UInt8;
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

procedure TPpu.RenderScanline;
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
      if (FSprite0HitX < 0) and (BgPixel <> 0) and (SprPixel <> 0) and
        SpriteZero and (X <> 255) then
      begin
        FSprite0HitX := X;
        FSprite0HitY := Y;
      end;
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
      FDrawingFrame[X, Y] := NES_PALETTE[PpuReadMemory($3F00 + FinalPaletteAddress) and $3F];
    end;
  finally
    FRenderingLine := False;
    FRenderV := SavedV;
    FRenderCtrl := SavedCtrl;
    FRenderMask := SavedMask;
    FRenderFineX := SavedFineX;
  end;
end;

procedure TPpu.RebuildFrame;
begin
  // The completed image was published at the frame boundary by Clock.
  FSplitActive := False;
  FSplitY := 240;
end;

function TPpu.DebugReadMemory(Address: UInt16): UInt8;
begin
  Result := PpuReadMemory(Address);
end;

function TPpu.DebugMask: UInt8;
begin
  Result := FMask;
end;

function TPpu.DebugCtrl: UInt8;
begin
  Result := FCtrl;
end;

function TPpu.DebugStatus: UInt8;
begin
  Result := FStatus;
end;

function TPpu.DebugV: UInt16;
begin
  Result := FV;
end;

function TPpu.DebugT: UInt16;
begin
  Result := FT;
end;

function TPpu.DebugBackgroundPixel(X, Y: Integer): UInt8;
begin
  var P: UInt8;
  Result := SampleBackgroundPixel(X, Y, P);
end;

function TPpu.DebugOam(Index: Integer): UInt8;
begin
  Result := FOam[Index and $FF];
end;

function TPpu.DebugSprite0HitX: Integer;
begin
  Result := FSprite0HitX;
end;

function TPpu.DebugSprite0HitY: Integer;
begin
  Result := FSprite0HitY;
end;

function TPpu.DebugSplitActive: Boolean;
begin
  Result := FSplitActive;
end;

function TPpu.DebugSplitY: Integer;
begin
  Result := FSplitY;
end;

end.

