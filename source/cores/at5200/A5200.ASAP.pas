unit A5200.ASAP;

interface

uses
  System.SysUtils, System.Math, A5200.Arithmetic, A5200.ASAP.Types,
  A5200.POKEY.Types;

procedure ASAP_Call6502(ctx: TASAP; addr: Integer);

procedure ASAP_Call6502Player(ctx: TASAP);

procedure ASAP_Construct(ctx: TASAP);

function ASAP_Do6502Frame(ctx: TASAP): Integer;

function ASAP_Do6502Init(ctx: TASAP; pc: Integer; a: Integer; x: Integer; y: Integer): Boolean;

function ASAP_DoFrame(ctx: TASAP): Integer;

function ASAP_Generate(ctx: TASAP; buffer: TBytes; bufferLen: Integer; format: TASAPSampleFormat): Integer;

function ASAP_GenerateAt(ctx: TASAP; buffer: TBytes; bufferOffset: Integer; bufferLen: Integer; format: TASAPSampleFormat): Integer;

procedure ASAP_HandleEvent(ctx: TASAP);

function ASAP_IsIrq(ctx: TASAP): Boolean;

function ASAP_MillisecondsToBlocks(ctx: TASAP; milliseconds: Integer): Integer;

procedure ASAP_MutePokeyChannels(ctx: TASAP; mask: Integer);

function ASAP_PeekHardware(ctx: TASAP; addr: Integer): Integer;

function ASAP_PlaySong(ctx: TASAP; song: Integer; duration: Integer): Boolean;

procedure ASAP_PokeHardware(ctx: TASAP; addr: Integer; data: Integer);

implementation

uses
  A5200.ASAP.Info, A5200.ASAP.CPU, A5200.POKEY.Engine;

procedure ASAP_Call6502(ctx: TASAP; addr: Integer);
begin
  ctx.cpu.memory[53760] := U8(32);
  ctx.cpu.memory[53761] := U8(addr);
  ctx.cpu.memory[53762] := U8(Sar32(addr, 8));
  ctx.cpu.memory[53763] := U8(210);
  ctx.cpu.pc := S32(53760);
end;

procedure ASAP_Call6502Player(ctx: TASAP);
var
  player: Integer;
  i: Integer;
begin
  player := S32(ctx.moduleInfo.player);
  case ctx.moduleInfo.kind of
    ASAPModuleType_SAP_B:
      begin
        ASAP_Call6502(ctx, player);
      end;
    ASAPModuleType_SAP_C, ASAPModuleType_CMC, ASAPModuleType_CM3, ASAPModuleType_CMR, ASAPModuleType_CMS:
      begin
        ASAP_Call6502(ctx, S32(Int64(player) + 6));
      end;
    ASAPModuleType_SAP_D, ASAPModuleType_MD1:
      begin
        if ctx.moduleInfo.kind = ASAPModuleType_MD1 then
          Inc(player, 3);
        if (player >= 0) then
        begin
          Cpu6502_PushPc(ctx.cpu);
          ctx.cpu.memory[53760] := U8(8);
          ctx.cpu.memory[53761] := U8(72);
          ctx.cpu.memory[53762] := U8(138);
          ctx.cpu.memory[53763] := U8(72);
          ctx.cpu.memory[53764] := U8(152);
          ctx.cpu.memory[53765] := U8(72);
          ctx.cpu.memory[53766] := U8(32);
          ctx.cpu.memory[53767] := U8(player);
          ctx.cpu.memory[53768] := U8(Sar32(player, 8));
          ctx.cpu.memory[53769] := U8(104);
          ctx.cpu.memory[53770] := U8(168);
          ctx.cpu.memory[53771] := U8(104);
          ctx.cpu.memory[53772] := U8(170);
          ctx.cpu.memory[53773] := U8(104);
          ctx.cpu.memory[53774] := U8(64);
          ctx.cpu.pc := S32(53760);
        end;
      end;
    ASAPModuleType_SAP_S:
      begin
        i := S32(Int64(ctx.cpu.memory[69]) - 1);
        ctx.cpu.memory[69] := U8(i);
        if (i = 0) then
        begin
          ctx.cpu.memory[45179] := U8(S32(Int64(ctx.cpu.memory[45179]) + 1));
        end;
      end;
    ASAPModuleType_DLT:
      begin
        ASAP_Call6502(ctx, S32(Int64(player) + 259));
      end;
    ASAPModuleType_MPT, ASAPModuleType_RMT, ASAPModuleType_TM2, ASAPModuleType_FC:
      begin
        ASAP_Call6502(ctx, S32(Int64(player) + 3));
      end;
    ASAPModuleType_D15:
      begin
        if (ctx.cpu.cycle >= 1254) and
          (ctx.mptSamplesCurrentAddress div 256 < ctx.cpu.memory[ctx.moduleInfo.music + 16 + ctx.currentSong]) then
        begin
          var Value := Integer(ctx.cpu.memory[ctx.mptSamplesCurrentAddress]);
          if ctx.mptSamplesSecondNibble then
          begin
            Inc(ctx.mptSamplesCurrentAddress);
            ctx.mptSamplesSecondNibble := False;
          end
          else
          begin
            Value := Value shr 4;
            ctx.mptSamplesSecondNibble := True;
          end;
          PokeyPair_Poke(ctx.pokeys, $D201, (Value and 15) or $F0, ctx.cpu.cycle);
        end;
      end;
    ASAPModuleType_TMC:
      begin
        ctx.tmcPerFrameCounter := S32(ctx.tmcPerFrameCounter - 1);
        if (ctx.tmcPerFrameCounter <= 0) then
        begin
          ctx.tmcPerFrameCounter := S32(ctx.cpu.memory[S32(Int64(ASAPInfo_GetMusicAddress(ctx.moduleInfo)) + 31)]);
          ASAP_Call6502(ctx, S32(Int64(player) + 3));
        end
        else
        begin
          ASAP_Call6502(ctx, S32(Int64(player) + 6));
        end;
      end;
  end;
end;

procedure ASAP_Construct(ctx: TASAP);
begin
  PokeyPair_Construct(ctx.pokeys);
  ASAPInfo_Construct(ctx.moduleInfo);
  ctx.currentSampleRate := S32(44100);
  ctx.silenceCycles := S32(0);
  ctx.cpu.asap := ctx;
end;

function ASAP_Do6502Frame(ctx: TASAP): Integer;
var
  conditionValue1: Integer;
  cycles: Integer;
  conditionValue2: Integer;
  i: Integer;
begin
  ctx.nextEventCycle := S32(0);
  ctx.nextScanlineCycle := S32(0);
  if (ctx.nmist = NmiStatus_RESET) then
  begin
    conditionValue1 := NmiStatus_ON_V_BLANK;
  end
  else
  begin
    conditionValue1 := NmiStatus_WAS_V_BLANK;
  end;
  ctx.nmist := S32(conditionValue1);
  if ASAPInfo_IsNtsc(ctx.moduleInfo) then
  begin
    conditionValue2 := 29868;
  end
  else
  begin
    conditionValue2 := 35568;
  end;
  cycles := S32(conditionValue2);
  Cpu6502_DoFrame(ctx.cpu, cycles);
  ctx.cpu.cycle := S32(Int64(ctx.cpu.cycle) - cycles);
  if (ctx.nextPlayerCycle <> 8388608) then
  begin
    ctx.nextPlayerCycle := S32(Int64(ctx.nextPlayerCycle) - cycles);
  end;
  i := S32(3);
  while True do
  begin
    PokeyChannel_EndFrame(ctx.pokeys.basePokey.channels[i], cycles);
    PokeyChannel_EndFrame(ctx.pokeys.extraPokey.channels[i], cycles);
    if (i = 0) then
    begin
      Break;
    end;

    i := S32(Sar32(i, 1));
  end;

  Exit(S32(cycles));
end;

function ASAP_Do6502Init(ctx: TASAP; pc: Integer; a: Integer; x: Integer; y: Integer): Boolean;
var
  frame: Integer;
begin
  ctx.cpu.pc := S32(pc);
  ctx.cpu.a := S32((a and 255));
  ctx.cpu.x := S32((x and 255));
  ctx.cpu.y := S32((y and 255));
  ctx.cpu.memory[53760] := U8(210);
  ctx.cpu.memory[510] := U8(255);
  ctx.cpu.memory[511] := U8(209);
  ctx.cpu.s := S32(253);
  frame := S32(0);
  while (frame < 50) do
  begin
    ASAP_Do6502Frame(ctx);
    if (ctx.cpu.pc = 53760) then
    begin
      Exit(True);
    end;

    frame := S32(frame + 1);
  end;

  Exit(False);
end;

function ASAP_DoFrame(ctx: TASAP): Integer;
var
  cycles: Integer;
begin
  ctx.gtiaOrCovoxPlayedThisFrame := False;
  PokeyPair_StartFrame(ctx.pokeys);
  cycles := S32(ASAP_Do6502Frame(ctx));
  PokeyPair_EndFrame(ctx.pokeys, cycles);
  Exit(S32(cycles));
end;

function ASAP_Generate(ctx: TASAP; buffer: TBytes; bufferLen: Integer; format: TASAPSampleFormat): Integer;
begin
  Exit(S32(ASAP_GenerateAt(ctx, buffer, 0, bufferLen, format)));
end;

function ASAP_GenerateAt(ctx: TASAP; buffer: TBytes; bufferOffset: Integer; bufferLen: Integer; format: TASAPSampleFormat): Integer;
var
  blockShift: Integer;
  conditionValue1: Integer;
  bufferBlocks: Integer;
  totalBlocks: Integer;
  block: Integer;
  blocks: Integer;
  cycles: Integer;
begin
  if ((ctx.silenceCycles > 0) and (ctx.silenceCyclesCounter <= 0)) then
  begin
    Exit(S32(0));
  end;

  if (format = ASAPSampleFormat_U8) then
  begin
    conditionValue1 := 1;
  end
  else
  begin
    conditionValue1 := 0;
  end;
  blockShift := S32(Int64(ASAPInfo_GetChannels(ctx.moduleInfo)) - conditionValue1);
  bufferBlocks := S32(Sar32(bufferLen, blockShift));
  if (ctx.currentDuration > 0) then
  begin
    totalBlocks := S32(ASAP_MillisecondsToBlocks(ctx, ctx.currentDuration));
    if (bufferBlocks > S32(Int64(totalBlocks) - ctx.blocksPlayed)) then
    begin
      bufferBlocks := S32(Int64(totalBlocks) - ctx.blocksPlayed);
    end;
  end;
  block := S32(0);
  while True do
  begin
    blocks := S32(PokeyPair_Generate(ctx.pokeys, buffer, S32(Int64(bufferOffset) + S32((Int64(block) shl (blockShift and 31)))), S32(Int64(bufferBlocks) - block), format));
    ctx.blocksPlayed := S32(Int64(ctx.blocksPlayed) + blocks);
    block := S32(Int64(block) + blocks);
    if (block >= bufferBlocks) then
    begin
      Break;
    end;

    cycles := S32(ASAP_DoFrame(ctx));
    if (ctx.silenceCycles > 0) then
    begin
      if (PokeyPair_IsSilent(ctx.pokeys) and not (ctx.gtiaOrCovoxPlayedThisFrame)) then
      begin
        ctx.silenceCyclesCounter := S32(Int64(ctx.silenceCyclesCounter) - cycles);
        if (ctx.silenceCyclesCounter <= 0) then
        begin
          Break;
        end;
      end
      else
      begin
        ctx.silenceCyclesCounter := S32(ctx.silenceCycles);
      end;
    end;
  end;

  Exit(S32((Int64(block) shl (blockShift and 31))));
end;

procedure ASAP_HandleEvent(ctx: TASAP);
var
  cycle: Integer;
  nextEventCycle: Integer;
begin
  cycle := S32(ctx.cpu.cycle);
  if (cycle >= ctx.nextScanlineCycle) then
  begin
    if (S32(Int64(cycle) - ctx.nextScanlineCycle) < 50) then
    begin
      cycle := S32(Int64(cycle) + 9);
      ctx.cpu.cycle := S32(cycle);
    end;
    ctx.nextScanlineCycle := S32(Int64(ctx.nextScanlineCycle) + 114);
    if (cycle >= ctx.nextPlayerCycle) then
    begin
      ASAP_Call6502Player(ctx);
      ctx.nextPlayerCycle := S32(Int64(ctx.nextPlayerCycle) + S32(Int64(114) * ASAPInfo_GetPlayerRateScanlines(ctx.moduleInfo)));
    end;
  end;
  nextEventCycle := S32(ctx.nextScanlineCycle);
  nextEventCycle := S32(Pokey_CheckIrq(ctx.pokeys.basePokey, cycle, nextEventCycle));
  nextEventCycle := S32(Pokey_CheckIrq(ctx.pokeys.extraPokey, cycle, nextEventCycle));
  ctx.nextEventCycle := S32(nextEventCycle);
end;

function ASAP_IsIrq(ctx: TASAP): Boolean;
begin
  Exit((ctx.pokeys.basePokey.irqst <> 255));
end;

function ASAP_MillisecondsToBlocks(ctx: TASAP; milliseconds: Integer): Integer;
var
  ms: Int64;
begin
  ms := milliseconds;
  Exit(S32(((ms * ctx.currentSampleRate) div 1000)));
end;

procedure ASAP_MutePokeyChannels(ctx: TASAP; mask: Integer);
begin
  Pokey_Mute(ctx.pokeys.basePokey, mask);
  Pokey_Mute(ctx.pokeys.extraPokey, Sar32(mask, 4));
end;

function ASAP_PeekHardware(ctx: TASAP; addr: Integer): Integer;
var
  conditionValue2: Integer;
  cycle: Integer;
  conditionValue3: Integer;
  conditionValue5: Integer;
begin
  case (addr and 65311) of
    53268:
      begin
        if ASAPInfo_IsNtsc(ctx.moduleInfo) then
        begin
          conditionValue2 := 15;
        end
        else
        begin
          conditionValue2 := 1;
        end;
        Exit(S32(conditionValue2));
      end;
    53279:
      begin
        Exit(S32(((not ctx.consol) and 15)));
      end;
    53770, 53786, 53774, 53790:
      begin
        Exit(S32(PokeyPair_Peek(ctx.pokeys, addr, ctx.cpu.cycle)));
      end;
    53772, 53788, 53775, 53791:
      begin
        Exit(S32(255));
      end;
    54283, 54299:
      begin
        cycle := S32(ctx.cpu.cycle);
        if ASAPInfo_IsNtsc(ctx.moduleInfo) then
        begin
          conditionValue3 := 29868;
        end
        else
        begin
          conditionValue3 := 35568;
        end;
        if (cycle > conditionValue3) then
        begin
          Exit(S32(0));
        end;
        Exit(S32((cycle div 228)));
      end;
    54287, 54303:
      begin
        case ctx.nmist of
          NmiStatus_RESET:
            begin
              Exit(S32(31));
            end;
          NmiStatus_WAS_V_BLANK:
            begin
              Exit(S32(95));
            end;
        else
          begin
            if (ctx.cpu.cycle < 28291) then
            begin
              conditionValue5 := 31;
            end
            else
            begin
              conditionValue5 := 95;
            end;
            Exit(S32(conditionValue5));
          end;
        end;
      end;
  else
    Exit(S32(ctx.cpu.memory[addr]));
  end;
end;

function ASAP_PlaySong(ctx: TASAP; song: Integer; duration: Integer): Boolean;
var
  player: Integer;
  music: Integer;
begin
  if ((song < 0) or (song >= ASAPInfo_GetSongs(ctx.moduleInfo))) then
  begin
    Exit(False);
  end;

  ctx.currentSong := S32(song);
  ctx.currentDuration := S32(duration);
  ctx.nextPlayerCycle := S32(8388608);
  ctx.blocksPlayed := S32(0);
  ctx.silenceCyclesCounter := S32(ctx.silenceCycles);
  Cpu6502_Reset(ctx.cpu);
  ctx.nmist := S32(NmiStatus_ON_V_BLANK);
  ctx.consol := S32(8);
  ctx.covox[0] := U8(128);
  ctx.covox[1] := U8(128);
  ctx.covox[2] := U8(128);
  ctx.covox[3] := U8(128);
  PokeyPair_Initialize(ctx.pokeys, ASAPInfo_IsNtsc(ctx.moduleInfo), (ASAPInfo_GetChannels(ctx.moduleInfo) > 1), ctx.currentSampleRate);
  ASAP_MutePokeyChannels(ctx, 255);
  player := S32(ctx.moduleInfo.player);
  music := S32(ASAPInfo_GetMusicAddress(ctx.moduleInfo));
  case ctx.moduleInfo.kind of
    ASAPModuleType_SAP_B:
      begin
        if not (ASAP_Do6502Init(ctx, ASAPInfo_GetInitAddress(ctx.moduleInfo), song, 0, 0)) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_SAP_C, ASAPModuleType_CMC, ASAPModuleType_CM3, ASAPModuleType_CMR, ASAPModuleType_CMS:
      begin
        if not (ASAP_Do6502Init(ctx, S32(Int64(player) + 3), 112, music, Sar32(music, 8))) then
        begin
          Exit(False);
        end;
        if not (ASAP_Do6502Init(ctx, S32(Int64(player) + 3), 0, song, 0)) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_SAP_D, ASAPModuleType_SAP_S:
      begin
        ctx.cpu.pc := S32(ASAPInfo_GetInitAddress(ctx.moduleInfo));
        ctx.cpu.a := S32(song);
        ctx.cpu.x := S32(0);
        ctx.cpu.y := S32(0);
        ctx.cpu.s := S32(255);
      end;
    ASAPModuleType_DLT:
      begin
        if not (ASAP_Do6502Init(ctx, S32(Int64(player) + 256), 0, 0, ctx.moduleInfo.songPos[song])) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_MPT, ASAPModuleType_MD1:
      begin
        if not (ASAP_Do6502Init(ctx, player, 0, Sar32(music, 8), music)) then
        begin
          Exit(False);
        end;
        if ctx.moduleInfo.kind = ASAPModuleType_MD1 then
          if not ASAP_Do6502Init(ctx, player, 3, ctx.mptSamplesPage - 1, 224) then
            Exit(False);
        if not (ASAP_Do6502Init(ctx, player, 2, ctx.moduleInfo.songPos[song], 0)) then
        begin
          Exit(False);
        end;
        if ctx.moduleInfo.kind = ASAPModuleType_MD1 then
        begin
          ctx.cpu.pc := player;
          ctx.cpu.a := 5;
          ctx.cpu.x := Ord(ctx.mptSamples15kHz);
          ctx.cpu.s := 255;
        end;
      end;
    ASAPModuleType_D15:
      begin
        ctx.mptSamplesCurrentAddress := Integer(ctx.cpu.memory[music + song]) * 256;
        ctx.mptSamplesSecondNibble := False;
        ctx.cpu.memory[$D200] := $D2;
        ctx.cpu.pc := $D200;
      end;
    ASAPModuleType_RMT:
      begin
        if not (ASAP_Do6502Init(ctx, player, ctx.moduleInfo.songPos[song], music, Sar32(music, 8))) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_TMC, ASAPModuleType_TM2:
      begin
        if not (ASAP_Do6502Init(ctx, player, 112, Sar32(music, 8), music)) then
        begin
          Exit(False);
        end;
        if not (ASAP_Do6502Init(ctx, player, 0, song, 0)) then
        begin
          Exit(False);
        end;
        ctx.tmcPerFrameCounter := S32(1);
      end;
    ASAPModuleType_FC:
      begin
        if not (ASAP_Do6502Init(ctx, player, song, 0, 0)) then
        begin
          Exit(False);
        end;
      end;
  end;
  ASAP_MutePokeyChannels(ctx, 0);
  ctx.nextPlayerCycle := S32(0);
  Exit(True);
end;

procedure ASAP_PokeHardware(ctx: TASAP; addr: Integer; data: Integer);
var
  t: Integer;
  x: Integer;
  conditionValue1: Integer;
  conditionValue2: Integer;
  pokey: TPokey;
  delta: Integer;
  cycle: Integer;
begin
  if (Sar32(addr, 8) = 210) then
  begin
    t := S32(PokeyPair_Poke(ctx.pokeys, addr, data, ctx.cpu.cycle));
    if (ctx.nextEventCycle > t) then
    begin
      ctx.nextEventCycle := S32(t);
    end;
  end
  else
  begin
    if ((addr and 65295) = 54282) then
    begin
      x := S32((ctx.cpu.cycle mod 114));
      if (x <= 106) then
      begin
        conditionValue1 := 106;
      end
      else
      begin
        conditionValue1 := 220;
      end;
      ctx.cpu.cycle := S32(Int64(ctx.cpu.cycle) + S32(Int64(conditionValue1) - x));
    end
    else
    begin
      if ((addr and 65295) = 54287) then
      begin
        if (ctx.cpu.cycle < 28292) then
        begin
          conditionValue2 := NmiStatus_ON_V_BLANK;
        end
        else
        begin
          conditionValue2 := NmiStatus_RESET;
        end;
        ctx.nmist := S32(conditionValue2);
      end
      else
      begin
        if ((addr and 65280) = ASAPInfo_GetCovoxAddress(ctx.moduleInfo)) then
        begin
          addr := S32(Int64(addr) and 3);
          if ((addr = 0) or (addr = 3)) then
          begin
            pokey := ctx.pokeys.basePokey;
          end
          else
          begin
            pokey := ctx.pokeys.extraPokey;
          end;
          delta := S32(Int64(data) - ctx.covox[addr]);
          if (delta <> 0) then
          begin
            Pokey_AddExternalDelta(pokey, ctx.pokeys, ctx.cpu.cycle, S32((Int64(delta) shl (17 and 31))));
            ctx.covox[addr] := U8(data);
            ctx.gtiaOrCovoxPlayedThisFrame := True;
          end;
        end
        else
        begin
          if ((addr and 65311) = 53279) then
          begin
            delta := S32((Int64(S32(Int64((ctx.consol and 8)) - (data and 8))) shl (20 and 31)));
            if (delta <> 0) then
            begin
              cycle := S32(ctx.cpu.cycle);
              Pokey_AddExternalDelta(ctx.pokeys.basePokey, ctx.pokeys, cycle, delta);
              Pokey_AddExternalDelta(ctx.pokeys.extraPokey, ctx.pokeys, cycle, delta);
              ctx.gtiaOrCovoxPlayedThisFrame := True;
            end;
            ctx.consol := S32(data);
          end
          else
          begin
            ctx.cpu.memory[addr] := U8(data);
          end;
        end;
      end;
    end;
  end;
end;

end.

