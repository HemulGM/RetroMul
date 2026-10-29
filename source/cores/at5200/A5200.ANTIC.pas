unit A5200.ANTIC;

interface

uses
  System.SysUtils, A5200.Types, A5200.GTIA, Core.Snapshots;

type
  TA5200ANTIC = class
  private
    FRead: TA5200Read;
    FRegs: array[0..15] of Byte;
    FDL, FScan: Word;
    FInstruction, FNMIST: Byte;
    FRow, FHeight, FLine, FCost, FBytes, FCycle: Integer;
    FWaiting, FJVB, FNMI, FNeedFetch, FVScroll, FWaitNextLine, FWaitDelay: Boolean;
    FCharacters: array[0..63] of Byte;
    FOutput: TA5200Scanline;
    function NextDL: Byte;
    procedure FetchInstruction;
    procedure DecodeLine(GTIAMode: Byte);
  public
    constructor Create(Reader: TA5200Read);
    procedure Reset;
    procedure BeginLine(Line: Integer; GTIA: TA5200GTIA);
    procedure EndLine;
    function Read(Index: Byte): Byte;
    procedure Write(Index, Value: Byte);
    function TakeNMI: Boolean;
    function Halted(Cycle: Integer): Boolean;
    procedure SerializeState(State: TStateArchive);
    property Output: TA5200Scanline read FOutput;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TA5200ANTIC.Create(Reader: TA5200Read);
begin
  inherited Create;
  FRead := Reader;
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
  FRow := 0;
  FHeight := 0;
  FLine := 0;
  FCost := 0;
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

function TA5200ANTIC.NextDL: Byte;
begin
  Result := FRead(FDL);
  FDL := (FDL and $FC00) or ((FDL + 1) and $3FF);
  Inc(FCost);
end;

procedure TA5200ANTIC.FetchInstruction;
const
  Heights: array[0..15] of Integer = (1, 1, 8, 10, 8, 16, 8, 16, 8, 4, 4, 2, 1, 2, 1, 1);
begin
  FInstruction := NextDL;
  var Mode := FInstruction and 15;
  FHeight := Heights[Mode];
  FRow := 0;
  FNeedFetch := True;
  if Mode = 0 then
    FHeight := ((FInstruction shr 4) and 7) + 1
  else if Mode = 1 then
  begin
    var Low := NextDL;
    var High := NextDL;
    FDL := Low or (Word(High) shl 8);
    FJVB := FInstruction and $40 <> 0;
  end
  else
  begin
    if FInstruction and $40 <> 0 then
    begin
      var Low := NextDL;
      FScan := Low or (Word(NextDL) shl 8);
    end;
    var Scrolling := FInstruction and $20 <> 0;
    // VSCROL trims only the first and last mode lines of a scroll region.
    if Scrolling and not FVScroll then
      FRow := Min(FRegs[5] and 15, FHeight - 1)
    else if FVScroll and not Scrolling then
      FHeight := Min((FRegs[5] and 15) + 1, FHeight);
    FVScroll := Scrolling;
  end;
end;

procedure TA5200ANTIC.DecodeLine(GTIAMode: Byte);
const
  NormalBytes: array[0..15] of Integer = (0, 0, 40, 40, 40, 40, 20, 20, 10, 10, 20, 20, 20, 40, 40, 40);
begin
  var Mode := FInstruction and 15;
  if Mode < 2 then
    Exit;
  var Width := FRegs[0] and 3;
  if Width = 0 then
    Exit;
  var FetchWidth := Width;
  if (FInstruction and $10 <> 0) and (FetchWidth < 3) then
    Inc(FetchWidth);
  var Count := NormalBytes[Mode];
  if FetchWidth = 1 then
    Count := Count * 4 div 5
  else if FetchWidth = 3 then
    Count := Count * 6 div 5;
  FBytes := Count;
  if FNeedFetch then
  begin
    for var i := 0 to Count - 1 do
    begin
      FCharacters[i] := FRead((FScan and $F000) or ((FScan + i) and $FFF));
      Inc(FCost);
    end;
    FNeedFetch := False;
  end;
  var Start := 96;
  if Width = 1 then
    Start := 128
  else if Width = 3 then
    Start := 64;
  var PixelsPerByte := 320 div NormalBytes[Mode];
  var ClipLeft := Start;
  var ClipRight := 512 - ClipLeft;
  if FetchWidth = 2 then
    Start := 96
  else if FetchWidth = 3 then
    Start := 64;
  if FInstruction and $10 <> 0 then
    Inc(Start, (FRegs[4] and 15) * 2);
  for var i := 0 to Count - 1 do
  begin
    var Data := FCharacters[i];
    var Character := Data;
    var Row := FRow;
    if Mode < 8 then
    begin
      if Mode in [5, 7] then
        Row := Row div 2;
      if FRegs[1] and 4 <> 0 then
        Row := 7 - Row;
      var Address := Word(FRegs[9] shl 8);
      if Mode in [6, 7] then
        Address := (Address and $FE00) + ((Data and 63) * 8) + (Row and 7)
      else
        Address := (Address and $FC00) + ((Data and 127) * 8) + (Row and 7);
      Data := FRead(Address);
      Inc(FCost);
      if Mode = 3 then
        if ((Character and $60) = $60) then
        begin
          if FRow < 2 then
            Data := 0;
        end
        else if FRow >= 8 then
          Data := 0;
      if (Mode in [2, 3]) and (Character and $80 <> 0) then
      begin
        if FRegs[1] and 1 <> 0 then
          Data := 0;
        if FRegs[1] and 2 <> 0 then
          Data := Data xor 255;
      end;
    end;
    for var X := 0 to PixelsPerByte - 1 do
    begin
      var Pixel: Byte := 0;
      if (Mode in [2, 3, 15]) and (GTIAMode <> 0) then
        Pixel := $80 or ((Data shr (4 * (1 - X * 2 div PixelsPerByte))) and 15)
      else if Mode in [2, 3, 15] then
      begin
        if Data and (128 shr (X * 8 div PixelsPerByte)) <> 0 then
          Pixel := 5
        else
          Pixel := 6;
      end
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
      var Position := Start + i * PixelsPerByte + X;
      if (Position >= ClipLeft) and (Position < ClipRight) then
        FOutput[Position] := Pixel;
    end;
  end;
end;

procedure TA5200ANTIC.BeginLine(Line: Integer; GTIA: TA5200GTIA);
begin
  FLine := Line;
  FCost := 9;
  FCycle := 0;
  FWaitNextLine := False;
  FillChar(FOutput, SizeOf(FOutput), 0);
  if Line = 0 then
  begin
    FJVB := False;
    FHeight := 0;
    FVScroll := False;
  end;
  if Line = 248 then
  begin
    FNMIST := $40;
    if FRegs[14] and $40 <> 0 then
      FNMI := True;
  end;
  if (Line < 8) or (Line >= 248) then
    Exit;
  if FRegs[0] and $0C <> 0 then
  begin
    var Single := FRegs[0] and $10 <> 0;
    var Base := Word(FRegs[7] shl 8);
    var Y := Line;
    if Single then
      Base := Base and $F800
    else
    begin
      Base := Base and $FC00;
      Y := Y div 2;
    end;
    if FRegs[0] and 4 <> 0 then
    begin
      var Offset := $180;
      if Single then
        Offset := $300;
      GTIA.LoadPlayer(4, FRead(Word(Base + Offset + Y)), Line);
      Inc(FCost);
    end;
    if FRegs[0] and 8 <> 0 then
      for var i := 0 to 3 do
      begin
        var Offset := $200 + i * $80;
        if Single then
          Offset := $400 + i * $100;
        GTIA.LoadPlayer(i, FRead(Word(Base + Offset + Y)), Line);
        Inc(FCost);
      end;
  end;
  if (FRegs[0] and $20 = 0) or FJVB then
    Exit;
  if FHeight <= 0 then
  begin
    // JMP consumes display-list DMA but no visible mode line. Bound self loops.
    for var I := 0 to 15 do
    begin
      FetchInstruction;
      if (FInstruction and 15 <> 1) or FJVB then
        Break;
    end;
  end;
  if FJVB then
    Exit;
  DecodeLine(GTIA.Priority shr 6);
  FCost := Min(FCost, 105);
  // DLI is asserted on the last scanline, before its visible pixels. A handler
  // can use WSYNC to set up the following line during horizontal blank.
  if (FRow = FHeight - 1) and (FInstruction and $80 <> 0) then
  begin
    FNMIST := $80;
    if FRegs[14] and $80 <> 0 then
      FNMI := True;
  end;
end;

procedure TA5200ANTIC.EndLine;
begin
  if (FLine >= 8) and (FLine < 248) and not FJVB and (FHeight > 0) then
  begin
    Inc(FRow);
    if FRow >= FHeight then
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
      Result := FLine div 2;
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
        FWaiting := True;
        FWaitDelay := True;
        FWaitNextLine := FCycle >= 105;
      end;
    15:
      FNMIST := 0;
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
  if FWaiting and not FWaitNextLine and (Cycle >= 105) then
    FWaiting := False;
  Result := (Cycle < FCost) or (FWaiting and not FWaitDelay);
  // ANTIC's WSYNC latch has a one-cycle propagation delay.
  FWaitDelay := False;
end;

procedure TA5200ANTIC.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FDL, SizeOf(FDL));
  State.Field(FScan, SizeOf(FScan));
  State.Field(FInstruction, SizeOf(FInstruction));
  State.Field(FNMIST, SizeOf(FNMIST));
  State.Field(FRow, SizeOf(FRow));
  State.Field(FHeight, SizeOf(FHeight));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FCost, SizeOf(FCost));
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
  if State.Loading and ((FRow < 0) or (FRow > 32) or (FHeight < 0) or (FHeight > 16)) then
    raise EReadError.Create('Invalid ANTIC state');
end;

end.

