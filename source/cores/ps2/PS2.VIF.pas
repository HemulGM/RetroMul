unit PS2.VIF;

// VIF0/VIF1: the VIFcode stream from DMA channels 0/1 or the FIFOs. All
// commands (NOP, STCYCL, OFFSET, BASE, ITOP, STMOD, MSKPATH3, MARK, FLUSH*,
// MSCAL/MSCALF/MSCNT, STMASK, STROW, STCOL, MPG, DIRECT/DIRECTHL, UNPACK in
// every format with write cycles, masks and modes), double buffering of
// VU1 data (BASE/OFST/TOPS/TOP), the IRQ bit and the registers. VU micro
// programs run when started (synchronously for now).
// References: EE User's Manual (VIF chapter), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types, PS2.EE.Bus, PS2.DMAC, PS2.VU, PS2.GIF;

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
    Path3Masked: Boolean;
    // Words the stalled VIF holds (its FIFO and the rest of the current
    // quadword), oldest first.
    Held: array[0..79] of Cardinal;
    HeldCount: Integer;
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
    FDirectBuf: TPS2Reg128;
    FDirectWords: Integer;
    // DIRECT data went to the GIF (not yet taken).
    FDirectSent: Boolean;
    procedure StartCommand(W: Cardinal);
    procedure UnpackWord(W: Cardinal);
    procedure WriteVector(const V: TPS2Reg128);
    procedure FinishCommand;
    procedure StartVU(Address: Cardinal);
    procedure ProcessWord(W: Cardinal);
    function Stalled: Boolean; inline;
    function Blocked: Boolean;
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
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); override;
    procedure SerializeState(State: TStateArchive);
    property OnInterrupt: TProc read FOnInterrupt write FOnInterrupt;
    // The stall ended and the FIFO has room: a waiting DMA channel goes on.
    property OnResume: TProc read FOnResume write FOnResume;
  end;

  TPS2VIFPort = class(TPS2DMAPort)
  private
    FVIF: TPS2VIF;
  public
    constructor Create(VIF: TPS2VIF);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    procedure Tag(Channel: Integer; const Tag: TPS2Reg128); override;
    function TakeBusyCycles: Int64; override;
  end;

implementation

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

procedure TPS2VIF.StartVU(Address: Cardinal);
begin
  if (FGIF <> nil) and (FGIF.TagLog <> nil) and (FGIF.TagLog.Count < 200000) then
    FGIF.TagLog.Add(Format('vif%d start vu at %x', [FIndex, Address]));
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
  var Before: TBytes := nil;
  if CaptureUnfinished and (UnfinishedCapture = nil) then
  begin
    // Code, data and VI as the program starts.
    SetLength(Before, $8000 + 32 * 4);
    Move(FVU.Code^, Before[0], $4000);
    Move(FVU.Data^, Before[$4000], $4000);
    for var K := 0 to 31 do
      PCardinal(@Before[$8000 + K * 4])^ := FVU.VI[K];
    if FVU.RunTrace = nil then
      SetLength(FVU.RunTrace, 40000 * 16);
    FVU.RunTraceCount := 0;
  end;
  if not FVU.Run(4000000) then
  begin
    if Before <> nil then
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
    end;
    Inc(Unfinished);
    LastUnfinishedStart := Address;
    LastUnfinishedPC := FVU.S.TPC;
    for var K := 0 to 15 do
      LastUnfinishedVI[K] := FVU.VI[K];
  end;
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
  Result := Stalled;
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
  while (Taken < S.HeldCount) and not Blocked do
  begin
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
function CycleWL(Cycle: Cardinal): Integer;
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
            FGIF.TagLog.Add(Format('vif%d mskpath3 %d', [FIndex, Ord(S.Path3Masked)]));
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
          FGIF.TagLog.Add(Format('vif%d unpack %.2x num %d addr %x usn %d cycle %.4x mask %.8x mode %d', [FIndex, Cmd, Num,
            Addr, (Imm shr 14) and 1, S.CYCLE, S.MASK, S.MODE]));
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
  var Mask := S.MASK;
  var R := V;
  var CL := Integer(S.CYCLE and $FF);
  var WL := CycleWL(S.CYCLE);
  var Masked := ((S.Command and $10) <> 0);
  var Row := Min(S.CycleWritten, 3);
  var P := PPS2Reg128(FData + ((Cardinal(S.UnpackAddr) * 16) and FDataMask));
  for var K := 0 to 3 do
  begin
    var M := 0;
    if Masked then
      M := Integer((Mask shr (Row * 8 + K * 2)) and 3);
    case M of
      0:
        case S.MODE of
          1: R.UW[K] := Cardinal(UInt64(R.UW[K]) + S.Row[K]);
          2:
            begin
              R.UW[K] := Cardinal(UInt64(R.UW[K]) + S.Row[K]);
              S.Row[K] := R.UW[K];
            end;
          // Mode 3 keeps the data and loads it into the row.
          3: S.Row[K] := R.UW[K];
        end;
      1: R.UW[K] := S.Row[K];
      2: R.UW[K] := S.Col[Min(S.CycleWritten, 3)];
      3: R.UW[K] := P.UW[K];
    end;
  end;
  P^ := R;
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
  Result := 0;
  while Result < Count do
  begin
    var W := Data[Result];
    if (S.HeldCount > 0) or Blocked then
    begin
      if not Hold(W) then
        Exit;
    end
    else
      ProcessWord(W);
    Inc(Result);
  end;
end;

function TPS2VIF.FeedQuads(Data: PCardinal; Count: Integer): Integer;
begin
  // FIFO: 8 quadwords on VIF0, 16 on VIF1.
  var FIFOWords := 32;
  if FIndex = 1 then
    FIFOWords := 64;
  Result := 0;
  while Result < Count do
  begin
    if ((S.HeldCount > 0) or Blocked) and (S.HeldCount >= FIFOWords) then
      Exit;
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
            FGIF.Transfer(2, @FDirectBuf, 1);
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
  case Address and $1F0 of
    $000:
      begin
        // STAT: VPS (waiting for data while a command is open, or a
        // command fetched while stalled), VEW, MRK, DBF, VSS/VFS/VIS, INT,
        // FQC (0, as hardware reads with held data in ps2autotests).
        var V := S.STAT and $FC0;
        if S.Remaining > 0 then
          V := V or 1
        else if Stalled and (S.HeldCount > 0) then
          V := V or 2;
        if FVU.S.Running then
          V := V or 4;
        if S.DBF then
          V := V or $80;
        if S.Path3Masked then
          V := V or $10;
        Result := V;
      end;
    $020: Result := S.ERR;
    $030: Result := S.MARK;
    $040: Result := S.CYCLE;
    $050: Result := S.MODE;
    $060:
      if FIndex = 0 then
        Result := S.NUM and $FF
      else
        Result := S.NUM;
    $070: Result := S.MASK;
    $080: Result := S.CODE;
    $090: Result := S.ITOPS;
    $0A0: Result := S.BASE;
    $0B0: Result := S.OFST;
    $0C0: Result := S.TOPS;
    $0D0: Result := S.ITOP;
    $0E0: Result := S.TOP;
    $100: Result := S.Row[0];
    $110: Result := S.Row[1];
    $120: Result := S.Row[2];
    $130: Result := S.Row[3];
    $140: Result := S.Col[0];
    $150: Result := S.Col[1];
    $160: Result := S.Col[2];
    $170: Result := S.Col[3];
  else
    Result := 0;
  end;
end;

procedure TPS2VIF.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
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

procedure TPS2VIFPort.Tag(Channel: Integer; const Tag: TPS2Reg128);
begin
  // TTE: the upper half of the DMA tag goes to the VIF as two words.
  var T := Tag;
  FVIF.Feed(@T.UW[2], 2);
end;

// DIRECT data reaches the GS after what is queued before it (PATH1 packets
// from earlier kicks, drawing in progress): the channel ends once the GS has
// drawn it all.
function TPS2VIFPort.TakeBusyCycles: Int64;
begin
  Result := 0;
  if FVIF.TakeDirectSent then
    Result := FVIF.FGIF.GSBusyCycles;
end;

end.
