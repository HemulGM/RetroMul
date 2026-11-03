unit Saturn.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.SyncObjs, HW.SH2,
  HW.SH7604, HW.M68k, Saturn.SCU, Saturn.SMPC, Saturn.VDP1, Saturn.VDP2,
  Core.Snapshots, Core.CD.Disc, Saturn.CD, Saturn.SCSP, Saturn.Cartridge;

type
  TSaturnBusObserver = reference to procedure(Address, Value: Cardinal; Size: Integer);

  TSaturnInstructionObserver = reference to procedure(CPU: Integer; const State: TSH2State);

  TSaturnConsole = class
  private
    type
      TPort = record
        Owner: TSaturnConsole;
        Index: Integer;
      end;

      PPort = ^TPort;
  private
    FRenderThread: TThread;
    FRenderWake, FRenderDone: TLightweightEvent;
    FRenderStop, FRenderPending, FRunningFrame: Boolean;
    FRenderMailbox: array[0..31] of Integer; // [16]: idle/work/stop, isolated cache line
    FRenderLine, FRenderOffset: Integer;
    FRenderError: string;
    procedure SetThreadedVideo(Value: Boolean);
    function GetThreadedVideo: Boolean;
    procedure SynchronizeVideo(RaiseError: Boolean = True);
    procedure RenderLine(Line, Offset: Integer);
  private
    FPixels: TArray<TAlphaColor>; // renderer reads this reference away from CPU timestamps
    FBIOS: TBytes;
    FWorkLow, FWorkHigh: array[0..$FFFFF] of Byte;
    FBackup: array[0..$7FFF] of Byte;
    FSound: array[0..$7FFFF] of Byte;
    FSoundRegisters: array[0..$FFF] of Byte;
    FSoundCPU: TM68kState;
    FSoundCallbacks: TM68kReadWriteCallbacks;
    FSoundAt, FSamplePhase: Int64;
    FSoundFraction: Int64;
    FTimerPhase: array[0..2] of Integer;
    FSoundDMAActive: Boolean;
    FSoundDMANext: Int64;
    FSoundDMAMemory, FSoundDMARegister: Cardinal;
    FSoundDMACount: Integer;
    FSoundDMAControl: Word;
    FSoundPending, FMainSoundPending: Word;
    procedure SoundTick;
    procedure SoundIRQ;
    procedure SoundRegisterWrite(Address: Cardinal; Value: Byte);
    function SoundRegisterRead(Address: Cardinal): Byte;
  private
    FCPU: array[0..1] of TSH7604;
    FPort: array[0..1] of TPort;
    FSCU: TSaturnSCU;
    FSMPC: TSaturnSMPC;
    FVDP1: TSaturnVDP1;
    FVDP2: TSaturnVDP2;
    FCPUTime: array[0..1] of Int64;
    FTime, FNextRaster, FLineStart: Int64;
    FRasterPhase: Integer;
    FLine, FClock: Integer;
    FHBlank, FSlaveOn, FSoundOn, FResetPending, FPAL: Boolean;
    FFrames: UInt64;
    FFrameWidth, FFrameHeight: Integer;
    FCD: TSaturnCD;
    FSCSP: TSaturnSCSP;
    FCartridge: TSaturnCartridge;
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
    procedure CDIRQ(Active: Boolean);
    procedure NetlinkIRQ(Active: Boolean);
    function SoundRAMRead(Address: Cardinal): Byte;
    procedure SoundRAMWrite(Address: Cardinal; Value: Byte);
    procedure SoundDMA(Target: Int64);
  private
    FBusUntil: Int64;
    FIRQLevel, FIRQVector: Integer;
    FBackupDirty: Boolean;
    FBusObserver: TSaturnBusObserver;
    FInstructionObserver: TSaturnInstructionObserver;
    procedure RasterEvent;
    procedure CaptureRaster;
    procedure AdvanceDevices(Target: Int64);
    procedure SCUIRQ(Level, Vector: Integer);
    procedure SMPCCommand(Command: Byte);
    procedure SMPCIRQ;
    procedure DrawIRQ;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    function Wait(CPU: Integer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
    function ReserveDMA(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean; SCUBurst: Boolean = False): Int64;
    function ReserveSCUDMA(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;
    function DMAReady(Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;
  public
    constructor Create(const BIOS: TBytes; Region: Byte = 4; PAL: Boolean = False; Disc: TCDDisc = nil; RAMCart: Integer = 0; const CartROM: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    function ReadBus(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBus(Address, Value: Cardinal; Size: Integer);
    function ReadCPU(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteCPU(CPU: Integer; Address, Value: Cardinal; Size: Integer);
    function CPUState(CPU: Integer): TSH2State;
    procedure SetCPUState(CPU: Integer; const State: TSH2State);
    procedure RunCycles(Cycles: Int64);
    procedure RunFrame;
    procedure SetInput(Port: Integer; Buttons: TSaturnButtons; Connected: Boolean = True);
    procedure LoadBackup(const Data: TBytes);
    function Backup: TBytes;
    function FramesPerSecond: Double;
    procedure SerializeState(Archive: TStateArchive);
    property SoundState: TM68kState read FSoundCPU;
    property SoundOn: Boolean read FSoundOn;
    property CD: TSaturnCD read FCD;
    property SCSP: TSaturnSCSP read FSCSP;
    property Cartridge: TSaturnCartridge read FCartridge;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
    property VDP1: TSaturnVDP1 read FVDP1;
    property VDP2: TSaturnVDP2 read FVDP2;
    property SCU: TSaturnSCU read FSCU;
    property SMPC: TSaturnSMPC read FSMPC;
    property ThreadedVideo: Boolean read GetThreadedVideo write SetThreadedVideo;
    property Pixels: TArray<TAlphaColor> read FPixels;
    property FrameWidth: Integer read FFrameWidth;
    property FrameHeight: Integer read FFrameHeight;
    property FrameNumber: UInt64 read FFrames;
    property Time: Int64 read FTime;
    property ClockFrequency: Integer read FClock;
    property SlaveOn: Boolean read FSlaveOn;
    property BackupDirty: Boolean read FBackupDirty write FBackupDirty;
    property InstructionObserver: TSaturnInstructionObserver read FInstructionObserver write FInstructionObserver;
    property BusObserver: TSaturnBusObserver read FBusObserver write FBusObserver;
  end;

implementation

uses
  System.Math, System.Hash, Saturn.SCUDSP;

{$Q+}{$R+}

const
{$IFDEF MSWINDOWS}
  RenderSpinLimit = 4096;
{$ELSE}
  RenderSpinLimit = 128;
{$ENDIF}

function CPURead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.ReadBus(Address, Size);
end;

procedure CPUWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  var Port := TSaturnConsole.PPort(User)^;
  Port.Owner.WriteBus(Address, Value, Size);
end;

function CPUWait(User: Pointer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.Wait(Port.Index, Address, Size, Writing);
end;

function CPUDMAReserve(User: Pointer; At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.ReserveDMA(At, Address, Size, Writing);
end;

function CPUDMAReady(User: Pointer; Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.DMAReady(Address, Size, Writing);
end;

function SoundRead(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte): Cardinal;
begin
  var Board := TSaturnConsole(User);
  var A: Cardinal := (Address * 2) and $FFFFFF;
  Result := $FFFF;
  if A < $100000 then
    Result := Board.ReadBus($05A00000 + (A and $7FFFF), 2)
  else if (A >= $100000) and (A < $101000) then
    Result := Board.ReadBus($05B00000 + (A and $FFF), 2);
end;

procedure SoundWrite(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte; Value: Cardinal);
begin
  var Board := TSaturnConsole(User);
  var A: Cardinal := (Address * 2) and $FFFFFF;
  if A < $100000 then
    A := $05A00000 + (A and $7FFFF)
  else if (A >= $100000) and (A < $101000) then
    A := $05B00000 + (A and $FFF)
  else
    Exit;

  if Hi <> 0 then
    Board.WriteBus(A, (Value shr 8) and $FF, 1);
  if Lo <> 0 then
    Board.WriteBus(A + 1, Value and $FF, 1);
end;

procedure SoundAck(User: Pointer);
begin
  TSaturnConsole(User).SoundIRQ;
end;

function SCURead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TSaturnConsole(User).ReadBus(Address, Size);
end;

procedure SCUWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TSaturnConsole(User).WriteBus(Address, Value, Size);
end;

constructor TSaturnConsole.Create(const BIOS: TBytes; Region: Byte; PAL: Boolean; Disc: TCDDisc; RAMCart: Integer; const CartROM: TBytes);
begin
  inherited Create;
  if Length(BIOS) <> $80000 then
    raise EReadError.Create('Saturn BIOS must contain exactly 512 KiB');

  FBIOS := Copy(BIOS);
  FPAL := PAL;
  FSoundCallbacks.UserData := Self;
  FSoundCallbacks.ReadCallback := SoundRead;
  FSoundCallbacks.WriteCallback := SoundWrite;
  FSoundCallbacks.InterruptAcknowledgeCallback := SoundAck;
  for var i := 0 to 1 do
  begin
    FPort[i].Owner := Self;
    FPort[i].Index := i;
    FCPU[i] := TSH7604.Create(CPURead, CPUWrite, @FPort[i], CPUWait, i = 1);
  end;
  for var i := 0 to 1 do
  begin
    FCPU[i].ReserveDMA := CPUDMAReserve;
    FCPU[i].DMAReady := CPUDMAReady;
  end;
  FSCU := TSaturnSCU.Create(SCURead, SCUWrite, Self, SCUIRQ);
  FSCU.Reserve := ReserveSCUDMA;
  FSCU.Ready := DMAReady;
  FSMPC := TSaturnSMPC.Create(Region, SMPCCommand, SMPCIRQ);
  FVDP1 := TSaturnVDP1.Create(DrawIRQ);
  FVDP2 := TSaturnVDP2.Create(PAL);
  FVDP2.RasterSync := CaptureRaster;
  FCD := TSaturnCD.Create(Disc, CDIRQ);
  FCD.NetlinkIRQ := NetlinkIRQ;
  FSCSP := TSaturnSCSP.Create(SoundRAMRead, SoundRAMWrite);
  FCartridge := TSaturnCartridge.Create(RAMCart, CartROM);
  SetLength(FSamples, 8192);

  // New backup RAM has the BIOS format signature and free block headers.
  FillChar(FBackup, SizeOf(FBackup), 0);
  var Header: AnsiString := 'BackUpRam Format';
  for var RepeatIndex := 0 to 3 do
    Move(Header[1], FBackup[RepeatIndex * 16], 16);
  Reset;
end;

function TSaturnConsole.GetThreadedVideo: Boolean;
begin
  Result := FRenderThread <> nil;
end;

procedure TSaturnConsole.SynchronizeVideo(RaiseError: Boolean);
begin
  if FRenderPending then
  begin
    var Spins := 0;
    var Limit := 0;
    if TThread.ProcessorCount > 1 then
      Limit := RenderSpinLimit;
    while (TInterlocked.CompareExchange(FRenderMailbox[16], 0, 0) <> 0) and (Spins < Limit) do
    begin
      TThread.SpinWait(1);
      Inc(Spins);
    end;

    // The mailbox is the completion predicate; events are notifications.
    // Recheck after resetting so neither late nor coalesced signals lose work.
    while TInterlocked.CompareExchange(FRenderMailbox[16], 0, 0) <> 0 do
    begin
      FRenderDone.ResetEvent;
      if (TInterlocked.CompareExchange(FRenderMailbox[16], 0, 0) <> 0) and
        (FRenderDone.WaitFor(High(Cardinal)) <> wrSignaled) then
        raise EInvalidOperation.Create('Saturn video worker synchronization failed');
    end;

    FRenderPending := False;
  end;
  if RaiseError and (FRenderError <> '') then
    raise EInvalidOperation.Create('Saturn video worker: ' + FRenderError);
end;

procedure TSaturnConsole.SetThreadedVideo(Value: Boolean);
begin
  if Value = (FRenderThread <> nil) then
  begin
    if not Value then
    begin
      FreeAndNil(FRenderDone);
      FreeAndNil(FRenderWake);
    end;
    Exit;
  end;

  if Value then
  begin
    FRenderWake := TLightweightEvent.Create(False);
    FRenderDone := TLightweightEvent.Create(False);
    FRenderStop := False;
    FRenderError := '';
    FillChar(FRenderMailbox, SizeOf(FRenderMailbox), 0);
    FRenderThread := TThread.CreateAnonymousThread(
      procedure
      begin
        var Limit := 0;
        if TThread.ProcessorCount > 1 then
          Limit := RenderSpinLimit;
        while True do
        begin
          var Job := TInterlocked.CompareExchange(FRenderMailbox[16], 0, 0);
          var Spins := 0;
          while (Job = 0) and (Spins < Limit) do
          begin
            TThread.SpinWait(1);
            Inc(Spins);
            Job := TInterlocked.CompareExchange(FRenderMailbox[16], 0, 0);
          end;
          if Job = 0 then
          begin
            if FRenderWake.WaitFor(High(Cardinal)) <> wrSignaled then
            begin
              FRenderError := 'Worker wake failed';
              TInterlocked.Exchange(FRenderMailbox[16], 0);
              FRenderDone.SetEvent;
              Exit;
            end;

            FRenderWake.ResetEvent;
            Continue;
          end;
          if Job = 2 then
            Exit;

          FRenderWake.ResetEvent;
          try
            FVDP2.RenderLine(FRenderLine, FVDP1, FPixels, FRenderOffset, True);
            FVDP1.ScanLine;
          except
            on E: Exception do
              FRenderError := E.ClassName + ': ' + E.Message;
          end;
          TInterlocked.Exchange(FRenderMailbox[16], 0);
          FRenderDone.SetEvent;
        end;
      end);
    FRenderThread.FreeOnTerminate := False;
    FRenderThread.Start;
  end
  else
  begin
    SynchronizeVideo(False);
    FRenderStop := True;
    TInterlocked.Exchange(FRenderMailbox[16], 2);
    FRenderWake.SetEvent;
    FRenderThread.WaitFor;
    FreeAndNil(FRenderThread);
    FreeAndNil(FRenderDone);
    FreeAndNil(FRenderWake);
    FRenderError := '';
  end;
end;

procedure TSaturnConsole.RenderLine(Line, Offset: Integer);
begin
  SynchronizeVideo;
  var W := FVDP2.Width;
  if (Line < 0) or (Line >= FVDP2.Height) or (Offset < 0) or
    (W > Length(FPixels)) or (Offset > Length(FPixels) - W) then
    Exit;

  FVDP2.LatchLine(Line, FVDP1.RotationEnabled);
  if FRenderThread = nil then
  begin
    FVDP2.RenderLine(Line, FVDP1, FPixels, Offset, True);
    FVDP1.ScanLine;
  end
  else
  begin
    FRenderLine := Line;
    FRenderOffset := Offset;
    FRenderDone.ResetEvent;
    FRenderPending := True;
    TInterlocked.Exchange(FRenderMailbox[16], 1);
    FRenderWake.SetEvent;
  end;
end;

destructor TSaturnConsole.Destroy;
begin
  SetThreadedVideo(False);
  FCartridge.Free;
  FSCSP.Free;
  FCD.Free;
  FCPU[0].Free;
  FCPU[1].Free;
  FVDP1.Free;
  FVDP2.Free;
  FSMPC.Free;
  FSCU.Free;
  inherited;
end;

procedure TSaturnConsole.Reset;
begin
  SynchronizeVideo;
  FillChar(FWorkLow, SizeOf(FWorkLow), 0);
  FillChar(FWorkHigh, SizeOf(FWorkHigh), 0);
  FillChar(FSound, SizeOf(FSound), 0);
  FillChar(FSoundRegisters, SizeOf(FSoundRegisters), 0);
  FSoundCPU := Default(TM68kState);
  FSoundAt := 0;
  FSoundFraction := 0;
  FSamplePhase := 0;
  FSoundDMAActive := False;
  FSoundDMANext := 0;
  FSoundDMAMemory := 0;
  FSoundDMARegister := 0;
  FSoundDMACount := 0;
  FSoundDMAControl := 0;
  FillChar(FTimerPhase, SizeOf(FTimerPhase), 0);
  FSoundPending := 0;
  FMainSoundPending := 0;
  FTime := 0;
  FBusUntil := 0;
  FFrames := 0;
  FSlaveOn := False;
  FSoundOn := False;
  FResetPending := False;
  FCPUTime[0] := 0;
  FCPUTime[1] := 0;
  FLine := 0;
  FHBlank := False;
  FClock := 26846587;
  if FPAL then
    FClock := 26656400;
  FIRQLevel := 0;
  FIRQVector := 0;
  FSCU.Reset;
  FSMPC.Reset;
  FSMPC.SetClock(FClock);
  FVDP1.Reset;
  FVDP2.Reset;
  FCPU[0].Reset;
  FCPU[1].Reset;
  FCD.Reset(FClock);
  FSCSP.Reset;
  FSampleFrames := 0;
  FCartridge.Reset;
  FFrameWidth := 320;
  FFrameHeight := 224;
  SetLength(FPixels, FFrameWidth * FFrameHeight);
  FLineStart := 0;
  FRasterPhase := 0;
  FNextRaster := 1280;
end;

procedure TSaturnConsole.SCUIRQ(Level, Vector: Integer);
begin
  FIRQLevel := Level;
  FIRQVector := Vector;
  if FCPU[0] <> nil then
    FCPU[0].Interrupt(Level, Vector);
end;

procedure TSaturnConsole.SMPCIRQ;
begin
  FSCU.Signal(7);
end;

procedure TSaturnConsole.DrawIRQ;
begin
  FSCU.Signal(13);
end;

procedure TSaturnConsole.SMPCCommand(Command: Byte);
begin
  SynchronizeVideo;
  case Command of
    $02:
      begin
        FCPU[1].Reset;
        FCPUTime[1] := FTime;
        FCPU[1].Advance(FTime);
        FSlaveOn := True;
      end;
    $03:
      FSlaveOn := False;
    $06:
      begin
        Clown68000Reset(FSoundCPU, FSoundCallbacks);
        FSoundAt := FTime;
        FSoundOn := True;
      end;
    $07:
      FSoundOn := False;
    $08:
      FCD.SetPower(True, FTime);
    $09:
      FCD.SetPower(False, FTime);
    $0D:
      FResetPending := True;
    $0E, $0F:
      begin
        var OldClock := FClock;
        FClock := 26846587;
        if FPAL then
          FClock := 26656400;
        if Command = $0E then
        begin
          FClock := 28636360;
          if FPAL then
            FClock := 28437500;
        end;
        FSamplePhase := FSamplePhase * FClock div OldClock;
        FSMPC.SetClock(FClock);
        FCD.SetClock(FClock);
        FSlaveOn := False;
        FSoundOn := False;

        // The boot ROM clock-change contract resets these LSIs, retaining the
        // CD block and work RAM. Sound RAM remains backed by its own DRAM.
        FSCU.Reset;
        FSCSP.Reset;
        FVDP1.Reset(False);
        FVDP2.Reset(False);
        FillChar(FSoundRegisters, SizeOf(FSoundRegisters), 0);
        FillChar(FTimerPhase, SizeOf(FTimerPhase), 0);
        FSoundPending := 0;
        FMainSoundPending := 0;
        FSoundFraction := 0;
        FLine := 0;
        FHBlank := False;
        FRasterPhase := 0;
        FLineStart := FTime;
        FNextRaster := FTime + 1280;
        if FSMPC.Clock352 then
          FNextRaster := FTime + 1408;
        FSoundDMAActive := False;
        FFrameWidth := 320;
        FFrameHeight := 224;
        SetLength(FPixels, FFrameWidth * FFrameHeight);
        FCPU[0].NMI;
      end;
    $18:
      FCPU[0].NMI;
  end;
end;

function TSaturnConsole.SoundRegisterRead(Address: Cardinal): Byte;
begin
  var A: Integer := Address and $FFF;
  if (A < $400) or (A >= $600) or ((A >= $400) and (A <= $403)) or (A = $408) or (A = $409) then
    Exit(FSCSP.ReadRegister(A));

  case A of
    $404:
      Result := $09; // MIDI input empty, output FIFO empty
      $420:
      Result := FSoundPending shr 8;
    $421:
      Result := FSoundPending and $FF;
    $42C:
      Result := FMainSoundPending shr 8;
    $42D:
      Result := FMainSoundPending and $FF;
  else
    Result := FSoundRegisters[A];
  end;
end;

procedure TSaturnConsole.SoundIRQ;
begin
  var Enable: Word := (Word(FSoundRegisters[$41E]) shl 8) or FSoundRegisters[$41F];
  var Pending := FSoundPending and Enable;
  var Level: Integer := 0;
  for var i := 0 to 10 do
    if Pending and (1 shl i) <> 0 then
    begin
      var B := Min(i, 7);
      Level := Ord(FSoundRegisters[$425] and (1 shl B) <> 0) or (Ord(FSoundRegisters[$427] and (1 shl B) <> 0) shl 1) or (Ord(FSoundRegisters[$429] and (1 shl B) <> 0) shl 2);
      Break;
    end;

  Clown68000Interrupt(FSoundCPU, Level);
  Enable := (Word(FSoundRegisters[$42A]) shl 8) or FSoundRegisters[$42B];
  if FMainSoundPending and Enable <> 0 then
    FSCU.Signal(6);
end;

procedure TSaturnConsole.SoundRegisterWrite(Address: Cardinal; Value: Byte);
begin
  var A: Integer := Address and $FFF;
  FSoundRegisters[A] := Value;
  FSCSP.WriteRegister(A, Value);
  case A of
    $421:
      FSoundPending := FSoundPending or (Value and $20);
    $423:
      FSoundPending := FSoundPending and not ((Word(FSoundRegisters[$422]) shl 8) or Value);
    $42D:
      FMainSoundPending := FMainSoundPending or (Value and $20);
    $42F:
      FMainSoundPending := FMainSoundPending and not ((Word(FSoundRegisters[$42E]) shl 8) or Value);
  end;
  if (A >= $41E) and (A <= $42F) then
    SoundIRQ;
end;

procedure TSaturnConsole.SoundTick;
begin
  var CDLeft, CDRight: Integer;
  var Left, Right: SmallInt;
  FCD.AudioSample(CDLeft, CDRight);
  FSCSP.Sample(CDLeft, CDRight, Left, Right);
  if FSampleFrames < 4096 then
  begin
    FSamples[FSampleFrames * 2] := Left;
    FSamples[FSampleFrames * 2 + 1] := Right;
    Inc(FSampleFrames);
  end;
  for var T := 0 to 2 do
  begin
    var A: Integer := $418 + T * 2;
    var Divider: Integer := 1 shl (FSoundRegisters[A] and 7);
    Inc(FTimerPhase[T]);
    if FTimerPhase[T] >= Divider then
    begin
      FTimerPhase[T] := 0;
      FSoundRegisters[A + 1] := Byte((Integer(FSoundRegisters[A + 1]) + 1) and $FF);
      if FSoundRegisters[A + 1] = 0 then
      begin
        FSoundPending := FSoundPending or (Word(1) shl (6 + T));
        FMainSoundPending := FMainSoundPending or (Word(1) shl (6 + T));
      end;
    end;
  end;
  SoundIRQ;
end;

procedure TSaturnConsole.NetlinkIRQ(Active: Boolean);
begin
  FSCU.SetExternal(12, Active);
end;

procedure TSaturnConsole.CDIRQ(Active: Boolean);
begin
  FSCU.SetExternal(0, Active);
end;

function TSaturnConsole.SoundRAMRead(Address: Cardinal): Byte;
begin
  Result := FSound[Address and $7FFFF];
end;

procedure TSaturnConsole.SoundRAMWrite(Address: Cardinal; Value: Byte);
begin
  FSound[Address and $7FFFF] := Value;
end;

procedure TSaturnConsole.SoundDMA(Target: Int64);
begin
  if not FSoundDMAActive then
  begin
    FSoundDMAControl := (Word(FSoundRegisters[$416]) shl 8) or FSoundRegisters[$417];
    if FSoundDMAControl and $1000 = 0 then
      Exit;

    FSoundDMAMemory := ((Cardinal(FSoundRegisters[$414] and $F0) shl 12) or (Cardinal(FSoundRegisters[$412]) shl 8) or FSoundRegisters[$413]) and $7FFFE;
    FSoundDMARegister := ((Cardinal(FSoundRegisters[$414] and 15) shl 8) or FSoundRegisters[$415]) and $FFE;
    FSoundDMACount := (FSoundDMAControl and $FFE) div 2;
    FSoundDMAActive := True;
    FSoundDMANext := FTime + 4;
  end;
  while FSoundDMAActive and (FSoundDMANext <= Target) do
  begin
    var V: Word := 0;
    var RegisterAddress := FSoundDMARegister;
    var Memory := FSoundDMAMemory;

    // The DMA register block cannot itself be a DMA source/destination.
    var ValidRegister: Boolean := (RegisterAddress < $412) or (RegisterAddress > $416);
    if (FSoundDMACount > 0) and (FSoundDMAControl and $2000 <> 0) then
    begin
      if (FSoundDMAControl and $4000 = 0) and ValidRegister then
        V := (Word(SoundRegisterRead(RegisterAddress)) shl 8) or SoundRegisterRead(RegisterAddress + 1);
      FSound[Memory] := V shr 8;
      FSound[(Memory + 1) and $7FFFF] := V and $FF;
    end
    else if FSoundDMACount > 0 then
    begin
      if FSoundDMAControl and $4000 = 0 then
        V := (Word(FSound[Memory]) shl 8) or FSound[(Memory + 1) and $7FFFF];
      if ValidRegister then
      begin
        SoundRegisterWrite(RegisterAddress, V shr 8);
        SoundRegisterWrite(RegisterAddress + 1, V and $FF);
      end;
    end;
    FSoundDMAMemory := (Memory + 2) and $7FFFF;
    FSoundDMARegister := (RegisterAddress + 2) and $FFE;
    Dec(FSoundDMACount);
    Inc(FSoundDMANext, 4);

    // Shared sound bus ownership delays simultaneous SH-2 transactions.
    FBusUntil := Max(FBusUntil, FSoundDMANext);
    if FSoundDMACount <= 0 then
    begin
      FSoundDMAActive := False;
      FSoundDMACount := 0;
      FSoundRegisters[$416] := FSoundRegisters[$416] and not $10;
      FSoundPending := FSoundPending or $10;
      FMainSoundPending := FMainSoundPending or $10;
      SoundIRQ;
    end;
  end;
end;

function TSaturnConsole.ReadByte(Address: Cardinal): Byte;
begin
  Result := $FF;
  case Address of
    $00000000..$000FFFFF:
      Result := FBIOS[Address and $7FFFF];
    $00100000..$0017FFFF:
      Result := FSMPC.Read(Address);
    $00180000..$001FFFFF:
      if Odd(Address) then
        Result := FBackup[(Address shr 1) and $7FFF];
    $00200000..$002FFFFF:
      Result := FWorkLow[Address and $FFFFF];
    $02000000..$04FFFFFF:
      Result := FCartridge.Read(Address);
    $05A00000..$05AFFFFF:
      Result := FSound[Address and $7FFFF];
    $05B00000..$05BFFFFF:
      Result := SoundRegisterRead(Address);
    $05C00000..$05C7FFFF:
      Result := FVDP1.ReadVRAM(Address, 1);
    $05C80000..$05CFFFFF:
      Result := FVDP1.ReadBuffer(Address, 1);
    $06000000..$07FFFFFF:
      Result := FWorkHigh[Address and $FFFFF];
  end;
end;

procedure TSaturnConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  case Address of
    $00100000..$0017FFFF:
      FSMPC.Write(Address, Value);
    $00180000..$001FFFFF:
      if Odd(Address) then
      begin
        var At := (Address shr 1) and $7FFF;
        if FBackup[At] <> Value then
        begin
          FBackup[At] := Value;
          FBackupDirty := True;
        end;
      end;
    $00200000..$002FFFFF:
      FWorkLow[Address and $FFFFF] := Value;
    $01000000..$017FFFFF:
      FCPU[1].InputCapture;
    $01800000..$01FFFFFF:
      FCPU[0].InputCapture;
    $02000000..$04FFFFFF:
      FCartridge.Write(Address, Value);
    $05A00000..$05AFFFFF:
      FSound[Address and $7FFFF] := Value;
    $05B00000..$05BFFFFF:
      SoundRegisterWrite(Address, Value);
    $05C00000..$05C7FFFF:
      FVDP1.WriteVRAM(Address, Value, 1);
    $05C80000..$05CFFFFF:
      FVDP1.WriteBuffer(Address, Value, 1);
    $06000000..$07FFFFFF:
      FWorkHigh[Address and $FFFFF] := Value;
  end;
end;

function ReadMemoryBE(Data: PByte; Size: Integer): Cardinal; inline;
begin
  case Size of
    1:
      Result := Data^;
    2:
      Result := Swap(PWord(Data)^);
  else
    var V := PCardinal(Data)^;
    Result := (V shl 24) or ((V and $FF00) shl 8) or ((V shr 8) and $FF00) or (V shr 24);
  end;
end;

procedure WriteMemoryBE(Data: PByte; Value: Cardinal; Size: Integer); inline;
begin
  case Size of
    1:
      Data^ := Value and $FF;
    2:
      PWord(Data)^ := Swap(Word(Value and $FFFF));
    4:
      PCardinal(Data)^ := (Value shl 24) or ((Value and $FF00) shl 8) or
        ((Value shr 8) and $FF00) or (Value shr 24);
  end;
end;

function TSaturnConsole.ReadBus(Address: Cardinal; Size: Integer): Cardinal;
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('Saturn bus size');

  Address := Address and $1FFFFFFF;

  // Aligned accesses cannot cross a RAM mirror or BIOS boundary. Unaligned
  // DMA/debug accesses retain the byte-by-byte bus path below.
  if Address and Cardinal(Size - 1) = 0 then
    case Address of
      $00000000..$000FFFFF:
        Exit(ReadMemoryBE(@FBIOS[Address and $7FFFF], Size));
      $00200000..$002FFFFF:
        Exit(ReadMemoryBE(@FWorkLow[Address and $FFFFF], Size));
      $05A00000..$05AFFFFF:
        Exit(ReadMemoryBE(@FSound[Address and $7FFFF], Size));
      $06000000..$07FFFFFF:
        Exit(ReadMemoryBE(@FWorkHigh[Address and $FFFFF], Size));
    end;

  case Address of
    $05800000..$058FFFFF:
      Exit(FCD.Read(Address, Size));
    $05D00000..$05D7FFFF:
      Exit(FVDP1.ReadRegister(Address, Size));
    $05E00000..$05EFFFFF:
      Exit(FVDP2.ReadVRAM(Address, Size));
    $05F00000..$05F7FFFF:
      Exit(FVDP2.ReadCRAM(Address, Size));
    $05F80000..$05FBFFFF:
      Exit(FVDP2.ReadRegister(Address, Size));
    $05FE0000..$05FEFFFF:
      Exit(FSCU.ReadRegister(Address, Size));
  end;

  Result := 0;
  for var i := 0 to Size - 1 do
    Result := (Result shl 8) or ReadByte(Address + Cardinal(i));
end;

procedure TSaturnConsole.WriteBus(Address, Value: Cardinal; Size: Integer);
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('Saturn bus size');

  Address := Address and $1FFFFFFF;
  if Assigned(FBusObserver) then
  begin
    SynchronizeVideo;
    FBusObserver(Address, Value, Size);
  end;
  if (Address >= $05C00000) and (Address < $05FC0000) then
    SynchronizeVideo;

  if Address and Cardinal(Size - 1) = 0 then
    case Address of
      $00200000..$002FFFFF:
        begin
          WriteMemoryBE(@FWorkLow[Address and $FFFFF], Value, Size);
          Exit;
        end;
      $05A00000..$05AFFFFF:
        begin
          WriteMemoryBE(@FSound[Address and $7FFFF], Value, Size);
          Exit;
        end;
      $06000000..$07FFFFFF:
        begin
          WriteMemoryBE(@FWorkHigh[Address and $FFFFF], Value, Size);
          Exit;
        end;
    end;

  case Address of
    $05800000..$058FFFFF:
      begin
        FCD.Write(Address, Value, Size);
        Exit;
      end;
    $05D00000..$05D7FFFF:
      begin
        FVDP1.WriteRegister(Address, Value, Size);
        Exit;
      end;
    $05E00000..$05EFFFFF:
      begin
        FVDP2.WriteVRAM(Address, Value, Size);
        Exit;
      end;
    $05F00000..$05F7FFFF:
      begin
        FVDP2.WriteCRAM(Address, Value, Size);
        Exit;
      end;
    $05F80000..$05FBFFFF:
      begin
        FVDP2.WriteRegister(Address, Value, Size);
        Exit;
      end;
    $05FE0000..$05FEFFFF:
      begin
        FSCU.WriteRegister(Address, Value, Size);
        Exit;
      end;
  end;

  for var i := 0 to Size - 1 do
    WriteByte(Address + Cardinal(i), (Value shr ((Size - i - 1) * 8)) and $FF);
end;

function TSaturnConsole.Wait(CPU: Integer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
begin
  // Nominal bus cycles; shared transactions serialize at their start times.
  var Clocks: Integer := 1;
  case Address of
    $00000000..$000FFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 3;
    $00100000..$001FFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 8;
    $00200000..$002FFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 4;
    $02000000..$05FFFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 4;
    $06000000..$07FFFFFF:
      if Writing then
        Clocks := Max(1, (Size + 3) div 4) * 2
      else
      begin
        if Size = 16 then
          Clocks := 8
        else
          Clocks := 3;
      end;
  end;
  var Start := Max(FCPUTime[CPU], FBusUntil);
  Result := Integer(Min(Int64(4096), Start - FCPUTime[CPU])) + Clocks;
  var CDWait := FCD.WaitHost(Address, Size, Writing);
  Inc(Result, CDWait);
  Inc(Clocks, CDWait);
  FBusUntil := Start + Clocks;
end;

function TSaturnConsole.DMAReady(Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;
begin
  Address := Address and $1FFFFFFF;
  Result := True;
  if (FCD.SH1 <> nil) and ((Address = $05818000) or (Address = $05898000)) then
    Result := FCD.SH1.HostReady(Size, Writing);
end;

function TSaturnConsole.ReserveSCUDMA(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;
begin
  Result := ReserveDMA(At, Address, Size, Writing, True);
end;

function TSaturnConsole.ReserveDMA(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean; SCUBurst: Boolean): Int64;
begin
  var Clocks: Integer := 4;
  case Address of
    $00200000..$002FFFFF:
      Clocks := ((Size + 1) div 2) * 4;
    $02000000..$059FFFFF:
      Clocks := ((Size + 1) div 2) * 4;
    $05A00000..$05FDFFFF:
      begin
        Clocks := ((Size + 1) div 2) * 2;
        // SCU burst writes use the 16-bit B-bus at the CPU clock rate.
        // SH-2 DMA accesses and B-bus reads retain their existing latency.
        if SCUBurst and Writing then
          Clocks := (Size + 1) div 2;
      end;
    $06000000..$07FFFFFF:
      begin
        if Writing then
          Clocks := 2
        else
          Clocks := 3;
      end;
  end;

  // SCU owns the CPU bus in burst mode; SH-2 non-burst read timing
  // must not be charged for every SDRAM word. Sega's programming FAQ
  // measures WRAM-H -> VDP1 at about 2.25 clocks/longword. Our serial
  // phases remain conservative at three, rather than the former five.
  if SCUBurst and not Writing and (Address >= $06000000) and (Address <= $07FFFFFF) then
    Clocks := 1;
  Result := Max(At, FBusUntil) + Clocks;
  FBusUntil := Result;
end;

function TSaturnConsole.ReadCPU(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');

  Result := FCPU[CPU].Read(Address, Size);
end;

procedure TSaturnConsole.WriteCPU(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');

  FCPU[CPU].Write(Address, Value, Size);
end;

function TSaturnConsole.CPUState(CPU: Integer): TSH2State;
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');

  Result := FCPU[CPU].State;
end;

procedure TSaturnConsole.SetCPUState(CPU: Integer; const State: TSH2State);
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');

  FCPU[CPU].State := State;
end;

procedure TSaturnConsole.RasterEvent;
begin
  var Active: Integer := 1280;
  var Sync: Integer := 1388;
  var Total: Integer := 1708;
  if FSMPC.Clock352 then
  begin
    Active := 1408;
    Sync := 1500;
    Total := 1820;
  end;
  var Lines := FVDP2.FieldLines;
  case FRasterPhase of
    0:
      begin
        FHBlank := True;
        var RenderY: Integer := FLine;
        if FFrameHeight > 256 then
          RenderY := FLine * 2 + Ord(FVDP2.Field);
        if (FLine < FVDP2.ScanHeight) and (RenderY < FFrameHeight) then
          RenderLine(RenderY, RenderY * FFrameWidth);
        if FLine = FVDP2.ScanHeight then
        begin
          SynchronizeVideo;
          FVDP1.VBlankIn;
        end;
        FSCU.HBlank;
        FRasterPhase := 1;
        FNextRaster := FLineStart + Sync;
      end;
    1:
      begin
        Inc(FLine);
        if FLine = FVDP2.ScanHeight then
        begin
          FSMPC.VBlankIn;
          FSCU.Signal(0);
        end;

        // V-blank OUT precedes the first active line. Software must have
        // time to write FCM/FCT before VDP1 samples them for this field.
        if FLine = Lines - 1 then
          FSCU.VBlankOut;
        if FLine >= Lines then
        begin
          FLine := 0;
          Inc(FFrames);
          SynchronizeVideo;
          FVDP2.NewField;

          // VDP1 exchanges buffers at the field boundary, after V-blank.
          // V-blank-in handlers must be able to finish drawing and request
          // the exchange before CEF is latched into BEF for the new field.
          FVDP1.VBlank;
          FFrameWidth := FVDP2.Width;
          FFrameHeight := FVDP2.Height;
          SetLength(FPixels, FFrameWidth * FFrameHeight);
        end;
        FRasterPhase := 2;
        FNextRaster := FLineStart + Total;
      end;
    2:
      begin
        FHBlank := False;
        FLineStart := FNextRaster;
        FRasterPhase := 0;
        FNextRaster := FLineStart + Active;
      end;
  end;
  FVDP2.SetRaster(FLine, 0, FHBlank, (FLine >= FVDP2.ScanHeight) and (FLine < Lines - 1));
end;

procedure TSaturnConsole.CaptureRaster;
begin
  var Dot: Integer := Max(0, Integer(FTime - FLineStart)) div 4;
  var TotalDots: Integer := 427;
  var SyncDot: Integer := 347;
  if FSMPC.Clock352 then
  begin
    TotalDots := 455;
    SyncDot := 375;
  end;
  if Dot >= SyncDot then
    Inc(Dot, 512 - TotalDots);
  var Lines := FVDP2.FieldLines;
  FVDP2.SetRaster(FLine, (Dot * 2) and $3FF, FHBlank, (FLine >= FVDP2.ScanHeight) and (FLine < Lines - 1));
end;

// The scheduler bounds intervals/counters before entering this hot path.
{$Q-}
procedure TSaturnConsole.AdvanceDevices(Target: Int64);
begin
  var VDP1BusBusy := FSCU.VDP1BusBusy;
  if FSoundDMAActive then
    SoundDMA(Target)
  else
  begin
    FSoundDMAControl := (Word(FSoundRegisters[$416]) shl 8) or FSoundRegisters[$417];
    if FSoundDMAControl and $1000 <> 0 then
      SoundDMA(Target);
  end;
  Inc(FSamplePhase, (Target - FTime) * 44100);
  while FSamplePhase >= FClock do
  begin
    Dec(FSamplePhase, FClock);
    SoundTick;
  end;
  FTime := Target;
  FCPU[0].AdvanceForward(Target);
  if FSlaveOn then
    FCPU[1].AdvanceForward(Target);
  FSCU.AdvanceForward(Target);
  FSMPC.AdvanceForward(Target);
  FVDP1.AdvanceForward(Target, VDP1BusBusy);
  FCD.AdvanceForward(Target);
  while FNextRaster <= Target do
    RasterEvent;
end;

// CPU is selected only from master/slave (sound is handled before indexing).
{$R-}
procedure TSaturnConsole.RunCycles(Cycles: Int64);
begin
  if (Cycles < 0) or (Cycles > Int64(FClock) * 60) then
    raise EArgumentOutOfRangeException.Create('Saturn run interval');

  {$Q+}
  var Target := FTime + Cycles;
  // Reserve the maximum 60-second interval plus instruction overshoot.
  if (Target > High(Int64) - Int64(30000000) * 61) or
    (FCPUTime[0] > High(Int64) - Int64(30000000) * 61) or
    (FCPUTime[1] > High(Int64) - Int64(30000000) * 61) or
    (FSoundAt > High(Int64) - Int64(30000000) * 61) then
    raise EArgumentOutOfRangeException.Create('Saturn clock counter exhausted');

  {$Q-}
  while FTime < Target do
  begin
    var CPU: Integer := 0;
    if FSlaveOn and (FCPUTime[1] < FCPUTime[0]) then
      CPU := 1;
    var Due := FCPUTime[CPU];
    if FSoundOn and (FSoundAt < Due) then
    begin
      CPU := 2;
      Due := FSoundAt;
    end;
    // Do not step over DMA ownership changes while advancing VDP1 drawing.
    var Next := Min(Target, Min(FNextRaster, Min(Due, FSCU.NextDMA)));
    if Next > FTime then
      AdvanceDevices(Next);
    if FResetPending then
    begin
      Reset;
      Exit;
    end;

    if FTime >= Target then
      Break;

    if Due > FTime then
      Continue;

    if CPU = 2 then
    begin
      var Used := Clown68000DoCycles(FSoundCPU, FSoundCallbacks, 1);
      Inc(FSoundFraction, Int64(Used) * FClock);
      var SoundClocks := FSoundFraction div 11289600;
      Inc(FSoundAt, SoundClocks);
      Dec(FSoundFraction, SoundClocks * 11289600);
      Continue;
    end;

    // Events are visible to both CPUs before instruction issue is attempted.
    if Assigned(FInstructionObserver) then
    begin
      SynchronizeVideo;
      FInstructionObserver(CPU, FCPU[CPU].State);
    end;
    if FSCU.CPUBusBusy then
    begin
      var CachedSpent := FCPU[CPU].StepBusReleased;
      if CachedSpent <> 0 then
      begin
        Inc(FCPUTime[CPU], CachedSpent);
        Continue;
      end;

      // A cache miss, store or other checked instruction waits for the next
      // DMA phase; devices and raster events keep advancing during the wait.
      var UntilDMA := Min(Target, Min(FNextRaster, FSCU.NextDMA));
      var Held := Integer(Min(Int64(4096), Max(Int64(1), UntilDMA - FCPUTime[CPU])));
      FCPU[CPU].Hold(Held);
      Inc(FCPUTime[CPU], Held);
      Continue;
    end;
    var Vector := FIRQVector;
    var Spent := FCPU[CPU].Step;
    Inc(FCPUTime[CPU], Spent);

    // A higher-priority on-chip IRQ also pushes eight bytes, but must not
    // acknowledge the SCU. Use the CPU's actual interrupt acceptance event.
    if (CPU = 0) and FCPU[CPU].ExternalInterruptAccepted then
      FSCU.Acknowledge(Vector);
  end;
  if not FRunningFrame then
    SynchronizeVideo;
end;

{$Q+}{$R+}

procedure TSaturnConsole.RunFrame;
begin
  FSampleFrames := 0;
  var Frame := FFrames;

  // A frame ends at the VDP2 field event, not at the next arbitrary
  // 1708-clock chunk. This also handles 1820-clock lines and interlace.
  FRunningFrame := True;
  try
    while FFrames = Frame do
      RunCycles(Max(Int64(1), FNextRaster - FTime));
  finally
    FRunningFrame := False;
    SynchronizeVideo;
  end;
end;

procedure TSaturnConsole.SetInput(Port: Integer; Buttons: TSaturnButtons; Connected: Boolean);
begin
  FSMPC.SetInput(Port, Buttons, Connected);
end;

procedure TSaturnConsole.LoadBackup(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FBackup) then
    raise EReadError.Create('Saturn backup RAM size');

  Move(Data[0], FBackup, SizeOf(FBackup));
  FBackupDirty := False;
end;

function TSaturnConsole.Backup: TBytes;
begin
  SetLength(Result, SizeOf(FBackup));
  Move(FBackup, Result[0], SizeOf(FBackup));
end;

function TSaturnConsole.FramesPerSecond: Double;
begin
  var Lines: Double := 263;
  if FPAL then
    Lines := 313;
  if FVDP2.ReadRegister(0, 2) and $80 <> 0 then
    Lines := Lines - 0.5;
  var LineClocks: Integer := 1708;
  if FSMPC.Clock352 then
    LineClocks := 1820;
  Result := FClock / (LineClocks * Lines);
end;

procedure TSaturnConsole.SerializeState(Archive: TStateArchive);
begin
  SynchronizeVideo;
  var Version: Cardinal := $53415409;
  Archive.Field(Version, SizeOf(Version));
  if (Version < $53415404) or (Version > $53415409) then
    raise EReadError.Create('Unsupported Saturn snapshot format; a current Saturn snapshot is required');

  var Hash := THashSHA2.Create;
  Hash.Update(FBIOS);
  var Identity := Hash.HashAsBytes;
  var Expected := Copy(Identity);
  Archive.Field(Identity[0], Length(Identity));
  if Archive.Loading and not CompareMem(@Identity[0], @Expected[0], Length(Identity)) then
    raise EReadError.Create('Saturn snapshot BIOS mismatch');

  SetLength(Identity, 32);
  FillChar(Identity[0], 32, 0);
  if FCD.Disc <> nil then
  begin
    Hash := THashSHA2.Create;
    Hash.Update(FCD.Disc.Identity);
    Identity := Hash.HashAsBytes;
  end;
  Expected := Copy(Identity);
  Archive.Field(Identity[0], Length(Identity));
  if Archive.Loading and not CompareMem(@Identity[0], @Expected[0], Length(Identity)) then
    raise EReadError.Create('Saturn snapshot disc mismatch');

  Archive.Field(FWorkLow, SizeOf(FWorkLow));
  Archive.Field(FWorkHigh, SizeOf(FWorkHigh));
  Archive.Field(FBackup, SizeOf(FBackup));
  Archive.Field(FSoundCPU, SizeOf(FSoundCPU));
  Archive.Field(FSoundAt, SizeOf(FSoundAt));
  Archive.Field(FSoundFraction, SizeOf(FSoundFraction));
  Archive.Field(FSoundDMAActive, SizeOf(FSoundDMAActive));
  Archive.Field(FSoundDMANext, SizeOf(FSoundDMANext));
  Archive.Field(FSoundDMAMemory, SizeOf(FSoundDMAMemory));
  Archive.Field(FSoundDMARegister, SizeOf(FSoundDMARegister));
  Archive.Field(FSoundDMACount, SizeOf(FSoundDMACount));
  Archive.Field(FSoundDMAControl, SizeOf(FSoundDMAControl));
  Archive.Field(FSamplePhase, SizeOf(FSamplePhase));
  Archive.Field(FTimerPhase, SizeOf(FTimerPhase));
  Archive.Field(FSoundPending, SizeOf(FSoundPending));
  Archive.Field(FMainSoundPending, SizeOf(FMainSoundPending));
  Archive.Field(FSound, SizeOf(FSound));
  Archive.Field(FSoundRegisters, SizeOf(FSoundRegisters));
  FCPU[0].SerializeState(Archive);
  FCPU[1].SerializeState(Archive);
  FSCU.SerializeState(Archive, Version >= $53415408);
  FSMPC.SerializeState(Archive);
  FVDP1.SerializeState(Archive, Version >= $53415407);
  FVDP2.SerializeState(Archive, Version >= $53415405);
  Archive.Field(FCPUTime, SizeOf(FCPUTime));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FNextRaster, SizeOf(FNextRaster));
  Archive.Field(FLineStart, SizeOf(FLineStart));
  Archive.Field(FRasterPhase, SizeOf(FRasterPhase));
  Archive.Field(FLine, SizeOf(FLine));
  Archive.Field(FClock, SizeOf(FClock));
  Archive.Field(FHBlank, SizeOf(FHBlank));
  Archive.Field(FSlaveOn, SizeOf(FSlaveOn));
  Archive.Field(FSoundOn, SizeOf(FSoundOn));
  Archive.Field(FResetPending, SizeOf(FResetPending));
  Archive.Field(FPAL, SizeOf(FPAL));
  Archive.Field(FFrames, SizeOf(FFrames));
  Archive.Field(FFrameWidth, SizeOf(FFrameWidth));
  Archive.Field(FFrameHeight, SizeOf(FFrameHeight));
  FCD.SerializeState(Archive, Version >= $53415405, Version >= $53415406, Version >= $53415409);
  FSCSP.SerializeState(Archive);
  FCartridge.SerializeState(Archive);
  Archive.Field(FSampleFrames, SizeOf(FSampleFrames));
  if (FSampleFrames < 0) or (FSampleFrames > 4096) then
    raise EReadError.Create('Saturn snapshot audio size');

  if FSampleFrames > 0 then
    Archive.Field(FSamples[0], FSampleFrames * 4);
  Archive.Field(FBusUntil, SizeOf(FBusUntil));
  Archive.Field(FIRQLevel, SizeOf(FIRQLevel));
  Archive.Field(FIRQVector, SizeOf(FIRQVector));
  if (FTime < 0) or (FNextRaster < FTime) or (FCPUTime[0] < FTime) or (FSlaveOn and (FCPUTime[1] < FTime)) or (FClock < 20000000) or (FClock > 30000000) or (FSoundFraction < 0) or (FSoundFraction >= 11289600) or (FSamplePhase < 0) or (FSamplePhase >= FClock) or (FFrameWidth < 320) or (FFrameWidth > 704) or (FFrameHeight < 224) or (FFrameHeight > 512) or (FLine < 0) or (FLine > 312) or
    (FRasterPhase < 0) or (FRasterPhase > 2) or (FLineStart < 0) or (FLineStart > FTime) or
    (FSoundDMACount < 0) or (FSoundDMACount > $FFE) or (FSoundDMAActive and ((FSoundDMACount = 0) or (FSoundDMANext < FTime))) then
    raise EReadError.Create('Saturn state timing');

  SetLength(FPixels, FFrameWidth * FFrameHeight);
  Archive.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
  if Archive.Loading then
    FBackupDirty := True;
end;

end.

