unit PCE.Video;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Snapshots, PCE.Cartridge;

type
  TPCEPixelRow = array[0..1023] of Word;

  THuC6270 = class
  private
    FVRAM: array[0..32767] of Word;
    FSAT: array[0..255] of Word;
    FReg: array[0..31] of Word;
    FLatch, FStatus, FWriteLow: Byte;
    FReadBuffer: Word;
    FSATPending: Boolean;
    FScrollY: Integer;
    FScrollPending, FDMAPending: Boolean;
    FDMACycles, FSATCycles, FSATPosition: Integer;
    function IncrementSize: Integer;
  public
    constructor Create;
    procedure Reset;
    function Read(Port: Word): Byte;
    procedure Write(Port: Word; Value: Byte);
    procedure Scanline(Line: Integer; var Pixels: TPCEPixelRow; const Options: TPCEOptions);
    function IRQ: Boolean;
    function Width: Integer;
    function Height: Integer;
    function DisplayStart: Integer;
    procedure Advance(Cycles, ClockDivider: Integer; Blanking: Boolean);
    procedure SerializeState(State: TStateArchive);
  end;

  TPCEVideo = class
  private
    FVDC: array[0..1] of THuC6270;
    FPalette: array[0..511] of Word;
    FVCEAddress: Word;
    FVCEControl: Byte;
    FVPC: array[0..7] of Byte;
    FSuperGrafx: Boolean;
  public
    constructor Create(SuperGrafx: Boolean);
    destructor Destroy; override;
    procedure Reset;
    function Read(Port: Word): Byte;
    procedure Write(Port: Word; Value: Byte);
    procedure StoreVDC(Port: Word; Value: Byte);
    procedure Scanline(Line: Integer; var Pixels: TArray<TAlphaColor>; const Options: TPCEOptions; OutputWidth, OutputHeight: Integer);
    function IRQ: Boolean;
    function Width: Integer;
    function Height: Integer;
    function Lines: Integer;
    procedure Advance(Cycles, Line: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor THuC6270.Create;
begin
  inherited;
  Reset;
end;

procedure THuC6270.Reset;
begin
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FillChar(FSAT, SizeOf(FSAT), 0);
  FillChar(FReg, SizeOf(FReg), 0);
  FLatch := 0;
  FStatus := 0;
  FWriteLow := 0;
  FReadBuffer := 0;
  FSATPending := False;
  FScrollY := 0;
  FScrollPending := False;
  FDMAPending := False;
  FDMACycles := 0;
  FSATCycles := 0;
  FSATPosition := 256;
end;

function THuC6270.IncrementSize: Integer;
const
  Steps: array[0..3] of Integer = (1, 32, 64, 128);
begin
  Result := Steps[(FReg[5] shr 11) and 3];
end;

function THuC6270.Width: Integer;
begin
  Result := EnsureRange(((FReg[11] and $7F) + 1) * 8, 8, 1024);
end;

function THuC6270.Height: Integer;
begin
  Result := (FReg[13] and $1FF) + 1;
end;

function THuC6270.DisplayStart: Integer;
begin
  Result := (FReg[12] and 31) + (FReg[12] shr 8) + 2;
end;

function THuC6270.IRQ: Boolean;
begin
  // SR records enabled interrupt events, and reading SR acknowledges them.
  // Changing CR after an event must not erase an already latched request.
  Result := FStatus and $3F <> 0;
end;

function THuC6270.Read(Port: Word): Byte;
begin
  Result := 0;
  case Port and 3 of
    0:
      begin
        Result := FStatus;
        FStatus := 0;
      end;
    2:
      Result := FReadBuffer and 255;
    3:
      begin
        Result := FReadBuffer shr 8;
        if FLatch = 2 then
        begin
          FReg[1] := (Integer(FReg[1]) + IncrementSize) and $FFFF;
          FReadBuffer := FVRAM[FReg[1] and $7FFF];
        end;
      end;
  end;
end;

procedure THuC6270.Write(Port: Word; Value: Byte);
begin
  case Port and 3 of
    0:
      FLatch := Value and 31;
    2:
      begin
        FReg[FLatch] := (FReg[FLatch] and $FF00) or Value;
        if FLatch = 2 then
          FWriteLow := Value;
        if FLatch = 8 then
          FScrollPending := True;
      end;
    3:
      begin
        FReg[FLatch] := (FReg[FLatch] and 255) or (Word(Value) shl 8);
        case FLatch of
          1:
            FReadBuffer := FVRAM[FReg[1] and $7FFF];
          2:
            begin
              FVRAM[FReg[0] and $7FFF] := FWriteLow or (Word(Value) shl 8);
              FReg[0] := (Integer(FReg[0]) + IncrementSize) and $FFFF;
            end;
          8:
            FScrollPending := True;
          18:
            begin
              FDMAPending := True;
              FDMACycles := 0;
            end;
          19:
            FSATPending := True;
        end;
      end;
  end;
end;

procedure THuC6270.Advance(Cycles, ClockDivider: Integer; Blanking: Boolean);
begin
  if not Blanking and (FReg[5] and $C0 <> 0) then
    Exit;
  // Both engines transfer one word every four dot clocks; SATB has priority.
  if FSATPosition < 256 then
  begin
    Inc(FSATCycles, Cycles * 3);
    while (FSATCycles >= ClockDivider * 4) and (FSATPosition < 256) do
    begin
      Dec(FSATCycles, ClockDivider * 4);
      FSAT[FSATPosition] := FVRAM[(Integer(FReg[19]) + FSATPosition) and $7FFF];
      Inc(FSATPosition);
    end;
    if (FSATPosition = 256) and (FReg[15] and 1 <> 0) then
      FStatus := FStatus or 8;
    Exit;
  end;
  if not FDMAPending then
    Exit;
  Inc(FDMACycles, Cycles * 3);
  while FDMACycles >= ClockDivider * 4 do
  begin
    Dec(FDMACycles, ClockDivider * 4);
    FVRAM[FReg[17] and $7FFF] := FVRAM[FReg[16] and $7FFF];
    FReg[16] := (Integer(FReg[16]) + 1 - 2 * Ord(FReg[15] and 4 <> 0)) and $FFFF;
    FReg[17] := (Integer(FReg[17]) + 1 - 2 * Ord(FReg[15] and 8 <> 0)) and $FFFF;
    FReg[18] := (Integer(FReg[18]) - 1) and $FFFF;
    if FReg[18] = $FFFF then
    begin
      FDMAPending := False;
      if FReg[15] and 2 <> 0 then
        FStatus := FStatus or $10;
      Break;
    end;
  end;
end;

procedure THuC6270.Scanline(Line: Integer; var Pixels: TPCEPixelRow; const Options: TPCEOptions);
const
  MapWidths: array[0..3] of Integer = (32, 64, 128, 128);
  SpriteHeights: array[0..3] of Integer = (16, 32, 64, 64);
var
  Owners: array[0..1023] of SmallInt;
begin
  // Bit 15 marks transparent pixels, bit 8 selects the sprite palette.
  for var I := 0 to High(Pixels) do
  begin
    Pixels[I] := $8000;
    Owners[I] := -1;
  end;
  if Line = 0 then
  begin
    FScrollY := FReg[8] and $1FF;
    FScrollPending := False;
  end
  else if FScrollPending and (Line > 0) then
  begin
    FScrollY := (FReg[8] + 1) and $1FF;
    FScrollPending := False;
  end;
  if (Line + $41 = (FReg[6] and $3FF)) and (FReg[5] and 4 <> 0) then
    FStatus := FStatus or 4;
  if Line = Height then
  begin
    if FReg[5] and 8 <> 0 then
      FStatus := FStatus or $20;
    if FSATPending or (FReg[15] and $10 <> 0) then
    begin
      FSATPosition := 0;
      FSATCycles := 0;
      FSATPending := False;
    end;
  end;
  if (Line < 0) or (Line >= Height) then
    Exit;
  var W := Width;
  var MW := MapWidths[(FReg[9] shr 4) and 3];
  var MH := 32 shl ((FReg[9] shr 6) and 1);
  var SY := FScrollY and (MH * 8 - 1);
  FScrollY := (FScrollY + 1) and $1FF;
  if Options.ShowBackground and (FReg[5] and $80 <> 0) then
    for var PX := 0 to W - 1 do
    begin
      var SX := (PX + FReg[7]) and (MW * 8 - 1);
      var BAT := FVRAM[((SY shr 3) * MW + (SX shr 3)) and $7FFF];
      var Pattern := ((BAT and $FFF) * 16 + (SY and 7)) and $7FFF;
      var B0 := FVRAM[Pattern];
      var B1 := FVRAM[(Pattern + 8) and $7FFF];
      var Bit := 7 - (SX and 7);
      var C := ((B0 shr Bit) and 1) or (((B0 shr (Bit + 8)) and 1) shl 1) or
        (((B1 shr Bit) and 1) shl 2) or (((B1 shr (Bit + 8)) and 1) shl 3);
      if FReg[9] and 3 = 3 then
        if FReg[9] and $80 = 0 then
          C := C and 3
        else
          C := C and 12;
      if C <> 0 then
        Pixels[PX] := ((BAT shr 12) * 16 + C);
    end;
  var Count := 0;
  // SAT order resolves sprite priority before the background priority bit.
  for var S := 0 to 63 do
  begin
    var Y := Integer(FSAT[S * 4] and $3FF) - 64;
    var X := Integer(FSAT[S * 4 + 1] and $3FF) - 32;
    var Attr := FSAT[S * 4 + 3];
    var SH := SpriteHeights[(Attr shr 12) and 3];
    var SW := 16 shl ((Attr shr 8) and 1);
    if (Line < Y) or (Line >= Y + SH) then
      Continue;
    Inc(Count, SW div 16);
    if Count > 16 then
    begin
      if FReg[5] and 2 <> 0 then
        FStatus := FStatus or 2;
      if not Options.RemoveSpriteLimit then
        Break;
    end;
    if FReg[5] and $40 = 0 then
      Continue;
    var RY := Line - Y;
    if Attr and $8000 <> 0 then
      RY := SH - 1 - RY;
    var Tile := (FSAT[S * 4 + 2] shr 1) and $3FF;
    if SW = 32 then
      Tile := Tile and not 1;
    if SH >= 32 then
      Tile := Tile and not 2;
    if SH = 64 then
      Tile := Tile and not 4;
    for var CX := 0 to SW - 1 do
    begin
      var DX := X + CX;
      if (DX < 0) or (DX >= W) then
        Continue;
      var RX := CX;
      if Attr and $800 <> 0 then
        RX := SW - 1 - RX;
      var Pattern := ((Tile + (RY div 16) * 2 + (RX div 16)) * 64 + (RY and 15)) and $7FFF;
      var Bit := 15 - (RX and 15);
      var C := 0;
      for var Plane := 0 to 3 do
        C := C or (((FVRAM[(Pattern + Plane * 16) and $7FFF] shr Bit) and 1) shl Plane);
      if C = 0 then
        Continue;
      if Owners[DX] >= 0 then
      begin
        if (Owners[DX] = 0) and (Count <= 16) and (FReg[5] and 1 <> 0) then
          FStatus := FStatus or 1;
        Continue;
      end;
      Owners[DX] := S;
      if Options.ShowSprites and ((Attr and $80 <> 0) or (Pixels[DX] and $8000 <> 0)) then
        Pixels[DX] := $100 or ((Attr and 15) * 16 + C);
    end;
  end;
end;

procedure THuC6270.SerializeState(State: TStateArchive);
begin
  State.Field(FVRAM, SizeOf(FVRAM));
  State.Field(FSAT, SizeOf(FSAT));
  State.Field(FReg, SizeOf(FReg));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FWriteLow, SizeOf(FWriteLow));
  State.Field(FReadBuffer, SizeOf(FReadBuffer));
  State.Field(FSATPending, SizeOf(FSATPending));
  State.Field(FScrollY, SizeOf(FScrollY));
  State.Field(FScrollPending, SizeOf(FScrollPending));
  State.Field(FDMAPending, SizeOf(FDMAPending));
  State.Field(FDMACycles, SizeOf(FDMACycles));
  State.Field(FSATCycles, SizeOf(FSATCycles));
  State.Field(FSATPosition, SizeOf(FSATPosition));
  if State.Loading and (FLatch > 31) then
    raise EReadError.Create('Invalid VDC latch');
end;

constructor TPCEVideo.Create(SuperGrafx: Boolean);
begin
  inherited Create;
  FSuperGrafx := SuperGrafx;
  FVDC[0] := THuC6270.Create;
  if SuperGrafx then
    FVDC[1] := THuC6270.Create;
  Reset;
end;

destructor TPCEVideo.Destroy;
begin
  FVDC[0].Free;
  FVDC[1].Free;
  inherited;
end;

procedure TPCEVideo.Reset;
begin
  FVDC[0].Reset;
  if FVDC[1] <> nil then
    FVDC[1].Reset;
  FillChar(FPalette, SizeOf(FPalette), 0);
  FillChar(FVPC, SizeOf(FVPC), 0);
  FVPC[0] := $11;
  FVPC[1] := $11;
  FVCEAddress := 0;
  FVCEControl := 0;
end;

function TPCEVideo.Width: Integer;
begin
  Result := FVDC[0].Width;
end;

function TPCEVideo.Height: Integer;
begin
  Result := Min(242, FVDC[0].Height);
end;

function TPCEVideo.Lines: Integer;
begin
  Result := 262 + Ord(FVCEControl and 4 <> 0);
end;

function TPCEVideo.IRQ: Boolean;
begin
  Result := FVDC[0].IRQ or ((FVDC[1] <> nil) and FVDC[1].IRQ);
end;

procedure TPCEVideo.StoreVDC(Port: Word; Value: Byte);
begin
  FVDC[Ord(FSuperGrafx and (FVPC[6] and 1 <> 0))].Write(Port, Value);
end;

function TPCEVideo.Read(Port: Word): Byte;
begin
  if Port < $400 then
  begin
    Port := Port and $1F;
    if not FSuperGrafx or (Port < 8) then
      Exit(FVDC[0].Read(Port));
    if Port in [8..13] then
      Exit(FVPC[Port - 8]);
    if Port in [16..23] then
      Exit(FVDC[1].Read(Port));
    Exit($FF);
  end;
  Result := $FF;
  case Port and 7 of
    4:
      Result := FPalette[FVCEAddress] and 255;
    5:
      begin
        Result := $FE or (FPalette[FVCEAddress] shr 8);
        FVCEAddress := (FVCEAddress + 1) and 511;
      end;
  end;
end;

procedure TPCEVideo.Write(Port: Word; Value: Byte);
begin
  if Port < $400 then
  begin
    Port := Port and $1F;
    if not FSuperGrafx or (Port < 8) then
      FVDC[0].Write(Port, Value)
    else if Port in [8..14] then
      FVPC[Port - 8] := Value
    else if Port in [16..23] then
      FVDC[1].Write(Port, Value);
    Exit;
  end;
  case Port and 7 of
    0:
      FVCEControl := Value;
    2:
      FVCEAddress := (FVCEAddress and 256) or Value;
    3:
      FVCEAddress := (FVCEAddress and 255) or ((Word(Value) and 1) shl 8);
    4:
      FPalette[FVCEAddress] := (FPalette[FVCEAddress] and 256) or Value;
    5:
      begin
        FPalette[FVCEAddress] := (FPalette[FVCEAddress] and 255) or ((Word(Value) and 1) shl 8);
        FVCEAddress := (FVCEAddress + 1) and 511;
      end;
  end;
end;

procedure TPCEVideo.Scanline(Line: Integer; var Pixels: TArray<TAlphaColor>; const Options: TPCEOptions; OutputWidth, OutputHeight: Integer);
var
  Rows: array[0..1] of TPCEPixelRow;
begin
  FVDC[0].Scanline(Line - FVDC[0].DisplayStart, Rows[0], Options);
  if FSuperGrafx then
    FVDC[1].Scanline(Line - FVDC[1].DisplayStart, Rows[1], Options);
  Line := Line - FVDC[0].DisplayStart;
  if (Line < 0) or (Line >= Height) or (Line >= OutputHeight) then
    Exit;
  var W := Min(Width, OutputWidth);
  for var X := 0 to W - 1 do
  begin
    var Index := Rows[0][X];
    if FSuperGrafx then
    begin
      var Region := Ord(X + 64 >= (Integer(FVPC[2]) or ((FVPC[3] and 3) shl 8))) or
        (Ord(X + 64 >= (Integer(FVPC[4]) or ((FVPC[5] and 3) shl 8))) shl 1);
      var Priority := (FVPC[Region div 2] shr ((Region and 1) * 4)) and 15;
      var A := Rows[0][X];
      var B := Rows[1][X];
      if Priority and 1 = 0 then
        A := $8000;
      if Priority and 2 = 0 then
        B := $8000;
      Index := A;
      if (A and $8000 <> 0) or
        ((Priority and 12 = 4) and (B and $100 <> 0) and (A and $100 = 0)) or
        ((Priority and 12 = 8) and (A and $100 <> 0) and (B and $100 = 0)) then
        if B and $8000 = 0 then
          Index := B;
    end;
    if Index and $8000 <> 0 then
      Index := 0;
    var Color := FPalette[Index and 511];
    var R := ((Color shr 3) and 7) * 255 div 7;
    var G := ((Color shr 6) and 7) * 255 div 7;
    var B := (Color and 7) * 255 div 7;
    if FVCEControl and $80 <> 0 then
    begin
      R := (R * 30 + G * 59 + B * 11) div 100;
      G := R;
      B := R;
    end;
    var Offset := Line * OutputWidth + X;
    if Offset < Length(Pixels) then
      Pixels[Offset] := $FF000000 or
        (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
  end;
end;

procedure TPCEVideo.Advance(Cycles, Line: Integer);
const
  Divider: array[0..3] of Integer = (4, 3, 2, 2);
begin
  for var I := 0 to Ord(FSuperGrafx) do
  begin
    var Start := FVDC[I].DisplayStart;
    FVDC[I].Advance(Cycles, Divider[FVCEControl and 3], (Line < Start) or (Line >= Start + FVDC[I].Height));
  end;
end;

procedure TPCEVideo.SerializeState(State: TStateArchive);
begin
  FVDC[0].SerializeState(State);
  if FSuperGrafx then
    FVDC[1].SerializeState(State);
  State.Field(FPalette, SizeOf(FPalette));
  State.Field(FVCEAddress, SizeOf(FVCEAddress));
  State.Field(FVCEControl, SizeOf(FVCEControl));
  State.Field(FVPC, SizeOf(FVPC));
  if State.Loading and (FVCEAddress > 511) then
    raise EReadError.Create('Invalid VCE address');
end;

end.

