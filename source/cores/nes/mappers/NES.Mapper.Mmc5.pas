unit NES.Mapper.Mmc5;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperMmc5 = class(TMapperBanked)
  private
    FPrgRegisters: array[0..4] of Byte;
    FChrRegisters: array[0..11] of Integer;
    FCiram: array[0..$7FF] of Byte;
    FExRam: array[0..$3FF] of Byte;
    FPrgMode, FChrMode, FProtect1, FProtect2, FExMode, FNameMap, FFillTile, FFillColor, FChrUpper: Byte;
    FMultiplyA, FMultiplyB, FIrqTarget, FSplitControl, FSplitScroll, FSplitBank: Byte;
    FIrqEnabled, FPending, FInFrame, FSpriteFetch, FLargeSprites, FLastChrB: Boolean;
    FPixelX, FPixelY, FExTile: Integer;
    function CpuBank(Address: UInt16; out IsRam: Boolean): Integer;
    function PatternOffset(Address: UInt16): Integer;
    function SplitActive: Boolean;
    function NameSource(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); override;
    procedure SetPpuControl(Value: UInt8); override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperMmc5.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRegisters, SizeOf(FPrgRegisters));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FCiram, SizeOf(FCiram));
  State.Field(FExRam, SizeOf(FExRam));
  State.Field(FPrgMode, SizeOf(FPrgMode));
  State.Field(FChrMode, SizeOf(FChrMode));
  State.Field(FProtect1, SizeOf(FProtect1));
  State.Field(FProtect2, SizeOf(FProtect2));
  State.Field(FExMode, SizeOf(FExMode));
  State.Field(FNameMap, SizeOf(FNameMap));
  State.Field(FFillTile, SizeOf(FFillTile));
  State.Field(FFillColor, SizeOf(FFillColor));
  State.Field(FChrUpper, SizeOf(FChrUpper));
  State.Field(FMultiplyA, SizeOf(FMultiplyA));
  State.Field(FMultiplyB, SizeOf(FMultiplyB));
  State.Field(FIrqTarget, SizeOf(FIrqTarget));
  State.Field(FSplitControl, SizeOf(FSplitControl));
  State.Field(FSplitScroll, SizeOf(FSplitScroll));
  State.Field(FSplitBank, SizeOf(FSplitBank));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FInFrame, SizeOf(FInFrame));
  State.Field(FSpriteFetch, SizeOf(FSpriteFetch));
  State.Field(FLargeSprites, SizeOf(FLargeSprites));
  State.Field(FLastChrB, SizeOf(FLastChrB));
  State.Field(FPixelX, SizeOf(FPixelX));
  State.Field(FPixelY, SizeOf(FPixelY));
  State.Field(FExTile, SizeOf(FExTile));
end;

constructor TMapperMmc5.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited;
  SetLength(FPrgRam, $10000);
  Reset;
end;

procedure TMapperMmc5.Reset;
begin
  inherited;
  FillChar(FPrgRegisters, SizeOf(FPrgRegisters), 0);
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  FPrgRegisters[4] := $FF;
  FPrgMode := 3;
  FChrMode := 0;
  FProtect1 := 0;
  FProtect2 := 0;
  FExMode := 0;
  FNameMap := 0;
  FFillTile := 0;
  FFillColor := 0;
  FChrUpper := 0;
  FMultiplyA := $FF;
  FMultiplyB := $FF;
  FIrqTarget := 0;
  FSplitControl := 0;
  FSplitScroll := 0;
  FSplitBank := 0;
  FIrqEnabled := False;
  FPending := False;
  FInFrame := False;
  FSpriteFetch := False;
  FLargeSprites := False;
  FLastChrB := False;
  FPixelX := 0;
  FPixelY := 0;
  FExTile := 0;
end;

function TMapperMmc5.CpuBank(Address: UInt16; out IsRam: Boolean): Integer;
begin
  if Address < $8000 then
  begin
    IsRam := True;
    Exit(FPrgRegisters[0] and 7);
  end;
  var Slot := (Address - $8000) shr 13;
  var RegisterIndex := Slot + 1;
  var Span := 1;
  case FPrgMode of
    0:
      begin
        RegisterIndex := 4;
        Span := 4;
      end;
    1:
      begin
        RegisterIndex := 2 + (Slot shr 1) * 2;
        Span := 2;
      end;
    2:
      if Slot < 2 then
      begin
        RegisterIndex := 2;
        Span := 2;
      end;
  end;
  var Value := FPrgRegisters[RegisterIndex];
  IsRam := (RegisterIndex <> 4) and ((Value and $80) = 0);
  Result := ((Value and $7F) and not (Span - 1)) + (Slot and (Span - 1));
end;

function TMapperMmc5.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $6000 then
  begin
    var IsRam: Boolean;
    var Bank := CpuBank(Address, IsRam);
    if IsRam then
      Value := FPrgRam[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRam)]
    else
      Value := FPrgRom[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit;
  end;
  if (Address >= $5C00) and (Address <= $5FFF) then
  begin
    if FExMode >= 2 then
      Value := FExRam[Address and $3FF]
    else
      Value := 0;
    Exit;
  end;
  case Address of
    $5010, $5015:
      Value := 0;
    $5204:
      begin
        Value := (Ord(FPending) shl 7) or (Ord(FInFrame) shl 6);
        FPending := False;
      end;
    $5205:
      Value := (Integer(FMultiplyA) * FMultiplyB) and $FF;
    $5206:
      Value := (Integer(FMultiplyA) * FMultiplyB) shr 8;
  else
    Result := False;
  end;
end;

function TMapperMmc5.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $6000 then
  begin
    var IsRam: Boolean;
    var Bank := CpuBank(Address, IsRam);
    if IsRam and (FProtect1 = 2) and (FProtect2 = 1) then
      FPrgRam[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRam)] := Value;
    Exit;
  end;
  if (Address >= $5C00) and (Address <= $5FFF) then
  begin
    if FExMode = 2 then
      FExRam[Address and $3FF] := Value
    else if FExMode < 2 then
      if FInFrame then
        FExRam[Address and $3FF] := Value
      else
        FExRam[Address and $3FF] := 0;
    Exit;
  end;
  case Address of
    $5000..$5015:
      ;
    $5100:
      FPrgMode := Value and 3;
    $5101:
      FChrMode := Value and 3;
    $5102:
      FProtect1 := Value and 3;
    $5103:
      FProtect2 := Value and 3;
    $5104:
      FExMode := Value and 3;
    $5105:
      FNameMap := Value;
    $5106:
      FFillTile := Value;
    $5107:
      FFillColor := Value and 3;
    $5113..$5117:
      FPrgRegisters[Address - $5113] := Value;
    $5120..$512B:
      begin
        FChrRegisters[Address - $5120] := Value or (Integer(FChrUpper) shl 8);
        FLastChrB := Address >= $5128;
      end;
    $5130:
      FChrUpper := Value and 3;
    $5200:
      FSplitControl := Value;
    $5201:
      FSplitScroll := Value;
    $5202:
      FSplitBank := Value;
    $5203:
      FIrqTarget := Value;
    $5204:
      FIrqEnabled := (Value and $80) <> 0;
    $5205:
      FMultiplyA := Value;
    $5206:
      FMultiplyB := Value;
  else
    Result := False;
  end;
end;

function TMapperMmc5.SplitActive: Boolean;
begin
  Result := False;
  if FSpriteFetch or not FInFrame or (FExMode > 1) or ((FSplitControl and $80) = 0) then
    Exit;
  var Right := (FPixelX div 8) >= (FSplitControl and $1F);
  Result := Right = ((FSplitControl and $40) <> 0);
end;

function TMapperMmc5.PatternOffset(Address: UInt16): Integer;
begin
  if SplitActive then
    Exit(((Integer(FSplitBank) shl 12) + ((Address and $0FF8) or ((FPixelY + FSplitScroll) mod 240 and 7))) mod Length(FChrMemory));
  if (FExMode = 1) and FInFrame and not FSpriteFetch then
    Exit(((((FExRam[FExTile] and $3F) or (Integer(FChrUpper) shl 6)) shl 12) + (Address and $0FFF)) mod Length(FChrMemory));
  var UseB := FLargeSprites and ((FInFrame and not FSpriteFetch) or (not FInFrame and FLastChrB));
  var Slot := Address shr 10;
  var Span := 1 shl (3 - FChrMode);
  var Index := (Slot div Span) * Span + Span - 1;
  if UseB then
    Index := 8 + (Index and 3);
  Result := (FChrRegisters[Index] * Span * $400 + (Address and (Span * $400 - 1))) mod Length(FChrMemory);
end;

function TMapperMmc5.NameSource(Address: UInt16): Integer;
begin
  Result := (FNameMap shr (((Address and $0FFF) shr 10) * 2)) and 3;
end;

function TMapperMmc5.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;
  if Address < $2000 then
  begin
    Value := FChrMemory[PatternOffset(Address)];
    Exit;
  end;
  var Offset := Address and $3FF;
  if SplitActive then
  begin
    var Row := (FPixelY + FSplitScroll) mod 240;
    var Column := (FPixelX div 8) and $1F;
    if Offset < $3C0 then
      Value := FExRam[(Row div 8) * 32 + Column]
    else
      Value := ((FExRam[$3C0 + (Row div 32) * 8 + Column div 4] shr (((Row div 8) and 2) * 2 + (Column and 2))) and 3) * $55;
    Exit;
  end;
  if (FExMode = 1) and FInFrame and not FSpriteFetch then
    if Offset < $3C0 then
      FExTile := Offset
    else
    begin
      Value := (FExRam[FExTile] shr 6) * $55;
      Exit;
    end;
  case NameSource(Address) of
    0, 1:
      Value := FCiram[NameSource(Address) * $400 + Offset];
    2:
      if FExMode <= 1 then
        Value := FExRam[Offset]
      else
        Value := 0;
    3:
      if Offset < $3C0 then
        Value := FFillTile
      else
        Value := FFillColor * $55;
  end;
end;

function TMapperMmc5.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;
  if Address < $2000 then
  begin
    if FHasChrRam then
      FChrMemory[PatternOffset(Address)] := Value;
    Exit;
  end;
  var Offset := Address and $3FF;
  case NameSource(Address) of
    0, 1:
      FCiram[NameSource(Address) * $400 + Offset] := Value;
    2:
      if FExMode <= 1 then
        FExRam[Offset] := Value;
  end;
end;

procedure TMapperMmc5.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  FInFrame := Rendering and (Line >= 0) and (Line < 240);
  if FInFrame and (Line > 0) and (Line = FIrqTarget) then
    FPending := True;
end;

procedure TMapperMmc5.SetPpuFetchKind(Sprite: Boolean; X, Y: Integer);
begin
  FSpriteFetch := Sprite;
  FPixelX := X;
  FPixelY := Y;
end;

procedure TMapperMmc5.SetPpuControl(Value: UInt8);
begin
  FLargeSprites := (Value and $20) <> 0;
end;

function TMapperMmc5.IrqPending: Boolean;
begin
  Result := FPending and FIrqEnabled;
end;

end.

