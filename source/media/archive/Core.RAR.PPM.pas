unit Core.RAR.PPM;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
{$POINTERMATH ON}

// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

//  TModelPPM — PPMd order-4 model (model.hpp / model.cpp / coder.cpp)
//  Dmitry Shkarin's original code, translated to Free Pascal.

//  TRangeCoder is declared in Core.RAR.Types and implemented there;
//  its GetChar delegates to TUnpackBase.GetChar, overridden by TUnpack.

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  SysUtils, Core.RAR.Types, Core.RAR.SubAlloc;

type
  TModelPPM = class
  private
    SEE2Cont: array[0..24, 0..15] of TRARPPM_SEE2_CONTEXT;
    DummySEE2Cont: TRARPPM_SEE2_CONTEXT;
    MinContext: PRARPPM_CONTEXT;
    MedContext: PRARPPM_CONTEXT;
    MaxContext: PRARPPM_CONTEXT;
    FoundState: PRARPPM_STATE;   // result of decode step
    NumMasked: Integer;
    InitEsc: Integer;
    OrderFall: Integer;
    MaxOrder: Integer;
    RunLength: Integer;
    InitRL: Integer;
    CharMask: array[0..255] of Byte;
    NS2Indx: array[0..255] of Byte;
    NS2BSIndx: array[0..255] of Byte;
    HB2Flag: array[0..255] of Byte;
    EscCount: Byte;
    PrevSuccess: Byte;
    HiBitsFlag: Byte;
    BinSumm: array[0..127, 0..63] of Word;

    procedure RestartModelRare;
    procedure StartModelRare(AMaxOrder: Integer);
    function CreateSuccessors(Skip: Boolean; p1: PRARPPM_STATE): PRARPPM_CONTEXT;
    procedure UpdateModel;
    procedure ClearMask; {$IFDEF FPC} inline;{$ENDIF}

    // SEE2 helpers
    procedure SEE2_Init(ps: PRARPPM_SEE2_CONTEXT; InitVal: Integer);
                                                   {$IFDEF FPC} inline;{$ENDIF}
    function SEE2_GetMean(ps: PRARPPM_SEE2_CONTEXT): LongWord;
                                                   {$IFDEF FPC} inline;{$ENDIF}
    procedure SEE2_Update(ps: PRARPPM_SEE2_CONTEXT);
                                                   {$IFDEF FPC} inline;{$ENDIF}

    // Context operations (replace C++ inline member functions)
    procedure Ctx_DecodeBinSymbol(pc: PRARPPM_CONTEXT);
    function Ctx_DecodeSymbol1(pc: PRARPPM_CONTEXT): Boolean;
    function Ctx_DecodeSymbol2(pc: PRARPPM_CONTEXT): Boolean;
    procedure Ctx_Update1(pc: PRARPPM_CONTEXT; p: PRARPPM_STATE);
    procedure Ctx_Update2(pc: PRARPPM_CONTEXT; p: PRARPPM_STATE);
    procedure Ctx_Rescale(pc: PRARPPM_CONTEXT);
    function Ctx_CreateChild(pc: PRARPPM_CONTEXT; pStats: PRARPPM_STATE; const FirstState: TRARPPM_STATE): PRARPPM_CONTEXT;
    function Ctx_MakeEscFreq2(pc: PRARPPM_CONTEXT; Diff: Integer): PRARPPM_SEE2_CONTEXT;

    // Inline expansion of ARI_DEC_NORMALIZE macro
    procedure AriNorm; {$IFDEF FPC} inline;{$ENDIF}

  public
    Coder: TRangeCoder;
    SubAlloc: TSubAllocator;

    constructor Create;
    destructor Destroy; override;

    procedure CleanUp;
    function DecodeInit(UnpackRead: TUnpackBase; var EscChar: Integer): Boolean;
    function DecodeChar: Integer;
  end;

implementation

// ── Helper macros as inline functions ────────────────────────────────────────

// GET_SHORT16(x) — truncate to Word
function GS16(x: LongWord): Word; {$IFDEF FPC} inline;{$ENDIF}
begin
  Result := Word(x);
end;

// GET_MEAN(SUMM, SHIFT, ROUND) = (SUMM + (1 shl (SHIFT-ROUND))) shr SHIFT
function GetMean(Summ, Shift, Round: LongWord): LongWord; {$IFDEF FPC} inline;{$ENDIF}
begin
  Result := (Summ + (1 shl (Shift - Round))) shr Shift;
end;

// Tabulated escapes for exponential symbol distribution
const
  ExpEscape: array[0..15] of Byte = (25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2);

// ── SEE2 helpers ─────────────────────────────────────────────────────────────

procedure TModelPPM.SEE2_Init(ps: PRARPPM_SEE2_CONTEXT; InitVal: Integer);
begin
  ps^.Summ := Word(InitVal shl (PPM_PERIOD_BITS - 4));
  ps^.Shift := PPM_PERIOD_BITS - 4;
  ps^.Count := 4;
end;

function TModelPPM.SEE2_GetMean(ps: PRARPPM_SEE2_CONTEXT): LongWord;
var
  RetVal: SmallInt;
begin
  RetVal := GS16(ps^.Summ) shr ps^.Shift;
  ps^.Summ := Word(Integer(ps^.Summ) - RetVal);
  if RetVal = 0 then
    Result := 1
  else
    Result := LongWord(RetVal);
end;

procedure TModelPPM.SEE2_Update(ps: PRARPPM_SEE2_CONTEXT);
begin
  if ps^.Shift < PPM_PERIOD_BITS then
  begin
    Dec(ps^.Count);
    if ps^.Count = 0 then
    begin
      ps^.Summ := ps^.Summ shl 1;
      ps^.Count := 3 shl ps^.Shift;
      Inc(ps^.Shift);
    end;
  end;
end;

// ── Context operations ───────────────────────────────────────────────────────

procedure TModelPPM.AriNorm;
// C++ macro: ARI_DEC_NORMALIZE(Coder.code, Coder.low, Coder.range, Coder.UnpackRead)
begin
  while True do
  begin
    if (Coder.low xor (Coder.low + Coder.range)) >= PPM_TOP then
    begin
      if Coder.range >= PPM_BOT then
        Break;
      // range < BOT: range = (-low) & (BOT-1)
      Coder.range := LongWord(-Int32(Coder.low)) and (PPM_BOT - 1);
    end;
    Coder.code := (Coder.code shl 8) or Coder.CoderGetChar;
    Coder.range := Coder.range shl 8;
    Coder.low := Coder.low shl 8;
  end;
end;

function TModelPPM.Ctx_CreateChild(pc: PRARPPM_CONTEXT; pStats: PRARPPM_STATE; const FirstState: TRARPPM_STATE): PRARPPM_CONTEXT;
var
  child: PRARPPM_CONTEXT;
begin
  child := PRARPPM_CONTEXT(SubAlloc.AllocContext);
  if child <> nil then
  begin
    child^.NumStats := 1;
    child^.U.OneState := FirstState;
    child^.Suffix := pc;
    pStats^.Successor := child;
  end;
  Result := child;
end;

procedure TModelPPM.Ctx_Rescale(pc: PRARPPM_CONTEXT);
var
  OldNS, i, Adder, EscFreq: Integer;
  p1, p: PRARPPM_STATE;
  tmp: TRARPPM_STATE;
begin
  OldNS := pc^.NumStats;
  i := pc^.NumStats - 1;
  // Move FoundState to front.
  p := FoundState;
  while p <> pc^.U.Stats do
  begin
    tmp := p^;
    p^ := (p - 1)^;
    (p - 1)^ := tmp;
    Dec(p);
  end;
  pc^.U.Stats^.Freq := pc^.U.Stats^.Freq + 4;
  pc^.U.SummFreq := pc^.U.SummFreq + 4;
  EscFreq := pc^.U.SummFreq - p^.Freq;
  Adder := Ord(OrderFall <> 0);
  pc^.U.SummFreq := 0;
  p^.Freq := (p^.Freq + Adder) shr 1;
  pc^.U.SummFreq := p^.Freq;
  repeat
    Inc(p);
    Dec(EscFreq, p^.Freq);
    p^.Freq := (p^.Freq + Adder) shr 1;
    Inc(pc^.U.SummFreq, p^.Freq);
    if (p^.Freq > (p - 1)^.Freq) then
    begin
      tmp := p^;
      p1 := p;
      repeat
        p1^ := (p1 - 1)^;
        Dec(p1);
      until (p1 = pc^.U.Stats) or (tmp.Freq <= (p1 - 1)^.Freq);
      p1^ := tmp;
    end;
    Dec(i);
  until i = 0;

  // Remove zero-freq entries.
  if p^.Freq = 0 then
  begin
    i := 0;
    repeat
      Inc(i);
      Dec(p);
    until p^.Freq <> 0;
    Inc(EscFreq, i);
    Dec(pc^.NumStats, i);
    if pc^.NumStats = 1 then
    begin
      tmp := pc^.U.Stats^;
      repeat
        tmp.Freq := tmp.Freq - (tmp.Freq shr 1);
        EscFreq := EscFreq shr 1;
      until EscFreq <= 1;
      SubAlloc.FreeUnits(pc^.U.Stats, (OldNS + 1) shr 1);
      pc^.U.OneState := tmp;
      FoundState := @pc^.U.OneState;
      Exit;
    end;
  end;
  Inc(pc^.U.SummFreq, EscFreq - (EscFreq shr 1));
  if ((OldNS + 1) shr 1) <> ((pc^.NumStats + 1) shr 1) then
    pc^.U.Stats := PRARPPM_STATE(
      SubAlloc.ShrinkUnits(pc^.U.Stats, (OldNS + 1) shr 1,
        (pc^.NumStats + 1) shr 1));
  FoundState := pc^.U.Stats;
end;

procedure TModelPPM.Ctx_DecodeBinSymbol(pc: PRARPPM_CONTEXT);
var
  rs: PRARPPM_STATE;
  bs: PWord;
begin
  rs := @pc^.U.OneState;
  HiBitsFlag := HB2Flag[FoundState^.Symbol];
  bs := @BinSumm[rs^.Freq - 1][
      PrevSuccess
      + NS2BSIndx[pc^.Suffix^.NumStats - 1]
      + HiBitsFlag
      + 2 * HB2Flag[rs^.Symbol]
      + ((LongWord(RunLength) shr 26) and $20)];
  if Coder.GetCurrentShiftCount(PPM_TOT_BITS) < bs^ then
  begin
    FoundState := rs;
    rs^.Freq := rs^.Freq + Ord(rs^.Freq < 128);
    Coder.SubRange.LowCount := 0;
    Coder.SubRange.HighCount := bs^;
    bs^ := GS16(bs^ + PPM_INTERVAL - GetMean(bs^, PPM_PERIOD_BITS, 2));
    PrevSuccess := 1;
    Inc(RunLength);
  end
  else
  begin
    Coder.SubRange.LowCount := bs^;
    bs^ := GS16(bs^ - GetMean(bs^, PPM_PERIOD_BITS, 2));
    Coder.SubRange.HighCount := PPM_BIN_SCALE;
    InitEsc := ExpEscape[bs^ shr 10];
    NumMasked := 1;
    CharMask[rs^.Symbol] := EscCount;
    PrevSuccess := 0;
    FoundState := nil;
  end;
end;

procedure TModelPPM.Ctx_Update1(pc: PRARPPM_CONTEXT; p: PRARPPM_STATE);
var
  tmp: TRARPPM_STATE;
begin
  FoundState := p;
  Inc(p^.Freq, 4);
  Inc(pc^.U.SummFreq, 4);
  if p^.Freq > (p - 1)^.Freq then
  begin
    tmp := p^;
    p^ := (p - 1)^;
    (p - 1)^ := tmp;
    FoundState := p - 1;
    if FoundState^.Freq > PPM_MAX_FREQ then
      Ctx_Rescale(pc);
  end;
end;

function TModelPPM.Ctx_DecodeSymbol1(pc: PRARPPM_CONTEXT): Boolean;
var
  p: PRARPPM_STATE;
  i, HiCnt, count: Integer;
begin
  Coder.SubRange.scale := pc^.U.SummFreq;
  p := pc^.U.Stats;
  count := Coder.GetCurrentCount;
  if count >= Integer(Coder.SubRange.scale) then
  begin
    Result := False;
    Exit;
  end;
  HiCnt := p^.Freq;
  if count < HiCnt then
  begin
    PrevSuccess := Ord(2 * HiCnt > Integer(Coder.SubRange.scale));
    Inc(RunLength, PrevSuccess);
    FoundState := p;
    Inc(p^.Freq, 4);
    Inc(pc^.U.SummFreq, 4);
    if p^.Freq > PPM_MAX_FREQ then
      Ctx_Rescale(pc);
    Coder.SubRange.LowCount := 0;
    Coder.SubRange.HighCount := HiCnt;
    Result := True;
    Exit;
  end
  else if FoundState = nil then
  begin
    Result := False;
    Exit;
  end;
  PrevSuccess := 0;
  i := pc^.NumStats - 1;
  repeat
    Inc(p);
    Inc(HiCnt, p^.Freq);
    if HiCnt > count then
      Break;
    Dec(i);
    if i = 0 then
    begin
      HiBitsFlag := HB2Flag[FoundState^.Symbol];
      Coder.SubRange.LowCount := HiCnt;
      CharMask[p^.Symbol] := EscCount;
      i := pc^.NumStats - 1;
      NumMasked := pc^.NumStats;
      FoundState := nil;
      repeat
        Dec(p);
        CharMask[p^.Symbol] := EscCount;
        Dec(i);
      until i = 0;
      Coder.SubRange.HighCount := Coder.SubRange.scale;
      Result := True;
      Exit;
    end;
  until HiCnt > count;
  Coder.SubRange.LowCount := HiCnt - p^.Freq;
  Coder.SubRange.HighCount := HiCnt;
  Ctx_Update1(pc, p);
  Result := True;
end;

procedure TModelPPM.Ctx_Update2(pc: PRARPPM_CONTEXT; p: PRARPPM_STATE);
begin
  FoundState := p;
  Inc(p^.Freq, 4);
  Inc(pc^.U.SummFreq, 4);
  if p^.Freq > PPM_MAX_FREQ then
    Ctx_Rescale(pc);
  Inc(EscCount);
  RunLength := InitRL;
end;

function TModelPPM.Ctx_MakeEscFreq2(pc: PRARPPM_CONTEXT; Diff: Integer): PRARPPM_SEE2_CONTEXT;
begin
  if pc^.NumStats <> 256 then
  begin
    Result := @SEE2Cont[NS2Indx[Diff - 1]][
        Ord(Diff < pc^.Suffix^.NumStats - pc^.NumStats)
        + 2 * Ord((pc^.U.SummFreq) < 11 * pc^.NumStats)
        + 4 * Ord(NumMasked > Diff)
        + HiBitsFlag];
    Coder.SubRange.scale := SEE2_GetMean(Result);
  end
  else
  begin
    Result := @DummySEE2Cont;
    Coder.SubRange.scale := 1;
  end;
end;

function TModelPPM.Ctx_DecodeSymbol2(pc: PRARPPM_CONTEXT): Boolean;
const
  MAX_PS = 256;
var
  count, HiCnt, i: Integer;
  psee2c: PRARPPM_SEE2_CONTEXT;
  ps: array[0..MAX_PS - 1] of PRARPPM_STATE;
  pps: Integer;  // index into ps[]
  p: PRARPPM_STATE;
begin
  i := pc^.NumStats - NumMasked;
  if i <= 0 then
  begin
    Result := False;
    Exit;
  end;
  psee2c := Ctx_MakeEscFreq2(pc, i);
  pps := 0;
  p := pc^.U.Stats - 1;
  HiCnt := 0;
  repeat
    repeat
      Inc(p);
      if p >= pc^.U.Stats + pc^.NumStats then
      begin
        Result := False;
        Exit;
      end;
    until CharMask[p^.Symbol] <> EscCount;
    Inc(HiCnt, p^.Freq);
    if pps >= MAX_PS then
    begin
      Result := False;
      Exit;
    end;
    ps[pps] := p;
    Inc(pps);
    Dec(i);
  until i = 0;
  Inc(Coder.SubRange.scale, HiCnt);
  count := Coder.GetCurrentCount;
  if count >= Integer(Coder.SubRange.scale) then
  begin
    Result := False;
    Exit;
  end;
  p := ps[0];
  if count < HiCnt then
  begin
    HiCnt := 0;
    i := 0;
    while HiCnt + ps[i]^.Freq <= count do
    begin
      Inc(HiCnt, ps[i]^.Freq);
      Inc(i);
      if i >= pps then
      begin
        Result := False;
        Exit;
      end;
      p := ps[i];
    end;
    Coder.SubRange.LowCount := HiCnt;
    Coder.SubRange.HighCount := HiCnt + p^.Freq;
    SEE2_Update(psee2c);
    Ctx_Update2(pc, p);
  end
  else
  begin
    Coder.SubRange.LowCount := HiCnt;
    Coder.SubRange.HighCount := Coder.SubRange.scale;
    i := pc^.NumStats - NumMasked;
    pps := 0;
    repeat
      CharMask[ps[pps]^.Symbol] := EscCount;
      Inc(pps);
      Dec(i);
    until i = 0;
    Inc(psee2c^.Summ, Word(Coder.SubRange.scale));
    NumMasked := pc^.NumStats;
  end;
  Result := True;
end;

// ── ModelPPM main ────────────────────────────────────────────────────────────

constructor TModelPPM.Create;
begin
  SubAlloc := TSubAllocator.Create;
  MinContext := nil;
  MaxContext := nil;
  MedContext := nil;
end;

destructor TModelPPM.Destroy;
begin
  SubAlloc.Free;
  inherited;
end;

procedure TModelPPM.RestartModelRare;
const
  InitBinEsc: array[0..7] of Word = (
    $3CDD, $1F3F, $59BF, $48F3, $64A1, $5ABC, $6632, $6051);
var
  i, k, m: Integer;
begin
  FillChar(CharMask, SizeOf(CharMask), 0);
  SubAlloc.InitSubAllocator;
  if MaxOrder < 12 then
    InitRL := -(MaxOrder) - 1
  else
    InitRL := -13;
  MinContext := PRARPPM_CONTEXT(SubAlloc.AllocContext);
  if MinContext = nil then
    raise EOutOfMemory.Create('PPM alloc');
  MaxContext := MinContext;
  MinContext^.Suffix := nil;
  OrderFall := MaxOrder;
  MinContext^.NumStats := 256;
  MinContext^.U.SummFreq := MinContext^.NumStats + 1;
  FoundState := PRARPPM_STATE(SubAlloc.AllocUnits(256 div 2));
  if FoundState = nil then
    raise EOutOfMemory.Create('PPM alloc');
  MinContext^.U.Stats := FoundState;
  RunLength := InitRL;
  PrevSuccess := 0;
  for i := 0 to 255 do
  begin
    MinContext^.U.Stats[i].Symbol := Byte(i);
    MinContext^.U.Stats[i].Freq := 1;
    MinContext^.U.Stats[i].Successor := nil;
  end;
  for i := 0 to 127 do
    for k := 0 to 7 do
      for m := 0 to 7 do
        BinSumm[i][k + m * 8] :=
          PPM_BIN_SCALE - InitBinEsc[k] div (i + 2);
  for i := 0 to 24 do
    for k := 0 to 15 do
      SEE2_Init(@SEE2Cont[i][k], 5 * i + 10);
end;

procedure TModelPPM.StartModelRare(AMaxOrder: Integer);
var
  i, k, m, Step: Integer;
begin
  EscCount := 1;
  MaxOrder := AMaxOrder;
  RestartModelRare;
  NS2BSIndx[0] := 2 * 0;
  NS2BSIndx[1] := 2 * 1;
  FillChar(NS2BSIndx[2], 9, 2 * 2);
  FillChar(NS2BSIndx[11], 256 - 11, 2 * 3);
  for i := 0 to 2 do
    NS2Indx[i] := i;
  m := 3;
  k := 1;
  Step := 1;
  for i := 3 to 255 do
  begin
    NS2Indx[i] := m;
    Dec(k);
    if k = 0 then
    begin
      Inc(Step);
      Inc(m);
      k := Step;
    end;
  end;
  FillChar(HB2Flag[0], $40, 0);
  FillChar(HB2Flag[$40], $100 - $40, 8);
  DummySEE2Cont.Shift := PPM_PERIOD_BITS;
end;

procedure TModelPPM.ClearMask;
begin
  EscCount := 1;
  FillChar(CharMask, SizeOf(CharMask), 0);
end;

// ── CreateSuccessors ──────────────────────────────────────────────────────────

function TModelPPM.CreateSuccessors(Skip: Boolean; p1: PRARPPM_STATE): PRARPPM_CONTEXT;
label
  NO_LOOP, LOOP_ENTRY;
var
  UpState: TRARPPM_STATE;
  pc, UpBranch: PRARPPM_CONTEXT;
  p: PRARPPM_STATE;
  ps: array[0..PPM_MAX_O - 1] of PRARPPM_STATE;
  pps: Integer;  // index into ps[]
  cf, s0: LongWord;
begin
  pc := MinContext;
  UpBranch := FoundState^.Successor;
  pps := 0;
  if not Skip then
  begin
    ps[pps] := FoundState;
    Inc(pps);
    if pc^.Suffix = nil then
      goto NO_LOOP;
  end;
  if p1 <> nil then
  begin
    p := p1;
    pc := pc^.Suffix;
    goto LOOP_ENTRY;
  end;
  // The label/goto structure is preserved via a loop:
  repeat
    pc := pc^.Suffix;
    if pc^.NumStats <> 1 then
    begin
      p := pc^.U.Stats;
      if p^.Symbol <> FoundState^.Symbol then
        repeat
          Inc(p)
        until p^.Symbol = FoundState^.Symbol;
    end
    else
      p := @pc^.U.OneState;
LOOP_ENTRY:
    if p^.Successor <> UpBranch then
    begin
      pc := p^.Successor;
      Break;
    end;
    if pps >= PPM_MAX_O then
    begin
      Result := nil;
      Exit;
    end;
    ps[pps] := p;
    Inc(pps);
    if p1 <> nil then
    begin
      p1 := nil;
    end; // only first iteration
  until pc^.Suffix = nil;
NO_LOOP:
  if pps = 0 then
  begin
    Result := pc;
    Exit;
  end;

  UpState.Symbol := PByte(UpBranch)^;
  UpState.Successor := PRARPPM_CONTEXT(PByte(UpBranch) + 1);
  if pc^.NumStats <> 1 then
  begin
    if PByte(pc) <= SubAlloc.pText then
    begin
      Result := nil;
      Exit;
    end;
    p := pc^.U.Stats;
    if p^.Symbol <> UpState.Symbol then
      repeat
        Inc(p)
      until p^.Symbol = UpState.Symbol;
    cf := p^.Freq - 1;
    s0 := LongWord(pc^.U.SummFreq) - LongWord(pc^.NumStats) - cf;
    if 2 * cf <= s0 then
      UpState.Freq := 1 + Ord(5 * cf > s0)
    else
      UpState.Freq := Byte((2 * cf + 3 * s0 - 1) div (2 * s0)) + 1;
  end
  else
    UpState.Freq := pc^.U.OneState.Freq;

  repeat
    Dec(pps);
    pc := Ctx_CreateChild(pc, ps[pps], UpState);
    if pc = nil then
    begin
      Result := nil;
      Exit;
    end;
  until pps = 0;
  Result := pc;
end;

// ── UpdateModel ───────────────────────────────────────────────────────────────

procedure TModelPPM.UpdateModel;
label
  RESTART_MODEL;
var
  fs: TRARPPM_STATE;
  p: PRARPPM_STATE;
  pc, Successor: PRARPPM_CONTEXT;
  ns1, ns, cf, sf, s0: LongWord;
  SwapTmp: TRARPPM_STATE;
begin
  fs := FoundState^;
  p := nil;
  if (fs.Freq < PPM_MAX_FREQ div 4) and (MinContext^.Suffix <> nil) then
  begin
    pc := MinContext^.Suffix;
    if pc^.NumStats <> 1 then
    begin
      p := pc^.U.Stats;
      if p^.Symbol <> fs.Symbol then
      begin
        repeat
          Inc(p)
        until p^.Symbol = fs.Symbol;
        if p^.Freq >= (p - 1)^.Freq then
        begin
          SwapTmp := p^;
          p^ := (p - 1)^;
          (p - 1)^ := SwapTmp;
          p := p - 1;
        end;
      end;
      if p^.Freq < PPM_MAX_FREQ - 9 then
      begin
        Inc(p^.Freq, 2);
        Inc(pc^.U.SummFreq, 2);
      end;
    end
    else
    begin
      p := @pc^.U.OneState;
      if p^.Freq < 32 then
        Inc(p^.Freq);
    end;
  end;

  if OrderFall = 0 then
  begin
    MinContext := CreateSuccessors(True, p);
    MaxContext := MinContext;
    if MinContext = nil then
      goto RESTART_MODEL;
    FoundState^.Successor := MinContext;
    Exit;
  end;
  SubAlloc.pText^ := fs.Symbol;
  Inc(SubAlloc.pText);
  Successor := PRARPPM_CONTEXT(SubAlloc.pText);
  if SubAlloc.pText >= SubAlloc.FakeUnitsStart then
    goto RESTART_MODEL;
  if fs.Successor <> nil then
  begin
    if PByte(fs.Successor) <= SubAlloc.pText then
    begin
      fs.Successor := CreateSuccessors(False, p);
      if fs.Successor = nil then
        goto RESTART_MODEL;
    end;
    Dec(OrderFall);
    if OrderFall = 0 then
    begin
      Successor := fs.Successor;
      if MaxContext <> MinContext then
        Dec(SubAlloc.pText);
    end;
  end
  else
  begin
    FoundState^.Successor := Successor;
    fs.Successor := MinContext;
  end;
  s0 := MinContext^.U.SummFreq - MinContext^.NumStats - (fs.Freq - 1);
  ns := MinContext^.NumStats;
  pc := MaxContext;
  while pc <> MinContext do
  begin
    ns1 := pc^.NumStats;
    if ns1 <> 1 then
    begin
      if (ns1 and 1) = 0 then
      begin
        pc^.U.Stats := PRARPPM_STATE(
          SubAlloc.ExpandUnits(pc^.U.Stats, ns1 shr 1));
        if pc^.U.Stats = nil then
          goto RESTART_MODEL;
      end;
      Inc(pc^.U.SummFreq,
        Ord(2 * ns1 < ns)
        + 2 * Ord((4 * ns1 <= ns) and (pc^.U.SummFreq <= 8 * ns1)));
    end
    else
    begin
      p := PRARPPM_STATE(SubAlloc.AllocUnits(1));
      if p = nil then
        goto RESTART_MODEL;
      p^ := pc^.U.OneState;
      pc^.U.Stats := p;
      if p^.Freq < PPM_MAX_FREQ div 4 - 1 then
        p^.Freq := p^.Freq * 2
      else
        p^.Freq := PPM_MAX_FREQ - 4;
      pc^.U.SummFreq := p^.Freq + InitEsc + Ord(ns > 3);
    end;
    cf := 2 * fs.Freq * (pc^.U.SummFreq + 6);
    sf := s0 + pc^.U.SummFreq;
    if cf < 6 * sf then
    begin
      cf := 1 + Ord(cf > sf) + Ord(cf >= 4 * sf);
      Inc(pc^.U.SummFreq, 3);
    end
    else
    begin
      cf := 4 + Ord(cf >= 9 * sf) + Ord(cf >= 12 * sf) + Ord(cf >= 15 * sf);
      Inc(pc^.U.SummFreq, cf);
    end;
    p := pc^.U.Stats + ns1;
    p^.Successor := Successor;
    p^.Symbol := fs.Symbol;
    p^.Freq := Byte(cf);
    pc^.NumStats := Word(ns1 + 1);
    pc := pc^.Suffix;
  end;
  MaxContext := fs.Successor;
  MinContext := MaxContext;
  Exit;
RESTART_MODEL:
  RestartModelRare;
  EscCount := 0;
end;

// ── Public interface ──────────────────────────────────────────────────────────

procedure TModelPPM.CleanUp;
begin
  SubAlloc.StopSubAllocator;
  SubAlloc.StartSubAllocator(1);
  StartModelRare(2);
end;

function TModelPPM.DecodeInit(UnpackRead: TUnpackBase; var EscChar: Integer): Boolean;
var
  AMaxOrder, MaxMB: Integer;
  Reset: Boolean;
begin
  MaxMB := 0; // Only reset blocks supply and consume this byte.
  AMaxOrder := UnpackRead.GetChar;
  Reset := (AMaxOrder and $20) <> 0;
  if Reset then
    MaxMB := UnpackRead.GetChar
  else if SubAlloc.GetAllocatedMemory = 0 then
  begin
    Result := False;
    Exit;
  end;
  if (AMaxOrder and $40) <> 0 then
    EscChar := UnpackRead.GetChar;
  Coder.InitDecoder(UnpackRead);
  if Reset then
  begin
    AMaxOrder := (AMaxOrder and $1F) + 1;
    if AMaxOrder > 16 then
      AMaxOrder := 16 + (AMaxOrder - 16) * 3;
    if AMaxOrder = 1 then
    begin
      SubAlloc.StopSubAllocator;
      Result := False;
      Exit;
    end;
    SubAlloc.StartSubAllocator(MaxMB + 1);
    StartModelRare(AMaxOrder);
  end;
  Result := MinContext <> nil;
end;

function TModelPPM.DecodeChar: Integer;
var
  Symbol: Integer;
begin
  if (PByte(MinContext) <= SubAlloc.pText)
    or (PByte(MinContext) > SubAlloc.HeapEnd) then
  begin
    Result := -1;
    Exit;
  end;

  if MinContext^.NumStats <> 1 then
  begin
    if (PByte(MinContext^.U.Stats) <= SubAlloc.pText)
      or (PByte(MinContext^.U.Stats) > SubAlloc.HeapEnd) then
    begin
      Result := -1;
      Exit;
    end;
    if not Ctx_DecodeSymbol1(MinContext) then
    begin
      Result := -1;
      Exit;
    end;
  end
  else
    Ctx_DecodeBinSymbol(MinContext);

  Coder.Decode;

  while FoundState = nil do
  begin
    AriNorm;
    repeat
      Inc(OrderFall);
      MinContext := MinContext^.Suffix;
      if (PByte(MinContext) <= SubAlloc.pText)
        or (PByte(MinContext) > SubAlloc.HeapEnd) then
      begin
        Result := -1;
        Exit;
      end;
    until MinContext^.NumStats <> NumMasked;
    if not Ctx_DecodeSymbol2(MinContext) then
    begin
      Result := -1;
      Exit;
    end;
    Coder.Decode;
  end;

  Symbol := FoundState^.Symbol;
  if (OrderFall = 0) and (PByte(FoundState^.Successor) > SubAlloc.pText) then
  begin
    MinContext := FoundState^.Successor;
    MaxContext := MinContext;
  end
  else
  begin
    UpdateModel;
    if EscCount = 0 then
      ClearMask;
  end;
  AriNorm;
  Result := Symbol;
end;

end.

