unit Jaguar.Jerry;

interface

uses
  System.SysUtils, Jaguar.Video, HW.EEPROM93Cxx, Core.Emulation.Types,
  Core.InputConfig, Core.Snapshots;

type
  TJaguarKeypads = array[0..7] of Word;

  TJaguarJerry = class
  private
    FMemory: array[0..$FFFF] of Byte;
    FInput: TEmulatorInput;
    FKeypads: TJaguarKeypads;
    FPorts: TCoreInputPorts;
    FRotaryPhase: array[0..7] of Byte;
    FRotaryClock: array[0..7] of Integer;
    FCDLeft, FCDRight: SmallInt;
    FEEPROM: TSerialEEPROM93Cxx;
    FDSPInterrupt, FCPUInterrupt: TJaguarIRQ;
    FTimer: array[0..1] of Int64;
    FSerialPhase: Integer;
    FAudioPhase: Double;
    FLeft, FRight: SmallInt;
    FEnable, FPending, FJoystick: Word;
    FSelected, FPAL, FEEPROMData, FIRQLevel: Boolean;
    FSamples: TArray<SmallInt>;
    FSampleCount: Integer;
    function WordAt(Address: Integer): Word;
    function JoyData: Word;
    function JoyButtons: Word;
    function Row(Port: Integer): Integer;
    function Socket(Port: Integer): Integer;
    function PadButtons(Port: Integer): TEmulatorButtons;
    function Player(Port: Integer): Integer;
    function PlayerButtons(Index: Integer): TEmulatorButtons;
    procedure RaiseIRQ(Line: Integer);
    procedure UpdateIRQ;
  public
    constructor Create(DSPIRQ, CPUIRQ: TJaguarIRQ; PAL: Boolean);
    destructor Destroy; override;
    procedure Reset;
    function Read(Offset: Cardinal; Size: Integer): Cardinal;
    procedure Write(Offset, Value: Cardinal; Size: Integer);
    procedure Clock(Cycles: Integer);
    procedure DSPInterruptCPU;
    procedure ExternalInterrupt;
    procedure BeginFrame;
    procedure EndFrame;
    procedure SetInput(const Input: TEmulatorInput);
    procedure ConfigurePorts(const Ports: TCoreInputPorts);
    procedure CDSerialInput(Left, Right: SmallInt);
    procedure SetKeypad(Port: Integer; Mask: Word);
    procedure SerializeState(State: TStateArchive);
    property Samples: TArray<SmallInt> read FSamples;
    property EEPROM: TSerialEEPROM93Cxx read FEEPROM;
  end;

implementation

uses
  System.Math, Jaguar.Firmware;

{$Q-}{$R-}

constructor TJaguarJerry.Create(DSPIRQ, CPUIRQ: TJaguarIRQ; PAL: Boolean);
begin
  inherited Create;
  FDSPInterrupt := DSPIRQ;
  FCPUInterrupt := CPUIRQ;
  FPAL := PAL;
  FPorts := TCoreInputPorts.Defaults;
  FEEPROM := TSerialEEPROM93Cxx.Create(128, 16);
  Reset;
end;

destructor TJaguarJerry.Destroy;
begin
  FEEPROM.Free;
  inherited;
end;

procedure TJaguarJerry.Reset;
begin
  FillChar(FMemory, SizeOf(FMemory), 0);
  FillChar(FTimer, SizeOf(FTimer), 0);
  FillChar(FRotaryPhase, SizeOf(FRotaryPhase), 0);
  FillChar(FRotaryClock, SizeOf(FRotaryClock), 0);
  FCDLeft := 0;
  FCDRight := 0;
  FSerialPhase := 0;
  FAudioPhase := 0;
  FLeft := 0;
  FRight := 0;
  FEnable := 0;
  FPending := 0;
  FJoystick := 0;
  FSelected := False;
  FEEPROMData := False;
  FIRQLevel := False;
  FSampleCount := 0;
  FSamples := nil;
  FEEPROM.Reset;
  FMemory[$A153] := 19;
  // The mask ROM contains eight 128-cell waves, sign-extended to longwords.
  var WaveROM := LoadJaguarWaveROM;
  Move(WaveROM[0], FMemory[$D000], Length(WaveROM));
end;

function TJaguarJerry.WordAt(Address: Integer): Word;
begin
  Result := (Word(FMemory[Address and $FFFF]) shl 8) or FMemory[(Address + 1) and $FFFF];
end;

procedure TJaguarJerry.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TJaguarJerry.SetKeypad(Port: Integer; Mask: Word);
begin
  if (Port >= 0) and (Port < 8) then
    FKeypads[Port] := Mask and $FFF;
end;

procedure TJaguarJerry.ConfigurePorts(const Ports: TCoreInputPorts);
begin
  FPorts := Ports;
end;

procedure TJaguarJerry.CDSerialInput(Left, Right: SmallInt);
begin
  FCDLeft := Left;
  FCDRight := Right;
  // Slave mode receives external I2S words; internal SCLK does not drive it.
  if WordAt($A156) and 1 = 0 then
    FDSPInterrupt(1);
end;

function TJaguarJerry.Socket(Port: Integer): Integer;
const
  Map: array[0..15] of Integer = (0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3);
begin
  Result := 0;
  if FPorts.Multitap[Port] then
  begin
    var Code := (FJoystick shr (Port * 4)) and 15;
    if Port = 1 then
      Code := ((Code and 1) shl 3) or ((Code and 2) shl 1) or ((Code and 4) shr 1) or ((Code and 8) shr 3);
    Result := Map[Code];
  end;
end;

function TJaguarJerry.Player(Port: Integer): Integer;
begin
  Result := Port;
  if FPorts.Multitap[Port] then
  begin
    var S := Socket(Port);
    if S > 0 then
      Result := 2 + Port * 3 + S - 1;
  end;
end;

function TJaguarJerry.PadButtons(Port: Integer): TEmulatorButtons;
begin
  Result := PlayerButtons(Player(Port));
end;

function TJaguarJerry.PlayerButtons(Index: Integer): TEmulatorButtons;
begin
  if FPorts.Devices[Index] = 'none' then
    Exit([]);
  case Index of
    0:
      Result := FInput.Buttons;
    1:
      Result := FInput.Buttons2;
    2:
      Result := FInput.Buttons3;
    3:
      Result := FInput.Buttons4;
    4:
      Result := FInput.Buttons5;
    5:
      Result := FInput.Buttons6;
    6:
      Result := FInput.Buttons7;
    7:
      Result := FInput.Buttons8;
  else
    Result := [];
  end;
end;

function TJaguarJerry.Row(Port: Integer): Integer;
begin
  Result := -1;
  if FJoystick and $8000 = 0 then
    Exit;
  var Select := FJoystick and 15;
  if Port = 1 then
  begin
    Select := (FJoystick shr 4) and 15;
    Select := ((Select and 1) shl 3) or ((Select and 2) shl 1) or ((Select and 4) shr 1) or ((Select and 8) shr 3);
  end;
  if FPorts.Multitap[Port] then
  begin
    case Select of
      0, 4, 9, 14:
        Result := 0;
      1, 5, 10, 13:
        Result := 1;
      2, 6, 11, 12:
        Result := 2;
      3, 7, 8, 15:
        Result := 3;
    end;
    Exit;
  end;
  case Select of
    14:
      Result := 0;
    13:
      Result := 1;
    11:
      Result := 2;
    7:
      Result := 3;
  end;
end;

function TJaguarJerry.JoyData: Word;
const
  Gray: array[0..3] of Byte = (0, 2, 3, 1);
  KeyMap: array[1..3, 0..3] of Integer = ((10, 7, 4, 1), (0, 8, 5, 2), (11, 9, 6, 3));
begin
  Result := $FFFF;
  for var Port := 0 to 1 do
  begin
    var Buttons := PadButtons(Port);
    var R := Row(Port);
    var Value := 15;
    if R = 0 then
    begin
      if TEmulatorButton.Up in Buttons then
        Value := Value and 14;
      if TEmulatorButton.Down in Buttons then
        Value := Value and 13;
      if TEmulatorButton.Left in Buttons then
        Value := Value and 11;
      if TEmulatorButton.Right in Buttons then
        Value := Value and 7;
    end
    else if R > 0 then
    begin
      var Index := Player(Port);
      var Keys := FKeypads[Index];
      // ProController adds switches wired in parallel with keypad contacts.
      if TEmulatorButton.X in Buttons then
        Keys := Keys or (1 shl 9);
      if TEmulatorButton.Y in Buttons then
        Keys := Keys or (1 shl 8);
      if TEmulatorButton.Z in Buttons then
        Keys := Keys or (1 shl 7);
      if FInput.Analog[Index].LeftTrigger >= 128 then
        Keys := Keys or (1 shl 4);
      if FInput.Analog[Index].RightTrigger >= 128 then
        Keys := Keys or (1 shl 6);
      for var Bit := 0 to 3 do
        if Keys and (1 shl KeyMap[R, Bit]) <> 0 then
          Value := Value and not (1 shl Bit);
    end;
    if (R = 0) and (FPorts.Devices[Player(Port)] = 'rotary') then
    begin
      Value := 3 or (Gray[FRotaryPhase[Player(Port)] and 3] shl 2);
    end;
    var Shift := 8 + Port * 4;
    Result := (Result and not (15 shl Shift)) or (Value shl Shift);
  end;
  Result := (Result and $FFFE) or Word(Ord(FEEPROM.Output));
end;

function TJaguarJerry.JoyButtons: Word;
begin
  Result := $FFFF;
  if FPAL then
    Result := Result and $FFEF;
  for var Port := 0 to 1 do
  begin
    var Buttons := PadButtons(Port);
    var R := Row(Port);
    var B := False;
    var Pause := False;
    case R of
      0:
        begin
          B := TEmulatorButton.A in Buttons;
          Pause := TEmulatorButton.Start in Buttons;
        end;
      1:
        B := TEmulatorButton.B in Buttons;
      2:
        B := TEmulatorButton.C in Buttons;
      3:
        B := (TEmulatorButton.Select in Buttons) or (TEmulatorButton.Mode in Buttons);
    end;
    if B then
      Result := Result and not (1 shl (Port * 2 + 1));
    if (R = 3) and (FPorts.Devices[Player(Port)] = 'rotary') then
      Pause := True;
    // Team Tap signature at socket 3, row 1 (C1 active low).
    if FPorts.Multitap[Port] and (Socket(Port) = 3) and (R = 1) then
      Pause := True;
    if Pause then
      Result := Result and not (1 shl (Port * 2));
  end;
end;

function TJaguarJerry.Read(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
  begin
    var A := (Offset + Cardinal(i)) and $FFFF;
    var V := FMemory[A];
    if (A >= $36) and (A <= $3D) then
    begin
      var Index := Integer(A - $36) div 4;
      var Pre := Integer(WordAt(Index * 4)) + 1;
      var Counter := Integer(WordAt(Index * 4)) - Integer(FTimer[Index] mod Pre);
      if (A - $36) and 2 <> 0 then
        Counter := Integer(WordAt(Index * 4 + 2)) - Integer(FTimer[Index] div Pre);
      if A and 1 = 0 then
        V := Byte(Counter shr 8)
      else
        V := Byte(Counter);
    end;
    case A of
      $20:
        V := 0;
      $21:
        V := FPending;
      $4000:
        V := JoyData shr 8;
      $4001:
        V := JoyData and 255;
      $4002:
        V := JoyButtons shr 8;
      $4003:
        V := JoyButtons and 255;
      $4801:
        begin
          FEEPROM.Lines(FSelected, False, FEEPROMData);
          FEEPROM.Lines(FSelected, True, FEEPROMData);
          V := 0;
        end;
      $5001:
        begin
          FSelected := True;
          FEEPROM.Lines(False, False, False);
          FEEPROM.Lines(True, False, False);
          V := 0;
        end;
      $A148, $A149, $A14C, $A14D:
        V := 0;
      $A14A:
        V := Byte(Word(FCDLeft) shr 8);
      $A14B:
        V := Byte(FCDLeft);
      $A14E:
        V := Byte(Word(FCDRight) shr 8);
      $A14F:
        V := Byte(FCDRight);
      $A150, $A151, $A152:
        V := 0;
      $A153:
        V := (FSerialPhase div 32) and 1;
    end;
    Result := (Result shl 8) or V;
  end;
end;

procedure TJaguarJerry.Write(Offset, Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size - 1 do
  begin
    var A := (Offset + Cardinal(i)) and $FFFF;
    if (A < $D000) or (A >= $E000) then
      FMemory[A] := Byte(Value shr ((Size - 1 - i) * 8));
  end;
  if (Offset < 8) then
    FTimer[Offset div 4] := 0;
  if (Offset <= $21) and (Offset + Cardinal(Size) > $20) then
  begin
    var V := WordAt($20);
    FEnable := V and $1F;
    FPending := FPending and not ((V shr 8) and $1F);
    UpdateIRQ;
  end;
  if (Offset <= $4001) and (Offset + Cardinal(Size) > $4000) then
    FJoystick := WordAt($4000);
  if (Offset <= $A14B) and (Offset + Cardinal(Size) > $A148) then
    FLeft := SmallInt(WordAt($A14A));
  if (Offset <= $A14F) and (Offset + Cardinal(Size) > $A14C) then
    FRight := SmallInt(WordAt($A14E));
  // The cartridge EEPROM's data clock is generated by bus writes to its latch.
  if Offset and $FFFE = $5000 then
  begin
    FSelected := True;
    FEEPROM.Lines(False, False, False);
    FEEPROM.Lines(True, False, False);
  end;
  if Offset and $FFFE = $4800 then
  begin
    FEEPROMData := Value and 1 <> 0;
    FEEPROM.Lines(FSelected, False, FEEPROMData);
    FEEPROM.Lines(FSelected, True, FEEPROMData);
  end;
end;

procedure TJaguarJerry.RaiseIRQ(Line: Integer);
begin
  if (Line < 0) or (Line > 4) then
    Exit;
  FPending := FPending or (1 shl Line);
  UpdateIRQ;
end;

procedure TJaguarJerry.UpdateIRQ;
begin
  var Active := FEnable and FPending <> 0;
  if Active <> FIRQLevel then
  begin
    FIRQLevel := Active;
    FCPUInterrupt(Ord(Active));
  end;
end;

procedure TJaguarJerry.ExternalInterrupt;
begin
  RaiseIRQ(0);
end;

procedure TJaguarJerry.DSPInterruptCPU;
begin
  RaiseIRQ(1);
end;

procedure TJaguarJerry.Clock(Cycles: Integer);
begin
  for var Port := 0 to 7 do
    if FPorts.Devices[Port] = 'rotary' then
    begin
      var Buttons := PlayerButtons(Port);
      var Velocity := 0;
      if TEmulatorButton.Left in Buttons then
        Dec(Velocity, 200);
      if TEmulatorButton.Right in Buttons then
        Inc(Velocity, 200);
      if FInput.Analog[Port].Valid then
        Inc(Velocity, FInput.Analog[Port].X div 128);
      Inc(FRotaryClock[Port], Cycles * Velocity);
      while FRotaryClock[Port] >= 26590906 do
      begin
        Dec(FRotaryClock[Port], 26590906);
        FRotaryPhase[Port] := (FRotaryPhase[Port] + 1) and 3;
      end;
      while FRotaryClock[Port] <= -26590906 do
      begin
        Inc(FRotaryClock[Port], 26590906);
        FRotaryPhase[Port] := (FRotaryPhase[Port] - 1) and 3;
      end;
    end;
  for var Timer := 0 to 1 do
  begin
    var Pre := WordAt(Timer * 4);
    var Divisor := WordAt(Timer * 4 + 2);
    if (Pre <> 0) or (Divisor <> 0) then
    begin
      var Period := (Int64(Pre) + 1) * (Int64(Divisor) + 1);
      Inc(FTimer[Timer], Cycles);
      while FTimer[Timer] >= Period do
      begin
        Dec(FTimer[Timer], Period);
        FDSPInterrupt(Timer + 2);
        RaiseIRQ(Timer + 2);
      end;
    end;
  end;
  var SerialPeriod := 64 * (Integer(WordAt($A152) and 255) + 1);
  if WordAt($A156) and 1 <> 0 then
  begin
    Inc(FSerialPhase, Cycles);
    while FSerialPhase >= SerialPeriod do
    begin
      Dec(FSerialPhase, SerialPeriod);
      FDSPInterrupt(1);
    end;
  end;
  FAudioPhase := FAudioPhase + Cycles * 44100 / 26590906.0;
  while FAudioPhase >= 1 do
  begin
    FAudioPhase := FAudioPhase - 1;
    if FSampleCount + 2 > Length(FSamples) then
      SetLength(FSamples, FSampleCount + 2048);
    FSamples[FSampleCount] := 0;
    FSamples[FSampleCount + 1] := 0;
    if FJoystick and $100 <> 0 then
    begin
      FSamples[FSampleCount] := FLeft;
      FSamples[FSampleCount + 1] := FRight;
    end;
    Inc(FSampleCount, 2);
  end;
end;

procedure TJaguarJerry.BeginFrame;
begin
  FSampleCount := 0;
end;

procedure TJaguarJerry.EndFrame;
begin
  SetLength(FSamples, FSampleCount);
end;

procedure TJaguarJerry.SerializeState(State: TStateArchive);
begin
  State.Field(FMemory, SizeOf(FMemory));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FSerialPhase, SizeOf(FSerialPhase));
  State.Field(FAudioPhase, SizeOf(FAudioPhase));
  State.Field(FLeft, SizeOf(FLeft));
  State.Field(FRight, SizeOf(FRight));
  State.Field(FEnable, SizeOf(FEnable));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FJoystick, SizeOf(FJoystick));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FEEPROMData, SizeOf(FEEPROMData));
  State.Field(FRotaryPhase, SizeOf(FRotaryPhase));
  State.Field(FRotaryClock, SizeOf(FRotaryClock));
  State.Field(FCDLeft, SizeOf(FCDLeft));
  State.Field(FCDRight, SizeOf(FCDRight));
  State.Field(FIRQLevel, SizeOf(FIRQLevel));
  FEEPROM.SerializeState(State);
  if State.Loading then
  begin
    FSamples := nil;
    FSampleCount := 0;
  end;
end;

end.

