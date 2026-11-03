unit CV.F18A;

interface

uses
  System.SysUtils, System.UITypes, SG1000.VDP, Core.Snapshots, CV.F18A.GPU;

type
  // F18A v1.9 enhanced VDP. Register and bus contracts checked against the
  // manufacturer's BSD HDL: https://github.com/dnotq/f18a .
  TCVF18A = class(TSGVDP)
  private
    type
      TPixel = record
        Color: Byte;
        Opaque, Priority: Boolean;
      end;
  private
    FR: array[0..63] of Byte;
    FPalette: array[0..63] of Word;
    FGPURAM: array[0..$7FF] of Byte;
    FDMA: array[0..7] of Byte;
    FGPU: TCVF18AGPU;
    FUnlocked, FUnlockPending, FPaletteMode, FPalettePending, FLineIRQ: Boolean;
    FPaletteIndex, FPaletteLatch, FRegisterRead, FUserStatus: Byte;
    FWidth, FHeight, FLine, FLineClocks, FRasterX: Integer;
    FGPUPhase: Int64;
    FCounter, FCounterSnapshot: UInt64;
    FTileLine, FSpriteLine: array[0..511] of TPixel;
    procedure ResetRegisters;
    procedure Geometry;
    procedure FlushRaster;
    procedure IncrementAddress;
    procedure SetRegister(Index, Value: Byte; GPU: Boolean = False);
    function Status(Index: Integer): Byte;
    function PatternPixel(Address, X, ECM, Offset: Integer): Byte;
    procedure TileLayer(Y: Integer; Layer: Integer);
    procedure BitmapLayer(Y: Integer);
    procedure Sprites(Y: Integer);
    procedure Compose(Y, First, Last: Integer);
    procedure RunDMA;
  protected
    function Color(Index: Integer): TAlphaColor; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Advance(Cycles: Integer);
    procedure EndLine(Line, TotalLines: Integer); override;
    function ReadData: Byte; override;
    function ReadStatus: Byte; override;
    procedure WriteData(Value: Byte); override;
    procedure WriteControl(Value: Byte); override;
    function Interrupt: Boolean; override;
    procedure VBlank; override;
    procedure RenderLine(Y: Integer); override;
    function ScreenHeight: Integer; override;
    function ScreenWidth: Integer;
    function GPURead(Address: Word): Byte;
    procedure GPUWrite(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive); override;
    property GPU: TCVF18AGPU read FGPU;
    property Unlocked: Boolean read FUnlocked;
  end;

implementation

uses
  System.Classes, System.Math;

const
  F18AInitialGPU: array[0..469] of Byte = (
    $02, $0F, $47, $FE, $10, $0D, $40, $36, $40, $5A, $40, $94, $40, $B4, $40, $FA,
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,
    $0C, $A0, $41, $1C, $03, $40, $04, $C1, $D0, $60, $3F, $00, $09, $71, $C0, $21,
    $40, $06, $06, $90, $10, $F7, $C0, $20, $3F, $02, $C0, $60, $3F, $04, $C0, $A0,
    $3F, $06, $D0, $E0, $3F, $01, $13, $05, $D0, $10, $DC, $40, $06, $02, $16, $FD,
    $10, $03, $DC, $70, $06, $02, $16, $FD, $04, $5B, $0D, $0B, $06, $A0, $40, $B4,
    $0F, $0B, $C1, $C7, $13, $16, $04, $C0, $D0, $20, $60, $04, $0A, $30, $C0, $C0,
    $04, $C1, $02, $02, $04, $00, $CC, $01, $06, $02, $16, $FD, $04, $C0, $D0, $20,
    $41, $4F, $06, $C0, $0A, $30, $A0, $03, $0C, $A0, $41, $AC, $D8, $20, $41, $4F,
    $B0, $00, $04, $5B, $D8, $20, $41, $1A, $3F, $00, $02, $00, $41, $D4, $C8, $00,
    $3F, $02, $02, $00, $40, $06, $C8, $00, $3F, $04, $02, $00, $40, $10, $C8, $00,
    $3F, $06, $04, $5B, $04, $C7, $D0, $20, $3F, $01, $13, $13, $C0, $20, $41, $18,
    $06, $00, $0C, $A0, $41, $50, $02, $04, $00, $05, $02, $05, $3F, $02, $02, $06,
    $41, $40, $8D, $B5, $16, $03, $06, $04, $16, $FC, $10, $09, $06, $00, $16, $F1,
    $10, $09, $C0, $20, $3F, $02, $0C, $A0, $41, $50, $80, $40, $14, $03, $0C, $A0,
    $41, $98, $05, $47, $D8, $07, $B0, $00, $04, $5B, $0D, $0B, $06, $A0, $40, $B4,
    $0F, $0B, $C1, $C7, $13, $04, $C0, $20, $3F, $0C, $0C, $A0, $41, $AC, $04, $5B,
    $05, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $02, $00, $41, $10,
    $02, $01, $41, $14, $02, $02, $0B, $00, $03, $A0, $32, $02, $32, $30, $32, $30,
    $32, $30, $02, $02, $00, $07, $36, $31, $06, $02, $16, $FD, $03, $C0, $0C, $00,
    $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $00, $00, $00, $00, $00, $00,
    $88, $00, $41, $18, $1A, $03, $C0, $60, $41, $18, $0C, $00, $0D, $00, $0A, $40,
    $02, $01, $0B, $00, $A0, $20, $41, $16, $17, $01, $05, $81, $A0, $60, $41, $14,
    $02, $03, $41, $40, $02, $02, $00, $10, $03, $A0, $32, $01, $06, $C1, $32, $01,
    $32, $00, $06, $C0, $32, $00, $36, $00, $36, $33, $06, $02, $16, $FD, $03, $C0,
    $0F, $00, $C0, $60, $41, $18, $0C, $00, $02, $00, $3F, $00, $02, $01, $41, $40,
    $02, $02, $00, $08, $CC, $31, $06, $02, $16, $FD, $0C, $00, $02, $01, $41, $4A,
    $D0, $A0, $41, $4E, $06, $C2, $D0, $A0, $41, $4D, $02, $03, $0B, $00, $03, $A0,
    $32, $03, $32, $31, $32, $31, $32, $31, $36, $01, $36, $30, $06, $02, $16, $FD,
    $03, $C0, $0C, $00, $03, $40);

const
  InitialPalette: array[0..63] of Word = (
    $000, $000, $2C3, $5D6, $54F, $76F, $D54, $4EF, $F54, $F76, $DC3, $ED6, $2B2, $C5C, $CCC, $FFF,
    $000, $2C3, $000, $54F, $000, $D54, $000, $4EF, $000, $CCC, $000, $DC3, $000, $C5C, $000, $FFF,
    $000, $00A, $0A0, $0AA, $A00, $A0A, $A50, $AAA, $555, $55F, $5F5, $5FF, $F55, $F5F, $FF5, $FFF,
    $000, $555, $000, $00A, $000, $0A0, $000, $0AA, $000, $A00, $000, $A0A, $000, $A50, $000, $FFF);

constructor TCVF18A.Create;
begin
  inherited Create;
  FGPU := TCVF18AGPU.Create(GPURead, GPUWrite);
  Reset;
end;

destructor TCVF18A.Destroy;
begin
  FGPU.Free;
  inherited;
end;

procedure TCVF18A.ResetRegisters;
begin
  FillChar(FR, SizeOf(FR), 0);
  FR[1] := $40;
  FR[3] := $10;
  FR[4] := 1;
  FR[5] := $0A;
  FR[6] := 2;
  FR[7] := $1F;
  FR[30] := $1F;
  FR[48] := 1;
  FR[51] := $20;
  FR[54] := $40;
  Move(FR[0], FRegisters[0], SizeOf(FRegisters));
  FUnlocked := False;
  FUnlockPending := False;
  FPaletteMode := False;
  FPalettePending := False;
end;

procedure TCVF18A.Reset;
begin
  inherited;
  ResetRegisters;
  Move(InitialPalette, FPalette, SizeOf(FPalette));
  FillChar(FGPURAM, SizeOf(FGPURAM), 0);
  Move(F18AInitialGPU, FGPURAM, SizeOf(F18AInitialGPU));
  FillChar(FDMA, SizeOf(FDMA), 0);
  FUserStatus := 0;
  FRegisterRead := 0;
  FPaletteIndex := 0;
  FPaletteLatch := 0;
  FLineIRQ := False;
  FLine := 0;
  FLineClocks := 0;
  FRasterX := 0;
  FGPUPhase := 0;
  FCounter := 0;
  FCounterSnapshot := 0;
  FWidth := 256;
  FHeight := 192;
  SetLength(FPixels, FWidth * FHeight);
  if FGPU <> nil then
  begin
    FGPU.Reset;
    FGPU.Load($4000, True);
  end;
end;

function TCVF18A.ScreenWidth: Integer;
begin
  Result := FWidth;
end;

function TCVF18A.ScreenHeight: Integer;
begin
  Result := FHeight;
  if Result = 0 then
    Result := 192; // inherited constructor dispatches Reset
end;

procedure TCVF18A.Geometry;
begin
  var Width := 256;
  if FR[0] and 4 <> 0 then
    Width := 512;
  var Height := 192;
  if FR[49] and $40 <> 0 then
    Height := 240;
  if (Width <> FWidth) or (Height <> FHeight) then
  begin
    FWidth := Width;
    FHeight := Height;
    SetLength(FPixels, FWidth * FHeight);
    for var I := 0 to High(FPixels) do
      FPixels[I] := Color(FR[7] and 15);
  end;
end;

function TCVF18A.Color(Index: Integer): TAlphaColor;
begin
  var C := FPalette[Index and 63];
  Result := $FF000000 or (Cardinal((C shr 8) and 15) * 17 shl 16) or
    (Cardinal((C shr 4) and 15) * 17 shl 8) or (Cardinal(C and 15) * 17);
end;

procedure TCVF18A.IncrementAddress;
begin
  var Increment := Integer(FR[48]);
  if Increment >= 128 then
    Dec(Increment, 256);
  FAddress := (FAddress + Increment) and $3FFF;
end;

function TCVF18A.ReadData: Byte;
begin
  FControlPending := False;
  Result := FReadBuffer;
  FReadBuffer := FVRAM[FAddress];
  IncrementAddress;
end;

procedure TCVF18A.WriteData(Value: Byte);
begin
  FlushRaster;
  FControlPending := False;
  if FPaletteMode then
  begin
    if not FPalettePending then
    begin
      FPaletteLatch := Value and 15;
      FPalettePending := True;
    end
    else
    begin
      FPalette[FPaletteIndex] := (Word(FPaletteLatch) shl 8) or Value;
      FPalettePending := False;
      if FR[47] and $40 <> 0 then
      begin
        FPaletteIndex := (FPaletteIndex + 1) and 63;
        if FPaletteIndex = 0 then
          FPaletteMode := False;
      end
      else
        FPaletteMode := False;
    end;
    Exit;
  end;
  FVRAM[FAddress] := Value;
  FReadBuffer := Value;
  IncrementAddress;
end;

procedure TCVF18A.WriteControl(Value: Byte);
begin
  if not FControlPending then
  begin
    FAddress := (FAddress and $3F00) or Value;
    FControlPending := True;
    Exit;
  end;
  var Data := FAddress and $FF;
  FAddress := ((Integer(Value and $3F) shl 8) or Data) and $3FFF;
  FControlPending := False;
  if Value and $80 <> 0 then
    SetRegister(Value and $3F, Data)
  else if Value and $40 = 0 then
  begin
    FReadBuffer := FVRAM[FAddress];
    FRegisterRead := FR[(FAddress shr 8) and 63];
    IncrementAddress;
  end;
end;

procedure TCVF18A.SetRegister(Index, Value: Byte; GPU: Boolean);
begin
  FlushRaster;
  if Index = 57 then
  begin
    var Valid := Value and $FC = $1C;
    FUnlocked := Valid and FUnlockPending;
    FUnlockPending := Valid;
    Exit;
  end;
  if not GPU and not FUnlocked then
    if Index >= 8 then
      if FR[0] and 4 <> 0 then
        Exit
      else
        Index := Index and 7;
  FUnlockPending := False;
  case Index of
    0:
      Value := Value and $16;
    1:
      Value := Value and $7B;
    2, 10:
      Value := Value and 15;
    4, 6:
      Value := Value and 7;
    5:
      Value := Value and $7F;
    15:
      begin
        if Value and $20 <> 0 then
          FCounterSnapshot := FCounter;
        if Value and $40 <> 0 then
          FCounter := 0;
        Value := Value and $1F;
      end;
    24, 51:
      Value := Value and $3F;
    30:
      begin
        Value := Value and 31;
        if Value = 0 then
          Value := 31;
      end;
    47:
      if not GPU then
      begin
        FPaletteMode := Value and $80 <> 0;
        FPaletteIndex := Value and 63;
        FPalettePending := False;
      end;
    49:
      Value := Value and $FB;
    50:
      if Value and $80 <> 0 then
      begin
        ResetRegisters;
        Exit;
      end;
    55:
      if not GPU and (FGPU <> nil) then
        FGPU.Load((Word(FR[54]) shl 8) or Value, True);
    56:
      begin
        if not GPU and (FGPU <> nil) then
          if Value and 1 <> 0 then
            FGPU.Trigger
          else
            FGPU.Load((Word(FR[54]) shl 8) or FR[55], False);
        Exit;
      end;
    3, 7, 11, 19, 25..29, 31..36, 48, 54:
      ;
  else
    Exit;
  end;
  FR[Index] := Value;
  if Index < 8 then
    FRegisters[Index] := Value;
  if (Index = 19) and (Value <> 0) and (Value = FLine) then
    FLineIRQ := True;
end;

function TCVF18A.Status(Index: Integer): Byte;
begin
  Result := 0;
  var Ticks := FCounterSnapshot;
  case Index of
    0:
      Result := FStatus;
    1:
      Result := $E0 or (Ord((FLine >= FHeight) or (FLineClocks < 37)) shl 1) or Ord(FLineIRQ);
    2:
      Result := (Ord((FGPU <> nil) and FGPU.Running) shl 7) or FUserStatus;
    3:
      if FLine < FHeight then
        Result := FLine;
    4:
      Result := ((Ticks mod 100) * 10) and $FF;
    5:
      Result := ((Ticks mod 100) * 10) shr 8;
    6:
      Result := (Ticks div 100 mod 1000) and $FF;
    7:
      Result := (Ticks div 100 mod 1000) shr 8;
    8:
      Result := (Ticks div 100000 mod 1000) and $FF;
    9:
      Result := (Ticks div 100000 mod 1000) shr 8;
    10:
      Result := (Ticks div 100000000) and $FF;
    11:
      Result := (Ticks div 100000000 shr 8) and $FF;
    14:
      Result := $19;
    15:
      Result := FRegisterRead;
  end;
end;

function TCVF18A.ReadStatus: Byte;
begin
  FlushRaster;
  Result := Status(FR[15] and 15);
  if FR[15] and 15 = 0 then
    FStatus := FStatus and $1F;
  if FR[15] and 15 = 1 then
    FLineIRQ := False;
  FControlPending := False;
  FPaletteMode := False;
  FPalettePending := False;
end;

function TCVF18A.Interrupt: Boolean;
begin
  Result := inherited Interrupt or ((FR[0] and $10 <> 0) and FLineIRQ);
end;

procedure TCVF18A.VBlank;
begin
  inherited;
  if (FGPU <> nil) and (FR[50] and $20 <> 0) then
    FGPU.Trigger;
end;

procedure TCVF18A.Advance(Cycles: Integer);
begin
  Inc(FLineClocks, Cycles);
  Inc(FGPUPhase, Int64(Cycles) * 100000000);
  var Clocks := FGPUPhase div 3579545;
  FGPUPhase := FGPUPhase mod 3579545;
  if FR[15] and $10 <> 0 then
    FCounter := (FCounter + UInt64(Clocks)) mod (UInt64(65536) * 100000000);
  if FGPU <> nil then
    FGPU.Advance(Clocks);
end;

procedure TCVF18A.EndLine(Line, TotalLines: Integer);
begin
  FLineClocks := 0;
  FRasterX := 0;
  FLine := (Line + 1) mod TotalLines;
  if Line = FHeight - 1 then
    VBlank;
  if (FGPU <> nil) and (FR[50] and $40 <> 0) then
    FGPU.Trigger;
  if (FR[19] <> 0) and (FLine = FR[19]) then
    FLineIRQ := True;
  if FLine = 0 then
    Geometry;
end;

procedure TCVF18A.FlushRaster;
begin
  if (FLine >= FHeight) or (FWidth = 0) then
    Exit;
  var Last := EnsureRange((FLineClocks - 37) * FWidth div 171, 0, FWidth);
  if Last > FRasterX then
  begin
    Compose(FLine, FRasterX, Last);
    FRasterX := Last;
  end;
end;

function TCVF18A.PatternPixel(Address, X, ECM, Offset: Integer): Byte;
begin
  var Bit := $80 shr (X and 7);
  Result := Ord(VRAM(Address) and Bit <> 0);
  if ECM >= 2 then
    Result := Result or (Ord(VRAM(Address + Offset) and Bit <> 0) shl 1);
  if ECM = 3 then
    Result := Result or (Ord(VRAM(Address + Offset * 2) and Bit <> 0) shl 2);
end;

procedure TCVF18A.TileLayer(Y: Integer; Layer: Integer);
begin
  var Mode := ((FR[1] shr 4) and 1) or ((FR[1] shr 2) and 2) or ((FR[0] and 6) shl 1);
  var Text := Mode in [1, 9];
  var Columns := 32;
  var Cell := 8;
  var Origin := 0;
  if Text then
  begin
    Cell := 6;
    Columns := 40;
    Origin := 8;
    if FWidth = 512 then
    begin
      Columns := 80;
      Origin := 16;
    end;
  end;
  var NameBase := Integer(FR[2]);
  var ColorBase := Integer(FR[3]);
  var HScroll := Integer(FR[27]);
  var VScroll := Integer(FR[28]);
  var Palette := FR[24] and 3;
  if Layer = 1 then
  begin
    NameBase := FR[10];
    ColorBase := FR[11];
    HScroll := FR[25];
    VScroll := FR[26];
    Palette := (FR[24] shr 2) and 3;
  end;
  var ECM := 0;
  if FUnlocked then
    ECM := (FR[49] shr 4) and 3;
  var Rows := FHeight div 8;
  var PatternOffset := 2048 shr ((FR[29] shr 2) and 3);
  for var X := Origin to FWidth - Origin - 1 do
  begin
    var SX := X - Origin + HScroll;
    if not Text and (FWidth > 256) then
      SX := (X - Origin) div 2 + HScroll;
    var SY := Y + VScroll;
    var Col := SX div Cell;
    var Row := SY div 8;
    var HP := NameBase and 1;
    var VP := (NameBase shr 1) and 1;
    var HSize := (FR[29] shr (Layer * 4 + 1)) and 1;
    var VSize := (FR[29] shr (Layer * 4)) and 1;
    var Position: Integer;
    if Text then
      Position := (Row mod (Rows * 2)) * Columns + Col mod Columns
    else
    begin
      if HSize <> 0 then
        HP := (HP + Col div 32) and 1;
      if VSize <> 0 then
        VP := (VP + Row div Rows) and 1;
      Position := VP * 2048 + HP * 1024 + (Row mod Rows) * 32 + (Col and 31);
    end;
    var NameAddress := (NameBase and $C) * 1024 + Position;
    if Text then
      NameAddress := NameBase * 1024 + Position;
    var Name := Integer(VRAM(NameAddress));
    var Attribute := VRAM(ColorBase * 64 + Name);
    if FR[50] and 2 <> 0 then
      Attribute := VRAM(ColorBase * 64 + Position);
    var PX := SX mod Cell;
    var PY := SY and 7;
    if ECM <> 0 then
    begin
      if Attribute and $40 <> 0 then
        PX := 7 - PX;
      if Attribute and $20 <> 0 then
        PY := 7 - PY;
    end;
    var Address := Integer(FR[4]) * 2048 + Name * 8 + PY;
    var Region := (Row mod Rows div 8) * 256;
    if Mode in [4, 5] then
      Address := (FR[4] and 4) * 2048 +
        ((Name + Region) and (((FR[4] and 3) shl 8) or $FF)) * 8 + PY;
    var Pixel := Integer(PatternPixel(Address, PX, ECM, PatternOffset));
    var Index: Integer;
    var Opaque: Boolean;
    if ECM = 0 then
    begin
      var Colors := FR[7];
      if Text then
      begin
        if FR[50] and 2 <> 0 then
          Colors := Attribute;
      end
      else if Mode = 2 then
      begin
        Colors := VRAM(Integer(FR[4]) * 2048 + Name * 8 + ((SY div 4) and 7));
        Pixel := Ord(PX < 4);
      end
      else if Mode = 4 then
        Colors := VRAM((FR[3] and $80) * 64 +
          ((Name + Region) and (((FR[3] and $7F) shl 3) or 7)) * 8 + PY)
      else
        Colors := VRAM(ColorBase * 64 + Name div 8);
      Index := Colors and 15;
      if Pixel <> 0 then
        Index := Colors shr 4;
      Opaque := Index <> 0;
      Index := Palette * 16 + Index;
    end
    else
    begin
      Opaque := (Attribute and $10 = 0) or (Pixel <> 0);
      case ECM of
        1:
          Index := (Palette and 2) * 16 + (Attribute and 15) * 2 + Pixel;
        2:
          Index := (Attribute and 15) * 4 + Pixel;
      else
        Index := (Attribute and 14) * 4 + Pixel;
      end;
    end;
    if Opaque then
    begin
      FTileLine[X].Color := Index and 63;
      FTileLine[X].Opaque := True;
      FTileLine[X].Priority := ((ECM <> 0) and (Attribute and $80 <> 0)) or
        ((Layer = 1) and (FR[50] and 1 = 0));
    end;
  end;
end;

procedure TCVF18A.BitmapLayer(Y: Integer);
begin
  if not FUnlocked or (FR[31] and $80 = 0) then
    Exit;
  var LocalY := Y - Integer(FR[34]);
  if (LocalY < 0) or (LocalY >= FR[36]) then
    Exit;
  var Width := Integer(FR[35]);
  if Width = 0 then
    Width := 256;
  for var X := 0 to FWidth - 1 do
  begin
    var LocalX := X;
    if FWidth > 256 then
      LocalX := LocalX div 2;
    Dec(LocalX, FR[33]);
    if (LocalX < 0) or (LocalX >= Width) then
      Continue;
    var Data := VRAM(Integer(FR[32]) * 64 + LocalY * ((Width + 3) div 4) + LocalX div 4);
    var Pixel := (Data shr (6 - (LocalX and 3) * 2)) and 3;
    var Index := (FR[31] and 15) * 4 + Pixel;
    if FR[31] and $10 <> 0 then
    begin
      Pixel := (Data shr (4 - ((LocalX div 2) and 1) * 4)) and 15;
      Index := (FR[31] and $C) * 4 + Pixel;
    end;
    if (Pixel = 0) and (FR[31] and $20 <> 0) then
      Continue;
    if (FR[31] and $40 <> 0) or not FTileLine[X].Opaque then
    begin
      FTileLine[X].Color := Index and 63;
      FTileLine[X].Opaque := True;
      FTileLine[X].Priority := False;
    end;
  end;
end;

procedure TCVF18A.Sprites(Y: Integer);
begin
  FillChar(FSpriteLine, SizeOf(FSpriteLine), 0);
  var Text := (FR[1] and $10 <> 0);
  if Text and not FUnlocked then
    Exit;
  var Occupied: array[0..255] of Boolean;
  FillChar(Occupied, SizeOf(Occupied), 0);
  var Count := 0;
  var ECM := 0;
  if FUnlocked then
    ECM := FR[49] and 3;
  var Offset := 2048 shr (FR[29] shr 6);
  for var I := 0 to Min(31, Integer(FR[51]) - 1) do
  begin
    var Base := Integer(FR[5]) * 128 + I * 4;
    var RawY := VRAM(Base);
    if (FHeight = 192) and (RawY = $D0) then
      Break;
    var Attr := VRAM(Base + 3);
    var Size := 8;
    if (FR[1] and 2 <> 0) or (FUnlocked and (Attr and $10 <> 0)) then
      Size := 16;
    var Zoom := 1 + (FR[1] and 1);
    var Top := Integer(RawY) + Ord(FR[49] and 8 = 0);
    var Row := (Y - Top) and $FF;
    if Row >= Size * Zoom then
      Continue;
    Inc(Count);
    var Limit := 32;
    if FR[30] <> 31 then
      Limit := FR[30];
    if ((Count = 5) and (FR[50] and 8 = 0)) or (Count > Limit) then
      if FStatus and $C0 = 0 then
        FStatus := (FStatus and $A0) or $40 or I;
    if (Count > Limit) and not FRemoveSpriteLimit then
      Break;
    Row := Row div Zoom;
    if FUnlocked and (Attr and $20 <> 0) then
      Row := Size - 1 - Row;
    var Name := Integer(VRAM(Base + 2));
    if Size = 16 then
      Name := Name and $FC;
    var Left := Integer(VRAM(Base + 1));
    if Attr and $80 <> 0 then
      Dec(Left, 32);
    for var DX := 0 to Size * Zoom - 1 do
    begin
      var X := Left + DX;
      if (X < 0) or (X >= 256) then
        Continue;
      var PX := DX div Zoom;
      if FUnlocked and (Attr and $40 <> 0) then
        PX := Size - 1 - PX;
      var Address := Integer(FR[6]) * 2048 + Name * 8 + Row;
      if PX >= 8 then
        Inc(Address, 16);
      var Pixel := PatternPixel(Address, PX, ECM, Offset);
      if Pixel = 0 then
        Continue;
      if Count <= Limit then
      begin
        if Occupied[X] then
          FStatus := FStatus or $20;
        Occupied[X] := True;
      end;
      if (ECM = 0) and (Attr and 15 = 0) then
        Continue;
      var Index := ((FR[24] shr 4) and 3) * 16 + (Attr and 15);
      case ECM of
        1:
          Index := (FR[24] shr 5) * 32 + (Attr and 15) * 2 + Pixel;
        2:
          Index := (Attr and 15) * 4 + Pixel;
        3:
          Index := (Attr and 14) * 4 + Pixel;
      end;
      var Scale := FWidth div 256;
      for var RepeatX := 0 to Scale - 1 do
        if not FSpriteLine[X * Scale + RepeatX].Opaque then
        begin
          FSpriteLine[X * Scale + RepeatX].Color := Index and 63;
          FSpriteLine[X * Scale + RepeatX].Opaque := True;
        end;
    end;
  end;
end;

procedure TCVF18A.Compose(Y, First, Last: Integer);
begin
  var Backdrop := (FR[24] and 3) * 16 + (FR[7] and 15);
  for var X := 0 to FWidth - 1 do
  begin
    FTileLine[X] := Default(TPixel);
    FTileLine[X].Color := Backdrop;
  end;
  FillChar(FSpriteLine, SizeOf(FSpriteLine), 0);
  if FR[1] and $40 <> 0 then
  begin
    if FShowBackground and (FR[50] and $10 = 0) then
      TileLayer(Y, 0);
    if FShowBackground then
    begin
      BitmapLayer(Y);
      if FUnlocked and (FR[49] and $80 <> 0) then
        TileLayer(Y, 1);
    end;
    Sprites(Y);
  end;
  for var X := First to Last - 1 do
  begin
    var Pixel := FTileLine[X];
    if FShowSprites and FSpriteLine[X].Opaque and not Pixel.Priority then
      Pixel := FSpriteLine[X];
    FPixels[Y * FWidth + X] := Color(Pixel.Color);
  end;
end;

procedure TCVF18A.RenderLine(Y: Integer);
begin
  if (Y < 0) or (Y >= FHeight) then
    Exit;
  var First := 0;
  if Y = FLine then
    First := FRasterX;
  Compose(Y, First, FWidth);
end;

procedure TCVF18A.RunDMA;
begin
  var Source := (Integer(FDMA[0]) shl 8) or FDMA[1];
  var Dest := (Integer(FDMA[2]) shl 8) or FDMA[3];
  var Width := Integer(FDMA[4]);
  if Width = 0 then
    Width := 256;
  var Height := Integer(FDMA[5]);
  if Height = 0 then
    Height := 256;
  var Direction := 1;
  if FDMA[7] and 2 <> 0 then
    Direction := -1;
  // HDL uses a signed eight-bit stride difference, not a signed stride byte.
  var Diff := (Direction * (Integer(FDMA[6]) - (Width - 1))) and $FF;
  if Diff >= 128 then
    Dec(Diff, 256);
  var RowStep := Direction * (Width - 1) + Diff;
  var Fill := FVRAM[Source and $3FFF];
  for var Y := 0 to Height - 1 do
  begin
    for var X := 0 to Width - 1 do
      if FDMA[7] and 1 <> 0 then
        FVRAM[(Dest + X * Direction) and $3FFF] := Fill
      else
        FVRAM[(Dest + X * Direction) and $3FFF] := FVRAM[(Source + X * Direction) and $3FFF];
    Source := (Source + RowStep) and $FFFF;
    Dest := (Dest + RowStep) and $FFFF;
  end;
  FGPU.Stall(Width * Height * 2 + 4);
end;

function TCVF18A.GPURead(Address: Word): Byte;
begin
  Result := 0;
  case Address shr 12 of
    0..3:
      Result := FVRAM[Address];
    4:
      Result := FGPURAM[Address and $7FF];
    5:
      if Address and 1 = 0 then
        Result := FPalette[(Address shr 1) and 63] shr 8
      else
        Result := FPalette[(Address shr 1) and 63] and $FF;
    6:
      Result := FR[Address and 63];
    7:
      if Address and 1 = 0 then
        Result := Status(3)
      else
        Result := Status(1) and 2 shr 1;
    8:
      if Address and 15 < 8 then
        Result := FDMA[Address and 7];
    10:
      Result := $19;
  end;
end;

procedure TCVF18A.GPUWrite(Address: Word; Value: Byte);
begin
  FlushRaster;
  case Address shr 12 of
    0..3:
      FVRAM[Address] := Value;
    4:
      FGPURAM[Address and $7FF] := Value;
    5:
      begin
        var Index := (Address shr 1) and 63;
        if Address and 1 = 0 then
          FPalette[Index] := (FPalette[Index] and $FF) or (Word(Value and 15) shl 8)
        else
          FPalette[Index] := (FPalette[Index] and $F00) or Value;
      end;
    6:
      SetRegister(Address and 63, Value, True);
    8:
      if Address and 15 < 8 then
        FDMA[Address and 7] := Value
      else if Address and 15 = 8 then
        RunDMA;
    11:
      FUserStatus := Value and $7F;
  end;
end;

procedure TCVF18A.SerializeState(State: TStateArchive);
begin
  State.Field(FWidth, SizeOf(FWidth));
  State.Field(FHeight, SizeOf(FHeight));
  if ((FWidth <> 256) and (FWidth <> 512)) or not (FHeight in [192, 240]) then
    raise EReadError.Create('Invalid F18A dimensions');
  if State.Loading then
    SetLength(FPixels, FWidth * FHeight);
  State.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
  State.Field(FVRAM, SizeOf(FVRAM));
  State.Field(FR, SizeOf(FR));
  State.Field(FPalette, SizeOf(FPalette));
  State.Field(FGPURAM, SizeOf(FGPURAM));
  State.Field(FDMA, SizeOf(FDMA));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FReadBuffer, SizeOf(FReadBuffer));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FControlPending, SizeOf(FControlPending));
  State.Field(FUnlocked, SizeOf(FUnlocked));
  State.Field(FUnlockPending, SizeOf(FUnlockPending));
  State.Field(FPaletteMode, SizeOf(FPaletteMode));
  State.Field(FPalettePending, SizeOf(FPalettePending));
  State.Field(FLineIRQ, SizeOf(FLineIRQ));
  State.Field(FPaletteIndex, SizeOf(FPaletteIndex));
  State.Field(FPaletteLatch, SizeOf(FPaletteLatch));
  State.Field(FRegisterRead, SizeOf(FRegisterRead));
  State.Field(FUserStatus, SizeOf(FUserStatus));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineClocks, SizeOf(FLineClocks));
  State.Field(FRasterX, SizeOf(FRasterX));
  State.Field(FGPUPhase, SizeOf(FGPUPhase));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FCounterSnapshot, SizeOf(FCounterSnapshot));
  FGPU.SerializeState(State);
  if State.Loading then
  begin
    Move(FR[0], FRegisters[0], SizeOf(FRegisters));
    if (FAddress < 0) or (FAddress > $3FFF) or (FLine < 0) or (FLine >= 313) or
      (FLineClocks < 0) or (FLineClocks > 228) or (FRasterX < 0) or (FRasterX > FWidth) or
      (FPaletteIndex > 63) or (FPaletteLatch > 15) or (FUserStatus > $7F) or
      (FGPUPhase < 0) or (FGPUPhase >= 3579545) or
      (FCounter >= UInt64(65536) * 100000000) or
      (FCounterSnapshot >= UInt64(65536) * 100000000) then
      raise EReadError.Create('Invalid F18A state');
    for var Entry in FPalette do
      if Entry > $FFF then
        raise EReadError.Create('Invalid F18A palette');
  end;
end;

end.

