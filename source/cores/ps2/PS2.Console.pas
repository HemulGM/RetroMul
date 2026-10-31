unit PS2.Console;

// PlayStation 2 machine: EE, its bus and devices, the high-level kernel and
// IOP services, the scheduler in EE cycles and the field timing (NTSC/PAL,
// VBlank start/end). RunFrame runs one field.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, Core.Snapshots, Core.DVD.Image, PS2.Types, PS2.Scheduler, PS2.EE.CPU,
  PS2.EE.Bus, PS2.Timers, PS2.DMAC, PS2.SIF, PS2.GS, PS2.GIF, PS2.Kernel, PS2.ELF, PS2.IOP.FileIO, PS2.IOP.HLE, PS2.IOP.CDVD, PS2.IOP.Pad, PS2.IOP.MemoryCard, PS2.IOP.Kernel, PS2.VU, PS2.VIF, PS2.IPU;

const
  // Serialized layout of TPS2Console.SerializeState. Increase it with every
  // layout change; tests/cores/ps2/system checks the recorded field layout.
  PS2SnapshotVersion = 5;

type
  TPS2ConsoleConfig = record
    PAL: Boolean;
    // Directory for host: paths (homebrew).
    HostDirectory: string;
    // The disc (owned by the caller) or nil.
    Disc: TDVDImage;
    Region: TPS2Region;
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
    // FINISH writes not in CSR yet: the EE cycle each shows, oldest first.
    FFinishDue: array[0..7] of Int64;
    FFinishCount: Integer;
    procedure GSFinishWritten;
    procedure GSFinishShown;
    procedure TTYWrite(const Text: string);
    procedure IOPTTY(Text: string);
    procedure DMACInterrupt(Active: Boolean);
    procedure GSInterrupt;
    procedure HandleEvent(Event: TPS2Event; At: Int64);
    procedure SetVideo(PAL: Boolean);
    procedure LoadExec(const Path: string; const Args: TArray<string>);
    procedure IOPReset(const Args: string);
    procedure BootIOP;
    procedure AddIOPServers;
    procedure StartVU1(Address: Cardinal);
    function ImageVersion(const ResetArgs: string): Integer;
    procedure VU1Kick(Address: Cardinal; Data: PByte);
    procedure NoteModuleVersion(const Path: string; const Image: TBytes);
    function StartModule(Server: TPS2LoadFileServer; const Path: string; const Image, Args: TBytes;
      out ModResult: Integer): Integer;
    procedure ModuleDone(const Token: TBytes; ModuleId, Result: Integer);
    function GetHalted: Boolean;
  public
    Scheduler: TPS2Scheduler;
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
    // Run game IOP modules as IOP code (False: report them loaded only).
    RunIOPModules: Boolean;
    // Modules the EE asked the IOP to load (diagnostics).
    ModuleLog: TStringList;
    constructor Create(const Config: TPS2ConsoleConfig);
    destructor Destroy; override;
    procedure Reset;
    // A homebrew ELF (EE executable): loaded and started by the HLE kernel.
    procedure LoadProgram(const Data: TBytes; const Name: string);
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
    property IdleCycles: Int64 read FIdleCycles;
    // Snapshot header policy: version and the errors users see.
    class function SnapshotPolicy: TSnapshotPolicy; static;
  end;

implementation

uses
  System.Math, PS2.IOP.Loader;

const
  // EE cycles per IOP slice while IOP code has work.
  IOPSlice = 4096;
  // EE cycles from a FINISH register write to CSR.FINISH.
  GSFinishDelay = 8192;
  // SPU2 samples computed together, and their EE cycles.
  SPU2Batch = 32;
  SPU2BatchCycles = SPU2Batch * (PS2EEClock div PS2SPU2Rate);

{ TPS2Console }

constructor TPS2Console.Create(const Config: TPS2ConsoleConfig);
begin
  inherited Create;
  FConfig := Config;
  FTTY := TStringBuilder.Create;
  Scheduler := TPS2Scheduler.Create;
  Bus := TPS2EEBus.Create(Scheduler);
  VU0 := TPS2VU0.Create(Bus.VU0Code, Bus.VU0Data);
  VU1 := TPS2VU1.Create(Bus.VU1Code, Bus.VU1Data);
  VU0.VU1 := VU1.Core;
  VU0.Clock := @Scheduler.Now;
  VU0.OnStartVU1 := StartVU1;
  VU1.Core.OnKick := VU1Kick;
  CPU := TEECPU.Create(Bus, VU0, @Scheduler.Now, @Scheduler.Deadline);
  Bus.CPU := CPU;
  Bus.OnTTY := TTYWrite;
  Timers := TPS2Timers.Create(Scheduler, Bus.RaiseIRQ);
  Bus.Timers := Timers;
  DMAC := TPS2DMAC.Create(Scheduler, Bus.RAM, CPU.Scratchpad, Bus.RAMGenerations);
  DMAC.OnInterrupt := DMACInterrupt;
  Bus.DMAC := DMAC;
  SIF := TPS2SIF.Create(Scheduler, DMAC, Bus.RAM, Bus.IOPRAM);
  SIF.OnReset := IOPReset;
  SIF.StubUnknownServers := True;
  Bus.SIF := SIF;
  GS := TPS2GS.Create;
  GS.OnInterrupt := GSInterrupt;
  GS.Raster.OnFinish := GSFinishWritten;
  Bus.GS := GS;
  GIF := TPS2GIF.Create(GS);
  GIF.Clock := @Scheduler.Now;
  Bus.GIF := GIF;
  GIFPort := TPS2GIFPort.Create(GIF);
  GIF.OnPath3Resume := procedure begin DMAC.Resume(DMAGIF); end;
  GIF.OnPath3Held := procedure(Cycles: Int64) begin Scheduler.Schedule(TPS2Event.GIF, Scheduler.Now + Cycles); end;
  DMAC.Ports[DMAGIF] := GIFPort;
  VIF0 := TPS2VIF.Create(0, VU0.Core, nil, Bus.VU0Code, Bus.VU0Data, $1000, $1000);
  VIF1 := TPS2VIF.Create(1, VU1.Core, GIF, Bus.VU1Code, Bus.VU1Data, $4000, $4000);
  VIF0.OnInterrupt := procedure begin Bus.RaiseIRQ(4); end;
  VIF1.OnInterrupt := procedure begin Bus.RaiseIRQ(5); end;
  VIF0.OnResume := procedure begin DMAC.Resume(DMAVIF0); end;
  VIF1.OnResume := procedure begin DMAC.Resume(DMAVIF1); end;
  VIF0.Scheduler := Scheduler;
  VIF1.Scheduler := Scheduler;
  Bus.VIF0 := VIF0;
  Bus.VIF1 := VIF1;
  VIF0Port := TPS2VIFPort.Create(VIF0);
  VIF1Port := TPS2VIFPort.Create(VIF1);
  DMAC.Ports[DMAVIF0] := VIF0Port;
  DMAC.Ports[DMAVIF1] := VIF1Port;
  IPU := TPS2IPU.Create(Scheduler, DMAC);
  IPU.OnInterrupt := procedure begin Bus.RaiseIRQ(8); end;
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
  IOP := TPS2IOPKernel.Create(Scheduler, SIF, IOPHeap, IOMan, FDiscFS, Bus.RAM, Bus.IOPRAM);
  IOP.OnTTY := IOPTTY;
  IOP.OnHighLevelModule := procedure(Name: string; Image: TBytes)
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
  Reset;
end;

destructor TPS2Console.Destroy;
begin
  FileIO.Free;
  LoadFile.Free;
  PadMan.Free;
  MemoryCards.Free;
  IOP.Free;
  HeapServer.Free;
  IOPHeap.Free;
  ModuleLog.Free;
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

// FINISH shows in CSR once the GS has drawn what came before it, and not
// before GSFinishDelay (programs clear CSR events right after starting a
// transfer and then wait for FINISH). Each write shows on its own: programs
// count FINISH interrupts, one per packet they send.
procedure TPS2Console.GSFinishWritten;
begin
  var Due := Max(Scheduler.Now + GSFinishDelay, GIF.GSBusyUntil);
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
    Scheduler.Schedule(TPS2Event.GSSignal, Due);
end;

procedure TPS2Console.GSFinishShown;
begin
  if FFinishCount > 0 then
  begin
    Dec(FFinishCount);
    Move(FFinishDue[1], FFinishDue[0], FFinishCount * SizeOf(Int64));
  end;
  GS.Raster.SetFinish;
  if FFinishCount > 0 then
    Scheduler.Schedule(TPS2Event.GSSignal, FFinishDue[0]);
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
  IOP.LineCycles := FLineCycles;
end;

procedure TPS2Console.Reset;
begin
  Scheduler.Reset;
  FFinishCount := 0;
  Bus.Reset;
  CPU.Reset;
  VU1.Reset;
  Timers.Reset;
  DMAC.Reset;
  DMAC.CTRL := 1;
  SIF.Reset;
  GS.Reset;
  GS.Interlaced := True;
  GIF.Reset;
  VIF0.Reset;
  VIF1.Reset;
  IPU.Reset;
  Kernel.Reset;
  // OSD configuration (GetOsdConfigParam): Japanese on Japanese consoles,
  // English elsewhere (language bits 16-20, 'English' flag bit 4).
  if FConfig.Region = TPS2Region.Japan then
    Kernel.OsdConfig := 0
  else
    Kernel.OsdConfig := (1 shl 16) or (1 shl 4);
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

function TPS2Console.StartModule(Server: TPS2LoadFileServer; const Path: string; const Image, Args: TBytes;
  out ModResult: Integer): Integer;
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

procedure TPS2Console.StartVU1(Address: Cardinal);
begin
  // CMSAR1 holds a 16-bit instruction address.
  VU1.Core.Start((Address and $FFFF) * 8);
  VU1.Core.RunProgram(Scheduler.Now, 4000000);
end;

procedure TPS2Console.VU1Kick(Address: Cardinal; Data: PByte);
begin
  if (GIF.TagLog <> nil) and (GIF.TagLog.Count < 200000) then
    GIF.TagLog.Add(Format('xgkick %x pc %x', [Address, VU1.Core.S.TPC]));
  GIF.Kick(Data, 0, $3FFF);
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

procedure TPS2Console.HandleEvent(Event: TPS2Event; At: Int64);
begin
  case Event of
    TPS2Event.VBlankStart:
      begin
        FInVBlank := True;
        Bus.RaiseIRQ(2);
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
    TPS2Event.Timer0: Timers.Event(0);
    TPS2Event.Timer1: Timers.Event(1);
    TPS2Event.Timer2: Timers.Event(2);
    TPS2Event.Timer3: Timers.Event(3);
    TPS2Event.DMAC: DMAC.Event;
    TPS2Event.GIF: GIF.ReleasePath3;
    TPS2Event.VIF0: VIF0.Wake;
    TPS2Event.VIF1: VIF1.Wake;
    TPS2Event.IPU: IPU.Event;
    TPS2Event.GSSignal: GSFinishShown;
    TPS2Event.SIF: SIF.Deliver;
    TPS2Event.Alarm: Kernel.AlarmEvent;
    TPS2Event.Compare: CPU.CompareReached;
    TPS2Event.IOPSync: BootIOP;
    TPS2Event.IOPTimers: IOP.TimerEvent;
    TPS2Event.IOPDMA: IOP.Hardware.Event;
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
    Scheduler.Deadline := Scheduler.NextDue;
    // IOP code runs in slices behind the EE.
    var IOPActive := IOP.Active;
    if IOPActive and (Scheduler.Deadline > Scheduler.Now + IOPSlice) then
      Scheduler.Deadline := Scheduler.Now + IOPSlice;
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
      IOP.Run(Scheduler.Now);
      Continue;
    end;
    CPU.Run;
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
  Scheduler.SerializeState(State);
  Bus.SerializeState(State);
  CPU.SerializeState(State);
  VU1.SerializeState(State);
  Timers.SerializeState(State);
  DMAC.SerializeState(State);
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
end;

end.
