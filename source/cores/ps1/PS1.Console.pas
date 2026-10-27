unit PS1.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Snapshots, Core.CD.Disc,
  PS1.Types, PS1.Scheduler, PS1.Bus, PS1.GTE, PS1.CPU, PS1.DMA, PS1.Timers,
  PS1.SIO, PS1.GPU, PS1.CDROM, PS1.SPU, PS1.MDEC, PS1.Exe;

type
  TPS1Console = class(TPS1IOHandler)
  private
    FScheduler: TPS1Scheduler;
    FBus: TPS1Bus;
    FGTE: TPS1GTE;
    FCPU: TPS1CPU;
    FDMA: TPS1DMA;
    FTimers: TPS1Timers;
    FSIO0: TPS1SIO0;
    FSIO1: TPS1SIO1;
    FGPU: TPS1GPU;
    FCDROM: TPS1CDROM;
    FSPU: TPS1SPU;
    FMDEC: TPS1MDEC;
    FPads: array[0..1] of TPS1Controller;
    FCards: array[0..1] of TPS1MemoryCard;
    FPadConnected: array[0..1] of Boolean;
    FIStat, FIMask: Cardinal;
    FStallUntil: Int64;
    FPAL: Boolean;
    FBIOSIdentity: TBytes;
    FFrameDone: Boolean;
    FPixels: TArray<TAlphaColor>;
    FFrameWidth, FFrameHeight: Integer;
    FFrameNumber: UInt64;
    FExe: TPS1Exe;
    FExeLoaded, FExePending: Boolean;
    FTraceHook: TPS1CPUHook;
    procedure CPUHook(CPU: TPS1CPU);
    procedure UpdateHook;
    procedure SetTraceHook(const Value: TPS1CPUHook);
    procedure RequestIRQ(Line: TPS1IRQ);
    procedure UpdateIRQ; inline;
    procedure Stall(Ready: Int64);
    procedure DispatchEvents;
    procedure HandleHBlank(Active: Boolean; Time: Int64);
    procedure HandleVBlank(Active: Boolean; Time: Int64);
    procedure HandleDotClockChange;
    procedure ConnectPorts;
    function CDROMAddress(Address: Cardinal; Index: Integer): Cardinal;
  public
    constructor Create(const BIOS: TBytes; PAL: Boolean);
    destructor Destroy; override;
    procedure Reset;
    function ReadIO(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean; override;
    function WriteIO(Address, Value: Cardinal; Size: Integer): Boolean; override;
    // Runs until the scheduler reaches Target (or a frame ends when Frame is set).
    procedure RunUntil(Target: Int64; Frame: Boolean = False);
    // Runs to the start of the next vertical blank and captures the picture.
    procedure RunFrame;
    procedure SetPad(Port: Integer; Buttons: Word; Connected: Boolean = True); overload;
    procedure SetPad(Port: Integer; const Input: TPS1PadInput; Kind: TPS1PadKind; Connected: Boolean); overload;
    function Pad(Port: Integer): TPS1Controller;
    // The console owns inserted cards; nil removes the card.
    procedure InsertCard(Port: Integer; Card: TPS1MemoryCard);
    // The disc stays owned by the caller; nil leaves the drive empty.
    procedure InsertDisc(Disc: TCDDisc);
    function Card(Port: Integer): TPS1MemoryCard;
    // Starts a PS-X EXE when the BIOS enters its shell (after Reset).
    procedure LoadExe(const Data: TBytes);
    function FramesPerSecond: Double;
    // Width/height of the current picture on a 4:3 screen.
    function DisplayAspect: Double;
    procedure SerializeState(State: TStateArchive);
    property Scheduler: TPS1Scheduler read FScheduler;
    property Bus: TPS1Bus read FBus;
    property CPU: TPS1CPU read FCPU;
    property GTE: TPS1GTE read FGTE;
    property GPU: TPS1GPU read FGPU;
    property SPU: TPS1SPU read FSPU;
    property CDROM: TPS1CDROM read FCDROM;
    property DMA: TPS1DMA read FDMA;
    property MDEC: TPS1MDEC read FMDEC;
    property Timers: TPS1Timers read FTimers;
    property PAL: Boolean read FPAL;
    property Pixels: TArray<TAlphaColor> read FPixels;
    property FrameWidth: Integer read FFrameWidth;
    property FrameHeight: Integer read FFrameHeight;
    property FrameNumber: UInt64 read FFrameNumber;
    property BIOSIdentity: TBytes read FBIOSIdentity;
    // Called before every instruction (diagnostics).
    property TraceHook: TPS1CPUHook read FTraceHook write SetTraceHook;
  end;

implementation

uses
  System.Hash, System.Math;

const
  StateMagic = $53315350; // 'PS1S'
  StateVersion = 1;

constructor TPS1Console.Create(const BIOS: TBytes; PAL: Boolean);
begin
  inherited Create;
  FPAL := PAL;
  FScheduler := TPS1Scheduler.Create;
  FBus := TPS1Bus.Create;
  FBus.LoadBIOS(BIOS);
  FBus.IO := Self;
  var Hash := THashSHA2.Create;
  Hash.Update(BIOS);
  FBIOSIdentity := Hash.HashAsBytes;
  FGTE := TPS1GTE.Create;
  FCPU := TPS1CPU.Create(FBus, FScheduler, FGTE);
  FDMA := TPS1DMA.Create(FScheduler, FBus, RequestIRQ, Stall);
  FTimers := TPS1Timers.Create(FScheduler, RequestIRQ);
  FSIO0 := TPS1SIO0.Create(FScheduler, RequestIRQ);
  FSIO1 := TPS1SIO1.Create;
  FGPU := TPS1GPU.Create(FScheduler, RequestIRQ, PAL);
  FCDROM := TPS1CDROM.Create(FScheduler, RequestIRQ);
  if PAL then
    FCDROM.Region := 'E';
  FSPU := TPS1SPU.Create(FScheduler, RequestIRQ, FCDROM.Audio);
  FSPU.OnReady := FDMA.Kick;
  FMDEC := TPS1MDEC.Create;
  FDMA.Devices[0] := FMDEC;
  FDMA.Devices[1] := FMDEC;
  FDMA.Devices[2] := FGPU;
  FDMA.Devices[3] := FCDROM;
  FDMA.Devices[4] := FSPU;
  FMDEC.OnReady := FDMA.Kick;
  FTimers.DotCount := FGPU.DotCount;
  FTimers.DotTime := FGPU.DotTime;
  FGPU.OnHBlank := HandleHBlank;
  FGPU.OnVBlank := HandleVBlank;
  FGPU.OnDotClockChange := HandleDotClockChange;
  FGPU.OnReady := FDMA.Kick;
  for var Port := 0 to 1 do
  begin
    FPads[Port] := TPS1Controller.Create;
    FPadConnected[Port] := True;
  end;
  ConnectPorts;
  Reset;
end;

destructor TPS1Console.Destroy;
begin
  for var Port := 0 to 1 do
  begin
    FCards[Port].Free;
    FPads[Port].Free;
  end;
  FMDEC.Free;
  FSPU.Free;
  FCDROM.Free;
  FGPU.Free;
  FSIO1.Free;
  FSIO0.Free;
  FTimers.Free;
  FDMA.Free;
  FCPU.Free;
  FGTE.Free;
  FBus.Free;
  FScheduler.Free;
  inherited;
end;

procedure TPS1Console.ConnectPorts;
begin
  for var Port := 0 to 1 do
  begin
    if FPadConnected[Port] then
      FSIO0.Pads[Port] := FPads[Port]
    else
      FSIO0.Pads[Port] := nil;
    FSIO0.Cards[Port] := FCards[Port];
  end;
end;

procedure TPS1Console.Reset;
begin
  FScheduler.Reset;
  FBus.Reset;
  FGTE.Reset;
  FCPU.Reset;
  FDMA.Reset;
  FTimers.Reset;
  FSIO0.Reset;
  FSIO1.Reset;
  FGPU.Reset;
  FCDROM.Reset;
  FSPU.Reset;
  FMDEC.Reset;
  FIStat := 0;
  FIMask := 0;
  FStallUntil := 0;
  FFrameDone := False;
  FFrameNumber := 0;
  FExePending := FExeLoaded;
  UpdateHook;
  FGPU.Output(FPixels, FFrameWidth, FFrameHeight);
end;

procedure TPS1Console.UpdateIRQ;
begin
  FCPU.SetIRQ((FIStat and FIMask) <> 0);
end;

procedure TPS1Console.RequestIRQ(Line: TPS1IRQ);
begin
  FIStat := FIStat or (Cardinal(1) shl Ord(Line));
  UpdateIRQ;
end;

procedure TPS1Console.Stall(Ready: Int64);
begin
  if Ready > FStallUntil then
    FStallUntil := Ready;
  FCPU.BreakRun;
end;

procedure TPS1Console.HandleHBlank(Active: Boolean; Time: Int64);
begin
  FTimers.HBlank(Active, Time);
end;

procedure TPS1Console.HandleVBlank(Active: Boolean; Time: Int64);
begin
  FTimers.VBlank(Active, Time);
  if Active then
  begin
    FGPU.Output(FPixels, FFrameWidth, FFrameHeight);
    Inc(FFrameNumber);
    FFrameDone := True;
  end;
end;

procedure TPS1Console.HandleDotClockChange;
begin
  FTimers.DotClockChanged(FScheduler.Now);
end;

procedure TPS1Console.DispatchEvents;
var
  Event: TPS1Event;
  At: Int64;
begin
  while FScheduler.TakeDue(Event, At) do
    case Event of
      TPS1Event.GPU:
        FGPU.Event(At);
      TPS1Event.Timer0:
        FTimers.Event(0, At);
      TPS1Event.Timer1:
        FTimers.Event(1, At);
      TPS1Event.Timer2:
        FTimers.Event(2, At);
      TPS1Event.DMA:
        FDMA.Event(At);
      TPS1Event.CDROM:
        FCDROM.Event(At);
      TPS1Event.SPU:
        FSPU.Event(At);
      TPS1Event.SIO0:
        FSIO0.Event(At);
      TPS1Event.GPUDraw:
        FGPU.DrawEvent(At);
    end;
end;

function Narrow(Value: Cardinal; Address: Cardinal; Size: Integer): Cardinal; inline;
begin
  Result := Value shr ((Address and 3) * 8);
  if Size < 4 then
    Result := Result and ($FFFFFFFF shr ((4 - Size) * 8));
end;

function TPS1Console.CDROMAddress(Address: Cardinal; Index: Integer): Cardinal;
begin
  Result := Address;
  if (FBus.MemControl[6] and $2000) <> 0 then
    Result := $1F801800 + ((Address + Cardinal(Index)) and 3);
end;

function TPS1Console.ReadIO(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean;
begin
  // Devices observe all events that are due by the access.
  DispatchEvents;
  Value := 0;
  Result := True;
  case Address of
    $1F801040..$1F80104F:
      Value := FSIO0.Read(Address, Size);
    $1F801050..$1F80105F:
      Value := FSIO1.Read(Address, Size);
    $1F801070..$1F801073:
      Value := Narrow(FIStat, Address, Size);
    $1F801074..$1F801077:
      Value := Narrow(FIMask, Address, Size);
    $1F801080..$1F8010FF:
      Value := Narrow(FDMA.Read(Address and not 3), Address, Size);
    $1F801100..$1F80112F:
      Value := Narrow(FTimers.Read(Address and not 3), Address, Size);
    $1F801800..$1F801803:
      // 8-bit bus: wider accesses repeat the byte access, at the same
      // address unless DEV5 auto-increment is enabled.
      for var I := 0 to Size - 1 do
        Value := Value or (Cardinal(FCDROM.Read(CDROMAddress(Address, I))) shl (I * 8));
    $1F801810..$1F801813:
      Value := Narrow(FGPU.ReadGP0, Address, Size);
    $1F801814..$1F801817:
      Value := Narrow(FGPU.Status, Address, Size);
    $1F801820..$1F801827:
      Value := Narrow(FMDEC.Read(Address and not 3), Address, Size);
    $1F801C00..$1F801FFF:
      begin
        Value := FSPU.Read(Address and not 1);
        if Size = 4 then
          Value := Value or (Cardinal(FSPU.Read(Address + 2)) shl 16)
        else if Size = 1 then
          Value := (Value shr ((Address and 1) * 8)) and $FF;
      end;
  end;
  // Unused ports read as zero without a bus error (Gran Turismo 2 reads a
  // fourth timer at 1F801130h).
end;

// psx-spx "Unpredictable Things": 8/16-bit stores drive the whole register
// on the bus; 32-bit ports ("w32") take it shifted to the address offset.
function Wide(Value, Address: Cardinal): Cardinal; inline;
begin
  Result := Value shl ((Address and 3) * 8);
end;

function TPS1Console.WriteIO(Address, Value: Cardinal; Size: Integer): Boolean;
begin
  DispatchEvents;
  Result := True;
  case Address of
    $1F801040..$1F80104F:
      FSIO0.Write(Address, Value, Size);
    $1F801050..$1F80105F:
      FSIO1.Write(Address, Value, Size);
    $1F801070..$1F801073:
      begin
        FIStat := FIStat and Wide(Value, Address);
        UpdateIRQ;
      end;
    $1F801074..$1F801077:
      begin
        FIMask := Wide(Value, Address) and $7FF;
        UpdateIRQ;
      end;
    $1F801080..$1F8010F7:
      FDMA.Write(Address and not 3, Wide(Value, Address));
    $1F801100..$1F80112F:
      FTimers.Write(Address and not 3, Wide(Value, Address));
    $1F801800..$1F801803:
      for var I := 0 to Size - 1 do
        FCDROM.Write(CDROMAddress(Address, I), Byte(Value shr (I * 8)));
    $1F801810..$1F801813:
      FGPU.WriteGP0(Value);
    $1F801814..$1F801817:
      FGPU.WriteGP1(Value);
    $1F801820..$1F801827:
      FMDEC.Write(Address and not 3, Value);
    $1F801C00..$1F801FFF:
      begin
        FSPU.Write(Address and not 1, Word(Value));
        if Size = 4 then
          FSPU.Write(Address + 2, Word(Value shr 16));
      end;
  end;
end;

procedure TPS1Console.RunUntil(Target: Int64; Frame: Boolean);
begin
  while FScheduler.Now < Target do
  begin
    DispatchEvents;
    if Frame and FFrameDone then
      Exit;
    if FStallUntil > FScheduler.Now then
    begin
      // The CPU is held off the bus while a DMA transfer runs.
      FScheduler.Now := Min(FStallUntil, Min(FScheduler.NextDue, Target));
      Continue;
    end;
    FCPU.Run(Target);
  end;
  DispatchEvents;
end;

procedure TPS1Console.RunFrame;
begin
  FFrameDone := False;
  // Bounded even when the display never reaches a vertical blank.
  RunUntil(FScheduler.Now + PS1CPUClock div 10, True);
end;

procedure TPS1Console.SetPad(Port: Integer; Buttons: Word; Connected: Boolean);
begin
  SetPad(Port, TPS1PadInput.Centred(Buttons), TPS1PadKind.Digital, Connected);
end;

procedure TPS1Console.SetPad(Port: Integer; const Input: TPS1PadInput; Kind: TPS1PadKind; Connected: Boolean);
begin
  FPads[Port].Kind := Kind;
  FPads[Port].SetInput(Input);
  if FPadConnected[Port] <> Connected then
  begin
    FPadConnected[Port] := Connected;
    ConnectPorts;
  end;
end;

function TPS1Console.Pad(Port: Integer): TPS1Controller;
begin
  Result := FPads[Port];
end;

procedure TPS1Console.InsertCard(Port: Integer; Card: TPS1MemoryCard);
begin
  if FCards[Port] <> Card then
    FCards[Port].Free;
  FCards[Port] := Card;
  ConnectPorts;
end;

procedure TPS1Console.InsertDisc(Disc: TCDDisc);
begin
  FCDROM.SetDisc(Disc);
end;

function TPS1Console.Card(Port: Integer): TPS1MemoryCard;
begin
  Result := FCards[Port];
end;

function TPS1Console.FramesPerSecond: Double;
begin
  Result := FGPU.FramesPerSecond;
end;

function TPS1Console.DisplayAspect: Double;
begin
  Result := FGPU.DisplayAspect;
end;

procedure TPS1Console.UpdateHook;
begin
  FCPU.OnHook := CPUHook;
  FCPU.HookEnabled := FExePending or Assigned(FTraceHook);
end;

procedure TPS1Console.SetTraceHook(const Value: TPS1CPUHook);
begin
  FTraceHook := Value;
  UpdateHook;
end;

procedure TPS1Console.LoadExe(const Data: TBytes);
begin
  FExe := ParsePS1Exe(Data);
  FExeLoaded := True;
  FExePending := True;
  UpdateHook;
end;

// Replaces the BIOS shell with the executable, as the kernel's Exec does.
procedure TPS1Console.CPUHook(CPU: TPS1CPU);
begin
  if FExePending and (CPU.PC = PS1ShellEntry) then
  begin
    FExePending := False;
    var Start := FExe.Destination and PS1RAMMask;
    if Length(FExe.Image) > 0 then
      Move(FExe.Image[0], FBus.RAM[Start], Length(FExe.Image));
    if FExe.BSSSize <> 0 then
      FillChar(FBus.RAM[FExe.BSS and PS1RAMMask], FExe.BSSSize, 0);
    CPU.Reg[28] := FExe.GP;
    if FExe.StackBase <> 0 then
    begin
      CPU.Reg[29] := Add32(FExe.StackBase, FExe.StackOffset);
      CPU.Reg[30] := CPU.Reg[29];
    end;
    CPU.Reg[4] := 1;
    CPU.Reg[5] := 0;
    CPU.InvalidateICache;
    CPU.SetPC(FExe.PC);
    UpdateHook;
  end;
  if Assigned(FTraceHook) then
    FTraceHook(CPU);
end;

procedure TPS1Console.SerializeState(State: TStateArchive);
begin
  var Magic: Cardinal := StateMagic;
  var Version: Cardinal := StateVersion;
  State.Field(Magic, SizeOf(Magic));
  State.Field(Version, SizeOf(Version));
  if (Magic <> StateMagic) or (Version <> StateVersion) then
    raise EReadError.Create('Unsupported PS1 snapshot format');

  var Identity := Copy(FBIOSIdentity);
  State.Field(Identity[0], Length(Identity));
  if State.Loading and not CompareMem(@Identity[0], @FBIOSIdentity[0], Length(Identity)) then
    raise EReadError.Create('PS1 snapshot was made with a different BIOS');

  var PALValue := FPAL;
  State.Field(PALValue, SizeOf(PALValue));
  if PALValue <> FPAL then
    raise EReadError.Create('PS1 snapshot video standard mismatch');

  FScheduler.SerializeState(State);
  FBus.SerializeState(State);
  FCPU.SerializeState(State);
  FGTE.SerializeState(State);
  FDMA.SerializeState(State);
  FTimers.SerializeState(State);
  FSIO0.SerializeState(State);
  FSIO1.SerializeState(State);
  for var Port := 0 to 1 do
  begin
    FPads[Port].SerializeState(State);
    State.Field(FPadConnected[Port], SizeOf(FPadConnected[Port]));
    var Present := FCards[Port] <> nil;
    State.Field(Present, SizeOf(Present));
    if Present <> (FCards[Port] <> nil) then
      raise EReadError.Create('PS1 snapshot memory card slots differ');
    if Present then
      FCards[Port].SerializeState(State);
  end;
  FGPU.SerializeState(State);
  FCDROM.SerializeState(State);
  FSPU.SerializeState(State);
  FMDEC.SerializeState(State);
  State.Field(FIStat, SizeOf(FIStat));
  State.Field(FIMask, SizeOf(FIMask));
  State.Field(FStallUntil, SizeOf(FStallUntil));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FExePending, SizeOf(FExePending));
  if State.Loading then
  begin
    FExePending := FExePending and FExeLoaded;
    UpdateHook;
    ConnectPorts;
    UpdateIRQ;
    FGPU.Output(FPixels, FFrameWidth, FFrameHeight);
  end;
end;

end.

