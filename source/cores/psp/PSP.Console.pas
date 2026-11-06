unit PSP.Console;

// The PSP: wires the CPU, kernel and services, boots a program and runs it
// one display field at a time on the master clock.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Core.Emulation.Types, Core.Storage, PSP.Types, PSP.Memory, PSP.Scheduler,
  PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Media, PSP.IO, PSP.Loader, PSP.Display,
  PSP.Service, PSP.Audio, PSP.CPU.JIT, PSP.State, PSP.Settings, PSP.State.Graph,
  PSP.State.Direct, Core.Snapshots;

type
  // The shown framebuffer (VRAM address, format, stride in pixels) as a renderer
  // holds it, at its own resolution: True when it filled Frame.
  TPSPPresentEvent = function(Address, Format, Stride: Cardinal; var Frame: TEmulatorFrame): Boolean of object;

  TPSPConsole = class
  private
    FMemory: TPSPMemory;
    FScheduler: TPSPScheduler;
    FCPU: TPSPCPU;
    FRecompiler: TPSPRecompiler;
    FHLE: TPSPHLE;
    FKernel: TPSPKernel;
    FIO: TPSPIO;
    FLoader: TPSPLoader;
    FDisplay: TPSPDisplay;
    FSystem: TPSPSystem;
    FAudio: TPSPAudio;
    FStorage: IStorage;
    FProgram: TPSPProgram;
    FDiscStream: TStream;
    FDisc: TPSPDisc;
    FInput: TEmulatorInput;
    FAudioSamples: TArray<SmallInt>;
    FAudioOutputEnabled: Boolean;
    FFrameNumber: UInt64;
    FRunDeadline: Int64;
    FLog: TStringList;
    FOnLog: TPSPLogEvent;
    FOnPresent: TPSPPresentEvent;
    FOutput: TStringBuilder;
    FMemstickRoot, FHostRoot, FFlashRoot: string;
    FPendingExec: string;
    FPendingExecArgs, FPendingExecImage: TBytes;
    FBooted: Boolean;
    FStopAtFrame: Boolean;
    FExecuted: Int64;
    FState: TPSPReplayState;
    FReplaying: Boolean;
    FMediaDigest: TBytes;
    FSettings: TPSPSettings;
    FLastSnapshotFormat: string;
    FDirectMediaBanks: Boolean;
    function DirectGraph(Schema: TPSPGraphSchema): TPSPGraph;
    procedure TransferDirectMemory(State: TStateArchive);
    function RestoreDirectSnapshot(Data: TPSPStateFile; const Progress: TPSPStateProgress): TPSPConsole;
    function StateRoots: TPSPStateRoots;
    function StateDigest: TBytes;
    function MediaDigest(const Progress: TPSPStateProgress = nil): TBytes;
    procedure HostChanged(const Name: string; Created, Tree: Boolean);
    procedure ResetServices;
    procedure ResetMachine(KeepClock: Boolean);
    procedure Syscall(C: TPSPCPU; Code: Cardinal);
    procedure Break_(C: TPSPCPU; Code: Cardinal);
    procedure SyncTime;
    procedure HandleLog(const Text: string);
    procedure HandleOutput(const Text: RawByteString);
    function HandleLoadExec(const Path: string; ArgSize, ArgPtr: Cardinal): Cardinal;
    procedure DispatchEvent(E: TPSPEvent);
    procedure MountDisc;
    procedure Boot(const Executable: TBytes; const Path: string; const Arguments: TBytes = nil; UseArguments: Boolean = False);
  public
    constructor Create(const ProgramData: TPSPProgram; const Storage: IStorage = nil; const HostRoot: string = ''; const MemstickRoot: string = ''; const FontDirectory: string = ''; TrackSnapshots: Boolean = False; Seed: TPSPReplayState = nil; BootProgram: Boolean = True);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame(out Frame: TEmulatorFrame);
    // Runs until the guest time reaches At (ns) or the program exits.
    procedure RunUntil(At: Int64);
    procedure SaveSnapshot(const Path: string; const Progress: TPSPStateProgress = nil);
    procedure SaveDirectSnapshot(const Path: string; const Progress: TPSPStateProgress = nil);
    // Returns a fully checked replacement; Self remains usable on failure/cancel.
    function RestoreSnapshot(const Path: string; const Progress: TPSPStateProgress = nil): TPSPConsole;
    function TakeOutput: string;
    function TakeLog: string;
    property Input: TEmulatorInput read FInput write FInput;
    property Memory: TPSPMemory read FMemory;
    property CPU: TPSPCPU read FCPU;
    // The CPU's recompiler (PSPJIT; nil: the interpreter only); Enabled
    // switches between them.
    property Recompiler: TPSPRecompiler read FRecompiler;
    property Kernel: TPSPKernel read FKernel;
    property HLE: TPSPHLE read FHLE;
    property IO: TPSPIO read FIO;
    property Loader: TPSPLoader read FLoader;
    property Display: TPSPDisplay read FDisplay;
    property System: TPSPSystem read FSystem;
    property Scheduler: TPSPScheduler read FScheduler;
    property AudioSamples: TArray<SmallInt> read FAudioSamples;
    property AudioOutputEnabled: Boolean read FAudioOutputEnabled write FAudioOutputEnabled;
    property FrameNumber: UInt64 read FFrameNumber;
    // CPU cycles run (instructions plus HLE costs), for speed measurements.
    property Executed: Int64 read FExecuted;
    property OnLog: TPSPLogEvent read FOnLog write FOnLog;
    // Not state: the renderer session sets it.
    property OnPresent: TPSPPresentEvent read FOnPresent write FOnPresent;
    property LastSnapshotFormat: string read FLastSnapshotFormat;
  end;

implementation

uses
  System.Math, PSP.VFPU, PSP.GE, PSP.SysLibs, PSP.SAS, PSP.Atrac, PSP.MP3,
  PSP.AudioCodec, PSP.Mpeg, PSP.Psmf, PSP.Utility, PSP.Font, PSP.Misc, PSP.Jpeg,
  PSP.SFO, PSP.Net, PSP.Crypto, System.Hash, System.Rtti, PSP.State.Schema;

constructor TPSPConsole.Create(const ProgramData: TPSPProgram; const Storage: IStorage; const HostRoot, MemstickRoot, FontDirectory: string; TrackSnapshots: Boolean; Seed: TPSPReplayState; BootProgram: Boolean);
begin
  inherited Create;
  FState := Seed;
  FAudioOutputEnabled := True;
  FDirectMediaBanks := True;
  FReplaying := Seed <> nil;
  FSettings := PSPSettings;
  if FState = nil then
    FState := TPSPReplayState.Create;
  FProgram := ProgramData;
  FStorage := Storage;
  FHostRoot := HostRoot;
  FLog := TStringList.Create;
  FOutput := TStringBuilder.Create;
  FMemstickRoot := MemstickRoot;
  if Seed <> nil then
    FMemstickRoot := Seed.Roots[0];
  if (Seed = nil) and (FMemstickRoot = '') and (Storage <> nil) then
    FMemstickRoot := TPath.Combine(Storage.SaveRoot, 'psp-memstick');
  if FMemstickRoot <> '' then
  begin
    ForceDirectories(TPath.Combine(FMemstickRoot, 'PSP' + PathDelim + 'SAVEDATA'));
    ForceDirectories(TPath.Combine(FMemstickRoot, 'PSP' + PathDelim + 'GAME'));
    FFlashRoot := TPath.Combine(ExtractFileDir(ExcludeTrailingPathDelimiter(FMemstickRoot)), 'psp-flash0');
  end;
  FMemory := TPSPMemory.Create;
  FScheduler := TPSPScheduler.Create;
  FCPU := TPSPCPU.Create(FMemory);
  FCPU.OnSyscall := Syscall;
  FCPU.OnBreak := Break_;
  FRecompiler := CreatePSPRecompiler(FCPU);
  FHLE := TPSPHLE.Create(FCPU, FMemory);
  FHLE.OnLog := HandleLog;
  FKernel := TPSPKernel.Create(FCPU, FMemory, FHLE, FScheduler);
  FKernel.OnSyncTime := SyncTime;
  FIO := TPSPIO.Create(FKernel);
  FIO.OnOutput := HandleOutput;
  FLoader := TPSPLoader.Create(FKernel, FIO);
  FLoader.OnLoadExec := HandleLoadExec;
  FDisplay := TPSPDisplay.Create(FKernel);
  FSystem := TPSPSystem.Create;
  FSystem.Memory := FMemory;
  FSystem.CPU := FCPU;
  FSystem.HLE := FHLE;
  FSystem.Kernel := FKernel;
  FSystem.Scheduler := FScheduler;
  FSystem.IO := FIO;
  FSystem.Loader := FLoader;
  FSystem.Display := FDisplay;
  FSystem.FlashRoot := FFlashRoot;
  FSystem.FontDirectory := FontDirectory;
  if Seed <> nil then
  begin
    FFlashRoot := Seed.Roots[1];
    FHostRoot := Seed.Roots[2];
    FSystem.FlashRoot := FFlashRoot;
    FSystem.FontDirectory := Seed.Roots[3];
  end;
  if TrackSnapshots or (Seed <> nil) then
    FIO.OnHostChange := HostChanged;
  FSystem.Services := TObjectList<TPSPService>.Create;
  for var Cls in PSPServiceClasses do
    FSystem.Services.Add(Cls.Create(FSystem));
  FAudio := TPSPAudio(FSystem.Find(TPSPAudio));
  MountDisc;
  if BootProgram then
    Reset
  else
    ResetMachine(False);
end;

destructor TPSPConsole.Destroy;
begin
  if FSystem <> nil then
    FSystem.Services.Free;
  FSystem.Free;
  FDisplay.Free;
  FLoader.Free;
  FIO.Free;
  FKernel.Free;
  FHLE.Free;
  FRecompiler.Free;
  FCPU.Free;
  FScheduler.Free;
  FMemory.Free;
  FDisc.Free;
  FDiscStream.Free;
  FOutput.Free;
  FLog.Free;
  FState.Free;
  inherited;
end;

procedure TPSPConsole.MountDisc;
begin
  if FProgram.MediaPath = '' then
    Exit;
  if FStorage <> nil then
    FDiscStream := FStorage.OpenRead(FProgram.MediaPath)
  else
    FDiscStream := TFileStream.Create(FProgram.MediaPath, fmOpenRead or fmShareDenyWrite);
  FDisc := TPSPDisc.Create(FDiscStream);
end;

procedure TPSPConsole.HandleLog(const Text: string);
begin
  if FLog.Count < 20000 then
    FLog.Add(Text);
  if Assigned(FOnLog) then
    FOnLog(Text);
end;

procedure TPSPConsole.HandleOutput(const Text: RawByteString);
begin
  FOutput.Append(string(Text));
end;

function TPSPConsole.TakeOutput: string;
begin
  Result := FOutput.ToString + FKernel.TakeDebugOutput;
  FOutput.Clear;
end;

function TPSPConsole.TakeLog: string;
begin
  Result := FLog.Text;
  FLog.Clear;
end;

function TPSPConsole.HandleLoadExec(const Path: string; ArgSize, ArgPtr: Cardinal): Cardinal;
begin
  var Image: TBytes;
  Result := FIO.ReadAll(Path, Image);
  if Result <> 0 then
    Exit;
  Result := FLoader.Validate(Image, Path, ArgSize);
  if Result <> 0 then
    Exit;
  FPendingExec := Path;
  FPendingExecImage := Image;
  SetLength(FPendingExecArgs, ArgSize);
  if ArgSize > 0 then
    FMemory.ReadBytes(ArgPtr, FPendingExecArgs[0], ArgSize);
  FCPU.Stop;
end;

procedure TPSPConsole.ResetServices;
begin
  for var S in FSystem.Services do
  begin
    S.Reset;
    S.Register;
  end;
end;

procedure TPSPConsole.ResetMachine(KeepClock: Boolean);
begin
  FMemory.Reset;
  FCPU.Reset;
  if not KeepClock then
    FScheduler.Reset;
  FKernel.Reset;
  FIO.Reset;
  FIO.Disc := FDisc;
  FIO.MemstickRoot := FMemstickRoot;
  FIO.FlashRoot := FFlashRoot;
  FIO.HostDirectory := FHostRoot;
  FIO.ProgramArchive := FProgram.Archive;
  FIO.Register;
  FLoader.Reset;
  FLoader.Register;
  FDisplay.Reset;
  FDisplay.Register;
  ResetServices;
  FPendingExec := '';
  FPendingExecArgs := nil;
  FPendingExecImage := nil;
  FBooted := False;
end;

procedure TPSPConsole.Reset;
begin
  PSPSettings := FSettings;
  ResetMachine(False);
  if not FReplaying then
    FState.TrackRoots(StateRoots);
  FFrameNumber := 0;
  var Path := FProgram.BootPath;
  if Path = '' then
  begin
    if FHostRoot <> '' then
      Path := 'host0:/' + 'program.prx'
    else
      Path := 'ms0:/PSP/GAME/APP/EBOOT.PBP';
  end;
  Boot(FProgram.Executable, Path);
end;

procedure TPSPConsole.Boot(const Executable: TBytes; const Path: string; const Arguments: TBytes; UseArguments: Boolean);
begin
  var M: TPSPModule;
  var Err := FLoader.Load(Executable, Path, M);
  if Err <> 0 then
    raise EPSPError.CreateFmt('PSP: the program cannot be loaded (%.8x)', [Err]);
  if M.Fake then
    raise EPSPError.Create('PSP: the program is a firmware module');
  var Dir := Path;
  var Slash := Dir.LastIndexOf('/');
  if Slash > 0 then
    Dir := Dir.Substring(0, Slash);
  FIO.Cwd := Dir;
  FLoader.StartMain(M, Path, Arguments, UseArguments);
  FBooted := True;
end;

procedure TPSPConsole.SyncTime;
begin
  var N := FCPU.TakeCycles;
  if N > 0 then
  begin
    FScheduler.AddCycles(N);
    if FKernel.Current <> nil then
      Inc(FKernel.Current.RunClocks, N);
  end;
end;

procedure TPSPConsole.Syscall(C: TPSPCPU; Code: Cardinal);
begin
  SyncTime;
  if Code < PSPTrapCount then
    FKernel.Trap(Code)
  else
  begin
    if not FHLE.Call(Code) then
      raise EPSPGuestFault.CreateFmt('PSP: unknown syscall %x at %.8x', [Code, C.CurPC]);
  end;
  FKernel.AfterSyscall;
  // Call costs count toward the slice too: a loop of calls must not run past
  // an event.
  SyncTime;
  if (FScheduler.NextDue < FRunDeadline) or (FScheduler.Now >= FRunDeadline) then
    C.Stop;
end;

procedure TPSPConsole.Break_(C: TPSPCPU; Code: Cardinal);
begin
  HandleLog(Format('break %x at %.8x in %s', [Code, C.CurPC, PSPThreadName(FKernel.Current)]));
  // A break stops the thread on hardware (the debugger owns it); exit it.
  if FKernel.Current <> nil then
  begin
    FKernel.ExitCurrent(SCE_KERNEL_ERROR_ERROR);
    FKernel.Reschedule;
  end;
end;

procedure TPSPConsole.DispatchEvent(E: TPSPEvent);
begin
  // Every event is an interrupt on hardware, whose return breaks a pending ll/sc.
  FCPU.Ctx.LLBit := 0;
  case E of
    TPSPEvent.VBlank:
      FDisplay.OnEvent;
    TPSPEvent.Kernel:
      FKernel.OnTimerEvent;
  else
    for var S in FSystem.Services do
      S.OnEvent(E);
  end;
  FKernel.AfterSyscall;
end;

procedure TPSPConsole.RunUntil(At: Int64);
begin
  var SysLibs := TPSPSysLibs(FSystem.Find(TPSPSysLibs));
  while True do
  begin
    SysLibs.RunMediaEngine(FScheduler.Now);
    // Events that fell due during the last run are handled before returning.
    var E: TPSPEvent;
    while FScheduler.TakeDue(E) do
      DispatchEvent(E);
    if FKernel.Exited or (FScheduler.Now >= At) or (FStopAtFrame and FDisplay.FrameDone) then
      Break;
    if FPendingExec <> '' then
    begin
      var Path := FPendingExec;
      var Data := FPendingExecImage;
      var Args := FPendingExecArgs;
      // The image and arguments were checked and copied before stopping the
      // caller; host files cannot change between validation and this boot.
      ResetMachine(True);
      Boot(Data, Path, Args, True);
      Continue;
    end;
    FKernel.ProcessInterrupts;
    var Deadline := Min(FScheduler.NextDue, At);
    if not FKernel.InInterrupt and (FScheduler.Now < FKernel.BusyUntil) then
      FScheduler.AdvanceTo(Min(Deadline, FKernel.BusyUntil))
    else if FKernel.HasRunnable then
    begin
      var Budget := FScheduler.CyclesUntil(Deadline);
      if Budget > 4000000 then
        Budget := 4000000;
      if SysLibs.MediaRunning and (Budget > 2048) then
        Budget := 2048;
      if Budget < 1 then
        Budget := 1;
      FRunDeadline := Deadline;
      var Used := FCPU.Run(Budget);
      Inc(FExecuted, Used);
      FScheduler.AddCycles(Used);
      if FKernel.Current <> nil then
        Inc(FKernel.Current.RunClocks, Used);
      FRunDeadline := PSPNever;
    end
    else
      FScheduler.AdvanceTo(Deadline);
  end;
end;

procedure TPSPConsole.RunFrame(out Frame: TEmulatorFrame);
begin
  PSPSettings := FSettings;
  FDisplay.SetInput(FInput);
  FDisplay.FrameDone := False;
  FStopAtFrame := True;
  try
    RunUntil(FScheduler.Now + Int64(PSPFrameNs) * 2);
  finally
    FStopAtFrame := False;
  end;
  Inc(FFrameNumber);
  Frame := Default(TEmulatorFrame);
  if not Assigned(FOnPresent) or (FDisplay.CurrentAddress = 0) or not FOnPresent(FDisplay.CurrentAddress,
      FDisplay.Format, FDisplay.Width, Frame) then
    FDisplay.Render(Frame);
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := PSPFrameRate;
  FAudioSamples := FAudio.TakeSamples(FAudioOutputEnabled);
  FSettings := PSPSettings;
end;

function TPSPConsole.StateRoots: TPSPStateRoots;
begin
  Result[0] := FMemstickRoot;
  Result[1] := FFlashRoot;
  Result[2] := FHostRoot;
  Result[3] := FSystem.FontDirectory;
end;

procedure TPSPConsole.HostChanged(const Name: string; Created, Tree: Boolean);
begin
  var Time := EncodeDate(2026, 1, 1) + FScheduler.Now / 86400e9 +
    (PSPSettings.Timezone + 60 * PSPSettings.DaylightSaving) / 1440;
  FState.HostChanged(Name, Time, Created, Tree);
end;

function TPSPConsole.StateDigest: TBytes;
begin
  TPSPGE(FSystem.Find(TPSPGE)).Engine.Synchronize;
  var Hash := THashSHA2.Create;
  Hash.Update(FMemory.RAM);
  Hash.Update(FMemory.VRAM);
  Hash.Update(FMemory.Scratch);
  Hash.Update(FCPU.Ctx, SizeOf(FCPU.Ctx));
  Hash.Update(FScheduler.Now, SizeOf(FScheduler.Now));
  var N := FScheduler.Remainder;
  Hash.Update(N, SizeOf(N));
  N := FScheduler.MHz;
  Hash.Update(N, SizeOf(N));
  for var E := Low(TPSPEvent) to High(TPSPEvent) do
  begin
    N := FScheduler.Due(E);
    Hash.Update(N, SizeOf(N));
  end;
  var SysLibs := TPSPSysLibs(FSystem.Find(TPSPSysLibs));
  if SysLibs.MediaCycles <> 0 then
  begin
    Hash.Update(FMemory.BootRAM);
    Hash.Update(SysLibs.MediaMemory.MediaRAM);
    Hash.Update(SysLibs.MediaCPU.Ctx, SizeOf(TPSPContext));
    Hash.Update(SysLibs.MediaCPU.COP0, SizeOf(SysLibs.MediaCPU.COP0));
  end;
  Result := Hash.HashAsBytes;
end;

function TPSPConsole.MediaDigest(const Progress: TPSPStateProgress): TBytes;
begin
  if Length(FMediaDigest) = 0 then
  begin
    if FDiscStream = nil then
    begin
      var Hash := THashSHA2.Create;
      Hash.Update(FProgram.Executable);
      if FProgram.Archive <> nil then
      begin
        Hash.Update(TEncoding.UTF8.GetBytes(FProgram.BootPath + #0));
        for var I := 0 to FProgram.Archive.Count - 1 do
        begin
          if Assigned(Progress) and not Progress(0, 0) then
            raise EAbort.Create('PSP snapshot operation cancelled');
          var Entry := FProgram.Archive.Entries[I];
          Hash.Update(TEncoding.UTF8.GetBytes(Entry.Name + #0));
          Hash.Update(Entry.Size, SizeOf(Entry.Size));
          Hash.Update(Entry.IsDirectory, SizeOf(Entry.IsDirectory));
          if not Entry.IsDirectory then
          begin
            var CRC := FProgram.Archive.Checksum(I);
            Hash.Update(CRC, SizeOf(CRC));
          end;
        end;
      end;
      FMediaDigest := Hash.HashAsBytes;
    end
    else
    begin
      var Position := FDiscStream.Position;
      try
        FDiscStream.Position := 0;
        var Hash := THashSHA2.Create;
        var Buffer: array[0..65535] of Byte;
        while True do
        begin
          if Assigned(Progress) and not Progress(0, 0) then
            raise EAbort.Create('PSP snapshot operation cancelled');
          var N := FDiscStream.Read(Buffer, SizeOf(Buffer));
          if N = 0 then
            Break;
          Hash.Update(Buffer, N);
        end;
        FMediaDigest := Hash.HashAsBytes;
      finally
        FDiscStream.Position := Position;
      end;
    end;
  end;
  Result := FMediaDigest;
end;

procedure TPSPConsole.SaveSnapshot(const Path: string; const Progress: TPSPStateProgress);
begin
  SaveDirectSnapshot(Path, Progress);
end;

function TPSPConsole.RestoreSnapshot(const Path: string; const Progress: TPSPStateProgress): TPSPConsole;
begin
  Result := nil;
  var FileData := TPSPStateFile.Create;
  var Seed: TPSPReplayState := nil;
  var Candidate: TPSPConsole := nil;
  var Settings := PSPSettings;
  try
    LoadCoreSnapshot(Path, 'PSP', FProgram.Executable,
      procedure(State: TStateArchive)
      begin
        FileData.Transfer(State);
      end, FStorage);
    if FileData.Kind = 2 then
    begin
      Result := RestoreDirectSnapshot(FileData, Progress);
      Exit;
    end;
    Seed := FileData.Seed;
    FileData.Seed := nil;
    var Media := MediaDigest(Progress);
    if Assigned(Progress) and not Progress(0, 0) then
      raise EAbort.Create('PSP snapshot loading cancelled');
    if (Length(Seed.MediaDigest) <> 32) or not CompareMem(@Media[0], @Seed.MediaDigest[0], 32) then
      raise EReadError.Create('PSP snapshot belongs to a different game image');
    var LiveRoots := StateRoots;
    if FState <> nil then
      LiveRoots := FState.LiveRoots;
    Seed.Materialize(LiveRoots);
    PSPSettings := Seed.Settings;
    var OwnedSeed := Seed;
    Seed := nil;
    Candidate := TPSPConsole.Create(FProgram, FStorage, '', '', '', False, OwnedSeed);
    Candidate.FMediaDigest := Media;
    var Replay := Candidate.FState;
    Candidate.FIO.HasDisplay := Replay.HasDisplay;
    Candidate.FIO.NoEmulatorDevice := Replay.NoEmulatorDevice;
    Candidate.FHLE.NoClobber := Replay.NoClobber;
    if Candidate.Recompiler <> nil then
      Candidate.Recompiler.Enabled := FRecompiler <> nil;
    var Frame: TEmulatorFrame;
    var Done: UInt64 := 0;
    for var R in Replay.Inputs do
    begin
      Candidate.Input := R.Expand;
      for var I := 1 to R.Count do
      begin
        if Assigned(Progress) and not Progress(Done, Replay.Frames) then
          raise EAbort.Create('PSP snapshot loading cancelled');
        Candidate.RunFrame(Frame);
        Inc(Done);
        Candidate.TakeOutput;
        Candidate.TakeLog;
      end;
    end;
    var Digest := Candidate.StateDigest;
    if (Length(Replay.Digest) <> 32) or not CompareMem(@Replay.Digest[0], @Digest[0], 32) then
      raise EReadError.Create('PSP snapshot reconstruction differs from the saved machine; current game was not changed');
    if Assigned(Progress) and not Progress(Done, Replay.Frames) then
      raise EAbort.Create('PSP snapshot loading cancelled');
    Replay.Publishing := True;
    Candidate.FReplaying := False;
    Result := Candidate;
    Candidate := nil;
  finally
    if Result <> nil then
      PSPSettings := Result.FSettings
    else
      PSPSettings := Settings;
    Candidate.Free;
    Seed.Free;
    FileData.Free;
  end;
end;

function TPSPConsole.DirectGraph(Schema: TPSPGraphSchema): TPSPGraph;
begin
  var Mounts := StateRoots;
  var Roots: TPSPGraphRoots;
  for var I := 0 to High(Roots) do
    Roots[I] := Mounts[I];
  Result := TPSPGraph.Create(Schema, Roots,
    function(Stream: TStream): Word
    begin
      Result := FIO.StateStreamMode(Stream);
    end);
  try
    Schema.Optional(TPSPConsole, ['FPendingExecImage']);
    Result.Bind('console', Self,
      ['FFrameNumber', 'FPendingExec', 'FPendingExecArgs', 'FBooted', 'FExecuted', 'FInput', 'FAudioSamples',
        'FSettings', 'FPendingExecImage']);
    Result.Bind('memory', FMemory, []);
    var SysLibs := TPSPSysLibs(FSystem.Find(TPSPSysLibs));
    if FDirectMediaBanks then
    begin
      Result.Bind('memory:me', SysLibs.MediaMemory, []);
      Result.Bind('cpu:me', SysLibs.MediaCPU, ['*']);
    end;
    Result.Bind('cpu', FCPU, ['*']);
    Result.Bind('scheduler', FScheduler, ['*']);
    Result.Bind('hle', FHLE, ['*']);
    Result.Bind('kernel', FKernel, ['*']);
    Result.Bind('io', FIO, ['*']);
    Result.Bind('loader', FLoader, ['*']);
    Result.Bind('display', FDisplay, ['*']);
    Result.Bind('system', FSystem, []);
    Result.Bind('partition:kernel', FKernel.KernelPartition, ['*']);
    Result.Bind('partition:user', FKernel.UserPartition, ['*']);
    Result.Bind('partition:volatile', FKernel.Partition(5), ['*']);
    Result.Bind('partition:stack', FKernel.StackPartition, ['*']);
    if FDisc <> nil then
      Result.Bind('disc', FDisc, []);
    var Services := FSystem.Services.ToArray;
    for var I := 0 to High(Services) do
      for var J := I + 1 to High(Services) do
        if CompareStr(Services[I].ClassName, Services[J].ClassName) > 0 then
        begin
          var Swap := Services[I];
          Services[I] := Services[J];
          Services[J] := Swap;
        end;
    for var S in Services do
      Result.Bind('service:' + S.ClassName, S, ['*']);
    var Engine := TPSPGE(FSystem.Find(TPSPGE)).Engine;
    Result.Bind('ge-engine', Engine,
      ['Regs', 'BoxVisible', 'FClut', 'FVSize', 'FOffTC', 'FOffC', 'FOffN', 'FOffP', 'FPrimCost', 'FAsmType',
        'FAsmCount', 'FLastU', 'FLastV', 'FLastN', 'FAsm', 'FCullOn', 'FCullCW', 'FDepthClamp']);
  except
    Result.Free;
    raise;
  end;
end;

procedure TPSPConsole.TransferDirectMemory(State: TStateArchive);
begin
  // The high bit adds ME banks; unflagged snapshots keep their older layout.
  var Shift := Cardinal(FMemory.VRAMShift) or $80000000;
  State.Field(Shift, SizeOf(Shift));
  var HasMediaBanks := (Shift and $80000000) <> 0;
  if State.Loading then
    FDirectMediaBanks := HasMediaBanks;
  Shift := Shift and $7FFFFFFF;
  if Shift > 31 then
    raise EReadError.Create('Invalid PSP VRAM translation');
  if State.Loading then
    FMemory.SetVRAMTranslation(Cardinal(1) shl Shift);
  var Data := FMemory.RAM;
  State.Field(Data[0], Length(Data));
  Data := FMemory.VRAM;
  State.Field(Data[0], Length(Data));
  Data := FMemory.Scratch;
  State.Field(Data[0], Length(Data));
  if HasMediaBanks then
  begin
    Data := FMemory.BootRAM;
    State.Field(Data[0], Length(Data));
    Data := TPSPSysLibs(FSystem.Find(TPSPSysLibs)).MediaMemory.MediaRAM;
    State.Field(Data[0], Length(Data));
  end;
end;

procedure TPSPConsole.SaveDirectSnapshot(const Path: string; const Progress: TPSPStateProgress);
begin
  TPSPGE(FSystem.Find(TPSPGE)).Engine.Synchronize;
  FDirectMediaBanks := True;
  var Schema := NewPSPStateSchema;
  var Data := TPSPStateFile.Create;
  var Current := TPSPReplayState.Create;
  var GraphStream := TMemoryStream.Create;
  var Raw := TMemoryStream.Create;
  try
    var Graph := DirectGraph(Schema);
    try
      try
        Graph.Save(GraphStream);
      except
        on E: EPSPStateOpaque do
          raise EPSPStateOpaque.Create(E.Message + FKernel.DescribeStateTimers);
      end;
    finally
      Graph.Free;
    end;
    if Assigned(Progress) and not Progress(0, 1) then
      raise EAbort.Create('PSP snapshot saving cancelled');
    Current.Capture(StateRoots);
    if Current.CaptureError <> '' then
      raise EWriteError.Create(Current.CaptureError);
    Data.CurrentFiles := Current.InitialFiles;
    Data.HasHistory := False;
    Data.Seed.Settings := FSettings;
    Data.Seed.HasDisplay := FIO.HasDisplay;
    Data.Seed.NoEmulatorDevice := FIO.NoEmulatorDevice;
    Data.Seed.NoClobber := FHLE.NoClobber;
    Data.Seed.Digest := StateDigest;
    Data.Seed.MediaDigest := MediaDigest(Progress);
    var State := TStateArchive.Create(Raw, False);
    try
      TransferDirectMemory(State);
      var GraphBytes: TBytes;
      SetLength(GraphBytes, GraphStream.Size);
      if Length(GraphBytes) > 0 then
        Move(GraphStream.Memory^, GraphBytes[0], Length(GraphBytes));
      PSPStateBytes(State, GraphBytes, 128 * 1024 * 1024);
    finally
      State.Free;
    end;
    Data.Core := PSPPackState(Raw);
    if Int64(Length(Data.CurrentFiles)) + Length(Data.Core) > 63 * 1024 * 1024 then
      raise EWriteError.Create('PSP direct snapshot exceeds the 64 MiB payload limit');
    if Assigned(Progress) and not Progress(1, 1) then
      raise EAbort.Create('PSP snapshot saving cancelled');
    SaveCoreSnapshot(Path, 'PSP', FProgram.Executable,
      procedure(State: TStateArchive)
      begin
        Data.Transfer(State);
      end, FStorage);
    FLastSnapshotFormat := 'direct';
  finally
    Raw.Free;
    GraphStream.Free;
    Current.Free;
    Data.Free;
    Schema.Free;
  end;
end;

function TPSPConsole.RestoreDirectSnapshot(Data: TPSPStateFile; const Progress: TPSPStateProgress): TPSPConsole;
begin
  var Media := MediaDigest(Progress);
  var Seed := Data.Seed;
  if (Length(Seed.MediaDigest) <> 32) or not CompareMem(@Media[0], @Seed.MediaDigest[0], 32) then
    raise EReadError.Create('PSP snapshot belongs to a different game image');
  if Assigned(Progress) and not Progress(0, 4) then
    raise EAbort.Create('PSP snapshot loading cancelled');
  var Roots := StateRoots;
  if FState <> nil then
    Roots := FState.LiveRoots;
  var Initial := Seed.InitialFiles;
  Seed.InitialFiles := Data.CurrentFiles;
  Seed.Materialize(Roots);
  Seed.InitialFiles := Initial;
  PSPSettings := Seed.Settings;
  Data.Seed := nil;
  var Candidate := TPSPConsole.Create(FProgram, FStorage, '', '', '', False, Seed, False);
  try
    Candidate.FMediaDigest := Media;
    var Raw := PSPUnpackState(Data.Core);
    var Schema := NewPSPStateSchema;
    try
      var GraphBytes: TBytes := nil;
      var State := TStateArchive.Create(Raw, True);
      try
        Candidate.TransferDirectMemory(State);
        PSPStateBytes(State, GraphBytes, 128 * 1024 * 1024);
      finally
        State.Free;
      end;
      if Raw.Position <> Raw.Size then
        raise EReadError.Create('Unexpected PSP direct-state data');
      if Assigned(Progress) and not Progress(1, 4) then
        raise EAbort.Create('PSP snapshot loading cancelled');
      var GraphStream := TBytesStream.Create(GraphBytes);
      var Graph := Candidate.DirectGraph(Schema);
      try
        Graph.Load(GraphStream);
      finally
        Graph.Free;
        GraphStream.Free;
      end;
      Candidate.FCPU.FlushDecoded;
      TPSPGE(Candidate.System.Find(TPSPGE)).Engine.Restored;
      if Assigned(Progress) and not Progress(3, 4) then
        raise EAbort.Create('PSP snapshot loading cancelled');
      var Actual := Candidate.StateDigest;
      if (Length(Seed.Digest) <> 32) or not CompareMem(@Actual[0], @Seed.Digest[0], 32) then
        raise EReadError.Create('PSP direct-state validation failed; current game was not changed');
      if Assigned(Progress) and not Progress(4, 4) then
        raise EAbort.Create('PSP snapshot loading cancelled');
    finally
      Schema.Free;
      Raw.Free;
    end;
    Seed.Publishing := True;
    Candidate.FReplaying := False;
    Candidate.FLastSnapshotFormat := 'direct';
    Result := Candidate;
    Candidate := nil;
  finally
    Candidate.Free;
  end;
end;

end.

