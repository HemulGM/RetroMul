unit A5200.ASAP.CPU;

interface

uses
  System.SysUtils, System.Math, A5200.Arithmetic, A5200.ASAP.Types,
  A5200.POKEY.Types;

procedure Cpu6502_AddWithCarry(ctx: TCpu6502; data: Integer);

function Cpu6502_ArithmeticShiftLeft(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_CheckIrq(ctx: TCpu6502);

function Cpu6502_Decrement(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_DoFrame(ctx: TCpu6502; cycleLimit: Integer);

procedure Cpu6502_ExecuteIrq(ctx: TCpu6502; b: Integer);

function Cpu6502_Increment(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_LogicalShiftRight(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_Peek(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_PeekReadModifyWrite(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_Poke(ctx: TCpu6502; addr: Integer; data: Integer);

function Cpu6502_Pull(ctx: TCpu6502): Integer;

procedure Cpu6502_PullFlags(ctx: TCpu6502);

procedure Cpu6502_Push(ctx: TCpu6502; data: Integer);

procedure Cpu6502_PushFlags(ctx: TCpu6502; b: Integer);

procedure Cpu6502_PushPc(ctx: TCpu6502);

procedure Cpu6502_Reset(ctx: TCpu6502);

function Cpu6502_RotateLeft(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_RotateRight(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_Shx(ctx: TCpu6502; addr: Integer; data: Integer);

procedure Cpu6502_SubtractWithCarry(ctx: TCpu6502; data: Integer);

implementation

uses
  A5200.ASAP;

const
  OpcodeCycles: array[0..255] of Byte = (
    7, 6, 2, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    6, 6, 2, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    6, 6, 2, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    6, 6, 2, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,
    2, 6, 2, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5,
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,
    2, 5, 2, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4,
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7);


// One shared work limit protects both RMT analysis paths from cyclic commands.

procedure Cpu6502_AddWithCarry(ctx: TCpu6502; data: Integer);
var
  a: Integer;
  vdi: Integer;
  tmp: Integer;
  al: Integer;
  conditionValue1: Integer;
begin
  a := S32(ctx.a);
  vdi := S32(ctx.vdi);
  tmp := S32(Int64(S32(Int64(a) + data)) + ctx.c);
  ctx.nz := S32((tmp and 255));
  if ((vdi and 8) = 0) then
  begin
    ctx.vdi := S32(Int64((vdi and 12)) + (Sar32(((not (data xor a)) and (a xor tmp)), 1) and 64));
    ctx.c := S32(Sar32(tmp, 8));
    ctx.a := S32(ctx.nz);
  end
  else
  begin
    al := S32(Int64(S32(Int64((a and 15)) + (data and 15))) + ctx.c);
    if (al >= 10) then
    begin
      if (al < 26) then
      begin
        conditionValue1 := 6;
      end
      else
      begin
        conditionValue1 := (-10);
      end;
      tmp := S32(Int64(tmp) + conditionValue1);
      if (ctx.nz <> 0) then
      begin
        ctx.nz := S32(Int64((tmp and 128)) + 1);
      end;
    end;
    ctx.vdi := S32(Int64((vdi and 12)) + (Sar32(((not (data xor a)) and (a xor tmp)), 1) and 64));
    if (tmp >= 160) then
    begin
      ctx.c := S32(1);
      ctx.a := S32((S32(Int64(tmp) - 160) and 255));
    end
    else
    begin
      ctx.c := S32(0);
      ctx.a := S32(tmp);
    end;
  end;
end;

function Cpu6502_ArithmeticShiftLeft(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Cpu6502_PeekReadModifyWrite(ctx, addr));
  ctx.c := S32(Sar32(data, 7));
  data := S32((S32((Int64(data) shl (1 and 31))) and 255));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

procedure Cpu6502_CheckIrq(ctx: TCpu6502);
begin
  if (((ctx.vdi and 4) = 0) and ASAP_IsIrq(ctx.asap)) then
  begin
    ctx.cycle := S32(Int64(ctx.cycle) + 7);
    Cpu6502_ExecuteIrq(ctx, 32);
  end;
end;

function Cpu6502_Decrement(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32((S32(Int64(Cpu6502_PeekReadModifyWrite(ctx, addr)) - 1) and 255));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

// Resolves addressing modes and executes instructions without a memory operand.
// True requests the second stage, including a taken relative branch.

function Cpu6502_DecodeOperand(ctx: TCpu6502; opcode: Integer; out addr: Integer): Boolean;
var
  data: Integer;
  operandPC5: Integer;
  operandPC8: Integer;
  operandPC9: Integer;
  operandPC10: Integer;
  operandPC11: Integer;
  operandPC12: Integer;
  zp: Integer;
  operandPC14: Integer;
  operandPC16: Integer;
  operandPC17: Integer;
  operandPC18: Integer;
  operandPC20: Integer;
  operandPC21: Integer;
  operandPC22: Integer;
  operandPC24: Integer;
  operandPC26: Integer;
  operandPC27: Integer;
  operandPC28: Integer;
  operandPC29: Integer;
  operandPC31: Integer;
  operandPC32: Integer;
  operandPC34: Integer;
  operandPC36: Integer;
  operandPC38: Integer;
  hi: Integer;
  operandPC39: Integer;
  operandPC40: Integer;
  operandPC42: Integer;
  conditionValue43: Integer;
begin
  addr := 0;
  case opcode of
    0:
      begin
        ctx.pc := S32(ctx.pc + 1);
        Cpu6502_ExecuteIrq(ctx, 48);
        Exit(False);
      end;
    1, 3, 33, 35, 65, 67, 97, 99, 129, 131, 161, 163, 193, 195, 225, 227:
      begin
        operandPC5 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(ctx.memory[operandPC5]) + ctx.x) and 255));
        addr := S32(Int64(ctx.memory[addr]) + S32((Int64(ctx.memory[(S32(Int64(addr) + 1) and 255)]) shl (8 and 31))));
        Exit(True);
      end;
    2, 18, 34, 50, 66, 82, 98, 114, 146, 178, 210, 242:
      begin
        ctx.pc := S32(ctx.pc - 1);
        ctx.cycle := S32(ctx.asap.nextEventCycle);
        Exit(False);
      end;
    4, 68, 100, 20, 52, 84, 116, 212, 244, 128, 130, 137, 194, 226:
      begin
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    5, 6, 7, 36, 37, 38, 39, 69, 70, 71, 101, 102, 103, 132, 133, 134, 135, 164, 165, 166, 167, 196, 197, 198, 199, 228, 229, 230, 231:
      begin
        operandPC8 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC8]);
        Exit(True);
      end;
    8:
      begin
        Cpu6502_PushFlags(ctx, 48);
        Exit(False);
      end;
    9, 41, 73, 105, 160, 162, 169, 192, 201, 224, 233, 235:
      begin
        operandPC9 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(operandPC9);
        Exit(True);
      end;
    10:
      begin
        ctx.c := S32(Sar32(ctx.a, 7));
        ctx.a := S32((S32((Int64(ctx.a) shl (1 and 31))) and 255));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    11, 43:
      begin
        operandPC10 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.a := S32(Int64(ctx.a) and ctx.memory[operandPC10]);
        ctx.nz := S32(ctx.a);
        ctx.c := S32(Sar32(ctx.nz, 7));
        Exit(False);
      end;
    12:
      begin
        ctx.pc := S32(Int64(ctx.pc) + 2);
        Exit(False);
      end;
    13, 14, 15, 44, 45, 46, 47, 77, 78, 79, 108, 109, 110, 111, 140, 141, 142, 143, 172, 173, 174, 175, 204, 205, 206, 207, 236, 237, 238, 239:
      begin
        operandPC11 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC11]);
        operandPC12 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(addr) + S32((Int64(ctx.memory[operandPC12]) shl (8 and 31))));
        Exit(True);
      end;
    16:
      begin
        if (ctx.nz < 128) then
        begin
          Exit(True);
        end;

        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    17, 49, 81, 113, 177, 179, 209, 241:
      begin
        operandPC14 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        zp := S32(ctx.memory[operandPC14]);
        addr := S32(Int64(ctx.memory[zp]) + ctx.y);
        if (addr >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[(S32(Int64(zp) + 1) and 255)]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    19, 51, 83, 115, 145, 211, 243:
      begin
        operandPC16 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC16]);
        addr := S32((S32(Int64(S32(Int64(ctx.memory[addr]) + S32((Int64(ctx.memory[(S32(Int64(addr) + 1) and 255)]) shl (8 and 31))))) + ctx.y) and 65535));
        Exit(True);
      end;
    21, 22, 23, 53, 54, 55, 85, 86, 87, 117, 118, 119, 148, 149, 180, 181, 213, 214, 215, 245, 246, 247:
      begin
        operandPC17 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(ctx.memory[operandPC17]) + ctx.x) and 255));
        Exit(True);
      end;
    24:
      begin
        ctx.c := S32(0);
        Exit(False);
      end;
    25, 57, 89, 121, 185, 187, 190, 191, 217, 249:
      begin
        operandPC18 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC18]) + ctx.y);
        if (addr >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        operandPC20 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC20]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    27, 59, 91, 123, 153, 219, 251:
      begin
        operandPC21 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC21]) + ctx.y);
        operandPC22 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC22]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    28, 60, 92, 124, 220, 252:
      begin
        if (S32(Int64(ctx.memory[ctx.pc]) + ctx.x) >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        ctx.pc := S32(Int64(ctx.pc) + 2);
        Exit(False);
      end;
    29, 61, 93, 125, 188, 189, 221, 253:
      begin
        operandPC24 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC24]) + ctx.x);
        if (addr >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        operandPC26 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC26]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    30, 31, 62, 63, 94, 95, 126, 127, 157, 222, 223, 254, 255:
      begin
        operandPC27 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC27]) + ctx.x);
        operandPC28 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC28]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    32:
      begin
        operandPC29 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC29]);
        Cpu6502_PushPc(ctx);
        ctx.pc := S32(Int64(addr) + S32((Int64(ctx.memory[ctx.pc]) shl (8 and 31))));
        Exit(False);
      end;
    40:
      begin
        Cpu6502_PullFlags(ctx);
        Cpu6502_CheckIrq(ctx);
        Exit(False);
      end;
    42:
      begin
        ctx.a := S32(Int64(S32((Int64(ctx.a) shl (1 and 31)))) + ctx.c);
        ctx.c := S32(Sar32(ctx.a, 8));
        ctx.a := S32(Int64(ctx.a) and 255);
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    48:
      begin
        if (ctx.nz >= 128) then
        begin
          Exit(True);
        end;

        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    56:
      begin
        ctx.c := S32(1);
        Exit(False);
      end;
    64:
      begin
        Cpu6502_PullFlags(ctx);
        ctx.pc := S32(Cpu6502_Pull(ctx));
        ctx.pc := S32(Int64(ctx.pc) + S32((Int64(Cpu6502_Pull(ctx)) shl (8 and 31))));
        Cpu6502_CheckIrq(ctx);
        Exit(False);
      end;
    72:
      begin
        Cpu6502_Push(ctx, ctx.a);
        Exit(False);
      end;
    74:
      begin
        ctx.c := S32((ctx.a and 1));
        ctx.a := S32(Sar32(ctx.a, 1));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    75:
      begin
        operandPC31 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.a := S32(Int64(ctx.a) and ctx.memory[operandPC31]);
        ctx.c := S32((ctx.a and 1));
        ctx.a := S32(Sar32(ctx.a, 1));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    76:
      begin
        operandPC32 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC32]);
        ctx.pc := S32(Int64(addr) + S32((Int64(ctx.memory[ctx.pc]) shl (8 and 31))));
        Exit(False);
      end;
    80:
      begin
        if ((ctx.vdi and 64) = 0) then
        begin
          Exit(True);
        end;

        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    88:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) and 72);
        Cpu6502_CheckIrq(ctx);
        Exit(False);
      end;
    96:
      begin
        ctx.pc := S32(Cpu6502_Pull(ctx));
        ctx.pc := S32(Int64(ctx.pc) + S32(Int64(S32((Int64(Cpu6502_Pull(ctx)) shl (8 and 31)))) + 1));
        Exit(False);
      end;
    104:
      begin
        ctx.a := S32(Cpu6502_Pull(ctx));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    106:
      begin
        ctx.nz := S32(Int64(S32((Int64(ctx.c) shl (7 and 31)))) + Sar32(ctx.a, 1));
        ctx.c := S32((ctx.a and 1));
        ctx.a := S32(ctx.nz);
        Exit(False);
      end;
    107:
      begin
        operandPC34 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        data := S32((ctx.a and ctx.memory[operandPC34]));
        ctx.a := S32(Int64(Sar32(data, 1)) + S32((Int64(ctx.c) shl (7 and 31))));
        ctx.nz := S32(ctx.a);
        ctx.vdi := S32(Int64((ctx.vdi and 12)) + ((ctx.a xor data) and 64));
        if ((ctx.vdi and 8) = 0) then
        begin
          ctx.c := S32(Sar32(data, 7));
        end
        else
        begin
          if ((data and 15) >= 5) then
          begin
            ctx.a := S32(Int64((ctx.a and 240)) + (S32(Int64(ctx.a) + 6) and 15));
          end;
          if (data >= 80) then
          begin
            ctx.a := S32((S32(Int64(ctx.a) + 96) and 255));
            ctx.c := S32(1);
          end
          else
          begin
            ctx.c := S32(0);
          end;
        end;
        Exit(False);
      end;
    112:
      begin
        if ((ctx.vdi and 64) <> 0) then
        begin
          Exit(True);
        end;

        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    120:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) or 4);
        Exit(False);
      end;
    136:
      begin
        ctx.y := S32((S32(Int64(ctx.y) - 1) and 255));
        ctx.nz := S32(ctx.y);
        Exit(False);
      end;
    138:
      begin
        ctx.a := S32(ctx.x);
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    139:
      begin
        operandPC36 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        data := S32(ctx.memory[operandPC36]);
        ctx.a := S32(Int64(ctx.a) and ((data or 239) and ctx.x));
        ctx.nz := S32((ctx.a and data));
        Exit(False);
      end;
    144:
      begin
        if (ctx.c = 0) then
        begin
          Exit(True);
        end;

        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    147:
      begin
        operandPC38 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC38]);
        hi := S32(ctx.memory[(S32(Int64(addr) + 1) and 255)]);
        addr := S32(ctx.memory[addr]);
        data := S32(((S32(Int64(hi) + 1) and ctx.a) and ctx.x));
        addr := S32(Int64(addr) + ctx.y);
        if (addr >= 256) then
        begin
          hi := S32(Int64(data) - 1);
        end;
        addr := S32(Int64(addr) + S32((Int64(hi) shl (8 and 31))));
        Cpu6502_Poke(ctx, addr, data);
        Exit(False);
      end;
    150, 151, 182, 183:
      begin
        operandPC39 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(ctx.memory[operandPC39]) + ctx.y) and 255));
        Exit(True);
      end;
    152:
      begin
        ctx.a := S32(ctx.y);
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    154:
      begin
        ctx.s := S32(ctx.x);
        Exit(False);
      end;
    155:
      begin
        ctx.s := S32((ctx.a and ctx.x));
        Cpu6502_Shx(ctx, ctx.y, ctx.s);
        Exit(False);
      end;
    156:
      begin
        Cpu6502_Shx(ctx, ctx.x, ctx.y);
        Exit(False);
      end;
    158:
      begin
        Cpu6502_Shx(ctx, ctx.y, ctx.x);
        Exit(False);
      end;
    159:
      begin
        Cpu6502_Shx(ctx, ctx.y, (ctx.a and ctx.x));
        Exit(False);
      end;
    168:
      begin
        ctx.y := S32(ctx.a);
        ctx.nz := S32(ctx.y);
        Exit(False);
      end;
    170:
      begin
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    171:
      begin
        operandPC40 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.a := S32(Int64(ctx.a) and ctx.memory[operandPC40]);
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    176:
      begin
        if (ctx.c <> 0) then
        begin
          Exit(True);
        end;

        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    184:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) and 12);
        Exit(False);
      end;
    186:
      begin
        ctx.x := S32(ctx.s);
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    200:
      begin
        ctx.y := S32((S32(Int64(ctx.y) + 1) and 255));
        ctx.nz := S32(ctx.y);
        Exit(False);
      end;
    202:
      begin
        ctx.x := S32((S32(Int64(ctx.x) - 1) and 255));
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    203:
      begin
        operandPC42 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.nz := S32(ctx.memory[operandPC42]);
        ctx.x := S32(Int64(ctx.x) and ctx.a);
        if (ctx.x >= ctx.nz) then
        begin
          conditionValue43 := 1;
        end
        else
        begin
          conditionValue43 := 0;
        end;
        ctx.c := S32(conditionValue43);
        ctx.x := S32((S32(Int64(ctx.x) - ctx.nz) and 255));
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    208:
      begin
        if ((ctx.nz and 255) <> 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    216:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) and 68);
        Exit(False);
      end;
    232:
      begin
        ctx.x := S32((S32(Int64(ctx.x) + 1) and 255));
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    234, 26, 58, 90, 122, 218, 250:
      begin
        Exit(False);
      end;
    240:
      begin
        if ((ctx.nz and 255) = 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    248:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) or 8);
        Exit(False);
      end;
  else
    begin
      abort();
    end;
  end;
end;

// Applies the memory operation after its addressing mode has been resolved.

procedure Cpu6502_ExecuteOperand(ctx: TCpu6502; opcode, addr: Integer);
var
  data: Integer;
  conditionValue48: Integer;
  conditionValue49: Integer;
  conditionValue50: Integer;
  conditionValue51: Integer;
  conditionValue52: Integer;
begin
  case opcode of
    1, 5, 9, 13, 17, 21, 25, 29:
      begin
        ctx.a := S32(Int64(ctx.a) or Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    3, 7, 15, 19, 23, 27, 31:
      begin
        ctx.a := S32(Int64(ctx.a) or Cpu6502_ArithmeticShiftLeft(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    6, 14, 22, 30:
      begin
        ctx.nz := S32(Cpu6502_ArithmeticShiftLeft(ctx, addr));
      end;
    16, 48, 80, 112, 144, 176, 208, 240:
      begin
        addr := S32(Int64((ctx.memory[ctx.pc] xor 128)) - 128);
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(addr) + ctx.pc);
        if (Sar32((addr xor ctx.pc), 8) <> 0) then
        begin
          conditionValue48 := 2;
        end
        else
        begin
          conditionValue48 := 1;
        end;
        ctx.cycle := S32(Int64(ctx.cycle) + conditionValue48);
        ctx.pc := S32(addr);
      end;
    33, 37, 41, 45, 49, 53, 57, 61:
      begin
        ctx.a := S32(Int64(ctx.a) and Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    35, 39, 47, 51, 55, 59, 63:
      begin
        ctx.a := S32(Int64(ctx.a) and Cpu6502_RotateLeft(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    36, 44:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        ctx.vdi := S32(Int64((ctx.vdi and 12)) + (ctx.nz and 64));
        ctx.nz := S32(Int64(S32((Int64((ctx.nz and 128)) shl (1 and 31)))) + (ctx.nz and ctx.a));
      end;
    38, 46, 54, 62:
      begin
        ctx.nz := S32(Cpu6502_RotateLeft(ctx, addr));
      end;
    65, 69, 73, 77, 81, 85, 89, 93:
      begin
        ctx.a := S32(Int64(ctx.a) xor Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    67, 71, 79, 83, 87, 91, 95:
      begin
        ctx.a := S32(Int64(ctx.a) xor Cpu6502_LogicalShiftRight(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    70, 78, 86, 94:
      begin
        ctx.nz := S32(Cpu6502_LogicalShiftRight(ctx, addr));
      end;
    97, 101, 105, 109, 113, 117, 121, 125:
      begin
        Cpu6502_AddWithCarry(ctx, Cpu6502_Peek(ctx, addr));
      end;
    99, 103, 111, 115, 119, 123, 127:
      begin
        Cpu6502_AddWithCarry(ctx, Cpu6502_RotateRight(ctx, addr));
      end;
    102, 110, 118, 126:
      begin
        ctx.nz := S32(Cpu6502_RotateRight(ctx, addr));
      end;
    108:
      begin
        ctx.pc := S32(ctx.memory[addr]);
        addr := S32(addr + 1);
        if ((addr and 255) = 0) then
        begin
          addr := S32(Int64(addr) - 255);
        end;
        ctx.pc := S32(Int64(ctx.pc) + S32((Int64(ctx.memory[addr]) shl (8 and 31))));
      end;
    129, 133, 141, 145, 149, 153, 157:
      begin
        Cpu6502_Poke(ctx, addr, ctx.a);
      end;
    131, 135, 143, 151:
      begin
        Cpu6502_Poke(ctx, addr, (ctx.a and ctx.x));
      end;
    132, 140, 148:
      begin
        Cpu6502_Poke(ctx, addr, ctx.y);
      end;
    134, 142, 150:
      begin
        Cpu6502_Poke(ctx, addr, ctx.x);
      end;
    160, 164, 172, 180, 188:
      begin
        ctx.y := S32(Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.y);
      end;
    161, 165, 169, 173, 177, 181, 185, 189:
      begin
        ctx.a := S32(Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    162, 166, 174, 182, 190:
      begin
        ctx.x := S32(Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.x);
      end;
    163, 167, 175, 179, 183, 191:
      begin
        ctx.a := S32(Cpu6502_Peek(ctx, addr));
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
      end;
    187:
      begin
        ctx.s := S32(Int64(ctx.s) and Cpu6502_Peek(ctx, addr));
        ctx.a := S32(ctx.s);
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
      end;
    192, 196, 204:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        if (ctx.y >= ctx.nz) then
        begin
          conditionValue49 := 1;
        end
        else
        begin
          conditionValue49 := 0;
        end;
        ctx.c := S32(conditionValue49);
        ctx.nz := S32((S32(Int64(ctx.y) - ctx.nz) and 255));
      end;
    193, 197, 201, 205, 209, 213, 217, 221:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        if (ctx.a >= ctx.nz) then
        begin
          conditionValue50 := 1;
        end
        else
        begin
          conditionValue50 := 0;
        end;
        ctx.c := S32(conditionValue50);
        ctx.nz := S32((S32(Int64(ctx.a) - ctx.nz) and 255));
      end;
    195, 199, 207, 211, 215, 219, 223:
      begin
        data := S32(Cpu6502_Decrement(ctx, addr));
        if (ctx.a >= data) then
        begin
          conditionValue51 := 1;
        end
        else
        begin
          conditionValue51 := 0;
        end;
        ctx.c := S32(conditionValue51);
        ctx.nz := S32((S32(Int64(ctx.a) - data) and 255));
      end;
    198, 206, 214, 222:
      begin
        ctx.nz := S32(Cpu6502_Decrement(ctx, addr));
      end;
    224, 228, 236:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        if (ctx.x >= ctx.nz) then
        begin
          conditionValue52 := 1;
        end
        else
        begin
          conditionValue52 := 0;
        end;
        ctx.c := S32(conditionValue52);
        ctx.nz := S32((S32(Int64(ctx.x) - ctx.nz) and 255));
      end;
    225, 229, 233, 235, 237, 241, 245, 249, 253:
      begin
        Cpu6502_SubtractWithCarry(ctx, Cpu6502_Peek(ctx, addr));
      end;
    227, 231, 239, 243, 247, 251, 255:
      begin
        Cpu6502_SubtractWithCarry(ctx, Cpu6502_Increment(ctx, addr));
      end;
    230, 238, 246, 254:
      begin
        ctx.nz := S32(Cpu6502_Increment(ctx, addr));
      end;
  else
    Abort;
  end;
end;

procedure Cpu6502_DoFrame(ctx: TCpu6502; cycleLimit: Integer);
var
  opcode, address, instructionPC: Integer;
begin
  while ctx.cycle < cycleLimit do
  begin
    if ctx.cycle >= ctx.asap.nextEventCycle then
    begin
      ASAP_HandleEvent(ctx.asap);
      Cpu6502_CheckIrq(ctx);
    end;
    instructionPC := ctx.pc;
    ctx.pc := S32(Int64(ctx.pc) + 1);
    opcode := ctx.memory[instructionPC];
    ctx.cycle := S32(Int64(ctx.cycle) + OpcodeCycles[opcode]);
    if Cpu6502_DecodeOperand(ctx, opcode, address) then
      Cpu6502_ExecuteOperand(ctx, opcode, address);
  end;
end;

procedure Cpu6502_ExecuteIrq(ctx: TCpu6502; b: Integer);
begin
  Cpu6502_PushPc(ctx);
  Cpu6502_PushFlags(ctx, b);
  ctx.vdi := S32(Int64(ctx.vdi) or 4);
  ctx.pc := S32(Int64(ctx.memory[65534]) + S32((Int64(ctx.memory[65535]) shl (8 and 31))));
end;

function Cpu6502_Increment(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32((S32(Int64(Cpu6502_PeekReadModifyWrite(ctx, addr)) + 1) and 255));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

function Cpu6502_LogicalShiftRight(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Cpu6502_PeekReadModifyWrite(ctx, addr));
  ctx.c := S32((data and 1));
  data := S32(Sar32(data, 1));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

function Cpu6502_Peek(ctx: TCpu6502; addr: Integer): Integer;
begin
  if ((addr and 63744) = 53248) then
  begin
    Exit(S32(ASAP_PeekHardware(ctx.asap, addr)));
  end
  else
  begin
    Exit(S32(ctx.memory[addr]));
  end;
end;

function Cpu6502_PeekReadModifyWrite(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  if (Sar32(addr, 8) = 210) then
  begin
    ctx.cycle := S32(ctx.cycle - 1);
    data := S32(ASAP_PeekHardware(ctx.asap, addr));
    ASAP_PokeHardware(ctx.asap, addr, data);
    ctx.cycle := S32(ctx.cycle + 1);
    Exit(S32(data));
  end;

  Exit(S32(ctx.memory[addr]));
end;

procedure Cpu6502_Poke(ctx: TCpu6502; addr: Integer; data: Integer);
begin
  if ((addr and 63744) = 53248) then
  begin
    ASAP_PokeHardware(ctx.asap, addr, data);
  end
  else
  begin
    ctx.memory[addr] := U8(data);
  end;
end;

function Cpu6502_Pull(ctx: TCpu6502): Integer;
var
  s: Integer;
begin
  s := S32((S32(Int64(ctx.s) + 1) and 255));
  ctx.s := S32(s);
  Exit(S32(ctx.memory[S32(Int64(256) + s)]));
end;

procedure Cpu6502_PullFlags(ctx: TCpu6502);
var
  data: Integer;
begin
  data := S32(Cpu6502_Pull(ctx));
  ctx.nz := S32(Int64(S32((Int64((data and 128)) shl (1 and 31)))) + ((not data) and 2));
  ctx.c := S32((data and 1));
  ctx.vdi := S32((data and 76));
end;

procedure Cpu6502_Push(ctx: TCpu6502; data: Integer);
var
  s: Integer;
begin
  s := S32(ctx.s);
  ctx.memory[S32(Int64(256) + s)] := U8(data);
  ctx.s := S32((S32(Int64(s) - 1) and 255));
end;

procedure Cpu6502_PushFlags(ctx: TCpu6502; b: Integer);
var
  nz: Integer;
begin
  nz := S32(ctx.nz);
  b := S32(Int64(b) + S32(Int64(S32(Int64(((nz or Sar32(nz, 1)) and 128)) + ctx.vdi)) + ctx.c));
  if ((nz and 255) = 0) then
  begin
    b := S32(Int64(b) + 2);
  end;
  Cpu6502_Push(ctx, b);
end;

procedure Cpu6502_PushPc(ctx: TCpu6502);
begin
  Cpu6502_Push(ctx, Sar32(ctx.pc, 8));
  Cpu6502_Push(ctx, (ctx.pc and 255));
end;

procedure Cpu6502_Reset(ctx: TCpu6502);
begin
  ctx.cycle := S32(0);
  ctx.nz := S32(0);
  ctx.c := S32(0);
  ctx.vdi := S32(0);
end;

function Cpu6502_RotateLeft(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Int64(S32((Int64(Cpu6502_PeekReadModifyWrite(ctx, addr)) shl (1 and 31)))) + ctx.c);
  ctx.c := S32(Sar32(data, 8));
  data := S32(Int64(data) and 255);
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

function Cpu6502_RotateRight(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Int64(S32((Int64(ctx.c) shl (8 and 31)))) + Cpu6502_PeekReadModifyWrite(ctx, addr));
  ctx.c := S32((data and 1));
  data := S32(Sar32(data, 1));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

procedure Cpu6502_Shx(ctx: TCpu6502; addr: Integer; data: Integer);
var
  operandPC1: Integer;
  hi: Integer;
  operandPC2: Integer;
begin
  operandPC1 := ctx.pc;
  ctx.pc := S32(ctx.pc + 1);
  addr := S32(Int64(addr) + ctx.memory[operandPC1]);
  operandPC2 := ctx.pc;
  ctx.pc := S32(ctx.pc + 1);
  hi := S32(ctx.memory[operandPC2]);
  data := S32(Int64(data) and S32(Int64(hi) + 1));
  if (addr >= 256) then
  begin
    hi := S32(Int64(data) - 1);
  end;
  addr := S32(Int64(addr) + S32((Int64(hi) shl (8 and 31))));
  Cpu6502_Poke(ctx, addr, data);
end;

procedure Cpu6502_SubtractWithCarry(ctx: TCpu6502; data: Integer);
var
  a: Integer;
  vdi: Integer;
  borrow: Integer;
  tmp: Integer;
  al: Integer;
  conditionValue1: Integer;
  conditionValue2: Integer;
begin
  a := S32(ctx.a);
  vdi := S32(ctx.vdi);
  borrow := S32(Int64(ctx.c) - 1);
  tmp := S32(Int64(S32(Int64(a) - data)) + borrow);
  al := S32(Int64(S32(Int64((a and 15)) - (data and 15))) + borrow);
  ctx.vdi := S32(Int64((vdi and 12)) + (Sar32(((data xor a) and (a xor tmp)), 1) and 64));
  if (tmp >= 0) then
  begin
    conditionValue1 := 1;
  end
  else
  begin
    conditionValue1 := 0;
  end;
  ctx.c := S32(conditionValue1);
  ctx.a := S32((tmp and 255));
  ctx.nz := S32(ctx.a);
  if ((vdi and 8) <> 0) then
  begin
    if (al < 0) then
    begin
      if (al < (-10)) then
      begin
        conditionValue2 := 10;
      end
      else
      begin
        conditionValue2 := (-6);
      end;
      ctx.a := S32(Int64(ctx.a) + conditionValue2);
    end;
    if (ctx.c = 0) then
    begin
      ctx.a := S32((S32(Int64(ctx.a) - 96) and 255));
    end;
  end;
end;

end.

