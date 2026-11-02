unit PSP.GE;

// sceGe_user: the display list queue of the GE driver and the GE command
// processor's control flow.
//
// Two layers, as on hardware. The "hardware" fetches commands at its PC until
// it meets the stall address or an END; an END after SIGNAL or FINISH stops it
// and raises the GE interrupt. The "driver" keeps up to 64 lists in a queue,
// feeds the head to the hardware, and in its interrupt handler acts on the
// signal or finish, calls the guest callbacks and moves the queue along.
//
// The hardware runs on its own clock (FGETime, guest ns) and may run a little
// ahead of the CPU (GERunAhead). Its interrupt is taken when the CPU's clock
// reaches it, or at the end of the kernel call (or interrupt handler) it came
// in, so short lists are over before the call that started them returns; a
// sync still waits until the CPU's clock has reached the GE's.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, PSP.Types,
  PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service,
  PSP.GE.Types, PSP.GE.Engine, PSP.State.Action;

const
  GEListCount = 64;
  GECallbackCount = 16;
  GESignalStackDepth = 32;

type
  TGEListState = (glsFree, glsQueued, glsRunning, glsCompleted, glsPaused);

  TGEIntKind = (gikNone, gikSignal, gikFinish, gikEnd);

  // Where the driver runs: a kernel call, its interrupt handler, the clock.
  TGEContext = (gcSyscall, gcISR, gcEvent);

  TGECallStackEntry = record
    PC, Offset: Cardinal;
  end;

  TGESignalFrame = record
    PC, Base, Offset: Cardinal;
    Depth: Integer;
    Stack: array[0..1] of TGECallStackEntry;
  end;

  TGEList = record
    State: TGEListState;
    Linked, Started: Boolean;
    Gen: Cardinal;
    PC, Stall: Cardinal;
    CBID: Integer;
    Context, Stacks: Cardinal;
    NumStacks: Integer;
    PausePending, SyncPending, SuspendPaused: Boolean;
    PauseValue: Cardinal;
    Depth: Integer;
    Stack: array[0..1] of TGECallStackEntry;
    SigDepth: Integer;
    SigStack: array[0..GESignalStackDepth - 1] of TGESignalFrame;
    // GE time of the END that completed it.
    DoneAt: Int64;
  end;

  PGEList = ^TGEList;

  TGECallback = record
    Used: Boolean;
    SignalFunc, SignalArg, FinishFunc, FinishArg, GP: Cardinal;
  end;

  TPSPGE = class(TPSPService)
  private
    FEngine: TPSPGEEngine;
    FLists: array[0..GEListCount - 1] of TGEList;
    FQueue: TList<Integer>;
    FFree: TList<Integer>;
    FCallbacks: array[0..GECallbackCount - 1] of TGECallback;
    FWaiters: TList<TPSPThread>;
    // Hardware
    FHWList: Integer;
    FHWPC, FHWStall: Cardinal;
    FHWRunning, FHWHalted: Boolean;
    FHWInt: TGEIntKind;
    FHWIntQueued: Boolean;
    FHWIntAt: Int64;
    FLastKind: TGEIntKind;
    FSignalCmd, FSignalPC, FFinishCmd, FEndCmd: Cardinal;
    FHWDepth: Integer;
    FHWStack: array[0..1] of TGECallStackEntry;
    FGETime: Int64;
    // GE time of the last list completion.
    FDoneAt: Int64;
    FEdramTranslation: Cardinal;
    FInHW: Boolean;
    FContext: TGEContext;
    function Now: Int64; inline;
    function IntWindow: Int64;
    function NewSdk: Boolean;
    function ListID(Slot: Integer): Cardinal; inline;
    function SlotOf(ID: Cardinal): Integer;
    function ActiveHead: Integer;
    function HasActive: Boolean;
    function SameAddr(A, B: Cardinal): Boolean; inline;
    function StateCode(Slot: Integer): Cardinal;
    procedure ResetAll;
    procedure FreeSlot(Slot: Integer);
    procedure StartOnHW(Slot: Integer);
    procedure DetachHW(Slot: Integer);
    procedure Kick;
    procedure RunHW(Limit: Int64);
    procedure StopAtEnd;
    procedure RaiseInterrupt;
    procedure Interrupt;
    procedure HandleSignal(Slot: Integer);
    procedure HandleFinish(Slot: Integer);
    procedure ResumeHW;
    procedure CompleteList(Slot: Integer; Gen: Cardinal);
    procedure CallSignal(Slot: Integer; Value: Cardinal; const Done: IPSPStateAction);
    procedure CallFinish(Slot: Integer; Value: Cardinal; const Done: IPSPStateAction);
    procedure StateInterrupt(Action: TPSPStateAction; Value: Cardinal);
    procedure StateSignalReturned(Action: TPSPStateAction; Value: Cardinal);
    procedure StateFinishReturned(Action: TPSPStateAction; Value: Cardinal);
    procedure WakeWaiters(Slot: Integer);
    procedure EndWaitAt(T: TPSPThread; At: Int64);
    procedure WaitUntil(At: Int64);
    function ClockRetry(T: TPSPThread): Boolean;
    function SyncRetry(T: TPSPThread): Boolean;
    procedure SyncAbort(T: TPSPThread);
    procedure FreeCompleted;
    function CheckWaitContext: Cardinal;
    procedure EnQueue(Head: Boolean);
    procedure hEdramGetAddr;
    procedure hEdramGetSize;
    procedure hEdramSetSize;
    procedure hEdramSetAddrTranslation;
    procedure hListEnQueue;
    procedure hListEnQueueHead;
    procedure hListDeQueue;
    procedure hListUpdateStallAddr;
    procedure hListSync;
    procedure hDrawSync;
    procedure hBreak;
    procedure hContinue;
    procedure hSetCallback;
    procedure hUnsetCallback;
    procedure hGetCmd;
    procedure hGetMtx;
    procedure hGetStack;
    procedure hSaveContext;
    procedure hRestoreContext;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    procedure OnEvent(Event: TPSPEvent); override;
    property Engine: TPSPGEEngine read FEngine;
  end;

implementation

uses
  PSP.GE.Workers, PSP.GE.Backend;

const
  SCE_ERROR_ALREADY = Cardinal($80000020);
  SCE_ERROR_BUSY = Cardinal($80000021);
  SCE_ERROR_OUT_OF_MEMORY = Cardinal($80000022);
  SCE_ERROR_PRIV_REQUIRED = Cardinal($80000023);
  // How far the GE may run ahead of the CPU before it waits for the clock.
  GERunAhead = 2000;
  // CPU cycles of the driver's interrupt handler.
  GEISRCycles = 500;

constructor TPSPGE.Create(System: TPSPSystem);
begin
  inherited;
  FEngine := TPSPGEEngine.Create(FMemory);
  FQueue := TList<Integer>.Create;
  FFree := TList<Integer>.Create;
  FWaiters := TList<TPSPThread>.Create;
end;

destructor TPSPGE.Destroy;
begin
  FWaiters.Free;
  FFree.Free;
  FQueue.Free;
  FEngine.Free;
  inherited;
end;

function TPSPGE.Now: Int64;
begin
  Result := FSystem.Scheduler.Now;
end;

function TPSPGE.NewSdk: Boolean;
begin
  Result := FKernel.CompiledSdkVersion >= $02000000;
end;

function TPSPGE.ListID(Slot: Integer): Cardinal;
begin
  Result := Cardinal(Slot) + $1000;
end;

function TPSPGE.SlotOf(ID: Cardinal): Integer;
begin
  Result := Integer(ID) - $1000;
  if (Result < 0) or (Result >= GEListCount) or (FLists[Result].State = glsFree) then
    Result := -1;
end;

function TPSPGE.SameAddr(A, B: Cardinal): Boolean;
begin
  Result := (A and $1FFFFFFF) = (B and $1FFFFFFF);
end;

procedure TPSPGE.ResetAll;
begin
  for var I := 0 to GEListCount - 1 do
  begin
    var G := FLists[I].Gen;
    FLists[I] := Default(TGEList);
    FLists[I].Gen := G + 1;
  end;
  FQueue.Clear;
  FFree.Clear;
  for var I := 0 to GEListCount - 1 do
    FFree.Add(I);
  FHWList := -1;
  FHWRunning := False;
  FHWHalted := False;
  FHWInt := gikNone;
  FLastKind := gikNone;
  FHWDepth := 0;
  FSystem.Scheduler.Cancel(TPSPEvent.GE);
end;

procedure TPSPGE.Reset;
begin
  FEngine.Reset;
  ResetAll;
  for var I := 0 to GECallbackCount - 1 do
    FCallbacks[I] := Default(TGECallback);
  FWaiters.Clear;
  FHWPC := 0;
  FHWStall := 0;
  FHWIntQueued := False;
  FGETime := 0;
  FDoneAt := 0;
  FEdramTranslation := $400;
  FInHW := False;
end;

function TPSPGE.ActiveHead: Integer;
begin
  for var S in FQueue do
    if FLists[S].State <> glsCompleted then
      Exit(S);
  Result := -1;
end;

function TPSPGE.HasActive: Boolean;
begin
  Result := ActiveHead >= 0;
end;

function TPSPGE.StateCode(Slot: Integer): Cardinal;
begin
  var L: PGEList := @FLists[Slot];
  case L.State of
    glsCompleted:
      Result := 0;
    glsQueued:
      Result := 1;
    glsPaused:
      Result := 4;
    glsRunning:
      begin
        var PC := L.PC;
        if FHWList = Slot then
          PC := FHWPC;
        if SameAddr(PC, L.Stall) then
          Result := 3
        else
          Result := 2;
      end;
  else
    Result := 0;
  end;
end;

procedure TPSPGE.FreeSlot(Slot: Integer);
begin
  FQueue.Remove(Slot);
  FLists[Slot].Linked := False;
  FLists[Slot].State := glsFree;
  Inc(FLists[Slot].Gen);
  if not FFree.Contains(Slot) then
    FFree.Add(Slot);
end;

procedure TPSPGE.FreeCompleted;
begin
  for var I := 0 to GEListCount - 1 do
    if (FLists[I].State = glsCompleted) and not FLists[I].Linked then
    begin
      FLists[I].State := glsFree;
      Inc(FLists[I].Gen);
    end;
end;

{ Hardware }

procedure TPSPGE.StartOnHW(Slot: Integer);
begin
  var L: PGEList := @FLists[Slot];
  FHWList := Slot;
  if not L.Started then
  begin
    L.Started := True;
    if L.Context <> 0 then
      FEngine.SaveContext(L.Context);
    FEngine.Regs.Offset := 0;
    L.Depth := 0;
    L.SigDepth := 0;
  end;
  FHWPC := L.PC;
  FHWStall := L.Stall;
  FHWDepth := L.Depth;
  FHWStack[0] := L.Stack[0];
  FHWStack[1] := L.Stack[1];
  FHWRunning := True;
  FHWHalted := False;
  FHWInt := gikNone;
  FLastKind := gikNone;
  L.State := glsRunning;
  Kick;
end;

procedure TPSPGE.DetachHW(Slot: Integer);
begin
  var L: PGEList := @FLists[Slot];
  L.PC := FHWPC;
  L.Depth := FHWDepth;
  L.Stack[0] := FHWStack[0];
  L.Stack[1] := FHWStack[1];
  FHWList := -1;
  FHWRunning := False;
  FHWHalted := False;
  FHWInt := gikNone;
end;

procedure TPSPGE.Kick;
begin
  RunHW(Now + GERunAhead);
end;

procedure TPSPGE.StopAtEnd;
begin
  FHWHalted := True;
  FHWInt := FLastKind;
  if FHWInt = gikNone then
    FHWInt := gikEnd;
  FLastKind := gikNone;
  FHWIntAt := FGETime;
end;

procedure TPSPGE.RaiseInterrupt;
begin
  if FHWIntQueued then
    Exit;
  FHWIntQueued := True;
  FKernel.QueueInterrupt(FKernel.TrapReturnAddress, [], 0, nil, 0, 0, TPSPStateAction.Create(StateInterrupt, [], []));
end;

procedure TPSPGE.StateInterrupt(Action: TPSPStateAction; Value: Cardinal);
begin
  FHWIntQueued := False;
  Interrupt;
end;

procedure TPSPGE.RunHW(Limit: Int64);
begin
  if FInHW then
    Exit;

  FInHW := True;
  try
    if FGETime < Now then
      FGETime := Now;
    var RAM := FEngine.RAMBase;
    while FHWRunning and not FHWHalted do
    begin
      if SameAddr(FHWPC, FHWStall) then
        Break;
      if FGETime > Limit then
      begin
        FSystem.Scheduler.Schedule(TPSPEvent.GE, FGETime);
        Exit;
      end;
      var PC := FHWPC;
      var Op: Cardinal;
      var Physical := PC and $1FFFFFFF;
      if (RAM <> nil) and (Physical >= PSPRAMBase) and (Physical - PSPRAMBase <= PSPRAMSize - 4) then
        Op := PCardinal(RAM + (Physical - PSPRAMBase))^
      else
        Op := FMemory.Read32(PC);
      FHWPC := PC + 4;
      var Cmd := Op shr 24;
      Inc(FGETime, 4);
      case Cmd of
        GE_JUMP:
          FHWPC := FEngine.Address(Op) and not Cardinal(3);
        GE_BJUMP:
          if not FEngine.BoxVisible then
            FHWPC := FEngine.Address(Op) and not Cardinal(3);
        GE_CALL:
          if FHWDepth < 2 then
          begin
            FHWStack[FHWDepth].PC := FHWPC;
            FHWStack[FHWDepth].Offset := FEngine.Regs.Offset;
            Inc(FHWDepth);
            FHWPC := FEngine.Address(Op) and not Cardinal(3);
          end;
        GE_RET:
          if FHWDepth > 0 then
          begin
            Dec(FHWDepth);
            FHWPC := FHWStack[FHWDepth].PC;
            FEngine.Regs.Offset := FHWStack[FHWDepth].Offset;
          end;
        GE_END:
          begin
            FEndCmd := Op;
            FEngine.Regs.Cmd[GE_END] := Op;
            StopAtEnd;
          end;
        GE_SIGNAL:
          begin
            FSignalCmd := Op;
            FSignalPC := PC;
            FLastKind := gikSignal;
          end;
        GE_FINISH:
          begin
            FFinishCmd := Op;
            FLastKind := gikFinish;
          end;
      else
        Inc(FGETime, FEngine.Execute(Op, PC));
      end;
      if Cmd in [GE_JUMP, GE_BJUMP, GE_CALL, GE_RET, GE_SIGNAL, GE_FINISH] then
        FEngine.Regs.Cmd[Cmd] := Op;
    end;
    if FHWHalted and (FHWInt <> gikNone) and not FHWIntQueued then
    begin
      if FHWIntAt <= Now + IntWindow then
        RaiseInterrupt
      else
        FSystem.Scheduler.Schedule(TPSPEvent.GE, FHWIntAt);
    end;
  finally
    FEngine.ReleaseBackend;
    FInHW := False;
  end;
end;

procedure TPSPGE.OnEvent(Event: TPSPEvent);
begin
  if Event <> TPSPEvent.GE then
    Exit;
  var Saved := FContext;
  FContext := gcEvent;
  try
    Kick;
  finally
    FContext := Saved;
  end;
end;

// How much later than now an interrupt may be raised already: one that comes
// during a kernel call or the driver's interrupt handler is taken when that
// returns, as one from the clock is taken then.
function TPSPGE.IntWindow: Int64;
begin
  var MHz := Int64(FSystem.Scheduler.MHz);
  if MHz <= 0 then
    MHz := 222;
  case FContext of
    gcEvent:
      Result := 0;
    gcISR:
      Result := GEISRCycles * 1000 div MHz;
  else
    Result := Int64(FHLE.CycleCost) * 1000 div MHz;
  end;
end;

procedure TPSPGE.ResumeHW;
begin
  FHWHalted := False;
  FHWInt := gikNone;
  Kick;
end;

{ Driver interrupt }

procedure TPSPGE.Interrupt;
begin
  if FKernel.Trace then
    FHLE.Log('ge interrupt %d list %d pc %.8x now %d intat %d', [Ord(FHWInt), FHWList, FHWPC, Now, FHWIntAt]);
  var Kind := FHWInt;
  if (Kind = gikNone) or not FHWHalted or (FHWList < 0) then
    Exit;
  FHWInt := gikNone;
  FSystem.CPU.AddCycles(GEISRCycles);
  var Saved := FContext;
  FContext := gcISR;
  try
    case Kind of
      gikSignal:
        HandleSignal(FHWList);
      gikFinish:
        HandleFinish(FHWList);
    end;
  finally
    FContext := Saved;
  end;
end;

procedure TPSPGE.CallSignal(Slot: Integer; Value: Cardinal; const Done: IPSPStateAction);
begin
  var CB := FLists[Slot].CBID;
  if (CB < 0) or (CB >= GECallbackCount) or not FCallbacks[CB].Used or (FCallbacks[CB].SignalFunc = 0) then
  begin
    if Done <> nil then
      Done.Run;
    Exit;
  end;
  var PC: Cardinal := 0;
  if NewSdk then
    PC := FHWPC;
  var C := FCallbacks[CB];
  FKernel.QueueInterrupt(C.SignalFunc, [Value, C.SignalArg, PC], C.GP, nil, 0, 0, Done);
end;

procedure TPSPGE.CallFinish(Slot: Integer; Value: Cardinal; const Done: IPSPStateAction);
begin
  var CB := FLists[Slot].CBID;
  if (CB < 0) or (CB >= GECallbackCount) or not FCallbacks[CB].Used or (FCallbacks[CB].FinishFunc = 0) then
  begin
    if Done <> nil then
      Done.Run;
    Exit;
  end;
  var PC: Cardinal := 0;
  if NewSdk then
    PC := FHWPC;
  var C := FCallbacks[CB];
  FKernel.QueueInterrupt(C.FinishFunc, [Value, C.FinishArg, PC], C.GP, nil, 0, 0, Done);
end;

procedure TPSPGE.HandleSignal(Slot: Integer);
begin
  var L: PGEList := @FLists[Slot];
  var Behaviour := (FSignalCmd shr 16) and $FF;
  var Value := FSignalCmd and $FFFF;
  var Target := ((FSignalCmd and $FFFF) shl 16) or (FEndCmd and $FFFF);
  var Gen := L.Gen;
  case Behaviour of
    GE_SIG_SUSPEND:
      begin
        if not NewSdk then
        begin
          L.State := glsPaused;
          L.SuspendPaused := True;
        end;
        CallSignal(Slot, Value, TPSPStateAction.Create(StateSignalReturned, [], [Slot, Gen]));
      end;
    GE_SIG_CONTINUE:
      begin
        CallSignal(Slot, Value, nil);
        ResumeHW;
      end;
    GE_SIG_PAUSE:
      begin
        L.PausePending := True;
        L.PauseValue := Value;
        L.State := glsPaused;
        ResumeHW;
      end;
    GE_SIG_SYNC:
      begin
        L.SyncPending := True;
        ResumeHW;
      end;
    GE_SIG_JUMP, GE_SIG_RJUMP, GE_SIG_OJUMP, GE_SIG_CALL, GE_SIG_RCALL, GE_SIG_OCALL:
      begin
        var Addr := Target;
        case Behaviour of
          GE_SIG_RJUMP, GE_SIG_RCALL:
            Addr := FSignalPC + Target;
          GE_SIG_OJUMP, GE_SIG_OCALL:
            Addr := FEngine.Regs.Offset + Target;
        end;
        Addr := Addr and not Cardinal(3);
        if Behaviour in [GE_SIG_CALL, GE_SIG_RCALL, GE_SIG_OCALL] then
        begin
          if L.SigDepth < GESignalStackDepth then
          begin
            var F: TGESignalFrame;
            F.PC := FHWPC;
            F.Base := FEngine.Regs.Cmd[GE_BASE];
            F.Offset := FEngine.Regs.Offset;
            F.Depth := FHWDepth;
            F.Stack[0] := FHWStack[0];
            F.Stack[1] := FHWStack[1];
            L.SigStack[L.SigDepth] := F;
            Inc(L.SigDepth);
            FHWDepth := 0;
            FHWPC := Addr;
          end;
        end
        else
          FHWPC := Addr;
        ResumeHW;
      end;
    GE_SIG_RET:
      begin
        if L.SigDepth > 0 then
        begin
          Dec(L.SigDepth);
          var F := L.SigStack[L.SigDepth];
          FHWPC := F.PC;
          FEngine.Regs.Cmd[GE_BASE] := F.Base;
          FEngine.Regs.Offset := F.Offset;
          FHWDepth := F.Depth;
          FHWStack[0] := F.Stack[0];
          FHWStack[1] := F.Stack[1];
        end;
        ResumeHW;
      end;
    GE_SIG_RTBP0..GE_SIG_RTBP0 + 15, GE_SIG_RCBP, GE_SIG_OCBP:
      begin
        var Addr: Cardinal;
        if (Behaviour and $08) <> 0 then
          Addr := FEngine.Regs.Offset + Target
        else
          Addr := FSignalPC + Target;
        if Behaviour < GE_SIG_RCBP then
        begin
          var N := Behaviour and 7;
          var R := FEngine.Regs.Cmd[GE_TEXBUFWIDTH0 + N];
          FEngine.Execute((Cardinal(GE_TEXADDR0 + N) shl 24) or (Addr and $FFFFFF), FSignalPC);
          FEngine.Execute((Cardinal(GE_TEXBUFWIDTH0 + N) shl 24) or ((Addr shr 8) and $0F0000) or (R and $FFFF),
            FSignalPC);
        end
        else
        begin
          FEngine.Execute((Cardinal(GE_CLUTADDR) shl 24) or (Addr and $FFFFFF), FSignalPC);
          FEngine.Execute((Cardinal(GE_CLUTADDRUPPER) shl 24) or ((Addr shr 8) and $0F0000), FSignalPC);
        end;
        ResumeHW;
      end;
    GE_SIG_BREAK1, GE_SIG_BREAK2:
      ResumeHW;
  end;
end;

procedure TPSPGE.HandleFinish(Slot: Integer);
begin
  var L: PGEList := @FLists[Slot];
  var Value := FFinishCmd and $FFFF;
  if L.PausePending then
  begin
    L.PausePending := False;
    L.State := glsPaused;
    DetachHW(Slot);
    CallSignal(Slot, L.PauseValue, nil);
    Exit;
  end;
  if L.SyncPending then
  begin
    L.SyncPending := False;
    ResumeHW;
    Exit;
  end;
  L.State := glsCompleted;
  L.DoneAt := FHWIntAt;
  if FHWIntAt > FDoneAt then
    FDoneAt := FHWIntAt;
  var Gen := L.Gen;
  CallFinish(Slot, Value, TPSPStateAction.Create(StateFinishReturned, [], [Slot, Gen]));
end;

procedure TPSPGE.StateSignalReturned(Action: TPSPStateAction; Value: Cardinal);
begin
  var Slot := Integer(Action.Arg(0));
  if (Slot < 0) or (Slot >= GEListCount) then
    raise EReadError.Create('Invalid GE state list');
  var L: PGEList := @FLists[Slot];
  if L.Gen <> Cardinal(Action.Arg(1)) then
    Exit;
  if L.SuspendPaused then
  begin
    L.SuspendPaused := False;
    if L.State = glsPaused then
      L.State := glsRunning;
  end;
  if (FHWList = Slot) and FHWHalted then
    ResumeHW;
end;

procedure TPSPGE.StateFinishReturned(Action: TPSPStateAction; Value: Cardinal);
begin
  var Slot := Integer(Action.Arg(0));
  if (Slot < 0) or (Slot >= GEListCount) then
    raise EReadError.Create('Invalid GE state list');
  CompleteList(Slot, Cardinal(Action.Arg(1)));
end;

procedure TPSPGE.CompleteList(Slot: Integer; Gen: Cardinal);
begin
  var L: PGEList := @FLists[Slot];
  if (L.Gen <> Gen) or (L.State <> glsCompleted) then
    Exit;
  if L.Context <> 0 then
    FEngine.RestoreContext(L.Context);
  FQueue.Remove(Slot);
  L.Linked := False;
  if not FFree.Contains(Slot) then
    FFree.Add(Slot);
  if FHWList = Slot then
  begin
    FHWList := -1;
    FHWRunning := False;
    FHWHalted := False;
  end;
  WakeWaiters(Slot);
  var Next := ActiveHead;
  if (Next >= 0) and (FHWList < 0) then
    StartOnHW(Next);
end;

{ Waits }

function TPSPGE.SyncRetry(T: TPSPThread): Boolean;
begin
  if T.Wait.Data[0] = 0 then
    Result := not HasActive
  else
    Result := FLists[T.Wait.Data[1]].State in [glsCompleted, glsFree];
  if Result then
  begin
    if T.Wait.Data[0] = 0 then
      FreeCompleted;
    T.SetResult(0);
  end
  else if not FWaiters.Contains(T) then
    FWaiters.Add(T);
end;

procedure TPSPGE.SyncAbort(T: TPSPThread);
begin
  FWaiters.Remove(T);
end;

procedure TPSPGE.WakeWaiters(Slot: Integer);
begin
  var Active := HasActive;
  for var Pass := 0 to 1 do
    for var I := FWaiters.Count - 1 downto 0 do
    begin
      if I >= FWaiters.Count then
        Continue;
      var T := FWaiters[I];
      if not T.IsWaiting or (T.Wait.HLETag <> 'ge') then
      begin
        FWaiters.Delete(I);
        Continue;
      end;
      if (Pass = 0) and (T.Wait.Data[0] = 0) and not Active then
      begin
        FWaiters.Delete(I);
        FreeCompleted;
        EndWaitAt(T, FDoneAt);
      end
      else if (Pass = 1) and (T.Wait.Data[0] = 1) and (Integer(T.Wait.Data[1]) = Slot) then
      begin
        FWaiters.Delete(I);
        EndWaitAt(T, FLists[Slot].DoneAt);
      end;
    end;
end;

// The driver may learn of a finish before the CPU's clock reaches the GE's
// time for it (GERunAhead); a sync returns no earlier than that time.
procedure TPSPGE.EndWaitAt(T: TPSPThread; At: Int64);
begin
  if At <= Now then
  begin
    FKernel.EndWait(T, 0);
    Exit;
  end;
  FKernel.AddWakeTimer(At, T, 'ge', 0, -1, Self);
end;

function TPSPGE.ClockRetry(T: TPSPThread): Boolean;
begin
  Result := False;
end;

procedure TPSPGE.WaitUntil(At: Int64);
begin
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, ClockRetry, nil, 'ge');
  T.Wait.Data[0] := 2;
  EndWaitAt(T, At);
end;

function TPSPGE.CheckWaitContext: Cardinal;
begin
  if FKernel.InInterrupt then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
  if not FKernel.CanWait or not FSystem.CPU.InterruptsEnabled then
    Exit(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
  Result := 0;
end;

{ HLE }

procedure TPSPGE.hEdramGetAddr;
begin
  FHLE.Result(PSPVRAMBase);
end;

procedure TPSPGE.hEdramGetSize;
begin
  FHLE.Result(PSPVRAMSize);
end;

procedure TPSPGE.hEdramSetSize;
begin
  if FHLE.Arg(0) = PSPVRAMSize then
    FHLE.Result(0)
  else
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
end;

procedure TPSPGE.hEdramSetAddrTranslation;
begin
  var W := FHLE.Arg(0);
  if not ((W = 0) or (W = $200) or (W = $400) or (W = $800) or (W = $1000)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  FHLE.Result(FEdramTranslation);
  FEdramTranslation := W;
  FMemory.SetVRAMTranslation(W);
end;

procedure TPSPGE.EnQueue(Head: Boolean);
begin
  var List := FHLE.Arg(0);
  var Stall := FHLE.Arg(1);
  var CBID := FHLE.ArgInt(2);
  var Args := FHLE.Arg(3);
  if (List and 3) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER);
    Exit;
  end;
  var Context: Cardinal := 0;
  var Stacks: Cardinal := 0;
  var NumStacks := 0;
  if Args <> 0 then
  begin
    var Size := FMemory.Read32(Args);
    Context := FMemory.Read32(Args + 4);
    if Size >= 16 then
    begin
      var N := FMemory.Read32(Args + 8);
      if N > 255 then
      begin
        FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
        Exit;
      end;
      NumStacks := N;
      Stacks := FMemory.Read32(Args + 12);
    end;
  end;
  if NewSdk then
  begin
    for var S in FQueue do
      if SameAddr(FLists[S].PC, List) then
      begin
        FHLE.Result(SCE_ERROR_BUSY);
        Exit;
      end;
    if Stacks <> 0 then
      for var S in FQueue do
        if FLists[S].Started and (FLists[S].State <> glsCompleted) and (FLists[S].Stacks = Stacks) then
        begin
          FHLE.Result(SCE_ERROR_BUSY);
          Exit;
        end;
  end;
  var Active := ActiveHead;
  if Head and (Active >= 0) and (FLists[Active].State <> glsPaused) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  if FFree.Count = 0 then
  begin
    FHLE.Result(SCE_ERROR_OUT_OF_MEMORY);
    Exit;
  end;
  var Slot := FFree[0];
  FFree.Delete(0);
  var G := FLists[Slot].Gen + 1;
  FLists[Slot] := Default(TGEList);
  var L: PGEList := @FLists[Slot];
  L.Gen := G;
  L.Linked := True;
  L.PC := List;
  L.Stall := Stall;
  L.CBID := CBID;
  L.Context := Context;
  L.Stacks := Stacks;
  L.NumStacks := NumStacks;
  FHLE.Result(ListID(Slot));
  if Head then
  begin
    L.State := glsPaused;
    if (Active >= 0) and not FLists[Active].Started then
      FLists[Active].State := glsQueued;
    FQueue.Insert(0, Slot);
  end
  else
  begin
    L.State := glsQueued;
    FQueue.Add(Slot);
    if (FHWList < 0) and (ActiveHead = Slot) then
      StartOnHW(Slot);
  end;
end;

procedure TPSPGE.hListEnQueue;
begin
  EnQueue(False);
end;

procedure TPSPGE.hListEnQueueHead;
begin
  EnQueue(True);
end;

procedure TPSPGE.hListDeQueue;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  if Slot < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_ID);
    Exit;
  end;
  var L: PGEList := @FLists[Slot];
  if (L.State = glsQueued) or ((L.State = glsPaused) and not L.Started) then
  begin
    FreeSlot(Slot);
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_ERROR_BUSY);
end;

procedure TPSPGE.hListUpdateStallAddr;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  if Slot < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_ID);
    Exit;
  end;
  var L: PGEList := @FLists[Slot];
  if L.State = glsCompleted then
  begin
    FHLE.Result(SCE_ERROR_ALREADY);
    Exit;
  end;
  L.Stall := FHLE.Arg(1);
  FHLE.Result(0);
  if (L.State = glsRunning) and (FHWList = Slot) then
  begin
    FHWStall := L.Stall;
    Kick;
  end;
end;

procedure TPSPGE.hListSync;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Mode := FHLE.Arg(1);
  if Slot < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_ID);
    Exit;
  end;
  if Mode > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if Mode = 1 then
  begin
    FHLE.Result(StateCode(Slot));
    Exit;
  end;
  var E := CheckWaitContext;
  if E <> 0 then
  begin
    FHLE.Result(E);
    Exit;
  end;
  FHLE.Result(0);
  if FLists[Slot].State = glsCompleted then
  begin
    if FLists[Slot].DoneAt > Now then
      WaitUntil(FLists[Slot].DoneAt);
    Exit;
  end;
  FWaiters.Add(FKernel.Current);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, SyncRetry, SyncAbort, 'ge');
  FKernel.Current.Wait.Data[0] := 1;
  FKernel.Current.Wait.Data[1] := Cardinal(Slot);
end;

procedure TPSPGE.hDrawSync;
begin
  var Mode := FHLE.Arg(0);
  if Mode > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  var Head := ActiveHead;
  if Mode = 1 then
  begin
    if Head < 0 then
      FHLE.Result(0)
    else if SameAddr(FHWPC, FLists[Head].Stall) then
      FHLE.Result(3)
    else
      FHLE.Result(2);
    Exit;
  end;
  var E := CheckWaitContext;
  if E <> 0 then
  begin
    FHLE.Result(E);
    Exit;
  end;
  FHLE.Result(0);
  if Head < 0 then
  begin
    FreeCompleted;
    if FDoneAt > Now then
      WaitUntil(FDoneAt);
    Exit;
  end;
  FWaiters.Add(FKernel.Current);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, SyncRetry, SyncAbort, 'ge');
  FKernel.Current.Wait.Data[0] := 0;
end;

procedure TPSPGE.hBreak;
begin
  var Mode := FHLE.Arg(0);
  var Param := FHLE.Arg(1);
  if Mode > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if ((Param or (Param + 16)) and $80000000) <> 0 then
  begin
    FHLE.Result(SCE_ERROR_PRIV_REQUIRED);
    Exit;
  end;
  var Head := ActiveHead;
  if Head < 0 then
  begin
    FHLE.Result(SCE_ERROR_ALREADY);
    Exit;
  end;
  if Mode = 1 then
  begin
    ResetAll;
    FHLE.Result(0);
    Exit;
  end;
  var L: PGEList := @FLists[Head];
  if L.State = glsPaused then
  begin
    FHLE.Result(SCE_ERROR_BUSY);
    Exit;
  end;
  if FHWList = Head then
  begin
    DetachHW(Head);
    FHWPC := 0;
  end;
  L.State := glsPaused;
  FHLE.Result(ListID(Head));
end;

procedure TPSPGE.hContinue;
begin
  var Head := ActiveHead;
  if Head < 0 then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var L: PGEList := @FLists[Head];
  case L.State of
    glsPaused:
      begin
        if L.PausePending then
        begin
          FHLE.Result(SCE_ERROR_BUSY);
          Exit;
        end;
        FHLE.Result(0);
        if FHWList = Head then
        begin
          L.State := glsRunning;
          FHWStall := L.Stall;
          ResumeHW;
        end
        else if FHWList < 0 then
          StartOnHW(Head);
      end;
    glsRunning:
      if NewSdk then
        FHLE.Result(SCE_ERROR_ALREADY)
      else
        FHLE.Result($FFFFFFFF);
  else
    begin
      FHLE.Result(0);
      if FHWList < 0 then
        StartOnHW(Head);
    end;
  end;
end;

procedure TPSPGE.hSetCallback;
begin
  var P := FHLE.Arg(0);
  if P = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER);
    Exit;
  end;
  for var I := 0 to GECallbackCount - 1 do
    if not FCallbacks[I].Used then
    begin
      FCallbacks[I].Used := True;
      FCallbacks[I].SignalFunc := FMemory.Read32(P);
      FCallbacks[I].SignalArg := FMemory.Read32(P + 4);
      FCallbacks[I].FinishFunc := FMemory.Read32(P + 8);
      FCallbacks[I].FinishArg := FMemory.Read32(P + 12);
      FCallbacks[I].GP := FSystem.CPU.Ctx.GPR[28];
      FHLE.Result(Cardinal(I));
      Exit;
    end;
  FHLE.Result(SCE_ERROR_OUT_OF_MEMORY);
end;

procedure TPSPGE.hUnsetCallback;
begin
  var I := FHLE.ArgInt(0);
  if (I < 0) or (I >= GECallbackCount) or not FCallbacks[I].Used then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_ID);
    Exit;
  end;
  FCallbacks[I] := Default(TGECallback);
  FHLE.Result(0);
end;

procedure TPSPGE.hGetCmd;
begin
  var C := FHLE.Arg(0);
  if C > 255 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX);
    Exit;
  end;
  FHLE.Result(FEngine.Regs.Cmd[C]);
end;

procedure TPSPGE.hGetMtx;
begin
  var Kind := FHLE.Arg(0);
  var P := FHLE.Arg(1);
  if Kind > 11 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX);
    Exit;
  end;
  var R: ^TPSPGERegs := @FEngine.Regs;
  case Kind of
    0..7:
      FMemory.WriteBytes(P, R.Bone[Kind * 12], 48);
    8:
      FMemory.WriteBytes(P, R.World[0], 48);
    9:
      FMemory.WriteBytes(P, R.View[0], 48);
    10:
      FMemory.WriteBytes(P, R.Proj[0], 64);
    11:
      FMemory.WriteBytes(P, R.TGen[0], 48);
  end;
  FHLE.Result(0);
end;

procedure TPSPGE.hGetStack;
begin
  var Index := FHLE.ArgInt(0);
  var P := FHLE.Arg(1);
  if FHWList < 0 then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var L: PGEList := @FLists[FHWList];
  if Index >= L.SigDepth then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX);
    Exit;
  end;
  if (Index >= 0) and (P <> 0) then
  begin
    var F := L.SigStack[Index];
    var W: array[0..7] of Cardinal;
    W[0] := F.PC;
    W[1] := F.Base;
    W[2] := F.Offset;
    W[3] := Cardinal(F.Depth);
    W[4] := F.Stack[0].PC;
    W[5] := F.Stack[0].Offset;
    W[6] := F.Stack[1].PC;
    W[7] := F.Stack[1].Offset;
    FMemory.WriteBytes(P, W[0], 32);
  end;
  FHLE.Result(Cardinal(L.SigDepth));
end;

procedure TPSPGE.hSaveContext;
begin
  if FHWRunning and not FHWHalted then
  begin
    FHLE.Result($FFFFFFFF);
    Exit;
  end;
  FEngine.SaveContext(FHLE.Arg(0));
  FHLE.Result(0);
end;

procedure TPSPGE.hRestoreContext;
begin
  if FHWRunning and not FHWHalted then
  begin
    FHLE.Result(SCE_ERROR_BUSY);
    Exit;
  end;
  FEngine.RestoreContext(FHLE.Arg(0));
  FHLE.Result(0);
end;

procedure TPSPGE.Register;
const
  Libs: array[0..1] of string = ('sceGe_user', 'sceGe_driver');
begin
  for var G in Libs do
  begin
    var H := FHLE;
    H.Register(G, $E47E40E4, 'sceGeEdramGetAddr', hEdramGetAddr);
    H.Register(G, $1F6752AD, 'sceGeEdramGetSize', hEdramGetSize);
    H.Register(G, $B77905EA, 'sceGeEdramSetAddrTranslation', hEdramSetAddrTranslation);
    H.Register(G, $5BAA5439, 'sceGeEdramSetSize', hEdramSetSize);
    H.Register(G, $DC93CFEF, 'sceGeGetCmd', hGetCmd);
    H.Register(G, $57C8945B, 'sceGeGetMtx', hGetMtx);
    H.Register(G, $E66CB92E, 'sceGeGetStack', hGetStack);
    H.Register(G, $438A385A, 'sceGeSaveContext', hSaveContext);
    H.Register(G, $0BF608FB, 'sceGeRestoreContext', hRestoreContext);
    H.Register(G, $AB49E76A, 'sceGeListEnQueue', hListEnQueue);
    H.Register(G, $1C0D95A6, 'sceGeListEnQueueHead', hListEnQueueHead);
    H.Register(G, $5FB86AB0, 'sceGeListDeQueue', hListDeQueue);
    H.Register(G, $E0D68148, 'sceGeListUpdateStallAddr', hListUpdateStallAddr);
    H.Register(G, $03444EB4, 'sceGeListSync', hListSync);
    H.Register(G, $B287BD61, 'sceGeDrawSync', hDrawSync);
    H.Register(G, $B448EC0D, 'sceGeBreak', hBreak);
    H.Register(G, $4C06E472, 'sceGeContinue', hContinue);
    H.Register(G, $A4FC06A4, 'sceGeSetCallback', hSetCallback);
    H.Register(G, $05DB22CE, 'sceGeUnsetCallback', hUnsetCallback);
  end;
  FHLE.Register('sceGe_driver', $547EC5F0, 'sceGeEdramGetHwSize', hEdramGetSize);
  FHLE.Register('sceGe_driver', $D8633888, 'sceGeEdramSetSize', hEdramSetSize);
end;

initialization
  RegisterPSPService(TPSPGE);

end.

