unit PS2.Console;

// PlayStation 2 machine: EE, its bus and devices, the high-level kernel and
// IOP services, the scheduler in EE cycles and the field timing (NTSC/PAL,
// VBlank start/end). RunFrame runs one field.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, Core.Snapshots, PS2.Types, PS2.Scheduler, PS2.EE.CPU,
  PS2.EE.Bus, PS2.Timers, PS2.DMAC, PS2.SIF, PS2.GS, PS2.GIF, PS2.Kernel, PS2.ELF, PS2.IOP.FileIO, PS2.IOP.HLE;

type
  TPS2ConsoleConfig = record
    PAL: Boolean;
    // Directory for host: paths (homebrew).
    HostDirectory: string;
  end;

  // host: files from a directory on the host.
  TPS2HostFileSystem = class(TPS2FileSystem)
  private
    FRoot: string;
  public
    constructor Create(const Root: string);
    function ReadFile(const Device, Path: string): TBytes; override;
    function FileSize(const Device, Path: string): Int64; override;
    property Root: string read FRoot write FRoot;
  end;

  TPS2Console = class
  private
    FConfig: TPS2ConsoleConfig;
    FTTY: TStringBuilder;
    FFieldCycles, FVisibleCycles, FLineCycles: Int64;
    FFieldStart: Int64;
    FFrameCount: Int64;
    FInVBlank: Boolean;
    FHostFS: TPS2HostFileSystem;
    FProgram: TBytes;
    FProgramName: string;
    FIdleCycles: Int64;
    procedure TTYWrite(const Text: string);
    procedure IOPTTY(Text: string);
    procedure DMACInterrupt(Active: Boolean);
    procedure GSInterrupt;
    procedure HandleEvent(Event: TPS2Event);
    procedure SetVideo(PAL: Boolean);
    procedure LoadExec(const Path: string; const Args: TArray<string>);
    procedure IOPReset(const Args: string);
    procedure BootIOP;
    function StartModule(const Path: string; const Args: TBytes; out ModuleId: Integer): Boolean;
    function GetHalted: Boolean;
  public
    Scheduler: TPS2Scheduler;
    Bus: TPS2EEBus;
    CPU: TEECPU;
    Cop2: TEECop2;
    Timers: TPS2Timers;
    DMAC: TPS2DMAC;
    SIF: TPS2SIF;
    GS: TPS2GS;
    GIF: TPS2GIF;
    GIFPort: TPS2GIFPort;
    Kernel: TPS2Kernel;
    IOMan: TPS2IOMan;
    FileIO: TPS2FileIOServer;
    IOPHeap: TPS2IOPAllocator;
    HeapServer: TPS2IOPHeapServer;
    LoadFile: TPS2LoadFileServer;
    // Modules the EE asked the IOP to load (diagnostics).
    ModuleLog: TStringList;
    constructor Create(const Config: TPS2ConsoleConfig);
    destructor Destroy; override;
    procedure Reset;
    // A homebrew ELF (EE executable): loaded and started by the HLE kernel.
    procedure LoadProgram(const Data: TBytes; const Name: string);
    procedure RunFrame;
    function TakeTTY: string;
    procedure SerializeState(State: TStateArchive);
    property FrameCount: Int64 read FFrameCount;
    property Halted: Boolean read GetHalted;
    property IdleCycles: Int64 read FIdleCycles;
  end;

implementation

{ TPS2HostFileSystem }

constructor TPS2HostFileSystem.Create(const Root: string);
begin
  inherited Create;
  FRoot := Root;
end;

function TPS2HostFileSystem.ReadFile(const Device, Path: string): TBytes;
begin
  Result := nil;
  if Device <> 'host' then
    Exit;
  var Full := TPath.Combine(FRoot, Path.Replace('/', PathDelim));
  if TFile.Exists(Full) then
    Result := TFile.ReadAllBytes(Full);
end;

function TPS2HostFileSystem.FileSize(const Device, Path: string): Int64;
begin
  Result := -1;
  if Device <> 'host' then
    Exit;
  var Full := TPath.Combine(FRoot, Path.Replace('/', PathDelim));
  if TFile.Exists(Full) then
    Result := TFile.GetSize(Full);
end;

{ TPS2Console }

constructor TPS2Console.Create(const Config: TPS2ConsoleConfig);
begin
  inherited Create;
  FConfig := Config;
  FTTY := TStringBuilder.Create;
  Scheduler := TPS2Scheduler.Create;
  Bus := TPS2EEBus.Create(Scheduler);
  Cop2 := TEECop2.Create;
  CPU := TEECPU.Create(Bus, Cop2, @Scheduler.Now, @Scheduler.Deadline);
  Bus.CPU := CPU;
  Bus.OnTTY := TTYWrite;
  Timers := TPS2Timers.Create(Scheduler, Bus.RaiseIRQ);
  Bus.Timers := Timers;
  DMAC := TPS2DMAC.Create(Scheduler, Bus.RAM, CPU.Scratchpad, Bus.RAMGenerations);
  DMAC.OnInterrupt := DMACInterrupt;
  Bus.DMAC := DMAC;
  SIF := TPS2SIF.Create(Scheduler, DMAC, Bus.RAM, Bus.IOPRAM);
  SIF.OnReset := IOPReset;
  Bus.SIF := SIF;
  GS := TPS2GS.Create;
  GS.OnInterrupt := GSInterrupt;
  Bus.GS := GS;
  GIF := TPS2GIF.Create(GS);
  Bus.GIF := GIF;
  GIFPort := TPS2GIFPort.Create(GIF);
  DMAC.Ports[DMAGIF] := GIFPort;
  Kernel := TPS2Kernel.Create(CPU, Bus, Scheduler);
  Kernel.OnTTY := TTYWrite;
  Kernel.OnLoadExec := LoadExec;
  FHostFS := TPS2HostFileSystem.Create(Config.HostDirectory);
  IOMan := TPS2IOMan.Create(FHostFS);
  IOMan.OnTTY := IOPTTY;
  FileIO := TPS2FileIOServer.Create(IOMan);
  IOPHeap := TPS2IOPAllocator.Create($00080000, $001F0000);
  HeapServer := TPS2IOPHeapServer.Create(IOPHeap, IOMan);
  ModuleLog := TStringList.Create;
  LoadFile := TPS2LoadFileServer.Create(IOMan);
  LoadFile.OnModule := StartModule;
  LoadFile.Log := ModuleLog;
  Reset;
end;

destructor TPS2Console.Destroy;
begin
  FileIO.Free;
  LoadFile.Free;
  HeapServer.Free;
  IOPHeap.Free;
  ModuleLog.Free;
  IOMan.Free;
  FHostFS.Free;
  Kernel.Free;
  GIFPort.Free;
  GIF.Free;
  GS.Free;
  SIF.Free;
  DMAC.Free;
  Timers.Free;
  CPU.Free;
  Cop2.Free;
  Bus.Free;
  Scheduler.Free;
  FTTY.Free;
  inherited;
end;

function TPS2Console.GetHalted: Boolean;
begin
  Result := Kernel.Exited;
end;

procedure TPS2Console.TTYWrite(const Text: string);
begin
  FTTY.Append(Text);
end;

procedure TPS2Console.IOPTTY(Text: string);
begin
  FTTY.Append(Text);
end;

function TPS2Console.TakeTTY: string;
begin
  Result := FTTY.ToString;
  FTTY.Clear;
end;

procedure TPS2Console.DMACInterrupt(Active: Boolean);
begin
  CPU.SetInt1(Active);
end;

procedure TPS2Console.GSInterrupt;
begin
  Bus.RaiseIRQ(0);
end;

procedure TPS2Console.SetVideo(PAL: Boolean);
begin
  FConfig.PAL := PAL;
  GS.PAL := PAL;
  if PAL then
  begin
    FFieldCycles := PS2EEClock div 50;
    FLineCycles := FFieldCycles * 2 div 625;
    FVisibleCycles := FFieldCycles - 25 * FLineCycles;
  end
  else
  begin
    FFieldCycles := Round(PS2EEClock / 59.94);
    FLineCycles := FFieldCycles * 2 div 525;
    FVisibleCycles := FFieldCycles - 22 * FLineCycles;
  end;
  Timers.SetLineCycles(FLineCycles);
  Kernel.SetLineCycles(FLineCycles);
end;

procedure TPS2Console.Reset;
begin
  Scheduler.Reset;
  Bus.Reset;
  CPU.Reset;
  Timers.Reset;
  DMAC.Reset;
  DMAC.CTRL := 1;
  SIF.Reset;
  GS.Reset;
  GS.Interlaced := True;
  GIF.Reset;
  Kernel.Reset;
  IOMan.Reset;
  SetVideo(FConfig.PAL);
  FFrameCount := 0;
  FFieldStart := 0;
  FInVBlank := False;
  FIdleCycles := 0;
  Scheduler.Schedule(TPS2Event.VBlankStart, FVisibleCycles);
  BootIOP;
end;

procedure TPS2Console.BootIOP;
begin
  SIF.RemoveServers;
  SIF.AddServer(FileIO);
  SIF.AddServer(HeapServer);
  SIF.AddServer(LoadFile);
  IOPHeap.Reset;
  SIF.IOPBooted;
end;

function TPS2Console.StartModule(const Path: string; const Args: TBytes; out ModuleId: Integer): Boolean;
begin
  // The high-level IOP provides the system modules; others are not run yet.
  ModuleId := ModuleLog.Count + 1;
  Result := True;
end;

procedure TPS2Console.IOPReset(const Args: string);
begin
  // The IOP restarts: modules and servers again, then the boot flags.
  SIF.RemoveServers;
  SIF.EERecvAddr := 0;
  BootIOP;
end;

procedure TPS2Console.LoadProgram(const Data: TBytes; const Name: string);
begin
  var ELF := TPS2ELF.Create(Data);
  try
    for var S in ELF.Segments do
    begin
      if S.Flags <> 1 then
        Continue;
      var Address := S.PhysicalAddress;
      if Address = 0 then
        Address := S.VirtualAddress;
      var Phys := Address and $1FFFFFFF;
      if Int64(Phys) + S.MemorySize > PS2RAMSize then
        raise EReadError.CreateFmt('ELF segment outside RAM: %.8x', [Address]);
      FillChar((Bus.RAM + Phys)^, S.MemorySize, 0);
      if S.FileSize > 0 then
        Move(ELF.Data[S.Offset], (Bus.RAM + Phys)^, S.FileSize);
      Bus.MarkRAM(Phys, S.MemorySize);
    end;
    FProgram := Data;
    FProgramName := Name;
    Kernel.Boot(ELF.Entry, Name, nil);
  finally
    ELF.Free;
  end;
end;

procedure TPS2Console.LoadExec(const Path: string; const Args: TArray<string>);
begin
  var Device, P: string;
  TPS2IOMan.SplitPath(Path, Device, P);
  var Data: TBytes := nil;
  if IOMan.FileSystem <> nil then
    Data := IOMan.FileSystem.ReadFile(Device, P);
  if (Data = nil) or not TPS2ELF.IsELF(Data) then
  begin
    TTYWrite('LoadExecPS2: cannot load ' + Path + #10);
    CPU.S.GPR[2].Lo := UInt64(-1);
    Exit;
  end;
  LoadProgram(Data, Path);
end;

procedure TPS2Console.HandleEvent(Event: TPS2Event);
begin
  case Event of
    TPS2Event.VBlankStart:
      begin
        FInVBlank := True;
        Bus.RaiseIRQ(2);
        GS.VBlank;
        Kernel.VBlankStart(GS.OddField);
        Scheduler.Schedule(TPS2Event.VBlankEnd, FFieldStart + FFieldCycles);
      end;
    TPS2Event.VBlankEnd:
      begin
        FInVBlank := False;
        Bus.RaiseIRQ(3);
        FFieldStart := FFieldStart + FFieldCycles;
        Scheduler.Schedule(TPS2Event.VBlankStart, FFieldStart + FVisibleCycles);
      end;
    TPS2Event.Timer0: Timers.Event(0);
    TPS2Event.Timer1: Timers.Event(1);
    TPS2Event.Timer2: Timers.Event(2);
    TPS2Event.Timer3: Timers.Event(3);
    TPS2Event.DMAC: DMAC.Event;
    TPS2Event.SIF: SIF.Deliver;
    TPS2Event.Alarm: Kernel.AlarmEvent;
    TPS2Event.Compare: CPU.CompareReached;
  end;
end;

procedure TPS2Console.RunFrame;
begin
  // One field: until the next VBlank start has been handled.
  var Target := Scheduler.Due(TPS2Event.VBlankStart);
  if Target = PS2Never then
    Target := Scheduler.Now + FFieldCycles;
  while True do
  begin
    var Event: TPS2Event;
    var At: Int64;
    while Scheduler.TakeDue(Event, At) do
    begin
      HandleEvent(Event);
      if Event = TPS2Event.VBlankStart then
      begin
        Inc(FFrameCount);
        Exit;
      end;
    end;
    Scheduler.Deadline := Scheduler.NextDue;
    if Kernel.Exited then
    begin
      Scheduler.Now := Scheduler.Deadline;
      Continue;
    end;
    if Kernel.Idle then
    begin
      // Nothing runs until the next event.
      Inc(FIdleCycles, Scheduler.Deadline - Scheduler.Now);
      Scheduler.Now := Scheduler.Deadline;
      Kernel.Idle := False;
      Continue;
    end;
    CPU.Run;
  end;
end;

procedure TPS2Console.SerializeState(State: TStateArchive);
begin
  Scheduler.SerializeState(State);
  Bus.SerializeState(State);
  CPU.SerializeState(State);
  Timers.SerializeState(State);
  DMAC.SerializeState(State);
  SIF.SerializeState(State);
  GS.SerializeState(State);
  GIF.SerializeState(State);
  Kernel.SerializeState(State);
  IOMan.SerializeState(State);
  IOPHeap.SerializeState(State);
  State.Field(FFieldStart, SizeOf(FFieldStart));
  State.Field(FFrameCount, SizeOf(FFrameCount));
  State.Field(FInVBlank, SizeOf(FInVBlank));
end;

end.
