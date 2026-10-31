unit PS2.Kernel;

// High-level EE kernel. SYSCALL is handled here: threads and their scheduler,
// semaphores, INTC/DMAC handlers, alarms, SetupThread/SetupHeap, ExecPS2,
// LoadExecPS2, FlushCache, GS CRT/IMR, SetSyscall (custom syscalls run as
// guest code), the SIF calls and TLB setup. Interrupt handlers, alarm
// callbacks and custom syscalls run as guest code from small trampolines in
// kernel memory (8000_0000h..8007_FFFFh); register contexts are saved here.
// With no ready thread the CPU idles in a kernel loop that lets the console
// skip to the next event.
// References: ps2tek (BIOS EE syscalls and patches), ps2sdk kernel.h,
// syscallnr.h and deci2.c (interfaces, structures); ps2autotests.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, PS2.Types,
  PS2.Scheduler, PS2.EE.CPU, PS2.EE.Bus, PS2.DMAC, PS2.SIF;

const
  KernelTrapInterrupt = 1;
  KernelTrapHandlerReturn = 2;
  KernelTrapCustomReturn = 3;
  KernelTrapIdle = 4;
  KernelTrapException = 5;
  KernelTrapRefill = 6;

  KernelHandlerReturn = $80001000;
  KernelThreadExit = $80001010;
  KernelCustomReturn = $80001020;
  KernelIdle = $80001030;
  KernelInterruptStack = $80030000;
  // The syscall table SetSyscall fills (games search kernel memory for it).
  KernelSyscallTable = $00010000;
  KernelMaxThreads = 256;
  KernelMaxSemas = 256;

type
  TPS2Context = record
    GPR: array[0..31] of TPS2Reg128;
    HI, LO: TPS2Reg128;
    SA, PC, ACC, FCR31: Cardinal;
    FPR: array[0..31] of Cardinal;
  end;

  TPS2ThreadState = (Free, Dormant, Ready, Waiting, Suspended, WaitSuspended);

  TPS2Thread = record
    State: TPS2ThreadState;
    WaitKind, WaitId: Integer;
    Func, Stack, StackSize, GP, InitPriority, Priority, Attr, Option: Cardinal;
    WakeupCount: Integer;
    Seq, WaitSeq: Int64;
    Context: TPS2Context;
  end;

  TPS2Sema = record
    Used: Boolean;
    Count, MaxCount, InitCount: Integer;
    Attr, Option: Cardinal;
  end;

  TPS2Handler = record
    Used: Boolean;
    Cause, Address, Arg, GP: Cardinal;
    Enabled: Boolean;
  end;

  TPS2Alarm = record
    Used: Boolean;
    Due: Int64;
    Time, Callback, Arg, GP: Cardinal;
  end;

  TPS2GuestCall = record
    Address, A0, A1, A2, GP: Cardinal;
    Kind: Integer;
  end;

  TPS2LoadExec = procedure(const Path: string; const Args: TArray<string>) of object;

  TPS2Kernel = class
  private
    FCPU: TEECPU;
    FBus: TPS2EEBus;
    FScheduler: TPS2Scheduler;
    FThreads: array[0..KernelMaxThreads - 1] of TPS2Thread;
    FSemas: array[0..KernelMaxSemas - 1] of TPS2Sema;
    FIntc, FDmac: array[0..127] of TPS2Handler;
    FIntcOrder, FDmacOrder: TList<Integer>;
    FAlarms: array[0..63] of TPS2Alarm;
    FSysRegs: array[0..31] of Cardinal;
    FCurrent: Integer;
    FSeq: Int64;
    FInInterrupt, FNeedSchedule: Boolean;
    FIntContext: TPS2Context;
    FIntStatus: Cardinal;
    FCalls: TList<TPS2GuestCall>;
    FCallKind, FCallCause: Integer;
    FSkipCause: Integer;
    FCustomReturn: Cardinal;
    FCustomRA: UInt64;
    FCustomStatus: Cardinal;
    FInCustom: Boolean;
    FVSyncFlag1, FVSyncFlag2: Cardinal;
    FSifDmaId: Cardinal;
    FHeapEnd: Cardinal;
    FDeci2: array[0..31] of Cardinal;
    FIdle: Boolean;
    FExited: Boolean;
    FExitCode: Integer;
    FGsIMR: UInt64;
    FCrtMode: Cardinal;
    FCrtInterlace, FCrtField: Cardinal;
    FOsdConfig: Cardinal;
    FOsdConfig2: array[0..127] of Byte;
    FProgramName: string;
    FArgs: TArray<string>;
    FLineCycles: Int64;
    FOnLoadExec: TPS2LoadExec;
    FOnTTY: TPS2TTYWrite;
    FOnCrtChange: TProc;
    FUnknown: TStringList;
    procedure SaveContext(var C: TPS2Context);
    procedure LoadContext(const C: TPS2Context);
    procedure WriteTrap(Address, Index: Cardinal);
    procedure SetupKernelMemory;
    procedure SetupTLB;
    function Arg(N: Integer): Cardinal; inline;
    procedure Ret(Value: Integer); inline;
    function ReadU32(Address: Cardinal): Cardinal;
    procedure WriteU32(Address, Value: Cardinal);
    function ReadString(Address: Cardinal; Max: Integer = 1024): string;
    function NextReady: Integer;
    procedure MakeReady(Id: Integer);
    procedure Schedule;
    procedure SwitchTo(Id: Integer);
    procedure EnterIdle;
    procedure Reschedule;
    procedure WakeThread(Id: Integer; Value: Integer);
    procedure StartNextCall;
    procedure FinishInterrupt;
    procedure Interrupt;
    procedure Exception;
    procedure UpdateAlarmEvent;
    procedure AddHandler(Kind: Integer);
    procedure RemoveHandler(Kind: Integer);
    procedure EnableHandler(Kind: Integer; Enable: Boolean);
    procedure EnableIntc(Cause: Cardinal; Enable: Boolean);
    procedure EnableDmac(Channel: Cardinal; Enable: Boolean);
    procedure SetupThread;
    procedure CreateThread;
    procedure StartThread;
    procedure ReferThreadStatus;
    procedure CreateSema;
    procedure WaitSema(Poll: Boolean);
    procedure SignalSema;
    procedure ReferSemaStatus;
    procedure SetAlarm;
    procedure SifSetDma;
    procedure CallCustom(Index: Cardinal);
    function Custom(Index: Cardinal): Cardinal; inline;
    procedure Unknown(Code: Integer);
  public
    constructor Create(CPU: TEECPU; Bus: TPS2EEBus; Scheduler: TPS2Scheduler);
    destructor Destroy; override;
    procedure Reset;
    // Starts a loaded program: main thread state and argument list.
    procedure Boot(Entry: Cardinal; const ProgramName: string; const Args: TArray<string>);
    procedure Syscall(CPU: TEECPU);
    procedure Trap(CPU: TEECPU; Index: Cardinal);
    // VBlank start (SetVSyncFlag), the alarm event.
    procedure VBlankStart(OddField: Boolean);
    procedure AlarmEvent;
    procedure SetLineCycles(Cycles: Int64);
    procedure SerializeState(State: TStateArchive);
    // Set while the CPU sits in the idle loop; the console clears it.
    property Idle: Boolean read FIdle write FIdle;
    property Exited: Boolean read FExited;
    property ExitCode: Integer read FExitCode;
    property CurrentThread: Integer read FCurrent;
    property GsIMR: UInt64 read FGsIMR;
    property CrtMode: Cardinal read FCrtMode;
    property CrtInterlace: Cardinal read FCrtInterlace;
    property CrtField: Cardinal read FCrtField;
    property OsdConfig: Cardinal read FOsdConfig write FOsdConfig;
    // The OSD configuration area of GetOsdConfigParam2 (128 bytes; the
    // first four: format, date/time format flags, version, language).
    procedure SetOsdConfig2(const Data: array of Byte);
    function OsdConfig2: TBytes;
    property OnLoadExec: TPS2LoadExec read FOnLoadExec write FOnLoadExec;
    property OnTTY: TPS2TTYWrite read FOnTTY write FOnTTY;
    property OnCrtChange: TProc read FOnCrtChange write FOnCrtChange;
    // Syscalls not handled (diagnostics).
    property UnknownCalls: TStringList read FUnknown;
  public
    // Diagnostics: every syscall and trap when assigned.
    Trace: TStringList;
    // Diagnostics: the RAM word shown in syscall trace lines.
    WatchAddress: Cardinal;
    // Diagnostics: syscalls by number, Deci2Call by function.
    SyscallCounts: array[0..255] of Int64;
    Deci2Counts: array[0..16] of Int64;
    // Diagnostics: one line per thread (state, wait, priority, PC, RA).
    function DescribeThreads: TArray<string>;
  end;

implementation

const
  ReturnReg = 2;
  StackReserve = $2A0;
  TrapOpcode = $EC000000;

  KernelTLB: array[0..12, 0..3] of Cardinal = (
    ($00000000, $70000000, $80000007, $00000007),
    ($00006000, $FFFF8000, $00001E1F, $00001F1F),
    ($00000000, $10000000, $00400017, $00400053),
    ($00000000, $10002000, $00400097, $004000D7),
    ($00000000, $10004000, $00400117, $00400157),
    ($00000000, $10006000, $00400197, $004001D7),
    ($00000000, $10008000, $00400217, $00400257),
    ($00000000, $1000A000, $00400297, $004002D7),
    ($00000000, $1000C000, $00400313, $00400357),
    ($00000000, $1000E000, $00400397, $004003D7),
    ($0001E000, $11000000, $00440017, $00440415),
    ($0001E000, $12000000, $00480017, $00480415),
    ($01FFE000, $1E000000, $00780017, $007C0017));
  DefaultTLB: array[0..17, 0..3] of Cardinal = (
    ($0007E000, $00080000, $0000201F, $0000301F),
    ($0007E000, $00100000, $0000401F, $0000501F),
    ($0007E000, $00180000, $0000601F, $0000701F),
    ($001FE000, $00200000, $0000801F, $0000C01F),
    ($001FE000, $00400000, $0001001F, $0001401F),
    ($001FE000, $00600000, $0001801F, $0001C01F),
    ($007FE000, $00800000, $0002001F, $0003001F),
    ($007FE000, $01000000, $0004001F, $0005001F),
    ($007FE000, $01800000, $0006001F, $0007001F),
    ($0007E000, $20080000, $00002017, $00003017),
    ($0007E000, $20100000, $00004017, $00005017),
    ($0007E000, $20180000, $00006017, $00007017),
    ($001FE000, $20200000, $00008017, $0000C017),
    ($001FE000, $20400000, $00010017, $00014017),
    ($001FE000, $20600000, $00018017, $0001C017),
    ($007FE000, $20800000, $00020017, $00030017),
    ($007FE000, $21000000, $00040017, $00050017),
    ($007FE000, $21800000, $00060017, $00070017));
  ExtendedTLB: array[0..7, 0..3] of Cardinal = (
    ($0007E000, $30100000, $0000403F, $0000503F),
    ($0007E000, $30180000, $0000603F, $0000703F),
    ($001FE000, $30200000, $0000803F, $0000C03F),
    ($001FE000, $30400000, $0001003F, $0001403F),
    ($001FE000, $30600000, $0001803F, $0001C03F),
    ($007FE000, $30800000, $0002003F, $0003003F),
    ($007FE000, $31000000, $0004003F, $0005003F),
    ($007FE000, $31800000, $0006003F, $0007003F));

  // Thread status codes (ReferThreadStatus).
  THSRun = $01;
  THSReady = $02;
  THSWait = $04;
  THSSuspend = $08;
  THSDormant = $10;

  // Initial COP0 Status of user code: CU0-2, EDI, EIE, IM2/IM3, IE.
  ThreadStatus = $70030C01;

constructor TPS2Kernel.Create(CPU: TEECPU; Bus: TPS2EEBus; Scheduler: TPS2Scheduler);
begin
  inherited Create;
  FCPU := CPU;
  FBus := Bus;
  FScheduler := Scheduler;
  FIntcOrder := TList<Integer>.Create;
  FDmacOrder := TList<Integer>.Create;
  FCalls := TList<TPS2GuestCall>.Create;
  FUnknown := TStringList.Create;
  FUnknown.Sorted := True;
  FUnknown.Duplicates := dupIgnore;
  FLineCycles := 18743;
  CPU.OnSyscall := Syscall;
  CPU.OnTrap := Trap;
  Reset;
end;

destructor TPS2Kernel.Destroy;
begin
  FIntcOrder.Free;
  FDmacOrder.Free;
  FCalls.Free;
  FUnknown.Free;
  inherited;
end;

procedure TPS2Kernel.Reset;
begin
  FillChar(FThreads, SizeOf(FThreads), 0);
  FillChar(FSemas, SizeOf(FSemas), 0);
  FillChar(FIntc, SizeOf(FIntc), 0);
  FillChar(FDmac, SizeOf(FDmac), 0);
  FillChar(FAlarms, SizeOf(FAlarms), 0);
  FillChar(FSysRegs, SizeOf(FSysRegs), 0);
  FillChar(FDeci2, SizeOf(FDeci2), 0);
  FIntcOrder.Clear;
  FDmacOrder.Clear;
  FCalls.Clear;
  FCurrent := -1;
  FSeq := 0;
  FInInterrupt := False;
  FCPU.SetIntBlock(False);
  FNeedSchedule := False;
  FInCustom := False;
  FVSyncFlag1 := 0;
  FVSyncFlag2 := 0;
  FSifDmaId := 0;
  FIdle := False;
  FExited := False;
  FExitCode := 0;
  FGsIMR := $FF00;
  FCrtMode := 2;
  FCrtInterlace := 1;
  FCrtField := 1;
  FScheduler.Cancel(TPS2Event.Alarm);
  SetupKernelMemory;
end;

procedure TPS2Kernel.SetLineCycles(Cycles: Int64);
begin
  FLineCycles := Cycles;
end;

procedure TPS2Kernel.SetOsdConfig2(const Data: array of Byte);
begin
  FillChar(FOsdConfig2, SizeOf(FOsdConfig2), 0);
  for var K := 0 to Min(High(Data), High(FOsdConfig2)) do
    FOsdConfig2[K] := Data[K];
end;

function TPS2Kernel.OsdConfig2: TBytes;
begin
  SetLength(Result, Length(FOsdConfig2));
  Move(FOsdConfig2[0], Result[0], Length(FOsdConfig2));
end;

function TPS2Kernel.Arg(N: Integer): Cardinal;
begin
  Result := Cardinal(FCPU.S.GPR[4 + N].Lo);
end;

procedure TPS2Kernel.Ret(Value: Integer);
begin
  FCPU.S.GPR[ReturnReg].Lo := UInt64(Int64(Value));
end;

function TPS2Kernel.ReadU32(Address: Cardinal): Cardinal;
var
  V: UInt64;
begin
  if FCPU.ReadVirtual(Address, 4, V) then
    Result := Cardinal(V)
  else
    Result := 0;
end;

procedure TPS2Kernel.WriteU32(Address, Value: Cardinal);
begin
  FCPU.WriteVirtual(Address, 4, Value);
end;

function TPS2Kernel.ReadString(Address: Cardinal; Max: Integer): string;
var
  V: UInt64;
begin
  Result := '';
  var B: TBytes;
  while Length(B) < Max do
  begin
    if not FCPU.ReadVirtual(Address, 1, V) or (V = 0) then
      Break;
    B := B + [Byte(V)];
    Inc(Address);
  end;
  Result := TEncoding.ANSI.GetString(B);
end;

procedure TPS2Kernel.WriteTrap(Address, Index: Cardinal);
begin
  PCardinal(FBus.RAM + (Address and $1FFFFFFF))^ := TrapOpcode or Index;
end;

procedure TPS2Kernel.SetupKernelMemory;
begin
  FillChar(FBus.RAM^, $80000, 0);
  WriteTrap($80000000, KernelTrapRefill);
  WriteTrap($80000080, KernelTrapException);
  WriteTrap($80000100, KernelTrapException);
  WriteTrap($80000180, KernelTrapException);
  WriteTrap($80000200, KernelTrapInterrupt);
  WriteTrap(KernelHandlerReturn, KernelTrapHandlerReturn);
  // Threads return here: ExitThread.
  PCardinal(FBus.RAM + (KernelThreadExit and $1FFFFFFF))^ := $24030023;
  PCardinal(FBus.RAM + ((KernelThreadExit + 4) and $1FFFFFFF))^ := $0000000C;
  WriteTrap(KernelCustomReturn, KernelTrapCustomReturn);
  // Idle loop: the trap, then branch back to it.
  WriteTrap(KernelIdle, KernelTrapIdle);
  PCardinal(FBus.RAM + ((KernelIdle + 4) and $1FFFFFFF))^ := $1000FFFE;
  PCardinal(FBus.RAM + ((KernelIdle + 8) and $1FFFFFFF))^ := 0;
  FBus.MarkRAM(0, $80000);
end;

procedure TPS2Kernel.SetupTLB;
var
  E: TEETLBEntry;
begin
  var Index := 0;
  for var K := 0 to High(KernelTLB) do
  begin
    E.PageMask := KernelTLB[K, 0];
    E.EntryHi := KernelTLB[K, 1];
    E.EntryLo0 := KernelTLB[K, 2];
    E.EntryLo1 := KernelTLB[K, 3];
    FCPU.WriteTLB(Index, E);
    Inc(Index);
  end;
  for var K := 0 to High(DefaultTLB) do
  begin
    E.PageMask := DefaultTLB[K, 0];
    E.EntryHi := DefaultTLB[K, 1];
    E.EntryLo0 := DefaultTLB[K, 2];
    E.EntryLo1 := DefaultTLB[K, 3];
    FCPU.WriteTLB(Index, E);
    Inc(Index);
  end;
  for var K := 0 to High(ExtendedTLB) do
  begin
    E.PageMask := ExtendedTLB[K, 0];
    E.EntryHi := ExtendedTLB[K, 1];
    E.EntryLo0 := ExtendedTLB[K, 2];
    E.EntryLo1 := ExtendedTLB[K, 3];
    FCPU.WriteTLB(Index, E);
    Inc(Index);
  end;
  FCPU.S.COP0[C0Wired] := Cardinal(Index);
  FCPU.S.COP0[C0Random] := 47;
end;

procedure TPS2Kernel.Boot(Entry: Cardinal; const ProgramName: string; const Args: TArray<string>);
begin
  Reset;
  SetupTLB;
  FProgramName := ProgramName;
  FArgs := Args;
  // Main thread (id 1) at the entry point; SetupThread completes it.
  FThreads[1] := Default(TPS2Thread);
  FThreads[1].State := TPS2ThreadState.Ready;
  FThreads[1].InitPriority := 0;
  FThreads[1].Priority := 0;
  FThreads[1].Func := Entry;
  FThreads[1].Stack := PS2RAMSize - $40000;
  FThreads[1].StackSize := $40000;
  FCurrent := 1;
  FCPU.S.PC := Entry;
  FCPU.S.COP0[C0Status] := ThreadStatus;
  FCPU.S.GPR[29].Lo := SX32(PS2RAMSize - $10);
  FCPU.SetInt0(False);
end;

{ Contexts and scheduling }

procedure TPS2Kernel.SaveContext(var C: TPS2Context);
begin
  Move(FCPU.S.GPR[0], C.GPR[0], SizeOf(C.GPR));
  C.HI := FCPU.S.HI;
  C.LO := FCPU.S.LO;
  C.SA := FCPU.S.SA;
  C.PC := FCPU.S.PC;
  C.ACC := FCPU.S.ACC;
  C.FCR31 := FCPU.S.FCR31;
  Move(FCPU.S.FPR[0], C.FPR[0], SizeOf(C.FPR));
end;

procedure TPS2Kernel.LoadContext(const C: TPS2Context);
begin
  Move(C.GPR[0], FCPU.S.GPR[0], SizeOf(C.GPR));
  FCPU.S.GPR[0] := Default(TPS2Reg128);
  FCPU.S.HI := C.HI;
  FCPU.S.LO := C.LO;
  FCPU.S.SA := C.SA;
  FCPU.S.PC := C.PC;
  FCPU.S.ACC := C.ACC;
  FCPU.S.FCR31 := C.FCR31;
  Move(C.FPR[0], FCPU.S.FPR[0], SizeOf(C.FPR));
end;

function TPS2Kernel.NextReady: Integer;
begin
  Result := -1;
  for var K := 1 to KernelMaxThreads - 1 do
    if FThreads[K].State = TPS2ThreadState.Ready then
      if (Result < 0) or (FThreads[K].Priority < FThreads[Result].Priority) or
        ((FThreads[K].Priority = FThreads[Result].Priority) and (FThreads[K].Seq < FThreads[Result].Seq)) then
        Result := K;
end;

procedure TPS2Kernel.MakeReady(Id: Integer);
begin
  FThreads[Id].State := TPS2ThreadState.Ready;
  Inc(FSeq);
  FThreads[Id].Seq := FSeq;
end;

procedure TPS2Kernel.SwitchTo(Id: Integer);
begin
  // The CPU holds the current thread (if it still runs or waits) or idles.
  if (FCurrent > 0) and (FThreads[FCurrent].State <> TPS2ThreadState.Free) then
    SaveContext(FThreads[FCurrent].Context);
  FCurrent := Id;
  LoadContext(FThreads[Id].Context);
  FCPU.S.COP0[C0Status] := ThreadStatus;
  FIdle := False;
end;

procedure TPS2Kernel.EnterIdle;
begin
  if (FCurrent > 0) and (FThreads[FCurrent].State <> TPS2ThreadState.Free) then
    SaveContext(FThreads[FCurrent].Context);
  FCurrent := -1;
  FCPU.S.PC := KernelIdle;
  FCPU.S.COP0[C0Status] := ThreadStatus;
end;

// The current thread may keep running (it is ready and no better thread is).
procedure TPS2Kernel.Schedule;
begin
  if FInInterrupt then
  begin
    FNeedSchedule := True;
    Exit;
  end;
  Reschedule;
end;

procedure TPS2Kernel.Reschedule;
begin
  var Best := NextReady;
  if (FCurrent > 0) and (FThreads[FCurrent].State = TPS2ThreadState.Ready) then
  begin
    // Running threads stay Ready with their sequence; a strictly better one
    // preempts.
    if (Best = FCurrent) or (Best < 0) or (FThreads[Best].Priority >= FThreads[FCurrent].Priority) then
      Exit;
  end;
  if Best < 0 then
    EnterIdle
  else if Best <> FCurrent then
    SwitchTo(Best);
end;

procedure TPS2Kernel.WakeThread(Id: Integer; Value: Integer);
begin
  FThreads[Id].WaitKind := 0;
  FThreads[Id].WaitId := 0;
  if Id = FCurrent then
    FCPU.S.GPR[ReturnReg].Lo := UInt64(Int64(Value))
  else
    FThreads[Id].Context.GPR[ReturnReg].Lo := UInt64(Int64(Value));
  if FThreads[Id].State = TPS2ThreadState.WaitSuspended then
    FThreads[Id].State := TPS2ThreadState.Suspended
  else
    MakeReady(Id);
end;

{ Interrupts }

procedure TPS2Kernel.Interrupt;
begin
  // Entered at the interrupt vector: EPC holds the interrupted PC.
  FCPU.S.PC := FCPU.S.COP0[C0EPC];
  if Trace <> nil then
    Trace.Add(Format('%d interrupt epc=%.8x cause=%x thread=%d ra=%.8x', [FScheduler.Now, FCPU.S.PC, FCPU.S.COP0[C0Cause],
      FCurrent, Cardinal(FCPU.S.GPR[31].Lo)]));
  SaveContext(FIntContext);
  FIntStatus := FCPU.S.COP0[C0Status];
  FInInterrupt := True;
  // Handlers do not nest, whatever they do to Status (some set EIE or
  // write Status before returning).
  FCPU.SetIntBlock(True);
  // The handlers run now even if the idle loop just asked to sleep.
  FIdle := False;
  FNeedSchedule := False;
  FCalls.Clear;
  var Cause := FCPU.S.COP0[C0Cause];
  // Alarms first (the kernel's INT0 source).
  var Now := FScheduler.Now;
  for var K := 0 to High(FAlarms) do
    if FAlarms[K].Used and (FAlarms[K].Due <= Now) then
    begin
      var C: TPS2GuestCall;
      C.Address := FAlarms[K].Callback;
      C.A0 := Cardinal(K);
      C.A1 := FAlarms[K].Time;
      C.A2 := FAlarms[K].Arg;
      C.GP := FAlarms[K].GP;
      C.Kind := 2;
      FAlarms[K].Used := False;
      FCalls.Add(C);
    end;
  FBus.SetKernelLine(False);
  UpdateAlarmEvent;
  if (Cause and EECauseIP2) <> 0 then
  begin
    var Pending := FBus.INTCStat and FBus.INTCMask;
    for var Bit := 0 to 14 do
      if (Pending and (Cardinal(1) shl Bit)) <> 0 then
      begin
        FBus.AcknowledgeIRQ(Bit);
        for var Id in FIntcOrder do
          if FIntc[Id].Used and FIntc[Id].Enabled and (FIntc[Id].Cause = Cardinal(Bit)) then
          begin
            var C: TPS2GuestCall;
            C.Address := FIntc[Id].Address;
            C.A0 := Cardinal(Bit);
            C.A1 := FIntc[Id].Arg;
            C.A2 := 0;
            C.GP := FIntc[Id].GP;
            C.Kind := 0;
            FCalls.Add(C);
          end;
      end;
  end;
  if (Cause and EECauseIP3) <> 0 then
  begin
    var Stat := FBus.DMAC.STAT;
    var Pending := Stat and (Stat shr 16) and $3FF;
    for var Ch := 0 to 9 do
      if (Pending and (Cardinal(1) shl Ch)) <> 0 then
      begin
        FBus.DMAC.Write($1000E010, Cardinal(1) shl Ch);
        for var Id in FDmacOrder do
          if FDmac[Id].Used and FDmac[Id].Enabled and (FDmac[Id].Cause = Cardinal(Ch)) then
          begin
            var C: TPS2GuestCall;
            C.Address := FDmac[Id].Address;
            C.A0 := Cardinal(Ch);
            C.A1 := FDmac[Id].Arg;
            C.A2 := 0;
            C.GP := FDmac[Id].GP;
            C.Kind := 1;
            FCalls.Add(C);
          end;
      end;
    // Stall and error interrupts: acknowledge.
    if (Stat and $E000 and (Stat shr 16)) <> 0 then
      FBus.DMAC.Write($1000E010, Stat and $E000);
  end;
  if (Cause and EECauseIP7) <> 0 then
    FCPU.S.COP0[C0Cause] := FCPU.S.COP0[C0Cause] and not Cardinal(EECauseIP7);
  FSkipCause := -1;
  StartNextCall;
end;

procedure TPS2Kernel.StartNextCall;
begin
  while FCalls.Count > 0 do
  begin
    var C := FCalls[0];
    FCalls.Delete(0);
    if (C.Kind <= 1) and (Integer(C.A0) + C.Kind * 64 = FSkipCause) then
      Continue;
    FCallKind := C.Kind;
    if Trace <> nil then
      Trace.Add(Format('%d call kind %d %.8x a0=%x', [FScheduler.Now, C.Kind, C.Address, C.A0]));
    FCPU.S.GPR[4].Lo := C.A0;
    FCPU.S.GPR[5].Lo := C.A1;
    FCPU.S.GPR[6].Lo := C.A2;
    FCPU.S.GPR[28].Lo := SX32(C.GP);
    FCPU.S.GPR[29].Lo := SX32(KernelInterruptStack - $40);
    FCPU.S.GPR[31].Lo := SX32(KernelHandlerReturn);
    FCPU.S.PC := C.Address;
    FCPU.S.COP0[C0Status] := ThreadStatus or EESREXL;
    FCallCause := Integer(C.A0);
    Exit;
  end;
  FinishInterrupt;
end;

procedure TPS2Kernel.FinishInterrupt;
begin
  FInInterrupt := False;
  LoadContext(FIntContext);
  if Trace <> nil then
    Trace.Add(Format('%d interrupt return pc=%.8x ra=%.8x', [FScheduler.Now, FCPU.S.PC, Cardinal(FCPU.S.GPR[31].Lo)]));
  FCPU.S.COP0[C0Status] := FIntStatus and not Cardinal(EESREXL);
  FCPU.SetIntBlock(False);
  if FNeedSchedule or (FCurrent < 0) then
  begin
    FNeedSchedule := False;
    // The interrupted thread (or the idle loop) is in the CPU again.
    if FCurrent < 0 then
    begin
      var Best := NextReady;
      if Best > 0 then
        SwitchTo(Best)
      else
        FCPU.S.PC := KernelIdle;
    end
    else
      Reschedule;
  end;
end;

procedure TPS2Kernel.Exception;
begin
  var Code := (FCPU.S.COP0[C0Cause] shr 2) and $1F;
  var Text := Format('EE exception %d at %.8x (bad address %.8x, thread %d) ra=%.8x sp=%.8x v0=%.8x a0=%.8x a1=%.8x'#10,
    [Code, FCPU.S.COP0[C0EPC], FCPU.S.COP0[C0BadVAddr], FCurrent, Cardinal(FCPU.S.GPR[31].Lo), Cardinal(FCPU.S.GPR[29].Lo),
    Cardinal(FCPU.S.GPR[2].Lo), Cardinal(FCPU.S.GPR[4].Lo), Cardinal(FCPU.S.GPR[5].Lo)]);
  Text := Text + '  last blocks:';
  for var K := 16 downto 1 do
    Text := Text + Format(' %.8x', [FCPU.PCHistory[(FCPU.PCHistoryPos - K) and 15]]);
  Text := Text + #10;
  if Assigned(FOnTTY) then
    FOnTTY(Text);
  FUnknown.Add(Format('exception %d', [Code]));
  // The faulting thread stops: it waits forever.
  FCPU.S.COP0[C0Status] := FCPU.S.COP0[C0Status] and not Cardinal(EESREXL);
  if FInInterrupt then
  begin
    StartNextCall;
    Exit;
  end;
  if FCurrent > 0 then
  begin
    FThreads[FCurrent].State := TPS2ThreadState.Waiting;
    FThreads[FCurrent].WaitKind := 3;
  end;
  Reschedule;
  if FCurrent < 0 then
    FCPU.S.PC := KernelIdle;
end;

procedure TPS2Kernel.Trap(CPU: TEECPU; Index: Cardinal);
begin
  if Trace <> nil then
    Trace.Add(Format('%d trap %d pc=%.8x epc=%.8x thread=%d', [FScheduler.Now, Index, FCPU.S.PC, FCPU.S.COP0[C0EPC],
      FCurrent]));
  case Index of
    KernelTrapInterrupt:
      Interrupt;
    KernelTrapHandlerReturn:
      begin
        // A custom syscall may end here instead of returning: the alarm patch
        // runs an alarm callback outside the timer 3 handler, and its
        // ResumeIntrDispatch (syscall 8) restores the handler's ra and sp and
        // returns from the handler.
        FInCustom := False;
        if (FCallKind <= 1) and (Integer(Cardinal(FCPU.S.GPR[2].Lo)) < 0) then
          FSkipCause := FCallCause + FCallKind * 64;
        if FInInterrupt then
          StartNextCall
        else
          Reschedule;
      end;
    KernelTrapCustomReturn:
      begin
        FCPU.S.PC := FCustomReturn;
        FCPU.S.GPR[31].Lo := FCustomRA;
        FCPU.S.COP0[C0Status] := FCustomStatus;
        FInCustom := False;
      end;
    KernelTrapIdle:
      begin
        FIdle := True;
        FCPU.RequestExit;
        FCPU.S.PC := KernelIdle;
      end;
    KernelTrapException, KernelTrapRefill:
      Exception;
  end;
end;

procedure TPS2Kernel.VBlankStart(OddField: Boolean);
begin
  // SetVSyncFlag: the flag becomes 1 and, with a second pointer, that gets
  // GS CSR. Once only: libgraph's sceGsSyncV passes pointers to its stack
  // and returns as soon as the flag is set.
  if FVSyncFlag1 <> 0 then
  begin
    WriteU32(FVSyncFlag1, 1);
    if FVSyncFlag2 <> 0 then
    begin
      var V: UInt64 := (FBus.Read($12001000, 8) and not UInt64(1 shl 13)) or (UInt64(Ord(OddField)) shl 13);
      FCPU.WriteVirtual(FVSyncFlag2, 8, V);
    end;
    FVSyncFlag1 := 0;
    FVSyncFlag2 := 0;
  end;
end;

procedure TPS2Kernel.UpdateAlarmEvent;
begin
  var Next := PS2Never;
  for var K := 0 to High(FAlarms) do
    if FAlarms[K].Used and (FAlarms[K].Due < Next) then
      Next := FAlarms[K].Due;
  if Next = PS2Never then
    FScheduler.Cancel(TPS2Event.Alarm)
  else
    FScheduler.Schedule(TPS2Event.Alarm, Next);
end;

procedure TPS2Kernel.AlarmEvent;
begin
  FBus.SetKernelLine(True);
end;

{ Handlers }

procedure TPS2Kernel.AddHandler(Kind: Integer);
begin
  var Cause := Arg(0);
  var Address := Arg(1);
  var Next := Integer(Arg(2));
  var HArg := Arg(3);
  var Id := -1;
  for var K := 1 to 127 do
    if ((Kind = 0) and not FIntc[K].Used) or ((Kind = 1) and not FDmac[K].Used) then
    begin
      Id := K;
      Break;
    end;
  if Id < 0 then
  begin
    Ret(-1);
    Exit;
  end;
  var H := Default(TPS2Handler);
  H.Used := True;
  H.Cause := Cause;
  H.Address := Address;
  H.Arg := HArg;
  H.GP := Cardinal(FCPU.S.GPR[28].Lo);
  H.Enabled := True;
  var Order := FIntcOrder;
  if Kind = 0 then
    FIntc[Id] := H
  else
  begin
    FDmac[Id] := H;
    Order := FDmacOrder;
  end;
  if Next = 0 then
    Order.Insert(0, Id)
  else if (Next < 0) or (Order.IndexOf(Next) < 0) then
    Order.Add(Id)
  else
    Order.Insert(Order.IndexOf(Next), Id);
  Ret(Id);
end;

procedure TPS2Kernel.RemoveHandler(Kind: Integer);
begin
  var Id := Integer(Arg(1));
  if (Id <= 0) or (Id > 127) then
  begin
    Ret(-1);
    Exit;
  end;
  if Kind = 0 then
  begin
    FIntc[Id].Used := False;
    FIntcOrder.Remove(Id);
  end
  else
  begin
    FDmac[Id].Used := False;
    FDmacOrder.Remove(Id);
  end;
  Ret(0);
end;

procedure TPS2Kernel.EnableHandler(Kind: Integer; Enable: Boolean);
begin
  var Id := Integer(Arg(1));
  if (Id <= 0) or (Id > 127) then
  begin
    Ret(-1);
    Exit;
  end;
  if Kind = 0 then
    FIntc[Id].Enabled := Enable
  else
    FDmac[Id].Enabled := Enable;
  Ret(0);
end;

procedure TPS2Kernel.EnableIntc(Cause: Cardinal; Enable: Boolean);
begin
  if Cause > 14 then
  begin
    Ret(0);
    Exit;
  end;
  var Bit := Cardinal(1) shl Cause;
  var Was := (FBus.INTCMask and Bit) <> 0;
  if Enable then
    FBus.SetINTCMask(FBus.INTCMask or Bit)
  else
    FBus.SetINTCMask(FBus.INTCMask and not Bit);
  Ret(Ord(Was <> Enable));
end;

procedure TPS2Kernel.EnableDmac(Channel: Cardinal; Enable: Boolean);
begin
  if Channel > 15 then
  begin
    Ret(0);
    Exit;
  end;
  var Bit := Cardinal(1) shl (Channel + 16);
  var Was := (FBus.DMAC.STAT and Bit) <> 0;
  if Was <> Enable then
    FBus.DMAC.Write($1000E010, Bit);
  Ret(Ord(Was <> Enable));
end;

{ Threads }

procedure TPS2Kernel.SetupThread;
begin
  // SetupThread(gp, stack, stack_size, args, root): the stack ends at
  // stack + size, or at the end of RAM for stack -1; returns its top.
  var Stack := Arg(1);
  var Size := Arg(2);
  var ArgsAddr := Arg(3);
  var Top: Cardinal;
  if Stack = $FFFFFFFF then
    Top := PS2RAMSize
  else
    Top := Stack + Size;
  if FCurrent > 0 then
  begin
    FThreads[FCurrent].Stack := Top - Size;
    FThreads[FCurrent].StackSize := Size;
    FThreads[FCurrent].GP := Arg(0);
  end;
  if ArgsAddr <> 0 then
  begin
    // argc, argv[], then the strings.
    var List := [FProgramName] + FArgs;
    var Count := Length(List);
    if Count > 16 then
      Count := 16;
    WriteU32(ArgsAddr, Cardinal(Count));
    var Payload := ArgsAddr + 4 + Cardinal(Count) * 4;
    for var K := 0 to Count - 1 do
    begin
      WriteU32(ArgsAddr + 4 + Cardinal(K) * 4, Payload);
      var B := TEncoding.ANSI.GetBytes(List[K]);
      for var J := 0 to High(B) do
        FCPU.WriteVirtual(Payload + Cardinal(J), 1, B[J]);
      FCPU.WriteVirtual(Payload + Cardinal(Length(B)), 1, 0);
      Payload := Payload + Cardinal(Length(B)) + 1;
    end;
  end;
  Ret(Integer(Top));
end;

procedure TPS2Kernel.CreateThread;
begin
  var P := Arg(0);
  var Id := -1;
  for var K := 1 to KernelMaxThreads - 1 do
    if FThreads[K].State = TPS2ThreadState.Free then
    begin
      Id := K;
      Break;
    end;
  if Id < 0 then
  begin
    Ret(-1);
    Exit;
  end;
  var T := Default(TPS2Thread);
  T.State := TPS2ThreadState.Dormant;
  T.Func := ReadU32(P + 4);
  T.Stack := ReadU32(P + 8);
  T.StackSize := ReadU32(P + 12);
  T.GP := ReadU32(P + 16);
  T.InitPriority := ReadU32(P + 20);
  T.Priority := T.InitPriority;
  T.Attr := ReadU32(P + 28);
  T.Option := ReadU32(P + 32);
  FThreads[Id] := T;
  Ret(Id);
end;

procedure TPS2Kernel.StartThread;
begin
  var Id := Integer(Arg(0));
  if (Id <= 0) or (Id >= KernelMaxThreads) or (FThreads[Id].State <> TPS2ThreadState.Dormant) then
  begin
    Ret(-1);
    Exit;
  end;
  var C := Default(TPS2Context);
  C.PC := FThreads[Id].Func;
  C.GPR[4].Lo := SX32(Arg(1));
  C.GPR[28].Lo := SX32(FThreads[Id].GP);
  C.GPR[29].Lo := SX32(FThreads[Id].Stack + FThreads[Id].StackSize - StackReserve);
  C.GPR[31].Lo := SX32(KernelThreadExit);
  C.FCR31 := $01000001;
  FThreads[Id].Context := C;
  FThreads[Id].Priority := FThreads[Id].InitPriority;
  FThreads[Id].WakeupCount := 0;
  MakeReady(Id);
  Ret(Id);
  Schedule;
end;

procedure TPS2Kernel.ReferThreadStatus;
begin
  var Id := Integer(Arg(0));
  var P := Arg(1);
  if Id = 0 then
    Id := FCurrent;
  if (Id <= 0) or (Id >= KernelMaxThreads) then
  begin
    Ret(-1);
    Exit;
  end;
  var Code: Integer;
  case FThreads[Id].State of
    // A deleted (or never created) thread's slot reads as status 0: games
    // wait for a helper thread to be gone by polling for 0.
    TPS2ThreadState.Free: Code := 0;
    TPS2ThreadState.Ready:
      if Id = FCurrent then
        Code := THSRun
      else
        Code := THSReady;
    TPS2ThreadState.Waiting: Code := THSWait;
    TPS2ThreadState.Suspended: Code := THSSuspend;
    TPS2ThreadState.WaitSuspended: Code := THSWait or THSSuspend;
  else
    Code := THSDormant;
  end;
  if P <> 0 then
  begin
    WriteU32(P, Cardinal(Code));
    WriteU32(P + 4, FThreads[Id].Func);
    WriteU32(P + 8, FThreads[Id].Stack);
    WriteU32(P + 12, FThreads[Id].StackSize);
    WriteU32(P + 16, FThreads[Id].GP);
    WriteU32(P + 20, FThreads[Id].InitPriority);
    WriteU32(P + 24, FThreads[Id].Priority);
    WriteU32(P + 28, FThreads[Id].Attr);
    WriteU32(P + 32, FThreads[Id].Option);
    var WaitType := 0;
    if FThreads[Id].State in [TPS2ThreadState.Waiting, TPS2ThreadState.WaitSuspended] then
      WaitType := FThreads[Id].WaitKind;
    WriteU32(P + 36, Cardinal(WaitType));
    WriteU32(P + 40, Cardinal(FThreads[Id].WaitId));
    WriteU32(P + 44, Cardinal(FThreads[Id].WakeupCount));
  end;
  Ret(Code);
end;

{ Semaphores }

procedure TPS2Kernel.CreateSema;
begin
  var P := Arg(0);
  var Id := -1;
  for var K := 1 to KernelMaxSemas - 1 do
    if not FSemas[K].Used then
    begin
      Id := K;
      Break;
    end;
  if Id < 0 then
  begin
    Ret(-1);
    Exit;
  end;
  FSemas[Id].Used := True;
  FSemas[Id].MaxCount := Integer(ReadU32(P + 4));
  FSemas[Id].InitCount := Integer(ReadU32(P + 8));
  FSemas[Id].Count := FSemas[Id].InitCount;
  FSemas[Id].Attr := ReadU32(P + 16);
  FSemas[Id].Option := ReadU32(P + 20);
  Ret(Id);
end;

procedure TPS2Kernel.WaitSema(Poll: Boolean);
begin
  var Id := Integer(Arg(0));
  if (Id <= 0) or (Id >= KernelMaxSemas) or not FSemas[Id].Used then
  begin
    Ret(-1);
    Exit;
  end;
  if FSemas[Id].Count > 0 then
  begin
    Dec(FSemas[Id].Count);
    Ret(Id);
    Exit;
  end;
  if Poll or FInInterrupt or (FCurrent <= 0) then
  begin
    Ret(-1);
    Exit;
  end;
  Ret(Id);
  FThreads[FCurrent].State := TPS2ThreadState.Waiting;
  FThreads[FCurrent].WaitKind := 2;
  FThreads[FCurrent].WaitId := Id;
  Inc(FSeq);
  FThreads[FCurrent].WaitSeq := FSeq;
  Reschedule;
end;

procedure TPS2Kernel.SignalSema;
begin
  var Id := Integer(Arg(0));
  if (Id <= 0) or (Id >= KernelMaxSemas) or not FSemas[Id].Used then
  begin
    Ret(-1);
    Exit;
  end;
  // The first waiter in wait order gets it.
  var Best := -1;
  for var K := 1 to KernelMaxThreads - 1 do
    if (FThreads[K].State in [TPS2ThreadState.Waiting, TPS2ThreadState.WaitSuspended]) and
      (FThreads[K].WaitKind = 2) and (FThreads[K].WaitId = Id) then
      if (Best < 0) or (FThreads[K].WaitSeq < FThreads[Best].WaitSeq) then
        Best := K;
  Ret(Id);
  if Best > 0 then
  begin
    WakeThread(Best, Id);
    Schedule;
  end
  else
    Inc(FSemas[Id].Count);
end;

procedure TPS2Kernel.ReferSemaStatus;
begin
  var Id := Integer(Arg(0));
  var P := Arg(1);
  if (Id <= 0) or (Id >= KernelMaxSemas) or not FSemas[Id].Used then
  begin
    Ret(-1);
    Exit;
  end;
  var Waiting := 0;
  for var K := 1 to KernelMaxThreads - 1 do
    if (FThreads[K].State in [TPS2ThreadState.Waiting, TPS2ThreadState.WaitSuspended]) and
      (FThreads[K].WaitKind = 2) and (FThreads[K].WaitId = Id) then
      Inc(Waiting);
  if P <> 0 then
  begin
    WriteU32(P, Cardinal(FSemas[Id].Count));
    WriteU32(P + 4, Cardinal(FSemas[Id].MaxCount));
    WriteU32(P + 8, Cardinal(FSemas[Id].InitCount));
    WriteU32(P + 12, Cardinal(Waiting));
    WriteU32(P + 16, FSemas[Id].Attr);
    WriteU32(P + 20, FSemas[Id].Option);
  end;
  Ret(Id);
end;

procedure TPS2Kernel.SetAlarm;
begin
  var Id := -1;
  for var K := 0 to High(FAlarms) do
    if not FAlarms[K].Used then
    begin
      Id := K;
      Break;
    end;
  if Id < 0 then
  begin
    Ret(-1);
    Exit;
  end;
  FAlarms[Id].Used := True;
  FAlarms[Id].Time := Arg(0) and $FFFF;
  FAlarms[Id].Callback := Arg(1);
  FAlarms[Id].Arg := Arg(2);
  FAlarms[Id].GP := Cardinal(FCPU.S.GPR[28].Lo);
  FAlarms[Id].Due := FScheduler.Now + Int64(FAlarms[Id].Time) * FLineCycles;
  UpdateAlarmEvent;
  Ret(Id);
end;

procedure TPS2Kernel.SifSetDma;
begin
  var P := Arg(0);
  var Count := Integer(Arg(1));
  for var K := 0 to Count - 1 do
  begin
    var Src := ReadU32(P + Cardinal(K) * 16);
    var Dest := ReadU32(P + Cardinal(K) * 16 + 4);
    var Size := Integer(ReadU32(P + Cardinal(K) * 16 + 8));
    var Attr := ReadU32(P + Cardinal(K) * 16 + 12);
    if Trace <> nil then
      Trace.Add(Format('%d sifdma %.8x -> %.8x size %x attr %x', [FScheduler.Now, Src, Dest, Size, Attr]));
    // Source addresses are EE virtual (KSEG, user or uncached RAM views).
    var Host := FCPU.HostPointer(Src);
    if (Host <> nil) and (NativeUInt(Host) >= NativeUInt(FBus.RAM)) and
      (NativeUInt(Host) < NativeUInt(FBus.RAM) + PS2RAMSize) then
      FBus.SIF.EEToIOP(Cardinal(NativeUInt(Host) - NativeUInt(FBus.RAM)), Dest, Size, Attr)
    else if FUnknown.IndexOf(Format('SifSetDma from %.8x', [Src])) < 0 then
      FUnknown.Add(Format('SifSetDma from %.8x', [Src]));
  end;
  Inc(FSifDmaId);
  if FSifDmaId = 0 then
    FSifDmaId := 1;
  Ret(Integer(FSifDmaId));
end;

function TPS2Kernel.Custom(Index: Cardinal): Cardinal;
begin
  Result := PCardinal(FBus.RAM + KernelSyscallTable + (Index and $FF) * 4)^;
end;

procedure TPS2Kernel.CallCustom(Index: Cardinal);
begin
  FCustomReturn := FCPU.S.PC;
  FCustomRA := FCPU.S.GPR[31].Lo;
  FCustomStatus := FCPU.S.COP0[C0Status];
  FInCustom := True;
  FCPU.S.GPR[31].Lo := SX32(KernelCustomReturn);
  FCPU.S.PC := Custom(Index);
  FCPU.S.COP0[C0Status] := FCustomStatus or EESREXL;
end;

procedure TPS2Kernel.Unknown(Code: Integer);
begin
  FUnknown.Add(Format('syscall %d (%.2x)', [Code, Code and $FF]));
  Ret(0);
end;

procedure TPS2Kernel.Syscall(CPU: TEECPU);
begin
  var Code := Integer(Cardinal(FCPU.S.GPR[3].Lo));
  var Index := Cardinal(Abs(Code)) and $FF;
  Inc(SyscallCounts[Index]);
  if (Index = $7C) and (Arg(0) <= 16) then
    Inc(Deci2Counts[Arg(0)]);
  if Trace <> nil then
    Trace.Add(Format('%d syscall %x a0=%x a1=%x a2=%x pc=%.8x ra=%.8x thread=%d custom=%x w=%.8x', [FScheduler.Now, Code,
      Arg(0), Arg(1), Arg(2), FCPU.S.PC, Cardinal(FCPU.S.GPR[31].Lo), FCurrent, Custom(Index),
      PCardinal(FBus.RAM + (WatchAddress and PS2RAMMask and not Cardinal(3)))^]));
  if (Custom(Index) <> 0) and not FInCustom then
  begin
    CallCustom(Index);
    Exit;
  end;
  case Abs(Code) of
    $01: // ResetEE
      Ret(0);
    $02: // SetGsCrt(interlace, mode, ffmd)
      begin
        FCrtInterlace := Arg(0);
        FCrtMode := Arg(1);
        FCrtField := Arg(2);
        if Assigned(FOnCrtChange) then
          FOnCrtChange();
        Ret(0);
      end;
    $04: // Exit
      begin
        FExited := True;
        FExitCode := Integer(Arg(0));
        if FCurrent > 0 then
          FThreads[FCurrent].State := TPS2ThreadState.Dormant;
        EnterIdle;
        FCurrent := -1;
      end;
    $06: // LoadExecPS2(filename, argc, argv)
      begin
        var Path := ReadString(Arg(0));
        var Args: TArray<string>;
        for var K := 0 to Integer(Arg(1)) - 1 do
          Args := Args + [ReadString(ReadU32(Arg(2) + Cardinal(K) * 4))];
        if Assigned(FOnLoadExec) then
          FOnLoadExec(Path, Args)
        else
          Ret(-1);
      end;
    $07: // ExecPS2(entry, gp, argc, argv)
      begin
        var Entry := Arg(0);
        var GP := Arg(1);
        var Args: TArray<string>;
        for var K := 0 to Integer(Arg(2)) - 1 do
          Args := Args + [ReadString(ReadU32(Arg(3) + Cardinal(K) * 4))];
        var Name := FProgramName;
        Boot(Entry, Name, Args);
        FCPU.S.GPR[28].Lo := SX32(GP);
      end;
    $0D, $0E, $0F: // SetVTLBRefillHandler, SetVCommonHandler, SetVInterruptHandler
      Ret(0);
    $10: AddHandler(0);
    $11: RemoveHandler(0);
    $12: AddHandler(1);
    $13: RemoveHandler(1);
    $14: EnableIntc(Arg(0), True);
    $15: EnableIntc(Arg(0), False);
    $16: EnableDmac(Arg(0), True);
    $17: EnableDmac(Arg(0), False);
    $18, $FC: SetAlarm;
    $19, $FE:
      begin
        var Id := Integer(Arg(0));
        if (Id >= 0) and (Id <= High(FAlarms)) and FAlarms[Id].Used then
        begin
          FAlarms[Id].Used := False;
          UpdateAlarmEvent;
          Ret(Id);
        end
        else
          Ret(-1);
      end;
    $1A: EnableIntc(Arg(0), True);
    $1B: EnableIntc(Arg(0), False);
    $1C: EnableDmac(Arg(0), True);
    $1D: EnableDmac(Arg(0), False);
    $1E, $FD: SetAlarm;
    $1F, $FF:
      begin
        var Id := Integer(Arg(0));
        if (Id >= 0) and (Id <= High(FAlarms)) and FAlarms[Id].Used then
        begin
          FAlarms[Id].Used := False;
          UpdateAlarmEvent;
          Ret(Id);
        end
        else
          Ret(-1);
      end;
    $20: CreateThread;
    $21: // DeleteThread
      begin
        var Id := Integer(Arg(0));
        if (Id <= 0) or (Id >= KernelMaxThreads) or (Id = FCurrent) or
          (FThreads[Id].State <> TPS2ThreadState.Dormant) then
          Ret(-1)
        else
        begin
          FThreads[Id].State := TPS2ThreadState.Free;
          Ret(Id);
        end;
      end;
    $22: StartThread;
    $23, $24: // ExitThread, ExitDeleteThread
      begin
        if FCurrent > 0 then
        begin
          if Abs(Code) = $24 then
            FThreads[FCurrent].State := TPS2ThreadState.Free
          else
            FThreads[FCurrent].State := TPS2ThreadState.Dormant;
          FThreads[FCurrent].Priority := FThreads[FCurrent].InitPriority;
          FCurrent := -1;
        end;
        Reschedule;
        if FCurrent < 0 then
          FCPU.S.PC := KernelIdle;
      end;
    $25, $26: // TerminateThread
      begin
        var Id := Integer(Arg(0));
        if (Id <= 0) or (Id >= KernelMaxThreads) or (Id = FCurrent) or
          (FThreads[Id].State in [TPS2ThreadState.Free, TPS2ThreadState.Dormant]) then
          Ret(-1)
        else
        begin
          FThreads[Id].State := TPS2ThreadState.Dormant;
          FThreads[Id].Priority := FThreads[Id].InitPriority;
          FThreads[Id].WaitKind := 0;
          Ret(Id);
        end;
      end;
    $27, $28: Ret(0); // Disable/EnableDispatchThread
    $29, $2A: // ChangeThreadPriority
      begin
        var Id := Integer(Arg(0));
        if Id = 0 then
          Id := FCurrent;
        if (Id <= 0) or (Id >= KernelMaxThreads) or (FThreads[Id].State = TPS2ThreadState.Free) or
          (Arg(1) > 127) then
          Ret(-1)
        else
        begin
          var Old := FThreads[Id].Priority;
          FThreads[Id].Priority := Arg(1);
          if FThreads[Id].State = TPS2ThreadState.Ready then
            MakeReady(Id);
          Ret(Integer(Old));
          if Code > 0 then
          begin
            // The current thread may now lose to an equal or better one.
            if (Id = FCurrent) and not FInInterrupt then
            begin
              var Best := NextReady;
              if (Best > 0) and (Best <> FCurrent) and (FThreads[Best].Priority <= FThreads[FCurrent].Priority) and
                (FThreads[Best].Priority < Old) then
                SwitchTo(Best)
              else
                Schedule;
            end
            else
              Schedule;
          end
          else
            Schedule;
        end;
      end;
    $2B, $2C: // RotateThreadReadyQueue(prio)
      begin
        var Prio := Arg(0);
        var First := -1;
        for var K := 1 to KernelMaxThreads - 1 do
          if (FThreads[K].State = TPS2ThreadState.Ready) and (FThreads[K].Priority = Prio) then
            if (First < 0) or (FThreads[K].Seq < FThreads[First].Seq) then
              First := K;
        if First > 0 then
          MakeReady(First);
        Ret(Integer(Prio));
        if FInInterrupt then
          FNeedSchedule := True
        else
        begin
          var Best := NextReady;
          if (Best > 0) and (Best <> FCurrent) then
            SwitchTo(Best);
        end;
      end;
    $2D, $2E: // ReleaseWaitThread
      begin
        var Id := Integer(Arg(0));
        if (Id <= 0) or (Id >= KernelMaxThreads) or
          not (FThreads[Id].State in [TPS2ThreadState.Waiting, TPS2ThreadState.WaitSuspended]) then
          Ret(-1)
        else
        begin
          WakeThread(Id, -418);
          Ret(Id);
          Schedule;
        end;
      end;
    $2F: Ret(FCurrent);
    $30, $31: ReferThreadStatus;
    $32: // SleepThread
      begin
        if FCurrent <= 0 then
          Ret(-1)
        else if FThreads[FCurrent].WakeupCount > 0 then
        begin
          Dec(FThreads[FCurrent].WakeupCount);
          Ret(FCurrent);
        end
        else
        begin
          Ret(FCurrent);
          FThreads[FCurrent].State := TPS2ThreadState.Waiting;
          FThreads[FCurrent].WaitKind := 1;
          Reschedule;
        end;
      end;
    $33, $34: // WakeupThread
      begin
        var Id := Integer(Arg(0));
        if (Id <= 0) or (Id >= KernelMaxThreads) or (Id = FCurrent) or
          (FThreads[Id].State in [TPS2ThreadState.Free, TPS2ThreadState.Dormant]) then
          Ret(-1)
        else
        begin
          Ret(Id);
          if (FThreads[Id].State in [TPS2ThreadState.Waiting, TPS2ThreadState.WaitSuspended]) and
            (FThreads[Id].WaitKind = 1) then
          begin
            WakeThread(Id, Id);
            Schedule;
          end
          else
            Inc(FThreads[Id].WakeupCount);
        end;
      end;
    $35, $36: // CancelWakeupThread
      begin
        var Id := Integer(Arg(0));
        if Id = 0 then
          Id := FCurrent;
        if (Id <= 0) or (Id >= KernelMaxThreads) or (FThreads[Id].State = TPS2ThreadState.Free) then
          Ret(-1)
        else
        begin
          Ret(FThreads[Id].WakeupCount);
          FThreads[Id].WakeupCount := 0;
        end;
      end;
    $37, $38: // SuspendThread
      begin
        var Id := Integer(Arg(0));
        if (Id = 0) and not FInInterrupt then
          Id := FCurrent;
        if (Id <= 0) or (Id >= KernelMaxThreads) then
          Ret(-1)
        else
          case FThreads[Id].State of
            TPS2ThreadState.Ready:
              begin
                // The current thread keeps running until it next waits.
                FThreads[Id].State := TPS2ThreadState.Suspended;
                Ret(Id);
              end;
            TPS2ThreadState.Waiting:
              begin
                FThreads[Id].State := TPS2ThreadState.WaitSuspended;
                Ret(Id);
              end;
          else
            Ret(-1);
          end;
      end;
    $39, $3A: // ResumeThread
      begin
        var Id := Integer(Arg(0));
        if (Id <= 0) or (Id >= KernelMaxThreads) then
          Ret(-1)
        else
          case FThreads[Id].State of
            TPS2ThreadState.Suspended:
              begin
                MakeReady(Id);
                Ret(Id);
                Schedule;
              end;
            TPS2ThreadState.WaitSuspended:
              begin
                FThreads[Id].State := TPS2ThreadState.Waiting;
                Ret(Id);
              end;
          else
            Ret(-1);
          end;
      end;
    $3C: SetupThread;
    $3D: // SetupHeap(start, size)
      begin
        var Start := Arg(0);
        var Size := Arg(1);
        var Top := Add32(Start, Size);
        if (Size = $FFFFFFFF) and (FCurrent > 0) then
          Top := FThreads[FCurrent].Stack;
        FHeapEnd := Top;
        Ret(Integer(Top));
      end;
    $3E: // EndOfHeap
      Ret(Integer(FHeapEnd));
    $40: CreateSema;
    $41, $49: // DeleteSema
      begin
        var Id := Integer(Arg(0));
        if (Id <= 0) or (Id >= KernelMaxSemas) or not FSemas[Id].Used then
          Ret(-1)
        else
        begin
          FSemas[Id].Used := False;
          for var K := 1 to KernelMaxThreads - 1 do
            if (FThreads[K].State in [TPS2ThreadState.Waiting, TPS2ThreadState.WaitSuspended]) and
              (FThreads[K].WaitKind = 2) and (FThreads[K].WaitId = Id) then
              WakeThread(K, -1);
          Ret(Id);
          Schedule;
        end;
      end;
    $42, $43: SignalSema;
    $44: WaitSema(False);
    $45, $46: WaitSema(True);
    $47, $48: ReferSemaStatus;
    $4A: // SetOsdConfigParam
      begin
        FOsdConfig := ReadU32(Arg(0));
        Ret(0);
      end;
    $4B: // GetOsdConfigParam
      begin
        WriteU32(Arg(0), FOsdConfig);
        Ret(0);
      end;
    $4C, $4D, $4E, $4F: Ret(0);
    $5A: // Copy (kCopy): dest, src, size
      begin
        var D := Arg(0);
        var Src := Arg(1);
        var N := Integer(Arg(2));
        for var K := 0 to (N div 4) - 1 do
          WriteU32(D + Cardinal(K) * 4, ReadU32(Src + Cardinal(K) * 4));
        Ret(0);
      end;
    $5B: Ret(0); // GetEntryAddress
    $5C, $5D: EnableHandler(0, Abs(Code) = $5C);
    $5E, $5F: EnableHandler(1, Abs(Code) = $5E);
    $60: Ret(0); // KSeg0
    $61, $62: Ret(0);
    $63, $67: Ret(Integer(FCPU.S.COP0[Arg(0) and 31])); // GetCop0
    $64, $68: // FlushCache
      begin
        if Arg(0) = 2 then
          FCPU.InvalidateBlocks;
        Ret(0);
      end;
    $66, $6A: Ret(Integer(FCPU.S.COP0[C0Config]));
    $6B: // SifStopDma
      begin
        FBus.DMAC.Write($1000C000, FBus.DMAC.Ch[DMASIF0].CHCR and not Cardinal(CHCRSTR));
        Ret(0);
      end;
    $6E, $6F: // SetOsdConfigParam2, GetOsdConfigParam2 (buffer, size, offset)
      begin
        // Only the part inside the 128-byte area moves.
        var Offset := Integer(Arg(2));
        var First := Integer(EnsureRange(Int64(Offset), 0, Length(FOsdConfig2)));
        var Last := Integer(EnsureRange(Int64(Offset) + Integer(Arg(1)), 0, Length(FOsdConfig2)));
        for var K := First to Last - 1 do
        begin
          var At := Add32(Arg(0), Cardinal((Int64(K) - Offset) and $FFFFFFFF));
          if Abs(Code) = $6E then
          begin
            var V: UInt64 := 0;
            FCPU.ReadVirtual(At, 1, V);
            FOsdConfig2[K] := Byte(V);
          end
          else
            FCPU.WriteVirtual(At, 1, FOsdConfig2[K]);
        end;
        Ret(0);
      end;
    $70: Ret(Integer(Cardinal(FGsIMR))); // GsGetIMR
    $71: // GsPutIMR
      begin
        FGsIMR := Arg(0);
        FBus.GS.Write($12001010, FGsIMR, 8);
        Ret(0);
      end;
    $73: // SetVSyncFlag
      begin
        FVSyncFlag1 := Arg(0);
        FVSyncFlag2 := Arg(1);
        Ret(0);
      end;
    $74: // SetSyscall(index, address)
      begin
        var N := Arg(0);
        if N < $100 then
          PCardinal(FBus.RAM + KernelSyscallTable + N * 4)^ := Arg(1)
        else if N = $12C then
        begin
          // Out of range: lands on the INTC handler of timer 3.
          var Saved := FCPU.S.GPR[4].Lo;
          FCPU.S.GPR[4].Lo := 12;
          FCPU.S.GPR[6].Lo := 0;
          FCPU.S.GPR[7].Lo := 0;
          AddHandler(0);
          FCPU.S.GPR[4].Lo := Saved;
          EnableIntc(12, True);
        end;
        Ret(0);
      end;
    $75: // _print
      begin
        if Assigned(FOnTTY) then
          FOnTTY(ReadString(Arg(0)));
        Ret(0);
      end;
    $76: Ret(-1); // SifDmaStat: transfers complete at once
    $77: SifSetDma;
    $78: // SifSetDChain: arm SIF0
      begin
        FBus.DMAC.Ch[DMASIF0].QWC := 0;
        if (FBus.DMAC.Ch[DMASIF0].CHCR and CHCRSTR) = 0 then
          FBus.DMAC.Write($1000C000, $184);
        FScheduler.Schedule(TPS2Event.SIF, FScheduler.Now + 64);
        Ret(0);
      end;
    $79: // SifSetReg
      begin
        var Reg := Arg(0);
        if (Reg and $80000000) <> 0 then
          FSysRegs[Reg and 31] := Arg(1)
        else
          FBus.SIF.WriteRegister(Reg, Arg(1));
        Ret(0);
      end;
    $7A: // SifGetReg
      begin
        var Reg := Arg(0);
        if (Reg and $80000000) <> 0 then
          Ret(Integer(FSysRegs[Reg and 31]))
        else
          Ret(Integer(FBus.SIF.ReadRegister(Reg)));
      end;
    $7C:
      // Deci2Call(function, args) (ps2sdk deci2.c): open, close, request
      // send, poll, kputs. There is no DECI2 host: for a TTY client (area
      // {socket, bytes left, ?, busy, data} given at open) the kernel takes
      // the text (12-byte header with the 16-bit length, then the bytes) and
      // settles 'bytes left' and 'busy' as the client's handler would on
      // DECI2_WRITE and DECI2_WRITE_DONE.
      begin
        var P := Arg(1);
        case Arg(0) of
          1: // Open {device, buffer}
            begin
              var Id := -1;
              for var K := 0 to High(FDeci2) do
                if FDeci2[K] = 0 then
                begin
                  Id := K;
                  Break;
                end;
              if Id >= 0 then
                FDeci2[Id] := ReadU32(P + 4);
              Ret(Id);
            end;
          2: // Close
            begin
              var Id := Integer(ReadU32(P));
              if (Id >= 0) and (Id <= High(FDeci2)) then
                FDeci2[Id] := 0;
              Ret(1);
            end;
          3: // ReqSend: the data block {size, ?, ?, bytes}
            begin
              var Id := Integer(ReadU32(P));
              if (Id >= 0) and (Id <= High(FDeci2)) and (FDeci2[Id] <> 0) then
              begin
                var Buffer := FDeci2[Id];
                var Data := ReadU32(Buffer + 16);
                if Data <> 0 then
                begin
                  var Size := Integer(ReadU32(Data) and $FFFF);
                  if (Size >= 12) and (Size < 65536) and Assigned(FOnTTY) then
                  begin
                    var B: TBytes;
                    SetLength(B, Size - 12);
                    for var K := 0 to Size - 13 do
                    begin
                      var V: UInt64;
                      FCPU.ReadVirtual(Data + 12 + Cardinal(K), 1, V);
                      B[K] := Byte(V);
                    end;
                    FOnTTY(TEncoding.ANSI.GetString(B));
                  end;
                  WriteU32(Buffer + 4, 0);
                end
                else
                  WriteU32(Buffer + 4, Cardinal(-1));
              end;
              Ret(1);
            end;
          4: // Poll
            begin
              var Id := Integer(ReadU32(P));
              if (Id >= 0) and (Id <= High(FDeci2)) and (FDeci2[Id] <> 0) then
                WriteU32(FDeci2[Id] + 12, 0);
              Ret(1);
            end;
          $10: // kputs
            begin
              if Assigned(FOnTTY) then
                FOnTTY(ReadString(ReadU32(P)));
              Ret(0);
            end;
        else
          Ret(0);
        end;
      end;
    $7D: Ret(0); // PSMode
    $7E: Ret(0); // MachineType
    $7F: Ret(PS2RAMSize); // GetMemorySize
    $80: Ret(0);
    $82: Ret(0); // _InitTLB
    $83: Ret(0);
    $85, $86: Ret(0);
  else
    Unknown(Code);
  end;
end;

function TPS2Kernel.DescribeThreads: TArray<string>;
const
  Names: array[TPS2ThreadState] of string = ('free', 'dormant', 'ready', 'waiting', 'suspended', 'waitsuspended');
begin
  Result := nil;
  for var K := 1 to KernelMaxThreads - 1 do
    if FThreads[K].State <> TPS2ThreadState.Free then
    begin
      var PC := FThreads[K].Context.PC;
      var RA := Cardinal(FThreads[K].Context.GPR[31].Lo);
      var Mark := '';
      if K = FCurrent then
      begin
        PC := FCPU.S.PC;
        RA := Cardinal(FCPU.S.GPR[31].Lo);
        Mark := ' current';
      end;
      Result := Result + [Format('ee thread %d: %s wait %d id %d prio %d pc %.8x ra %.8x func %.8x%s', [K,
        Names[FThreads[K].State], FThreads[K].WaitKind, FThreads[K].WaitId, FThreads[K].Priority, PC, RA,
        FThreads[K].Func, Mark])];
    end;
  for var K := 1 to KernelMaxSemas - 1 do
    if FSemas[K].Used then
      Result := Result + [Format('ee sema %d: count %d max %d', [K, FSemas[K].Count, FSemas[K].MaxCount])];
end;

procedure TPS2Kernel.SerializeState(State: TStateArchive);

  procedure IntList(L: TList<Integer>);
  begin
    var N := L.Count;
    State.Field(N, SizeOf(N));
    if State.Loading then
    begin
      L.Clear;
      for var K := 0 to N - 1 do
      begin
        var V: Integer;
        State.Field(V, SizeOf(V));
        L.Add(V);
      end;
    end
    else
      for var K := 0 to N - 1 do
      begin
        var V := L[K];
        State.Field(V, SizeOf(V));
      end;
  end;

begin
  State.Field(FThreads, SizeOf(FThreads));
  State.Field(FSemas, SizeOf(FSemas));
  State.Field(FIntc, SizeOf(FIntc));
  State.Field(FDmac, SizeOf(FDmac));
  IntList(FIntcOrder);
  IntList(FDmacOrder);
  State.Field(FAlarms, SizeOf(FAlarms));
  State.Field(FSysRegs, SizeOf(FSysRegs));
  State.Field(FCurrent, SizeOf(FCurrent));
  State.Field(FSeq, SizeOf(FSeq));
  State.Field(FInInterrupt, SizeOf(FInInterrupt));
  if State.Loading then
    FCPU.SetIntBlock(FInInterrupt);
  State.Field(FNeedSchedule, SizeOf(FNeedSchedule));
  State.Field(FIntContext, SizeOf(FIntContext));
  State.Field(FIntStatus, SizeOf(FIntStatus));
  var N := FCalls.Count;
  State.Field(N, SizeOf(N));
  if State.Loading then
  begin
    FCalls.Clear;
    for var K := 0 to N - 1 do
    begin
      var C: TPS2GuestCall;
      State.Field(C, SizeOf(C));
      FCalls.Add(C);
    end;
  end
  else
    for var K := 0 to N - 1 do
    begin
      var C := FCalls[K];
      State.Field(C, SizeOf(C));
    end;
  State.Field(FCallKind, SizeOf(FCallKind));
  State.Field(FCallCause, SizeOf(FCallCause));
  State.Field(FSkipCause, SizeOf(FSkipCause));
  State.Field(FCustomReturn, SizeOf(FCustomReturn));
  State.Field(FCustomRA, SizeOf(FCustomRA));
  State.Field(FCustomStatus, SizeOf(FCustomStatus));
  State.Field(FInCustom, SizeOf(FInCustom));
  State.Field(FVSyncFlag1, SizeOf(FVSyncFlag1));
  State.Field(FVSyncFlag2, SizeOf(FVSyncFlag2));
  State.Field(FSifDmaId, SizeOf(FSifDmaId));
  State.Field(FHeapEnd, SizeOf(FHeapEnd));
  State.Field(FDeci2, SizeOf(FDeci2));
  State.Field(FIdle, SizeOf(FIdle));
  State.Field(FExited, SizeOf(FExited));
  State.Field(FExitCode, SizeOf(FExitCode));
  State.Field(FGsIMR, SizeOf(FGsIMR));
  State.Field(FCrtMode, SizeOf(FCrtMode));
  State.Field(FCrtInterlace, SizeOf(FCrtInterlace));
  State.Field(FCrtField, SizeOf(FCrtField));
  State.Field(FOsdConfig, SizeOf(FOsdConfig));
  State.Field(FOsdConfig2, SizeOf(FOsdConfig2));
  State.Field(FLineCycles, SizeOf(FLineCycles));
end;

end.
