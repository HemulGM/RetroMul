unit A5200.ANTIC;

interface

uses
  System.SysUtils, A5200.Types, A5200.GTIA, Core.Snapshots;

type
  TA5200ANTIC = class
  private
    FRead: TA5200Read;
    FLines, FDLFetches: Integer;
    FDMACycles: array[0..A5200CyclesPerLine - 1] of Boolean;
    FLineNMI, FNMIEnabled, FPMControl, FDelayedPMControl: Byte;
    FPMFirstCycle: Integer;
    FHiresVBlank, FScrollEnding, FEndModeLine: Boolean;
    FRegs: array[0..15] of Byte;
    FDL, FScan: Word;
    FInstruction, FNMIST: Byte;
    FRow, FHeight, FLine, FBytes, FCycle: Integer;
    FWaiting, FJVB, FNMI, FNeedFetch, FVScroll, FWaitNextLine, FWaitDelay: Boolean;
    FCharacters: array[0..63] of Byte;
    FOutput: TA5200Scanline;
    FGTIA: TA5200GTIA;
    FRefreshPending: Boolean;
    FPlayfieldClock: Byte;
    FPlayfieldStop: Integer;
    FNameIndex, FGlyphIndex: Integer;
    FVirtualName, FVirtualGlyph: Boolean;
    procedure ClockPlayfield(Bus: Byte; AfterCPU: Boolean);
    procedure PlayfieldFetch(Bus: Byte; Name, Glyph: Boolean; virtual: Boolean);
    function ReadGlyph(Character: Byte): Byte;
    procedure RenderByte(Start: Integer; Data, Character: Byte);
    procedure FetchObject(GTIA: TA5200GTIA; ObjectIndex: Integer);
    function NextDL: Byte;
    procedure FetchInstruction;
  public
    constructor Create(Reader: TA5200Read; LinesPerFrame: Integer);
    procedure Reset;
    procedure SystemReset;
    procedure BeginLine(Line: Integer; GTIA: TA5200GTIA);
    procedure EndLine;
    procedure ClockObjects(Cycle: Integer; GTIA: TA5200GTIA; Bus: Byte);
    function GraphicsActive: Boolean;
    function Read(Index: Byte): Byte;
    procedure Write(Index, Value: Byte);
    function TakeNMI: Boolean;
    function Halted(Cycle: Integer): Boolean;
    function DMAActive: Boolean;
    function WaitingForSync: Boolean;
    function PixelAt(X: Integer): Byte;
    procedure SerializeState(State: TStateArchive; LegacyTiming: Boolean = False);
  end;

implementation

uses
  System.Classes, System.Math;

constructor TA5200ANTIC.Create(Reader: TA5200Read; LinesPerFrame: Integer);
begin
  inherited Create;
  FRead := Reader;
  FLines := LinesPerFrame;
  Reset;
end;

procedure TA5200ANTIC.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FCharacters, SizeOf(FCharacters), 0);
  FillChar(FOutput, SizeOf(FOutput), 0);
  FDL := 0;
  FScan := 0;
  FInstruction := 0;
  FNMIST := 0;
  FLineNMI := 0;
  FPMControl := 0;
  FDelayedPMControl := 0;
  FPMFirstCycle := -1;
  FHiresVBlank := False;
  FScrollEnding := False;
  FEndModeLine := False;
  FPlayfieldClock := 0;
  FPlayfieldStop := -1;
  FRow := 0;
  FHeight := 0;
  FLine := 0;
  FCycle := 0;
  FWaitNextLine := False;
  FWaitDelay := False;
  FBytes := 0;
  FWaiting := False;
  FJVB := False;
  FNMI := False;
  FVScroll := False;
  FNeedFetch := False;
end;

procedure TA5200ANTIC.SystemReset;
begin
  FNMIST := $20;
  FNMI := True;
end;

function TA5200ANTIC.NextDL: Byte;
begin
  Result := FRead(FDL);
  FDL := (FDL and $FC00) or ((FDL + 1) and $3FF);
  case FDLFetches of
    0:
      FDMACycles[1] := True;
    1:
      FDMACycles[6] := True;
    2:
      FDMACycles[7] := True;
  end;
  Inc(FDLFetches);
end;

procedure TA5200ANTIC.FetchInstruction;
const
  Heights: array[0..15] of Integer = (1, 1, 8, 10, 8, 16, 8, 16, 8, 4, 4, 2, 1, 2, 1, 1);
begin
  var Fetch := FRegs[0] and $20 <> 0;
  if Fetch then
    FInstruction := NextDL;
  var Mode := FInstruction and 15;
  FHeight := Heights[Mode];
  FRow := 0;
  FNeedFetch := True;
  FBytes := 0;
  if Mode = 0 then
    FHeight := ((FInstruction shr 4) and 7) + 1
  else if (Mode = 1) and Fetch then
  begin
    var Low := NextDL;
    var High := NextDL;
    FDL := Low or (Word(High) shl 8);
    FJVB := FInstruction and $40 <> 0;
  end
  else if Fetch and (FInstruction and $40 <> 0) then
  begin
    var Low := NextDL;
    FScan := Low or (Word(NextDL) shl 8);
  end;
  // The first and last mode lines in a vertical scroll region use VSCROL.
  var Scrolling := (Mode >= 2) and (FInstruction and $20 <> 0);
  if Scrolling and not FVScroll then
    FRow := FRegs[5] and 15;
  FScrollEnding := FVScroll and not Scrolling;
  FVScroll := Scrolling;
end;

const
  PlayfieldStep: array[0..15] of Integer = (1, 1, 2, 2, 2, 2, 4, 4, 8, 8, 4, 4, 4, 2, 2, 2);

function TA5200ANTIC.ReadGlyph(Character: Byte): Byte;
begin
  var Mode := FInstruction and 15;
  var Row := FRow;
  if Mode in [5, 7] then
    Row := Row div 2;
  if FRegs[1] and 4 <> 0 then
    Row := 7 - Row;
  var Address := Word(FRegs[9] shl 8);
  if Mode in [6, 7] then
    Address := (Address and $FE00) + ((Character and 63) * 8) + (Row and 7)
  else
    Address := (Address and $FC00) + ((Character and 127) * 8) + (Row and 7);
  Result := FRead(Address);
  if Mode = 3 then
    if ((Character and $60) = $60) then
    begin
      if FRow < 2 then
        Result := 0;
    end
    else if FRow >= 8 then
      Result := 0;
  if (Mode in [2, 3]) and (Character and $80 <> 0) then
  begin
    if FRegs[1] and 1 <> 0 then
      Result := 0;
    if FRegs[1] and 2 <> 0 then
      Result := Result xor 255;
  end;
end;

procedure TA5200ANTIC.RenderByte(Start: Integer; Data, Character: Byte);
begin
  var Mode := FInstruction and 15;
  var PixelsPerByte := PlayfieldStep[Mode] * 4;
  for var X := 0 to PixelsPerByte - 1 do
  begin
    var Pixel: Byte := 0;
    if Mode in [2, 3, 15] then
      Pixel := $80 or (((Data shr (6 - (X div 2) * 2)) and 3) shl 4) or
        ((Data shr (4 * (1 - X div 4))) and 15)
    else if Mode in [4, 5, 8, 10, 13, 14] then
    begin
      Pixel := (Data shr (6 - 2 * (X * 4 div PixelsPerByte))) and 3;
      if (Mode in [4, 5]) and (Pixel = 3) and (Character and $80 <> 0) then
        Pixel := 4;
    end
    else if Data and (128 shr (X * 8 div PixelsPerByte)) <> 0 then
      if Mode in [6, 7] then
        Pixel := 1 + (Character shr 6)
      else
        Pixel := 1;
    var Position := Start + X;
    if Position < Length(FOutput) then
      FOutput[Position] := Pixel;
  end;
end;

procedure TA5200ANTIC.PlayfieldFetch(Bus: Byte; Name, Glyph: Boolean; virtual: Boolean);
begin
  var Mode := FInstruction and 15;
  if Name then
  begin
    var Index := FNameIndex mod 48;
    if FNeedFetch then
    begin
      if not virtual then
        Bus := FRead((FScan and $F000) or ((FScan + FNameIndex) and $FFF));
      FCharacters[Index] := Bus;
      Inc(FBytes);
    end;
    if Mode >= 8 then
    begin
      var Data := FCharacters[Index];
      var Start := FCycle * 4 + 16;
      RenderByte(Start, Data, Data);
    end;
    Inc(FNameIndex);
  end;
  if Glyph then
  begin
    var Character := FCharacters[FGlyphIndex mod 48];
    if not virtual then
      Bus := ReadGlyph(Character);
    var Start := FCycle * 4 + 12;
    RenderByte(Start, Bus, Character);
    Inc(FGlyphIndex);
  end;
end;

procedure TA5200ANTIC.ClockPlayfield(Bus: Byte; AfterCPU: Boolean);
begin
  if AfterCPU then
  begin
    if FVirtualName or FVirtualGlyph then
      PlayfieldFetch(Bus, FVirtualName, FVirtualGlyph, True);
    Exit;
  end;
  FVirtualName := False;
  FVirtualGlyph := False;
  var Mode := FInstruction and 15;
  if (FLine < 8) or (FLine >= 248) or FJVB or (Mode < 2) then
  begin
    FPlayfieldClock := 0;
    FPlayfieldStop := -1;
    Exit;
  end;
  var Width := FRegs[0] and 3;
  var Offset := 0;
  if FInstruction and $10 <> 0 then
  begin
    Offset := (FRegs[4] and 15) shr 1;
    Width := Min(Width + Ord(Width <> 0), 3);
  end;
  if (Width <> 0) and (FCycle = 80 + 8 * Width + Offset) then
    FPlayfieldStop := FCycle + 2;
  if FCycle = FPlayfieldStop then
    FPlayfieldClock := FPlayfieldClock and $FE;

  // The DMA clock rings every two, four or eight cycles, while the
  // three taps retain their offsets when width or scroll changes.
  var Name := FPlayfieldClock and (1 shl (2 * Ord(Mode >= 8))) <> 0;
  var Glyph := (Mode < 8) and (FPlayfieldClock and 8 <> 0);
  var Feedback := (FPlayfieldClock shr (PlayfieldStep[Mode] - 1)) and 1;
  if (Width <> 0) and (FCycle = 33 - 8 * Width + Offset) then
    Feedback := 1;
  FPlayfieldClock := ((FPlayfieldClock shl 1) and $FF) or Feedback;
  if not (Name or Glyph) then
    Exit;
  if (Width = 0) or (FCycle = 0) or (FCycle > 105) then
  begin
    FVirtualName := Name;
    FVirtualGlyph := Glyph;
    Exit;
  end;
  if Glyph or (Name and FNeedFetch) then
    FDMACycles[FCycle] := True;
  PlayfieldFetch(Bus, Name, Glyph, False);
end;

function TA5200ANTIC.PixelAt(X: Integer): Byte;
begin
  Result := 0;
  case FRegs[0] and 3 of
    1:
      if (X < 128) or (X >= 384 + 2 * Ord(FGTIA.Priority shr 6 = 2)) then
        Exit;
    2:
      if (X < 96) or (X >= 416 + 2 * Ord(FGTIA.Priority shr 6 = 2)) then
        Exit;
    3:
      if (X < $2C * 2) or (X >= $DE * 2) then
        Exit;
  else
    Exit;
  end;
  var Source := X;
  if (FInstruction and 15 in [2, 3, 15]) and (FGTIA.Priority shr 6 = 2) then
    Dec(Source, 2);
  if FInstruction and $10 <> 0 then
    Dec(Source, (FRegs[4] and 1) * 2);
  Result := FOutput[Source];
end;

procedure TA5200ANTIC.BeginLine(Line: Integer; GTIA: TA5200GTIA);
begin
  FLine := Line;
  FGTIA := GTIA;
  FEndModeLine := False;
  if FPlayfieldStop >= A5200CyclesPerLine then
    Dec(FPlayfieldStop, A5200CyclesPerLine)
  else
    FPlayfieldStop := -1;
  FNameIndex := 0;
  FGlyphIndex := 0;
  FRefreshPending := False;
  FCycle := 0;
  FDLFetches := 0;
  FLineNMI := 0;
  FillChar(FDMACycles, SizeOf(FDMACycles), 0);
  FWaitNextLine := False;
  FillChar(FOutput, SizeOf(FOutput), 0);
  if Line = 0 then
  begin
    FJVB := False;
    FHeight := 0;
    FInstruction := FInstruction and $BF;
    FHiresVBlank := False;
  end;
  if Line = 248 then
  begin
    FHiresVBlank := (FInstruction and 15 in [2, 3, 15]) and (FRegs[0] and 3 <> 0);
    FLineNMI := $40;
  end;
  if (Line < 8) or (Line >= 248) then
    Exit;
  FPMFirstCycle := -1;
  FPMControl := FDelayedPMControl;
  FDMACycles[0] := FPMControl and 12 <> 0;
  for var Cycle := 2 to 5 do
    FDMACycles[Cycle] := FRegs[0] and 8 <> 0;
  if not FJVB and (FHeight <= 0) then
    FetchInstruction;
  if FJVB and (FInstruction and $80 <> 0) then
    FLineNMI := $80;
end;

function TA5200ANTIC.GraphicsActive: Boolean;
begin
  Result := (FLine >= 8) and ((FLine < 248) or FHiresVBlank);
end;

procedure TA5200ANTIC.FetchObject(GTIA: TA5200GTIA; ObjectIndex: Integer);
begin
  var Base := Word(FRegs[7] shl 8);
  var Y := FLine;
  var Stride := $100;
  if FPMControl and $10 = 0 then
  begin
    Base := Base and $FC00;
    Y := Y shr 1;
    Stride := $80;
  end
  else
    Base := Base and $F800;
  var Section := ObjectIndex + 4;
  if ObjectIndex = 4 then
    Section := 3;
  GTIA.LoadPlayer(ObjectIndex, FRead(Word(Base + Section * Stride + Y)), FLine);
end;

procedure TA5200ANTIC.ClockObjects(Cycle: Integer; GTIA: TA5200GTIA; Bus: Byte);
begin
  ClockPlayfield(Bus, True);
  if (FLine < 8) or (FLine >= 248) then
    Exit;
  if (FPMFirstCycle < 0) and (Cycle <= 1) and FDMACycles[Cycle] then
  begin
    FPMFirstCycle := Cycle;
    if Cycle = 0 then
      FetchObject(GTIA, 4)
    else
      GTIA.LoadPlayer(4, FInstruction, FLine);
  end
  else if (FPMFirstCycle >= 0) and (Cycle >= FPMFirstCycle + 2) and
    (Cycle <= FPMFirstCycle + 5) then
  begin
    var Index := Cycle - FPMFirstCycle - 2;
    if FDMACycles[Cycle] and (FPMFirstCycle = 0) then
      FetchObject(GTIA, Index)
    else
      GTIA.LoadPlayer(Index, Bus, FLine);
  end;
end;

procedure TA5200ANTIC.EndLine;
begin
  if (FLine >= 8) and (FLine < 248) and not FJVB and (FHeight > 0) then
  begin
    FNeedFetch := False;
    FRow := (FRow + 1) and 15;
    if FEndModeLine then
    begin
      if FInstruction and 15 >= 2 then
        FScan := (FScan and $F000) or ((FScan + FBytes) and $FFF);
      FHeight := 0;
    end;
  end;
end;

function TA5200ANTIC.Read(Index: Byte): Byte;
begin
  case Index and 15 of
    11:
      begin
        var Line := FLine;
        if FCycle >= 111 then
        begin
          Inc(Line);
          if (Line = FLines) and (FCycle >= 112) then
            Line := 0;
        end;
        Result := Line div 2;
      end;
    15:
      Result := FNMIST or $1F;
  else
    Result := $FF;
  end;
end;

procedure TA5200ANTIC.Write(Index, Value: Byte);
begin
  Index := Index and 15;
  FRegs[Index] := Value;
  case Index of
    2:
      FDL := (FDL and $FF00) or Value;
    3:
      FDL := (FDL and $FF) or (Word(Value) shl 8);
    10:
      begin
        FWaitDelay := not FWaiting or (FCycle = 104);
        FWaitNextLine := FCycle >= 104;
        FWaiting := True;
      end;
    15:
      if (FCycle <> 7) or (FLineNMI = 0) then
        FNMIST := 0
      else
        FNMIST := FNMIST and $C0;
  end;
end;

function TA5200ANTIC.TakeNMI: Boolean;
begin
  Result := FNMI;
  FNMI := False;
end;

function TA5200ANTIC.Halted(Cycle: Integer): Boolean;
begin
  FCycle := Cycle;
  if Cycle = 113 then
    FDelayedPMControl := FRegs[0];
  ClockPlayfield(0, False);
  if (Cycle >= 25) and (Cycle <= 57) and (Cycle and 3 = 1) then
    FRefreshPending := True;
  if FRefreshPending and not FDMACycles[Cycle] then
  begin
    FDMACycles[Cycle] := True;
    FRefreshPending := False;
  end;
  case Cycle of
    6:
      if (FLine >= 8) and (FLine < 248) and not FJVB and (FInstruction and $80 <> 0) then
      begin
        var LastRow := FHeight - 1;
        if FScrollEnding then
          LastRow := FRegs[5] and 15;
        if FRow = LastRow then
          FLineNMI := $80;
      end;
    7:
      begin
        if FLineNMI <> 0 then
          FNMIST := (FNMIST and $20) or FLineNMI;
        FNMIEnabled := FRegs[14];
      end;
    8:
      begin
        if FLineNMI and FNMIEnabled <> 0 then
        begin
          FNMI := True;
          FNMIEnabled := 0;
        end
        else
          FNMIEnabled := FRegs[14];
      end;
    9:
      if FLineNMI and FNMIEnabled <> 0 then
        FNMI := True;
    109:
      if FHeight > 0 then
      begin
        var LastRow := FHeight - 1;
        if FScrollEnding then
          LastRow := FRegs[5] and 15;
        FEndModeLine := FRow = LastRow;
      end;
  end;
  if FWaiting and not FWaitNextLine and (Cycle >= 105) then
    FWaiting := False;
  Result := (FWaiting and not FWaitDelay) or FDMACycles[Cycle];
  // ANTIC's WSYNC latch has a one-cycle propagation delay.
  FWaitDelay := False;
end;

function TA5200ANTIC.DMAActive: Boolean;
begin
  Result := FDMACycles[FCycle];
end;

function TA5200ANTIC.WaitingForSync: Boolean;
begin
  Result := FWaiting;
end;

procedure TA5200ANTIC.SerializeState(State: TStateArchive; LegacyTiming: Boolean);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FDL, SizeOf(FDL));
  State.Field(FScan, SizeOf(FScan));
  State.Field(FInstruction, SizeOf(FInstruction));
  State.Field(FNMIST, SizeOf(FNMIST));
  State.Field(FRow, SizeOf(FRow));
  State.Field(FHeight, SizeOf(FHeight));
  State.Field(FLine, SizeOf(FLine));
  // Older snapshots stored an estimated number of stolen cycles here.
  var LegacyCost := 0;
  State.Field(LegacyCost, SizeOf(LegacyCost));
  State.Field(FCycle, SizeOf(FCycle));
  State.Field(FWaitNextLine, SizeOf(FWaitNextLine));
  State.Field(FWaitDelay, SizeOf(FWaitDelay));
  State.Field(FBytes, SizeOf(FBytes));
  State.Field(FWaiting, SizeOf(FWaiting));
  State.Field(FJVB, SizeOf(FJVB));
  State.Field(FNeedFetch, SizeOf(FNeedFetch));
  State.Field(FVScroll, SizeOf(FVScroll));
  State.Field(FNMI, SizeOf(FNMI));
  State.Field(FCharacters, SizeOf(FCharacters));
  State.Field(FOutput, SizeOf(FOutput));
  if not LegacyTiming and (State.Version <> 1) then
  begin
    State.Field(FDelayedPMControl, SizeOf(FDelayedPMControl));
    State.Field(FHiresVBlank, SizeOf(FHiresVBlank));
    State.Field(FScrollEnding, SizeOf(FScrollEnding));
    State.Field(FPlayfieldClock, SizeOf(FPlayfieldClock));
    State.Field(FPlayfieldStop, SizeOf(FPlayfieldStop));
  end
  else if State.Loading then
  begin
    FDelayedPMControl := FRegs[0];
    FHiresVBlank := False;
    FScrollEnding := False;
    FPlayfieldClock := 0;
    FPlayfieldStop := -1;
  end;
  if State.Loading and ((FRow < 0) or (FRow > 32) or (FHeight < 0) or (FHeight > 16)) then
    raise EReadError.Create('Invalid ANTIC state');
end;

end.

