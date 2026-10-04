unit NES.Mapper.Rainbow;

interface

uses
  System.Math, NES.State, NES.Types, NES.Mapper, NES.Mapper.VrcAudio;

type
  TRainbowFlash = record
    Step, Mode: Integer;
    SoftwareId, Bypass: Boolean;
  end;

  TMapperRainbow = class(TMapperVrcAudio)
  private
    FRegs: array[0..$685] of Byte;
    FHigh: array[0..7] of Word;
    FLow: array[0..1] of Word;
    FChr: array[0..15] of Word;
    FFpga: array[0..$1FFF] of Byte;
    FNames: array[0..$7FF] of Byte;
    FChrRam: TByteArray;
    FFlash: array[0..1] of TRainbowFlash;
    FOamCode: array[0..$505] of Byte;
    FOamLocked: Boolean;
    FCounter, FReload, FFpgaAddr, FLine, FReads, FIdle, FJitter, FLastAddress: Integer;
    FSlEnabled, FSlPending, FCpuEnabled, FCpuPending, FParity, FInFrame, FInHblank: Boolean;
    FFetchSprite, FWindow, FOverride: Boolean;
    FFetchX, FFetchY, FSpriteIndex, FExt, FOamAddress, FSpriteHeight: Integer;
    function CpuOffset(Address: UInt16; out Source: Integer): Integer;
    function ReadChrData(Source, Offset: Integer): Byte;
    function ChrOffsetRainbow(Address: UInt16): Integer;
    procedure FlashWrite(Chip, Offset: Integer; Value: Byte);
    function FlashRead(Chip, Offset: Integer): Byte;
    procedure AckIrq;
    procedure GenerateOam(Extended: Boolean);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    procedure ClockPpuRead; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); override;
    procedure SetPpuSpriteIndex(Index: Integer); override;
    procedure CpuIoWrite(Address: UInt16; Value: UInt8); override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

// Register and memory behavior follows Rainbow mapper version $21.
// Raster IRQ offsets still need validation against a Rainbow hardware ROM;
// the ESP interface currently reports a disconnected device.

constructor TMapperRainbow.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(MAPPER_RAINBOW, Prg, Chr, HasChrRam, MirrorMode);
  SetLength(FChrRam, $40000);
  SetLength(FPrgRam, $8000);
  Reset;
end;

procedure TMapperRainbow.Reset;
begin
  inherited;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FHigh, SizeOf(FHigh), 0);
  FillChar(FLow, SizeOf(FLow), 0);
  FillChar(FChr, SizeOf(FChr), 0);
  FRegs[$28] := 1;
  FRegs[$29] := 1;
  FRegs[$2F] := $80;
  FRegs[$53] := $87;
  FRegs[$142] := 6;
  FRegs[$141] := 7;
  FRegs[$AA] := 15;
  FCounter := 0;
  FReload := 0;
  FFpgaAddr := 0;
  FLine := -1;
  FReads := 0;
  FIdle := 0;
  FJitter := 0;
  FLastAddress := 0;
  FSlEnabled := False;
  FSlPending := False;
  FCpuEnabled := False;
  FCpuPending := False;
  FParity := False;
  FInFrame := False;
  FInHblank := False;
  FFetchSprite := False;
  FFetchX := 0;
  FFetchY := 0;
  FSpriteIndex := 0;
  FWindow := False;
  FOverride := False;
  FExt := 0;
  FOamLocked := False;
  FOamAddress := 0;
  FSpriteHeight := 8;
end;

procedure TMapperRainbow.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FHigh, SizeOf(FHigh));
  State.Field(FLow, SizeOf(FLow));
  State.Field(FChr, SizeOf(FChr));
  State.Field(FFpga, SizeOf(FFpga));
  State.Field(FNames, SizeOf(FNames));
  State.Field(FChrRam[0], Length(FChrRam));
  State.Field(FPrgRom[0], Length(FPrgRom));
  State.Field(FFlash, SizeOf(FFlash));
  State.Field(FOamCode, SizeOf(FOamCode));
  State.Field(FOamLocked, SizeOf(FOamLocked));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FReload, SizeOf(FReload));
  State.Field(FFpgaAddr, SizeOf(FFpgaAddr));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FReads, SizeOf(FReads));
  State.Field(FIdle, SizeOf(FIdle));
  State.Field(FJitter, SizeOf(FJitter));
  State.Field(FLastAddress, SizeOf(FLastAddress));
  State.Field(FSlEnabled, SizeOf(FSlEnabled));
  State.Field(FSlPending, SizeOf(FSlPending));
  State.Field(FCpuEnabled, SizeOf(FCpuEnabled));
  State.Field(FCpuPending, SizeOf(FCpuPending));
  State.Field(FParity, SizeOf(FParity));
  State.Field(FInFrame, SizeOf(FInFrame));
  State.Field(FInHblank, SizeOf(FInHblank));
  State.Field(FFetchSprite, SizeOf(FFetchSprite));
  State.Field(FWindow, SizeOf(FWindow));
  State.Field(FOverride, SizeOf(FOverride));
  State.Field(FFetchX, SizeOf(FFetchX));
  State.Field(FFetchY, SizeOf(FFetchY));
  State.Field(FSpriteIndex, SizeOf(FSpriteIndex));
  State.Field(FExt, SizeOf(FExt));
  State.Field(FOamAddress, SizeOf(FOamAddress));
  State.Field(FSpriteHeight, SizeOf(FSpriteHeight));
end;

function TMapperRainbow.CpuOffset(Address: UInt16; out Source: Integer): Integer;
begin
  Source := 0;
  if Address < $8000 then
  begin
    var Size := $2000;
    var Slot := 0;
    if (FRegs[0] and $80) <> 0 then
    begin
      Size := $1000;
      Slot := (Address - $6000) shr 12
    end;
    var Bank := FLow[Slot];
    Source := Bank shr 14;
    if Source <= 1 then
      Source := 0;
    Result := (Bank and $3FFF) * Size + (Address and (Size - 1));
    Exit;
  end;

  var Size := $1000;
  var Slot := (Address - $8000) shr 12;
  case FRegs[0] and 7 of
    0:
      begin
        Size := $8000;
        Slot := 0
      end;
    1:
      begin
        Size := $4000;
        Slot := Slot and 4
      end;
    2:
      if Slot < 4 then
      begin
        Size := $4000;
        Slot := 0
      end
      else
      begin
        Size := $2000;
        Slot := Slot and 6
      end;
    3:
      begin
        Size := $2000;
        Slot := Slot and 6
      end;
  end;
  if (FHigh[Slot] and $8000) <> 0 then
    Source := 2;
  Result := (FHigh[Slot] and $7FFF) * Size + (Address and (Size - 1));
end;

procedure TMapperRainbow.AckIrq;
begin
  FCpuPending := False;
  FCpuEnabled := (FRegs[$5A] and 2) <> 0
end;

procedure TMapperRainbow.GenerateOam(Extended: Boolean);
begin
  if FOamLocked then
    Exit;

  FOamLocked := True;
  var Pos := 0;
  var Count := (FRegs[$143] and $3F) * 4 + 4;
  var Page := FRegs[$141] and 7;
  if Extended then
  begin
    Pos := 2;
    Count := (FRegs[$143] and $3F) + 1;
    Page := FRegs[$142] and 7
  end;
  for var i := 0 to Count - 1 do
  begin
    FOamCode[Pos] := $A9;
    FOamCode[Pos + 1] := FFpga[($1800 + Page * $100 + i * (1 + Ord(Extended) * 3)) and $1FFF];
    FOamCode[Pos + 2] := $8D;
    if Extended then
    begin
      FOamCode[Pos + 3] := i;
      FOamCode[Pos + 4] := $42
    end
    else
    begin
      FOamCode[Pos + 3] := 4;
      FOamCode[Pos + 4] := $20
    end;
    Inc(Pos, 5);
  end;
  FOamCode[Pos] := $60;
end;

function TMapperRainbow.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address = $4011 then
  begin
    if (FRegs[$5A] and 4) <> 0 then
      AckIrq;
    Value := (FOutputs[0] + FOutputs[1] + FOutputs[2]) * 2;
    Exit(True)
  end;

  if (Address >= $4800) and (Address < $5000) then
  begin
    Value := FFpga[$1800 + (Address and $7FF)];
    Exit(True)
  end;

  if (Address >= $5000) and (Address < $6000) then
  begin
    Value := FFpga[(FRegs[$15] and 1) * $1000 + (Address and $FFF)];
    Exit(True)
  end;

  if (Address >= $4100) and (Address < $4800) then
  begin
    case Address of
      $4100, $4120, $412A..$412D, $412F, $4190:
        Value := FRegs[Address - $4100];
      $4150:
        Value := FLine and $FF;
      $4151:
        begin
          Value := Ord(FInFrame) * $40 + Ord(FInHblank) * $80;
          FSlPending := False
        end;
      $4154:
        Value := FJitter;
      $4157:
        Value := Ord(FParity) * $80;
      $415F:
        begin
          Value := FFpga[FFpgaAddr];
          FFpgaAddr := (FFpgaAddr + FRegs[$5E]) and $1FFF
        end;
      $4160:
        Value := $21;
      $4161:
        Value := Ord(FCpuPending) * $40 + Ord(FSlPending) * $80;
      $4191, $4192:
        Value := 0;
    else
      if Address >= $4280 then
      begin
        if Address = $4280 then
          GenerateOam(False)
        else if Address = $4282 then
          GenerateOam(True);
        if Address - $4280 < Length(FOamCode) then
          Value := FOamCode[Address - $4280]
        else
          Value := FCpuOpenBus;
        if Address >= $4282 then
          FOamLocked := False;
      end
      else
        Value := FCpuOpenBus;
    end;
    Exit(True);
  end;

  if Address >= $6000 then
  begin
    if (Address = $FFFA) or (Address = $FFFB) then
    begin
      FInFrame := False;
      FLine := 0;
      FSlPending := False;
      if (FRegs[$6B] and 1) <> 0 then
      begin
        Value := FRegs[$6D - (Address and 1)];
        Exit(True)
      end
    end;
    if (Address >= $FFFE) and ((FRegs[$6B] and 2) <> 0) then
    begin
      Value := FRegs[$6F - (Address and 1)];
      Exit(True)
    end;

    var Source: Integer;
    var Offset := CpuOffset(Address, Source);
    case Source of
      0:
        Value := FlashRead(0, Offset);
      2:
        Value := FPrgRam[Offset mod Length(FPrgRam)];
      3:
        Value := FFpga[Offset and $1FFF]
    end;
    Exit(True);
  end;

  Result := False;
end;

function TMapperRainbow.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $4800) and (Address < $5000) then
  begin
    FFpga[$1800 + (Address and $7FF)] := Value;
    Exit(True)
  end;

  if (Address >= $5000) and (Address < $6000) then
  begin
    FFpga[(FRegs[$15] and 1) * $1000 + (Address and $FFF)] := Value;
    Exit(True)
  end;

  if Address >= $6000 then
  begin
    var Source: Integer;
    var Offset := CpuOffset(Address, Source);
    case Source of
      0:
        FlashWrite(0, Offset, Value);
      2:
        FPrgRam[Offset mod Length(FPrgRam)] := Value;
      3:
        FFpga[Offset and $1FFF] := Value
    end;
    Exit(True);
  end;

  if (Address < $4100) or (Address > $4785) then
    Exit(False);

  FRegs[Address - $4100] := Value;
  case Address of
    $4106..$4107:
      FLow[Address - $4106] := (FLow[Address - $4106] and $FF) or (Word(Value) shl 8);
    $4116..$4117:
      FLow[Address - $4116] := (FLow[Address - $4116] and $FF00) or Value;
    $4108..$410F:
      FHigh[Address - $4108] := (FHigh[Address - $4108] and $FF) or (Word(Value) shl 8);
    $4118..$411F:
      FHigh[Address - $4118] := (FHigh[Address - $4118] and $FF00) or Value;
    $4130..$413F:
      FChr[Address - $4130] := (FChr[Address - $4130] and $FF) or (Word(Value) shl 8);
    $4140..$414F:
      FChr[Address - $4140] := (FChr[Address - $4140] and $FF00) or Value;
    $4151:
      FSlEnabled := True;
    $4152:
      begin
        FSlEnabled := False;
        FSlPending := False
      end;
    $4153:
      FRegs[$53] := EnsureRange(Value, 1, 170);
    $4157:
      FParity := True;
    $4158:
      FReload := (FReload and $FF) or (Value shl 8);
    $4159:
      FReload := (FReload and $FF00) or Value;
    $415A:
      begin
        FCpuPending := False;
        FCpuEnabled := (Value and 1) <> 0;
        if FCpuEnabled then
          FCounter := FReload
      end;
    $415B:
      AckIrq;
    $415C:
      FFpgaAddr := (FFpgaAddr and $FF) or ((Value and $1F) shl 8);
    $415D:
      FFpgaAddr := (FFpgaAddr and $1F00) or Value;
    $415F:
      begin
        FFpga[FFpgaAddr] := Value;
        FFpgaAddr := (FFpgaAddr + FRegs[$5E]) and $1FFF
      end;
    $41A0..$41A8:
      inherited CpuWrite($9000 + ((Address - $41A0) div 3) * $1000 + ((Address - $41A0) mod 3), Value);
  end;
  Result := True;
end;

function TMapperRainbow.ChrOffsetRainbow(Address: UInt16): Integer;
begin
  var Mode := Min(FRegs[$20] and 7, 4);
  var Size := $2000 shr Mode;
  Result := FChr[Address div Size] * Size + (Address and (Size - 1));
end;

function TMapperRainbow.ReadChrData(Source, Offset: Integer): Byte;
begin
  case Source of
    0:
      Result := FlashRead(1, Offset);
    1:
      Result := FChrRam[Offset mod Length(FChrRam)];
    2:
      Result := FFpga[Offset and $1FFF];
  else
    Result := FNames[Offset and $7FF]
  end;
end;

function TMapperRainbow.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;

  var Source := FRegs[$20] shr 6;
  if Address < $2000 then
  begin
    var Offset := ChrOffsetRainbow(Address);
    if Source = 2 then
      Offset := Address and $FFF
    else if Source = 3 then
      Offset := Address and $7FF;
    if FPpuRenderingRead and FInFrame and not FFetchSprite and FOverride then
    begin
      Offset := (Address and $FFF) or ((FExt and $3F) shl 12) or ((FRegs[$21] and $1F) shl 18);
      if FWindow then
        Offset := (Offset and not 7) or ((FFetchY + FRegs[$75]) mod 240 and 7)
    end
    else if FPpuRenderingRead and FFetchSprite and ((FRegs[$20] and $20) <> 0) then
      if FSpriteHeight = 16 then
        Offset := ((FRegs[$140] and 7) shl 21) or (FRegs[$100 + FSpriteIndex] shl 13) or (Address and $1FFF)
      else
        Offset := ((FRegs[$140] and 7) shl 20) or (FRegs[$100 + FSpriteIndex] shl 12) or (Address and $FFF);
    Value := ReadChrData(Source, Offset);
    Exit;
  end;

  var Nt := (Address shr 10) and 3;
  var Ctrl := FRegs[$2A + Nt];
  var Offset := Address and $3FF;
  var Bank := FRegs[$26 + Nt];
  var Attribute := Offset >= $3C0;
  if FPpuRenderingRead and FInFrame and not FFetchSprite then
  begin
    if not Attribute then
    begin
      FWindow := False;
      if (FRegs[$20] and $10) <> 0 then
      begin
        var Column := FFetchX shr 3;
        var Y := FFetchY;
        var XMatch := (Column >= (FRegs[$70] and 31)) and (Column <= (FRegs[$71] and 31));
        var YMatch := (Y >= FRegs[$72]) and (Y <= FRegs[$73]);
        if FRegs[$70] >= FRegs[$71] then
          XMatch := (Column <= FRegs[$71]) or (Column > FRegs[$70]);
        if FRegs[$72] >= FRegs[$73] then
          YMatch := (Y <= FRegs[$73]) or (Y > FRegs[$72]);
        FWindow := XMatch and YMatch;
      end;
    end;
    if FWindow then
    begin
      Ctrl := FRegs[$2F];
      Bank := FRegs[$2E];
      Source := 2;
      var Y := (FFetchY + FRegs[$75]) mod 240;
      var X := ((FFetchX shr 3) + FRegs[$74]) and 31;
      if Attribute then
        Offset := $3C0 + ((Y shr 5) * 8) + (X shr 2)
      else
        Offset := (Y shr 3) * 32 + X;
    end;
    if not Attribute then
    begin
      FOverride := (Ctrl and 2) <> 0;
      FExt := FFpga[((Ctrl and 12) shl 8) + Offset]
    end;
    if (Ctrl and $20) <> 0 then
    begin
      if Attribute then
        Value := (FRegs[$25] and 3) * $55
      else
        Value := FRegs[$24];
      Exit
    end;
    if Attribute and ((Ctrl and 1) <> 0) then
    begin
      Value := (FExt shr 6) * $55;
      Exit
    end;
  end;
  if not (FPpuRenderingRead and FWindow) then
    Source := Ctrl shr 6;
  case Source of
    0:
      Value := FNames[(Bank and 1) * $400 + Offset];
    1:
      Value := FChrRam[(Bank * $400 + Offset) mod Length(FChrRam)];
    2:
      Value := FFpga[(Bank and 3) * $400 + Offset];
    3:
      Value := FlashRead(1, Bank * $400 + Offset);
  end;
  if FPpuRenderingRead and FWindow and Attribute then
  begin
    var X := ((FFetchX shr 3) + FRegs[$74]) and 31;
    var Y := (FFetchY + FRegs[$75]) mod 240;
    Value := ((Value shr (((Y shr 2) and 4) or (X and 2))) and 3) * $55
  end;
end;

function TMapperRainbow.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $3F00;
  if not Result then
    Exit;

  if Address < $2000 then
  begin
    case FRegs[$20] shr 6 of
      0:
        FlashWrite(1, ChrOffsetRainbow(Address), Value);
      1:
        FChrRam[ChrOffsetRainbow(Address) mod Length(FChrRam)] := Value;
      2:
        FFpga[Address and $FFF] := Value;
      3:
        FNames[Address and $7FF] := Value;
    end;
    Exit;
  end;

  var Nt := (Address shr 10) and 3;
  var Bank := FRegs[$26 + Nt];
  var Offset := Address and $3FF;
  case FRegs[$2A + Nt] shr 6 of
    0:
      FNames[(Bank and 1) * $400 + Offset] := Value;
    1:
      FChrRam[(Bank * $400 + Offset) mod Length(FChrRam)] := Value;
    2:
      FFpga[(Bank and 3) * $400 + Offset] := Value;
  end;
end;

procedure TMapperRainbow.ClockCpu;
begin
  ClockPulseAudio;
  FParity := not FParity;
  FJitter := (FJitter + 1) and $FF;
  if FCpuEnabled and (FCounter > 0) then
  begin
    Dec(FCounter);
    if FCounter = 0 then
    begin
      FCounter := FReload;
      if not IrqPending then
        FJitter := 0;
      FCpuPending := True
    end
  end;
  if FIdle > 0 then
  begin
    Dec(FIdle);
    if FIdle = 0 then
    begin
      FInFrame := False;
      FInHblank := False;
      FLine := -1
    end
  end;
end;

procedure TMapperRainbow.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  FLine := Line;
  FInFrame := Rendering and (Line < 240);
  FReads := 0;
  FInHblank := False
end;

procedure TMapperRainbow.ClockPpuRead;
begin
  Inc(FReads);
  FIdle := 3;
  FInHblank := FReads >= 128;
  if (FLine = FRegs[$50]) and (FReads = FRegs[$53]) then
    FSlPending := True;
end;

procedure TMapperRainbow.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  FLastAddress := Address
end;

procedure TMapperRainbow.SetPpuFetchKind(Sprite: Boolean; X, Y: Integer);
begin
  FFetchSprite := Sprite;
  FFetchX := X;
  FFetchY := Y
end;

procedure TMapperRainbow.SetPpuSpriteIndex(Index: Integer);
begin
  FSpriteIndex := Index and 63
end;

procedure TMapperRainbow.CpuIoWrite(Address: UInt16; Value: UInt8);
begin
  case Address of
    $2000:
      FSpriteHeight := 8 + Ord((Value and $20) <> 0) * 8;
    $2003:
      FOamAddress := Value;
    $2004:
      FOamAddress := (FOamAddress + 1) and $FF
  end;
end;

function TMapperRainbow.IrqPending: Boolean;
begin
  Result := (FCpuEnabled and FCpuPending) or (FSlEnabled and FSlPending)
end;

function TMapperRainbow.ExpansionAudio: Double;
begin
  if (FRegs[$A9] and 3) <> 0 then
    Result := inherited ExpansionAudio * (FRegs[$AA] and 15) / 15.0
  else
    Result := 0
end;

function TMapperRainbow.GetSaveMemory: TByteArray;
begin
  SetLength(Result, Length(FPrgRom) + Length(FChrMemory) + Length(FPrgRam));
  Move(FPrgRom[0], Result[0], Length(FPrgRom));
  Move(FChrMemory[0], Result[Length(FPrgRom)], Length(FChrMemory));
  Move(FPrgRam[0], Result[Length(FPrgRom) + Length(FChrMemory)], Length(FPrgRam));
end;

procedure TMapperRainbow.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRom) + Length(FChrMemory) + Length(FPrgRam) then
    raise ENesException.Create('Invalid Rainbow save size');

  Move(Data[0], FPrgRom[0], Length(FPrgRom));
  Move(Data[Length(FPrgRom)], FChrMemory[0], Length(FChrMemory));
  Move(Data[Length(FPrgRom) + Length(FChrMemory)], FPrgRam[0], Length(FPrgRam));
end;

function TMapperRainbow.FlashRead(Chip, Offset: Integer): Byte;
begin
  var Data := FPrgRom;
  if Chip = 1 then
    Data := FChrMemory;
  if not FFlash[Chip].SoftwareId then
    Exit(Data[Offset mod Length(Data)]);

  case Offset and $1FF of
    0:
      Result := 1;
    2:
      case Length(Data) of
        $100000:
          Result := $5B;
        $200000:
          Result := $49;
      else
        Result := $7E
      end;
    $1C:
      if Length(Data) = $400000 then
        Result := $0A
      else if Length(Data) = $800000 then
        Result := $10
      else
        Result := $FF;
    $1E:
      if Length(Data) >= $400000 then
        Result := 0
      else
        Result := $FF;
  else
    Result := $FF
  end;
end;

procedure TMapperRainbow.FlashWrite(Chip, Offset: Integer; Value: Byte);
begin
  var Data := FPrgRom;
  if Chip = 1 then
    Data := FChrMemory;
  var S := FFlash[Chip];
  var Command := Offset and $FFF;
  if S.Mode = 1 then
  begin
    Data[Offset mod Length(Data)] := Data[Offset mod Length(Data)] and Value;
    S.Mode := 0;
    S.Step := 0
  end
  else if S.Bypass then
  begin
    if (S.Step = 1) and (Value = 0) then
    begin
      S.Bypass := False;
      S.Step := 0
    end
    else if Value = $A0 then
      S.Mode := 1
    else if Value = $90 then
      S.Step := 1
    else
      S.Step := 0;
  end
  else
    case S.Step of
      0:
        if (Command = $AAA) and (Value = $AA) then
          S.Step := 1
        else if Value = $F0 then
          S.SoftwareId := False;
      1:
        if (Command = $555) and (Value = $55) then
          S.Step := 2
        else
          S.Step := 0;
      2:
        begin
          S.Step := 0;
          if Command = $AAA then
            case Value of
              $20:
                S.Bypass := True;
              $80:
                S.Step := 3;
              $90:
                S.SoftwareId := True;
              $A0:
                S.Mode := 1;
              $F0:
                S.SoftwareId := False
            end;
        end;
      3:
        if (Command = $AAA) and (Value = $AA) then
          S.Step := 4
        else
          S.Step := 0;
      4:
        if (Command = $555) and (Value = $55) then
          S.Step := 5
        else
          S.Step := 0;
      5:
        begin
          if (Command = $AAA) and (Value = $10) then
            FillChar(Data[0], Length(Data), $FF)
          else if Value = $30 then
          begin
            var Base := (Offset mod Length(Data)) and not $FFFF;
            var Size := $10000;
            if Base = Length(Data) - $10000 then
              if Length(Data) >= $400000 then
              begin
                Base := (Offset mod Length(Data)) and not $1FFF;
                Size := $2000
              end
              else
                case Offset and $FFFF of
                  0..$7FFF:
                    Size := $8000;
                  $8000..$9FFF:
                    begin
                      Inc(Base, $8000);
                      Size := $2000
                    end;
                  $A000..$BFFF:
                    begin
                      Inc(Base, $A000);
                      Size := $2000
                    end;
                else
                  begin
                    Inc(Base, $C000);
                    Size := $4000
                  end
                end;
            Size := Min(Size, Length(Data) - Base);
            FillChar(Data[Base], Size, $FF);
          end;
          S.Step := 0;
        end;
    end;
  FFlash[Chip] := S;
end;

end.

