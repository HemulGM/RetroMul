unit PS2.EE.Bus;

// EE physical memory and MMIO: 32 MiB RAM, BIOS ROM, IOP RAM window, VU
// memories, and the register blocks (timers, IPU, GIF, VIF, FIFOs, DMAC,
// INTC, SIO, SIF, GS privileged). Unknown registers keep written values.
// RAM pages carry write generations for the CPU's decoded blocks.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Snapshots, PS2.Types, PS2.Scheduler, PS2.EE.CPU, PS2.Timers, PS2.DMAC,
  PS2.SIF;

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
    procedure UpdateINT0;
    procedure SIOPut(C: Byte);
  public
    RAM, BIOS, IOPRAM: PByte;
    VU0Code, VU0Data, VU1Code, VU1Data: PByte;
    CPU: TEECPU;
    Timers: TPS2Timers;
    DMAC: TPS2DMAC;
    SIF: TPS2SIF;
    GS, GIF, VIF0, VIF1, IPU: TPS2Device;
    MMIOReads, MMIOWrites: Int64;
    // Diagnostics: accesses per address when assigned (reads; writes with bit 0 set).
    MMIOCounts: TDictionary<Cardinal, Int64>;
    LastReadPC: TDictionary<Cardinal, Cardinal>;
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
    $11000000: Exit(VU0Code);
    $11004000: Exit(VU0Data);
    $11008000..$1100B000: Exit(VU1Code + (A - $11008000));
    $1100C000..$1100F000: Exit(VU1Data + (A - $1100C000));
    $1C000000..$1C1FF000: Exit(IOPRAM + (A - $1C000000));
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
  Result := DMAC.CPCond0;
end;

procedure TPS2EEBus.UpdateINT0;
begin
  if CPU <> nil then
    CPU.SetInt0(((FINTCStat and FINTCMask) <> 0) or FKernelLine);
end;

procedure TPS2EEBus.RaiseIRQ(Cause: Integer);
begin
  FINTCStat := FINTCStat or (Cardinal(1) shl Cause);
  UpdateINT0;
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

function TPS2EEBus.Read(Address: Cardinal; Size: Integer): UInt64;
begin
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
      Exit(SIF.ReadRegister(((Address shr 4) and $F) + 1));
    $1000F520:
      Exit(DMAC.ENABLE);
    $12000000..$12001FFF:
      if GS <> nil then
        Exit(GS.Read(Address, Size));
  end;
  if (Address >= $10000000) and (Address < $10010000) then
  begin
    var V := UInt64(FRegs[(Address and $FFFC) shr 2]);
    if Size = 8 then
      V := V or (UInt64(FRegs[((Address + 4) and $FFFC) shr 2]) shl 32);
    Exit(V shr ((Address and 3) * 8));
  end;
  Result := 0;
end;

procedure TPS2EEBus.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
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
        SIF.WriteRegister(((Address shr 4) and $F) + 1, Cardinal(Value));
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
          4: Dev := VIF0;
          5: Dev := VIF1;
          6: Dev := GIF;
          7: Dev := IPU;
        end;
        if Dev <> nil then
          Dev.ReadFIFO(Address, Value)
        else
          Value := Default(TPS2Reg128);
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
          4: Dev := VIF0;
          5: Dev := VIF1;
          6: Dev := GIF;
          7: Dev := IPU;
        end;
        if Dev <> nil then
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
