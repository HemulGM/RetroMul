unit A7800.MARIA;

interface

uses
  System.SysUtils, Core.Emulation.Types, Core.Snapshots;

type
  TMariaRead = function(Address: Word): Byte of object;

  TA7800Maria = class
  private
    FRead: TMariaRead;
    FRegs: array[0..31] of Byte;
    FLineRAM: array[0..159] of Byte;
    FPalette: array[0..255] of Cardinal;
    FDLL, FDL: Word;
    FOffset, FHoley, FWriteMode, FScanline: Integer;
    FWaiting, FNMI, FPAL: Boolean;
    FFrame: TEmulatorFrame;
    function Fetch(Address: Word): Byte;
    procedure LoadZone;
    procedure StoreGraphics(Value: Byte; Palette: Integer; var X: Integer);
    function DrawList: Integer;
  public
    constructor Create(Reader: TMariaRead; PAL: Boolean);
    procedure Reset;
    procedure Write(Address: Byte; Value: Byte);
    function Read(Address: Byte): Byte;
    procedure StartLine(Line: Integer);
    function BeginLine(Line: Integer): Integer;
    procedure DisplayLine;
    procedure EndFrame;
    procedure SerializeState(State: TStateArchive);
    property NMI: Boolean read FNMI;
    property Waiting: Boolean read FWaiting;
    property Frame: TEmulatorFrame read FFrame;
  end;

implementation

uses
  System.Math;

constructor TA7800Maria.Create(Reader: TMariaRead; PAL: Boolean);
begin
  inherited Create;
  FRead := Reader;
  FPAL := PAL;
  for var i := 0 to 255 do
  begin
    var Hue := i shr 4;
    var Angle := (Hue - 1) * Pi / 7 - 0.8;
    var Y := (i and 15) / 15;
    var Chroma := 0.22;
    if Hue = 0 then
      Chroma := 0;
    var U := Cos(Angle) * Chroma;
    var V := Sin(Angle) * Chroma;
    FPalette[i] := $FF000000 or
      (Cardinal(EnsureRange(Round((Y + 0.956 * U + 0.621 * V) * 255), 0, 255)) shl 16) or
      (Cardinal(EnsureRange(Round((Y - 0.272 * U - 0.647 * V) * 255), 0, 255)) shl 8) or
      Cardinal(EnsureRange(Round((Y - 1.106 * U + 1.703 * V) * 255), 0, 255));
  end;
  Reset;
end;

procedure TA7800Maria.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FLineRAM, SizeOf(FLineRAM), 0);
  FDLL := 0;
  FDL := 0;
  FOffset := 0;
  FHoley := 0;
  FWriteMode := 0;
  FScanline := -1;
  FWaiting := False;
  FNMI := False;
  FFrame := Default(TEmulatorFrame);
  FFrame.Width := 320;
  FFrame.Height := 240;
  if FPAL then
    FFrame.Height := 288;
  FFrame.FramesPerSecond := 1789772.727272727 / (113.5 * 263);
  if FPAL then
    FFrame.FramesPerSecond := 1773447 / (113.5 * 313);
  SetLength(FFrame.Pixels, FFrame.Width * FFrame.Height);
end;

function TA7800Maria.Read(Address: Byte): Byte;
begin
  Result := 0;
  if Address and 31 = 8 then
    if (FScanline < 16) or (FScanline >= 258 + Ord(FPAL) * 50) then
      Result := $80;
end;

procedure TA7800Maria.Write(Address: Byte; Value: Byte);
begin
  Address := Address and 31;
  if Address = 4 then
    FWaiting := True
  else if Address <> 8 then
    FRegs[Address] := Value;
end;

procedure TA7800Maria.LoadZone;
begin
  var Control := FRead(FDLL);
  FOffset := Control and 15;
  FHoley := Control and $60;
  FNMI := Control and $80 <> 0;
  FDL := (Word(FRead(Word((Integer(FDLL) + 1) and $FFFF))) shl 8) or
    FRead(Word((Integer(FDLL) + 2) and $FFFF));
  FDLL := Word((Integer(FDLL) + 3) and $FFFF);
end;

function TA7800Maria.Fetch(Address: Word): Byte;
begin
  Result := 0;
  if Address >= $8000 then
  begin
    if (FHoley and $40 <> 0) and (Address and $1000 <> 0) then
      Exit;
    if (FHoley and $20 <> 0) and (Address and $800 <> 0) then
      Exit;
  end;
  Result := FRead(Address);
end;

procedure TA7800Maria.StoreGraphics(Value: Byte; Palette: Integer; var X: Integer);
begin
  var Pixels := 4;
  if FWriteMode <> 0 then
    Pixels := 2;
  for var i := 0 to Pixels - 1 do
  begin
    var Color := (Value shr (6 - i * 2)) and 3;
    if FWriteMode <> 0 then
      Color := ((Value shr (2 - i * 2)) and 3) shl 2 or ((Value shr (6 - i * 2)) and 3);
    if (Color and 3 <> 0) or (FRegs[28] and 4 <> 0) then
    begin
      if FWriteMode = 0 then
        Color := Palette or Color
      else
        Color := (Palette and $10) or Color;
      if X < 160 then
        FLineRAM[X] := Color;
    end;
    X := (X + 1) and 255;
  end;
end;

function TA7800Maria.DrawList: Integer;
begin
  Result := 16;
  var Ptr := Integer(FDL);
  // The DMA window bounds malformed lists, even if a ROM never terminates one.
  while Result < 426 do
  begin
    var LowAddress := FRead(Word(Ptr and $FFFF));
    var Control := FRead(Word((Ptr + 1) and $FFFF));
    if Control = 0 then
      Break;
    var HighAddress := FRead(Word((Ptr + 2) and $FFFF));
    var Indirect := False;
    var PaletteWidth := Control;
    var X: Integer;
    if Control and 31 = 0 then
    begin
      FWriteMode := Control shr 7;
      Indirect := Control and $20 <> 0;
      PaletteWidth := FRead(Word((Ptr + 3) and $FFFF));
      X := FRead(Word((Ptr + 4) and $FFFF));
      Inc(Ptr, 5);
      Inc(Result, 10);
    end
    else
    begin
      X := FRead(Word((Ptr + 3) and $FFFF));
      Inc(Ptr, 4);
      Inc(Result, 8);
    end;
    var Width := 32 - (PaletteWidth and 31);
    var Palette := (PaletteWidth shr 3) and $1C;
    var Address := (Integer(HighAddress) shl 8) or LowAddress;
    if not Indirect then
      Inc(Address, FOffset * 256);
    for var i := 0 to Width - 1 do
    begin
      if Result >= 426 then
        Break;
      var GfxAddress := (Address + i) and $FFFF;
      if Indirect then
      begin
        GfxAddress := (((Integer(FRegs[20]) + FOffset) and 255) shl 8) or FRead(Word(GfxAddress));
        Inc(Result, 3);
      end;
      StoreGraphics(Fetch(Word(GfxAddress)), Palette, X);
      Inc(Result, 3);
      if Indirect and (FRegs[28] and $10 <> 0) then
      begin
        StoreGraphics(Fetch(Word((GfxAddress + 1) and $FFFF)), Palette, X);
        Inc(Result, 3);
      end;
    end;
  end;
end;

procedure TA7800Maria.StartLine(Line: Integer);
begin
  FScanline := Line;
  FWaiting := False;
  FNMI := False;
end;

function TA7800Maria.BeginLine(Line: Integer): Integer;
begin
  if FScanline <> Line then
    StartLine(Line);
  Result := 0;
  FillChar(FLineRAM, SizeOf(FLineRAM), 0);
  if (Line < 16) or (Line >= 258 + Ord(FPAL) * 50) or (FRegs[28] and $60 <> $40) then
    Exit;
  if Line = 16 then
  begin
    FDLL := (Word(FRegs[12]) shl 8) or FRegs[16];
    LoadZone;
  end;
  Result := DrawList;
  if Line = 16 then
    Inc(Result, 8);
  if FOffset = 0 then
    Inc(Result, 8);
  if FOffset = 0 then
    LoadZone
  else
    Dec(FOffset);
end;

procedure TA7800Maria.DisplayLine;
begin
  var Y := FScanline - 18;
  if (Y < 0) or (Y >= FFrame.Height) then
    Exit;
  var Mode := FRegs[28] and 3;
  for var X := 0 to 319 do
  begin
    var Entry := FLineRAM[X div 2];
    var Color := Integer(Entry);
    case Mode of
      2:
        if X and 1 = 0 then
          Color := (Entry and $10) or ((Entry shr 3) and 1) or (Entry and 2)
        else
          Color := (Entry and $10) or ((Entry shr 2) and 1) or ((Entry and 1) shl 1);
      3:
        if X and 1 = 0 then
          Color := (Entry and $1C) or (Entry and 2)
        else
          Color := (Entry and $1C) or ((Entry and 1) shl 1);
    end;
    if Color and 3 = 0 then
      Color := FRegs[0]
    else
      Color := FRegs[Color];
    if FRegs[28] and $80 <> 0 then
      Color := Color and 15;
    FFrame.Pixels[Y * 320 + X] := FPalette[Color];
  end;
end;

procedure TA7800Maria.EndFrame;
begin
  Inc(FFrame.FrameNumber);
end;

procedure TA7800Maria.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FLineRAM, SizeOf(FLineRAM));
  State.Field(FDLL, SizeOf(FDLL));
  State.Field(FDL, SizeOf(FDL));
  State.Field(FOffset, SizeOf(FOffset));
  State.Field(FHoley, SizeOf(FHoley));
  State.Field(FWriteMode, SizeOf(FWriteMode));
  State.Field(FScanline, SizeOf(FScanline));
  State.Field(FWaiting, SizeOf(FWaiting));
  State.Field(FNMI, SizeOf(FNMI));
  State.Field(FFrame.FrameNumber, SizeOf(FFrame.FrameNumber));
  State.Field(FFrame.Pixels[0], Length(FFrame.Pixels) * SizeOf(Cardinal));
end;

end.

