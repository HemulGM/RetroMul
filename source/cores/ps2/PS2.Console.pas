unit PS2.Console;

// PlayStation 2 machine: EE, its bus and devices, the high-level kernel and
// IOP services, the scheduler in EE cycles and the field timing (NTSC/PAL,
// VBlank start/end). RunFrame runs one field.
// With a BIOS image the console boots it instead (External BIOS mode): the EE
// and the IOP start at their reset vectors and run the BIOS kernels; the IOP
// side is TPS2IOPMachine with the SIF hardware (TPS2SIFBridge) and the CDVD
// drive, and the high-level kernels and servers stay idle.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Core.Snapshots, Core.DVD.Image, PS2.Types, PS2.Scheduler, PS2.EE.CPU,
  PS2.EE.Bus, PS2.Timers, PS2.DMAC, PS2.SIF, PS2.GS, PS2.GIF, PS2.Kernel,
  PS2.ELF, PS2.IOP.FileIO, PS2.IOP.HLE, PS2.IOP.CDVD, PS2.IOP.Pad,
  PS2.IOP.MemoryCard, PS2.IOP.Kernel, PS2.VU, PS2.VIF, PS2.IPU, PS2.SIF.Bridge,
  PS2.CDVD.Drive, PS2.IOP.Machine, PS2.BIOS, PS2.VU1Domain, PS2.VU1Thread;

const
  // Serialized layout of TPS2Console.SerializeState. Increase it with every
  // layout change; tests/cores/ps2/system checks the recorded field layout.
  PS2SnapshotVersion = 9;

type
  TPS2ConsoleConfig = record
    PAL: Boolean;
    // Directory for host: paths (homebrew).
    HostDirectory: string;
    // The disc (owned by the caller) or nil.
    Disc: TDVDImage;
    Region: TPS2Region;
    Language: TPS2Language;
    // A PlayStation 2 BIOS (4 MiB) to boot instead of the high-level
    // kernels, and its console's MECHACON version and EEPROM (empty: a
    // default version, a blank EEPROM).
    BIOS: TBytes;
    Mechacon: TBytes;
    NVM: TBytes;
  end;

  // Experimental: the VU1 domain's registers the EE reads, as the domain had
  // them from Time on (its events up to then done).
  TPS2DomainView = record
    Time: Int64;
    Ch: array[DMAVIF1..DMAGIF] of TPS2DMAChannel;
    PortOnEE: array[DMAVIF1..DMAGIF] of Boolean;
    VIF: TPS2VIFRegisters;
    VU1BusyUntil: Int64;
    VU1Running, MaskedPath3: Boolean;
    DrainWaiting: array[DMAVIF1..DMAGIF] of Boolean;
  end;

  PPS2DomainView = ^TPS2DomainView;

  // The VU1 domain as it was when it went ahead (going back starts there).
  TPS2DomainCheckpoint = record
    Now: Int64;
    Scheduler: TPS2SchedulerSaved;
    Ch: array[DMAVIF1..DMAGIF] of TPS2DMAChannel;
    Moved: array[DMAVIF1..DMAGIF] of Integer;
    PortOnEE: array[DMAVIF1..DMAGIF] of Boolean;
    PortEndAt: array[DMAVIF1..DMAGIF] of Int64;
    DrainWaiting: array[DMAVIF1..DMAGIF] of Boolean;
    VIF: TPS2VIFSaved;
    VU1: TPS2VU1Saved;
    GIF: TPS2GIFSaved;
    Code, Data: array[0..$3FFF] of Byte;
  end;

  TPS2Console = class
  private
    FConfig: TPS2ConsoleConfig;
    FTTY: TStringBuilder;
    FFieldCycles, FVisibleCycles, FLineCycles: Int64;
    FFieldStart: Int64;
    FFrameCount: Int64;
    FInVBlank: Boolean;
    FDiscFS: TPS2DiscFileSystem;
    FCDVD: TObjectList<TPS2CDVDServer>;
    FProgram: TBytes;
    FProgramName: string;
    FIdleCycles: Int64;
    // EE interrupts the VU1 domain raised (VIF1, DMAC, GS): ends an idle wait.
    FDomainSignals: Int64;
    // The VU1 domain ahead of the EE on a thread while channel 1 runs (off
    // with PS2_VU1_THREAD=0).
    FAheadThread: TPS2VU1Thread;
    // Host scheduling only: pause speculation after an expensive JIT replay.
    FAheadAdaptive: Boolean;
    FAheadRetryAt: Int64;
    // Running ahead: views the domain thread posts (the EE side keeps the
    // one at FViewDone, the last up to its time).
    FViews: TArray<TPS2DomainView>;
    FViewPosted, FViewDone: Int64;
    // State from the start of the speculative session, restored on conflict.
    FCheckpoint: TPS2DomainCheckpoint;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
    // RunEE's limit and the deadline it ran the EE to (-1: not in RunEE);
    // deadlines the EE went on past (EEDeadline).
    FRunLimit, FRunStop: Int64;
{$ENDIF}
    // FINISH writes not in CSR yet: the EE cycle each shows, oldest first.
    FFinishDue: array[0..7] of Int64;
    FFinishCount: Integer;
    // BIOS boot: the console's video standard at power-on (by BIOS region).
    FBIOSPAL: Boolean;
    procedure GSFinishWritten;
    procedure GSFinishShown;
    procedure TTYWrite(const Text: string);
    procedure IOPTTY(Text: string);
    procedure DMACInterrupt(Active: Boolean);
    procedure GSInterrupt;
    function GSInterruptRaised: Boolean;
    procedure HandleEvent(Event: TPS2Event; At: Int64);
    procedure HandleEventHere(Event: TPS2Event; At: Int64);
    procedure CatchUpDomain(T: Int64);
    procedure RunEE(Limit: Int64);
    procedure IdleTo(Limit: Int64);
    procedure DomainLeft;
    procedure RunDomainEvent;
    function NextDomainStop: Int64;
    function CanGoAhead: Boolean;
    procedure StartAhead;
    procedure StopAhead;
    procedure EndAhead;
    procedure AbandonAhead;
    procedure SaveDomain(var C: TPS2DomainCheckpoint);
    procedure RestoreDomain(const C: TPS2DomainCheckpoint);
    procedure RollBack(Applied: Int64);
    procedure WaitDomain(T: Int64);
    procedure ServeAhead(UpTo: Int64);
    procedure ApplyOutput(Kind: Integer; Value: Cardinal);
    function AnswerAhead(Kind: Integer; Time: Int64): Int64;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
    function AheadStep: TPS2AheadStep;
{$ENDIF}
    procedure PostView(Time: Int64);
    function ViewIndex(T: Int64): Int64;
    procedure RetireViews(T: Int64; SkipUnchanged: Boolean); inline;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
    function ViewAt(T: Int64): PPS2DomainView;
    function ReadAheadRegister(Address: Cardinal; out Value: UInt64): Boolean;
    function AheadVU1Busy(out Busy: Boolean): Boolean;
    function AheadCopy(Key: Integer; Source: PByte; Size: Integer; out Token: Int64): PByte;
    procedure AheadCopyUsed(Token: Int64; Used: Integer);
    function AheadLimit(Key: Integer; Source: PByte; Count: Integer): Integer;
    function AheadCheck(Source: PCardinal; Mask, Offset, Value: Cardinal; Decided: Boolean): Boolean;
    procedure AheadResume(N: Integer);
    function EEDeadline: Boolean;
{$ENDIF}
    procedure SetVideo(PAL: Boolean);
    procedure SetVideoTiming(PAL: Boolean);
    procedure LoadExec(const Path: string; const Args: TArray<string>);
    procedure IOPReset(const Args: string);
    procedure BootIOP;
    procedure ConfigureOSD;
    procedure AddIOPServers;
    procedure StartVU1(Address: Cardinal);
    function ImageVersion(const ResetArgs: string): Integer;
    procedure VU1Kick(Address: Cardinal; Data: PByte);
    procedure NoteModuleVersion(const Path: string; const Image: TBytes);
    function StartModule(Server: TPS2LoadFileServer; const Path: string; const Image, Args: TBytes; out ModResult: Integer): Integer;
    procedure ModuleDone(const Token: TBytes; ModuleId, Result: Integer);
    function GetHalted: Boolean;
    procedure CreateMachine;
    function GetBIOSBoot: Boolean;
    procedure ResetMachine;
    procedure HandleMachineEvent(Event: TPS2Event; At: Int64);
    procedure RunMachine;
    procedure VUCodeWritten(Index: Integer);
    procedure SerializeStateHere(State: TStateArchive);
  public
    Scheduler: TPS2Scheduler;
    // DMA channels 1 and 2, VIF1, VU1, the GIF and the GS, with their own
    // events (VIF1 wake, PATH3 release, ends of channels 1 and 2).
    VU1Domain: TPS2VU1Domain;
    DomainScheduler: TPS2Scheduler;
    Bus: TPS2EEBus;
    CPU: TEECPU;
    VU0: TPS2VU0;
    VU1: TPS2VU1;
    Timers: TPS2Timers;
    DMAC: TPS2DMAC;
    SIF: TPS2SIF;
    GS: TPS2GS;
    GIF: TPS2GIF;
    GIFPort: TPS2GIFPort;
    VIF0, VIF1: TPS2VIF;
    VIF0Port, VIF1Port: TPS2VIFPort;
    IPU: TPS2IPU;
    IPUPort: TPS2IPUPort;
    Kernel: TPS2Kernel;
    IOMan: TPS2IOMan;
    FileIO: TPS2FileIOServer;
    IOPHeap: TPS2IOPAllocator;
    HeapServer: TPS2IOPHeapServer;
    LoadFile: TPS2LoadFileServer;
    PadMan: TPS2PadMan;
    MemoryCards: TPS2MCServer;
    IOP: TPS2IOPKernel;
    // BIOS boot: the SIF hardware, the CDVD drive and the IOP running its
    // own kernel (nil with the high-level kernels).
    Bridge: TPS2SIFBridge;
    SIF0Port, SIF1Port: TPS2DMAPort;
    Drive: TPS2CDVDDrive;
    IOPMachine: TPS2IOPMachine;
    // Run game IOP modules as IOP code (False: report them loaded only).
    RunIOPModules: Boolean;
    // Modules the EE asked the IOP to load (diagnostics).
    ModuleLog: TStringList;
    constructor Create(const Config: TPS2ConsoleConfig);
    destructor Destroy; override;
    procedure Reset;
    // A homebrew ELF (EE executable): loaded and started by the HLE kernel.
    procedure LoadProgram(const Data: TBytes; const Name: string);
    // Loads an IOP module (IRX) and starts it on the IOP, with no EE program
    // (IOP test programs).
    procedure LoadIOPModule(const Data: TBytes; const Name: string);
    // Boots the disc: BOOT2 from SYSTEM.CNF (False without a PS2 disc).
    function BootDisc: Boolean;
    property DiscFS: TPS2DiscFileSystem read FDiscFS;
    procedure RunFrame;
    function TakeTTY: string;
    procedure SerializeState(State: TStateArchive);
    // Diagnostics: CDVD server requests go to Log.
    procedure SetCDVDLog(Log: TStrings);
    property FrameCount: Int64 read FFrameCount;
    property Halted: Boolean read GetHalted;
    // The console boots its BIOS (External BIOS mode).
    property BIOSBoot: Boolean read GetBIOSBoot;
    property IdleCycles: Int64 read FIdleCycles;
    // Experimental: the VU1 thread's counters ('' without it).
    // Snapshot header policy: version and the errors users see.
    class function SnapshotPolicy: TSnapshotPolicy; static;
  end;

implementation

uses
  System.Math, System.Diagnostics, System.SyncObjs, PS2.IOP.Loader, HW.HostFPU;

const
  // EE cycles per IOP slice while IOP code has work.
  IOPSlice = 4096;
  // EE cycles from a FINISH register write to CSR.FINISH.
  GSFinishDelay = 8192;
  // SPU2 samples computed together, and their EE cycles.
  SPU2Batch = 32;
  SPU2BatchCycles = SPU2Batch * (PS2EEClock div PS2SPU2Rate);
  VU1ReplayMinPairs = 65536;
  VU1ReplayCooldown = Int64(PS2EEClock);

{ TPS2Console }

constructor TPS2Console.Create(const Config: TPS2ConsoleConfig);
begin
  inherited Create;
  FConfig := Config;
  FTTY := TStringBuilder.Create;
  Scheduler := TPS2Scheduler.Create;
  VU1Domain := TPS2VU1Domain.Create(Scheduler);
  VU1Domain.OnCatchUp := CatchUpDomain;
  VU1Domain.OnLeave := DomainLeft;
  DomainScheduler := TPS2Scheduler.Create;
  Bus := TPS2EEBus.Create(Scheduler);
  Bus.VU1Domain := VU1Domain;
  VU0 := TPS2VU0.Create(Bus.VU0Code, Bus.VU0Data);
  VU1 := TPS2VU1.Create(Bus.VU1Code, Bus.VU1Data);
  VU0.VU1 := VU1.Core;
  VU0.VU1Domain := VU1Domain;
  VU0.Clock := @Scheduler.Now;
  VU0.OnStartVU1 := StartVU1;
  VU1.Core.OnKick := VU1Kick;
  CPU := TEECPU.Create(Bus, VU0, @Scheduler.Now, @Scheduler.Deadline);
  Bus.CPU := CPU;
  Bus.OnCodeWritten := VUCodeWritten;
  Bus.OnTTY := TTYWrite;
  Timers := TPS2Timers.Create(Scheduler, Bus.RaiseIRQ);
  Bus.Timers := Timers;
  DMAC := TPS2DMAC.Create(Scheduler, Bus.RAM, CPU.Scratchpad, Bus.RAMGenerations);
  DMAC.OnInterrupt := DMACInterrupt;
  Bus.DMAC := DMAC;
  DMAC.Domain := VU1Domain;
  DMAC.DomainScheduler := DomainScheduler;
  SIF := TPS2SIF.Create(Scheduler, DMAC, Bus.RAM, Bus.IOPRAM);
  SIF.OnReset := IOPReset;
  SIF.StubUnknownServers := True;
  Bus.SIF := SIF;
  GS := TPS2GS.Create;
  GS.OnInterrupt := GSInterrupt;
  GS.InterruptRaised := GSInterruptRaised;
  GS.Raster.OnFinish := GSFinishWritten;
  Bus.GS := GS;
  GIF := TPS2GIF.Create(GS);
  GIF.Domain := VU1Domain;
  GIF.Clock := @VU1Domain.Now;
  // Speculative execution restores the guest's exact host floating-point state.
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  var AheadMode := GetEnvironmentVariable('PS2_VU1_THREAD');
  if AheadMode <> '0' then
  begin
    FAheadAdaptive := AheadMode <> '1';
    GIF.DeferWork := True;
    GIF.CommitClock := @Scheduler.Now;
    GIF.OnRequest :=
      function(Kind: Integer; Time: Int64): Int64
      begin
        Result := FAheadThread.Request(Kind, Time);
      end;
    DMAC.OnAheadStat :=
      procedure(Mask: Cardinal)
      begin
        FAheadThread.Output(VU1Domain.Now, 1, Mask);
      end;
    VU1Domain.OnStopAhead :=
      procedure
      begin
        StopAhead;
      end;
    DMAC.OnAheadPortEnd :=
      procedure(Channel, Moved: Integer)
      begin
        GIF.PostPortEnd(Channel, Moved);
      end;
    GIF.OnPortEnd :=
      procedure(Channel, Moved: Integer; Time: Int64)
      begin
        if Channel = DMAGIF then
          DMAC.PortDoneAt(Channel, Moved, GIF.TakePortCyclesHere, Time)
        else
          DMAC.PortDoneAt(Channel, Moved, GIF.GSBusyCyclesAt(Time), Time);
      end;
    FAheadThread := TPS2VU1Thread.Create(AheadStep);
    SetLength(FViews, 1 shl 14);
    DMAC.OnAheadRead := AheadCopy;
    DMAC.OnAheadReadUsed := AheadCopyUsed;
    DMAC.OnAheadLimit := AheadLimit;
    DMAC.OnAheadCheck := AheadCheck;
    DMAC.OnAheadResume := AheadResume;
    GIF.OnAheadRead := AheadCopy;
    GIF.OnAheadReadUsed := AheadCopyUsed;
    VU1Domain.OnAheadRead := ReadAheadRegister;
    VU1Domain.OnAheadBusy := AheadVU1Busy;
    FRunStop := -1;
    CPU.OnDeadline := EEDeadline;
  end;
{$ENDIF}
  Bus.GIF := GIF;
  GIFPort := TPS2GIFPort.Create(GIF);
  GIF.OnPath3Resume :=
    procedure
    begin
      DMAC.Resume(DMAGIF);
    end;
  GIF.OnPath3Held :=
    procedure(Cycles: Int64)
    begin
      DomainScheduler.ScheduleAt(TPS2Event.GIF, VU1Domain.Now + Cycles);
    end;
  DMAC.Ports[DMAGIF] := GIFPort;
  VIF0 := TPS2VIF.Create(0, VU0.Core, nil, Bus.VU0Code, Bus.VU0Data, $1000, $1000);
  VIF1 := TPS2VIF.Create(1, VU1.Core, GIF, Bus.VU1Code, Bus.VU1Data, $4000, $4000);
  VIF0.OnInterrupt :=
    procedure
    begin
      Bus.RaiseIRQ(4);
    end;
  VIF1.OnInterrupt :=
    procedure
    begin
      if VU1Domain.Ahead then
        FAheadThread.Output(VU1Domain.Now, 0, 5)
      else
      begin
        Inc(FDomainSignals);
        Bus.RaiseIRQ(5);
      end;
    end;
  VIF0.OnResume :=
    procedure
    begin
      DMAC.Resume(DMAVIF0);
    end;
  VIF1.OnResume :=
    procedure
    begin
      DMAC.Resume(DMAVIF1);
    end;
  VIF0.Scheduler := Scheduler;
  VIF1.Scheduler := DomainScheduler;
  VIF1.Domain := VU1Domain;
  Bus.VIF0 := VIF0;
  Bus.VIF1 := VIF1;
  VIF0Port := TPS2VIFPort.Create(VIF0);
  VIF1Port := TPS2VIFPort.Create(VIF1);
  DMAC.Ports[DMAVIF0] := VIF0Port;
  DMAC.Ports[DMAVIF1] := VIF1Port;
  IPU := TPS2IPU.Create(Scheduler, DMAC);
  IPU.OnInterrupt :=
    procedure
    begin
      Bus.RaiseIRQ(8);
    end;
  Bus.IPU := IPU;
  IPUPort := TPS2IPUPort.Create(IPU);
  DMAC.Ports[DMAFromIPU] := IPUPort;
  DMAC.Ports[DMAToIPU] := IPUPort;
  Kernel := TPS2Kernel.Create(CPU, Bus, Scheduler);
  Kernel.OnTTY := TTYWrite;
  Kernel.OnLoadExec := LoadExec;
  FDiscFS := TPS2DiscFileSystem.Create(Config.Disc, Config.HostDirectory, Config.Region);
  IOMan := TPS2IOMan.Create(FDiscFS);
  FCDVD := TObjectList<TPS2CDVDServer>.Create(True);
  for var SID in PS2CDVDServerSIDs do
  begin
    var S := TPS2CDVDServer.Create(SID, FDiscFS);
    S.Log := nil;
    S.Clock := @Scheduler.Now;
    FCDVD.Add(S);
  end;
  IOMan.OnTTY := IOPTTY;
  FileIO := TPS2FileIOServer.Create(IOMan);
  // IOP memory above the high-level kernel area and the SIF server buffers
  // (below 4E000h), up to the end of the 2 MiB.
  IOPHeap := TPS2IOPAllocator.Create($00050000, $00200000);
  HeapServer := TPS2IOPHeapServer.Create(IOPHeap, IOMan);
  ModuleLog := TStringList.Create;
  LoadFile := TPS2LoadFileServer.Create(IOMan);
  LoadFile.OnModule := StartModule;
  LoadFile.Log := ModuleLog;
  PadMan := TPS2PadMan.Create(Bus.RAM);
  MemoryCards := TPS2MCServer.Create(Bus.RAM);
  MemoryCards.Clock := @Scheduler.Now;
  IOMan.Cards := TPS2MCDevice.Create(MemoryCards);
  IOP := TPS2IOPKernel.Create(Scheduler, SIF, IOPHeap, IOMan, FDiscFS, Bus.RAM, Bus.IOPRAM);
  IOP.OnTTY := IOPTTY;
  IOP.OnHighLevelModule :=
    procedure(Name: string; Image: TBytes)
    begin
      NoteModuleVersion(Name, Image);
    end;
  IOP.OnModuleDone := ModuleDone;
  IOP.OnMarkEE := Bus.MarkRAM;
  IOP.Hardware.SIO2.PadSource := PadMan;
  IOP.Hardware.SIO2.CardSource := MemoryCards;
  SIF.OnGuestBind := IOP.GuestBind;
  SIF.OnGuestCommand := IOP.GuestCommand;
  LoadFile.ImageReader := IOP.ImageAt;
  RunIOPModules := True;
  // (As polling loops: the turns of a loop that only counts down pass at
  // once, BIOS boot or not.)
  CPU.SkipCountdowns := True;
  if Length(Config.BIOS) = PS2BIOSSize then
    CreateMachine;
  Reset;
end;

// BIOS boot: the BIOS in ROM, no high-level syscalls, the SIF hardware
// between EE DMA channels 5/6 and the IOP, the CDVD drive, and the IOP
// machine sharing the SPU2 and SIO2 with the high-level IOP's hardware.
procedure TPS2Console.CreateMachine;
begin
  Move(FConfig.BIOS[0], Bus.BIOS^, PS2BIOSSize);
  CPU.OnSyscall := nil;
  CPU.OnTrap := nil;
  CPU.SkipSpins := True;
  Bridge := TPS2SIFBridge.Create;
  Bus.SIFBridge := Bridge;
  SIF0Port := TPS2SIF0Port.Create(Bridge);
  SIF1Port := TPS2SIF1Port.Create(Bridge);
  DMAC.Ports[DMASIF0] := SIF0Port;
  DMAC.Ports[DMASIF1] := SIF1Port;
  DMAC.SIF0Chain := True;
  Drive := TPS2CDVDDrive.Create(Scheduler, FConfig.Disc);
  Bus.CDVD := Drive;
  Drive.SetMechacon(FConfig.Mechacon);
  // The Dragon MECHACON (its EEPROM layout) came with the SCPH-50000 and its
  // BIOS 1.70; earlier consoles have the older MECHACON.
  // European consoles start with PAL timing, the others with NTSC; SMODE1
  // switches it later.
  var Version := 0;
  FBIOSPAL := False;
  if TPS2BIOS.IsBIOS(FConfig.BIOS) then
  begin
    var B := TPS2BIOS.Create(FConfig.BIOS);
    try
      Version := StrToIntDef(Copy(B.ROMVER, 1, 4), 0);
      FBIOSPAL := B.RegionLetter = 'E';
    finally
      B.Free;
    end;
  end;
  Drive.SetNVM(FConfig.NVM, Version >= 170);
  // An explicit language setting goes into the console's OSD configuration
  // (the extended languages from BIOS 1.90 on).
  if (FConfig.Language <> TPS2Language.Auto) and ((Ord(FConfig.Language) - 1 < 8) or (Version >= 190)) then
    Drive.SetOSDLanguage(Ord(FConfig.Language) - 1);
  GS.OnVideoMode :=
    procedure(PAL: Boolean)
    begin
      if PAL <> GS.PAL then
      begin
        SetVideo(PAL);
        IOPMachine.SetLineCycles(FLineCycles);
      end;
    end;
  IOPMachine := TPS2IOPMachine.Create(Scheduler, Bus.IOPRAM, Bus.BIOS, IOP.Hardware, Bridge, Drive);
  Bridge.OnEEData :=
    procedure
    begin
      DMAC.Resume(DMASIF0);
    end;
  Bridge.OnEERoom :=
    procedure
    begin
      DMAC.Resume(DMASIF1);
    end;
  Bridge.OnIOPData := IOPMachine.SIFData;
  Bridge.OnIOPRoom := IOPMachine.SIFRoom;
  Drive.OnInterrupt :=
    procedure
    begin
      IOPMachine.RaiseIRQ(IOPIrqCDVD);
    end;
  Drive.OnData := IOPMachine.CDVDData;
  IOP.Hardware.OnInterrupt := IOPMachine.HWInterrupt;
  IOP.Hardware.IOPCycles := @IOPMachine.CPU.Cycles;
  IOPMachine.OnEEInterrupt :=
    procedure
    begin
      Bus.RaiseIRQ(1);
    end;
end;

function TPS2Console.GetBIOSBoot: Boolean;
begin
  Result := IOPMachine <> nil;
end;

destructor TPS2Console.Destroy;
begin
  // (No going back: the domain goes with the console.)
  if (FAheadThread <> nil) and VU1Domain.Ahead then
    AbandonAhead;
  FAheadThread.Free;
  IOPMachine.Free;
  Drive.Free;
  SIF0Port.Free;
  SIF1Port.Free;
  Bridge.Free;
  FileIO.Free;
  LoadFile.Free;
  PadMan.Free;
  MemoryCards.Free;
  IOP.Free;
  HeapServer.Free;
  IOPHeap.Free;
  ModuleLog.Free;
  IOMan.Cards.Free;
  IOMan.Free;
  FCDVD.Free;
  FDiscFS.Free;
  Kernel.Free;
  GIFPort.Free;
  VIF0Port.Free;
  VIF1Port.Free;
  IPUPort.Free;
  IPU.Free;
  VIF0.Free;
  VIF1.Free;
  GIF.Free;
  GS.Free;
  SIF.Free;
  DMAC.Free;
  Timers.Free;
  CPU.Free;
  VU1.Free;
  VU0.Free;
  Bus.Free;
  VU1Domain.Free;
  DomainScheduler.Free;
  Scheduler.Free;
  FTTY.Free;
  inherited;
end;

function TPS2Console.GetHalted: Boolean;
begin
  Result := (IOPMachine = nil) and Kernel.Exited;
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
  Inc(FDomainSignals);
  CPU.SetInt1(Active);
end;

procedure TPS2Console.GSInterrupt;
begin
  Inc(FDomainSignals);
  Bus.RaiseIRQ(0);
end;

function TPS2Console.GSInterruptRaised: Boolean;
begin
  Result := Bus.IRQRaised(0);
end;

// FINISH shows in CSR once the GS has drawn what came before it, and not
// before GSFinishDelay (programs clear CSR events right after starting a
// transfer and then wait for FINISH). Each write shows on its own: programs
// count FINISH interrupts, one per packet they send.
procedure TPS2Console.GSFinishWritten;
begin
  // (On the GIF's GS side, at the time of the work that wrote FINISH.)
  var Due := Max(GIF.CommitNow + GSFinishDelay, GIF.GSBusyUntil);
  if FFinishCount > 0 then
    Due := Max(Due, FFinishDue[FFinishCount - 1]);
  if FFinishCount = Length(FFinishDue) then
  begin
    FFinishDue[FFinishCount - 1] := Due;
    Exit;
  end;
  FFinishDue[FFinishCount] := Due;
  Inc(FFinishCount);
  if FFinishCount = 1 then
    Scheduler.ScheduleAt(TPS2Event.GSSignal, Due);
end;

procedure TPS2Console.GSFinishShown;
begin
  if FFinishCount > 0 then
  begin
    Dec(FFinishCount);
    Move(FFinishDue[1], FFinishDue[0], FFinishCount * SizeOf(Int64));
  end;
  GIF.Join;
  GS.Raster.SetFinish;
  if FFinishCount > 0 then
    Scheduler.ScheduleAt(TPS2Event.GSSignal, FFinishDue[0]);
end;

procedure TPS2Console.SetVideo(PAL: Boolean);
begin
  SetVideoTiming(PAL);
  Timers.SetLineCycles(FLineCycles);
end;

// The field and line timing of PAL or NTSC, except the EE timers' (they
// resynchronize when it changes; snapshots restore their own).
procedure TPS2Console.SetVideoTiming(PAL: Boolean);
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
  Kernel.SetLineCycles(FLineCycles);
  IOP.LineCycles := FLineCycles;
end;

procedure TPS2Console.Reset;
begin
  // (The thread works on what the reset replaces.)
  if (FAheadThread <> nil) and VU1Domain.Ahead then
    StopAhead;
  FAheadRetryAt := 0;
  Scheduler.Reset;
  DomainScheduler.Reset;
  VU1Domain.Reset;
  FFinishCount := 0;
  Bus.Reset;
  CPU.Reset;
  VU1.Reset;
  Timers.Reset;
  DMAC.Reset;
  if IOPMachine <> nil then
  begin
    ResetMachine;
    Exit;
  end;
  DMAC.CTRL := 1;
  SIF.Reset;
  GS.Reset;
  GS.Interlaced := True;
  GIF.Reset;
  VIF0.Reset;
  VIF1.Reset;
  IPU.Reset;
  Kernel.Reset;
  ConfigureOSD;
  IOMan.Reset;
  SetVideo(FConfig.PAL);
  FFrameCount := 0;
  FFieldStart := 0;
  FInVBlank := False;
  FIdleCycles := 0;
  Scheduler.Schedule(TPS2Event.VBlankStart, FVisibleCycles);
  Scheduler.Schedule(TPS2Event.SPU2, SPU2BatchCycles);
  IOP.CPU.Cycles := 0;
  BootIOP;
end;

// BIOS boot: the devices at power-on, the IOP machine at its reset vector,
// the field timing.
procedure TPS2Console.ResetMachine;
begin
  GS.Reset;
  GS.InterlaceFromSMODE2 := True;
  GIF.Reset;
  VIF0.Reset;
  VIF1.Reset;
  IPU.Reset;
  Bridge.Reset;
  Drive.Reset;
  IOP.Hardware.Reset;
  IOPMachine.Reset;
  SetVideo(FBIOSPAL);
  IOPMachine.SetLineCycles(FLineCycles);
  FFrameCount := 0;
  FFieldStart := 0;
  FInVBlank := False;
  FIdleCycles := 0;
  Scheduler.Schedule(TPS2Event.VBlankStart, FVisibleCycles);
  Scheduler.Schedule(TPS2Event.SPU2, SPU2BatchCycles);
end;

procedure TPS2Console.HandleMachineEvent(Event: TPS2Event; At: Int64);
begin
  case Event of
    TPS2Event.VBlankStart:
      begin
        FInVBlank := True;
        Bus.RaiseIRQ(2);
        GS.FrameNumber := FFrameCount + 1;
        GS.VBlank;
        IOPMachine.VBlank(True);
        Scheduler.Schedule(TPS2Event.VBlankEnd, FFieldStart + FFieldCycles);
      end;
    TPS2Event.VBlankEnd:
      begin
        FInVBlank := False;
        Bus.RaiseIRQ(3);
        IOPMachine.VBlank(False);
        FFieldStart := FFieldStart + FFieldCycles;
        Scheduler.Schedule(TPS2Event.VBlankStart, FFieldStart + FVisibleCycles);
      end;
    TPS2Event.Timer0:
      Timers.Event(0);
    TPS2Event.Timer1:
      Timers.Event(1);
    TPS2Event.Timer2:
      Timers.Event(2);
    TPS2Event.Timer3:
      Timers.Event(3);
    TPS2Event.DMAC:
      DMAC.Event;
    TPS2Event.GIF:
      GIF.ReleasePath3;
    TPS2Event.VIF0:
      VIF0.Wake;
    TPS2Event.VIF1:
      VIF1.Wake;
    TPS2Event.IPU:
      IPU.Event;
    TPS2Event.GSSignal:
      GSFinishShown;
    TPS2Event.Compare:
      CPU.CompareReached;
    TPS2Event.IOPTimers:
      IOPMachine.TimerEvent;
    TPS2Event.IOPSync:
      IOPMachine.DMAEvent;
    TPS2Event.IOPDMA:
      IOP.Hardware.Event;
    TPS2Event.CDVD:
      Drive.Event;
    TPS2Event.SPU2:
      begin
        IOP.Hardware.SPU2.Tick(SPU2Batch);
        Scheduler.Schedule(TPS2Event.SPU2, At + SPU2BatchCycles);
      end;
  end;
end;

// One field of the BIOS-booted console: the EE and the IOP in slices.
procedure TPS2Console.RunMachine;
begin
  while True do
  begin
    var Event: TPS2Event;
    var At: Int64;
    while Scheduler.TakeDue(Event, At) do
    begin
      HandleEvent(Event, At);
      if Event = TPS2Event.VBlankStart then
      begin
        Inc(FFrameCount);
        Exit;
      end;
    end;
    RunEE(Min(Scheduler.NextDue, Scheduler.Now + IOPSlice));
    IOPMachine.Run(Scheduler.Now);
  end;
end;

// The OSD configuration games read (GetOsdConfigParam): the non-Japanese
// flag (bit 4), the OSD version (bits 13-15: 1 for OSD2, 2 when the
// language is one of the later ones, which this word reports as English)
// and the language (bits 16-20). The second area (GetOsdConfigParam2) holds
// the region's date and time formats and, with version 2, the language.
procedure TPS2Console.ConfigureOSD;
begin
  var Lang := FConfig.Language;
  if Lang = TPS2Language.Auto then
    if FConfig.Region = TPS2Region.Japan then
      Lang := TPS2Language.Japanese
    else
      Lang := TPS2Language.English;
  var Code := Cardinal(Ord(Lang) - 1);
  var Version: Cardinal := 1;
  var Shown := Code;
  if Code >= 8 then
  begin
    Version := 2;
    Shown := 1;
  end;
  Kernel.OsdConfig := (Cardinal(Ord(Shown <> 0)) shl 4) or (Version shl 13) or (Shown shl 16);
  // Date format (bits 6-7): YYYYMMDD in Japan, MMDDYYYY in America,
  // DDMMYYYY in Europe; 12-hour time (bit 5) in America.
  var Formats: Byte := 0;
  case FConfig.Region of
    TPS2Region.America:
      Formats := (1 shl 6) or (1 shl 5);
    TPS2Region.Europe:
      Formats := 2 shl 6;
  end;
  if Version = 2 then
    Kernel.SetOsdConfig2([0, Formats, 2, Byte(Code)])
  else
    Kernel.SetOsdConfig2([0, Formats]);
end;

procedure TPS2Console.BootIOP;
begin
  FileIO.Reset;
  IOP.Reset;
  PadMan.Reset;
  MemoryCards.Reset;
  IOPHeap.Reset;
  AddIOPServers;
  SIF.IOPBooted;
end;

// The high-level servers in their fixed order (snapshots rely on it).
procedure TPS2Console.AddIOPServers;
begin
  SIF.RemoveServers;
  SIF.AddServer(FileIO);
  SIF.AddServer(HeapServer);
  SIF.AddServer(LoadFile);
  for var S in FCDVD do
    SIF.AddServer(S);
  PadMan.AddServers(SIF);
  SIF.AddServer(MemoryCards);
end;

// The pad and memory card managers report the version of the module the
// game loads (libpad and libmc ask for it).
procedure TPS2Console.NoteModuleVersion(const Path: string; const Image: TBytes);
begin
  var Device, P: string;
  TPS2IOMan.SplitPath(Path, Device, P);
  var Base := ExtractFileName(P.Replace('/', '\')).ToUpper;
  if Base.EndsWith('.IRX') then
    Base := Base.Substring(0, Length(Base) - 4);
  if (Base <> 'PADMAN') and (Base <> 'XPADMAN') and (Base <> 'MCSERV') and (Base <> 'XMCSERV') and
    (Base <> 'MCMAN') and (Base <> 'XMCMAN') then
    Exit;
  var Data := Image;
  if Data = nil then
    Data := FDiscFS.ReadFile(Device, P);
  var Info: TIRXInfo;
  if (Data = nil) or not ParseIRX(Data, Info) then
    Exit;
  if Base.EndsWith('PADMAN') then
    PadMan.Version := Info.Version
  else if Base.EndsWith('MCSERV') then
    MemoryCards.ServVersion := Info.Version
  else
    MemoryCards.ManVersion := Info.Version;
end;

function TPS2Console.StartModule(Server: TPS2LoadFileServer; const Path: string; const Image, Args: TBytes; out ModResult: Integer): Integer;
begin
  ModResult := 0;
  // The high-level IOP provides the system modules; game modules run as IOP
  // code and answer once their start routine returned.
  if Path <> '' then
    NoteModuleVersion(Path, Image);
  var Data := Image;
  if (Data = nil) and (Path <> '') and not IOP.IsHLEModule(Path, '') then
  begin
    var Device, P: string;
    TPS2IOMan.SplitPath(Path, Device, P);
    if not SameText(Device, 'rom0') then
      Data := FDiscFS.ReadFile(Device, P);
  end;
  if not RunIOPModules or (Data = nil) then
  begin
    if IOP.IsAbsentDevice(Path, '') then
      ModResult := 1;
    Exit(1000 + ModuleLog.Count);
  end;
  var Info: TIRXInfo;
  if not ParseIRX(Data, Info) then
    Exit(-201);
  if IOP.IsHLEModule(Path, Info.Name) then
  begin
    if IOP.IsAbsentDevice(Path, Info.Name) then
      ModResult := 1;
    Exit(1000 + ModuleLog.Count);
  end;
  var Index := IOP.LoadModule(Data, Path);
  if Index <= 0 then
    Exit(Index);
  var Name := Path;
  if Name = '' then
    Name := Info.Name;
  IOP.StartModule(Index, Name, Args, Server.DeferCall, 0, 0);
  Result := Index;
end;

procedure TPS2Console.ModuleDone(const Token: TBytes; ModuleId, Result: Integer);
begin
  LoadFile.FinishModule(Token, ModuleId, Result);
end;

procedure TPS2Console.VUCodeWritten(Index: Integer);
begin
  if Index = 0 then
    VU0.Core.NoteCodeWritten
  else
    VU1.Core.NoteCodeWritten;
end;

procedure TPS2Console.StartVU1(Address: Cardinal);
begin
  // CMSAR1 holds a 16-bit instruction address.
  VU1Domain.Enter;
  try
    VU1.Core.Start((Address and $FFFF) * 8);
    VU1.Core.RunProgram(VU1Domain.Now, 4000000);
  finally
    VU1Domain.Leave;
  end;
end;

procedure TPS2Console.VU1Kick(Address: Cardinal; Data: PByte);
begin
  if (GIF.TagLog <> nil) and (GIF.TagLog.Count < 200000) then
    GIF.TagLog.Add(Format('xgkick %x pc %x', [Address, VU1.Core.S.TPC]));
  GIF.KickPacket(Data);
end;

// The IOP module set an IOP reset loads (IOPRP/DNAS image): its FILEIO
// version string, else the number in the image's name.
function TPS2Console.ImageVersion(const ResetArgs: string): Integer;
begin
  Result := 1000;
  var Parts := ResetArgs.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) < 2 then
    Exit;
  var Device, Path: string;
  TPS2IOMan.SplitPath(Parts[1], Device, Path);
  var Data := FDiscFS.ReadFile(Device, Path);
  if Data <> nil then
  begin
    var Text := TEncoding.ANSI.GetString(Data);
    var P := Text.IndexOf('PsIIfileio  ');
    if P >= 0 then
    begin
      var V := StrToIntDef(Text.Substring(P + 12, 4), 0);
      if V >= 1000 then
        Exit(V);
    end;
  end;
  var Name := ExtractFileName(Path.Replace('/', '\')).ToUpper;
  for var Prefix in ['IOPRP', 'DNAS'] do
    if Name.StartsWith(Prefix) then
    begin
      var Digits := '';
      for var Ch in Name.Substring(Length(Prefix)) do
        if CharInSet(Ch, ['0'..'9']) then
          Digits := Digits + Ch
        else
          Break;
      var V := StrToIntDef(Digits, 0);
      if V > 0 then
      begin
        if V < 100 then
          Exit(V * 100);
        Exit(V * 10);
      end;
    end;
end;

procedure TPS2Console.IOPReset(const Args: string);
begin
  // The IOP restarts with the modules of the reset string; it answers again
  // (servers, boot flags) once it has booted.
  SIF.RemoveServers;
  SIF.EERecvAddr := 0;
  SIF.SMCOM := 0;
  ModuleLog.Add('IOP reset: ' + Args);
  FileIO.Version := ImageVersion(Args);
  Scheduler.Schedule(TPS2Event.IOPSync, Scheduler.Now + PS2EEClock div 100);
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

procedure TPS2Console.LoadIOPModule(const Data: TBytes; const Name: string);
begin
  var Index := IOP.LoadModule(Data, Name);
  if Index <= 0 then
    raise EReadError.CreateFmt('IOP module %s did not load (%d)', [Name, Index]);
  IOP.StartModule(Index, Name, nil, nil, 0, 0);
end;

function TPS2Console.BootDisc: Boolean;
begin
  var Info: TPS2DiscInfo;
  if (FConfig.Disc = nil) or not ReadPS2DiscInfo(FConfig.Disc, Info) then
    Exit(False);
  if Info.VMode = 'PAL' then
    SetVideo(True);
  LoadExec(Info.Boot2, nil);
  Result := FProgram <> nil;
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

// Events reaching the VU1 domain (the GS at VBlank start and when FINISH
// shows) run inside it at the EE time.
procedure TPS2Console.HandleEvent(Event: TPS2Event; At: Int64);
begin
  if not (Event in [TPS2Event.VBlankStart, TPS2Event.GSSignal]) then
  begin
    HandleEventHere(Event, At);
    Exit;
  end;
  var Entered := VU1Domain.EnterKind(deGS);
  // Only this outermost event restores the actual saved caller word. Its
  // non-BIOS tail updates pad RAM, queues IOP notifications and an integer
  // deadline. A GS IRQ or a kernel vsync write excludes this handoff.
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  var Scoped :=
    (Event = TPS2Event.VBlankStart)
    and Entered
    and (VU1Domain.Depth = 1)
    and (IOPMachine = nil)
    and (Kernel <> nil)
    and (Kernel.PendingVSyncWrite = 0)
    and ((GS.IMR and $1F00) = $1F00);
  var Expected: Cardinal := 0;
  if Scoped then
    Expected := VU1Domain.SavedHostWord;
{$ELSE}
  const Scoped = False;
{$ENDIF}
  var Previous := GS.ClosedDisplayScope;
  GS.ClosedDisplayScope := Scoped;
  try
    HandleEventHere(Event, At);
  finally
    GS.ClosedDisplayScope := Previous;
    if Entered then
      VU1Domain.Leave;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
    if Scoped and (ReadHostMXCSR <> Expected) then
      raise Exception.Create('Lost enclosing domain host status');
{$ENDIF}
  end;
end;

// The VU1 domain's events due by T, in time order (ties: DMAC, GIF, VIF1),
// each at its own time.
procedure TPS2Console.CatchUpDomain(T: Int64);
begin
  while DomainScheduler.NextDue <= T do
    RunDomainEvent;
end;

// The VU1 domain's earliest event, at its time.
procedure TPS2Console.RunDomainEvent;
begin
  var Event := TPS2Event.DMAC;
  var At := DomainScheduler.Due(TPS2Event.DMAC);
  for var E in [TPS2Event.GIF, TPS2Event.VIF1] do
    if DomainScheduler.Due(E) < At then
    begin
      Event := E;
      At := DomainScheduler.Due(E);
    end;
  DomainScheduler.Cancel(Event);
  VU1Domain.EnterEvent(At);
  try
    case Event of
      TPS2Event.DMAC:
        DMAC.Event(True);
      TPS2Event.GIF:
        GIF.ReleasePath3;
      TPS2Event.VIF1:
        VIF1.Wake;
    end;
  finally
    VU1Domain.Leave;
  end;
end;

// Leaving the VU1 domain: its events may be due earlier now, the EE stops for
// them.
procedure TPS2Console.DomainLeft;
begin
  if VU1Domain.Ahead then
    Exit;
  // (With an end of a channel the EE side holds.)
  var Stop := NextDomainStop;
  if Stop < Scheduler.Deadline then
    Scheduler.Deadline := Stop;
end;

// Where the EE next stops for the VU1 domain: its next event, or running
// ahead the time it is complete up to; and what it handed the EE side
// (outputs, GS work, a question).
function TPS2Console.NextDomainStop: Int64;
begin
  if VU1Domain.Ahead then
    Result := Min(FAheadThread.Complete, FAheadThread.RequestTime)
  else
    Result := DomainScheduler.NextDue;
  if FAheadThread <> nil then
    Result := Min(Min(Result, DMAC.PortEnd), Min(Min(FAheadThread.OutputHead, GIF.WorkHead), FAheadThread.ReadHead));
end;

function TPS2Console.CanGoAhead: Boolean;
begin
  // While channel 1 runs from memory (the domain then only reads memory),
  // without stall control, with events of the domain due.
  Result :=
    (FAheadThread <> nil)
    and not VU1Domain.Ahead
    and ((Scheduler.Now >= FAheadRetryAt) or not VU1.Core.UseJit)
    and (VU1Domain.Depth = 0)
    and ((DMAC.Ch[DMAVIF1].CHCR and CHCRSTR) <> 0)
    and ((DMAC.Ch[DMAVIF1].CHCR and CHCRDir) <> 0)
    and not DMAC.PortOnEE[DMAVIF1]
    and ((DMAC.CTRL and $F0) = 0)
    and (GIF.TagLog = nil)
    and (DomainScheduler.NextDue <> PS2Never);
end;

procedure TPS2Console.StartAhead;
begin
  CatchUpDomain(Scheduler.Now);
  for var N := DMAVIF1 to DMAGIF do
    DMAC.PortEndedAt[N] := PS2Never;
  SaveDomain(FCheckpoint);
  FAheadThread.TakenUpTo := Scheduler.Now;
  PostView(Scheduler.Now);
  VU1Domain.Ahead := True;
  GIF.Ahead := True;
  FAheadThread.Go(DomainScheduler.NextDue, VU1Domain.Now);
end;

// The EE takes the domain back. One that went past the EE's time (an access
// reached it there), or read memory that has changed since, goes back to
// where it went ahead and does its events up to there again (RollBack).
procedure TPS2Console.StopAhead;
begin
  if not VU1Domain.Ahead then
    Exit;
  var Failure := '';
  var Sound := False;
  // (What the thread still does is past the EE's time: none of it is taken.)
  FAheadThread.Quieten;
  GIF.Discard(True);
  try
    FAheadThread.Pause(
      procedure
      begin
        ServeAhead(Scheduler.Now);
        StoreShared(FViewDone, LoadShared(FViewPosted));
      end);
    // (What the last event posted: the thread may have parked after the last
    // serving.)
    ServeAhead(Scheduler.Now);
    Failure := FAheadThread.TakeFailure;
    if Failure = '' then
    begin
      var Applied := Scheduler.Now;
      var Conflict := FAheadThread.ConflictAt <= Applied;
      if Conflict then
      begin
        Applied := FAheadThread.ConflictAt - 1;
      end;
      if FAheadThread.Last > Applied then
      begin
        var InitialPairs := FCheckpoint.VU1.Core.Executed;
        var SpeculativePairs := VU1.Core.Executed - InitialPairs;
        RollBack(Applied);
        // Repeated conflicts can make the JIT run the same long VU1 program
        // twice. Let the EE run it inline before probing for overlap again.
        if Conflict and FAheadAdaptive and VU1.Core.UseJit then
        begin
          var ReplayedPairs := VU1.Core.Executed - InitialPairs;
          if (ReplayedPairs >= VU1ReplayMinPairs) and (ReplayedPairs >= SpeculativePairs div 2) then
            FAheadRetryAt := Scheduler.Now + VU1ReplayCooldown;
        end;
      end;
      Sound := True;
    end;
  finally
    // (Failed, here or on the thread: the session is given up as it is.)
    if Sound then
      EndAhead
    else
      AbandonAhead;
  end;
  if Failure <> '' then
    raise Exception.Create('VU1 thread: ' + Failure);
end;

// The session ends (parked thread): the domain is the EE side's again.
procedure TPS2Console.EndAhead;
begin
  FAheadThread.EndSession;
  GIF.Discard(False);
  FViewDone := FViewPosted;
  VU1Domain.Ahead := False;
  GIF.Ahead := False;
end;

// The session is given up: the thread parks, nothing more is taken from it
// and nothing done again (the console goes, or taking the domain back
// failed).
procedure TPS2Console.AbandonAhead;
begin
  FAheadThread.Quieten;
  GIF.Discard(True);
  FAheadThread.Pause(
    procedure
    begin
      StoreShared(FViewDone, LoadShared(FViewPosted));
    end);
  FAheadThread.TakeFailure;
  // (Work not done yet may read the session's copies.)
  GIF.DropWork;
  EndAhead;
end;

procedure TPS2Console.SaveDomain(var C: TPS2DomainCheckpoint);
begin
  C.Now := VU1Domain.Now;
  DomainScheduler.Save(C.Scheduler);
  for var N := DMAVIF1 to DMAGIF do
  begin
    C.Ch[N] := DMAC.Ch[N];
    C.Moved[N] := DMAC.Moved[N];
    C.PortOnEE[N] := DMAC.PortOnEE[N];
    C.PortEndAt[N] := DMAC.PortEndAt[N];
    C.DrainWaiting[N] := DMAC.DrainWaiting[N];
  end;
  VIF1.SaveDomain(C.VIF);
  VU1.SaveDomain(C.VU1);
  GIF.SaveDomain(C.GIF);
  Move(Bus.VU1Code^, C.Code, SizeOf(C.Code));
  Move(Bus.VU1Data^, C.Data, SizeOf(C.Data));
end;

procedure TPS2Console.RestoreDomain(const C: TPS2DomainCheckpoint);
begin
  VU1Domain.Now := C.Now;
  DomainScheduler.Restore(C.Scheduler);
  for var N := DMAVIF1 to DMAGIF do
  begin
    DMAC.Ch[N] := C.Ch[N];
    DMAC.Moved[N] := C.Moved[N];
    DMAC.PortOnEE[N] := C.PortOnEE[N];
    DMAC.PortEndAt[N] := C.PortEndAt[N];
    DMAC.DrainWaiting[N] := C.DrainWaiting[N];
  end;
  VIF1.RestoreDomain(C.VIF);
  Move(C.Code, Bus.VU1Code^, SizeOf(C.Code));
  Move(C.Data, Bus.VU1Data^, SizeOf(C.Data));
  VU1.RestoreDomain(C.VU1);
  GIF.RestoreDomain(C.GIF);
end;

// Going back (parked thread): the domain does its events up to Applied again
// from where it went ahead, with the session's copies and answers, handing
// the EE side nothing again (it has taken all of that up to Applied and
// nothing past it); a channel it handed to the EE side by then stays as the
// EE side has it.
procedure TPS2Console.RollBack(Applied: Int64);
var
  Ch: array[DMAVIF1..DMAGIF] of TPS2DMAChannel;
  OnEE: array[DMAVIF1..DMAGIF] of Boolean;
  EndAt: array[DMAVIF1..DMAGIF] of Int64;
begin
  FAheadThread.DropOutputs;
  GIF.DropWork;
  for var N := DMAVIF1 to DMAGIF do
  begin
    Ch[N] := DMAC.Ch[N];
    OnEE[N] := DMAC.PortOnEE[N];
    EndAt[N] := DMAC.PortEndAt[N];
  end;
  RestoreDomain(FCheckpoint);
  FAheadThread.BeginReplay;
  GIF.Replaying := True;
  VU1Domain.Replaying := True;
  try
    while DomainScheduler.NextDue <= Applied do
    begin
      if ((DMAC.Ch[DMAVIF1].CHCR and CHCRSTR) = 0) or DMAC.PortOnEE[DMAVIF1] then
        raise EPS2Replay.Create('VU1 replay: channel 1 ended before the session did');
      RunDomainEvent;
    end;
    FAheadThread.EndReplay(Applied);
  finally
    GIF.Replaying := False;
    VU1Domain.Replaying := False;
  end;
  for var N := DMAVIF1 to DMAGIF do
    if DMAC.PortOnEE[N] then
    begin
      DMAC.PortOnEE[N] := OnEE[N];
      DMAC.PortEndAt[N] := EndAt[N];
      DMAC.Ch[N].DoneAt := Ch[N].DoneAt;
      DMAC.Ch[N].Finishing := Ch[N].Finishing;
      DMAC.Ch[N].CHCR := (DMAC.Ch[N].CHCR and not Cardinal(CHCRSTR)) or (Ch[N].CHCR and CHCRSTR);
    end;
end;

const
  FastViewRetire = True;

procedure TPS2Console.RetireViews(T: Int64; SkipUnchanged: Boolean);
begin
  if FViewDone < LoadShared(FViewPosted) then
  begin
    var Index := ViewIndex(T);

    // Only a changed index releases slots. Publishing the same retained
    // view again gives the producer no new ownership or ordering fact.
{$IFDEF CPUX64}
    if not SkipUnchanged or (Index <> FViewDone) then
{$ENDIF}
    begin
      StoreShared(FViewDone, Index);
    end;
  end;
end;

// Running ahead: until the domain is complete past T (its outputs up to T
// applied), or it stopped.
procedure TPS2Console.WaitDomain(T: Int64);
begin
  while VU1Domain.Ahead do
  begin
    // (Before serving: complete past T, the domain has posted all its events
    // up to T hand over, and serving takes or refuses all of it.)
    var Done := (FAheadThread.Complete > T) and (FAheadThread.RequestTime > T);
    ServeAhead(T);
    // A parked thread hands the domain back once the EE has reached the last
    // event it ran (until then the EE reads what that left) or what it is
    // complete up to, a read whose copy differs from memory takes it back;
    // the domain catches up from there.
    if (FAheadThread.ConflictAt <> PS2Never)
      or FAheadThread.Parked and ((FAheadThread.Last <= T) or (FAheadThread.Complete <= T) or FAheadThread.Failed) then
    begin
      StopAhead;
      CatchUpDomain(T);
      Break;
    end;
    if Done then
      Break;
    YieldProcessor;
  end;
  // (Taken back: what catching up handed over, ends the EE side holds.)
  if not VU1Domain.Ahead then
    ServeAhead(T);
end;

procedure TPS2Console.ServeAhead(UpTo: Int64);
begin
  // What the domain read up to UpTo, against memory as the EE has it there
  // (nothing is taken from a read whose copy differs on: it goes back).
  FAheadThread.CheckReads(UpTo);
  if FAheadThread.ConflictAt <= UpTo then
    UpTo := FAheadThread.ConflictAt - 1;
  if UpTo > FAheadThread.TakenUpTo then
    FAheadThread.TakenUpTo := UpTo;
  FAheadThread.TakeOutputs(UpTo, ApplyOutput);
  GIF.CommitTo(UpTo);
  FAheadThread.ServeRequest(UpTo, AnswerAhead);
  if DMAC.PortEnd <= UpTo then
    DMAC.EndPorts(UpTo);
  RetireViews(UpTo, FastViewRetire);
end;

// Domain thread (or the EE side starting it): the registers the EE may read
// from Time on.
procedure TPS2Console.PostView(Time: Int64);
begin
  var Rounds := 0;
  while FViewPosted - LoadShared(FViewDone) >= Length(FViews) do
    WaitRound(Rounds);
  var V := PPS2DomainView(@FViews[FViewPosted and High(FViews)]);
  V.Time := Time;
  // (PortOnEE first: the EE side clears STR before it.)
  for var N := DMAVIF1 to DMAGIF do
    V.PortOnEE[N] := DMAC.PortOnEE[N];
  V.Ch[DMAVIF1] := DMAC.Ch[DMAVIF1];
  V.Ch[DMAGIF] := DMAC.Ch[DMAGIF];
  VIF1.GetRegisters(V.VIF);
  V.VU1Running := VU1.Core.S.Running;
  V.VU1BusyUntil := VU1.Core.S.BusyUntil;
  V.MaskedPath3 := GIF.MaskedPath3;
  for var N := DMAVIF1 to DMAGIF do
    V.DrainWaiting[N] := DMAC.DrainWaiting[N];
  StoreShared(FViewPosted, FViewPosted + 1);
end;

// The last view up to T (from the one kept).
function TPS2Console.ViewIndex(T: Int64): Int64;
begin
  var Posted := LoadShared(FViewPosted);
  Result := FViewDone;
  while (Result + 1 < Posted) and (FViews[(Result + 1) and High(FViews)].Time <= T) do
    Inc(Result);
end;

{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
function TPS2Console.ViewAt(T: Int64): PPS2DomainView;
begin
  if FViewDone >= LoadShared(FViewPosted) then
    Exit(nil);
  Result := @FViews[ViewIndex(T) and High(FViews)];
  if Result.Time > T then
    Result := nil;
end;

// Running ahead, the EE reads a register of channel 1 or 2, VIF1 or the GIF
// as the domain had it at the EE time.
function TPS2Console.ReadAheadRegister(Address: Cardinal; out Value: UInt64): Boolean;
begin
  var V := ViewAt(Scheduler.Now);
  if V = nil then
    Exit(False);
  Result := True;
  case Address of
    $10003000..$100037FF:
      Value := GIF.ReadRegister(Address, V.MaskedPath3);
    $10003C00..$10003FFF:
      Value := TPS2VIF.RegisterValue(V.VIF, 1, Address and $1F0, V.VU1Running or (Scheduler.Now < V.VU1BusyUntil));
  else
    begin
      var N := DMAVIF1;
      if (Address and $F000) = $A000 then
        N := DMAGIF;
      var R := TPS2DMAC.ChannelRegister(V.Ch[N], Address and $FC);
      // A channel whose end the EE side has: ended once it passed.
      if ((Address and $FC) = 0) and V.PortOnEE[N] and (DMAC.PortEndedAt[N] <= Scheduler.Now) then
        R := R and not Cardinal(CHCRSTR);
      Value := R;
    end;
  end;
end;

function TPS2Console.AheadVU1Busy(out Busy: Boolean): Boolean;
begin
  var V := ViewAt(Scheduler.Now);
  Result := V <> nil;
  if Result then
  begin
    Busy := V.VU1Running or (Scheduler.Now < V.VU1BusyUntil);
  end;
end;

function TPS2Console.AheadCopy(Key: Integer; Source: PByte; Size: Integer; out Token: Int64): PByte;
begin
  Result := FAheadThread.ReadCopy(Key, VU1Domain.Now, Source, Size, Token);
end;

procedure TPS2Console.AheadCopyUsed(Token: Int64; Used: Integer);
begin
  FAheadThread.ReadUsed(Token, Used);
end;

function TPS2Console.AheadLimit(Key: Integer; Source: PByte; Count: Integer): Integer;
begin
  Result := FAheadThread.ReadLimit(Key, Source, Count);
end;

function TPS2Console.AheadCheck(Source: PCardinal; Mask, Offset, Value: Cardinal; Decided: Boolean): Boolean;
begin
  Result := FAheadThread.PostCheck(VU1Domain.Now, Source, Mask, Offset, Value, Decided);
end;

// Running ahead, the EE side has channel N of the domain try again at its
// time (fromSPR filled the MFIFO ring, a write to the DMAC's shared
// registers). A channel that waits for its device finds it as it left it;
// what trying again still does is done here, from the view at that time:
// the drain on the still empty ring raises MEIS again, PATH3 taking nothing
// brings the GS side's time up to the EE's. For anything else the domain is
// entered (it goes back if it is past that time) and the channel goes on.
procedure TPS2Console.AheadResume(N: Integer);
begin
  var T := Scheduler.Now;
  var V := ViewAt(T);
  if V <> nil then
  begin
    if ((V.Ch[N].CHCR and CHCRSTR) = 0) or V.Ch[N].Finishing or ((DMAC.CTRL and 1) = 0) then
      Exit;
    if V.DrainWaiting[N] then
    begin
      if DMAC.RingEmptyAt(V.Ch[N].TADR) then
      begin
        DMAC.SetStat($4000);
        Exit;
      end;
    end
    else if N = DMAVIF1 then
      Exit
    else if FAheadThread.ConflictAt = PS2Never then
    begin
      GIF.GSBusyCyclesAt(T);
      Exit;
    end;
  end;
  VU1Domain.Enter;
  try
    DMAC.Resume(N);
  finally
    VU1Domain.Leave;
  end;
end;

// The EE reached its deadline inside RunEE. When only the domain's reads were
// due there (checked now) and RunEE would go on at once, the EE goes on to the
// next deadline without leaving its run.
function TPS2Console.EEDeadline: Boolean;
begin
  Result := False;
  var T := Scheduler.Now;
  // (Not lowered meanwhile, no limit or event of the EE's own.)
  if not VU1Domain.Ahead or (Scheduler.Deadline <> FRunStop) or (T >= FRunLimit) or (Scheduler.NextDue <= T) then
    Exit;
  // (Nothing to wait for, take or hand back.)
  if (FAheadThread.Complete <= T)
    or (FAheadThread.RequestTime <= T)
    or (FAheadThread.OutputHead <= T)
    or (GIF.WorkHead <= T)
    or (DMAC.PortEnd <= T)
    or FAheadThread.Parked and (FAheadThread.Last <= T) then
    Exit;
  FAheadThread.CheckReads(T);
  if FAheadThread.ReadHead <= T then
    Exit;
  RetireViews(T, FastViewRetire);
  var D := Min(Min(FRunLimit, Scheduler.NextDue), NextDomainStop);
  if D <= T then
    Exit;
  Scheduler.Deadline := D;
  FRunStop := D;
  Result := True;
end;

{$ENDIF}
procedure TPS2Console.ApplyOutput(Kind: Integer; Value: Cardinal);
begin
  case Kind of
    0:
      begin
        Inc(FDomainSignals);
        Bus.RaiseIRQ(Value);
      end;
    1:
      DMAC.SetStat(Value);
  end;
end;

function TPS2Console.AnswerAhead(Kind: Integer; Time: Int64): Int64;
begin
  if Kind = 1 then
  begin
    GIF.CommitTo(Time);
    Result := GIF.TakePortCyclesHere;
  end
  else
    Result := GIF.GSBusyCyclesAt(Time);
end;

{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
// The VU1 thread's step: one domain event; done once channel 1 ended.
function TPS2Console.AheadStep: TPS2AheadStep;
begin
  if ((DMAC.Ch[DMAVIF1].CHCR and CHCRSTR) = 0) or DMAC.PortOnEE[DMAVIF1] or FAheadThread.SessionFull then
    Exit(asEnd);
  var At := DomainScheduler.NextDue;
  if At = PS2Never then
    Exit(asIdle);
  RunDomainEvent;
  PostView(At);
  FAheadThread.Publish(DomainScheduler.NextDue, At);
  Result := asDone;
end;

{$ENDIF}
// The EE up to Limit (an event of its own, the IOP slice). It stops for the
// VU1 domain's events too, which then run, and goes on: those stops do not
// let the IOP or the scheduler run (they come only at the EE's own stops).
procedure TPS2Console.RunEE(Limit: Int64);
begin
  while True do
  begin
    if VU1Domain.Ahead then
      WaitDomain(Scheduler.Now)
    else if CanGoAhead then
      StartAhead;
    // (With the scheduler's next event: one scheduled since the caller
    // took its limit, while the EE ran.)
    Scheduler.Deadline := Min(Min(Limit, Scheduler.NextDue), NextDomainStop);
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
    FRunLimit := Limit;
    FRunStop := Scheduler.Deadline;
{$ENDIF}
    CPU.Run;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
    FRunStop := -1;
{$ENDIF}
    if VU1Domain.Ahead then
      WaitDomain(Scheduler.Now)
    else
    begin
      CatchUpDomain(Scheduler.Now);
      if FAheadThread <> nil then
        ServeAhead(Scheduler.Now);
    end;
    // An exit request, an event of the EE's own or the limit: done. (Not by
    // where the EE stopped: the domain's stops are not the same with its
    // thread running ahead.)
    if CPU.ExitTaken or (Scheduler.Now >= Limit) or (Scheduler.NextDue <= Scheduler.Now) then
      Exit;
  end;
end;

// The EE waits (its kernel idles) up to Limit; the VU1 domain's events run
// meanwhile, and one that interrupts the EE ends the wait there.
procedure TPS2Console.IdleTo(Limit: Int64);
begin
  while Scheduler.Now < Limit do
  begin
    if VU1Domain.Ahead then
      WaitDomain(Scheduler.Now);
    var T := Min(Min(Limit, Scheduler.NextDue), NextDomainStop);
    if T < Scheduler.Now then
      T := Scheduler.Now;
    Inc(FIdleCycles, T - Scheduler.Now);
    Scheduler.Now := T;
    var Signals := FDomainSignals;
    if VU1Domain.Ahead then
      WaitDomain(T)
    else
    begin
      CatchUpDomain(T);
      if FAheadThread <> nil then
        ServeAhead(T);
    end;
    if FDomainSignals <> Signals then
      Exit;
    // (An event of the EE's own came with the domain's work: FINISH shown.)
    if Scheduler.NextDue <= Scheduler.Now then
      Exit;
  end;
end;

procedure TPS2Console.HandleEventHere(Event: TPS2Event; At: Int64);
begin
  if IOPMachine <> nil then
  begin
    HandleMachineEvent(Event, At);
    Exit;
  end;
  case Event of
    TPS2Event.VBlankStart:
      begin
        FInVBlank := True;
        Bus.RaiseIRQ(2);
        GS.FrameNumber := FFrameCount + 1;
        GS.VBlank;
        PadMan.Update;
        IOP.VBlank(True);
        Kernel.VBlankStart(GS.OddField);
        Scheduler.Schedule(TPS2Event.VBlankEnd, FFieldStart + FFieldCycles);
      end;
    TPS2Event.VBlankEnd:
      begin
        FInVBlank := False;
        Bus.RaiseIRQ(3);
        IOP.VBlank(False);
        FFieldStart := FFieldStart + FFieldCycles;
        Scheduler.Schedule(TPS2Event.VBlankStart, FFieldStart + FVisibleCycles);
      end;
    TPS2Event.Timer0:
      Timers.Event(0);
    TPS2Event.Timer1:
      Timers.Event(1);
    TPS2Event.Timer2:
      Timers.Event(2);
    TPS2Event.Timer3:
      Timers.Event(3);
    TPS2Event.DMAC:
      DMAC.Event;
    TPS2Event.GIF:
      GIF.ReleasePath3;
    TPS2Event.VIF0:
      VIF0.Wake;
    TPS2Event.VIF1:
      VIF1.Wake;
    TPS2Event.IPU:
      IPU.Event;
    TPS2Event.GSSignal:
      GSFinishShown;
    TPS2Event.SIF:
      SIF.Deliver;
    TPS2Event.Alarm:
      Kernel.AlarmEvent;
    TPS2Event.Compare:
      CPU.CompareReached;
    TPS2Event.IOPSync:
      BootIOP;
    TPS2Event.IOPTimers:
      IOP.TimerEvent;
    TPS2Event.IOPDMA:
      IOP.Hardware.Event;
    TPS2Event.SPU2:
      begin
      // 48 kHz output in batches (6144 EE cycles a sample).
        IOP.Hardware.SPU2.Tick(SPU2Batch);
        Scheduler.Schedule(TPS2Event.SPU2, At + SPU2BatchCycles);
      end;
  end;
end;

procedure TPS2Console.RunFrame;
begin
  if IOPMachine <> nil then
  begin
    RunMachine;
    Exit;
  end;
  // One field: until the next VBlank start has been handled.
  while True do
  begin
    var Event: TPS2Event;
    var At: Int64;
    while Scheduler.TakeDue(Event, At) do
    begin
      HandleEvent(Event, At);
      if Event = TPS2Event.VBlankStart then
      begin
        Inc(FFrameCount);
        Exit;
      end;
    end;
    var Limit := Scheduler.NextDue;
    // IOP code runs in slices behind the EE.
    var IOPActive := IOP.Active;
    if IOPActive and (Limit > Scheduler.Now + IOPSlice) then
      Limit := Scheduler.Now + IOPSlice;
    if Kernel.Exited then
    begin
      StopAhead;
      Scheduler.Now := Limit;
      CatchUpDomain(Scheduler.Now);
      Continue;
    end;
    if Kernel.Idle then
    begin
      // Nothing runs on the EE until the next event (or an interrupt from
      // the VU1 domain).
      IdleTo(Limit);
      Kernel.Idle := False;
      IOP.Run(Scheduler.Now);
      Continue;
    end;
    RunEE(Limit);
    IOP.Run(Scheduler.Now);
  end;
end;

procedure TPS2Console.SetCDVDLog(Log: TStrings);
begin
  for var S in FCDVD do
    S.Log := Log;
end;

class function TPS2Console.SnapshotPolicy: TSnapshotPolicy;
begin
  // 32 MiB of EE RAM plus GS, IOP, SPU2 memory and both memory cards.
  Result := TSnapshotPolicy.Create(PS2SnapshotVersion, 128 * 1024 * 1024);
  Result.VersionError := 'This PS2 snapshot uses state format %d, but this build uses format %d. ' +
    'Load it with the build that created it, or continue from an in-game save.';
  Result.IdentityError := 'This PS2 snapshot belongs to a different disc or program. ' +
    'Load the disc or program used to save it.';
end;

procedure TPS2Console.SerializeState(State: TStateArchive);
begin
  if State.Loading then
  begin
    // (The thread works on what the snapshot replaces.)
    if (FAheadThread <> nil) and VU1Domain.Ahead then
      StopAhead;
    VU1Domain.EnterRestore;
  end
  else
  begin
    VU1Domain.Enter;
  end;
  try
    SerializeStateHere(State);
  finally
    VU1Domain.Leave;
  end;
end;

procedure TPS2Console.SerializeStateHere(State: TStateArchive);
begin
  // The VU1 domain's events go in the scheduler's VIF1, GIF and DMAC slots
  // (the layout before the domain had its own).
  var Kept: array[0..2] of Int64;
  if not State.Loading then
  begin
    Kept[0] := Scheduler.Due(TPS2Event.VIF1);
    Kept[1] := Scheduler.Due(TPS2Event.GIF);
    Kept[2] := Scheduler.Due(TPS2Event.DMAC);
    Scheduler.ScheduleAt(TPS2Event.VIF1, DomainScheduler.Due(TPS2Event.VIF1));
    Scheduler.ScheduleAt(TPS2Event.GIF, DomainScheduler.Due(TPS2Event.GIF));
    // (With the ends of channels the EE side holds: their events too.)
    Scheduler.ScheduleAt(TPS2Event.DMAC, Min(Min(Kept[2], DomainScheduler.Due(TPS2Event.DMAC)), DMAC.PortEnd));
  end;
  Scheduler.SerializeState(State);
  if not State.Loading then
  begin
    Scheduler.ScheduleAt(TPS2Event.VIF1, Kept[0]);
    Scheduler.ScheduleAt(TPS2Event.GIF, Kept[1]);
    Scheduler.ScheduleAt(TPS2Event.DMAC, Kept[2]);
  end
  else
  begin
    // (The domain caught up with the EE when the snapshot was taken.)
    FAheadRetryAt := 0;
    VU1Domain.Now := Scheduler.Now;
    DomainScheduler.Reset;
    DomainScheduler.ScheduleAt(TPS2Event.VIF1, Scheduler.Due(TPS2Event.VIF1));
    DomainScheduler.ScheduleAt(TPS2Event.GIF, Scheduler.Due(TPS2Event.GIF));
    Scheduler.Cancel(TPS2Event.VIF1);
    Scheduler.Cancel(TPS2Event.GIF);
  end;
  Bus.SerializeState(State);
  CPU.SerializeState(State);
  VU1.SerializeState(State);
  Timers.SerializeState(State);
  DMAC.SerializeState(State);
  if State.Loading then
    DMAC.Reschedule;
  // The IOP's server list (booted or between a reset and its boot).
  var Booted := SIF.ServerCount > 0;
  State.Field(Booted, SizeOf(Booted));
  if State.Loading then
    if Booted then
      AddIOPServers
    else
      SIF.RemoveServers;
  SIF.SerializeState(State);
  GS.SerializeState(State);
  GIF.SerializeState(State);
  VIF0.SerializeState(State);
  VIF1.SerializeState(State);
  IPU.SerializeState(State);
  Kernel.SerializeState(State);
  IOMan.SerializeState(State);
  IOPHeap.SerializeState(State);
  PadMan.SerializeState(State);
  IOP.SerializeState(State);
  MemoryCards.SerializeCards(State);
  State.Field(FFieldStart, SizeOf(FFieldStart));
  State.Field(FFrameCount, SizeOf(FFrameCount));
  State.Field(FInVBlank, SizeOf(FInVBlank));
  GIF.SerializeTimeline(State);
  State.Field(FFinishDue, SizeOf(FFinishDue));
  State.Field(FFinishCount, SizeOf(FFinishCount));
  if (FFinishCount < 0) or (FFinishCount > Length(FFinishDue)) then
    FFinishCount := 0;
  State.Field(IOP.StrtokNext, SizeOf(IOP.StrtokNext));
  // BIOS boot only (its snapshots do not load into the high-level console
  // and back).
  if IOPMachine <> nil then
  begin
    Bridge.SerializeState(State);
    Drive.SerializeState(State);
    IOPMachine.SerializeState(State);
    State.Field(Bus.MCHRicm, SizeOf(Bus.MCHRicm));
    State.Field(Bus.MCHDrd, SizeOf(Bus.MCHDrd));
    State.Field(Bus.RDRAMDevice, SizeOf(Bus.RDRAMDevice));
    State.Field(Bus.CmdRegs, SizeOf(Bus.CmdRegs));
    // The field timing follows the restored GS mode.
    if State.Loading then
    begin
      SetVideoTiming(GS.PAL);
      IOPMachine.SetLineCycles(FLineCycles);
    end;
  end;
end;

end.

