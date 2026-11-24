unit PS2.VIF;

// VIF0/VIF1: the VIFcode stream from DMA channels 0/1 or the FIFOs. All
// commands (NOP, STCYCL, OFFSET, BASE, ITOP, STMOD, MSKPATH3, MARK, FLUSH*,
// MSCAL/MSCALF/MSCNT, STMASK, STROW, STCOL, MPG, DIRECT/DIRECTHL, UNPACK in
// every format with write cycles, masks and modes), double buffering of
// VU1 data (BASE/OFST/TOPS/TOP), the IRQ bit and the registers. VU micro
// programs run to their end when started; the VU then stays busy for the
// cycles they took, and FLUSHE/FLUSH/FLUSHA/MSCAL/MSCALF/MSCNT/MPG wait for
// that window to pass (the DMA channel waits with them).
// References: EE User's Manual (VIF chapter), ps2tek.
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
  System.SysUtils,
  System.Math,
  Core.Snapshots,
  PS2.Types,
  PS2.Scheduler,
  PS2.EE.Bus,
  PS2.DMAC,
  PS2.VU,
  PS2.GIF,
  PS2.VU1Domain;

type
  TPS2VIFState = record
    STAT, ERR, MARK, CYCLE, MODE, NUM, MASK, CODE, ITOPS, BASE, OFST, TOPS, ITOP, TOP: Cardinal;
    Row, Col: array[0..3] of Cardinal;
    // Current command and the words it still expects.
    Command: Cardinal;
    Remaining: Integer;
    // UNPACK progress: vectors written, write-cycle counters, address.
    UnpackAddr, UnpackCount, CycleIndex, CycleWritten: Integer;
    UnpackBits: UInt64;
    UnpackBitCount: Integer;
    // 32-bit elements (up to 128 bits a vector) collect as words.
    UnpackWords: array[0..3] of Cardinal;
    // MPG progress (in 32-bit words).
    MPGAddr: Cardinal;
    DBF: Boolean;
    // Stall on the next command: after an interrupt bit (VIS) or STOP (VSS).
    StallNext, StopNext: Boolean;
    // A command that needs the VU idle waits for its busy window to pass.
    WaitVU: Boolean;
    Path3Masked: Boolean;
    // Words the stalled VIF holds (its FIFO and the rest of the current
    // quadword), oldest first.
    Held: array[0..79] of Cardinal;
    HeldCount: Integer;
  end;

  // What the VIF registers read from (a copy answers reads later).
  TPS2VIFRegisters = record
    STAT, ERR, MARK, CYCLE, MODE, NUM, MASK, CODE, ITOPS, BASE, OFST, TOPS, ITOP, TOP: Cardinal;
    Row, Col: array[0..3] of Cardinal;
    Remaining, HeldCount: Integer;
    DBF, Path3Masked: Boolean;
  end;

  // VIF1's part of the VU1 domain, kept to go back to (with the counts
  // measurements read).
  TPS2VIFSaved = record
    S: TPS2VIFState;
    DirectBuf: TPS2Reg128;
    DirectWords: Integer;
    DirectSent: Boolean;
    Words, Starts, Unfinished: Int64;
  end;

  TPS2VIF = class(TPS2Device)
  private
    FIndex: Integer;
    FVU: TPS2VUCore;
    FGIF: TPS2GIF;
    FCode, FData: PByte;
    FCodeMask, FDataMask: Cardinal;
    FOnInterrupt: TProc;
    FOnResume: TProc;
    FScheduler: TPS2Scheduler;
    FDirectBuf: TPS2Reg128;
    FDirectWords: Integer;
    // DIRECT data went to the GIF (not yet taken).
    FDirectSent: Boolean;
    FDomain: TPS2VU1Domain;
    procedure StartCommand(W: Cardinal);
    // Diagnostics lines, apart: no string temporaries in the hot routines.
    procedure LogStartVU(Address: Cardinal);
    procedure RunCapturing(Address: Cardinal);
    procedure NoteUnfinished(Address: Cardinal);
    procedure LogPath3Mask;
    procedure LogUnpack(Cmd: Cardinal; Num, Addr: Integer; Imm: Cardinal);
    function UploadMicroQuads(Data: PCardinal; Available: Integer): Integer;
    procedure UnpackWord(W: Cardinal);
    function UnpackRun(Data: PCardinal; Count: Integer): Integer;
    function UnpackContiguous(Data: PCardinal; Count, WordsPerVector: Integer): Integer;
    function UnpackGroups(Data: PCardinal; Count: Integer): Integer;
    function UnpackPlain(
      Data: PCardinal;
      Count, VN, VL, PerVector: Integer;
      Unsigned: Boolean;
      CL, WL: Integer
    ): Integer;
    procedure WriteVector(const V: TPS2Reg128);
    procedure WriteMasked(const V: TPS2Reg128; P: PPS2Reg128);
    procedure FinishCommand;
    procedure StartVU(Address: Cardinal);
    procedure ProcessWord(W: Cardinal);
    function Stalled: Boolean; inline;
    function Blocked: Boolean;
    function Waits(W: Cardinal): Boolean;
    function Now: Int64; inline;
    function Hold(W: Cardinal): Boolean;
    procedure Release;
  public
    S: TPS2VIFState;
    // Words processed (diagnostics).
    Words: Int64;
    // Micro programs started, and those still running after the step limit.
    Starts, Unfinished: Int64;
    // Diagnostics: where the last program that did not end started and was.
    LastUnfinishedStart, LastUnfinishedPC: Cardinal;
    LastUnfinishedVI: array[0..15] of Cardinal;
    // Diagnostics: with CaptureUnfinished, the code, data and VI registers
    // the first program that did not end started with.
    CaptureUnfinished: Boolean;
    UnfinishedCapture: TBytes;
    // Diagnostics (with CaptureUnfinished): the last command words with
    // TOPS and the UNPACK address they started at; UnfinishedCommands is
    // the ring at the first program that did not end (oldest first).
    // Data words are in the ring too (second entry EEEEEEEEh).
    CommandRing: array[0..2047] of array[0..2] of Cardinal;
    CommandRingPos: Integer;
    UnfinishedCommands: TArray<Cardinal>;
    constructor Create(Index: Integer; VU: TPS2VUCore; GIF: TPS2GIF; Code, Data: PByte; CodeSize, DataSize: Cardinal);
    procedure Reset;
    // Feeds 32-bit words; a stalled VIF holds them while it has room.
    // Returns how many were taken.
    function Feed(Data: PCardinal; Count: Integer): Integer;
    // Feeds DMA quadwords; returns how many were taken (fewer: the stalled
    // VIF's FIFO is full and the channel waits for OnResume).
    function FeedQuads(Data: PCardinal; Count: Integer): Integer;
    // Whether DIRECT data went to the GIF since the last call.
    function TakeDirectSent: Boolean;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure GetRegisters(out R: TPS2VIFRegisters);
    procedure SaveDomain(out C: TPS2VIFSaved);
    procedure RestoreDomain(const C: TPS2VIFSaved);
    // The register at Offset of VIF Index (VUBusy: its VU's busy window has
    // not passed).
    class function RegisterValue(
      const R: TPS2VIFRegisters;
      Index: Integer;
      Offset: Cardinal;
      VUBusy: Boolean
    ): Cardinal; static;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); override;
    procedure SerializeState(State: TStateArchive);
    property OnInterrupt: TProc read FOnInterrupt write FOnInterrupt;
    // The stall ended and the FIFO has room: a waiting DMA channel goes on.
    property OnResume: TProc read FOnResume write FOnResume;
    // EE time for the VU busy window; the VIF0/VIF1 event wakes a command
    // that waits for it.
    property Scheduler: TPS2Scheduler read FScheduler write FScheduler;
    // VIF1: the VU1 domain it belongs to (its time; nil: the scheduler's).
    property Domain: TPS2VU1Domain read FDomain write FDomain;
    // Scheduler event: the VU program a command waited for has ended.
    procedure Wake;
  end;

var
  // UNPACK and DIRECT data taken many words at once where it can (tests
  // compare it with one word at a time).
  PS2VIFRuns: Boolean = True;

type
  TPS2VIFPort = class(TPS2DMAPort)
  private
    FVIF: TPS2VIF;
  public
    constructor Create(VIF: TPS2VIF);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    function Pull(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    procedure Tag(Channel: Integer; const Tag: TPS2Reg128); override;
    function TagRoom(Channel: Integer): Boolean; override;
    function BusyFromGS: Boolean; override;
    function TakeBusyCycles: Int64; override;
  end;

implementation

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
uses
  PS2.VU.Float;

// V4-8 unsigned plus ROW. No padding is read past the last source word.
// One source word expands to one 16-byte destination vector.
procedure ExpandBytesRow(Source: PCardinal; Target: PByte; Row: PCardinal; Count: Integer);
asm
  .NOFRAME
  vbroadcasti128 ymm4, [r8]
  cmp r9d, 8
  jb @@Pairs
@@Eight:
  vpmovzxbd ymm0, qword ptr [rcx]
  vpmovzxbd ymm1, qword ptr [rcx + 8]
  vpmovzxbd ymm2, qword ptr [rcx + 16]
  vpmovzxbd ymm3, qword ptr [rcx + 24]
  vpaddd ymm0, ymm0, ymm4
  vpaddd ymm1, ymm1, ymm4
  vpaddd ymm2, ymm2, ymm4
  vpaddd ymm3, ymm3, ymm4
  vmovdqu [rdx], ymm0
  vmovdqu [rdx + 32], ymm1
  vmovdqu [rdx + 64], ymm2
  vmovdqu [rdx + 96], ymm3
  add rcx, 32
  add rdx, 128
  sub r9d, 8
  cmp r9d, 8
  jae @@Eight
@@Pairs:
  cmp r9d, 2
  jb @@Tail
  vpmovzxbd ymm0, qword ptr [rcx]
  vpaddd ymm0, ymm0, ymm4
  vmovdqu [rdx], ymm0
  add rcx, 8
  add rdx, 32
  sub r9d, 2
  jmp @@Pairs
@@Tail:
  test r9d, r9d
  jz @@Done
  vpmovzxbd xmm0, dword ptr [rcx]
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
@@Done:
  vzeroupper
end;

type
  TExpandStride = procedure(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);

const
  ZeroRow: array[0..3] of Cardinal = (0, 0, 0, 0);

procedure ExpandByteUStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vpmovzxbd xmm0, dword ptr [rcx]
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 4
  dec r9d
  jnz @@Loop
end;

procedure ExpandByteSStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vpmovsxbd xmm0, dword ptr [rcx]
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 4
  dec r9d
  jnz @@Loop
end;

procedure ExpandShortUStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vpmovzxwd xmm0, qword ptr [rcx]
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 8
  dec r9d
  jnz @@Loop
end;

procedure ExpandShortSStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vpmovsxwd xmm0, qword ptr [rcx]
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 8
  dec r9d
  jnz @@Loop
end;

procedure ExpandPairUStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vmovd xmm0, dword ptr [rcx]
  vpmovzxwd xmm0, xmm0
  vpshufd xmm0, xmm0, $44
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 4
  dec r9d
  jnz @@Loop
end;

procedure ExpandPairSStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vmovd xmm0, dword ptr [rcx]
  vpmovsxwd xmm0, xmm0
  vpshufd xmm0, xmm0, $44
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 4
  dec r9d
  jnz @@Loop
end;

procedure ExpandTripleStride(Source: PCardinal; Target: PByte; Row: PCardinal; Count, StrideBytes: Integer);
asm
  .NOFRAME
  mov r10d, [rsp + 40]
  vmovdqu xmm4, [r8]
@@Loop:
  vmovq xmm0, qword ptr [rcx]
  vpinsrd xmm0, xmm0, dword ptr [rcx + 8], 2
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [rdx], xmm0
  add rdx, r10
  add rcx, 12
  dec r9d
  jnz @@Loop
end;
{$ENDIF}

{ TPS2VIF }

constructor TPS2VIF.Create(Index: Integer; VU: TPS2VUCore; GIF: TPS2GIF; Code, Data: PByte; CodeSize,
  DataSize: Cardinal);
begin
  inherited Create;
  FIndex := Index;
  FVU := VU;
  FGIF := GIF;
  FCode := Code;
  FData := Data;
  FCodeMask := CodeSize - 1;
  FDataMask := DataSize - 1;
  Reset;
end;

procedure TPS2VIF.Reset;
begin
  S := Default(TPS2VIFState);
  FDirectWords := 0;
end;

procedure TPS2VIF.LogStartVU(Address: Cardinal);
begin
  FGIF.TagLog.Add(Format('vif%d start vu at %x', [FIndex, Address]));
end;

procedure TPS2VIF.LogPath3Mask;
begin
  FGIF.TagLog.Add(Format('vif%d mskpath3 %d', [FIndex, Ord(S.Path3Masked)]));
end;

procedure TPS2VIF.LogUnpack(Cmd: Cardinal; Num, Addr: Integer; Imm: Cardinal);
begin
  FGIF.TagLog.Add(Format('vif%d unpack %.2x num %d addr %x usn %d cycle %.4x mask %.8x mode %d', [FIndex, Cmd, Num,
    Addr, (Imm shr 14) and 1, S.CYCLE, S.MASK, S.MODE]));
end;

procedure TPS2VIF.StartVU(Address: Cardinal);
begin
  if (FGIF <> nil) and (FGIF.TagLog <> nil) and (FGIF.TagLog.Count < 200000) then
    LogStartVU(Address);
  if FIndex = 1 then
  begin
    // Double buffering: TOP takes TOPS, the next TOPS the other buffer.
    S.TOP := S.TOPS;
    S.ITOP := S.ITOPS;
    S.DBF := not S.DBF;
    if S.DBF then
      S.TOPS := (S.BASE + S.OFST) and $3FF
    else
      S.TOPS := S.BASE and $3FF;
    FVU.VI[26] := S.TOP;
    FVU.VI[27] := S.ITOP;
  end
  else
  begin
    S.ITOP := S.ITOPS;
    FVU.VI[27] := S.ITOP;
  end;
  FVU.Start(Address);
  Inc(Starts);
  if CaptureUnfinished and (UnfinishedCapture = nil) then
  begin
    RunCapturing(Address);
    Exit;
  end;
  FVU.RunProgram(Now, 4000000);
  if FVU.S.Running then
    NoteUnfinished(Address);
end;

// StartVU's run with the diagnostics capture (apart: no managed variables in
// StartVU).
procedure TPS2VIF.RunCapturing(Address: Cardinal);
begin
  // Code, data and VI as the program starts.
  var Before: TBytes;
  SetLength(Before, $8000 + 32 * 4);
  Move(FVU.Code^, Before[0], $4000);
  Move(FVU.Data^, Before[$4000], $4000);
  for var K := 0 to 31 do
    PCardinal(@Before[$8000 + K * 4])^ := FVU.VI[K];
  if FVU.RunTrace = nil then
    SetLength(FVU.RunTrace, 40000 * 16);
  FVU.RunTraceCount := 0;
  FVU.RunProgram(Now, 4000000);
  if FVU.S.Running then
  begin
    // Then the trace of the run's first pairs.
    var At := Length(Before);
    SetLength(Before, At + FVU.RunTraceCount * 32);
    if FVU.RunTraceCount > 0 then
      Move(FVU.RunTrace[0], Before[At], FVU.RunTraceCount * 32);
    UnfinishedCapture := Before;
    SetLength(UnfinishedCommands, Length(CommandRing) * 3);
    for var K := 0 to High(CommandRing) do
      for var J := 0 to 2 do
        UnfinishedCommands[K * 3 + J] := CommandRing[(CommandRingPos + K) and High(CommandRing)][J];
    FVU.RunTrace := nil;
    NoteUnfinished(Address);
  end;
end;
procedure TPS2VIF.NoteUnfinished(Address: Cardinal);
begin
  Inc(Unfinished);
  LastUnfinishedStart := Address;
  LastUnfinishedPC := FVU.S.TPC;
  for var K := 0 to 15 do
    LastUnfinishedVI[K] := FVU.VI[K];
end;

procedure TPS2VIF.FinishCommand;
begin
  S.Command := 0;
  S.Remaining := 0;
  if ((S.CODE and $80000000) <> 0) and ((S.ERR and 1) = 0) then
  begin
    // Interrupt bit (unless ERR.MII): INT now, and the VIF stalls on the
    // next command (VIS), except after MARK.
    S.STAT := S.STAT or $800;
    if ((S.CODE shr 24) and $7F) <> $07 then
      S.StallNext := True;
    if Assigned(FOnInterrupt) then
      FOnInterrupt();
  end;
end;

// VSS (STOP), VFS (force break) or VIS (interrupt bit).
function TPS2VIF.Stalled: Boolean;
begin
  Result := (S.STAT and $700) <> 0;
end;

// Whether the next word must wait: a stall in force, or one that begins at
// this command boundary (VIS after an interrupt bit, VSS after STOP).
function TPS2VIF.Blocked: Boolean;
begin
  if S.Remaining = 0 then
    if S.StallNext then
    begin
      S.StallNext := False;
      S.STAT := S.STAT or $400;
    end
    else if S.StopNext then
    begin
      S.StopNext := False;
      S.STAT := S.STAT or $100;
    end;
  Result := Stalled or S.WaitVU;
end;

function TPS2VIF.Now: Int64;
begin
  if FDomain <> nil then
    Result := FDomain.Now
  else if FScheduler <> nil then
    Result := FScheduler.Now
  else
    Result := 0;
end;

// Whether word W must wait: a stall, or a command that needs the VU idle
// (FLUSHE, FLUSH, FLUSHA, MSCAL, MSCALF, MSCNT, MPG) inside its busy window.
function TPS2VIF.Waits(W: Cardinal): Boolean;
begin
  if Blocked then
    Exit(True);
  Result := False;
  if (S.Remaining <> 0) or (FScheduler = nil) or (Now >= FVU.S.BusyUntil) then
    Exit;
  case (W shr 24) and $7F of
    $10, $11, $13, $14, $15, $17, $4A:
    begin
      S.WaitVU := True;
      var Event := TPS2Event.VIF0;
      if FIndex = 1 then
        Event := TPS2Event.VIF1;
      if FDomain <> nil then
        FScheduler.ScheduleAt(Event, FVU.S.BusyUntil)
      else
        FScheduler.Schedule(Event, FVU.S.BusyUntil);
      Result := True;
    end;
  end;
end;

procedure TPS2VIF.Wake;
begin
  FDomain.Check;
  if S.WaitVU then
  begin
    S.WaitVU := False;
    Release;
  end;
end;

// The stalled VIF keeps W for later; False when it has no room.
function TPS2VIF.Hold(W: Cardinal): Boolean;
begin
  Result := S.HeldCount <= High(S.Held);
  if Result then
  begin
    S.Held[S.HeldCount] := W;
    Inc(S.HeldCount);
  end;
end;

// After a stall cancel: the held words run until the VIF stalls again, then
// a channel waiting for room goes on.
procedure TPS2VIF.Release;
begin
  var Taken := 0;
  while (Taken < S.HeldCount) and not Waits(S.Held[Taken]) do
  begin
    // Inside an UNPACK nothing stalls before its last word: whole vectors of
    // the held words at once (as Feed takes them).
    if (S.Remaining > 1) and (S.Command >= $60) and not CaptureUnfinished and not Stalled and not S.WaitVU then
    begin
      var Run := UnpackRun(@S.Held[Taken], Min(S.HeldCount - Taken, Integer(S.Remaining) - 1));
      if Run > 0 then
      begin
        Inc(Taken, Run);
        Dec(S.Remaining, Run);
        Continue;
      end;
    end;
    var W := S.Held[Taken];
    Inc(Taken);
    ProcessWord(W);
  end;
  if Taken > 0 then
  begin
    Dec(S.HeldCount, Taken);
    if S.HeldCount > 0 then
      Move(S.Held[Taken], S.Held[0], S.HeldCount * SizeOf(Cardinal));
  end;
  if Assigned(FOnResume) then
    FOnResume();
end;

// STCYCL write length; 0 stands for 256.
function CycleWL(Cycle: Cardinal): Integer; inline;
begin
  Result := Integer((Cycle shr 8) and $FF);
  if Result = 0 then
    Result := 256;
end;

function UnpackWordsFor(Cmd: Cardinal; Num, CL, WL: Integer): Integer;
begin
  // Data words of an UNPACK: vectors actually read from the stream.
  var VN := Integer((Cmd shr 2) and 3);
  var VL := Integer(Cmd and 3);
  var Bits: Integer;
  if VL = 3 then
    Bits := 16
  else
    Bits := (32 shr VL) * (VN + 1);
  var Vectors := Num;
  if (WL > CL) and (CL > 0) then
  begin
    // Fill mode: only CL of every WL vectors come from the stream.
    Vectors := (Num div WL) * CL + Min(Num mod WL, CL);
  end;
  Result := (Vectors * Bits + 31) div 32;
end;

procedure TPS2VIF.StartCommand(W: Cardinal);
begin
  if CaptureUnfinished then
  begin
    CommandRing[CommandRingPos and High(CommandRing)][0] := W;
    CommandRing[CommandRingPos and High(CommandRing)][1] := S.TOPS or (S.MODE shl 12);
    CommandRing[CommandRingPos and High(CommandRing)][2] := $FFFFFFFF;
    Inc(CommandRingPos);
  end;
  S.CODE := W;
  var Cmd := (W shr 24) and $7F;
  var Imm := W and $FFFF;
  var Num := Integer((W shr 16) and $FF);
  S.Command := Cmd;
  S.Remaining := 0;
  case Cmd of
    $00: ;
    $01: S.CYCLE := Imm;
    $02:
      begin
        S.OFST := Imm and $3FF;
        S.DBF := False;
        S.TOPS := S.BASE;
      end;
    $03: S.BASE := Imm and $3FF;
    $04: S.ITOPS := Imm and $3FF;
    $05: S.MODE := Imm and 3;
    $06:
      begin
        S.Path3Masked := (Imm and $8000) <> 0;
        if FGIF <> nil then
        begin
          if (FGIF.TagLog <> nil) and (FGIF.TagLog.Count < 200000) then
            LogPath3Mask;
          FGIF.SetPath3Mask(S.Path3Masked);
        end;
      end;
    $07:
      begin
        S.MARK := Imm;
        S.STAT := S.STAT or $40;
      end;
    $10, $11, $13: ;
    $14, $15: StartVU((Imm * 8) and FCodeMask);
    $17: StartVU(FVU.S.TPC);
    $20: S.Remaining := 1;
    $30, $31: S.Remaining := 4;
    $4A:
      begin
        if Num = 0 then
          Num := 256;
        S.MPGAddr := (Imm * 8) and FCodeMask;
        S.Remaining := Num * 2;
      end;
    $50, $51:
      begin
        var Q := Integer(Imm);
        if Q = 0 then
          Q := 65536;
        S.Remaining := Q * 4;
        FDirectWords := 0;
      end;
    $60..$7F:
      begin
        if Num = 0 then
          Num := 256;
        S.NUM := Cardinal(Num);
        var Addr := Integer(Imm and $3FF);
        if (FIndex = 1) and ((Imm and $8000) <> 0) then
          Inc(Addr, Integer(S.TOPS));
        S.UnpackAddr := Addr;
        if (FGIF <> nil) and (FGIF.TagLog <> nil) and (FGIF.TagLog.Count < 200000) then
          LogUnpack(Cmd, Num, Addr, Imm);
        if CaptureUnfinished then
          CommandRing[(CommandRingPos - 1) and High(CommandRing)][2] := Cardinal(Addr);
        S.UnpackCount := 0;
        S.CycleIndex := 0;
        S.CycleWritten := 0;
        S.UnpackBits := 0;
        S.UnpackBitCount := 0;
        var CL := Integer(S.CYCLE and $FF);
        var WL := CycleWL(S.CYCLE);
        S.Remaining := UnpackWordsFor(Cmd, Num, CL, WL);
        if S.Remaining = 0 then
          FinishCommand;
      end;
  end;
  if S.Remaining = 0 then
    FinishCommand;
end;

procedure TPS2VIF.WriteVector(const V: TPS2Reg128);
begin
  var CL := Integer(S.CYCLE and $FF);
  var WL := CycleWL(S.CYCLE);
  var P := PPS2Reg128(FData + ((Cardinal(S.UnpackAddr) * 16) and FDataMask));
  if ((S.Command and $10) = 0) and (S.MODE = 0) then
  begin
    // No mask, no row: the data as it is (by words: V was written so).
    P.UW[0] := V.UW[0];
    P.UW[1] := V.UW[1];
    P.UW[2] := V.UW[2];
    P.UW[3] := V.UW[3];
  end
  else
    WriteMasked(V, P);
  Inc(S.UnpackCount);
  Inc(S.CycleWritten);
  // Write cycle: after WL writes, skip CL - WL vectors (or none in fill mode).
  if (WL > 0) and (S.CycleWritten >= WL) then
  begin
    S.CycleWritten := 0;
    if CL > WL then
      Inc(S.UnpackAddr, CL - WL + 1)
    else
      Inc(S.UnpackAddr);
  end
  else
    Inc(S.UnpackAddr);
end;

procedure TPS2VIF.WriteMasked(const V: TPS2Reg128; P: PPS2Reg128);
begin
  // (Word by word: V was written so, and each field's value depends on its
  // own only.)
  var Row := Min(S.CycleWritten, 3);
  // The mask bits of this row (none: every field takes the data).
  var Bits: Cardinal := 0;
  if (S.Command and $10) <> 0 then
    Bits := (S.MASK shr (Row * 8)) and $FF;
  var Mode := S.MODE;
  for var K := 0 to 3 do
  begin
    var W := V.UW[K];
    case (Bits shr (K * 2)) and 3 of
      0:
        case Mode of
          1: W := Cardinal(UInt64(W) + S.Row[K]);
          2:
            begin
              W := Cardinal(UInt64(W) + S.Row[K]);
              S.Row[K] := W;
            end;
          // Mode 3 keeps the data and loads it into the row.
          3: S.Row[K] := W;
        end;
      1: W := S.Row[K];
      2: W := S.Col[Row];
    else
      W := P.UW[K];
    end;
    P.UW[K] := W;
  end;
end;

// Whole vectors in a contiguous part of VU memory, with no row arithmetic
// and either no mask or a fixed row in z/w. No callback observes progress
// within the run: update the write-cycle counters once for all its vectors.
function TPS2VIF.UnpackContiguous(Data: PCardinal; Count, WordsPerVector: Integer): Integer;
begin
  Result := 0;
  var Kind := S.Command and $F;
  var WL := CycleWL(S.CYCLE);
  var Mask: Cardinal := 0;
  if (S.Command and $10) <> 0 then
  begin
    Mask := S.MASK and $FF;
    // Only mask rows actually selected by this write cycle need agree.
    for var Row := 1 to Min(WL - 1, 3) do
      if ((S.MASK shr (Row * 8)) and $FF) <> Mask then
        Exit;
  end;
  case Kind of
    $C, $E: if Mask <> 0 then Exit;
    $5: if Mask <> $50 then Exit;
    $8: if (Mask <> 0) and (Mask <> $40) then Exit;
  else
    Exit;
  end;
  if (S.CycleWritten < 0) or (S.CycleWritten >= WL) then
    Exit;
  var N := Min(Count div WordsPerVector, Integer(S.NUM) - S.UnpackCount);
  if N < 2 then
    Exit;
  var At := (Cardinal(S.UnpackAddr) * 16) and FDataMask;
  if Cardinal(N * 16) > FDataMask + 1 - At then
    Exit;
  var Target := PPS2Reg128(FData + At);
  // Preserve the word-at-a-time semantics when source and destination alias.
  var SourceEnd := NativeUInt(Data) + NativeUInt(N * WordsPerVector * 4);
  var TargetEnd := NativeUInt(Target) + NativeUInt(N * 16);
  if (NativeUInt(Data) < TargetEnd) and (NativeUInt(Target) < SourceEnd) then
    Exit;
  var Unsigned := (S.CODE and $4000) <> 0;
  case Kind of
    $C: Move(Data^, Target^, N * 16);
    $8:
      begin
        var W: Cardinal := 0;
        if Mask <> 0 then
          W := S.Row[3];
        for var I := 0 to N - 1 do
        begin
          Target.UW[0] := Data[0];
          Target.UW[1] := Data[1];
          Target.UW[2] := Data[2];
          Target.UW[3] := W;
          Inc(Data, 3);
          Inc(Target);
        end;
      end;
    $5:
      begin
        var R2 := S.Row[2];
        var R3 := S.Row[3];
        for var I := 0 to N - 1 do
        begin
          if Unsigned then
          begin
            Target.UW[0] := PWord(Data)[0];
            Target.UW[1] := PWord(Data)[1];
          end
          else
          begin
            Target.SW[0] := PSmallInt(Data)[0];
            Target.SW[1] := PSmallInt(Data)[1];
          end;
          Target.UW[2] := R2;
          Target.UW[3] := R3;
          Inc(Data);
          Inc(Target);
        end;
      end;
    $E:
      for var I := 0 to N - 1 do
      begin
        if Unsigned then
        begin
          Target.UW[0] := PByte(Data)[0];
          Target.UW[1] := PByte(Data)[1];
          Target.UW[2] := PByte(Data)[2];
          Target.UW[3] := PByte(Data)[3];
        end
        else
        begin
          Target.SW[0] := PShortInt(Data)[0];
          Target.SW[1] := PShortInt(Data)[1];
          Target.SW[2] := PShortInt(Data)[2];
          Target.SW[3] := PShortInt(Data)[3];
        end;
        Inc(Data);
        Inc(Target);
      end;
  end;
  // For 32-bit elements the last vector remains in UnpackWords as usual.
  if (Kind and 3) = 0 then
  begin
    if Kind = $C then
      Inc(Data, N * WordsPerVector);
    Dec(Data, WordsPerVector);
    for var K := 0 to WordsPerVector - 1 do
      S.UnpackWords[K] := Data[K];
  end;
  Inc(S.UnpackAddr, N);
  Inc(S.UnpackCount, N);
  S.CycleWritten := (S.CycleWritten + N) mod WL;
  Result := N * WordsPerVector;
  Inc(Self.Words, Result);
end;

// UnpackWord for many words at once where each vector takes whole words
// (32-bit elements, V2-16, V4-16, V4-8), no fill rows are due and no bits
// wait from an earlier word (WriteVector masks and offsets them): whole
// vectors of Data (at most Count words) as UnpackWord would write them, the
// state as it would leave it. The words taken (0: none, UnpackWord goes on).
function TPS2VIF.UnpackRun(Data: PCardinal; Count: Integer): Integer;
begin
  Result := 0;
  var Cmd := S.Command;
  if (S.UnpackBitCount <> 0) or (S.UnpackBits <> 0) or not PS2VIFRuns then
    Exit;
  var VN := Integer((Cmd shr 2) and 3);
  var VL := Integer(Cmd and 3);
  var Words: Integer;
  case VL of
    0: Words := VN + 1;
    1:
      if VN = 1 then
        Words := 1
      else if VN = 3 then
        Words := 2
      else
        Exit(UnpackGroups(Data, Count));
    2:
      if VN = 3 then
        Words := 1
      else
        Exit(UnpackGroups(Data, Count));
  else
    Exit;
  end;
  var Unsigned := (S.CODE and $4000) <> 0;
  var CL := Integer(S.CYCLE and $FF);
  var WL := CycleWL(S.CYCLE);
  var V: TPS2Reg128;
  if (S.MODE = 0) and (CL = WL) then
  begin
    Result := UnpackContiguous(Data, Count, Words);
    if Result > 0 then
      Exit;
  end;
  // No mask, no row kept from the data and no fill rows: see UnpackPlain.
  if ((Cmd and $10) = 0) and (S.MODE <= 1) and not ((WL > CL) and (CL > 0)) then
    Exit(UnpackPlain(Data, Count, VN, VL, Words, Unsigned, CL, WL));
  while (Result + Words <= Count)
    and (S.UnpackCount < Integer(S.NUM))
    and not ((WL > CL) and (CL > 0) and (S.CycleWritten >= CL)) do
  begin
    var D := Data + Result;
    case VL of
      0:
        case VN of
          0:
          begin
            V.UW[0] := D[0];
            V.UW[1] := D[0];
            V.UW[2] := D[0];
            V.UW[3] := D[0];
          end;
          1:
          begin
            V.UW[0] := D[0];
            V.UW[1] := D[1];
            V.UW[2] := D[0];
            V.UW[3] := D[1];
          end;
          2:
          begin
            V.UW[0] := D[0];
            V.UW[1] := D[1];
            V.UW[2] := D[2];
            V.UW[3] := 0;
          end;
        else
          begin
            V.UW[0] := D[0];
            V.UW[1] := D[1];
            V.UW[2] := D[2];
            V.UW[3] := D[3];
          end;
        end;
      1:
      begin
        // Halfwords, sign-extended unless unsigned; V2-16 repeats its two.
        for var K := 0 to Words * 2 - 1 do
        begin
          var Raw := (D[K shr 1] shr ((K and 1) * 16)) and $FFFF;
          if not Unsigned and ((Raw and $8000) <> 0) then
            Raw := Raw or $FFFF0000;
          V.UW[K] := Raw;
        end;
        if VN = 1 then
        begin
          V.UW[2] := V.UW[0];
          V.UW[3] := V.UW[1];
        end;
      end;
    else
      for var K := 0 to 3 do
      begin
        var Raw := (D[0] shr (K * 8)) and $FF;
        if not Unsigned and ((Raw and $80) <> 0) then
          Raw := Raw or $FFFFFF00;
        V.UW[K] := Raw;
      end;
    end;
    // (32-bit elements stay in UnpackWords, as UnpackWord leaves them.)
    if VL = 0 then
      for var K := 0 to VN do
        S.UnpackWords[K] := D[K];
    WriteVector(V);
    Inc(Result, Words);
  end;
  Inc(Self.Words, Result);
end;

// UnpackRun's vectors (PerVector words each) with no mask, MODE 0 or 1 (the
// row added) and no fill rows: each as WriteVector writes it, its counters
// kept here meanwhile (no callback runs). (Each vector's words are read
// before it is written, as in UnpackRun: a source inside VU memory reads
// what earlier vectors wrote.)
function TPS2VIF.UnpackPlain(
  Data: PCardinal;
  Count, VN, VL, PerVector: Integer;
  Unsigned: Boolean;
  CL, WL: Integer
): Integer;
var
  V, Last: array[0..3] of Cardinal;
begin
  Result := 0;
  var N := Min(Count div PerVector, Integer(S.NUM) - S.UnpackCount);
  if N <= 0 then
    Exit;
  var Addr := S.UnpackAddr;
  var Written := S.CycleWritten;
  var Skip := 1;
  if CL > WL then
    Skip := CL - WL + 1;
  var AddRow := S.MODE = 1;
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  if (FIndex = 1)
    and ((CL = WL) or ((WL = 1) and (CL >= 2) and (CL <= 8)))
    and (N >= 8)
    and (N <= 256)
    and (FDataMask = $3FFF)
    and (Written >= 0)
    and (Written < WL)
    and (Addr >= 0)
    and (Addr < $100000)
    and PS2VectorAVX2 then
  begin
    var Kernel: TExpandStride := nil;
    case VN * 4 + VL of
      $05:
        if Unsigned then
          Kernel := ExpandPairUStride
        else
          Kernel := ExpandPairSStride;
      $08: Kernel := ExpandTripleStride;
      $0D:
        if Unsigned then
          Kernel := ExpandShortUStride
        else
          Kernel := ExpandShortSStride;
      $0E:
        if Unsigned then
          Kernel := ExpandByteUStride
        else
          Kernel := ExpandByteSStride;
    end;
    var Src := NativeUInt(Data);
    var Dest := NativeUInt(FData);
    var Obj := NativeUInt(Self);
    if Assigned(Kernel)
      and ((Src + NativeUInt(N * PerVector) * 4 <= Dest) or (Src >= Dest + $4000))
      and ((Obj + NativeUInt(InstanceSize) <= Dest) or (Obj >= Dest + $4000)) then
    begin
      var Stride := 1;
      if CL <> WL then
        Stride := CL;
      var Row: PCardinal := @ZeroRow[0];
      if AddRow then
        Row := @S.Row[0];
      var D := Data;
      var Remaining := N;
      while Remaining > 0 do
      begin
        var Offset := Addr and $3FF;
        var Span := Remaining;
        if Offset + (Span - 1) * Stride > $3FF then
          Span := 1 + ($3FF - Offset) div Stride;
        if (VL = 2) and Unsigned and (Stride = 1) then
          ExpandBytesRow(D, FData + Offset * 16, Row, Span)
        else
          Kernel(D, FData + Offset * 16, Row, Span, Stride * 16);
        Inc(Addr, Span * Stride);
        Inc(D, Span * PerVector);
        Dec(Remaining, Span);
      end;
      if VL = 0 then
      begin
        Dec(D, PerVector);
        for var K := 0 to VN do
          S.UnpackWords[K] := D[K];
      end;
      S.UnpackAddr := Addr;
      S.CycleWritten := (Written + N) mod WL;
      Inc(S.UnpackCount, N);
      Result := N * PerVector;
      Inc(Self.Words, Result);

      Exit;
    end;
  end;
{$ENDIF}
  var D := Data;
  for var I := 0 to N - 1 do
  begin
    case VL of
      0:
      begin
        for var K := 0 to VN do
          Last[K] := D[K];
        case VN of
          0:
          begin
            V[0] := Last[0];
            V[1] := Last[0];
            V[2] := Last[0];
            V[3] := Last[0];
          end;
          1:
          begin
            V[0] := Last[0];
            V[1] := Last[1];
            V[2] := Last[0];
            V[3] := Last[1];
          end;
          2:
          begin
            V[0] := Last[0];
            V[1] := Last[1];
            V[2] := Last[2];
            V[3] := 0;
          end;
        else
          begin
            V[0] := Last[0];
            V[1] := Last[1];
            V[2] := Last[2];
            V[3] := Last[3];
          end;
        end;
      end;
      1:
      begin
        // Halfwords, sign-extended unless unsigned; V2-16 repeats its two.
        for var K := 0 to PerVector * 2 - 1 do
        begin
          var Raw := (D[K shr 1] shr ((K and 1) * 16)) and $FFFF;
          if not Unsigned and ((Raw and $8000) <> 0) then
            Raw := Raw or $FFFF0000;
          V[K] := Raw;
        end;
        if VN = 1 then
        begin
          V[2] := V[0];
          V[3] := V[1];
        end;
      end;
    else
      begin
        var W := D[0];
        for var K := 0 to 3 do
        begin
          var Raw := (W shr (K * 8)) and $FF;
          if not Unsigned and ((Raw and $80) <> 0) then
            Raw := Raw or $FFFFFF00;
          V[K] := Raw;
        end;
      end;
    end;
    if AddRow then
      for var K := 0 to 3 do
        V[K] := Cardinal(UInt64(V[K]) + S.Row[K]);
    var P := PCardinal(FData + ((Cardinal(Addr) * 16) and FDataMask));
    P[0] := V[0];
    P[1] := V[1];
    P[2] := V[2];
    P[3] := V[3];
    // Write cycle: after WL writes, skip CL - WL vectors.
    Inc(Written);
    if Written >= WL then
    begin
      Written := 0;
      Inc(Addr, Skip);
    end
    else
      Inc(Addr);
    Inc(D, PerVector);
  end;
  // (32-bit elements stay in UnpackWords, as UnpackWord leaves them.)
  if VL = 0 then
    for var K := 0 to VN do
      S.UnpackWords[K] := Last[K];
  S.UnpackAddr := Addr;
  S.CycleWritten := Written;
  Inc(S.UnpackCount, N);
  Result := N * PerVector;
  Inc(Self.Words, Result);
end;

// UnpackRun for the formats whose vectors share words (S-16, V3-16, S-8, V2-8,
// V3-8, V4-5): whole groups of words that end with a vector (the bits as
// UnpackWord gathers them, none left over), every vector of a group within
// NUM, outside fill mode.
function TPS2VIF.UnpackGroups(Data: PCardinal; Count: Integer): Integer;
begin
  Result := 0;
  var Cmd := S.Command;
  var VN := Integer((Cmd shr 2) and 3);
  var VL := Integer(Cmd and 3);
  // Words and vectors per group, and the vector's bits.
  var Group, Vectors, VecBits: Integer;
  case VL of
    1:
      case VN of
        0: begin Group := 1; Vectors := 2; VecBits := 16; end;
        2: begin Group := 3; Vectors := 2; VecBits := 48; end;
      else
        Exit;
      end;
    2:
      case VN of
        0: begin Group := 1; Vectors := 4; VecBits := 8; end;
        1: begin Group := 1; Vectors := 2; VecBits := 16; end;
        2: begin Group := 3; Vectors := 4; VecBits := 24; end;
      else
        Exit;
      end;
    3:
      begin
        Group := 1;
        Vectors := 2;
        VecBits := 16;
      end;
  else
    Exit;
  end;
  var CL := Integer(S.CYCLE and $FF);
  var WL := CycleWL(S.CYCLE);
  if (WL > CL) and (CL > 0) then
    Exit;
  var Unsigned := (S.CODE and $4000) <> 0;
  var ElemBits := 32 shr VL;
  var Mask := (Cardinal(1) shl ElemBits) - 1;
  var Sign := Cardinal(1) shl (ElemBits - 1);
  var V: TPS2Reg128;
  while (Result + Group <= Count) and (S.UnpackCount + Vectors <= Integer(S.NUM)) do
  begin
    var D := Data + Result;
    for var N := 0 to Vectors - 1 do
    begin
      var At := N * VecBits;
      if VL = 3 then
      begin
        var X := (D[At shr 5] shr (At and 31)) and $FFFF;
        V.UW[0] := (X and $1F) shl 3;
        V.UW[1] := ((X shr 5) and $1F) shl 3;
        V.UW[2] := ((X shr 10) and $1F) shl 3;
        V.UW[3] := ((X shr 15) and 1) shl 7;
      end
      else
      begin
        var E: array[0..2] of Cardinal;
        for var K := 0 to VN do
        begin
          var B := At + K * ElemBits;
          var Raw := (D[B shr 5] shr (B and 31)) and Mask;
          if not Unsigned and ((Raw and Sign) <> 0) then
            Raw := Raw or not Mask;
          E[K] := Raw;
        end;
        case VN of
          0:
            begin
              V.UW[0] := E[0];
              V.UW[1] := E[0];
              V.UW[2] := E[0];
              V.UW[3] := E[0];
            end;
          1:
            begin
              V.UW[0] := E[0];
              V.UW[1] := E[1];
              V.UW[2] := E[0];
              V.UW[3] := E[1];
            end;
        else
          begin
            V.UW[0] := E[0];
            V.UW[1] := E[1];
            V.UW[2] := E[2];
            V.UW[3] := 0;
          end;
        end;
      end;
      WriteVector(V);
    end;
    Inc(Result, Group);
  end;
  Inc(Self.Words, Result);
end;

procedure TPS2VIF.UnpackWord(W: Cardinal);
begin
  var Cmd := S.Command;
  var VN := Integer((Cmd shr 2) and 3);
  var VL := Integer(Cmd and 3);
  var Unsigned := (S.CODE and $4000) <> 0;
  var ElemBits := 32 shr VL;
  var VecBits: Integer;
  if VL = 3 then
    VecBits := 16
  else
    VecBits := ElemBits * (VN + 1);
  if VL = 0 then
    S.UnpackWords[(S.UnpackBitCount shr 5) and 3] := W
  else
    S.UnpackBits := S.UnpackBits or (UInt64(W) shl S.UnpackBitCount);
  Inc(S.UnpackBitCount, 32);
  var CL := Integer(S.CYCLE and $FF);
  var WL := CycleWL(S.CYCLE);
  while (S.UnpackBitCount >= VecBits) and (S.UnpackCount < Integer(S.NUM)) do
  begin
    // Fill mode writes the rows beyond CL from the mask/row without data.
    if (WL > CL) and (CL > 0) and (S.CycleWritten >= CL) then
    begin
      var Fill: TPS2Reg128;
      for var K := 0 to 3 do
        Fill.UW[K] := S.Row[K];
      WriteVector(Fill);
      Continue;
    end;
    var V: TPS2Reg128;
    if VL = 3 then
    begin
      var X := Cardinal(S.UnpackBits and $FFFF);
      V.UW[0] := (X and $1F) shl 3;
      V.UW[1] := ((X shr 5) and $1F) shl 3;
      V.UW[2] := ((X shr 10) and $1F) shl 3;
      V.UW[3] := ((X shr 15) and 1) shl 7;
    end
    else
    begin
      var E: array[0..3] of Cardinal;
      for var K := 0 to VN do
      begin
        var Raw: Cardinal;
        if VL = 0 then
          Raw := S.UnpackWords[K]
        else
          Raw := Cardinal((S.UnpackBits shr (K * ElemBits)) and ((UInt64(1) shl ElemBits) - 1));
        if (ElemBits < 32) and not Unsigned and ((Raw and (Cardinal(1) shl (ElemBits - 1))) <> 0) then
          Raw := Raw or not ((Cardinal(1) shl ElemBits) - 1);
        E[K] := Raw;
      end;
      case VN of
        0:
          for var K := 0 to 3 do
            V.UW[K] := E[0];
        1:
          begin
            V.UW[0] := E[0];
            V.UW[1] := E[1];
            V.UW[2] := E[0];
            V.UW[3] := E[1];
          end;
        2:
          begin
            V.UW[0] := E[0];
            V.UW[1] := E[1];
            V.UW[2] := E[2];
            V.UW[3] := 0;
          end;
      else
        for var K := 0 to 3 do
          V.UW[K] := E[K];
      end;
    end;
    // A 64-bit vector (V4-16) takes all the bits: shifts by 64 do nothing.
    if VecBits >= 64 then
      S.UnpackBits := 0
    else if VL <> 0 then
      S.UnpackBits := S.UnpackBits shr VecBits;
    Dec(S.UnpackBitCount, VecBits);
    WriteVector(V);
  end;
  // Fill rows that end the command.
  while (WL > CL) and (CL > 0) and (S.CycleWritten >= CL) and (S.UnpackCount < Integer(S.NUM)) and
    (S.Remaining <= 1) do
  begin
    var Fill: TPS2Reg128;
    for var K := 0 to 3 do
      Fill.UW[K] := S.Row[K];
    WriteVector(Fill);
  end;
end;

function TPS2VIF.TakeDirectSent: Boolean;
begin
  Result := FDirectSent;
  FDirectSent := False;
end;

function TPS2VIF.Feed(Data: PCardinal; Count: Integer): Integer;
begin
  FDomain.Check;
  Result := 0;
  while Result < Count do
  begin
    // Inside an UNPACK nothing stalls the VIF until the command ends: its
    // data words go straight to the unpacker.
    if (S.Remaining > 1)
      and (S.Command >= $60)
      and (S.HeldCount = 0)
      and not CaptureUnfinished
      and not Stalled
      and not S.WaitVU then
    begin
      while (Result < Count) and (S.Remaining > 1) do
      begin
        // (Whole vectors at once where it can, the last word of the command
        // left to ProcessWord.)
        var Run := UnpackRun(Data + Result, Min(Count - Result, Integer(S.Remaining) - 1));
        if Run > 0 then
        begin
          Inc(Result, Run);
          Dec(S.Remaining, Run);
          Continue;
        end;
        Inc(Words);
        UnpackWord(Data[Result]);
        Dec(S.Remaining);
        Inc(Result);
      end;
      Continue;
    end;
    // Inside DIRECT/DIRECTHL the same: whole quadwords go to the GIF as
    // ProcessWord would hand them over (through FDirectBuf), the last word
    // of the command left to it.
    if ((S.Command = $50) or (S.Command = $51))
      and (S.Remaining > 1)
      and (S.HeldCount = 0)
      and not CaptureUnfinished
      and not Stalled
      and not S.WaitVU
      and PS2VIFRuns then
    begin
      if (FDirectWords = 0) and (FGIF <> nil) then
      begin
        var Quads := Min((Count - Result) div 4, (S.Remaining - 1) div 4);
        if (Quads >= 2) and (NativeUInt(Quads) <= High(NativeUInt) div SizeOf(TPS2Reg128)) then
        begin
          var Source := NativeUInt(Data + Result);
          var Bytes := NativeUInt(Quads) * SizeOf(TPS2Reg128);
          if (Source <= High(NativeUInt) - Bytes)
            and ((Source + Bytes <= NativeUInt(Self)) or (Source >= NativeUInt(Self) + NativeUInt(InstanceSize))) then
          begin
            var Taken := FGIF.TransferDirectRun(Data + Result, Quads);
            if Taken > 0 then
            begin
              // Keep even the private staging value as repeated calls leave it.
              Move((Data + Result + (Taken - 1) * 4)^, FDirectBuf, SizeOf(FDirectBuf));
              FDirectSent := True;
              Inc(Words, Taken * 4);
              Inc(Result, Taken * 4);
              Dec(S.Remaining, Taken * 4);
            end;
          end;
        end;
      end;
      while (Result < Count) and (S.Remaining > 1) do
      begin
        if (FDirectWords = 0) and (FGIF <> nil) and (Count - Result >= 4) and (S.Remaining > 4) then
        begin
          var D := Data + Result;
          FDirectBuf.UW[0] := D[0];
          FDirectBuf.UW[1] := D[1];
          FDirectBuf.UW[2] := D[2];
          FDirectBuf.UW[3] := D[3];
          FGIF.TransferDirect(FDirectBuf);
          FDirectSent := True;
          Inc(Words, 4);
          Inc(Result, 4);
          Dec(S.Remaining, 4);
          Continue;
        end;
        ProcessWord(Data[Result]);
        Inc(Result);
      end;
      Continue;
    end;
    var W := Data[Result];
    if (S.HeldCount > 0) or Waits(W) then
    begin
      if not Hold(W) then
        Exit;
    end
    else
      ProcessWord(W);
    Inc(Result);
  end;
end;

// Interior of a VIF1 MPG command: no boundary, stall or callback occurs
// while these quadwords are consumed. Leave its last word to ProcessWord.
function TPS2VIF.UploadMicroQuads(Data: PCardinal; Available: Integer): Integer;
begin
  Result := 0;
  if not PS2VIFRuns
    or (FIndex <> 1)
    or (FCodeMask <> $3FFF)
    or (FVU = nil)
    or (FCode <> FVU.Code)
    or (Data = nil)
    or (S.Remaining <= 8)
    or (S.Remaining > 512)
    or (S.HeldCount <> 0)
    or CaptureUnfinished
    or Stalled
    or S.WaitVU
    or ((S.MPGAddr and 3) <> 0) then
    Exit;
  var Offset := S.MPGAddr and FCodeMask;
  var Quads := Min(Min(Available, (S.Remaining - 1) div 4), Integer((FCodeMask + 1 - Offset) div 16));
  if Quads < 2 then
    Exit;
  var Taken := Quads * 4;
  var Bytes := Cardinal(Taken * SizeOf(Cardinal));
  if (S.MPGAddr > High(Cardinal) - Bytes)
    or (Words > High(Int64) - Taken)
    or (NativeUInt(Data) > High(NativeUInt) - Bytes)
    or (NativeUInt(FCode) > High(NativeUInt) - FCodeMask - 1) then
    Exit;
  // The scalar path updates VIF fields after each word, which aliased
  // input can see. A destination must not modify the parser itself.
  var Owner := NativeUInt(Self);
  var OwnerEnd := Owner + NativeUInt(InstanceSize);
  if ((NativeUInt(Data) < OwnerEnd) and (Owner < NativeUInt(Data) + Bytes))
    or ((NativeUInt(FCode) < OwnerEnd) and (Owner < NativeUInt(FCode) + FCodeMask + 1)) then
    Exit;
  if (FDomain <> nil)
    and (NativeUInt(FCode) < NativeUInt(FDomain) + NativeUInt(FDomain.InstanceSize))
    and (NativeUInt(FDomain) < NativeUInt(FCode) + FCodeMask + 1) then
    Exit;
  if not FVU.TryUploadMicroWords(Offset, Data, Taken) then
    Exit;
  Inc(S.MPGAddr, Bytes);
  Inc(Words, Taken);
  Dec(S.Remaining, Taken);
  Result := Quads;
end;

function TPS2VIF.FeedQuads(Data: PCardinal; Count: Integer): Integer;
begin
  FDomain.Check;
  // FIFO: 8 quadwords on VIF0, 16 on VIF1.
  var FIFOWords := 32;
  if FIndex = 1 then
    FIFOWords := 64;
  Result := 0;
  while Result < Count do
  begin
    if S.HeldCount >= FIFOWords then
      Exit;
    if (S.Command = $4A) and (Count - Result >= 2) and (Result <= MaxInt div 4 - 128) then
    begin
      var Taken := UploadMicroQuads(Data + Result * 4, Count - Result);
      if Taken <> 0 then
      begin
        Inc(Result, Taken);
        Continue;
      end;
    end;
    // Inside an UNPACK or DIRECT nothing stalls before its last word: the
    // quadwords up to there at once (Feed takes them all, as one at a time).
    if (S.Remaining > 5)
      and ((S.Command >= $60) or (((S.Command = $50) or (S.Command = $51)) and PS2VIFRuns))
      and (S.HeldCount = 0)
      and not CaptureUnfinished
      and not Stalled
      and not S.WaitVU then
    begin
      var N := Min(Count - Result, (S.Remaining - 1) div 4);
      Feed(Data + Result * 4, N * 4);
      Inc(Result, N);
      Continue;
    end;
    Feed(Data + Result * 4, 4);
    Inc(Result);
  end;
end;

procedure TPS2VIF.ProcessWord(W: Cardinal);
begin
  Inc(Words);
  if S.Remaining = 0 then
  begin
    StartCommand(W);
    Exit;
  end;
  if CaptureUnfinished then
  begin
    CommandRing[CommandRingPos and High(CommandRing)][0] := W;
    CommandRing[CommandRingPos and High(CommandRing)][1] := $EEEEEEEE;
    CommandRing[CommandRingPos and High(CommandRing)][2] := 0;
    Inc(CommandRingPos);
  end;
  case S.Command of
    $20: S.MASK := W;
    $30: S.Row[4 - S.Remaining] := W;
    $31: S.Col[4 - S.Remaining] := W;
    $4A:
      begin
        PCardinal(FCode + (S.MPGAddr and FCodeMask))^ := W;
        FVU.NoteCodeWritten;
        S.MPGAddr := S.MPGAddr + 4;
      end;
    $50, $51:
      begin
        FDirectBuf.UW[FDirectWords] := W;
        Inc(FDirectWords);
        if FDirectWords = 4 then
        begin
          FDirectWords := 0;
          if FGIF <> nil then
          begin
            FGIF.TransferDirect(FDirectBuf);
            FDirectSent := True;
          end;
        end;
      end;
    $60..$7F: UnpackWord(W);
  end;
  Dec(S.Remaining);
  if S.Remaining = 0 then
    FinishCommand;
end;

function TPS2VIF.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  FDomain.Check;
  var R: TPS2VIFRegisters;
  GetRegisters(R);
  Result := RegisterValue(R, FIndex, Address and $1F0, FVU.Busy(Now));
end;

procedure TPS2VIF.SaveDomain(out C: TPS2VIFSaved);
begin
  C.S := S;
  C.DirectBuf := FDirectBuf;
  C.DirectWords := FDirectWords;
  C.DirectSent := FDirectSent;
  C.Words := Words;
  C.Starts := Starts;
  C.Unfinished := Unfinished;
end;

procedure TPS2VIF.RestoreDomain(const C: TPS2VIFSaved);
begin
  S := C.S;
  FDirectBuf := C.DirectBuf;
  FDirectWords := C.DirectWords;
  FDirectSent := C.DirectSent;
  Words := C.Words;
  Starts := C.Starts;
  Unfinished := C.Unfinished;
end;

procedure TPS2VIF.GetRegisters(out R: TPS2VIFRegisters);
begin
  R.STAT := S.STAT;
  R.ERR := S.ERR;
  R.MARK := S.MARK;
  R.CYCLE := S.CYCLE;
  R.MODE := S.MODE;
  R.NUM := S.NUM;
  R.MASK := S.MASK;
  R.CODE := S.CODE;
  R.ITOPS := S.ITOPS;
  R.BASE := S.BASE;
  R.OFST := S.OFST;
  R.TOPS := S.TOPS;
  R.ITOP := S.ITOP;
  R.TOP := S.TOP;
  Move(S.Row, R.Row, SizeOf(R.Row));
  Move(S.Col, R.Col, SizeOf(R.Col));
  R.Remaining := S.Remaining;
  R.HeldCount := S.HeldCount;
  R.DBF := S.DBF;
  R.Path3Masked := S.Path3Masked;
end;

class function TPS2VIF.RegisterValue(
  const R: TPS2VIFRegisters;
  Index: Integer;
  Offset: Cardinal;
  VUBusy: Boolean
): Cardinal;
begin
  case Offset of
    $000:
    begin
      // STAT: VPS (waiting for data while a command is open, or a
      // command fetched while stalled), VEW, MRK, DBF, VSS/VFS/VIS, INT,
      // FQC (0, as hardware reads with held data in ps2autotests).
      var V := R.STAT and $FC0;
      if R.Remaining > 0 then
        V := V or 1
      else if ((R.STAT and $700) <> 0) and (R.HeldCount > 0) then
        V := V or 2;
      if VUBusy then
        V := V or 4;
      if R.DBF then
        V := V or $80;
      if R.Path3Masked then
        V := V or $10;
      Result := V;
    end;
    $020: Result := R.ERR;
    $030: Result := R.MARK;
    $040: Result := R.CYCLE;
    $050: Result := R.MODE;
    $060:
      if Index = 0 then
        Result := R.NUM and $FF
      else
        Result := R.NUM;
    $070: Result := R.MASK;
    $080: Result := R.CODE;
    $090: Result := R.ITOPS;
    $0A0: Result := R.BASE;
    $0B0: Result := R.OFST;
    $0C0: Result := R.TOPS;
    $0D0: Result := R.ITOP;
    $0E0: Result := R.TOP;
    $100: Result := R.Row[0];
    $110: Result := R.Row[1];
    $120: Result := R.Row[2];
    $130: Result := R.Row[3];
    $140: Result := R.Col[0];
    $150: Result := R.Col[1];
    $160: Result := R.Col[2];
    $170: Result := R.Col[3];
  else
    Result := 0;
  end;
end;

procedure TPS2VIF.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  FDomain.Check;
  case Address and $1F0 of
    $010:
    begin
      // FBRST: reset with the FIFO (bit 0), force break (1: VFS now),
      // STOP (2: VSS at the next command), stall cancel (3: clears VSS,
      // VFS, VIS, INT, ER0, ER1; held words run).
      var Resume := False;
      if (Value and 1) <> 0 then
      begin
        Reset;
        Resume := True;
      end;
      if (Value and 2) <> 0 then
        S.STAT := S.STAT or $200;
      if (Value and 4) <> 0 then
        S.StopNext := True;
      if (Value and 8) <> 0 then
      begin
        S.STAT := S.STAT and not Cardinal($3F00);
        S.StallNext := False;
        S.StopNext := False;
        Release;
      end
      else if Resume and Assigned(FOnResume) then
        FOnResume();
    end;
    $020: S.ERR := Cardinal(Value);
    $030:
    begin
      // MARK: writes clear MRK.
      S.MARK := Cardinal(Value);
      S.STAT := S.STAT and not Cardinal($40);
    end;
    $100: S.Row[0] := Cardinal(Value);
    $110: S.Row[1] := Cardinal(Value);
    $120: S.Row[2] := Cardinal(Value);
    $130: S.Row[3] := Cardinal(Value);
    $140: S.Col[0] := Cardinal(Value);
    $150: S.Col[1] := Cardinal(Value);
    $160: S.Col[2] := Cardinal(Value);
    $170: S.Col[3] := Cardinal(Value);
  end;
end;

procedure TPS2VIF.WriteFIFO(Address: Cardinal; const Value: TPS2Reg128);
begin
  var V := Value;
  Feed(@V.UW[0], 4);
end;

procedure TPS2VIF.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
  State.Field(FDirectBuf, SizeOf(FDirectBuf));
  State.Field(FDirectWords, SizeOf(FDirectWords));
end;

{ TPS2VIFPort }

constructor TPS2VIFPort.Create(VIF: TPS2VIF);
begin
  inherited Create;
  FVIF := VIF;
end;

function TPS2VIFPort.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := FVIF.FeedQuads(PCardinal(Data), Count);
end;

function TPS2VIFPort.Pull(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := 0;
  if FVIF.FIndex <> 1 then
    Exit;
  // Reverse VIF1 DMA returns the GS local-to-host stream.
  var Value: TPS2Reg128;
  while Result < Count do
  begin
    if not FVIF.FGIF.GS.ReadImage(Value) then
      Break;
    PPS2Reg128(Data)[Result] := Value;
    Inc(Result);
  end;
end;

// (As FeedQuads takes a quadword: while the FIFO is not full.)
function TPS2VIFPort.TagRoom(Channel: Integer): Boolean;
begin
  var FIFOWords := 32;
  if FVIF.FIndex = 1 then
    FIFOWords := 64;
  Result := FVIF.S.HeldCount < FIFOWords;
end;

procedure TPS2VIFPort.Tag(Channel: Integer; const Tag: TPS2Reg128);
begin
  // TTE: the upper half of the DMA tag goes to the VIF as two words.
  var T := Tag;
  FVIF.Feed(@T.UW[2], 2);
end;

// DIRECT data reaches the GS after what is queued before it (PATH1 packets
// from earlier kicks, drawing in progress): the channel ends once the GS has
// drawn it all.
function TPS2VIFPort.BusyFromGS: Boolean;
begin
  Result := FVIF.TakeDirectSent;
end;

function TPS2VIFPort.TakeBusyCycles: Int64;
begin
  Result := 0;
  if FVIF.TakeDirectSent then
    Result := FVIF.FGIF.GSBusyCycles;
end;

end.
