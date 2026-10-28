unit PS1.CPU;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler,
  PS1.Bus, PS1.GTE;

const
  // COP0 status register bits.
  PS1SRIEc = $00000001;
  PS1SRKUc = $00000002;
  PS1SRIsC = $00010000;
  PS1SRBEV = $00400000;
  PS1SRCU0 = $10000000;
  PS1SRCU1 = $20000000;
  PS1SRCU2 = $40000000;
  PS1SRCU3 = $80000000;

  // Cause bits.
  PS1CauseSoftware = $00000300;
  PS1CauseIP2 = $00000400;
  PS1CauseBT = $40000000;
  PS1CauseBD = $80000000;

type
  TPS1ExceptionCode = (Interrupt = 0, AddressLoad = 4, AddressStore = 5,
    BusFetch = 6, BusData = 7, Syscall = 8, Breakpoint = 9, Reserved = 10,
    Unusable = 11, Overflow = 12);

  TPS1CPU = class;

  // Called before each instruction while TPS1CPU.HookEnabled is set. The hook
  // may redirect execution with SetPC.
  TPS1CPUHook = procedure(CPU: TPS1CPU) of object;

  // R3000A with load/branch delay slots, COP0 exceptions and a 4 KiB i-cache.
  TPS1CPU = class
  private
    FBus: TPS1Bus;
    FScheduler: TPS1Scheduler;
    FGTE: TPS1GTE;
    FRegs: array[0..31] of Cardinal;
    FHi, FLo: Cardinal;
    // FPC is the next instruction, FNextPC the one after it. FBranch marks the
    // instruction at FPC as a delay slot of a (taken or not) branch.
    FPC, FNextPC, FCurrentPC: Cardinal;
    FBranch, FBranchTaken: Boolean;
    FBranchTarget: Cardinal;
    FInDelay, FDelayTaken: Boolean;
    FDelayTarget: Cardinal;
    // A load retires after the next instruction unless that instruction
    // writes the same register itself.
    FLoadReg: Integer;
    FLoadValue: Cardinal;
    FNewLoadReg: Integer;
    FNewLoadValue: Cardinal;
    FWrittenReg: Integer;
    FSR, FCause, FEPC, FBadVaddr, FTAR: Cardinal;
    FBPC, FBDA, FBDAM, FBPCM, FDCIC: Cardinal;
    FIRQ: Boolean;
    FInterruptPending, FUserMode: Boolean;
    FMulDivReady, FGTEReady: Int64;
    // Completion of the stores waiting in the four-entry write queue.
    FWriteDone: Int64;
    FBreak: Boolean;
    FICacheTag: array[0..255] of Cardinal;
    FICacheData: array[0..1023] of Cardinal;
    FHookEnabled: Boolean;
    FOnHook: TPS1CPUHook;
    procedure UpdateStatus;
    procedure SetReg(Index: Integer; Value: Cardinal); inline;
    procedure LoadReg(Index: Integer; Value: Cardinal); inline;
    procedure Enter(Code: TPS1ExceptionCode; InDelay, Taken: Boolean; Target, PC: Cardinal; Coprocessor: Integer);
    procedure Fault(Code: TPS1ExceptionCode; Coprocessor: Integer = 0);
    procedure AddressError(Code: TPS1ExceptionCode; Address: Cardinal);
    procedure Branch(Taken: Boolean; Target: Cardinal); inline;
    function RelativeTarget(Op: Cardinal): Cardinal; inline;
    function JumpTarget(Op: Cardinal): Cardinal; inline;
    function Fetch(Address: Cardinal; out Op: Cardinal): Boolean;
    function FetchCached(Address: Cardinal; out Op: Cardinal): Boolean;
    function Peek(Address: Cardinal; out Op: Cardinal): Boolean;
    function CacheLoad(Address: Cardinal; Size: Integer): Cardinal;
    procedure CacheStore(Address, Value: Cardinal; Size: Integer);
    function ReadData(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean;
    function WriteData(Address, Value: Cardinal; Size: Integer): Boolean;
    function DataAddress(Op: Cardinal; Size: Integer; Store: Boolean; out Address: Cardinal): Boolean; inline;
    procedure Load(Op: Cardinal; Size: Integer; Signed: Boolean);
    procedure LoadUnaligned(Op: Cardinal; Left: Boolean);
    procedure Store(Op: Cardinal; Size: Integer);
    procedure StoreUnaligned(Op: Cardinal; Left: Boolean);
    procedure Drain; inline;
    procedure QueueWrite(Cycles: Integer);
    procedure WaitMulDiv; inline;
    procedure WaitGTE; inline;
    procedure ExecuteSpecial(Op: Cardinal);
    procedure ExecuteCop0(Op: Cardinal);
    procedure ExecuteCop2(Op: Cardinal);
    procedure ExecuteCopUnused(Op: Cardinal; Number: Integer);
    procedure ExecuteCopMemory(Op: Cardinal; Number: Integer; Store: Boolean);
    procedure Execute(Op: Cardinal);
    procedure TakeInterrupt;
    procedure StepOnce; inline;
    function GetReg(Index: Integer): Cardinal;
    procedure SetRegPublic(Index: Integer; Value: Cardinal);
    function GetCause: Cardinal;
  public
    constructor Create(Bus: TPS1Bus; Scheduler: TPS1Scheduler; GTE: TPS1GTE);
    procedure Reset;
    procedure Step;
    // Executes until Target or the next scheduled event.
    procedure Run(Target: Int64);
    procedure SetIRQ(Active: Boolean);
    // Ends Run after the current instruction (the CPU lost the bus).
    procedure BreakRun;
    // Redirects execution; pending branch and load state is discarded.
    procedure SetPC(Value: Cardinal);
    procedure InvalidateICache;
    procedure SerializeState(State: TStateArchive);
    property Reg[Index: Integer]: Cardinal read GetReg write SetRegPublic;
    property Hi: Cardinal read FHi write FHi;
    property Lo: Cardinal read FLo write FLo;
    property PC: Cardinal read FPC;
    property CurrentPC: Cardinal read FCurrentPC;
    property SR: Cardinal read FSR;
    property Cause: Cardinal read GetCause;
    property EPC: Cardinal read FEPC;
    property BadVaddr: Cardinal read FBadVaddr;
    property TAR: Cardinal read FTAR;
    property HookEnabled: Boolean read FHookEnabled write FHookEnabled;
    property OnHook: TPS1CPUHook read FOnHook write FOnHook;
  end;

implementation

const
  PRId = $00000002;
  SRWritable = $F27FFF3F;
  DCICWritable = $FF80F03F;

constructor TPS1CPU.Create(Bus: TPS1Bus; Scheduler: TPS1Scheduler; GTE: TPS1GTE);
begin
  inherited Create;
  FBus := Bus;
  FScheduler := Scheduler;
  FGTE := GTE;
  Reset;
end;

procedure TPS1CPU.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FHi := 0;
  FLo := 0;
  FPC := $BFC00000;
  FNextPC := $BFC00004;
  FCurrentPC := FPC;
  FBranch := False;
  FBranchTaken := False;
  FBranchTarget := 0;
  FInDelay := False;
  FDelayTaken := False;
  FDelayTarget := 0;
  FLoadReg := 0;
  FLoadValue := 0;
  FNewLoadReg := 0;
  FNewLoadValue := 0;
  FWrittenReg := 0;
  FSR := PS1SRBEV;
  FCause := 0;
  FEPC := 0;
  FBadVaddr := 0;
  FTAR := 0;
  FBPC := 0;
  FBDA := 0;
  FBDAM := 0;
  FBPCM := 0;
  FDCIC := 0;
  FMulDivReady := 0;
  FGTEReady := 0;
  FWriteDone := 0;
  FBreak := False;
  FillChar(FICacheTag, SizeOf(FICacheTag), 0);
  FillChar(FICacheData, SizeOf(FICacheData), 0);
  UpdateStatus;
end;

procedure TPS1CPU.UpdateStatus;
begin
  FUserMode := (FSR and PS1SRKUc) <> 0;
  FInterruptPending := ((FSR and PS1SRIEc) <> 0) and ((FSR and GetCause and $FF00) <> 0);
  FBus.SetIsolated((FSR and PS1SRIsC) <> 0);
end;

function TPS1CPU.GetCause: Cardinal;
begin
  Result := FCause;
  if FIRQ then
    Result := Result or PS1CauseIP2;
end;

procedure TPS1CPU.SetIRQ(Active: Boolean);
begin
  if FIRQ = Active then
    Exit;

  FIRQ := Active;
  FInterruptPending := ((FSR and PS1SRIEc) <> 0) and ((FSR and GetCause and $FF00) <> 0);
end;

function TPS1CPU.GetReg(Index: Integer): Cardinal;
begin
  Result := FRegs[Index and 31];
end;

procedure TPS1CPU.SetRegPublic(Index: Integer; Value: Cardinal);
begin
  if (Index and 31) <> 0 then
    FRegs[Index and 31] := Value;
end;

procedure TPS1CPU.SetPC(Value: Cardinal);
begin
  if FLoadReg <> 0 then
    FRegs[FLoadReg] := FLoadValue;
  FLoadReg := 0;
  FPC := Value;
  FNextPC := Add32(Value, 4);
  FBranch := False;
  FBranchTaken := False;
end;

procedure TPS1CPU.InvalidateICache;
begin
  for var Line := 0 to High(FICacheTag) do
    FICacheTag[Line] := FICacheTag[Line] and not Cardinal($F);
end;

procedure TPS1CPU.SetReg(Index: Integer; Value: Cardinal);
begin
  if Index <> 0 then
    FRegs[Index] := Value;
  FWrittenReg := Index;
end;

procedure TPS1CPU.LoadReg(Index: Integer; Value: Cardinal);
begin
  FNewLoadReg := Index;
  FNewLoadValue := Value;
end;

procedure TPS1CPU.Enter(Code: TPS1ExceptionCode; InDelay, Taken: Boolean; Target, PC: Cardinal; Coprocessor: Integer);
begin
  // Push the KU/IE stack: current -> previous -> old.
  FSR := (FSR and not Cardinal($3F)) or ((FSR shl 2) and $3F);
  FCause := (FCause and PS1CauseSoftware) or (Cardinal(Ord(Code)) shl 2) or
    (Cardinal(Coprocessor and 3) shl 28);
  if InDelay then
  begin
    FEPC := Sub32(PC, 4);
    FCause := FCause or PS1CauseBD;
    if Taken then
    begin
      FCause := FCause or PS1CauseBT;
      FTAR := Target;
    end;
  end
  else
    FEPC := PC;
  var Vector: Cardinal := $80000080;
  if (FSR and PS1SRBEV) <> 0 then
    Vector := $BFC00180;
  FPC := Vector;
  FNextPC := Vector + 4;
  FBranch := False;
  FBranchTaken := False;
  UpdateStatus;
end;

procedure TPS1CPU.Fault(Code: TPS1ExceptionCode; Coprocessor: Integer);
begin
  Enter(Code, FInDelay, FDelayTaken, FDelayTarget, FCurrentPC, Coprocessor);
end;

procedure TPS1CPU.AddressError(Code: TPS1ExceptionCode; Address: Cardinal);
begin
  FBadVaddr := Address;
  Fault(Code);
end;

procedure TPS1CPU.Branch(Taken: Boolean; Target: Cardinal);
begin
  FBranch := True;
  FBranchTaken := Taken;
  FBranchTarget := Target;
  if Taken then
    FNextPC := Target;
end;

// Targets are relative to the branch's own delay slot, even when the branch
// itself sits in another branch's delay slot.
function TPS1CPU.RelativeTarget(Op: Cardinal): Cardinal;
begin
  Result := Add32(Add32(FCurrentPC, 4), SX16(Op and $FFFF) shl 2);
end;

function TPS1CPU.JumpTarget(Op: Cardinal): Cardinal;
begin
  Result := (Add32(FCurrentPC, 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
end;

procedure TPS1CPU.WaitMulDiv;
begin
  if FScheduler.Now < FMulDivReady then
    FScheduler.Now := FMulDivReady;
end;

procedure TPS1CPU.WaitGTE;
begin
  if FScheduler.Now < FGTEReady then
    FScheduler.Now := FGTEReady;
end;

function TPS1CPU.FetchCached(Address: Cardinal; out Op: Cardinal): Boolean;
begin
  var Physical := Address and $1FFFFFFF;
  var Line := (Address shr 4) and $FF;
  var Slot := Integer((Address shr 2) and 3);
  var Tag := FICacheTag[Line];
  var Match := ((Tag xor Physical) and $FFFFF000) = 0;
  if Match and (((Tag shr Slot) and 1) <> 0) then
  begin
    Op := FICacheData[Line * 4 + Cardinal(Slot)];
    Exit(True);
  end;

  if not FBus.FetchAllowed(Address) then
  begin
    Fault(TPS1ExceptionCode.BusFetch);
    Exit(False);
  end;

  // A tag hit with a missing word refills the whole line. A miss fills from
  // the requested word to the end of the line (two words with IBLKSZ=0).
  var First := Slot;
  var Last := 3;
  if Match then
    First := 0
  else if (Slot = 0) and (((FBus.CacheControl shr 8) and 3) = 0) then
    Last := 1;
  Drain;
  var LineBase := Address and $FFFFFFF0;
  var Kind := FBus.PageKind[Address shr 16];
  for var I := First to Last do
  begin
    var WordAddress := LineBase + Cardinal(I) * 4;
    var Value: Cardinal;
    var P := FBus.ReadMap[WordAddress shr 16];
    if P <> nil then
      Value := PCardinal(P + (WordAddress and $FFFF))^
    else
    begin
      var Cycles: Integer;
      if not FBus.ReadSlow(WordAddress, 4, Value, Cycles) then
      begin
        Fault(TPS1ExceptionCode.BusFetch);
        Exit(False);
      end;
      Inc(FScheduler.Now, Cycles);
    end;
    FICacheData[Line * 4 + Cardinal(I)] := Value;
  end;
  case Kind of
    TPS1PageKind.RAM:
      Inc(FScheduler.Now, PS1ICacheFillFirst + (Last - First) * PS1ICacheFillNext);
    TPS1PageKind.BIOS:
      Inc(FScheduler.Now, (Last - First + 1) * FBus.BIOSReadCycles(4));
  end;
  var Valid := (Cardinal($F) shl First) and (Cardinal($F) shr (3 - Last));
  FICacheTag[Line] := (Physical and $FFFFF000) or Valid;
  Op := FICacheData[Line * 4 + Cardinal(Slot)];
  Result := True;
end;

function TPS1CPU.Fetch(Address: Cardinal; out Op: Cardinal): Boolean;
begin
  if ((Address and 3) <> 0) or (FUserMode and (Address >= $80000000)) then
  begin
    AddressError(TPS1ExceptionCode.AddressLoad, Address);
    Exit(False);
  end;

  var Segment := Address shr 29;
  if ((Segment = 0) or (Segment = 4)) and ((FBus.CacheControl and PS1BCCICache) <> 0) then
    Exit(FetchCached(Address, Op));

  Drain;
  var P := FBus.ReadMap[Address shr 16];
  if P <> nil then
  begin
    Op := PCardinal(P + (Address and $FFFF))^;
    if FBus.PageKind[Address shr 16] = TPS1PageKind.RAM then
      Inc(FScheduler.Now, PS1RAMFetchStall)
    else
      Inc(FScheduler.Now, FBus.BIOSReadCycles(4));
    Exit(True);
  end;

  var Cycles: Integer;
  if not FBus.FetchAllowed(Address) or not FBus.ReadSlow(Address, 4, Op, Cycles) then
  begin
    Fault(TPS1ExceptionCode.BusFetch);
    Exit(False);
  end;
  Inc(FScheduler.Now, Cycles);
  Result := True;
end;

function TPS1CPU.Peek(Address: Cardinal; out Op: Cardinal): Boolean;
begin
  Op := 0;
  if (Address and 3) <> 0 then
    Exit(False);

  var Segment := Address shr 29;
  if ((Segment = 0) or (Segment = 4)) and ((FBus.CacheControl and PS1BCCICache) <> 0) then
  begin
    var Line := (Address shr 4) and $FF;
    var Slot := (Address shr 2) and 3;
    var Tag := FICacheTag[Line];
    if (((Tag xor Address) and $1FFFF000) = 0) and (((Tag shr Slot) and 1) <> 0) then
    begin
      Op := FICacheData[Line * 4 + Slot];
      Exit(True);
    end;
  end;
  var P := FBus.ReadMap[Address shr 16];
  Result := P <> nil;
  if Result then
    Op := PCardinal(P + (Address and $FFFF))^;
end;

function TPS1CPU.CacheLoad(Address: Cardinal; Size: Integer): Cardinal;
begin
  var Line := (Address shr 4) and $FF;
  var Data := FICacheData[(Address shr 2) and $3FF];
  if (FBus.CacheControl and PS1BCCTag) <> 0 then
  begin
    var Tag := FICacheTag[Line];
    Data := (Data and $FFFFFFE0) or (Tag and $F);
    if ((Tag xor Address) and $1FFFF000) = 0 then
      Data := Data or $10;
  end;
  Result := Data shr ((Address and 3) * 8);
  if Size < 4 then
    Result := Result and ($FFFFFFFF shr ((4 - Size) * 8));
end;

procedure TPS1CPU.CacheStore(Address, Value: Cardinal; Size: Integer);
begin
  var Line := (Address shr 4) and $FF;
  if (FBus.CacheControl and PS1BCCTag) <> 0 then
    FICacheTag[Line] := (Value and $F) or (Address and $1FFFF000)
  else if (FBus.CacheControl and PS1BCCICache) <> 0 then
    FICacheData[(Address shr 2) and $3FF] := Value;
end;

// Reads use the bus after the write queue has drained; scratchpad and cache
// accesses do not touch the bus.
procedure TPS1CPU.Drain;
begin
  if FWriteDone > FScheduler.Now then
    FScheduler.Now := FWriteDone;
end;

procedure TPS1CPU.QueueWrite(Cycles: Integer);
begin
  var Start := FScheduler.Now;
  if FWriteDone > Start then
    Start := FWriteDone;
  FWriteDone := Start + Cycles;
  // Four entries fit; a further store waits for the oldest to retire.
  var Backlog := FWriteDone - FScheduler.Now;
  if Backlog > PS1WriteQueueDepth * PS1RAMWriteCycles then
    FScheduler.Now := FWriteDone - PS1WriteQueueDepth * PS1RAMWriteCycles;
end;

function IsScratchpad(Address: Cardinal): Boolean; inline;
begin
  Result := ((Address and $1FFFFC00) = $1F800000) and ((Address shr 29) <> 5);
end;

function TPS1CPU.ReadData(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean;
begin
  var Page := Address shr 16;
  var P := FBus.ReadMap[Page];
  if P <> nil then
  begin
    Drain;
    Inc(P, Address and $FFFF);
    case Size of
      1:
        Value := P^;
      2:
        Value := PWord(P)^;
    else
      Value := PCardinal(P)^;
    end;
    if FBus.PageKind[Page] = TPS1PageKind.RAM then
      Inc(FScheduler.Now, PS1RAMReadStall)
    else
      Inc(FScheduler.Now, FBus.BIOSReadCycles(Size));
    Exit(True);
  end;

  var Segment := Address shr 29;
  if FBus.Isolated and ((Segment = 0) or (Segment = 4)) then
  begin
    Value := CacheLoad(Address, Size);
    Exit(True);
  end;

  if not IsScratchpad(Address) then
    Drain;
  var Cycles: Integer;
  Result := FBus.ReadSlow(Address, Size, Value, Cycles);
  Inc(FScheduler.Now, Cycles);
end;

// Stores enter the write queue, except KSEG1 stores, which bypass it after
// flushing it, and scratchpad stores.
function TPS1CPU.WriteData(Address, Value: Cardinal; Size: Integer): Boolean;
begin
  var Segment := Address shr 29;
  var P := FBus.WriteMap[Address shr 16];
  if P <> nil then
  begin
    Inc(P, Address and $FFFF);
    case Size of
      1:
        P^ := Byte(Value);
      2:
        PWord(P)^ := Word(Value);
    else
      PCardinal(P)^ := Value;
    end;
    if Segment = 5 then
    begin
      Drain;
      Inc(FScheduler.Now, PS1RAMWriteCycles);
    end
    else
      QueueWrite(PS1RAMWriteCycles);
    Exit(True);
  end;

  if FBus.Isolated and ((Segment = 0) or (Segment = 4)) then
  begin
    CacheStore(Address, Value, Size);
    Exit(True);
  end;

  var Scratch := IsScratchpad(Address);
  if Segment = 5 then
    Drain;
  var Cycles: Integer;
  Result := FBus.WriteSlow(Address, Value, Size, Cycles);
  if Scratch then
    Exit;
  if Cycles < PS1IOWriteCycles then
    Cycles := PS1IOWriteCycles;
  if Segment = 5 then
    Inc(FScheduler.Now, Cycles)
  else
    QueueWrite(Cycles);
end;

function TPS1CPU.DataAddress(Op: Cardinal; Size: Integer; Store: Boolean; out Address: Cardinal): Boolean;
begin
  Address := Add32(FRegs[(Op shr 21) and 31], SX16(Op and $FFFF));
  if ((Address and Cardinal(Size - 1)) <> 0) or (FUserMode and (Address >= $80000000)) then
  begin
    if Store then
      AddressError(TPS1ExceptionCode.AddressStore, Address)
    else
      AddressError(TPS1ExceptionCode.AddressLoad, Address);
    Exit(False);
  end;
  Result := True;
end;

procedure TPS1CPU.Load(Op: Cardinal; Size: Integer; Signed: Boolean);
begin
  var Address: Cardinal;
  if not DataAddress(Op, Size, False, Address) then
    Exit;

  var Value: Cardinal;
  if not ReadData(Address, Size, Value) then
  begin
    Fault(TPS1ExceptionCode.BusData);
    Exit;
  end;
  if Signed then
  begin
    if Size = 1 then
      Value := SX8(Value)
    else
      Value := SX16(Value);
  end;
  LoadReg((Op shr 16) and 31, Value);
end;

procedure TPS1CPU.LoadUnaligned(Op: Cardinal; Left: Boolean);
begin
  var Address: Cardinal;
  if not DataAddress(Op, 1, False, Address) then
    Exit;

  var Data: Cardinal;
  if not ReadData(Address and not Cardinal(3), 4, Data) then
  begin
    Fault(TPS1ExceptionCode.BusData);
    Exit;
  end;
  // A pending load to the same register is forwarded into the merge.
  var Target := Integer((Op shr 16) and 31);
  var Current := FRegs[Target];
  if FLoadReg = Target then
    Current := FLoadValue;
  var Shift := (Address and 3) * 8;
  var Value: Cardinal;
  if Left then
  begin
    Shift := 24 - Shift;
    Value := (Current and not ($FFFFFFFF shl Shift)) or (Data shl Shift);
  end
  else
    Value := (Current and not ($FFFFFFFF shr Shift)) or (Data shr Shift);
  LoadReg(Target, Value);
end;

procedure TPS1CPU.Store(Op: Cardinal; Size: Integer);
begin
  var Address: Cardinal;
  if not DataAddress(Op, Size, True, Address) then
    Exit;

  if not WriteData(Address, FRegs[(Op shr 16) and 31], Size) then
    Fault(TPS1ExceptionCode.BusData);
end;

procedure TPS1CPU.StoreUnaligned(Op: Cardinal; Left: Boolean);
begin
  var Address: Cardinal;
  if not DataAddress(Op, 1, True, Address) then
    Exit;

  var Value := FRegs[(Op shr 16) and 31];
  var Offset := Integer(Address and 3);
  var Base := Address and not Cardinal(3);
  // SWL stores the upper bytes of rt to [base..address], SWR the lower bytes
  // to [address..base+3].
  var First, Last, Shift: Integer;
  if Left then
  begin
    First := 0;
    Last := Offset;
    Shift := 3 - Offset;
  end
  else
  begin
    First := Offset;
    Last := 3;
    Shift := -Offset;
  end;
  for var I := First to Last do
  begin
    var ByteValue := Value shr ((I + Shift) * 8);
    if not WriteData(Base + Cardinal(I), ByteValue and $FF, 1) then
    begin
      Fault(TPS1ExceptionCode.BusData);
      Exit;
    end;
  end;
end;

procedure TPS1CPU.ExecuteSpecial(Op: Cardinal);
begin
  var Rs := FRegs[(Op shr 21) and 31];
  var Rt := FRegs[(Op shr 16) and 31];
  var Rd := Integer((Op shr 11) and 31);
  var Shamt := Integer((Op shr 6) and 31);
  case Op and $3F of
    $00:
      SetReg(Rd, Rt shl Shamt);
    $02:
      SetReg(Rd, Rt shr Shamt);
    $03:
      if (Rt and $80000000) <> 0 then
        SetReg(Rd, not ((not Rt) shr Shamt))
      else
        SetReg(Rd, Rt shr Shamt);
    $04:
      SetReg(Rd, Rt shl (Rs and 31));
    $06:
      SetReg(Rd, Rt shr (Rs and 31));
    $07:
      if (Rt and $80000000) <> 0 then
        SetReg(Rd, not ((not Rt) shr (Rs and 31)))
      else
        SetReg(Rd, Rt shr (Rs and 31));
    $08:
      Branch(True, Rs);
    $09:
      begin
        SetReg(Rd, Add32(FCurrentPC, 8));
        Branch(True, Rs);
      end;
    $0C:
      Fault(TPS1ExceptionCode.Syscall);
    $0D:
      Fault(TPS1ExceptionCode.Breakpoint);
    $10:
      begin
        WaitMulDiv;
        SetReg(Rd, FHi);
      end;
    $11:
      FHi := Rs;
    $12:
      begin
        WaitMulDiv;
        SetReg(Rd, FLo);
      end;
    $13:
      FLo := Rs;
    $18, $19:
      begin
        var Magnitude := Rs;
        var Product: UInt64;
        if (Op and 1) = 0 then
        begin
          if (Rs and $80000000) <> 0 then
            Magnitude := not Rs;
          Product := UInt64(Int64(Integer(Rs)) * Int64(Integer(Rt)));
        end
        else
          Product := UInt64(Rs) * Rt;
        FLo := Cardinal(Product);
        FHi := Cardinal(Product shr 32);
        var Cycles := 13;
        if Magnitude < $800 then
          Cycles := 6
        else if Magnitude < $100000 then
          Cycles := 9;
        FMulDivReady := FScheduler.Now + Cycles;
      end;
    $1A:
      begin
        if Rt = 0 then
        begin
          FHi := Rs;
          if (Rs and $80000000) <> 0 then
            FLo := 1
          else
            FLo := $FFFFFFFF;
        end
        else if (Rs = $80000000) and (Rt = $FFFFFFFF) then
        begin
          FHi := 0;
          FLo := $80000000;
        end
        else
        begin
          FLo := Cardinal(Integer(Rs) div Integer(Rt));
          FHi := Cardinal(Integer(Rs) mod Integer(Rt));
        end;
        FMulDivReady := FScheduler.Now + 36;
      end;
    $1B:
      begin
        if Rt = 0 then
        begin
          FHi := Rs;
          FLo := $FFFFFFFF;
        end
        else
        begin
          FLo := Rs div Rt;
          FHi := Rs mod Rt;
        end;
        FMulDivReady := FScheduler.Now + 36;
      end;
    $20:
      begin
        var Sum := Int64(Integer(Rs)) + Integer(Rt);
        if (Sum < Low(Integer)) or (Sum > High(Integer)) then
          Fault(TPS1ExceptionCode.Overflow)
        else
          SetReg(Rd, Cardinal(Sum));
      end;
    $21:
      SetReg(Rd, Add32(Rs, Rt));
    $22:
      begin
        var Difference := Int64(Integer(Rs)) - Integer(Rt);
        if (Difference < Low(Integer)) or (Difference > High(Integer)) then
          Fault(TPS1ExceptionCode.Overflow)
        else
          SetReg(Rd, Cardinal(Difference));
      end;
    $23:
      SetReg(Rd, Sub32(Rs, Rt));
    $24:
      SetReg(Rd, Rs and Rt);
    $25:
      SetReg(Rd, Rs or Rt);
    $26:
      SetReg(Rd, Rs xor Rt);
    $27:
      SetReg(Rd, not (Rs or Rt));
    $2A:
      SetReg(Rd, Ord(Integer(Rs) < Integer(Rt)));
    $2B:
      SetReg(Rd, Ord(Rs < Rt));
  else
    Fault(TPS1ExceptionCode.Reserved);
  end;
end;

procedure TPS1CPU.ExecuteCop0(Op: Cardinal);
begin
  var Rd := Integer((Op shr 11) and 31);
  var Format := (Op shr 21) and 31;
  // Garbage registers 16..31 stay readable without COP0 access rights.
  if FUserMode and ((FSR and PS1SRCU0) = 0) and not ((Format = 0) and (Rd >= 16)) then
  begin
    Fault(TPS1ExceptionCode.Unusable, 0);
    Exit;
  end;

  case Format of
    $00:
      begin
        var Value: Cardinal;
        case Rd of
          3:
            Value := FBPC;
          5:
            Value := FBDA;
          6:
            Value := FTAR;
          7:
            Value := FDCIC;
          8:
            Value := FBadVaddr;
          9:
            Value := FBDAM;
          11:
            Value := FBPCM;
          12:
            Value := FSR;
          13:
            Value := GetCause;
          14:
            Value := FEPC;
          15:
            Value := PRId;
          16..31:
            Value := 0;
        else
          Fault(TPS1ExceptionCode.Reserved);
          Exit;
        end;
        LoadReg((Op shr 16) and 31, Value);
      end;
    $04:
      begin
        var Value := FRegs[(Op shr 16) and 31];
        case Rd of
          3:
            FBPC := Value;
          5:
            FBDA := Value;
          7:
            FDCIC := Value and DCICWritable;
          9:
            FBDAM := Value;
          11:
            FBPCM := Value;
          12:
            begin
              FSR := Value and SRWritable;
              UpdateStatus;
            end;
          13:
            begin
              FCause := (FCause and not PS1CauseSoftware) or (Value and PS1CauseSoftware);
              UpdateStatus;
            end;
        end;
      end;
    $08:
      Fault(TPS1ExceptionCode.Unusable, 0);
    $10..$1F:
      // RFE; the TLB commands are reserved, other command numbers do nothing.
      case Op and $3F of
        $10:
          begin
            FSR := (FSR and not Cardinal($F)) or ((FSR shr 2) and $F);
            UpdateStatus;
          end;
        $01, $02, $06, $08:
          Fault(TPS1ExceptionCode.Reserved);
      end;
  else
    Fault(TPS1ExceptionCode.Reserved);
  end;
end;

procedure TPS1CPU.ExecuteCop2(Op: Cardinal);
begin
  if (FSR and PS1SRCU2) = 0 then
  begin
    Fault(TPS1ExceptionCode.Unusable, 2);
    Exit;
  end;

  WaitGTE;
  if (Op and $02000000) <> 0 then
  begin
    FGTEReady := FScheduler.Now + FGTE.Execute(Op and $01FFFFFF);
    Exit;
  end;

  var Rt := Integer((Op shr 16) and 31);
  var Rd := Integer((Op shr 11) and 31);
  case (Op shr 21) and 31 of
    $00:
      LoadReg(Rt, FGTE.ReadData(Rd));
    $02:
      LoadReg(Rt, FGTE.ReadControl(Rd));
    $04:
      FGTE.WriteData(Rd, FRegs[Rt]);
    $06:
      FGTE.WriteControl(Rd, FRegs[Rt]);
    $08:
      // The GTE drives no branch condition input.
      Branch((Op and $10000) = 0, RelativeTarget(Op));
  else
    Fault(TPS1ExceptionCode.Reserved);
  end;
end;

procedure TPS1CPU.ExecuteCopUnused(Op: Cardinal; Number: Integer);
begin
  if (FSR and (Cardinal(PS1SRCU0) shl Number)) = 0 then
    Fault(TPS1ExceptionCode.Unusable, Number)
  else if ((Op shr 21) and 31) in [$00, $02] then
    LoadReg((Op shr 16) and 31, 0);
end;

procedure TPS1CPU.ExecuteCopMemory(Op: Cardinal; Number: Integer; Store: Boolean);
begin
  // Every LWCn/SWCn needs its usable bit, CU0 included even in kernel mode
  // (ps1-tests cpu/cop); without a data path they then do nothing.
  if (FSR and (Cardinal(PS1SRCU0) shl Number)) = 0 then
  begin
    Fault(TPS1ExceptionCode.Unusable, Number);
    Exit;
  end;
  if Number <> 2 then
    Exit;

  WaitGTE;
  var Address: Cardinal;
  if not DataAddress(Op, 4, Store, Address) then
    Exit;

  var Index := Integer((Op shr 16) and 31);
  if Store then
  begin
    if not WriteData(Address, FGTE.ReadData(Index), 4) then
      Fault(TPS1ExceptionCode.BusData);
  end
  else
  begin
    var Value: Cardinal;
    if ReadData(Address, 4, Value) then
      FGTE.WriteData(Index, Value)
    else
      Fault(TPS1ExceptionCode.BusData);
  end;
end;

procedure TPS1CPU.Execute(Op: Cardinal);
begin
  case Op shr 26 of
    $00:
      ExecuteSpecial(Op);
    $01:
      begin
        var Rs := FRegs[(Op shr 21) and 31];
        var Rt := (Op shr 16) and 31;
        var Taken := (Rs and $80000000) <> 0;
        if (Rt and 1) <> 0 then
          Taken := not Taken;
        // The link register is written whether or not the branch is taken,
        // after rs has been read.
        if (Rt and $1E) = $10 then
          SetReg(31, Add32(FCurrentPC, 8));
        Branch(Taken, RelativeTarget(Op));
      end;
    $02:
      Branch(True, JumpTarget(Op));
    $03:
      begin
        SetReg(31, Add32(FCurrentPC, 8));
        Branch(True, JumpTarget(Op));
      end;
    $04:
      Branch(FRegs[(Op shr 21) and 31] = FRegs[(Op shr 16) and 31], RelativeTarget(Op));
    $05:
      Branch(FRegs[(Op shr 21) and 31] <> FRegs[(Op shr 16) and 31], RelativeTarget(Op));
    $06:
      Branch(Integer(FRegs[(Op shr 21) and 31]) <= 0, RelativeTarget(Op));
    $07:
      Branch(Integer(FRegs[(Op shr 21) and 31]) > 0, RelativeTarget(Op));
    $08:
      begin
        var Sum := Int64(Integer(FRegs[(Op shr 21) and 31])) + SmallInt(Op and $FFFF);
        if (Sum < Low(Integer)) or (Sum > High(Integer)) then
          Fault(TPS1ExceptionCode.Overflow)
        else
          SetReg((Op shr 16) and 31, Cardinal(Sum));
      end;
    $09:
      SetReg((Op shr 16) and 31, Add32(FRegs[(Op shr 21) and 31], SX16(Op and $FFFF)));
    $0A:
      SetReg((Op shr 16) and 31, Ord(Integer(FRegs[(Op shr 21) and 31]) < SmallInt(Op and $FFFF)));
    $0B:
      SetReg((Op shr 16) and 31, Ord(FRegs[(Op shr 21) and 31] < SX16(Op and $FFFF)));
    $0C:
      SetReg((Op shr 16) and 31, FRegs[(Op shr 21) and 31] and (Op and $FFFF));
    $0D:
      SetReg((Op shr 16) and 31, FRegs[(Op shr 21) and 31] or (Op and $FFFF));
    $0E:
      SetReg((Op shr 16) and 31, FRegs[(Op shr 21) and 31] xor (Op and $FFFF));
    $0F:
      SetReg((Op shr 16) and 31, (Op and $FFFF) shl 16);
    $10:
      ExecuteCop0(Op);
    $11:
      ExecuteCopUnused(Op, 1);
    $12:
      ExecuteCop2(Op);
    $13:
      ExecuteCopUnused(Op, 3);
    $20:
      Load(Op, 1, True);
    $21:
      Load(Op, 2, True);
    $22:
      LoadUnaligned(Op, True);
    $23:
      Load(Op, 4, False);
    $24:
      Load(Op, 1, False);
    $25:
      Load(Op, 2, False);
    $26:
      LoadUnaligned(Op, False);
    $28:
      Store(Op, 1);
    $29:
      Store(Op, 2);
    $2A:
      StoreUnaligned(Op, True);
    $2B:
      Store(Op, 4);
    $2E:
      StoreUnaligned(Op, False);
    $30..$33:
      ExecuteCopMemory(Op, Integer(Op shr 26) and 3, False);
    $38..$3B:
      ExecuteCopMemory(Op, Integer(Op shr 26) and 3, True);
  else
    Fault(TPS1ExceptionCode.Reserved);
  end;
end;

procedure TPS1CPU.TakeInterrupt;
begin
  // The pending load completes during interrupt entry.
  if FLoadReg <> 0 then
    FRegs[FLoadReg] := FLoadValue;
  FLoadReg := 0;

  // A GTE command at the interrupted address is executed even though EPC
  // still points at it; handlers skip it when returning.
  var Op: Cardinal;
  if Peek(FPC, Op) and ((Op and $FE000000) = $4A000000) and ((FSR and PS1SRCU2) <> 0) then
  begin
    WaitGTE;
    FGTEReady := FScheduler.Now + FGTE.Execute(Op and $01FFFFFF);
  end;
  Enter(TPS1ExceptionCode.Interrupt, FBranch, FBranchTaken, FBranchTarget, FPC, 0);
end;

procedure TPS1CPU.StepOnce;
begin
  if FInterruptPending then
  begin
    Inc(FScheduler.Now);
    TakeInterrupt;
    Exit;
  end;
  if FHookEnabled and Assigned(FOnHook) then
    FOnHook(Self);

  FCurrentPC := FPC;
  FInDelay := FBranch;
  FDelayTaken := FBranchTaken;
  FDelayTarget := FBranchTarget;
  FBranch := False;
  FBranchTaken := False;
  FWrittenReg := 0;
  FNewLoadReg := 0;
  Inc(FScheduler.Now);
  // An i-cache hit as in FetchCached: aligned address in KUSEG (first 512
  // MiB) or in KSEG0 outside user mode, cache enabled, tag and word valid.
  var Op: Cardinal;
  var Address := FCurrentPC;
  var Segment := Address shr 29;
  var Tag := FICacheTag[(Address shr 4) and $FF];
  var Fetched: Boolean;
  if ((Address and 3) = 0) and ((Segment = 0) or ((Segment = 4) and not FUserMode)) and
    ((FBus.CacheControl and PS1BCCICache) <> 0) and (((Tag xor Address) and $1FFFF000) = 0) and
    (((Tag shr ((Address shr 2) and 3)) and 1) <> 0) then
  begin
    Op := FICacheData[(Address shr 2) and $3FF];
    Fetched := True;
  end
  else
    Fetched := Fetch(Address, Op);
  if Fetched then
  begin
    FPC := FNextPC;
    FNextPC := Add32(FNextPC, 4);
    Execute(Op);
  end;
  if (FLoadReg <> 0) and (FLoadReg <> FWrittenReg) then
    FRegs[FLoadReg] := FLoadValue;
  FLoadReg := FNewLoadReg;
  FLoadValue := FNewLoadValue;
end;

procedure TPS1CPU.Step;
begin
  StepOnce;
end;

procedure TPS1CPU.Run(Target: Int64);
begin
  FBreak := False;
  while (FScheduler.Now < Target) and (FScheduler.Now < FScheduler.NextDue) and not FBreak do
    StepOnce;
end;

procedure TPS1CPU.BreakRun;
begin
  FBreak := True;
end;

procedure TPS1CPU.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FHi, SizeOf(FHi));
  State.Field(FLo, SizeOf(FLo));
  State.Field(FPC, SizeOf(FPC));
  State.Field(FNextPC, SizeOf(FNextPC));
  State.Field(FCurrentPC, SizeOf(FCurrentPC));
  State.Field(FBranch, SizeOf(FBranch));
  State.Field(FBranchTaken, SizeOf(FBranchTaken));
  State.Field(FBranchTarget, SizeOf(FBranchTarget));
  State.Field(FLoadReg, SizeOf(FLoadReg));
  State.Field(FLoadValue, SizeOf(FLoadValue));
  State.Field(FSR, SizeOf(FSR));
  State.Field(FCause, SizeOf(FCause));
  State.Field(FEPC, SizeOf(FEPC));
  State.Field(FBadVaddr, SizeOf(FBadVaddr));
  State.Field(FTAR, SizeOf(FTAR));
  State.Field(FBPC, SizeOf(FBPC));
  State.Field(FBDA, SizeOf(FBDA));
  State.Field(FBDAM, SizeOf(FBDAM));
  State.Field(FBPCM, SizeOf(FBPCM));
  State.Field(FDCIC, SizeOf(FDCIC));
  State.Field(FIRQ, SizeOf(FIRQ));
  State.Field(FMulDivReady, SizeOf(FMulDivReady));
  State.Field(FGTEReady, SizeOf(FGTEReady));
  State.Field(FWriteDone, SizeOf(FWriteDone));
  State.Field(FICacheTag, SizeOf(FICacheTag));
  State.Field(FICacheData, SizeOf(FICacheData));
  if State.Loading then
  begin
    if (FLoadReg < 0) or (FLoadReg > 31) then
      raise EReadError.Create('PS1 snapshot CPU load slot');
    FRegs[0] := 0;
    FNewLoadReg := 0;
    FWrittenReg := 0;
    FInDelay := False;
    UpdateStatus;
  end;
end;

end.

