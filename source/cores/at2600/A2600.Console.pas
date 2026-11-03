unit A2600.Console;

interface

uses
  System.SysUtils, A2600.CPU, A2600.Cartridge, A2600.RIOT, A2600.TIA,
  A2600.Controller, Core.Emulation.Types, Core.Snapshots, Core.InputConfig;

type
  TA2600Mapper = A2600.Cartridge.TA2600Mapper;

  TA2600Console = class
  private
    FCPU: TCPU6507;
    FCartridge: TA2600Cartridge;
    FRIOT: TA2600RIOT;
    FTIA: TA2600TIA;
    FController: TA2600Controller;
    FPAL: Boolean;
    FBus: Byte;
    FClock, FAudioPhase, FAudioDebt: Double;
    FSamples: TArray<SmallInt>;
    FSampleCount: Integer;
    function ReadBus(Address: Word): Byte;
    procedure WriteBus(Address: Word; Value: Byte);
    procedure ClockHardware;
    procedure Clock;
    function GetRate: Double;
    function GetFrame: TEmulatorFrame;
    function GetMapper: TA2600Mapper;
    procedure UpdatePaddleConnections;
  public
    ConsoleSwitches: Byte;
    constructor Create(const Data: TBytes; PAL: Boolean = False; const Mapper: string = ''; VideoEnabled: Boolean = True);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInput(const Input: TEmulatorInput);
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    procedure ApplyMouse(DX, DY: Integer; Buttons: Byte);
    function SupportedButtons: TEmulatorButtons;
    procedure RunFrame;
    procedure Sample(out Left, Right: SmallInt);
    procedure SerializeState(State: TStateArchive);
    property Frame: TEmulatorFrame read GetFrame;
    property Samples: TArray<SmallInt> read FSamples;
    property Rate: Double read GetRate;
    property CPU: TCPU6507 read FCPU;
    property Mapper: TA2600Mapper read GetMapper;
  end;

implementation

uses
  A2600.Types, A2600.State;

constructor TA2600Console.Create(const Data: TBytes; PAL: Boolean; const Mapper: string; VideoEnabled: Boolean);
begin
  inherited Create;
  FPAL := PAL;
  FClock := A2600CPUClock(PAL);
  ConsoleSwitches := $3F;
  FCartridge := TA2600Cartridge.Create(Data, Mapper);
  FRIOT := TA2600RIOT.Create;
  FTIA := TA2600TIA.Create(PAL, VideoEnabled);
  FController := TA2600Controller.Create;
  FCPU := TCPU6507.Create;
  FCPU.Connect(ReadBus, WriteBus);
  Reset;
end;

destructor TA2600Console.Destroy;
begin
  FCPU.Free;
  FController.Free;
  FTIA.Free;
  FRIOT.Free;
  FCartridge.Free;
  inherited;
end;

function TA2600Console.GetRate: Double;
begin
  Result := A2600FrameRate(FPAL);
end;

function TA2600Console.GetFrame: TEmulatorFrame;
begin
  Result := FTIA.Frame;
end;

function TA2600Console.GetMapper: TA2600Mapper;
begin
  Result := FCartridge.Mapper;
end;

procedure TA2600Console.Reset;
begin
  FBus := 0;
  FAudioPhase := 0;
  FAudioDebt := 0;
  FSampleCount := 0;
  FSamples := nil;
  FCartridge.Reset;
  FRIOT.Reset;
  FTIA.Reset;
  FCPU.Reset;
end;

procedure TA2600Console.SetInput(const Input: TEmulatorInput);
begin
  FController.SetInput(Input);
end;

procedure TA2600Console.UpdatePaddleConnections;
begin
  for var Index := 0 to 3 do
    FTIA.SetPaddleResistance(Index, FController.Resistance(Index));
end;

procedure TA2600Console.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
  FController.Configure(Ports);
  UpdatePaddleConnections;
end;

procedure TA2600Console.ApplyMouse(DX, DY: Integer; Buttons: Byte);
begin
  FController.ApplyMouse(DX, DY, Buttons);
end;

function TA2600Console.SupportedButtons: TEmulatorButtons;
begin
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.Start, TEmulatorButton.Select];
  if FController.UsesPaddles(0) then
    Include(Result, TEmulatorButton.B);
end;

function TA2600Console.ReadBus(Address: Word): Byte;
begin
  Address := Address and $1FFF;
  FCartridge.Hotspot(Address, 0, False);
  if Address and $1000 <> 0 then
    Result := FCartridge.Read(Address)
  else if Address and $80 = 0 then
    Result := FTIA.Read(Address and 15, FBus,
      (FCartridge.Mapper <> mCM) and FController.FirePressed(0),
      (FCartridge.Mapper <> mCM) and FController.FirePressed(1))
  else
    Result := FRIOT.Read(Address, FController.ReadJoysticks,
      FController.ReadSwitches(ConsoleSwitches));
  // CompuMate identifies itself through grounded controller pins 5L and 9R.
  if (FCartridge.Mapper = mCM) and (Address and $1080 = 0) and
    ((Address and 15 = 8) or (Address and 15 = 11)) then
    Result := Result and $7F;
  FCartridge.Observe(Address, Result);
  FBus := Result;
end;

procedure TA2600Console.WriteBus(Address: Word; Value: Byte);
begin
  Address := Address and $1FFF;
  FBus := Value;
  FCartridge.Hotspot(Address, Value, True);
  if Address and $1000 <> 0 then
    FCartridge.Write(Address, Value)
  else if Address and $80 = 0 then
    FTIA.Write(Address and $3F, Value)
  else
    FRIOT.Write(Address, Value);
  FCartridge.Observe(Address, Value);
end;

procedure TA2600Console.ClockHardware;
begin
  if not FTIA.Waiting or FCPU.NextCycleIsWrite then
    FCPU.Clock;
  FCartridge.Clock(FClock);
  FRIOT.Clock;
  for var I := 1 to 3 do
    FTIA.Clock;
end;

procedure TA2600Console.Clock;
begin
  ClockHardware;
  FAudioPhase := FAudioPhase + A2600SampleRate / FClock;
  if FAudioPhase >= 1 then
  begin
    FAudioPhase := FAudioPhase - 1;
    if FSampleCount + 2 > Length(FSamples) then
      SetLength(FSamples, FSampleCount + 2048);
    FTIA.Sound.Sample(FSamples[FSampleCount], FSamples[FSampleCount + 1]);
    Inc(FSampleCount, 2);
  end;
end;

procedure TA2600Console.RunFrame;
begin
  FController.Update(1 / Rate);
  UpdatePaddleConnections;
  FTIA.BeginFrame;
  FSampleCount := 0;
  for var Tick := 1 to A2600CyclesPerLine * A2600MaxFrameLines do
  begin
    Clock;
    if FCPU.Jammed then
      raise EInvalidOpException.CreateFmt('6507 jam at %.4x', [FCPU.JamPc]);
    if FTIA.FrameReady then
      Break;
  end;
  // Bound RSYNC loops so a worker can always finish stopping.
  if not FTIA.FrameReady then
    FTIA.FinishFrame;
  SetLength(FSamples, FSampleCount);
end;

procedure TA2600Console.Sample(out Left, Right: SmallInt);
begin
  // Audio clients pull one sample without allocating/publishing video frames.
  // Address decoding, CPU, cartridge and RIOT/TIA clocks are shared with RunFrame.
  FAudioDebt := FAudioDebt + FClock / A2600SampleRate;
  while FAudioDebt >= 1 do
  begin
    FAudioDebt := FAudioDebt - 1;
    ClockHardware;
    if FCPU.Jammed then
      raise EInvalidOpException.CreateFmt('6507 jam at %.4x', [FCPU.JamPc]);
  end;
  FTIA.Sound.Sample(Left, Right);
end;

procedure TA2600Console.SerializeState(State: TStateArchive);
begin
  TransferA2600MachineState(State, FCartridge, FRIOT, FTIA, FBus, FAudioPhase);
  FCartridge.SerializeExtra(State);
  FCPU.SerializeState(State);
  FTIA.SerializePresentation(State);
  if (State.Version > 0) and (State.Version < 3) then
  begin
    if State.Loading then
    begin
      FTIA.ResetPaddleInputs;
      UpdatePaddleConnections;
    end;
  end
  else
  begin
    FTIA.SerializeInputs(State);
    FController.SerializeState(State);
  end;
end;

end.

