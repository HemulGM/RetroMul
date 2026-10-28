unit CPS2.Console;

interface

uses
  System.SysUtils, System.Classes, CPS1.Console, CPS.Cartridge, HW.M68k,
  Core.Snapshots, CPS.QSound;

type
  TCPS2Console = class(TCPS1Console)
  private
    FDecrypted: TBytes;
    FGigaman2: Boolean;
    FQSound: TCPSQSound;
    FRasterReload: array[0..2] of Word;
    FRasterCount: array[0..1] of Word;
    FScanline: Integer;
    FShared: array[0..1, 0..$FFF] of Byte;
    FExtraRAM: array[0..$4001] of Byte;
    FObjectRAM: array[0..1, 0..$FFF] of Word;
    FObjectBank: Integer;
    FSoundCycles: Integer;
    FEEPROM: array[0..63] of Word;
    FEESelected, FEEClock, FEEOutput, FEEWriteEnabled: Boolean;
    FEEBits, FEEAddress, FEEOperation, FEEReadBit: Integer;
    FEEShift: Cardinal;
    FReadPaddle: Boolean;
    FRotary: array[0..1] of Word;
    FEcoDirection: array[0..1] of Byte;
    procedure EEPROM(Value: Word);
  protected
    procedure BeginAudio; override;
    procedure BeginScanline(Line: Integer); override;
    procedure TriggerRaster; override;
    function GetSamples: TArray<SmallInt>; override;
    function ReadZ(Address: Word): Byte; override;
    procedure WriteZ(Address: Word; Value: Byte); override;
    procedure AdvanceSound(Cycles: Integer); override;
    procedure FinishFrame; override;
  public
    constructor Create(Cart: TCPSCartridge);
    destructor Destroy; override;
    procedure SerializeState(State: TStateArchive); override;
    function Battery: TBytes; override;
    procedure LoadBattery(const Data: TBytes); override;
    procedure Reset; override;
    function ReadWord(Address: Cardinal): Word; override;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True); override;
  end;

implementation

uses
  CPS.RomSets, CPS.Crypto, HW.Z80, CPS.Video, CPS1.Sound, Core.Emulation.Types;

function Fetch(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte): Cardinal;
begin
  var C := TCPS2Console(User);
  Address := Address shl 1;
  if Address + 1 < Cardinal(Length(C.FDecrypted)) then
    Result := (Word(C.FDecrypted[Address]) shl 8) or C.FDecrypted[Address + 1]
  else
    Result := C.ReadWord(Address);
end;

constructor TCPS2Console.Create(Cart: TCPSCartridge);
begin
  if Cart.RomSet.Generation <> TCPSGeneration.CPS2 then
    raise EArgumentException.Create('CPS2 requires a CPS2 ROM set');

  inherited Create(Cart);
  FGigaman2 := Cart.RomSet.Init = 'init_gigaman2';
  if FGigaman2 then
  begin
    if Length(FProgram) <> $400000 then
      raise ECPSRom.Create('Truncated Giga Man 2 code/data flash');

    // Instruction words are preserved separately from data and reset vectors.
    FDecrypted := Copy(FProgram, $200000, $200000);
    FProgram := Copy(FProgram, 0, $200000);
    FProgramRead := Fetch;
    FClock := 16000000;
    FZClock := 8000000;

    // The dumped 16-bit sample flash duplicates the connected 8-bit lane.
    // Preserve its OKI tables/data; command sequencing needs the missing MCU.
    var RawSamples := Cart['oki'];
    if Length(RawSamples) <> $800000 then
      raise ECPSRom.Create('Truncated Giga Man 2 sample flash');

    var SampleROM: TBytes;
    SetLength(SampleROM, Length(RawSamples) div 2);
    for var i := 0 to High(SampleROM) do
    begin
      if RawSamples[i * 2] <> RawSamples[i * 2 + 1] then
        raise ECPSRom.Create('Invalid Giga Man 2 sample flash lanes');

      SampleROM[i] := RawSamples[i * 2];
    end;
    FSound.Free;
    FSound := nil;
    FSound := TCPS1Sound.Create(SampleROM, FZClock);
    Video.ConfigureScrollOffset(-9);
    Video.ConfigureAddressMask($7FFFFF);
    FillChar(FEEPROM, SizeOf(FEEPROM), $FF);
    FEEOutput := True;
    Reset;
    Exit;
  end;

  FQSound := TCPSQSound.Create(Cart['qsound']);
  var Key0 := Cart.RomSet.MasterKey[0];
  var Key1 := Cart.RomSet.MasterKey[1];
  var Encrypted := Cart.RomSet.EncryptedBytes;
  if Cart.HasRegion('key') then
  begin
    var ROM := Cart['key'];
    if Length(ROM) < 20 then
      raise ECPSRom.Create('Truncated CPS2 security key');

    var Decoded: array[0..9] of Word;
    FillChar(Decoded, SizeOf(Decoded), 0);
    for var B := 0 to 159 do
    begin
      var BitNo := (317 - B) mod 160;
      if ROM[BitNo div 8] and (1 shl ((BitNo xor 7) mod 8)) <> 0 then
        Decoded[B div 16] := Decoded[B div 16] or (Word($8000) shr (B mod 16));
    end;
    Key0 := (Cardinal(Decoded[0]) shl 16) or Decoded[1];
    Key1 := (Cardinal(Decoded[2]) shl 16) or Decoded[3];
    if Decoded[9] = $FFFF then
      Encrypted := 0
    else
      Encrypted := (((not Cardinal(Decoded[9]) and $3FF) shl 14) or $3FFF) + 1;
  end
  else if not Cart.RomSet.Machine.StartsWith('dead_cps2') and (Encrypted = 0) then
    raise ECPSRom.Create('CPS2 security key is required');

  if Encrypted > Cardinal(Length(FProgram)) then
    Encrypted := Length(FProgram);
  if Encrypted = 0 then
    FDecrypted := Copy(FProgram)
  else
    FDecrypted := DecryptCPS2(FProgram, Key0, Key1, Encrypted);
  FProgramRead := Fetch;
  FClock := 16000000;
  FZClock := 8000000;
  FZHoldInterrupt := True;
  FillChar(FEEPROM, SizeOf(FEEPROM), $FF);
  FEEOutput := True;
  Reset;
end;

destructor TCPS2Console.Destroy;
begin
  FQSound.Free;
  inherited;
end;

procedure TCPS2Console.BeginAudio;
begin
  if FGigaman2 then
    FSound.BeginFrame
  else
    FQSound.BeginFrame;
  Video.BeginRaster;
  if (FCart.RomSet.Init = 'init_pzloop2') or (FCart.RomSet.Init = 'init_ecofghtr') then
    for var P := 0 to 1 do
    begin
      var Buttons := FInput.Buttons;
      if P = 1 then
        Buttons := FInput.Buttons2;
      var Delta := 0;
      if FInput.Analog[P].Valid then
        Delta := FInput.Analog[P].X div 1024;
      if TEmulatorButton.X in Buttons then
        Dec(Delta, 8);
      if TEmulatorButton.Y in Buttons then
        Inc(Delta, 8);
      if (FCart.RomSet.Init = 'init_pzloop2') and not FReadPaddle then
      begin
        if TEmulatorButton.Left in Buttons then
          Dec(Delta, 8);
        if TEmulatorButton.Right in Buttons then
          Inc(Delta, 8);
      end;
      if Delta <> 0 then
        FEcoDirection[P] := Ord(Delta > 0);
      FRotary[P] := (Integer(FRotary[P]) + Delta + $1000) and $FFF;
    end;
end;

procedure TCPS2Console.BeginScanline(Line: Integer);
begin
  inherited;
  FScanline := Line;
  var Pending := False;
  for var i := 0 to 1 do
  begin
    if Line = 0 then
      FRasterCount[i] := FRasterReload[i]
    else
      FRasterCount[i] := (FRasterCount[i] + 511) and $1FF;
    if FRasterCount[i] = 0 then
      Pending := True;
  end;
  if Pending then
    FNextIRQ := ((FFrameNumber * 262 + Line) * Int64(FClock) * 512) div 8000000 +
      Int64(FRasterReload[2]) * 2 * FClock div 8000000;
end;

procedure TCPS2Console.TriggerRaster;
begin
  inherited;
  Video.PaletteDMA;
  Video.RenderTo(FScanline - 16);
  Clown68000Interrupt(FCPU, FCPU.PendingInterrupt or 4);
end;

function TCPS2Console.GetSamples: TArray<SmallInt>;
begin
  if FGigaman2 then
    Result := FSound.Samples
  else
    Result := FQSound.Samples;
end;

procedure TCPS2Console.Reset;
begin
  inherited;
  if FQSound <> nil then
    FQSound.Reset;
  FillChar(FShared, SizeOf(FShared), 0);
  FillChar(FExtraRAM, SizeOf(FExtraRAM), 0);
  FillChar(FObjectRAM, SizeOf(FObjectRAM), 0);
  FObjectBank := 0;
  FSoundCycles := 0;
  FRasterReload[0] := $1FF;
  FRasterReload[1] := $1FF;
  FRasterReload[2] := 0;
  FillChar(FRasterCount, SizeOf(FRasterCount), 0);
  FScanline := 0;
  FSoundEnabled := False;
  FEESelected := False;
  FEEClock := False;
  FEEOutput := True;
  FEEBits := 0;
  FEEShift := 0;
  FEEOperation := 0;
  FEEWriteEnabled := False;
  FReadPaddle := False;
  FillChar(FRotary, SizeOf(FRotary), 0);
  FillChar(FEcoDirection, SizeOf(FEcoDirection), 0);
end;

function TCPS2Console.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  if (Address = $80414E) or (Address = $80014E) then
  begin
    var LineStart := ((FFrameNumber * 262 + FScanline) * Int64(FClock) * 512) div 8000000;
    var HPos := (FTime - LineStart) * 8000000 div FClock;
    Exit(Word(((Int64(FRasterReload[2]) - HPos div 2) * 2) and $1FE) or (Video.B[$0E div 2] and 1));
  end;

  if (Address = $804150) or (Address = $804152) then
    Exit(FRasterCount[(Address shr 1) and 1]);

  if (Address = $800150) or (Address = $800152) then
    Exit(FRasterCount[(Address shr 1) and 1]);

  if (Address >= $618000) and (Address < $61A000) then
  begin
    var Index := (Address - $618000) div 2;
    if FGigaman2 then
      Exit((Word(FShared[1, Index]) shl 8) or FShared[0, Index]);

    Exit($FF00 or FShared[0, Index]);
  end;

  if (Address >= $660000) and (Address < $664002) then
    Exit((Word(FExtraRAM[Address - $660000]) shl 8) or FExtraRAM[Address - $660000 + 1]);

  if (Address >= $708000) and (Address < $710000) then
    Exit(FObjectRAM[1 xor FObjectBank, (Address and $1FFF) div 2]);

  if (Address >= $400000) and (Address < $40000C) then
    Exit(Video.Output[(Address - $400000) div 2]);

  if (Address >= $804100) and (Address < $804180) then
    Exit(inherited ReadWord(Address - $4000));

  case Address of
    $804000:
      begin
        if ((FCart.RomSet.Init = 'init_pzloop2') and not FReadPaddle) or
          ((FCart.RomSet.Init = 'init_ecofghtr') and FReadPaddle and
          (FInput.Analog[0].Valid or FInput.Analog[1].Valid)) then
          Exit((FRotary[0] and $FF) or ((FRotary[1] and $FF) shl 8));

        Result := (Word(Pad(FInput.Buttons2)) shl 8) or Pad(FInput.Buttons);
        if (FCart.RomSet.Init = 'init_ecofghtr') and
          (FInput.Analog[0].Valid or FInput.Analog[1].Valid) then
          Result := (Result and $DFDF) or (Word(FEcoDirection[0]) shl 5) or (Word(FEcoDirection[1]) shl 13);
        Exit;
      end;
    $804010:
      begin
        if FCart.RomSet.Inputs.StartsWith('cps2_4p') then
          Exit((Word(Pad(FInput.Buttons4)) shl 8) or Pad(FInput.Buttons3));

        if FCart.RomSet.Inputs.StartsWith('cps2_3p') then
          Exit($FF00 or Pad(FInput.Buttons3));

        Result := $FFFF;
        if (FCart.RomSet.Init = 'init_ecofghtr') and
          (FInput.Analog[0].Valid or FInput.Analog[1].Valid) then
          Result := Result and $FFEF;
        if TEmulatorButton.X in FInput.Buttons then
          Result := Result and $FFFE;
        if TEmulatorButton.Y in FInput.Buttons then
          Result := Result and $FFFD;
        if TEmulatorButton.Z in FInput.Buttons then
          Result := Result and $FFFB;
        if TEmulatorButton.X in FInput.Buttons2 then
          Result := Result and $FFEF;
        if TEmulatorButton.Y in FInput.Buttons2 then
          Result := Result and $FFDF;
        Exit;
      end;
    $804020:
      begin
        Result := $FFFF;
        if not FEEOutput then
          Result := Result and $FFFE;
        if TEmulatorButton.Mode in FInput.Buttons then
          Result := Result and $FFFD;
        if FCart.RomSet.Inputs.EndsWith('6b') and (TEmulatorButton.Z in FInput.Buttons2) then
          Result := Result and $BFFF;
        if TEmulatorButton.Start in FInput.Buttons then
          Result := Result and $FEFF;
        if TEmulatorButton.Start in FInput.Buttons2 then
          Result := Result and $FDFF;
        if FCart.RomSet.Inputs.StartsWith('cps2_3p') or FCart.RomSet.Inputs.StartsWith('cps2_4p') then
        begin
          if TEmulatorButton.Start in FInput.Buttons3 then
            Result := Result and $FBFF;
          if TEmulatorButton.Select in FInput.Buttons3 then
            Result := Result and $BFFF;
        end;
        if FCart.RomSet.Inputs.StartsWith('cps2_4p') then
        begin
          if TEmulatorButton.Start in FInput.Buttons4 then
            Result := Result and $F7FF;
          if TEmulatorButton.Select in FInput.Buttons4 then
            Result := Result and $7FFF;
        end;
        if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
          Result := Result and $EFFF;
        if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
          Result := Result and $DFFF;
        Exit;
      end;
    $804030:
      Exit($D000);
  end;
  Result := inherited ReadWord(Address);
end;

procedure TCPS2Console.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  function Merge(Old: Word): Word;
  begin
    Result := Old;
    if HighByte then
      Result := (Result and $FF) or (Value and $FF00);
    if LowByte then
      Result := (Result and $FF00) or (Value and $FF);
  end;

begin
  Address := Address and $FFFFFE;
  if ((Address >= $80414E) and (Address <= $804152)) or ((Address >= $80014E) and (Address <= $800152)) then
  begin
    var Index := (Integer(Address and $FF) - $50) div 2;
    if Address and $FF = $4E then
      Index := 2;
    var Old := FRasterReload[Index];
    if Index = 2 then
      Old := Old shl 1;
    if HighByte then
      Old := (Old and $FF) or (Value and $FF00);
    if LowByte then
      Old := (Old and $FF00) or (Value and $FF);
    if Index = 2 then
    begin
      FRasterReload[Index] := (Old shr 1) and $FF;
      Video.B[$0E div 2] := Old;
    end
    else
    begin
      FRasterReload[Index] := Old and $1FF;
      if Old and $8000 <> 0 then
        FRasterCount[Index] := FRasterReload[Index];
    end;
    Exit;
  end;

  if (Address >= $618000) and (Address < $61A000) then
  begin
    if LowByte then
      FShared[0, (Address - $618000) div 2] := Byte(Value and $FF);
    if FGigaman2 and HighByte then
      FShared[1, (Address - $618000) div 2] := Byte(Value shr 8);
  end
  else if (Address >= $660000) and (Address < $664002) then
  begin
    if HighByte then
      FExtraRAM[Address - $660000] := Byte(Value shr 8);
    if LowByte then
      FExtraRAM[Address - $660000 + 1] := Byte(Value and $FF);
  end
  else if (Address >= $400000) and (Address < $40000C) then
    Video.Output[(Address - $400000) div 2] := Merge(Video.Output[(Address - $400000) div 2])
  else if (Address >= $700000) and (Address < $702000) then
    FObjectRAM[FObjectBank, (Address and $1FFF) div 2] := Merge(FObjectRAM[FObjectBank, (Address and $1FFF) div 2])
  else if (Address >= $708000) and (Address < $710000) then
    FObjectRAM[1 xor FObjectBank, (Address and $1FFF) div 2] := Merge(FObjectRAM[1 xor FObjectBank, (Address and $1FFF) div 2])
  else if (Address >= $804100) and (Address < $804180) then
    inherited WriteWord(Address - $4000, Value, HighByte, LowByte)
  else if Address = $804040 then
  begin
    if HighByte then
    begin
      EEPROM(Value);
      if FCart.RomSet.Init = 'init_ecofghtr' then
        FReadPaddle := Value and $100 <> 0;
    end;
    if LowByte then
    begin
      if FCart.RomSet.Init = 'init_pzloop2' then
        FReadPaddle := Value and 2 <> 0;
      var Enabled := (Value and 8 <> 0) and not FGigaman2;
      if Enabled and not FSoundEnabled then
      begin
        Z80Reset(FZ80);
        FBank := 0;
      end;
      FSoundEnabled := Enabled;
    end;
  end
  else if (Address = $8040E0) and LowByte then
    FObjectBank := Value and 1
  else
    inherited;
end;

function TCPS2Console.ReadZ(Address: Word): Byte;
begin
  if Address < $8000 then
    Exit(FAudio[Address]);

  if Address < $C000 then
  begin
    var Index := $10000 + (FBank and 15) * $4000 + (Address and $3FFF);
    if Index < Length(FAudio) then
      Exit(FAudio[Index]);

    Exit($FF);
  end;

  if (Address >= $C000) and (Address < $D000) then
    Exit(FShared[0, Address and $FFF]);

  if Address >= $F000 then
    Exit(FShared[1, Address and $FFF]);

  if Address = $D007 then
    Exit(FQSound.Status);

  Result := $FF;
end;

procedure TCPS2Console.WriteZ(Address: Word; Value: Byte);
begin
  if (Address >= $D000) and (Address <= $D002) then
    FQSound.Write(Address - $D000, Value);
  if (Address >= $C000) and (Address < $D000) then
    FShared[0, Address and $FFF] := Value;
  if Address >= $F000 then
    FShared[1, Address and $FFF] := Value;
  if Address = $D003 then
    FBank := Value;
end;

procedure TCPS2Console.AdvanceSound(Cycles: Integer);
begin
  if FGigaman2 then
  begin
    FSound.Advance(Cycles);
    Exit;
  end;

  FQSound.Advance(Cycles);
  Inc(FSoundCycles, Cycles);
  if FSoundCycles >= 32000 then
  begin
    Dec(FSoundCycles, 32000);
    Z80Interrupt(FZ80, 1);
  end;
end;

procedure TCPS2Console.FinishFrame;
begin
  if FGigaman2 then
    FSound.EndFrame
  else
    FQSound.EndFrame;
  Video.PaletteDMA;
  Video.RenderTo(CPS_HEIGHT - 1);
  Video.LatchCPS2(FObjectRAM[FObjectBank]);
end;

procedure TCPS2Console.EEPROM(Value: Word);
begin
  // 93C46 x16: DI=12, CLK=13, CS=14. Writes are gated by EWEN.
  var Selected := Value and $4000 <> 0;
  var Clock := Value and $2000 <> 0;
  if not Selected then
  begin
    FEEBits := 0;
    FEEShift := 0;
    FEEOperation := 0;
    FEEReadBit := -1;
    FEEOutput := True;
  end
  else if FEESelected and Clock and not FEEClock then
  begin
    if FEEOperation = 2 then
    begin
      if FEEReadBit < 0 then
      begin
        FEEAddress := (FEEAddress + 1) and 63;
        FEEReadBit := 15;
      end;
      FEEOutput := FEEPROM[FEEAddress] and (1 shl FEEReadBit) <> 0;
      Dec(FEEReadBit);
    end
    else
    begin
      var BitValue := Ord(Value and $1000 <> 0);
      if (FEEBits <> 0) or (BitValue <> 0) then
      begin
        FEEShift := (FEEShift shl 1) or Cardinal(BitValue);
        Inc(FEEBits);
        if FEEBits = 9 then
        begin
          FEEAddress := FEEShift and 63;
          FEEOperation := (FEEShift shr 6) and 3;
          if FEEOperation = 2 then
          begin
            FEEReadBit := 15;
            FEEOutput := False;
          end;
          if (FEEOperation = 3) and FEEWriteEnabled then
            FEEPROM[FEEAddress] := $FFFF;
          if FEEOperation = 0 then
          begin
            case FEEAddress shr 4 of
              0:
                FEEWriteEnabled := False;
              3:
                FEEWriteEnabled := True;
              2:
                if FEEWriteEnabled then
                  FillChar(FEEPROM, SizeOf(FEEPROM), $FF);
            end;
          end;
        end;
        if (FEEBits = 25) and FEEWriteEnabled then
        begin
          if FEEOperation = 1 then
            FEEPROM[FEEAddress] := Word(FEEShift and $FFFF)
          else if (FEEOperation = 0) and (FEEAddress shr 4 = 1) then
            for var i := 0 to 63 do
              FEEPROM[i] := Word(FEEShift and $FFFF);
        end;
      end;
    end;
  end;
  FEESelected := Selected;
  FEEClock := Clock;
end;

procedure TCPS2Console.SerializeState(State: TStateArchive);
begin
  inherited;
  if not FGigaman2 then
    FQSound.SerializeState(State);
  State.Field(FRasterReload, SizeOf(FRasterReload));
  State.Field(FRasterCount, SizeOf(FRasterCount));
  State.Field(FScanline, SizeOf(FScanline));
  if (FScanline < 0) or (FScanline > 261) or (FRasterReload[0] > 511) or (FRasterReload[1] > 511) or
    (FRasterReload[2] > 255) or (FRasterCount[0] > 511) or (FRasterCount[1] > 511) then
    raise EReadError.Create('Invalid CPS2 raster state');

  State.Field(FShared, SizeOf(FShared));
  State.Field(FExtraRAM, SizeOf(FExtraRAM));
  State.Field(FObjectRAM, SizeOf(FObjectRAM));
  State.Field(FObjectBank, SizeOf(FObjectBank));
  State.Field(FSoundCycles, SizeOf(FSoundCycles));
  State.Field(FReadPaddle, SizeOf(FReadPaddle));
  State.Field(FRotary, SizeOf(FRotary));
  State.Field(FEcoDirection, SizeOf(FEcoDirection));
  State.Field(FEEPROM, SizeOf(FEEPROM));
  State.Field(FEESelected, SizeOf(FEESelected));
  State.Field(FEEClock, SizeOf(FEEClock));
  State.Field(FEEOutput, SizeOf(FEEOutput));
  State.Field(FEEWriteEnabled, SizeOf(FEEWriteEnabled));
  State.Field(FEEBits, SizeOf(FEEBits));
  State.Field(FEEAddress, SizeOf(FEEAddress));
  State.Field(FEEOperation, SizeOf(FEEOperation));
  State.Field(FEEReadBit, SizeOf(FEEReadBit));
  State.Field(FEEShift, SizeOf(FEEShift));

  if not (FObjectBank in [0, 1]) or (FEEAddress < 0) or (FEEAddress > 63) or (FEEBits < 0) or (FEEBits > 25) then
    raise EReadError.Create('Invalid CPS2 state');
end;

function TCPS2Console.Battery: TBytes;
begin
  SetLength(Result, SizeOf(FEEPROM));
  Move(FEEPROM, Result[0], Length(Result));
end;

procedure TCPS2Console.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FEEPROM) then
    raise EReadError.Create('Invalid CPS2 EEPROM size');

  Move(Data[0], FEEPROM, Length(Data));
end;

end.

