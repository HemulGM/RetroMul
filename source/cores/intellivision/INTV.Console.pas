unit INTV.Console;

interface

uses
  System.SysUtils, HW.CPU.CP1610, HW.Sound.YM2149, INTV.Cartridge, INTV.STIC,
  Core.Emulation.Types, Core.Input.Keyboard, Core.Snapshots, Core.Storage,
  INTV.ECS, INTV.Voice, INTV.KeyboardComponent, INTV.PlayCable;

const
  IntvSampleRate = 44100;

type
  TIntvKeypads = array[0..3] of Word;

  TIntvConsole = class
  private
    FCPU: TCP1610;
    FSTIC: TIntvSTIC;
    FPSG: TYM2149F;
    FCartridge: TIntvCartridge;
    FECS: TIntvECS;
    FVoice: TIntvVoice;
    FPlayCable: TIntvPlayCable;
    FKeyboardComponent: TIntvKeyboardComponent;
    FExec: array[0..$FFF] of Word;
    FExecExtra: array[0..$FF] of Word;
    FHasExecExtra, FSTIC1A: Boolean;
    FWBExec: TArray<Word>;
    FGROM: array[0..$7FF] of Byte;
    FGRAM: array[0..$7FF] of Byte;
    FGRAMMask: Word;
    FScratch: array[0..$EF] of Byte;
    FSystemRAM: array[0..$2FF] of Word;
    FVolumeRegisters: array[0..2] of Byte;
    FController: array[0..3] of Byte;
    FClock, FFrameCycles, FScanline, FRegisterEnd, FInterruptEnd, FGraphicsEnd: Integer;
    FCycle, FSamplePhase, FSampleFrames: Integer;
    FFrameNumber: UInt64;
    FSamples: TArray<SmallInt>;
    FKeyboardMicrophone: TArray<SmallInt>;
    function ReadExpansionBus(Address: Word): Word;
    function ReadBus(Address: Word): Word;
    procedure WriteBus(Address, Value: Word);
    function ReadController(Port: Integer): Byte;
    procedure Advance(Cycles: Integer);
    procedure RunUntil(Target: Integer; var IRQ: Boolean);
    procedure FetchVideo(Target, Hold, Row: Integer; var IRQ: Boolean);
    function GetFramesPerSecond: Double;
    function FirstVideoRow: Integer;
    function GraphicsAccessible: Boolean;
  public
    constructor Create(const Cart, Exec, GROM: TBytes; const Mapping: string; PAL: Boolean; STIC1A: Boolean = False);
    destructor Destroy; override;
    procedure EnableECS(const ROM: TBytes; const Storage: IStorage = nil; const MediaFolder: string = '');
    procedure FlushECS;
    procedure EnableVoice(const ROM: TBytes);
    procedure EnableKeyboardComponent(const Firmware: TIntvKeyboardFirmware);
    procedure SetECSInput(const Keys: THostKeyboardKeys; InputMode: TIntvECSInput);
    procedure Reset;
    procedure SetKeyboardMicrophone(const Samples: TArray<SmallInt>);
    procedure SetInput(const Input: TEmulatorInput; const Keypads: TIntvKeypads);
    function NextFrameSampleCount: Integer;
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    property KeyboardComponent: TIntvKeyboardComponent read FKeyboardComponent;
    property PlayCable: TIntvPlayCable read FPlayCable;
    property Cartridge: TIntvCartridge read FCartridge;
    property STIC: TIntvSTIC read FSTIC;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
    property FrameNumber: UInt64 read FFrameNumber;
    property FramesPerSecond: Double read GetFramesPerSecond;
  end;

implementation

uses
  System.Classes, System.Math;

const
  PSGRegisters: array[0..15] of Byte = (0, 2, 4, 11, 1, 3, 5, 12, 7, 6, 13, 8, 9, 10, 14, 15);
  KeypadCodes: array[0..11] of Byte =
    ($48, $81, $41, $21, $82, $42, $22, $84, $44, $24, $88, $28);
  DiscCodes: array[0..15] of Byte =
    ($02, $06, $16, $14, $04, $0C, $1C, $18, $08, $09, $19, $11, $01, $03, $13, $12);
  MasterNTSC = 3579545;
  MasterPAL = 4000000;

constructor TIntvConsole.Create(const Cart, Exec, GROM: TBytes; const Mapping: string; PAL, STIC1A: Boolean);
begin
  inherited Create;
  FSTIC1A := STIC1A or (Length(Exec) = $4000);
  if (Length(Exec) <> $2000) and (Length(Exec) <> $2200) and (Length(Exec) <> $4000) then
    raise EReadError.Create('Intellivision EXEC must contain 8192, 8704 or 16384 bytes');
  if FSTIC1A and (Length(Exec) = $2200) then
    raise EReadError.Create('INTV88 requires an 8192-byte EXEC or a 16384-byte WBEXEC');
  FGRAMMask := $1FF;
  if FSTIC1A then
    FGRAMMask := $7FF;
  if Length(Exec) = $4000 then
  begin
    SetLength(FWBExec, $1000);
    for var Index := 0 to High(FWBExec) do
      FWBExec[Index] := (Exec[$2000 + Index * 2] shl 8) or Exec[$2001 + Index * 2];
  end;
  if Length(GROM) <> $800 then
    raise EReadError.Create('Intellivision GROM must contain 2048 bytes');
  for var Index := 0 to High(FExec) do
    FExec[Index] := (Exec[Index * 2] shl 8) or Exec[Index * 2 + 1];
  FHasExecExtra := Length(Exec) = $2200;
  if FHasExecExtra then
    for var Index := 0 to High(FExecExtra) do
      FExecExtra[Index] := (Exec[$2000 + Index * 2] shl 8) or Exec[$2001 + Index * 2];
  Move(GROM[0], FGROM, SizeOf(FGROM));

  FClock := MasterNTSC;
  FScanline := 57;
  FRegisterEnd := 2900;
  FInterruptEnd := 2907;
  FGraphicsEnd := 3796;
  FFrameCycles := 262 * FScanline;
  if PAL then
  begin
    FClock := MasterPAL;
    FScanline := 64;
    FRegisterEnd := 6393;
    FInterruptEnd := 6400;
    FGraphicsEnd := 7456;
    FFrameCycles := 312 * FScanline;
  end;

  SetLength(FSamples, (Ceil(IntvSampleRate / FramesPerSecond) + 1) * 2);
  if TIntvPlayCable.IsImage(Cart) then
  begin
    FPlayCable := TIntvPlayCable.CreateFromImage(Cart, FClock div 4);
    FCartridge := TIntvCartridge.CreateEmpty;
  end
  else
    FCartridge := TIntvCartridge.Create(Cart, Mapping);
  FSTIC := TIntvSTIC.Create(FSTIC1A);
  FPSG := TYM2149F.Create(FClock div 2, IntvSampleRate);
  FPSG.AYModel := True;
  FPSG.MaxZeroTonePeriod := FSTIC1A;
  FPSG.OnPortRead := ReadController;
  for var Channel := 0 to 2 do
    FPSG.SetPan(Channel, 0.5, 0.5);
  // Power-on SRAM is unspecified. Use reproducible nonzero contents so firmware
  // that consumes uninitialized RAM does not get an artificial all-zero seed.
  var PowerOnBits: Word := $ACE1;
  for var Index := 0 to High(FSystemRAM) do
  begin
    PowerOnBits := (PowerOnBits shr 1) xor (Word(0 - (PowerOnBits and 1)) and $B400);
    FSystemRAM[Index] := PowerOnBits;
  end;
  FCPU := TCP1610.Create(ReadBus, WriteBus);
  FCPU.ExtendedEnabled := FCartridge.HasExtendedCPU;
  if FCPU.ExtendedEnabled then
    FCPU.OnPreviousValue := FCartridge.TryPreviousValue;
  Reset;
end;

destructor TIntvConsole.Destroy;
begin
  FCPU.Free;
  FVoice.Free;
  FPlayCable.Free;
  FKeyboardComponent.Free;
  FECS.Free;
  FPSG.Free;
  FSTIC.Free;
  FCartridge.Free;
  inherited;
end;

procedure TIntvConsole.Reset;
begin
  FCPU.Reset;
  FSTIC.Reset;
  FPSG.Reset;
  FCartridge.Reset;
  if FPlayCable <> nil then
    FPlayCable.Reset;
  if FECS <> nil then
    FECS.Reset;
  if FVoice <> nil then
    FVoice.Reset;
  if FKeyboardComponent <> nil then
    FKeyboardComponent.Reset;
  FillChar(FGRAM, SizeOf(FGRAM), 0);
  FillChar(FScratch, SizeOf(FScratch), 0);
  FillChar(FVolumeRegisters, SizeOf(FVolumeRegisters), 0);
  for var Channel := 0 to 2 do
    FPSG.SetEnvelopeShift(Channel, 0);
  FillChar(FController, SizeOf(FController), $FF);
  FCycle := 0;
  FSamplePhase := 0;
  FSampleFrames := 0;
  FFrameNumber := 0;
end;

function TIntvConsole.GetFramesPerSecond: Double;
begin
  Result := FClock / (4.0 * FFrameCycles);
end;

function TIntvConsole.ReadController(Port: Integer): Byte;
begin
  Result := FController[1 - Port];
end;

procedure TIntvConsole.SetKeyboardMicrophone(const Samples: TArray<SmallInt>);
begin
  FKeyboardMicrophone := Samples;
end;

procedure TIntvConsole.SetInput(const Input: TEmulatorInput; const Keypads: TIntvKeypads);
begin
  for var Port := Low(FController) to High(FController) do
  begin
    var Buttons := Input.PortButtons(Port);
    var Mask: Byte := 0;
    if TEmulatorButton.A in Buttons then
      Mask := Mask or $A0;
    if TEmulatorButton.B in Buttons then
      Mask := Mask or $60;
    if TEmulatorButton.C in Buttons then
      Mask := Mask or $C0;
    var Keys := Keypads[Port];
    if TEmulatorButton.Start in Buttons then
      Keys := Keys or (1 shl 11);
    if TEmulatorButton.Select in Buttons then
      Keys := Keys or (1 shl 10);
    if TEmulatorButton.X in Buttons then
      Keys := Keys or (1 shl 1);
    if TEmulatorButton.Y in Buttons then
      Keys := Keys or (1 shl 2);
    for var Key := 0 to 11 do
      if Keys and (1 shl Key) <> 0 then
        Mask := Mask or KeypadCodes[Key];

    var X := Ord(TEmulatorButton.Right in Buttons) - Ord(TEmulatorButton.Left in Buttons);
    var Y := Ord(TEmulatorButton.Up in Buttons) - Ord(TEmulatorButton.Down in Buttons);
    var AnalogX := Integer(Input.Analog[Port].X);
    var AnalogY := -Integer(Input.Analog[Port].Y);
    var Threshold := 8192;
    if not Input.Analog[Port].Valid then
    begin
      var Motion := Input.AnalogButtons[Port];
      const Directions: TEmulatorButtons = [TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right];
      if Motion.Axes * Directions <> [] then
      begin
        AnalogX := Integer(Motion.Values[TEmulatorButton.Right]) - Motion.Values[TEmulatorButton.Left];
        AnalogY := Integer(Motion.Values[TEmulatorButton.Up]) - Motion.Values[TEmulatorButton.Down];
        Threshold := 64;
      end;
    end;
    if AnalogX * Int64(AnalogX) + AnalogY * Int64(AnalogY) >= Threshold * Threshold then
    begin
      X := AnalogX;
      Y := AnalogY;
    end;
    if (X <> 0) or (Y <> 0) then
      Mask := Mask or DiscCodes[Round(ArcTan2(Y, X) * (8 / Pi)) and 15];
    FController[Port] := not Mask;
  end;
end;

procedure TIntvConsole.EnableECS(const ROM: TBytes; const Storage: IStorage; const MediaFolder: string);
begin
  if FCartridge.Kiosk <> nil then
    raise EReadError.Create('The kiosk ROM occupies the ECS ROM window');
  if FECS <> nil then
    raise EInvalidOpException.Create('Intellivision ECS is already connected');
  if FWBExec <> nil then
    raise EReadError.Create('TutorVision WBEXEC occupies the ECS ROM window at $2000-$2FFF');
  FECS := TIntvECS.Create(ROM, FClock div 2, IntvSampleRate, Storage, MediaFolder);
end;

procedure TIntvConsole.EnableVoice(const ROM: TBytes);
begin
  if FVoice <> nil then
    raise EInvalidOpException.Create('Intellivoice is already connected');
  FVoice := TIntvVoice.Create(ROM, FClock);
end;

procedure TIntvConsole.EnableKeyboardComponent(const Firmware: TIntvKeyboardFirmware);
begin
  if FCartridge.Kiosk <> nil then
    raise EReadError.Create('The kiosk ROM occupies the Keyboard Component ROM window');
  if FKeyboardComponent <> nil then
    raise EInvalidOpException.Create('Intellivision Keyboard Component is already connected');
  FKeyboardComponent := TIntvKeyboardComponent.Create(Firmware.MasterROM,
    Firmware.KeyboardROM, Firmware.CharacterROM, Firmware.CartridgeROM, FClock div 4);
end;

procedure TIntvConsole.FlushECS;
begin
  if FECS <> nil then
    FECS.FlushSerial;
end;

procedure TIntvConsole.SetECSInput(const Keys: THostKeyboardKeys; InputMode: TIntvECSInput);
begin
  if FECS <> nil then
    FECS.SetInput(Keys, FController[2], FController[3], InputMode);
end;

function TIntvConsole.ReadExpansionBus(Address: Word): Word;
begin
  if (FPlayCable <> nil) and (Address >= $4800) and (Address <= $6FFF) then
    Exit(FPlayCable.ReadWord(Address));
  if (FKeyboardComponent <> nil) and (Address >= $7000) and (Address <= $BFFF) then
    Exit(FKeyboardComponent.ReadMaster(Address));
  Result := FCartridge.ReadWord(Address);
  if FECS <> nil then
    Result := Result and FECS.ReadWord(Address);
end;

function IsExtendedPort(Address: Word): Boolean; inline;
begin
  Result := (Address = $9F8D) or ((Address >= $9F90) and (Address <= $9F9F));
end;

function TIntvConsole.ReadBus(Address: Word): Word;
begin
  if (FKeyboardComponent = nil) and IsExtendedPort(Address) and FCartridge.ExtendedPortsVisible then
    Exit(FCPU.ReadExtendedPort(Address));
  if (FVoice <> nil) and ((Address = $80) or (Address = $81)) then
    Exit(FVoice.ReadRegister(Address));
  if (Address and $3FC0 = 0) and ((Address < $40) or not FSTIC1A) then
  begin
    if not FSTIC.Active or (FCycle < FRegisterEnd) then
    begin
      var Value := FSTIC.ReadRegister(Address and $3F);
      if Address < $40 then
        Exit(Value);
    end;
    // The aliases forward the read strobe, but do not drive the CPU data bus.
    if Address >= $4000 then
      Exit(ReadExpansionBus(Address));
    Exit($FFFF);
  end;
  case Address of
    $0100..$01EF:
      Exit(FScratch[Address - $100]);
    $01F0..$01FF:
      begin
        if (Address >= $1FB) and (Address <= $1FD) then
          Exit(FVolumeRegisters[Address - $1FB]);
        if FSTIC1A and (Address >= $1FE) then
          Exit(ReadController(Address - $1FE));
        var Value := FPSG.ReadRegister(PSGRegisters[Address - $1F0]);
        if FSTIC1A and (Address = $1F8) then
          Value := Value and $3F;
        Exit(Value);
      end;
    $0200..$035F:
      Exit(FSystemRAM[Address - $200]);
    $0360..$03FF:
      if FHasExecExtra or FSTIC1A then
        Exit(FSystemRAM[Address - $200]);
    $0400..$04FF:
      if FSTIC1A then
        Exit(FSystemRAM[Address - $200])
      else if FHasExecExtra then
        Exit(FExecExtra[Address - $400]);
    $1000..$1FFF:
      Exit(FExec[Address - $1000]);
    $2000..$2FFF:
      if FWBExec <> nil then
        Exit(FWBExec[Address - $2000]);
    $3000..$3FFF:
      begin
        if not GraphicsAccessible then
          if FSTIC1A then
            Exit($FF)
          else
            Exit(Address and $3FFF);
        if Address < $3800 then
          Exit(FGROM[Address and $7FF]);
        Exit(FGRAM[Address and FGRAMMask]);
      end;
  end;
  Result := ReadExpansionBus(Address);
end;

procedure TIntvConsole.WriteBus(Address, Value: Word);
begin
  if (FPlayCable <> nil) and (Address >= $4800) and (Address <= $6FFF) then
  begin
    FPlayCable.WriteWord(Address, Value);
    Exit;
  end;
  if (FKeyboardComponent <> nil) and (Address >= $7000) and (Address <= $BFFF) then
  begin
    if not FSTIC1A and (Address and $3FC0 = 0) and (not FSTIC.Active or (FCycle < FRegisterEnd)) then
      FSTIC.WriteRegister(Address and $3F, Value);
    FKeyboardComponent.WriteMaster(Address, Value);
    Exit;
  end;
  if (FWBExec <> nil) and (Address >= $2000) and (Address < $3000) then
    Exit;
  if FCPU.ExtendedEnabled then
  begin
    if (FKeyboardComponent = nil) and IsExtendedPort(Address) and FCartridge.ExtendedPortsVisible then
    begin
      FCPU.WriteExtendedPort(Address, Value);
      Exit;
    end;
    var Previous: Word;
    if FCartridge.TryPreviousValue(Address, Previous) then
      FCPU.WriteExtendedPort($9F8D, Previous);
  end;
  if FCartridge.Locutus <> nil then
    FCartridge.WriteWord(Address, Value);
  if (FVoice <> nil) and ((Address = $80) or (Address = $81)) then
  begin
    FVoice.WriteRegister(Address, Value);
    Exit;
  end;
  if FECS <> nil then
    FECS.WriteWord(Address, Value);
  if (Address and $3FC0 = 0) and ((Address < $40) or not FSTIC1A) then
  begin
    if not FSTIC.Active or (FCycle < FRegisterEnd) then
      FSTIC.WriteRegister(Address and $3F, Value);
    if Address < $40 then
      Exit;
  end;
  if (Address and $3FFF >= $3800) and
    ((Address < $4000) or ((FECS = nil) and not FSTIC1A)) and GraphicsAccessible then
    FGRAM[Address and FGRAMMask] := Byte(Value);
  case Address of
    $0100..$01EF:
      FScratch[Address - $100] := Byte(Value);
    $01F0..$01FF:
      if (Address >= $1FB) and (Address <= $1FD) then
      begin
        var Channel := Address - $1FB;
        var Mode := (Value shr 4) and 3;
        FVolumeRegisters[Channel] := Value and $3F;
        if Mode <> 0 then
        begin
          FPSG.SetEnvelopeShift(Channel, 3 - Mode);
          FPSG.WriteRegister(8 + Channel, $10);
          if FSTIC1A and (Mode < 3) then
            FPSG.TriggerEnvelopePulse(Channel);
        end
        else
          FPSG.WriteRegister(8 + Channel, Value and 15);
      end
      else
        FPSG.WriteRegister(PSGRegisters[Address - $1F0], Byte(Value));
    $0200..$035F:
      FSystemRAM[Address - $200] := Value;
    $0360..$03FF:
      if FHasExecExtra or FSTIC1A then
        FSystemRAM[Address - $200] := Value
      else if FCartridge.Locutus = nil then
        FCartridge.WriteWord(Address, Value);
    $0400..$04FF:
      if FSTIC1A then
        FSystemRAM[Address - $200] := Value
      else if not FHasExecExtra and (FCartridge.Locutus = nil) then
        FCartridge.WriteWord(Address, Value);
    $1000..$1FFF, $3000..$3FFF:
      ;
  else
    if FCartridge.Locutus = nil then
      FCartridge.WriteWord(Address, Value);
  end;
end;

procedure TIntvConsole.Advance(Cycles: Integer);
begin
  Inc(FCycle, Cycles);
  if FCartridge.Kiosk <> nil then
    FCartridge.Kiosk.Advance(Cycles, FClock div 4);
  if FPlayCable <> nil then
    FPlayCable.Advance(Cycles);
  if FKeyboardComponent <> nil then
    FKeyboardComponent.Advance(Cycles);
  if FVoice <> nil then
    FVoice.Advance(Cycles);
  Inc(FSamplePhase, Cycles * IntvSampleRate * 4);
  while FSamplePhase >= FClock do
  begin
    Dec(FSamplePhase, FClock);
    var Left, Right: SmallInt;
    FPSG.Sample(Left, Right);
    var MixedLeft := Integer(Left);
    var MixedRight := Integer(Right);
    if FECS <> nil then
    begin
      FECS.Sample(Left, Right);
      Inc(MixedLeft, Left);
      Inc(MixedRight, Right);
    end;
    if FVoice <> nil then
    begin
      var Speech := FVoice.Sample;
      Inc(MixedLeft, Speech);
      Inc(MixedRight, Speech);
    end;
    if FKeyboardComponent <> nil then
    begin
      var Input: SmallInt := 0;
      if FSampleFrames < Length(FKeyboardMicrophone) then
        Input := FKeyboardMicrophone[FSampleFrames];
      var TapeAudio := FKeyboardComponent.Peripherals.AudioSample(Input);
      Inc(MixedLeft, TapeAudio);
      Inc(MixedRight, TapeAudio);
    end;
    FSamples[FSampleFrames * 2] := EnsureRange(MixedLeft, -32768, 32767);
    FSamples[FSampleFrames * 2 + 1] := EnsureRange(MixedRight, -32768, 32767);
    Inc(FSampleFrames);
  end;
end;

procedure TIntvConsole.RunUntil(Target: Integer; var IRQ: Boolean);
begin
  while FCycle < Target do
  begin
    var Acknowledged: Boolean;
    var Cycles := FCPU.Step(IRQ and (FCycle < FInterruptEnd), Acknowledged);
    if Acknowledged then
      IRQ := False;
    Advance(Cycles);
  end;
end;

procedure TIntvConsole.FetchVideo(Target, Hold, Row: Integer; var IRQ: Boolean);
begin
  RunUntil(Target, IRQ);
  // BUSRQ is acknowledged between interruptible instructions.
  while (FCycle < Target + Hold) and not FCPU.State.Interruptible and
    not FCPU.State.Halted do
    RunUntil(FCycle + 1, IRQ);
  if FCycle < Target + Hold then
    Advance(Target + Hold - FCycle);
  if Row >= 0 then
    FSTIC.FetchRow(Row, FSystemRAM);
end;

function TIntvConsole.NextFrameSampleCount: Integer;
begin
  Result := (Int64(FSamplePhase) + Int64(FFrameCycles) * IntvSampleRate * 4) div FClock;
end;

function TIntvConsole.FirstVideoRow: Integer;
begin
  Result := FGraphicsEnd + (5 * FScanline + 1) div 2 + 2 * FScanline * FSTIC.VerticalDelay;
  if FSTIC1A then
    Inc(Result, 6);
end;

function TIntvConsole.GraphicsAccessible: Boolean;
begin
  if FSTIC1A then
    // The measured copy window grows by two scanlines per vertical-delay step.
    Result := not FSTIC.Active or
      (FCycle < FGraphicsEnd + 24 + 2 * FScanline * FSTIC.VerticalDelay)
  else
    Result := not FSTIC.Active or (FCycle < FGraphicsEnd);
end;

procedure TIntvConsole.RunFrame;
begin
  if (FCartridge.Kiosk <> nil) and FCartridge.Kiosk.ResetPending then
    Reset;
  FSampleFrames := 0;
  FSTIC.BeginFrame;
  if FKeyboardComponent <> nil then
    FKeyboardComponent.VBlank;
  var IRQ := True;
  RunUntil(FRegisterEnd, IRQ);
  FSTIC.LatchDisplay;
  if FSTIC.Active then
  begin
    if not FSTIC1A then
      FetchVideo(FGraphicsEnd, FScanline, -1, IRQ);
    var FirstRow := FirstVideoRow;
    var RowHold := 110;
    if FScanline = 64 then
      RowHold := 118;
    if FSTIC1A then
      Dec(RowHold, 6);
    for var Row := 0 to 11 do
      FetchVideo(FirstRow + Row * 16 * FScanline, RowHold, Row, IRQ);
    if not FSTIC1A and (FSTIC.VerticalDelay = 0) then
      FetchVideo(FirstRow + 12 * 16 * FScanline, RowHold - 66 + Ord(FScanline = 64) * 8, -1, IRQ);
  end;
  RunUntil(FFrameCycles, IRQ);
  Dec(FCycle, FFrameCycles);
  FSTIC.Draw(FGROM, FGRAM);
  Inc(FFrameNumber);
end;

procedure TIntvConsole.SerializeState(State: TStateArchive);
begin
  var CPUState := FCPU.State;
  State.Field(CPUState, SizeOf(CPUState));
  State.Field(FCycle, SizeOf(FCycle));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FScratch, SizeOf(FScratch));
  State.Field(FSystemRAM, $200 * SizeOf(Word));
  State.Field(FGRAM, $200);
  if FSTIC1A then
  begin
    if (State.Version <> 0) and (State.Version < 7) then
      raise EReadError.Create('Snapshot lacks INTV88 memory');
    State.Field(FSystemRAM[$200], $100 * SizeOf(Word));
    State.Field(FGRAM[$200], $600);
    FPSG.SerializeEnvelopePulse(State.Field);
  end;
  State.Field(FVolumeRegisters, SizeOf(FVolumeRegisters));
  if FPlayCable <> nil then
  begin
    if (State.Version <> 0) and (State.Version < 6) then
      raise EReadError.Create('Snapshot lacks PlayCable state');
    FPlayCable.SerializeState(State);
  end
  else
    FCartridge.SerializeState(State);
  FSTIC.SerializeState(State);
  FPSG.SerializeState(State.Field);
  if FECS <> nil then
    FECS.SerializeState(State);
  if FVoice <> nil then
    FVoice.SerializeState(State);
  if FCPU.ExtendedEnabled then
  begin
    var Extended := Default(TCP1600XState);
    if (State.Version = 0) or (State.Version >= 3) then
    begin
      Extended := FCPU.ExtendedState;
      State.Field(Extended, SizeOf(Extended));
    end
    else if State.Loading and (State.Version = 2) and (FCartridge.JLP <> nil) then
    begin
      // Version 2 exposed X registers through the JLP address window.
      for var Index := 0 to High(Extended.Registers) do
        Extended.Registers[Index] := FCartridge.JLP.LoadLegacyRegister($9F90 + Index);
      Extended.PreviousValue := FCartridge.JLP.LoadLegacyRegister($9F8D);
    end;
    if State.Loading then
      FCPU.ExtendedState := Extended;
  end;
  if FKeyboardComponent <> nil then
  begin
    if (State.Version <> 0) and (State.Version < 4) then
      raise EReadError.Create('Snapshot lacks Keyboard Component state');
    FKeyboardComponent.SerializeState(State);
  end;
  if State.Loading then
  begin
    if (FCycle < 0) or (FCycle > 12) or (FSamplePhase < 0) or (FSamplePhase >= FClock) then
      raise EReadError.Create('Invalid Intellivision snapshot timing');
    FCPU.State := CPUState;
    for var Channel := 0 to 2 do
      FPSG.SetEnvelopeShift(Channel, (3 - (FVolumeRegisters[Channel] shr 4)) and 3);
  end;
end;

end.

