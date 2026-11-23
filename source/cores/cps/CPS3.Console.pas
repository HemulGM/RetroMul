unit CPS3.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, HW.SH2, HW.SH7604,
  CPS.Cartridge, Core.Emulation.Types, Core.Snapshots, CPS3.Sound, CPS3.Flash,
  CPS3.SCSI, Core.CD.Disc;

const
  CPS3_FPS = 42954545.0 / (6 * 455 * 264);

type
  TCPS3Console = class
  private
    FCPU: TSH7604;
    FSCSI: TCPS3SCSI;
    FFlash: array[0..39] of TCPS3Flash;
    FCDMode, FFlashDirty: Boolean;
    FBatteryRevision: UInt64;
    FSound: TCPS3Sound;
    FBIOS, FProgram, FCode, FGfx, FRAM, FSprite, FList, FChar, FSS, FPalette, FRegs: TBytes;
    FEEPROM: array[0..$7F] of Byte;
    FEERead: Word;
    FKey1, FKey2: Cardinal;
    FAlt: Boolean;
    FPlain: Boolean;
    FInput: TEmulatorInput;
    FPixels: TArray<TAlphaColor>;
    FIndices: TArray<Cardinal>;
    FCoins: array[0..1] of Integer;
    FTime, FFrameNumber: Int64;
    FIRQ10, FIRQ12: Boolean;
    FCharBank, FGfxBank, FTable, FDMASource: Cardinal;
    FDMAStatus, FSpriteDMA: Word;
    FFlashID: array[0..1] of Boolean;
    FGfxPresent, FGfxID: array[0..31] of Boolean;
    FSSPal, FSSY: Integer;
    function SecurityMask(Address: Cardinal): Cardinal;
    procedure RebuildCode(Offset, Count: Integer);
    procedure SetIRQ;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure CharacterDMA(Address: Cardinal);
    procedure PaletteDMA;
    procedure Render;
    procedure RenderTileMap(LayerNo, Line: Integer);
    procedure DrawTile(Code, Palette, X, Y, W, H: Integer; FlipX, FlipY, SixBit, Blend: Boolean; ClipLine: Integer = -1);
    function PaletteColor(Index: Cardinal): TAlphaColor;
    function GetCPUState: TSH2State;
  public
    constructor Create(Cart: TCPSCartridge; Disc: TCDDisc = nil);
    destructor Destroy; override;
    procedure SerializeState(State: TStateArchive);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    property Sound: TCPS3Sound read FSound;
    property SCSI: TCPS3SCSI read FSCSI;
    property FlashDirty: Boolean read FFlashDirty;
    property BatteryRevision: UInt64 read FBatteryRevision;
    procedure Reset;
    procedure RunFrame;
    function Step: Integer;
    function Read(Address: Cardinal; Size: Integer; Instruction: Boolean = False): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure SetInput(const Input: TEmulatorInput);
    procedure InsertCoin(Player: Integer);
    property Pixels: TArray<TAlphaColor> read FPixels;
    property FrameNumber: Int64 read FFrameNumber;
    property CPUState: TSH2State read GetCPUState;
  end;

implementation

uses
  CPS.RomSets, CPS.Crypto, System.Math;

const
  Buttons: array[0..6] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C);
  Shifts: array[0..2] of Integer = (24, 16, 0);

function Get32(const Data: TBytes; Offset: Cardinal): Cardinal; inline;
begin
  if UInt64(Offset) + 4 > Cardinal(Length(Data)) then
    Exit($FFFFFFFF);

  Result := (Cardinal(Data[Offset]) shl 24) or (Cardinal(Data[Offset + 1]) shl 16) or
    (Cardinal(Data[Offset + 2]) shl 8) or Data[Offset + 3];
end;

procedure Put32(var Data: TBytes; Offset, Value: Cardinal); inline;
begin
  if UInt64(Offset) + 4 > Cardinal(Length(Data)) then
    Exit;

  Data[Offset] := Byte(Value shr 24);
  Data[Offset + 1] := Byte((Value shr 16) and $FF);
  Data[Offset + 2] := Byte((Value shr 8) and $FF);
  Data[Offset + 3] := Byte(Value and $FF);
end;

function BusRead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TCPS3Console(User).Read(Address, Size);
end;

function DecodeOpcode(User: Pointer; Address: Cardinal; Opcode: Word): Word;
begin
  var C := TCPS3Console(User);
  Result := Opcode;
  if ((Address >= $C0000000) and (Address < $C0000400)) or
    (C.FAlt and (Address and $1FFFFFFF >= $06000000) and (Address and $1FFFFFFF < $07000000)) then
  begin
    var Mask := C.SecurityMask(Address and $FFFFFFFC);
    Result := Opcode xor Word((Mask shr ((2 - Integer(Address and 2)) * 8)) and $FFFF);
  end;
end;

function DMARead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var C := TCPS3Console(User);
  Result := C.Read(Address, Size);
  if (Address < $80000) or (not C.FAlt and (Address >= $06000000) and (Address < $07000000)) then
  begin
    var Mask := C.SecurityMask(Address and $FFFFFFFC);
    if Size < 4 then
      Mask := Mask shr ((4 - Integer(Address and 3) - Size) * 8);
    case Size of
      1:
        Mask := Mask and $FF;
      2:
        Mask := Mask and $FFFF;
    end;
    Result := Result xor Mask;
  end;
end;

procedure BusWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TCPS3Console(User).Write(Address, Value, Size);
end;

constructor TCPS3Console.Create(Cart: TCPSCartridge; Disc: TCDDisc);
begin
  inherited Create;
  if Cart.RomSet.Generation <> TCPSGeneration.CPS3 then
    raise EArgumentException.Create('CPS3 requires a CPS3 set');

  FCDMode := not Cart.HasRegion('simm1.0');
  FSCSI := TCPS3SCSI.Create(Disc);
  var Mode := Cart.RomSet.Init;
  if Mode = 'init_sfiii2' then
    FAlt := True
  else if Mode = 'init_cps3boot' then
  begin
    FPlain := True;
    FAlt := True;
  end
  else if Mode = 'init_sfiii3' then
  begin
    FKey1 := $A55432B4;
    FKey2 := $0C129981;
  end
  else if Mode = 'init_sfiii' then
  begin
    FKey1 := $B5FE053E;
    FKey2 := $FC03925A;
  end
  else if Mode = 'init_jojoba' then
  begin
    FKey1 := $23323EE3;
    FKey2 := $03021972;
  end
  else if Mode = 'init_jojo' then
  begin
    FKey1 := $02203EE3;
    FKey2 := $01301972;
  end
  else if Mode = 'init_redearth' then
  begin
    FKey1 := $9E300AB1;
    FKey2 := $A175B82C;
  end
  else
    raise ECPSRom.Create('Unsupported CPS3 security cartridge: ' + Cart.RomSet.Name);

  FBIOS := Copy(Cart['bios']);
  for var i := 0 to Length(FBIOS) div 4 - 1 do
    Put32(FBIOS, i * 4, Get32(FBIOS, i * 4) xor SecurityMask(i * 4));
  SetLength(FProgram, $1000000);
  FillChar(FProgram[0], Length(FProgram), $FF);
  for var Bank := 0 to 1 do
    for var Chip := 0 to 3 do
    begin
      var Source := Cart[Format('simm%d.%d', [Bank + 1, Chip])];
      for var i := 0 to Length(Source) - 1 do
        FProgram[Bank * $800000 + i * 4 + Chip] := Source[i];
    end;
  for var Bank := 0 to 1 do
    for var Chip := 0 to 3 do
      FFlash[Bank * 4 + Chip] := TCPS3Flash.Create(FProgram, Bank * $800000 + Chip, 4);
  FCode := Copy(FProgram);
  for var i := 0 to Length(FCode) div 4 - 1 do
    Put32(FCode, i * 4, Get32(FCode, i * 4) xor SecurityMask($6000000 + Cardinal(i * 4)));
  SetLength(FGfx, $4000000);
  FillChar(FGfx[0], Length(FGfx), $FF);
  for var Bank := 3 to 6 do
    for var Pair := 0 to 3 do
    begin
      var S0 := Cart[Format('simm%d.%d', [Bank, Pair * 2])];
      var S1 := Cart[Format('simm%d.%d', [Bank, Pair * 2 + 1])];
      FGfxPresent[(Bank - 3) * 8 + Pair * 2] := (Length(S0) > 0) and (Length(S1) > 0);
      FGfxPresent[(Bank - 3) * 8 + Pair * 2 + 1] := FGfxPresent[(Bank - 3) * 8 + Pair * 2];
      var Dest := (Bank - 3) * $1000000 + Pair * $400000;
      for var i := 0 to Min(Length(S0), Length(S1)) - 1 do
      begin
        FGfx[Dest + i * 2] := S0[i];
        FGfx[Dest + i * 2 + 1] := S1[i];
      end;
    end;
  if FCDMode then
    FillChar(FGfxPresent, SizeOf(FGfxPresent), 1);
  for var Pair := 0 to 15 do
    for var Chip := 0 to 1 do
      FFlash[8 + Pair * 2 + Chip] := TCPS3Flash.Create(FGfx, Pair * $400000 + Chip, 2);
  SetLength(FRAM, $80000);
  SetLength(FSprite, $80000);
  SetLength(FList, $80000);
  SetLength(FChar, $800000);
  SetLength(FSS, $8000);
  SetLength(FPalette, $40000);
  SetLength(FRegs, $B0);
  SetLength(FPixels, 384 * 224);
  SetLength(FIndices, 1024 * 1024);
  FillChar(FEEPROM, SizeOf(FEEPROM), $FF);
  FSound := TCPS3Sound.Create(FGfx);
  FCPU := TSH7604.Create(BusRead, BusWrite, Self);
  FCPU.SetOpcodeDecoder(DecodeOpcode);
  FCPU.DMARead := DMARead;
  Reset;
end;

destructor TCPS3Console.Destroy;
begin
  FCPU.Free;
  FSound.Free;
  FSCSI.Free;
  for var Chip in FFlash do
    Chip.Free;
  inherited;
end;

procedure TCPS3Console.Reset;

  procedure Clear(var Data: TBytes);
  begin
    if Length(Data) > 0 then
      FillChar(Data[0], Length(Data), 0);
  end;

begin
  Clear(FRAM);
  Clear(FSprite);
  Clear(FList);
  Clear(FChar);
  Clear(FSS);
  Clear(FPalette);
  Clear(FRegs);
  FFlashID[0] := False;
  FFlashID[1] := False;
  FillChar(FGfxID, SizeOf(FGfxID), 0);
  FCoins[0] := 0;
  FCoins[1] := 0;
  FTime := 0;
  FFrameNumber := 0;
  FIRQ10 := False;
  FIRQ12 := False;
  FCharBank := 0;
  FGfxBank := 0;
  FTable := 0;
  FDMASource := 0;
  FDMAStatus := 0;
  FSpriteDMA := 0;
  FSSPal := 0;
  FSSY := 0;
  FEERead := 0;
  Put32(FList, 0, $80000000);
  FSound.Reset;
  FSCSI.Reset;
  for var Chip in FFlash do
    Chip.Reset;
  FCPU.Reset;
end;

function TCPS3Console.Read(Address: Cardinal; Size: Integer; Instruction: Boolean): Cardinal;
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('CPS3 bus width');

  if Address >= $FFFFFE00 then
    Exit(FCPU.Read(Address, Size));

  var Physical := Address and $1FFFFFFF;
  var Aligned := Physical and $FFFFFFFC;
  var Value: Cardinal := $FFFFFFFF;
  if (Address >= $C0000000) and (Address < $C0000400) then
  begin
    Value := FCPU.Read(Address and $FFFFFFFC, 4);
    if Instruction then
      Value := Value xor SecurityMask(Address and $FFFFFFFC);
  end
  else if Physical < $80000 then
    Value := Get32(FBIOS, Aligned)
  else if (Physical >= $02000000) and (Physical < $02080000) then
    Value := Get32(FRAM, Aligned - $02000000)
  else if (Physical >= $04000000) and (Physical < $04080000) then
    Value := Get32(FSprite, Aligned - $04000000)
  else if (Physical >= $04080000) and (Physical < $040C0000) then
    Value := Get32(FPalette, Aligned - $04080000)
  else if (Physical >= $040C0000) and (Physical < $040C00B0) then
  begin
    if Aligned = $040C000C then
      Value := FDMAStatus shl 16
    else
      Value := Get32(FRegs, Aligned - $040C0000);
  end
  else if (Physical >= $040E0000) and (Physical < $040E0300) then
  begin
    FSound.AdvanceTo(FTime);
    Value := FSound.Read(Aligned - $040E0000);
  end
  else if (Physical >= $04100000) and (Physical < $04200000) then
    Value := Get32(FChar, (FCharBank and 7) * $100000 + Aligned - $04100000)
  else if (Physical >= $04200000) and (Physical < $04400000) then
  begin
    if not FGfxPresent[FGfxBank] then
      Value := $FFFFFFFF
    else
    begin
      var Chip := 8 + (Integer(FGfxBank) and not 1);
      var At := (FGfxBank and 1) * $100000 + (Aligned - $04200000) div 2;
      Value := (Cardinal(FFlash[Chip].Read(At)) shl 24) or (Cardinal(FFlash[Chip + 1].Read(At)) shl 16) or
        (Cardinal(FFlash[Chip].Read(At + 1)) shl 8) or FFlash[Chip + 1].Read(At + 1);
    end;
  end
  else if (Physical >= $05040000) and (Physical < $05050000) then
  begin
    var Index := (Aligned - $05040000) div 2;
    Value := (Cardinal(FSS[Index]) shl 16) or FSS[Index + 1];
  end
  else if (Physical >= $06000000) and (Physical < $07000000) then
  begin
    var Bank := (Physical - $06000000) div $800000;
    if Instruction then
      Value := Get32(FCode, Aligned - $06000000)
    else
    begin
      var At := (Aligned and $7FFFFF) div 4;
      Value := 0;
      for var Chip := 0 to 3 do
        Value := (Value shl 8) or FFlash[Bank * 4 + Cardinal(Chip)].Read(At);
      if not FAlt then
        Value := Value xor SecurityMask(Aligned);
    end;
  end
  else if Aligned = $05140000 then
  begin
    Value := $FF00FF00;
    if (Size = 4) or ((Physical and 3) < 2) then
      Value := Value or (Cardinal(FSCSI.Read(0)) shl 16);
    if (Size = 4) or ((Physical and 3) >= 2) then
      Value := Value or FSCSI.Read(1);
  end
  else if Aligned = $05000000 then
  begin
    Value := $FFFFFFFF;
    for var i := 0 to 6 do
    begin
      if Buttons[i] in FInput.Buttons then
        Value := Value and not (Cardinal(1) shl i);
      if Buttons[i] in FInput.Buttons2 then
        Value := Value and not (Cardinal(1) shl (i + 8));
    end;
    if TEmulatorButton.Start in FInput.Buttons then
      Value := Value and $EFFFFFFF;
    if TEmulatorButton.Start in FInput.Buttons2 then
      Value := Value and $DFFFFFFF;
    if TEmulatorButton.Mode in FInput.Buttons then
      Value := Value and $FFFDFFFF;
    if TEmulatorButton.Z in FInput.Buttons2 then
      Value := Value and $FBFFFFFF;
    if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
      Value := Value and $FEFFFFFF;
    if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
      Value := Value and $FDFFFFFF;
  end
  else if Aligned = $05000004 then
  begin
    Value := $FFFFFFFF;
    if TEmulatorButton.X in FInput.Buttons then
      Value := Value and $FFF7FFFF;
    if TEmulatorButton.Y in FInput.Buttons then
      Value := Value and $FFFBFFFF;
    if TEmulatorButton.Z in FInput.Buttons then
      Value := Value and $FFFDFFFF;
    if TEmulatorButton.X in FInput.Buttons2 then
      Value := Value and $FFEFFFFF;
    if TEmulatorButton.Y in FInput.Buttons2 then
      Value := Value and $FFDFFFFF;
  end
  else if (Physical >= $05001100) and (Physical < $05001180) then
  begin
    var Index := (Physical - $05001100) and $7E;
    FEERead := (Word(FEEPROM[Index]) shl 8) or FEEPROM[Index + 1];
    Value := 0;
  end
  else if Aligned = $05001200 then
    Value := FEERead
  else if (Physical >= $05001000) and (Physical < $05001204) then
    Value := 0;

  if Size = 4 then
    Exit(Value);

  Result := Value shr ((4 - Integer(Physical and 3) - Size) * 8);
  if Size = 1 then
    Result := Result and $FF
  else
    Result := Result and $FFFF;
end;

procedure TCPS3Console.Write(Address, Value: Cardinal; Size: Integer);

  procedure Store(var Dest: TBytes; Offset: Cardinal);
  begin
    if UInt64(Offset) + Cardinal(Size) > Cardinal(Length(Dest)) then
      Exit;

    for var i := 0 to Size - 1 do
      Dest[Offset + Cardinal(i)] := Byte((Value shr ((Size - 1 - i) * 8)) and $FF);
  end;

begin
  if Address >= $FFFFFE00 then
  begin
    FCPU.Write(Address, Value, Size);
    Exit;
  end;

  var Physical := Address and $1FFFFFFF;
  if (Address >= $C0000000) and (Address < $C0000400) then
    FCPU.Write(Address, Value, Size)
  else if (Physical >= $02000000) and (Physical < $02080000) then
    Store(FRAM, Physical - $02000000)
  else if (Physical >= $04000000) and (Physical < $04080000) then
    Store(FSprite, Physical - $04000000)
  else if (Physical >= $04080000) and (Physical < $040C0000) then
    Store(FPalette, Physical - $04080000)
  else if (Physical >= $040C0000) and (Physical < $040C00B0) then
  begin
    Store(FRegs, Physical - $040C0000);
    WriteRegister(Physical, Value, Size);
  end
  else if (Physical >= $040E0000) and (Physical < $040E0300) then
  begin
    FSound.AdvanceTo(FTime);
    var Shift := (4 - Integer(Physical and 3) - Size) * 8;
    var Mask: Cardinal := $FFFFFFFF;
    if Size < 4 then
      Mask := (Cardinal(1) shl (Size * 8)) - 1;
    FSound.Write((Physical - $040E0000) and $FFFFFFFC, Value shl Shift, Mask shl Shift);
  end
  else if (Physical >= $04100000) and (Physical < $04200000) then
    Store(FChar, (FCharBank and 7) * $100000 + Physical - $04100000)
  else if (Physical >= $04200000) and (Physical < $04400000) then
  begin
    if not FGfxPresent[FGfxBank] then
      Exit;

    for var i := 0 to Size - 1 do
    begin
      var Offset := (FGfxBank and 1) * $200000 + Physical - $04200000 + Cardinal(i);
      var Chip := 8 + (Integer(FGfxBank) and not 1) + Integer(Offset and 1);
      var Changed, Count: Integer;
      if FFlash[Chip].Write(Offset div 2, Byte((Value shr ((Size - 1 - i) * 8)) and $FF), Changed, Count) then
      begin
        FFlashDirty := True;
        Inc(FBatteryRevision);
      end;
    end;
  end
  else if (Physical >= $05040000) and (Physical < $05050000) then
  begin
    for var i := 0 to Size - 1 do
      if (Physical + Cardinal(i)) and 1 <> 0 then
        FSS[((Physical - $05040000) + Cardinal(i)) div 2] := Byte((Value shr ((Size - 1 - i) * 8)) and $FF);
  end
  else if (Physical >= $05050000) and (Physical < $0505002C) then
  begin
    if Physical = $05050024 then
      FSSPal := Value and $FF;
    if Physical = $05050020 then
      FSSY := Value and $FF;
    if Physical = $05050022 then
      FSSY := (FSSY and $FF) or (Integer(Value and $FF) shl 8);
  end
  else if (Physical >= $05001080) and (Physical < $05001100) then
  begin
    for var i := 0 to Size - 1 do
    begin
      var At := Physical - $05001080 + Cardinal(i);
      if At >= Cardinal(Length(FEEPROM)) then
        Continue;

      var B := Byte((Value shr ((Size - 1 - i) * 8)) and $FF);
      if FEEPROM[At] <> B then
      begin
        FEEPROM[At] := B;
        Inc(FBatteryRevision);
      end;
    end;
  end
  else if (Physical >= $06000000) and (Physical < $07000000) then
  begin
    for var i := 0 to Size - 1 do
    begin
      var At := Physical - $06000000 + Cardinal(i);
      var Chip := (At div $800000) * 4 + (At and 3);
      var Changed, Count: Integer;
      if FFlash[Chip].Write((At and $7FFFFF) div 4, Byte((Value shr ((Size - 1 - i) * 8)) and $FF), Changed, Count) then
      begin
        RebuildCode(Integer(At div $800000) * $800000 + Changed * 4, Count * 4);
        FFlashDirty := True;
        Inc(FBatteryRevision);
      end;
    end;
  end
  else if (Physical >= $05140000) and (Physical < $05140004) then
  begin
    for var i := 0 to Size - 1 do
      if (Physical + Cardinal(i)) and 1 <> 0 then
        FSCSI.Write(((Physical + Cardinal(i)) and 3) div 2, Byte((Value shr ((Size - 1 - i) * 8)) and $FF));
  end
  else if Physical = $05100000 then
    FIRQ12 := False
  else if Physical = $05110000 then
    FIRQ10 := False;
end;

procedure TCPS3Console.SetIRQ;
begin
  if FIRQ12 then
    FCPU.Interrupt(12, 64 + 12 div 2)
  else if FIRQ10 then
    FCPU.Interrupt(10, 64 + 10 div 2)
  else
    FCPU.Interrupt(0, 0);
end;

procedure TCPS3Console.WriteRegister(Address, Value: Cardinal; Size: Integer);
begin
  var Offset := (Address - $040C0000) and $FFFFFFFC;
  case Offset of
    $80:
      begin
        var NewValue := Get32(FRegs, $80) and $FFFF;
        if (FSpriteDMA and 9 = 9) and (NewValue and 9 = 8) then
        begin
          FList := Copy(FSprite);
          FDMAStatus := FDMAStatus or 1;
        end;
        FSpriteDMA := NewValue;
      end;
    $84:
      FCharBank := Get32(FRegs, $84) and 7;
    $88:
      FGfxBank := ((Get32(FRegs, $88) shr 16) + 30) and $1F;
    $94:
      FDMASource := Get32(FRegs, $94) and $FFFF;
    $98:
      if Get32(FRegs, $98) and $00400000 <> 0 then
        CharacterDMA((FDMASource or (Get32(FRegs, $98) and $3F0000)) * 4);
    $AC:
      if Get32(FRegs, $AC) and 2 <> 0 then
        PaletteDMA;
  end;
end;

procedure TCPS3Console.CharacterDMA(Address: Cardinal);

  function GfxByte(At: Cardinal): Byte;
  begin
    Result := FGfx[At and $3FFFFFF];
  end;

begin
  for var Entry := 0 to $1000 div 3 - 1 do
  begin
    var Command := Get32(FChar, Address + Cardinal(Entry * 12));
    if Command and $01000000 <> 0 then
      Break;

    var Dest := Get32(FChar, Address + Cardinal(Entry * 12 + 4)) * 8;
    var Source := (UInt64(Get32(FChar, Address + Cardinal(Entry * 12 + 8))) * 2 + $FC00000) and $FFFFFFF;
    var Count := Integer(((Command and $1FFFFF) + 1) * 8);
    var Kind := (Command shr 21) and 7;
    if Kind = 4 then
    begin
      FTable := Source;
      Continue;
    end;

    if not (Kind in [0, 2, 3]) then
      raise EInvalidOpException.CreateFmt('CPS3 unsupported character DMA command %d', [Kind]);

    var Last := -1;
    var Last2 := -2;
    var Control := 0;
    var ControlBits := 0;
    while Count > 0 do
    begin
      if Kind = 3 then
      begin
        if ControlBits = 0 then
        begin
          Control := GfxByte(Source);
          Inc(Source);
          ControlBits := 8;
        end;
      end;
      var B := Integer(GfxByte(Source));
      Inc(Source);
      var ExpandTable := ((Kind = 2) and (B and $80 <> 0)) or ((Kind = 3) and (Control and $80 <> 0));
      var Items := 1;
      if ExpandTable then
        Items := 2;
      for var i := 0 to Items - 1 do
      begin
        var V := B;
        if ExpandTable then
          V := GfxByte(FTable + Cardinal((B and $7F) * 2 + i));
        var RepeatCount := 1;
        var Output := V;
        if (Kind = 2) and (V and $40 <> 0) then
        begin
          RepeatCount := (V and $3F) + 1;
          Output := Max(Last, 0) and $3F;
        end
        else if (Kind = 3) and (Last = Last2) then
        begin
          RepeatCount := (V + 1) and $FF;
          Output := Last;
          Last2 := -2;
        end
        else
        begin
          Last2 := Last;
          Last := V;
        end;
        RepeatCount := Min(RepeatCount, Count);
        for var J := 1 to RepeatCount do
        begin
          FChar[Dest and $7FFFFF] := Byte(Output);
          Inc(Dest);
        end;
        Dec(Count, RepeatCount);
        if Count = 0 then
          Break;
      end;

      if Kind = 3 then
      begin
        Control := (Control shl 1) and $FF;
        Dec(ControlBits);
      end;
    end;
  end;
  FDMAStatus := FDMAStatus or 2;
  FIRQ10 := True;
end;

procedure TCPS3Console.PaletteDMA;
begin
  var Source := (UInt64(Get32(FRegs, $A0)) * 2 + $FC00000) and $3FFFFFF;
  var Dest := Get32(FRegs, $A4) and $1FFFF;
  var Fade := Get32(FRegs, $A8);
  var Count := (Get32(FRegs, $AC) shr 16) or ((Get32(FRegs, $AC) and 1) shl 16);
  for var i := 0 to Integer(Count) - 1 do
  begin
    var V := (Word(FGfx[(Source + Cardinal(i * 2)) and $3FFFFFF]) shl 8) or FGfx[(Source + Cardinal(i * 2 + 1)) and $3FFFFFF];
    var RGB: array[0..2] of Integer;
    RGB[0] := V and 31;
    RGB[1] := (V shr 5) and 31;
    RGB[2] := (V shr 10) and 31;
    for var C := 0 to 2 do
    begin
      var F := (Fade shr Shifts[C]) and $7F;
      if F and $40 <> 0 then
        if F and $20 <> 0 then
          RGB[C] := (((RGB[C] xor 31) * Integer((not F) and 31)) shr 5) xor 31
        else
          RGB[C] := (RGB[C] * Integer(F and 31)) shr 5;
    end;
    V := RGB[0] or (RGB[1] shl 5) or (RGB[2] shl 10);
    var At := ((Dest + Cardinal(i)) and $1FFFF) * 2;
    FPalette[At] := Byte(V shr 8);
    FPalette[At + 1] := Byte(V and $FF);
  end;
  FDMAStatus := FDMAStatus or 4;
  FIRQ10 := True;
end;

function TCPS3Console.PaletteColor(Index: Cardinal): TAlphaColor;
begin
  Index := (Index and $1FFFF) * 2;
  var V := (Word(FPalette[Index]) shl 8) or FPalette[Index + 1];
  Result := $FF000000 or (Cardinal(V and 31) shl 19) or (Cardinal((V shr 5) and 31) shl 11) or (Cardinal((V shr 10) and 31) shl 3);
end;

procedure TCPS3Console.DrawTile(Code, Palette, X, Y, W, H: Integer; FlipX, FlipY, SixBit, Blend: Boolean; ClipLine: Integer);
begin
  if (W <= 0) or (H <= 0) or (X >= 1024) or (Y >= 1024) or (X + W <= 0) or (Y + H <= 0) then
    Exit;

  var Colours := 256;
  if SixBit then
    Colours := 64;
  var StartY := Max(0, Y);
  var EndY := Min(1023, Y + H - 1);
  if ClipLine >= 0 then
  begin
    StartY := Max(StartY, ClipLine);
    EndY := Min(EndY, ClipLine);
  end;
  for var DY := StartY to EndY do
  begin
    var PY := (DY - Y) * 16 div H;
    if FlipY then
      PY := 15 - PY;
    for var DX := Max(0, X) to Min(1023, X + W - 1) do
    begin
      var PX := (DX - X) * 16 div W;
      if FlipX then
        PX := 15 - PX;
      var Pen := FChar[((Code and $7FFF) * 256 + PY * 16 + PX) and $7FFFFF];
      if Pen = 0 then
        Continue;

      var At := DY * 1024 + DX;
      if Blend then
        FIndices[At] := FIndices[At] or (Cardinal(Pen) shl 15)
      else
        FIndices[At] := Cardinal(Palette * Colours + Pen) and $1FFFF;
    end;
  end;
end;

procedure TCPS3Console.RenderTileMap(LayerNo, Line: Integer);
begin
  var Offset := Cardinal($20 + LayerNo * 16);
  var R0 := Get32(FRegs, Offset);
  var R1 := Get32(FRegs, Offset + 4);
  var R2 := Get32(FRegs, Offset + 8);
  if R1 and $8000 = 0 then
    Exit;

  var ScrollX := Integer(R0 shr 16);
  var ScrollY := Integer(R0 and $FFFF) + 4;
  var L := (Line + ScrollY) and $3FF;
  if R1 and $400 <> 0 then
    L := L xor $3FF;
  if R1 and $4000 <> 0 then
    Inc(ScrollX, Get32(FSprite, ((R2 shr 24) * 1024 + Cardinal((L + 16) and $3FF)) * 4) shr 16);
  for var X := 0 to 64 do
  begin
    var Col := (X + ScrollX div 16) and 63;
    if R1 and $800 <> 0 then
      Col := Col xor 63;
    var At := (((R2 shr 16) and $7F) * 1024 + Cardinal((((L div 16) + 1) and 63) * 64 + Col)) * 4;
    var D := Get32(FSprite, At);
    DrawTile(D shr 17, D and $1FF, X * 16 - ScrollX mod 16, Line - L mod 16, 16, 16,
      (D and $1000 <> 0) xor (R1 and $800 <> 0), D and $800 <> 0, D and $200 <> 0, D and $400 <> 0, Line);
  end;
end;

procedure TCPS3Console.Render;
const
  Sizes: array[0..3] of Integer = (8, 1, 2, 4);
var
  Group, Item, i, TX, TY, X, Y, SourceX, SourceY, SY, SX, At, D, PX, PY, GX, GY, NX, NY, W, H, Line, Palette, DX, DY, ByteValue, Pen: Integer;
  G0, G1, G2, Scroll, Start, Count, V1, V2, V3, ZX, ZY: Cardinal;
  FX, FY, SixBit: Boolean;
begin
  FillChar(FIndices[0], Length(FIndices) * SizeOf(Cardinal), 0);
  for Group := 0 to $2000 div 16 - 1 do
  begin
    G0 := Get32(FList, Group * 16);
    if G0 and $80000000 <> 0 then
      Break;

    G1 := Get32(FList, Group * 16 + 4);
    G2 := Get32(FList, Group * 16 + 8);
    Scroll := Get32(FRegs, ((G0 shr 28) and 7) * 4);
    GX := Integer((G1 shr 16) and $3FF) + Integer((Scroll shr 16) and $3FF);
    GY := Integer(G1 and $3FF) + Integer(Scroll and $3FF);
    Start := (G0 and $7FF0) * 16;
    Count := (G0 shr 16) and $1FF;
    for Item := 0 to Integer(Count) - 1 do
    begin
      V1 := Get32(FList, Start + Cardinal(Item * 16));
      V2 := Get32(FList, Start + Cardinal(Item * 16 + 4));
      V3 := Get32(FList, Start + Cardinal(Item * 16 + 8));
      NX := Integer(V3 and 3);
      NY := Integer((V3 shr 2) and 3);
      if NY = 0 then
        Continue;

      W := Integer((V3 shr 16) and $7F) + 1;
      H := Integer((V3 shr 24) and $7F) + 1;
      X := Integer((V2 shr 16) and $3FF);
      Y := Integer(V2 and $3FF);
      if NX = 0 then
      begin
        for i := 0 to H - 1 do
        begin
          Line := ((not (Y + Integer(Scroll and $3FF) - i)) - 18) and $3FF;
          if Line < 1024 then
            RenderTileMap((V3 shr 4) and 3, Line);
        end;
        Continue;
      end;

      NX := Sizes[NX];
      NY := Sizes[NY];
      FX := (V1 and $1000 <> 0) xor (G2 and $10000000 <> 0);
      FY := (V1 and $800 <> 0) xor (G2 and $08000000 <> 0);
      Palette := Integer(V1 and $1FF);
      if G2 and $20000000 <> 0 then
        Palette := (G2 shr 16) and $1FF;
      SixBit := V1 and $200 <> 0;
      if G2 and $40000000 <> 0 then
        SixBit := G2 and $02000000 <> 0;
      if not FX then
        X := X + W div 2 - W
      else
        X := X - W div 2 + (NX - 1) * W div NX;
      Y := Y + H div 2;
      if FY then
        Dec(Y, (NY - 1) * H div NY);
      for TX := 0 to NX - 1 do
        for TY := 0 to NY - 1 do
        begin
          DX := TX * W div NX;
          if FX then
            DX := -DX;
          DY := TY * H div NY;
          if not FY then
            DY := -DY;
          DX := (GX + X + DX + 1) and $3FF;
          if DX and $200 <> 0 then
            Dec(DX, $400);
          DY := ($3FF - (GY + Y + DY) - 17) and $3FF;
          if DY and $200 <> 0 then
            Dec(DY, $400);
          DrawTile(Integer(V1 shr 17) + TX * NY + TY, Palette, DX, DY, (W + NX - 1) div NX, (H + NY - 1) div NY, FX, FY, SixBit, (V1 and $400 <> 0) or (G2 and $04000000 <> 0));
        end;
    end;
  end;
  ZX := Get32(FRegs, $6C) and $FF;
  ZY := Get32(FRegs, $7C) and $FF;
  if ZX = 0 then
    ZX := $40;
  if ZY = 0 then
    ZY := $40;
  for Y := 0 to 223 do
    for X := 0 to 383 do
    begin
      SourceX := Min(1023, X * Integer(ZX) div 64);
      SourceY := Min(1023, Y * Integer(ZY) div 64);
      FPixels[Y * 384 + X] := PaletteColor(FIndices[SourceY * 1024 + SourceX]);
      SY := (Y + ((-FSSY) and $100)) and $1FF;
      Scroll := FSS[$2000 + (((SY - 1) and $1FF) * 2)];
      SX := (X + Integer(Scroll)) and $1FF;
      At := ((SY div 8) * 128 + (SX div 8) * 2) and $1FFF;
      D := Word(FSS[At]) or (Word(FSS[At + 1]) shl 8);
      PX := SX and 7;
      PY := Y and 7;
      if D and $8000 <> 0 then
        PX := 7 - PX;
      if D and $4000 <> 0 then
        PY := 7 - PY;
      ByteValue := FSS[$4000 + (D and $1FF) * 32 + PY * 4 + PX div 2];
      Pen := (ByteValue shr ((PX and 1) * 4)) and 15;
      if Pen <> 0 then
        FPixels[Y * 384 + X] := PaletteColor(Cardinal((((D shr 9) and 31) + FSSPal * 32) * 16 + Pen));
    end;
end;

function TCPS3Console.Step: Integer;
begin
  FCPU.AdvanceForward(FTime);
  SetIRQ;
  Result := FCPU.Step;
  Inc(FTime, Result);
end;

procedure TCPS3Console.RunFrame;
begin
  FSound.BeginFrame;
  for var Line := 0 to 263 do
  begin
    if Line = 224 then
      FIRQ12 := True;
    var Target := Trunc((FFrameNumber * 264 + Line + 1) * 25000000.0 * 455 * 6 / 42954545);
    while FTime < Target do
    begin
      Step;
    end;
    FSound.AdvanceTo(FTime);
    FDMAStatus := 0;
  end;
  Render;
  Inc(FFrameNumber);
  for var i := 0 to 1 do
    if FCoins[i] > 0 then
      Dec(FCoins[i]);
end;

function TCPS3Console.GetCPUState: TSH2State;
begin
  Result := FCPU.State;
end;

procedure TCPS3Console.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TCPS3Console.InsertCoin(Player: Integer);
begin
  if not (Player in [1, 2]) then
    raise EArgumentOutOfRangeException.Create('CPS3 coin player');

  FCoins[Player - 1] := 3;
end;

procedure TCPS3Console.SerializeState(State: TStateArchive);
begin
  FCPU.SerializeState(State);
  FSCSI.SerializeState(State);
  for var Chip in FFlash do
    Chip.SerializeState(State);

  // Flash can change on both CD and No-CD boards (service installation).
  State.Field(FProgram[0], Length(FProgram));
  State.Field(FGfx[0], Length(FGfx));
  if State.Loading then
  begin
    RebuildCode(0, Length(FProgram));
    FFlashDirty := True;
    Inc(FBatteryRevision);
  end;
  State.Field(FEEPROM, SizeOf(FEEPROM));
  State.Field(FEERead, SizeOf(FEERead));
  State.CompatibleField(FInput, SizeOf(FInput), TEmulatorInput.LegacySize, TEmulatorInput.TravelSize);
  State.Field(FCoins, SizeOf(FCoins));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FIRQ10, SizeOf(FIRQ10));
  State.Field(FIRQ12, SizeOf(FIRQ12));
  State.Field(FCharBank, SizeOf(FCharBank));
  State.Field(FGfxBank, SizeOf(FGfxBank));
  State.Field(FTable, SizeOf(FTable));
  State.Field(FDMASource, SizeOf(FDMASource));
  State.Field(FDMAStatus, SizeOf(FDMAStatus));
  State.Field(FSpriteDMA, SizeOf(FSpriteDMA));
  State.Field(FFlashID, SizeOf(FFlashID));
  State.Field(FGfxPresent, SizeOf(FGfxPresent));
  State.Field(FGfxID, SizeOf(FGfxID));
  State.Field(FSSPal, SizeOf(FSSPal));
  State.Field(FSSY, SizeOf(FSSY));
  State.Field(FRAM[0], Length(FRAM) * SizeOf(FRAM[0]));
  State.Field(FSprite[0], Length(FSprite) * SizeOf(FSprite[0]));
  State.Field(FList[0], Length(FList) * SizeOf(FList[0]));
  State.Field(FChar[0], Length(FChar) * SizeOf(FChar[0]));
  State.Field(FSS[0], Length(FSS) * SizeOf(FSS[0]));
  State.Field(FPalette[0], Length(FPalette) * SizeOf(FPalette[0]));
  State.Field(FRegs[0], Length(FRegs) * SizeOf(FRegs[0]));
  State.Field(FPixels[0], Length(FPixels) * SizeOf(FPixels[0]));
  FSound.SerializeState(State);

  if (FTime < 0) or (FFrameNumber < 0) or (FGfxBank > 31) or (FCharBank > 7) then
    raise EReadError.Create('Invalid CPS3 state');
end;

function TCPS3Console.SecurityMask(Address: Cardinal): Cardinal;
begin
  if FPlain then
    Result := 0
  else
    Result := CPS3Mask(Address, FKey1, FKey2);
end;

procedure TCPS3Console.RebuildCode(Offset, Count: Integer);
begin
  for var i := Offset div 4 to (Offset + Count) div 4 - 1 do
    Put32(FCode, i * 4, Get32(FProgram, i * 4) xor SecurityMask($6000000 + Cardinal(i * 4)));
end;

function TCPS3Console.Battery: TBytes;
begin
  if FCDMode or FFlashDirty then
  begin
    SetLength(Result, SizeOf(FEEPROM) + Length(FProgram) + Length(FGfx));
    Move(FProgram[0], Result[SizeOf(FEEPROM)], Length(FProgram));
    Move(FGfx[0], Result[SizeOf(FEEPROM) + Length(FProgram)], Length(FGfx));
  end
  else
    SetLength(Result, SizeOf(FEEPROM));
  Move(FEEPROM, Result[0], SizeOf(FEEPROM));
end;

procedure TCPS3Console.LoadBattery(const Data: TBytes);
begin
  if (Length(Data) <> SizeOf(FEEPROM)) and (Length(Data) <> SizeOf(FEEPROM) + Length(FProgram) + Length(FGfx)) then
    raise EReadError.Create('Invalid CPS3 EEPROM/SIMM size');

  Move(Data[0], FEEPROM, SizeOf(FEEPROM));
  if Length(Data) > SizeOf(FEEPROM) then
  begin
    Move(Data[SizeOf(FEEPROM)], FProgram[0], Length(FProgram));
    Move(Data[SizeOf(FEEPROM) + Length(FProgram)], FGfx[0], Length(FGfx));
    RebuildCode(0, Length(FProgram));
    FFlashDirty := True;
  end;
end;

end.

