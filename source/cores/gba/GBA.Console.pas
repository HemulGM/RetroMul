unit GBA.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Math, System.Hash,
  Core.InputConfig, Core.Emulation.Types, Core.Snapshots, HW.ARM, GBA.Firmware,
  GBA.Video, GBA.Sound, GBA.Cartridge;

const
  GBA_CLOCK = 16777216;
  GBA_FRAME_CYCLES = 280896;

type
  TGBATimer = record
    Reload, Counter, Control: Word;
    Phase, StartDelay: Integer;
    PendingControl, PendingReload: Word;
    ReloadDelay: Integer;
  end;

  TGBADMA = record
    Source, Destination, InitialDestination: Cardinal;
    ReadLatch: Cardinal;
    Count: Integer;
    Control: Word;
    Pending, Sequential, SoundTransfer: Boolean;
    ReadyAt: UInt64;
    Remaining, Width: Integer;
  end;

  PGBATimer = ^TGBATimer;

  PGBADMA = ^TGBADMA;

  TGBACPUAccess = record
    Address, Value: Cardinal;
    Size: Integer;
    Kind: Byte;
    IRQSample: Boolean;
    Reserved: Word; // Explicit zero padding; the v6 snapshot layout stays unchanged.
  end;

  PGBACPUAccess = ^TGBACPUAccess;

  TGBAConsole = class
  private
    FCPU: TARMProcessor;
    FVideo: TGBAVideo;
    FSound: TGBASound;
    FCartridge: TGBACartridge;
    FTimers: array[0..3] of TGBATimer;
    FTimerPendingCycles: Integer;
    FTimerEventCycles: Integer; // Derived distance to the next timer edge/write.
    FTimerWorkMask: Byte; // Enabled timers or pending control/reload writes.
    FDMA: array[0..3] of TGBADMA;
    FNextDMAReady: UInt64; // Derived minimum of pending channel deadlines.
    FFrameNumber, FFrameTarget, FMasterClock: UInt64;
    FIRQDue: array[0..13] of UInt64;
    FNextIRQDue: UInt64; // Derived cache; rebuilt from FIRQDue on snapshot load.
    FIRQLevel, FIRQRequested, FClockBus, FBusSequential, FBusCode, FHLE: Boolean;
    FIRQSample: Boolean;
    FHaltIRQ, FHaltIRQRequested: Boolean;
    FHaltIRQDelay: Integer;
    FIRQPipeline: Byte;
    FCPUCheckpoint: TARMCheckpoint;
    FCPUCheckpointGeneration: UInt64;
    FCPUAccesses: array[0..63] of TGBACPUAccess;
    FCPUAccessCount, FCPUAccessPosition: Integer;
    FCPUResuming, FBusLocked, FCPUSequenceBroken: Boolean;
    FCPUYieldIdle: Boolean;
    FParallelIRQ: array[0..7] of Byte;
    FParallelCount, FParallelPosition: Integer;
    FIRQDelay: Integer;
    FIRQReadLatch: Word;
    FIRQReadDelay: Integer;
    FVideoCaptureArmed: Boolean;
    FDMAReadLatch: Cardinal;
    FActiveDMA: Integer;
    FSerialStart, FSerialEnd: UInt64;
    FSerialActive: Boolean;
    FWaitControl: Cardinal; // Derived decode; checked against IO, never serialized.
    FWaitFirst, FWaitSequential: array[0..2] of Integer;
    FWaitSave: Integer;
    FPrefetchAddress, FPrefetchNext: Cardinal;
    FPrefetchCount, FPrefetchPhase: Integer;
    FPrefetchValid, FGamePakBusy: Boolean;
    FRenderedX, FStopFrameCycles: Integer;
    FLine, FLineCycle, FAccessCycles, FExtraCycles, FWaitMask: Integer;
    FVideoPendingCycles: Integer; // Derived clocks; materialized before a PPU observation.
    FLastAddress, FOpenBus, FProtectedBIOS, FWaitPC: Cardinal;
    FInput: TEmulatorButtons;
    FPadEnabled, FHalted, FStopped, FInDMA, FRealBIOS, FFrameBoundaryActive, FExtraInDMA: Boolean;
    // Keep bus/scheduler fields at short ARM64 offsets. Memory is serialized
    // field by field, so moving these arrays does not change snapshot v6.
    FEWRAM: array[0..$3FFFF] of Byte;
    FIWRAM: array[0..$7FFF] of Byte;
    FBIOS: array[0..$3FFF] of Byte;
    function ReadByteRaw(Address: Cardinal): Byte;
    function ReadBusInternal(Address: Cardinal; Size: Integer; RotateValue: Boolean): Cardinal;
    procedure WriteByteRaw(Address: Cardinal; Value: Byte);
    function ReadIO(Offset: Integer): Byte;
    procedure WriteIO(Offset: Integer; Value: Byte);
    procedure Access(Address: Cardinal; Size: Integer);
    procedure IRQ(Bit: Integer; Delay: Integer = 0);
    procedure UpdateIRQ;
    procedure BusState(Sequential, Code: Boolean);
    procedure Idle(Cycles: Integer);
    function SampleIRQ: Boolean;
    procedure LockBus(Locked: Boolean);
    procedure CheckDMAStart(IdleCycle: Boolean = False);
    procedure RecordCPUAccess(Address, Value: Cardinal; Size: Integer; Kind: Byte); inline;
    function CPURead(Address: Cardinal; Size: Integer): Cardinal;
    function CPUReadUnrotated(Address: Cardinal; Size: Integer): Cardinal;
    function CPUReadInternal(Address: Cardinal; Size: Integer; Kind: Byte): Cardinal;
    procedure CPUWrite(Address, Value: Cardinal; Size: Integer);
    procedure ExecuteCPU;
    procedure ExecuteSWI(Number: Byte);
    procedure UpdateDMADeadline;
    function ServiceDMA: Boolean;
    procedure RenderUntil;
    procedure FlushVideo; inline;
    procedure StepInternal;
    procedure TickSleep;
    function WaitControl: Word; inline;
    procedure DecodeWaitControl(Value: Word);
    procedure PrefetchTick(Cycles: Integer);
    procedure DMA(Timing: Integer; FIFO: Integer = -1);
    procedure UpdateTimerDeadline;
    procedure FlushTimers;
    procedure AdvanceTimers(N: Integer; OldClock: UInt64);
    procedure Tick(Cycles: Integer); inline;
    procedure TickEvents(Cycles: Integer);
    procedure SoftwareInterrupt(Number: Byte);
    function IsEEPROM(Address: Cardinal): Boolean; inline;
    procedure InstallHLEBIOS;
  public
    constructor Create(const Data: TBytes; const BIOS: TBytes = nil; LegacyHLE: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame;
    procedure Step;
    function ReadBus(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBus(Address, Value: Cardinal; Size: Integer);
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    procedure SetInput(const Input: TEmulatorButtons);
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    procedure MarkBatteryDirty;
    function GetBatteryDirty: Boolean;
    function GetPixels: TArray<TAlphaColor>;
    function GetSamples: TArray<SmallInt>;
    function GetSampleFrames: Integer;
    function FramesPerSecond: Double;
    procedure SerializeState(State: TStateArchive);
    property CPU: TARMProcessor read FCPU;
    property Video: TGBAVideo read FVideo;
    property Sound: TGBASound read FSound;
    property Cartridge: TGBACartridge read FCartridge;
    property MasterClock: UInt64 read FMasterClock;
    property FrameNumber: UInt64 read FFrameNumber;
    property BatteryDirty: Boolean read GetBatteryDirty;
    property Pixels: TArray<TAlphaColor> read GetPixels;
    property Samples: TArray<SmallInt> read GetSamples;
    property SampleFrames: Integer read GetSampleFrames;
    function Width: Integer;
    function Height: Integer;
  end;

implementation

uses
  GBA.Peripherals; // Required for cross-unit expansion of cartridge/IRQ helpers.

type
  EGBABusYield = class(Exception);

constructor TGBAConsole.Create(const Data, BIOS: TBytes; LegacyHLE: Boolean);
begin
  inherited Create;
  FCartridge := TGBACartridge.Create(Data);
  FVideo := TGBAVideo.Create;
  FVideo.Clocked := not LegacyHLE;
  FSound := TGBASound.Create;
  FCPU := TARMProcessor.Create(CPURead, CPUWrite);
  FCPU.MemoryReadUnrotated := CPUReadUnrotated;
  FCPU.BusState := BusState;
  FCPU.Idle := Idle;
  FCPU.IRQSample := SampleIRQ;
  FCPU.BusLock := LockBus;
  if Length(BIOS) > 0 then
  begin
    if Length(BIOS) <> SizeOf(FBIOS) then
      raise EReadError.Create('GBA BIOS must be exactly 16384 bytes');

    Move(BIOS[0], FBIOS[0], SizeOf(FBIOS));
    FRealBIOS := True;
  end
  else if LegacyHLE then
  begin
    InstallHLEBIOS;
    FCPU.SoftwareInterrupt := ExecuteSWI;
    FCPU.IRQSample := nil;
  end
  else
  begin
    var Builtin := LoadBuiltinGBABIOS;
    Move(Builtin[0], FBIOS[0], SizeOf(FBIOS));
  end;
  FPadEnabled := True;
  Reset;
end;

destructor TGBAConsole.Destroy;
begin
  FCPU.Free;
  FSound.Free;
  FVideo.Free;
  FCartridge.Free;
  inherited;
end;

procedure TGBAConsole.InstallHLEBIOS;

  procedure Put(Address: Integer; Value: Cardinal);
  begin
    for var i := 0 to 3 do
      FBIOS[Address + i] := Byte((Value shr (i * 8)) and 255);
  end;

begin
  FillChar(FBIOS, SizeOf(FBIOS), 0);
  Put($18, $EA000038); // B 0x100: IRQ trampoline, compatible with cartridge handlers.
  Put($100, $E92D500F); // STMFD sp!, {r0-r3,r12,lr}
  Put($104, $E59F0010); // LDR r0, [pc,#16] -> 0x11C
  Put($108, $E1A0E00F); // MOV lr,pc -> 0x110
  Put($10C, $E590F000); // LDR pc,[r0]
  Put($110, $E8BD500F); // LDMFD sp!,{r0-r3,r12,lr}
  Put($114, $E25EF004); // SUBS pc,lr,#4
  Put($11C, $03007FFC);
  Put($130, $E12FFF1E); // default handler: BX lr
end;

procedure TGBAConsole.Reset;
begin
  FWaitControl := $FFFFFFFF;
  FVideoPendingCycles := 0;
  FillChar(FEWRAM, SizeOf(FEWRAM), 0);
  FillChar(FIWRAM, SizeOf(FIWRAM), 0);
  FillChar(FTimers, SizeOf(FTimers), 0);
  FTimerWorkMask := 0;
  FTimerEventCycles := 0;
  FTimerPendingCycles := 0;
  FillChar(FDMA, SizeOf(FDMA), 0);
  FNextDMAReady := 0;
  FCPU.Reset;
  FVideo.Reset;
  FSound.Reset;
  FCartridge.Reset;
  FFrameNumber := 0;
  FFrameTarget := 0;
  FFrameBoundaryActive := False;

  // Power-on starts in the last part of VBlank, as on the GBA LCD.
  FLine := 225;
  FLineCycle := 0;
  FAccessCycles := 0;
  FExtraCycles := 0;
  FExtraInDMA := False;
  FWaitMask := 0;
  FWaitPC := 0;
  FLastAddress := $FFFFFFFF;
  FOpenBus := 0;
  FProtectedBIOS := $E129F000;
  FHalted := False;
  FStopped := False;
  FInDMA := False;
  FStopFrameCycles := 0;
  FMasterClock := 0;
  FillChar(FIRQDue, SizeOf(FIRQDue), 0);
  FNextIRQDue := 0;
  FIRQDelay := 0;
  FIRQLevel := False;
  FIRQReadLatch := 0;
  FIRQReadDelay := 0;
  FVideoCaptureArmed := False;
  FIRQSample := False;
  FHaltIRQ := False;
  FHaltIRQRequested := False;
  FHaltIRQDelay := 0;
  FIRQPipeline := 0;
  FCPUResuming := False;
  FCPUAccessCount := 0;
  FCPUAccessPosition := 0;
  FillChar(FCPUCheckpoint, SizeOf(FCPUCheckpoint), 0);
  FillChar(FCPUAccesses, SizeOf(FCPUAccesses), 0);
  FBusLocked := False;
  FCPUSequenceBroken := False;
  FCPUYieldIdle := False;
  FParallelCount := 0;
  FParallelPosition := 0;
  FillChar(FParallelIRQ, SizeOf(FParallelIRQ), 0);
  FIRQRequested := False;
  FClockBus := False;
  FHLE := False;
  FBusSequential := False;
  FBusCode := False;
  FDMAReadLatch := 0;
  FActiveDMA := 0;
  FSerialStart := 0;
  FSerialEnd := 0;
  FSerialActive := False;
  FPrefetchValid := False;
  FPrefetchCount := 0;
  FPrefetchPhase := 0;
  FGamePakBusy := False;
  FRenderedX := 0;
  FVideo.SetReg16($130, $3FF);
  FVideo.SetReg16(6, FLine);
  FVideo.IO[4] := 1;
  if not FRealBIOS then
  begin
    // emibios 0.1.6 calibrates cartridge handoff to cycle 76001675.
    // With the power-on LCD at line 225 that is line 126, dot-cycle 827.
    // Skipping boot must preserve this phase, not the power-on VBlank phase.
    FLine := 126;
    FLineCycle := 827;
    FVideo.SetReg16(6, FLine);
    FVideo.IO[4] := 0;
    FRenderedX := EnsureRange((FLineCycle - 46) div 4, 0, 240);
    FSound.Write($89, 2);
    FVideo.SetReg16($88, $200);
    FVideo.IO[$300] := 1;
    FVideo.SetReg16($134, $8000); // RCNT: GPIO mode after the BIOS boot.
  end;
  if not FRealBIOS then
  begin
    FVideo.SetReg16($20, $100);
    FVideo.SetReg16($26, $100);
    FVideo.SetReg16($30, $100);
    FVideo.SetReg16($36, $100);
    FCPU.SetStatus($D2);
    FCPU.R[13] := $03007FA0;
    FCPU.SetStatus($D3);
    FCPU.R[13] := $03007FE0;
    FCPU.SetStatus($1F);
    FCPU.R[13] := $03007F00;
    FCPU.R[15] := $08000000;
    if Assigned(FCPU.SoftwareInterrupt) then
      WriteBus($03007FFC, $130, 4);
  end;
  FAccessCycles := 0;
  FVideo.BeginScanline(FLine);
end;

function TGBAConsole.IsEEPROM(Address: Cardinal): Boolean;
begin
  Result := (FCartridge.SaveKind = TGBASaveKind.EEPROM) and (Address shr 24 = $0D) and
    ((Length(FCartridge.Data) <= 16 * 1024 * 1024) or (Address and $FFFFFF >= $FFFF00));
end;

procedure TGBAConsole.BusState(Sequential, Code: Boolean);
begin
  FBusSequential := Sequential and not FCPUSequenceBroken;
  FBusCode := Code;
end;

procedure TGBAConsole.Idle(Cycles: Integer);
begin
  FBusCode := False;
  FBusSequential := False;
  for var i := 1 to Cycles do
  begin
    if FCPUAccessPosition < FCPUAccessCount then
    begin
      if FCPUAccesses[FCPUAccessPosition].Kind <> 3 then
        raise EInvalidOp.Create('GBA CPU idle replay diverged');

      FIRQSample := FCPUAccesses[FCPUAccessPosition].IRQSample;
      Inc(FCPUAccessPosition);
      Continue;
    end;

    CheckDMAStart(True);
    if FParallelPosition < FParallelCount then
    begin
      // CPU internal cycles can overlap DMA, unlike a read or write.
      // Advance its IRQ synchronizer using the original DMA clock history.
      FIRQPipeline := ((FIRQPipeline shl 1) or FParallelIRQ[FParallelPosition]) and 7;
      FIRQLevel := FIRQPipeline and 4 <> 0;
      Inc(FParallelPosition);
      FIRQDelay := 0;
      if FIRQPipeline <> Ord(FIRQRequested) * 7 then
        FIRQDelay := 3;
    end
    else
      Tick(1);
    FIRQSample := FIRQLevel;
    RecordCPUAccess(0, 0, 1, 3);
  end;
end;

function TGBAConsole.SampleIRQ: Boolean;
begin
  Result := FIRQSample;
end;

procedure TGBAConsole.LockBus(Locked: Boolean);
begin
  FBusLocked := Locked;
end;

procedure TGBAConsole.CheckDMAStart(IdleCycle: Boolean);
begin
  if (FNextDMAReady = 0) or (FNextDMAReady > FMasterClock) or FBusLocked or Assigned(FCPU.SoftwareInterrupt) then
    Exit;

  for var i := 0 to 3 do
    if FDMA[i].Pending and (FDMA[i].ReadyAt <= FMasterClock) then
    begin
      FCPUYieldIdle := IdleCycle;
      FParallelCount := 0;
      FParallelPosition := 0;
      raise EGBABusYield.Create('GBA CPU bus suspended for DMA');
    end;
end;

procedure TGBAConsole.RecordCPUAccess(Address, Value: Cardinal; Size: Integer; Kind: Byte);
begin
  if FCPUAccessCount = Length(FCPUAccesses) then
    raise EInvalidOp.Create('GBA CPU instruction exceeds bus transaction capacity');

  var A: PGBACPUAccess := @FCPUAccesses[FCPUAccessCount];
  A.Reserved := 0;
  A.Address := Address;
  A.Value := Value;
  A.Size := Size;
  A.Kind := Kind;
  A.IRQSample := FIRQSample;
  Inc(FCPUAccessCount);
  Inc(FCPUAccessPosition);
end;

function TGBAConsole.CPURead(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := CPUReadInternal(Address, Size, 0);
end;

function TGBAConsole.CPUReadUnrotated(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := CPUReadInternal(Address, Size, 1);
end;

function TGBAConsole.CPUReadInternal(Address: Cardinal; Size: Integer; Kind: Byte): Cardinal;
begin
  if FCPUAccessPosition < FCPUAccessCount then
  begin
    var A: PGBACPUAccess := @FCPUAccesses[FCPUAccessPosition];
    if (A.Address <> Address) or (A.Size <> Size) or (A.Kind <> Kind) then
      raise EInvalidOp.Create('GBA CPU read replay diverged');

    FIRQSample := A.IRQSample;
    Inc(FCPUAccessPosition);
    Exit(A.Value);
  end;

  CheckDMAStart;
  Result := ReadBusInternal(Address, Size, Kind = 0);
  FCPUSequenceBroken := False;
  RecordCPUAccess(Address, Result, Size, Kind);
end;

procedure TGBAConsole.CPUWrite(Address, Value: Cardinal; Size: Integer);
begin
  if FCPUAccessPosition < FCPUAccessCount then
  begin
    var A: PGBACPUAccess := @FCPUAccesses[FCPUAccessPosition];
    if (A.Address <> Address) or (A.Size <> Size) or (A.Kind <> 2) or (A.Value <> Value) then
      raise EInvalidOp.Create('GBA CPU write replay diverged');

    FIRQSample := A.IRQSample;
    Inc(FCPUAccessPosition);
    Exit;
  end;

  CheckDMAStart;
  WriteBus(Address, Value, Size);
  FCPUSequenceBroken := False;
  RecordCPUAccess(Address, Value, Size, 2);
end;

procedure TGBAConsole.ExecuteCPU;
begin
  // Usually an instruction runs once. If DMA steals the bus, keep its
  // completed transactions and replay only CPU-local work after DMA ends.
  // Reads keep their original values; writes and device clocks run once.
  if FCPUResuming then
    FCPU.Restore(FCPUCheckpoint)
  else
  begin
    FCPU.CaptureCached(FCPUCheckpoint, FCPUCheckpointGeneration);
    FCPUAccessCount := 0;
    FCPUYieldIdle := False;
    FParallelCount := 0;
    FParallelPosition := 0;
  end;
  FCPUAccessPosition := 0;
  try
    FCPU.Step(FIRQLevel);
    FCPUResuming := False;
    FCPUAccessCount := 0;
    FCPUYieldIdle := False;
    FParallelCount := 0;
    FParallelPosition := 0;
  except
    on E: EGBABusYield do
      FCPUResuming := True;
  end;
end;

procedure TGBAConsole.ExecuteSWI(Number: Byte);
begin
  var Before := FAccessCycles;
  var Clocking := FClockBus;
  FClockBus := False;
  FHLE := True;
  try
    SoftwareInterrupt(Number);
  finally
    FHLE := False;
    FClockBus := Clocking;
    Inc(FExtraCycles, FAccessCycles - Before);
    FAccessCycles := Before;
  end;
end;

function TGBAConsole.WaitControl: Word;
begin
  Result := FVideo.Reg16($204);
  if FWaitControl <> Result then
    DecodeWaitControl(Result);
end;

procedure TGBAConsole.DecodeWaitControl(Value: Word);
const
  First: array[0..3] of Integer = (5, 4, 3, 9);
  Slow: array[0..2] of Integer = (3, 5, 9);
begin
  FWaitControl := Value;
  FWaitSave := First[Value and 3];
  for var Bank := 0 to 2 do
  begin
    FWaitFirst[Bank] := First[(Value shr (2 + Bank * 3)) and 3];
    FWaitSequential[Bank] := Slow[Bank];
    if Value and (1 shl (4 + Bank * 3)) <> 0 then
      FWaitSequential[Bank] := 2;
  end;
end;

procedure TGBAConsole.PrefetchTick(Cycles: Integer);
begin
  if not FPrefetchValid or FGamePakBusy or (WaitControl and $4000 = 0) then
    Exit;

  var Bank := Integer(((FPrefetchNext shr 24) - 8) div 2);
  if (Bank < 0) or (Bank > 2) then
  begin
    FPrefetchValid := False;
    Exit;
  end;

  var Period := FWaitSequential[Bank];
  Inc(FPrefetchPhase, Cycles);
  while (FPrefetchCount < 8) and (FPrefetchPhase >= Period) do
  begin
    Dec(FPrefetchPhase, Period);
    Inc(FPrefetchCount);
    FPrefetchNext := ARMAdd(FPrefetchNext, 2);
    if FPrefetchNext and $1FFFF = 0 then
    begin
      FPrefetchPhase := 0;
      Break;
    end;
  end;
  if FPrefetchCount = 8 then
    FPrefetchPhase := 0;
end;

procedure TGBAConsole.Access(Address: Cardinal; Size: Integer);
begin
  var Region := Address shr 24;
  var W: Word := 0;
  if Region and $F8 = 8 then
    W := WaitControl;
  var Prefetched := False;
  var Cost := 1;
  var CancelPenalty := 0;
  if (Region and $F8 = 8) and FPrefetchValid and (FPrefetchCount < 8) then
  begin
    var PrefetchBank := Integer(((FPrefetchNext shr 24) - 8) div 2);
    if ((PrefetchBank >= 0) and (PrefetchBank <= 2)) then
    begin
      var Period := FWaitSequential[PrefetchBank];
      if FPrefetchPhase = Period - 1 then
        CancelPenalty := 1;
    end;
  end;
  if Region = 2 then
    Cost := 3 * (1 + Ord(Size = 4));
  if ((Region = 5) or (Region = 6)) then
    Cost := 1 + Ord(Size = 4);
  if ((Region >= 8) and (Region <= 13)) then
  begin
    var Bank := (Region - 8) div 2;
    var N := FWaitFirst[Bank];
    var SeqCost := FWaitSequential[Bank];
    var Sequential := FBusSequential and (Address and $1FFFF <> 0);
    Cost := N;
    if Sequential then
      Cost := SeqCost;
    if Size = 4 then
      Inc(Cost, SeqCost);
    if FBusCode and not FInDMA and (W and $4000 <> 0) then
    begin
      var Words := 1 + Ord(Size = 4);
      if FPrefetchValid and (Address = FPrefetchAddress) then
      begin
        var Available := Min(Words, FPrefetchCount);
        Dec(FPrefetchCount, Available);
        if Available = Words then
        begin
          Cost := 1;
          Prefetched := True;
        end
        else
        begin
          // A CPU data access breaks CPU bus sequencing, but an already
          // running prefetch stream still finishes its sequential ROM read.
          Cost := Max(1, SeqCost - FPrefetchPhase) + (Words - Available - 1) * SeqCost;
          FPrefetchPhase := 0;
        end;
      end
      else
      begin
        Inc(Cost, CancelPenalty);
        FPrefetchCount := 0;
        FPrefetchPhase := 0;
      end;
      FPrefetchAddress := ARMAdd(Address, Size);
      if FPrefetchCount = 0 then
        FPrefetchNext := FPrefetchAddress;
      FPrefetchValid := True;
    end
    else
    begin
      Inc(Cost, CancelPenalty);
      FPrefetchValid := False;
      FPrefetchCount := 0;
      FPrefetchPhase := 0;
    end;
  end;
  if (Region shr 1 = 7) then
  begin
    Cost := FWaitSave + CancelPenalty;
    FPrefetchValid := False;
  end;
  FLastAddress := ARMAdd(Address, Size);
  if FClockBus then
  begin
    FGamePakBusy := ((Region and $F8 = 8)) and not Prefetched;
    try
      Tick(1);
      if not FInDMA then
        FIRQSample := FIRQLevel;
      if FVideo.Clocked and (((Region >= 5) and (Region <= 7))) then
      begin
        // Each halfword competes with the PPU for its own memory port.
        for var Beat := 1 to Cost do
        begin
          if Beat > 1 then
            Tick(1);
          FlushVideo;
          while FVideo.MemoryBusy(Address) do
          begin
            if FFrameBoundaryActive and (FFrameNumber >= FFrameTarget) then
              Break;

            Tick(1);
            FlushVideo;
          end;
        end;
      end
      else if Cost > 1 then
        Tick(Cost - 1);
    finally
      FGamePakBusy := False;
    end;
  end
  else if FHLE then
    Inc(FAccessCycles, Cost);
end;

procedure TGBAConsole.FlushVideo;
begin
  if FVideoPendingCycles = 0 then
    Exit;

  // No PPU register or memory can change while these clocks are pending.
  // Execute the same per-clock fetch/OBJ/merger path as a contiguous slice.
  FVideo.RunCycles(FLine, FLineCycle - FVideoPendingCycles + 1, FLineCycle);
  FVideoPendingCycles := 0;
end;

procedure TGBAConsole.RenderUntil;
begin
  FlushVideo;
  if FVideo.Clocked then
    Exit;

  if FLine >= 160 then
    Exit;

  var Last := EnsureRange((FLineCycle - 46) div 4, 0, 240);
  if Last > FRenderedX then
  begin
    FVideo.RenderLine(FLine, FRenderedX, Last - 1);
    FRenderedX := Last;
  end;
end;

function TGBAConsole.ReadByteRaw(Address: Cardinal): Byte;
begin
  case Address shr 24 of
    0:
      begin
        if Address >= $4000 then
          Exit(Byte((FOpenBus shr ((Address and 3) * 8)) and 255));

        if FCPU.R[15] < $4000 then
          Result := FBIOS[Address]
        else
          Result := Byte((FProtectedBIOS shr ((Address and 3) * 8)) and 255);
      end;
    2:
      Result := FEWRAM[Address and $3FFFF];
    3:
      Result := FIWRAM[Address and $7FFF];
    4:
      if Address and $FFFFFF < $400 then
        Result := ReadIO(Address and $3FF)
      else
        Result := Byte((FOpenBus shr ((Address and 3) * 8)) and 255);
    5:
      Result := FVideo.Palette[Address and $3FF];
    6:
      begin
        var A := Address and $1FFFF;
        if (A >= $18000) and (A < $1C000) and (FVideo.Reg16(0) and 7 >= 3) then
          Exit(0);

        if A >= $18000 then
          Dec(A, $8000);
        Result := FVideo.VRAM[A];
      end;
    7:
      Result := FVideo.OAM[Address and $3FF];
    8..13:
      Result := FCartridge.ReadROM(Address);
    14, 15:
      Result := FCartridge.ReadSave(Address);
  else
    Result := Byte((FOpenBus shr ((Address and 3) * 8)) and 255);
  end;
end;

function TGBAConsole.ReadBus(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := ReadBusInternal(Address, Size, True);
end;

function TGBAConsole.ReadBusInternal(Address: Cardinal; Size: Integer; RotateValue: Boolean): Cardinal;
begin
  Access(Address, Size);
  if (Address and $FC000000 = $04000000) then
    FlushVideo;
  if FInDMA and ((Address < $02000000) or (Address shr 24 >= $10)) then
  begin
    Result := FDMA[FActiveDMA].ReadLatch;
    if Size = 2 then
      Result := Result and $FFFF;
    Exit;
  end;

  if IsEEPROM(Address) then
    Exit(FCartridge.ReadEEPROM);

  if Address shr 24 in [14, 15] then
  begin
    var B := FCartridge.ReadSave(Address);
    Result := B;
    if Size >= 2 then
      Result := Result or (Cardinal(B) shl 8);
    if Size = 4 then
      Result := Result or (Result shl 16);
    if RotateValue and (Size = 2) and (Address and 1 <> 0) then
      Result := (Result shr 8) or (Result shl 24);
    Exit;
  end;

  var Base := Address and not Cardinal(Size - 1);

  // Aligned RAM/BIOS transactions cannot cross a mirror boundary.
  // Read them at bus width after charging the unchanged bus timing above.
  // Device reads retain their per-byte side effects in the fallback paths.
  case Base shr 24 of
    0:
      if (Base < $4000) and (FCPU.R[15] < $4000) then
      begin
        case Size of
          1:
            Result := FBIOS[Base];
          2:
            Result := PWord(@FBIOS[Base])^;
          4:
            Result := PCardinal(@FBIOS[Base])^;
        else
          Result := 0;
        end;
      end
      else
      begin
        Result := 0;
        for var i := 0 to Size - 1 do
          Result := Result or (Cardinal(ReadByteRaw(ARMAdd(Base, i))) shl (i * 8));
      end;
    2:
      case Size of
        1:
          Result := FEWRAM[Base and $3FFFF];
        2:
          Result := PWord(@FEWRAM[Base and $3FFFF])^;
        4:
          Result := PCardinal(@FEWRAM[Base and $3FFFF])^;
      else
        Result := 0;
      end;
    3:
      case Size of
        1:
          Result := FIWRAM[Base and $7FFF];
        2:
          Result := PWord(@FIWRAM[Base and $7FFF])^;
        4:
          Result := PCardinal(@FIWRAM[Base and $7FFF])^;
      else
        Result := 0;
      end;
    8..13:
      Result := FCartridge.ReadROMBus(Base, Size);
  else
    Result := 0;
    for var i := 0 to Size - 1 do
      Result := Result or (Cardinal(ReadByteRaw(ARMAdd(Base, i))) shl (i * 8));
  end;
  if RotateValue and (Size = 4) and (Address and 3 <> 0) then
  begin
    var Shift := Integer(Address and 3) * 8;
    Result := (Result shr Shift) or (Result shl (32 - Shift));
  end;
  if RotateValue and (Size = 2) and (Address and 1 <> 0) then
    Result := (Result shr 8) or (Result shl 24);
  if (Base < $4000) and (FCPU.R[15] < $4000) and (Size = 4) then
    FProtectedBIOS := Result;
  if Size = 4 then
    FOpenBus := Result
  else if Size = 2 then
    FOpenBus := Result or (Result shl 16);
end;

procedure TGBAConsole.WriteByteRaw(Address: Cardinal; Value: Byte);
begin
  case Address shr 24 of
    2:
      FEWRAM[Address and $3FFFF] := Value;
    3:
      FIWRAM[Address and $7FFF] := Value;
    4:
      if Address and $FFFFFF < $400 then
        WriteIO(Address and $3FF, Value);
    5:
      FVideo.Palette[Address and $3FF] := Value;
    6:
      begin
        var A := Address and $1FFFF;
        if (A >= $18000) and (A < $1C000) and (FVideo.Reg16(0) and 7 >= 3) then
          Exit;

        if A >= $18000 then
          Dec(A, $8000);
        FVideo.VRAM[A] := Value;
      end;
    7:
      FVideo.OAM[Address and $3FF] := Value;
    8..13:
      FCartridge.WriteROM(Address, Value);
    14, 15:
      FCartridge.WriteSave(Address, Value);
  end;
end;

procedure TGBAConsole.WriteBus(Address, Value: Cardinal; Size: Integer);
begin
  Access(Address, Size);
  if Address = $FFFFFFFF then
  begin
    FOpenBus := Value;
    Exit;
  end;

  if (Address and $FC000000 = $04000000) then
    RenderUntil;

  if (Address shr 24 = 4) and (Address and $FFFFFF >= $A0) and (Address and $FFFFFF < $A8) then
  begin
    FSound.WriteFIFO(Integer(Address and $FF) and not (Size - 1), Value, Size);
    Exit;
  end;

  if IsEEPROM(Address) then
  begin
    FCartridge.WriteEEPROM(Byte(Value and 1));
    Exit;
  end;

  if Address shr 24 in [14, 15] then
  begin
    FCartridge.WriteSave(Address, Byte((Value shr ((Address and Cardinal(Size - 1)) * 8)) and 255));
    Exit;
  end;

  if (Size = 1) and (Address shr 24 in [5, 6, 7]) then
  begin
    if Address shr 24 = 7 then
      Exit;

    if (Address shr 24 = 6) and ((Address and $1FFFF) >= Cardinal($10000 + Ord(FVideo.Reg16(0) and 7 >= 3) * $4000)) then
      Exit;

    Address := Address and $FFFFFFFE;
    Value := (Value and 255) * $101;
    Size := 2;
  end;
  Address := Address and not Cardinal(Size - 1);

  // The bus transaction and byte-write replication have already completed.
  // Aligned memory writes cannot straddle a mirror or bitmap VRAM hole.
  var Target: PByte := nil;
  case Address shr 24 of
    2:
      Target := @FEWRAM[Address and $3FFFF];
    3:
      Target := @FIWRAM[Address and $7FFF];
    5:
      Target := @FVideo.Palette[Address and $3FF];
    6:
      begin
        var A := Address and $1FFFF;
        if (A >= $18000) and (A < $1C000) and (FVideo.Reg16(0) and 7 >= 3) then
          Exit;

        if A >= $18000 then
          Dec(A, $8000);
        Target := @FVideo.VRAM[A];
      end;
    7:
      Target := @FVideo.OAM[Address and $3FF];
  end;
  if Target <> nil then
    case Size of
      1:
        Target^ := Byte(Value and $FF);
      2:
        PWord(Target)^ := Word(Value and $FFFF);
      4:
        PCardinal(Target)^ := Value;
    end
  else
    for var i := 0 to Size - 1 do
      WriteByteRaw(ARMAdd(Address, i), Byte((Value shr (i * 8)) and 255));
end;

function TGBAConsole.ReadIO(Offset: Integer): Byte;
begin
  if (Offset >= $100) and (Offset < $110) then
    FlushTimers;
  Result := Byte((FOpenBus shr ((Offset and 3) * 8)) and 255);
  if (Offset >= $60) and (Offset <= $8B) or (Offset >= $90) and (Offset < $A0) then
    Exit(FSound.Read(Offset));

  if (Offset >= $B0) and (Offset < $E0) then
  begin
    case (Offset - $B0) mod 12 of
      8, 9:
        Exit(0);
      10, 11:
        Exit(FVideo.IO[Offset]);
    end;
    Exit;
  end;

  if (Offset >= $100) and (Offset < $110) then
  begin
    var i := (Offset - $100) div 4;
    case Offset and 3 of
      0, 1:
        Exit(Byte((FTimers[i].Counter shr ((Offset and 1) * 8)) and 255));
      2:
        Exit(FVideo.IO[Offset]);
      3:
        Exit(0);
    end;
  end;

  case Offset of
    $202, $203:
      begin
        // The readable interrupt register follows the source latch by a clock.
        if FClockBus then
          Exit(Byte((FIRQReadLatch shr ((Offset and 1) * 8)) and $FF));

        Exit(FVideo.IO[Offset]);
      end;
    4:
      begin
        // VCOUNT advances before the comparator latch, which takes one clock.
        var CompareLine := FLine;
        if FLineCycle = 0 then
          CompareLine := (FLine + 227) mod 228;
        Exit((FVideo.IO[4] and $38) or Byte(Ord((FLine >= 160) and (FLine < 227))) or
          Byte(Ord(FLineCycle >= 1007) * 2) or Byte(Ord(CompareLine = FVideo.IO[5]) * 4));
      end;
    $00..$03, $05..$0F, $48..$4B, $50..$53, $120..$12B, $130..$135, $140..$141, $150..$158, $200..$201, $204..$205, $208, $300:
      Exit(FVideo.IO[Offset]);
    $136..$137, $142..$143, $15A..$15B, $206..$207, $209..$20B, $301..$303:
      Exit(0);
  end;
end;

procedure TGBAConsole.WriteIO(Offset: Integer; Value: Byte);
begin
  if (Offset >= $100) and (Offset < $110) then
    FlushTimers;
  if (Offset = 6) or (Offset = 7) or (Offset = $130) or (Offset = $131) then
    Exit;

  case Offset of
    2:
      Value := Value and 1;
    3, $206, $207, $209..$20B, $302, $303:
      Exit;
    4:
      Value := (Value and $38) or (FVideo.IO[4] and 7);
    $09, $0B:
      Value := Value and $DF;
    $48..$4B, $51:
      Value := Value and $3F;
    $52, $53, $54:
      Value := Value and $1F;
    $55:
      Exit;
    $133:
      Value := Value and $C3;
    $201, $203:
      Value := Value and $3F;
    $205:
      Value := Value and $7F;
    $208:
      Value := Value and 1;
    $300:
      begin
        if (FCPU.R[15] >= $4000) or (FVideo.IO[$300] <> 0) then
          Exit;
        Value := Value and 1;
      end;
  end;

  if (Offset >= $100) and (Offset < $110) then
    case Offset and 3 of
      2:
        begin
          Value := Value and $C7;
          if Offset = $102 then
            Value := Value and $FB;
        end;
      3:
        Exit;
    end;

  if (Offset >= $B0) and (Offset < $E0) then
  begin
    var i := (Offset - $B0) div 12;
    case (Offset - $B0) mod 12 of
      3:
        if i = 0 then
          Value := Value and 7
        else
          Value := Value and 15;
      7:
        if i < 3 then
          Value := Value and 7
        else
          Value := Value and 15;
      9:
        if i < 3 then
          Value := Value and $3F;
      10:
        Value := Value and $E0;
      11:
        if i < 3 then
          Value := Value and $F7;
    end;
  end;

  if (Offset = $202) or (Offset = $203) then
  begin
    FVideo.IO[Offset] := FVideo.IO[Offset] and not Value;
    UpdateIRQ;
    Exit;
  end;

  if Offset = $301 then
  begin
    if FCPU.R[15] < $4000 then
    begin
      FHalted := True;
      FStopped := Value and $80 <> 0;
    end;
    Exit;
  end;

  var Old := FVideo.IO[Offset];
  FVideo.IO[Offset] := Value;
  if (Offset = 5) and (Old <> Value) and (FLine = Value) and (FVideo.IO[4] and $20 <> 0) then
    IRQ(2, 2);
  if Offset < $40 then
    FVideo.ReloadAffine(Offset);
  if ((Offset = $200) or (Offset = $201) or (Offset = $208)) then
    UpdateIRQ;
  if ((Offset = $204) or (Offset = $205)) then
  begin
    FPrefetchValid := False;
    FPrefetchCount := 0;
    FPrefetchPhase := 0;
  end;
  if Offset = $135 then
  begin
    FVideo.IO[Offset] := Value and $C1;
    if Value and $80 <> 0 then
      FSerialActive := False;
  end;
  if ((Offset = $128) or (Offset = $129)) then
  begin
    var Control := FVideo.Reg16($128);
    var Mode := (Control shr 12) and 3;
    var WasActive := FSerialActive;
    FSerialActive := (FVideo.Reg16($134) and $8000 = 0) and (Control and $80 <> 0) and
      (Mode in [0, 1]) and (Control and 1 <> 0);

    // With no cable, multiplayer has no parent's clock/readiness handshake.
    // Leave it waiting instead of manufacturing a successful completion/IRQ.
    if (Mode = 2) and (Control and $80 <> 0) then
      for var i := $120 to $127 do
        FVideo.IO[i] := $FF;
    if FSerialActive and not WasActive then
      FSerialStart := FMasterClock;

    // Both bytes of a halfword write share a bus cycle. Finish applying its
    // parameters then; later writes (including IRQ enable) retain the clock.
    if FSerialActive and (FSerialStart = FMasterClock) then
    begin
      var Bits := 8;
      if Mode = 1 then
        Bits := 32;
      var Divider := 64;
      if Control and 2 <> 0 then
        Divider := 8;
      FSerialEnd := FSerialStart + UInt64(Bits * Divider + 6);
    end;
  end;
  if (Offset >= $60) and (Offset < $A8) then
    FSound.Write(Offset, Value);
  if (Offset >= $100) and (Offset < $110) then
  begin
    var i := (Offset - $100) div 4;
    case Offset and 3 of
      0, 1:
        begin
          FTimers[i].PendingReload := FVideo.Reg16($100 + i * 4);
          FTimers[i].ReloadDelay := 1;
          FTimerWorkMask := FTimerWorkMask or (1 shl i);
          FTimerEventCycles := 0;
          FTimerPendingCycles := 0;
        end;
      2:
        begin
          FTimers[i].PendingControl := Value and $C7;
          FTimers[i].StartDelay := 1;
          if (FTimers[i].Control and $80 = 0) and (Value and $80 <> 0) then
            FTimers[i].StartDelay := 2;
          FTimerWorkMask := FTimerWorkMask or (1 shl i);
          FTimerEventCycles := 0;
          FTimerPendingCycles := 0;
        end;
    end;
  end;

  if (Offset >= $B0) and (Offset < $E0) and ((Offset - $B0) mod 12 = 11) and (Old and $80 = 0) and (Value and $80 <> 0) then
  begin
    var i := (Offset - $B0) div 12;
    var B := $B0 + i * 12;
    FDMA[i].Source := Cardinal(FVideo.Reg16(B)) or (Cardinal(FVideo.Reg16(B + 2)) shl 16);
    FDMA[i].Destination := Cardinal(FVideo.Reg16(B + 4)) or (Cardinal(FVideo.Reg16(B + 6)) shl 16);
    FDMA[i].Source := FDMA[i].Source and $0FFFFFFF;
    if i = 0 then
      FDMA[i].Source := FDMA[i].Source and $07FFFFFF;
    FDMA[i].Destination := FDMA[i].Destination and $0FFFFFFF;
    if i < 3 then
      FDMA[i].Destination := FDMA[i].Destination and $07FFFFFF;
    FDMA[i].InitialDestination := FDMA[i].Destination;
    FDMA[i].Count := FVideo.Reg16(B + 8);
    if i < 3 then
      FDMA[i].Count := FDMA[i].Count and $3FFF;
    if FDMA[i].Count = 0 then
      if i = 3 then
        FDMA[i].Count := $10000
      else
        FDMA[i].Count := $4000;
    FDMA[i].Control := FVideo.Reg16(B + 10);
    FDMA[i].Pending := False;
    UpdateDMADeadline;
    if FDMA[i].Control and $3000 = 0 then
      DMA(0);
  end;

  if (Offset >= $B0) and (Offset < $E0) and ((Offset - $B0) mod 12 = 11) and (Value and $80 = 0) then
  begin
    var i := (Offset - $B0) div 12;
    FDMA[i].Control := FDMA[i].Control and $7FFF;
    FDMA[i].Pending := False;
    UpdateDMADeadline;
  end;
  if (Offset = $132) or (Offset = $133) then
    SetInput(FInput);
end;

procedure TGBAConsole.UpdateIRQ;
begin
  if FIRQReadLatch <> FVideo.Reg16($202) then
    FIRQReadDelay := 1;

  var Pending := FVideo.Reg16($200) and FVideo.Reg16($202) <> 0;
  if Pending <> FHaltIRQRequested then
  begin
    FHaltIRQRequested := Pending;
    FHaltIRQDelay := 2;
  end;
  var Requested := Pending and (FVideo.Reg16($208) and 1 <> 0);
  if Requested <> FIRQRequested then
  begin
    FIRQRequested := Requested;
    FIRQDelay := 3;
  end;
end;

procedure TGBAConsole.IRQ(Bit: Integer; Delay: Integer);
begin
  if Delay > 0 then
  begin
    if FIRQDue[Bit] = 0 then
      FIRQDue[Bit] := FMasterClock + UInt64(Delay);
    if (FNextIRQDue = 0) or (FIRQDue[Bit] < FNextIRQDue) then
      FNextIRQDue := FIRQDue[Bit];
  end
  else
  begin
    FVideo.SetReg16($202, FVideo.Reg16($202) or (1 shl Bit));
    UpdateIRQ;
  end;
end;

procedure TGBAConsole.DMA(Timing: Integer; FIFO: Integer);
begin
  for var i := 0 to 3 do
  begin
    var D: PGBADMA := @FDMA[i];
    var C := D.Control;
    if (C and $8000 = 0) or (D.Pending) or ((C shr 12) and 3 <> Timing) then
      Continue;

    var SoundDMA := (Timing = 3) and (i in [1, 2]) and (FIFO >= 0);
    var Capture := (Timing = 3) and (i = 3) and (FIFO < 0) and FVideoCaptureArmed and (FLine in [2..161]);
    if Timing = 3 then
      if not Capture and (not SoundDMA or (D.Destination <> Cardinal($040000A0 + FIFO * 4))) then
        Continue;

    D.Pending := True;
    D.Sequential := False;
    D.SoundTransfer := SoundDMA;
    D.Remaining := D.Count;
    D.Width := 2;
    if C and $400 <> 0 then
      D.Width := 4;
    if SoundDMA then
    begin
      D.Remaining := 4;
      D.Width := 4;
    end;
    if (i = 3) and IsEEPROM(D.Destination) then
      FCartridge.BeginEEPROM(D.Remaining);
    var Delay := 3;
    if Timing = 0 then
      Delay := 2
    else if Timing = 1 then
      Delay := 2
    else if Capture then
      Delay := 5;
    D.ReadyAt := FMasterClock + UInt64(Delay);
    if (FNextDMAReady = 0) or (D.ReadyAt < FNextDMAReady) then
      FNextDMAReady := D.ReadyAt;
  end;
end;

procedure TGBAConsole.UpdateDMADeadline;
begin
  FNextDMAReady := 0;
  for var i := 0 to 3 do
    if FDMA[i].Pending and ((FNextDMAReady = 0) or (FDMA[i].ReadyAt < FNextDMAReady)) then
      FNextDMAReady := FDMA[i].ReadyAt;
end;

function TGBAConsole.ServiceDMA: Boolean;
begin
  Result := False;
  if (FNextDMAReady = 0) or (FNextDMAReady > FMasterClock) then
    Exit;

  for var i := 0 to 3 do
    if FDMA[i].Pending and (FDMA[i].ReadyAt <= FMasterClock) then
    begin
      Result := True;
      var D: PGBADMA := @FDMA[i];
      var C := D.Control;
      var Size := D.Width;
      FInDMA := True;
      FActiveDMA := i;
      FClockBus := True;
      FBusCode := False;
      FCPUSequenceBroken := True;
      try
        // Bus arbitration precedes the first DMA read. ROM prefetch may
        // finish during this idle cycle, before the DMA claims Game Pak.
        if not D.Sequential then
          Tick(1);
        FBusSequential := D.Sequential;
        var V := ReadBus(D.Source and not Cardinal(Size - 1), Size);
        if Size = 2 then
          V := (V and $FFFF) * $10001;
        FDMAReadLatch := V;

        // A forbidden source reuses the channel latch without changing it.
        // In particular a halfword read must not destroy its upper halfword.
        if (D.Source >= $02000000) and (D.Source shr 24 < $10) then
          D.ReadLatch := V;
        if Size = 2 then
          V := (V shr ((D.Destination and 2) * 8)) and $FFFF;
        FBusSequential := D.Sequential or (D.Source shr 24 in [8..13]);
        WriteBus(D.Destination and not Cardinal(Size - 1), V, Size);
        var SourceStep := Size;
        var DestStep := Size;
        case (C shr 7) and 3 of
          1:
            SourceStep := -Size;
          2:
            SourceStep := 0;
        end;

        // Game Pak DMA always steps forward, independent of the programmed source mode.
        if D.Source shr 24 in [8..13] then
          SourceStep := Size;
        case (C shr 5) and 3 of
          1:
            DestStep := -Size;
          2:
            DestStep := 0;
        end;
        if D.SoundTransfer then
          DestStep := 0;
        D.Source := Cardinal((Int64(D.Source) + SourceStep + $100000000) and $FFFFFFFF);
        D.Destination := Cardinal((Int64(D.Destination) + DestStep + $100000000) and $FFFFFFFF);
        D.Sequential := True;
        Dec(D.Remaining);
        if D.Remaining = 0 then
        begin
          D.Pending := False;
          UpdateDMADeadline;
          Tick(1);
          if C and $4000 <> 0 then
            IRQ(8 + i, 1);
          if (C and $200 <> 0) and (C and $3000 <> 0) and not ((i = 3) and (C and $3000 = $3000) and (FLine = 161)) then
          begin
            // The first count is latched on enable; repeat counts reload only
            // after the preceding transfer, so writes cannot alter that run.
            D.Count := FVideo.Reg16($B8 + i * 12);
            if i < 3 then
              D.Count := D.Count and $3FFF;
            if D.Count = 0 then
              if i = 3 then
                D.Count := $10000
              else
                D.Count := $4000;
            if C and $60 = $60 then
              D.Destination := Cardinal(FVideo.Reg16($B4 + i * 12)) or (Cardinal(FVideo.Reg16($B6 + i * 12)) shl 16);
          end
          else
          begin
            D.Control := C and $7FFF;
            FVideo.IO[$BB + i * 12] := FVideo.IO[$BB + i * 12] and $7F;
          end;
        end;
      finally
        FInDMA := False;
        FClockBus := False;
      end;
      Exit;
    end;
end;

procedure TGBAConsole.TickSleep;
begin
  // Host publications continue, but CPU, LCD, timers and APU keep their phase.
  if FStopFrameCycles = 0 then
  begin
    var P := FVideo.Pixels;
    for var i := 0 to High(P) do
      P[i] := $FFFFFFFF;
  end;
  var N := Min(32, GBA_FRAME_CYCLES - FStopFrameCycles);
  FCartridge.Tick(N);
  if FCartridge.Hardware.TakeIRQ then
    IRQ(13);
  Inc(FStopFrameCycles, N);
  if FStopFrameCycles = GBA_FRAME_CYCLES then
  begin
    FStopFrameCycles := 0;
    Inc(FFrameNumber);
  end;
end;

procedure TGBAConsole.UpdateTimerDeadline;
const
  Prescales: array[0..3] of Integer = (1, 64, 256, 1024);
begin
  FTimerEventCycles := MaxInt;
  for var i := 0 to 3 do
  begin
    if FTimerWorkMask and (1 shl i) = 0 then
      Continue;

    var T: PGBATimer := @FTimers[i];
    if T.StartDelay > 0 then
      FTimerEventCycles := Min(FTimerEventCycles, T.StartDelay);
    if T.ReloadDelay > 0 then
      FTimerEventCycles := Min(FTimerEventCycles, T.ReloadDelay);
    if (T.Control and $80 <> 0) and ((i = 0) or (T.Control and 4 = 0)) then
    begin
      var P := Prescales[T.Control and 3];
      FTimerEventCycles := Min(FTimerEventCycles, ($10000 - Integer(T.Counter)) * P -
        Integer((FMasterClock + UInt64(P - 1)) and UInt64(P - 1)));
    end;
  end;
end;

procedure TGBAConsole.FlushTimers;
const
  Masks: array[0..3] of Integer = (0, 63, 255, 1023);
  Shifts: array[0..3] of Integer = (0, 6, 8, 10);
begin
  if FTimerPendingCycles = 0 then
    Exit;

  // These clocks precede every overflow/control/reload event. Cascaded
  // timers cannot advance, and no IRQ or FIFO operation is deferred.
  for var i := 0 to 3 do
    if FTimerWorkMask and (1 shl i) <> 0 then
    begin
      var T: PGBATimer := @FTimers[i];
      if T.StartDelay > 0 then
        Dec(T.StartDelay, FTimerPendingCycles);
      if T.ReloadDelay > 0 then
        Dec(T.ReloadDelay, FTimerPendingCycles);
      if (i = 0) or (T.Control and 4 = 0) then
      begin
        var Mask := Masks[T.Control and 3];
        var Phase := Integer((FMasterClock - UInt64(FTimerPendingCycles) + UInt64(Mask)) and UInt64(Mask)) + FTimerPendingCycles;
        if T.Control and $80 <> 0 then
          T.Counter := Word(Integer(T.Counter) + (Phase shr Shifts[T.Control and 3]));
        T.Phase := Phase and Mask;
      end;
    end;
  FTimerPendingCycles := 0;
end;

procedure TGBAConsole.AdvanceTimers(N: Integer; OldClock: UInt64);
const
  Prescales: array[0..3] of Integer = (1, 64, 256, 1024);
  PrescaleShifts: array[0..3] of Integer = (0, 6, 8, 10);
begin
  var Cascades := 0;
  if FTimerWorkMask <> 0 then
    for var i := 0 to 3 do
    begin
      if FTimerWorkMask and (1 shl i) = 0 then
      begin
        Cascades := 0;
        Continue;
      end;

      var T: PGBATimer := @FTimers[i];
      var ApplyControl := False;
      if T.StartDelay > 0 then
      begin
        Dec(T.StartDelay, N);
        ApplyControl := T.StartDelay = 0;
      end;
      var Clocks := Cascades;
      if (i = 0) or (T.Control and 4 = 0) then
      begin
        var P := Prescales[T.Control and 3];

        // The free-running divider starts at phase -1 before the first bus
        // cycle. Use a positive offset to preserve that phase at clock zero.
        var Shift := PrescaleShifts[T.Control and 3];
        var Phase := Integer((OldClock + UInt64(P - 1)) and UInt64(P - 1)) + N;
        Clocks := Phase shr Shift;
        T.Phase := Phase and (P - 1);
      end;
      if T.Control and $80 = 0 then
        Clocks := 0;
      Cascades := 0;
      while Clocks > 0 do
      begin
        var Remaining := $10000 - Integer(T.Counter);
        if Clocks < Remaining then
        begin
          T.Counter := Word(Integer(T.Counter) + Clocks);
          Clocks := 0;
        end
        else
        begin
          Dec(Clocks, Remaining);
          T.Counter := T.Reload;
          Inc(Cascades);
          if T.Control and $40 <> 0 then
            IRQ(3 + i);
          if i < 2 then
          begin
            var Request := FSound.ClockFIFO(i);
            for var F := 0 to 1 do
              if Request and (1 shl F) <> 0 then
                DMA(3, F);
          end;
        end;
      end;

      if ApplyControl then
      begin
        if (T.Control and $80 = 0) and (T.PendingControl and $80 <> 0) then
        begin
          // On enable, the old counter gets one divider edge before the
          // reload latch replaces it. FFFF can therefore request an IRQ
          // even when the new reload value would not overflow yet.
          if (T.Counter = $FFFF) and ((i = 0) or (T.PendingControl and 4 = 0)) and
            ((FMasterClock + UInt64(Prescales[T.PendingControl and 3] - 1)) and
            UInt64(Prescales[T.PendingControl and 3] - 1) = 0) then
          begin
            Inc(Cascades);
            if T.PendingControl and $40 <> 0 then
              IRQ(3 + i);
            if i < 2 then
            begin
              var Request := FSound.ClockFIFO(i);
              for var F := 0 to 1 do
                if Request and (1 shl F) <> 0 then
                  DMA(3, F);
            end;
          end;
          T.Counter := T.Reload;
        end;
        T.Control := T.PendingControl;
        var P := Prescales[T.Control and 3];
        T.Phase := Integer((FMasterClock + UInt64(P - 1)) and UInt64(P - 1));
      end;

      // Register writes reach the reload latch after this cycle's overflow.
      // A simultaneous overflow still uses the preceding reload value.
      if T.ReloadDelay > 0 then
      begin
        Dec(T.ReloadDelay, N);
        if T.ReloadDelay = 0 then
          T.Reload := T.PendingReload;
      end;
      if (T.Control and $80 = 0) and (T.StartDelay = 0) and (T.ReloadDelay = 0) then
        FTimerWorkMask := FTimerWorkMask and not (1 shl i);
    end;
end;

procedure TGBAConsole.Tick(Cycles: Integer);
begin
  // A bus slice that ends before every scheduler edge needs no event walk.
  // Keep the full scheduler for IRQ synchronization, timer edges and DMA replay.
  if (Cycles > 0) and (Cycles < FTimerEventCycles) and
    (FIRQDelay = 0) and (FHaltIRQDelay = 0) and (FIRQReadDelay = 0) and
    (FNextIRQDue = 0) and not FSerialActive and
    not FCartridge.Hardware.HasRTC and not FCartridge.Hardware.IRQPending and
    (Cycles < 1232 - FLineCycle) and
    ((FLineCycle >= 1007) or (Cycles < 1006 - FLineCycle)) and
    not (FFrameBoundaryActive and (FFrameNumber >= FFrameTarget)) and
    not (FInDMA and FCPUResuming and FCPUYieldIdle and not FHalted) then
  begin
    FSound.Tick(Cycles);
    FCartridge.Tick(Cycles);
    PrefetchTick(Cycles);
    Inc(FMasterClock, Cycles);
    if FTimerWorkMask <> 0 then
    begin
      Dec(FTimerEventCycles, Cycles);
      Inc(FTimerPendingCycles, Cycles);
    end;
    Inc(FLineCycle, Cycles);
    Inc(FVideoPendingCycles, Cycles);
  end
  else
    TickEvents(Cycles);
end;

procedure TGBAConsole.TickEvents(Cycles: Integer);
begin
  // Bound event slices to preserve timer/FIFO ordering while a DMA blocks the CPU.
  while Cycles > 0 do
  begin
    // A single BIOS call or DMA may occupy several video frames. Preserve
    // its remaining clocks for the next publication instead of returning an
    // oversized PCM block and skipping video frames in RunFrame.
    if FFrameBoundaryActive and (FFrameNumber >= FFrameTarget) then
    begin
      Inc(FExtraCycles, Cycles);
      FExtraInDMA := FInDMA;
      Exit;
    end;

    var N := Min(Min(Cycles, 32), 1232 - FLineCycle);
    if FLineCycle < 1006 then
      N := Min(N, 1006 - FLineCycle)
    else if FLineCycle < 1007 then
      N := Min(N, 1007 - FLineCycle);
    if (FIRQDelay > 0) and (not FInDMA or FHalted) then
      N := Min(N, FIRQDelay);
    if (FHaltIRQDelay > 0) and (not FInDMA or FHalted) then
      N := Min(N, FHaltIRQDelay);
    if FNextIRQDue > 0 then
      N := Min(N, Max(1, Integer(FNextIRQDue - FMasterClock)));
    if FSerialActive then
      N := Min(N, Max(1, Integer(FSerialEnd - FMasterClock)));
    if FIRQReadDelay > 0 then
      N := Min(N, FIRQReadDelay);

    if FTimerWorkMask <> 0 then
    begin
      if FTimerEventCycles = 0 then
        UpdateTimerDeadline;
      N := Min(N, FTimerEventCycles);
      if N = FTimerEventCycles then
        FlushTimers;
      Dec(FTimerEventCycles, N);
    end;
    Dec(Cycles, N);
    if FInDMA and FCPUResuming and FCPUYieldIdle and not FHalted then
      for var i := 1 to Min(N, Length(FParallelIRQ) - FParallelCount) do
      begin
        FParallelIRQ[FParallelCount] := Ord(FIRQRequested);
        Inc(FParallelCount);
      end;

    FSound.Tick(N);
    FCartridge.Tick(N);
    PrefetchTick(N);
    var OldClock := FMasterClock;
    Inc(FMasterClock, N);
    if FIRQReadDelay > 0 then
    begin
      Dec(FIRQReadDelay, N);
      if FIRQReadDelay = 0 then
        FIRQReadLatch := FVideo.Reg16($202);
    end;
    if FCartridge.Hardware.TakeIRQ then
      IRQ(13);

    // DMA advances peripherals, but pauses the CPU IRQ synchronizer. A CPU
    // in HALT still observes the line while the bus is owned by DMA.
    if (FHaltIRQDelay > 0) and (not FInDMA or FHalted) then
    begin
      Dec(FHaltIRQDelay, N);
      if FHaltIRQDelay = 0 then
        FHaltIRQ := FHaltIRQRequested;
    end;
    if (FIRQDelay > 0) and (not FInDMA or FHalted) then
    begin
      FIRQPipeline := ((FIRQPipeline shl N) or ((1 shl N) - 1) * Ord(FIRQRequested)) and 7;
      FIRQLevel := FIRQPipeline and 4 <> 0;
      Dec(FIRQDelay, N);
    end;

    if (FNextIRQDue > 0) and (FNextIRQDue <= FMasterClock) then
    begin
      FNextIRQDue := 0;
      for var i := 0 to 13 do
        if FIRQDue[i] > 0 then
          if FIRQDue[i] <= FMasterClock then
          begin
            FIRQDue[i] := 0;
            IRQ(i);
          end
          else if (FNextIRQDue = 0) or (FIRQDue[i] < FNextIRQDue) then
            FNextIRQDue := FIRQDue[i];
    end;

    if FSerialActive and (FSerialEnd <= FMasterClock) then
    begin
      FSerialActive := False;
      FVideo.IO[$128] := FVideo.IO[$128] and $7F;
      var Mode := (FVideo.Reg16($128) shr 12) and 3;
      if Mode = 2 then
      begin
        FVideo.IO[$128] := FVideo.IO[$128] or $40; // No peer: multiplayer error.
        FVideo.SetReg16($120, FVideo.Reg16($12A));
        for var i := 1 to 3 do
          FVideo.SetReg16($120 + i * 2, $FFFF);
      end
      else if Mode = 0 then
        FVideo.IO[$12A] := $FF
      else
      begin
        FVideo.SetReg16($120, $FFFF);
        FVideo.SetReg16($122, $FFFF);
      end;
      if FVideo.IO[$129] and $40 <> 0 then
        IRQ(7);
    end;

    if FTimerWorkMask <> 0 then
      if FTimerEventCycles = 0 then
        AdvanceTimers(N, OldClock)
      else
        Inc(FTimerPendingCycles, N);

    Inc(FLineCycle, N);
    Inc(FVideoPendingCycles, N);
    if FLineCycle = 1006 then
    begin
      FlushVideo;
      if FLine < 160 then
      begin
        if not FVideo.Clocked then
          FVideo.RenderLine(FLine, FRenderedX, 239);
        FRenderedX := 240;
      end;
      FVideo.IO[4] := FVideo.IO[4] or 2; // Event latch; readable HBlank becomes visible at 1007.
      if FVideo.IO[4] and $10 <> 0 then
        IRQ(1, 2);
      if FLine < 160 then
        DMA(2);
    end;

    if FLineCycle >= 1232 then
    begin
      FlushVideo;
      Dec(FLineCycle, 1232);
      if FLine < 160 then
        FVideo.EndLine;
      Inc(FLine);
      FRenderedX := 0;
      if FLine = 228 then
      begin
        FLine := 0;
        Inc(FFrameNumber);
        FVideo.BeginFrame;
      end;
      FVideo.SetReg16(6, FLine);
      FVideo.BeginScanline(FLine);
      if FLine = 162 then
        FVideoCaptureArmed := FDMA[3].Control and $B000 = $B000;
      if (FLine >= 2) and (FLine <= 161) then
        DMA(3);
      FVideo.IO[4] := FVideo.IO[4] and $F8;
      if (FLine >= 160) and (FLine < 227) then
        FVideo.IO[4] := FVideo.IO[4] or 1;
      if FLine = FVideo.IO[5] then
      begin
        FVideo.IO[4] := FVideo.IO[4] or 4;
        if FVideo.IO[4] and $20 <> 0 then
          IRQ(2, 2);
      end;
      if FLine = 160 then
      begin
        if FVideo.IO[4] and 8 <> 0 then
          IRQ(0, 1);
        DMA(1);
        FVideo.BeginFrame;
      end;
    end;

    // HALT releases the CPU when an enabled source asserts, including in
    // the middle of an idle batch. Discard the unused sleep clocks.
    if FHalted and not FInDMA and FHaltIRQ then
      Exit;
  end;
end;

procedure TGBAConsole.StepInternal;
begin
  if FStopped then
  begin
    if FVideo.Reg16($200) and FVideo.Reg16($202) and $3080 = 0 then
    begin
      TickSleep;
      Exit;
    end;

    FStopped := False;
    FStopFrameCycles := 0;
  end;

  // DMA and deferred BIOS clocks must finish before another CPU instruction
  // or interrupt can execute. Tick may defer them again at a frame boundary.
  if FExtraCycles > 0 then
  begin
    var Extra := FExtraCycles;
    var DMAClocks := FExtraInDMA;
    FExtraCycles := 0;
    FExtraInDMA := False;
    FInDMA := DMAClocks;
    try
      Tick(Extra);
    finally
      FInDMA := False;
    end;
    Exit;
  end;

  if ServiceDMA then
    Exit;

  if FCPUResuming then
  begin
    FClockBus := True;
    try
      ExecuteCPU;
    finally
      FClockBus := False;
    end;
    Exit;
  end;

  // IntrWait returns only after a requested flag has been recorded by the
  // cartridge IRQ handler. Other enabled interrupts still run their handler.
  if (FWaitMask <> 0) and (FCPU.R[15] = FWaitPC) then
  begin
    var Flags := Word(FIWRAM[$7FF8]) or (Word(FIWRAM[$7FF9]) shl 8);
    if Flags and FWaitMask <> 0 then
    begin
      Flags := Flags and not Word(FWaitMask);
      FIWRAM[$7FF8] := Byte(Flags and 255);
      FIWRAM[$7FF9] := Byte(Flags shr 8);
      FWaitMask := 0;
      FHalted := False;
    end
    else
      FHalted := True;
  end;
  var Pending := FVideo.Reg16($200) and FVideo.Reg16($202);
  if (FWaitMask <> 0) and FHalted and (Pending <> 0) and not FIRQLevel then
  begin
    Tick(3);
    Exit;
  end;

  if FHalted then
  begin
    if not FHaltIRQ then
    begin
      Tick(32);
      Exit;
    end;

    // An enabled IF source traverses the wake synchronizer before the CPU
    // restarts. IME does not gate HALT wake-up.
    FHalted := False;
    Tick(2);
  end;
  FAccessCycles := 0;
  FClockBus := True;
  try
    ExecuteCPU;
  finally
    FClockBus := False;
  end;
end;

procedure TGBAConsole.Step;
begin
  StepInternal;

  // Public single-step callers can inspect the PPU immediately afterwards.
  FlushVideo;
end;

procedure TGBAConsole.RunFrame;
begin
  FSound.BeginFrame;
  FFrameTarget := FFrameNumber + 1;
  FFrameBoundaryActive := True;
  try
    while FFrameNumber < FFrameTarget do
      StepInternal;
  finally
    FFrameBoundaryActive := False;
  end;
end;

procedure TGBAConsole.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
  FPadEnabled := Ports.Devices[0] <> 'none';
  SetInput(FInput);
end;

procedure TGBAConsole.SetInput(const Input: TEmulatorButtons);
const
  Mapping: array[0..9] of TEmulatorButton = (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select,
    TEmulatorButton.Start, TEmulatorButton.Right, TEmulatorButton.Left, TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Z, TEmulatorButton.C);
begin
  FInput := Input;
  var V := $3FF;
  if FPadEnabled then
    for var i := 0 to 9 do
      if Mapping[i] in Input then
        V := V and not (1 shl i);

  FVideo.SetReg16($130, V);
  var C := FVideo.Reg16($132);
  var Mask := C and $3FF;
  var Down := (not V) and Mask;
  if (C and $4000 <> 0) and (Mask <> 0) then
    if ((C and $8000 = 0) and (Down <> 0)) or ((C and $8000 <> 0) and (Down = Mask)) then
      IRQ(12);
end;

procedure TGBAConsole.LoadBattery(const Data: TBytes);
begin
  FCartridge.LoadBattery(Data);
end;

function TGBAConsole.BatteryData: TBytes;
begin
  Result := FCartridge.BatteryData;
end;

procedure TGBAConsole.MarkBatteryDirty;
begin
  FCartridge.MarkBatteryDirty;
end;

function TGBAConsole.GetBatteryDirty: Boolean;
begin
  Result := FCartridge.BatteryDirty;
end;

function TGBAConsole.GetPixels: TArray<TAlphaColor>;
begin
  Result := FVideo.Pixels;
end;

function TGBAConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FSound.Samples;
end;

function TGBAConsole.GetSampleFrames: Integer;
begin
  Result := FSound.SampleFrames;
end;

function TGBAConsole.FramesPerSecond: Double;
begin
  Result := GBA_CLOCK / GBA_FRAME_CYCLES;
end;

function TGBAConsole.Width: Integer;
begin
  Result := GBA_WIDTH;
end;

function TGBAConsole.Height: Integer;
begin
  Result := GBA_HEIGHT;
end;

procedure TGBAConsole.SerializeState(State: TStateArchive);
const
  TimerMasks: array[0..3] of Integer = (0, 63, 255, 1023);
begin
  if State.Loading then
  begin
    FWaitControl := $FFFFFFFF;
    FVideoPendingCycles := 0;
  end
  else
    FlushVideo;
  var Hash := THashSHA2.Create;
  Hash.Update(FBIOS, SizeOf(FBIOS));
  var BIOSHash := Hash.HashAsBytes;
  var ExpectedBIOS := Copy(BIOSHash);
  State.Field(BIOSHash[0], Length(BIOSHash));
  if State.Loading and not CompareMem(@BIOSHash[0], @ExpectedBIOS[0], Length(BIOSHash)) then
    raise EReadError.Create('GBA snapshot requires the same BIOS');

  FCPU.SerializeState(State);
  FVideo.SerializeState(State);
  FSound.SerializeState(State);
  FCartridge.SerializeState(State);
  State.Field(FEWRAM, SizeOf(FEWRAM));
  State.Field(FIWRAM, SizeOf(FIWRAM));

  // An idle timer's free-running phase is derived without visiting it on
  // every CPU access. Materialize it for the unchanged v6 snapshot layout.
  if not State.Loading then
    for var i := 0 to 3 do
      if (FTimerWorkMask and (1 shl i) = 0) and ((i = 0) or (FTimers[i].Control and 4 = 0)) then
      begin
        var Mask := TimerMasks[FTimers[i].Control and 3];
        FTimers[i].Phase := Integer((FMasterClock + UInt64(Mask)) and UInt64(Mask));
      end;
  if not State.Loading then
    FlushTimers;
  State.Field(FTimers, SizeOf(FTimers));
  if State.Loading then
  begin
    FTimerWorkMask := 0;
    FTimerEventCycles := 0;
    FTimerPendingCycles := 0;
    for var i := 0 to 3 do
      if (FTimers[i].Control and $80 <> 0) or (FTimers[i].StartDelay > 0) or (FTimers[i].ReloadDelay > 0) then
        FTimerWorkMask := FTimerWorkMask or (1 shl i);
  end;

  State.Field(FDMA, SizeOf(FDMA));
  if State.Loading then
    UpdateDMADeadline;
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineCycle, SizeOf(FLineCycle));
  State.Field(FExtraCycles, SizeOf(FExtraCycles));
  State.Field(FExtraInDMA, SizeOf(FExtraInDMA));
  State.Field(FWaitPC, SizeOf(FWaitPC));
  State.Field(FWaitMask, SizeOf(FWaitMask));
  State.Field(FHalted, SizeOf(FHalted));
  State.Field(FStopped, SizeOf(FStopped));
  State.Field(FLastAddress, SizeOf(FLastAddress));
  State.Field(FOpenBus, SizeOf(FOpenBus));
  State.Field(FProtectedBIOS, SizeOf(FProtectedBIOS));
  State.Field(FMasterClock, SizeOf(FMasterClock));
  State.Field(FIRQDue, SizeOf(FIRQDue));
  if State.Loading then
  begin
    FNextIRQDue := 0;
    for var i := 0 to 13 do
      if (FIRQDue[i] > 0) and ((FNextIRQDue = 0) or (FIRQDue[i] < FNextIRQDue)) then
        FNextIRQDue := FIRQDue[i];
  end;
  State.Field(FIRQLevel, SizeOf(FIRQLevel));
  State.Field(FIRQRequested, SizeOf(FIRQRequested));
  State.Field(FIRQDelay, SizeOf(FIRQDelay));
  State.Field(FIRQSample, SizeOf(FIRQSample));
  State.Field(FHaltIRQ, SizeOf(FHaltIRQ));
  State.Field(FHaltIRQRequested, SizeOf(FHaltIRQRequested));
  State.Field(FHaltIRQDelay, SizeOf(FHaltIRQDelay));
  State.Field(FIRQPipeline, SizeOf(FIRQPipeline));
  State.Field(FCPUResuming, SizeOf(FCPUResuming));
  State.Field(FCPUSequenceBroken, SizeOf(FCPUSequenceBroken));
  State.Field(FCPUYieldIdle, SizeOf(FCPUYieldIdle));
  State.Field(FParallelIRQ, SizeOf(FParallelIRQ));
  State.Field(FParallelCount, SizeOf(FParallelCount));
  State.Field(FParallelPosition, SizeOf(FParallelPosition));
  State.Field(FCPUCheckpoint, SizeOf(FCPUCheckpoint));
  State.Field(FCPUAccessCount, SizeOf(FCPUAccessCount));

  if (FCPUAccessCount < 0) or (FCPUAccessCount > Length(FCPUAccesses)) then
    raise EReadError.Create('Invalid GBA CPU transaction count');

  for var i := 0 to FCPUAccessCount - 1 do
  begin
    State.Field(FCPUAccesses[i], SizeOf(FCPUAccesses[i]));
    if State.Loading and ((FCPUAccesses[i].Kind > 3) or not (FCPUAccesses[i].Size in [1, 2, 4])) then
      raise EReadError.Create('Invalid GBA CPU transaction');
  end;

  State.Field(FDMAReadLatch, SizeOf(FDMAReadLatch));
  State.Field(FSerialStart, SizeOf(FSerialStart));
  State.Field(FSerialEnd, SizeOf(FSerialEnd));
  State.Field(FSerialActive, SizeOf(FSerialActive));
  State.Field(FIRQReadLatch, SizeOf(FIRQReadLatch));
  State.Field(FIRQReadDelay, SizeOf(FIRQReadDelay));
  State.Field(FVideoCaptureArmed, SizeOf(FVideoCaptureArmed));
  State.Field(FPrefetchAddress, SizeOf(FPrefetchAddress));
  State.Field(FPrefetchNext, SizeOf(FPrefetchNext));
  State.Field(FPrefetchCount, SizeOf(FPrefetchCount));
  State.Field(FPrefetchPhase, SizeOf(FPrefetchPhase));
  State.Field(FPrefetchValid, SizeOf(FPrefetchValid));
  State.Field(FRenderedX, SizeOf(FRenderedX));
  State.Field(FStopFrameCycles, SizeOf(FStopFrameCycles));

  if State.Loading then
  begin
    if (FLine < 0) or (FLine >= 228) or (FLineCycle < 0) or (FLineCycle >= 1232) or
      (FRenderedX < 0) or (FRenderedX > 240) or (FStopFrameCycles < 0) or (FStopFrameCycles >= GBA_FRAME_CYCLES) or
      (FPrefetchCount < 0) or (FPrefetchCount > 8) or (FPrefetchPhase < 0) or (FPrefetchPhase > 8) or
      (FIRQDelay < 0) or (FIRQDelay > 3) or (FIRQPipeline > 7) or
      (FIRQReadDelay < 0) or (FIRQReadDelay > 1) or
      (FHaltIRQDelay < 0) or (FHaltIRQDelay > 2) or
      (FParallelCount < 0) or (FParallelCount > 8) or
      (FParallelPosition < 0) or (FParallelPosition > FParallelCount) or
      (FExtraCycles < 0) or (FExtraCycles > 128 * 1024 * 1024) or (FWaitMask < 0) or (FWaitMask > $3FFF) then
      raise EReadError.Create('Invalid GBA scheduler state');

    for var i := 0 to 7 do
      if FParallelIRQ[i] > 1 then
        raise EReadError.Create('Invalid GBA parallel IRQ state');

    for var i := 0 to 3 do
      if (FDMA[i].Count < 0) or (FDMA[i].Count > $10000) or (FDMA[i].Remaining < 0) or (FDMA[i].Remaining > $10000) or
        (FTimers[i].StartDelay < 0) or (FTimers[i].StartDelay > 2) or
        (FTimers[i].ReloadDelay < 0) or (FTimers[i].ReloadDelay > 1) or
        (FTimers[i].Phase < 0) or (FTimers[i].Phase >= 1024) then
        raise EReadError.Create('Invalid GBA DMA/timer state');

    FAccessCycles := 0;
    FInDMA := False;
    FClockBus := False;
    FHLE := False;
    FCPUAccessPosition := 0;
    FBusLocked := False;
  end;
end;

procedure TGBAConsole.SoftwareInterrupt(Number: Byte);
var
  OutData: TBytes;
  Src, Dest: Cardinal;
  Size, Cursor: Integer;

  function RB: Byte;
  begin
    Result := Byte(ReadBus(Src, 1));
    Src := ARMAdd(Src, 1);
  end;

  procedure Emit(Value: Byte);
  begin
    if Cursor >= Size then
      raise EReadError.Create('GBA BIOS decompression overflow');

    OutData[Cursor] := Value;
    Inc(Cursor);
  end;

  function Signed(V: Cardinal): Int64;
  begin
    Result := V;
    if V and $80000000 <> 0 then
      Dec(Result, $100000000);
  end;

  function Wrap(V: Int64): Cardinal;
  begin
    Result := Cardinal(V and $FFFFFFFF);
  end;

  function SH(Address: Cardinal): Integer;
  begin
    Result := ReadBus(Address, 2) and $FFFF;
    if Result and $8000 <> 0 then
      Dec(Result, $10000);
  end;

  procedure CopyBytes(Address: Cardinal; const Bytes: TBytes; Halfwords: Boolean);
  begin
    if Halfwords then
      for var i := 0 to (Length(Bytes) + 1) div 2 - 1 do
      begin
        var V := Cardinal(Bytes[i * 2]);
        if i * 2 + 1 < Length(Bytes) then
          V := V or (Cardinal(Bytes[i * 2 + 1]) shl 8);
        WriteBus(ARMAdd(Address, i * 2), V, 2);
      end
    else
      for var i := 0 to High(Bytes) do
        WriteBus(ARMAdd(Address, i), Bytes[i], 1);
  end;

begin
  Src := FCPU.R[0];
  Dest := FCPU.R[1];
  Size := 0;
  Cursor := 0;
  case Number of
    $00:
      begin
        var Boot := FIWRAM[$7FFA];
        FillChar(FIWRAM[$7E00], $200, 0);
        FCPU.SetStatus($D2);
        FCPU.R[13] := $03007FA0;
        FCPU.SetStatus($D3);
        FCPU.R[13] := $03007FE0;
        FCPU.SetStatus($1F);
        FCPU.R[13] := $03007F00;
        for var i := 0 to 12 do
          FCPU.R[i] := 0;
        if Boot = 0 then
          FCPU.R[15] := $08000000
        else
          FCPU.R[15] := $02000000;
        FCPU.R[14] := FCPU.R[15];
        FHalted := False;
        FWaitMask := 0;
        FProtectedBIOS := $E129F000;
      end;
    $01:
      begin
        var Flags := FCPU.R[0];
        if Flags and 1 <> 0 then
          FillChar(FEWRAM, SizeOf(FEWRAM), 0);
        if Flags and 2 <> 0 then
          FillChar(FIWRAM, $7E00, 0);
        if Flags and 4 <> 0 then
          FillChar(FVideo.Palette, SizeOf(FVideo.Palette), 0);
        if Flags and 8 <> 0 then
          FillChar(FVideo.VRAM, SizeOf(FVideo.VRAM), 0);
        if Flags and 16 <> 0 then
          FillChar(FVideo.OAM, SizeOf(FVideo.OAM), 0);
        if Flags and 32 <> 0 then
          FillChar(FVideo.IO[$120], 16, 0);
        if Flags and 64 <> 0 then
          FSound.Reset;
        if Flags and 128 <> 0 then
        begin
          FillChar(FVideo.IO, 96, 0);
          FillChar(FTimers, SizeOf(FTimers), 0);
          FTimerWorkMask := 0;
          FTimerEventCycles := 0;
          FTimerPendingCycles := 0;
          FillChar(FDMA, SizeOf(FDMA), 0);
          FNextDMAReady := 0;
          FVideo.SetReg16($20, $100);
          FVideo.SetReg16($26, $100);
          FVideo.SetReg16($30, $100);
          FVideo.SetReg16($36, $100);
        end;
        FVideo.SetReg16(0, $80);
      end;
    $02, $03:
      begin
        FHalted := True;
        FStopped := Number = $03;
      end;
    $04, $05:
      begin
        if Number = $05 then
        begin
          FCPU.R[0] := 1;
          FCPU.R[1] := 1;
        end;
        FVideo.SetReg16($208, 1);
        var Flags := ReadBus($03007FF8, 2);
        FWaitMask := FCPU.R[1] and $3FFF;
        FWaitPC := FCPU.R[15];
        if FCPU.R[0] <> 0 then
          Flags := Flags and not Cardinal(FWaitMask);
        WriteBus($03007FF8, Flags, 2);
        FHalted := (Flags and Cardinal(FWaitMask)) = 0;
        if not FHalted then
        begin
          WriteBus($03007FF8, Flags and not Cardinal(FWaitMask), 2);
          FWaitMask := 0;
        end;
      end;
    $06, $07:
      begin
        var A := Signed(FCPU.R[0]);
        var B := Signed(FCPU.R[1]);
        if Number = $07 then
        begin
          var Temp := A;
          A := B;
          B := Temp;
        end;
        var Q: Int64;
        if B = 0 then
          if A < 0 then
            Q := 1
          else
            Q := -1
        else
          Q := A div B;
        FCPU.R[0] := Wrap(Q);
        if B = 0 then
          FCPU.R[1] := Wrap(A)
        else
          FCPU.R[1] := Wrap(A mod B);
        FCPU.R[3] := Wrap(Abs(Q));
      end;
    $08:
      FCPU.R[0] := Cardinal(Trunc(Sqrt(FCPU.R[0])));
    $09:
      FCPU.R[0] := Wrap(Round(ArcTan((Int64(Integer(FCPU.R[0] and $FFFF)) - Ord(FCPU.R[0] and $8000 <> 0) * 65536) / 16384.0) * 32768 / Pi));
    $0A:
      begin
        if (FCPU.R[0] or FCPU.R[1]) = 0 then
          FCPU.R[0] := 0
        else
          FCPU.R[0] := Cardinal(Round(ArcTan2(Signed(FCPU.R[1]), Signed(FCPU.R[0])) * 32768 / Pi) and $FFFF);
      end;
    $0B, $0C:
      begin
        var Control := FCPU.R[2];
        var Count := Integer(Control and $1FFFFF);
        var UnitSize := 2;
        if (Control and $04000000 <> 0) or (Number = $0C) then
          UnitSize := 4;
        if Number = $0C then
          Count := (Count + 7) and not 7;
      // The documented 21-bit length permits up to 8 MiB.
      // Rejecting valid large transfers breaks translated cartridges.
        Src := Src and not Cardinal(UnitSize - 1);
        Dest := Dest and not Cardinal(UnitSize - 1);
        var V: Cardinal := 0;
        if Control and $01000000 <> 0 then
          V := ReadBus(Src, UnitSize);
        for var i := 0 to Count - 1 do
        begin
          if Control and $01000000 = 0 then
            V := ReadBus(ARMAdd(Src, i * UnitSize), UnitSize);
          WriteBus(ARMAdd(Dest, i * UnitSize), V, UnitSize);
        end;
      end;
    $0D:
      FCPU.R[0] := $BAAE187F;
    $0E, $0F:
      begin
        var Count := Integer(FCPU.R[2]);
        if Count > 4096 then
          raise EReadError.Create('GBA affine count too large');

        for var i := 0 to Count - 1 do
        begin
          var ScaleOffset := 0;
          if Number = $0E then
            ScaleOffset := 12;
          var SX := SH(ARMAdd(Src, ScaleOffset));
          var SY := SH(ARMAdd(Src, ScaleOffset + 2));
          var Angle := ReadBus(ARMAdd(Src, ScaleOffset + 4), 2) shr 8;
          var SinV := Sin(Angle * Pi / 128);
          var CosV := Cos(Angle * Pi / 128);
          var PA := Trunc(CosV * SX);
          var PB := Trunc(-SinV * SX);
          var PC := Trunc(SinV * SY);
          var PD := Trunc(CosV * SY);
          var Stride := 2;
          if Number = $0F then
            Stride := Integer(FCPU.R[3]);

          if (Stride < 0) or (Stride > $100000) then
            raise EReadError.Create('GBA affine stride too large');

          WriteBus(Dest, Wrap(PA), 2);
          WriteBus(ARMAdd(Dest, Stride), Wrap(PB), 2);
          WriteBus(ARMAdd(Dest, Stride * 2), Wrap(PC), 2);
          WriteBus(ARMAdd(Dest, Stride * 3), Wrap(PD), 2);
          if Number = $0E then
          begin
            var X := SH(ARMAdd(Src, 8));
            var Y := SH(ARMAdd(Src, 10));
            WriteBus(ARMAdd(Dest, 8), Wrap(Signed(ReadBus(Src, 4)) - Int64(PA) * X - Int64(PB) * Y), 4);
            WriteBus(ARMAdd(Dest, 12), Wrap(Signed(ReadBus(ARMAdd(Src, 4), 4)) - Int64(PC) * X - Int64(PD) * Y), 4);
            Src := ARMAdd(Src, 20);
            Dest := ARMAdd(Dest, 16);
          end
          else
          begin
            Src := ARMAdd(Src, 8);
            Dest := ARMAdd(Dest, Stride * 4);
          end;
        end;
      end;
    $10:
      begin
        var Info := FCPU.R[2];
        var Count := Integer(ReadBus(Info, 2));
        var SourceWidth := Integer(ReadBus(ARMAdd(Info, 2), 1));
        var DestWidth := Integer(ReadBus(ARMAdd(Info, 3), 1));
        var Offset := ReadBus(ARMAdd(Info, 4), 4);

        if not (SourceWidth in [1, 2, 4, 8]) or not (DestWidth in [1, 2, 4, 8, 16, 32]) then
          raise EReadError.Create('Invalid GBA BitUnpack width');

        var WordValue: Cardinal := 0;
        var Bits := 0;
        var Address := Dest;
        for var i := 0 to Count - 1 do
        begin
          var B := Integer(RB);
          for var Bit := 0 to 8 div SourceWidth - 1 do
          begin
            var V := Cardinal((B shr (Bit * SourceWidth)) and ((1 shl SourceWidth) - 1));
            if (V <> 0) or (Offset and $80000000 <> 0) then
              V := ARMAdd(V, Offset and $7FFFFFFF);
            WordValue := WordValue or (V shl Bits);
            Inc(Bits, DestWidth);
            if Bits = 32 then
            begin
              WriteBus(Address, WordValue, 4);
              Address := ARMAdd(Address, 4);
              WordValue := 0;
              Bits := 0;
            end;
          end;
        end;
        if Bits <> 0 then
          WriteBus(Address, WordValue, 4);
      end;
    $11..$18:
      begin
        var Header := ReadBus(Src, 4);
        Src := ARMAdd(Src, 4);
        Size := Integer(Header shr 8);
        if Size > 4 * 1024 * 1024 then
          raise EReadError.Create('GBA decompression output too large');

        SetLength(OutData, Size);
        case Number of
          $11, $12:
            while Cursor < Size do
            begin
              var Flags := RB;
              for var Bit := 7 downto 0 do
              begin
                if Cursor >= Size then
                  Break;
                if Flags and (1 shl Bit) = 0 then
                  Emit(RB)
                else
                begin
                  var A := RB;
                  var B := RB;
                  var Count := (A shr 4) + 3;
                  var Distance := ((Integer(A) and 15) * 256) + B + 1;
                  for var i := 1 to Count do
                    if Cursor < Size then
                    begin
                      // BIOS reads the destination bus; patched cartridges can refer
                      // to bytes preceding the output buffer, already present in RAM.
                      if Distance > Cursor then
                        Emit(Byte(ReadBus(Wrap(Int64(Dest) + Cursor - Distance), 1)))
                      else
                        Emit(OutData[Cursor - Distance]);
                    end;
                end;
              end;
            end;
          $13:
            begin
              var Width := Header and 15;
              if not (Width in [4, 8]) then
                raise EReadError.Create('Invalid GBA Huffman width');

              var TreeSize := (Integer(RB) + 1) * 2;
              var Tree := Src;
              Src := ARMAdd(Src, TreeSize - 1);
              Src := ARMAdd(Src, 3) and $FFFFFFFC;
              var Bits := 0;
              var Stream: Cardinal := 0;
              var Node := Tree;
              var Nibble := -1;
              var Depth := 0;
              while Cursor < Size do
              begin
                if Bits = 0 then
                begin
                  Stream := ReadBus(Src, 4);
                  Src := ARMAdd(Src, 4);
                  Bits := 32;
                end;
                var Right := Stream shr 31;
                Stream := Stream shl 1;
                Dec(Bits);
                var Value := ReadBus(Node, 1);
                var Next := (Node and $FFFFFFFE) + ((Value and $3F) + 1) * 2 + Right;
                if (Next < Tree) or (Next >= Tree + Cardinal(TreeSize)) then
                  raise EReadError.Create('Invalid GBA Huffman tree');

                Inc(Depth);
                if Depth > 512 then
                  raise EReadError.Create('GBA Huffman tree cycle');

                if Value and ($80 shr Right) <> 0 then
                begin
                  var V := Byte(ReadBus(Next, 1));
                  if Width = 8 then
                    Emit(V)
                  else if Nibble < 0 then
                    Nibble := V and 15
                  else
                  begin
                    Emit(Byte(Nibble or ((V and 15) shl 4)));
                    Nibble := -1;
                  end;
                  Node := Tree;
                  Depth := 0;
                end
                else
                  Node := Next;
              end;
            end;
          $14, $15:
            while Cursor < Size do
            begin
              var Control := RB;
              var Count := Integer(Control and 127);
              if Control and $80 <> 0 then
              begin
                Inc(Count, 3);
                var V := RB;
                for var i := 1 to Count do
                  if Cursor < Size then
                    Emit(V);
              end
              else
              begin
                Inc(Count);
                for var i := 1 to Count do
                  if Cursor < Size then
                    Emit(RB);
              end;
            end;
          $16, $17:
            begin
              var V := 0;
              while Cursor < Size do
              begin
                V := (V + RB) and 255;
                Emit(Byte(V));
              end;
            end;
          $18:
            begin
              var V := 0;
              while Cursor < Size do
              begin
                V := (V + Integer(ReadBus(Src, 2))) and $FFFF;
                Src := ARMAdd(Src, 2);
                Emit(Byte(V and 255));
                if Cursor < Size then
                  Emit(Byte(V shr 8));
              end;
            end;
        end;
        CopyBytes(Dest, OutData, (Number in [$12, $15, $17, $18]) or (Dest shr 24 in [5, 6, 7]));
      end;
    $19:
      begin
        FVideo.SetReg16($88, Ord(FCPU.R[0] <> 0) * $200);
      end;
    $1F:
      begin
        var Frequency := ReadBus(ARMAdd(FCPU.R[0], 4), 4);
        FCPU.R[0] := Cardinal(EnsureRange(Trunc(Frequency / Power(2, (180.0 - FCPU.R[1] - FCPU.R[2] / 256.0) / 12)), Int64(0), Int64($FFFFFFFF)));
      end;
    $25:
      FCPU.R[0] := 1; // No cable connected.
      $26:
      begin
        FHalted := True;
        FStopped := FCPU.R[2] and $80 <> 0;
      end;
    $27:
      begin
        for var i := 0 to 11 do
        begin
          WriteBus(ARMAdd(Src, i * 4), $E129F000, 4);
        end;
      end;
    $2A:
      FCPU.R[0] := 0;
  else
    raise ENotSupportedException.CreateFmt('GBA BIOS SWI %.2x requires a BIOS file (Boot/File in gba.ini)', [Number]);
  end;

  FProtectedBIOS := $E3A02004;
end;

end.

