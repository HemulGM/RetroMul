unit CV.Console;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Emulation.Types,
  Core.Input.Keyboard, Core.Snapshots, HW.Z80, SG1000.VDP, SG1000.Sound,
  HW.Sound.YM2149, CV.Cartridge, MSX.VDP, MSX.Machine, CV.Audio, CV.Controller,
  CV.F18A;

type
  TCVHostKeys = THostKeyboardKeys;

  TCVOptions = record
    ShowBackground, ShowSprites, RemoveSpriteLimit, SGMEnabled, LegacyRAM: Boolean;
    ChannelVolume: array[0..3] of Integer;
    AYVolume: Integer;
    MousePort: Integer;
    class function Defaults: TCVOptions; static;
  end;

  TCVConsole = class
  private
    FCPU: TZ80State;
    FCallbacks: TZ80ReadAndWriteCallbacks;
    FCartridge: TCVCartridge;
    FBIOS: TBytes;
    FRAM: array[0..$3FF] of Byte;
    FSGMRAM: array[0..$7FFF] of Byte;
    FVDP: TSGVDP;
    FVideoChip: Integer;
    FSound: TSGSound;
    FAudio: TCVAudio;
    FAY: TYM2149F;
    FOptions: TCVOptions;
    FInput: TEmulatorInput;
    FKeys: TCVHostKeys;
    FControllers: array[0..1] of string;
    FSpinners: array[0..1] of TCVSpinner;
    FMouseButtons: Byte;
    FPAL, FJoystickMode, FNMILine, FSGMLower, FSGMUpper: Boolean;
    FLine, FLineCycles, FSamplePhase, FSampleCount, FWaitCycles, FBusCycles: Integer;
    FFrameNumber: UInt64;
    FSamples: TArray<SmallInt>;
    function Controller(Port: Integer): Byte;
    procedure Advance(Cycles: Integer);
    procedure UpdateNMI;
    function GetFPS: Double;
  public
    constructor Create(const Data, BIOS: TBytes; PAL: Boolean = False; MapperHint: Integer = -1; VideoHint: Integer = -1);
    destructor Destroy; override;
    procedure Reset;
    procedure ApplyOptions(const Options: TCVOptions);
    procedure SetInput(const Input: TEmulatorInput; const Keys: TCVHostKeys);
    procedure ConfigureControllers(const First, Second: string);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    procedure MoveSpinner(Port, Delta: Integer);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word): Byte;
    procedure WritePort(Address: Word; Value: Byte);
    function Step: Integer;
    procedure RunFrame;
    function ScreenWidth: Integer;
    procedure SerializeState(State: TStateArchive);
    property VDP: TSGVDP read FVDP;
    property Cartridge: TCVCartridge read FCartridge;
    property CPU: TZ80State read FCPU;
    property FrameNumber: UInt64 read FFrameNumber;
    property FramesPerSecond: Double read GetFPS;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleCount;
  end;

implementation

uses
  CV.Firmware;

function ReadBus(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TCVConsole(UserData).ReadMemory(Word(Address and $FFFF));
end;

procedure WriteBus(UserData: Pointer; Address, Value: Cardinal);
begin
  TCVConsole(UserData).WriteMemory(Word(Address and $FFFF), Byte(Value and $FF));
end;

function ReadIO(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TCVConsole(UserData).ReadPort(Word(Address and $FFFF));
end;

procedure WriteIO(UserData: Pointer; Address, Value: Cardinal);
begin
  TCVConsole(UserData).WritePort(Word(Address and $FFFF), Byte(Value and $FF));
end;

procedure BusCycle(UserData: Pointer; Kind: TZ80BusCycle; Address, Count: Cardinal);
begin
  // The ColecoVision inserts one WAIT state in every M1 fetch, including HALT.
  var Console := TCVConsole(UserData);
  Inc(Console.FBusCycles, Count);
  Console.Advance(Count);
  if Kind in [zbcOpcode, zbcAcknowledge] then
  begin
    Inc(Console.FWaitCycles);
    Console.Advance(1);
  end;
end;

class function TCVOptions.Defaults: TCVOptions;
begin
  Result := Default(TCVOptions);
  Result.ShowBackground := True;
  Result.ShowSprites := True;
  Result.SGMEnabled := True;
  Result.AYVolume := 100;
  for var I := 0 to 3 do
    Result.ChannelVolume[I] := 100;
end;

constructor TCVConsole.Create(const Data, BIOS: TBytes; PAL: Boolean; MapperHint, VideoHint: Integer);
begin
  inherited Create;
  if Length(BIOS) <> $2000 then
    raise EReadError.Create('ColecoVision requires an 8 KiB BIOS ROM');
  FBIOS := ColecoBIOSForRegion(BIOS, PAL);
  FPAL := PAL;
  FCartridge := TCVCartridge.Create(Data, MapperHint);
  // Reuse RetroMul's clocked TI model: physical VRAM addressing, scheduled
  // CPU/display fetches, sprite evaluation and raster changes within a line.
  FVideoChip := VideoHint;
  if VideoHint < 0 then
    FVideoChip := Ord(FCartridge.NeedsF18A);
  if FVideoChip = 1 then
    FVDP := TCVF18A.Create
  else
  begin
    FVideoChip := 0;
    FVDP := TMSXVDP.Create(MSX1, PAL, True);
  end;
  FSound := TSGSound.Create;
  FAudio := TCVAudio.Create;
  for var I := 0 to 1 do
    FSpinners[I] := TCVSpinner.Create;
  FAY := TYM2149F.Create(1789772);
  FAY.AYModel := True;
  for var I := 0 to 2 do
    FAY.SetPan(I, 0.5, 0.5);
  SetLength(FSamples, 2048 * 2);
  FCallbacks.ReadCallback := ReadBus;
  FCallbacks.WriteCallback := WriteBus;
  FCallbacks.PortReadCallback := ReadIO;
  FCallbacks.PortWriteCallback := WriteIO;
  FCallbacks.CycleCallback := BusCycle;
  FCallbacks.UserData := Self;
  ApplyOptions(TCVOptions.Defaults);
  Reset;
  ConfigureControllers('pad', 'pad');
end;

destructor TCVConsole.Destroy;
begin
  for var Spinner in FSpinners do
    Spinner.Free;
  FAudio.Free;
  FAY.Free;
  FSound.Free;
  FVDP.Free;
  FCartridge.Free;
  inherited;
end;

procedure TCVConsole.ApplyOptions(const Options: TCVOptions);
begin
  FOptions := Options;
  FOptions.LegacyRAM := Options.LegacyRAM or FCartridge.NeedsLegacyRAM;
  FOptions.AYVolume := EnsureRange(Options.AYVolume, 0, 100);
  FOptions.MousePort := EnsureRange(Options.MousePort, 0, 1);
  FVDP.ConfigureDisplay(Options.ShowBackground, Options.ShowSprites, Options.RemoveSpriteLimit);
  FSound.SetVolumes(Options.ChannelVolume);
end;

procedure TCVConsole.Reset;
begin
  FCPU := Default(TZ80State);
  Z80StateInitialise(FCPU);
  FCPU.StackPointer := $FFFF;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FSGMRAM, SizeOf(FSGMRAM), 0);
  FCartridge.Reset;
  FVDP.Reset;
  FSound.Reset;
  FAudio.Reset;
  FAY.Reset;
  FSGMLower := False;
  FSGMUpper := False;
  FJoystickMode := False;
  FNMILine := False;
  FLine := 0;
  FLineCycles := 0;
  FSamplePhase := 0;
  FSampleCount := 0;
  FFrameNumber := 0;
  for var Spinner in FSpinners do
    Spinner.Reset;
  FMouseButtons := 0;
end;

function TCVConsole.GetFPS: Double;
begin
  Result := 3579545 / (228.0 * (262 + Ord(FPAL) * 51));
end;

function TCVConsole.ScreenWidth: Integer;
begin
  if FVideoChip = 1 then
    Result := TCVF18A(FVDP).ScreenWidth
  else
    Result := 256;
end;

procedure TCVConsole.SetInput(const Input: TEmulatorInput; const Keys: TCVHostKeys);
begin
  FInput := Input;
  FKeys := Keys;
  var Roller := (FControllers[0] = 'roller') or (FControllers[1] = 'roller');
  for var Port := 0 to 1 do
  begin
    var Value := 0;
    var AnalogPort := Port;
    if Roller then
      AnalogPort := Ord(FControllers[1] = 'roller');
    if Roller or (FControllers[Port] = 'driving') or (FControllers[Port] = 'superaction') then
    begin
      if Input.Analog[AnalogPort].Valid then
        if Roller and (Port = 1) then
          Value := Input.Analog[AnalogPort].Y
        else
          Value := Input.Analog[AnalogPort].X
      else if Roller or (FControllers[Port] = 'driving') then
      begin
        var Buttons := Input.Buttons;
        if AnalogPort = 1 then
          Buttons := Input.Buttons2;
        if Roller and (Port = 1) then
        begin
          if TEmulatorButton.Up in Buttons then
            Dec(Value, 24576);
          if TEmulatorButton.Down in Buttons then
            Inc(Value, 24576);
        end
        else
        begin
          if TEmulatorButton.Left in Buttons then
            Dec(Value, 24576);
          if TEmulatorButton.Right in Buttons then
            Inc(Value, 24576);
        end;
      end;
    end;
    FSpinners[Port].SetVelocity(Value);
  end;
end;

procedure TCVConsole.ConfigureControllers(const First, Second: string);
begin
  if (FControllers[0] <> First) or (FControllers[1] <> Second) then
  begin
    for var Spinner in FSpinners do
      Spinner.Reset;
    FMouseButtons := 0;
  end;
  FControllers[0] := First;
  FControllers[1] := Second;
end;

procedure TCVConsole.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  FMouseButtons := Buttons;
  if (FControllers[0] = 'roller') or (FControllers[1] = 'roller') then
  begin
    MoveSpinner(0, DX);
    MoveSpinner(1, DY);
  end
  else if (FControllers[FOptions.MousePort] = 'driving') or
    (FControllers[FOptions.MousePort] = 'superaction') then
    MoveSpinner(FOptions.MousePort, DX);
end;

procedure TCVConsole.MoveSpinner(Port, Delta: Integer);
begin
  if (Port < 0) or (Port > 1) then
    Exit;
  FSpinners[Port].Move(Delta, 228 * (262 + Ord(FPAL) * 51));
end;

function TCVConsole.ReadMemory(Address: Word): Byte;
begin
  if Address >= $8000 then
    Exit(FCartridge.Read(Address));
  if (FOptions.SGMEnabled and (((Address < $2000) and FSGMLower) or
    ((Address >= $2000) and FSGMUpper))) or
    (FOptions.LegacyRAM and (Address >= $2000)) then
    Exit(FSGMRAM[Address]);
  if Address < $2000 then
    Exit(FBIOS[Address]);
  if Address >= $6000 then
    Exit(FRAM[Address and $3FF]);
  Result := $FF;
end;

procedure TCVConsole.WriteMemory(Address: Word; Value: Byte);
begin
  if Address >= $8000 then
    FCartridge.Write(Address, Value)
  else if (FOptions.SGMEnabled and (((Address < $2000) and FSGMLower) or
    ((Address >= $2000) and FSGMUpper))) or
    (FOptions.LegacyRAM and (Address >= $2000)) then
    FSGMRAM[Address] := Value
  else if Address >= $6000 then
    FRAM[Address and $3FF] := Value;
end;

function TCVConsole.Controller(Port: Integer): Byte;
const
  Codes: array[0..11] of Byte = ($A, $D, $7, $C, $2, $3, $E, $5, $1, $B, $9, $6);
begin
  var Buttons := FInput.Buttons;
  if Port = 1 then
    Buttons := FInput.Buttons2;
  Result := $7F;
  if FControllers[Port] = 'none' then
    Exit;
  if (FControllers[0] = 'roller') or (FControllers[1] = 'roller') then
  begin
    if FMouseButtons and (1 shl Port) <> 0 then
      Include(Buttons, TEmulatorButton.A);
    if FMouseButtons and 4 <> 0 then
      Include(Buttons, TEmulatorButton.B);
  end
  else if (FControllers[Port] = 'driving') and (FMouseButtons and 1 <> 0) then
    if Port = FOptions.MousePort then
      Include(Buttons, TEmulatorButton.A);
  if (FControllers[Port] = 'driving') and FInput.Analog[Port].Valid and
    (FInput.Analog[Port].RightTrigger >= 32) then
    Include(Buttons, TEmulatorButton.A);
  if FJoystickMode then
  begin
    if TEmulatorButton.Up in Buttons then
      Result := Result and $FE;
    if TEmulatorButton.Right in Buttons then
      Result := Result and $FD;
    if TEmulatorButton.Down in Buttons then
      Result := Result and $FB;
    if TEmulatorButton.Left in Buttons then
      Result := Result and $F7;
    if TEmulatorButton.A in Buttons then
      Result := Result and $BF;
    if FControllers[Port] = 'driving' then
      Result := Result or $F;
    Result := FSpinners[Port].PortValue(Result, True);
  end
  else
  begin
    if FControllers[Port] = 'driving' then
    begin
      Result := FSpinners[Port].PortValue(Result, False);
      Exit;
    end;
    for var I := 0 to 11 do
    begin
      var Key := $30 + I;
      if Port = 1 then
        Key := $60 + I;
      if I = 10 then
        Key := $51 - Port * 12; // Q / E = star
      if I = 11 then
        Key := $57 - Port * 5;  // W / R = hash
      if FKeys[Key] or ((I = 1) and (TEmulatorButton.Start in Buttons)) or
        ((I = 2) and (TEmulatorButton.Select in Buttons)) then
        Result := Result and ($70 or Codes[I]);
    end;
    if TEmulatorButton.B in Buttons then
      Result := Result and $BF;
    if (FControllers[Port] = 'superaction') and (TEmulatorButton.X in Buttons) then
      Result := Result and $74;
    if (FControllers[Port] = 'superaction') and (TEmulatorButton.Y in Buttons) then
      Result := Result and $78;
    Result := FSpinners[Port].PortValue(Result, False);
  end;
end;

procedure TCVConsole.UpdateNMI;
begin
  var Level := FVDP.Interrupt;
  if Level and not FNMILine then
    Z80NonMaskableInterrupt(FCPU);
  FNMILine := Level;
end;

function TCVConsole.ReadPort(Address: Word): Byte;
begin
  var Port := Address and $FF;
  Result := $FF;
  if (Port = $52) and FOptions.SGMEnabled then
    Exit(FAY.ReadData);
  case Port and $E0 of
    $A0:
      begin
        if Port and 1 = 0 then
          Result := FVDP.ReadData
        else
          Result := FVDP.ReadStatus;
        UpdateNMI;
      end;
    $E0:
      Result := Controller((Port shr 1) and 1);
  end;
end;

procedure TCVConsole.WritePort(Address: Word; Value: Byte);
begin
  var Port := Address and $FF;
  if FOptions.SGMEnabled then
    case Port of
      $50:
        FAY.WriteAddress(Value);
      $51:
        FAY.WriteData(Value);
      $53:
        FSGMUpper := Value and 1 <> 0;
      $7F:
        FSGMLower := Value and 2 = 0;
    end;
  case Port and $E0 of
    $80:
      FJoystickMode := False;
    $A0:
      begin
        if Port and 1 = 0 then
          FVDP.WriteData(Value)
        else
          FVDP.WriteControl(Value);
        UpdateNMI;
      end;
    $C0:
      FJoystickMode := True;
    $E0:
      begin
        // READY is wired to Z80 /WAIT. A TI PSG write holds the bus for
        // 32 master clocks (the ordinary I/O cycle already consumed four).
        Inc(FWaitCycles, 28);
        Advance(28);
        FSound.Write(Value);
        FAudio.SetLevel(FSound.Sample, FSamplePhase);
      end;
  end;
end;

procedure TCVConsole.Advance(Cycles: Integer);
begin
  while Cycles > 0 do
  begin
    var Chunk := Min(Cycles, Min(228 - FLineCycles, (3579545 - FSamplePhase + 44099) div 44100));
    Chunk := Min(Chunk, FSound.ClocksUntilTick);
    for var Spinner in FSpinners do
      Chunk := Min(Chunk, Spinner.ClocksUntilEvent);
    FAudio.SetLevel(FSound.Sample, FSamplePhase);
    Dec(Cycles, Chunk);
    if FVideoChip = 1 then
      TCVF18A(FVDP).Advance(Chunk)
    else
      TMSXVDP(FVDP).Advance(Chunk);
    UpdateNMI;
    FCartridge.AdvanceClocks(Chunk);
    FSound.Advance(Chunk);
    for var Spinner in FSpinners do
      Spinner.Advance(Chunk);
    Z80Interrupt(FCPU, Ord(FSpinners[0].IRQ or FSpinners[1].IRQ));
    Inc(FSamplePhase, Chunk * 44100);
    if FSamplePhase >= 3579545 then
    begin
      Dec(FSamplePhase, 3579545);
      var L, R: SmallInt;
      FAY.Sample(L, R);
      var Sample := FAudio.Sample;
      if FOptions.SGMEnabled then
        Inc(Sample, (Integer(L) + R) * FOptions.AYVolume div 200);
      Sample := EnsureRange(Sample, -32768, 32767);
      if FSampleCount >= Length(FSamples) div 2 then
        raise EInvalidOpException.Create('ColecoVision audio frame buffer exhausted');
      FSamples[FSampleCount * 2] := Sample;
      FSamples[FSampleCount * 2 + 1] := Sample;
      Inc(FSampleCount);
    end;
    FAudio.SetLevel(FSound.Sample, FSamplePhase);
    Inc(FLineCycles, Chunk);
    if FLineCycles = 228 then
    begin
      FLineCycles := 0;
      if FLine < FVDP.ScreenHeight then
        FVDP.RenderLine(FLine);
      FVDP.EndLine(FLine, 262 + Ord(FPAL) * 51);
      Inc(FLine);
      if FLine = 262 + Ord(FPAL) * 51 then
      begin
        FLine := 0;
        if FFrameNumber = High(UInt64) then
          FFrameNumber := 0
        else
          Inc(FFrameNumber);
      end;
      UpdateNMI;
    end;
  end;
end;

function TCVConsole.Step: Integer;
begin
  FWaitCycles := 0;
  FBusCycles := 0;
  Z80Interrupt(FCPU, Ord(FSpinners[0].IRQ or FSpinners[1].IRQ));
  Result := Z80DoInstruction(FCPU, FCallbacks);
  // Retain any internal cycles not reported by an instruction's bus callbacks.
  if Result > FBusCycles then
    Advance(Result - FBusCycles);
  Result := Max(Result, FBusCycles) + FWaitCycles;
end;

procedure TCVConsole.RunFrame;
begin
  FSampleCount := 0;
  var Frame := FFrameNumber;
  repeat
    Step
  until FFrameNumber <> Frame;
end;

procedure TCVConsole.SerializeState(State: TStateArchive);
begin
  var Region := FPAL;
  State.Field(Region, SizeOf(Region));
  if State.Loading and (Region <> FPAL) then
    raise EReadError.Create('Snapshot TV region differs');
  var Chip := FVideoChip;
  State.Field(Chip, SizeOf(Chip));
  if State.Loading and (Chip <> FVideoChip) then
    raise EReadError.Create('Snapshot video chip differs');
  var Expansion := Byte(Ord(FOptions.SGMEnabled) or (Ord(FOptions.LegacyRAM) shl 1));
  var ExpectedExpansion := Expansion;
  State.Field(Expansion, SizeOf(Expansion));
  if State.Loading and (Expansion <> ExpectedExpansion) then
    raise EReadError.Create('Snapshot expansion RAM configuration differs');
  var BIOS := SnapshotIdentity(FBIOS);
  var ExpectedBIOS := BIOS;
  // Persist a fixed-length identity, never a managed string pointer.
  var Identity := TEncoding.ASCII.GetBytes(BIOS);
  State.Field(Identity[0], Length(Identity));
  if State.Loading and (TEncoding.ASCII.GetString(Identity) <> ExpectedBIOS) then
    raise EReadError.Create('Snapshot ColecoVision BIOS differs');
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FSGMRAM, SizeOf(FSGMRAM));
  State.Field(FJoystickMode, SizeOf(FJoystickMode));
  State.Field(FNMILine, SizeOf(FNMILine));
  State.Field(FSGMLower, SizeOf(FSGMLower));
  State.Field(FSGMUpper, SizeOf(FSGMUpper));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineCycles, SizeOf(FLineCycles));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  for var Spinner in FSpinners do
    Spinner.SerializeState(State);
  FCartridge.SerializeState(State);
  FVDP.SerializeState(State);
  FSound.SerializeState(State);
  FAudio.SerializeState(State);
  FAY.SerializeState(State.Field);
  if State.Loading then
  begin
    FSampleCount := 0;
    if (FLine < 0) or (FLine >= 262 + Ord(FPAL) * 51) or
      (FLineCycles < 0) or (FLineCycles >= 228) or
      (FSamplePhase < 0) or (FSamplePhase >= 3579545) or
      (FCPU.RegisterMode > 2) or (FCPU.InterruptMode > 2) then
      raise EReadError.Create('Invalid ColecoVision snapshot timing or CPU state');
  end;
end;

initialization
  HW.Z80.ConstantInitialise;

end.

