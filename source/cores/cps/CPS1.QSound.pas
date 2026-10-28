unit CPS1.QSound;

interface

uses
  System.SysUtils, System.Classes, CPS1.Console, CPS.Cartridge, CPS.QSound,
  Core.Snapshots;

type
  TCPS1QSoundConsole = class(TCPS1Console)
  private
    FQSound: TCPSQSound;
    FRawAudio, FOpcodes: TBytes;
    FShared: array[0..1, 0..$FFF] of Byte;
    FSoundCycles: Integer;
    FEEPROM: array[0..127] of Byte;
    FEESelected, FEEClock, FEEOutput, FEEWriteEnabled: Boolean;
    FEEBits, FEEAddress, FEEOperation, FEEReadBit: Integer;
    FEEShift: Cardinal;
    procedure EEPROM(Value: Byte);
  protected
    procedure BeginAudio; override;
    function GetSamples: TArray<SmallInt>; override;
    function ReadZ(Address: Word): Byte; override;
    procedure WriteZ(Address: Word; Value: Byte); override;
    procedure AdvanceSound(Cycles: Integer); override;
    procedure FinishFrame; override;
  public
    constructor Create(Cart: TCPSCartridge);
    destructor Destroy; override;
    procedure Reset; override;
    procedure SerializeState(State: TStateArchive); override;
    function Battery: TBytes; override;
    procedure LoadBattery(const Data: TBytes); override;
    function ReadWord(Address: Cardinal): Word; override;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True); override;
  end;

function CreateCPS1Console(Cart: TCPSCartridge): TCPS1Console;

implementation

uses
  CPS.Kabuki, HW.Z80, CPS1.Boards, CPS1.Fcrash, CPS1.PIC, CPS1.MSM,
  CPS1.Multigame;

function CreateCPS1Console(Cart: TCPSCartridge): TCPS1Console;
begin
  if Cart.RomSet.Init = 'init_cps1mult' then
    Exit(TCPSMultigameConsole.Create(Cart));

  if (Cart.RomSet.Machine = 'captcommb2') or (Cart.RomSet.Machine = 'knightsb') or
    (Cart.RomSet.Machine = 'sf2mdt') or (Cart.RomSet.Machine = 'sf2b') then
    Exit(TCPSMSMConsole.Create(Cart));

  if Cart.RomSet.Machine = 'punipic' then
    Exit(TCPSPICConsole.Create(Cart));

  if (Cart.RomSet.Machine = 'fcrash') or (Cart.RomSet.Machine = 'cawingbl') or
    (Cart.RomSet.Machine = 'kodb') or (Cart.RomSet.Machine = 'mtwinsb') or
    (Cart.RomSet.Machine = 'sf2m1') or (Cart.RomSet.Machine = 'varthb') or
    (Cart.RomSet.Machine = 'sgyxz') or (Cart.RomSet.Machine = 'wofabl') or
    (Cart.RomSet.Machine = 'wofr1bl') or (Cart.RomSet.Machine = 'ffightblb') then
    Exit(TCPSFcrashConsole.Create(Cart));

  if Cart.HasRegion('qsound') then
    Result := TCPS1QSoundConsole.Create(Cart)
  else
    Result := TCPS1BoardConsole.Create(Cart);
end;

function Fetch(User: Pointer; Address: Cardinal): Cardinal;
begin
  var C := TCPS1QSoundConsole(User);
  if Address < $8000 then
    Result := C.FOpcodes[Address]
  else
    Result := C.ReadZ(Word(Address and $FFFF));
end;

constructor TCPS1QSoundConsole.Create(Cart: TCPSCartridge);
begin
  inherited Create(Cart);
  FRawAudio := Copy(FAudio);
  var Name := Cart.RomSet.Name;
  var Family := Name;
  if Name.StartsWith('wof') then
    Family := 'wof'
  else if Name.StartsWith('dino') then
    Family := 'dino'
  else if Name.StartsWith('punisher') then
    Family := 'punisher'
  else if Name.StartsWith('slammast') or Name.StartsWith('mbomb') then
    Family := 'slammast';
  DecodeKabuki(FRawAudio, Family, FAudio, FOpcodes);
  FZProgramRead := Fetch;
  FZHoldInterrupt := True;
  FQSound := TCPSQSound.Create(Cart['qsound']);
  FClock := 12000000;
  FZClock := 8000000;
  DIP[0] := $FF;
  DIP[1] := $FF;
  DIP[2] := $FF;
  FillChar(FEEPROM, SizeOf(FEEPROM), $FF);
  Reset;
end;

destructor TCPS1QSoundConsole.Destroy;
begin
  FQSound.Free;
  inherited;
end;

procedure TCPS1QSoundConsole.Reset;
begin
  inherited;
  if FQSound <> nil then
    FQSound.Reset;
  FillChar(FShared, SizeOf(FShared), 0);
  FSoundCycles := 0;
  FSoundEnabled := True;
  FEESelected := False;
  FEEClock := False;
  FEEOutput := True;
  FEEBits := 0;
  FEEAddress := 0;
  FEEOperation := 0;
  FEEReadBit := -1;
  FEEShift := 0;
  FEEWriteEnabled := False;
end;

procedure TCPS1QSoundConsole.BeginAudio;
begin
  FQSound.BeginFrame;
end;

function TCPS1QSoundConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FQSound.Samples;
end;

function TCPS1QSoundConsole.ReadZ(Address: Word): Byte;
begin
  if Address < $8000 then
    Exit(FAudio[Address]);

  if Address < $C000 then
  begin
    var Bank := FBank and 15;
    if $10000 + Bank * $4000 >= Length(FAudio) then
      Bank := 0;
    var Index := $10000 + Bank * $4000 + (Address and $3FFF);
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

procedure TCPS1QSoundConsole.WriteZ(Address: Word; Value: Byte);
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

procedure TCPS1QSoundConsole.AdvanceSound(Cycles: Integer);
begin
  FQSound.Advance(Cycles);
  Inc(FSoundCycles, Cycles);
  if FSoundCycles >= 32000 then
  begin
    Dec(FSoundCycles, 32000);
    Z80Interrupt(FZ80, 1);
  end;
  // HOLD_LINE: the Z80 acknowledges and clears the pending interrupt.
end;

procedure TCPS1QSoundConsole.FinishFrame;
begin
  FQSound.EndFrame;
  Video.Render;
  Video.LatchObjects;
end;

function TCPS1QSoundConsole.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  if (Address >= $F00000) and (Address < $F10000) then
    Exit($FF00 or FRawAudio[(Address - $F00000) div 2]);

  if (Address >= $F18000) and (Address < $F1A000) then
    Exit($FF00 or FShared[0, (Address - $F18000) div 2]);

  if (Address >= $F1E000) and (Address < $F20000) then
    Exit($FF00 or FShared[1, (Address - $F1E000) div 2]);

  if Address = $F1C006 then
    Exit(Ord(FEEOutput));

  if Address = $F1C000 then
  begin
    if FCart.RomSet.Inputs = 'punisher' then
      Exit($FFFF);

    Exit(ExtraPad(FInput.Buttons3));
  end;

  if Address = $F1C002 then
  begin
    if FCart.RomSet.Inputs <> 'slammast' then
      Exit($FFFF);

    Exit(ExtraPad(FInput.Buttons4));
  end;

  Result := inherited ReadWord(Address);
end;

procedure TCPS1QSoundConsole.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  Address := Address and $FFFFFE;
  if (Address >= $F18000) and (Address < $F1A000) then
  begin
    if LowByte then
      FShared[0, (Address - $F18000) div 2] := Byte(Value and $FF);
  end
  else if (Address >= $F1E000) and (Address < $F20000) then
  begin
    if LowByte then
      FShared[1, (Address - $F1E000) div 2] := Byte(Value and $FF);
  end
  else if Address = $F1C006 then
  begin
    if LowByte then
      EEPROM(Byte(Value and $FF));
  end
  else
    inherited;
end;

procedure TCPS1QSoundConsole.EEPROM(Value: Byte);
begin
  // 93C46 x8: start + 2 operation bits + 7 address bits + 8 data bits.
  var Selected := Value and $80 <> 0;
  var Clock := Value and $40 <> 0;
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
        FEEAddress := (FEEAddress + 1) and 127;
        FEEReadBit := 7;
      end;
      FEEOutput := FEEPROM[FEEAddress] and (1 shl FEEReadBit) <> 0;
      Dec(FEEReadBit);
    end
    else
    begin
      var BitValue := Value and 1;
      if (FEEBits <> 0) or (BitValue <> 0) then
      begin
        FEEShift := (FEEShift shl 1) or BitValue;
        Inc(FEEBits);
        if FEEBits = 10 then
        begin
          FEEAddress := FEEShift and 127;
          FEEOperation := (FEEShift shr 7) and 3;
          if FEEOperation = 2 then
          begin
            FEEReadBit := 7;
            FEEOutput := False;
          end;
          if (FEEOperation = 3) and FEEWriteEnabled then
            FEEPROM[FEEAddress] := $FF;
          if FEEOperation = 0 then
            case FEEAddress shr 5 of
              0:
                FEEWriteEnabled := False;
              3:
                FEEWriteEnabled := True;
              2:
                if FEEWriteEnabled then
                  FillChar(FEEPROM, SizeOf(FEEPROM), $FF);
            end;
        end;
        if (FEEBits = 18) and FEEWriteEnabled then
        begin
          if FEEOperation = 1 then
            FEEPROM[FEEAddress] := Byte(FEEShift and $FF)
          else if (FEEOperation = 0) and (FEEAddress shr 5 = 1) then
            FillChar(FEEPROM, SizeOf(FEEPROM), Byte(FEEShift and $FF));
        end;
      end;
    end;
  end;
  FEESelected := Selected;
  FEEClock := Clock;
end;

procedure TCPS1QSoundConsole.SerializeState(State: TStateArchive);
begin
  inherited;
  FQSound.SerializeState(State);
  State.Field(FShared, SizeOf(FShared));
  State.Field(FSoundCycles, SizeOf(FSoundCycles));
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

  if (FEEAddress < 0) or (FEEAddress > 127) or (FEEBits < 0) or (FEEBits > 18) or
    (FEEOperation < 0) or (FEEOperation > 3) or (FEEReadBit < -1) or (FEEReadBit > 7) or
    (FSoundCycles < 0) or (FSoundCycles >= 32000) then
    raise EReadError.Create('Invalid CPS1 QSound state');
end;

function TCPS1QSoundConsole.Battery: TBytes;
begin
  SetLength(Result, SizeOf(FEEPROM));
  Move(FEEPROM, Result[0], Length(Result));
end;

procedure TCPS1QSoundConsole.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FEEPROM) then
    raise EReadError.Create('Invalid CPS1 EEPROM size');

  Move(Data[0], FEEPROM, Length(Data));
end;

end.

