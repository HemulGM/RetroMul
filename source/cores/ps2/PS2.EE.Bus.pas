unit PS2.EE.Bus;

// EE physical memory and MMIO: 32 MiB RAM, BIOS ROM, IOP RAM window, VU
// memories, and the register blocks (timers, IPU, GIF, VIF, FIFOs, DMAC,
// INTC, SIO, SIF, GS privileged). Unknown registers keep written values.
// RAM pages carry write generations for the CPU's decoded blocks.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Snapshots,
  PS2.Types, PS2.Scheduler, PS2.EE.CPU, PS2.Timers, PS2.DMAC, PS2.SIF,
  PS2.SIF.Bridge, PS2.CDVD.Drive, PS2.VU1Domain;

type
  // A register block outside the bus (GIF/GS, VIF, IPU): 32/64-bit
  // registers and 128-bit FIFO writes.
  TPS2Device = class
  public
    function Read(Address: Cardinal; Size: Integer): UInt64; virtual;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); virtual;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); virtual;
    procedure ReadFIFO(Address: Cardinal; out Value: TPS2Reg128); virtual;
  end;

  TPS2TTYWrite = procedure(const Text: string) of object;

  TPS2EEBus = class(TEEBus)
  private
    FScheduler: TPS2Scheduler;
    FRAMGen: array[0..PS2RAMSize shr 12 - 1] of Cardinal;
    FIOPGen: array[0..PS2IOPRAMSize shr 12 - 1] of Cardinal;
    FConstGen: Cardinal;
    FRegs: array[0..$3FFF] of Cardinal;
    FINTCStat, FINTCMask: Cardinal;
    FKernelLine: Boolean;
    FSIOLine: string;
    FOnTTY: TPS2TTYWrite;
    FReadSeen: TDictionary<Cardinal, Integer>;
    procedure UpdateINT0;
    procedure SIOPut(C: Byte);
    function MCHRead: Cardinal;
    // Diagnostics lines, apart: no string temporaries in Read and Write.
    procedure LogRegisterRead(Address: Cardinal);
    procedure LogUnmappedRead(Address: Cardinal; Size: Integer);
    procedure LogRegisterWrite(Address: Cardinal; Value: UInt64; Size: Integer);
    function ReadHere(Address: Cardinal; Size: Integer): UInt64;
    function ReadAhead(Address: Cardinal; Size: Integer; out Value: UInt64): Boolean;
    procedure WriteHere(Address: Cardinal; Value: UInt64; Size: Integer);
  public
    RAM, BIOS, IOPRAM: PByte;
    VU0Code, VU0Data, VU1Code, VU1Data: PByte;
    // VU0 (0) or VU1 (1) micro memory written by the EE (its pages are not
    // mapped for direct access): the core's compiled code looks again.
    OnCodeWritten: procedure(Index: Integer) of object;
    CPU: TEECPU;
    Timers: TPS2Timers;
    DMAC: TPS2DMAC;
    SIF: TPS2SIF;
    // The SIF hardware when the IOP runs its own kernel (it then answers the
    // SIF registers instead of the high-level SIF).
    SIFBridge: TPS2SIFBridge;
    // RDRAM initialization (MCH_RICM at 1000F430h, MCH_DRD at 1000F440h):
    // the BIOS sends commands and reads the devices' answers.
    MCHRicm, MCHDrd: Cardinal;
    RDRAMDevice: Integer;
    // The command interface at 1A000000h the BIOS drives during its
    // initialization (16-bit registers): a command written to register 0
    // with bit 7 completes at once and sets bit 1 (done) of register 6,
    // which writes to register 6 clear.
    CmdRegs: array[0..15] of Word;
    // The CDVD drive's registers, which the EE reaches at 1F402000h too (the
    // BIOS browser reads the disc type and drive status there).
    CDVD: TPS2CDVDDrive;
    // Diagnostics: INTC causes raised.
    IRQCounts: array[0..15] of Int64;
    GS, GIF, VIF0, VIF1, IPU: TPS2Device;
    // Its registers, FIFOs, micro memory, the DMAC and the GS are reached
    // inside it.
    VU1Domain: TPS2VU1Domain;
    MMIOReads, MMIOWrites: Int64;
    // Diagnostics: accesses per address when assigned (reads; writes with bit 0 set).
    MMIOCounts: TDictionary<Cardinal, Int64>;
    LastReadPC: TDictionary<Cardinal, Cardinal>;
    // Diagnostics: accesses to registers without a device (the plain
    // register file), writes always, reads the first times per address.
    RegisterLog: TStrings;
    constructor Create(Scheduler: TPS2Scheduler);
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure Read128(Address: Cardinal; out Value: TPS2Reg128); override;
    procedure Write128(Address: Cardinal; const Value: TPS2Reg128); override;
    function PagePointer(Page: Cardinal; Writing: Boolean): PByte; override;
    function PageGeneration(Page: Cardinal): PCardinal; override;
    function CPCond0: Boolean; override;
    // INTC: devices raise a cause (sets INTC_STAT).
    procedure RaiseIRQ(Cause: Integer);
    // Whether RaiseIRQ(Cause) would change nothing now (the cause is set and
    // INT0 is as INTC says).
    function IRQRaised(Cause: Integer): Boolean;
    procedure AcknowledgeIRQ(Cause: Integer);
    procedure SetINTCMask(Value: Cardinal);
    // An extra INT0 source of the HLE kernel (alarms).
    procedure SetKernelLine(Active: Boolean);
    // Code changed in RAM outside the CPU (DMA, loaders): bump generations.
    procedure MarkRAM(Address, Size: Cardinal);
    function RAMGenerations: PCardinal;
    procedure SerializeState(State: TStateArchive);
    property INTCStat: Cardinal read FINTCStat;
    property INTCMask: Cardinal read FINTCMask;
    property OnTTY: TPS2TTYWrite read FOnTTY write FOnTTY;
  end;

implementation

{ TPS2Device }

function TPS2Device.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  Result := 0;
end;

procedure TPS2Device.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
end;

procedure TPS2Device.WriteFIFO(Address: Cardinal; const Value: TPS2Reg128);
begin
end;

procedure TPS2Device.ReadFIFO(Address: Cardinal; out Value: TPS2Reg128);
begin
  Value := Default(TPS2Reg128);
end;

{ TPS2EEBus }

constructor TPS2EEBus.Create(Scheduler: TPS2Scheduler);
begin
  inherited Create;
  FScheduler := Scheduler;
  RAM := AllocMem(PS2RAMSize + 64);
  BIOS := AllocMem(PS2BIOSSize);
  IOPRAM := AllocMem(PS2IOPRAMSize + 64);
  VU0Code := AllocMem($1000);
  VU0Data := AllocMem($1000);
  VU1Code := AllocMem($4000);
  VU1Data := AllocMem($4000);
end;

destructor TPS2EEBus.Destroy;
begin
  FreeMem(RAM);
  FreeMem(BIOS);
  FreeMem(IOPRAM);
  FreeMem(VU0Code);
  FreeMem(VU0Data);
  FreeMem(VU1Code);
  FreeMem(VU1Data);
  FReadSeen.Free;
  inherited;
end;

procedure TPS2EEBus.Reset;
begin
  FillChar(RAM^, PS2RAMSize, 0);
  FillChar(IOPRAM^, PS2IOPRAMSize, 0);
  FillChar(VU0Code^, $1000, 0);
  FillChar(VU0Data^, $1000, 0);
  FillChar(VU1Code^, $4000, 0);
  FillChar(VU1Data^, $4000, 0);
  for var K := 0 to High(FRAMGen) do
    Inc(FRAMGen[K]);
  FillChar(FRegs, SizeOf(FRegs), 0);
  FINTCStat := 0;
  FINTCMask := 0;
  FKernelLine := False;
  FSIOLine := '';
  MCHRicm := 0;
  MCHDrd := 0;
  RDRAMDevice := 0;
  FillChar(CmdRegs, SizeOf(CmdRegs), 0);
  MMIOReads := 0;
  MMIOWrites := 0;
end;

function TPS2EEBus.RAMGenerations: PCardinal;
begin
  Result := @FRAMGen[0];
end;

procedure TPS2EEBus.MarkRAM(Address, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  Address := Address and PS2RAMMask;
  if (DMAC <> nil) and (DMAC.WatchLog <> nil) and (DMAC.WatchAddress >= Address) and (DMAC.WatchAddress < Address + Size) then
    DMAC.WatchLog.Add(Format('%d bus write %.8x size %x', [FScheduler.Now, Address, Size]));
  var Last := (Address + Size - 1) shr 12;
  if Last > High(FRAMGen) then
    Last := High(FRAMGen);
  for var P := Address shr 12 to Last do
    Inc(FRAMGen[P]);
end;

function TPS2EEBus.PagePointer(Page: Cardinal; Writing: Boolean): PByte;
begin
  var A := Page shl 12;
  if A < PS2RAMSize then
    Exit(RAM + A);
  case A of
    // (Micro memory: not mapped at all, else the CPU takes the page for ROM;
    // Read and Write. VU1 data belongs to the VU1 domain.)
    $11000000:
      Exit(nil);
    $11004000:
      Exit(VU0Data);
    $11008000..$1100F000:
      Exit(nil);
    $1C000000..$1C1FF000:
      Exit(IOPRAM + (A - $1C000000));
    $1FC00000..$1FFFF000:
      if Writing then
        Exit(nil)
      else
        Exit(BIOS + (A - $1FC00000));
  end;
  Result := nil;
end;

function TPS2EEBus.PageGeneration(Page: Cardinal): PCardinal;
begin
  var A := Page shl 12;
  if A < PS2RAMSize then
    Exit(@FRAMGen[Page]);
  if (A >= $1C000000) and (A < $1C200000) then
    Exit(@FIOPGen[(A - $1C000000) shr 12]);
  Result := @FConstGen;
end;

function TPS2EEBus.CPCond0: Boolean;
begin
  var Entered := VU1Domain.EnterKind(deLocal);
  try
    Result := DMAC.CPCond0;
  finally
    if Entered then
      VU1Domain.Leave;
  end;
end;

procedure TPS2EEBus.UpdateINT0;
begin
  if CPU <> nil then
    CPU.SetInt0(((FINTCStat and FINTCMask) <> 0) or FKernelLine);
end;

procedure TPS2EEBus.RaiseIRQ(Cause: Integer);
begin
  Inc(IRQCounts[Cause and 15]);
  FINTCStat := FINTCStat or (Cardinal(1) shl Cause);
  UpdateINT0;
end;

function TPS2EEBus.IRQRaised(Cause: Integer): Boolean;
begin
  Result := ((FINTCStat and (Cardinal(1) shl Cause)) <> 0) and
    ((CPU = nil) or (CPU.Int0 = (((FINTCStat and FINTCMask) <> 0) or FKernelLine)));
end;

procedure TPS2EEBus.AcknowledgeIRQ(Cause: Integer);
begin
  FINTCStat := FINTCStat and not (Cardinal(1) shl Cause);
  UpdateINT0;
end;

procedure TPS2EEBus.SetINTCMask(Value: Cardinal);
begin
  FINTCMask := Value and $7FFF;
  UpdateINT0;
end;

procedure TPS2EEBus.SetKernelLine(Active: Boolean);
begin
  FKernelLine := Active;
  UpdateINT0;
end;

// The answer to the last RDRAM command (ps2tek, EE RDRAM initialization):
// the two devices' IDs, then their configuration registers.
function TPS2EEBus.MCHRead: Cardinal;
begin
  Result := 0;
  var SOP := (MCHRicm shr 6) and $F;
  var SA := (MCHRicm shr 16) and $FFF;
  if SOP <> 0 then
    Exit;
  case SA of
    $21:
      if RDRAMDevice < 2 then
      begin
        Inc(RDRAMDevice);
        Result := $1F;
      end;
    $23:
      Result := $0D0D;
    $24:
      Result := $0090;
    $40:
      Result := MCHRicm and $1F;
  end;
end;

procedure TPS2EEBus.SIOPut(C: Byte);
begin
  if C = 13 then
    Exit;
  if C = 10 then
  begin
    if Assigned(FOnTTY) then
      FOnTTY(FSIOLine + #10);
    FSIOLine := '';
  end
  else
    FSIOLine := FSIOLine + Char(C);
end;

procedure TPS2EEBus.LogRegisterRead(Address: Cardinal);
begin
  RegisterLog.Add(Format('ee r %.8x = %.8x pc %.8x', [Address, FRegs[(Address and $FFFC) shr 2], CPU.SlowPC]));
end;

procedure TPS2EEBus.LogUnmappedRead(Address: Cardinal; Size: Integer);
begin
  RegisterLog.Add(Format('ee r unmapped %.8x/%d pc %.8x', [Address, Size, CPU.SlowPC]));
end;

procedure TPS2EEBus.LogRegisterWrite(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  RegisterLog.Add(Format('ee w %.8x = %.8x/%d pc %.8x', [Address, Value, Size, CPU.SlowPC]));
end;

// Whether Address is in the VU1 domain: GIF, VIF1, DMAC, D_ENABLE, VU1
// micro memory, GS.
function DomainAddress(Address: Cardinal): Boolean; inline;
begin
  case Address of
    $10003000..$100037FF, $10003C00..$10003FFF, $10008000..$1000EFFF, $1000F520, $1000F590, $11008000..$1100FFFF, $12000000..$12001FFF:
      Result := True;
  else
    Result := False;
  end;
end;

// The VU1 domain's part an access reaches (DomainAddress).
function EntryKind(Address: Cardinal): TPS2DomainEntry; inline;
begin
  case Address of
    $12000000..$12001FFF:
      Result := deGS;
    // D_STAT, D_PCR, D_SQWC, D_RBSR, D_RBOR, D_STADR (channels 1 and 2 use
    // the last three only with MFIFO or stall control, which D_CTRL turns
    // on) and the other channels' registers.
      $1000E010..$1000E06F, $10008000..$10008FFF, $1000B000..$1000DFFF:
      Result := deLocal;
  else
    Result := deDomain;
  end;
end;

function TPS2EEBus.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  if (VU1Domain = nil) or not DomainAddress(Address) then
    Exit(ReadHere(Address, Size));
  if VU1Domain.Ahead and ReadAhead(Address, Size, Result) then
    Exit;
  var Entered := VU1Domain.EnterKind(EntryKind(Address));
  try
    Result := ReadHere(Address, Size);
  finally
    if Entered then
      VU1Domain.Leave;
  end;
end;

// Running ahead: the domain's own registers as it had them at the EE time,
// those it leaves alone (the DMAC's other channels and shared registers,
// D_ENABLER) as they are. False: the domain is entered.
function TPS2EEBus.ReadAhead(Address: Cardinal; Size: Integer; out Value: UInt64): Boolean;
begin
  case Address of
    $10003000..$100037FF, $10003C00..$10003FFF, $10009000..$100090FF, $1000A000..$1000A0FF:
      begin
        Result := Assigned(VU1Domain.OnAheadRead) and VU1Domain.OnAheadRead(Address, Value);
        if Result then
          Inc(MMIOReads);
      end;
    $10008000..$10008FFF, $10009100..$10009FFF, $1000A100..$1000EFFF, $1000F520:
      begin
        Value := ReadHere(Address, Size);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

function TPS2EEBus.ReadHere(Address: Cardinal; Size: Integer): UInt64;
begin
  // Micro memory, whose pages are not mapped (not counted as MMIO).
  if ((Address >= $11000000) and (Address <= $11000FFF)) or ((Address >= $11008000) and (Address <= $1100FFFF)) then
  begin
    var P := VU0Code + (Address and $FFF);
    if Address >= $1100C000 then
      P := VU1Data + (Address and $3FFF)
    else if Address >= $11008000 then
      P := VU1Code + (Address and $3FFF);
    case Size of
      1:
        Exit(P^);
      2:
        Exit(PWord(P)^);
      4:
        Exit(PCardinal(P)^);
    else
      Exit(PUInt64(P)^);
    end;
  end;
  Inc(MMIOReads);
  if MMIOCounts <> nil then
  begin
    var N: Int64;
    MMIOCounts.TryGetValue(Address, N);
    MMIOCounts.AddOrSetValue(Address, N + 1);
    LastReadPC.AddOrSetValue(Address, CPU.SlowPC);
  end;
  case Address of
    $10000000..$10001FFF:
      Exit(Timers.Read(Address));
    $10002000..$10002FFF:
      if IPU <> nil then
        Exit(IPU.Read(Address, Size));
    $10003000..$100037FF:
      if GIF <> nil then
        Exit(GIF.Read(Address, Size));
    $10003800..$10003BFF:
      if VIF0 <> nil then
        Exit(VIF0.Read(Address, Size));
    $10003C00..$10003FFF:
      if VIF1 <> nil then
        Exit(VIF1.Read(Address, Size));
    $10008000..$1000EFFF:
      Exit(DMAC.Read(Address and not 3));
    $1000F000:
      Exit(FINTCStat);
    $1000F010:
      Exit(FINTCMask);
    $1000F130:
      Exit(0);
    $1000F200..$1000F2FF:
      if SIFBridge <> nil then
        Exit(SIFBridge.EERead(Address and $FF))
      else
        Exit(SIF.ReadRegister(((Address shr 4) and $F) + 1));
    $1000F430:
      Exit(0);
    $1000F440:
      Exit(MCHRead);
    $1A000000..$1A00FFFF:
      Exit(CmdRegs[(Address shr 1) and 15]);
    $1F402000..$1F4020FF:
      if CDVD <> nil then
        Exit(CDVD.Read(Address and $FF));
    $1000F520:
      Exit(DMAC.ENABLE);
    $12000000..$12001FFF:
      if GS <> nil then
        Exit(GS.Read(Address, Size));
  end;
  if (Address >= $10000000) and (Address < $10010000) then
  begin
    if (RegisterLog <> nil) and (RegisterLog.Count < 2000) then
    begin
      if FReadSeen = nil then
        FReadSeen := TDictionary<Cardinal, Integer>.Create;
      var Seen: Integer;
      FReadSeen.TryGetValue(Address, Seen);
      if Seen < 3 then
        LogRegisterRead(Address);
      FReadSeen.AddOrSetValue(Address, Seen + 1);
    end;
    var V := UInt64(FRegs[(Address and $FFFC) shr 2]);
    if Size = 8 then
      V := V or (UInt64(FRegs[((Address + 4) and $FFFC) shr 2]) shl 32);
    Exit(V shr ((Address and 3) * 8));
  end;
  if (RegisterLog <> nil) and (RegisterLog.Count < 4000) then
    LogUnmappedRead(Address, Size);
  Result := 0;
end;

procedure TPS2EEBus.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  if (VU1Domain = nil) or not DomainAddress(Address) then
  begin
    WriteHere(Address, Value, Size);
    Exit;
  end;
  var Kind := EntryKind(Address);
  // (With MFIFO on, the drain reads the ring D_RBSR and D_RBOR make.)
  if ((Address = $1000E040) or (Address = $1000E050)) and ((DMAC.CTRL and $0C) <> 0) then
    Kind := deDomain;
  var Entered := VU1Domain.EnterKind(Kind);
  try
    WriteHere(Address, Value, Size);
  finally
    if Entered then
      VU1Domain.Leave;
  end;
end;

procedure TPS2EEBus.WriteHere(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  // Micro memory (not counted as MMIO): compiled code looks at code again.
  if ((Address >= $11000000) and (Address <= $11000FFF)) or ((Address >= $11008000) and (Address <= $1100FFFF)) then
  begin
    var Index := 0;
    var P := VU0Code + (Address and $FFF);
    if Address >= $1100C000 then
    begin
      Index := -1;
      P := VU1Data + (Address and $3FFF);
    end
    else if Address >= $11008000 then
    begin
      Index := 1;
      P := VU1Code + (Address and $3FFF);
    end;
    case Size of
      1:
        P^ := Byte(Value);
      2:
        PWord(P)^ := Word(Value);
      4:
        PCardinal(P)^ := Cardinal(Value);
    else
      PUInt64(P)^ := Value;
    end;
    if (Index >= 0) and Assigned(OnCodeWritten) then
      OnCodeWritten(Index);
    Exit;
  end;
  Inc(MMIOWrites);
  if MMIOCounts <> nil then
  begin
    var N: Int64;
    MMIOCounts.TryGetValue(Address or 1, N);
    MMIOCounts.AddOrSetValue(Address or 1, N + 1);
  end;
  case Address of
    $10000000..$10001FFF:
      begin
        Timers.Write(Address, Cardinal(Value));
        CPU.RequestExit;
        Exit;
      end;
    $10002000..$10002FFF:
      if IPU <> nil then
      begin
        IPU.Write(Address, Value, Size);
        CPU.RequestExit;
        Exit;
      end;
    $10003000..$100037FF:
      if GIF <> nil then
      begin
        GIF.Write(Address, Value, Size);
        Exit;
      end;
    $10003800..$10003BFF:
      if VIF0 <> nil then
      begin
        VIF0.Write(Address, Value, Size);
        Exit;
      end;
    $10003C00..$10003FFF:
      if VIF1 <> nil then
      begin
        VIF1.Write(Address, Value, Size);
        Exit;
      end;
    $10008000..$1000EFFF:
      begin
        DMAC.Write(Address and not 3, Cardinal(Value));
        CPU.RequestExit;
        Exit;
      end;
    $1000F000:
      begin
        FINTCStat := FINTCStat and not Cardinal(Value);
        UpdateINT0;
        Exit;
      end;
    $1000F010:
      begin
        FINTCMask := (FINTCMask xor Cardinal(Value)) and $7FFF;
        UpdateINT0;
        Exit;
      end;
    $1000F180:
      begin
        SIOPut(Byte(Value));
        Exit;
      end;
    $1000F200..$1000F2FF:
      begin
        if SIFBridge <> nil then
          SIFBridge.EEWrite(Address and $FF, Cardinal(Value))
        else
          SIF.WriteRegister(((Address shr 4) and $F) + 1, Cardinal(Value));
        Exit;
      end;
    $1000F430:
      begin
      // A command to the RDRAM devices; a broadcast device-ID reset (SA
      // 21h, SBC 1) restarts the device count.
        var SA := (Cardinal(Value) shr 16) and $FFF;
        var SBC := (Cardinal(Value) shr 6) and $F;
        if (SA = $21) and (SBC = 1) and (((MCHDrd shr 7) and 1) = 0) then
          RDRAMDevice := 0;
        MCHRicm := Cardinal(Value) and not Cardinal($80000000);
        Exit;
      end;
    $1000F440:
      begin
        MCHDrd := Cardinal(Value);
        Exit;
      end;
    $1A000000..$1A00FFFF:
      begin
        var R := (Address shr 1) and 15;
        if R = 3 then
          CmdRegs[3] := CmdRegs[3] and not Word(Value)
        else
          CmdRegs[R] := Word(Value);
        if (R = 0) and ((Value and $80) <> 0) then
          CmdRegs[3] := CmdRegs[3] or 2;
        Exit;
      end;
    $1F402000..$1F4020FF:
      if CDVD <> nil then
      begin
        CDVD.Write(Address and $FF, Byte(Value));
        Exit;
      end;
    $1000F410:
      begin
      // Memory controller command: bit 31 starts it and reads back clear
      // (the command has completed).
        FRegs[$F410 shr 2] := Cardinal(Value) and not Cardinal($80000000);
        Exit;
      end;
    $1000F590:
      begin
        DMAC.ENABLE := Cardinal(Value);
        Exit;
      end;
    $12000000..$12001FFF:
      if GS <> nil then
      begin
        GS.Write(Address, Value, Size);
        Exit;
      end;
  end;
  if (RegisterLog <> nil) and (RegisterLog.Count < 2000) then
    LogRegisterWrite(Address, Value, Size);
  if (Address >= $10000000) and (Address < $10010000) then
  begin
    var Index := (Address and $FFFC) shr 2;
    case Size of
      1, 2:
        begin
          var Shift := (Address and 3) * 8;
          var Mask := ((Cardinal(1) shl (Size * 8)) - 1) shl Shift;
          FRegs[Index] := (FRegs[Index] and not Mask) or ((Cardinal(Value) shl Shift) and Mask);
        end;
      8:
        begin
          FRegs[Index] := Cardinal(Value);
          FRegs[(Index + 1) and $3FFF] := Cardinal(Value shr 32);
        end;
    else
      FRegs[Index] := Cardinal(Value);
    end;
  end;
end;

procedure TPS2EEBus.Read128(Address: Cardinal; out Value: TPS2Reg128);
begin
  case Address and not Cardinal($F) of
    $10004000, $10005000, $10006000, $10007000, $10007010:
      begin
        var Dev: TPS2Device := nil;
        case (Address shr 12) and $F of
          4:
            Dev := VIF0;
          5:
            Dev := VIF1;
          6:
            Dev := GIF;
          7:
            Dev := IPU;
        end;
        if Dev = nil then
          Value := Default(TPS2Reg128)
        else if (Dev = VIF1) or (Dev = GIF) then
        begin
          VU1Domain.Enter;
          try
            Dev.ReadFIFO(Address, Value);
          finally
            VU1Domain.Leave;
          end;
        end
        else
          Dev.ReadFIFO(Address, Value);
        Exit;
      end;
  end;
  inherited Read128(Address, Value);
end;

procedure TPS2EEBus.Write128(Address: Cardinal; const Value: TPS2Reg128);
begin
  case Address and not Cardinal($F) of
    $10004000, $10005000, $10006000, $10007000, $10007010:
      begin
        var Dev: TPS2Device := nil;
        case (Address shr 12) and $F of
          4:
            Dev := VIF0;
          5:
            Dev := VIF1;
          6:
            Dev := GIF;
          7:
            Dev := IPU;
        end;
        if (Dev <> nil) and ((Dev = VIF1) or (Dev = GIF)) then
        begin
          VU1Domain.Enter;
          try
            Dev.WriteFIFO(Address, Value);
          finally
            VU1Domain.Leave;
          end;
        end
        else if Dev <> nil then
          Dev.WriteFIFO(Address, Value);
        Exit;
      end;
  end;
  inherited Write128(Address, Value);
end;

procedure TPS2EEBus.SerializeState(State: TStateArchive);
begin
  State.Field(RAM^, PS2RAMSize);
  State.Field(IOPRAM^, PS2IOPRAMSize);
  State.Field(VU0Code^, $1000);
  State.Field(VU0Data^, $1000);
  State.Field(VU1Code^, $4000);
  State.Field(VU1Data^, $4000);
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FINTCStat, SizeOf(FINTCStat));
  State.Field(FINTCMask, SizeOf(FINTCMask));
  State.Field(FKernelLine, SizeOf(FKernelLine));
  if State.Loading then
  begin
    for var K := 0 to High(FRAMGen) do
      Inc(FRAMGen[K]);
    for var K := 0 to High(FIOPGen) do
      Inc(FIOPGen[K]);
    FSIOLine := '';
  end;
end;

end.

