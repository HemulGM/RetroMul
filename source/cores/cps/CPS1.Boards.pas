unit CPS1.Boards;

interface

uses
  System.SysUtils, CPS1.Console, CPS.Cartridge, CPS.EEPROM, CPS.Timekeeper,
  CPS.Medal, Core.Snapshots;

type
  TCPS1BoardConsole = class(TCPS1Console)
  private
    FSerial: TCPS93C46;
    FRTC: TCPSM48T35;
    FHopper: TCPSMedalHopper;
    FProtection: Word;
    FExtra: TBytes;
    FDial: array[0..1] of Word;
    FInit, FMachine: string;
    FReload: array[0..2] of Word;
    FCounter: array[0..1] of Word;
    FScanline: Integer;
    function HackDSW(Address: Cardinal): Word;
  protected
    procedure BeginAudio; override;
    procedure BeginScanline(Line: Integer); override;
    procedure TriggerRaster; override;
    procedure FinishFrame; override;
  public
    property Hopper: TCPSMedalHopper read FHopper;
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
  Core.Emulation.Types, CPS.Video, HW.M68k;

constructor TCPS1BoardConsole.Create(Cart: TCPSCartridge);
begin
  inherited;
  FInit := Cart.RomSet.Init;
  FMachine := Cart.RomSet.Machine;

  // Operator NVRAM dumps can contain pending payouts and stale cabinet state.
  // A new cabinet starts with fresh SRAM; its own battery is loaded by the worker.
  if FInit = 'init_ganbare' then
  begin
    FRTC := TCPSM48T35.Create(nil);
    FHopper := TCPSMedalHopper.Create;
  end;

  if (FInit = 'init_pang3') or (FInit = 'init_pang3b') then
    FSerial := TCPS93C46.Create(16);

  if FInit = 'init_pang3' then
  begin
    FProgram := Copy(FProgram);
    for var A := $80000 div 2 to $100000 div 2 - 1 do
    begin
      var V := FProgram[A * 2 + 1];
      var D := 0;
      if V and 1 <> 0 then
        D := D xor $04;
      if V and 2 <> 0 then
        D := D xor $21;
      if V and 4 <> 0 then
        D := D xor $01;
      if V and 8 = 0 then
        D := D xor $50;
      if V and $10 <> 0 then
        D := D xor $40;
      if V and $20 <> 0 then
        D := D xor $06;
      if V and $40 <> 0 then
        D := D xor $08;
      if V and $80 = 0 then
        D := D xor $88;
      FProgram[A * 2 + 1] := Byte(D);
    end;
  end;

  if FMachine = 'sf2m10' then
    SetLength(FExtra, $100100);
  Reset;
end;

destructor TCPS1BoardConsole.Destroy;
begin
  FSerial.Free;
  FRTC.Free;
  FHopper.Free;
  inherited;
end;

procedure TCPS1BoardConsole.Reset;
begin
  inherited;
  if FSerial <> nil then
    FSerial.Reset;
  if FHopper <> nil then
    FHopper.Reset;
  FProtection := 0;
  FillChar(FDial, SizeOf(FDial), 0);
  FReload[0] := $1FF;
  FReload[1] := $1FF;
  FReload[2] := 0;
  FillChar(FCounter, SizeOf(FCounter), 0);
  FScanline := 0;
  if Length(FExtra) > 0 then
    FillChar(FExtra[0], Length(FExtra), 0);
end;

procedure TCPS1BoardConsole.BeginAudio;
begin
  inherited;
  if FRTC <> nil then
  begin
    Video.BeginRaster;
    FRTC.Advance(512 * 262, 8000000);
  end;

  if FMachine = 'forgottn' then
    for var P := 0 to 1 do
    begin
      var Buttons := FInput.Buttons;
      if P = 1 then
        Buttons := FInput.Buttons2;
      if FInput.Analog[P].Valid then
        FDial[P] := (Integer(FDial[P]) + FInput.Analog[P].X div 1024 + $1000) and $FFF;
      if TEmulatorButton.X in Buttons then
        FDial[P] := (FDial[P] + $FF8) and $FFF;
      if TEmulatorButton.Y in Buttons then
        FDial[P] := (FDial[P] + 8) and $FFF;
    end;
  Video.FrameNumber := FFrameNumber;
end;

procedure TCPS1BoardConsole.BeginScanline(Line: Integer);
begin
  inherited;
  if FRTC = nil then
    Exit;

  FHopper.Advance(512);
  FScanline := Line;
  var Pending := False;
  for var i := 0 to 1 do
  begin
    if Line = 0 then
      FCounter[i] := FReload[i]
    else
      FCounter[i] := (FCounter[i] + 511) and $1FF;
    if FCounter[i] = 0 then
      Pending := True;
  end;
  if Pending then
    FNextIRQ := ((FFrameNumber * 262 + Line) * Int64(FClock) * 512) div 8000000 +
      Int64(FReload[2]) * 2 * FClock div 8000000;
end;

procedure TCPS1BoardConsole.TriggerRaster;
begin
  inherited;
  if FRTC = nil then
    Exit;

  Video.RenderTo(FScanline - 16);
  Clown68000Interrupt(FCPU, FCPU.PendingInterrupt or 4);
end;

procedure TCPS1BoardConsole.FinishFrame;
begin
  if FRTC = nil then
  begin
    inherited;
    Exit;
  end;

  FSound.EndFrame;
  Video.RenderTo(CPS_HEIGHT - 1);
  Video.LatchObjects;
end;

function TCPS1BoardConsole.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  if FRTC <> nil then
  begin
    if (Address >= $800000) and (Address <= $800006) then
    begin
      Result := $FFFF;
      if FCart.RomSet.Inputs = 'pmonster' then
      begin
        if TEmulatorButton.Start in FInput.Buttons then
          Result := Result and $FFEF;
        if TEmulatorButton.A in FInput.Buttons then
          Result := Result and $FF7F;
      end
      else
      begin
        Result := $FFCC or (Pad(FInput.Buttons) and $33);
        if TEmulatorButton.Start in FInput.Buttons then
          Result := Result and $FFEF;
      end;
      Exit;
    end;

    if Address = $800018 then
    begin
      var V: Byte := $FF;
      var Coin1 := 1;
      var Coin2 := 2;
      if FCart.RomSet.Inputs = 'pmonster' then
      begin
        Coin1 := 2;
        Coin2 := 1;
      end;
      if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
        V := V and Byte($FF xor Coin1);
      if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
        V := V and Byte($FF xor Coin2);
      if TEmulatorButton.Mode in FInput.Buttons then
        V := V and $BF;

      // The payout routines test IN0.7 (BTST #7,$800018), independently of
      // coin inputs. IN0.4 is the cabinet hopper switch, not a game Start.
      if FHopper.Sensor then
        V := V and $7F;
      if TEmulatorButton.X in FInput.Buttons then
        V := V and $EF;
      Exit((Word(V) shl 8) or $FF);
    end;

    if Address >= $FF0000 then
      Exit((inherited ReadWord(Address) and $FF00) or FRTC.Read((Address - $FF0000) div 2));

    if (Address = $800150) or (Address = $800152) then
      Exit(FCounter[(Address shr 1) and 1]);

    if Address = $80014E then
      Exit(Word(((Int64(FReload[2]) - (FTime - ((FFrameNumber * 262 + FScanline) * Int64(FClock) * 512) div 8000000) * 8000000 div FClock div 2) * 2) and $1FE));
  end;

  if (FSerial <> nil) and (Address = $80017A) then
    Exit(Ord(FSerial.Output));

  if (FInit = 'init_pang3b4') and (Address = $80017A) then
    Exit($FFFF);

  if Address = $57A2B0 then
  begin
    if FInit = 'init_sf2ceblp' then
    begin
      if FProtection = 0 then
        Exit($1992);

      if FProtection = 4 then
        Exit($0408);

      Exit($FFFF);
    end;

    if FInit = 'init_pang3b4' then
    begin
      if FProtection and $FF <= 7 then
        Exit((FProtection and $FF) + $20);

      if FProtection = $17 then
        Exit($7321);

      Exit($FFFF);
    end;
  end;

  if (FInit = 'init_sf2rb') or (FInit = 'init_sf2rb2') then
    if (Address >= $200000) and (Address < $300000) then
    begin
      if Address = $281200 then
        Exit($0040);

      if (Address = $201200) and (FInit = 'init_sf2rb') then
        Exit(2);

      Exit(0);
    end;

  if (FInit = 'init_sf2dongb') and (Address >= $180000) and (Address < $200000) then
  begin
    if (Address = $180000) or (Address = $1F7040) then
      Exit($0210);

    Exit(0);
  end;

  if (FInit = 'init_sf2ee') or (FInit = 'init_sf2thndr') then
    if (Address >= $8001C0) and (Address < $800200) then
      Exit(Video.ReadB(Address - $8001C0));

  if (FInit = 'init_dinohunt') and (Address >= $F18000) and (Address < $F1A000) then
    Exit($FF);

  if FMachine = 'forgottn' then
    case Address of
      $800052:
        Exit($FF00 or (FDial[0] and $FF));
      $800054:
        Exit($FF00 or (FDial[0] shr 8));
      $80005A:
        Exit($FF00 or (FDial[1] and $FF));
      $80005C:
        Exit($FF00 or (FDial[1] shr 8));
    end;

  if (FMachine = 'sf2m3') or (FMachine = 'sf2cems6') then
  begin
    if Address = $800010 then
      Exit(inherited ReadWord($800000));

    if Address = $800186 then
      Exit(inherited ReadWord($800176));

    if (Address >= $800028) and (Address < $800030) then
      Exit(HackDSW(Address - $10));
  end;

  if FMachine = 'varthb3' then
  begin
    if (Address >= $880000) and (Address < $880008) then
      Exit(inherited ReadWord($800000));

    if (Address >= $880008) and (Address < $880010) then
      Exit(HackDSW(Address - $7FFF0));
  end;

  if (FInit = 'init_sf2hack') or (FInit = 'init_sf2rk') or
    (FMachine = 'sf2m10') or (FMachine = 'varthb2') or (FInit = 'init_pang3b4') then
    if (Address >= $800018) and (Address < $800020) then
      Exit(HackDSW(Address));

  if (FMachine = 'sf2m10') and (Length(FExtra) > 0) then
  begin
    if (Address >= $E00000) and (Address < $F00000) then
      Exit((Word(FExtra[Address - $E00000]) shl 8) or FExtra[Address - $E00000 + 1]);

    if (Address >= $FEFF00) and (Address < $FF0000) then
      Exit((Word(FExtra[$100000 + Address - $FEFF00]) shl 8) or FExtra[$100001 + Address - $FEFF00]);

    if Address = $F1C000 then
      Exit(inherited ReadWord($800176));
  end;

  Result := inherited ReadWord(Address);
end;

procedure TCPS1BoardConsole.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  Address := Address and $FFFFFE;
  if FRTC <> nil then
  begin
    if (Address = $800030) and HighByte then
      FHopper.Motor := Value and $0800 <> 0;
    if (Address >= $80014E) and (Address <= $800152) then
    begin
      var Index := (Integer(Address) - $800150) div 2;
      if Address = $80014E then
        Index := 2;
      var V := Video.B[(Address - $800140) div 2];
      if HighByte then
        V := (V and $FF) or (Value and $FF00);
      if LowByte then
        V := (V and $FF00) or (Value and $FF);
      Video.B[(Address - $800140) div 2] := V;
      if Index = 2 then
        FReload[Index] := (V shr 1) and $FF
      else
      begin
        FReload[Index] := V and $1FF;
        if V and $8000 <> 0 then
          FCounter[Index] := FReload[Index];
      end;
      Exit;
    end;

    if (Address >= $FF0000) and LowByte then
      FRTC.Write((Address - $FF0000) div 2, Byte(Value and $FF));
  end;

  if (Address = $5762B0) and ((FInit = 'init_sf2ceblp') or (FInit = 'init_pang3b4')) then
  begin
    if HighByte then
      FProtection := (FProtection and $FF) or (Value and $FF00);
    if LowByte then
      FProtection := (FProtection and $FF00) or (Value and $FF);
    Exit;
  end;

  if (FSerial <> nil) and (Address = $80017A) then
  begin
    if LowByte then
      FSerial.Lines(Value and $80 <> 0, Value and $40 <> 0, Value and 1 <> 0);
    Exit;
  end;

  if (FInit = 'init_sf2ee') or (FInit = 'init_sf2thndr') then
    if (Address >= $8001C0) and (Address < $800200) then
    begin
      inherited WriteWord(Address - $80, Value, HighByte, LowByte);
      Exit;
    end;

  if FMachine = 'forgottn' then
    if LowByte then
      case Address of
        $800040:
          FDial[0] := 0;
        $800048:
          FDial[1] := 0;
      end;

  if (FMachine = 'sf2m3') or (FMachine = 'sf2cems6') then
  begin
    if (Address >= $800190) and (Address < $8001A0) then
    begin
      inherited WriteWord(Address - $10, Value, HighByte, LowByte);
      Exit;
    end;

    if (Address >= $8001A0) and (Address < $8001C4) then
    begin
      inherited WriteWord(Address - $A0, Value, HighByte, LowByte);
      Exit;
    end;

    if Address = $8001C4 then
    begin
      inherited WriteWord($80014A, Value, HighByte, LowByte);
      Exit;
    end;
  end;

  if FMachine = 'sf2m10' then
  begin
    if (Address >= $8001A2) and (Address < $8001B4) then
    begin
      inherited WriteWord(Address - $A2, Value, HighByte, LowByte);
      Exit;
    end;

    var Index := -1;
    if (Address >= $E00000) and (Address < $F00000) then
      Index := Address - $E00000;
    if (Address >= $FEFF00) and (Address < $FF0000) then
      Index := $100000 + Address - $FEFF00;
    if Index >= 0 then
    begin
      if HighByte then
        FExtra[Index] := Byte(Value shr 8);
      if LowByte then
        FExtra[Index + 1] := Byte(Value and $FF);
      Exit;
    end;
  end;

  if (FMachine = 'varthb2') and (Address >= $800100) and (Address < $800140) then
    case Address of
      $800100:
        Value := $9100;
      $800102:
        Value := $90C0;
      $800104:
        Value := $9040;
      $800106:
        Value := $9080;
      $80010A:
        Value := $9000;
    end;

  inherited;
end;

function TCPS1BoardConsole.HackDSW(Address: Cardinal): Word;
begin
  Result := inherited ReadWord(Address) shr 8;
  Result := Result or (Result shl 8);
end;

procedure TCPS1BoardConsole.SerializeState(State: TStateArchive);
begin
  inherited;
  if FSerial <> nil then
    FSerial.SerializeState(State);
  if FRTC <> nil then
    FRTC.SerializeState(State);
  if FHopper <> nil then
    FHopper.SerializeState(State);
  State.Field(FReload, SizeOf(FReload));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FScanline, SizeOf(FScanline));
  State.Field(FProtection, SizeOf(FProtection));
  State.Field(FDial, SizeOf(FDial));
  if Length(FExtra) > 0 then
    State.Field(FExtra[0], Length(FExtra));
end;

function TCPS1BoardConsole.Battery: TBytes;
begin
  if FRTC <> nil then
    Result := FRTC.Battery
  else if FSerial <> nil then
    Result := FSerial.Battery
  else
    Result := inherited;
end;

procedure TCPS1BoardConsole.LoadBattery(const Data: TBytes);
begin
  if FRTC <> nil then
    FRTC.LoadBattery(Data)
  else if FSerial <> nil then
    FSerial.LoadBattery(Data)
  else
    inherited;
end;

end.

