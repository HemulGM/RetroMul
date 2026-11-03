unit CPS1.Fcrash;

interface

uses
  System.SysUtils, CPS1.Boards, CPS.Cartridge, CPS.BootlegSound, CPS.EEPROM,
  Core.Snapshots;

type
  TCPSFcrashConsole = class(TCPS1BoardConsole)
  private
    FBootSound: TCPSBootlegSound;
    FCawing: Boolean;
    FMachine: string;
    FSpriteRAM: TArray<Word>;
    FSerial: TCPS93C46;
    FSpriteBase: Integer;
    function SpriteIndex(Address: Cardinal): Integer;
    procedure Layers(Offset: Integer; Value: Word);
  protected
    procedure BeginAudio; override;
    procedure BeginScanline(Line: Integer); override;
    procedure AdvanceSound(Cycles: Integer); override;
    procedure FinishFrame; override;
    function GetSamples: TArray<SmallInt>; override;
    function ReadZ(Address: Word): Byte; override;
    procedure WriteZ(Address: Word; Value: Byte); override;
  public
    constructor Create(Cart: TCPSCartridge);
    destructor Destroy; override;
    procedure Reset; override;
    function ReadWord(Address: Cardinal): Word; override;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True); override;
    procedure SerializeState(State: TStateArchive); override;
    function Battery: TBytes; override;
    procedure LoadBattery(const Data: TBytes); override;
  end;

implementation

uses
  HW.Z80, HW.M68k, CPS1.Sound;

constructor TCPSFcrashConsole.Create(Cart: TCPSCartridge);
begin
  inherited;
  FCawing := Cart.RomSet.Machine = 'cawingbl';
  FMachine := Cart.RomSet.Machine;
  FSpriteBase := $1000;
  if (FMachine = 'fcrash') or FCawing then
  begin
    FBootSound := TCPSBootlegSound.Create;
    FZClock := 4000000;
    FZHoldInterrupt := True;
  end;
  if FCawing then
    Video.ConfigureBootleg($0C, [$0A, $08, $06, $04], 63, 62, 65, $1000, $8000)
  else
    Video.ConfigureBootleg($20, [$26, $30, $28, $32], 62, 60, 64, $50C8, $8000);
  if FMachine = 'kodb' then
    Video.ConfigureBootleg($20, [$2E, $2C, $2A, $28], 0, 0, 0, $1000, $FFFF);
  if FMachine = 'mtwinsb' then
    Video.ConfigureBootleg($12, [$14, $16, $18, $1A], 0, 0, 0, $1000, $8000);
  if FMachine = 'varthb' then
    Video.ConfigureBootleg($12, [$14, $16, $18, $1A], 0, 0, 0, $1000, $8000);
  if FMachine = 'sf2m1' then
    Video.ConfigureBootleg($26, [$28, $2A, $2C, $2E], 62, 60, 64, $1000, $8000);
  if (FMachine = 'sgyxz') or (FMachine = 'wofabl') then
    Video.ConfigureBootleg($20, [$38, $3A, $3C, $3E], 64, 64, 64, $1000, $8000, True);
  if FMachine = 'wofr1bl' then
  begin
    FSerial := TCPS93C46.Create(8);
    Video.ConfigureBootleg($26, [$28, $2A, $2C, $2E], 64, 64, 64, $1000, $8000, True, 2);
  end;
  if FMachine = 'ffightblb' then
  begin
    FZClock := 4000000;
    FZHoldInterrupt := True;
    FSound.Free;
    FSound := TCPS1Sound.Create(Cart['oki'], 4000000);
    Video.ConfigureBootleg($20, [$26, $30, $28, $32], 0, 8, 4, $5008, $8000, False, -$38);
  end;
  if (FMachine = 'kodb') or (FMachine = 'mtwinsb') or (FMachine = 'sf2m1') or (FMachine = 'varthb') or (FMachine = 'wofr1bl') then
  begin
    SetLength(FSpriteRAM, $2000);
    Video.BindBootlegSprites(FSpriteRAM);
  end;
  Reset;
end;

destructor TCPSFcrashConsole.Destroy;
begin
  FBootSound.Free;
  FSerial.Free;
  inherited;
end;

procedure TCPSFcrashConsole.Reset;
begin
  inherited;
  if FBootSound <> nil then
    FBootSound.Reset;
  FSpriteBase := $1000;
  if FSerial <> nil then
    FSerial.Reset;
  if FMachine = 'ffightblb' then
    FSound.SetSampleBank($20000, $20000, $20000);
  if (FMachine = 'sgyxz') or (FMachine = 'wofabl') then
  begin
    Video.B[$3C div 2] := $1FF;
    Video.B[$3E div 2] := $1FF;
  end;
  if Length(FSpriteRAM) > 0 then
    FillChar(FSpriteRAM[0], Length(FSpriteRAM) * SizeOf(Word), 0);
end;

procedure TCPSFcrashConsole.BeginAudio;
begin
  if FBootSound <> nil then
    FBootSound.BeginFrame
  else
    inherited;
  if FMachine = 'wofr1bl' then
    Video.SetBootlegSpriteBase(FSpriteBase);
end;

procedure TCPSFcrashConsole.BeginScanline(Line: Integer);
begin
  if Line = 240 then
    if FCawing then
      Clown68000Interrupt(FCPU, 6)
    else
      Clown68000Interrupt(FCPU, 2);
end;

procedure TCPSFcrashConsole.AdvanceSound(Cycles: Integer);
begin
  if FBootSound <> nil then
    FBootSound.Advance(Cycles, FZ80)
  else if FMachine = 'ffightblb' then
    FSound.Advance(Cycles)
  else
    inherited;
end;

procedure TCPSFcrashConsole.FinishFrame;
begin
  if FBootSound <> nil then
    FBootSound.EndFrame
  else
    FSound.EndFrame;
  Video.Render;
end;

function TCPSFcrashConsole.GetSamples: TArray<SmallInt>;
begin
  if FBootSound <> nil then
    Result := FBootSound.Samples
  else
    Result := inherited;
end;

function TCPSFcrashConsole.ReadZ(Address: Word): Byte;
begin
  if FMachine = 'ffightblb' then
  begin
    if Address < $8000 then
      Exit(FAudio[Address]);

    if (Address >= $8000) and (Address < $8800) then
      Exit(FZRAM[Address and $7FF]);

    if Address = $9800 then
      Exit(FSound.OKIStatus);

    if Address = $A000 then
      Exit(FCommand);

    Exit($FF);
  end;

  if FBootSound = nil then
  begin
    if FMachine = 'kodb' then
      case Address of
        $E000:
          Exit(inherited ReadZ($F001));
        $E001:
          Exit(inherited ReadZ($F001));
        $E400:
          Exit(inherited ReadZ($F002));
        $E800:
          Exit(FCommand);
      end;
    Exit(inherited ReadZ(Address));
  end;

  if Address < $8000 then
    Exit(FAudio[Address]);

  if Address < $C000 then
  begin
    var Index := $10000 + (FBank and 7) * $4000 + (Address and $3FFF);
    if Index < Length(FAudio) then
      Exit(FAudio[Index]);

    Exit($FF);
  end;

  if (Address >= $D000) and (Address < $D800) then
    Exit(FZRAM[Address and $7FF]);

  if Address = $E400 then
    Exit(FCommand);

  if (Address = $D800) or (Address = $D801) then
    Exit(FBootSound.ReadFM(0, Address and 1));

  if (Address = $DC00) or (Address = $DC01) then
    Exit(FBootSound.ReadFM(1, Address and 1));

  Result := $FF;
end;

procedure TCPSFcrashConsole.WriteZ(Address: Word; Value: Byte);
begin
  if FMachine = 'ffightblb' then
  begin
    if (Address >= $8000) and (Address < $8800) then
      FZRAM[Address and $7FF] := Value;
    if Address = $9000 then
      FSound.SetSampleBank($20000, $20000, $20000 + (Value and 3) * $20000);
    if Address = $9800 then
      FSound.WriteOKI(Value);
    Exit;
  end;

  if FBootSound = nil then
  begin
    if FMachine = 'kodb' then
      case Address of
        $E000, $E001:
          begin
            inherited WriteZ($F000 + (Address and 1), Value);
            Exit;
          end;
        $E400:
          begin
            inherited WriteZ($F002, Value);
            Exit;
          end;
      end;

    inherited;
    Exit;
  end;

  if (Address >= $D000) and (Address < $D800) then
    FZRAM[Address and $7FF] := Value;
  case Address of
    $D800, $D801:
      FBootSound.WriteFM(0, Address and 1, Value);
    $DC00, $DC01:
      FBootSound.WriteFM(1, Address and 1, Value);
    $E000:
      begin
        FBank := Value;
        FBootSound.Bank(Value);
      end;
    $E800:
      FBootSound.WriteADPCM(0, Value);
    $EC00:
      FBootSound.WriteADPCM(1, Value);
  end;
end;

function TCPSFcrashConsole.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  if FMachine = 'wofr1bl' then
  begin
    if Address = $F1C006 then
      Exit(Ord(FSerial.Output));

    if Address = $F1C000 then
      Exit(ExtraPad(FInput.Buttons3));
  end;

  if (FMachine = 'sgyxz') or (FMachine = 'wofabl') then
  begin
    var SystemAddress: Cardinal := $880006;
    var DIPBase: Cardinal := $880008;
    if FMachine = 'wofabl' then
    begin
      SystemAddress := $880008;
      DIPBase := $88000A;
    end;
    if Address = SystemAddress then
      Exit((inherited ReadWord($800018) and $FF00) or (Pad(FInput.Buttons3) and $7F) or (ExtraPad(FInput.Buttons3) and $80));

    if (Address >= DIPBase) and (Address < DIPBase + 6) then
      Exit(inherited ReadWord($80001A + Address - DIPBase));

    if Address = $F1C006 then
      Exit($FFFF);
  end;

  var Index := SpriteIndex(Address);
  if Index >= 0 then
    Exit(FSpriteRAM[Index]);

  if (FMachine = 'sf2m1') and (Address = $800012) then
    Exit(inherited ReadWord($800176));

  if (Address = $880000) or (FCawing and (Address = $882000)) then
    Exit(inherited ReadWord($800000));

  if (Address >= $880008) and (Address < $880010) then
    Exit(inherited ReadWord(Address - $7FFF0));

  if FCawing and (Address >= $882008) and (Address < $882010) then
    Exit(inherited ReadWord(Address - $81FF0));

  Result := inherited;
end;

procedure TCPSFcrashConsole.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  Address := Address and $FFFFFE;
  if FMachine = 'wofr1bl' then
  begin
    if Address = $F1C006 then
    begin
      if LowByte then
        FSerial.Lines(Value and $80 <> 0, Value and $40 <> 0, Value and 1 <> 0);
      Exit;
    end;

    if Address = $990000 then
    begin
      if Value <> 0 then
        FSpriteBase := $3000
      else
        FSpriteBase := $1000;
      Video.SetBootlegSpriteBase(FSpriteBase);
      Exit;
    end;

    if Address = $800008 then
    begin
      Video.A[3] := Value;
      Exit;
    end;

    if Address = $800006 then
    begin
      inherited WriteWord($800180, Value, HighByte, LowByte);
      Exit;
    end;
  end;

  if ((FMachine = 'sgyxz') and (Address = $88000E)) or ((FMachine = 'wofabl') and (Address = $880006)) then
  begin
    inherited WriteWord($800180, Value, HighByte, LowByte);
    Exit;
  end;

  if ((FMachine = 'sgyxz') or (FMachine = 'wofabl')) and (Address = $890000) then
  begin
    inherited WriteWord($800188, Value, HighByte, LowByte);
    Exit;
  end;

  var Index := SpriteIndex(Address);
  if Index >= 0 then
  begin
    if HighByte then
      FSpriteRAM[Index] := (FSpriteRAM[Index] and $FF) or (Value and $FF00);
    if LowByte then
      FSpriteRAM[Index] := (FSpriteRAM[Index] and $FF00) or (Value and $FF);
    Exit;
  end;

  if (Length(FSpriteRAM) > 0) and (Address >= $980000) and (Address < $980200) then
  begin
    Layers((Address - $980000) div 2, Value);
    Exit;
  end;

  if (FMachine = 'varthb') and (Address = $800008) then
  begin
    if Value > $9000 then
      Video.A[3] := Value;
    Exit;
  end;

  if ((FMachine = 'mtwinsb') or (FMachine = 'sf2m1') or (FMachine = 'varthb')) and (Address = $800006) then
  begin
    inherited WriteWord($800180, Value, HighByte, LowByte);
    Exit;
  end;

  if (Address = $880006) or (FCawing and (Address = $882006)) then
  begin
    if FCawing then
    begin
      if HighByte then
      begin
        FCommand := Byte(Value shr 8);
        Z80Interrupt(FZ80, 1);
      end;
    end
    else if LowByte then
    begin
      FCommand := Byte(Value and $FF);
      Z80Interrupt(FZ80, 1);
    end;
    Exit;
  end;

  inherited;
end;

procedure TCPSFcrashConsole.SerializeState(State: TStateArchive);
begin
  inherited;
  if FBootSound <> nil then
    FBootSound.SerializeState(State);
  State.Field(FSpriteBase, SizeOf(FSpriteBase));
  if FSerial <> nil then
    FSerial.SerializeState(State);
  if Length(FSpriteRAM) > 0 then
    State.Field(FSpriteRAM[0], Length(FSpriteRAM) * SizeOf(Word));
end;

function TCPSFcrashConsole.SpriteIndex(Address: Cardinal): Integer;
begin
  Result := -1;
  if Length(FSpriteRAM) = 0 then
    Exit;

  if FMachine = 'kodb' then
  begin
    if (Address >= $900000) and (Address < $908000) then
      Result := (Address and $3FFF) div 2;
  end
  else if (Address >= $990000) and (Address < $994000) then
    Result := (Address - $990000) div 2;
end;

procedure TCPSFcrashConsole.Layers(Offset: Integer; Value: Word);
const
  Scroll: array[0..5] of Integer = (7, 6, 9, 8, 11, 10);
  Order: array[0..5] of Word = ($078E, $12C0, $06CE, $09CE, $12CE, $0B4E);
begin
  if FMachine = 'wofr1bl' then
  begin
    if Offset <= 5 then
    begin
      Video.A[Scroll[Offset]] := Value;
      if Offset = 2 then
        Video.A[16] := Value;
      Exit;
    end;

    if Offset = 6 then
    begin
      Video.B[$3E div 2] := Value;
      case Value of
        0:
          begin
            Video.B[$26 div 2] := $12CE;
            Video.B[$2A div 2] := $1F;
            Video.B[$2C div 2] := $1FF;
            Video.B[$2E div 2] := $7FFF;
          end;
        1:
          begin
            Video.B[$26 div 2] := $138E;
            Video.B[$2A div 2] := $3F;
            Video.B[$2C div 2] := $1FF;
            Video.B[$2E div 2] := $7FFF;
          end;
        2:
          begin
            Video.B[$26 div 2] := $12CE;
            Video.B[$2C div 2] := $780;
            Video.B[$2E div 2] := 0;
          end;
        3:
          begin
            Video.B[$26 div 2] := $1C8E;
            Video.B[$2A div 2] := $1F;
            Video.B[$2C div 2] := $780;
            Video.B[$2E div 2] := 0;
          end;
        4:
          begin
            Video.B[$26 div 2] := $12CE;
            Video.B[$2C div 2] := 0;
            Video.B[$2E div 2] := $7FFF;
          end;
        6:
          begin
            Video.B[$26 div 2] := $12CE;
            Video.B[$2C div 2] := $781;
            Video.B[$2E div 2] := $1F;
          end;
        8:
          begin
            Video.B[$26 div 2] := $12CE;
            Video.B[$2C div 2] := 0;
            Video.B[$2E div 2] := $1F;
          end;
        10:
          begin
            Video.B[$26 div 2] := $12CE;
            Video.B[$2C div 2] := $40FF;
            Video.B[$2E div 2] := $7FFF;
          end;
        14:
          Video.B[$26 div 2] := $12CE;
        15:
          begin
            Video.B[$26 div 2] := $138E;
            Video.B[$2A div 2] := $7FFF;
            Video.B[$2C div 2] := $7FFF;
            Video.B[$2E div 2] := $7FFF;
          end;
      end;
    end;
    Exit;
  end;

  if FMachine = 'kodb' then
  begin
    case Offset of
      $06:
        Video.B[$20 div 2] := Value;
      $10:
        Video.B[$2C div 2] := Value;
      $11:
        Video.B[$2A div 2] := Value;
    end;
    Exit;
  end;

  if Offset <= 5 then
  begin
    // The Twins conversion has a fixed palette page and wired X offsets.
    if FMachine = 'mtwinsb' then
    begin
      Video.A[3] := $9100;
      case Offset of
        1:
          Value := (Integer(Value) - 62) and $FFFF;
        3:
          Value := (Integer(Value) - 60) and $FFFF;
        5:
          Value := (Integer(Value) - 64) and $FFFF;
      end;
    end;
    Video.A[Scroll[Offset]] := Value;
    if Offset = 2 then
      Video.A[$20 div 2] := Value;
    Exit;
  end;

  if FMachine = 'sf2m1' then
    case Offset of
      6:
        begin
          if Value <= High(Order) then
            Value := Order[Value];
          Video.B[$26 div 2] := Value;
        end;
      $B3:
        Video.B[$26 div 2] := Value;
      $0B, $1B:
        Video.A[3] := Value;
    end;
end;

function TCPSFcrashConsole.Battery: TBytes;
begin
  if FSerial <> nil then
    Result := FSerial.Battery
  else
    Result := inherited;
end;

procedure TCPSFcrashConsole.LoadBattery(const Data: TBytes);
begin
  if FSerial <> nil then
    FSerial.LoadBattery(Data)
  else
    inherited;
end;

end.

