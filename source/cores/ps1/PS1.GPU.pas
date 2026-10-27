unit PS1.GPU;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Snapshots, PS1.Types,
  PS1.Scheduler, PS1.DMA, PS1.GPU.Raster;

type
  TPS1BlankNotify = procedure(Active: Boolean; Time: Int64) of object;

  TPS1GPU = class(TPS1DMADevice)
  private
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FVideoClock: Int64;
    // GP0 command assembly.
    FCommand: array[0..15] of Cardinal;
    FCommandCount, FCommandLength: Integer;
    FPolyLine, FPolyLineContinued: Boolean;
    // VRAM transfers: 1 = CPU to VRAM, 2 = VRAM to CPU.
    FTransfer: Integer;
    FTransferX, FTransferY, FTransferWidth, FTransferHeight: Cardinal;
    FTransferColumn, FTransferRow: Cardinal;
    FRead: Cardinal;
    FEnv: TPS1DrawEnvironment;
    FRaster: TPS1Rasterizer;
    // Display control.
    FDisplayStart, FHorizontalRange, FVerticalRange, FDisplayMode: Cardinal;
    FDisplayDisabled, FInterrupt: Boolean;
    FDMADirection: Cardinal;
    // Video timing: the current line starts at FLineStart + FLineFraction /
    // FVideoClock CPU cycles; positions within a line are video cycles.
    FLine, FField: Integer;
    FLineStart: Int64;
    FLineFraction: Int64;
    FInHBlank, FInVBlank, FVBlankSeen: Boolean;
    FNextPosition: Integer;
    FDotBase: Int64;
    FDotPosition: Integer;
    FFrames: UInt64;
    // Commands execute when received; the time they take on hardware keeps
    // the GPU busy (GPUSTAT 26/28, DMA requests) until FBusyUntil, counted in
    // 1/256 CPU cycles. FFIFOWords counts words queued meanwhile.
    FBusyUntil: Int64;
    FFIFOWords: Integer;
    function Busy: Boolean; inline;
    procedure AddWork(Units: Int64);
    procedure ResetCommands;
    function LineLength: Integer; inline;
    function LinesInField: Integer;
    function DotDivider: Integer;
    function PositionTime(Position: Integer): Int64;
    function PositionAt(Time: Int64): Integer;
    function HBlankStart: Integer; inline;
    function HBlankEnd: Integer; inline;
    procedure ScheduleNext(Current: Integer);
    procedure UpdateBlankRange;
    procedure StartLine;
    procedure StartVBlank(Time: Int64);
    procedure ExecuteCommand;
    procedure ExecuteEnvironment(Word_: Cardinal);
    function CommandLength(Op: Cardinal): Integer;
    procedure WritePixel(X, Y: Cardinal; Value: Word); inline;
    procedure Fill;
    procedure Copy;
    procedure WriteTransfer(Value: Cardinal);
    function ReadTransfer: Cardinal;
    procedure ReadRegister(Index: Cardinal);
    procedure SetDisplayMode(Value: Cardinal);
    function OddField: Boolean;
    function FIFOEmpty: Boolean;
  public
    VRAM: TPS1VRAM;
    // Called with the CPU cycle of each blanking edge.
    OnHBlank, OnVBlank: TPS1BlankNotify;
    // The dot clock rate is about to change.
    OnDotClockChange: TPS1Notify;
    // The GPU finished its drawing work and can take DMA again.
    OnReady: TPS1Notify;
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest; PAL: Boolean);
    destructor Destroy; override;
    procedure Reset;
    procedure WriteGP0(Value: Cardinal);
    procedure WriteGP1(Value: Cardinal);
    function ReadGP0: Cardinal;
    function Status: Cardinal;
    procedure Event(Time: Int64);
    procedure DrawEvent(Time: Int64);
    function DotCount(Time: Int64): Int64;
    function DotTime(Count: Int64): Int64;
    // Converts the displayed VRAM area into premultiplied ARGB pixels.
    procedure Output(var Pixels: TArray<TAlphaColor>; out Width, Height: Integer);
    function FramesPerSecond: Double;
    // Width/height of the picture on a 4:3 screen: 2560 video clocks by 240
    // (NTSC) or 288 (PAL) lines fill it. Presentation only, not emulated state.
    function DisplayAspect: Double;
    function DMARequest(Channel: Integer): Boolean; override;
    procedure DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure DMARead(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure SerializeState(State: TStateArchive);
    // Increments at the start of each vertical blank (or field end without one).
    property Frames: UInt64 read FFrames;
  end;

implementation

const
  Dividers: array[0..7] of Integer = (10, 7, 8, 7, 5, 7, 4, 7);
  FIFOSize = 16;
  // Work in 1/256 CPU cycles per halfword (ps1-tests gpu/bandwidth and
  // dma/chopping).
  FillPixelWork = 21;
  CopyPixelWork = 343;
  TransferPixelWork = 154;
  ReadPixelWork = 275;

var
  // Opaque ARGB of each 15-bit VRAM color (5 bits widened by repeating the
  // top bits). Filled once at unit initialization, read-only afterwards.
  Color15: array[0..$7FFF] of TAlphaColor;

procedure InitColor15;
begin
  for var P := 0 to $7FFF do
  begin
    var R := Cardinal(P and $1F);
    var G := Cardinal((P shr 5) and $1F);
    var B := Cardinal((P shr 10) and $1F);
    Color15[P] := $FF000000 or (((R shl 3) or (R shr 2)) shl 16) or (((G shl 3) or (G shr 2)) shl 8) or
      ((B shl 3) or (B shr 2));
  end;
end;

constructor TPS1GPU.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest; PAL: Boolean);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  if PAL then
    FVideoClock := PS1VideoClockPAL
  else
    FVideoClock := PS1VideoClockNTSC;
  FRaster := TPS1Rasterizer.Create(@VRAM, @FEnv);
  Reset;
end;

destructor TPS1GPU.Destroy;
begin
  FRaster.Free;
  inherited;
end;

procedure TPS1GPU.ResetCommands;
begin
  FCommandCount := 0;
  FCommandLength := 0;
  FPolyLine := False;
  FPolyLineContinued := False;
  FTransfer := 0;
end;

procedure TPS1GPU.Reset;
begin
  FillChar(VRAM, SizeOf(VRAM), 0);
  ResetCommands;
  FRead := 0;
  FEnv := Default(TPS1DrawEnvironment);
  FRaster.Reset;
  FDisplayStart := 0;
  FHorizontalRange := $200 or (($200 + 256 * 10) shl 12);
  FVerticalRange := $010 or (($010 + 240) shl 10);
  FDisplayMode := 0;
  FDisplayDisabled := True;
  FInterrupt := False;
  FDMADirection := 0;
  FLine := 0;
  FField := 0;
  FLineStart := FScheduler.Now;
  FLineFraction := 0;
  FInHBlank := False;
  FInVBlank := True;
  FVBlankSeen := False;
  FDotBase := 0;
  FDotPosition := 0;
  FFrames := 0;
  FBusyUntil := 0;
  FFIFOWords := 0;
  FScheduler.Cancel(TPS1Event.GPUDraw);
  FNextPosition := 0;
  ScheduleNext(0);
end;

function TPS1GPU.LineLength: Integer;
begin
  if (FDisplayMode and 8) <> 0 then
    Result := 3406
  else
    Result := 3413;
end;

function TPS1GPU.LinesInField: Integer;
begin
  var PAL := (FDisplayMode and 8) <> 0;
  if PAL then
    Result := 314
  else
    Result := 263;
  // Interlaced fields alternate between the two half-line counts.
  if (FDisplayMode and $20) <> 0 then
    Result := Result - 1 + FField;
end;

function TPS1GPU.DisplayAspect: Double;
begin
  var Clocks := Integer((FHorizontalRange shr 12) and $FFF) - Integer(FHorizontalRange and $FFF);
  var Lines := Integer((FVerticalRange shr 10) and $3FF) - Integer(FVerticalRange and $3FF);
  if Clocks <= 0 then
    Clocks := 2560;
  if Lines > LinesInField then
    Lines := LinesInField;
  if Lines <= 0 then
    Lines := 240;
  var FullLines := 240;
  if (FDisplayMode and 8) <> 0 then
    FullLines := 288;
  Result := 4 / 3 * (Clocks / 2560) * (FullLines / Lines);
end;

function TPS1GPU.DotDivider: Integer;
begin
  Result := Dividers[((FDisplayMode and 3) shl 1) or ((FDisplayMode shr 6) and 1)];
end;

function TPS1GPU.PositionTime(Position: Integer): Int64;
begin
  Result := FLineStart + (FLineFraction + Int64(Position) * PS1CPUClock + FVideoClock - 1) div FVideoClock;
end;

function TPS1GPU.PositionAt(Time: Int64): Integer;
begin
  var Video := ((Time - FLineStart) * FVideoClock - FLineFraction);
  if Video <= 0 then
    Exit(0);
  Video := Video div PS1CPUClock;
  if Video > LineLength then
    Video := LineLength;
  Result := Integer(Video);
end;

function TPS1GPU.HBlankStart: Integer;
begin
  Result := Integer((FHorizontalRange shr 12) and $FFF);
end;

function TPS1GPU.HBlankEnd: Integer;
begin
  Result := Integer(FHorizontalRange and $FFF);
end;

// Next timing boundary after Current: horizontal display start/end (HBlank
// edges) or the end of the line.
procedure TPS1GPU.ScheduleNext(Current: Integer);
begin
  var Next := LineLength;
  var X1 := HBlankEnd;
  var X2 := HBlankStart;
  if X1 < X2 then
  begin
    if (X1 > Current) and (X1 < Next) then
      Next := X1;
    if (X2 > Current) and (X2 < Next) then
      Next := X2;
  end;
  FNextPosition := Next;
  FScheduler.Schedule(TPS1Event.GPU, PositionTime(Next));
end;

function TPS1GPU.DotCount(Time: Int64): Int64;
begin
  Result := FDotBase + (PositionAt(Time) - FDotPosition) div DotDivider;
end;

function TPS1GPU.DotTime(Count: Int64): Int64;
begin
  var Divider := DotDivider;
  var Remaining := Count - FDotBase;
  var LineDots := (LineLength - FDotPosition) div Divider;
  if Remaining <= LineDots then
    Exit(PositionTime(FDotPosition + Integer(Remaining) * Divider));

  // Later lines are assumed to keep the current mode.
  Dec(Remaining, LineDots);
  var PerLine := LineLength div Divider;
  var Lines := (Remaining - 1) div PerLine + 1;
  var Within := Remaining - (Lines - 1) * PerLine;
  var Start := FLineStart + (FLineFraction + Lines * LineLength * PS1CPUClock) div FVideoClock;
  var Fraction := (FLineFraction + Lines * LineLength * PS1CPUClock) mod FVideoClock;
  Result := Start + (Fraction + Within * Divider * PS1CPUClock + FVideoClock - 1) div FVideoClock;
end;

procedure TPS1GPU.StartVBlank(Time: Int64);
begin
  FInVBlank := True;
  FVBlankSeen := True;
  Inc(FFrames);
  FIRQ(TPS1IRQ.VBlank);
  if Assigned(OnVBlank) then
    OnVBlank(True, Time);
end;

procedure TPS1GPU.StartLine;
begin
  var Time := PositionTime(LineLength);
  var Total := FLineFraction + Int64(LineLength) * PS1CPUClock;
  Inc(FLineStart, Total div FVideoClock);
  FLineFraction := Total mod FVideoClock;
  Inc(FDotBase, (LineLength - FDotPosition) div DotDivider);
  FDotPosition := 0;

  Inc(FLine);
  if FLine >= LinesInField then
  begin
    FLine := 0;
    if not FVBlankSeen then
      Inc(FFrames);
    FVBlankSeen := False;
    if (FDisplayMode and $20) <> 0 then
      FField := FField xor 1
    else
      FField := 0;
  end;
  var Y1 := Integer(FVerticalRange and $3FF);
  var Y2 := Integer((FVerticalRange shr 10) and $3FF);
  if (FLine = Y2) and not FInVBlank then
    StartVBlank(Time)
  else if (FLine = Y1) and FInVBlank then
  begin
    FInVBlank := False;
    if Assigned(OnVBlank) then
      OnVBlank(False, Time);
  end;
end;

procedure TPS1GPU.Event(Time: Int64);
begin
  var Position := FNextPosition;
  if Position >= LineLength then
  begin
    StartLine;
    Position := 0;
  end
  else
  begin
    var Active := Position = HBlankStart;
    if Active <> FInHBlank then
    begin
      FInHBlank := Active;
      if Assigned(OnHBlank) then
        OnHBlank(Active, PositionTime(Position));
    end;
  end;
  ScheduleNext(Position);
end;

// A display range of zero width keeps HBlank permanently active.
procedure TPS1GPU.UpdateBlankRange;
begin
  if (HBlankEnd >= HBlankStart) and not FInHBlank then
  begin
    FInHBlank := True;
    if Assigned(OnHBlank) then
      OnHBlank(True, FScheduler.Now);
  end;
  ScheduleNext(PositionAt(FScheduler.Now));
end;

function TPS1GPU.FramesPerSecond: Double;
begin
  var Lines: Double := 263;
  if (FDisplayMode and 8) <> 0 then
    Lines := 314;
  if (FDisplayMode and $20) <> 0 then
    Lines := Lines - 0.5;
  Result := FVideoClock / (LineLength * Lines);
end;

function TPS1GPU.Status: Cardinal;
begin
  Result := (FEnv.DrawMode and $7FF) or ((FEnv.DrawMode shr 11) and 1) shl 15;
  if FEnv.MaskSet then
    Result := Result or $800;
  if FEnv.MaskCheck then
    Result := Result or $1000;
  if ((FDisplayMode and $20) = 0) or (FField <> 0) then
    Result := Result or $2000;
  Result := Result or ((FDisplayMode shr 6) and 1) shl 16 or (FDisplayMode and 3) shl 17 or
    ((FDisplayMode shr 2) and 1) shl 19 or ((FDisplayMode shr 3) and 1) shl 20 or
    ((FDisplayMode shr 4) and 1) shl 21 or ((FDisplayMode shr 5) and 1) shl 22 or
    ((FDisplayMode shr 7) and 1) shl 14;
  if FDisplayDisabled then
    Result := Result or $00800000;
  if FInterrupt then
    Result := Result or $01000000;
  if (FCommandCount = 0) and (FTransfer <> 1) and not Busy then
    Result := Result or $04000000;
  var Empty := FIFOEmpty;
  if Empty then
    Result := Result or $10000000;
  if FTransfer = 2 then
    Result := Result or $08000000;
  case FDMADirection of
    1:
      if FFIFOWords < FIFOSize then
        Result := Result or $02000000;
    2:
      if Empty then
        Result := Result or $02000000;
    3:
      if (FTransfer = 2) and not Busy then
        Result := Result or $02000000;
  end;
  Result := Result or (FDMADirection shl 29);
  if OddField then
    Result := Result or $80000000;
end;

// Commands execute at once, so the FIFO only holds a polygon or line whose
// parameters are still arriving (bit 28 drops on its first word).
function TPS1GPU.FIFOEmpty: Boolean;
begin
  Result := ((FCommandCount = 0) or not ((FCommand[0] shr 29) in [1, 2])) and not Busy;
end;

function TPS1GPU.Busy: Boolean;
begin
  Result := FScheduler.Now * 256 < FBusyUntil;
end;

procedure TPS1GPU.AddWork(Units: Int64);
begin
  if Units <= 0 then
    Exit;

  var Start := FScheduler.Now * 256;
  if FBusyUntil < Start then
    FBusyUntil := Start;
  Inc(FBusyUntil, Units);
  FScheduler.Schedule(TPS1Event.GPUDraw, (FBusyUntil + 255) div 256);
end;

procedure TPS1GPU.DrawEvent(Time: Int64);
begin
  if Busy then
    FScheduler.Schedule(TPS1Event.GPUDraw, (FBusyUntil + 255) div 256)
  else
  begin
    FFIFOWords := 0;
    if Assigned(OnReady) then
      OnReady;
  end;
end;

// GPUSTAT bit 31: drawing odd lines; false in vblank. In 480-line mode the
// GPU draws the field that is not displayed, so bit 31 is the inverse of
// the field in bit 13 (the OpenBIOS shell's frame wait depends on this).
function TPS1GPU.OddField: Boolean;
begin
  if FInVBlank then
    Result := False
  else if (FDisplayMode and $24) = $24 then
    Result := FField = 0
  else
    Result := (FLine and 1) <> 0;
end;

function TPS1GPU.CommandLength(Op: Cardinal): Integer;
begin
  case Op shr 5 of
    1:
      begin
        var Vertices := 3;
        if (Op and $08) <> 0 then
          Vertices := 4;
        var PerVertex := 1;
        if (Op and $04) <> 0 then
          Inc(PerVertex);
        Result := 1 + Vertices * PerVertex;
        if (Op and $10) <> 0 then
          Inc(Result, Vertices - 1);
      end;
    2:
      begin
        Result := 3;
        if (Op and $10) <> 0 then
          Result := 4;
      end;
    3:
      begin
        Result := 2;
        if (Op and $04) <> 0 then
          Inc(Result);
        if (Op and $18) = 0 then
          Inc(Result);
      end;
    4:
      Result := 4;
    5, 6:
      Result := 3;
  else
    if Op = $02 then
      Result := 3
    else
      Result := 1;
  end;
end;

procedure TPS1GPU.WriteGP0(Value: Cardinal);
begin
  if Busy then
    Inc(FFIFOWords)
  else
    FFIFOWords := 0;
  if FTransfer = 1 then
  begin
    WriteTransfer(Value);
    AddWork(2 * TransferPixelWork);
    Exit;
  end;

  if FCommandCount = 0 then
  begin
    var Op := Value shr 24;
    // NOPs and drawing area/offset settings bypass the command FIFO.
    if (Op = 0) or ((Op >= $04) and (Op <= $1E)) or (Op = $E0) or (Op >= $E7) then
      Exit;
    if (Op >= $E1) and (Op <= $E6) then
    begin
      ExecuteEnvironment(Value);
      Exit;
    end;
    FCommandLength := CommandLength(Op);
    FPolyLine := ((Op shr 5) = 2) and ((Op and $08) <> 0);
    FPolyLineContinued := False;
  end
  else if FPolyLineContinued and (FCommandCount = 2) and ((Value and $F000F000) = $50005000) then
  begin
    // Poly-line terminator in place of the next vertex (or its color).
    FCommandCount := 0;
    FPolyLine := False;
    FPolyLineContinued := False;
    Exit;
  end;

  if FCommandCount < Length(FCommand) then
    FCommand[FCommandCount] := Value;
  Inc(FCommandCount);
  if FCommandCount >= FCommandLength then
  begin
    ExecuteCommand;
    AddWork(FRaster.Work);
    FRaster.Work := 0;
  end;
end;

procedure TPS1GPU.ExecuteCommand;
begin
  var Op := FCommand[0] shr 24;
  // In 480-line interlaced output the lines of the displayed field are left
  // alone unless drawing to the display area is allowed.
  FRaster.SkipParity := -1;
  if ((FDisplayMode and $24) = $24) and ((FEnv.DrawMode and $400) = 0) and not FInVBlank then
    FRaster.SkipParity := FField;
  case Op shr 5 of
    1:
      FRaster.Polygon(Slice(FCommand, FCommandLength));
    2:
      begin
        var Shaded := (Op and $10) <> 0;
        var SemiTransparent := (Op and $02) <> 0;
        if Shaded then
          FRaster.Line(FCommand[0], FCommand[1], FCommand[2], FCommand[3], True, SemiTransparent)
        else
          FRaster.Line(FCommand[0], FCommand[1], FCommand[0], FCommand[2], False, SemiTransparent);
        if FPolyLine then
        begin
          // Keep the last vertex as the start of the next segment.
          FPolyLineContinued := True;
          if Shaded then
          begin
            FCommand[0] := (FCommand[0] and $FF000000) or (FCommand[2] and $FFFFFF);
            FCommand[1] := FCommand[3];
            FCommandCount := 2;
          end
          else
          begin
            FCommand[1] := FCommand[2];
            FCommandCount := 2;
          end;
          Exit;
        end;
      end;
    3:
      FRaster.Rectangle(Slice(FCommand, FCommandLength));
    4:
      Copy;
    5, 6:
      begin
        FTransferX := FCommand[1] and $3FF;
        FTransferY := (FCommand[1] shr 16) and $1FF;
        FTransferWidth := ((Sub32(FCommand[2] and $FFFF, 1)) and $3FF) + 1;
        FTransferHeight := ((Sub32(FCommand[2] shr 16, 1)) and $1FF) + 1;
        FTransferColumn := 0;
        FTransferRow := 0;
        FCommandCount := 0;
        if (Op shr 5) = 5 then
          FTransfer := 1
        else
          FTransfer := 2;
        Exit;
      end;
  else
    case Op of
      $01:
        FRaster.InvalidateClut;
      $02:
        Fill;
      $1F:
        if not FInterrupt then
        begin
          FInterrupt := True;
          FIRQ(TPS1IRQ.GPU);
        end;
    end;
  end;
  FCommandCount := 0;
end;

procedure TPS1GPU.ExecuteEnvironment(Word_: Cardinal);
begin
  case Word_ shr 24 of
    $E1:
      begin
        // Bit 11 (texture disable) only takes a value while GP1(09h) allows it.
        FEnv.DrawMode := Word_ and $37FF;
        if FEnv.TextureDisableAllowed then
          FEnv.DrawMode := FEnv.DrawMode or (Word_ and $800);
      end;
    $E2:
      FEnv.TextureWindow := Word_ and $FFFFF;
    $E3:
      FEnv.AreaTopLeft := Word_ and $FFFFF;
    $E4:
      FEnv.AreaBottomRight := Word_ and $FFFFF;
    $E5:
      FEnv.Offset := Word_ and $3FFFFF;
    $E6:
      begin
        FEnv.MaskSet := (Word_ and 1) <> 0;
        FEnv.MaskCheck := (Word_ and 2) <> 0;
      end;
  end;
end;

procedure TPS1GPU.WritePixel(X, Y: Cardinal; Value: Word);
begin
  var Index := (Y and $1FF) * PS1VRAMWidth + (X and $3FF);
  if FEnv.MaskCheck and ((VRAM[Index] and $8000) <> 0) then
    Exit;
  if FEnv.MaskSet then
    Value := Value or $8000;
  VRAM[Index] := Value;
end;

procedure TPS1GPU.Fill;
begin
  var Color := FCommand[0];
  var Value := Word(((Color shr 3) and $1F) or (((Color shr 11) and $1F) shl 5) or (((Color shr 19) and $1F) shl 10));
  var X := FCommand[1] and $3F0;
  var Y := (FCommand[1] shr 16) and $1FF;
  var Width := ((FCommand[2] and $3FF) + $F) and not Cardinal($F);
  var Height := (FCommand[2] shr 16) and $1FF;
  Inc(FRaster.Work, Int64(Width) * Height * FillPixelWork);
  for var Row := 0 to Integer(Height) - 1 do
  begin
    var Line := ((Y + Cardinal(Row)) and $1FF) * PS1VRAMWidth;
    for var Column := 0 to Integer(Width) - 1 do
      VRAM[Line + ((X + Cardinal(Column)) and $3FF)] := Value;
  end;
end;

// Each row is read before it is written (overlapping copies to the right do
// not smear), while rows are copied top to bottom (ps1-tests
// vram-to-vram-overlap).
procedure TPS1GPU.Copy;
var
  Row_: array[0..PS1VRAMWidth - 1] of Word;
begin
  var SourceX := FCommand[1] and $3FF;
  var SourceY := (FCommand[1] shr 16) and $1FF;
  var TargetX := FCommand[2] and $3FF;
  var TargetY := (FCommand[2] shr 16) and $1FF;
  var Width := (Sub32(FCommand[3] and $FFFF, 1) and $3FF) + 1;
  var Height := (Sub32(FCommand[3] shr 16, 1) and $1FF) + 1;
  Inc(FRaster.Work, Int64(Width) * Height * CopyPixelWork);
  for var Row := 0 to Integer(Height) - 1 do
  begin
    var Source := ((SourceY + Cardinal(Row)) and $1FF) * PS1VRAMWidth;
    for var Column := 0 to Integer(Width) - 1 do
      Row_[Column] := VRAM[Source + ((SourceX + Cardinal(Column)) and $3FF)];
    for var Column := 0 to Integer(Width) - 1 do
      WritePixel(TargetX + Cardinal(Column), TargetY + Cardinal(Row), Row_[Column]);
  end;
end;

procedure TPS1GPU.WriteTransfer(Value: Cardinal);
begin
  for var Half := 0 to 1 do
  begin
    if FTransfer <> 1 then
      Exit;
    WritePixel(FTransferX + FTransferColumn, FTransferY + FTransferRow, Word(Value shr (Half * 16)));
    Inc(FTransferColumn);
    if FTransferColumn >= FTransferWidth then
    begin
      FTransferColumn := 0;
      Inc(FTransferRow);
      if FTransferRow >= FTransferHeight then
        FTransfer := 0;
    end;
  end;
end;

function TPS1GPU.ReadTransfer: Cardinal;
begin
  Result := 0;
  for var Half := 0 to 1 do
  begin
    if FTransfer <> 2 then
      Break;
    var Pixel := VRAM[((FTransferY + FTransferRow) and $1FF) * PS1VRAMWidth + ((FTransferX + FTransferColumn) and $3FF)];
    Result := Result or (Cardinal(Pixel) shl (Half * 16));
    Inc(FTransferColumn);
    if FTransferColumn >= FTransferWidth then
    begin
      FTransferColumn := 0;
      Inc(FTransferRow);
      if FTransferRow >= FTransferHeight then
        FTransfer := 0;
    end;
  end;
  FRead := Result;
end;

function TPS1GPU.ReadGP0: Cardinal;
begin
  if FTransfer = 2 then
  begin
    Result := ReadTransfer;
    AddWork(2 * ReadPixelWork);
  end
  else
    Result := FRead;
end;

procedure TPS1GPU.ReadRegister(Index: Cardinal);
begin
  case Index and $F of
    2:
      FRead := FEnv.TextureWindow;
    3:
      FRead := FEnv.AreaTopLeft;
    4:
      FRead := FEnv.AreaBottomRight;
    5:
      FRead := FEnv.Offset;
    7:
      FRead := 2;
    8:
      FRead := 0;
  end;
end;

procedure TPS1GPU.SetDisplayMode(Value: Cardinal);
begin
  // Rebase the dot counter so counts before the change keep their rate.
  var Position := PositionAt(FScheduler.Now);
  FDotBase := DotCount(FScheduler.Now);
  FDotPosition := Position;
  FDisplayMode := Value and $FF;
  if FLine >= LinesInField then
    FLine := LinesInField - 1;
  ScheduleNext(PositionAt(FScheduler.Now));
  if Assigned(OnDotClockChange) then
    OnDotClockChange;
end;

procedure TPS1GPU.WriteGP1(Value: Cardinal);
begin
  case (Value shr 24) and $3F of
    $00:
      begin
        ResetCommands;
        FInterrupt := False;
        FDisplayDisabled := True;
        FDMADirection := 0;
        FDisplayStart := 0;
        FHorizontalRange := $200 or (($200 + 256 * 10) shl 12);
        FVerticalRange := $010 or (($010 + 240) shl 10);
        // GP1(09h) survives the reset.
        var Allowed := FEnv.TextureDisableAllowed;
        FEnv := Default(TPS1DrawEnvironment);
        FEnv.TextureDisableAllowed := Allowed;
        FRaster.InvalidateClut;
        SetDisplayMode(0);
      end;
    $01:
      begin
        ResetCommands;
        FRaster.InvalidateClut;
      end;
    $02:
      FInterrupt := False;
    $03:
      FDisplayDisabled := (Value and 1) <> 0;
    $04:
      FDMADirection := Value and 3;
    $05:
      FDisplayStart := Value and $7FFFF;
    $06:
      begin
        FHorizontalRange := Value and $FFFFFF;
        UpdateBlankRange;
      end;
    $07:
      FVerticalRange := Value and $FFFFF;
    $08:
      SetDisplayMode(Value);
    $09:
      FEnv.TextureDisableAllowed := (Value and 1) <> 0;
    $10..$1F:
      ReadRegister(Value and $FFFFFF);
  end;
end;

function TPS1GPU.DMARequest(Channel: Integer): Boolean;
begin
  case FDMADirection of
    1:
      Result := (FTransfer <> 2) and (FFIFOWords < FIFOSize);
    2:
      Result := FIFOEmpty and (FTransfer <> 2);
    3:
      Result := (FTransfer = 2) and not Busy;
  else
    Result := False;
  end;
end;

procedure TPS1GPU.DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    WriteGP0(Data^);
    Inc(Data);
  end;
end;

procedure TPS1GPU.DMARead(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    Data^ := ReadGP0;
    Inc(Data);
  end;
end;

procedure TPS1GPU.Output(var Pixels: TArray<TAlphaColor>; out Width, Height: Integer);
begin
  var X1 := Integer(FHorizontalRange and $FFF);
  var X2 := Integer((FHorizontalRange shr 12) and $FFF);
  var Y1 := Integer(FVerticalRange and $3FF);
  var Y2 := Integer((FVerticalRange shr 10) and $3FF);
  Width := ((X2 - X1) div DotDivider + 2) and not 3;
  if Width > PS1VRAMWidth then
    Width := PS1VRAMWidth;
  Height := Y2 - Y1;
  if Height > LinesInField then
    Height := LinesInField;
  var Interlaced := (FDisplayMode and $24) = $24;
  if Interlaced then
    Height := Height * 2;
  if Width < 4 then
    Width := 4;
  if Height < 2 then
    Height := 2;
  if Length(Pixels) <> Width * Height then
    SetLength(Pixels, Width * Height);
  if FDisplayDisabled then
  begin
    for var I := 0 to High(Pixels) do
      Pixels[I] := $FF000000;
    Exit;
  end;

  var SourceX := FDisplayStart and $3FF;
  var SourceY := (FDisplayStart shr 10) and $1FF;
  var Color24 := (FDisplayMode and $10) <> 0;
  for var Row := 0 to Height - 1 do
  begin
    var Line := ((SourceY + Cardinal(Row)) and $1FF) * PS1VRAMWidth;
    var Target := Row * Width;
    if Color24 then
    begin
      var ByteX := SourceX * 2;
      if ByteX + Cardinal(Width) * 3 <= PS1VRAMWidth * 2 then
      begin
        // The row does not wrap: read its bytes in place.
        var Source := PByte(@VRAM[Line]) + ByteX;
        for var Column := 0 to Width - 1 do
        begin
          Pixels[Target + Column] := $FF000000 or (Cardinal(Source[0]) shl 16) or (Cardinal(Source[1]) shl 8) or
            Source[2];
          Inc(Source, 3);
        end;
      end
      else
        for var Column := 0 to Width - 1 do
        begin
          var C: array[0..2] of Cardinal;
          for var I := 0 to 2 do
          begin
            var Offset := ByteX + Cardinal(Column * 3 + I);
            C[I] := (VRAM[Line + ((Offset shr 1) and $3FF)] shr ((Offset and 1) * 8)) and $FF;
          end;
          Pixels[Target + Column] := $FF000000 or (C[0] shl 16) or (C[1] shl 8) or C[2];
        end;
    end
    else
      for var Column := 0 to Width - 1 do
        Pixels[Target + Column] := Color15[VRAM[Line + ((SourceX + Cardinal(Column)) and $3FF)] and $7FFF];
  end;
end;

procedure TPS1GPU.SerializeState(State: TStateArchive);
begin
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FCommandCount, SizeOf(FCommandCount));
  State.Field(FCommandLength, SizeOf(FCommandLength));
  State.Field(FPolyLine, SizeOf(FPolyLine));
  State.Field(FPolyLineContinued, SizeOf(FPolyLineContinued));
  State.Field(FTransfer, SizeOf(FTransfer));
  State.Field(FTransferX, SizeOf(FTransferX));
  State.Field(FTransferY, SizeOf(FTransferY));
  State.Field(FTransferWidth, SizeOf(FTransferWidth));
  State.Field(FTransferHeight, SizeOf(FTransferHeight));
  State.Field(FTransferColumn, SizeOf(FTransferColumn));
  State.Field(FTransferRow, SizeOf(FTransferRow));
  State.Field(FRead, SizeOf(FRead));
  State.Field(FEnv.DrawMode, SizeOf(FEnv.DrawMode));
  State.Field(FEnv.TextureWindow, SizeOf(FEnv.TextureWindow));
  State.Field(FEnv.AreaTopLeft, SizeOf(FEnv.AreaTopLeft));
  State.Field(FEnv.AreaBottomRight, SizeOf(FEnv.AreaBottomRight));
  State.Field(FEnv.Offset, SizeOf(FEnv.Offset));
  State.Field(FEnv.MaskSet, SizeOf(FEnv.MaskSet));
  State.Field(FEnv.MaskCheck, SizeOf(FEnv.MaskCheck));
  State.Field(FEnv.TextureDisableAllowed, SizeOf(FEnv.TextureDisableAllowed));
  FRaster.SerializeState(State);
  State.Field(FDisplayStart, SizeOf(FDisplayStart));
  State.Field(FHorizontalRange, SizeOf(FHorizontalRange));
  State.Field(FVerticalRange, SizeOf(FVerticalRange));
  State.Field(FDisplayMode, SizeOf(FDisplayMode));
  State.Field(FDisplayDisabled, SizeOf(FDisplayDisabled));
  State.Field(FInterrupt, SizeOf(FInterrupt));
  State.Field(FDMADirection, SizeOf(FDMADirection));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FField, SizeOf(FField));
  State.Field(FLineStart, SizeOf(FLineStart));
  State.Field(FLineFraction, SizeOf(FLineFraction));
  State.Field(FInHBlank, SizeOf(FInHBlank));
  State.Field(FInVBlank, SizeOf(FInVBlank));
  State.Field(FVBlankSeen, SizeOf(FVBlankSeen));
  State.Field(FNextPosition, SizeOf(FNextPosition));
  State.Field(FDotBase, SizeOf(FDotBase));
  State.Field(FDotPosition, SizeOf(FDotPosition));
  State.Field(FFrames, SizeOf(FFrames));
  State.Field(FBusyUntil, SizeOf(FBusyUntil));
  State.Field(FFIFOWords, SizeOf(FFIFOWords));
  if State.Loading and ((FCommandCount < 0) or (FCommandCount > Length(FCommand)) or
    (FCommandLength < 0) or (FCommandLength > Length(FCommand)) or (FTransfer < 0) or (FTransfer > 2) or
    (FLine < 0) or (FLine >= 314) or (FLineFraction < 0) or (FLineFraction >= FVideoClock) or
    (FNextPosition < 0) or (FNextPosition > 3413) or (FDotPosition < 0) or (FDotPosition > 3413)) then
    raise EReadError.Create('PS1 snapshot GPU');
end;

initialization
  InitColor15;

end.

