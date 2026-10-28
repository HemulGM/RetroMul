unit N64.Types;
// Hot emulation paths use explicit guest arithmetic and bounded indices.
// Define N64_CHECKED to enable range and overflow checks for diagnostics.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Math;

// All guest wraparound is explicit. These routines also work with {$Q+}{$R+}.
function Add64(A, B: UInt64): UInt64; inline;

function Sub64(A, B: UInt64): UInt64; inline;

function Add32(A, B: Cardinal): Cardinal; inline;

function SX(Value: UInt64; Bits: Integer): UInt64; inline;

function SX8(Value: UInt64): UInt64; inline;

function SX16(Value: UInt64): UInt64; inline;

function SX32(Value: UInt64): UInt64; inline;

function SignedValue(Value: UInt64): Int64; inline;

function SignedLess(A, B: UInt64): Boolean; inline;

function SAR(Value: UInt64; Count, Bits: Integer): UInt64; inline;

procedure Multiply64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64); inline;

procedure Divide64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64); inline;

const
  // RDRAM pages tracked for queued RDP work.
  RDPPageShift = 12;
  RDPPageCount = $800000 shr RDPPageShift;
  RDPLineShift = 6;
  RDPLineCount = $800000 shr RDPLineShift;

type
  EN64Unsupported = class(Exception);

  TN64TraceKind = (Instruction, GuestException, MMIORead, MMIOWrite,
    DMAStart, DMAComplete, InterruptChange);

  TN64TraceRecord = record
    Tick, PC, Address, Value: UInt64;
    Kind: TN64TraceKind;
  end;

  TN64TraceSink = reference to procedure(const Event: TN64TraceRecord);

  // Where generated CPU code reads the bus's page state (N64.CPU's JIT), and
  // generated RSP code the IMEM write count and the eighths' stamps
  // (N64.RSP's).
  TN64BusJitInfo = record
    SPMarked, SPDoneCount, SPWrites, SPReads: PInt64;
    RDPPending: PBoolean;
    RDPWrites, RDPDone: PUInt64;
    CodeGen: PCardinal;
    IMemCounter: PUInt64;
    IMemRegions: PUInt64;
  end;

  TN64Bus = class abstract
  private
    FTraceSink: TN64TraceSink;
    FTraceEnabled: Boolean;
  protected
    // IMEM ($1000..$1FFF of FSP) as big-endian words, and for each word the
    // value of FIMemCounter at its last change (0: never written).
    FIMemWords: array[0..1023] of Cardinal;
    FIMemStamps: array[0..1023] of UInt64;
    FIMemCounter: UInt64;
    // For each eighth of IMEM (128 words), the value of FIMemCounter when one
    // of its words last changed value (a write of the same value leaves it).
    FIMemRegions: array[0..7] of UInt64;
    // SP DMEM+IMEM ($04000000..$04001FFF), plain RDRAM bytes and their
    // hidden bits. Fixed bounds keep the checked accesses cheap. A bus that
    // sets FDirectMemory promises that CPU/RSP/RDP/VI accesses there have
    // exactly the semantics of the helpers below, so callers may bypass the
    // virtual decoder. Other buses never expose these arrays. (After the
    // 8-byte fields: FSP and FRAM start 8-byte aligned, where the instance
    // is, for the RSP's 16-byte vector loads and stores in 8-byte words.)
    FSP: array[0..$1FFF] of Byte;
    FRAM: array[0..$7FFFFF] of Byte;
    FHiddenRAM: array[0..$3FFFFF] of Byte;
    FDirectMemory: Boolean;
    // RDRAM pages decoded CPU code came from (TN64CPU's blocks), and per page
    // a count every write of RDRAM data there changes: the code is checked
    // again when its page's count changed. Band RDPs write it at once
    // (lost updates still change it).
    FCodePage: array[0..2047] of Boolean;
    FCodeGen: array[0..2047] of Cardinal;
    // RDP lists queued to a worker thread (N64.RDPWorker). Per 4 KB RDRAM
    // page: the number of the last queued list that may write the page
    // (FRDPWrites) or read or write it (FRDPUses). FRDPList is the list being
    // queued; FRDPDone the emulation thread's copy of the last list the worker
    // has finished (it may lag, which only costs a WaitRDP call). Lists are
    // numbered from 1; without a worker everything stays 0.
    FRDPWrites, FRDPUses: array[0..RDPPageCount - 1] of UInt64;
    // The same per 64-byte line, so that an access waits exactly for the
    // last list that marked the lines it touches.
    FRDPLineWrites, FRDPLineUses: array[0..RDPLineCount - 1] of UInt64;
    FRDPDone, FRDPList: UInt64;
    // FRDPList > FRDPDone, kept by the owner of the lists: while it is clear
    // (always without a worker) the checked accessors test nothing else.
    FRDPPending: Boolean;
    // SP DMA transfers not complete (their beats may wait while the CPU runs
    // on, see TN64Console): per 4 KB RDRAM page the number of the last one
    // that writes it (FSPWrites) or reads it (FSPReads), transfers counted
    // from 1; FSPDoneCount: those complete; FSPMarked: the last one marked.
    FSPWrites, FSPReads: array[0..RDPPageCount - 1] of Int64;
    FSPDoneCount, FSPMarked: Int64;
    // A bus that sets FInterruptLineKnown keeps FInterruptLine equal to
    // InterruptPending at all times, so the CPU can skip the virtual call.
    FInterruptLineKnown, FInterruptLine: Boolean;
    // Emulation thread only: returns once queued RDP work up to List can no
    // longer change or use RDRAM. The base bus has no worker.
    procedure WaitRDP(List: UInt64); virtual;
  public
    function Read8(Address: Cardinal): Byte; virtual; abstract;
    procedure Write8(Address: Cardinal; Value: Byte); virtual; abstract;
    function Read32(Address: Cardinal): Cardinal; virtual;
    procedure Write32(Address, Value: Cardinal); virtual;
    function InterruptPending: Boolean; virtual;
    // Two hidden RDRAM bits belong to each physical halfword. Byte addresses
    // keep the bus interface consistent with CPU/DMA/framebuffer accesses.
    function ReadHidden(Address: Cardinal): Byte; virtual;
    procedure WriteHidden(Address: Cardinal; Value: Byte); virtual;
    function GuestTick: UInt64; virtual;
    // The CPU, running a batch of instructions (TN64CPU.RunBatch), is about to
    // access a device (anything but direct RDRAM): the instructions before
    // the current one took Elapsed PClocks since the batch started.
    procedure SyncDevice(Elapsed: UInt64); virtual;
    procedure SetTraceSink(const Sink: TN64TraceSink);
    procedure Trace(Kind: TN64TraceKind; PC, Address, Value: UInt64);
    // $800000 with FDirectMemory, otherwise 0 (no direct RDRAM).
    function RAMSize: Cardinal; inline;
    // CPU, DMA and VI accessors. Callers guarantee Address + access size <=
    // RAMSize. Each first waits for queued RDP work on the bytes it touches.
    function ReadRAM8(Address: Cardinal): Byte; inline;
    function ReadRAM16(Address: Cardinal): Cardinal; inline;
    function ReadRAM32(Address: Cardinal): Cardinal; inline;
    procedure WriteRAM8(Address: Cardinal; Value: Byte); inline;
    procedure WriteRAM32(Address, Value: Cardinal); inline;
    // Whether reads of the 4 KB RDRAM page with Address need not wait for
    // RDP work queued now (which stays so until more is queued), and a word
    // of RDRAM read without the wait (after that).
    function RDPReadClean(Address: Cardinal): Boolean; inline;
    // Whether the CPU reading (writing) RDRAM at Address must first let the
    // SP DMA beats due by then run (TN64CPU.DeviceAccess): a transfer not
    // complete writes the page (or, for a write, reads it).
    function SPReadHazard(Address: Cardinal): Boolean; inline;
    function SPWriteHazard(Address: Cardinal): Boolean; inline;
    // Neither is true anywhere: no SP DMA transfer is still to complete.
    function SPIdle: Boolean; inline;
    function PlainRAM32(Address: Cardinal): Cardinal; inline;
    // Callers guarantee Address < RAMSize.
    function ReadHiddenRAM(Address: Cardinal): Byte; inline;
    procedure WriteHiddenRAM(Address: Cardinal; Value: Byte); inline;
    // Count bytes from Address, all within RDRAM: read as ReadRAM8 reads
    // each, written as WriteRAM8 writes each (data, hidden bits, code
    // counts); the waits are checked once for every page of the range.
    procedure ReadRAMBytes(Address: Cardinal; Dest: PByte; Count: Cardinal);
    procedure WriteRAMBytes(Address: Cardinal; Source: PByte; Count: Cardinal);
    // The same waits for a byte range (any part may lie beyond RDRAM).
    procedure SyncRDPRead(Address, Count: Cardinal);
    // Copies Count bytes of RDRAM from Address (within RDRAM), with their
    // hidden bits, to the same place in Target (without RDP waits).
    procedure CopyRAMTo(Target: TN64Bus; Address, Count: Cardinal);
    // The bytes of Count at Address that queued RDP lists may still write
    // (with FRDPDone as it is): from the first to the last 64-byte line
    // they mark, [First, Last) within the range. False: none (SyncRDPRead
    // would not wait).
    function RDPPendingRange(Address, Count: Cardinal; out First, Last: Cardinal): Boolean;
    procedure SyncRDPWrite(Address, Count: Cardinal);
    // RDP accessors, without waits: the worker owns the pages of the lists
    // it runs. Same bounds as above; RDPWrite8/32 behave as WriteRAM8/32.
    function RDPRead8(Address: Cardinal): Byte; inline;
    function RDPRead16(Address: Cardinal): Cardinal; inline;
    function RDPRead32(Address: Cardinal): Cardinal; inline;
    procedure RDPWrite8(Address: Cardinal; Value: Byte); inline;
    procedure RDPWrite32(Address, Value: Cardinal); inline;
    function RDPReadHidden(Address: Cardinal): Byte; inline;
    procedure RDPWriteHidden(Address: Cardinal; Value: Byte); inline;
    // Data bytes followed by explicit hidden bits: the same result as RDPWrite8
    // or RDPWrite32 then RDPWriteHidden for each halfword written. For the 16-
    // and 32-bit forms Address is even.
    procedure RDPWrite8Hidden(Address: Cardinal; Value, Hidden: Byte); inline;
    procedure RDPWrite16Hidden(Address, Value: Cardinal; Hidden: Byte); inline;
    procedure RDPWrite32Hidden(Address, Value: Cardinal; HiddenHi, HiddenLo: Byte); inline;
    // Decoded CPU code: its page counts writes from now on; the count.
    procedure MarkCodePage(Address: Cardinal); inline;
    function CodeGeneration(Address: Cardinal): Cardinal; inline;
    // The counts by 4 KB page (generated CPU code reads them).
    function CodeGenerations: PCardinal; inline;
    function JitInfo: TN64BusJitInfo;
    // RDRAM changed as a whole (reset, state load): every page's count.
    procedure RAMReplaced;
    // Pages the list being queued may read, or write (and read). Parts of
    // the range beyond RDRAM are ignored.
    procedure MarkRDPRead(Address, Count: Cardinal);
    procedure MarkRDPWrite(Address, Count: Cardinal);
    // Whether queued lists may write part of the range (never waits).
    function RDPWriteHazard(Address, Count: Cardinal): Boolean;
    // SP memory helpers; Offset is below $2000 and DirectMemory is set.
    // Every write to SP memory goes through WriteSP8 or SPLoaded, which keep
    // the IMEM words and their stamps up to date.
    function ReadSP8(Offset: Cardinal): Byte; inline;
    procedure WriteSP8(Offset: Cardinal; Value: Byte); inline;
    // Count bytes at Offset (not past $2000), as WriteSP8 writes each.
    procedure WriteSPBytes(Offset: Cardinal; Source: PByte; Count: Cardinal);
    // DMEM (offsets 0..$FFF; IMEM follows): direct access for the RSP's
    // vector loads and stores, which never reach IMEM.
    function DMemBytes: PByte; inline;
    function ReadSP32(Offset: Cardinal): Cardinal; inline;
    procedure IMemChanged(Offset: Cardinal);
    procedure CodeWritten(Address: Cardinal); inline;
    // Count bytes from SP memory at Offset to Dest[Index..], and back.
    procedure CopyFromSP(Offset: Cardinal; var Dest: array of Byte; Index, Count: Integer);
    procedure CopyToSP(Offset: Cardinal; const Source: array of Byte; Index, Count: Integer);
    // After FSP changed as a whole (reset, boot, state load).
    procedure SPLoaded;
    // IMEM word Slot (0..1023) and the stamp of its last change.
    function IMemWord(Slot: Integer): Cardinal; inline;
    function IMemStamp(Slot: Integer): UInt64; inline;
    // The stamp of the last change to any IMEM word.
    function IMemCounter: UInt64; inline;
    // The stamp of the last change of value in IMEM's eighth Region (words
    // Region * 128 on).
    function IMemRegionStamp(Region: Integer): UInt64; inline;
    function InterruptLine: Boolean; inline;
    property DirectMemory: Boolean read FDirectMemory;
    property TraceEnabled: Boolean read FTraceEnabled;
  end;

implementation

function Add64(A, B: UInt64): UInt64;
begin
  {$IFDEF N64_CHECKED}
  // B > not A exactly when A + B exceeds 64 bits; both branches stay in range.
  if B > not A then
    Result := B - (not A) - 1
  else
    Result := A + B;
  {$ELSE}
  Result := A + B;
  {$ENDIF}
end;

function Sub64(A, B: UInt64): UInt64;
begin
  {$IFDEF N64_CHECKED}
  if A >= B then
    Result := A - B
  else
    Result := A + (not B) + 1;
  {$ELSE}
  Result := A - B;
  {$ENDIF}
end;

function Add32(A, B: Cardinal): Cardinal;
begin
  {$IFDEF N64_CHECKED}
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
  {$ELSE}
  Result := A + B;
  {$ENDIF}
end;

function SX(Value: UInt64; Bits: Integer): UInt64;
begin
  if Bits = 64 then
    Exit(Value);
  var Mask := (UInt64(1) shl Bits) - 1;
  Result := Value and Mask;
  if (Result and (UInt64(1) shl (Bits - 1))) <> 0 then
    Result := Result or not Mask;
end;

function SX8(Value: UInt64): UInt64;
begin
  {$IFDEF N64_CHECKED}
  if (Value and $80) <> 0 then
    Result := Value or not UInt64($FF)
  else
    Result := Value and $FF;
  {$ELSE}
  Result := UInt64(Int64(ShortInt(Byte(Value))));
  {$ENDIF}
end;

function SX16(Value: UInt64): UInt64;
begin
  {$IFDEF N64_CHECKED}
  if (Value and $8000) <> 0 then
    Result := Value or not UInt64($FFFF)
  else
    Result := Value and $FFFF;
  {$ELSE}
  Result := UInt64(Int64(SmallInt(Word(Value))));
  {$ENDIF}
end;

function SX32(Value: UInt64): UInt64;
begin
  {$IFDEF N64_CHECKED}
  if (Value and $80000000) <> 0 then
    Result := Value or not UInt64($FFFFFFFF)
  else
    Result := Value and $FFFFFFFF;
  {$ELSE}
  Result := UInt64(Int64(Integer(Cardinal(Value))));
  {$ENDIF}
end;

function SignedValue(Value: UInt64): Int64;
begin
  {$IFDEF N64_CHECKED}
  if Value <= UInt64(High(Int64)) then
    Result := Int64(Value)
  else
    Result := -1 - Int64(not Value);
  {$ELSE}
  Result := Int64(Value);
  {$ENDIF}
end;

function SignedLess(A, B: UInt64): Boolean;
begin
  {$IFDEF N64_CHECKED}
  Result := (A xor (UInt64(1) shl 63)) < (B xor (UInt64(1) shl 63));
  {$ELSE}
  Result := Int64(A) < Int64(B);
  {$ENDIF}
end;

function SAR(Value: UInt64; Count, Bits: Integer): UInt64;
begin
  Value := SX(Value, Bits);
  Count := Count and (Bits - 1);
  Result := Value shr Count;
  if (Count <> 0) and (Value shr 63 <> 0) then
    Result := Result or (High(UInt64) shl (64 - Count));
end;

procedure Multiply64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64);
begin
  var Negative := Signed and ((A xor B) shr 63 <> 0);
  if Signed and (A shr 63 <> 0) then
    A := Sub64(0, A);
  if Signed and (B shr 63 <> 0) then
    B := Sub64(0, B);
  // Four exact 32x32 products instead of 64 bit-at-a-time iterations.
  // Middle has at most 34 bits; the high-word sum cannot exceed the high
  // half of the full 128-bit product, so it also fits with Q+ enabled.
  var P0 := (A and $FFFFFFFF) * (B and $FFFFFFFF);
  var P1 := (A and $FFFFFFFF) * (B shr 32);
  var P2 := (A shr 32) * (B and $FFFFFFFF);
  var P3 := (A shr 32) * (B shr 32);
  var Middle := (P0 shr 32) + (P1 and $FFFFFFFF) + (P2 and $FFFFFFFF);
  Lo := (P0 and $FFFFFFFF) or (Middle shl 32);
  Hi := P3 + (P1 shr 32) + (P2 shr 32) + (Middle shr 32);
  if Negative then
  begin
    Hi := not Hi;
    Lo := Add64(not Lo, 1);
    if Lo = 0 then
      Hi := Add64(Hi, 1);
  end;
end;

procedure Divide64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64);
begin
  var NA := Signed and (A shr 63 <> 0);
  var NB := Signed and (B shr 63 <> 0);
  if B = 0 then
  begin
    Hi := A;
    if NA then
      Lo := 1
    else
      Lo := High(UInt64);
    Exit;
  end;
  if NA then
    A := Sub64(0, A);
  if NB then
    B := Sub64(0, B);
  Hi := 0;
  Lo := 0;
  for var I := 63 downto 0 do
  begin
    var Carry := Hi shr 63 <> 0;
    Hi := (Hi shl 1) or ((A shr I) and 1);
    if Carry or (Hi >= B) then
    begin
      Hi := Sub64(Hi, B);
      Lo := Lo or (UInt64(1) shl I);
    end;
  end;
  if NA then
    Hi := Sub64(0, Hi);
  if NA <> NB then
    Lo := Sub64(0, Lo);
end;

function TN64Bus.Read32(Address: Cardinal): Cardinal;
begin
  Result := 0;
  for var I := 0 to 3 do
    Result := (Result shl 8) or Read8(Add32(Address, Cardinal(I)));
end;

procedure TN64Bus.Write32(Address, Value: Cardinal);
begin
  for var I := 0 to 3 do
    Write8(Add32(Address, Cardinal(I)), Byte((Value shr (24 - I * 8)) and $FF));
end;

function TN64Bus.InterruptPending: Boolean;
begin
  Result := False;
end;

function TN64Bus.ReadHidden(Address: Cardinal): Byte;
begin
  Result := 3;
end;

procedure TN64Bus.WriteHidden(Address: Cardinal; Value: Byte);
begin
end;

function TN64Bus.GuestTick: UInt64;
begin
  Result := 0;
end;

procedure TN64Bus.SyncDevice(Elapsed: UInt64);
begin
end;

procedure TN64Bus.SetTraceSink(const Sink: TN64TraceSink);
begin
  FTraceSink := Sink;
  FTraceEnabled := Assigned(FTraceSink);
end;

function TN64Bus.InterruptLine: Boolean;
begin
  if FInterruptLineKnown then
    Result := FInterruptLine
  else
    Result := InterruptPending;
end;

function TN64Bus.RAMSize: Cardinal;
begin
  if FDirectMemory then
    Result := Length(FRAM)
  else
    Result := 0;
end;

procedure TN64Bus.WaitRDP(List: UInt64);
begin
end;

// RDRAM hazards: a read waits for queued lists that may write the bytes it
// reads, a write also for lists that may read them. The fast check is per
// 4 KB page; SyncRDPRead/Write then wait for the last list that marked the
// 64-byte lines touched.
// An aligned access never crosses a line; the other ones go through the
// range check for every page they touch.

function TN64Bus.ReadRAM8(Address: Cardinal): Byte;
begin
  if FRDPPending and (FRDPWrites[Address shr RDPPageShift] > FRDPDone) then
    SyncRDPRead(Address, 1);
  Result := FRAM[Address];
end;

function TN64Bus.ReadRAM16(Address: Cardinal): Cardinal;
begin
  if FRDPPending and ((FRDPWrites[Address shr RDPPageShift] > FRDPDone) or ((Address and $FFF) = $FFF)) then
    SyncRDPRead(Address, 2);
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  Result := Swap(PWord(@FRAM[Address])^);
  {$ELSE}
  Result := (Cardinal(FRAM[Address]) shl 8) or FRAM[Address + 1];
  {$ENDIF}
end;

function TN64Bus.RDPReadClean(Address: Cardinal): Boolean;
begin
  Result := not FRDPPending or (FRDPWrites[Address shr RDPPageShift] <= FRDPDone);
end;

function TN64Bus.SPReadHazard(Address: Cardinal): Boolean;
begin
  Result := (FSPMarked > FSPDoneCount) and (FSPWrites[Address shr RDPPageShift] > FSPDoneCount);
end;

function TN64Bus.SPWriteHazard(Address: Cardinal): Boolean;
begin
  Result := (FSPMarked > FSPDoneCount) and ((FSPWrites[Address shr RDPPageShift] > FSPDoneCount) or
    (FSPReads[Address shr RDPPageShift] > FSPDoneCount));
end;

function TN64Bus.SPIdle: Boolean;
begin
  Result := FSPMarked <= FSPDoneCount;
end;

function TN64Bus.PlainRAM32(Address: Cardinal): Cardinal;
begin
  // RDRAM holds big-endian words.
  var V := PCardinal(@FRAM[Address])^;
  Result := (Cardinal(Swap(Word(V and $FFFF))) shl 16) or Swap(Word(V shr 16));
end;

function TN64Bus.ReadRAM32(Address: Cardinal): Cardinal;
begin
  if FRDPPending and ((FRDPWrites[Address shr RDPPageShift] > FRDPDone) or ((Address and $FFF) > $FFC)) then
    SyncRDPRead(Address, 4);
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  // x86 and ARM64 permit unaligned loads. Keep the bus fences above; decode
  // one native word instead of loading its four bytes separately.
  Result := PlainRAM32(Address);
  {$ELSE}
  Result := (Cardinal(FRAM[Address]) shl 24) or (Cardinal(FRAM[Address + 1]) shl 16) or
    (Cardinal(FRAM[Address + 2]) shl 8) or FRAM[Address + 3];
  {$ENDIF}
end;

procedure TN64Bus.WriteRAM8(Address: Cardinal; Value: Byte);
begin
  if FRDPPending and (FRDPUses[Address shr RDPPageShift] > FRDPDone) then
    SyncRDPWrite(Address, 1);
  RDPWrite8(Address, Value);
end;

procedure TN64Bus.WriteRAM32(Address, Value: Cardinal);
begin
  if FRDPPending and ((FRDPUses[Address shr RDPPageShift] > FRDPDone) or ((Address and $FFF) > $FFC)) then
    SyncRDPWrite(Address, 4);
  RDPWrite32(Address, Value);
end;

function TN64Bus.ReadHiddenRAM(Address: Cardinal): Byte;
begin
  if FRDPPending and (FRDPWrites[Address shr RDPPageShift] > FRDPDone) then
    SyncRDPRead(Address, 1);
  Result := FHiddenRAM[Address shr 1] and 3;
end;

procedure TN64Bus.WriteHiddenRAM(Address: Cardinal; Value: Byte);
begin
  if FRDPPending and (FRDPUses[Address shr RDPPageShift] > FRDPDone) then
    SyncRDPWrite(Address, 1);
  FHiddenRAM[Address shr 1] := Value and 3;
end;

procedure TN64Bus.ReadRAMBytes(Address: Cardinal; Dest: PByte; Count: Cardinal);
begin
  if Count = 0 then
    Exit;
  if FRDPPending then
    for var Page := Address shr RDPPageShift to (Address + Count - 1) shr RDPPageShift do
      if FRDPWrites[Page] > FRDPDone then
      begin
        SyncRDPRead(Address, Count);
        Break;
      end;
  Move(FRAM[Address], Dest^, Count);
end;

procedure TN64Bus.WriteRAMBytes(Address: Cardinal; Source: PByte; Count: Cardinal);
begin
  if Count = 0 then
    Exit;
  var Last := Address + Count - 1;
  if FRDPPending then
    for var Page := Address shr RDPPageShift to Last shr RDPPageShift do
      if FRDPUses[Page] > FRDPDone then
      begin
        SyncRDPWrite(Address, Count);
        Break;
      end;
  for var Page := Address shr 12 to Last shr 12 do
    CodeWritten(Page shl 12);
  Move(Source^, FRAM[Address], Count);
  // Each halfword's hidden bits from its odd byte, as RDPWrite8 leaves them
  // (an odd byte not written keeps its value).
  for var Half := Address shr 1 to Last shr 1 do
    FHiddenRAM[Half] := Byte(Ord((FRAM[(Half shl 1) or 1] and 1) <> 0) * 3);
end;

procedure TN64Bus.CopyRAMTo(Target: TN64Bus; Address, Count: Cardinal);
begin
  if (Count = 0) or (UInt64(Address) + Count > Length(FRAM)) then
    Exit;
  Move(FRAM[Address], Target.FRAM[Address], Count);
  var Hidden := Address shr 1;
  Move(FHiddenRAM[Hidden], Target.FHiddenRAM[Hidden], ((Address + Count - 1) shr 1) - Hidden + 1);
end;

procedure TN64Bus.SyncRDPRead(Address, Count: Cardinal);
begin
  if (Count = 0) or (Address >= Cardinal(Length(FRAM))) then
    Exit;
  var Last := Cardinal(Min(UInt64(Address) + Count, UInt64(Length(FRAM))) - 1);
  for var Page := Address shr RDPPageShift to Last shr RDPPageShift do
    if FRDPWrites[Page] > FRDPDone then
    begin
      // The latest queued writer of the lines read.
      var List: UInt64 := 0;
      for var Line := Max(Address, Page shl RDPPageShift) shr RDPLineShift to Min(Last, (Page shl RDPPageShift) or $FFF) shr RDPLineShift do
        if FRDPLineWrites[Line] > List then
          List := FRDPLineWrites[Line];
      if List > FRDPDone then
        WaitRDP(List);
    end;
end;

function TN64Bus.RDPPendingRange(Address, Count: Cardinal; out First, Last: Cardinal): Boolean;
begin
  Result := False;
  First := 0;
  Last := 0;
  if not FRDPPending or (Count = 0) or (Address >= Cardinal(Length(FRAM))) then
    Exit;
  var Final := Cardinal(Min(UInt64(Address) + Count, UInt64(Length(FRAM))) - 1);
  var Low := High(Cardinal);
  var High_: Cardinal := 0;
  for var Page := Address shr RDPPageShift to Final shr RDPPageShift do
    if FRDPWrites[Page] > FRDPDone then
      for var Line := Max(Address, Page shl RDPPageShift) shr RDPLineShift to Min(Final, (Page shl RDPPageShift) or $FFF) shr RDPLineShift do
        if FRDPLineWrites[Line] > FRDPDone then
        begin
          if Low = High(Cardinal) then
            Low := Line;
          High_ := Line;
        end;
  if Low = High(Cardinal) then
    Exit;
  First := Max(Address, Low shl RDPLineShift);
  Last := Min(Address + Count, (High_ + 1) shl RDPLineShift);
  Result := True;
end;

procedure TN64Bus.SyncRDPWrite(Address, Count: Cardinal);
begin
  if (Count = 0) or (Address >= Cardinal(Length(FRAM))) then
    Exit;
  var Last := Cardinal(Min(UInt64(Address) + Count, UInt64(Length(FRAM))) - 1);
  for var Page := Address shr RDPPageShift to Last shr RDPPageShift do
    if FRDPUses[Page] > FRDPDone then
    begin
      var List: UInt64 := 0;
      for var Line := Max(Address, Page shl RDPPageShift) shr RDPLineShift to Min(Last, (Page shl RDPPageShift) or $FFF) shr RDPLineShift do
        if FRDPLineUses[Line] > List then
          List := FRDPLineUses[Line];
      if List > FRDPDone then
        WaitRDP(List);
    end;
end;

function TN64Bus.RDPWriteHazard(Address, Count: Cardinal): Boolean;
begin
  // Whether a queued list may write any byte of the range (no waiting).
  Result := False;
  if (Count = 0) or (Address >= Cardinal(Length(FRAM))) then
    Exit;
  var Last := Cardinal(Min(UInt64(Address) + Count, UInt64(Length(FRAM))) - 1);
  for var Page := Address shr RDPPageShift to Last shr RDPPageShift do
    if FRDPWrites[Page] > FRDPDone then
      for var Line := Max(Address, Page shl RDPPageShift) shr RDPLineShift to Min(Last, (Page shl RDPPageShift) or $FFF) shr RDPLineShift do
        if FRDPLineWrites[Line] > FRDPDone then
          Exit(True);
end;

procedure TN64Bus.MarkRDPRead(Address, Count: Cardinal);
begin
  if (Count = 0) or (Address >= Cardinal(Length(FRAM))) then
    Exit;
  var Last := Cardinal(Min(UInt64(Address) + Count, UInt64(Length(FRAM))) - 1);
  for var Line := Address shr RDPLineShift to Last shr RDPLineShift do
    FRDPLineUses[Line] := FRDPList;
  for var Page := Address shr RDPPageShift to Last shr RDPPageShift do
    FRDPUses[Page] := FRDPList;
end;

procedure TN64Bus.MarkRDPWrite(Address, Count: Cardinal);
begin
  if (Count = 0) or (Address >= Cardinal(Length(FRAM))) then
    Exit;
  var Last := Cardinal(Min(UInt64(Address) + Count, UInt64(Length(FRAM))) - 1);
  for var Line := Address shr RDPLineShift to Last shr RDPLineShift do
  begin
    FRDPLineWrites[Line] := FRDPList;
    FRDPLineUses[Line] := FRDPList;
  end;
  for var Page := Address shr RDPPageShift to Last shr RDPPageShift do
  begin
    FRDPWrites[Page] := FRDPList;
    FRDPUses[Page] := FRDPList;
  end;
end;

function TN64Bus.RDPRead8(Address: Cardinal): Byte;
begin
  Result := FRAM[Address];
end;

function TN64Bus.RDPRead16(Address: Cardinal): Cardinal;
begin
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  Result := Swap(PWord(@FRAM[Address])^);
  {$ELSE}
  Result := (Cardinal(FRAM[Address]) shl 8) or FRAM[Address + 1];
  {$ENDIF}
end;

function TN64Bus.RDPRead32(Address: Cardinal): Cardinal;
begin
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  // x86 and ARM64 permit unaligned loads. Keep the bus fences above; decode
  // one native word instead of loading its four bytes separately.
  Result := PlainRAM32(Address);
  {$ELSE}
  Result := (Cardinal(FRAM[Address]) shl 24) or (Cardinal(FRAM[Address + 1]) shl 16) or
    (Cardinal(FRAM[Address + 2]) shl 8) or FRAM[Address + 3];
  {$ENDIF}
end;

procedure TN64Bus.CodeWritten(Address: Cardinal);
begin
  var Page := Address shr 12;
  if FCodePage[Page] then
    FCodeGen[Page] := FCodeGen[Page] + 1;
end;

procedure TN64Bus.MarkCodePage(Address: Cardinal);
begin
  FCodePage[Address shr 12] := True;
end;

function TN64Bus.CodeGeneration(Address: Cardinal): Cardinal;
begin
  Result := FCodeGen[Address shr 12];
end;

function TN64Bus.JitInfo: TN64BusJitInfo;
begin
  Result.SPMarked := @FSPMarked;
  Result.SPDoneCount := @FSPDoneCount;
  Result.SPWrites := @FSPWrites[0];
  Result.SPReads := @FSPReads[0];
  Result.RDPPending := @FRDPPending;
  Result.RDPWrites := @FRDPWrites[0];
  Result.RDPDone := @FRDPDone;
  Result.CodeGen := @FCodeGen[0];
  Result.IMemCounter := @FIMemCounter;
  Result.IMemRegions := @FIMemRegions[0];
end;

function TN64Bus.CodeGenerations: PCardinal;
begin
  Result := @FCodeGen[0];
end;

procedure TN64Bus.RAMReplaced;
begin
  for var I := 0 to High(FCodeGen) do
    FCodeGen[I] := FCodeGen[I] + 1;
end;

procedure TN64Bus.RDPWrite8(Address: Cardinal; Value: Byte);
begin
  CodeWritten(Address);
  FRAM[Address] := Value;
  FHiddenRAM[Address shr 1] := Byte(Ord((FRAM[Address or 1] and 1) <> 0) * 3);
end;

procedure TN64Bus.RDPWrite32(Address, Value: Cardinal);
begin
  CodeWritten(Address);
  if (Address and $FFF) > $FFC then CodeWritten(Address + 3);
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  PCardinal(@FRAM[Address])^ := (Cardinal(Swap(Word(Value and $FFFF))) shl 16) or Swap(Word(Value shr 16));
  {$ELSE}
  FRAM[Address] := Byte(Value shr 24);
  FRAM[Address + 1] := Byte((Value shr 16) and $FF);
  FRAM[Address + 2] := Byte((Value shr 8) and $FF);
  FRAM[Address + 3] := Byte(Value and $FF);
  {$ENDIF}
  FHiddenRAM[Address shr 1] := Byte(Ord((Value and $10000) <> 0) * 3);
  FHiddenRAM[(Address + 3) shr 1] := Byte(Ord((Value and 1) <> 0) * 3);
end;

function TN64Bus.RDPReadHidden(Address: Cardinal): Byte;
begin
  Result := FHiddenRAM[Address shr 1] and 3;
end;

procedure TN64Bus.RDPWriteHidden(Address: Cardinal; Value: Byte);
begin
  FHiddenRAM[Address shr 1] := Value and 3;
end;

procedure TN64Bus.RDPWrite8Hidden(Address: Cardinal; Value, Hidden: Byte);
begin
  CodeWritten(Address);
  FRAM[Address] := Value;
  FHiddenRAM[Address shr 1] := Hidden and 3;
end;

procedure TN64Bus.RDPWrite16Hidden(Address, Value: Cardinal; Hidden: Byte);
begin
  CodeWritten(Address);
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  PWord(@FRAM[Address])^ := Swap(Word(Value and $FFFF));
  {$ELSE}
  FRAM[Address] := Byte((Value shr 8) and $FF);
  FRAM[Address + 1] := Byte(Value and $FF);
  {$ENDIF}
  FHiddenRAM[Address shr 1] := Hidden and 3;
end;

procedure TN64Bus.RDPWrite32Hidden(Address, Value: Cardinal; HiddenHi, HiddenLo: Byte);
begin
  CodeWritten(Address);
  if (Address and $FFF) > $FFC then CodeWritten(Address + 3);
  {$IF DEFINED(CPU386) or DEFINED(CPUX64) or DEFINED(CPUARM64)}
  PCardinal(@FRAM[Address])^ := (Cardinal(Swap(Word(Value and $FFFF))) shl 16) or Swap(Word(Value shr 16));
  {$ELSE}
  FRAM[Address] := Byte(Value shr 24);
  FRAM[Address + 1] := Byte((Value shr 16) and $FF);
  FRAM[Address + 2] := Byte((Value shr 8) and $FF);
  FRAM[Address + 3] := Byte(Value and $FF);
  {$ENDIF}
  FHiddenRAM[Address shr 1] := HiddenHi and 3;
  FHiddenRAM[(Address shr 1) + 1] := HiddenLo and 3;
end;

function TN64Bus.ReadSP8(Offset: Cardinal): Byte;
begin
  Result := FSP[Offset];
end;

function TN64Bus.DMemBytes: PByte;
begin
  Result := @FSP[0];
end;

procedure TN64Bus.WriteSP8(Offset: Cardinal; Value: Byte);
begin
  FSP[Offset] := Value;
  if Offset >= $1000 then
    IMemChanged(Offset);
end;

procedure TN64Bus.WriteSPBytes(Offset: Cardinal; Source: PByte; Count: Cardinal);
begin
  if Count = 0 then
    Exit;
  Move(Source^, FSP[Offset], Count);
  if Offset + Count > $1000 then
    for var Word := Max(Offset, $1000) shr 2 to (Offset + Count - 1) shr 2 do
      IMemChanged(Word * 4);
end;

procedure TN64Bus.IMemChanged(Offset: Cardinal);
begin
  var Slot := (Offset - $1000) shr 2;
  var Value := ReadSP32(Offset and not Cardinal(3));
  Inc(FIMemCounter);
  if FIMemWords[Slot] <> Value then
    FIMemRegions[Slot shr 7] := FIMemCounter;
  FIMemWords[Slot] := Value;
  FIMemStamps[Slot] := FIMemCounter;
end;

procedure TN64Bus.SPLoaded;
begin
  for var Slot := 0 to High(FIMemWords) do
    IMemChanged($1000 + Cardinal(Slot) * 4);
end;

function TN64Bus.IMemWord(Slot: Integer): Cardinal;
begin
  Result := FIMemWords[Slot];
end;

function TN64Bus.IMemStamp(Slot: Integer): UInt64;
begin
  Result := FIMemStamps[Slot];
end;

function TN64Bus.IMemCounter: UInt64;
begin
  Result := FIMemCounter;
end;

function TN64Bus.IMemRegionStamp(Region: Integer): UInt64;
begin
  Result := FIMemRegions[Region];
end;

procedure TN64Bus.CopyFromSP(Offset: Cardinal; var Dest: array of Byte; Index, Count: Integer);
begin
  if (Count < 0) or (Index < 0) or (Index + Count > Length(Dest)) or (UInt64(Offset) + Cardinal(Count) > Length(FSP)) then
    raise ERangeError.Create('SP memory copy out of range');
  if Count > 0 then
    Move(FSP[Offset], Dest[Index], Count);
end;

procedure TN64Bus.CopyToSP(Offset: Cardinal; const Source: array of Byte; Index, Count: Integer);
begin
  if (Count < 0) or (Index < 0) or (Index + Count > Length(Source)) or (UInt64(Offset) + Cardinal(Count) > Length(FSP)) then
    raise ERangeError.Create('SP memory copy out of range');
  if Count > 0 then
    Move(Source[Index], FSP[Offset], Count);
  if UInt64(Offset) + Cardinal(Count) > $1000 then
    for var Word := Max(Offset, $1000) shr 2 to (Offset + Cardinal(Count) - 1) shr 2 do
      IMemChanged(Word * 4);
end;

function TN64Bus.ReadSP32(Offset: Cardinal): Cardinal;
begin
  Result := (Cardinal(FSP[Offset]) shl 24) or (Cardinal(FSP[Offset + 1]) shl 16) or
    (Cardinal(FSP[Offset + 2]) shl 8) or FSP[Offset + 3];
end;

procedure TN64Bus.Trace(Kind: TN64TraceKind; PC, Address, Value: UInt64);
begin
  if not Assigned(FTraceSink) then
    Exit;
  var Event := Default(TN64TraceRecord);
  Event.Tick := GuestTick;
  Event.Kind := Kind;
  Event.PC := PC;
  Event.Address := Address;
  Event.Value := Value;
  FTraceSink(Event);
end;

end.

