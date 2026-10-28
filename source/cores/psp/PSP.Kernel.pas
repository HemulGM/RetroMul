unit PSP.Kernel;

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Memory, PSP.CPU,
  PSP.Executable, PSP.VariablePool;

type
  TPSPThreadExitEvent = procedure(Id, Status: Cardinal) of object;

  TPSPKernelTimeEvent = procedure(Time: UInt64) of object;

  TPSPResolveGPEvent = function(Address: Cardinal): Cardinal of object;

  TPSPThreadStatus = (Dormant, Ready, Sleeping, delayed, WaitingThread, WaitingObject, WaitingDevice, Dead);

  TPSPWaitState = class
    Status: TPSPThreadStatus;
    WakeTime: UInt64;
    WaitId, WaitValue, WaitMode, WaitOut, TimeoutPointer: Cardinal;
    PipeAddress, PipeTransferred: Cardinal;
    AcceptCallbacks: Boolean;
    Sequence: UInt64;
  end;

  TPSPThread = class
    Id, Entry, Stack, StackSize, StackBlock, Priority, InitialPriority, Attributes, ModuleId: Cardinal;
    RunClocks: UInt64;
    Name: string;
    Context: TPSPCPUContext;
    State: TPSPWaitState;
    CallbackWaits: TArray<TPSPWaitState>;
    CallbackIds: TArray<Cardinal>;
    CallbackCompletions: TArray<TProc>;
    WakeCount: Integer;
    ExitStatus: Cardinal;
    CallbackContexts: TArray<TPSPCPUContext>;
    CallbackInterrupts: TArray<Boolean>;
    CallbackAlarms: TArray<Cardinal>;
    ContextDirty, ModuleStartThread: Boolean;
    constructor Create;
    destructor Destroy; override;
    function WaitState(Depth: Integer): TPSPWaitState;
  end;

  TPSPObjectWaiter = record
    Thread: TPSPThread;
    State: TPSPWaitState;
  end;

  TPSPMemoryBlock = record
    Id, Address, Size: Cardinal;
    KernelMemory: Boolean;
  end;

  TPSPCallback = record
    Id, Entry, Argument, ThreadId: Cardinal;
    NotifyCount, NotifyArgument: Cardinal;
    Name: string;
  end;

  TPSPFixedPool = class
    Id, Block, Address, BlockSize: Cardinal;
    Used: TArray<Boolean>;
  end;

  TPSPSyncObject = class
    Id, Kind, Attributes, Count, InitialValue, Maximum, Owner, WorkArea: Cardinal;
    Name: string;
    Pool: TPSPVariablePool;
    PoolBlock: Cardinal;
    PipeAddress, PipeSize, PipeUsed, PipeHead: Cardinal;
    destructor Destroy; override;
  end;

  TPSPVTimer = class
    Id, Handler, Argument, GP, Block, Address, Generation: Cardinal;
    Name: string;
    Base, Current, Schedule, FireTime: UInt64;
    Active, Pending: Boolean;
  end;

  TPSPGuestCall = record
    Entry, A0, A1, A2, A3, ThreadId, TimerId, TimerGeneration, GP: Cardinal;
    SetGP: Boolean;
    Interrupt: Boolean;
    AlarmId, CallbackId: Cardinal;
    Completion: TProc;
  end;

  TPSPAlarm = class
    Id, Handler, Argument: Cardinal;
    Schedule, FireTime: UInt64;
    Pending: Boolean;
  end;

  TPSPSubInterrupt = record
    Entry, Argument: Cardinal;
    Enabled: Boolean;
  end;

  TPSPKernel = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FThreads: TObjectList<TPSPThread>;
    FBlocks: TList<TPSPMemoryBlock>;
    FFree: TList<TPSPMemoryBlock>;
    FKernelFree: TList<TPSPMemoryBlock>;
    FCallbacks: TList<TPSPCallback>;
    FPools: TObjectList<TPSPFixedPool>;
    FExecutable: TPSPExecutable;
    FObjects: TObjectDictionary<Cardinal, TPSPSyncObject>;
    FVolatileMemory: TPSPSyncObject;
    FExitCallback: Cardinal;
    FGuestCalls: TList<TPSPGuestCall>;
    FDeviceEvents: TList<UInt64>;
    FAlarms: TObjectDictionary<Cardinal, TPSPAlarm>;
    FVTimers: TObjectDictionary<Cardinal, TPSPVTimer>;
    FCurrent: TPSPThread;
    FNextId, FSDK, FCompiler, FGP, FLastCallResult: Cardinal;
    FTime, FWaitSequence: UInt64;
    FCPUClock, FClockRemainder: Cardinal;
    FKernelPrivilege: Integer;
    FDispatchEnabled: Boolean;
    FStopRequested: Boolean;
    FDebugOutput: string;
    FOnTime: TPSPKernelTimeEvent;
    FOnThreadExit: TPSPThreadExitEvent;
    FResolveGP: TPSPResolveGPEvent;
    FSubInterrupts: array[0..66, 0..31] of TPSPSubInterrupt;
    function Printf(Address: Cardinal): Cardinal;
    function VTimerTime(Timer: TPSPVTimer): UInt64;
    procedure ScheduleVTimer(Timer: TPSPVTimer);
    procedure FireVTimers;
    function HandleVTimer(NID: Cardinal; out Value: Cardinal): Boolean;
    function NewId: Cardinal;
    function Allocate(Size, Kind, Value: Cardinal): Cardinal;
    function AllocateRanges(Size, Kind, Value: Cardinal; Ranges: TList<TPSPMemoryBlock>; KernelMemory: Boolean): Cardinal;
    function FreeBlock(Id: Cardinal): Cardinal;
    function BlockAddress(Id: Cardinal): Cardinal;
    function FindThread(Id: Cardinal): TPSPThread;
    function CreateThread(Name: string; Entry, Priority, StackSize, Attributes: Cardinal; KernelStack: Boolean = False): Cardinal;
    function StartThread(Id, ArgSize, ArgPointer: Cardinal): Cardinal;
    procedure WakeWaiters(Id: Cardinal);
    procedure SetCPUClock(Value: Cardinal);
    procedure InitializeContext(Thread: TPSPThread; ArgSize, ArgPointer: Cardinal);
    function HandleVpl(NID: Cardinal; out Value: Cardinal): Boolean;
    function HandleMsgPipe(NID: Cardinal; out Value: Cardinal): Boolean;
    procedure PumpMsgPipe(Obj: TPSPSyncObject);
    function HandleSync(const ModuleName: string; NID: Cardinal; out Value: Cardinal): Boolean;
    function AcquireObject(Thread: TPSPThread; Obj: TPSPSyncObject; Amount, Mode, Output: Cardinal): Boolean;
    function WaitObject(Obj: TPSPSyncObject; Amount, Mode, Output, Timeout: Cardinal; Poll: Boolean): Cardinal;
    procedure UpdateWorkArea(Obj: TPSPSyncObject);
    procedure WakeObject(Obj: TPSPSyncObject);
    procedure SetThreadResult(Thread: TPSPThread; Value: Cardinal; State: TPSPWaitState = nil);
    function DispatchCallbacks(Thread: TPSPThread): Boolean;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; const Executable: TPSPExecutable);
    destructor Destroy; override;
    function Handle(const ModuleName: string; NID: Cardinal; out Value: Cardinal): Boolean;
    procedure RunUntil(Deadline: UInt64; Budget: Cardinal);
    procedure StopScheduling;
    procedure ExitCurrent(Status: Cardinal; Delete: Boolean);
    function TerminateDeleteThread(Id, Status: Cardinal): Cardinal;
    procedure WaitUntil(Time: UInt64);
    procedure Yield;
    procedure ScheduleDeviceEvent(Deadline: UInt64);
    function IsWaitingDevice(ThreadId, Kind, Id: Cardinal): Boolean;
    function NotifyCallback(Id, Argument: Cardinal): Cardinal;
    procedure RaiseInterrupt(Number: Cardinal);
    procedure QueueCall(Entry, A0, A1, A2: Cardinal; Interrupt: Boolean = True; const Completion: TProc = nil);
    procedure QueueCall4(Entry, A0, A1, A2, A3: Cardinal; Interrupt: Boolean = True; const Completion: TProc = nil);
    procedure ReturnFromCall;
    function CurrentThreadId: Cardinal;
    function CurrentModuleId: Cardinal;
    function IsWaitingUntil(Id: Cardinal; Deadline: UInt64): Boolean;
    procedure RescheduleWait(Id: Cardinal; OldTime, NewTime: UInt64);
    procedure WaitDevice(Kind, Id: Cardinal);
    procedure AcceptCallbacks;
    procedure CompleteDevice(Kind, Id, Value: Cardinal);
    function ReserveModule(Size: Cardinal; out Address: Cardinal; KernelMemory: Boolean = False): Cardinal;
    function ReleaseModule(Id: Cardinal): Cardinal;
    function StartModule(Entry, GP, ArgSize, ArgPointer, Priority, StackSize, Attributes: Cardinal; KernelMemory: Boolean = False; ModuleId: Cardinal = 0): Cardinal;
    property OnThreadExit: TPSPThreadExitEvent read FOnThreadExit write FOnThreadExit;
    property ResolveGP: TPSPResolveGPEvent read FResolveGP write FResolveGP;
    function DescribeThreads: string;
    property LastCallResult: Cardinal read FLastCallResult;
    property DebugOutput: string read FDebugOutput;
    property SDK: Cardinal read FSDK;
    property Time: UInt64 read FTime;
    property CPUClock: Cardinal read FCPUClock write SetCPUClock;
    property OnTime: TPSPKernelTimeEvent read FOnTime write FOnTime;
    property DispatchEnabled: Boolean read FDispatchEnabled;
  end;

implementation

uses
  System.Math, System.Generics.Defaults;

destructor TPSPSyncObject.Destroy;
begin
  Pool.Free;
  inherited;
end;

constructor TPSPThread.Create;
begin
  inherited;
  State := TPSPWaitState.Create;
end;

destructor TPSPThread.Destroy;
begin
  State.Free;
  for var Wait in CallbackWaits do
    Wait.Free;
  inherited;
end;

function TPSPThread.WaitState(Depth: Integer): TPSPWaitState;
begin
  if Depth = Length(CallbackWaits) then
    Result := State
  else
    Result := CallbackWaits[Depth];
end;

constructor TPSPKernel.Create(Memory: TPSPMemory; CPU: TPSPCPU; const Executable: TPSPExecutable);
begin
  inherited Create;
  FMemory := Memory;
  FCPUClock := 222;
  FGuestCalls := TList<TPSPGuestCall>.Create;
  FDeviceEvents := TList<UInt64>.Create;
  FAlarms := TObjectDictionary<Cardinal, TPSPAlarm>.Create([doOwnsValues]);
  FVTimers := TObjectDictionary<Cardinal, TPSPVTimer>.Create([doOwnsValues]);
  FCPU := CPU;
  FGP := Executable.GP;
  FExecutable := Executable;
  FObjects := TObjectDictionary<Cardinal, TPSPSyncObject>.Create([doOwnsValues]);
  FCallbacks := TList<TPSPCallback>.Create;
  FPools := TObjectList<TPSPFixedPool>.Create(True);
  FThreads := TObjectList<TPSPThread>.Create(True);
  FBlocks := TList<TPSPMemoryBlock>.Create;
  FFree := TList<TPSPMemoryBlock>.Create;
  FKernelFree := TList<TPSPMemoryBlock>.Create;
  var KernelRange := Default(TPSPMemoryBlock);
  KernelRange.Address := PSPInterruptStackTop;
  KernelRange.Size := $400000 - $2000;
  KernelRange.KernelMemory := True;
  FKernelFree.Add(KernelRange);
  FNextId := $100;
  FDispatchEnabled := True;
  var FreeRange := Default(TPSPMemoryBlock);
  FreeRange.Address := (Executable.HighAddress + $FF) and $FFFFFF00;
  FreeRange.Size := PSPRAMBase + PSPRAMSize - $10000 - FreeRange.Address;
  FFree.Add(FreeRange);
  if (Executable.LowAddress >= PSPUserBase) and (Executable.LowAddress < Executable.HighAddress) and
    (Executable.HighAddress <= PSPRAMBase + PSPRAMSize - $10000) then
  begin
    var RootBlock := Default(TPSPMemoryBlock);
    RootBlock.Id := $50;
    RootBlock.Address := Executable.LowAddress and $FFFFFF00;
    RootBlock.Size := ((Executable.HighAddress + $FF) and $FFFFFF00) - RootBlock.Address;
    FBlocks.Add(RootBlock);
  end;
  var Root := TPSPThread.Create;
  Root.Id := NewId;
  Root.Name := 'root';
  Root.ModuleId := $50;
  Root.Priority := 32;
  Root.InitialPriority := 32;
  Root.Entry := Executable.Entry;
  Root.Stack := PSPRAMBase + PSPRAMSize - $10000;
  Root.StackSize := $10000;
  var K0 := Root.Stack + Root.StackSize - $100;
  FMemory.Zero(K0, $100);
  FMemory.Write32(K0 + $C0, Root.Id);
  FMemory.Write32(K0 + $C8, Root.Stack);
  FMemory.Write32(K0 + $F8, $FFFFFFFF);
  FMemory.Write32(K0 + $FC, $FFFFFFFF);
  FMemory.Write32(Root.Stack, Root.Id);
  CPU.Registers[26] := K0;
  if CPU.Registers[29] > K0 - $40 then
    CPU.Registers[29] := K0 - $40;
  Root.Context := CPU.SaveContext;
  Root.State.Status := TPSPThreadStatus.Ready;
  FThreads.Add(Root);
  FCurrent := Root;
  FVolatileMemory := TPSPSyncObject.Create;
  FVolatileMemory.Id := NewId;
  FVolatileMemory.Kind := 3;
  FVolatileMemory.Count := 1;
  FVolatileMemory.Maximum := 1;
  FObjects.Add(FVolatileMemory.Id, FVolatileMemory);
end;

destructor TPSPKernel.Destroy;
begin
  FPools.Free;
  FGuestCalls.Free;
  FDeviceEvents.Free;
  FVTimers.Free;
  FAlarms.Free;
  FObjects.Free;
  FCallbacks.Free;
  FFree.Free;
  FKernelFree.Free;
  FBlocks.Free;
  FThreads.Free;
  inherited;
end;

function TPSPKernel.NewId: Cardinal;
begin
  Result := FNextId;
  Inc(FNextId);
end;

function TPSPKernel.DescribeThreads: string;
begin
  var Builder := TStringBuilder.Create;
  try
    Builder.AppendFormat('kernel time=%d us', [FTime]).AppendLine;
    for var Thread in FThreads do
    begin
      var Context := Thread.Context;
      if Thread = FCurrent then
        Context := FCPU.SaveContext;
      Builder.AppendFormat('thread %.8x %s priority=%d state=%d PC=%.8x RA=%.8x callbacks=%d S0=%.8x S1=%.8x SP=%.8x GP=%.8x module=%.8x',
        [Thread.Id, Thread.Name, Thread.Priority, Ord(Thread.State.Status), Context.PC, Context.R[31], Length(Thread.CallbackContexts), Context.R[16], Context.R[17], Context.R[29], Context.R[28], Thread.ModuleId]).AppendLine;
      for var Depth := 0 to Length(Thread.CallbackWaits) do
      begin
        var State := Thread.WaitState(Depth);
        Builder.AppendFormat('  frame %d state=%d object=%.8x kind=%d value=%d wake=%d CB=%s',
          [Depth, Ord(State.Status), State.WaitId, State.WaitMode, State.WaitValue, State.WakeTime, BoolToStr(State.AcceptCallbacks, True)]).AppendLine;
      end;
    end;
    for var Obj in FObjects.Values do
      Builder.AppendFormat('object %.8x %s kind=%d count=%.8x max=%d owner=%.8x attributes=%.8x',
        [Obj.Id, Obj.Name, Obj.Kind, Obj.Count, Obj.Maximum, Obj.Owner, Obj.Attributes]).AppendLine;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function TPSPKernel.CurrentThreadId: Cardinal;
begin
  Result := FCurrent.Id;
end;

function TPSPKernel.CurrentModuleId: Cardinal;
begin
  Result := FCurrent.ModuleId;
end;

function TPSPKernel.IsWaitingUntil(Id: Cardinal; Deadline: UInt64): Boolean;
begin
  var Thread := FindThread(Id);
  Result := False;
  if Thread = nil then
    Exit;
  for var Depth := 0 to Length(Thread.CallbackWaits) do
  begin
    var State := Thread.WaitState(Depth);
    if (State.Status = TPSPThreadStatus.delayed) and (State.WakeTime = Deadline) then
      Exit(True);
  end;
end;

procedure TPSPKernel.RescheduleWait(Id: Cardinal; OldTime, NewTime: UInt64);
begin
  var Thread := FindThread(Id);
  if Thread = nil then
    Exit;
  for var Depth := 0 to Length(Thread.CallbackWaits) do
  begin
    var State := Thread.WaitState(Depth);
    if (State.Status = TPSPThreadStatus.delayed) and (State.WakeTime = OldTime) then
      State.WakeTime := NewTime;
  end;
end;

procedure TPSPKernel.SetThreadResult(Thread: TPSPThread; Value: Cardinal; State: TPSPWaitState);
begin
  if State = nil then
    State := Thread.State;
  State.AcceptCallbacks := False;
  for var Depth := 0 to High(Thread.CallbackWaits) do
    if Thread.CallbackWaits[Depth] = State then
    begin
      var Context := Thread.CallbackContexts[Depth];
      Context.R[2] := Value;
      Thread.CallbackContexts[Depth] := Context;
      Exit;
    end;
  Thread.Context.R[2] := Value;
  if Thread = FCurrent then
    FCPU.Registers[2] := Value;
  Thread.ContextDirty := True;
end;

procedure TPSPKernel.AcceptCallbacks;
begin
  FCurrent.State.AcceptCallbacks := True;
  FCPU.Yield;
end;

procedure TPSPKernel.WaitDevice(Kind, Id: Cardinal);
begin
  FCurrent.State.Status := TPSPThreadStatus.WaitingDevice;
  FCurrent.State.WaitValue := Kind;
  FCurrent.State.WaitId := Id;
  FCurrent.State.AcceptCallbacks := False;
  FCPU.Yield;
end;

procedure TPSPKernel.CompleteDevice(Kind, Id, Value: Cardinal);
begin
  for var Thread in FThreads do
    for var Depth := 0 to Length(Thread.CallbackWaits) do
    begin
      var State := Thread.WaitState(Depth);
      if (State.Status = TPSPThreadStatus.WaitingDevice) and (State.WaitValue = Kind) and (State.WaitId = Id) then
      begin
        SetThreadResult(Thread, Value, State);
        State.Status := TPSPThreadStatus.Ready;
      end;
    end;
end;

function TPSPKernel.Allocate(Size, Kind, Value: Cardinal): Cardinal;
begin
  Result := AllocateRanges(Size, Kind, Value, FFree, False);
end;

function TPSPKernel.AllocateRanges(Size, Kind, Value: Cardinal; Ranges: TList<TPSPMemoryBlock>; KernelMemory: Boolean): Cardinal;
begin
  Result := $80020190;
  if (Size = 0) or (Size > PSPRAMSize) or (Kind > 4) then
    Exit;
  Size := (Size + $FF) and $FFFFFF00;
  var Alignment: Cardinal := $100;
  if Kind in [3, 4] then
  begin
    if (Value = 0) or (Value > PSPRAMSize) or (Value and (Value - 1) <> 0) then
      Exit;
    Alignment := Max(Alignment, Value);
  end;
  for var Step := 0 to Ranges.Count - 1 do
  begin
    var Index := Step;
    if Kind in [1, 4] then
      Index := Ranges.Count - 1 - Step;
    var Range := Ranges[Index];
    var Address := (Range.Address + Alignment - 1) and not (Alignment - 1);
    if Kind in [1, 4] then
    begin
      if Size > Range.Size then
        Continue;
      Address := (Range.Address + Range.Size - Size) and not (Alignment - 1);
    end
    else if Kind = 2 then
      Address := Value;
    if (Address < Range.Address) or (UInt64(Address) + Size > UInt64(Range.Address) + Range.Size) then
      Continue;
    var Block: TPSPMemoryBlock;
    Block.KernelMemory := KernelMemory;
    Block.Id := NewId;
    Block.Address := Address;
    Block.Size := Size;
    FBlocks.Add(Block);
    Ranges.Delete(Index);
    if Address > Range.Address then
    begin
      var Prefix := Range;
      Prefix.Size := Address - Range.Address;
      Ranges.Insert(Index, Prefix);
      Inc(Index);
    end;
    if Address + Size < Range.Address + Range.Size then
    begin
      var Suffix := Range;
      Suffix.Address := Address + Size;
      Suffix.Size := Range.Address + Range.Size - Suffix.Address;
      Ranges.Insert(Index, Suffix);
    end;
    Exit(Block.Id);
  end;
end;

function TPSPKernel.BlockAddress(Id: Cardinal): Cardinal;
begin
  Result := 0;
  for var Block in FBlocks do
    if Block.Id = Id then
      Exit(Block.Address);
end;

function TPSPKernel.FreeBlock(Id: Cardinal): Cardinal;
begin
  Result := $800200CB;
  for var I := 0 to FBlocks.Count - 1 do
    if FBlocks[I].Id = Id then
    begin
      var Block := FBlocks[I];
      FBlocks.Delete(I);
      var Ranges := FFree;
      if Block.KernelMemory then
        Ranges := FKernelFree;
      var Index := 0;
      while (Index < Ranges.Count) and (Ranges[Index].Address < Block.Address) do
        Inc(Index);
      Ranges.Insert(Index, Block);
      if (Index > 0) and (Ranges[Index - 1].Address + Ranges[Index - 1].Size = Block.Address) then
      begin
        var Previous := Ranges[Index - 1];
        Inc(Previous.Size, Block.Size);
        Ranges[Index - 1] := Previous;
        Ranges.Delete(Index);
        Dec(Index);
      end;
      if (Index + 1 < Ranges.Count) and (Ranges[Index].Address + Ranges[Index].Size = Ranges[Index + 1].Address) then
      begin
        var Merged := Ranges[Index];
        Inc(Merged.Size, Ranges[Index + 1].Size);
        Ranges[Index] := Merged;
        Ranges.Delete(Index + 1);
      end;
      Exit(0);
    end;
end;

function TPSPKernel.FindThread(Id: Cardinal): TPSPThread;
begin
  if Id = 0 then
    Exit(FCurrent);
  for var Thread in FThreads do
    if Thread.Id = Id then
      Exit(Thread);
  Result := nil;
end;

function TPSPKernel.CreateThread(Name: string; Entry, Priority, StackSize, Attributes: Cardinal; KernelStack: Boolean): Cardinal;
begin
  if (Entry and 3 <> 0) or not FMemory.IsValid(Entry, 4) then
    Exit($800200D3);
  if (Priority < 8) or (Priority > 119) then
    Exit($80020193);
  if StackSize > PSPRAMSize then
    Exit($80020190);
  StackSize := Max(Cardinal($200), (StackSize + $FF) and $FFFFFF00);
  var Block: Cardinal;
  if KernelStack then
    Block := AllocateRanges(StackSize, 1, 0, FKernelFree, True)
  else
    Block := Allocate(StackSize, 1, 0);
  if Block and $80000000 <> 0 then
    Exit(Block);
  var Thread := TPSPThread.Create;
  Thread.Id := NewId;
  Thread.Name := Name.Substring(0, 31);
  Thread.Entry := Entry;
  Thread.Priority := Priority;
  Thread.InitialPriority := Priority;
  Thread.StackBlock := Block;
  Thread.Stack := BlockAddress(Block);
  Thread.StackSize := StackSize;
  Thread.Attributes := Attributes;
  Thread.ModuleId := FCurrent.ModuleId;
  Thread.State.Status := TPSPThreadStatus.Dormant;
  FThreads.Add(Thread);
  Result := Thread.Id;
end;

procedure TPSPKernel.InitializeContext(Thread: TPSPThread; ArgSize, ArgPointer: Cardinal);
begin
  Thread.Context := Default(TPSPCPUContext);
  Thread.Context.PC := Thread.Entry;
  Thread.Context.FCR31 := $0E00;
  Thread.Context.VFPU.Reset;
  Thread.Context.NextPC := Thread.Entry + 4;
  if Assigned(FResolveGP) then
    Thread.Context.R[28] := FResolveGP(Thread.Entry)
  else
  begin
    Thread.Context.R[28] := FCPU.Registers[28];
    if Thread.Context.R[28] = 0 then
      Thread.Context.R[28] := FGP;
  end;
  FMemory.Fill(Thread.Stack, Thread.StackSize, $FF);
  var K0 := Thread.Stack + Thread.StackSize - $100;
  FMemory.Zero(K0, $100);
  FMemory.Write32(K0 + $C0, Thread.Id);
  FMemory.Write32(K0 + $C8, Thread.Stack);
  FMemory.Write32(K0 + $F8, $FFFFFFFF);
  FMemory.Write32(K0 + $FC, $FFFFFFFF);
  FMemory.Write32(Thread.Stack, Thread.Id);
  var SP := (K0 - ArgSize) and $FFFFFFF0;
  if ArgSize <> 0 then
    FMemory.CopyMemory(SP, ArgPointer, ArgSize);
  Thread.Context.R[4] := ArgSize;
  if ArgSize <> 0 then
    Thread.Context.R[5] := SP;
  Thread.Context.R[26] := K0;
  Thread.Context.R[29] := SP - $40;
  Thread.Context.R[31] := PSPThreadReturnTrampoline;
end;

function TPSPKernel.StartThread(Id, ArgSize, ArgPointer: Cardinal): Cardinal;
begin
  var Thread := FindThread(Id);
  if Thread = nil then
    Exit($80020198);
  if Thread.State.Status <> TPSPThreadStatus.Dormant then
    Exit($800201A4);
  if (ArgSize > Thread.StackSize - $180) or ((ArgSize <> 0) and not FMemory.IsValid(ArgPointer, ArgSize)) then
    Exit($800200D3);
  InitializeContext(Thread, ArgSize, ArgPointer);
  Thread.State.Status := TPSPThreadStatus.Ready;
  Yield;
  Result := 0;
end;

procedure TPSPKernel.WakeWaiters(Id: Cardinal);
begin
  for var Thread in FThreads do
    for var Depth := 0 to Length(Thread.CallbackWaits) do
    begin
      var State := Thread.WaitState(Depth);
      if (State.Status = TPSPThreadStatus.WaitingThread) and (State.WaitId = Id) then
      begin
        if State.TimeoutPointer <> 0 then
          FMemory.Write32(State.TimeoutPointer,
            Cardinal(Max(Int64(0), Int64(State.WakeTime) - Int64(FTime))));
        State.Status := TPSPThreadStatus.Ready;
        SetThreadResult(Thread, 0, State);
      end;
    end;
end;

function TPSPKernel.ReserveModule(Size: Cardinal; out Address: Cardinal; KernelMemory: Boolean): Cardinal;
begin
  if KernelMemory then
    Result := AllocateRanges(Size, 3, $1000, FKernelFree, True)
  else
    Result := Allocate(Size, 3, $1000);
  Address := 0;
  if Result and $80000000 = 0 then
    Address := BlockAddress(Result);
end;

function TPSPKernel.ReleaseModule(Id: Cardinal): Cardinal;
begin
  Result := FreeBlock(Id);
end;

function TPSPKernel.StartModule(Entry, GP, ArgSize, ArgPointer, Priority, StackSize, Attributes: Cardinal; KernelMemory: Boolean; ModuleId: Cardinal): Cardinal;
begin
  Result := CreateThread('module_start', Entry, Priority, StackSize, Attributes, KernelMemory);
  if Result and $80000000 <> 0 then
    Exit;
  var Id := Result;
  Result := StartThread(Id, ArgSize, ArgPointer);
  if Result and $80000000 <> 0 then
  begin
    var Thread := FindThread(Id);
    FreeBlock(Thread.StackBlock);
    Thread.StackBlock := 0;
    Thread.State.Status := TPSPThreadStatus.Dead;
    Exit;
  end;
  FindThread(Id).Context.R[28] := GP;
  FindThread(Id).ModuleStartThread := True;
  if ModuleId <> 0 then
    FindThread(Id).ModuleId := ModuleId;
  Result := Id;
end;

procedure TPSPKernel.ExitCurrent(Status: Cardinal; Delete: Boolean);
begin
  FCurrent.ExitStatus := Status;
  FCurrent.State.Status := TPSPThreadStatus.Dormant;
  if Delete or FCurrent.ModuleStartThread then
  begin
    FCurrent.State.Status := TPSPThreadStatus.Dead;
    if FCurrent.StackBlock <> 0 then
      FreeBlock(FCurrent.StackBlock);
    FCurrent.StackBlock := 0;
  end;
  for var State in FCurrent.CallbackWaits do
    State.Free;
  FCurrent.CallbackWaits := nil;
  FCurrent.CallbackContexts := nil;
  FCurrent.CallbackIds := nil;
  FCurrent.CallbackCompletions := nil;
  FCurrent.CallbackInterrupts := nil;
  FCurrent.CallbackAlarms := nil;
  FCurrent.State.AcceptCallbacks := False;
  for var I := FGuestCalls.Count - 1 downto 0 do
    if not FGuestCalls[I].Interrupt and (FGuestCalls[I].ThreadId = FCurrent.Id) then
      FGuestCalls.Delete(I);
  WakeWaiters(FCurrent.Id);
  if Assigned(FOnThreadExit) then
    FOnThreadExit(FCurrent.Id, Status);
  FCPU.Yield;
end;

function TPSPKernel.TerminateDeleteThread(Id, Status: Cardinal): Cardinal;
begin
  var Thread := FindThread(Id);
  if (Thread = nil) or (Thread.State.Status = TPSPThreadStatus.Dead) then
    Exit($80020198);
  if Thread = FCurrent then
  begin
    ExitCurrent(Status, True);
    Exit(0)
  end;
  Thread.ExitStatus := Status;
  Thread.State.Status := TPSPThreadStatus.Dead;
  for var State in Thread.CallbackWaits do
    State.Free;
  Thread.CallbackWaits := nil;
  Thread.CallbackContexts := nil;
  Thread.CallbackIds := nil;
  Thread.CallbackCompletions := nil;
  Thread.CallbackInterrupts := nil;
  Thread.CallbackAlarms := nil;
  Thread.State.AcceptCallbacks := False;
  for var I := FGuestCalls.Count - 1 downto 0 do
    if not FGuestCalls[I].Interrupt and (FGuestCalls[I].ThreadId = Thread.Id) then
      FGuestCalls.Delete(I);
  WakeWaiters(Thread.Id);
  if Assigned(FOnThreadExit) then
    FOnThreadExit(Thread.Id, Status);
  if Thread.StackBlock <> 0 then
    FreeBlock(Thread.StackBlock);
  Thread.StackBlock := 0;
  Result := 0;
end;

procedure TPSPKernel.WaitUntil(Time: UInt64);
begin
  FCurrent.State.AcceptCallbacks := False;
  FCurrent.State.WakeTime := Time;
  FCurrent.State.Status := TPSPThreadStatus.delayed;
  FCPU.Yield;
end;

procedure TPSPKernel.Yield;
begin
  if FDispatchEnabled and FCPU.InterruptEnabled then
    FCPU.Yield;
end;

procedure TPSPKernel.StopScheduling;
begin
  FStopRequested := True;
  FCPU.Yield
end;

procedure TPSPKernel.SetCPUClock(Value: Cardinal);
begin
  if (Value < 1) or (Value > 333) then
    raise EArgumentOutOfRangeException.Create('PSP CPU clock');
  if FCPUClock = Value then
    Exit;
  FCPUClock := Value;
  FClockRemainder := 0;
  FCPU.Yield;
end;

procedure TPSPKernel.RunUntil(Deadline: UInt64; Budget: Cardinal);
begin
  while (FTime < Deadline) and (Budget <> 0) and not FStopRequested do
  begin
    for var Alarm in FAlarms.Values do
      if not Alarm.Pending and (Alarm.FireTime <= FTime) then
      begin
        var Call := Default(TPSPGuestCall);
        Call.Entry := Alarm.Handler;
        Call.A0 := Alarm.Argument;
        Call.Interrupt := True;
        Call.AlarmId := Alarm.Id;
        FGuestCalls.Add(Call);
        Alarm.Pending := True;
      end;
    FireVTimers;
    if Assigned(FOnTime) then
      FOnTime(FTime);
    for var I := FDeviceEvents.Count - 1 downto 0 do
      if FDeviceEvents[I] <= FTime then
        FDeviceEvents.Delete(I);
    for var Thread in FThreads do
    begin
      for var Depth := 0 to Length(Thread.CallbackWaits) do
      begin
        var State := Thread.WaitState(Depth);
        if (State.Status = TPSPThreadStatus.delayed) and (State.WakeTime <= FTime) then
        begin
          State.Status := TPSPThreadStatus.Ready;
          SetThreadResult(Thread, 0, State);
        end;
        if (State.Status in [TPSPThreadStatus.WaitingObject, TPSPThreadStatus.WaitingThread]) and (State.WakeTime <> 0) and (State.WakeTime <= FTime) then
        begin
          State.Status := TPSPThreadStatus.Ready;
          SetThreadResult(Thread, $800201A8, State);
          if State.TimeoutPointer <> 0 then
            FMemory.Write32(State.TimeoutPointer, 0);
          var TimedObject: TPSPSyncObject;
          if FObjects.TryGetValue(State.WaitId, TimedObject) and (TimedObject.Kind = 5) then
            PumpMsgPipe(TimedObject);
        end;
      end;
      if Thread.State.AcceptCallbacks then
        DispatchCallbacks(Thread);
    end;
    var Selected: TPSPThread := nil;
    for var Thread in FThreads do
    begin
      var Eligible := Thread.State.Status = TPSPThreadStatus.Ready;
      if Thread.State.AcceptCallbacks then
        for var Call in FGuestCalls do
          if not Call.Interrupt and (Call.ThreadId = Thread.Id) then
          begin
            Eligible := True;
            Break;
          end;
      if Eligible and ((Selected = nil) or (Thread.Priority < Selected.Priority)) then
        Selected := Thread;
    end;
    if (FCurrent.State.Status = TPSPThreadStatus.Ready) and
      (not FDispatchEnabled or not FCPU.InterruptEnabled) then
      Selected := FCurrent;
    if (Length(FCurrent.CallbackContexts) > 0) and not FCPU.InterruptEnabled then
      Selected := FCurrent;
    if (Selected = nil) and FCPU.InterruptEnabled then
      for var Call in FGuestCalls do
        if Call.Interrupt then
        begin
          Selected := FCurrent;
          Break;
        end;
    if Selected = nil then
    begin
      var Next := Deadline;
      for var Thread in FThreads do
        for var Depth := 0 to Length(Thread.CallbackWaits) do
        begin
          var State := Thread.WaitState(Depth);
          if ((State.Status = TPSPThreadStatus.delayed) or
            ((State.Status in [TPSPThreadStatus.WaitingObject, TPSPThreadStatus.WaitingThread]) and (State.WakeTime <> 0))) and
            (State.WakeTime < Next) then
            Next := State.WakeTime;
        end;
      for var Alarm in FAlarms.Values do
        if not Alarm.Pending and (Alarm.FireTime < Next) then
          Next := Alarm.FireTime;
      for var Timer in FVTimers.Values do
        if Timer.Active and not Timer.Pending and (Timer.Handler <> 0) and (Timer.FireTime < Next) then
          Next := Timer.FireTime;
      for var EventTime in FDeviceEvents do
        if (EventTime > FTime) and (EventTime < Next) then
          Next := EventTime;
      FTime := Next;
      Continue;
    end;
    if (FCurrent <> Selected) or Selected.ContextDirty then
    begin
      FCurrent := Selected;
      FCPU.LoadContext(FCurrent.Context);
      FCurrent.ContextDirty := False;
    end;
    for var I := 0 to FGuestCalls.Count - 1 do
      if ((FGuestCalls[I].ThreadId = FCurrent.Id) and not FGuestCalls[I].Interrupt) or
        (FGuestCalls[I].Interrupt and FCPU.InterruptEnabled) then
      begin
        var Call := FGuestCalls[I];
        FGuestCalls.Delete(I);
        FCurrent.CallbackContexts := FCurrent.CallbackContexts + [FCPU.SaveContext];
        FCurrent.CallbackWaits := FCurrent.CallbackWaits + [FCurrent.State];
        FCurrent.CallbackIds := FCurrent.CallbackIds + [Call.CallbackId];
        FCurrent.CallbackCompletions := FCurrent.CallbackCompletions + [Call.Completion];
        FCurrent.State := TPSPWaitState.Create;
        FCurrent.State.Status := TPSPThreadStatus.Ready;
        FCurrent.CallbackInterrupts := FCurrent.CallbackInterrupts + [FCPU.InterruptEnabled];
        FCurrent.CallbackAlarms := FCurrent.CallbackAlarms + [Call.AlarmId];
        FCPU.Registers[4] := Call.A0;
        FCPU.Registers[5] := Call.A1;
        FCPU.Registers[6] := Call.A2;
        FCPU.Registers[7] := Call.A3;
        if Call.SetGP then
          FCPU.Registers[28] := Call.GP;
        if not Call.SetGP and Assigned(FResolveGP) then
          FCPU.Registers[28] := FResolveGP(Call.Entry);
        if Call.Interrupt then
          FCPU.Registers[29] := PSPInterruptStackTop - $40
        else
          FCPU.Registers[29] := FCPU.Registers[29] - $40;
        FCPU.Registers[31] := PSPCallbackReturnTrampoline;
        if Call.Interrupt then
          FCPU.InterruptEnabled := False;
        FCPU.SetPC(Call.Entry);
        Break;
      end;
    var Before := FCPU.Instructions;
    var Slice := Min(Budget, Cardinal(10000));
    var SliceClock := FCPUClock;
    var Remainder := FClockRemainder;
    var UntilDeadline: UInt64 := (Deadline - FTime) * SliceClock - Remainder;
    Slice := Min(Slice, Cardinal(Min(UInt64(10000), UntilDeadline)));
    FCPU.Run(Slice);
    var Count := Cardinal(FCPU.Instructions - Before);
    Inc(FCurrent.RunClocks, Count);
    FCurrent.Context := FCPU.SaveContext;
    Dec(Budget, Max(Cardinal(1), Count));
    var Clocks := UInt64(Count) + Remainder;
    Inc(FTime, Clocks div SliceClock);
    if FCPUClock = SliceClock then
      FClockRemainder := Clocks mod SliceClock
    else
      FClockRemainder := 0;
    if Count = 0 then
      Inc(FTime);
    if FCPU.Halted then
      ExitCurrent(FCPU.Registers[2], False);
  end;
  FTime := Max(FTime, Deadline);
  if Assigned(FOnTime) then
    FOnTime(FTime);
end;

procedure TPSPKernel.ScheduleDeviceEvent(Deadline: UInt64);
begin
  FDeviceEvents.Add(Deadline);
end;

function TPSPKernel.IsWaitingDevice(ThreadId, Kind, Id: Cardinal): Boolean;
begin
  var Thread := FindThread(ThreadId);
  Result := False;
  if Thread = nil then
    Exit;
  for var Depth := 0 to Length(Thread.CallbackWaits) do
  begin
    var State := Thread.WaitState(Depth);
    if (State.Status = TPSPThreadStatus.WaitingDevice) and (State.WaitValue = Kind) and (State.WaitId = Id) then
      Exit(True);
  end;
end;

function TPSPKernel.DispatchCallbacks(Thread: TPSPThread): Boolean;
begin
  Result := False;
  for var I := 0 to FCallbacks.Count - 1 do
  begin
    var Callback := FCallbacks[I];
    if (Callback.ThreadId <> Thread.Id) or (Callback.NotifyCount = 0) then
      Continue;
    var Call := Default(TPSPGuestCall);
    Call.Entry := Callback.Entry;
    Call.A0 := Callback.NotifyCount;
    Call.A1 := Callback.NotifyArgument;
    Call.A2 := Callback.Argument;
    Call.ThreadId := Thread.Id;
    Call.CallbackId := Callback.Id;
    FGuestCalls.Add(Call);
    Callback.NotifyCount := 0;
    Callback.NotifyArgument := 0;
    FCallbacks[I] := Callback;
    Result := True;
  end;
end;

function TPSPKernel.NotifyCallback(Id, Argument: Cardinal): Cardinal;
begin
  Result := $800201A1;
  for var I := 0 to FCallbacks.Count - 1 do
    if FCallbacks[I].Id = Id then
    begin
      var Callback := FCallbacks[I];
      Inc(Callback.NotifyCount);
      Callback.NotifyArgument := Argument;
      FCallbacks[I] := Callback;
      Exit(0);
    end;
end;

procedure TPSPKernel.RaiseInterrupt(Number: Cardinal);
begin
  if Number > 66 then
    Exit;
  for var Sub := 0 to 31 do
    if FSubInterrupts[Number, Sub].Enabled and (FSubInterrupts[Number, Sub].Entry <> 0) then
      QueueCall(FSubInterrupts[Number, Sub].Entry, Sub, FSubInterrupts[Number, Sub].Argument, 0);
end;

procedure TPSPKernel.QueueCall(Entry, A0, A1, A2: Cardinal; Interrupt: Boolean; const Completion: TProc);
begin
  QueueCall4(Entry, A0, A1, A2, 0, Interrupt, Completion);
end;

procedure TPSPKernel.QueueCall4(Entry, A0, A1, A2, A3: Cardinal; Interrupt: Boolean; const Completion: TProc);
begin
  if Entry = 0 then
    Exit;
  if (Entry and 3 <> 0) or not FMemory.IsValid(Entry, 4) then
    raise EPSPInstruction.Create('PSP: invalid guest callback target');
  var Call := Default(TPSPGuestCall);
  Call.Entry := Entry;
  Call.A0 := A0;
  Call.A1 := A1;
  Call.A2 := A2;
  Call.A3 := A3;
  Call.ThreadId := FCurrent.Id;
  Call.Interrupt := Interrupt;
  Call.Completion := Completion;
  FGuestCalls.Add(Call);
  FCPU.Yield;
end;

procedure TPSPKernel.ReturnFromCall;
begin
  var N := Length(FCurrent.CallbackContexts);
  if N = 0 then
    raise EPSPInstruction.Create('PSP: callback return without saved context');
  var AlarmId := FCurrent.CallbackAlarms[N - 1];
  var ReturnValue := Integer(FCPU.Registers[2]);
  var CallbackId := FCurrent.CallbackIds[N - 1];
  var Completion := FCurrent.CallbackCompletions[N - 1];
  SetLength(FCurrent.CallbackCompletions, N - 1);
  FCurrent.State.Free;
  FCurrent.State := FCurrent.CallbackWaits[N - 1];
  SetLength(FCurrent.CallbackWaits, N - 1);
  SetLength(FCurrent.CallbackIds, N - 1);
  if (CallbackId <> 0) and (ReturnValue <> 0) then
    for var I := FCallbacks.Count - 1 downto 0 do
      if FCallbacks[I].Id = CallbackId then
        FCallbacks.Delete(I);
  FCPU.LoadContext(FCurrent.CallbackContexts[N - 1]);
  FCPU.InterruptEnabled := FCurrent.CallbackInterrupts[N - 1];
  SetLength(FCurrent.CallbackContexts, N - 1);
  SetLength(FCurrent.CallbackInterrupts, N - 1);
  SetLength(FCurrent.CallbackAlarms, N - 1);
  FCurrent.Context := FCPU.SaveContext;
  FCurrent.ContextDirty := False;
  FCPU.Yield;
  FLastCallResult := Cardinal(ReturnValue);
  if Assigned(Completion) then
    Completion();
  var Alarm: TPSPAlarm;
  if (AlarmId <> 0) and FAlarms.TryGetValue(AlarmId, Alarm) then
    if ReturnValue <= 0 then
      FAlarms.Remove(AlarmId)
    else
    begin
      if Alarm.Schedule + Cardinal(ReturnValue) > FTime then
        Inc(Alarm.Schedule, Cardinal(ReturnValue))
      else
        Alarm.Schedule := FTime + Cardinal(ReturnValue);
      Alarm.FireTime := Alarm.Schedule;
      Alarm.Pending := False;
    end;
end;

procedure TPSPKernel.UpdateWorkArea(Obj: TPSPSyncObject);
begin
  if Obj.WorkArea = 0 then
    Exit;
  FMemory.Write32(Obj.WorkArea, Obj.Count);
  FMemory.Write32(Obj.WorkArea + 4, Obj.Owner);
  FMemory.Write32(Obj.WorkArea + 8, Obj.Attributes);
  var Waiting: Cardinal := 0;
  for var Thread in FThreads do
    if (Thread.State.Status = TPSPThreadStatus.WaitingObject) and (Thread.State.WaitId = Obj.Id) then
      Inc(Waiting);
  FMemory.Write32(Obj.WorkArea + 12, Waiting);
  FMemory.Write32(Obj.WorkArea + 16, Obj.Id);
end;

function TPSPKernel.AcquireObject(Thread: TPSPThread; Obj: TPSPSyncObject; Amount, Mode, Output: Cardinal): Boolean;
begin
  Result := False;
  case Obj.Kind of
    4:
      begin
        var Address := Obj.Pool.Allocate(Amount);
        Result := Address <> $FFFFFFFF;
        if Result then
          FMemory.Write32(Output, Address);
      end;
    3:
      if Obj.Count <> 0 then
      begin
        Obj.Count := 0;
        if Output <> 0 then
          FMemory.Write32(Output, $08400000);
        if Mode <> 0 then
          FMemory.Write32(Mode, $00400000);
        Result := True;
      end;
    0:
      if Obj.Count >= Amount then
      begin
        Dec(Obj.Count, Amount);
        Result := True;
      end;
    1:
      begin
        Result := (Obj.Count and Amount) = Amount;
        if Mode and 1 <> 0 then
          Result := Obj.Count and Amount <> 0;
        if Result then
        begin
          if Output <> 0 then
            FMemory.Write32(Output, Obj.Count);
          if Mode and $10 <> 0 then
            Obj.Count := 0;
          if Mode and $20 <> 0 then
            Obj.Count := Obj.Count and not Amount;
        end;
      end;
    2:
      begin
        if Obj.WorkArea <> 0 then
        begin
          Obj.Count := FMemory.Read32(Obj.WorkArea);
          Obj.Owner := FMemory.Read32(Obj.WorkArea + 4);
        end;
        if (Obj.Count = 0) or ((Obj.Owner = Thread.Id) and (Obj.Attributes and $200 <> 0)) then
        begin
          if Amount > Cardinal(MaxInt) - Obj.Count then
            Exit;
          Inc(Obj.Count, Amount);
          Obj.Owner := Thread.Id;
          UpdateWorkArea(Obj);
          Result := True;
        end;
      end;
  end;
end;

function TPSPKernel.WaitObject(Obj: TPSPSyncObject; Amount, Mode, Output, Timeout: Cardinal; Poll: Boolean): Cardinal;
begin
  if Amount = 0 then
    Exit($800201BD);
  if (Obj.Kind = 0) and (Amount > Obj.Maximum) then
    Exit($800201BD);
  if (Output <> 0) and not FMemory.IsValid(Output, 4) then
    Exit($800200D3);
  if (Timeout <> 0) and not FMemory.IsValid(Timeout, 4) then
    Exit($800200D3);
  if AcquireObject(FCurrent, Obj, Amount, Mode, Output) then
    Exit(0);
  if Poll then
    Exit($800201AF);
  if not FDispatchEnabled or not FCPU.InterruptEnabled then
    Exit($800201A7);
  if (Timeout <> 0) and (FMemory.Read32(Timeout) = 0) then
    Exit($800201A8);
  Inc(FWaitSequence);
  FCurrent.State.Sequence := FWaitSequence;
  FCurrent.State.WaitId := Obj.Id;
  FCurrent.State.WaitValue := Amount;
  FCurrent.State.WaitMode := Mode;
  FCurrent.State.WaitOut := Output;
  FCurrent.State.TimeoutPointer := Timeout;
  FCurrent.State.WakeTime := 0;
  if Timeout <> 0 then
    FCurrent.State.WakeTime := FTime + FMemory.Read32(Timeout);
  FCurrent.State.Status := TPSPThreadStatus.WaitingObject;
  FCurrent.State.AcceptCallbacks := False;
  UpdateWorkArea(Obj);
  FCPU.Yield;
  Result := 0;
end;

procedure TPSPKernel.WakeObject(Obj: TPSPSyncObject);
begin
  var Waiting := TList<TPSPObjectWaiter>.Create;
  try
    for var Thread in FThreads do
      for var Depth := 0 to Length(Thread.CallbackWaits) do
      begin
        var State := Thread.WaitState(Depth);
        if (State.Status = TPSPThreadStatus.WaitingObject) and (State.WaitId = Obj.Id) then
        begin
          var Item: TPSPObjectWaiter;
          Item.Thread := Thread;
          Item.State := State;
          Waiting.Add(Item);
        end;
      end;
    Waiting.Sort(TComparer<TPSPObjectWaiter>.Construct(
      function(const Left, Right: TPSPObjectWaiter): Integer
      begin
        if (Obj.Kind = 4) and (Obj.Attributes and $300 = $200) and (Left.State.WaitValue <> Right.State.WaitValue) then
        begin
          if Left.State.WaitValue < Right.State.WaitValue then
            Exit(-1)
          else
            Exit(1);
        end;
        if (Obj.Attributes and $300 = $100) and (Left.Thread.Priority <> Right.Thread.Priority) then
        begin
          if Left.Thread.Priority < Right.Thread.Priority then
            Exit(-1)
          else
            Exit(1);
        end;
        if Left.State.Sequence < Right.State.Sequence then
          Exit(-1);
        if Left.State.Sequence > Right.State.Sequence then
          Exit(1);
        Result := 0;
      end));
    for var Item in Waiting do
    begin
      var State := Item.State;
      if AcquireObject(Item.Thread, Obj, State.WaitValue, State.WaitMode, State.WaitOut) then
      begin
        if State.TimeoutPointer <> 0 then
          FMemory.Write32(State.TimeoutPointer, Cardinal(Max(Int64(0), Int64(State.WakeTime) - Int64(FTime))));
        State.Status := TPSPThreadStatus.Ready;
        SetThreadResult(Item.Thread, 0, State);
      end
      else if ((Obj.Kind = 4) or (Obj.Kind = 0)) and (Obj.Attributes and $300 = 0) then
        Break;
    end;
  finally
    Waiting.Free;
  end;
  UpdateWorkArea(Obj);
  Yield;
end;

function TPSPKernel.Printf(Address: Cardinal): Cardinal;
var
  ArgIndex: Integer;

  function Argument: Cardinal;
  begin
    if ArgIndex < 8 then
      Result := FCPU.Registers[4 + ArgIndex]
    else
      Result := FMemory.Read32(FCPU.Registers[29] + Cardinal(ArgIndex - 8) * 4);
    Inc(ArgIndex);
  end;

begin
  if Address = 0 then
    Exit($FFFFFFFF);
  var FormatString := FMemory.ReadString(Address, 16384);
  var Text := TStringBuilder.Create;
  try
    ArgIndex := 1;
    var P := 1;
    while P <= Length(FormatString) do
    begin
      if FormatString[P] <> '%' then
      begin
        Text.Append(FormatString[P]);
        Inc(P);
        Continue
      end;
      Inc(P);
      if P > Length(FormatString) then
        Break;
      if FormatString[P] = '%' then
      begin
        Text.Append('%');
        Inc(P);
        Continue
      end;
      var Left := False;
      var Zero := False;
      var Prefix := False;
      var Plus := False;
      while (P <= Length(FormatString)) and CharInSet(FormatString[P], ['-', '0', '#', '+', ' ']) do
      begin
        case FormatString[P] of
          '-':
            Left := True;
          '0':
            Zero := True;
          '#':
            Prefix := True;
          '+':
            Plus := True
        end;
        Inc(P);
      end;
      var Width := 0;
      if (P <= Length(FormatString)) and (FormatString[P] = '*') then
      begin
        Width := Integer(EnsureRange(Int64(Integer(Argument)), Int64(-4096), Int64(4096)));
        Inc(P)
      end
      else
        while (P <= Length(FormatString)) and CharInSet(FormatString[P], ['0'..'9']) do
        begin
          Width := Min(4096, Width * 10 + Ord(FormatString[P]) - Ord('0'));
          Inc(P)
        end;
      if Width < 0 then
      begin
        Left := True;
        Width := Min(4096, Abs(Width))
      end;
      var Precision: Integer := -1;
      if (P <= Length(FormatString)) and (FormatString[P] = '.') then
      begin
        Inc(P);
        Precision := 0;
        while (P <= Length(FormatString)) and CharInSet(FormatString[P], ['0'..'9']) do
        begin
          Precision := Min(4096, Precision * 10 + Ord(FormatString[P]) - Ord('0'));
          Inc(P)
        end;
      end;
      while (P <= Length(FormatString)) and CharInSet(FormatString[P], ['h', 'l', 'z', 't', 'j']) do
        Inc(P);
      if P > Length(FormatString) then
        Break;
      var Specifier := FormatString[P];
      Inc(P);
      var Value: string;
      case Specifier of
        'd', 'i':
          begin
            var Number := Integer(Argument);
            Value := IntToStr(Number);
            if Plus and (Number >= 0) then
              Value := '+' + Value
          end;
        'u':
          Value := UIntToStr(Argument);
        'x', 'X', 'p':
          begin
            var Number := Argument;
            var Digits := Max(1, Precision);
            if Specifier = 'p' then
              Digits := 8;
            Value := IntToHex(Number, Digits);
            if Specifier <> 'X' then
              Value := LowerCase(Value);
            if Prefix and (Number <> 0) then
              if Specifier = 'X' then
                Value := '0X' + Value
              else
                Value := '0x' + Value;
          end;
        'c':
          Value := Char(Argument and 255);
        's':
          begin
            var Pointer := Argument;
            if Pointer = 0 then
              Value := '(null)'
            else
              Value := FMemory.ReadString(Pointer, 16384);
            if (Precision >= 0) and (Length(Value) > Precision) then
              SetLength(Value, Precision)
          end;
        'f', 'e', 'g':
          begin
            var Bits := Argument;
            var Float: Single;
            Move(Bits, Float, 4);
            Value := FloatToStr(Float, TFormatSettings.Invariant)
          end;
      else
        Value := '%' + Specifier;
      end;
      if Width > Length(Value) then
      begin
        var Pad: Char := ' ';
        if Zero and not Left then
          Pad := '0';
        if Left then
          Value := Value + StringOfChar(Pad, Width - Length(Value))
        else
          Value := StringOfChar(Pad, Width - Length(Value)) + Value;
      end;
      Text.Append(Value);
      if Text.Length > 65536 then
        Break;
    end;
    FDebugOutput := FDebugOutput + Text.ToString;
    if Length(FDebugOutput) > 65536 then
      Delete(FDebugOutput, 1, Length(FDebugOutput) - 65536);
    {$IFDEF PSP_TRACE_PRINTF}            Write(Text.ToString);{$ENDIF}
    Result := 0;
  finally
    Text.Free
  end;
end;

function TPSPKernel.VTimerTime(Timer: TPSPVTimer): UInt64;
begin
  Result := Timer.Current;
  if Timer.Active then
    Inc(Result, FTime - Timer.Base)
end;

procedure TPSPKernel.ScheduleVTimer(Timer: TPSPVTimer);
begin
  if not Timer.Active or (Timer.Handler = 0) then
    Exit;
  var Current := VTimerTime(Timer);
  Timer.FireTime := FTime + 250;
  if (Timer.Schedule > Current) and (Timer.Schedule - Current > 250) then
    Timer.FireTime := FTime + Timer.Schedule - Current;
end;

procedure TPSPKernel.FireVTimers;
begin
  for var Timer in FVTimers.Values do
    if Timer.Active and not Timer.Pending and (Timer.Handler <> 0) and (Timer.FireTime <= FTime) then
    begin
      var Id := Timer.Id;
      var Generation := Timer.Generation;
      FMemory.Write32(Timer.Address, Cardinal(Timer.Schedule));
      FMemory.Write32(Timer.Address + 4, Cardinal(Timer.Schedule shr 32));
      var Current := VTimerTime(Timer);
      FMemory.Write32(Timer.Address + 8, Cardinal(Current));
      FMemory.Write32(Timer.Address + 12, Cardinal(Current shr 32));
      QueueCall4(Timer.Handler, Id, Timer.Address, Timer.Address + 8, Timer.Argument, True,
        procedure
        begin
          var Active: TPSPVTimer;
          if not FVTimers.TryGetValue(Id, Active) or (Active.Generation <> Generation) then
            Exit;
          Active.Pending := False;
          if FLastCallResult = 0 then
            Active.Handler := 0
          else
          begin
            Inc(Active.Schedule, FLastCallResult);
            ScheduleVTimer(Active)
          end;
        end);
      var Call := FGuestCalls.Last;
      Call.TimerId := Id;
      Call.TimerGeneration := Generation;
      Call.SetGP := True;
      Call.GP := Timer.GP;
      FGuestCalls[FGuestCalls.Count - 1] := Call;
      Timer.Pending := True;
    end;
end;

function TPSPKernel.HandleVTimer(NID: Cardinal; out Value: Cardinal): Boolean;

  function Read64(Address: Cardinal): UInt64;
  begin
    Result := UInt64(FMemory.Read32(Address)) or (UInt64(FMemory.Read32(Address + 4)) shl 32)
  end;

  procedure Write64(Address: Cardinal; Value: UInt64);
  begin
    FMemory.Write32(Address, Cardinal(Value));
    FMemory.Write32(Address + 4, Cardinal(Value shr 32))
  end;

begin
  Result := True;
  Value := 0;
  case NID of
    $20FFF560, $328F9E52, $C68D9437, $D0AEEE87, $D2D615EF, $B3A59970, $B7C18B77, $034A921F, $C0B3FFD2, $5F32BEAA, $542AD630, $FB6425C3, $D8B299AE, $53B00E9A:
      ;
  else
    Exit(False);
  end;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  if NID = $20FFF560 then
  begin
    if A = 0 then
    begin
      Value := $80020001;
      Exit
    end;
    var Timer := TPSPVTimer.Create;
    Timer.Name := FMemory.ReadString(A, 32);
    Timer.Id := NewId;
    Timer.Block := ReserveModule(128, Timer.Address, True);
    if Timer.Block and $80000000 <> 0 then
    begin
      Value := Timer.Block;
      Timer.Free;
      Exit
    end;
    Value := Timer.Id;
    FVTimers.Add(Timer.Id, Timer);
    Exit;
  end;
  var Timer: TPSPVTimer;
  if not FVTimers.TryGetValue(A, Timer) then
  begin
    Value := $800201BE;
    if (NID = $B7C18B77) or (NID = $C0B3FFD2) or (NID = $FB6425C3) then
    begin
      Value := $FFFFFFFF;
      FCPU.Registers[3] := $FFFFFFFF
    end;
    Exit;
  end;
  case NID of
    $328F9E52:
      begin
        for var I := FGuestCalls.Count - 1 downto 0 do
          if FGuestCalls[I].TimerId = A then
            FGuestCalls.Delete(I);
        FreeBlock(Timer.Block);
        FVTimers.Remove(A);
      end;
    $C68D9437:
      begin
        Value := Ord(Timer.Active);
        if not Timer.Active then
        begin
          Timer.Active := True;
          Timer.Base := FTime;
          ScheduleVTimer(Timer)
        end
      end;
    $D0AEEE87:
      begin
        Value := Ord(Timer.Active);
        Timer.Current := VTimerTime(Timer);
        Timer.Active := False;
        Timer.Base := 0
      end;
    $D2D615EF:
      begin
        Timer.Handler := 0;
        Timer.Pending := False;
        Inc(Timer.Generation);
        for var I := FGuestCalls.Count - 1 downto 0 do
          if FGuestCalls[I].TimerId = A then
            FGuestCalls.Delete(I);
      end;
    $B3A59970:
      Write64(B, Timer.Base);
    $B7C18B77:
      begin
        Value := Cardinal(Timer.Base);
        FCPU.Registers[3] := Cardinal(Timer.Base shr 32)
      end;
    $034A921F:
      Write64(B, VTimerTime(Timer));
    $C0B3FFD2:
      begin
        var Current := VTimerTime(Timer);
        Value := Cardinal(Current);
        FCPU.Registers[3] := Cardinal(Current shr 32)
      end;
    $542AD630, $FB6425C3:
      begin
        var Old := VTimerTime(Timer);
        if NID = $542AD630 then
        begin
          Timer.Current := Read64(B);
          Write64(B, Old)
        end
        else
        begin
          Timer.Current := UInt64(C) or (UInt64(D) shl 32);
          Value := Cardinal(Old);
          FCPU.Registers[3] := Cardinal(Old shr 32)
        end;
        if Timer.Active then
          Timer.Base := FTime;
        ScheduleVTimer(Timer);
      end;
    $D8B299AE, $53B00E9A:
      begin
        if NID = $D8B299AE then
        begin
          Timer.Schedule := Read64(B);
          Timer.Handler := C;
          Timer.Argument := D
        end
        else
        begin
          Timer.Schedule := UInt64(C) or (UInt64(D) shl 32);
          Timer.Handler := FCPU.Registers[8];
          Timer.Argument := FCPU.Registers[9]
        end;
        if (Timer.Handler <> 0) and not FMemory.IsValid(Timer.Handler, 4) then
        begin
          Timer.Handler := 0;
          Value := $800200D3;
          Exit
        end;
        Timer.GP := FCPU.Registers[28];
        Inc(Timer.Generation);
        Timer.Pending := False;
        ScheduleVTimer(Timer);
      end;
    $5F32BEAA:
      begin
        var Size := Min(FMemory.Read32(B), Cardinal(72));
        if Size = 0 then
          Exit;
        if not FMemory.IsValid(B, Size) then
        begin
          Value := $800200D3;
          Exit
        end;
        var Data: Cardinal := Timer.Address + 16;
        FMemory.Zero(Data, 72);
        FMemory.Write32(Data, 72);
        FMemory.Load(Data + 4, TEncoding.UTF8.GetBytes(Timer.Name));
        FMemory.Write32(Data + 36, Ord(Timer.Active));
        Write64(Data + 40, Timer.Base);
        Write64(Data + 48, VTimerTime(Timer));
        Write64(Data + 56, Timer.Schedule);
        FMemory.Write32(Data + 64, Timer.Handler);
        FMemory.Write32(Data + 68, Timer.Argument);
        FMemory.CopyMemory(B, Data, Size);
      end;
  end;
end;

procedure TPSPKernel.PumpMsgPipe(Obj: TPSPSyncObject);

  procedure Complete(const Item: TPSPObjectWaiter);
  begin
    var State := Item.State;
    if State.WaitOut <> 0 then
      FMemory.Write32(State.WaitOut, State.PipeTransferred);
    if State.TimeoutPointer <> 0 then
      FMemory.Write32(State.TimeoutPointer, Cardinal(Max(Int64(0), Int64(State.WakeTime) - Int64(FTime))));
    State.Status := TPSPThreadStatus.Ready;
    SetThreadResult(Item.Thread, 0, State);
  end;

  procedure Order(Items: TList<TPSPObjectWaiter>; Priority: Boolean);
  begin
    Items.Sort(TComparer<TPSPObjectWaiter>.Construct(
      function(const L, R: TPSPObjectWaiter): Integer
      begin
        if Priority and (L.Thread.Priority <> R.Thread.Priority) then
        begin
          if L.Thread.Priority < R.Thread.Priority then
            Exit(-1)
          else
            Exit(1)
        end;
        if L.State.Sequence < R.State.Sequence then
          Exit(-1);
        if L.State.Sequence > R.State.Sequence then
          Exit(1);
        Result := 0;
      end));
  end;

begin
  var Senders := TList<TPSPObjectWaiter>.Create;
  var Receivers := TList<TPSPObjectWaiter>.Create;
  try
    for var Thread in FThreads do
      for var Depth := 0 to Length(Thread.CallbackWaits) do
      begin
        var State := Thread.WaitState(Depth);
        if (State.Status <> TPSPThreadStatus.WaitingObject) or (State.WaitId <> Obj.Id) then
          Continue;
        var Item: TPSPObjectWaiter;
        Item.Thread := Thread;
        Item.State := State;
        if State.WaitMode and 2 <> 0 then
          Senders.Add(Item)
        else
          Receivers.Add(Item);
      end;
    Order(Senders, Obj.Attributes and $100 <> 0);
    Order(Receivers, Obj.Attributes and $1000 <> 0);
    if Obj.PipeSize = 0 then
    begin
      while (Senders.Count <> 0) and (Receivers.Count <> 0) do
      begin
        var S := Senders[0].State;
        var R := Receivers[0].State;
        var Count := Min(S.WaitValue - S.PipeTransferred, R.WaitValue - R.PipeTransferred);
        FMemory.CopyMemory(R.PipeAddress + R.PipeTransferred, S.PipeAddress + S.PipeTransferred, Count);
        Inc(S.PipeTransferred, Count);
        Inc(R.PipeTransferred, Count);
        if S.WaitOut <> 0 then
          FMemory.Write32(S.WaitOut, S.PipeTransferred);
        if R.WaitOut <> 0 then
          FMemory.Write32(R.WaitOut, R.PipeTransferred);
        if (S.PipeTransferred = S.WaitValue) or (S.WaitMode and 1 <> 0) then
        begin
          Complete(Senders[0]);
          Senders.Delete(0)
        end;
        if (R.PipeTransferred = R.WaitValue) or (R.WaitMode and 1 <> 0) then
        begin
          Complete(Receivers[0]);
          Receivers.Delete(0)
        end;
      end;
      Exit;
    end;
    var Progress: Boolean;
    repeat
      Progress := False;
      while Receivers.Count <> 0 do
      begin
        var State := Receivers[0].State;
        var Count := State.WaitValue;
        if Count > Obj.PipeUsed then
          if State.WaitMode and 1 <> 0 then
            Count := Obj.PipeUsed
          else
            Break;
        if Count = 0 then
          Break;
        var First := Min(Count, Obj.PipeSize - Obj.PipeHead);
        FMemory.CopyMemory(State.PipeAddress, Obj.PipeAddress + Obj.PipeHead, First);
        if First < Count then
          FMemory.CopyMemory(State.PipeAddress + First, Obj.PipeAddress, Count - First);
        Obj.PipeHead := (Obj.PipeHead + Count) mod Obj.PipeSize;
        Dec(Obj.PipeUsed, Count);
        State.PipeTransferred := Count;
        Complete(Receivers[0]);
        Receivers.Delete(0);
        Progress := True;
      end;
      while Senders.Count <> 0 do
      begin
        var State := Senders[0].State;
        var Count := State.WaitValue;
        if Count > Obj.PipeSize - Obj.PipeUsed then
          if State.WaitMode and 1 <> 0 then
            Count := Obj.PipeSize - Obj.PipeUsed
          else
            Break;
        if Count = 0 then
          Break;
        var At := (Obj.PipeHead + Obj.PipeUsed) mod Obj.PipeSize;
        var First := Min(Count, Obj.PipeSize - At);
        FMemory.CopyMemory(Obj.PipeAddress + At, State.PipeAddress, First);
        if First < Count then
          FMemory.CopyMemory(Obj.PipeAddress, State.PipeAddress + First, Count - First);
        Inc(Obj.PipeUsed, Count);
        State.PipeTransferred := Count;
        Complete(Senders[0]);
        Senders.Delete(0);
        Progress := True;
      end;
    until not Progress;
  finally
    Receivers.Free;
    Senders.Free
  end;
end;

function TPSPKernel.HandleMsgPipe(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  var E := FCPU.Registers[8];
  var F := FCPU.Registers[9];
  if NID = $7C0DC2A0 then
  begin
    if A = 0 then
    begin
      Value := $80020190;
      Exit
    end;
    if (B < 1) or (B > 6) then
    begin
      Value := $800200D2;
      Exit
    end;
    if (B <> 2) and not ((B = 1) and (FKernelPrivilege > 0)) then
    begin
      Value := $800200D1;
      Exit
    end;
    if C and not $51FF <> 0 then
    begin
      Value := $80020191;
      Exit
    end;
    if D > PSPRAMSize then
    begin
      Value := $80020190;
      Exit
    end;
    if (E <> 0) and not FMemory.IsValid(E, 4) then
    begin
      Value := $800200D3;
      Exit
    end;
    var Name := FMemory.ReadString(A, 32);
    var Block: Cardinal := 0;
    if D <> 0 then
    begin
      var Kind: Cardinal := 0;
      if C and $4000 <> 0 then
        Kind := 1;
      if B = 1 then
        Block := AllocateRanges(D, Kind, 0, FKernelFree, True)
      else
        Block := Allocate(D, Kind, 0);
      if Block and $80000000 <> 0 then
      begin
        Value := Block;
        Exit
      end;
    end;
    var Obj := TPSPSyncObject.Create;
    Obj.Id := NewId;
    Obj.Kind := 5;
    Obj.Name := Name;
    Obj.Attributes := C;
    Obj.PoolBlock := Block;
    Obj.PipeAddress := BlockAddress(Block);
    Obj.PipeSize := D;
    FObjects.Add(Obj.Id, Obj);
    Value := Obj.Id;
    Exit;
  end;
  case NID of
    $F0B7DA1C, $876DBFAD, $7C41F2C2, $884C9F90, $74829B76, $FBFA697D, $DF52098F, $349B864D, $33BE4024:
      ;
  else
    Exit(False)
  end;
  var Obj: TPSPSyncObject;
  if not FObjects.TryGetValue(A, Obj) or (Obj.Kind <> 5) then
  begin
    Value := $8002019E;
    Exit
  end;
  if (NID = $F0B7DA1C) or (NID = $349B864D) or (NID = $33BE4024) then
  begin
    var Senders: Cardinal := 0;
    var Receivers: Cardinal := 0;
    if (NID = $349B864D) and (((B <> 0) and not FMemory.IsValid(B, 4)) or ((C <> 0) and not FMemory.IsValid(C, 4))) then
    begin
      Value := $800200D3;
      Exit
    end;
    if (NID = $33BE4024) and not FMemory.IsValid(B, 56) then
    begin
      Value := $800200D3;
      Exit
    end;
    for var Thread in FThreads do
      for var Depth := 0 to Length(Thread.CallbackWaits) do
      begin
        var State := Thread.WaitState(Depth);
        if (State.Status <> TPSPThreadStatus.WaitingObject) or (State.WaitId <> A) then
          Continue;
        if State.WaitMode and 2 <> 0 then
          Inc(Senders)
        else
          Inc(Receivers);
        if NID = $33BE4024 then
          Continue;
        State.Status := TPSPThreadStatus.Ready;
        if NID = $F0B7DA1C then
          SetThreadResult(Thread, $800201B5, State)
        else
          SetThreadResult(Thread, $800201A9, State);
      end;
    case NID of
      $33BE4024:
        if FMemory.Read32(B) <> 0 then
        begin
          FMemory.Zero(B, 56);
          FMemory.Write32(B, 56);
          FMemory.Load(B + 4, Copy(TEncoding.UTF8.GetBytes(Obj.Name), 0, 31));
          FMemory.Write32(B + 36, Obj.Attributes);
          FMemory.Write32(B + 40, Obj.PipeSize);
          FMemory.Write32(B + 44, Obj.PipeSize - Obj.PipeUsed);
          FMemory.Write32(B + 48, Senders);
          FMemory.Write32(B + 52, Receivers);
        end;
      $349B864D:
        begin
          if B <> 0 then
            FMemory.Write32(B, Senders);
          if C <> 0 then
            FMemory.Write32(C, Receivers);
          Obj.PipeUsed := 0;
          Obj.PipeHead := 0;
        end;
      $F0B7DA1C:
        begin
          if Obj.PoolBlock <> 0 then
            FreeBlock(Obj.PoolBlock);
          FObjects.Remove(A)
        end;
    end;
    if NID <> $33BE4024 then
      Yield;
    Exit;
  end;
  var Send := (NID = $876DBFAD) or (NID = $7C41F2C2) or (NID = $884C9F90);
  var Poll := (NID = $884C9F90) or (NID = $DF52098F);
  if (C and $80000000 <> 0) or ((C <> 0) and not FMemory.IsValid(B, C)) or ((E <> 0) and not FMemory.IsValid(E, 4)) then
  begin
    Value := $800200D3;
    Exit
  end;
  if D > 1 then
  begin
    Value := $80020195;
    Exit
  end;
  if (Obj.PipeSize <> 0) and (C > Obj.PipeSize) then
  begin
    Value := $800201BC;
    Exit
  end;
  if not Poll and not FDispatchEnabled then
  begin
    Value := $800201A7;
    Exit
  end;
  if not Poll and not FCPU.InterruptEnabled then
  begin
    Value := $80020064;
    Exit
  end;
  if Poll then
    F := 0;
  if (F <> 0) and not FMemory.IsValid(F, 4) then
  begin
    Value := $800200D3;
    Exit
  end;
  if C = 0 then
  begin
    if E <> 0 then
      FMemory.Write32(E, 0);
    Exit
  end;
  var State := FCurrent.State;
  State.WaitId := A;
  State.WaitValue := C;
  State.WaitMode := D or (Cardinal(Ord(Send)) * 2);
  State.WaitOut := E;
  State.PipeAddress := B;
  State.PipeTransferred := 0;
  State.TimeoutPointer := F;
  State.WakeTime := 0;
  if F <> 0 then
    State.WakeTime := FTime + FMemory.Read32(F);
  Inc(FWaitSequence);
  State.Sequence := FWaitSequence;
  State.Status := TPSPThreadStatus.WaitingObject;
  State.AcceptCallbacks := (NID = $7C41F2C2) or (NID = $FBFA697D);
  PumpMsgPipe(Obj);
  if State.Status = TPSPThreadStatus.WaitingObject then
  begin
    if Poll then
    begin
      State.Status := TPSPThreadStatus.Ready;
      if Send then
        Value := $800201B3
      else
        Value := $800201B4;
    end
    else if (F <> 0) and (FMemory.Read32(F) = 0) then
    begin
      State.Status := TPSPThreadStatus.Ready;
      Value := $800201A8
    end
    else
      FCPU.Yield;
  end
  else
    Yield;
end;

function TPSPKernel.HandleVpl(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  if NID = $56C039B5 then
  begin
    if A = 0 then
    begin
      Value := $80020001;
      Exit;
    end;
    if (B < 1) or (B > 6) then
    begin
      Value := $800200D2;
      Exit;
    end;
    if (B <> 2) and not ((B = 1) and (FKernelPrivilege > 0)) then
    begin
      Value := $800200D1;
      Exit;
    end;
    if C and not $43FF <> 0 then
    begin
      Value := $80020191;
      Exit;
    end;
    if D = 0 then
    begin
      Value := $800201B7;
      Exit;
    end;
    if D > PSPRAMSize then
    begin
      Value := $80020190;
      Exit;
    end;
    var Size := D;
    if Size <= $30 then
      Size := $1000;
    Size := (Size + 7) and $FFFFFFF8;
    var Kind: Cardinal := 0;
    if C and $4000 <> 0 then
      Kind := 1;
    var Block: Cardinal;
    if B = 1 then
      Block := AllocateRanges(Size, Kind, 0, FKernelFree, True)
    else
      Block := Allocate(Size, Kind, 0);
    if Block and $80000000 <> 0 then
    begin
      Value := Block;
      Exit;
    end;
    var Obj := TPSPSyncObject.Create;
    try
      Obj.Kind := 4;
      Obj.Id := NewId;
      Obj.Name := FMemory.ReadString(A, 32);
      Obj.Attributes := C;
      Obj.PoolBlock := Block;
      Obj.Pool := TPSPVariablePool.Create(FMemory, BlockAddress(Block), Size);
      FObjects.Add(Obj.Id, Obj);
    except
      Obj.Free;
      FreeBlock(Block);
      raise;
    end;
    Value := Obj.Id;
    Exit;
  end;
  case NID of
    $89B3D48C, $BED27435, $EC0A693F, $AF36D708, $B736E9FF, $1D371B8A, $39810265:
      ;
  else
    Exit(False);
  end;
  var Obj: TPSPSyncObject;
  if not FObjects.TryGetValue(A, Obj) or (Obj.Kind <> 4) then
  begin
    Value := $8002019C;
    Exit;
  end;
  case NID of
    $BED27435, $EC0A693F, $AF36D708:
      begin
        if (B = 0) or (B > Obj.Pool.Size - $20) then
        begin
          Value := $800201B7;
          Exit;
        end;
        if not FMemory.IsValid(C, 4) then
        begin
          Value := $800200D3;
          Exit;
        end;
        var Timeout := D;
        if NID = $AF36D708 then
          Timeout := 0;
        Value := WaitObject(Obj, B, 0, C, Timeout, NID = $AF36D708);
        if Value = $800201AF then
          Value := $80020190;
        if (NID = $EC0A693F) and (FCurrent.State.Status = TPSPThreadStatus.WaitingObject) then
          AcceptCallbacks;
      end;
    $B736E9FF:
      if not Obj.Pool.Release(B) then
        Value := $800201B6
      else
        WakeObject(Obj);
    $39810265:
      begin
        if not FMemory.IsValid(B, 52) then
        begin
          Value := $800200D3;
          Exit;
        end;
        if FMemory.Read32(B) = 0 then
          Exit;
        FMemory.Zero(B, 52);
        FMemory.Write32(B, 52);
        FMemory.Load(B + 4, Copy(TEncoding.UTF8.GetBytes(Obj.Name), 0, 31));
        FMemory.Write32(B + 36, Obj.Attributes);
        FMemory.Write32(B + 40, Obj.Pool.Size - $20);
        FMemory.Write32(B + 44, Obj.Pool.FreeSize);
        var Waiting: Cardinal := 0;
        for var Thread in FThreads do
          for var Depth := 0 to Length(Thread.CallbackWaits) do
          begin
            var State := Thread.WaitState(Depth);
            if (State.Status = TPSPThreadStatus.WaitingObject) and (State.WaitId = A) then
              Inc(Waiting);
          end;
        FMemory.Write32(B + 48, Waiting);
      end;
    $89B3D48C, $1D371B8A:
      begin
        var Waiting: Cardinal := 0;
        for var Thread in FThreads do
          for var Depth := 0 to Length(Thread.CallbackWaits) do
          begin
            var State := Thread.WaitState(Depth);
            if (State.Status = TPSPThreadStatus.WaitingObject) and (State.WaitId = A) then
            begin
              Inc(Waiting);
              State.Status := TPSPThreadStatus.Ready;
              if NID = $89B3D48C then
                SetThreadResult(Thread, $800201B5, State)
              else
                SetThreadResult(Thread, $800201A9, State);
            end;
          end;
        if (NID = $1D371B8A) and (B <> 0) then
          FMemory.Write32(B, Waiting);
        if NID = $89B3D48C then
        begin
          FreeBlock(Obj.PoolBlock);
          FObjects.Remove(A);
        end;
        Yield;
      end;
  end;
end;

function TPSPKernel.HandleSync(const ModuleName: string; NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  if (ModuleName = 'ThreadManForUser') and
    ((NID = $D6DA4BA1) or (NID = $55C20A00) or (NID = $B7D098C6) or (NID = $19CFF145)) then
  begin
    var Obj := TPSPSyncObject.Create;
    Obj.Id := NewId;
    if NID <> $19CFF145 then
      Obj.Name := FMemory.ReadString(A);
    Obj.Attributes := B;
    Obj.Owner := $FFFFFFFF;
    case NID of
      $D6DA4BA1:
        begin
          Obj.Kind := 0;
          Obj.Count := C;
          Obj.Maximum := D;
        end;
      $55C20A00:
        begin
          Obj.Kind := 1;
          Obj.Count := C;
        end;
      $B7D098C6:
        begin
          Obj.Kind := 2;
          Obj.Count := C;
        end;
      $19CFF145:
        begin
          if not FMemory.IsValid(A, 32) then
          begin
            Obj.Free;
            Value := $800200D3;
            Exit;
          end;
          Obj.Name := FMemory.ReadString(B);
          Obj.Kind := 2;
          Obj.Count := D;
          Obj.Attributes := C;
          Obj.WorkArea := A;
          FMemory.Zero(A, 32);
        end;
    end;
    if (Obj.Kind = 0) and ((Integer(Obj.Count) < 0) or (Obj.Maximum = 0) or (Obj.Count > Obj.Maximum)) then
    begin
      Obj.Free;
      Value := $800201BD;
      Exit;
    end;
    if (Obj.Kind = 2) and (Obj.Count <> 0) then
      Obj.Owner := FCurrent.Id;
    Obj.InitialValue := Obj.Count;
    FObjects.Add(Obj.Id, Obj);
    UpdateWorkArea(Obj);
    if Obj.WorkArea = 0 then
      Value := Obj.Id;
    Exit;
  end;
  var Id := A;
  var Lightweight := ((ModuleName = 'Kernel_Library') and
    ((NID = $BEA46419) or (NID = $1FC64E09) or (NID = $DC692EE3) or (NID = $37431849) or (NID = $15B6446B))) or
    ((ModuleName = 'ThreadManForUser') and (NID = $60107536));
  if Lightweight then
  begin
    if not FMemory.IsValid(A, 32) then
    begin
      Value := $800200D3;
      Exit;
    end;
    Id := FMemory.Read32(A + 16);
  end
  else if ModuleName <> 'ThreadManForUser' then
    Exit(False);
  var Obj: TPSPSyncObject := nil;
  FObjects.TryGetValue(Id, Obj);
  var ExpectedKind: Cardinal;
  case NID of
    $4E3A1105, $6D212BAC, $58B1F937, $3F53E640, $28B6489C, $BC6FEBC5:
      ExpectedKind := 0;
    $402FCF22, $328C546A, $30FD48F0, $1FB15A32, $812346E4, $EF9E4C70, $A66B0120:
      ExpectedKind := 1;
    $B011B11F, $5BF4DD27, $0DDCD2C9, $6B30100F, $F8170FBE, $BEA46419, $1FC64E09, $DC692EE3, $37431849, $15B6446B, $60107536:
      ExpectedKind := 2;
  else
    Exit(False);
  end;
  if (Obj = nil) or (Obj.Kind <> ExpectedKind) or
    ((ExpectedKind = 2) and ((Obj.WorkArea <> 0) <> Lightweight)) then
  begin
    case ExpectedKind of
      0:
        Value := $80020199;
      1:
        Value := $8002019A;
      2:
        if Lightweight then
          Value := $800201CA
        else
          Value := $800201C3;
    end;
    Exit;
  end;
  case NID of
    $4E3A1105, $6D212BAC, $58B1F937, $402FCF22, $328C546A, $30FD48F0, $B011B11F, $5BF4DD27, $0DDCD2C9, $BEA46419, $1FC64E09, $DC692EE3, $37431849:
      begin
        if Obj = nil then
        begin
          Value := $800200CB;
          Exit;
        end;
        var Timeout := C;
        var Output: Cardinal := 0;
        var Mode: Cardinal := 0;
        if Obj.Kind = 1 then
        begin
          Mode := C;
          Output := D;
          Timeout := FCPU.Registers[8];
        end;
        if (NID = $58B1F937) or (NID = $30FD48F0) or (NID = $0DDCD2C9) or (NID = $DC692EE3) or (NID = $37431849) then
          Timeout := 0;
        Value := WaitObject(Obj, B, Mode, Output, Timeout,
          (NID = $58B1F937) or (NID = $30FD48F0) or (NID = $0DDCD2C9) or (NID = $DC692EE3) or (NID = $37431849));
        if FCurrent.State.Status = TPSPThreadStatus.WaitingObject then
          case NID of
            $6D212BAC, $328C546A, $5BF4DD27, $1FC64E09:
              AcceptCallbacks;
          end;
      end;
    $3F53E640, $1FB15A32, $812346E4, $6B30100F, $15B6446B:
      begin
        if Obj = nil then
        begin
          Value := $800200CB;
          Exit;
        end;
        case Obj.Kind of
          0:
            if (B = 0) or (Integer(B) < 0) then
              Value := $800201BD
            else if UInt64(Obj.Count) + B > Obj.Maximum then
              Value := $800201AE
            else
              Inc(Obj.Count, B);
          1:
            if NID = $812346E4 then
              Obj.Count := Obj.Count and B
            else
              Obj.Count := Obj.Count or B;
          2:
            begin
              if Obj.WorkArea <> 0 then
              begin
                Obj.Count := FMemory.Read32(Obj.WorkArea);
                Obj.Owner := FMemory.Read32(Obj.WorkArea + 4);
              end;
              if Obj.Owner <> FCurrent.Id then
                Value := $800201C5
              else if (B = 0) or (B > Obj.Count) then
                Value := $800201BD
              else
              begin
                Dec(Obj.Count, B);
                if Obj.Count = 0 then
                  Obj.Owner := $FFFFFFFF;
                UpdateWorkArea(Obj);
              end;
            end;
        end;
        if Value = 0 then
          WakeObject(Obj);
      end;
    $BC6FEBC5, $A66B0120:
      begin
        var Expected: Cardinal := 0;
        if NID = $A66B0120 then
          Expected := 1;
        if (Obj = nil) or (Obj.Kind <> Expected) then
        begin
          Value := $800200CB;
          Exit;
        end;
        if not FMemory.IsValid(B, 4) then
        begin
          Value := $FFFFFFFF;
          Exit;
        end;
        if FMemory.Read32(B) = 0 then
          Exit;
        var Size: Cardinal := 56;
        if Expected = 1 then
          Size := 52;
        if not FMemory.IsValid(B, Size) then
        begin
          Value := $FFFFFFFF;
          Exit;
        end;
        FMemory.Zero(B, Size);
        FMemory.Write32(B, Size);
        var Name := TEncoding.UTF8.GetBytes(Obj.Name);
        FMemory.Load(B + 4, Copy(Name, 0, 31));
        FMemory.Write32(B + 36, Obj.Attributes);
        FMemory.Write32(B + 40, Obj.InitialValue);
        FMemory.Write32(B + 44, Obj.Count);
        var Waiters: Cardinal := 0;
        for var Thread in FThreads do
          if (Thread.State.Status = TPSPThreadStatus.WaitingObject) and (Thread.State.WaitId = Obj.Id) then
            Inc(Waiters);
        if Expected = 0 then
          FMemory.Write32(B + 48, Obj.Maximum);
        FMemory.Write32(B + Size - 4, Waiters);
      end;
    $28B6489C, $EF9E4C70, $F8170FBE, $60107536:
      begin
        if Obj = nil then
        begin
          Value := $800200CB;
          Exit;
        end;
        var WokeThreads := False;
        for var Thread in FThreads do
          for var Depth := 0 to Length(Thread.CallbackWaits) do
          begin
            var State := Thread.WaitState(Depth);
            if (State.Status = TPSPThreadStatus.WaitingObject) and (State.WaitId = Id) then
            begin
              State.Status := TPSPThreadStatus.Ready;
              SetThreadResult(Thread, $800201B5, State);
              WokeThreads := True;
            end;
          end;
        if Lightweight then
        begin
          FMemory.Write32(A, 0);
          FMemory.Write32(A + 4, $FFFFFFFF);
          FMemory.Write32(A + 12, 0);
          FMemory.Write32(A + 16, $FFFFFFFF);
        end;
        FObjects.Remove(Id);
        if WokeThreads then
          Yield;
      end;
  else
    Result := False;
  end;
end;

function TPSPKernel.Handle(const ModuleName: string; NID: Cardinal; out Value: Cardinal): Boolean;
begin
  if ModuleName = 'ThreadManForKernel' then
  begin
    Inc(FKernelPrivilege);
    try
      Exit(Handle('ThreadManForUser', NID, Value));
    finally
      Dec(FKernelPrivilege);
    end;
  end;
  if (ModuleName = 'ThreadManForUser') and HandleVTimer(NID, Value) then
    Exit(True);
  if (ModuleName = 'ThreadManForUser') and HandleVpl(NID, Value) then
    Exit(True);
  if (ModuleName = 'ThreadManForUser') and HandleMsgPipe(NID, Value) then
    Exit(True);
  if HandleSync(ModuleName, NID, Value) then
    Exit(True);
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  if (ModuleName = 'sceSuspendForUser') and ((NID = $3E0271D3) or (NID = $A14F40B2) or (NID = $A569E425)) then
  begin
    if A <> 0 then
    begin
      Value := $80000107;
      Exit;
    end;
    if NID = $A569E425 then
    begin
      if FVolatileMemory.Count <> 0 then
      begin
        Value := $800201AE;
        Exit;
      end;
      FVolatileMemory.Count := 1;
      WakeObject(FVolatileMemory);
      Exit;
    end;
    if ((B <> 0) and not FMemory.IsValid(B, 4)) or ((C <> 0) and not FMemory.IsValid(C, 4)) then
    begin
      Value := $80000103;
      Exit;
    end;
    if NID = $3E0271D3 then
    begin
      if not FDispatchEnabled then
        Value := $800201A7
      else if (Length(FCurrent.CallbackContexts) > 0) and not FCPU.InterruptEnabled then
        Value := $80020064;
      if Value <> 0 then
      begin
        if B <> 0 then
          FMemory.Write32(B, $08400000);
        if C <> 0 then
          FMemory.Write32(C, $00400000);
        Exit;
      end;
    end;
    Value := WaitObject(FVolatileMemory, 1, C, B, 0, NID = $A14F40B2);
    if Value = $800201AF then
      Value := $802B0200;
    Exit;
  end;
  if ModuleName = 'SysMemUserForUser' then
    case NID of
      $13A5ABEF:
        Value := Printf(A);
      $7591C7DB, $342061E5, $315AD3A0, $EBD5C3E6, $057E7380, $91DE343C, $7893F79A, $35669D4C, $1B4217BC, $358CA1BB:
        FSDK := A;
      $F77D77CB:
        FCompiler := A;
      $FC114573:
        Value := FSDK;
      $3FC9AE6A:
        Value := $06060110;
      $A291F107:
        for var Range in FFree do
          Value := Max(Value, Range.Size);
      $F919F628:
        for var Range in FFree do
          Inc(Value, Range.Size);
      $ACBD88CA:
        Value := PSPRAMSize;
      $237DBD4F:
        if A <> 2 then
          Value := $800200D6
        else
          Value := Allocate(D, C, FCPU.Registers[8]);
      $9D9A5BA1:
        begin
          Value := BlockAddress(A);
          if Value = 0 then
            Value := $800200CB;
        end;
      $B6D61D02:
        Value := FreeBlock(A);
      $50F61D8A:
        Value := FreeBlock(A);
      $FE707FDF:
        if A = 0 then
          Value := $80020001
        else if B > 1 then
          Value := $800200D8
        else if (D <> 0) and (FMemory.Read32(D) <> 4) then
          Value := $800200D2
        else
        begin
          Value := Allocate(C, B, 0);
          if Value and $80000000 <> 0 then
            Value := $800200D9;
        end;
      $DB83A952:
        begin
          var Address := BlockAddress(A);
          if Address = 0 then
            Value := $800200CB
          else
            FMemory.Write32(B, Address);
        end;
    else
      Result := False;
    end
  else if (ModuleName = 'InterruptManager') or (ModuleName = 'InterruptManagerForKernel') then
  begin
    if (A > 66) or (B > 31) then
    begin
      Value := $80020065;
      Exit;
    end;
    case NID of
      $CA04A2B9:
        begin
          if (A <> 25) and (A <> 30) then
          begin
            Value := $80020068;
            Exit;
          end;
          if FSubInterrupts[A, B].Entry <> 0 then
          begin
            Value := $80020067;
            Exit;
          end;
          if (C <> 0) and ((C and 3 <> 0) or not FMemory.IsValid(C, 4)) then
          begin
            Value := $800200D3;
            Exit;
          end;
          FSubInterrupts[A, B].Entry := C;
          FSubInterrupts[A, B].Argument := D;
        end;
      $D61E6961:
        begin
          if FSubInterrupts[A, B].Entry = 0 then
          begin
            Value := $80020068;
            Exit;
          end;
          FSubInterrupts[A, B] := Default(TPSPSubInterrupt);
        end;
      $FB8E22EC:
        FSubInterrupts[A, B].Enabled := True;
      $8A389411:
        FSubInterrupts[A, B].Enabled := False;
    else
      Result := False;
    end;
  end
  else if ModuleName = 'ModuleMgrForUser' then
    case NID of
      $F0A26395:
        Value := $50;
      $D8B73127:
        if (A >= FExecutable.LowAddress) and (A < FExecutable.HighAddress) then
          Value := $50
        else
          Value := $8002012E;
    else
      Result := False;
    end
  else if ModuleName = 'Kernel_Library' then
    case NID of
      $293B45B8:
        Value := FCurrent.Id;
      $092968F4:
        begin
          Value := Ord(FCPU.InterruptEnabled);
          FCPU.InterruptEnabled := False;
        end;
      $5F10D406, $3B84732D:
        begin
          FCPU.InterruptEnabled := A and 1 <> 0;
          Yield;
        end;
      $47A0B729:
        Value := Ord(A = 0);
      $B55249D2:
        Value := Ord(FCPU.InterruptEnabled);
      $1839852A:
        begin
          FMemory.CopyMemory(A, B, C);
          Value := A;
        end;
      $A089ECA4:
        begin
          FMemory.Fill(A, C, Byte(B and $FF));
          Value := A;
        end;
    else
      Result := False;
    end
  else if (ModuleName = 'LoadExecForUser') and (NID = $4AC57943) then
  begin
    Value := $800201A1;
    for var Callback in FCallbacks do
      if Callback.Id = A then
      begin
        FExitCallback := A;
        Value := 0;
        Break;
      end;
  end
  else if ModuleName = 'ThreadManForUser' then
    case NID of
      $6652B8CA, $B2C25152:
        begin
          if (B and 3 <> 0) or not FMemory.IsValid(B, 4) then
          begin
            Value := $800200D3;
            Exit;
          end;
          var Delay := UInt64(A);
          if NID = $B2C25152 then
          begin
            if (A and 3 <> 0) or not FMemory.IsValid(A, 8) then
            begin
              Value := $800200D3;
              Exit;
            end;
            Delay := UInt64(FMemory.Read32(A)) or (UInt64(FMemory.Read32(A + 4)) shl 32);
          end;
          if Delay > UInt64(1) shl 52 then
          begin
            Value := $800200D2;
            Exit;
          end;
          var Alarm := TPSPAlarm.Create;
          Alarm.Id := NewId;
          Alarm.Handler := B;
          Alarm.Argument := C;
          Alarm.Schedule := FTime + Delay;
          Alarm.FireTime := FTime + Max(UInt64(215), Delay);
          FAlarms.Add(Alarm.Id, Alarm);
          Value := Alarm.Id;
        end;
      $7E65B999:
        if not FAlarms.ContainsKey(A) then
          Value := $8002019F
        else
        begin
          for var I := FGuestCalls.Count - 1 downto 0 do
            if FGuestCalls[I].AlarmId = A then
              FGuestCalls.Delete(I);
          FAlarms.Remove(A);
        end;
      $DAA3F564:
        begin
          var Alarm: TPSPAlarm;
          if not FAlarms.TryGetValue(A, Alarm) then
            Value := $8002019F
          else if (B and 3 <> 0) or not FMemory.IsValid(B, 20) then
            Value := $800200D3
          else
          begin
            var Size := FMemory.Read32(B);
            if Size > 0 then
              FMemory.Write32(B, 20);
            if Size > 4 then
            begin
              FMemory.Write32(B + 4, Cardinal(Alarm.Schedule and $FFFFFFFF));
              FMemory.Write32(B + 8, Cardinal(Alarm.Schedule shr 32));
            end;
            if Size > 12 then
              FMemory.Write32(B + 12, Alarm.Handler);
            if Size > 16 then
              FMemory.Write32(B + 16, Alarm.Argument);
          end;
        end;
      $110DEC9A:
        begin
          FMemory.Write32(B, A);
          FMemory.Write32(B + 4, 0);
        end;
      $C8CD158C:
        begin
          Value := A;
          FCPU.Registers[3] := 0;
        end;
      $8218B4DD:
        Value := 0; // The PSP's profiling service is disabled in retail firmware.
        $ED1410E0:
        begin
          Value := $800201A0;
          for var I := 0 to FPools.Count - 1 do
            if FPools[I].Id = A then
            begin
              Value := FreeBlock(FPools[I].Block);
              FPools.Delete(I);
              Break;
            end;
        end;
      $912354A7:
        begin
          var Priority := A;
          if Priority = 0 then
            Priority := FCurrent.Priority;
          Value := $80020193;
          if (Priority >= 8) and (Priority <= 119) then
          begin
            Value := 0;
            for var I := 0 to FThreads.Count - 1 do
              if (FThreads[I].State.Status = TPSPThreadStatus.Ready) and (FThreads[I].Priority = Priority) then
              begin
                var Thread := FThreads.Extract(FThreads[I]);
                FThreads.Add(Thread);
                Break;
              end;
            Yield;
          end;
        end;
      $E1619D7C:
        begin
          var Ticks := UInt64(A) or (UInt64(B) shl 32);
          if C <> 0 then
            FMemory.Write32(C, Ticks div 1000000);
          if D <> 0 then
            FMemory.Write32(D, Ticks mod 1000000);
        end;
      $BA6B92E2:
        begin
          var Ticks := UInt64(FMemory.Read32(A)) or (UInt64(FMemory.Read32(A + 4)) shl 32);
          if B <> 0 then
            FMemory.Write32(B, Ticks div 1000000);
          if C <> 0 then
            FMemory.Write32(C, Ticks mod 1000000);
        end;
      $349D6D6C:
        begin
          Value := Ord(DispatchCallbacks(FCurrent));
          if Value <> 0 then
            FCPU.Yield;
        end;
      $EDBA5844, $C11BA8C4, $BA4051D6, $2A3D44FF:
        begin
          Value := $800201A1;
          for var I := 0 to FCallbacks.Count - 1 do
            if FCallbacks[I].Id = A then
            begin
              var Callback := FCallbacks[I];
              Value := 0;
              if NID = $EDBA5844 then
                FCallbacks.Delete(I)
              else if NID = $2A3D44FF then
                Value := Callback.NotifyCount
              else
              begin
                if NID = $C11BA8C4 then
                begin
                  Inc(Callback.NotifyCount);
                  Callback.NotifyArgument := B;
                end
                else
                begin
                  Callback.NotifyCount := 0;
                  Callback.NotifyArgument := 0;
                end;
                FCallbacks[I] := Callback;
              end;
              Break;
            end;
        end;
      $446D8DE6:
        Value := CreateThread(FMemory.ReadString(A), B, C, D, FCPU.Registers[8], FKernelPrivilege > 0);
      $EA748E31:
        FCurrent.Attributes := (FCurrent.Attributes and not A) or B;
      $E81CAF8F:
        begin
          var Callback := Default(TPSPCallback);
          Callback.Id := NewId;
          Callback.Name := FMemory.ReadString(A);
          Callback.Entry := B;
          Callback.Argument := C;
          Callback.ThreadId := FCurrent.Id;
          if not FMemory.IsValid(B, 4) then
            Value := $800200D3
          else
          begin
            FCallbacks.Add(Callback);
            Value := Callback.Id;
          end;
        end;
      $C07BB470:
        begin
          var Count := FCPU.Registers[8];
          var Stride := (UInt64(D) + 7) and not UInt64(7);
          if (B <> 2) or (Count = 0) or (Stride = 0) or (Stride * Count > PSPRAMSize) then
            Value := $80020190
          else
          begin
            var Block := Allocate(Stride * Count, 0, 0);
            if Block and $80000000 <> 0 then
              Value := Block
            else
            begin
              var Pool := TPSPFixedPool.Create;
              Pool.Id := NewId;
              Pool.Block := Block;
              Pool.Address := BlockAddress(Block);
              Pool.BlockSize := Stride;
              SetLength(Pool.Used, Count);
              FPools.Add(Pool);
              Value := Pool.Id;
            end;
          end;
        end;
      $D979E9BF, $E7282CB6, $623AE665:
        begin
          Value := $800201A0;
          for var Pool in FPools do
            if Pool.Id = A then
            begin
              Value := $800201AF;
              for var I := 0 to High(Pool.Used) do
                if not Pool.Used[I] then
                begin
                  FMemory.Write32(B, Pool.Address + Cardinal(I) * Pool.BlockSize);
                  Pool.Used[I] := True;
                  Value := 0;
                  Break;
                end;
              if (Value <> 0) and (NID <> $623AE665) then
                raise EPSPInstruction.Create('PSP: blocking allocation from exhausted FPL is not implemented');
            end;
        end;
      $F6414A71:
        begin
          Value := $800201A0;
          for var Pool in FPools do
            if Pool.Id = A then
            begin
              Value := $800201B6;
              if (B >= Pool.Address) and ((B - Pool.Address) mod Pool.BlockSize = 0) then
              begin
                var Index := (B - Pool.Address) div Pool.BlockSize;
                if (Index < Cardinal(Length(Pool.Used))) and Pool.Used[Index] then
                begin
                  Pool.Used[Index] := False;
                  Value := 0;
                end;
              end;
            end;
        end;
      $F475845D:
        Value := StartThread(A, B, C);
      $AA73C935, $809CE29B:
        ExitCurrent(A, NID = $809CE29B);
      $293B45B8:
        Value := FCurrent.Id;
      $94AA61EE:
        Value := FCurrent.Priority;
      $17C1684E:
        begin
          var Thread := FindThread(A);
          if (Thread = nil) or (Thread.State.Status = TPSPThreadStatus.Dead) then
          begin
            Value := $80020198;
            Exit;
          end;
          if not FMemory.IsValid(B, 104) then
          begin
            Value := $800200D3;
            Exit;
          end;
          if FMemory.Read32(B) = 0 then
            Exit;
          FMemory.Zero(B, 104);
          FMemory.Write32(B, 104);
          FMemory.Load(B + 4, Copy(TEncoding.UTF8.GetBytes(Thread.Name), 0, 31));
          FMemory.Write32(B + 36, Thread.Attributes);
          var Status: Cardinal := 4;
          var WaitType: Cardinal := 0;
          case Thread.State.Status of
            TPSPThreadStatus.Dormant:
              Status := 16;
            TPSPThreadStatus.Ready:
              begin
                Status := 2;
                if Thread = FCurrent then
                  Status := 1;
              end;
            TPSPThreadStatus.Sleeping:
              WaitType := 1;
            TPSPThreadStatus.delayed:
              WaitType := 2;
            TPSPThreadStatus.WaitingThread:
              WaitType := 9;
            TPSPThreadStatus.WaitingObject:
              begin
                var Obj: TPSPSyncObject;
                if FObjects.TryGetValue(Thread.State.WaitId, Obj) then
                  case Obj.Kind of
                    0:
                      WaitType := 3;
                    1:
                      WaitType := 4;
                    2:
                      WaitType := 13;
                    3:
                      WaitType := 22;
                    4:
                      WaitType := 6;
                    5:
                      WaitType := 8;
                  end;
              end;
            TPSPThreadStatus.WaitingDevice:
              case Thread.State.WaitValue of
                1:
                  WaitType := 18;
                2:
                  WaitType := 17;
                3:
                  WaitType := 19;
                5:
                  WaitType := 23;
              end;
          end;
          FMemory.Write32(B + 40, Status);
          FMemory.Write32(B + 44, Thread.Entry);
          FMemory.Write32(B + 48, Thread.Stack);
          FMemory.Write32(B + 52, Thread.StackSize);
          var GP := Thread.Context.R[28];
          if Thread = FCurrent then
            GP := FCPU.Registers[28];
          FMemory.Write32(B + 56, GP);
          FMemory.Write32(B + 60, Thread.InitialPriority);
          FMemory.Write32(B + 64, Thread.Priority);
          FMemory.Write32(B + 68, WaitType);
          if WaitType <> 0 then
            FMemory.Write32(B + 72, Thread.State.WaitId);
          FMemory.Write32(B + 76, Cardinal(Thread.WakeCount));
          FMemory.Write32(B + 80, Thread.ExitStatus);
          FMemory.Write32(B + 84, Cardinal(Thread.RunClocks and $FFFFFFFF));
          FMemory.Write32(B + 88, Cardinal(Thread.RunClocks shr 32));
        end;
      $CEADEB47, $68DA9E36:
        begin
          WaitUntil(FTime + Max(Cardinal(200), A));
          if NID = $68DA9E36 then
            AcceptCallbacks;
        end;
      $9ACE131E, $82826F70:
        if FCurrent.WakeCount > 0 then
          Dec(FCurrent.WakeCount)
        else
        begin
          FCurrent.State.Status := TPSPThreadStatus.Sleeping;
          FCurrent.State.AcceptCallbacks := NID = $82826F70;
          FCPU.Yield;
        end;
      $D59EAD2F:
        begin
          var Thread := FindThread(A);
          if Thread = nil then
            Value := $80020198
          else
          begin
            var Woke := False;
            for var Depth := 0 to Length(Thread.CallbackWaits) do
            begin
              var State := Thread.WaitState(Depth);
              if State.Status = TPSPThreadStatus.Sleeping then
              begin
                State.Status := TPSPThreadStatus.Ready;
                SetThreadResult(Thread, 0, State);
                Woke := True;
                Break;
              end;
            end;
            if not Woke then
              Inc(Thread.WakeCount);
          end;
          Yield;
        end;
      $278C0DF5, $840E8133:
        begin
          var Thread := FindThread(A);
          if Thread = nil then
            Value := $80020198
          else if Thread = FCurrent then
            Value := $800201B3
          else if not (Thread.State.Status in [TPSPThreadStatus.Dormant, TPSPThreadStatus.Dead]) then
          begin
            if (B <> 0) and not FMemory.IsValid(B, 4) then
            begin
              Value := $800200D3;
              Exit
            end;
            if not FDispatchEnabled or not FCPU.InterruptEnabled then
            begin
              Value := $800201A7;
              Exit
            end;
            if (B <> 0) and (FMemory.Read32(B) = 0) then
            begin
              Value := $800201A8;
              Exit
            end;
            FCurrent.State.TimeoutPointer := B;
            FCurrent.State.WakeTime := 0;
            if B <> 0 then
              FCurrent.State.WakeTime := FTime + FMemory.Read32(B);
            FCurrent.State.WaitId := A;
            FCurrent.State.Status := TPSPThreadStatus.WaitingThread;
            FCurrent.State.AcceptCallbacks := NID = $840E8133;
            FCPU.Yield;
          end;
        end;
      $9FA03CD3, $383F7BCC, $616403BA:
        begin
          var Thread := FindThread(A);
          if (Thread = nil) or (Thread.State.Status = TPSPThreadStatus.Dead) then
            Value := $80020198
          else if Thread = FCurrent then
            Value := $80020197
          else if (NID = $9FA03CD3) and (Thread.State.Status <> TPSPThreadStatus.Dormant) then
            Value := $800201A4
          else if NID = $383F7BCC then
            Value := TerminateDeleteThread(A, $800201AC)
          else
          begin
            if NID <> $9FA03CD3 then
              Thread.ExitStatus := $800201AC;
            Thread.State.Status := TPSPThreadStatus.Dead;
            if NID = $616403BA then
            begin
              Thread.State.Status := TPSPThreadStatus.Dormant;
              Thread.Priority := Thread.InitialPriority
            end;
            for var State in Thread.CallbackWaits do
              State.Free;
            Thread.CallbackWaits := nil;
            Thread.CallbackContexts := nil;
            Thread.CallbackIds := nil;
            Thread.CallbackCompletions := nil;
            Thread.CallbackInterrupts := nil;
            Thread.CallbackAlarms := nil;
            for var I := FGuestCalls.Count - 1 downto 0 do
              if not FGuestCalls[I].Interrupt and (FGuestCalls[I].ThreadId = A) then
                FGuestCalls.Delete(I);
            WakeWaiters(A);
            if (NID <> $9FA03CD3) and Assigned(FOnThreadExit) then
              FOnThreadExit(A, Thread.ExitStatus);
            if NID = $616403BA then
            begin
              Yield;
              Exit
            end;
            if Thread.StackBlock <> 0 then
              FreeBlock(Thread.StackBlock);
            Thread.StackBlock := 0;
          end;
        end;
      $71BC9871:
        begin
          var Thread := FindThread(A);
          if Thread = nil then
            Value := $80020198
          else if (B < 8) or (B > 119) then
            Value := $80020193
          else
          begin
            Thread.Priority := B;
            Yield;
          end;
        end;
      $3AD58B8C:
        begin
          Value := Ord(FDispatchEnabled);
          FDispatchEnabled := False;
        end;
      $27E22EC2:
        begin
          FDispatchEnabled := A <> 0;
          Yield;
        end;
      $369ED59D:
        Value := Cardinal(FTime and $FFFFFFFF);
      $82BC5777:
        begin
          Value := Cardinal(FTime and $FFFFFFFF);
          FCPU.Registers[3] := Cardinal(FTime shr 32);
        end;
      $DB738F35:
        begin
          FMemory.Write32(A, Cardinal(FTime and $FFFFFFFF));
          FMemory.Write32(A + 4, Cardinal(FTime shr 32));
        end;
    else
      Result := False;
    end
  else
    Result := False;
end;

end.

