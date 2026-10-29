unit A5200.POKEY.Engine;

interface

uses
  System.SysUtils, System.Math, A5200.Arithmetic, A5200.POKEY.Types;

procedure PokeyChannel_DoStimer(ctx: TPokeyChannel; cycle: Integer);

procedure PokeyChannel_DoTick(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer; ch: Integer);

procedure PokeyChannel_EndFrame(ctx: TPokeyChannel; cycle: Integer);

procedure PokeyChannel_Initialize(ctx: TPokeyChannel);

procedure PokeyChannel_SetAudc(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; data: Integer; cycle: Integer);

procedure PokeyChannel_SetMute(ctx: TPokeyChannel; enable: Boolean; mask: Integer; cycle: Integer);

procedure PokeyChannel_Slope(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer);

procedure PokeyPair_Construct(ctx: TPokeyPair);

function PokeyPair_EndFrame(ctx: TPokeyPair; cycle: Integer): Integer;

function PokeyPair_Generate(ctx: TPokeyPair; buffer: TBytes; bufferOffset: Integer; blocks: Integer; format: TASAPSampleFormat): Integer;

function PokeyPair_GetSampleFactor(ctx: TPokeyPair; clock: Integer): Integer;

procedure PokeyPair_Initialize(ctx: TPokeyPair; ntsc: Boolean; stereo: Boolean; sampleRate: Integer);

function PokeyPair_IsSilent(ctx: TPokeyPair): Boolean;

function PokeyPair_Peek(ctx: TPokeyPair; addr: Integer; cycle: Integer): Integer;

function PokeyPair_Poke(ctx: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;

procedure PokeyPair_StartFrame(ctx: TPokeyPair);

procedure Pokey_AccumulateTrailing(ctx: TPokey; i: Integer);

procedure Pokey_AddDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);

procedure Pokey_AddExternalDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);

function Pokey_CheckIrq(ctx: TPokey; cycle: Integer; nextEventCycle: Integer): Integer;

procedure Pokey_Construct(ctx: TPokey);

procedure Pokey_EndFrame(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer);

procedure Pokey_GenerateUntilCycle(ctx: TPokey; pokeys: TPokeyPair; cycleLimit: Integer);

procedure Pokey_InitMute(ctx: TPokey; cycle: Integer);

procedure Pokey_Initialize(ctx: TPokey; sampleRate: Integer);

function Pokey_IsSilent(ctx: TPokey): Boolean;

procedure Pokey_Mute(ctx: TPokey; mask: Integer);

function Pokey_Poke(ctx: TPokey; pokeys: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;

procedure Pokey_StartFrame(ctx: TPokey);

function Pokey_StoreSample(ctx: TPokey; buffer: TBytes; bufferOffset: Integer; i: Integer; format: TASAPSampleFormat): Integer;

implementation

procedure PokeyChannel_DoStimer(ctx: TPokeyChannel; cycle: Integer);
begin
  if (ctx.tickCycle <> 8388608) then
  begin
    ctx.tickCycle := S32(Int64(cycle) + ctx.periodCycles);
  end;
end;

procedure PokeyChannel_DoTick(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer; ch: Integer);
var
  audc: Integer;
  poly: Integer;
  newOut: Integer;
begin
  ctx.tickCycle := S32(Int64(ctx.tickCycle) + ctx.periodCycles);
  audc := S32(ctx.audc);
  if ((audc and 176) = 160) then
  begin
    ctx.output := S32(Int64(ctx.output) xor 1);
  end
  else
  begin
    if (((audc and 16) <> 0) or pokey.init) then
    begin
      Exit;
    end
    else
    begin
      poly := S32(Int64(S32(Int64(cycle) + pokey.polyIndex)) - ch);
      if ((audc < 128) and ((1706902752 and S32((Int64(1) shl ((poly mod 31) and 31)))) = 0)) then
      begin
        Exit;
      end;

      if ((audc and 32) <> 0) then
      begin
        ctx.output := S32(Int64(ctx.output) xor 1);
      end
      else
      begin
        if ((audc and 64) <> 0) then
        begin
          newOut := S32(Sar32(21360, (poly mod 15)));
        end
        else
        begin
          if (pokey.audctl < 128) then
          begin
            poly := S32(Int64(poly) mod 131071);
            newOut := S32(Sar32(pokeys.poly17Lookup[Sar32(poly, 3)], (poly and 7)));
          end
          else
          begin
            newOut := S32(pokeys.poly9Lookup[(poly mod 511)]);
          end;
        end;
        newOut := S32(Int64(newOut) and 1);
        if (ctx.output = newOut) then
        begin
          Exit;
        end;

        ctx.output := S32(newOut);
      end;
    end;
  end;
  PokeyChannel_Slope(ctx, pokey, pokeys, cycle);
end;

procedure PokeyChannel_EndFrame(ctx: TPokeyChannel; cycle: Integer);
begin
  if (ctx.timerCycle <> 8388608) then
  begin
    ctx.timerCycle := S32(Int64(ctx.timerCycle) - cycle);
  end;
end;

procedure PokeyChannel_Initialize(ctx: TPokeyChannel);
begin
  ctx.audf := S32(0);
  ctx.audc := S32(0);
  ctx.periodCycles := S32(28);
  ctx.tickCycle := S32(8388608);
  ctx.timerCycle := S32(8388608);
  ctx.mute := S32(0);
  ctx.output := S32(0);
  ctx.delta := S32(0);
end;

procedure PokeyChannel_SetAudc(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; data: Integer; cycle: Integer);
var
  conditionValue1: Integer;
begin
  if (ctx.audc = data) then
  begin
    Exit;
  end;

  Pokey_GenerateUntilCycle(pokey, pokeys, cycle);
  ctx.audc := S32(data);
  if ((data and 16) <> 0) then
  begin
    data := S32(Int64(data) and 15);
    if ((ctx.mute and 2) = 0) then
    begin
      if (ctx.delta > 0) then
      begin
        conditionValue1 := S32(Int64(data) - ctx.delta);
      end
      else
      begin
        conditionValue1 := data;
      end;
      Pokey_AddDelta(pokey, pokeys, cycle, conditionValue1);
    end;
    ctx.delta := S32(data);
  end
  else
  begin
    data := S32(Int64(data) and 15);
    if (ctx.delta > 0) then
    begin
      if ((ctx.mute and 2) = 0) then
      begin
        Pokey_AddDelta(pokey, pokeys, cycle, S32(Int64(data) - ctx.delta));
      end;
      ctx.delta := S32(data);
    end
    else
    begin
      ctx.delta := S32((-data));
    end;
  end;
end;

procedure PokeyChannel_SetMute(ctx: TPokeyChannel; enable: Boolean; mask: Integer; cycle: Integer);
begin
  if enable then
  begin
    ctx.mute := S32(Int64(ctx.mute) or mask);
    ctx.tickCycle := S32(8388608);
  end
  else
  begin
    ctx.mute := S32(Int64(ctx.mute) and (not mask));
    if ((ctx.mute = 0) and (ctx.tickCycle = 8388608)) then
    begin
      ctx.tickCycle := S32(cycle);
    end;
  end;
end;

procedure PokeyChannel_Slope(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer);
begin
  ctx.delta := S32((-ctx.delta));
  Pokey_AddDelta(pokey, pokeys, cycle, ctx.delta);
end;

procedure PokeyPair_Construct(ctx: TPokeyPair);
var
  reg: Integer;
  i: Integer;
  sincSum: Double;
  leftSum: Double;
  norm: Double;
  sinc: TArray<Double>;
  j: Integer;
  x: Double;
  s: Double;
  conditionValue7: Double;
begin
  Pokey_Construct(ctx.basePokey);
  Pokey_Construct(ctx.extraPokey);
  reg := S32(511);
  i := S32(0);
  while (i < 511) do
  begin
    reg := S32(Int64(S32((Int64(((Sar32(reg, 5) xor reg) and 1)) shl (8 and 31)))) + Sar32(reg, 1));
    ctx.poly9Lookup[i] := U8(reg);
    i := S32(i + 1);
  end;
  reg := S32(131071);
  i := S32(0);
  while (i < 16385) do
  begin
    reg := S32(Int64(S32((Int64(((Sar32(reg, 5) xor reg) and 255)) shl (9 and 31)))) + Sar32(reg, 8));
    ctx.poly17Lookup[i] := U8(Sar32(reg, 1));
    i := S32(i + 1);
  end;
  i := S32(0);
  while (i < 1024) do
  begin
    sincSum := 0;
    leftSum := 0;
    norm := 0;
    SetLength(sinc, 31);
    j := S32((-32));
    while (j < 32) do
    begin
      if (j = (-16)) then
      begin
        leftSum := sincSum;
      end
      else
      begin
        if (j = 15) then
        begin
          norm := sincSum;
        end;
      end;
      x := ((3.141592653589793 / 1024) * S32(Int64(S32((Int64(j) shl (10 and 31)))) - i));
      if (x = 0) then
      begin
        conditionValue7 := 1;
      end
      else
      begin
        conditionValue7 := (sin(x) / x);
      end;
      s := conditionValue7;
      if ((j >= (-16)) and (j < 15)) then
      begin
        sinc[S32(Int64(16) + j)] := s;
      end;
      sincSum := sincSum + s;
      j := S32(j + 1);
    end;
    norm := (16384 / (norm + ((1 - sincSum) * 0.5)));
    ctx.sincLookup[i][0] := S16(Round(((leftSum + ((1 - sincSum) * 0.5)) * norm)));
    j := S32(1);
    while (j < 32) do
    begin
      ctx.sincLookup[i][j] := S16(Round((sinc[S32(Int64(j) - 1)] * norm)));
      j := S32(j + 1);
    end;
    i := S32(i + 1);
  end;
end;

function PokeyPair_EndFrame(ctx: TPokeyPair; cycle: Integer): Integer;
begin
  Pokey_EndFrame(ctx.basePokey, ctx, cycle);
  if (ctx.extraPokeyMask <> 0) then
  begin
    Pokey_EndFrame(ctx.extraPokey, ctx, cycle);
  end;
  ctx.sampleOffset := S32(Int64(ctx.sampleOffset) + S32(Int64(cycle) * ctx.sampleFactor));
  ctx.readySamplesStart := S32(0);
  ctx.readySamplesEnd := S32(Sar32(ctx.sampleOffset, 18));
  ctx.sampleOffset := S32(Int64(ctx.sampleOffset) and 262143);
  Exit(S32(ctx.readySamplesEnd));
end;

function PokeyPair_Generate(ctx: TPokeyPair; buffer: TBytes; bufferOffset: Integer; blocks: Integer; format: TASAPSampleFormat): Integer;
var
  i: Integer;
  samplesEnd: Integer;
begin
  i := S32(ctx.readySamplesStart);
  samplesEnd := S32(ctx.readySamplesEnd);
  if (blocks < S32(Int64(samplesEnd) - i)) then
  begin
    samplesEnd := S32(Int64(i) + blocks);
  end
  else
  begin
    blocks := S32(Int64(samplesEnd) - i);
  end;
  if (blocks > 0) then
  begin
    while (i < samplesEnd) do
    begin
      bufferOffset := S32(Pokey_StoreSample(ctx.basePokey, buffer, bufferOffset, i, format));
      if (ctx.extraPokeyMask <> 0) then
      begin
        bufferOffset := S32(Pokey_StoreSample(ctx.extraPokey, buffer, bufferOffset, i, format));
      end;
      i := S32(i + 1);
    end;
    if (i = ctx.readySamplesEnd) then
    begin
      Pokey_AccumulateTrailing(ctx.basePokey, i);
      Pokey_AccumulateTrailing(ctx.extraPokey, i);
    end;
    ctx.readySamplesStart := S32(i);
  end;
  Exit(S32(blocks));
end;

function PokeyPair_GetSampleFactor(ctx: TPokeyPair; clock: Integer): Integer;
begin
  Exit(S32((S32(Int64(S32((Int64(ctx.sampleRate) shl (13 and 31)))) + Sar32(clock, 6)) div Sar32(clock, 5))));
end;

procedure PokeyPair_Initialize(ctx: TPokeyPair; ntsc: Boolean; stereo: Boolean; sampleRate: Integer);
var
  conditionValue1: Integer;
  conditionValue2: Integer;
begin
  if stereo then
  begin
    conditionValue1 := 16;
  end
  else
  begin
    conditionValue1 := 0;
  end;
  ctx.extraPokeyMask := S32(conditionValue1);
  ctx.sampleRate := S32(sampleRate);
  Pokey_Initialize(ctx.basePokey, sampleRate);
  Pokey_Initialize(ctx.extraPokey, sampleRate);
  if ntsc then
  begin
    conditionValue2 := PokeyPair_GetSampleFactor(ctx, 1789772);
  end
  else
  begin
    conditionValue2 := PokeyPair_GetSampleFactor(ctx, 1773447);
  end;
  ctx.sampleFactor := S32(conditionValue2);
  ctx.sampleOffset := S32(0);
  ctx.readySamplesStart := S32(0);
  ctx.readySamplesEnd := S32(0);
end;

function PokeyPair_IsSilent(ctx: TPokeyPair): Boolean;
begin
  Exit((Pokey_IsSilent(ctx.basePokey) and Pokey_IsSilent(ctx.extraPokey)));
end;

function PokeyPair_Peek(ctx: TPokeyPair; addr: Integer; cycle: Integer): Integer;
var
  pokey: TPokey;
  conditionValue1: TPokey;
  i: Integer;
  j: Integer;
begin
  if ((addr and ctx.extraPokeyMask) <> 0) then
  begin
    conditionValue1 := ctx.extraPokey;
  end
  else
  begin
    conditionValue1 := ctx.basePokey;
  end;
  pokey := conditionValue1;
  case (addr and 15) of
    10:
      begin
        if pokey.init then
        begin
          Exit(S32(255));
        end;
        i := S32(Int64(cycle) + pokey.polyIndex);
        if ((pokey.audctl and 128) <> 0) then
        begin
          Exit(S32(ctx.poly9Lookup[(i mod 511)]));
        end;
        i := S32(Int64(i) mod 131071);
        j := S32(Sar32(i, 3));
        i := S32(Int64(i) and 7);
        Exit(S32((S32(Int64(Sar32(ctx.poly17Lookup[j], i)) + S32((Int64(ctx.poly17Lookup[S32(Int64(j) + 1)]) shl (S32(Int64(8) - i) and 31)))) and 255)));
      end;
    14:
      begin
        Exit(S32(pokey.irqst));
      end;
  else
    begin
      Exit(S32(255));
    end;
  end;
end;

function PokeyPair_Poke(ctx: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;
var
  pokey: TPokey;
  conditionValue1: TPokey;
begin
  if ((addr and ctx.extraPokeyMask) <> 0) then
  begin
    conditionValue1 := ctx.extraPokey;
  end
  else
  begin
    conditionValue1 := ctx.basePokey;
  end;
  pokey := conditionValue1;
  Exit(S32(Pokey_Poke(pokey, ctx, addr, data, cycle)));
end;

procedure PokeyPair_StartFrame(ctx: TPokeyPair);
begin
  Pokey_StartFrame(ctx.basePokey);
  if (ctx.extraPokeyMask <> 0) then
  begin
    Pokey_StartFrame(ctx.extraPokey);
  end;
end;

procedure Pokey_AccumulateTrailing(ctx: TPokey; i: Integer);
begin
  ctx.trailing := S32(i);
end;

procedure Pokey_AddDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);
var
  newOutput: Integer;
begin
  ctx.sumDACInputs := S32(Int64(ctx.sumDACInputs) + delta);
  newOutput := S32((Int64(Pokey_COMPRESSED_SUMS[EnsureRange(ctx.sumDACInputs, 0, 60)]) shl (16 and 31)));
  Pokey_AddExternalDelta(ctx, pokeys, cycle, S32(Int64(newOutput) - ctx.sumDACOutputs));
  ctx.sumDACOutputs := S32(newOutput);
end;

procedure Pokey_AddExternalDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);
var
  i: Integer;
  fraction: Integer;
  j: Integer;
begin
  if (delta = 0) then
  begin
    Exit;
  end;
  i := S32(Int64(S32(Int64(cycle) * pokeys.sampleFactor)) + pokeys.sampleOffset);
  fraction := S32((Sar32(i, 8) and 1023));
  i := S32(Sar32(i, 18));
  delta := S32(Sar32(delta, 14));
  j := S32(0);
  while (j < 32) do
  begin
    ctx.deltaBuffer[S32(Int64(i) + j)] := S32(Int64(ctx.deltaBuffer[S32(Int64(i) + j)]) + S32(Int64(delta) * pokeys.sincLookup[fraction][j]));
    j := S32(j + 1);
  end;
end;

function Pokey_CheckIrq(ctx: TPokey; cycle: Integer; nextEventCycle: Integer): Integer;
var
  i: Integer;
  timerCycle: Integer;
begin
  i := S32(3);
  while True do
  begin
    timerCycle := S32(ctx.channels[i].timerCycle);
    if (cycle >= timerCycle) then
    begin
      ctx.irqst := S32(Int64(ctx.irqst) and (not S32(Int64(i) + 1)));
      ctx.channels[i].timerCycle := S32(8388608);
    end
    else
    begin
      if (nextEventCycle > timerCycle) then
      begin
        nextEventCycle := S32(timerCycle);
      end;
    end;
    if (i = 0) then
    begin
      Break;
    end;
    i := S32(Sar32(i, 1));
  end;
  Exit(S32(nextEventCycle));
end;

procedure Pokey_Construct(ctx: TPokey);
begin
  ctx.deltaBuffer := nil;
end;

procedure Pokey_EndFrame(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer);
var
  m: Integer;
  conditionValue1: Integer;
  c: Integer;
  tickCycle: Integer;
begin
  Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
  ctx.polyIndex := S32(Int64(ctx.polyIndex) + cycle);
  if ((ctx.audctl and 128) <> 0) then
  begin
    conditionValue1 := 237615;
  end
  else
  begin
    conditionValue1 := 60948015;
  end;
  m := S32(conditionValue1);
  if (ctx.polyIndex >= S32(Int64(2) * m)) then
  begin
    ctx.polyIndex := S32(Int64(ctx.polyIndex) - m);
  end;
  c := S32(0);
  while (c < 4) do
  begin
    tickCycle := S32(ctx.channels[c].tickCycle);
    if (tickCycle <> 8388608) then
    begin
      ctx.channels[c].tickCycle := S32(Int64(tickCycle) - cycle);
    end;
    c := S32(c + 1);
  end;
end;

procedure Pokey_GenerateUntilCycle(ctx: TPokey; pokeys: TPokeyPair; cycleLimit: Integer);
var
  cycle: Integer;
  c: Integer;
  tickCycle: Integer;
begin
  while True do
  begin
    cycle := S32(cycleLimit);
    c := S32(0);
    while (c < 4) do
    begin
      tickCycle := S32(ctx.channels[c].tickCycle);
      if (cycle > tickCycle) then
      begin
        cycle := S32(tickCycle);
      end;
      c := S32(c + 1);
    end;
    if (cycle = cycleLimit) then
    begin
      Break;
    end;
    if (cycle = ctx.channels[2].tickCycle) then
    begin
      if ((((ctx.audctl and 4) <> 0) and (ctx.channels[0].delta > 0)) and (ctx.channels[0].mute = 0)) then
      begin
        PokeyChannel_Slope(ctx.channels[0], ctx, pokeys, cycle);
      end;
      PokeyChannel_DoTick(ctx.channels[2], ctx, pokeys, cycle, 2);
    end;
    if (cycle = ctx.channels[3].tickCycle) then
    begin
      if ((ctx.audctl and 8) <> 0) then
      begin
        ctx.channels[2].tickCycle := S32(Int64(cycle) + ctx.reloadCycles3);
      end;
      if ((((ctx.audctl and 2) <> 0) and (ctx.channels[1].delta > 0)) and (ctx.channels[1].mute = 0)) then
      begin
        PokeyChannel_Slope(ctx.channels[1], ctx, pokeys, cycle);
      end;
      PokeyChannel_DoTick(ctx.channels[3], ctx, pokeys, cycle, 3);
    end;
    if (cycle = ctx.channels[0].tickCycle) then
    begin
      if ((ctx.skctl and 136) = 8) then
      begin
        ctx.channels[1].tickCycle := S32(Int64(cycle) + ctx.channels[1].periodCycles);
      end;
      PokeyChannel_DoTick(ctx.channels[0], ctx, pokeys, cycle, 0);
    end;
    if (cycle = ctx.channels[1].tickCycle) then
    begin
      if ((ctx.audctl and 16) <> 0) then
      begin
        ctx.channels[0].tickCycle := S32(Int64(cycle) + ctx.reloadCycles1);
      end
      else
      begin
        if ((ctx.skctl and 8) <> 0) then
        begin
          ctx.channels[0].tickCycle := S32(Int64(cycle) + ctx.channels[0].periodCycles);
        end;
      end;
      PokeyChannel_DoTick(ctx.channels[1], ctx, pokeys, cycle, 1);
    end;
  end;
end;

procedure Pokey_InitMute(ctx: TPokey; cycle: Integer);
var
  init: Boolean;
  audctl: Integer;
begin
  init := ctx.init;
  audctl := S32(ctx.audctl);
  PokeyChannel_SetMute(ctx.channels[0], (init and ((audctl and 64) = 0)), 1, cycle);
  PokeyChannel_SetMute(ctx.channels[1], (init and ((audctl and 80) <> 80)), 1, cycle);
  PokeyChannel_SetMute(ctx.channels[2], (init and ((audctl and 32) = 0)), 1, cycle);
  PokeyChannel_SetMute(ctx.channels[3], (init and ((audctl and 40) <> 40)), 1, cycle);
end;

procedure Pokey_Initialize(ctx: TPokey; sampleRate: Integer);
var
  sr: Int64;
  c: Integer;
begin
  sr := sampleRate;
  ctx.deltaBufferLength := S32((((((sr * 312) * 114) div 1773447) + 32) + 2));
  SetLength(ctx.deltaBuffer, ctx.deltaBufferLength);
  ctx.trailing := S32(ctx.deltaBufferLength);
  c := S32(0);
  while (c < 4) do
  begin
    PokeyChannel_Initialize(ctx.channels[c]);
    c := S32(c + 1);
  end;
  ctx.audctl := S32(0);
  ctx.skctl := S32(3);
  ctx.irqst := S32(255);
  ctx.init := False;
  ctx.divCycles := S32(28);
  ctx.reloadCycles1 := S32(28);
  ctx.reloadCycles3 := S32(28);
  ctx.polyIndex := S32(60948015);
  ctx.iirAcc := S32(0);
  ctx.iirRate := S32((264600 div sampleRate));
  ctx.sumDACInputs := S32(0);
  Pokey_StartFrame(ctx);
end;

function Pokey_IsSilent(ctx: TPokey): Boolean;
var
  c: Integer;
begin
  c := S32(0);
  while (c < 4) do
  begin
    if ((ctx.channels[c].audc and 15) <> 0) then
    begin
      Exit(False);
    end;

    c := S32(c + 1);
  end;

  Exit(True);
end;

procedure Pokey_Mute(ctx: TPokey; mask: Integer);
var
  i: Integer;
begin
  i := S32(0);
  while (i < 4) do
  begin
    PokeyChannel_SetMute(ctx.channels[i], ((mask and S32((Int64(1) shl (i and 31)))) <> 0), 2, 0);
    i := S32(i + 1);
  end;
end;

function Pokey_Poke(ctx: TPokey; pokeys: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;
var
  nextEventCycle: Integer;
  conditionValue6: Integer;
  c: Integer;
  i: Integer;
  t: Integer;
  init: Boolean;
  conditionValue13: Integer;
begin
  nextEventCycle := S32(8388608);
  case (addr and 15) of
    0:
      begin
        if (data = ctx.channels[0].audf) then
        begin
          Exit(nextEventCycle);
        end;

        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[0].audf := S32(data);
        case (ctx.audctl and 80) of
          0:
            begin
              ctx.channels[0].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          16:
            begin
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles1 := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          64:
            begin
              ctx.channels[0].periodCycles := S32(Int64(data) + 4);
            end;
          80:
            begin
              ctx.channels[1].periodCycles := S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles1 := S32(Int64(data) + 4);
            end;
        else
          Abort;
        end;

        Exit(nextEventCycle);
      end;
    1:
      begin
        PokeyChannel_SetAudc(ctx.channels[0], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    2:
      begin
        if (data = ctx.channels[1].audf) then
        begin
          Exit(nextEventCycle);
        end;

        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[1].audf := S32(data);
        case (ctx.audctl and 80) of
          0, 64:
            begin
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          16:
            begin
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(data) shl (8 and 31))))) + 1));
            end;
          80:
            begin
              ctx.channels[1].periodCycles := S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(data) shl (8 and 31))))) + 7);
            end;
        else
          Abort;
        end;

        Exit(nextEventCycle);
      end;
    3:
      begin
        PokeyChannel_SetAudc(ctx.channels[1], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    4:
      begin
        if (data = ctx.channels[2].audf) then
        begin
          Exit(nextEventCycle);
        end;

        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[2].audf := S32(data);
        case (ctx.audctl and 40) of
          0:
            begin
              ctx.channels[2].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          8:
            begin
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles3 := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          32:
            begin
              ctx.channels[2].periodCycles := S32(Int64(data) + 4);
            end;
          40:
            begin
              ctx.channels[3].periodCycles := S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles3 := S32(Int64(data) + 4);
            end;
        else
          Abort;
        end;

        Exit(nextEventCycle);
      end;
    5:
      begin
        PokeyChannel_SetAudc(ctx.channels[2], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    6:
      begin
        if (data = ctx.channels[3].audf) then
        begin
          Exit(nextEventCycle);
        end;

        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[3].audf := S32(data);
        case (ctx.audctl and 40) of
          0, 32:
            begin
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          8:
            begin
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(data) shl (8 and 31))))) + 1));
            end;
          40:
            begin
              ctx.channels[3].periodCycles := S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(data) shl (8 and 31))))) + 7);
            end;
        else
          Abort;
        end;

        Exit(nextEventCycle);
      end;
    7:
      begin
        PokeyChannel_SetAudc(ctx.channels[3], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    8:
      begin
        if (data = ctx.audctl) then
        begin
          Exit(nextEventCycle);
        end;

        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.audctl := S32(data);
        if ((data and 1) <> 0) then
        begin
          conditionValue6 := 114;
        end
        else
        begin
          conditionValue6 := 28;
        end;
        ctx.divCycles := S32(conditionValue6);
        case (data and 80) of
          0:
            begin
              ctx.channels[0].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[0].audf) + 1));
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[1].audf) + 1));
            end;
          16:
            begin
              ctx.channels[0].periodCycles := S32((Int64(ctx.divCycles) shl (8 and 31)));
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles1 := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[0].audf) + 1));
            end;
          64:
            begin
              ctx.channels[0].periodCycles := S32(Int64(ctx.channels[0].audf) + 4);
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[1].audf) + 1));
            end;
          80:
            begin
              ctx.channels[0].periodCycles := S32(256);
              ctx.channels[1].periodCycles := S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles1 := S32(Int64(ctx.channels[0].audf) + 4);
            end;
        else
          Abort;
        end;

        case (data and 40) of
          0:
            begin
              ctx.channels[2].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[2].audf) + 1));
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[3].audf) + 1));
            end;
          8:
            begin
              ctx.channels[2].periodCycles := S32((Int64(ctx.divCycles) shl (8 and 31)));
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles3 := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[2].audf) + 1));
            end;
          32:
            begin
              ctx.channels[2].periodCycles := S32(Int64(ctx.channels[2].audf) + 4);
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[3].audf) + 1));
            end;
          40:
            begin
              ctx.channels[2].periodCycles := S32(256);
              ctx.channels[3].periodCycles := S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles3 := S32(Int64(ctx.channels[2].audf) + 4);
            end;
        else
          Abort;
        end;

        Pokey_InitMute(ctx, cycle);
        Exit(nextEventCycle);
      end;
    9:
      begin
        c := S32(0);
        while (c < 4) do
        begin
          PokeyChannel_DoStimer(ctx.channels[c], cycle);
          c := S32(c + 1);
        end;
        Exit(nextEventCycle);
      end;
    14:
      begin
        ctx.irqst := S32(Int64(ctx.irqst) or (data xor 255));
        i := S32(3);
        while True do
        begin
          if (((data and ctx.irqst) and S32(Int64(i) + 1)) <> 0) then
          begin
            if (ctx.channels[i].timerCycle = 8388608) then
            begin
              t := S32(ctx.channels[i].tickCycle);
              while (t < cycle) do
              begin
                t := S32(Int64(t) + ctx.channels[i].periodCycles);
              end;
              ctx.channels[i].timerCycle := S32(t);
              if (nextEventCycle > t) then
              begin
                nextEventCycle := S32(t);
              end;
            end;
          end
          else
          begin
            ctx.channels[i].timerCycle := S32(8388608);
          end;
          if (i = 0) then
          begin
            Break;
          end;

          i := S32(Sar32(i, 1));
        end;
        Exit(nextEventCycle);
      end;
    15:
      begin
        if (data = ctx.skctl) then
        begin
          Exit(nextEventCycle);
        end;

        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.skctl := S32(data);
        init := ((data and 3) = 0);
        if (ctx.init and not (init)) then
        begin
          if ((ctx.audctl and 128) <> 0) then
          begin
            conditionValue13 := 237614;
          end
          else
          begin
            conditionValue13 := 60948014;
          end;
          ctx.polyIndex := S32(Int64(conditionValue13) - cycle);
        end;
        ctx.init := init;
        Pokey_InitMute(ctx, cycle);
        PokeyChannel_SetMute(ctx.channels[2], ((data and 16) <> 0), 4, cycle);
        PokeyChannel_SetMute(ctx.channels[3], ((data and 16) <> 0), 4, cycle);
        Exit(nextEventCycle);
      end;
  else
    Exit(nextEventCycle);
  end;
  Exit(S32(nextEventCycle));
end;

procedure Pokey_StartFrame(ctx: TPokey);
begin
  for var copyIndex := 0 to (S32(Int64(S32(Int64(ctx.deltaBufferLength) - ctx.trailing)) * 4)) div 4 - 1 do
    ctx.deltaBuffer[0 + copyIndex] := ctx.deltaBuffer[ctx.trailing + copyIndex];
  for var clearIndex := 0 to (S32(Int64(ctx.trailing) * 4)) div 4 - 1 do
    ctx.deltaBuffer[S32(Int64(ctx.deltaBufferLength) - ctx.trailing) + clearIndex] := 0;
end;

function Pokey_StoreSample(ctx: TPokey; buffer: TBytes; bufferOffset: Integer; i: Integer; format: TASAPSampleFormat): Integer;
var
  sample: Integer;
begin
  ctx.iirAcc := S32(Int64(ctx.iirAcc) + S32(Int64(ctx.deltaBuffer[i]) - Sar32(S32(Int64(ctx.iirRate) * ctx.iirAcc), 11)));
  sample := EnsureRange(Sar32(ctx.iirAcc, 11), -32767, 32767);
  case format of
    ASAPSampleFormat_U8:
      begin
        buffer[bufferOffset] := U8(Sar32(sample, 8) + 128);
        Inc(bufferOffset);
      end;
    ASAPSampleFormat_S16_L_E:
      begin
        buffer[bufferOffset] := U8(sample);
        buffer[bufferOffset + 1] := U8(Sar32(sample, 8));
        Inc(bufferOffset, 2);
      end;
    ASAPSampleFormat_S16_B_E:
      begin
        buffer[bufferOffset] := U8(Sar32(sample, 8));
        buffer[bufferOffset + 1] := U8(sample);
        Inc(bufferOffset, 2);
      end;
  end;
  Result := bufferOffset;
end;

end.

