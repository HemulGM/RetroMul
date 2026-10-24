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
    Stalled: Boolean;
    Path3Masked: Boolean;
  end;

  TPS2VIF = class(TPS2Device)
  private
    FIndex: Integer;
    FVU: TPS2VUCore;
    FGIF: TPS2GIF;
    FCode, FData: PByte;
    FCodeMask, FDataMask: Cardinal;
    FOnInterrupt: TProc;
    FDirectBuf: TPS2Reg128;
    FDirectWords: Integer;
    procedure StartCommand(W: Cardinal);
    procedure UnpackWord(W: Cardinal);
    procedure WriteVector(const V: TPS2Reg128);
    procedure FinishCommand;
    procedure StartVU(Address: Cardinal);
  public
    S: TPS2VIFState;
    // Words processed (diagnostics).
    Words: Int64;
    // Micro programs started, and those still running after the step limit.
    Starts, Unfinished: Int64;
    constructor Create(Index: Integer; VU: TPS2VUCore; GIF: TPS2GIF; Code, Data: PByte; CodeSize, DataSize: Cardinal);
    procedure Reset;
    // Feeds 32-bit words; returns how many were taken (fewer: stalled on IRQ).
    function Feed(Data: PCardinal; Count: Integer): Integer;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); override;
    procedure SerializeState(State: TStateArchive);
    property OnInterrupt: TProc read FOnInterrupt write FOnInterrupt;
  end;

  TPS2VIFPort = class(TPS2DMAPort)
  private
    FVIF: TPS2VIF;
  public
    constructor Create(VIF: TPS2VIF);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    procedure Tag(Channel: Integer; const Tag: TPS2Reg128); override;
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
  if not FVU.Run(4000000) then
    Inc(Unfinished);
end;

procedure TPS2VIF.FinishCommand;
begin
  S.Command := 0;
  S.Remaining := 0;
  if (S.CODE and $80000000) <> 0 then
  begin
    // IRQ bit: interrupt and stall after this command.
    S.STAT := S.STAT or $800;
    S.Stalled := True;
    if Assigned(FOnInterrupt) then
      FOnInterrupt();
  end;
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
          FGIF.MaskedPath3 := S.Path3Masked;
          if not S.Path3Masked and Assigned(FGIF.OnPath3Resume) then
            FGIF.OnPath3Resume();
        end;
      end;
    $07: S.MARK := Imm;
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
    if VL <> 0 then
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

function TPS2VIF.Feed(Data: PCardinal; Count: Integer): Integer;
begin
  Result := 0;
  while Result < Count do
  begin
    var W := Data[Result];
    Inc(Result);
    Inc(Words);
    if S.Remaining = 0 then
    begin
      StartCommand(W);
      Continue;
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
              FGIF.Transfer(2, @FDirectBuf, 1);
          end;
        end;
      $60..$7F: UnpackWord(W);
    end;
    Dec(S.Remaining);
    if S.Remaining = 0 then
      FinishCommand;
  end;
end;

function TPS2VIF.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  case Address and $1F0 of
    $000:
      begin
        // STAT: VPS (waiting for data while a command is open), VEW, DBF,
        // INT, FQC (empty).
        var V := S.STAT and $800;
        if S.Remaining > 0 then
          V := V or 1;
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
        // FBRST: reset (bit 0) and stall cancel (bit 3).
        if (Value and 1) <> 0 then
          Reset;
        if (Value and 8) <> 0 then
        begin
          S.Stalled := False;
          S.STAT := S.STAT and not Cardinal($800);
        end;
      end;
    $020: S.ERR := Cardinal(Value);
    $030: S.MARK := Cardinal(Value);
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
  // The IRQ bit interrupts but does not stall the stream yet.
  FVIF.Feed(PCardinal(Data), Count * 4);
  Result := Count;
end;

procedure TPS2VIFPort.Tag(Channel: Integer; const Tag: TPS2Reg128);
begin
  // TTE: the upper half of the DMA tag goes to the VIF as two words.
  var T := Tag;
  FVIF.Feed(@T.UW[2], 2);
end;

end.
