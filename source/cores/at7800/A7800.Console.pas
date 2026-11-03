unit A7800.Console;

interface

uses
  System.SysUtils, A2600.CPU, A2600.RIOT, HW.Sound.TIA, A5200.POKEY,
  A5200.Controller, A7800.Cartridge, A7800.MARIA, Core.Emulation.Types,
  Core.Snapshots;

type
  TA7800Console = class
  private
    FCPU: TCPU6507;
    FRIOT: TA2600RIOT;
    FTIA: TTIASound;
    FPokey: TA5200POKEY;
    FPokeyController: TA5200Controller;
    FCartridge: TA7800Cartridge;
    FMaria: TA7800Maria;
    FRAM: array[0..4095] of Byte;
    FInput: TEmulatorInput;
    FControl, FBus: Byte;
    FAudioPhase: Double;
    FSlowPhase, FLineDebt, FCPUClockRemaining, FCPUClockCost: Integer;
    FInCPUClock: Boolean;
    FSamples: TArray<SmallInt>;
    FSampleCount: Integer;
    function GetFrame: TEmulatorFrame;
    function GetRate: Double;
    function PortA: Byte;
    function PortB: Byte;
    procedure Tick(RunCPU: Boolean);
  public
    constructor Create(const Image: TBytes);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInput(const Input: TEmulatorInput);
    function ReadBus(Address: Word): Byte;
    procedure WriteBus(Address: Word; Value: Byte);
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    property CPU: TCPU6507 read FCPU;
    property Cartridge: TA7800Cartridge read FCartridge;
    property Frame: TEmulatorFrame read GetFrame;
    property Samples: TArray<SmallInt> read FSamples;
    property Rate: Double read GetRate;
  end;

implementation

uses
  System.Classes, System.Math, NES.CPU;

constructor TA7800Console.Create(const Image: TBytes);
begin
  inherited Create;
  FCartridge := TA7800Cartridge.Create(Image);
  FRIOT := TA2600RIOT.Create;
  FTIA := TTIASound.Create;
  FPokeyController := TA5200Controller.Create;
  FPokey := TA5200POKEY.Create;
  FMaria := TA7800Maria.Create(ReadBus, FCartridge.PAL);
  FCPU := TCPU6507.Create;
  FCPU.Connect(ReadBus, WriteBus);
  Reset;
end;

destructor TA7800Console.Destroy;
begin
  FCPU.Free;
  FMaria.Free;
  FPokey.Free;
  FPokeyController.Free;
  FTIA.Free;
  FRIOT.Free;
  FCartridge.Free;
  inherited;
end;

procedure TA7800Console.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FControl := 7;
  FBus := 0;
  FAudioPhase := 0;
  FSlowPhase := 0;
  FLineDebt := 0;
  FCPUClockRemaining := 0;
  FCPUClockCost := 4;
  FInCPUClock := False;
  FSampleCount := 0;
  FSamples := nil;
  FCartridge.Reset;
  FRIOT.Reset;
  FTIA.Reset;
  FPokey.Reset;
  FMaria.Reset;
  FCPU.Reset;
end;

function TA7800Console.GetFrame: TEmulatorFrame;
begin
  Result := FMaria.Frame;
end;

function TA7800Console.GetRate: Double;
begin
  Result := FMaria.Frame.FramesPerSecond;
end;

procedure TA7800Console.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

function TA7800Console.PortA: Byte;
begin
  Result := $FF;
  if TEmulatorButton.Up in FInput.Buttons then
    Result := Result and $EF;
  if TEmulatorButton.Down in FInput.Buttons then
    Result := Result and $DF;
  if TEmulatorButton.Left in FInput.Buttons then
    Result := Result and $BF;
  if TEmulatorButton.Right in FInput.Buttons then
    Result := Result and $7F;
  if TEmulatorButton.Up in FInput.Buttons2 then
    Result := Result and $FE;
  if TEmulatorButton.Down in FInput.Buttons2 then
    Result := Result and $FD;
  if TEmulatorButton.Left in FInput.Buttons2 then
    Result := Result and $FB;
  if TEmulatorButton.Right in FInput.Buttons2 then
    Result := Result and $F7;
end;

function TA7800Console.PortB: Byte;
begin
  Result := $FF;
  if TEmulatorButton.Start in FInput.Buttons then
    Result := Result and $FE;
  if TEmulatorButton.Select in FInput.Buttons then
    Result := Result and $FD;
  if TEmulatorButton.Mode in FInput.Buttons then
    Result := Result and $F7;
end;

function TA7800Console.ReadBus(Address: Word): Byte;
begin
  if FInCPUClock and (Address < $4000) and
    not ((Address < $200) and (Address and $FF >= $40)) and
    not ((FCartridge.PokeyAddress <> 0) and (Address and $FFF0 = FCartridge.PokeyAddress)) and
    ((Address and $1280 = $280) or (Address and $1020 = 0)) then
    FCPUClockCost := 6;
  Result := $FF;
  var PokeyAddress := FCartridge.PokeyAddress;
  if (PokeyAddress <> 0) and (Address and $FFF0 = PokeyAddress) then
    Exit(FPokey.Read(Address and 15, FPokeyController, 0, False));
  if Address >= $4000 then
    Exit(FCartridge.Read(Address));
  if (Address >= $1800) and (Address < $2800) then
    Exit(FRAM[Address - $1800]);
  if (Address >= $2800) and (Address < $3000) then
    Exit(FRAM[Address - $2000]);
  if (Address >= $3000) and (Address < $4000) then
    Exit(FCartridge.Read(Address));
  // TIA/MARIA decode A8..A10 as don't-care lines; RAM shadows only the low pages.
  if (Address < $200) and (Address and $FF >= $40) then
    Exit(FRAM[$800 + (Address and $7FF)]);
  if Address and $1280 = $280 then
    Exit(FRIOT.Read($200 or (Address and $1F), PortA, PortB));
  if Address and $1020 = $20 then
    Exit(FMaria.Read(Address and 31));
  if Address and $1020 = 0 then
  begin
    Result := FBus and $7F;
    var Buttons := FInput.Buttons;
    var Port := 0;
    if Address and 15 in [10, 11, 13] then
      Port := 1;
    var Riot := FRIOT.SnapshotState;
    var EnableBit := 4;
    if Port = 1 then
      EnableBit := 16;
    var TwoButtons := (Riot.DDRB and EnableBit <> 0) and (Riot.PortB and EnableBit = 0);
    if Address and 15 in [10, 11, 13] then
      Buttons := FInput.Buttons2;
    case Address and 15 of
      8, 10:
        if TwoButtons and (TEmulatorButton.B in Buttons) then
          Result := Result or $80;
      9, 11:
        if TwoButtons and (TEmulatorButton.A in Buttons) then
          Result := Result or $80;
      12, 13:
        if TwoButtons or not ((TEmulatorButton.A in Buttons) or (TEmulatorButton.B in Buttons)) then
          Result := Result or $80;
    end;
  end;
  FBus := Result;
end;

procedure TA7800Console.WriteBus(Address: Word; Value: Byte);
begin
  FBus := Value;
  if FInCPUClock and (Address < $4000) and
    not ((Address < $200) and (Address and $FF >= $40)) and
    not ((FCartridge.PokeyAddress <> 0) and (Address and $FFF0 = FCartridge.PokeyAddress)) and
    ((Address and $1280 = $280) or (Address and $1020 = 0)) then
    FCPUClockCost := 6;
  if (FCartridge.PokeyAddress <> 0) and (Address and $FFF0 = FCartridge.PokeyAddress) then
  begin
    FPokey.Write(Address and 15, Value, FPokeyController);
    Exit;
  end;
  if Address >= $4000 then
    FCartridge.Write(Address, Value)
  else if (Address >= $1800) and (Address < $2800) then
    FRAM[Address - $1800] := Value
  else if (Address >= $2800) and (Address < $3000) then
    FRAM[Address - $2000] := Value
  else if (Address < $200) and (Address and $FF >= $40) then
    FRAM[$800 + (Address and $7FF)] := Value
  else if Address and $1280 = $280 then
    FRIOT.Write($200 or (Address and $1F), Value)
  else if Address and $1020 = $20 then
    FMaria.Write(Address and 31, Value)
  else if Address and $1020 = 0 then
  begin
    if (Address and $1F >= $15) and (Address and $1F <= $1A) then
      FTIA.WriteRegister(Address and $1F, Value);
    if (Address and $1F = 1) and (FControl and 1 = 0) then
      FControl := Value;
  end;
end;

procedure TA7800Console.Tick(RunCPU: Boolean);
begin
  if FCPUClockRemaining > 0 then
    Dec(FCPUClockRemaining);
  if (FCPUClockRemaining = 0) and (RunCPU or FCPU.NextCycleIsWrite) and
    (not FMaria.Waiting or FCPU.NextCycleIsWrite) then
  begin
    FCPUClockCost := 4;
    FInCPUClock := True;
    try
      FCPU.Clock;
    finally
      FInCPUClock := False;
    end;
    FCPUClockRemaining := FCPUClockCost;
  end;
  Inc(FSlowPhase);
  if FSlowPhase >= 6 then
  begin
    Dec(FSlowPhase, 6);
    FRIOT.Clock;
  end;
  Inc(FLineDebt);
  if FLineDebt = 4 then
  begin
    FLineDebt := 0;
    FPokey.Clock(FPokeyController, 0);
  end;
  var Clock := 1789772.727272727;
  if FCartridge.PAL then
    Clock := 1773447;
  FAudioPhase := FAudioPhase + 44100 / (Clock * 4);
  if FAudioPhase >= 1 then
  begin
    FAudioPhase := FAudioPhase - 1;
    var L, R: SmallInt;
    FTIA.Sample(L, R);
    if FSampleCount + 2 > Length(FSamples) then
      SetLength(FSamples, FSampleCount + 2048);
    FSamples[FSampleCount] := L;
    FSamples[FSampleCount + 1] := R;
    Inc(FSampleCount, 2);
  end;
end;

procedure TA7800Console.RunFrame;
begin
  FSampleCount := 0;
  FPokey.BeginFrame;
  var Lines := 263;
  if FCartridge.PAL then
    Lines := 313;
  for var Line := 0 to Lines - 1 do
  begin
    FMaria.StartLine(Line);
    var DMAEnd := 28;
    var DLI := False;
    // NTSC/PAL both have 454 MARIA clocks per scanline (113.5 Sally
    // cycles). Preserve CPU/RIOT/POKEY phases across every line boundary.
    for var Cycle := 0 to 453 do
    begin
      if Cycle = 28 then
      begin
        DMAEnd := Min(454, 28 + FMaria.BeginLine(Line));
        DLI := FMaria.NMI;
      end;
      if DLI and (Cycle = DMAEnd) then
      begin
        FCPU.TriggerNmi;
        DLI := False;
      end;
      Tick((Cycle < 28) or (Cycle >= DMAEnd));
    end;
    if DLI then
      FCPU.TriggerNmi;
    FMaria.DisplayLine;
  end;
  SetLength(FSamples, FSampleCount);
  var PokeySamples: TArray<SmallInt>;
  FPokey.EndFrame(PokeySamples);
  if FCartridge.PokeyAddress <> 0 then
    for var i := 0 to Min(Length(FSamples), Length(PokeySamples)) - 1 do
      FSamples[i] := EnsureRange(Integer(FSamples[i]) + PokeySamples[i], -32768, 32767);
  FMaria.EndFrame;
end;

procedure TA7800Console.SerializeState(State: TStateArchive);
begin
  FCPU.SerializeState(State);
  FCartridge.SerializeState(State);
  FMaria.SerializeState(State);
  var RiotState := FRIOT.SnapshotState;
  State.Field(RiotState, SizeOf(RiotState));
  if State.Loading then
    FRIOT.SnapshotState := RiotState;
  FTIA.SerializeState(State);
  FPokey.SerializeState(State);
  State.Field(FCPUClockRemaining, SizeOf(FCPUClockRemaining));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FBus, SizeOf(FBus));
  State.Field(FAudioPhase, SizeOf(FAudioPhase));
  State.Field(FSlowPhase, SizeOf(FSlowPhase));
  State.Field(FLineDebt, SizeOf(FLineDebt));
  if State.Loading then
  begin
    FSamples := nil;
    FSampleCount := 0;
  end;
end;

end.

